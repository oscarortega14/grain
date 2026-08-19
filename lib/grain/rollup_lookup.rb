# frozen_string_literal: true

module Grain
  # Finds a rollup class from the name given on a command line, accepting it with
  # or without the Rollup suffix.
  #
  # Kept out of the generator so the rule is testable on its own: Thor catches the
  # errors a generator raises and prints them rather than letting them out, which
  # makes assertions about failure unreliable at that level.
  module RollupLookup
    class << self
      def candidates(name)
        base = name.to_s.camelize
        [base, "#{base.delete_suffix("Rollup")}Rollup"].uniq
      end

      def find(name)
        candidates(name).filter_map(&:safe_constantize).find { |constant| rollup?(constant) }
      end

      def find!(name)
        find(name) || raise(RollupNotFoundError, message_for(name))
      end

      def rollup?(constant)
        constant.is_a?(Class) && constant < Rollup ? true : false
      end

      def message_for(name)
        "Could not find a Grain::Rollup named #{candidates(name).join(" or ")}. " \
          "Run `rails generate grain:rollup #{suggested_argument(name)}` first."
      end

      private

      def suggested_argument(name)
        name.to_s.underscore.delete_suffix("_rollup")
      end
    end
  end
end
