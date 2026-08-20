# frozen_string_literal: true

module Grain
  # Recreates the trigger function and every trigger from the current definitions.
  #
  # This is needed far more often than it looks. Rails' schema.rb cannot represent
  # a function or a trigger — the dumper only knows tables, columns and indexes —
  # so loading the schema creates every table and silently drops everything that
  # keeps them correct. That is how test databases are built by default, and what
  # `db:reset` and restoring a dump both do. Without re-attaching, a rollup simply
  # never updates, and the tests that should have caught it pass.
  #
  # Safe to run at any time: the function is CREATE OR REPLACE and each trigger is
  # dropped before being created.
  module Installer
    class << self
      # Returns the tables triggers were attached to.
      def install!(definitions = default_definitions)
        return [] if definitions.empty?

        triggers = Triggers.new(definitions)
        connection.execute(ChangeLog.function_sql)
        triggers.up_statements.each { |statement| connection.execute(statement) }
        triggers.specs.map(&:table)
      end

      # True when the change log's function is present, which is the cheap way to
      # tell a schema load has stripped Grain out.
      def installed?
        connection.select_value(<<~SQL).present?
          SELECT proname FROM pg_proc WHERE proname = '#{ChangeLog::FUNCTION_NAME}'
        SQL
      end

      private

      def default_definitions
        Registry.all.map(&:definition)
      end

      def connection
        ActiveRecord::Base.connection
      end
    end
  end
end
