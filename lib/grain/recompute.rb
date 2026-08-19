# frozen_string_literal: true

module Grain
  # Rebuilds a set of cells from the source: the primitive everything else falls
  # back to, and the only operation that is correct no matter what happened.
  #
  # Delete and then re-insert rather than upsert, because a cell can legitimately
  # become empty. An upsert would leave the old numbers standing when the last
  # source row for a cell goes away.
  class Recompute
    attr_reader :definition, :projection

    def initialize(definition)
      @definition = definition
      @projection = Projection.new(definition)
    end

    def call(cells)
      cells = cells.uniq
      return 0 if cells.empty?

      connection.execute(delete_sql(cells))
      connection.execute(insert_sql(cells))
      cells.length
    end

    def delete_sql(cells)
      "DELETE FROM #{table_name} WHERE #{cells.map { |cell| match(cell) { |key| quote_column(key) } }.join(" OR ")}"
    end

    def insert_sql(cells)
      <<~SQL
        INSERT INTO #{table_name} (#{columns.join(", ")})
        SELECT #{expressions.join(", ")}
        FROM #{projection.from_and_joins.join(" ")}
        WHERE #{where_for(cells)}
        GROUP BY #{projection.dimension_expressions.join(", ")}
      SQL
    end

    private

    def table_name
      definition.table_name
    end

    def columns
      projection.key_columns + projection.measure_columns
    end

    def expressions
      projection.dimension_expressions + projection.aggregate_expressions
    end

    def where_for(cells)
      matches = cells.map { |cell| match(cell) { |key| dimension_expression(key) } }
      (projection.filter_conditions + ["(#{matches.join(" OR ")})"]).join(" AND ")
    end

    # IS NOT DISTINCT FROM rather than =, because a dimension resolved from a
    # nullable column has null as a legitimate coordinate, and null = null is
    # never true.
    def match(cell)
      parts = projection.key_columns.map do |key|
        "#{yield(key)} IS NOT DISTINCT FROM #{connection.quote(cell[key])}"
      end
      "(#{parts.join(" AND ")})"
    end

    def dimension_expression(key)
      @dimension_expressions ||= projection.key_columns.zip(projection.dimension_expressions).to_h
      @dimension_expressions.fetch(key)
    end

    def quote_column(key)
      connection.quote_column_name(key)
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
