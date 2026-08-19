# frozen_string_literal: true

require "test_helper"
require "active_record"
require_relative "support/database"
require_relative "support/harness"
require_relative "test_integration"

# A measure whose expression has a fractional part, stored as an integer. It
# exists to pin down a trap described in the test below.
class DecimalSumRollup < Grain::Rollup
  fact LineItem

  tenant :store_id, via: { order: :store_id }

  measure :halves, sum: "quantity / 2.0", type: :bigint
end

# Verification is the product's whole argument, so it is tested by corrupting the
# rollup on purpose and checking that Grain notices — including the corruption a
# design built on upserts could never find.
class TestVerification < Minitest::Test
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
    LineItem.create!(order: @order, product: @coffee, quantity: 2, unit_price_cents: 500)
    Grain::Worker.drain
  end

  def table
    "grain_integration_revenue_rollups"
  end

  def verify(**options)
    IntegrationRevenueRollup.verify(**options)
  end

  def rows
    connection.select_all("SELECT * FROM #{table}").to_a
  end

  # -- the clean case --------------------------------------------------------

  def test_a_decimal_sum_does_not_disagree_with_itself_forever
    # A latent trap: SUM over bigint yields numeric, so a recompute would insert a
    # truncated value while a verification compared the untruncated one. The cell
    # would have been reported wrong on every run and repair could never settle
    # it. Aggregates are computed at the stored type so both agree.
    Grain::Registry.register(DecimalSumRollup)
    Harness.build_table!(DecimalSumRollup)
    LineItem.create!(order: @order, product: @mug, quantity: 3, unit_price_cents: 100)
    Grain::Worker.drain

    assert_predicate DecimalSumRollup.verify, :clean?, DecimalSumRollup.verify.to_s
    assert_predicate DecimalSumRollup.verify, :clean?
  end

  def test_a_rollup_the_worker_built_agrees_with_its_source
    report = verify

    assert_predicate report, :clean?
    assert_equal 0, report.count
    assert_match(/agrees with its source/, report.to_s)
  end

  def test_an_empty_rollup_over_an_empty_source_agrees
    LineItem.delete_all
    connection.execute("DELETE FROM #{table}")

    assert_predicate verify, :clean?
  end

  # -- the three kinds of disagreement ---------------------------------------

  def test_a_wrong_number_is_found_and_named
    connection.execute("UPDATE #{table} SET revenue_cents = 999999")

    report = verify

    refute_predicate report, :clean?
    assert_equal 1, report.count_of(:wrong)
    assert_match(/revenue_cents 999999 should be 1000/, report.to_s)
  end

  def test_a_cell_the_rollup_never_got_is_reported_as_missing
    connection.execute("DELETE FROM #{table}")

    report = verify

    assert_equal 1, report.count_of(:missing)
    assert_equal 1000, report.discrepancies.first.expected[:revenue_cents]
    assert_nil report.discrepancies.first.stored
  end

  def test_a_cell_whose_source_is_gone_is_reported_as_extra
    # The corruption an upsert-based design can never find: there is nothing left
    # in the source to upsert against, so only a comparison catches it.
    connection.execute(<<~SQL)
      INSERT INTO #{table} (store_id, ordered_on, product_id, line_count, revenue_cents)
      VALUES (#{@store.id}, '2020-01-01', #{@mug.id}, 7, 7777)
    SQL

    report = verify

    assert_equal 1, report.count_of(:extra)
    assert_equal :extra, report.discrepancies.first.kind
    assert_nil report.discrepancies.first.expected
  end

  def test_the_three_kinds_are_found_together
    connection.execute("UPDATE #{table} SET line_count = 99")
    connection.execute(<<~SQL)
      INSERT INTO #{table} (store_id, ordered_on, product_id, line_count, revenue_cents)
      VALUES (#{@store.id}, '2020-01-01', #{@mug.id}, 7, 7777)
    SQL
    LineItem.create!(order: @order, product: @mug, quantity: 1, unit_price_cents: 300)

    report = verify

    assert_equal 1, report.count_of(:wrong)
    assert_equal 1, report.count_of(:extra)
    assert_equal 1, report.count_of(:missing)
  end

  # -- repair ----------------------------------------------------------------

  def test_repair_fixes_all_three_kinds_at_once
    connection.execute("UPDATE #{table} SET line_count = 99")
    connection.execute(<<~SQL)
      INSERT INTO #{table} (store_id, ordered_on, product_id, line_count, revenue_cents)
      VALUES (#{@store.id}, '2020-01-01', #{@mug.id}, 7, 7777)
    SQL
    LineItem.create!(order: @order, product: @mug, quantity: 1, unit_price_cents: 300)

    repaired = verify(repair: true)

    assert_equal 3, repaired.repaired
    assert_predicate verify, :clean?
    assert_equal 2, rows.length
  end

  def test_repair_on_a_clean_rollup_touches_nothing
    report = verify(repair: true)

    assert_predicate report, :clean?
    assert_equal 0, report.repaired
  end

  # -- nullable dimensions ---------------------------------------------------

  def test_a_null_dimension_is_not_mistaken_for_a_disagreement
    # Matching cells on = would report every null cell as both missing and extra,
    # since null = null is never true. This is why the join uses IS NOT DISTINCT
    # FROM.
    LineItem.create!(order: @order, product: @mug, quantity: 1, unit_price_cents: 100)
    Grain::Worker.drain

    report = IntegrationCategoryRollup.verify

    assert_predicate report, :clean?, report.to_s
  end

  # -- scoping ---------------------------------------------------------------

  def test_scoping_by_tenant_ignores_other_tenants
    other = Order.create!(store: @other_store, placed_on: Date.new(2026, 8, 19), state: "paid")
    LineItem.create!(order: other, product: @coffee, quantity: 1, unit_price_cents: 100)
    Grain::Worker.drain
    connection.execute("UPDATE #{table} SET revenue_cents = 1 WHERE store_id = #{@other_store.id}")

    assert_predicate verify(tenant: @store.id), :clean?
    refute_predicate verify(tenant: @other_store.id), :clean?
  end

  def test_scoping_by_date_range_ignores_cells_outside_it
    connection.execute(<<~SQL)
      INSERT INTO #{table} (store_id, ordered_on, product_id, line_count, revenue_cents)
      VALUES (#{@store.id}, '2020-01-01', #{@mug.id}, 7, 7777)
    SQL

    assert_predicate verify(between: Date.new(2026, 8, 1)..Date.new(2026, 8, 31)), :clean?
    refute_predicate verify, :clean?
  end

  def test_a_rollup_without_a_time_dimension_refuses_a_date_range
    error = assert_raises(Grain::Error) do
      IntegrationCategoryRollup.verify(between: Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
    end

    assert_match(/no time dimension/, error.message)
  end
end
