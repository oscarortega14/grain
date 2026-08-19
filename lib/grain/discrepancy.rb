# frozen_string_literal: true

module Grain
  # One cell where the rollup and its source disagree.
  #
  # Three kinds, and all three matter. `wrong` is the obvious one. `missing` is a
  # cell the source has and the rollup never got. `extra` is a cell the rollup
  # still holds after its last source row went away — the one a design built on
  # upserts can never find, because there is nothing left to upsert against.
  class Discrepancy
    KINDS = %i[wrong missing extra].freeze

    attr_reader :cell, :stored, :expected

    def initialize(cell:, stored:, expected:)
      @cell = cell.freeze
      @stored = stored&.freeze
      @expected = expected&.freeze
      freeze
    end

    def kind
      return :missing if stored.nil?
      return :extra if expected.nil?

      :wrong
    end

    def to_s
      "#{kind}: #{format_cell}#{differences}"
    end

    private

    def format_cell
      cell.map { |name, value| "#{name}=#{value.inspect}" }.join(" ")
    end

    def differences
      return "" unless kind == :wrong

      changed = expected.filter_map do |measure, value|
        "#{measure} #{stored[measure].inspect} should be #{value.inspect}" if stored[measure] != value
      end
      changed.empty? ? "" : " — #{changed.join(", ")}"
    end
  end
end
