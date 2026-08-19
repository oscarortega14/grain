# frozen_string_literal: true

module Grain
  # What a verification found, in a shape that suits both a person reading a
  # terminal and a build deciding whether to fail.
  class VerificationReport
    attr_reader :rollup, :discrepancies, :repaired

    def initialize(rollup:, discrepancies:, repaired: 0)
      @rollup = rollup
      @discrepancies = discrepancies.freeze
      @repaired = repaired
    end

    def clean?
      discrepancies.empty?
    end

    def count
      discrepancies.length
    end

    def count_of(kind)
      discrepancies.count { |discrepancy| discrepancy.kind == kind }
    end

    def with_repaired(number)
      self.class.new(rollup: rollup, discrepancies: discrepancies, repaired: number)
    end

    def to_s
      return "#{rollup}: agrees with its source" if clean?

      [summary, *discrepancies.map { |discrepancy| "  #{discrepancy}" }].join("\n")
    end

    private

    def summary
      tally = Discrepancy::KINDS.filter_map do |kind|
        found = count_of(kind)
        "#{found} #{kind}" if found.positive?
      end
      repair_note = repaired.positive? ? ", #{repaired} repaired" : ""
      "#{rollup}: #{count} cells disagree (#{tally.join(", ")})#{repair_note}"
    end
  end
end
