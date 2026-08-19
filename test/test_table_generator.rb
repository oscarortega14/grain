# frozen_string_literal: true

require "test_helper"
require "active_record"
require "rails/generators/test_case"
require_relative "test_migration"
require "generators/grain/rollup/rollup_generator"
require "generators/grain/table/table_generator"

class TestRollupGenerator < Rails::Generators::TestCase
  tests Grain::Generators::RollupGenerator
  destination File.expand_path("tmp/generator", __dir__)
  setup :prepare_destination

  def test_it_scaffolds_a_definition_that_parses
    run_generator ["order_revenue"]

    assert_file "app/rollups/order_revenue_rollup.rb" do |content|
      assert RubyVM::InstructionSequence.compile(content)
      assert_match(/class OrderRevenueRollup < Grain::Rollup/, content)
    end
  end

  def test_a_name_that_already_ends_in_rollup_is_not_doubled
    run_generator ["order_revenue_rollup"]

    assert_file "app/rollups/order_revenue_rollup.rb" do |content|
      assert_match(/class OrderRevenueRollup < Grain::Rollup/, content)
      refute_match(/RollupRollup/, content)
    end
  end
end

class TestTableGenerator < Rails::Generators::TestCase
  tests Grain::Generators::TableGenerator
  destination File.expand_path("tmp/generator", __dir__)
  setup :prepare_destination

  MIGRATION = "db/migrate/create_grain_fake_revenue_rollups.rb"

  def test_the_generated_migration_is_valid_ruby
    run_generator ["fake_revenue"]

    assert_migration MIGRATION do |content|
      assert RubyVM::InstructionSequence.compile(content)
    end
  end

  def test_it_creates_the_rollup_table
    run_generator ["fake_revenue"]

    assert_migration MIGRATION do |content|
      assert_match(/create_table :grain_fake_revenue_rollups, primary_key: /, content)
      assert_match(/t\.date :ordered_on, null: false/, content)
      assert_match(/t\.bigint :revenue_cents, null: false, default: 0/, content)
    end
  end

  def test_it_attaches_the_triggers
    run_generator ["fake_revenue"]

    assert_migration MIGRATION do |content|
      assert_match(/CREATE TRIGGER grain_line_items_changed/, content)
      assert_match(/AFTER INSERT OR UPDATE OF placed_at, state, store_id OR DELETE ON orders/, content)
    end
  end

  def test_it_is_reversible
    run_generator ["fake_revenue"]

    assert_migration MIGRATION do |content|
      assert_match(/DROP TRIGGER IF EXISTS grain_orders_changed ON orders/, content)
      assert_match(/drop_table :grain_fake_revenue_rollups/, content)
    end
  end

  def test_the_rollup_suffix_is_optional_in_the_argument
    run_generator ["fake_revenue_rollup"]

    assert_migration MIGRATION
  end

  def test_a_name_it_cannot_resolve_writes_no_migration
    run_generator ["nothing_like_this"]

    assert_no_migration "db/migrate/create_grain_nothing_like_this_rollups.rb"
  end
end

# The lookup rule, tested away from Thor: a generator's failures are caught and
# printed by Thor rather than raised, so they cannot be asserted on there.
class TestRollupLookup < Minitest::Test
  def test_it_finds_a_rollup_named_exactly
    assert_equal FakeRevenueRollup, Grain::RollupLookup.find("FakeRevenueRollup")
  end

  def test_the_rollup_suffix_is_optional
    assert_equal FakeRevenueRollup, Grain::RollupLookup.find("fake_revenue")
    assert_equal FakeRevenueRollup, Grain::RollupLookup.find("fake_revenue_rollup")
  end

  def test_a_class_that_is_not_a_rollup_is_not_a_match
    refute Grain::RollupLookup.rollup?(FakeLineItem)
    assert_nil Grain::RollupLookup.find("fake_line_item")
  end

  def test_the_base_class_itself_is_not_a_match
    refute Grain::RollupLookup.rollup?(Grain::Rollup)
  end

  def test_an_unknown_name_raises_and_says_what_to_do_about_it
    error = assert_raises(Grain::RollupNotFoundError) { Grain::RollupLookup.find!("nothing_like_this") }

    assert_match(/Could not find a Grain::Rollup/, error.message)
    assert_match(/generate grain:rollup nothing_like_this/, error.message)
  end
end
