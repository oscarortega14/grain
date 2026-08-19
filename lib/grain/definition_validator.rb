# frozen_string_literal: true

module Grain
  # Judges whether a definition is complete and internally consistent.
  #
  # Kept apart from Definition so that accumulating declarations and deciding
  # whether they add up stay separate concerns: the DSL builds, this rules.
  class DefinitionValidator
    # Parts a rollup cannot do without.
    #
    # A time dimension is deliberately absent: a rollup without one is a counter
    # cache that cannot drift, which is a use case in its own right. A tenant is
    # required, because starting the key with the most selective column is what
    # makes reads and scoped recomputes cheap.
    REQUIRED_PARTS = {
      fact: "declares no fact",
      tenant: "declares no tenant"
    }.freeze

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def validate!
      validate_required_parts!
      validate_ratios!
      definition
    end

    private

    def owner
      definition.owner
    end

    def validate_required_parts!
      REQUIRED_PARTS.each do |reader, complaint|
        raise InvalidDefinitionError, "#{owner} #{complaint}" if definition.public_send(reader).nil?
      end

      raise InvalidDefinitionError, "#{owner} declares no measures" if definition.measures.empty?
    end

    def validate_ratios!
      definition.ratios.each { |ratio| validate_ratio!(ratio) }
    end

    def validate_ratio!(ratio)
      [ratio.numerator, ratio.denominator].each do |part|
        next if definition.measure_names.include?(part)

        raise InvalidDefinitionError, "ratio #{ratio.name} refers to unknown measure #{part.inspect}"
      end
    end
  end
end
