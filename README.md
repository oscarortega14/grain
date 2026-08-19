# Grain

**Incrementally maintained pre-aggregates for Rails dashboards — inside your own Postgres.**

> **Status: 0.0.0, name reservation only.** Nothing works yet. This README describes
> the design being built, not shipped behaviour. Do not install it.

## The problem

Rails gives you an OLTP schema: normalised, row-oriented, indexed for point lookups.
A dashboard asks for the opposite — wide aggregations over many rows, grouped by
several dimensions at once, computed on the fly. In a multi-tenant app there is one
more dimension multiplying everything.

ActiveRecord is not slow. What it does is make it trivial to write a catastrophic
query and impossible to see it until production falls over.

The usual escape routes each fail in a specific way:

| Approach | Why it breaks |
|---|---|
| Materialized views | `REFRESH` recomputes **everything**, always. One tenant's data changes and you pay to recompute all of them. Cost scales with total size, not with what changed. Plain `REFRESH` takes an exclusive lock; `CONCURRENTLY` needs a unique index and is slower still. |
| `pg_ivm` | Incremental, but it is an extension you usually cannot install on managed Postgres. |
| Fragment / page caching | Key-space explosion. With tenant × dimensions × date range, hit rate collapses and there is no clean way to know what to invalidate. The mistake is caching the *rendered page* instead of the *aggregate* — aggregates compose, pages do not. |
| Read replicas | Isolates load. Does not reduce the computation. |
| A separate OLAP store | The right answer at large scale, far too heavy for a mid-size Rails app: CDC pipeline, duplicated schema, eventual consistency, another system to operate. |

Grain sits in the gap between "materialized views plus cron" and "a full warehouse
with CDC".

## The idea

Declare the **grain** of an aggregate once — tenant, time bucket, dimensions — and
Grain maintains it with deltas driven by database triggers, instead of recomputing
on a schedule.

```ruby
# app/rollups/order_revenue_rollup.rb
class OrderRevenueRollup < Grain::Rollup
  fact LineItem, where: { order: { state: "paid" } }

  tenant    :store_id,    via: { order: :store_id }
  time      :ordered_on,  via: { order: :placed_on }, grain: :day
  dimension :product_id,  via: :product_id
  dimension :category_id, via: { product: :category_id }
  dimension :currency,    via: { order: :currency }, immutable: true

  measure :line_count,    count: true
  measure :units,         sum: "quantity"
  measure :revenue_cents, sum: "quantity * unit_price_cents"
  ratio   :average_unit_price, of: :revenue_cents, over: :units
end
```

Dimensions are resolved by following `belongs_to` associations upward from the
fact, so `via` can read a column off the fact table itself, or reach through one
or more associations to find it. Grain derives the rollup table, the resolution
query for a single fact row, and which tables to watch, from that declaration
alone.

```ruby
OrderRevenueRollup.for(store: current_store)
                  .between(1.month.ago, Date.current)
                  .by(:category_id)
                  .revenue_cents
```

`ratio` stores numerator and denominator separately and divides on read. That is not
a convenience — averaging averages is wrong, and a pre-divided rate cannot be rolled
up from day to month.

## How it works

1. **A physical rollup table**, not a materialized view, keyed on
   `(tenant, time_bucket, dimensions)` with the measures pre-aggregated. One table
   per definition, with the tenant as a key column — not a table per tenant.
2. **A change log written by database triggers**, not ActiveRecord callbacks.
   Callbacks miss `update_all`, `insert_all` and every raw SQL write. A trigger
   does not.
3. **An idempotent worker that applies deltas.** One attendance record changes, one
   cell is incremented. The year is not recomputed.
4. **A read path that rolls up further.** Day to week to month is a sum over a
   small, indexed table.
5. **Backfill as a first-class command**, for late-arriving data and for when a
   definition gains a dimension.

## Correctness before speed

`grain verify` recomputes from the source and compares against the rollup, reporting
any disagreement.

This is the point of the project, not a footnote. Nobody puts an aggregation layer in
front of student grades or financial figures without trusting the numbers, so the
obstacle is never performance — it is doubt. Speed is what Grain sells second.

## Scope of the first release

Deliberately narrow. Grain is not trying to be Materialize.

- Additive measures: `count`, `sum`, `min`, `max`
- Daily time grain
- One tenant dimension plus up to three free dimensions
- `ratio` (separate numerator and denominator)
- Triggers, change log, delta worker
- Backfill and `verify`
- Postgres only

Explicitly out of the first release: non-additive measures (distinct counts,
percentiles), rollups built on rollups, sub-daily grains, MySQL, and a web dashboard.

## License

MIT for now — see `LICENSE.txt`. This is provisional and may change to LGPL before
the first usable release.

## Contributing

Bug reports and pull requests are welcome at https://github.com/grainrb/grain.
