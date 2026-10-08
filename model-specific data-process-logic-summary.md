I recommend **immutable forecast snapshots, a small active-version pointer, and availability calculated from live transaction records**. Preparing a forecast must never copy or replace Shop reservations: supply versions change independently; Shop activity continues.

The important distinction is: **snapshot preparation can be slow; activation must be a short transaction**.

**1. Separate the Three Layers**
| Layer | Records involved | Responsibility |
|---|---|---|
| Forecast preparation | `ForecastPublication`, `ForecastLine` | Load and verify a complete, inactive snapshot. |
| Operational transactions | `DemandRequest`, `Reservation`, `ActualProduction`, `ActualUsage` | Record current business activity independently of forecast preparation. |
| Availability presentation | Views combining the above with `Mill`, `Product`, `Shop` | Calculate balances using one consistent active version and current operational records. |

`BusinessAuditEvent` records publication and operational decisions in the same transactions as the changes themselves.

**2. Load and Validate Separately**
A publication moves through **Draft → Loading → Validated → Published → Superseded**. Failed validation leaves it inactive.

The loader creates a `ForecastPublication` and its `ForecastLine` rows using a new publication ID. It does not change `Mill.ActiveForecastPublicationId`.

Validation checks:
- Declared horizon, valid weekly periods, recognized products, canonical units, and non-negative quantities.
- Unique publication/product/week combinations.
- Upload completeness, including expected record counts or a file checksum, so an interrupted upload is not mistaken for intentional zero quantities.
- A coverage declaration identifying which products the snapshot covers; omitted covered product/week combinations mean zero.
- Whether activation would reduce supply below existing commitments. This produces an impact report, **not a publication rejection**, because forecast-induced deficits are allowed.

After validation, freeze the snapshot. Editing it requires another version. Reservations made while it was loading remain in the operational tables; there is nothing to merge into the forecast.

**3. Publish with an Atomic Pointer Switch**
The publication procedure is conceptually:

```sql
PublishForecast(mill_id, publication_id, expected_active_version):
    BEGIN TRANSACTION
    verify publication belongs to mill and is validated and immutable
    verify active version still equals expected_active_version
    mark previous publication superseded
    mark new publication published
    set Mill.ActiveForecastPublicationId = publication_id
    append publication audit event
    COMMIT
```

The expected-version check prevents two publishers from unintentionally overwriting each other’s work. Only the pointer and lifecycle metadata change at activation; loading, bulk validation, and impact-report generation happen beforehand.

Using database snapshot/MVCC reads, a Shop query sees either the old publication or the new publication together with a consistent set of operational records. It never sees half of each.

**4. Build Authoritative Availability Views**
I would start with ordinary views or query functions, not an asynchronously refreshed materialized view:

| Illustrative view | Calculation |
|---|---|
| `vActiveForecast` | Resolve the Mill’s active publication and its covered product/weeks. |
| `vOpenReservations` | Aggregate each reservation’s remaining quantity by Mill/product/week. |
| `vWeeklySupplyDemand` | Join forecast coverage, actual production, actual usage, and open reservations. |
| `vTimePhasedBalance` | Calculate chronological running net balances from an established opening balance. |
| `vShopAvailability` | Present forecast version, projected balance, reservable quantity, realized carryover, and deficit separately. |

For open weeks, supply means the forecast’s **total weekly production**, not forecast plus actual production. Completed weeks use final actual production. Actual usage and remaining reservations are deducted without double-counting actualized reservations.

**An Important Correction to Our Earlier Reservation Rule**
Checking only the requested week’s ending balance is insufficient: an earlier reservation can consume carryover already supporting a later reservation.

Example: Week 1 has 10 EA supply and Week 2 has zero new supply but already reserves those 10 EA. Week 1 has a projected ending balance of 10, yet none is available for another reservation.

Therefore, for a target week $t$, new reservable quantity is bounded by the lowest projected ending balance from $t$ through the published horizon:

$$
\text{Reservable}_t=\max\left(0,\min_{k=t}^{H}\text{ProjectedEndingBalance}_k\right)
$$

If a downstream deficit already exists, this conservative rule prevents a new earlier reservation from worsening it. Whether to permit reservations that worsen existing deficits would require an explicit exception policy; I recommend not permitting them.

**5. Coordinate Shop Writes with Publication**
An illustrative `ReserveSupply` procedure checks the active version, calculates the authoritative time-phased balance, inserts the reservation, and writes its audit event in one transaction.

Reservation writes for the same Mill/product timeline must serialize or use validated optimistic retries. Publication must coordinate with those writes at activation:
- A reservation committed before activation belongs to the old version; the new forecast may legitimately expose its deficit.
- A reservation committed after activation must be checked against the new version.
- A request using a stale screen display is rechecked server-side, never accepted solely from the displayed quantity.

A short publication guard can establish this ordering. It may briefly serialize conflicting commits, but **must not hold locks throughout loading or validation**. Literal zero waiting cannot be guaranteed by a transactional database; the practical guarantee is no forecast-processing outage and short, bounded activation coordination.

**6. Keep Views and Shops Current**
Cancellation, actualization, and expiry update reservation quantities and audit records atomically. Week close finalizes actual production, expires remaining reservations, and advances realized balances consistently. All affected views then reflect the committed records without a refresh job.

After each commit, an event can notify connected Shop screens to reread availability. Notifications improve freshness but are not authoritative: disconnected screens can be stale, so display the version/read timestamp and always revalidate writes.

I would introduce cached balance projections only after measuring performance. If needed, their version and operational revision must match before they authorize reservations; background deficit alerts and priority recommendations may lag briefly, but **the authoritative availability check must not**.