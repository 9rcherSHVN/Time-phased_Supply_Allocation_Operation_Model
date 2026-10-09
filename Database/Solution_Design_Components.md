

You’re right. **My previous count was incorrect: the SQL scripts declare 12 stored procedures, not 13.** I verified the declarations and expanded `README.md` to list every component individually.

**Verified Counts**
10 tables, 7 views, 1 query function, 12 procedures, 2 input types, 1 schema, and 5 explicitly created secondary indexes.

**Tables**
All ten are defined in `01_entities.sql`.

| Table | Responsibility |
|---|---|
| `Mill` | Source identity, accounting dates, active forecast pointer. |
| `Shop` | Demand-owner identity. |
| `Product` | Product identity and canonical unit. |
| `ForecastPublication` | Version, horizon, coverage, completeness, publication lifecycle. |
| `ForecastLine` | Forecast quantity per version/product/week. |
| `DemandRequest` | Continuing Shop need assigned to one Mill/product. |
| `Reservation` | Weekly allocation and actualized/cancelled/expired quantities. |
| `ActualProduction` | Final weekly production by Mill/product. |
| `ActualUsage` | Full reported usage and reservation-applied quantity. |
| `BusinessAuditEvent` | Business history, correlation, severity, and event details. |

**Views and Function**
Defined in `02_availability.sql`.

| Object | Responsibility |
|---|---|
| `vWeekOffsets` | Generate weekly timeline offsets. |
| `vActiveForecast` | Resolve active publication and product coverage. |
| `vOpenReservations` | Aggregate remaining reservations. |
| `vWeeklyUsage` | Aggregate actual usage. |
| `vDemandPosition` | Calculate used, reserved, and pending demand. |
| `vShopAvailability` | Present balances, carryover, deficits, and timestamp. |
| `vDeficitExceptions` | Identify deficits and missing accounting basis. |
| `fnTimePhasedAvailability` | Calculate cumulative balances and downstream-protected reservable quantity. |

**Stored Procedures**
The five reference implementations are in `03_transactions.sql`. The seven templates are in `04_workflow_templates.sql`.

| # | Procedure | Status / responsibility |
|---|---|---|
| 1 | `AcquireTransactionLock` | Reference: checked transaction-owned lock helper. |
| 2 | `ValidateForecastPublication` | Reference: validate inactive snapshot. |
| 3 | `PublishForecast` | Reference: atomically activate a validated version. |
| 4 | `ReserveSupply` | Reference: guarded availability check and reservation. |
| 5 | `GetShopAvailability` | Reference: return Mill/product availability. |
| 6 | `LoadForecastSnapshot` | Template: import complete inactive snapshot. |
| 7 | `CreateDemandRequest` | Template: create pending demand. |
| 8 | `EditFutureDemand` | Template: edit demand and release reservations. |
| 9 | `CancelReservation` | Template: release reservation quantity. |
| 10 | `RecordActualUsage` | Template: record usage and actualize reservations. |
| 11 | `CloseMillWeek` | Template: finalize production, expire reservations, close accounting. |
| 12 | `RecommendDeficitPriority` | Template: produce advisory priority recommendations. |

**Other Components**
- Schema: `planning`.
- Input types: `ForecastInput`, `ProductionInput`.
- Secondary indexes: `IX_Reservation_Timeline`, `IX_Usage_Timeline`, `IX_Usage_Request`, `IX_Reservation_Request`, `IX_Audit_MillTime`.
- Table features: primary/foreign/unique keys, checks, defaults, identities, `rowversion`, and persisted `RemainingQuantity`.
- Verification scripts: `05_smoke_tests.sql` and `Validate-Package.ps1`.

There are **no custom triggers, scalar functions, SQL Agent jobs, or balance-refresh procedures**. `sys.sp_getapplock` is a SQL Server dependency, not a custom thirteenth procedure.

Independent cutoff expiry, authorization/calendar hardening, durable notifications, and detailed settlement attribution remain implementation gaps. The inventory check verified all 38 `CREATE` declarations and README links; it does not establish production readiness.

Made changes.

--- 

Below is the expanded implementation guide. **Reference** means executable skeleton logic requiring production hardening; **Template** means the procedure currently throws error `51999`.

Notation: $q$ = submitted quantity; $U$ = actual usage; $R$ = remaining reservations; $P_t$ = projected ending balance; $H$ = published horizon end.

| Stored Procedure | Query Targets / Reads | Writes | Technical Logic and Implementation Instructions |
|---|---|---|---|
| **1. `AcquireTransactionLock`** — Reference | SQL Server application-lock manager through `sys.sp_getapplock`; no business-table query. | Transaction-owned lock only. | Require an active transaction. Accept resource, mode and timeout; check the return code and throw on failure. Shop writers acquire **Shared Mill guard → Exclusive Mill/product guard**. Publication and whole-Mill close acquire an **Exclusive Mill guard**. Locks release at commit/rollback. All writers must participate; the helper cannot protect against unrestricted direct DML. |
| **2. `ValidateForecastPublication`** — Reference | `ForecastPublication`, `ForecastLine`, `Product`, `Mill`; parse declared product coverage with `OPENJSON`. | Change publication from `Loading` to `Validated`; insert `BusinessAuditEvent`. | Acquire the exclusive snapshot guard. Require `UploadComplete=1`; verify **expected source rows = loaded source rows = actual line count**. Check nonempty, unique, recognized product coverage; line dates within horizon and aligned to weeks; calendar bounds and quantity constraints. Missing covered lines mean zero only after verified upload completeness. Commit validation and audit together. Canonical-unit scale and source-checksum verification need additional implementation. The current procedure is not replay-idempotent after validation succeeds. |
| **3. `PublishForecast`** — Reference | `Mill`, candidate `ForecastPublication`, active `Reservation` rows, historical `ActualProduction`/`ActualUsage`, `BusinessAuditEvent`. | Old publication → `Superseded`; candidate → `Published`; update `Mill.ActiveForecastPublicationId`; insert publication audit. | Acquire exclusive Mill guard. Check operation replay, candidate ownership/status, and expected active pointer. Coverage must include the first unclosed week, active reservation weeks/products, and retained historical products. Atomically switch pointer, statuses and audit. **Do not modify reservations or actuals.** Lower quantities may create deficits and are allowed. Do not perform bulk loading or expensive impact calculations inside activation. |
| **4. `ReserveSupply`** — Reference | `DemandRequest`, `vDemandPosition`, `fnTimePhasedAvailability`, existing `Reservation` and audit replay records. | Insert `Reservation` with accepted publication ID; insert audit. | Resolve immutable source, acquire Shared Mill then Exclusive product guard, and reread current need/availability. Require uncancelled demand and $q\le\text{Pending}$. Require $q\le\max(0,\min_{k=t}^{H}P_k)$ for target week $t$. This protects carryover already supporting later commitments. Reject the full operation if insufficient; do not allocate partially or switch Mills. Identical replay returns the original reservation. Add trusted-current-week, authorization, unit-scale and explicit null checks before production use. |
| **5. `GetShopAvailability`** — Reference | `fnTimePhasedAvailability`, which reads active forecast coverage/lines, weekly usage, remaining reservations and final production. | None. | Execute one consistent read statement and order by week. Return active version, supply, usage, reservations, projected opening/end, realized carryover, deficit, reconciliation indicators and timestamp. Projected balance follows $P_t=P_{t-1}+S_t-U_t-R_t$, where $S_t$ is actual production for closed weeks and forecast for open weeks. No background refresh is required. The API must distinguish absent coverage as **unpublished**; richer presentation fields are also available through `vShopAvailability`. |
| **6. `LoadForecastSnapshot`** — Template | `Mill`, `Product`, existing publication/version and operation history; submitted `ForecastInput` and coverage manifest. | Insert `ForecastPublication` and `ForecastLine`; record completeness metadata and load audit. | Authorize the Mill; validate horizon, coverage, quantities and source payload. Create a new inactive version; never update the active version’s lines. Load **replacement production totals**, not adjustment deltas. Verify canonical payload checksum in the import service and reconcile source/loaded counts. Set `UploadComplete` only after successful complete transmission. For resumable batches, use snapshot-scoped coordination and an explicit import state contract. Do not hold the Mill publication guard during bulk loading. Validate separately after loading. |
| **7. `CreateDemandRequest`** — Template | `Shop`, `Mill`, `Product`, operation replay history. | Insert `DemandRequest` and audit. | Validate authenticated Shop ownership, selected Mill/product, positive requested quantity, unit scale, desired week and approved priority. Create continuing demand without checking supply or automatically reserving. Initially, pending equals requested quantity. Mill/product identity remains fixed. Record complete payload/result for idempotent replay; insufficient supply is not a reason to reject pending demand creation. |
| **8. `EditFutureDemand`** — Template | `DemandRequest`, actual usage totals, remaining reservations, rowversion and operation history. | Update request quantity/week/priority/cancellation; increase affected reservation `CancelledQuantity`; insert edit/release audits. | Acquire normal Shop writer guards and compare `ExpectedRowVersion`. For reduction to new target $Q$, required release is $\max(0,U+R-Q)$, limited to eligible future reservations. The target cannot fall below actual usage plus reservations that the edit is not authorized to release. Cancellation releases affected future reservations immediately. Increasing the target adds pending demand only. A desired-week change does not move reservations automatically. Caller-selected or business-approved release ordering is required; commit request and releases together. |
| **9. `CancelReservation`** — Template | Selected `Reservation`, owning `DemandRequest`, trusted business week and operation history. | Increase `CancelledQuantity`; insert release audit. | Authorize the owning Shop and acquire Shared Mill then Exclusive product guard. Require $0<q\le\text{RemainingQuantity}$ and permitted future-week editing. New remaining quantity equals old remaining minus $q$. Preserve original quantity, actualized amount, accepted version and row history. Reservation-only cancellation returns need to pending; it does not cancel the demand request. Do not delete the reservation or release already consumed units. |
| **10. `RecordActualUsage`** — Template | `DemandRequest`, optional linked `Reservation`, Mill close state, trusted calendar, current balances and replay history. | Insert full `ActualUsage`; increase reservation `ActualizedQuantity` by applied amount; insert normal/Red audit. | Acquire Shop writer guards and validate source, ownership and week linkage. For linked reservation remaining amount $r$, calculate $\text{Applied}=\min(q,r)$; otherwise Applied is zero. Insert **full** usage $q$, but actualize only Applied. Matching actualization leaves the combined usage/reservation deduction unchanged; excess deepens the balance. Accept valid excess/unreserved usage and flag it. Ordinary workflows must not rewrite a final closed period. Never record deficit settlement as another usage event. |
| **11. `CloseMillWeek`** — Template | `Mill`, trusted cutoff, declared/historical product applicability, submitted `ProductionInput`, closing-week reservations/usage and replay history. | Insert final `ActualProduction`; expire remaining reservations; advance `ClosedThroughWeek`; insert expiry and closure audits. | Acquire exclusive Mill guard; require the next consecutive closable week and an explicit production row for every required product, including zero. Atomically finalize production, expire outstanding reservations and advance close state. Realized ending position is opening position plus actual production minus actual usage. Each expiry generates a Red event. **Important gap:** reservations must expire at cutoff even if production reporting is late; implement an independent guarded/idempotent expiry workflow. Later finalization must not duplicate those expiries. |
| **12. `RecommendDeficitPriority`** — Template | Current deficit/availability, active reservations, requests and Shop-set priorities. | None for recommendation; an optional recommendation audit is separate from allocation mutation. | Read a consistent version and rank affected commitments using the approved priority scale and tie-breakers. The proposed order is priority, target week, request age, then stable ID. Where quantities are recommended, available supply must account for prior deficits first. Return affected quantities, ranking rationale, publication version and timestamp. **Do not cancel, reallocate or bypass availability automatically.** Applying a recommendation requires authorized, freshness-checked business actions; that application workflow is not currently declared. |

**Shared Implementation Rules**

All business writes must commit their state and audit together, enforce authenticated ownership, and support full-payload idempotency. Writers must read authoritative data **after acquiring coordination locks**. Retry only transient failures after rollback; do not blindly retry insufficient availability.

The reference procedures are in `03_transactions.sql`; template signatures are in `04_workflow_templates.sql`. Use `SPECIFICATION.md` for acceptance criteria and remaining policy decisions.
