# frozen_string_literal: true

module Grain
  # Which rollups exist, and which of them care about a given table.
  #
  # A trigger records only that a row in some table changed, so the worker needs
  # the reverse mapping: table to the rollups that read it, and in what capacity.
  # A table can be a rollup's fact, one of the tables it resolves dimensions
  # through, or both.
  module Registry
    class << self
      # Rollups are found rather than self-registered: with autoloading, a class
      # that nobody has referenced yet does not exist, so a registry populated by
      # `inherited` would be empty in exactly the process that needs it.
      def all
        @all ||= load_rollups
      end

      def reset!
        @all = nil
      end

      def register(*rollups)
        (@all ||= []).concat(rollups).uniq!
        all
      end

      # Rollups whose fact table this is: a change here is a change to what is
      # being counted.
      def facts_for(table)
        all.select { |rollup| fact_table(rollup) == table }
      end

      # Rollups that resolve a dimension or a filter through this table: a change
      # here can move fact rows between cells without touching the facts.
      def watchers_for(table)
        all.select { |rollup| watched_tables(rollup).include?(table) }
      end

      def for_table(table)
        (facts_for(table) + watchers_for(table)).uniq
      end

      private

      def load_rollups
        eager_load_rollups
        Rollup.subclasses.select { |rollup| rollup.name && valid?(rollup) }
      end

      def eager_load_rollups
        return unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

        Dir[Rails.root.join("app/rollups/**/*.rb")].sort.each { |path| require path }
      end

      # A rollup that cannot be used is left out rather than allowed to take the
      # whole worker down with it, but never silently: everything else it shares
      # a log with would go stale while the log kept draining.
      def valid?(rollup)
        rollup.definition.validate!
        rollup.definition.fact.model
        true
      rescue InvalidDefinitionError, NameError => e
        warn_about(rollup, e)
        false
      end

      def warn_about(rollup, error)
        message = "Grain is skipping #{rollup}: #{error.message}"
        logger = Grain.config.logger
        logger ? logger.warn(message) : Kernel.warn(message)
      end

      def fact_table(rollup)
        rollup.definition.fact.model.table_name
      end

      def watched_tables(rollup)
        WatchedColumns.new(rollup.definition).to_h.keys
      end
    end
  end
end
