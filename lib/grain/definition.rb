# frozen_string_literal: true

module Grain
  # Everything a Rollup subclass declares, plus what can be derived from it: the
  # rollup table's name and key order, and which tables have to be watched to
  # keep the aggregate correct.
  class Definition
    TABLE_PREFIX = "grain_"

    # Parts a rollup cannot do without, and how to complain when one is missing.
    #
    # A time dimension is deliberately absent: a rollup without one is a counter
    # cache that cannot drift, which is a use case in its own right. A tenant is
    # required, because starting the key with the most selective column is what
    # makes reads and scoped recomputes cheap.
    REQUIRED_PARTS = {
      fact: "declares no fact",
      tenant: "declares no tenant"
    }.freeze

    attr_reader :owner, :fact, :dimensions, :measures, :ratios

    def initialize(owner)
      @owner = owner
      @fact = nil
      @dimensions = []
      @measures = []
      @ratios = []
    end

    def declare_fact(model, where: nil)
      raise InvalidDefinitionError, "#{owner} already declares a fact" if fact

      @fact = Fact.new(model, where: where)
    end

    def add_dimension(name, via:, role: :dimension, grain: nil, immutable: false)
      dimension = Dimension.new(name: name, via: via, role: role, grain: grain, immutable: immutable)
      reject_duplicate_name!(dimension.name)
      reject_duplicate_role!(dimension)
      @dimensions << dimension
      dimension
    end

    def add_measure(name, options)
      measure = Measure.from_options(name, options)
      reject_duplicate_name!(measure.name)
      @measures << measure
      measure
    end

    def add_ratio(name, numerator:, denominator:)
      ratio = Ratio.new(name: name, numerator: numerator, denominator: denominator)
      reject_duplicate_name!(ratio.name)
      @ratios << ratio
      ratio
    end

    def tenant
      dimensions.find(&:tenant?)
    end

    def time
      dimensions.find(&:time?)
    end

    # False for a rollup that buckets by nothing but its dimensions — a counter
    # cache. Reads on one cannot take a date range, and it has no late-arriving
    # data to worry about.
    def temporal?
      !time.nil?
    end

    def plain_dimensions
      dimensions.reject { |dimension| dimension.tenant? || dimension.time? }
    end

    # The rollup table's primary key, in a fixed order so that migrations,
    # delta updates and reads all agree: tenant, then time bucket, then the
    # plain dimensions in declaration order.
    def key_dimensions
      [tenant, time, *plain_dimensions].compact
    end

    def table_name
      raise InvalidDefinitionError, "a rollup needs a name to derive its table from" if anonymous?

      "#{TABLE_PREFIX}#{owner.name.underscore.pluralize}"
    end

    # Associations whose rows can move fact rows between cells. Each one needs a
    # trigger that writes a scope invalidation rather than a delta.
    def watched_associations
      dimensions.select(&:watched?).map { |dimension| dimension.path.root_hop }.uniq
    end

    # True when a change somewhere other than the fact table can add or remove
    # fact rows entirely, which no delta can express.
    def invalidated_by_filter?
      fact ? fact.filtered_through_association? : false
    end

    def validate!
      validate_required_parts!
      validate_ratios!
      self
    end

    private

    def validate_required_parts!
      REQUIRED_PARTS.each do |reader, complaint|
        raise InvalidDefinitionError, "#{owner} #{complaint}" if public_send(reader).nil?
      end

      raise InvalidDefinitionError, "#{owner} declares no measures" if measures.empty?
    end

    def anonymous?
      owner.name.nil? || owner.name.empty?
    end

    def measure_names
      measures.map(&:name)
    end

    def declared_names
      dimensions.map(&:name) + measure_names + ratios.map(&:name)
    end

    def validate_ratios!
      ratios.each do |ratio|
        [ratio.numerator, ratio.denominator].each do |part|
          next if measure_names.include?(part)

          raise InvalidDefinitionError, "ratio #{ratio.name} refers to unknown measure #{part.inspect}"
        end
      end
    end

    def reject_duplicate_name!(name)
      return unless declared_names.include?(name)

      raise InvalidDefinitionError, "#{owner} already declares #{name.inspect}"
    end

    def reject_duplicate_role!(dimension)
      return unless (dimension.tenant? && tenant) || (dimension.time? && time)

      raise InvalidDefinitionError, "#{owner} already declares a #{dimension.role}"
    end
  end
end
