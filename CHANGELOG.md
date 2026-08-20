## [Unreleased]

## [0.0.1] - 2026-08-19

First published release. Feature complete for a first pass and tested end to end
against a live PostgreSQL, but not yet used in a real application, so the API may
still change.

- Rollup definitions: `fact`, `tenant`, `time`, `dimension`, `measure`, `ratio`,
  with dimensions resolved through `belongs_to` chains up to three hops deep.
- Generators: `grain:install`, `grain:rollup`, `grain:table`. The rollup table's
  shape, its key and every table needing a trigger are all derived from the
  definition.
- Change capture by database trigger into a single change log, with the previous
  row recorded so the cell a row leaves can still be found. `UPDATE` triggers are
  narrowed to the columns that can move a row between cells, taking the union
  across every rollup that watches a table.
- `Grain::Worker.drain` claims a batch and rebuilds the cells the changes could
  have touched, claiming and applying in one transaction.
- `Rollup.verify` compares a rollup against its source and reports wrong, missing
  and extra cells, with `repair: true` to rebuild them.
- `Rollup.backfill` populates a rollup from existing data, sliced so each slice is
  idempotent and never shows a partial total.
- Reads: `Rollup.for(...).between(...).by(...)`, with time buckets readable at a
  coarser grain than they are stored, measures combined by their own kind, and
  ratios divided at the grain they are read at.
- Rake tasks: `grain:verify`, `grain:backfill`, `grain:drain`.
