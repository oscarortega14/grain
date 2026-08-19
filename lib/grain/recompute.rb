# frozen_string_literal: true

module Grain
  # Rebuilds cells from the source: the primitive everything else falls back to,
  # and the only operation that is correct no matter what happened.
  #
  # Delete and then re-insert rather than upsert, because a cell can legitimately
  # become empty. An upsert would leave the old numbers standing when the last
  # source row for a cell goes away.
  #
  # Being complete rather than incremental has a useful consequence: a recompute
  # cannot be half-applied and cannot be applied out of order, so a backfill and
  # the worker can run at the same time without coordinating.
  class Recompute
    attr_reader :definition, :projection

    def initialize(definition)
      @definition = definition
      @projection = Projection.new(definition)
    end

    # Rebuilds a known list of cells.
    def call(cells)
      cells = cells.uniq
      return 0 if cells.empty?

      rebuild(matches(cells) { |key| quote_column(key) }, matches(cells) { |key| expression_for(key) })
      cells.length
    end

    # Rebuilds every cell in a slice, for when the cells are not known in advance
    # and all that is known is which slice has to be right — a backfill working
    # through one day or one tenant at a time.
    def call_slice(dimension, value)
      rebuild(
        "#{quote_column(dimension.name)} IS NOT DISTINCT FROM #{quote(value)}",
        "#{expression_for(dimension.name)} IS NOT DISTINCT FROM #{quote(value)}"
      )
    end

    private

    def rebuild(stored_where, source_where)
      connection.execute("DELETE FROM #{table_name} WHERE #{stored_where}")
      connection.execute(insert_sql(source_where))
    end

    def insert_sql(source_where)
      <<~SQL
        INSERT INTO #{table_name} (#{columns.join(", ")})
        SELECT #{expressions.join(", ")}
        FROM #{projection.from_and_joins.join(" ")}
        WHERE #{(projection.filter_conditions + [source_where]).join(" AND ")}
        GROUP BY #{projection.dimension_expressions.join(", ")}
      SQL
    end

    def table_name
      definition.table_name
    end

    def columns
      projection.key_columns + projection.measure_columns
    end

    def expressions
      projection.dimension_expressions + projection.aggregate_expressions
    end

    def matches(cells, &naming)
      "(#{cells.map { |cell| match(cell, &naming) }.join(" OR ")})"
    end

    # IS NOT DISTINCT FROM rather than =, because a dimension resolved from a
    # nullable column has null as a legitimate coordinate, and null = null is
    # never true.
    def match(cell)
      parts = projection.key_columns.map do |key|
        "#{yield(key)} IS NOT DISTINCT FROM #{quote(cell[key])}"
      end
      "(#{parts.join(" AND ")})"
    end

    def expression_for(key)
      @expressions ||= projection.key_columns.zip(projection.dimension_expressions).to_h
      @expressions.fetch(key)
    end

    def quote_column(key)
      connection.quote_column_name(key)
    end

    def quote(value)
      connection.quote(value)
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
