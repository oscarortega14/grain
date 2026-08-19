# frozen_string_literal: true

module Grain
  # The single table every trigger writes into, the trigger function they all
  # share, and the vocabulary of what a trigger can record.
  #
  # One trigger per source table, never one per rollup: several rollups can read
  # the same fact table, and triggers must not multiply with them. A trigger
  # records that a row changed and nothing more. Deciding which rollups care, and
  # which of their cells are affected, is the worker's job.
  module ChangeLog
    OPERATIONS = %i[insert update delete].freeze

    FUNCTION_NAME = "grain_record_change"

    COLUMNS = {
      id: :bigserial,
      source_table: :text,
      # Text rather than bigint so that Grain works on integer, UUID and string
      # primary keys alike. The worker casts it back when it reads the source, so
      # the fact table's own index is still used.
      row_id: :text,
      operation: :text,
      # The row as it was before the change, recorded for updates and deletes.
      #
      # Without it, the cell a row is leaving cannot be located: once the row
      # carries its new values, nothing points back at where it used to be
      # counted, and that cell would keep the departed row in its totals
      # forever. This is why the change log is not merely a list of ids.
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

      # No secondary indexes: the worker reads forward by id and prunes by id, so
      # the primary key already covers both. The log is drained continuously and
      # is never meant to grow.
      def table_definition
        <<~RUBY
          create_table :#{table_name} do |t|
            t.text :source_table, null: false
            t.text :row_id, null: false
            t.text :operation, null: false
            t.jsonb :previous
            t.datetime :created_at, null: false
          end
        RUBY
      end

      # One function for every watched table. TG_TABLE_NAME tells the worker which
      # table a row came from, so nothing here has to be generated per table.
      #
      # clock_timestamp() rather than now(): now() returns the transaction's start
      # time, which would stamp every row written in one transaction identically.
      def function_sql
        <<~SQL
          CREATE OR REPLACE FUNCTION #{FUNCTION_NAME}() RETURNS trigger
          LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'INSERT' THEN
              INSERT INTO #{table_name} (source_table, row_id, operation, previous, created_at)
              VALUES (TG_TABLE_NAME, NEW.id::text, 'insert', NULL, clock_timestamp());
              RETURN NEW;
            ELSIF TG_OP = 'UPDATE' THEN
              INSERT INTO #{table_name} (source_table, row_id, operation, previous, created_at)
              VALUES (TG_TABLE_NAME, NEW.id::text, 'update', to_jsonb(OLD), clock_timestamp());
              RETURN NEW;
            ELSE
              INSERT INTO #{table_name} (source_table, row_id, operation, previous, created_at)
              VALUES (TG_TABLE_NAME, OLD.id::text, 'delete', to_jsonb(OLD), clock_timestamp());
              RETURN OLD;
            END IF;
          END;
          $$;
        SQL
      end

      def drop_function_sql
        "DROP FUNCTION IF EXISTS #{FUNCTION_NAME}();"
      end
    end
  end
end
