# frozen_string_literal: true

module Grain
  # Base class for rollup definitions. A subclass declares the shape of one
  # pre-aggregated table. Nothing here touches the database.
  #
  #   class AssessmentResultRollup < Grain::Rollup
  #     fact TestingSectionStudent, where: { user: { role: "student" } }
  #
  #     tenant    :school_id, via: { testing_section: :school_id }
  #     time      :assessed_on,
  #               via: { testing_section: { assessment_window: :starts_on } },
  #               grain: :day
  #     dimension :grade_id,  via: { testing_section: :grade_id }
  #     dimension :window_id, via: { testing_section: :assessment_window_id },
  #               immutable: true
  #
  #     measure :attempts,     count: true
  #     measure :passed_count, sum: "CASE WHEN score >= 60 THEN 1 ELSE 0 END"
  #     ratio   :pass_rate, of: :passed_count, over: :attempts
  #   end
  class Rollup
    class << self
      def definition
        @definition ||= Definition.new(self)
      end

      def fact(model, where: nil)
        definition.declare_fact(model, where: where)
      end

      def tenant(name, via:)
        definition.add_dimension(name, via: via, role: :tenant)
      end

      def time(name, via:, grain:)
        definition.add_dimension(name, via: via, role: :time, grain: grain)
      end

      def dimension(name, via:, immutable: false)
        definition.add_dimension(name, via: via, immutable: immutable)
      end

      def measure(name, **options)
        definition.add_measure(name, options)
      end

      def ratio(name, of:, over:)
        definition.add_ratio(name, numerator: of, denominator: over)
      end

      def table_name
        definition.table_name
      end

      def validate!
        definition.validate!
      end

      def query
        Query.new(self)
      end

      # Reading entry points. Each returns a query that can be narrowed further.
      def for(**filters)
        query.for(**filters)
      end

      def between(from, to = nil)
        query.between(from, to)
      end

      def by(*names, **coarse)
        query.by(*names, **coarse)
      end

      # Lifts the tenant requirement for a read that is meant to span every one
      # of them. Reads are keyed by tenant and refuse to run without it.
      def across_tenants
        query.across_tenants
      end

      # Populates the rollup from data that already exists. A new rollup is empty
      # until this runs: its triggers only see what happens next.
      def backfill(from: nil, pause: 0, &progress)
        Backfill.new(self, from: from, pause: pause).call(&progress)
      end

      # Recomputes from the source and reports every cell that disagrees. Pass
      # repair: true to rebuild the ones that do.
      def verify(tenant: nil, between: nil, repair: false)
        Verification.new(self, tenant: tenant, between: between).call(repair: repair)
      end
    end
  end
end
