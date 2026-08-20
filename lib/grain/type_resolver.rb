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

    # ActiveRecord reports a bigint column as :integer carrying a limit of 8, so
    # taking its type at face value would key a rollup on four bytes while the
    # source uses eight. That holds until an id passes two billion and then stops,
    # silently, on a table nobody thinks to look at.
    INTEGER_WIDTHS = { 8 => :bigint, 2 => :integer, 1 => :integer }.freeze

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def dimension_type(dimension)
      return BUCKET_TYPES.fetch(dimension.grain) if dimension.time?

      widen(source_column(dimension))
    end

    # The type of the column a dimension is read from, before any bucketing. A
    # time dimension needs this to know whether the source is already a calendar
    # day or a timestamp that has to be resolved to one.
    def source_type(dimension)
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

    def fact_table
      definition.fact.model.table_name
    end

    def nullable_dimensions
      definition.key_dimensions.select { |dimension| dimension_nullable?(dimension) }
    end

    # The validated belongs_to reflection for one hop. Public because working out
    # which columns to watch needs the same walk and the same complaints.
    def reflection!(model, hop, context)
      reflection = model.reflect_on_association(hop)
      raise InvalidDefinitionError, "#{model} has no association #{hop.inspect} (via #{context})" if reflection.nil?
      raise InvalidDefinitionError, one_value_per_dimension(model, hop, context) unless reflection.belongs_to?

      reflection
    end

    private

    def one_value_per_dimension(model, hop, context)
      "#{model}##{hop} is not a belongs_to (via #{context}). A fact row must resolve to one " \
        "value per dimension, or it would be counted in several cells at once."
    end

    def widen(column)
      return column.type unless column.type == :integer && column.limit == 8

      INTEGER_WIDTHS.fetch(column.limit, :integer)
    end

    def source_column(dimension)
      model = walk(definition.fact.model, dimension.path)
      model.columns_hash.fetch(dimension.path.column.to_s) do
        raise InvalidDefinitionError,
              "#{dimension.name} resolves to #{model}##{dimension.path.column}, which does not exist"
      end
    end

    def walk(model, path)
      path.hops.reduce(model) { |current, hop| reflection!(current, hop, path).klass }
    end
  end
end
