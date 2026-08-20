# frozen_string_literal: true

require "test_helper"
require "active_record"
require_relative "support/database"
require_relative "support/harness"

# The case a real application hit on the first day: the value being measured is
# not on the fact table. Whether a line qualifies for a discount, and how much it
# is worth, live on the order and on the store's configuration.
class DiscountRollup < Grain::Rollup
  fact LineItem

  tenant    :store_id,   via: { order: :store_id }
  dimension :product_id, via: :product_id

  measure :line_count, count: true
  # Reads two joined tables: the order's state and the store's currency.
  measure :paid_lines,
          sum: "CASE WHEN g_order.state = 'paid' THEN 1 ELSE 0 END",
          type: :bigint,
          through: :order
  measure :local_cents,
          sum: "CASE WHEN g_order_store.currency = 'COP' THEN f.quantity * f.unit_price_cents ELSE 0 END",
          type: :bigint,
          through: { order: :store }
end

class TestMeasureJoins < Minitest::Test
  def setup
    skip "Postgres not available at #{Database::URL}" unless Database.available?
    Database.load_schema!
    Grain::Registry.reset!
    Grain::Registry.register(DiscountRollup)
    Harness.install!
    Harness.build_table!(DiscountRollup)
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
    @foreign = Store.create!(currency: "USD")
    @coffee = Product.create!(name: "Cafe")
    @paid = Order.create!(store: @store, placed_on: Date.new(2026, 8, 19), state: "paid")
    @pending = Order.create!(store: @store, placed_on: Date.new(2026, 8, 19), state: "pending")
    @abroad = Order.create!(store: @foreign, placed_on: Date.new(2026, 8, 19), state: "paid")

    LineItem.create!(order: @paid, product: @coffee, quantity: 2, unit_price_cents: 100)
    LineItem.create!(order: @pending, product: @coffee, quantity: 3, unit_price_cents: 100)
    LineItem.create!(order: @abroad, product: @coffee, quantity: 9, unit_price_cents: 100)
    Grain::Worker.drain
  end

  def mine
    DiscountRollup.for(store: @store)
  end

  # -- the thing that was impossible ----------------------------------------

  def test_a_measure_can_read_a_column_one_hop_away
    # Two of the three lines belong to this store; only one of those is paid.
    assert_equal 2, mine.line_count
    assert_equal 1, mine.paid_lines
  end

  def test_a_measure_can_read_a_column_two_hops_away
    assert_equal 500, mine.local_cents
    assert_equal 0, DiscountRollup.for(store: @foreign).local_cents
  end

  def test_it_agrees_with_its_source
    assert_predicate DiscountRollup.verify, :clean?, DiscountRollup.verify.to_s
  end

  # -- keeping it correct ----------------------------------------------------

  def test_changing_the_joined_column_updates_the_measure
    # Nothing about the line items changed. Without watching the joined table this
    # would drift with no way to notice.
    @pending.update!(state: "paid")
    Grain::Worker.drain

    assert_equal 2, mine.paid_lines
    assert_predicate DiscountRollup.verify, :clean?
  end

  def test_changing_a_column_two_hops_away_updates_the_measure
    @store.update!(currency: "USD")
    Grain::Worker.drain

    assert_equal 0, mine.local_cents
    assert_predicate DiscountRollup.verify, :clean?
  end

  # -- what it costs --------------------------------------------------------

  def test_a_table_a_measure_reads_cannot_be_narrowed
    triggers = Grain::Triggers.new(DiscountRollup.definition)
    orders = triggers.specs.find { |spec| spec.table == "orders" }
    stores = triggers.specs.find { |spec| spec.table == "stores" }

    # Both are read by a measure, so every update on them has to be logged: the
    # expression is arbitrary SQL and there is no telling which columns feed it.
    refute_predicate orders, :narrowed?
    refute_predicate stores, :narrowed?
  end

  def test_aliases_are_named_after_the_path_that_reaches_them
    graph = Grain::JoinGraph.new(DiscountRollup.definition)

    assert_equal "g_order", graph.alias_for([:order])
    assert_equal "g_order_store", graph.alias_for(%i[order store])
  end

  def test_two_routes_to_one_table_get_distinct_aliases
    # Naming an alias after the last hop alone would collide here.
    graph = Grain::JoinGraph.new(DiscountRollup.definition)

    refute_equal graph.alias_for([:order]), graph.alias_for(%i[order store])
  end
end
