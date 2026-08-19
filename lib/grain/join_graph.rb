# frozen_string_literal: true

module Grain
  # The aliases and joins that reach every table a rollup needs.
  #
  # Registration is recursive, so two dimensions resolved through the same
  # association share one join instead of duplicating it, and a parent is always
  # registered — and therefore emitted — before anything reached through it.
  class JoinGraph
    # The fact table's alias. Measure expressions are the user's own SQL inserted
    # verbatim, so this is the name they can qualify columns with.
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

    def alias_for(hops)
      hops.empty? ? FACT : register(hops).name
    end

    # The FROM and JOIN block, in registration order.
    #
    # `substitutions` maps an alias's hops to a JSON row, replacing that table with
    # the row as it was before a change. That is how a cell a row has since left
    # can still be found: the live table no longer points at it.
    def from_and_joins(substitutions = {})
      [table_expression([], FACT, substitutions)] +
        @joined.map { |hops, joined| "JOIN #{table_expression(hops, joined.name, substitutions)} ON #{joined.on}" }
    end

    # Hop paths that reach a given table, so a change there can be traced back to
    # the alias it arrived through.
    def hops_for_table(table)
      @joined.select { |_, joined| joined.model.table_name == table }.keys
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

      "jsonb_populate_record(NULL::#{table}, #{ActiveRecord::Base.connection.quote(json)}::jsonb) #{name}"
    end
  end
end
