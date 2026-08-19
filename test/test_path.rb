# frozen_string_literal: true

require "test_helper"

class TestPath < Minitest::Test
  def test_a_bare_symbol_is_a_local_column
    path = Grain::Path.parse(:user_id)

    assert_empty path.hops
    assert_equal :user_id, path.column
    assert_predicate path, :local?
  end

  def test_one_hop
    path = Grain::Path.parse(testing_section: :school_id)

    assert_equal %i[testing_section], path.hops
    assert_equal :school_id, path.column
    refute_predicate path, :local?
    assert_equal :testing_section, path.root_hop
  end

  def test_nested_hops
    path = Grain::Path.parse(testing_section: { assessment_window: :starts_on })

    assert_equal %i[testing_section assessment_window], path.hops
    assert_equal :starts_on, path.column
    assert_equal "testing_section.assessment_window.starts_on", path.to_s
  end

  def test_depth_beyond_the_limit_is_rejected
    too_deep = { a: { b: { c: { d: :column } } } }

    error = assert_raises(Grain::InvalidDefinitionError) { Grain::Path.parse(too_deep) }
    assert_match(/limit is 3/, error.message)
  end

  def test_a_hop_with_several_associations_is_ambiguous
    assert_raises(Grain::InvalidDefinitionError) do
      Grain::Path.parse(testing_section: :school_id, user: :id)
    end
  end

  def test_unsupported_via_is_rejected
    assert_raises(Grain::InvalidDefinitionError) { Grain::Path.parse([1, 2]) }
  end

  def test_paths_compare_by_value
    assert_equal Grain::Path.parse(a: :b), Grain::Path.parse(a: :b)
    refute_equal Grain::Path.parse(a: :b), Grain::Path.parse(a: :c)
  end
end
