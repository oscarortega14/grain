# frozen_string_literal: true

require "fileutils"
require "rails/generators"
require "generators/grain/install/install_generator"
require "generators/grain/table/table_generator"

# Runs the generators and applies what they write to the live database.
#
# Migrations are generated once per process and re-applied per test. The content
# is identical every time, and reloading the same file repeatedly floods the
# output with method-redefined warnings while proving nothing.
module Harness
  GENERATED = File.expand_path("../tmp/generated", __dir__)

  class << self
    def install!
      clear_once!
      apply(install_path, "CreateGrainChangeLog")
    end

    def build_table!(rollup)
      class_name = "Create#{Grain::Migration.new(rollup.definition).table_name.camelize}"
      apply(table_path(rollup, class_name), class_name)
    end

    private

    # Files left by an earlier run would be reused, so a change to the generators
    # would not show up in the tests that exist to catch it.
    def clear_once!
      return if @cleared

      FileUtils.rm_rf(GENERATED)
      @cleared = true
    end

    def install_path
      cached("CreateGrainChangeLog") do
        generate { Grain::Generators::InstallGenerator.start([], destination_root: GENERATED) }
        newest("create_grain_change_log")
      end
    end

    # Keyed by which rollups are registered as well as by name: the trigger
    # column list is a union across all of them, so the same rollup generates a
    # different migration under a different registry.
    def table_path(rollup, class_name)
      cached("#{class_name}/#{Grain::Registry.all.map(&:name).sort.join(",")}") do
        generate do
          Grain::Generators::TableGenerator.start([rollup.name.underscore], destination_root: GENERATED)
        end
        newest(class_name.underscore)
      end
    end

    def cached(key)
      @cache ||= {}
      @cache[key] ||= yield
    end

    def newest(basename)
      path = Dir[File.join(GENERATED, "db/migrate/*_#{basename}.rb")].max
      raise "no migration matched #{basename}" if path.nil?

      path
    end

    def apply(path, class_name)
      quietly { load path }
      Database.silence { Object.const_get(class_name).new.migrate(:up) }
    end

    def generate(&block)
      quietly(&block)
    end

    def quietly
      original_stdout = $stdout
      original_verbose = $VERBOSE
      $stdout = StringIO.new
      $VERBOSE = nil
      yield
    ensure
      $stdout = original_stdout
      $VERBOSE = original_verbose
    end
  end
end
