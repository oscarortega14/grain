# frozen_string_literal: true

module Grain
  # The SQL fragments every statement needs: the expression that produces each
  # dimension's value, the aggregate that produces each measure, and the
  # conditions the fact's filter imposes.
  #
  # Reaching the tables those expressions live on is JoinGraph's job.
  class Projection
    FACT = JoinGraph::FACT

    attr_reader :definition, :types, :joins

    def initialize(definition)
      @definition = definition
      @types = TypeResolver.new(definition)
      @joins = JoinGraph.new(definition)
    end

    def fact_table
      joins.fact_table
    end

    def alias_for(hops)
      joins.alias_for(hops)
    end

    def from_and_joins(substitutions = {})
      joins.from_and_joins(substitutions)
    end

    def hops_for_table(table)
      joins.hops_for_table(table)
    end

    def key_columns
      definition.key_dimensions.map(&:name)
    end

    def measure_columns
      definition.measures.map(&:name)
    end

    def dimension_expressions
      definition.key_dimensions.map { |dimension| dimension_expression(dimension) }
    end

    def dimension_expression(dimension)
      column = qualified(dimension.path)
      dimension.time? ? bucket(column, dimension) : column
    end

    def aggregate_expressions
      definition.measures.map { |measure| aggregate_expression(measure) }
    end

    # Cast to the measure's declared type, and not for tidiness.
    #
    # SUM over a bigint yields numeric, so a recompute would insert a numeric into
    # a bigint column and let Postgres truncate it, while a verification compared
    # the untruncated value and reported a difference. A sum over anything with a
    # fractional part would have disagreed with itself forever, and repair could
    # never have settled it. Computing at the stored type makes both agree.
    def aggregate_expression(measure)
      "#{raw_aggregate(measure)}::#{sql_type(measure.type)}"
    end

    # Conditions from the fact's filter, already qualified. Equality only in the
    # first release; anything richer belongs in the fact's own scope.
    def filter_conditions
      return [] unless definition.fact.where

      definition.fact.where.flat_map { |key, value| conditions_for(key, value) }
    end

    private

    def raw_aggregate(measure)
      return "COUNT(*)" if measure.counts_rows?

      "COALESCE(#{measure.aggregate.to_s.upcase}(#{measure.expression}), 0)"
    end

    def qualified(path)
      %(#{alias_for(path.hops)}."#{path.column}")
    end

    # A calendar day already is a bucket. A timestamp is not, and resolving it
    # needs an explicit zone: left to the session, the same row would land in
    # different buckets for different callers.
    def bucket(column, dimension)
      return column if types.source_type(dimension) == :date

      "((#{column} AT TIME ZONE '#{Grain.config.time_zone}')::date)"
    end

    def conditions_for(key, value)
      return ["#{FACT}.\"#{key}\" = #{quote(value)}"] unless value.is_a?(Hash)

      name = alias_for([key.to_sym])
      value.map { |column, expected| "#{name}.\"#{column}\" = #{quote(expected)}" }
    end

    def quote(value)
      connection.quote(value)
    end

    def sql_type(type)
      connection.type_to_sql(type)
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
