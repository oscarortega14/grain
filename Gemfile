# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in grain.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", "~> 5.16"

gem "rubocop", "~> 1.21"

# Grain ships Rails generators, so the generators are tested against the real
# thing: an ERB template that renders invalid Ruby is a bug that reaches users.
gem "railties", ">= 7.1"

# Integration tests run against a real Postgres. The SQL Grain generates is the
# product; asserting on strings alone would be false confidence.
gem "activerecord", ">= 7.1"
gem "pg", "~> 1.5"
