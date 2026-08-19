# frozen_string_literal: true

require_relative "lib/grain/version"

Gem::Specification.new do |spec|
  spec.name = "grain"
  spec.version = Grain::VERSION
  spec.authors = ["Oscar Ortega"]
  spec.email = ["oscardeveloper14@gmail.com"]

  spec.summary = "Incrementally maintained pre-aggregates for Rails dashboards."
  spec.description = <<~DESC.strip
    Grain keeps dashboard aggregates pre-computed and incrementally up to date
    inside your own Postgres database. You declare the grain of an aggregate
    once — tenant, time bucket and dimensions — and Grain maintains it with
    deltas driven by database triggers instead of recomputing everything on a
    schedule. No new infrastructure, no materialized view refresh storms, and a
    verify command that proves the aggregate still matches its source.
  DESC
  spec.homepage = "https://github.com/grainrb/grain"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Rails 7.1 is the floor: composite primary keys landed there, and rollup
  # tables are keyed on (tenant, time bucket, dimensions).
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
end
