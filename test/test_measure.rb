# frozen_string_literal: true

require "test_helper"

class TestMeasure < Minitest::Test
  def test_count_needs_neither_expression_nor_type
    measure = Grain::Measure.from_options(:attempts, count: true)

    assert_equal :count, measure.aggregate
    assert_nil measure.expression
    assert_equal :bigint, measure.type
    assert_predicate measure, :counts_rows?
  end

  def test_sum_carries_an_expression_and_a_type
    measure = Grain::Measure.from_options(:revenue_cents, sum: "quantity * unit_price_cents", type: :bigint)

    assert_equal :sum, measure.aggregate
    assert_equal "quantity * unit_price_cents", measure.expression
    assert_equal :bigint, measure.type
    refute_predicate measure, :counts_rows?
  end

  def test_a_decimal_sum_keeps_its_declared_type
    measure = Grain::Measure.from_options(:weight, sum: "weight_kg", type: :decimal)

    assert_equal :decimal, measure.type
  end

  def test_sum_without_a_type_is_rejected
    # Inferring it would mean silently rounding somebody's revenue.
    error = assert_raises(Grain::InvalidDefinitionError) do
      Grain::Measure.from_options(:revenue, sum: "amount")
    end
    assert_match(/needs an explicit type/, error.message)
  end

  def test_sum_without_an_expression_is_rejected
    assert_raises(Grain::InvalidDefinitionError) do
      Grain::Measure.from_options(:passed, sum: true, type: :bigint)
    end
  end

  def test_exactly_one_aggregate_is_allowed
    assert_raises(Grain::InvalidDefinitionError) do
      Grain::Measure.from_options(:muddled, count: true, sum: "score", type: :bigint)
    end
  end

  def test_unsupported_aggregates_are_rejected
    assert_raises(Grain::InvalidDefinitionError) do
      Grain::Measure.from_options(:median_score, median: "score", type: :bigint)
    end
  end

  def test_count_and_sum_are_reversible_but_extremes_are_not
    assert_predicate Grain::Measure.from_options(:a, count: true), :reversible?
    assert_predicate Grain::Measure.from_options(:b, sum: "score", type: :bigint), :reversible?
    refute_predicate Grain::Measure.from_options(:c, max: "score", type: :bigint), :reversible?
    refute_predicate Grain::Measure.from_options(:d, min: "score", type: :bigint), :reversible?
  end
end
