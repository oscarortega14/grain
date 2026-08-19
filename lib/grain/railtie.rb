# frozen_string_literal: true

require "rails/railtie"

module Grain
  # Hooks Grain into a Rails application: rake tasks, autoloading of
  # app/rollups, and the default logger.
  class Railtie < ::Rails::Railtie
    initializer "grain.logger" do
      Grain.config.logger ||= Rails.logger
    end

    rake_tasks do
      load File.expand_path("../tasks/grain.rake", __dir__)
    end

    initializer "grain.autoload_rollups" do |app|
      app.config.autoload_paths << app.root.join("app/rollups") if app.root.join("app/rollups").exist?
    end
  end
end
