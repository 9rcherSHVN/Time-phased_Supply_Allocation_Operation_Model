# Technical data and process workflows

These diagrams describe the SQL Server skeleton and the remaining implementation contracts. They are not a claim that all workflows are implemented. Use READ COMMITTED with READ_COMMITTED_SNAPSHOT for writers. A single read statement observes one committed database snapshot. All writes affecting availability must use the same coordination protocol.

## Implementation map

| Workflow | Database entry points | Package status |
| --- | --- | --- |
| Snapshot import | LoadForecastSnapshot | Fail-fast template; import service, permissions and checksum verification required. |
| Snapshot validation and activation | ValidateForecastPublication, PublishForecast | Reference implementations; authorization and full replay payload checks required. |
| Availability | GetShopAvailability, fnTimePhasedAvailability, views | Reference implementations; business calendar and physical inventory limits documented. |
| Reservation | ReserveSupply | Reference implementation; current-week validation, unit rules and authorization required. |
| Demand create/edit/release | CreateDemandRequest, EditFutureDemand, CancelReservation | Fail-fast templates. |
| Actual usage | RecordActualUsage | Fail-fast template. |
| Final production and expiry | CloseMillWeek | Fail-fast template. |
| Priority recommendations | RecommendDeficitPriority | Fail-fast template; advisory only. |
| Durable delivery and case management | Outbox/CDC worker, optional ExceptionCase | Production extensions, not additional objects in the ten-table skeleton. |

## 1. Layered data flow across the ten entities

```mermaid
flowchart TB
    subgraph MasterData[Master data]
        Mill[(Mill)]
        Shop[(Shop)]
        Product[(Product)]
    end
    subgraph Preparation[Layer 1 - isolated forecast preparation]
        Import[Mill import service]
        Publication[(ForecastPublication)]
        Lines[(ForecastLine)]
        Verify[ValidateForecastPublication]
        Activate[PublishForecast]
        Import --> Publication
        Import --> Lines
        Publication --> Verify
        Lines --> Verify
        Verify --> Activate
    end
    subgraph Operations[Layer 2 - operational transactions]
        Request[(DemandRequest)]
        Reservation[(Reservation)]
        Production[(ActualProduction)]
        Usage[(ActualUsage)]
        Audit[(BusinessAuditEvent)]
        Shop --> Request
        Request --> Reservation
        Request --> Usage
        Reservation --> Usage
        Mill --> Production
    end
    subgraph QueryLayer[Layer 3 - authoritative read calculations]
        Active[vActiveForecast]
        Reserved[vOpenReservations]
        Used[vWeeklyUsage]
        Pending[vDemandPosition]
        Balance[fnTimePhasedAvailability]
        Read[GetShopAvailability / vShopAvailability]
        Exceptions[vDeficitExceptions]
    end
    Activate -->|Atomic active publication pointer| Mill
    Activate -->|Publication event| Audit
    Mill --> Active
    Publication --> Active
    Lines --> Balance
    Product -->|Canonical identity and unit| Lines
    Product -->|Source product identity| Request
    Active --> Balance
    Reservation --> Reserved
    Usage --> Used
    Production --> Balance
    Reserved --> Balance
    Used --> Balance
    Request --> Pending
    Reservation --> Pending
    Usage --> Pending
    Balance --> Read
    Read --> Exceptions
    Read -->|Version and read timestamp| Shop
    Pending -->|Pending need is not reserved supply| Shop
    Reservation -->|Transaction event| Audit
    Usage -->|Usage and excess events| Audit
    Production -->|Close event| Audit
```

Arrows indicate dependency or write ownership, not automatic triggers. Audit rows are inserted by the corresponding procedure in the same transaction. Forecast preparation never rebuilds Request, Reservation or ActualUsage. Read calculations are ordinary views/functions: no asynchronous refresh is needed to see committed changes.

## 2. Snapshot loading, validation and activation

```mermaid
flowchart TD
    Start[Authenticated Mill upload] --> Manifest[Check horizon, product coverage, checksum and source row count]
    Manifest --> Loading[Create inactive publication in Loading state]
    Loading --> Load[Load sparse lines under snapshot lock]
    Load --> Complete{Complete payload received?}
    Complete -->|No| Incomplete[Remain Loading; resume or discard inactive upload]
    Complete -->|Yes| SetComplete[Record loaded count and UploadComplete]
    SetComplete --> Validate[ValidateForecastPublication transaction]
    Validate --> Checks{Valid coverage, units, weeks, lines and manifest?}
    Checks -->|No| ValidationRollback[Roll back validation; active forecast unchanged]
    Checks -->|Yes| Freeze[Set Validated and append audit; commit]
    Freeze --> Advisory[Optional impact report using current Shop transactions]
    Advisory --> BeginPublish[Begin PublishForecast transaction]
    BeginPublish --> MillGuard[Acquire exclusive Mill guard]
    MillGuard --> Replay{OperationId already committed?}
    Replay -->|Same operation| ReturnPrior[Return prior outcome without republishing]
    Replay -->|Different operation| Abort[Roll back and return conflict]
    Replay -->|New operation| Recheck{Expected active pointer and coverage checks pass?}
    Recheck -->|No| Abort
    Recheck -->|Yes| Switch[Supersede old version; publish new version; switch Mill pointer; append audit]
    Switch --> Commit[Commit and release guard]
    Commit --> Visible[New queries use new snapshot and current operational records]
    Visible --> Deficit[Deficit view reveals shortages; existing reservations remain intact]
```

Implementation details:

- Loader and validator use `snapshot:<PublicationId>`. They do not acquire the Mill transaction guard during bulk preparation.
- Validation freezes the snapshot; later correction creates another publication. Direct application table writes must be denied so immutable snapshots cannot be edited behind the procedures.
- An impact report is provisional. Reservations may change between validation and activation; the report is not copied into an authoritative balance table.
- PublishForecast takes `forecast:mill:<MillId>` in Exclusive mode, compares ExpectedActivePublicationId, and checks that coverage retains active reservations, historical products and the first unclosed week.
- Negative projected balances caused by lower quantities do NOT prevent publication. Existing reservations remain and the new deficit is displayed.
- Failure in any pointer/status/audit write rolls back the entire activation. No Shop sees a committed pointer referencing a half-activated publication.
- Idempotent replay checks precede pointer comparison so replaying a completed operation does not fail merely because its expected prior pointer is now stale. Production implementation must compare the complete original operation payload.

## 3. Publication versus Shop transaction ordering

```mermaid
sequenceDiagram
    autonumber
    participant Shop as Shop API
    participant Reserve as ReserveSupply
    participant Guard as Transaction-owned locks
    participant Publisher as PublishForecast
    participant DB as SQL Server tables
    participant Reader as Availability reader
    Shop->>Reserve: Request, week, quantity, OperationId
    Reserve->>DB: BEGIN TRANSACTION; resolve immutable source
    Reserve->>Guard: Shared forecast:mill:M
    Guard-->>Reserve: Granted
    Reserve->>Guard: Exclusive balance:M:P
    Guard-->>Reserve: Granted
    Reserve->>DB: Read active V1 and live balances AFTER locks
    Publisher->>Guard: Request Exclusive forecast:mill:M
    Note over Publisher,Guard: Waits for in-flight shared holders; no loading in this window
    Reserve->>DB: Insert reservation referencing V1 and audit
    Reserve->>DB: COMMIT
    Reserve->>Guard: Transaction commit releases both locks
    Guard-->>Publisher: Exclusive Mill guard granted
    Publisher->>DB: Recheck expected V1 and coverage; write V2 pointer, statuses, audit
    Reader->>DB: One RCSI availability SELECT before publisher commit
    DB-->>Reader: V1 plus previously committed reservation
    Publisher->>DB: COMMIT
    Publisher->>Guard: Release Mill guard
    Reader->>DB: Next availability SELECT
    DB-->>Reader: V2 plus preserved reservation; possible deficit
    Shop->>Reserve: Next reservation request
    Reserve->>Guard: Shared Mill then Exclusive product guard
    Reserve->>DB: Recheck availability using V2
```

This is one valid ordering. If publication wins the guard first, reservation waits briefly and then evaluates V2. A competing reservation for the same Mill/product waits for the exclusive product guard and reads the first reservation's committed result afterward. Different products may reserve concurrently under shared Mill guards. Different Mills use separate guards.

Do not use a stale SNAPSHOT transaction for writes. RCSI at READ COMMITTED permits a fresh post-lock statement snapshot. Publication cannot proceed while a Shop writer holds the shared Mill guard. This is short commit coordination, not a guarantee of literally zero waiting. RCSI readers avoid these writer application locks, but schema changes and system/resource failures are outside this availability guarantee.

## 4. Authoritative balance calculation

```mermaid
flowchart TD
    Query[Read selected Mill and product] --> Pointer[Resolve active publication in the same statement]
    Pointer --> Coverage{Product covered and target inside horizon?}
    Coverage -->|No| Unpublished[API reports Not published; no reservation]
    Coverage -->|Yes| Weeks[Generate weekly timeline from AccountingStartWeek through horizon]
    Weeks --> Supply{Week is closed?}
    Supply -->|Yes| Actual[Use final ActualProduction]
    Supply -->|No| Forecast[Use total forecast; omitted covered line is zero]
    Actual --> Basis[Check missing final reports or open-week gaps]
    Forecast --> Basis
    Basis --> Aggregates[Join independently aggregated actual usage and remaining reservations]
    Aggregates --> Delta[Weekly delta = supply - usage - remaining reservations]
    Delta --> Prefix[ProjectedEnd = cumulative delta from zero inception balance]
    Prefix --> Suffix[DownstreamMinimum = minimum ProjectedEnd from target through horizon]
    Suffix --> Trusted{Complete basis and target is open?}
    Trusted -->|No| Block[Reservable zero; expose missing-basis or closed status]
    Trusted -->|Yes| Capacity[Reservable = max of zero and DownstreamMinimum]
    Prefix --> Deficit[ProjectedDeficit = max of zero and negative ProjectedEnd]
    Actual --> Realized[RealizedCarryover = closed production minus closed usage only]
    Capacity --> Output[Return components, balances, active version and read timestamp]
    Block --> Output
    Deficit --> Output
    Realized --> Output
```

For week t: `ProjectedEnd(t) = ProjectedOpening(t) + Supply(t) - Usage(t) - RemainingReservations(t)`. Prefix sums carry positive and negative positions into subsequent weeks. A suffix minimum prevents earlier reservations from consuming carryover already promised later. For example, ending balances `[10, 0]` mean the first week has ZERO new reservable quantity, even though its projected ending position is 10.

Realized carryover is a separate signed CLOSED-week net position, not independent reservable stock and not a physical on-hand measurement. Never add forecast and actual production together. Never insert new usage merely to settle an old deficit: that would count it twice. Missing basis invalidates reservability instead of manufacturing a trustworthy zero supply balance.

The function uses a bounded week generator and inception balance zero. Importing an existing opening position or recording physical receipts requires the extensions described in the developer guide. Decimal aggregates are cast to bounded decimal(28,4) before chained arithmetic to preserve fractional precision.

## 5. Reservation decision and retry paths

```mermaid
flowchart TD
    Request[ReserveSupply call] --> Preconditions[Authorize Shop; validate input, unit, calendar and no ambient transaction]
    Preconditions --> Begin[Begin transaction; resolve request Mill and product]
    Begin --> Locks[Shared Mill guard then Exclusive Mill/product guard]
    Locks --> LockResult{Locks granted?}
    LockResult -->|No| Retry[Roll back; bounded transient retry with same OperationId]
    LockResult -->|Yes| Replay{Committed OperationId exists?}
    Replay -->|Same payload| Prior[Return original reservation; no new write]
    Replay -->|Different payload| Conflict[Roll back; idempotency conflict]
    Replay -->|No| Pending[Read current demand position and cancellation state]
    Pending --> Need{Pending quantity sufficient?}
    Need -->|No| Reject[Roll back; business rejection; demand remains pending]
    Need -->|Yes| Check[Read fnTimePhasedAvailability AFTER locks]
    Check --> Fits{Published reservable quantity sufficient?}
    Fits -->|No| Reject
    Fits -->|Yes| Insert[Insert Reservation and BusinessAuditEvent together]
    Insert --> Commit[Commit; release locks; return IDs]
    Commit --> Refresh[Post-commit notification prompts a fresh availability read]
```

Authorization, canonical-unit scale, complete payload replay comparison and business-current-week checks are required hardening, not fully implemented in the reference procedure. Transient retry does not turn an insufficient-availability rejection into an accepted reservation. A UI-read version is advisory; the server reads and validates the active version under coordination locks.

## 6. Demand edits, reservation release and rebooking

```mermaid
flowchart TD
    Demand[Continuing request with fixed Mill and product] --> NewReservation[Shop chooses published target week]
    NewReservation --> FreshCheck[Fresh ReserveSupply availability check]
    FreshCheck --> Reserved[Week-specific reservation]
    Reserved --> Consume[Actual usage reduces remaining reservation]
    Reserved --> Edit[Future demand reduction or cancellation]
    Edit --> EditGuard[Shared Mill and Exclusive product guards; check rowversion]
    EditGuard --> Release[Update demand and release affected FUTURE reservations atomically]
    Release --> Audit[Append before/after and release audit]
    Reserved --> Close[Week close]
    Close --> Expire[Expire unconsumed quantity and append Red audit]
    Expire --> Pending[Unfulfilled need becomes pending; no supply held]
    Release --> Pending
    Pending --> Decide{Shop still needs units?}
    Decide -->|Yes| NewReservation
    Decide -->|No| CancelDemand[Shop cancels remaining demand]
    Consume --> Outstanding[Actualized units remain immutable]
```

An expired reservation is never revived. Rebooking inserts a new row for a later week against the SAME Mill. Changing DesiredWeek does not silently move existing reservations. Increasing demand adds pending need; it does not automatically reserve supply. Release order among multiple future reservations must be caller-selected or business-approved. Do not infer current-week edit permission from future-request edit permission.

## 7. Actual usage transaction

```mermaid
flowchart TD
    Usage[RecordActualUsage call] --> Guard[Authorize; shared Mill then exclusive product guard]
    Guard --> Replay[Check idempotent replay before mutation]
    Replay --> Valid{Current open week and valid source linkage?}
    Valid -->|No| Rollback[Roll back; review invalid or late report]
    Valid -->|Yes| Applied[Applied quantity = min of reported usage and remaining linked reservation]
    Applied --> Writes[Insert FULL ActualUsage; increment ActualizedQuantity by APPLIED quantity]
    Writes --> Excess{Unreserved usage, excess or resulting deficit?}
    Excess -->|Yes| Red[Append Red audit event; do not reject valid actual usage]
    Excess -->|No| Info[Append normal usage audit]
    Red --> Commit[Commit all changes together]
    Info --> Commit
    Commit --> Views[Next query sees usage and reduced reservation consistently]
```

For a reservation with 8 remaining, reporting 5 usage produces 3 remaining and 5 actual usage: total demand deducted from the projection stays 8. Reporting 10 usage instead produces zero remaining and 10 actual usage, deepening the position by 2. Excess is not forced into ActualizedQuantity beyond ReservedQuantity. The template also permits usage without a reservation, associated with its request, subject to authenticated reporting policy.

## 8. Final production and week close transaction

```mermaid
flowchart TD
    Cutoff[Business cutoff and final Mill report] --> Begin[Begin CloseMillWeek; acquire Exclusive Mill guard]
    Begin --> Replay[Check operation replay and next consecutive week]
    Replay --> Full{Explicit report for every required product, including zero?}
    Full -->|No| Abort[Roll back; leave week unreconciled; missing-report alert]
    Full -->|Yes| Insert[Insert final ActualProduction for all required products]
    Insert --> Expire[Move every remaining reservation quantity for closing week into ExpiredQuantity]
    Expire --> Red[Append Red expiry event per reservation, correlated to close OperationId]
    Red --> Advance[Advance Mill.ClosedThroughWeek and append close audit]
    Advance --> Commit[Commit all production, expiry, pointer and audit changes]
    Commit --> Recalc[Next query uses actual supply for closed week and forecasts for open weeks]
    Recalc --> Balance{Realized net balance negative?}
    Balance -->|Yes| CarryDeficit[Carry deficit forward; later production offsets prior net shortfall first]
    Balance -->|No| CarrySupply[Carry positive balance forward indefinitely]
    CarryDeficit --> ShopView[Expose new projections, deficits and pending demand]
    CarrySupply --> ShopView
```

An in-flight Shop transaction completing before close belongs to the closing week. A usage transaction ordered after close cannot change a final week; reject for review rather than silently reassigning it. Readers see coherent pre-close or post-close data, never actual production with only half the reservations expired. CloseMillWeek remains a template. Net accounting offsets the oldest shortfall, but detailed Shop-specific FIFO settlement requires a separate settlement ledger.

## 9. Exception visibility and advisory priority

```mermaid
flowchart TD
    Commit[Committed forecast or operational change] --> Live[vShopAvailability / vDeficitExceptions]
    Commit --> History[Append-only BusinessAuditEvent history]
    History --> Delivery[Proposed outbox or CDC delivery worker]
    Live --> Shop[Shop sees authoritative deficit and active version]
    Delivery --> Notify[Notify affected Shops and Mill; deduplicate delivery]
    Notify --> Manual[Mill coordinates manual resolution using Shop priorities]
    Manual --> Fallback[Optional RecommendDeficitPriority advisory output]
    Fallback --> Approval[Business review and Shop-confirmed changes]
    Approval --> Actions[Publish more supply or explicitly edit/release commitments]
    Actions --> Commit
```

No priority recommendation mutates reservations automatically. Alert delivery may lag; the live database query must not. Exception acknowledgements/resolution events remain in history after a deficit disappears from the current view. A normalized ExceptionCase or outbox table is an optional production extension beyond the ten entities. Do not use a naive high-water audit identity cursor: identity order is not commit order and can skip late commits.

## Object and implementation references

- [01_entities.sql](01_entities.sql): keys, identities, quantities, pointers and indexes.
- [02_availability.sql](02_availability.sql): view dependencies, prefix/suffix balance windows and presentation.
- [03_transactions.sql](03_transactions.sql): implemented validation, publication and reservation locking paths.
- [04_workflow_templates.sql](04_workflow_templates.sql): fail-fast signatures for the required lifecycle workflows.
- [README.md](README.md): deployment, full procedure contracts, security, operational extensions and release gates.

## Diagram review checks

Every balance write and its audit records commit together. Every writer participates in coordination; direct application DML is denied. Publication switches only a verified immutable version. Availability reads do not depend on alert delivery or cached balances. Expiry releases only outstanding reservation quantity. A supply deficit, pending demand and an expired reservation are separate facts. These diagrams do not replace SQL compilation, authorization tests or two-session concurrency tests.
