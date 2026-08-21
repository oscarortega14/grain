# frozen_string_literal: true

module Grain
  # Refuses a read that does not say which tenant it is for.
  #
  # Every rollup is keyed by a tenant, so leaving it out does not make a number
  # slightly wrong, it makes it somebody else's: the read totals every tenant at
  # once and nothing about the result looks unusual. Grain cannot pick a default,
  # since it has no idea whose data the caller is entitled to, so the only two
  # options are to raise or to leak.
  class TenantGuard
    attr_reader :rollup, :filters

    def initialize(rollup, filters)
      @rollup = rollup
      @filters = filters
    end

    def check!
      name = rollup.definition.tenant.name
      return if filters.key?(name) && !filters[name].nil?

      raise MissingTenantError, complaint(name)
    end

    private

    def complaint(name)
      return null_tenant(name) if filters.key?(name)

      "#{rollup} is keyed by #{name} and was read without it, which would total every tenant " \
        "at once. Narrow it with .for(#{name}: ...), or ask for .across_tenants explicitly."
    end

    # A tenant column is never nullable, so a null filter matches no cell at all
    # and the read comes back a clean zero — a lie about the data rather than a
    # leak, and just as quiet.
    def null_tenant(name)
      "#{rollup} was read with #{name}: nil. A tenant is never null, so this matches no cell " \
        "and reads as zero; pass a real #{name}, or .across_tenants to span all of them."
    end
  end
end
