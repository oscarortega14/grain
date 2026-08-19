# frozen_string_literal: true

module Grain
  # The table a rollup counts rows from and reads its measures off.
  #
  # The model is stored by name and resolved lazily, so a definition can be
  # loaded and inspected before the application's models are.
  class Fact
    attr_reader :model_name, :where

    def initialize(model, where: nil)
      @model_name = model.is_a?(Class) ? model.name.to_s : model.to_s
      @where = where
      validate!
      freeze
    end

    def model
      model_name.constantize
    end

    # A filter reaching through an association adds or removes whole rows when
    # the associated row changes. That is not a delta on a cell, it is an
    # invalidation of every cell the row belonged to.
    def filtered_through_association?
      filter_associations.any?
    end

    # The association names the filter reaches through, each of which is a table
    # whose changes can add or remove fact rows.
    def filter_associations
      return [] unless where.is_a?(Hash)

      where.select { |_, value| value.is_a?(Hash) }.keys.map(&:to_sym)
    end

    private

    def validate!
      raise InvalidDefinitionError, "fact needs a model" if model_name.empty?
      return if where.nil? || where.is_a?(Hash)

      raise InvalidDefinitionError, "fact where takes a hash, got #{where.class}"
    end
  end
end
