# frozen_string_literal: true

module Grain
  # Renders the migration that creates a rollup's table.
  #
  # Grain emits a migration file for the application to read and run, rather than
  # creating tables at runtime. A rollup table is part of the schema like any
  # other: it belongs in version control, in code review, and in schema.rb.
  class Migration
    # Postgres caps identifiers at 63 bytes, and a long rollup name plus a
    # suffix passes that easily.
    MAX_IDENTIFIER = 63

    attr_reader :schema, :types

    def initialize(definition)
      @schema = Schema.new(definition)
      @types = TypeResolver.new(definition)
    end

    def table_name
      schema.table_name
    end

    # True when a dimension resolves to a nullable column. Postgres rejects nulls
    # in a primary key, so the rollup falls back to a surrogate key plus a unique
    # index that treats nulls as equal.
    def surrogate_key?
      types.nullable_dimensions.any?
    end

    def up
      [create_table, uniqueness_index].compact.join("\n\n")
    end

    def down
      "drop_table :#{table_name}"
    end

    def uniqueness_index_name
      truncate("index_#{table_name}_uniqueness")
    end

    private

    # Array#inspect renders [:a, :b], and rubocop-rails-omakase wants the inner
    # spaces. That matters because omakase ships with every `rails new` on Rails 8
    # and lints db/migrate — db/schema.rb is excluded, migrations are not. Without
    # this, installing Grain puts an application's linter in the red over a file it
    # did not write, and regenerating the migration brings the offence back.
    def symbol_list(names)
      "[ #{names.map(&:inspect).join(", ")} ]"
    end

    def create_table
      lines = ["create_table :#{table_name}#{primary_key_option} do |t|"]
      lines.concat(key_column_lines)
      lines << ""
      lines.concat(measure_column_lines)
      lines << "end"
      lines.join("\n")
    end

    # No `id: false` alongside a composite primary key. Rails accepts the pair
    # and then creates no primary key at all, silently, which would leave the
    # rollup table with nothing enforcing one row per cell.
    def primary_key_option
      return ", id: :bigint" if surrogate_key?

      ", primary_key: #{symbol_list(schema.primary_key)}"
    end

    def key_column_lines
      schema.definition.key_dimensions.map do |dimension|
        type = types.dimension_type(dimension)
        nullable = types.dimension_nullable?(dimension)
        "  t.#{type} :#{dimension.name}#{nullable ? "" : ", null: false"}"
      end
    end

    # Measures default to zero and are never null. A null measure would poison
    # every delta applied to it afterwards, since null plus one is null.
    def measure_column_lines
      schema.definition.measures.map do |measure|
        "  t.#{types.measure_type(measure)} :#{measure.name}, null: false, default: 0"
      end
    end

    def uniqueness_index
      return nil unless surrogate_key?

      "add_index :#{table_name}, #{symbol_list(schema.key_columns)}, unique: true,\n" \
        "          nulls_not_distinct: true, name: #{uniqueness_index_name.inspect}"
    end

    def truncate(identifier)
      return identifier if identifier.bytesize <= MAX_IDENTIFIER

      identifier[0, MAX_IDENTIFIER]
    end
  end
end
