# frozen_string_literal: true

module Grain
  # Turns a definition into the SQL fragments every statement needs: the aliases
  # and joins that reach each dimension, the expression that produces its value,
  # and the aggregate that produces each measure.
  #
  # Aliases are registered recursively, so two dimensions reached through the same
  # association share one join rather than duplicating it.
  class Projection
    # The fact table's alias. Measure expressions are the user's own SQL and are
    # inserted verbatim, so this is the name they can qualify columns with.
    FACT = "f"

    Joined = Struct.new(:name, :model, :on, keyword_init: true)

    attr_reader :definition, :types

    def initialize(definition)
      @definition = definition
      @types = TypeResolver.new(definition)
      @joined = {}
      register_all
    end

    def fact_model
      definition.fact.model
    end

    def fact_table
      fact_model.table_name
    end

    # The FROM and JOIN block, in registration order so a parent always precedes
    # anything reached through it.
    #
    # `substitutions` maps an alias's hops to a JSON row, replacing that table
    # with the row as it was before a change. That is how a cell a row has since
    # left can still be found: the live table no longer points at it.
    def from_and_joins(substitutions = {})
      [table_expression([], FACT, substitutions)] +
        @joined.map { |hops, joined| "JOIN #{table_expression(hops, joined.name, substitutions)} ON #{joined.on}" }
    end

    # Hop paths that reach a given table, so a change there can be traced back to
    # the alias it arrived through.
    def hops_for_table(table)
      @joined.select { |_, joined| joined.model.table_name == table }.keys
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

    def aggregate_expression(measure)
      return "COUNT(*)" if measure.counts_rows?

      "COALESCE(#{measure.aggregate.to_s.upcase}(#{measure.expression}), 0)"
    end

    # Conditions from the fact's filter, already qualified. Equality only in the
    # first release; anything richer belongs in the fact's own scope.
    def filter_conditions
      return [] unless definition.fact.where

      definition.fact.where.flat_map { |key, value| conditions_for(key, value) }
    end

    def alias_for(hops)
      hops.empty? ? FACT : register(hops).name
    end

    # The table expression for one alias, so a statement can swap a live table for
    # a row reconstructed from the change log's `previous` column.
    def source_for(hops)
      return [fact_table, FACT] if hops.empty?

      joined = register(hops)
      [joined.model.table_name, joined.name]
    end

    private

    def register_all
      definition.key_dimensions.reject { |dimension| dimension.path.local? }
                .each { |dimension| register(dimension.path.hops) }
      definition.filter_associations.each { |association| register([association]) }
    end

    # A local column needs no join, so an empty path is a caller's mistake rather
    # than a base case: treating it as one recurses forever.
    def register(hops)
      hops = hops.map(&:to_sym)
      raise InvalidDefinitionError, "a local column needs no join" if hops.empty?

      @joined[hops] ||= join_for(hops, parent_of(hops))
    end

    def join_for(hops, parent)
      reflection = types.reflection!(parent.model, hops.last, hops.join("."))
      name = "j#{@joined.size}"
      Joined.new(name: name, model: reflection.klass, on: "#{name}.id = #{parent.name}.#{reflection.foreign_key}")
    end

    def parent_of(hops)
      return Joined.new(name: FACT, model: fact_model, on: nil) if hops.length == 1

      register(hops[0..-2])
    end

    def table_expression(hops, name, substitutions)
      table = hops.empty? ? fact_table : @joined[hops].model.table_name
      json = substitutions[hops]
      return "#{table} #{name}" if json.nil?

      "jsonb_populate_record(NULL::#{table}, #{quote(json)}::jsonb) #{name}"
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
      ActiveRecord::Base.connection.quote(value)
    end
  end
end
