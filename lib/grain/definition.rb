# frozen_string_literal: true

module Grain
  # Everything a Rollup subclass declares, plus what can be derived from it: the
  # rollup table's name and key order, and which tables have to be watched to
  # keep the aggregate correct.
  class Definition
    TABLE_PREFIX = "grain_"

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

    # Paths whose tables can move fact rows between cells.
    def watched_paths
      dimensions.select(&:watched?).map(&:path).uniq
    end

    # Every association hop along a watched path, not only the first.
    #
    # A change anywhere along the path moves fact rows between cells: if a
    # dimension resolves as order then store then currency, changing that store's
    # currency moves every line item on every order pointing at it. Watching only
    # the root would let that drift silently, which is the worst failure this
    # gem can have.
    def watched_associations
      watched_paths.flat_map(&:hops).uniq
    end

    # Associations the fact's filter reaches through. A change there adds or
    # removes fact rows entirely, which no delta can express.
    def filter_associations
      return [] unless fact

      fact.filter_associations
    end

    # True when a change somewhere other than the fact table can add or remove
    # fact rows entirely, which no delta can express.
    def invalidated_by_filter?
      fact ? fact.filtered_through_association? : false
    end

    def measure_names
      measures.map(&:name)
    end

    def validate!
      DefinitionValidator.new(self).validate!
    end

    private

    def anonymous?
      owner.name.nil? || owner.name.empty?
    end

    def declared_names
      dimensions.map(&:name) + measure_names + ratios.map(&:name)
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
