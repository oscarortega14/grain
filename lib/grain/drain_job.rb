# frozen_string_literal: true

module Grain
  # Drains the change log from a background job, so keeping rollups fresh is a
  # scheduled entry rather than a cron line invoking rake.
  #
  # Overlapping runs are safe and need no guard. Claiming uses FOR UPDATE SKIP
  # LOCKED, so two of these at once split the work instead of fighting over it or
  # doing it twice — a slow run caught by the next tick is not a problem.
  #
  # Loaded only when ActiveJob is, so the gem does not depend on it.
  class DrainJob < ActiveJob::Base
    queue_as { Grain.config.queue }

    def perform(limit: nil, max_seconds: nil)
      Worker.drain(**{ limit: limit, max_seconds: max_seconds }.compact)
    end
  end
end
