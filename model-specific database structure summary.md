I’d use a **relational database as the transactional source of truth**, with versioned forecast snapshots, explicit demand and reservation records, and a derived time-phased availability view. The key design goal is to keep these facts distinct:

- What a Mill forecasts
- What a Mill actually produced
- What a Shop needs
- What supply is reserved for a week
- What a Shop actually used
- What supply or deficit carries forward

I would not store one mutable “available quantity” as the business truth. Availability is derived from those records; otherwise forecast corrections, reservation expiry, and actuals can make the number drift from its history.

**Design methodology**

1. **Model business facts and their lifecycles.** Forecast publication, demand request, reservation, actual production, actual usage, cancellation, and expiry are separate concepts with explicit states and timestamps.
2. **Preserve history.** Published forecast versions and operational changes are auditable. Corrections create new versions or adjustment records rather than overwriting the historical facts that decisions used.
3. **Make the Mill/product/week the supply accounting grain.** Supply is not pooled across Mills. A Shop request selects one Mill, and reservations against it cannot silently move to another.
4. **Separate source-of-truth records from projections.** Balances and Shop-facing availability are calculated views of forecasts, actuals, and active commitments. Any cached projection must stay transactionally consistent or clearly not be used to authorize reservations.
5. **Make reservation checks atomic.** A reservation must be validated against the selected Mill’s published time-phased availability at the moment it is accepted. Concurrent Shop requests cannot consume the same availability.
6. **Keep forecast publication off the Shop transaction path.** Load and validate a complete snapshot separately; the active forecast remains visible until an atomic version switch. Shop reads always see one complete published version.

**Proposed logical data model**

| Entity | Purpose and key fields |
|---|---|
| `Mill` | Mill identity and active forecast publication reference. |
| `Shop` | Shop identity. |
| `Product` | Product identity and canonical unit of measure. |
| `ForecastPublication` | Mill, version, covered week range, lifecycle status, published timestamp. Published snapshots are immutable. |
| `ForecastLine` | Publication version, product, week, forecast quantity. Unique by publication/product/week. An omitted line within the declared horizon means zero; a week outside the horizon is not published. |
| `DemandRequest` | Shop, selected Mill, product, requested quantity, desired week or due date, Shop-set priority, status. The selected Mill remains fixed for that request. |
| `Reservation` | Demand request, target week, reserved quantity, created time, active/expired/cancelled status, and forecast version used when accepted. Each reservation applies to one week and one Mill. |
| `ActualProduction` | Mill, product, week, final actual quantity and report timestamp. A completed week uses this instead of its forecast for realized accounting. |
| `ActualUsage` | Shop, Mill, product, week, quantity, and optional linked reservation. Usage is recorded even when it exceeds a reservation. |
| `BusinessAuditEvent` | Append-only record of publication, reservation, edit, actualization, cancellation, expiry, exception, and resolution actions. |

Quantities should use an exact decimal or integer representation appropriate to the product’s unit, not floating point. If unit conversions become necessary, define and validate them centrally; do not compare unlike units in balance calculations.

**Availability and balance design**

For each Mill/product, calculate the projected position week by week:

$$
\text{Projected ending position}_t
=
\text{Projected opening position}_t
+
\text{Published forecast}_t
-
\text{Actual usage}_t
-
\text{Active reservations}_t
$$

That position becomes the next week’s projected opening position. Negative values are carried deficits, not physical negative inventory; future production offsets the oldest deficit first. New reservations are accepted only if the selected Mill’s time-phased available quantity covers them.

For a completed week, realized carryover instead uses final actual production and actual usage. Unused reservations expire and are excluded from that realized calculation. The Shop view should keep distinct values for **realized carryover**, **available to reserve by week**, **active reservations**, **pending demand**, and **deficit**.

**Transaction and publication considerations**

- A reservation transaction reads a consistent published version, checks the time-phased balance, records the reservation and audit event, then returns the updated availability.
- Concurrent reservations for the same Mill/product timeline need serialization or equivalent concurrency control. Since carryover links weeks, locking only a single week’s row may not be sufficient.
- A forecast snapshot is staged and validated without changing the active version. Publication atomically changes the active version; reservations continue against the active snapshot during staging.
- Reservations record the version used for their check. If a new publication reduces supply below existing reservations, those reservations remain, the recalculated position goes negative, and the system raises the agreed exception.
- Cancelling or reducing future demand immediately releases its associated active reservations. Actual usage is retained.
- At week close, expire and audit unused reservation quantities; use the Mill’s final actual production report for realized carryover.

One implementation choice needs special care: whether time-phased balances are calculated directly from indexed source records or maintained as a transactional projection. A projection can make availability reads faster, but it must update consistently with reservation changes and forecast publication. I would first make correctness authoritative in the relational transaction model, then add a projection only if measured read volume requires it.

I have deliberately not selected a specific database product or written DDL yet. Before that, I’d like your review of the methodology and proposed entities, especially whether `DemandRequest` should represent a continuing need with multiple weekly reservations, as assumed here.