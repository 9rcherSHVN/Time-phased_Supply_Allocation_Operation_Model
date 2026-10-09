# SQL Server planning database skeleton

This package guides implementation; it is not a production-ready database. Target SQL Server 2019+ with compatibility level 150 or higher. Ten business tables are provided. Seven workflow procedures intentionally throw error 51999 until developers implement their contracts below. The validation, publication, reservation, and availability-read procedures contain executable reference logic, subject to integration testing and security completion.

See [WORKFLOWS.md](WORKFLOWS.md) for technical data-flow, transaction-ordering and lifecycle diagrams, including implementation status and failure paths.

Use [SPECIFICATION.md](SPECIFICATION.md) as the requirements and verification baseline: agreed rules, data invariants, balance equations, acceptance scenarios, package traceability and unresolved release decisions.

See [SHARED_RULES_EXAMPLES.md](SHARED_RULES_EXAMPLES.md) for non-deployment SQL/C# examples of guarded reads, authenticated ownership, full-payload replay, atomic state/audit and bounded transient retries.

## Deployment and verification

1. Use a NEW disposable database. These scripts are initial schema scripts, not repeatable migrations. Do not execute them against an existing production schema.
2. Have the DBA enable READ_COMMITTED_SNAPSHOT before connecting application sessions. Use READ COMMITTED for writer procedures. Do not run them under SNAPSHOT isolation: an older transaction snapshot can invalidate a post-lock availability check. Read-only multi-statement screens may use a SNAPSHOT transaction if ALLOW_SNAPSHOT_ISOLATION is enabled separately.
3. Execute 01_entities.sql, 02_availability.sql, 03_transactions.sql, and 04_workflow_templates.sql in order with a GO-aware tool (SSMS or sqlcmd). Procedures must be called without an ambient transaction.
4. Run `powershell -File database/Validate-Package.ps1` for structural and arithmetic checks. It does NOT compile SQL or test the SQL query implementation. Execute 05_smoke_tests.sql only in that NEW empty disposable database; it inserts test fixtures and leaves them in the test database. It is not a deployment migration.
5. Implement the seven templates, authorization, deployment migrations, and integration tests before granting application access. Add CI compilation against the exact SQL Server version, plus two-session concurrency tests.

## Object inventory

Verified against the CREATE declarations in the four deployment scripts: **10 tables, 7 views, 1 inline table-valued function, 12 stored procedures, 2 table-valued input types, 1 schema and 5 explicitly created secondary indexes**. The earlier conversational count of 13 procedures was incorrect. The grouped entries previously shown here included all 12, but did not enumerate them separately.

All names below are in the `planning` schema. Reference means executable skeleton logic, not production-approved. Template means a declared procedure that intentionally throws error 51999 and performs no business workflow. Constraints, primary/unique-key indexes, identity, computed columns and rowversion are table features and are not additional business entities or procedures.

### Tables: 10

Defined in [01_entities.sql](01_entities.sql).

| Table | Grain / implementation responsibility |
| --- | --- |
| Mill | One source; accounting start, last closed week and active publication pointer. |
| Shop | One demand owner; stable business identity. |
| Product | One product; canonical unit and stable identity. |
| ForecastPublication | One Mill/version; coverage, horizon, upload manifest and immutable snapshot lifecycle. |
| ForecastLine | One publication/product/week; non-negative forecast production quantity. |
| DemandRequest | One Shop need assigned to one Mill/product; current target, desired week and priority. |
| Reservation | One week-specific allocation; accepted version and actualized/cancelled/expired quantity components. |
| ActualProduction | One final Mill/product/week report; actual supply and reporting identity. |
| ActualUsage | One usage event; full actual quantity, optional reservation linkage and applied amount. |
| BusinessAuditEvent | One durable business/audit event; identity, correlation, severity and JSON details. |

### Views: 7

Defined in [02_availability.sql](02_availability.sql). These are ordinary views, not indexed/materialized views or asynchronously refreshed balance tables.

| View | Read responsibility |
| --- | --- |
| vWeekOffsets | Generate bounded weekly offsets for the accounting timeline. |
| vActiveForecast | Resolve each Mill's active publication and declared product coverage. |
| vOpenReservations | Aggregate remaining reservations by Mill/product/target week. |
| vWeeklyUsage | Aggregate full reported usage by Mill/product/week. |
| vDemandPosition | Calculate used, reserved, pending and cancellation state per request. |
| vShopAvailability | Expose time-phased components, positive realized carryover, deficit and read timestamp. |
| vDeficitExceptions | Select projected/realized deficits and missing accounting basis from current availability. |

### Query function: 1

| Function | Type / responsibility | Definition |
| --- | --- | --- |
| fnTimePhasedAvailability | Inline table-valued function; cumulative projected balances, closed-week realized carryover and downstream minimum protecting future commitments. | [02_availability.sql](02_availability.sql) |

### Stored procedures: 12

The first five are reference implementations in [03_transactions.sql](03_transactions.sql). The remaining seven are fail-fast templates in [04_workflow_templates.sql](04_workflow_templates.sql).

| Number | Procedure | Status | Responsibility |
| --- | --- | --- | --- |
| 1 | AcquireTransactionLock | Reference helper | Obtain checked transaction-owned SQL Server application locks. |
| 2 | ValidateForecastPublication | Reference | Verify inactive snapshot completeness, coverage and line validity; mark Validated and audit. |
| 3 | PublishForecast | Reference | Guard activation, check expected active version, atomically switch publication state/pointer and audit. |
| 4 | ReserveSupply | Reference | Check request need and authoritative time-phased capacity under guards; create reservation and audit with replay handling. |
| 5 | GetShopAvailability | Reference read | Return selected Mill/product availability with version and read timestamp. |
| 6 | LoadForecastSnapshot | Template | Import a complete inactive forecast snapshot, coverage and verified source manifest. |
| 7 | CreateDemandRequest | Template | Create authenticated Shop demand without automatically reserving supply. |
| 8 | EditFutureDemand | Template | Apply concurrency-checked future edits and release affected reservations atomically. |
| 9 | CancelReservation | Template | Release selected unconsumed future reservation quantity, retaining history. |
| 10 | RecordActualUsage | Template | Record full actual usage and actualize only the applied reservation quantity; flag excess. |
| 11 | CloseMillWeek | Template | Finalize actual production, expire outstanding reservations and advance accounting close with audit. |
| 12 | RecommendDeficitPriority | Template | Return a business-priority-based advisory recommendation; never mutate commitments automatically. |

Reference procedures still require authorization, canonical-unit/current-week validation, full payload idempotency and production concurrency tests. Procedure declaration/compilation does not establish workflow completion.

### Other declared database objects

| Object | Type / responsibility | Definition |
| --- | --- | --- |
| planning | Schema owned by dbo; groups all package objects. | [01_entities.sql](01_entities.sql) |
| ForecastInput | Table-valued input type; unique product/week forecast rows. | [04_workflow_templates.sql](04_workflow_templates.sql) |
| ProductionInput | Table-valued input type; unique product production rows for final reporting. | [04_workflow_templates.sql](04_workflow_templates.sql) |
| IX_Reservation_Timeline | Secondary index on Mill/product/target week; includes remaining quantity and request. | [01_entities.sql](01_entities.sql) |
| IX_Usage_Timeline | Secondary index on Mill/product/week; includes actual quantity. | [01_entities.sql](01_entities.sql) |
| IX_Usage_Request | Secondary index on request; includes actual quantity. | [01_entities.sql](01_entities.sql) |
| IX_Reservation_Request | Secondary index on request; includes remaining quantity. | [01_entities.sql](01_entities.sql) |
| IX_Audit_MillTime | Secondary index supporting Mill event-history queries. | [01_entities.sql](01_entities.sql) |

Table-level integrity features include primary keys, unique identities, foreign keys including Mill-specific publication and request/reservation linkage, check constraints, defaults, identity columns, rowversion edit tokens and the persisted RemainingQuantity computed column. Primary/unique constraints create supporting indexes in addition to the five explicitly named secondary indexes. SQL Server's built-in sys.sp_getapplock is a dependency, not a custom thirteenth procedure.

A JSON integer array on ForecastPublication declares covered products without introducing an eleventh table. If coverage requires independent relational management, add a normalized coverage table explicitly. A complete snapshot may be sparse: omitted combinations INSIDE declared coverage mean zero, while outside its horizon means unpublished.

### Package scripts and documentation

| File | Purpose / deployment status |
| --- | --- |
| [01_entities.sql](01_entities.sql) | Initial schema, ten tables, constraints and indexes; first deployment script. |
| [02_availability.sql](02_availability.sql) | Seven views and one inline query function; second deployment script. |
| [03_transactions.sql](03_transactions.sql) | Five reference procedures; third deployment script. |
| [04_workflow_templates.sql](04_workflow_templates.sql) | Two input types and seven unfinished procedures; fourth deployment script. |
| [05_smoke_tests.sql](05_smoke_tests.sql) | Disposable-database SQL fixtures/assertions; NOT a production migration. |
| [Validate-Package.ps1](Validate-Package.ps1) | Static structure and independent arithmetic checks; does not compile SQL. |
| [SPECIFICATION.md](SPECIFICATION.md) | Numbered requirements, acceptance tests, traceability and release gaps. |
| [WORKFLOWS.md](WORKFLOWS.md) | Nine technical data/process diagrams with transaction boundaries. |
| [SHARED_RULES_EXAMPLES.md](SHARED_RULES_EXAMPLES.md) | Non-deployment SQL and C# examples of guarded reads, ownership, atomic audit, canonical payload replay and selective retries. |
| [model-specific data-process-logic-summary.md](model-specific%20data-process-logic-summary.md) | Supplementary design discussion; illustrative names/states are not authoritative object declarations. |
| [model-specific data-process-logic-summary in SQL.md](model-specific%20data-process-logic-summary%20in%20SQL.md) | Supplementary SQL-oriented discussion; verify examples against deployed scripts. |
| [model-specific database structure summary.md](model-specific%20database%20structure%20summary.md) | Supplementary structural discussion; not an additional deployment script. |
| [README.md](README.md) | Developer inventory, implementation contracts and deployment guide. |

### Required or optional extensions not yet declared

- Independent business-cutoff expiry workflow and scheduler: required by SPECIFICATION TXN-017 when production reporting is late; no separate procedure/job exists yet.
- Authenticated Shop/Mill API, current-week calendar checks, identity mapping and EXECUTE-only permission roles: required production hardening; no application service or security deployment script is supplied.
- Durable notification/outbox/CDC consumer and optional operational exception-case management: described design work, not implemented components.
- Detailed FIFO deficit-settlement attribution, product-effective applicability and existing-opening-position migration: specification gaps requiring approved modeling; not extra hidden tables in this package.
- Applying priority recommendations, automatic fallback deadlines, indexed/materialized balance caches and new migration scripts: not implemented or authorized by the current skeleton.
- No custom triggers, scalar functions, SQL Agent jobs, balance-refresh procedures or custom thirteenth stored procedure are declared.

## Accounting assumptions and rules

- Weeks start Monday; the application computes the business current week from an agreed time zone and cutoff, never from a browser clock. Store timestamps in UTC. Geography filtering is out of scope.
- Accounting begins at zero at Mill.AccountingStartWeek. For existing inventory/deficits, add an explicitly approved Mill/product opening-position object and adjust the function before migration; do not fabricate actual production to import negative inventory. This skeleton assumes inception accounting only.
- Quantities use decimal(19,4), with decimal(38,4) SUM accumulation cast to decimal(28,4) before chained arithmetic to preserve four fractional digits. Aggregated net positions must fit 24 integer digits; overflow is an error, not saturation. EA products require whole-unit validation in write procedures; other units require approved scale validation. Supply is never pooled across Mills. Request Mill and product are immutable.
- RequestedQuantity is the current demand target, not an immutable original amount. Edits record before/after values in audit JSON. Actual overuse can exceed that target; pending quantity floors at zero without rejecting reality.
- ProjectedEnd is the cumulative sum of supply minus actual usage minus remaining reservations. Closed weeks use final production; open weeks use total forecast, NEVER forecast plus actual production. No independent weekly-availability shortcut is safe.
- New reservable quantity at week T is max(0, minimum ProjectedEnd from T through the active horizon). This protects supply already promised later and conservatively blocks new commitments that worsen an existing downstream deficit.
- RealizedCarryover is the sum of CLOSED-week actual production minus CLOSED-week usage. It is a signed net position, not a physical on-hand inventory system. UsableRealizedCarryover is positive net carryover, NOT independently reservable stock. Current-week physical usability cannot be inferred from a forecast or a final weekly report alone. Add receipts/movements if physical on-hand tracking is needed.
- A deficit is counted once in the cumulative balance. Later production offsets it mathematically; do not add another usage event when settling it. Detailed oldest-deficit settlement attribution requires an allocation/settlement ledger extension; these ten tables implement net FIFO offset, not Shop-specific settlement attribution.
- Missing closed-week production or an open-week gap makes the timeline untrusted; reservable quantity becomes zero. Views identify unreconciled basis. Outside-horizon weeks are not emitted: the API must explicitly label requested absent weeks as unpublished, not zero.
- Retain zero-supply historical products in every later coverage manifest. Publication cannot omit weeks/products containing active reservations. This is a conservative horizon-withdrawal safeguard, not a ban on lower quantities.

## Lock and isolation protocol

Use READ COMMITTED with RCSI for writers; reject other isolation levels in the application connection policy and production procedure hardening. Query availability AFTER acquiring coordination locks.

1. Shop balance writes: shared `forecast:mill:<MillId>`, then exclusive `balance:<MillId>:<ProductId>`.
2. Publication and whole-Mill week close: exclusive Mill guard. This drains in-flight Shop writes, blocks no snapshot reads, and excludes new writes only for the short commit window.
3. Snapshot loader/validator: exclusive `snapshot:<PublicationId>` while changing its lines or status. All writes to a validated snapshot are forbidden; publication need not lock immutable lines.
4. Multi-product Shop operations acquire product resources in increasing ProductId order. Avoid cross-Mill transactions; a request uses one Mill.
5. Check every application-lock return value. Use bounded retry only for transient contention/deadlocks; never retry business insufficiency blindly. Always roll back before retrying.

Application locks work only if EVERY writer participates. Deny direct application DML and use stored procedures. Validation does not block Shop transactions. Activation briefly coordinates commits; it cannot promise literally zero wait. One RCSI SELECT joins pointer, forecast, and transactions at one committed statement snapshot. Multiple SELECTs need a read-only snapshot transaction to avoid mixed versions.

## Workflow template contracts

### LoadForecastSnapshot

Validate caller Mill authority and input manifest, reject negative/invalid units and weeks, verify complete transmission and expected source row count, and verify SourceSha256 in the import service over the canonical source payload (the database cannot infer that file hash from normalized rows). Allocate an idempotent operation ID. Insert publication in Loading, insert sparse lines, and set LoadedSourceRows/UploadComplete only after the successful complete upload. Never mark an interrupted upload complete. For large staged batches, use the snapshot lock and a resumable import contract; do not hold the Mill publication guard while loading. Call ValidateForecastPublication separately. Record loader identity and checksum; record a load event. Version allocation must handle concurrent uploads with a unique-key retry. Bound payload and JSON size.

### CreateDemandRequest

Authorize the Shop, validate selected Mill/product, Monday desired week and positive units, and Shop priority 1 (highest) through 5 (lowest). No availability is required merely to record pending demand. Insert request and audit atomically. Idempotent replay returns the prior request only if the full original payload matches. Never auto-reserve or silently split across Mills.

### EditFutureDemand

Acquire the shared Mill and exclusive product guards. Re-read the request; compare ExpectedRowVersion; require an editable future request using the agreed business-week rule. Source Mill/product remain fixed. Preserve actual usage. For a reduction, release enough remaining FUTURE reservations immediately; for cancellation release all future reservations. Require the caller to select affected reservations, or implement a BUSINESS-APPROVED deterministic release order (not chosen here). If remaining current-week reservations cannot fit the edited target, reject or require an explicit current-week policy; do not silently change them. RequestedQuantity must not go below actual usage plus reservations the edit is not authorized to release. Increasing demand adds pending quantity, not reservations. A desired-week change does not silently move reservations; explicitly cancel/rebook. Update target/cancellation/priority and audit old/new values and every release in one transaction. Request cancellation, reservation cancellation, and expiry are different events.

### CancelReservation

Authorize owning Shop, take guards, re-read reservation, and verify requested release is positive and no greater than remaining quantity. Limit to editable future weeks under the approved policy. Increase CancelledQuantity; do not delete the row or change ActualizedQuantity. A reservation-only cancellation leaves demand pending; cancelling the underlying request also marks IsCancelled. Write release quantity, reason and identity in audit. Return prior result on identical retry.

### RecordActualUsage

Authorize Shop; take guards; require the current OPEN week and a valid positive quantity (closed-week amendments are out of scope because final reports are final). Derive Mill/product from the immutable request. If linked, the reservation must belong to that request and target the same week. ReservationAppliedQuantity = min(reported quantity, remaining quantity). Increase ActualizedQuantity by only the applied amount and insert ActualUsage with FULL reported quantity in the same transaction. Excess and unreserved usage are accepted, including usage against cancelled demand if business policy permits reporting reality; flag the exception. Audit excess over reservation and negative balance as Red. Check operation replay payload before changing anything. Never count a deficit settlement as new actual usage.

### CloseMillWeek

Run at the agreed business cutoff; never close a future/current unfinished period. Take exclusive Mill guard and require the next consecutive unclosed week. Establish the product set from retained coverage/history; require an explicit production entry INCLUDING ZERO for each product. Reject missing, duplicate, unexpected and negative entries. Insert final ActualProduction rows, expire all positive remaining reservations for that week, and advance ClosedThroughWeek atomically. Each expired reservation creates a Red audit event with reservation/request IDs, quantity and week; pending demand is not automatically rebooked. Allocate unique child event IDs and correlate them to the parent OperationId in Details. Audit the closure and final deficits. Do not advance the pointer on an incomplete report. Closed production and usage become immutable. Cutoff decides an in-flight transaction: before close can apply to the week, after close is rejected and reviewed, not silently reassigned. Missing-report alarms are external scheduled monitoring events before this operation succeeds. Large Mill closes may require a more granular close-state design; benchmark commit duration.

### RecommendDeficitPriority

Read consistent balance and active commitments; rank by ShopPriority (shared scale), target week, request creation time, and request ID as stable final tie-breaker. Return an ADVISORY allocation recommendation with publication version and generation timestamp. Never mutate commitments. Business owners resolve competing Shop priorities and approve tie-breakers. Applying a recommendation requires a separate authorized workflow that verifies freshness and obtains Shop confirmation for releases. Automatic application is NOT enabled by this skeleton.

## Reference procedure hardening

- Implement per-Shop/per-Mill authorization before exposing any procedure or raw view. Derive identity from authenticated application context, not a user-supplied Actor parameter. ORIGINAL_LOGIN records the database caller, which may be a shared service account, not the human user.
- Enforce the server-established business current week at every reservation/write entry point. The reference ReserveSupply blocks closed and unpublished weeks but does not derive a time-zone-aware current week; add that configured-calendar check before application exposure. Validate non-null parameters and product-specific quantity scale explicitly.
- Forecast and demand updates must use immutable source identity and guarded procedures. Grant application EXECUTE only on approved public procedures, not the internal lock helper; deny direct table DML. Give deployment privileges to a separate role. Do not grant a workflow stub merely because it exists.
- Idempotency keys are globally coordinated in BusinessAuditEvent; the reference reserve/publish procedures check replay identity. Production hardening must retain a canonical payload hash or full original arguments for ALL operations (including expected active version) and compare them on replay. Two concurrent misuses of one key may produce a unique-key error and rollback; map it to a clear client conflict.
- Validation/upload audit events alone are not full exception lifecycle storage. Live vDeficitExceptions has current truth; use BusinessAuditEvent for acknowledgements/resolutions/correlation. If an operational queue needs mutable status, add a normalized ExceptionCase table rather than treating audit JSON as an unlimited transactional subsystem.
- Persist notifications via an outbox in the same transaction, or let a worker consume durable audit IDs with an external cursor and idempotent delivery. Do not push only before commit or rely on in-memory post-commit delivery. SQL identity values are not commit ordered: a cursor that skips low uncommitted IDs can lose events. Use a proper transactional outbox/CDC or overlapping scans plus durable deduplication. Adding a dedicated outbox table is a reasonable production extension beyond the ten core business entities.
- Deficit views are authoritative immediately; impact emails and recommendation generation may run asynchronously. Screens display version/read timestamp and refresh via push/polling; disconnected screens cannot literally stay current. All writes revalidate server-side.
- Audit/publish detail generation must not scan the full horizon under the activation guard. Generated exception alerts should deduplicate by Mill/product/week/version and condition revision. A deficit disappearing from the live view does not delete its history.

## Required integration tests and release gates

1. Deploy SQL batches into a disposable SQL Server database and inspect compilation errors, constraints and plans.
2. Snapshot zero/omission semantics, unpublished horizon, sparse rows, duplicate coverage, checksum/count mismatch, invalid units and partial uploads.
3. Two concurrent reservations compete for the same remaining units: at most one can overtake the available quantity; earlier requests cannot steal carryover supporting later commitments.
4. Stage a slow upload while reading/reserving active supply; no loader lock blocks Shop operations. Race activation against reservation: consistent old/new version and no mixed snapshot.
5. Publication decrease preserves commitments and yields visible deficit; later production first offsets net deficit; unrelated Mills do not offset it.
6. Partial actualization preserves availability for the applied amount; excess usage deepens balance; replay does not duplicate usage/reservations.
7. Cancelling/reducing demand releases future allocations; expiry returns demand to pending with a red event; rebooking passes a fresh check.
8. Week close is consecutive, atomic and immutable; missing product reports block close; zero production is explicit; readers see coherent pre/post-close states.
9. Verify authorization, deadlock/timeout retries, rejected ambient/SNAPSHOT writer transactions, request rowversion conflicts and idempotency conflicts.
10. Benchmark timeline scans and activation/close latency before introducing cached projections. If a cache is introduced, version AND operational revision must be verified before it can authorize a reservation.

## Known limits

Verified on 2026-10-08 in SQL Server LocalDB: all four deployment scripts compiled and 05_smoke_tests.sql passed publication/reservation replay, downstream reservation protection, four-place decimal arithmetic, snapshot reduction/deficit preservation and Shop-view row-count assertions. Structural checks and four independent arithmetic cases also passed. The disposable test database is not part of deployment. Multi-session concurrency, the seven workflow templates, authorization and production load are NOT verified by these tests.

No database runtime or production concurrency guarantee is implied by static package checks. The bounded calendar supports 10,000 weeks from inception and snapshots of at most 520 weeks; validation enforces these limits. Source/product master changes and calendar migration require DBA-owned workflows. Business owners must finalize edit-release ordering, current-week edit permission, cutoff time zone, priority tie-breakers and detailed settlement attribution. No triggers, background-refresh balances or automatic commitment reallocation are included.
