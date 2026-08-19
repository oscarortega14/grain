# frozen_string_literal: true

module Grain
  # Application-wide settings. Defaults are chosen to be safe on a busy
  # production database rather than fast on an idle one.
  class Configuration
    # Table that database triggers write change events into.
    attr_accessor :change_log_table

    # Rows per batch when backfilling or draining the change log. Small enough
    # to keep transactions short and avoid long lock holds.
    attr_accessor :batch_size

    # Seconds a delta worker may run before yielding, so a large backlog cannot
    # monopolise a job queue slot.
    attr_accessor :max_run_seconds

    # ActiveJob queue used by the delta and backfill workers.
    attr_accessor :queue

    # Where Grain writes its own diagnostics.
    attr_accessor :logger

    def initialize
      @change_log_table = "grain_change_log"
      @batch_size = 1_000
      @max_run_seconds = 30
      @queue = :default
      @logger = nil
    end
  end
end
