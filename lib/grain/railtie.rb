# frozen_string_literal: true

require "rails/railtie"

module Grain
  # Hooks Grain into a Rails application.
  #
  # Nothing here touches autoload_paths. Rails already autoloads and eager loads
  # every directory under app/, so app/rollups needs no help — and by the time a
  # railtie initializer runs, autoload_paths is frozen anyway.
  class Railtie < ::Rails::Railtie
    initializer "grain.logger" do
      Grain.config.logger ||= Rails.logger
    end

    initializer "grain.drain_job" do
      ActiveSupport.on_load(:active_job) { require "grain/drain_job" }
    end

    rake_tasks do
      load File.expand_path("../tasks/grain.rake", __dir__)
    end
  end
end
