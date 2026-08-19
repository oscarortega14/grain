# frozen_string_literal: true

module Grain
  # The shape of the physical table a rollup is stored in, derived from its
  # definition: column names, their order, and the primary key.
  #
  # Column types are not here on purpose. A dimension's type has to match the
  # source column it is resolved from, which means reading the database. That
  # belongs to the migration generator; this class stays pure so the shape can be
  # reasoned about and tested without a connection.
  class Schema
    attr_reader :definition

    def initialize(definition)
      @definition = definition.validate!
      freeze
    end

    def table_name
      definition.table_name
    end

    # Key columns in a fixed order: tenant, then the time bucket if the rollup
    # has one, then the plain dimensions in declaration order.
    #
    # The order is part of the contract, not an implementation detail. Reads
    # filter on a prefix of it (tenant, or tenant and a date range), and so does
    # every scoped recompute, so both ride the primary key index.
    def key_columns
      definition.key_dimensions.map(&:name)
    end

    def measure_columns
      definition.measures.map(&:name)
    end

    # Every column of the rollup table.
    #
    # Ratios are absent by design: they are divided on read from two measures
    # that are stored, so a rate stays correct at every grain instead of being
    # frozen at the one it was computed for.
    def columns
      key_columns + measure_columns
    end

    def primary_key
      key_columns
    end

    # No secondary indexes in the first release, and that is a decision rather
    # than an omission. Every index slows down the writes that keep the rollup
    # fresh, and Grain cannot know an application's read patterns; the primary
    # key already covers the dominant ones. Extra indexes are the application's
    # call, added in its own migration.
    def indexes
      []
    end

    def temporal?
      definition.temporal?
    end
  end
end
