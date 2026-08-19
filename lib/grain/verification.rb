# frozen_string_literal: true

module Grain
  # Recomputes a rollup from its source and reports every cell that disagrees.
  #
  # This is the point of the whole gem, not a diagnostic bolted on afterwards.
  # Nobody puts an aggregation layer in front of numbers that matter without a way
  # to prove it still tells the truth, so the obstacle Grain has to clear is never
  # speed — it is doubt.
  #
  # A full verification is an aggregate scan of the source, which is a maintenance
  # operation rather than something to run per request. Scope it by tenant or by
  # date range on a large rollup.
  class Verification
    attr_reader :rollup, :definition

    def initialize(rollup, tenant: nil, between: nil)
      @rollup = rollup
      @definition = rollup.definition.validate!
      @scope = { tenant: tenant, between: between }
      validate_scope!
    end

    def call(repair: false)
      report = VerificationReport.new(rollup: rollup, discrepancies: discrepancies)
      return report unless repair && !report.clean?

      report.with_repaired(Recompute.new(definition).call(report.discrepancies.map(&:cell)))
    end

    def discrepancies
      connection.select_all(query.to_s).to_a.map { |row| build_discrepancy(row.symbolize_keys) }
    end

    def query
      VerificationQuery.new(definition, **@scope)
    end

    private

    def key_columns
      definition.key_dimensions.map(&:name)
    end

    def measure_columns
      definition.measures.map(&:name)
    end

    def build_discrepancy(row)
      Discrepancy.new(
        cell: key_columns.to_h { |key| [key, row[key]] },
        stored: side(row, "stored"),
        expected: side(row, "expected")
      )
    end

    def side(row, name)
      return nil unless row[:"in_#{name}"].to_i.positive?

      measure_columns.to_h { |measure| [measure, row[:"#{name}_#{measure}"]] }
    end

    def validate_scope!
      return if @scope[:between].nil? || definition.temporal?

      raise Error, "#{rollup} has no time dimension, so it cannot be verified over a date range"
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
