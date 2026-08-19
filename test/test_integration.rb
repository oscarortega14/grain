# frozen_string_literal: true

require "test_helper"
require "active_record"
require "rails/generators"
require_relative "support/database"
require "generators/grain/install/install_generator"
require "generators/grain/table/table_generator"

# Every key dimension resolves to a NOT NULL column, so this one gets a plain
# composite primary key.
class IntegrationRevenueRollup < Grain::Rollup
  fact LineItem, where: { order: { state: "paid" } }

  tenant    :store_id,   via: { order: :store_id }
  time      :ordered_on, via: { order: :placed_on }, grain: :day
  dimension :product_id, via: :product_id

  measure :line_count,    count: true
  measure :revenue_cents, sum: "quantity * unit_price_cents", type: :bigint
end

# products.category_id is nullable, which Postgres will not accept in a primary
# key, so this one exercises the surrogate key path.
class IntegrationCategoryRollup < Grain::Rollup
  fact LineItem

  tenant    :store_id,    via: { order: :store_id }
  dimension :category_id, via: { product: :category_id }

  measure :line_count, count: true
end

# Runs the generators, evaluates the files they write, and applies them to a real
# Postgres. Nothing here asserts on a string: the point is whether the SQL Grain
# produces actually does what it claims.
class TestIntegration < Minitest::Test
  GENERATED = File.expand_path("tmp/integration", __dir__)

  def setup
    skip "Postgres not available at #{Database::URL}" unless Database.available?
    Database.load_schema!
    FileUtils.rm_rf(GENERATED)
    apply_install
  end

  def teardown
    Database.drop_everything! if Database.available?
  end

  # -- helpers ---------------------------------------------------------------

  def connection
    Database.connection
  end

  def apply_install
    quietly { Grain::Generators::InstallGenerator.start([], destination_root: GENERATED) }
    run_generated_migration("CreateGrainChangeLog")
  end

  def apply_table(rollup)
    quietly do
      Grain::Generators::TableGenerator.start([rollup.name.underscore], destination_root: GENERATED)
    end
    run_generated_migration("Create#{Grain::Migration.new(rollup.definition).table_name.camelize}")
  end

  def run_generated_migration(class_name)
    path = Dir[File.join(GENERATED, "db/migrate/*_#{class_name.underscore}.rb")].max
    raise "no migration matched #{class_name}" if path.nil?

    load path
    Database.silence { Object.const_get(class_name).new.migrate(:up) }
  end

  def quietly
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def change_log
    connection.select_all("SELECT * FROM grain_change_log ORDER BY id").to_a
  end

  def seed_order(state: "paid")
    store = Store.create!(currency: "COP")
    product = Product.create!(name: "Cafe")
    order = Order.create!(store: store, placed_on: Date.new(2026, 8, 19), state: state)
    { store: store, product: product, order: order }
  end

  # -- the install migration -------------------------------------------------

  def test_the_install_migration_creates_the_change_log_and_the_function
    assert_includes connection.tables, "grain_change_log"

    function = connection.select_value(<<~SQL)
      SELECT proname FROM pg_proc WHERE proname = '#{Grain::ChangeLog::FUNCTION_NAME}'
    SQL

    assert_equal Grain::ChangeLog::FUNCTION_NAME, function
  end

  # -- the rollup table ------------------------------------------------------

  def test_a_composite_primary_key_is_created_as_declared
    apply_table(IntegrationRevenueRollup)

    key = connection.select_values(<<~SQL)
      SELECT a.attname
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE i.indrelid = 'grain_integration_revenue_rollups'::regclass AND i.indisprimary
      ORDER BY array_position(i.indkey, a.attnum)
    SQL

    assert_equal %w[store_id ordered_on product_id], key
  end

  def test_the_time_column_stores_a_date_even_though_the_source_is_one
    apply_table(IntegrationRevenueRollup)

    type = connection.select_value(<<~SQL)
      SELECT data_type FROM information_schema.columns
      WHERE table_name = 'grain_integration_revenue_rollups' AND column_name = 'ordered_on'
    SQL

    assert_equal "date", type
  end

  def test_measures_are_not_null_and_default_to_zero
    apply_table(IntegrationRevenueRollup)

    row = connection.select_one(<<~SQL)
      SELECT is_nullable, column_default FROM information_schema.columns
      WHERE table_name = 'grain_integration_revenue_rollups' AND column_name = 'revenue_cents'
    SQL

    assert_equal "NO", row["is_nullable"]
    assert_equal "0", row["column_default"]
  end

  def test_a_nullable_dimension_gets_a_surrogate_key_and_a_nulls_not_distinct_index
    # The riskiest assumption in the schema layer: Postgres rejects nulls in a
    # primary key, so uniqueness has to come from an index that treats them as
    # equal. This proves the generated DDL is accepted and behaves.
    apply_table(IntegrationCategoryRollup)

    name = Grain::Migration.new(IntegrationCategoryRollup.definition).uniqueness_index_name
    definition = connection.select_value(<<~SQL)
      SELECT indexdef FROM pg_indexes WHERE indexname = '#{name}'
    SQL

    assert_match(/NULLS NOT DISTINCT/, definition)

    connection.execute(<<~SQL)
      INSERT INTO grain_integration_category_rollups (store_id, category_id, line_count)
      VALUES (1, NULL, 1)
    SQL

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      connection.execute(<<~SQL)
        INSERT INTO grain_integration_category_rollups (store_id, category_id, line_count)
        VALUES (1, NULL, 1)
      SQL
    end
    assert_match(/duplicate key/, error.message)
  end

  # -- the triggers ----------------------------------------------------------

  def test_inserting_a_fact_row_is_logged_without_a_previous_row
    apply_table(IntegrationRevenueRollup)
    seeded = seed_order

    LineItem.create!(order: seeded[:order], product: seeded[:product], quantity: 2, unit_price_cents: 500)

    entry = change_log.find { |row| row["source_table"] == "line_items" }

    refute_nil entry
    assert_equal "insert", entry["operation"]
    assert_nil entry["previous"]
  end

  def test_updating_a_fact_row_records_the_row_as_it_was
    apply_table(IntegrationRevenueRollup)
    seeded = seed_order
    item = LineItem.create!(order: seeded[:order], product: seeded[:product], quantity: 2, unit_price_cents: 500)
    connection.execute("DELETE FROM grain_change_log")

    item.update!(quantity: 7)

    entry = change_log.last
    previous = JSON.parse(entry["previous"])

    assert_equal "update", entry["operation"]
    assert_equal 2, previous["quantity"]
  end

  def test_deleting_a_fact_row_logs_the_old_id_not_a_null
    apply_table(IntegrationRevenueRollup)
    seeded = seed_order
    item = LineItem.create!(order: seeded[:order], product: seeded[:product])
    connection.execute("DELETE FROM grain_change_log")

    item.destroy!

    entry = change_log.last

    assert_equal "delete", entry["operation"]
    assert_equal item.id.to_s, entry["row_id"]
  end

  def test_a_watched_column_on_a_related_table_wakes_the_trigger
    apply_table(IntegrationRevenueRollup)
    seeded = seed_order(state: "pending")
    connection.execute("DELETE FROM grain_change_log")

    seeded[:order].update!(state: "paid")

    assert_equal(%w[orders], change_log.map { |row| row["source_table"] })
  end

  def test_an_unwatched_column_stays_quiet
    # The whole reason triggers narrow their UPDATE. Without this, a busy table
    # writes a log row for every update it ever takes and the gem is unusable.
    apply_table(IntegrationRevenueRollup)
    seeded = seed_order
    connection.execute("DELETE FROM grain_change_log")

    seeded[:order].update!(notes: "left at the door")

    assert_empty change_log
  end

  def test_two_rollups_over_the_same_table_share_one_trigger
    apply_table(IntegrationRevenueRollup)
    apply_table(IntegrationCategoryRollup)

    count = connection.select_value(<<~SQL)
      SELECT count(*) FROM pg_trigger
      WHERE tgrelid = 'line_items'::regclass AND NOT tgisinternal
    SQL

    assert_equal 1, count
  end

  def test_installing_a_second_rollup_over_a_watched_table_is_not_an_error
    apply_table(IntegrationRevenueRollup)

    # Would raise if attaching were not written as drop-then-create.
    apply_table(IntegrationCategoryRollup)

    assert_includes connection.tables, "grain_integration_category_rollups"
  end
end
