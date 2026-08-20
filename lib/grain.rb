# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

require_relative "grain/version"
require_relative "grain/errors"
require_relative "grain/configuration"
require_relative "grain/path"
require_relative "grain/dimension"
require_relative "grain/measure"
require_relative "grain/ratio"
require_relative "grain/fact"
require_relative "grain/definition_validator"
require_relative "grain/definition"
require_relative "grain/rollup"
require_relative "grain/rollup_lookup"
require_relative "grain/schema"
require_relative "grain/change_log"
require_relative "grain/type_resolver"
require_relative "grain/migration"
require_relative "grain/watched_columns"
require_relative "grain/triggers"
require_relative "grain/registry"
require_relative "grain/installer"
require_relative "grain/join_graph"
require_relative "grain/projection"
require_relative "grain/cells"
require_relative "grain/recompute"
require_relative "grain/query_sql"
require_relative "grain/query"
require_relative "grain/backfill"
require_relative "grain/worker"
require_relative "grain/discrepancy"
require_relative "grain/verification_report"
require_relative "grain/verification_query"
require_relative "grain/verification"

# Grain keeps dashboard aggregates pre-computed and incrementally up to date
# inside the application's own Postgres database.
#
# What exists so far is the definition layer: a rollup declares its fact, its
# key dimensions and its measures, and Grain derives the rollup table's shape
# and the set of tables that have to be watched. Nothing writes to a database
# yet. See README.md for the design.
module Grain
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def reset_config!
      @config = Configuration.new
    end
  end
end

require_relative "grain/railtie" if defined?(Rails::Railtie)
