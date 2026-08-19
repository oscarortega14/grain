# frozen_string_literal: true

require "test_helper"
require "active_record"
require_relative "support/database"
require_relative "support/harness"
require_relative "test_integration"

# A rollup created over an existing database starts empty, because its triggers
# only see what happens next. These tests check the backfill makes it true about
# the past without the worker having seen any of it.
class TestBackfill < Minitest::Test
  def setup
    skip "Postgres not available at #{Database::URL}" unless Database.available?
    Database.load_schema!
    Grain::Registry.reset!
    Grain::Registry.register(IntegrationRevenueRollup, IntegrationCategoryRollup)
    Harness.install!
    seed_history
    Harness.build_table!(IntegrationRevenueRollup)
    Harness.build_table!(IntegrationCategoryRollup)
    # Whatever the triggers happened to catch while the tables were being built is
    # cleared, so the backfill is the only thing that can populate the rollup.
    Database.connection.execute("DELETE FROM grain_change_log")
  end

  def teardown
    Grain::Registry.reset!
    Database.drop_everything! if Database.available?
  end

  def connection
    Database.connection
  end

  # Three days of history, two stores, one order that never qualified.
  def seed_history
    @store = Store.create!(currency: "COP")
    @other = Store.create!(currency: "USD")
    @coffee = Product.create!(name: "Cafe", category: Category.create!(name: "Drinks"))
    @mug = Product.create!(name: "Mug")

    @days = [Date.new(2026, 8, 17), Date.new(2026, 8, 18), Date.new(2026, 8, 20)]
    @days.each_with_index do |day, index|
      order = Order.create!(store: @store, placed_on: day, state: "paid")
      LineItem.create!(order: order, product: @coffee, quantity: index + 1, unit_price_cents: 100)
    end

    other_order = Order.create!(store: @other, placed_on: @days.first, state: "paid")
    LineItem.create!(order: other_order, product: @mug, quantity: 5, unit_price_cents: 200)

    unpaid = Order.create!(store: @store, placed_on: @days.first, state: "pending")
    LineItem.create!(order: unpaid, product: @mug, quantity: 99, unit_price_cents: 999)
  end

  def rows
    connection.select_all(<<~SQL).to_a
      SELECT store_id, ordered_on, product_id, line_count, revenue_cents
      FROM grain_integration_revenue_rollups
      ORDER BY ordered_on, store_id
    SQL
  end

  # -- the point of it -------------------------------------------------------

  def test_a_new_rollup_is_empty_until_backfilled
    assert_empty rows
  end

  def test_backfilling_makes_it_true_about_the_past
    IntegrationRevenueRollup.backfill

    assert_predicate IntegrationRevenueRollup.verify, :clean?, IntegrationRevenueRollup.verify.to_s
    assert_equal 4, rows.length
  end

  def test_the_numbers_come_out_right
    IntegrationRevenueRollup.backfill

    day_two = rows.find { |row| Date.parse(row["ordered_on"]) == @days[1] && row["store_id"] == @store.id }

    assert_equal 1, day_two["line_count"]
    assert_equal 200, day_two["revenue_cents"]
  end

  def test_rows_failing_the_filter_stay_out
    IntegrationRevenueRollup.backfill

    refute(rows.any? { |row| row["revenue_cents"] == 99 * 999 })
  end

  # -- slicing ---------------------------------------------------------------

  def test_a_temporal_rollup_is_sliced_by_its_time_bucket
    backfill = Grain::Backfill.new(IntegrationRevenueRollup)

    assert_equal :ordered_on, backfill.slice_dimension.name
  end

  def test_only_days_that_have_data_become_slices
    # Distinct values rather than a min-to-max range, so the 19th — which has no
    # orders — is never visited.
    slices = Grain::Backfill.new(IntegrationRevenueRollup).slices.map { |day| Date.parse(day.to_s) }

    assert_equal @days, slices
  end

  def test_a_rollup_without_a_time_dimension_is_sliced_by_tenant
    backfill = Grain::Backfill.new(IntegrationCategoryRollup)

    assert_equal :store_id, backfill.slice_dimension.name
    assert_equal [@store.id, @other.id].sort, backfill.slices.sort
  end

  def test_progress_is_reported_per_slice
    seen = []
    total = IntegrationRevenueRollup.backfill { |value, index, count| seen << [Date.parse(value.to_s), index, count] }

    assert_equal 3, total
    assert_equal [[@days[0], 1, 3], [@days[1], 2, 3], [@days[2], 3, 3]], seen
  end

  # -- resuming and repeating ------------------------------------------------

  def test_from_skips_everything_before_it
    IntegrationRevenueRollup.backfill(from: @days[1])

    assert_equal 2, rows.length
    refute(rows.any? { |row| Date.parse(row["ordered_on"]) == @days[0] })
  end

  def test_running_it_twice_changes_nothing
    IntegrationRevenueRollup.backfill
    before = rows

    IntegrationRevenueRollup.backfill

    assert_equal before, rows
  end

  def test_a_slice_is_rebuilt_whole_rather_than_added_to
    # Batching by row would have to add to cells already written, which is the
    # delta problem with none of its safeguards. Slices are rebuilt, so a partial
    # earlier state cannot survive.
    IntegrationRevenueRollup.backfill
    connection.execute("UPDATE grain_integration_revenue_rollups SET revenue_cents = revenue_cents * 10")

    IntegrationRevenueRollup.backfill

    assert_predicate IntegrationRevenueRollup.verify, :clean?
  end

  # -- alongside the worker --------------------------------------------------

  def test_the_worker_and_a_backfill_do_not_need_to_agree_on_order
    # Recompute is complete rather than incremental, so it cannot be half applied
    # and cannot be applied out of order. That is what lets these two run at once.
    order = Order.create!(store: @store, placed_on: @days.first, state: "paid")
    LineItem.create!(order: order, product: @mug, quantity: 4, unit_price_cents: 50)

    Grain::Worker.drain
    IntegrationRevenueRollup.backfill
    Grain::Worker.drain

    assert_predicate IntegrationRevenueRollup.verify, :clean?
  end
end
