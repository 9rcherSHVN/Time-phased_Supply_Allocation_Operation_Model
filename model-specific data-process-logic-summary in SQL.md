I’ll use **SQL Server terminology** for concreteness, with `READ_COMMITTED_SNAPSHOT` enabled. The same patterns can be implemented in other relational databases with equivalent concurrency controls.

The architecture is: **immutable supply versions + independent operational records + authoritative, time-phased availability queries**.

**1. Separate the Three Layers**
| Layer | Tables | Implementation responsibility |
|---|---|---|
| Forecast preparation | `ForecastPublication`, `ForecastLine` | Bulk-load and validate an inactive snapshot. |
| Operational ledger | `DemandRequest`, `Reservation`, `ActualProduction`, `ActualUsage`, `BusinessAuditEvent` | Record business transactions without rebuilding them during publication. |
| Availability | Views/functions joining those tables with `Mill`, `Product`, `Shop` | Resolve the active snapshot and calculate balances consistently. |

Important keys and constraints:
- `Mill.ActiveForecastPublicationId` references the active publication; publication must belong to that Mill.
- `ForecastLine` has a unique key on `(PublicationId, ProductId, WeekStart)`.
- Each request identifies one Shop, Mill, and product. Reservations and usage must preserve that source identity.
- Reservation quantities track original reserved, actualized, cancelled, and expired amounts; their sum cannot exceed the original reservation.
- Excess actual usage is recorded separately from the quantity actualizing a reservation.
- Use exact numeric quantities, foreign keys, unique request/idempotency identifiers, and indexes beginning with `MillId, ProductId, WeekStart`.

**2. Load and Validate Separately**
Create the publication as `Loading`, with its declared horizon and product coverage. Load its lines under the new `PublicationId`; do not update the active pointer.

Use a stored procedure such as `ValidateForecastPublication` to check identity, units, periods, non-negative quantities, duplicates, upload completeness, and coverage. Explicit coverage is essential: missing covered combinations mean zero, whereas weeks outside the horizon are unpublished.

Generate an impact report against current reservations, but do not reject legitimate reductions merely because they create deficits. The report is advisory because Shop activity can change after validation.

Mark the publication `Validated` and immutable. Enforce this through write permissions and procedures, not only application conventions. A revised file creates another publication. Prevent accidental horizon truncation from silently discarding weeks containing active reservations: retain coverage or require an explicit withdrawal policy.

**3. Publish with an Atomic Pointer Switch**
All balance-affecting writes participate in a common transaction protocol. For publication, use a transaction-owned exclusive application lock for that Mill:

```sql
BEGIN TRANSACTION;
-- Acquire exclusive application lock: 'forecast:mill:<MillId>'.
-- Check lock result; roll back on failure.
-- Verify ownership, Validated status, and expected active publication ID.
-- Update prior publication to Superseded and new publication to Published.
-- Update Mill.ActiveForecastPublicationId.
-- Insert BusinessAuditEvent with old/new IDs, actor, and timestamp.
COMMIT;
```

The expected-pointer check prevents lost updates between competing publishers. Loading and validation occur before this transaction; activation changes only metadata and the pointer. Failure rolls everything back, leaving the previous snapshot active.

With snapshot-based reads, Shops continue reading a complete committed version while publication occurs. Do not synchronously rebuild every Shop’s balance inside this short activation transaction.

**4. Build Authoritative Availability Views**
Use views for aggregation and an inline table-valued function for Mill/product/horizon-specific calculations:

| Database object | Purpose |
|---|---|
| `vActiveForecast` | Join the Mill pointer to publication coverage and lines. |
| `vRemainingReservations` | Sum reserved minus actualized, cancelled, and expired quantities. |
| `vWeeklyActuals` | Aggregate production and usage independently before joining, avoiding row multiplication. |
| `fnTimePhasedAvailability` | Construct weekly rows, select the supply basis, and calculate cumulative balances. |
| `vShopAvailability` | Expose balance components, forecast version, reservable quantity, and deficit. |

A calendar table or generated week series ensures zero-supply weeks are included. Use a trusted realized opening balance and a non-overlapping calculation interval; never count historical production or usage again.

For open weeks, supply is the forecast’s **total weekly production**, not forecast plus reported production. Closed weeks use final actual production. Missing final reports must be shown as unreconciled rather than silently interpreted as zero.

The core window calculations are:

```sql
ProjectedEnd = OpeningBalance
             + SUM(Supply - ActualUsage - RemainingReservations)
               OVER (ORDER BY WeekStart ROWS UNBOUNDED PRECEDING);

Reservable = MAX(0, MIN(ProjectedEnd from TargetWeek through HorizonEnd));
```

These are illustrative expressions, not executable SQL syntax. The downstream minimum protects carryover already supporting later reservations. Realized carryover is calculated separately from closed-week production and usage; it excludes reservations. Keep deficit details by originating week if settlement must identify which oldest deficit was cleared.

Read the availability components in **one statement**, or within one snapshot transaction, so the UI does not combine quantities from different database moments.

**5. Coordinate Shop Writes with Publication**
Implement `ReserveSupply` as one transaction with this fixed lock order:

1. Acquire a **shared** transaction-owned application lock on `forecast:mill:<MillId>`.
2. Acquire an **exclusive** transaction-owned lock on `balance:<MillId>:<ProductId>`.
3. Read the current active publication and authoritative availability after acquiring the locks.
4. Validate target week, request balance, and requested quantity against reservable availability.
5. Insert the reservation, its forecast reference, and audit event; commit.

The shared Mill lock allows different products to transact concurrently but coordinates them with publication’s exclusive Mill lock. The product lock serializes changes across its weekly timeline, because carryover connects weeks. All cancellation, actualization, actual-production, and expiry procedures must follow the same protocol; multi-product operations acquire product locks in a consistent order.

A reservation committed before publication remains valid historically, although the revision may expose a deficit. A reservation ordered after publication checks the new snapshot. Lock failures or deadlocks trigger bounded, idempotent retries; insufficient availability returns a business rejection without creating a reservation.

This provides **no long publication-induced outage**, not a guarantee of literally zero transaction waiting. Readers remain available; conflicting commits may briefly serialize. Post-commit notifications refresh Shop screens, but every write is revalidated server-side. An asynchronously refreshed cache must never authorize reservations unless its forecast and operational revisions are verified current.