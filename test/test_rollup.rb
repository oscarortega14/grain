# frozen_string_literal: true

require "test_helper"

# A deliberately ordinary schema, chosen because it makes every structural case
# visible at once: a column local to the fact table, a single hop, two distinct
# association roots, a dimension declared immutable, and a filter that reaches
# through an association.
#
# Nothing about Grain assumes this shape. A rollup describes whatever tables the
# application already has.
class OrderRevenueRollup < Grain::Rollup
  fact "LineItem", where: { order: { state: "paid" } }

  tenant    :store_id,    via: { order: :store_id }
  time      :ordered_on,  via: { order: :placed_on }, grain: :day
  dimension :product_id,  via: :product_id
  dimension :category_id, via: { product: :category_id }
  dimension :currency,    via: { order: :currency }, immutable: true

  measure :line_count,    count: true
  measure :units,         sum: "quantity", type: :bigint
  measure :revenue_cents, sum: "quantity * unit_price_cents", type: :bigint
  ratio   :average_unit_price, of: :revenue_cents, over: :units
end

# The smallest useful rollup: a tenant, a time bucket and one count. Everything
# else in the DSL is optional.
class SignupCountRollup < Grain::Rollup
  fact "User"

  tenant :account_id, via: :account_id
  time   :created_on, via: :created_at, grain: :day

  measure :signups, count: true
end

class TestRollup < Minitest::Test
  def definition
    OrderRevenueRollup.definition
  end

  def test_a_multi_table_definition_is_valid
    assert_same definition, definition.validate!
  end

  def test_the_minimal_definition_is_valid
    assert_same SignupCountRollup.definition, SignupCountRollup.definition.validate!
  end

  def test_table_name_is_derived_from_the_class
    assert_equal "grain_order_revenue_rollups", OrderRevenueRollup.table_name
    assert_equal "grain_signup_count_rollups", SignupCountRollup.table_name
  end

  def test_key_order_is_tenant_then_time_then_declaration_order
    assert_equal %i[store_id ordered_on product_id category_id currency],
                 definition.key_dimensions.map(&:name)
  end

  def test_every_association_root_reached_by_a_mutable_dimension_is_watched
    # :order for store_id and ordered_on, :product for category_id. currency is
    # declared immutable and product_id is local to the fact table, so neither
    # contributes a table to watch.
    assert_equal %i[order product], definition.watched_associations
  end

  def test_a_rollup_reading_only_local_columns_watches_nothing
    assert_empty SignupCountRollup.definition.watched_associations
  end

  def test_a_filter_through_an_association_is_flagged_as_an_invalidation_source
    assert_predicate definition, :invalidated_by_filter?
    refute_predicate SignupCountRollup.definition, :invalidated_by_filter?
  end

  def test_measures_and_ratios_are_recorded
    assert_equal %i[line_count units revenue_cents], definition.measures.map(&:name)
    assert_equal :average_unit_price, definition.ratios.first.name
  end
end

# Every way a definition can be wrong should fail loudly at declaration or at
# validate!, never silently produce a rollup that counts the wrong thing.
class TestRollupValidation < Minitest::Test
  def test_a_definition_without_a_tenant_is_rejected
    rollup = Class.new(Grain::Rollup) do
      fact "LineItem"
      time :ordered_on, via: :placed_on, grain: :day
      measure :line_count, count: true
    end

    error = assert_raises(Grain::InvalidDefinitionError) { rollup.validate! }
    assert_match(/no tenant/, error.message)
  end

  def test_a_definition_without_a_time_dimension_is_allowed
    # Not an oversight: a rollup with no time bucket is a counter cache, and one
    # that can be verified against its source instead of drifting in silence.
    rollup = Class.new(Grain::Rollup) do
      fact "LineItem"
      tenant :store_id, via: :store_id
      measure :line_count, count: true
    end

    assert_same rollup.definition, rollup.validate!
    refute_predicate rollup.definition, :temporal?
  end

  def test_a_definition_without_measures_is_rejected
    rollup = Class.new(Grain::Rollup) do
      fact "LineItem"
      tenant :store_id, via: :store_id
      time :ordered_on, via: :placed_on, grain: :day
    end

    assert_raises(Grain::InvalidDefinitionError) { rollup.validate! }
  end

  def test_a_ratio_over_an_unknown_measure_is_rejected
    rollup = Class.new(Grain::Rollup) do
      fact "LineItem"
      tenant :store_id, via: :store_id
      time :ordered_on, via: :placed_on, grain: :day
      measure :units, sum: "quantity", type: :bigint
      ratio :average_unit_price, of: :revenue_cents, over: :units
    end

    error = assert_raises(Grain::InvalidDefinitionError) { rollup.validate! }
    assert_match(/unknown measure/, error.message)
  end

  def test_two_tenants_are_rejected
    assert_raises(Grain::InvalidDefinitionError) do
      Class.new(Grain::Rollup) do
        tenant :store_id, via: :store_id
        tenant :region_id, via: :region_id
      end
    end
  end

  def test_two_facts_are_rejected
    assert_raises(Grain::InvalidDefinitionError) do
      Class.new(Grain::Rollup) do
        fact "LineItem"
        fact "Order"
      end
    end
  end

  def test_a_duplicate_name_is_rejected
    assert_raises(Grain::InvalidDefinitionError) do
      Class.new(Grain::Rollup) do
        tenant :store_id, via: :store_id
        measure :store_id, count: true
      end
    end
  end

  def test_a_grain_on_a_plain_dimension_is_rejected
    assert_raises(Grain::InvalidDefinitionError) do
      Grain::Dimension.new(name: :product_id, via: :product_id, grain: :day)
    end
  end

  def test_a_time_dimension_needs_a_supported_grain
    assert_raises(Grain::InvalidDefinitionError) do
      Grain::Dimension.new(name: :ordered_on, via: :placed_on, role: :time, grain: :hour)
    end
  end

  def test_an_anonymous_rollup_cannot_derive_a_table_name
    assert_raises(Grain::InvalidDefinitionError) { Class.new(Grain::Rollup).table_name }
  end

  def test_definitions_do_not_leak_between_subclasses
    refute_same OrderRevenueRollup.definition, SignupCountRollup.definition
  end
end
