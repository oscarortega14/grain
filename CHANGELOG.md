## [Unreleased]

## [0.0.3] - 2026-08-21

### Fixed

- **Generated migrations tripped the linter of the app they landed in.** They
  wrote `[ :a, :b ]` as `[:a, :b]`, and `rubocop-rails-omakase` — which ships with
  every `rails new` on Rails 8 — wants the inner spaces. It lints `db/migrate`;
  `db/schema.rb` is the excluded one. So installing Grain put an application's
  linter in the red over a file it had not written, and regenerating the migration
  after a definition changed, which Grain asks for, brought the offence back.

## [0.0.2] - 2026-08-21

Everything here came out of using Grain in two real applications: a football
pool (golbet) and a multi-tenant church management API (ekklesia).

### Breaking

- **Reads require their tenant.** `Rollup.by(...)` without a `for(tenant: ...)`
  now raises `Grain::MissingTenantError` instead of aggregating every tenant into
  one number. The read it replaces did not return a wrong figure, it returned
  another tenant's, and nothing about the result gave that away. A `nil` tenant is
  refused for the same reason: no cell can hold one, so the read came back a clean
  zero. Spanning every tenant is asked for by name with `Rollup.across_tenants`,
  which also makes those reads greppable.
- **Joined tables are aliased `g_<path>` instead of `j0`, `j1`.** Named by the
  whole association path, because two routes can end at the same table and one
  alias for both is ambiguous. A measure expression written against a generated
  alias has to be updated.
- **Tables a measure reads through now log every update**, which changes the
  triggers a rollup installs. Regenerate the table migration for every rollup that
  uses `through:` — see Upgrading.

### Added

- **`through:` on a measure**, so an expression can read columns from tables the
  fact joins to: `sum: "CASE WHEN g_match.status = 'finished' THEN 1 ELSE 0 END",
  through: :match`. Those tables are joined into the recompute and watched by the
  triggers, because a column they own can change what a measure computes without
  any fact row moving.
- **`Grain::Installer.install!` and `rake grain:triggers`**, which re-attach the
  trigger function and every trigger. Needed after any `schema.rb` load: the
  schema format cannot represent functions or triggers, so loading it creates the
  tables and silently drops everything that keeps them correct. That is how test
  databases are built and what `db:reset` does.
- **`Grain::DrainJob`** and `config.queue`, so keeping rollups fresh is a
  scheduled ActiveJob entry rather than a cron line invoking rake. Overlapping
  runs are safe: claiming uses `FOR UPDATE SKIP LOCKED`.

### Fixed

- **A change to a table only a measure read never reached the rollup.** The
  trigger fired and the log took the row, but the registry did not route that
  table to any rollup, so the worker dropped it and the aggregate drifted in
  silence — the one failure mode Grain exists to prevent.
- **Rollup discovery `require`d files Zeitwerk manages**, which either
  double-defines the class or fails outright. It constantizes them now, and no
  longer blows up when `app/rollups` does not exist.
- **The railtie pushed `app/rollups` into `autoload_paths`** from an initializer,
  by which point that array is frozen. Rails already autoloads and eager loads
  everything under `app/`, so the hook was both broken and unnecessary.
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
- The install generator's closing instructions named the wrong generator for
  step 3.

### Upgrading from 0.0.1

1. Any read without a tenant now raises. Add `for(tenant: ...)`, or
   `across_tenants` where crossing them is the point.
2. Rename generated join aliases in measure expressions: `j0` becomes
   `g_<association path>`.
3. Regenerate and run the table migration for every rollup
   (`bin/rails generate grain:table <Rollup>`), so the triggers cover the tables
   your measures read through.
4. Call `Grain::Installer.install!` wherever your test suite loads the schema.
   Without it the triggers do not exist in the test database, the rollups never
   update, and the suite passes anyway.

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
