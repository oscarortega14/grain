# frozen_string_literal: true

require "test_helper"
require "active_job"
require "grain/drain_job"

class TestDrainJob < Minitest::Test
  def setup
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    Grain.reset_config!
  end

  def teardown
    Grain.reset_config!
  end

  def enqueued
    ActiveJob::Base.queue_adapter.enqueued_jobs
  end

  def test_it_runs_on_the_configured_queue
    Grain.configure { |config| config.queue = :rollups }
    Grain::DrainJob.perform_later

    assert_equal "rollups", enqueued.first[:queue]
  end

  def test_the_queue_is_read_at_enqueue_time
    # Read through a block rather than captured at load, so an initializer setting
    # it after the class is defined still takes effect.
    Grain::DrainJob.perform_later

    assert_equal "default", enqueued.first[:queue]
  end

  def test_it_passes_only_the_limits_it_was_given
    calls = []
    Grain::Worker.stub(:drain, ->(**options) { calls << options }) do
      Grain::DrainJob.new.perform
      Grain::DrainJob.new.perform(limit: 50)
      Grain::DrainJob.new.perform(limit: 10, max_seconds: 5)
    end

    assert_equal [{}, { limit: 50 }, { limit: 10, max_seconds: 5 }], calls
  end
end
