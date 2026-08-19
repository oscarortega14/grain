# frozen_string_literal: true

require "test_helper"
require "active_record"
require "rails/generators/test_case"
require "generators/grain/install/install_generator"

class TestInstallGenerator < Rails::Generators::TestCase
  tests Grain::Generators::InstallGenerator
  destination File.expand_path("../tmp/generator", __dir__)
  setup :prepare_destination

  MIGRATION = "db/migrate/create_grain_change_log.rb"

  def test_the_generated_migration_is_valid_ruby
    # The whole reason railties is a development dependency: an ERB template that
    # renders unparseable Ruby is a bug that reaches users on their first command.
    run_generator

    assert_migration MIGRATION do |content|
      assert RubyVM::InstructionSequence.compile(content)
    end
  end

  def test_the_migration_creates_the_change_log_table
    run_generator

    assert_migration MIGRATION do |content|
      assert_match(/class CreateGrainChangeLog < ActiveRecord::Migration\[\d+\.\d+\]/, content)
      assert_match(/create_table :grain_change_log do \|t\|/, content)
      assert_match(/t\.text :source_table, null: false/, content)
      assert_match(/t\.jsonb :previous/, content)
    end
  end

  def test_the_migration_installs_the_shared_trigger_function
    run_generator

    assert_migration MIGRATION do |content|
      assert_match(/CREATE OR REPLACE FUNCTION grain_record_change\(\) RETURNS trigger/, content)
      assert_match(/TG_TABLE_NAME/, content)
      assert_match(/to_jsonb\(OLD\)/, content)
      assert_match(/clock_timestamp\(\)/, content)
    end
  end

  def test_the_migration_is_reversible
    run_generator

    assert_migration MIGRATION do |content|
      assert_match(/DROP FUNCTION IF EXISTS grain_record_change\(\)/, content)
      assert_match(/drop_table :grain_change_log/, content)
    end
  end

  def test_it_writes_an_initializer
    run_generator

    assert_file "config/initializers/grain.rb" do |content|
      assert RubyVM::InstructionSequence.compile(content)
      assert_match(/Grain\.configure do \|config\|/, content)
      assert_match(/config\.change_log_table = "grain_change_log"/, content)
    end
  end

  def test_it_creates_the_rollups_directory
    run_generator

    assert_file "app/rollups/.keep"
  end
end

# The strings the generator writes, tested without a generator in the way.
class TestChangeLogSql < Minitest::Test
  def teardown
    Grain.reset_config!
  end

  def test_the_table_definition_carries_every_column
    definition = Grain::ChangeLog.table_definition

    %w[source_table row_id operation previous].each { |column| assert_match(/:#{column}/, definition) }
  end

  def test_row_id_is_text_so_uuid_keys_work
    assert_equal :text, Grain::ChangeLog::COLUMNS[:row_id]
    assert_match(/t\.text :row_id/, Grain::ChangeLog.table_definition)
  end

  def test_the_function_records_the_previous_row_only_where_there_is_one
    sql = Grain::ChangeLog.function_sql

    assert_match(/'insert', NULL/, sql)
    assert_match(/'update', to_jsonb\(OLD\)/, sql)
    assert_match(/'delete', to_jsonb\(OLD\)/, sql)
  end

  def test_a_delete_records_the_old_row_id_not_the_new_one
    # NEW is not populated on delete, so reading NEW.id there would be a null row.
    sql = Grain::ChangeLog.function_sql

    assert_match(/VALUES \(TG_TABLE_NAME, OLD\.id::text, 'delete'/, sql)
  end

  def test_the_configured_table_name_reaches_the_generated_sql
    Grain.configure { |c| c.change_log_table = "audit_grain_changes" }

    assert_match(/INSERT INTO audit_grain_changes/, Grain::ChangeLog.function_sql)
    assert_match(/create_table :audit_grain_changes/, Grain::ChangeLog.table_definition)
  end
end
