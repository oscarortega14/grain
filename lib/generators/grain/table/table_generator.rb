# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Grain
  module Generators
    # Builds the migration for a rollup that already exists: its table, and the
    # triggers on every table its definition depends on.
    #
    # Run it again whenever the definition changes. The rollup's shape is derived
    # from the class, so the generated migration always matches what the code
    # currently declares.
    class TableGenerator < Rails::Generators::NamedBase
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Generates the migration that creates NAME's rollup table and its triggers."

      def create_table_migration
        migration_template "create_rollup_table.rb.erb", "db/migrate/#{rollup_migration_basename}.rb"
      end

      def report_trigger_tables
        say ""
        say "Triggers will be attached to:", :green
        triggers.specs.each do |spec|
          scope = spec.narrowed? ? "updates of #{spec.update_columns.join(", ")}" : "all updates"
          say "  #{spec.table} (#{scope})"
        end
        say ""
      end

      private

      def rollup
        @rollup ||= resolve_rollup
      end

      # Thor prints the message and stops, which is the right behaviour for a
      # command line; the rule itself lives in RollupLookup so it can be tested.
      def resolve_rollup
        Grain::RollupLookup.find!(name)
      rescue Grain::RollupNotFoundError => e
        raise Thor::Error, e.message
      end

      def definition
        @definition ||= rollup.validate!
      end

      def migration
        @migration ||= Grain::Migration.new(definition)
      end

      def triggers
        @triggers ||= Grain::Triggers.new(definition)
      end

      # Deliberately not called migration_file_name or migration_class_name:
      # Rails' own migration machinery calls methods by those names on the
      # generator, and shadowing them breaks it from the inside.
      def rollup_migration_basename
        "create_#{migration.table_name}"
      end

      def rollup_migration_class_name
        rollup_migration_basename.camelize
      end

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end

      def indented(text, spaces)
        prefix = " " * spaces
        text.each_line.map { |line| line.strip.empty? ? line : "#{prefix}#{line}" }.join
      end

      def table_body
        indented(migration.up, 4).rstrip
      end

      def executed_statements(statements, spaces)
        statements.map do |statement|
          "#{" " * spaces}execute <<~SQL\n#{indented(statement, spaces + 2)}\n#{" " * spaces}SQL"
        end.join("\n\n")
      end

      def trigger_up
        executed_statements(triggers.up_statements, 4)
      end

      def trigger_down
        executed_statements(triggers.down_statements, 4)
      end

      def drop_table_statement
        migration.down
      end
    end
  end
end
