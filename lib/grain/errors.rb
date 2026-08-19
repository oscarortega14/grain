# frozen_string_literal: true

module Grain
  # Base class for everything Grain raises, so applications can rescue Grain
  # failures without catching unrelated errors.
  class Error < StandardError; end

  # A rollup definition is invalid: missing source, unknown dimension, a measure
  # that cannot be maintained incrementally, and so on.
  class InvalidDefinitionError < Error; end

  # The rollup table does not match its definition — usually a definition
  # changed without a backfill.
  class StaleSchemaError < Error; end

  # `verify` found rows where the rollup disagrees with its source.
  class VerificationError < Error; end

  # No rollup class matches the name a command was given.
  class RollupNotFoundError < Error; end

  # The change log has grown past the point where applying deltas is cheaper
  # than a backfill.
  class ChangeLogOverflowError < Error; end
end
