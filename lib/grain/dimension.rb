# frozen_string_literal: true

module Grain
  # One key column of a rollup table: the tenant, the time bucket, or a plain
  # dimension. +via+ says how to resolve it from a fact row.
  class Dimension
    ROLES = %i[tenant time dimension].freeze
    TIME_GRAINS = %i[day].freeze

    attr_reader :name, :path, :role, :grain

    def initialize(name:, via:, role: :dimension, grain: nil, immutable: false)
      @name = name.to_sym
      @path = Path.parse(via)
      @role = role.to_sym
      @grain = grain&.to_sym
      @immutable = immutable
      validate!
      freeze
    end

    def tenant?
      role == :tenant
    end

    def time?
      role == :time
    end

    def immutable?
      @immutable
    end

    # A dimension resolved through an association moves fact rows into a
    # different cell when the associated row changes, so its table needs a
    # trigger. Declaring it immutable trades that safety for speed.
    def watched?
      !path.local? && !immutable?
    end

    private

    def validate!
      raise InvalidDefinitionError, "unknown dimension role #{role.inspect}" unless ROLES.include?(role)

      time? ? validate_time_grain! : validate_no_grain!
    end

    def validate_time_grain!
      return if TIME_GRAINS.include?(grain)

      raise InvalidDefinitionError,
            "time dimension #{name} needs a grain in #{TIME_GRAINS.inspect}, got #{grain.inspect}"
    end

    def validate_no_grain!
      return if grain.nil?

      raise InvalidDefinitionError, "grain only applies to a time dimension, #{name} is a #{role}"
    end
  end
end
