# frozen_string_literal: true

module Grain
  # Works out the column type of every column of a rollup table by walking each
  # dimension's declared path to the model that owns the source column.
  #
  # This is the one part of the schema layer that needs the application's models,
  # which is why it is separate from Schema: the shape of a rollup can be reasoned
  # about without a database, its types cannot.
  class TypeResolver
    # A time dimension does not store the source timestamp, it stores the bucket
    # the row falls into, so its type comes from the grain rather than the source.
    BUCKET_TYPES = { day: :date }.freeze

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def dimension_type(dimension)
      return BUCKET_TYPES.fetch(dimension.grain) if dimension.time?

      source_column(dimension).type
    end

    # Whether the source column can be null, which decides whether the rollup can
    # use a plain composite primary key: Postgres will not accept a null in one.
    def dimension_nullable?(dimension)
      return false if dimension.time?

      source_column(dimension).null
    end

    def measure_type(measure)
      measure.type
    end

    def nullable_dimensions
      definition.key_dimensions.select { |dimension| dimension_nullable?(dimension) }
    end

    private

    def source_column(dimension)
      model = walk(definition.fact.model, dimension.path)
      model.columns_hash.fetch(dimension.path.column.to_s) do
        raise InvalidDefinitionError,
              "#{dimension.name} resolves to #{model}##{dimension.path.column}, which does not exist"
      end
    end

    def walk(model, path)
      path.hops.reduce(model) { |current, hop| hop_to(current, hop, path) }
    end

    def hop_to(model, hop, path)
      reflection = model.reflect_on_association(hop)
      raise InvalidDefinitionError, "#{model} has no association #{hop.inspect} (via #{path})" if reflection.nil?

      unless reflection.belongs_to?
        raise InvalidDefinitionError,
              "#{model}##{hop} is not a belongs_to (via #{path}). A fact row must resolve to one " \
              "value per dimension, or it would be counted in several cells at once."
      end

      reflection.klass
    end
  end
end
