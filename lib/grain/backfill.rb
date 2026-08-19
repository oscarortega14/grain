# frozen_string_literal: true

module Grain
  # Populates a rollup from data that already exists.
  #
  # A new rollup starts empty: its triggers only see what happens next. The
  # backfill is what makes it true about the past.
  #
  # The work is sliced rather than batched by row. Rows belonging to one cell are
  # scattered through the fact table, so a batch of rows would have to add to
  # cells already written, which is the delta problem again with none of its
  # safeguards. A slice — one day, or one tenant — is instead rebuilt whole with
  # the same recompute the worker uses: idempotent, never leaving a cell showing a
  # partial total, and safe to run while the worker is running.
  #
  # Resuming after an interruption is manual and deliberate: slices are processed
  # in order, so passing `from:` the last one reported picks up where it stopped.
  # Re-running an already-done slice is harmless either way.
  class Backfill
    attr_reader :rollup, :definition

    def initialize(rollup, from: nil, pause: 0)
      @rollup = rollup
      @definition = rollup.definition.validate!
      @projection = Projection.new(@definition)
      @from = from
      @pause = pause
    end

    # Yields each slice value as it completes, so a caller can report progress or
    # record where to resume from. Returns the number of slices rebuilt.
    def call
      recompute = Recompute.new(definition)
      slices.each_with_index do |value, index|
        recompute.call_slice(slice_dimension, value)
        yield(value, index + 1, slices.length) if block_given?
        sleep(@pause) if @pause.positive?
      end
      slices.length
    end

    # The dimension the work is cut along: the time bucket when there is one,
    # since a day is a naturally bounded unit of work, and the tenant otherwise.
    def slice_dimension
      definition.temporal? ? definition.time : definition.tenant
    end

    # Distinct slice values that actually have data, in order.
    #
    # This is the expensive part of a backfill: it reads the fact table to find
    # them. It is one pass and far cheaper than the full aggregate, and using the
    # distinct values rather than a min-to-max range skips every gap.
    def slices
      @slices ||= load_slices
    end

    private

    def load_slices
      expression = @projection.dimension_expression(slice_dimension)
      sql = +"SELECT DISTINCT #{expression} AS slice FROM #{@projection.from_and_joins.join(" ")}"
      conditions = @projection.filter_conditions
      conditions << "#{expression} >= #{quote(@from)}" unless @from.nil?
      sql << " WHERE #{conditions.join(" AND ")}" if conditions.any?
      sql << " ORDER BY slice"
      connection.select_values(sql)
    end

    def quote(value)
      connection.quote(value)
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
