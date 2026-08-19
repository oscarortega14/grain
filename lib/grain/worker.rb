# frozen_string_literal: true

module Grain
  # Drains the change log and brings the affected cells back in line with the
  # source.
  #
  # Claiming and applying happen in one transaction: the log rows are deleted and
  # the rollups are rewritten together, so a crash rolls the deletions back and
  # the work is simply done again. Claiming uses SKIP LOCKED, so several workers
  # can drain the same log without waiting on each other or doing the same work
  # twice.
  class Worker
    Entry = Struct.new(:source_table, :row_id, :operation, :previous, keyword_init: true)

    class << self
      # Drains until the log is empty or the time budget runs out. Returns the
      # number of log entries applied.
      def drain(limit: Grain.config.batch_size, max_seconds: Grain.config.max_run_seconds)
        applied = 0
        deadline = monotonic + max_seconds
        loop do
          batch = new(limit: limit).call
          applied += batch
          break if batch.zero? || monotonic >= deadline
        end
        applied
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    attr_reader :limit

    def initialize(limit: Grain.config.batch_size)
      @limit = limit
    end

    def call
      connection.transaction do
        entries = claim
        next 0 if entries.empty?

        apply(entries)
        entries.length
      end
    end

    private

    # Deleting with RETURNING is the claim: inside the transaction the rows are
    # gone, so no other worker can pick them up, and if this transaction fails
    # they come back.
    def claim
      connection.select_all(claim_sql).to_a.map { |row| Entry.new(**row.symbolize_keys) }
    end

    def claim_sql
      <<~SQL
        DELETE FROM #{ChangeLog.table_name}
        WHERE id IN (
          SELECT id FROM #{ChangeLog.table_name}
          ORDER BY id
          LIMIT #{limit.to_i}
          FOR UPDATE SKIP LOCKED
        )
        RETURNING source_table, row_id, operation, previous
      SQL
    end

    def apply(entries)
      entries.group_by(&:source_table).each do |table, group|
        Registry.for_table(table).each { |rollup| refresh(rollup, table, group) }
      end
    end

    def refresh(rollup, table, entries)
      cells = affected_cells(rollup, table, entries)
      Recompute.new(rollup.definition).call(cells)
    end

    def affected_cells(rollup, table, entries)
      cells = Cells.new(rollup.definition)
      as_fact(cells, table, entries) + as_watched(cells, table, entries)
    end

    def as_fact(cells, table, entries)
      return [] unless cells.projection.fact_table == table

      cells.live_for_facts(entries.map(&:row_id)) + previous_cells(entries) { |json| cells.previous_for_fact(json) }
    end

    def as_watched(cells, table, entries)
      cells.projection.hops_for_table(table).flat_map do |hops|
        cells.live_through(hops, entries.map(&:row_id)) +
          previous_cells(entries) { |json| cells.previous_through(hops, json) }
      end
    end

    def previous_cells(entries, &block)
      entries.filter_map(&:previous).flat_map(&block)
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
