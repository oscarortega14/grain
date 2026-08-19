# frozen_string_literal: true

module Grain
  # Works out which tables need a trigger, which columns of each are worth
  # reacting to, and renders the SQL that attaches them.
  #
  # Built from every rollup that touches a table, not from one at a time. The
  # trigger name is per table because the function it calls is shared, so a
  # migration that considered only its own rollup would narrow a trigger another
  # rollup depends on and leave that one drifting in silence. The column list is
  # therefore the union across all of them.
  class Triggers
    # `update_columns` narrows the UPDATE trigger to the columns that can move a
    # row between cells; nil means every update has to be logged.
    Spec = Struct.new(:table, :update_columns, keyword_init: true) do
      def trigger_name
        "grain_#{table}_changed"
      end

      def narrowed?
        !update_columns.nil?
      end
    end

    attr_reader :definitions

    def initialize(definitions)
      @definitions = Array(definitions).map(&:validate!).uniq
    end

    # Fact tables first, then the tables reached through them.
    def specs
      fact_specs + related_specs
    end

    # One statement per entry, so a migration can execute them individually
    # instead of relying on the adapter accepting several at once.
    def up_statements
      specs.flat_map { |spec| [drop_sql(spec), create_sql(spec)] }
    end

    def down_statements
      specs.map { |spec| drop_sql(spec) }
    end

    def up
      up_statements.join("\n")
    end

    def down
      down_statements.join("\n")
    end

    private

    # Measures aggregate arbitrary SQL, so which of a fact table's columns feed
    # them cannot be known. Narrowing here risks missing an update and letting a
    # rollup drift, so every update on a fact table is logged. Being a fact for
    # any one rollup is enough to disqualify the table from narrowing.
    def fact_specs
      fact_tables.map { |table| Spec.new(table: table, update_columns: nil) }
    end

    def fact_tables
      definitions.map { |definition| TypeResolver.new(definition).fact_table }.uniq
    end

    def related_specs
      union_of_related_columns.reject { |table, _| fact_tables.include?(table) }
                              .map { |table, columns| Spec.new(table: table, update_columns: columns.sort) }
    end

    def union_of_related_columns
      definitions.each_with_object({}) do |definition, union|
        WatchedColumns.new(definition).to_h.each do |table, columns|
          union[table] = ((union[table] || []) + columns).uniq
        end
      end
    end

    def create_sql(spec)
      <<~SQL.strip
        CREATE TRIGGER #{spec.trigger_name}
        AFTER INSERT OR #{update_clause(spec)} OR DELETE ON #{spec.table}
        FOR EACH ROW EXECUTE FUNCTION #{ChangeLog::FUNCTION_NAME}();
      SQL
    end

    def update_clause(spec)
      return "UPDATE" unless spec.narrowed?

      "UPDATE OF #{spec.update_columns.join(", ")}"
    end

    def drop_sql(spec)
      "DROP TRIGGER IF EXISTS #{spec.trigger_name} ON #{spec.table};"
    end
  end
end
