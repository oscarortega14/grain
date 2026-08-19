# frozen_string_literal: true

module Grain
  # Builds the single statement that compares a rollup against its source.
  #
  # Stored and expected are stacked with UNION ALL and folded with GROUP BY rather
  # than joined. A FULL OUTER JOIN would be the obvious shape, but Postgres only
  # supports one over merge-joinable or hash-joinable conditions, and matching
  # cells needs IS NOT DISTINCT FROM: a dimension resolved from a nullable column
  # has null as a legitimate coordinate, and null = null is never true. Grouping
  # sidesteps the limitation and gets the semantics for free, since GROUP BY
  # already treats nulls as equal.
  class VerificationQuery
    attr_reader :definition, :projection

    def initialize(definition, tenant: nil, between: nil)
      @definition = definition
      @projection = Projection.new(definition)
      @tenant = tenant
      @between = between
    end

    def to_s
      <<~SQL
        WITH combined AS (
          #{stored_side}
          UNION ALL
          #{expected_side}
        ), folded AS (
          SELECT #{folded_selection}
          FROM combined
          GROUP BY #{key_positions}
        )
        SELECT * FROM folded
        WHERE #{disagreement}
        ORDER BY #{key_positions}
      SQL
    end

    private

    def key_columns
      projection.key_columns
    end

    def measure_columns
      projection.measure_columns
    end

    def key_positions
      (1..key_columns.length).to_a.join(", ")
    end

    def stored_side
      columns = (key_columns + measure_columns).map { |column| quote_column(column) }.join(", ")
      conditions = scope_conditions { |column| quote_column(column) }
      where = conditions.empty? ? "" : " WHERE #{conditions.join(" AND ")}"
      "SELECT #{columns}, 1 AS grain_side FROM #{definition.table_name}#{where}"
    end

    def expected_side
      <<~SQL.rstrip
        SELECT #{expected_selection}, 2 AS grain_side
          FROM #{projection.from_and_joins.join(" ")}#{expected_where}
          GROUP BY #{projection.dimension_expressions.join(", ")}
      SQL
    end

    def expected_selection
      pairs = key_columns.zip(projection.dimension_expressions) +
              measure_columns.zip(projection.aggregate_expressions)
      pairs.map { |name, expression| "#{expression} AS #{quote_column(name)}" }.join(", ")
    end

    def expected_where
      conditions = projection.filter_conditions + scope_conditions { |column| dimension_expression(column) }
      conditions.empty? ? "" : "\n  WHERE #{conditions.join(" AND ")}"
    end

    # At most one row per side per cell, so MAX picks that row's value and the
    # counts say whether the side contributed a row at all — which is what
    # distinguishes "this side had nothing" from "this side had a null".
    def folded_selection
      (key_columns.map { |key| quote_column(key) } + measure_pickers + presence_counts).join(", ")
    end

    def measure_pickers
      sides.flat_map do |side, index|
        measure_columns.map do |measure|
          "MAX(CASE WHEN grain_side = #{index} THEN #{quote_column(measure)} END) AS #{side}_#{measure}"
        end
      end
    end

    def presence_counts
      sides.map { |side, index| "COUNT(*) FILTER (WHERE grain_side = #{index}) AS in_#{side}" }
    end

    def sides
      { "stored" => 1, "expected" => 2 }
    end

    # A cell survives if one side never produced a row, or any measure differs.
    def disagreement
      absent = ["in_stored = 0", "in_expected = 0"]
      differing = measure_columns.map { |measure| "stored_#{measure} IS DISTINCT FROM expected_#{measure}" }
      (absent + differing).join(" OR ")
    end

    def scope_conditions
      conditions = []
      conditions << "#{yield(definition.tenant.name)} = #{quote(@tenant)}" unless @tenant.nil?
      conditions << between_condition(yield(definition.time.name)) unless @between.nil?
      conditions
    end

    def between_condition(column)
      "#{column} BETWEEN #{quote(@between.first)} AND #{quote(@between.last)}"
    end

    def dimension_expression(name)
      @dimension_expressions ||= key_columns.zip(projection.dimension_expressions).to_h
      @dimension_expressions.fetch(name)
    end

    def quote_column(name)
      ActiveRecord::Base.connection.quote_column_name(name)
    end

    def quote(value)
      ActiveRecord::Base.connection.quote(value)
    end
  end
end
