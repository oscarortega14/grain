# frozen_string_literal: true

module Grain
  # The single table every trigger writes into, and the vocabulary of what a
  # trigger can record.
  #
  # One trigger per source table, never one per rollup: several rollups can read
  # the same fact table, and triggers must not multiply with them. A trigger
  # records that a row changed and nothing more. Deciding which rollups care, and
  # which of their cells are affected, is the worker's job.
  module ChangeLog
    OPERATIONS = %i[insert update delete].freeze

    COLUMNS = {
      id: :bigserial,
      source_table: :text,
      row_id: :bigint,
      operation: :text,
      # The row as it was before the change, recorded for updates and deletes.
      #
      # Without it, the cell a row is leaving cannot be located: once the row
      # carries its new values, nothing points back at where it used to be
      # counted, and that cell would keep the departed row in its totals
      # forever. This is the reason the change log is not merely a list of ids.
      previous: :jsonb,
      created_at: :timestamptz
    }.freeze

    class << self
      def table_name
        Grain.config.change_log_table
      end

      def operation!(name)
        operation = name.to_s.downcase.to_sym
        return operation if OPERATIONS.include?(operation)

        raise Error, "unknown change log operation #{name.inspect}, expected #{OPERATIONS.inspect}"
      end

      # Updates and deletes need the previous row to locate the cell being left.
      # An insert leaves nothing behind, so it needs none.
      def previous_required?(operation)
        operation!(operation) != :insert
      end
    end
  end
end
