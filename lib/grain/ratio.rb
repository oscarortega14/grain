# frozen_string_literal: true

module Grain
  # A derived value kept as its two parts and divided on read.
  #
  # Ratios are never stored pre-divided: averaging averages is wrong, and a
  # stored rate cannot be rolled up from day to month. Numerator and denominator
  # both sum, so their quotient stays correct at every grain.
  class Ratio
    attr_reader :name, :numerator, :denominator

    def initialize(name:, numerator:, denominator:)
      @name = name.to_sym
      @numerator = numerator.to_sym
      @denominator = denominator.to_sym
      validate!
      freeze
    end

    private

    def validate!
      return unless numerator == denominator

      raise InvalidDefinitionError, "ratio #{name} divides #{numerator.inspect} by itself"
    end
  end
end
