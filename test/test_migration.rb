# frozen_string_literal: true

require "test_helper"

# Every key dimension resolves to a NOT NULL column, so this rollup can use a
# plain composite primary key.
class FakeRevenueRollup < Grain::Rollup
  fact "FakeLineItem", where: { order: { state: "paid" } }

  tenant    :store_id,   via: { order: :store_id }
  time      :ordered_on, via: { order: :placed_at }, grain: :day
  dimension :product_id, via: :product_id
  dimension :currency,   via: { order: { store: :currency } }, immutable: true

  measure :line_count,    count: true
  measure :revenue_cents, sum: "quantity * unit_price_cents", type: :bigint
end

# category_id is nullable, which Postgres will not allow in a primary key.
class FakeCategoryRollup < Grain::Rollup
  fact "FakeLineItem"

  tenant    :store_id,    via: { order: :store_id }
  dimension :category_id, via: { product: :category_id }

  measure :line_count, count: true
end

# cancelled_at is nullable, so the day bucket it resolves to is nullable too.
class FakeCancellationRollup < Grain::Rollup
  fact "FakeLineItem"

  tenant :store_id,     via: { order: :store_id }
  time   :cancelled_on, via: { order: :cancelled_at }, grain: :day

  measure :line_count, count: true
end

class TestTypeResolver < Minitest::Test
  def resolver
    Grain::TypeResolver.new(FakeRevenueRollup.definition)
  end

  def dimension(name)
    FakeRevenueRollup.definition.dimensions.find { |d| d.name == name }
  end

  def test_a_local_column_type_comes_from_the_fact_table
    assert_equal :bigint, resolver.dimension_type(dimension(:product_id))
  end

  def test_one_hop_reads_the_associated_model
    assert_equal :bigint, resolver.dimension_type(dimension(:store_id))
  end

  def test_two_hops_walk_all_the_way
    assert_equal :string, resolver.dimension_type(dimension(:currency))
  end

  def test_a_time_dimension_takes_its_type_from_the_grain_not_the_source
    # placed_at is a datetime, but the rollup stores the day it falls into.
    assert_equal :datetime, FakeOrder.columns_hash["placed_at"].type
    assert_equal :date, resolver.dimension_type(dimension(:ordered_on))
  end

  def test_a_measure_keeps_its_declared_type
    measure = FakeRevenueRollup.definition.measures.last

    assert_equal :bigint, resolver.measure_type(measure)
  end

  def test_nullable_source_columns_are_reported
    nullable = Grain::TypeResolver.new(FakeCategoryRollup.definition).nullable_dimensions

    assert_equal %i[category_id], nullable.map(&:name)
  end

  def test_a_rollup_over_non_null_columns_reports_none
    assert_empty resolver.nullable_dimensions
  end

  def test_a_nullable_time_source_makes_its_bucket_nullable
    # The bucket of a null timestamp is null. Reporting a time dimension as NOT
    # NULL because it is a time dimension put that column in the primary key and
    # broke the next insert into the fact table.
    types = Grain::TypeResolver.new(FakeCancellationRollup.definition)
    dimension = FakeCancellationRollup.definition.time

    assert types.dimension_nullable?(dimension)
    assert_equal %i[cancelled_on], types.nullable_dimensions.map(&:name)
  end

  def test_a_bigint_source_column_stays_a_bigint
    # ActiveRecord reports bigint as :integer with limit 8. Taking that at face
    # value would key the rollup on four bytes and break past two billion.
    assert_equal :integer, FakeLineItem.columns_hash["order_id"].type
    assert_equal 8, FakeLineItem.columns_hash["order_id"].limit
    assert_equal :bigint, resolver.dimension_type(dimension(:product_id))
  end

  def test_a_missing_column_is_reported_with_the_model_that_lacks_it
    rollup = Class.new(Grain::Rollup) do
      fact "FakeLineItem"
      tenant :nope, via: { order: :does_not_exist }
      measure :line_count, count: true
    end

    error = assert_raises(Grain::InvalidDefinitionError) do
      Grain::TypeResolver.new(rollup.definition).dimension_type(rollup.definition.tenant)
    end
    assert_match(/does not exist/, error.message)
  end

  def test_a_missing_association_is_reported
    rollup = Class.new(Grain::Rollup) do
      fact "FakeLineItem"
      tenant :nope, via: { warehouse: :id }
      measure :line_count, count: true
    end

    error = assert_raises(Grain::InvalidDefinitionError) do
      Grain::TypeResolver.new(rollup.definition).dimension_type(rollup.definition.tenant)
    end
    assert_match(/no association/, error.message)
  end

  def test_crossing_a_has_many_is_refused
    rollup = Class.new(Grain::Rollup) do
      fact "FakeOrder"
      tenant :nope, via: { line_items: :id }
      measure :order_count, count: true
    end

    error = assert_raises(Grain::InvalidDefinitionError) do
      Grain::TypeResolver.new(rollup.definition).dimension_type(rollup.definition.tenant)
    end
    assert_match(/not a belongs_to/, error.message)
  end
end

class TestMigration < Minitest::Test
  def migration
    Grain::Migration.new(FakeRevenueRollup.definition)
  end

  def test_a_composite_primary_key_when_no_key_column_is_nullable
    refute_predicate migration, :surrogate_key?
    assert_includes migration.up,
                    "create_table :grain_fake_revenue_rollups, " \
                    "primary_key: [:store_id, :ordered_on, :product_id, :currency]"
  end

  def test_a_composite_key_is_never_paired_with_id_false
    # Rails accepts the pair and then creates no primary key at all, leaving
    # nothing to enforce one row per cell. Found by the integration test.
    refute_includes migration.up, "id: false"
  end

  def test_key_columns_are_typed_and_not_null
    up = migration.up

    assert_includes up, "t.bigint :store_id, null: false"
    assert_includes up, "t.date :ordered_on, null: false"
    assert_includes up, "t.string :currency, null: false"
  end

  def test_measures_default_to_zero_and_are_never_null
    # A null measure would poison every delta applied afterwards: null plus one
    # is null, and the cell would stay null forever.
    assert_includes migration.up, "t.bigint :line_count, null: false, default: 0"
    assert_includes migration.up, "t.bigint :revenue_cents, null: false, default: 0"
  end

  def test_ratios_get_no_column
    refute_includes migration.up, "average"
  end

  def test_no_uniqueness_index_is_added_when_the_primary_key_covers_it
    refute_includes migration.up, "add_index"
  end

  def test_a_nullable_dimension_falls_back_to_a_surrogate_key
    nullable = Grain::Migration.new(FakeCategoryRollup.definition)

    assert_predicate nullable, :surrogate_key?
    assert_includes nullable.up, "create_table :grain_fake_category_rollups, id: :bigint"
    assert_includes nullable.up, "t.bigint :category_id\n"
  end

  def test_a_nullable_time_bucket_takes_the_surrogate_path_too
    nullable = Grain::Migration.new(FakeCancellationRollup.definition)

    assert_predicate nullable, :surrogate_key?
    assert_includes nullable.up, "t.date :cancelled_on\n"
    refute_includes nullable.up, "t.date :cancelled_on, null: false"
  end

  def test_the_surrogate_path_keeps_uniqueness_with_nulls_treated_as_equal
    up = Grain::Migration.new(FakeCategoryRollup.definition).up

    assert_includes up, "add_index :grain_fake_category_rollups, [:store_id, :category_id], unique: true"
    assert_includes up, "nulls_not_distinct: true"
  end

  def test_down_drops_the_table
    assert_equal "drop_table :grain_fake_revenue_rollups", migration.down
  end

  def test_index_names_stay_within_the_postgres_identifier_limit
    name = Grain::Migration.new(FakeCategoryRollup.definition).uniqueness_index_name

    assert_operator name.bytesize, :<=, Grain::Migration::MAX_IDENTIFIER
  end
end
