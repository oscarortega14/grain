# frozen_string_literal: true

require "active_record"

# A real Postgres for the integration tests. Grain's product is the SQL it
# generates: triggers, upserts and aggregate queries. Asserting on generated
# strings alone would be false confidence, since a string can be syntactically
# fine and semantically wrong.
module Database
  URL = ENV.fetch("GRAIN_TEST_DATABASE_URL", "postgres://postgres:grain@127.0.0.1:5433/grain_test")

  class << self
    def available?
      connect!
      true
    rescue StandardError
      false
    end

    def connect!
      return if ActiveRecord::Base.connected?

      ActiveRecord::Base.establish_connection(URL)
      ActiveRecord::Base.connection.execute("SELECT 1")
    end

    def connection
      ActiveRecord::Base.connection
    end

    # The ordinary commerce schema the fixtures describe, built for real so that
    # reflections, column types and triggers are the genuine article.
    def load_schema!
      connect!
      silence do
        drop_everything!
        ActiveRecord::Schema.define do
          create_table :stores, force: true do |t|
            t.string :currency, null: false
          end

          create_table :categories, force: true do |t|
            t.string :name, null: false
          end

          create_table :products, force: true do |t|
            t.references :category, foreign_key: true, null: true
            t.string :name, null: false
          end

          create_table :orders, force: true do |t|
            t.references :store, foreign_key: true, null: false
            t.date :placed_on, null: false
            t.string :state, null: false, default: "pending"
            # No rollup resolves anything through this column. It exists so the
            # tests can prove a narrowed trigger stays quiet.
            t.string :notes
          end

          create_table :line_items, force: true do |t|
            t.references :order, foreign_key: true, null: false
            t.references :product, foreign_key: true, null: false
            t.integer :quantity, null: false, default: 1
            t.bigint :unit_price_cents, null: false, default: 0
          end
        end
      end
    end

    def drop_everything!
      tables = connection.tables
      tables.each { |table| connection.drop_table(table, force: :cascade) }
      connection.execute("DROP FUNCTION IF EXISTS #{Grain::ChangeLog::FUNCTION_NAME}() CASCADE")
    end

    def silence
      previous = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      yield
    ensure
      ActiveRecord::Migration.verbose = previous
    end

    def truncate!
      tables = connection.tables - %w[schema_migrations ar_internal_metadata]
      return if tables.empty?

      connection.execute("TRUNCATE #{tables.map { |t| connection.quote_table_name(t) }.join(", ")} CASCADE")
    end
  end
end

# Real models, so Grain walks real reflections rather than stand-ins.
class Store < ActiveRecord::Base; end

class Category < ActiveRecord::Base; end

class Product < ActiveRecord::Base
  belongs_to :category, optional: true
end

class Order < ActiveRecord::Base
  belongs_to :store
end

class LineItem < ActiveRecord::Base
  belongs_to :order
  belongs_to :product
end
