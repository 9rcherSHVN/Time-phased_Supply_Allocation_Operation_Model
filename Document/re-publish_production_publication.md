I’ll check the publication procedure and availability calculation, then walk through how an advance production adjustment becomes the active forecast while Shops continue transacting.

{Reference: Database \ sql scripts\]

The current design handles this as **publishing a new complete forecast version**, not editing the active forecast’s rows in place. The adjusted quantities become available **when publication commits**, even though production occurs in future target weeks.

**1. Prepare the Revised Snapshot**
Suppose Mill A’s active forecast is V1 and it adjusts production for Week 3.

The Mill/import service creates V2 in `ForecastPublication` and loads its `ForecastLine` records. V2 contains the complete declared snapshot: adjusted quantities plus unchanged quantities for other covered products/weeks.

Important rules:
- Quantities are **replacement totals**, not increments. Changing 20 EA to 25 EA means storing 25, not adding another 25.
- Omitted covered combinations mean zero—not “retain V1.”
- The horizon must retain active reservation coverage and include the first unclosed week.
- `Mill.ActiveForecastPublicationId` still points to V1. Shops continue viewing and reserving against V1.

The loader remains an implementation template in the package.

**2. Validate Without Activating**
`ValidateForecastPublication` checks upload completeness, line counts, coverage, products, period alignment, and supported calendar bounds. On success, V2 becomes `Validated`.

V2 is then immutable under the required permissions/procedure controls. Any further correction requires another snapshot version.

An impact report can compare V2 against existing reservations, but it is advisory: Shops may create or release reservations while V2 is being prepared. The current validation procedure does not implement that impact-report workflow.

**3. Activate V2 Atomically**
The Mill calls `PublishForecast`, supplying V2 and the expected active publication identity V1.

Inside one transaction, the procedure:
1. Acquires the exclusive `forecast:mill:<MillId>` guard.
2. Checks that V1 is still active and V2 is validated and belongs to that Mill.
3. Checks horizon and historical-product coverage.
4. Marks V1 `Superseded`, marks V2 `Published`, and changes the Mill pointer to V2.
5. Inserts the publication audit event and commits.

If another publication already replaced V1, this operation returns a conflict rather than overwriting it silently. If activation fails, all activation changes roll back.

Reference: `03_transactions.sql:60`.

**4. Preserve Shop Transactions**
Existing `DemandRequest`, `Reservation`, and `ActualUsage` records are **not copied, deleted, or reset**.

A reservation completed before activation retains its V1 reference. A reservation ordered after activation is checked against V2. The shared Mill guard used by Shop writers coordinates that ordering with publication’s exclusive guard.

Snapshot-based readers continue seeing consistent committed data. Conflicting writes may briefly wait at activation, but they do not wait throughout snapshot loading.

**5. Calculate Availability Against V2**
After commit, the next availability query follows the new pointer and combines V2 supply with **current operational records**. No background balance refresh is required.

For example, assume zero projected opening balance before Week 3 and no actual usage:

| State | W3 forecast / reservations | W3 projected end | W4 forecast / reservations | W4 projected end |
|---|---|---:|---|---:|
| V1 | 20 / 15 | 5 | 10 / 8 | 7 |
| V2: production reduced | 12 / 15 | -3 | 10 / 8 | -1 |

V2 preserves the 15 and 8 EA reservations but exposes deficits. New reservations cannot worsen those deficits. If Week 3 instead increases to 25 EA, projected ending balances become 10 and 12; Week 3 has 10 EA newly reservable, assuming no tighter balance later in the horizon.

Reference: `02_availability.sql:47`.

**6. Distinguish Forecast Changes from Actual Production**
Re-publication immediately changes **projected availability**, not realized production or closed-week carryover. Closed weeks continue using final actual production regardless of forecast revisions.

The live deficit view exposes shortfalls immediately; durable alerts and Shop-screen refresh still require the documented notification implementation.

In short: **prepare separately → validate → switch the active version → query revised supply against unchanged, live Shop records**. No reservation migration is needed, and advance production adjustments do not wait until their target week to affect reservability.

---

The current design uses **10 core tables, 8 views, 1 query function, and 13 stored procedures**. Not all procedures are implemented yet; seven are fail-fast workflow templates.

**Table Entities**
| Table | Role |
|---|---|
| `Mill` | Owns the active forecast-version pointer and accounting dates. |
| `Shop` | Identifies the demand owner. |
| `Product` | Defines product identity and canonical unit. |
| `ForecastPublication` | Stores V1, V2, their coverage, status, and publication metadata. |
| `ForecastLine` | Stores each version’s product/week production quantities. |
| `DemandRequest` | Stores continuing Shop demand against one selected Mill. |
| `Reservation` | Stores week-specific commitments and their lifecycle quantities. |
| `ActualProduction` | Stores final weekly Mill production. |
| `ActualUsage` | Stores reported Shop usage. |
| `BusinessAuditEvent` | Preserves publication and operational history. |

**Publication and Availability Objects**
For the V1-to-V2 use case, these are the principal objects:

| Object | Type | Responsibility |
|---|---|---|
| `LoadForecastSnapshot` | Procedure template | Creates and loads inactive V2 without changing V1. |
| `ValidateForecastPublication` | Reference procedure | Checks completeness and coverage; makes V2 validated. |
| `PublishForecast` | Reference procedure | Atomically switches the active pointer from V1 to V2. |
| `AcquireTransactionLock` | Helper procedure | Coordinates publication with Shop writes. |
| `ReserveSupply` | Reference procedure | Checks current time-phased availability and records a reservation atomically. |
| `GetShopAvailability` | Read procedure | Returns the selected Mill/product timeline. |
| `fnTimePhasedAvailability` | Query function | Calculates projected balances, realized carryover, and downstream-protected reservable quantities. |

The eight supporting views are `vWeekOffsets`, `vActiveForecast`, `vOpenReservations`, `vWeeklyUsage`, `vDemandPosition`, `vShopAvailability`, and `vDeficitExceptions`—**that is seven views, correcting the opening count**.

**Why V2 Balances Are Accurate**
`fnTimePhasedAvailability` reads:

```text
Active publication pointer → V2 forecast quantities
                          + existing actual production/usage
                          + current remaining reservations
                          → weekly projected ending balances
                          → protected reservable quantities
```

There is **no stored balance table to rebuild or synchronize**. After V2 commits, the next query calculates from V2 and the live operational records. Existing reservations remain unchanged.

The remaining five workflow procedures are `CreateDemandRequest`, `EditFutureDemand`, `CancelReservation`, `RecordActualUsage`, and `CloseMillWeek`; `RecommendDeficitPriority` supplies the advisory fallback. Two table-valued input types support forecast and production uploads.

**Correct total: 10 tables, 7 views, 1 function, 13 procedures, and 2 input types.** See the inventory in `README.md`.

One qualification: Shops have no bulk-loading outage, and reads continue through activation. Conflicting writes may briefly serialize at the atomic switch. Independent cutoff expiry and production-grade authorization/notification handling still need implementation.
