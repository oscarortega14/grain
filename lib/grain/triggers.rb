# frozen_string_literal: true

module Grain
  # Works out which tables a rollup needs a trigger on, which columns of each one
  # are worth reacting to, and renders the SQL that attaches them.
  #
  # Triggers are named per table rather than per rollup, because the function they
  # call is shared: several rollups reading the same table get one trigger between
  # them. Attaching is written as a drop-then-create so that installing a second
  # rollup over the same table is not an error.
  class Triggers
    # One trigger per table. `update_columns` narrows the UPDATE trigger to the
    # columns that can actually move a row between cells; nil means every update
    # has to be logged.
    Spec = Struct.new(:table, :update_columns, keyword_init: true) do
      def trigger_name
        "grain_#{table}_changed"
      end

      def narrowed?
        !update_columns.nil?
      end
    end

    attr_reader :definition, :types

    def initialize(definition)
      @definition = definition.validate!
      @types = TypeResolver.new(definition)
    end

    # The fact table first, then every table along a watched path, then the tables
    # the filter reaches through.
    def specs
      ([fact_spec] + related_specs).uniq(&:table)
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

    # Measures aggregate arbitrary SQL, so which of the fact table's columns feed
    # them cannot be known. Narrowing here risks missing an update and letting the
    # rollup drift in silence, so every update on the fact is logged.
    def fact_spec
      Spec.new(table: types.fact_table, update_columns: nil)
    end

    def related_specs
      WatchedColumns.new(definition).to_h.map { |table, columns| Spec.new(table: table, update_columns: columns.sort) }
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
