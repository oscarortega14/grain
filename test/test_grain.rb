# frozen_string_literal: true

require "test_helper"

class TestGrain < Minitest::Test
  def teardown
    Grain.reset_config!
  end

  def test_that_it_has_a_version_number
    refute_nil ::Grain::VERSION
  end

  def test_configuration_defaults_are_conservative
    assert_equal "grain_change_log", Grain.config.change_log_table
    assert_equal 1_000, Grain.config.batch_size
    assert_equal 30, Grain.config.max_run_seconds
  end

  def test_configure_yields_the_configuration
    Grain.configure { |c| c.batch_size = 250 }

    assert_equal 250, Grain.config.batch_size
  end

  def test_errors_share_a_rescuable_base_class
    [Grain::InvalidDefinitionError, Grain::StaleSchemaError,
     Grain::VerificationError, Grain::ChangeLogOverflowError].each do |klass|
      assert_operator klass, :<, Grain::Error
    end
  end
end
