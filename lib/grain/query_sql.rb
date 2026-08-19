# frozen_string_literal: true

module Grain
  # Builds the statement a read runs.
  #
  # Any dimension left out of the grouping is aggregated away, which is the
  # property the whole design rests on: a day rolls up into a month by addition,
  # so one stored grain answers questions at every coarser one.
  class QuerySql
    COARSER = %i[day week month quarter year].freeze

    attr_reader :definition

    def initialize(definition, filters: {}, range: nil, groups: {})
      @definition = definition
      @filters = filters
      @range = range
      @groups = groups
    end

    def to_s
      <<~SQL.strip
        SELECT #{selection.join(", ")}
        FROM #{definition.table_name}#{where_clause}#{group_clause}#{order_clause}
      SQL
    end

    private

    def selection
      @groups.map { |name, coarse| "#{group_expression(name, coarse)} AS #{quote_column(name)}" } +
        definition.measures.map { |measure| "#{measure_expression(measure)} AS #{measure.name}" }
    end

    # A sum over nothing is zero, so it is coalesced. An extreme over nothing is
    # left null on purpose: there is no largest value, which is not the same as a
    # largest value of zero.
    #
    # Cast back to the measure's declared type for the same reason the write side
    # does: SUM over a bigint yields numeric, and without this a column stored as
    # an integer would read back as a BigDecimal.
    def measure_expression(measure)
      aggregate = "#{measure.coarsens_with.to_s.upcase}(#{quote_column(measure.name)})"
      aggregate = "COALESCE(#{aggregate}, 0)" if measure.coarsens_with == :sum
      "#{aggregate}::#{connection.type_to_sql(measure.type)}"
    end

    def group_expression(name, coarse)
      column = quote_column(name)
      return column if coarse.nil?
      raise Error, "unknown grain #{coarse.inspect}, expected one of #{COARSER.inspect}" unless COARSER.include?(coarse)

      "(DATE_TRUNC('#{coarse}', #{column})::date)"
    end

    def where_clause
      conditions = @filters.map { |name, value| condition_for(name, value) } + [range_condition].compact
      conditions.empty? ? "" : "\nWHERE #{conditions.join(" AND ")}"
    end

    def condition_for(name, value)
      column = quote_column(name)
      case value
      when nil then "#{column} IS NULL"
      when Array then "#{column} IN (#{value.map { |item| quote(item) }.join(", ")})"
      else "#{column} = #{quote(value)}"
      end
    end

    def range_condition
      return nil if @range.nil?

      "#{quote_column(definition.time.name)} BETWEEN #{quote(@range.first)} AND #{quote(@range.last)}"
    end

    def group_clause
      @groups.empty? ? "" : "\nGROUP BY #{group_positions}"
    end

    def order_clause
      @groups.empty? ? "" : "\nORDER BY #{group_positions}"
    end

    def group_positions
      (1..@groups.length).to_a.join(", ")
    end

    def quote_column(name)
      connection.quote_column_name(name)
    end

    def quote(value)
      connection.quote(value)
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
