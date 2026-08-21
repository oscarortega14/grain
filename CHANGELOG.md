## [Unreleased]

### Breaking

- **Reads require their tenant.** `Rollup.by(...)` without a `for(tenant: ...)`
  now raises `Grain::MissingTenantError` instead of aggregating every tenant into
  one number. The read it replaces did not return a wrong figure, it returned
  another tenant's, and nothing about the result gave that away. A `nil` tenant is
  refused for the same reason: no cell can hold one, so the read came back a clean
  zero. Spanning every tenant is asked for by name with
  `Rollup.across_tenants`, which also makes those reads greppable.

### Fixed

- `for(dimension: [])` raised a Postgres syntax error from `IN ()`. An empty list
  is what `current_user.churches.ids` hands over when there are none, and it now
  matches nothing instead of failing.
- `for(dimension: [id, nil])` silently dropped the null coordinate: `IN` treats a
  null as an unknown that equals nothing, so the cells with no value for that
  dimension — the ones a dashboard labels "uncategorised" — fell out of the answer
  with no sign they had been left out. A list containing `nil` now matches them,
  the same as passing `nil` on its own already did.
- A `time` dimension resolved from a **nullable** column is now reported as
  nullable, so the rollup takes the surrogate key path instead of declaring the
  bucket `NOT NULL` inside the primary key. Before this, the first fact row with
  no timestamp failed to insert — at write time, on the application's own table,
  with nothing pointing at Grain.

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
