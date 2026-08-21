# Grain

**Incrementally maintained pre-aggregates for Rails dashboards — inside your own Postgres.**

Declare the grain of an aggregate once. Grain builds the table, keeps it correct as
your data changes, and can prove it still agrees with the source.

```ruby
class OrderRevenueRollup < Grain::Rollup
  fact LineItem, where: { order: { state: "paid" } }

  tenant    :store_id,    via: { order: :store_id }
  time      :ordered_on,  via: { order: :placed_on }, grain: :day
  dimension :product_id,  via: :product_id
  dimension :category_id, via: { product: :category_id }

  measure :line_count,    count: true
  measure :units,         sum: "quantity", type: :bigint
  measure :revenue_cents, sum: "quantity * unit_price_cents", type: :bigint
  ratio   :average_unit_price, of: :revenue_cents, over: :units
end
```

```ruby
OrderRevenueRollup.for(store: current_store)
                  .between(1.month.ago, Date.current)
                  .by(:category_id)
                  .revenue_cents
# => { 4 => 182_300, 9 => 55_100, nil => 3_400 }
```

> ### Status
>
> Version 0.0.2, and **in use in two real applications**: a football pool, where
> it agrees with the Ruby implementation it replaced and reads between 6x and 62x
> faster, and a multi-tenant church management API, where its dashboard endpoints
> now read rollups. Everything in 0.0.2 came out of that — including one breaking
> change, so read the CHANGELOG before upgrading.
>
> Still 0.x. The API can still change, and the limitations below are real rather
> than theoretical.

## The problem

Rails gives you an OLTP schema: normalised, row-oriented, indexed for point
lookups. A dashboard asks for the opposite — wide aggregations over many rows,
grouped by several dimensions at once, computed on the fly. In a multi-tenant app
there is one more dimension multiplying everything.

ActiveRecord is not slow. What it does is make it trivial to write a catastrophic
query and impossible to see it until production falls over.

The usual escape routes each fail in a specific way:

| Approach | Why it breaks |
|---|---|
| Materialized views | `REFRESH` recomputes **everything**, always. One tenant's data changes and you pay to recompute all of them: cost scales with total size, not with what changed. Plain `REFRESH` takes an exclusive lock; `CONCURRENTLY` needs a unique index and is slower still. |
| `pg_ivm` | Genuinely incremental, but an extension you usually cannot install on managed Postgres. |
| Fragment or page caching | Key-space explosion. With tenant × dimensions × date range the hit rate collapses, and there is no clean way to know what to invalidate. The deeper mistake is caching the *rendered page* instead of the *aggregate* — aggregates compose, pages do not. |
| Read replicas | Isolate the load. Do not reduce the computation. |
| A separate OLAP store | The right answer at large scale, far too heavy for a mid-size Rails app: a CDC pipeline, a duplicated schema, eventual consistency, another system to operate. |

Grain sits in the gap between "materialized views plus cron" and "a warehouse
with CDC".

## Install

```ruby
# Gemfile
gem "grain"
```

```console
$ bundle install
$ bin/rails generate grain:install
$ bin/rails db:migrate
```

`grain:install` writes the change log table, the trigger function every watched
table shares, an initializer, and `app/rollups/`.

## Getting started

**1. Describe a rollup.**

```console
$ bin/rails generate grain:rollup order_revenue
```

That writes `app/rollups/order_revenue_rollup.rb` with the DSL commented out for
you to fill in.

**2. Build its table.**

```console
$ bin/rails generate grain:table order_revenue
$ bin/rails db:migrate
```

Grain derives the table's shape, its key, and every table that needs a trigger,
from the definition alone. Run this again whenever the definition changes.

**3. Fill it in from the data you already have.**

```console
$ bin/rails grain:backfill ROLLUP=OrderRevenueRollup
```

A new rollup is empty: its triggers only see what happens next. The backfill is
what makes it true about the past.

**4. Keep it fresh.**

```console
$ bin/rails grain:drain
```

Or schedule `Grain::DrainJob`, which does the same thing from ActiveJob:

```yaml
# config/recurring.yml, with Solid Queue
production:
  grain_drain:
    class: Grain::DrainJob
    schedule: every minute
```

Overlapping runs are safe and need no guard: claiming uses `FOR UPDATE SKIP
LOCKED`, so two drains at once split the work rather than repeat it. A slow run
caught by the next tick is not a problem.

**5. Read it.**

```ruby
OrderRevenueRollup.for(store: current_store).by(:product_id).revenue_cents
```

## The DSL

### `fact`

The table whose rows are counted and whose columns the measures read.

```ruby
fact LineItem
fact LineItem, where: { order: { state: "paid" } }
```

`where` takes equality conditions, on the fact's own columns or through one
`belongs_to`. Anything richer belongs in the source data.

### `tenant` — required

The column the rollup is partitioned by. Required, because starting the key with
the most selective column is what keeps reads and recomputes cheap. In practice
every application with this problem has a natural one: an account, a store, a
workspace, an organisation.

```ruby
tenant :store_id, via: { order: :store_id }
```

Reads refuse to run without it. See [Reading](#reading).

### `time` — optional

The bucket rows fall into. Only `grain: :day` in this release.

```ruby
time :ordered_on, via: { order: :placed_on }, grain: :day
```

Leave it out and the rollup becomes a running total per dimension — a counter
cache, except one you can verify instead of one that quietly drifts.

Timestamps are resolved to a calendar day in an explicit zone (`config.time_zone`,
UTC by default). Left to the database session, the same row would land in
different buckets for different callers.

A nullable source column is allowed, and the rows with no timestamp collect in a
null bucket — the bucket of a null is null, so the rollup takes the surrogate key
path like any other nullable dimension. If those rows have no business being in
the aggregate at all, keep them out with the fact's `where:` instead.

### `dimension`

```ruby
dimension :product_id,  via: :product_id                       # a column on the fact
dimension :category_id, via: { product: :category_id }         # one hop
dimension :currency,    via: { order: { store: :currency } }   # two hops
dimension :window_id,   via: { order: :window_id }, immutable: true
```

**Dimensions are resolved by following `belongs_to` associations upward from the
fact, up to three hops.** The restriction is arithmetic, not convenience: through
a `belongs_to` chain each fact row resolves to exactly one value per dimension and
therefore lands in exactly one cell. Cross a `has_many` and one row would land in
several cells at once, silently doubling every count.

`immutable: true` is a promise that the path never changes after the row is
created, and Grain skips watching that table in exchange. Speed for a promise,
stated in the code where anyone can see it.

### `measure`

```ruby
measure :line_count,    count: true
measure :units,         sum: "quantity", type: :bigint
measure :revenue_cents, sum: "quantity * unit_price_cents", type: :bigint
measure :largest_line,  max: "quantity * unit_price_cents", type: :bigint
```

`count`, `sum`, `min` and `max`. Expressions are your own SQL. The fact table is
aliased `f`.

An expression can read columns from a related table by declaring the associations
it needs with `through:`. Joined tables are aliased `g_` plus the path that
reaches them, so the expression stays readable:

```ruby
measure :paid_lines,
        sum: "CASE WHEN g_order.state = 'paid' THEN 1 ELSE 0 END",
        type: :bigint,
        through: :order

measure :local_cents,
        sum: "CASE WHEN g_order_store.currency = 'COP' THEN f.quantity * f.unit_price_cents ELSE 0 END",
        type: :bigint,
        through: { order: :store }
```

Grain watches every table a measure reads, so changing one of those columns
rebuilds the affected cells even though no fact row moved. Those tables log
**every** update rather than a narrowed set, for the same reason the fact table
does: the expression is arbitrary SQL and there is no telling which of its
columns feed the measure. That is a real cost — weigh it before pointing a
measure at a table that is written constantly.

`sum`, `min` and `max` require an explicit `type:`. `count` does not, since
counting rows always yields an integer. The others aggregate arbitrary SQL whose
type cannot be inferred, and guessing would mean silently rounding your own
revenue. One extra word is cheap insurance.

### `ratio`

```ruby
ratio :average_unit_price, of: :revenue_cents, over: :units
```

Stored as its two parts and divided on read, so a rate stays correct at whatever
grain you read it at instead of being frozen at the one it was computed for.
Averaging averages is wrong, and a pre-divided rate cannot be rolled up from a day
to a month.

A ratio over nothing is `nil`, not `0`: there is no rate, which is not the same as
a rate of none.

## Verifying

This is the point of the gem, not a diagnostic bolted on afterwards. Nobody puts
an aggregation layer in front of numbers that matter without a way to prove it
still tells the truth, so the obstacle to clear is never speed — it is doubt.

```ruby
report = OrderRevenueRollup.verify
report.clean?   # => false
puts report
```

```
OrderRevenueRollup: 3 cells disagree (1 wrong, 1 missing, 1 extra)
  extra: store_id=1 ordered_on=2020-01-01 product_id=2
  wrong: store_id=1 ordered_on=2026-08-19 product_id=1 — revenue_cents 999999 should be 1000
  missing: store_id=1 ordered_on=2026-08-19 product_id=2
```

Three kinds, and all three matter:

- **wrong** — both sides have the cell, the numbers differ.
- **missing** — the source has a cell the rollup never got.
- **extra** — the rollup still holds a cell whose last source row went away. This
  is the one a design built on upserts can never find, because there is nothing
  left to upsert against.

Scope it, and repair what it finds:

```ruby
OrderRevenueRollup.verify(tenant: current_store.id)
OrderRevenueRollup.verify(between: 1.week.ago.to_date..Date.current)
OrderRevenueRollup.verify(repair: true)
```

Repair rebuilds all three kinds uniformly, because recomputing a cell already
knows to delete it when the source yields nothing.

```console
$ bin/rails grain:verify                    # exits non-zero if anything disagrees
$ bin/rails grain:verify VERIFY_REPAIR=1
```

The non-zero exit is so this can gate a build. A rollup that quietly disagrees
with its source is worse than one that is obviously broken.

A full verification is an aggregate scan of the source: a maintenance operation,
not something to run per request. Scope it on a large rollup.

## Reading

```ruby
mine = OrderRevenueRollup.for(store: current_store)

mine.revenue_cents                         # => 1400
mine.by(:product_id).revenue_cents         # => { 1 => 900, 2 => 500 }
mine.by(ordered_on: :month).revenue_cents  # => { Sat 01 Aug 2026 => 1000, ... }
mine.between(1.month.ago, Date.current).largest_line
mine.by(:product_id).average_unit_price    # => { 1 => 100.0, 2 => 500.0 }
mine.by(:product_id).rows                  # every measure and ratio at once
mine.by(:product_id).to_h                  # keyed by group
mine.sql                                   # the statement, for when you want to look
```

- **The tenant is required.** A read that does not name one raises
  `Grain::MissingTenantError` rather than totalling every tenant at once. That
  read does not return a wrong number, it returns somebody else's, and nothing
  about the result looks unusual — so it fails instead of warning. Grain has no
  safe default here: it cannot know whose data the caller is entitled to.
- **`for`** filters any dimension. Values may be ids, ActiveRecord objects,
  arrays, or `nil` (which matches a null coordinate). A `nil` *tenant* is refused
  too: no cell can have one, so the read would come back a clean, wrong zero.
- **`between`** takes two dates or a range.
- **`by`** groups. Coarsen the time bucket with `by(ordered_on: :month)` —
  `:day`, `:week`, `:month`, `:quarter`, `:year`.
- Any dimension left out of `by` is aggregated away. That is the property the
  whole design rests on: a day rolls up into a month by addition, so one stored
  grain answers questions at every coarser one.
- Each measure combines by its own kind. Counts and sums add; an extreme collapses
  to the extreme of the extremes, so the largest line in August is August's
  largest line, not the total of every day's largest.
- Narrowing returns a new query, so a base query can be handed around and reused.
- Results come back typed — `Date` and `Integer`, not the driver's strings.

Spanning every tenant is a real thing to want — a platform-wide total, an admin
dashboard — and it is asked for by name:

```ruby
OrderRevenueRollup.across_tenants.by(:product_id).revenue_cents
```

Grepping for `across_tenants` then lists every read that crosses the boundary,
which is not something you can do with an omission.

## Backfilling

```ruby
OrderRevenueRollup.backfill
OrderRevenueRollup.backfill(from: Date.new(2026, 3, 1), pause: 0.2) do |slice, i, total|
  Rails.logger.info("grain: slice #{i}/#{total} #{slice}")
end
```

```console
$ bin/rails grain:backfill ROLLUP=OrderRevenueRollup FROM=2026-03-01 PAUSE=0.2
```

The work is sliced, not batched by row. Rows belonging to one cell are scattered
through the fact table, so a batch of rows would have to add to cells already
written — the delta problem again with none of its safeguards. A slice (one day,
or one tenant for a rollup with no time bucket) is rebuilt whole instead. Three
things follow:

- It is idempotent. Running it twice changes nothing.
- No cell is ever visible holding a partial total.
- It needs no coordination with the worker. Recompute is complete rather than
  incremental, so it cannot be half applied or applied out of order.

Slices are the distinct values that actually have data, not a min-to-max range, so
gaps are skipped. Finding them reads the fact table once, which is the expensive
part of a backfill.

Resuming is manual and deliberate: slices are processed in order and each is
reported, so `FROM=` the last one reported picks up where it stopped. Repeating a
slice is harmless either way.

## How it works

1. **A physical rollup table**, not a materialized view, keyed on
   `(tenant, time bucket, dimensions…)` with the measures pre-aggregated. Reads
   filter on a prefix of that key, and so does every scoped recompute, so both
   ride the primary key index.
2. **One trigger per source table**, never one per rollup: several rollups can
   read the same table and triggers must not multiply with them. A trigger records
   that a row changed and nothing more.
3. **A change log** holding `(source_table, row_id, operation, previous, …)`. The
   `previous` column is why this is not merely a list of ids: without the row as it
   was, the cell it is *leaving* cannot be located, and that cell would keep the
   departed row in its totals forever.
4. **A worker** that claims a batch, works out which cells the changes could have
   touched, and rebuilds them.

**Recomputing a cell is the primitive; it is not a fallback.** A recompute is one
aggregate query scoped to a cell and it is correct no matter what happened, so the
design is built on it rather than on increments. The rule underneath: recomputing a
cell that did not need it is harmless, while missing one that did is the only
unforgivable bug. When in doubt, Grain recomputes.

Claiming and applying happen in one transaction — the log rows are deleted and the
rollups rewritten together, so a crash rolls the deletions back and the work is
simply redone. Claiming uses `FOR UPDATE SKIP LOCKED`, so several workers can drain
one log without waiting on each other or repeating work.

### What the triggers cost

Every write to a watched table inserts a row into the change log. That is the real
price of this approach and it is worth knowing before you adopt it.

Grain narrows the `UPDATE` trigger to the columns that can actually move a row
between cells:

```sql
AFTER INSERT OR UPDATE OF placed_on, state, store_id OR DELETE ON orders
```

The asymmetry is deliberate. Related tables get an exact column list — at each hop
only the foreign key to the next one matters, or the dimension's own column at the
end — while **fact tables log every update**, because measures aggregate arbitrary
SQL and guessing which columns feed them risks missing an update and drifting in
silence. Precise where it can be, conservative where it cannot.

The column list is the union across every rollup that watches a table, so adding
a rollup never narrows a trigger another one depends on.

## Triggers and schema loading

**`schema.rb` cannot represent a function or a trigger.** Rails' schema dumper
knows tables, columns and indexes, and nothing else, so loading a schema creates
every table and silently drops everything that keeps them correct. That is how
test databases are built by default, and what `db:reset` and restoring a dump both
do — leaving a rollup that never updates and a test suite that passes anyway.

Re-attach them after any schema load:

```console
$ bin/rails grain:triggers
```

```ruby
Grain::Installer.install!   # safe to call any number of times
Grain::Installer.installed? # false right after a schema load
```

In a test suite, put it where the database is prepared:

```ruby
# test/test_helper.rb
class ActiveSupport::TestCase
  Grain::Installer.install!
end
```

### Tests that read a rollup have to drain

A page backed by a rollup only shows what the worker has already applied, and in a
test nothing is running one. Any test that writes and then reads a rollup — or
renders something that does — has to drain in between:

```ruby
Prediction.create!(...)
Grain::Worker.drain
get standings_path
```

That includes a test that mutates data *after* its own setup already drained. This
is real friction, and the first thing to check when a test that should show new
numbers shows the old ones.

The other option is `config.active_record.schema_format = :sql`, which dumps
through `pg_dump` and keeps functions and triggers. That is the more thorough fix
and a bigger change to how an application works, so Grain does not assume it.

## Configuration

```ruby
# config/initializers/grain.rb
Grain.configure do |config|
  config.change_log_table = "grain_change_log"  # baked into the trigger function
  config.batch_size = 1_000                     # change log rows claimed per transaction
  config.max_run_seconds = 30                   # how long a drain may run before yielding
  config.queue = :default                       # queue Grain::DrainJob runs on
  config.time_zone = "UTC"                      # the zone day buckets are cut in
  config.logger = Rails.logger
end
```

Changing `change_log_table` after installing needs a new migration: the name is
written into the trigger function.

## Requirements

- Ruby 3.2 or newer
- Rails / ActiveRecord 7.1 or newer — composite primary keys landed there, and
  rollup tables are keyed on one
- PostgreSQL 15 or newer. Earlier versions work only if no dimension resolves to a
  nullable column: a null cannot sit in a primary key, so those rollups fall back
  to a surrogate key plus a unique index with `NULLS NOT DISTINCT`, which is 15+.

## Limitations

Stated plainly, because finding these out later is worse than reading them now.

- **Postgres only.** The triggers, `jsonb_populate_record` and the upsert
  semantics are all Postgres-specific.
- **Additive measures only.** `count`, `sum`, `min`, `max`. No distinct counts and
  no percentiles: neither can be maintained without reading the rest of the cell's
  source rows, which needs sketches (HyperLogLog, t-digest) rather than a column.
- **`belongs_to` chains only**, three hops deep. No `has_many`, no join tables.
  This applies to a measure's `through:` as much as to a dimension's `via:`.
- **Daily grain only.** No hourly buckets yet.
- **One fact per rollup.** No joins between facts, and no rollups built on rollups.
- **No deltas.** The worker recomputes affected cells rather than incrementing
  them. Batching makes this fine in ordinary use — a thousand inserts landing in
  ten cells cost ten recomputes — but a single enormous cell is recomputed in full
  every time it is touched.
- **`pause:` is a fixed wait**, not adaptive throttling on replication lag.
- **Triggers do not survive a `schema.rb` load** and have to be re-attached with
  `rake grain:triggers`. See above; this catches everyone once.
- **A rollup with a broken model reference is skipped with a warning** rather than
  raising, so one bad rollup cannot stop the log from draining. Watch your logs.

## Development

```console
$ bin/setup
$ bundle exec rake        # tests and rubocop
```

Integration tests need a PostgreSQL to talk to and skip themselves when there
isn't one, so the repository stays clonable without it:

```console
$ docker run -d --name grain-pg -e POSTGRES_PASSWORD=grain \
    -e POSTGRES_DB=grain_test -p 5433:5432 postgres:18
$ bundle exec rake
```

Point it elsewhere with `GRAIN_TEST_DATABASE_URL`.

The SQL Grain generates is the product, so the integration tests run the
generators for real, load the files they write, and apply them to a live database.
Asserting on generated strings alone is false confidence: a string can be
syntactically perfect and semantically wrong, and more than one has been.

## Contributing

Bug reports and pull requests are welcome at https://github.com/grainrb/grain.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
