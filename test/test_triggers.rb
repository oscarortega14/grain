# frozen_string_literal: true

require "test_helper"
require_relative "test_migration"

# A two hop path that is NOT immutable. This is the case that proves watching
# only the root association would be wrong: changing a store's currency moves
# every line item on every order pointing at that store.
class FakeStoreCurrencyRollup < Grain::Rollup
  fact "FakeLineItem"

  tenant    :store_id, via: { order: :store_id }
  dimension :currency, via: { order: { store: :currency } }

  measure :line_count, count: true
end

class TestTriggers < Minitest::Test
  def triggers
    Grain::Triggers.new(FakeRevenueRollup.definition)
  end

  def two_hop
    Grain::Triggers.new(FakeStoreCurrencyRollup.definition)
  end

  def table_names(subject)
    subject.specs.map(&:table)
  end

  def spec_for(subject, table)
    subject.specs.find { |spec| spec.table == table }
  end

  def test_the_fact_table_always_gets_a_trigger
    assert_equal "line_items", table_names(triggers).first
  end

  def test_the_fact_trigger_is_not_narrowed
    # Measures aggregate arbitrary SQL, so which fact columns feed them cannot be
    # known. Narrowing would risk missing an update and drifting in silence.
    refute_predicate spec_for(triggers, "line_items"), :narrowed?
    assert_includes triggers.up, "AFTER INSERT OR UPDATE OR DELETE ON line_items"
  end

  def test_an_immutable_dimension_keeps_its_table_unwatched
    # currency is declared immutable in FakeRevenueRollup, so stores is not watched.
    refute_includes table_names(triggers), "stores"
  end

  def test_every_table_along_a_mutable_path_is_watched
    assert_equal %w[line_items orders stores], table_names(two_hop)
  end

  def test_the_terminal_table_watches_the_dimension_column
    assert_equal %w[currency], spec_for(two_hop, "stores").update_columns
  end

  def test_an_intermediate_table_watches_the_foreign_key_to_the_next_hop
    assert_equal %w[store_id], spec_for(two_hop, "orders").update_columns
  end

  def test_a_filter_column_is_watched_too
    # FakeRevenueRollup filters on order.state, so orders reacts to it as well as
    # to the columns its dimensions are resolved through.
    assert_equal %w[placed_at state store_id], spec_for(triggers, "orders").update_columns
  end

  def test_narrowed_updates_name_their_columns
    assert_includes two_hop.up, "AFTER INSERT OR UPDATE OF currency OR DELETE ON stores"
  end

  def test_trigger_names_are_per_table_not_per_rollup
    # The function they call is shared, so two rollups over the same table get one
    # trigger between them rather than one each.
    assert_equal "grain_orders_changed", spec_for(triggers, "orders").trigger_name
    assert_equal "grain_orders_changed", spec_for(two_hop, "orders").trigger_name
  end

  def test_attaching_is_written_as_drop_then_create
    # So that installing a second rollup over a table already watched is not an
    # error.
    statements = triggers.up_statements

    assert_match(/\ADROP TRIGGER IF EXISTS grain_line_items_changed/, statements.first)
    assert_match(/\ACREATE TRIGGER grain_line_items_changed/, statements[1])
  end

  def test_a_shared_table_takes_the_union_of_what_every_rollup_needs
    # The bug this guards against: FakeStoreCurrencyRollup does not filter on
    # state, so on its own it would narrow the orders trigger and stop the other
    # rollup from ever hearing about a state change.
    combined = Grain::Triggers.new([FakeRevenueRollup.definition, FakeStoreCurrencyRollup.definition])
    orders = combined.specs.find { |spec| spec.table == "orders" }

    assert_equal %w[placed_at state store_id], orders.update_columns
  end

  def test_a_table_that_is_a_fact_anywhere_is_never_narrowed
    counter = Class.new(Grain::Rollup) do
      fact "FakeOrder"
      tenant :store_id, via: :store_id
      measure :order_count, count: true
    end
    combined = Grain::Triggers.new([FakeRevenueRollup.definition, counter.definition])
    orders = combined.specs.find { |spec| spec.table == "orders" }

    refute_predicate orders, :narrowed?
  end

  def test_down_only_drops
    two_hop.down_statements.each { |statement| assert_match(/\ADROP TRIGGER IF EXISTS/, statement) }
    assert_equal 3, two_hop.down_statements.length
  end

  def test_each_statement_stands_alone
    # One statement per entry, so a migration can execute them individually rather
    # than relying on the adapter accepting several at once.
    triggers.up_statements.each { |statement| assert_equal 1, statement.count(";") }
  end
end
