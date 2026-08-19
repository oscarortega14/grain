# frozen_string_literal: true

module Grain
  # A pre-aggregated column of a rollup table.
  #
  #   measure :attempts, count: true
  #   measure :passed_count, sum: "CASE WHEN score >= 60 THEN 1 ELSE 0 END"
  class Measure
    AGGREGATES = %i[count sum min max].freeze

    # count and sum can be undone by subtracting. min and max cannot: removing
    # the current extreme means the next one has to be found in the source, so a
    # delete forces recomputing the whole cell.
    REVERSIBLE = %i[count sum].freeze

    attr_reader :name, :aggregate, :expression

    def self.from_options(name, options)
      unless options.size == 1
        raise InvalidDefinitionError,
              "measure #{name} takes exactly one aggregate, got #{options.keys.inspect}"
      end

      aggregate, value = options.first
      new(name: name, aggregate: aggregate, expression: value == true ? nil : value)
    end

    def initialize(name:, aggregate:, expression: nil)
      @name = name.to_sym
      @aggregate = aggregate.to_sym
      @expression = expression
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
      unless AGGREGATES.include?(aggregate)
        raise InvalidDefinitionError,
              "measure #{name} uses #{aggregate.inspect}, supported aggregates are #{AGGREGATES.inspect}"
      end

      return if aggregate == :count || !expression.nil?

      raise InvalidDefinitionError, "measure #{name} aggregates with #{aggregate} and needs an expression"
    end
  end
end
