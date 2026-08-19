# frozen_string_literal: true

module Grain
  # Which columns of which tables can move a fact row between cells, and so are
  # worth waking a trigger for.
  #
  # Unlike the fact table these can be narrowed exactly: at each hop along a
  # dimension's path the only column that matters is the foreign key leading to
  # the next hop, or the dimension's own column at the end. Narrowing is not an
  # optimisation to add later — without it a single busy table would write a log
  # row on every update it ever takes.
  class WatchedColumns
    attr_reader :definition, :resolver

    def initialize(definition)
      @definition = definition
      @resolver = TypeResolver.new(definition)
    end

    # { table name => [column names] }, with the fact table left out: its measures
    # aggregate arbitrary SQL, so which of its columns feed them cannot be known
    # and every update on it has to be logged.
    def to_h
      collected = {}
      definition.watched_paths.each { |path| add_path(path, collected) }
      definition.filter_associations.each { |association| add_filter(association, collected) }
      collected.delete(resolver.fact_table)
      collected
    end

    private

    def add_path(path, into)
      path.hops.each_with_index.reduce(definition.fact.model) do |model, (hop, index)|
        add_hop(model, hop, path, index, into)
      end
    end

    # Two columns matter at each step: the foreign key on the table being left,
    # and — once the walk reaches the end — the dimension's own column.
    def add_hop(model, hop, path, index, into)
      reflection = resolver.reflection!(model, hop, path)
      add(into, model.table_name, reflection.foreign_key)
      reflection.klass.tap do |next_model|
        add(into, next_model.table_name, path.column) if last_hop?(path, index)
      end
    end

    def last_hop?(path, index)
      index == path.hops.length - 1
    end

    def add_filter(association, into)
      reflection = resolver.reflection!(definition.fact.model, association, association)
      add(into, definition.fact.model.table_name, reflection.foreign_key)
      conditions(association).each_key { |column| add(into, reflection.klass.table_name, column) }
    end

    def conditions(association)
      where = definition.fact.where
      where[association] || where[association.to_s] || {}
    end

    def add(into, table, column)
      list = (into[table] ||= [])
      list << column.to_s
      list.uniq!
    end
  end
end
