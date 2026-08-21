# frozen_string_literal: true

require "test_helper"
require "active_record"
require_relative "support/database"
require_relative "support/harness"
require_relative "test_integration"

# A rollup with a ratio and an extreme, so the read side has to combine three
# kinds of measure rather than only summing.
class ShopMetricsRollup < Grain::Rollup
  fact LineItem, where: { order: { state: "paid" } }

  tenant    :store_id,   via: { order: :store_id }
  time      :ordered_on, via: { order: :placed_on }, grain: :day
  dimension :product_id, via: :product_id

  measure :line_count,     count: true
  measure :units,          sum: "quantity", type: :bigint
  measure :revenue_cents,  sum: "quantity * unit_price_cents", type: :bigint
  measure :largest_line,   max: "quantity * unit_price_cents", type: :bigint
  ratio   :average_unit_price, of: :revenue_cents, over: :units
end

class TestQuery < Minitest::Test
  def setup
    skip "Postgres not available at #{Database::URL}" unless Database.available?
    Database.load_schema!
    Grain::Registry.reset!
    Grain::Registry.register(ShopMetricsRollup)
    Harness.install!
    Harness.build_table!(ShopMetricsRollup)
    seed
  end

  def teardown
    Grain::Registry.reset!
    Database.drop_everything! if Database.available?
  end

  # Two stores, two products, three days. August has two days, September one.
  def seed
    @store = Store.create!(currency: "COP")
    @other = Store.create!(currency: "USD")
    @coffee = Product.create!(name: "Cafe")
    @mug = Product.create!(name: "Mug")

    sell(@store, Date.new(2026, 8, 10), @coffee, quantity: 2, cents: 100)
    sell(@store, Date.new(2026, 8, 10), @mug,    quantity: 1, cents: 500)
    sell(@store, Date.new(2026, 8, 20), @coffee, quantity: 3, cents: 100)
    sell(@store, Date.new(2026, 9, 5),  @coffee, quantity: 4, cents: 100)
    sell(@other, Date.new(2026, 8, 10), @coffee, quantity: 9, cents: 100)
    ShopMetricsRollup.backfill
  end

  def sell(store, day, product, quantity:, cents:)
    order = Order.create!(store: store, placed_on: day, state: "paid")
    LineItem.create!(order: order, product: product, quantity: quantity, unit_price_cents: cents)
  end

  def mine
    ShopMetricsRollup.for(store: @store)
  end

  # -- totals ----------------------------------------------------------------

  def test_ungrouped_reads_collapse_to_a_single_number
    # 2*100 + 1*500 + 3*100 + 4*100 = 1400
    assert_equal 1400, mine.revenue_cents
    assert_equal 4, mine.line_count
  end

  def test_a_measure_reads_back_as_the_type_it_is_stored_as
    # SUM over bigint yields numeric, so without a cast an integer column would
    # come back as a BigDecimal — the same trap as on the write side.
    assert_instance_of Integer, mine.revenue_cents
    assert_instance_of Integer, mine.by(:product_id).revenue_cents.values.first
  end

  def test_a_tenant_can_be_given_as_a_record_or_an_id
    assert_equal ShopMetricsRollup.for(store_id: @store.id).revenue_cents, mine.revenue_cents
  end

  def test_other_tenants_are_excluded
    assert_equal 900, ShopMetricsRollup.for(store: @other).revenue_cents
  end

  def test_a_read_over_nothing_gives_zero_rather_than_nil
    assert_equal 0, ShopMetricsRollup.for(store_id: -1).revenue_cents
    assert_equal 0, ShopMetricsRollup.for(store_id: -1).line_count
  end

  def test_an_extreme_over_nothing_has_no_value_at_all
    # Zero would be a lie: there is no largest line, which is not the same as a
    # largest line of nothing.
    assert_nil ShopMetricsRollup.for(store_id: -1).largest_line
  end

  # -- the property the design rests on --------------------------------------

  def test_a_coarser_grain_is_the_sum_of_a_finer_one
    august = mine.between(Date.new(2026, 8, 1), Date.new(2026, 8, 31))
    tenth = mine.between(Date.new(2026, 8, 10), Date.new(2026, 8, 10))
    twentieth = mine.between(Date.new(2026, 8, 20), Date.new(2026, 8, 20))

    assert_equal august.revenue_cents, tenth.revenue_cents + twentieth.revenue_cents
  end

  def test_a_range_can_be_given_as_one_argument
    assert_equal mine.between(Date.new(2026, 8, 1), Date.new(2026, 8, 31)).revenue_cents,
                 mine.between(Date.new(2026, 8, 1)..Date.new(2026, 8, 31)).revenue_cents
  end

  # -- grouping --------------------------------------------------------------

  def test_grouping_gives_a_hash_keyed_by_the_dimension
    by_product = mine.by(:product_id).revenue_cents

    assert_equal 900, by_product[@coffee.id]
    assert_equal 500, by_product[@mug.id]
  end

  def test_grouping_by_two_dimensions_keys_on_a_pair
    result = mine.by(:ordered_on, :product_id).revenue_cents

    assert_equal 200, result[[Date.new(2026, 8, 10), @coffee.id]]
  end

  def test_the_time_bucket_can_be_read_coarser_than_it_is_stored
    by_month = mine.by(ordered_on: :month).revenue_cents

    assert_equal 1000, by_month[Date.new(2026, 8, 1)]
    assert_equal 400, by_month[Date.new(2026, 9, 1)]
  end

  def test_an_unknown_grain_is_refused
    assert_raises(Grain::Error) { mine.by(ordered_on: :fortnight).revenue_cents }
  end

  def test_an_unknown_dimension_says_what_there_is
    error = assert_raises(Grain::Error) { mine.by(:colour).revenue_cents }

    assert_match(/no dimension :colour/, error.message)
    assert_match(/store_id/, error.message)
  end

  # -- how measures combine --------------------------------------------------

  def test_an_extreme_collapses_to_the_extreme_of_the_extremes
    # Not summed: the largest single line in August is the 500 cent mug, not the
    # total of every day's largest.
    august = mine.between(Date.new(2026, 8, 1), Date.new(2026, 8, 31))

    assert_equal 500, august.largest_line
  end

  def test_a_ratio_is_divided_at_the_grain_it_is_read_at
    # 1400 cents over 10 units. Averaging the days' averages would give something
    # else entirely, which is the bug storing a rate pre-divided would bake in.
    assert_in_delta 140.0, mine.average_unit_price, 0.001
  end

  def test_a_ratio_over_nothing_is_nil_rather_than_zero
    assert_nil ShopMetricsRollup.for(store_id: -1).average_unit_price
  end

  def test_a_ratio_is_recomputed_per_group
    per_product = mine.by(:product_id).average_unit_price

    assert_in_delta 100.0, per_product[@coffee.id], 0.001
    assert_in_delta 500.0, per_product[@mug.id], 0.001
  end

  # -- reading everything at once --------------------------------------------

  def test_rows_carries_every_measure_and_ratio
    row = mine.by(:product_id).rows.find { |candidate| candidate[:product_id] == @mug.id }

    assert_equal 1, row[:line_count]
    assert_equal 500, row[:revenue_cents]
    assert_equal 500, row[:largest_line]
    assert_in_delta 500.0, row[:average_unit_price], 0.001
  end

  def test_to_h_is_keyed_by_group_and_falls_back_to_the_single_row
    assert_equal 500, mine.by(:product_id).to_h[@mug.id][:revenue_cents]
    assert_equal 1400, mine.to_h[:revenue_cents]
  end

  # -- composition -----------------------------------------------------------

  def test_filters_ranges_and_groups_compose_in_any_order
    one = mine.between(Date.new(2026, 8, 1), Date.new(2026, 8, 31)).by(:product_id).for(product_id: @coffee.id)
    other = ShopMetricsRollup.by(:product_id).for(product_id: @coffee.id, store: @store)
                             .between(Date.new(2026, 8, 1)..Date.new(2026, 8, 31))

    assert_equal one.revenue_cents, other.revenue_cents
    assert_equal({ @coffee.id => 500 }, one.revenue_cents)
  end

  def test_a_query_is_not_changed_by_narrowing_it
    base = mine
    base.by(:product_id).revenue_cents

    assert_equal 1400, base.revenue_cents
  end

  def test_a_list_of_values_filters_on_any_of_them
    assert_equal 1400, mine.for(product_id: [@coffee.id, @mug.id]).revenue_cents
    assert_equal 500, mine.for(product_id: [@mug.id]).revenue_cents
  end

  def test_an_empty_list_matches_nothing_instead_of_failing
    # Arrives as current_user.products.ids coming back empty. IN () is not valid
    # SQL, so this used to raise a syntax error out of a dashboard.
    assert_equal 0, mine.for(product_id: []).revenue_cents
    assert_equal 0, mine.for(product_id: []).line_count
    assert_empty mine.for(product_id: []).by(:product_id).rows
  end

  def test_a_rollup_without_a_time_dimension_refuses_a_range
    assert_raises(Grain::Error) do
      IntegrationCategoryRollup.between(Date.new(2026, 1, 1), Date.new(2026, 12, 31))
    end
  end

  # -- tenant isolation ------------------------------------------------------

  def test_a_read_without_its_tenant_refuses_to_run
    # The failure mode this replaces: 2300, silently, being this store's 1400
    # plus a competitor's 900.
    error = assert_raises(Grain::MissingTenantError) { ShopMetricsRollup.by(:product_id).revenue_cents }

    assert_match(/store_id/, error.message)
    assert_match(/across_tenants/, error.message)
  end

  def test_building_the_statement_refuses_too_and_not_only_running_it
    # sql is public and gets pasted into consoles, so the guard cannot live in
    # the part that happens to execute it.
    assert_raises(Grain::MissingTenantError) { ShopMetricsRollup.by(:product_id).sql }
  end

  def test_across_tenants_reads_every_tenant
    assert_equal 2300, ShopMetricsRollup.across_tenants.revenue_cents
    assert_equal 5, ShopMetricsRollup.across_tenants.line_count
  end

  def test_across_tenants_survives_being_narrowed_further
    # merge builds a new query, and dropping the flag there would turn the
    # escape hatch into a raise the moment anyone grouped or ranged on it.
    query = ShopMetricsRollup.across_tenants
                             .between(Date.new(2026, 8, 1), Date.new(2026, 8, 31))
                             .by(:product_id)

    assert_equal({ @coffee.id => 1400, @mug.id => 500 }, query.revenue_cents)
  end

  def test_a_null_tenant_refuses_rather_than_reading_as_zero
    # for(store_id: current_user.store_id) with a nil store_id matches no cell
    # and reads as a clean zero, which is a lie about the data rather than a leak.
    error = assert_raises(Grain::MissingTenantError) { ShopMetricsRollup.for(store_id: nil).revenue_cents }

    assert_match(/never null/, error.message)
  end

  def test_it_answers_to_the_measures_it_has_and_not_to_others
    assert_respond_to mine, :revenue_cents
    assert_respond_to mine, :average_unit_price
    refute_respond_to mine, :nonsense
    assert_raises(NoMethodError) { mine.nonsense }
  end
end
