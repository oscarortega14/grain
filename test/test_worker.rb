# frozen_string_literal: true

require "test_helper"
require "active_record"
require_relative "support/database"
require_relative "support/harness"
require_relative "test_integration"

# Does the rollup actually hold the right numbers? Every case is driven through
# real writes, real triggers and the real worker, and checked against the answer
# the source data gives.
class TestWorker < Minitest::Test
  def setup
    skip "Postgres not available at #{Database::URL}" unless Database.available?
    Database.load_schema!
    Grain::Registry.reset!
    Grain::Registry.register(IntegrationRevenueRollup, IntegrationCategoryRollup)
    Harness.install!
    Harness.build_table!(IntegrationRevenueRollup)
    Harness.build_table!(IntegrationCategoryRollup)
    seed
  end

  def teardown
    Grain::Registry.reset!
    Database.drop_everything! if Database.available?
  end

  def connection
    Database.connection
  end

  def seed
    @store = Store.create!(currency: "COP")
    @other_store = Store.create!(currency: "USD")
    @coffee = Product.create!(name: "Cafe", category: Category.create!(name: "Drinks"))
    @mug = Product.create!(name: "Mug")
    @order = Order.create!(store: @store, placed_on: Date.new(2026, 8, 19), state: "paid")
  end

  def drain
    Grain::Worker.drain
  end

  def revenue_rows
    connection.select_all(<<~SQL).to_a
      SELECT store_id, ordered_on, product_id, line_count, revenue_cents
      FROM grain_integration_revenue_rollups
      ORDER BY store_id, product_id
    SQL
  end

  def cell(store: @store, product: @coffee)
    revenue_rows.find { |row| row["store_id"] == store.id && row["product_id"] == product.id }
  end

  def item(quantity: 2, cents: 500, order: @order, product: @coffee)
    LineItem.create!(order: order, product: product, quantity: quantity, unit_price_cents: cents)
  end

  # -- the happy path --------------------------------------------------------

  def test_an_insert_produces_the_cell
    item(quantity: 2, cents: 500)

    drain

    assert_equal 1, cell["line_count"]
    assert_equal 1000, cell["revenue_cents"]
  end

  def test_rows_in_the_same_cell_accumulate
    item(quantity: 2, cents: 500)
    item(quantity: 3, cents: 100)

    drain

    assert_equal 2, cell["line_count"]
    assert_equal 1300, cell["revenue_cents"]
  end

  def test_rows_in_different_cells_stay_apart
    item(product: @coffee, quantity: 1, cents: 100)
    item(product: @mug, quantity: 1, cents: 900)

    drain

    assert_equal 100, cell(product: @coffee)["revenue_cents"]
    assert_equal 900, cell(product: @mug)["revenue_cents"]
  end

  def test_draining_twice_changes_nothing
    item(quantity: 2, cents: 500)
    drain
    before = revenue_rows

    drain

    assert_equal before, revenue_rows
  end

  # -- the cases that need the previous row ----------------------------------

  def test_updating_a_measure_column_corrects_the_cell
    line = item(quantity: 2, cents: 500)
    drain

    line.update!(quantity: 10)
    drain

    assert_equal 5000, cell["revenue_cents"]
    assert_equal 1, cell["line_count"]
  end

  def test_deleting_the_only_row_removes_the_cell_rather_than_leaving_it_stale
    # An upsert would leave 1000 standing here forever. This is why recompute is
    # a delete followed by an insert.
    line = item(quantity: 2, cents: 500)
    drain
    refute_nil cell

    line.destroy!
    drain

    assert_nil cell
  end

  def test_moving_a_row_to_another_cell_empties_the_one_it_left
    line = item(quantity: 1, cents: 700, product: @coffee)
    drain

    line.update!(product: @mug)
    drain

    assert_nil cell(product: @coffee)
    assert_equal 700, cell(product: @mug)["revenue_cents"]
  end

  # -- changes on a watched table -------------------------------------------

  def test_moving_an_order_to_another_store_moves_every_line_it_carries
    # The case that would drift silently without watching related tables: nothing
    # about the line items changed at all.
    item(quantity: 1, cents: 300)
    item(quantity: 1, cents: 200)
    drain

    @order.update!(store: @other_store)
    drain

    assert_nil cell(store: @store)
    assert_equal 500, cell(store: @other_store)["revenue_cents"]
  end

  def test_changing_the_order_date_rebuckets_its_lines
    item(quantity: 1, cents: 400)
    drain
    assert_equal Date.new(2026, 8, 19), Date.parse(cell["ordered_on"])

    @order.update!(placed_on: Date.new(2026, 9, 1))
    drain

    assert_equal Date.new(2026, 9, 1), Date.parse(cell["ordered_on"])
    assert_equal 1, revenue_rows.length
  end

  # -- the filter ------------------------------------------------------------

  def test_rows_failing_the_filter_are_not_counted
    unpaid = Order.create!(store: @store, placed_on: Date.new(2026, 8, 19), state: "pending")
    item(order: unpaid, quantity: 5, cents: 1000)

    drain

    assert_empty revenue_rows
  end

  def test_satisfying_the_filter_later_brings_the_rows_in
    unpaid = Order.create!(store: @store, placed_on: Date.new(2026, 8, 19), state: "pending")
    item(order: unpaid, quantity: 5, cents: 1000)
    drain
    assert_empty revenue_rows

    unpaid.update!(state: "paid")
    drain

    assert_equal 5000, cell["revenue_cents"]
  end

  def test_failing_the_filter_later_takes_the_rows_out
    item(quantity: 5, cents: 1000)
    drain
    refute_nil cell

    @order.update!(state: "refunded")
    drain

    assert_nil cell
  end

  # -- nullable dimensions ---------------------------------------------------

  def test_a_null_dimension_is_a_cell_of_its_own
    item(product: @mug)
    item(product: @coffee)
    drain

    rows = connection.select_all(<<~SQL).to_a
      SELECT category_id, line_count FROM grain_integration_category_rollups ORDER BY category_id NULLS LAST
    SQL

    assert_equal 2, rows.length
    assert_nil rows.last["category_id"]
    assert_equal 1, rows.last["line_count"]
  end

  # -- the log ---------------------------------------------------------------

  def test_the_log_is_emptied_by_draining
    item
    refute_equal 0, connection.select_value("SELECT count(*) FROM grain_change_log")

    drain

    assert_equal 0, connection.select_value("SELECT count(*) FROM grain_change_log")
  end

  def test_draining_an_empty_log_does_nothing
    drain

    assert_equal 0, drain
  end
end
