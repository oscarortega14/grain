# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Grain
  module Generators
    # Sets up the infrastructure every rollup shares: the change log table and the
    # trigger function that watched tables call.
    #
    # Triggers themselves are not installed here. Which tables need watching
    # depends on the rollups an application declares, so they are attached per
    # rollup once those exist.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the Grain change log migration, an initializer and app/rollups."

      def create_change_log_migration
        migration_template "create_grain_change_log.rb.erb",
                           "db/migrate/create_grain_change_log.rb"
      end

      def create_initializer
        template "initializer.rb.erb", "config/initializers/grain.rb"
      end

      def create_rollups_directory
        create_file "app/rollups/.keep"
      end

      def report_next_steps
        say ""
        say "Grain installed. Next:", :green
        say "  1. bin/rails db:migrate"
        say "  2. Declare a rollup in app/rollups"
        say "  3. bin/rails generate grain:rollup <name>  (to build its table and triggers)"
        say ""
      end

      private

      def migration_class_name
        "CreateGrainChangeLog"
      end

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end

      def change_log_table
        Grain::ChangeLog.table_name
      end

      # Migrations are snapshots: the SQL is written into the file rather than
      # read from Grain at run time, so that upgrading the gem never changes what
      # an already-applied migration says it did.
      def indented(text, spaces)
        prefix = " " * spaces
        text.each_line.map { |line| line.strip.empty? ? line : "#{prefix}#{line}" }.join
      end

      def change_log_table_definition
        indented(Grain::ChangeLog.table_definition, 4).rstrip
      end

      def change_log_function_sql
        indented(Grain::ChangeLog.function_sql, 6).rstrip
      end

      def change_log_drop_function_sql
        Grain::ChangeLog.drop_function_sql
      end
    end
  end
end
