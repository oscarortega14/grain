# frozen_string_literal: true

require "rails/generators"

module Grain
  module Generators
    # Writes a rollup definition for you to fill in.
    #
    # Separate from grain:table on purpose: this runs once per rollup, while the
    # migration that builds its table gets regenerated every time the definition
    # gains a dimension or a measure.
    class RollupGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Writes app/rollups/NAME_rollup.rb for you to fill in."

      def create_rollup_file
        template "rollup.rb.erb", File.join("app/rollups", "#{file_name}_rollup.rb")
      end

      def report_next_steps
        say ""
        say "Fill in #{file_name}_rollup.rb, then:", :green
        say "  bin/rails generate grain:table #{file_name}"
        say ""
      end

      private

      def rollup_class_name
        "#{class_name.delete_suffix("Rollup")}Rollup"
      end

      def file_name
        super.delete_suffix("_rollup")
      end
    end
  end
end
