# frozen_string_literal: true

module Grain
  # A pre-aggregated column of a rollup table.
  #
  #   measure :line_count,    count: true
  #   measure :units,         sum: "quantity", type: :bigint
  #   measure :revenue_cents, sum: "quantity * unit_price_cents", type: :bigint
  class Measure
    AGGREGATES = %i[count sum min max].freeze

    # count and sum can be undone by subtracting. min and max cannot: removing
    # the current extreme means the next one has to be found in the source, so a
    # delete forces recomputing the whole cell.
    REVERSIBLE = %i[count sum].freeze

    # A count of rows is always a whole number, so its type is not worth asking
    # for. Every other aggregate runs over an arbitrary SQL expression whose type
    # Grain cannot infer, and guessing would mean silently rounding somebody's
    # revenue. The declaration is one word, and it is cheap insurance.
    COUNT_TYPE = :bigint

    attr_reader :name, :aggregate, :expression, :type

    def self.from_options(name, options)
      options = options.dup
      type = options.delete(:type)
      reject_ambiguous_aggregate!(name, options)

      aggregate, value = options.first
      new(name: name, aggregate: aggregate, expression: value == true ? nil : value, type: type)
    end

    def self.reject_ambiguous_aggregate!(name, options)
      return if options.size == 1

      raise InvalidDefinitionError,
            "measure #{name} takes exactly one aggregate, got #{options.keys.inspect}"
    end
    private_class_method :reject_ambiguous_aggregate!

    def initialize(name:, aggregate:, expression: nil, type: nil)
      @name = name.to_sym
      @aggregate = aggregate.to_sym
      @expression = expression
      @type = (type || (@aggregate == :count ? COUNT_TYPE : nil))&.to_sym
      validate!
      freeze
    end

    # A bare count of fact rows, needing no expression to evaluate per row.
    def counts_rows?
      aggregate == :count && expression.nil?
    end

    # False means a delete cannot be applied as a delta and the cell has to be
    # recomputed from the source instead.
    def reversible?
      REVERSIBLE.include?(aggregate)
    end

    private

    def validate!
      validate_aggregate!
      validate_expression!
      validate_type!
    end

    def validate_aggregate!
      return if AGGREGATES.include?(aggregate)

      raise InvalidDefinitionError,
            "measure #{name} uses #{aggregate.inspect}, supported aggregates are #{AGGREGATES.inspect}"
    end

    def validate_expression!
      return if aggregate == :count || !expression.nil?

      raise InvalidDefinitionError, "measure #{name} aggregates with #{aggregate} and needs an expression"
    end

    def validate_type!
      return unless type.nil?

      raise InvalidDefinitionError,
            "measure #{name} needs an explicit type, as in `#{aggregate}: ..., type: :bigint`"
    end
  end
end
