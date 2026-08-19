# frozen_string_literal: true

module Grain
  # Finds the cells a change could have touched.
  #
  # The rule this is built on: recomputing a cell that did not need it is
  # harmless, while missing one that did is the only unforgivable bug. So the
  # search is deliberately generous — the fact's filter is applied when looking
  # for where rows are now, and left off when looking for where they used to be.
  class Cells
    attr_reader :projection

    def initialize(definition)
      @definition = definition
      @projection = Projection.new(definition)
    end

    # Cells the given fact rows belong to as things stand.
    def live_for_facts(row_ids)
      return [] if row_ids.empty?

      select(conditions: [id_in(Projection::FACT, row_ids)] + projection.filter_conditions)
    end

    # The cell a fact row sat in before it changed, rebuilt from the log. Without
    # this the row's contribution would sit in its old cell forever, because
    # nothing points there any more.
    def previous_for_fact(previous_json)
      select(substitutions: { [] => previous_json })
    end

    # Cells reachable through a row of a watched table, as things stand.
    def live_through(hops, row_ids)
      return [] if row_ids.empty?

      select(conditions: [id_in(projection.alias_for(hops), row_ids)] + projection.filter_conditions)
    end

    # ...and as they were, with that table's row rebuilt from the log.
    def previous_through(hops, previous_json)
      select(substitutions: { hops => previous_json })
    end

    private

    def select(conditions: [], substitutions: {})
      sql = +"SELECT DISTINCT #{selection} FROM #{projection.from_and_joins(substitutions).join(" ")}"
      sql << " WHERE #{conditions.join(" AND ")}" if conditions.any?
      connection.select_all(sql).to_a.map(&:symbolize_keys)
    end

    def selection
      projection.key_columns.zip(projection.dimension_expressions)
                .map { |name, expression| "#{expression} AS #{name}" }
                .join(", ")
    end

    def id_in(table_alias, row_ids)
      "#{table_alias}.id IN (#{row_ids.map { |id| connection.quote(id) }.join(", ")})"
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
