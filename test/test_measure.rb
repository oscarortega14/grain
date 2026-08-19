# frozen_string_literal: true

require "test_helper"

class TestMeasure < Minitest::Test
  def test_count_needs_no_expression
    measure = Grain::Measure.from_options(:attempts, count: true)

    assert_equal :count, measure.aggregate
    assert_nil measure.expression
    assert_predicate measure, :counts_rows?
  end

  def test_sum_carries_an_expression
    measure = Grain::Measure.from_options(:passed, sum: "CASE WHEN score >= 60 THEN 1 ELSE 0 END")

    assert_equal :sum, measure.aggregate
    assert_equal "CASE WHEN score >= 60 THEN 1 ELSE 0 END", measure.expression
    refute_predicate measure, :counts_rows?
  end

  def test_sum_without_an_expression_is_rejected
    assert_raises(Grain::InvalidDefinitionError) { Grain::Measure.from_options(:passed, sum: true) }
  end

  def test_exactly_one_aggregate_is_allowed
    assert_raises(Grain::InvalidDefinitionError) do
      Grain::Measure.from_options(:muddled, count: true, sum: "score")
    end
  end

  def test_unsupported_aggregates_are_rejected
    assert_raises(Grain::InvalidDefinitionError) do
      Grain::Measure.from_options(:median_score, median: "score")
    end
  end

  def test_count_and_sum_are_reversible_but_extremes_are_not
    assert_predicate Grain::Measure.from_options(:a, count: true), :reversible?
    assert_predicate Grain::Measure.from_options(:b, sum: "score"), :reversible?
    refute_predicate Grain::Measure.from_options(:c, max: "score"), :reversible?
    refute_predicate Grain::Measure.from_options(:d, min: "score"), :reversible?
  end
end
