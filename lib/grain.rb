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
require_relative "grain/definition"
require_relative "grain/rollup"
require_relative "grain/schema"
require_relative "grain/change_log"
require_relative "grain/type_resolver"
require_relative "grain/migration"

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
