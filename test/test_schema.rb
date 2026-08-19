# frozen_string_literal: true

require "test_helper"

# A rollup with no time dimension: the generalised counter cache. "How many paid
# line items does this store have, per product" — no buckets, no date range.
class ProductTotalsRollup < Grain::Rollup
  fact "LineItem", where: { order: { state: "paid" } }

  tenant    :store_id,   via: { order: :store_id }
  dimension :product_id, via: :product_id

  measure :line_count, count: true
  measure :units,      sum: "quantity", type: :bigint
end

class TestSchema < Minitest::Test
  def temporal
    Grain::Schema.new(OrderRevenueRollup.definition)
  end

  def counter
    Grain::Schema.new(ProductTotalsRollup.definition)
  end

  def test_key_columns_follow_the_declared_order
    assert_equal %i[store_id ordered_on product_id category_id currency], temporal.key_columns
  end

  def test_a_rollup_without_a_time_dimension_is_valid_and_keyed_without_one
    refute_predicate counter, :temporal?
    assert_equal %i[store_id product_id], counter.key_columns
  end

  def test_the_temporal_rollup_reports_itself_as_such
    assert_predicate temporal, :temporal?
  end

  def test_columns_are_the_key_followed_by_the_measures
    assert_equal %i[store_id product_id line_count units], counter.columns
  end

  def test_ratios_are_not_stored_as_columns
    refute_includes temporal.columns, :average_unit_price
    assert_includes temporal.columns, :revenue_cents
    assert_includes temporal.columns, :units
  end

  def test_the_primary_key_is_the_whole_key
    assert_equal temporal.key_columns, temporal.primary_key
  end

  def test_no_secondary_indexes_are_emitted
    assert_empty temporal.indexes
  end

  def test_an_invalid_definition_cannot_produce_a_schema
    rollup = Class.new(Grain::Rollup) do
      fact "LineItem"
      time :ordered_on, via: :placed_on, grain: :day
      measure :line_count, count: true
    end

    assert_raises(Grain::InvalidDefinitionError) { Grain::Schema.new(rollup.definition) }
  end
end

class TestChangeLog < Minitest::Test
  def teardown
    Grain.reset_config!
  end

  def test_the_table_name_follows_configuration
    assert_equal "grain_change_log", Grain::ChangeLog.table_name

    Grain.configure { |c| c.change_log_table = "audit_grain_changes" }

    assert_equal "audit_grain_changes", Grain::ChangeLog.table_name
  end

  def test_operations_are_normalised
    assert_equal :insert, Grain::ChangeLog.operation!("INSERT")
    assert_equal :delete, Grain::ChangeLog.operation!(:delete)
  end

  def test_unknown_operations_are_rejected
    assert_raises(Grain::Error) { Grain::ChangeLog.operation!(:truncate) }
  end

  def test_only_inserts_can_skip_the_previous_row
    refute Grain::ChangeLog.previous_required?(:insert)
    assert Grain::ChangeLog.previous_required?(:update)
    assert Grain::ChangeLog.previous_required?(:delete)
  end

  def test_the_previous_row_column_exists
    assert_equal :jsonb, Grain::ChangeLog::COLUMNS[:previous]
  end
end
