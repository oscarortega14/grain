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

    # ActiveJob queue Grain::DrainJob runs on.
    attr_accessor :queue

    # Time zone the day buckets are cut in. A timestamp has to be resolved to a
    # calendar day in some zone, and leaving it to the database session would make
    # the same row land in different buckets depending on who ran the query.
    attr_accessor :time_zone

    # Where Grain writes its own diagnostics.
    attr_accessor :logger

    def initialize
      @change_log_table = "grain_change_log"
      @batch_size = 1_000
      @max_run_seconds = 30
      @queue = :default
      @time_zone = "UTC"
      @logger = nil
    end
  end
end
