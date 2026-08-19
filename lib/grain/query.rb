# frozen_string_literal: true

module Grain
  # Reads a rollup.
  #
  #   OrderRevenueRollup.for(store: current_store)
  #                     .between(1.month.ago, Date.current)
  #                     .by(:product_id)
  #                     .revenue_cents
  #
  # Narrowing returns a new query rather than changing this one, so a base query
  # can be handed around and reused.
  class Query
    attr_reader :rollup, :definition

    def initialize(rollup, filters: {}, range: nil, groups: {})
      @rollup = rollup
      @definition = rollup.definition.validate!
      @filters = filters
      @range = range
      @groups = groups
    end

    # Filters on any dimension. A value may be an id, an ActiveRecord object, an
    # array, or nil.
    #
    #   for(store: current_store)   # same as for(store_id: current_store.id)
    #   for(product_id: [1, 2, 3])
    def for(**filters)
      merge(filters: @filters.merge(normalise(filters)))
    end

    def between(from, to = nil)
      raise Error, "#{rollup} has no time dimension to range over" unless definition.temporal?

      merge(range: to.nil? ? from : (from..to))
    end

    # Groups by dimensions, optionally coarsening the time bucket.
    #
    #   by(:product_id)
    #   by(ordered_on: :month)
    def by(*names, **coarse)
      groups = names.to_h { |name| [dimension_name(name), nil] }
                    .merge(coarse.transform_keys { |key| dimension_name(key) })
      merge(groups: @groups.merge(groups))
    end

    def sql
      QuerySql.new(definition, filters: @filters, range: @range, groups: @groups).to_s
    end

    # Every measure and ratio at once, one row per group.
    def rows
      @rows ||= typed_rows.map { |row| with_ratios(row) }
    end

    # Keyed by group value, or the single row when nothing is grouped.
    def to_h
      return rows.first || empty_row if @groups.empty?

      rows.to_h { |row| [group_key(row), row] }
    end

    def value(name)
      name = name.to_sym
      return rows.to_h { |row| [group_key(row), row[name]] } unless @groups.empty?

      (rows.first || empty_row)[name]
    end

    def respond_to_missing?(name, include_private = false)
      readable?(name) || super
    end

    def method_missing(name, *args)
      return value(name) if readable?(name) && args.empty?

      super
    end

    private

    def merge(**changes)
      self.class.new(rollup, filters: @filters, range: @range, groups: @groups, **changes)
    end

    def readable?(name)
      (definition.measures.map(&:name) + definition.ratios.map(&:name)).include?(name.to_sym)
    end

    def normalise(filters)
      filters.to_h { |key, value| [dimension_name(key), identify(value)] }
    end

    # Accepts a dimension's own name, or an association-shaped one: `store` finds
    # `store_id` when that is what the rollup is keyed on.
    def dimension_name(key)
      key = key.to_sym
      names = definition.key_dimensions.map(&:name)
      return key if names.include?(key)

      suffixed = :"#{key}_id"
      return suffixed if names.include?(suffixed)

      raise Error, "#{rollup} has no dimension #{key.inspect}; it has #{names.inspect}"
    end

    def identify(value)
      return value.map { |item| identify(item) } if value.is_a?(Array)

      value.respond_to?(:id) && !value.is_a?(Numeric) ? value.id : value
    end

    # to_a hands back the driver's strings — a date arrives as "2026-08-10" —
    # while the result object carries the adapter's own type map. Zipping the
    # columns against cast_values applies it, so callers get Dates and Integers
    # rather than having to parse what came out of a dashboard query.
    def typed_rows
      result = ActiveRecord::Base.connection.select_all(sql)
      names = result.columns.map(&:to_sym)
      values = result.columns.one? ? result.cast_values.map { |value| [value] } : result.cast_values
      values.map { |row| names.zip(row).to_h }
    end

    # Ratios are never stored. They are divided here from two measures that are,
    # so a rate is correct at whatever grain it is read at instead of frozen at
    # the one it was computed for. A rate over nothing is nil rather than zero:
    # there is no rate, which is not the same as a rate of none.
    def with_ratios(row)
      definition.ratios.each_with_object(row) do |ratio, result|
        denominator = result[ratio.denominator].to_f
        result[ratio.name] = denominator.zero? ? nil : result[ratio.numerator] / denominator
      end
    end

    def empty_row
      definition.measures.to_h { |measure| [measure.name, measure.coarsens_with == :sum ? 0 : nil] }
                .merge(definition.ratios.to_h { |ratio| [ratio.name, nil] })
    end

    def group_key(row)
      keys = @groups.keys.map { |name| row[name] }
      keys.length == 1 ? keys.first : keys
    end
  end
end
