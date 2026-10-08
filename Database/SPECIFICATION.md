# Time-phased Mill supply allocation: specification and verification requirements

Version: 1.0. Date: 2026-10-08. Audience: business analysts, solution architects, database developers and testers.

## 1. Purpose, authority and interpretation

This document is the verification baseline for the business operation model and SQL Server database package. Requirements describe intended behavior, not a declaration that the skeleton already implements it. Use this document to find discrepancies in the package, not to redefine the requirement to match existing SQL.

- **Agreed** means a business decision established in the design discussion.
- **Design** means a proposed technical interpretation used by the package; obtain approval where it materially affects business behavior.
- **Open** means a policy or measurable target still requires an owner and decision. Do not silently implement a convenient default.
- **MUST/MUST NOT** express mandatory behavior for the approved scope; **SHOULD** identifies a recommendation; **MAY** identifies an optional extension.
- An implemented reference procedure is not production-approved. Passing smoke tests does not demonstrate multi-session correctness, lifecycle completion or security.

Scope: versioned Mill production forecasts, Mill/product weekly availability, Shop demand requests and reservations, reported actual usage, final weekly production, indefinite carryover, deficits, expiry, audit and Shop visibility. There is no geographic eligibility filter, cross-Mill pooling, cross-Mill request splitting, product substitution, shelf-life rule or finite carryover expiry in this scope. Physical transportation, receipt, warehouse movement and manufacturing-capacity optimization are not modeled.

The original objective to prevent over-consumption is refined by the agreed exception rules: **new scheduled reservations MUST fit published availability; valid actual usage and later supply corrections MAY create a deficit, which MUST be retained and flagged**. Mills may revise future production to accommodate demand; the system does not invent supply or automatically increase forecasts.

## 2. Roles and terminology

| Term or role | Required meaning |
| --- | --- |
| Mill | Source of product supply; owns its forecast versions and final weekly production reports. |
| Shop | Demand owner; chooses one Mill for each request; owns its priorities, reservations and usage reporting. |
| Business resolver | Authorized Mill/Shop/planning personnel handling shortfalls; exact permissions require approval. |
| Product | Stable product identity with canonical unit; availability is not interchangeable across products. |
| Week | Explicit business period; not an ambiguous week number without a year. |
| Forecast | A Mill's commitment or estimate of TOTAL production for a covered product/week; not actual stock received. |
| Demand request | Continuing need with selected Mill, product, quantity and desired time; a pending request alone holds no supply. |
| Reservation / scheduled commitment | Quantity allocated to that request for ONE target week against published availability. |
| Actual usage | Shop-reported used quantity, retained even if recorded supply is insufficient. Not interchangeable with a reservation. |
| Pending demand | Needed quantity not already actualized or actively reserved; can be rebooked manually. |
| Realized net carryover | Final closed-week supply minus actual usage, accumulated through the last closed week. Can be negative. |
| Projected balance | Time-phased net position using forecasts for open weeks and actuals for closed weeks. |
| Deficit | Negative net position representing an unresolved reported usage/supply mismatch; NOT physical negative inventory. |
| Unpublished | A product or week has no active declared forecast coverage; distinct from a covered forecast quantity of zero. |

The phrase "unfilled actual usage" is a business-accounting convention in this model: reported actual usage can exceed recorded realized supply. The outstanding difference is carried as a supply deficit. Do not convert that deficit back into pending demand or insert another usage record when later production offsets it. If the business needs physical delivery/fulfillment status separately from reported usage, add an explicit fulfillment/settlement model and revise request fulfillment calculations.

## 3. Agreed business requirements

| ID | Requirement |
| --- | --- |
| BR-001 | Supply and balance MUST be separated by Mill, product and week. Another Mill/product's surplus MUST NOT offset them. |
| BR-002 | The Shop MUST choose the Mill. One request MUST retain that source; no automatic source selection, rerouting or cross-Mill split. |
| BR-003 | A request MAY be fulfilled over multiple weeks by its selected Mill. Each reservation MUST identify one target week. |
| BR-004 | Mills publish forecasts monthly and normally update weekly, usually at least one week ahead. Publication dates MUST NOT be hardcoded to prohibit an authorized correction. |
| BR-005 | Each publication MUST be a versioned complete snapshot of a Mill's declared product/week horizon, not a delta applied to its prior forecast. |
| BR-006 | Covered but omitted product/week combinations MUST mean zero forecast. Outside declared coverage MUST mean unpublished. |
| BR-007 | Current-week forecasts MUST be reservable from the start of the week, even before actual production is reported. Future forecasts MUST be reservable once published, however far ahead the published horizon allows. |
| BR-008 | New reservations MUST be accepted only when published time-phased availability covers their FULL submitted quantity. Pending demand is not a reservation and does not require available supply. |
| BR-009 | Actual usage MUST be recorded even if it exceeds a reservation or supply. Valid overuse MUST create a visible exception, not be hidden or rejected to make balances look correct. |
| BR-010 | Matching actualization MUST replace reserved quantity with actual usage without deducting both quantities. |
| BR-011 | Cancelling/reducing future demand MUST immediately release the affected active future reservations. Actual usage MUST remain retained. |
| BR-012 | At week close, every remaining unconsumed reservation for that week MUST expire automatically and generate a Red audit flag. |
| BR-013 | Expiry MUST NOT reserve later-week supply or automatically rebook demand. Shops MAY create new later-week reservations for still-needed quantities, subject to a fresh availability check. |
| BR-014 | Carryover MUST reflect supply remaining after actual usage, not after expired reservations. Positive supply carries forward indefinitely without expiry. |
| BR-015 | Negative realized carryover MUST carry forward until settled. Later production MUST offset the oldest deficit first before being available for new commitments. |
| BR-016 | Mills MUST provide final actual production by product each week. Final weekly reports MUST NOT be treated as revisable forecasts. |
| BR-017 | Forecast reductions MUST retain accepted reservations/actual usage and expose any resulting deficit. They MUST NOT silently cancel Shop commitments. |
| BR-018 | Shops MUST retain access to availability and operational transactions during forecast preparation. Publication MUST NOT expose a partial snapshot or impose a bulk-processing outage. |
| BR-019 | Shop-facing values MUST separate realized carryover, forecast-backed reservable quantity, active reservations, pending demand and deficits. |
| BR-020 | Shops MUST set business fulfillment priority. Mill manual resolution uses that priority; system determination is secondary backup, not hidden automatic business authority. |
| BR-021 | Geographic eligibility filtering MUST NOT be added to this approved scope. |

## 4. Data requirements and invariants

These requirements apply through constraints and/or authorized transaction procedures. A foreign key alone is not sufficient for temporal and authorization rules.

| ID | Entity / grain | Required data and invariant |
| --- | --- | --- |
| DATA-001 | Mill / one source | Stable ID/code; accounting start; last closed week; nullable active publication pointer. Pointer MUST reference a publication belonging to that Mill. |
| DATA-002 | Shop / one demand owner | Stable ID/code; authenticated owner mapping. A caller MUST NOT impersonate another Shop. |
| DATA-003 | Product / one product | Stable ID/code and canonical unit. Quantity scale/whole-unit rules MUST be centrally defined and enforced. |
| DATA-004 | ForecastPublication / Mill version | Unique Mill/version; declared horizon; product coverage; loading/validation/published state; completeness count/hash metadata; creator and publication timestamps. |
| DATA-005 | ForecastLine / version-product-week | Unique combination, valid covered product/week, non-negative quantity in canonical units. Lines MUST remain unchanged after validation. |
| DATA-006 | DemandRequest / one Shop need | Shop, fixed Mill/product, current requested quantity, desired week, Shop priority, cancellation state, timestamps and edit concurrency token. |
| DATA-007 | Reservation / request-week allocation | Original quantity, actualized/cancelled/expired quantities, target week, accepted publication reference, operation identity and timestamps. |
| DATA-008 | ActualProduction / Mill-product-week | One final non-negative production amount, reporter and report timestamp. Zero production MUST be explicit when a report is required. |
| DATA-009 | ActualUsage / usage event | Request/source/product/week, full positive actual quantity, optional linked reservation, applied reservation quantity, operation identity and reporter. |
| DATA-010 | BusinessAuditEvent / event | Event type, actor, UTC time, operation correlation, relevant identities/week/quantities, severity and before/after or reason details. MUST be append-only to application users. |
| DATA-011 | Reservation quantity invariant | Remaining = original - actualized - cancelled - expired. Every component MUST be non-negative, and component totals MUST NOT exceed original reserved quantity. |
| DATA-012 | Usage linkage invariant | Linked reservation MUST belong to the same request, Mill and product, and actualization MUST apply only to its target week. Applied quantity MUST NOT exceed usage or remaining reservation. |
| DATA-013 | Source immutability | Editing demand MUST NOT mutate selected Mill/product or transfer reservations. A source change requires a separately approved cancel/new-request workflow. |
| DATA-014 | Precision | Quantities MUST use exact numerics. Floating point, unintended scale loss, silent overflow and silent rounding of disallowed fractions are prohibited. |
| DATA-015 | Time | Period keys MUST be normalized and unambiguous; timestamps MUST be UTC. Business current week/cutoff MUST come from trusted server configuration, not client input. |
| DATA-016 | Finality | No ordinary application workflow may rewrite closed production/usage. A formal amendment workflow would require new specification and auditable accounting. |
| DATA-017 | Aggregation | Production, usage and reservations MUST be aggregated independently before joins to avoid multiplying quantities through join fan-out. |
| DATA-018 | Historical retention | Forecast versions, actuals, reservation outcomes and business events MUST remain traceable. Retention/archival policy MUST preserve accounting and audit integrity. |

Cancelled and expired reservation quantities are lifecycle outcomes, not extra actual usage. DemandRequestedQuantity is the current approved target; preserve original and changed amounts in history. Priority changes must be visible in audit rather than hiding past business decisions.

## 5. Balance specification

### 5.1 Variables and accounting baseline

Fix one Mill m and product p. Let t denote an ordered week, c the final closed week and H the active forecast horizon end. Every term refers only to m and p. No cross-source or cross-product substitution is permitted.

- $F_t$: active published total production forecast.
- $A_t$: final actual production for a closed week.
- $U_t$: sum of FULL reported actual usage for that week.
- $R_t$: sum of remaining active reservation quantities for that week.
- $B_0$: trusted opening signed position at accounting inception.

The skeleton uses $B_0=0$. Existing opening inventory/deficits require an approved opening-position model and migration reconciliation; developers MUST NOT fabricate production or usage to force the initial balance.

### 5.2 Supply basis and projected balances

$$
S_t = \begin{cases} A_t, & t \le c \\ F_t, & t > c \end{cases}
$$

$$
P_t = B_0 + \sum_{k \le t}(S_k-U_k-R_k)
$$

$$
\text{ProjectedOpening}_t=P_t-S_t+U_t+R_t
$$

| ID | Calculation requirement |
| --- | --- |
| CAL-001 | Closed weeks MUST use actual production; open weeks MUST use total forecast. Never add forecast and actual production together. |
| CAL-002 | Timeline calculations MUST include zero-activity intervening weeks. A skipped week MUST NOT lose carryover or conceal a deficit. |
| CAL-003 | Invalid/missing accounting basis MUST NOT be silently treated as confirmed zero supply. Mark affected balances unknown/unreconciled and prohibit reservations relying on them. |
| CAL-004 | Positive and negative projected positions MUST propagate to subsequent weeks. Historical or closed-week inputs MUST NOT be counted twice through an opening balance plus repeated history. |
| CAL-005 | Once closed, R for that week MUST be zero because unresolved reservations were expired; actual usage remains deducted. |

### 5.3 Reservable quantity protects later commitments

For a published open/current/future target week t with a complete trusted basis:

$$
\text{Reservable}_t=\max\left(0,\min_{k=t}^{H}P_k\right)
$$

| ID | Calculation requirement |
| --- | --- |
| CAL-006 | A new reservation q MUST fit both pending request need and time-phased reservable quantity at t. A forecast correction may make existing positions negative; new reservations MUST NOT worsen such protected downstream deficits under the package's conservative policy. |
| CAL-007 | Looking only at the target week's ending balance is insufficient: a reservation reduces balances in every later week through H. Protect the minimum downstream balance, including later accepted reservations. |
| CAL-008 | Supply forecast for a later week MUST NOT satisfy an earlier-week reservation. A reservation outside active declared coverage MUST be rejected as unpublished, not evaluated using the next week's supply. |

CAL-006's conservative zero-availability rule when a downstream deficit exists is a **Design** policy. It may block otherwise-local reservations; a different rule requires business approval and an equally safe allocation model. It does not authorize blocking actual reporting.

### 5.4 Realized carryover and deficit

$$
\text{RealizedCarryover}_c=B_0+\sum_{k \le c}(A_k-U_k)
$$

$$
\text{RealizedDeficit}=\max(0,-\text{RealizedCarryover}_c),\qquad
\text{ProjectedDeficit}_t=\max(0,-P_t)
$$

| ID | Calculation requirement |
| --- | --- |
| CAL-009 | Realized carryover MUST use actual production and actual usage only; reserved, cancelled or expired amounts MUST NOT reduce realized inventory again. |
| CAL-010 | Later production MUST first offset carried deficit. Do not insert extra usage or subtract the same deficit again when settling it. |
| CAL-011 | Net arithmetic proves aggregate deficit offset, not Shop-specific oldest-deficit attribution. If detailed FIFO settlement is required for approval, preserve deficit origins and evidence of oldest-first allocation in a settlement ledger or equivalent audited records. |
| CAL-012 | UsableRealizedCarryover = max(0, realized carryover) is NOT a separate reservable pool to add to the time-phased view. Current-week physical on-hand availability requires receipt/movement data beyond weekly forecasts. |
| CAL-013 | A period whose business cutoff has passed without a final report MUST be shown as unreconciled, even if ClosedThroughWeek has not advanced. Old forecast supply MUST NOT be labeled confirmed realized carryover. Detect this using the trusted calendar plus report/close state. |

### 5.5 Demand and actualization

For a non-cancelled request:

$$
\text{Pending}=\max(0,\text{Requested}-\text{ActualUsage}-\text{RemainingReservations})
$$

Cancelled requests have zero actionable pending demand. Actual usage may exceed the requested target; retain it and display overuse separately. Releasing a reservation makes an uncancelled request's remaining need pending again. A request cancellation is different from a reservation-only cancellation.

For reported usage q linked to remaining reservation r: `Applied = min(q,r)`. Record q as FULL usage, and actualize only Applied. If q=r, the net deduction is unchanged. If q>r, the excess deepens the position and must be flagged. No reservation linkage means Applied = 0.

## 6. Forecast publication requirements

| ID | Requirement |
| --- | --- |
| PUB-001 | Loading MUST create an inactive snapshot under a new publication identity. Shop activity MUST continue against the currently active version throughout loading. |
| PUB-002 | Validation MUST check declared coverage, periods, product/unit identity, unique rows, quantity rules, canonical source completeness and loaded counts. Source hash MUST be verified against the canonical import payload by its owning component. |
| PUB-003 | UploadComplete MUST only be set after verified complete transmission. An interrupted upload MUST NOT become a valid sparse snapshot whose missing rows are misinterpreted as intentional zero. |
| PUB-004 | Validated snapshots MUST be immutable. Validation failure MUST leave the active publication unchanged and preserve evidence of the failure outside rolled-back successful audit writes. |
| PUB-005 | Publication MUST atomically change prior/new lifecycle state, active Mill pointer and its audit event. Failure MUST roll back all activation writes. |
| PUB-006 | Competing publishers MUST check the expected active publication identity; a stale publisher MUST NOT silently overwrite a newer activation. |
| PUB-007 | Validation-time impact reports MUST be advisory because Shop activity continues. Publication MUST use current coverage/transaction checks, not freeze old demand totals. |
| PUB-008 | A quantity reduction MAY make accepted commitments exceed supply. Publish the corrected snapshot, retain commitments and immediately expose the deficit in authoritative reads. |
| PUB-009 | Snapshot activation MUST NOT remove existing reservation coverage or silently discard deficit/actual history. The package retains historical products and first-unclosed-week coverage; alternate withdrawal policy requires approval. |
| PUB-010 | Publication preparation and large balance recomputation MUST NOT run under the activation guard. Keep activation coordination short and measure its contention under load. |

Publication lifecycle: Loading -> Validated -> Published -> Superseded. Loading failures remain inactive; corrections to a validated/published snapshot create a new version. No Failed enum is assumed by the existing schema. Only a committed active pointer selects live supply.

## 7. Operational transaction contracts

### 7.1 Demand creation and future edits

| ID | Requirement |
| --- | --- |
| TXN-001 | CreateDemandRequest MUST validate ownership/source/product/unit/time/priority and record request plus audit atomically. Insufficient supply MUST NOT prevent creating pending demand. |
| TXN-002 | Future edits MUST compare a concurrency token before changing the request; stale edits MUST fail without partially releasing reservations. |
| TXN-003 | Reducing future need MUST atomically update the target and release affected reservations. Cancelling future demand MUST release all affected active future reservations; actuals remain intact. |
| TXN-004 | Increasing demand MUST add pending need, not invent supply or silently reserve. Changing desired week MUST NOT silently move allocations; cancel/rebook them explicitly. |
| TXN-005 | Release ordering among several future reservations MUST be caller-selected or follow a approved business policy. Current-week or already-actualized amounts MUST NOT be changed under assumed future-edit permission. |

### 7.2 Reservation and usage

| ID | Requirement |
| --- | --- |
| TXN-006 | ReserveSupply MUST recheck authoritative availability and remaining need within its write transaction. Client screen values MUST NOT authorize allocation. |
| TXN-007 | Accepted reservation MUST retain the forecast version used, source/request/week identity and original reserved quantity. Insufficiency MUST create no reservation or partial allocation unless the Shop submits a separate smaller quantity. |
| TXN-008 | Usage MUST validate ownership, request/source identity and reservation-week linkage; insert full usage and actualize the applied portion atomically. |
| TXN-009 | Valid excess/unreserved usage MUST be retained and generate an exception. Reporting after a final closed period requires review, not silent assignment to another week. |
| TXN-010 | Every balance-affecting write MUST commit its audit and associated state together; rollback MUST leave neither a phantom audit success nor a partial business change. |

### 7.3 Week close

| ID | Requirement |
| --- | --- |
| TXN-011 | Close MUST verify the trusted business cutoff and next consecutive unclosed week. Skipping weeks or prematurely closing future periods is prohibited. |
| TXN-012 | Mill final reports MUST explicitly include every required product, including zero. Missing rows MUST leave the week unreconciled, not be treated as confirmed zero production. |
| TXN-013 | When final reporting is timely, final production, any remaining-reservation expiry, Red expiry events, closure event and ClosedThroughWeek advance MUST commit atomically. Finalization after prior expiry MUST retain prior expiry events without duplicating them. |
| TXN-014 | Expiry MUST apply only to unconsumed remaining quantity; it MUST NOT release actualized usage or future-week reservations. |
| TXN-015 | Once closed, new writes to that finalized week MUST be rejected/reviewed by ordinary workflows. In-flight writes are ordered before or after close by the coordination protocol. |
| TXN-016 | Expired need MAY be rebooked only by a new Shop reservation with a fresh published-availability check. No rollover allocation or priority-based automatic rebooking is permitted. |
| TXN-017 | Reservation validity MUST end at the business week cutoff independently of final-report arrival. A guarded, idempotent expiry job MUST release remaining quantities and create Red events even when final accounting close cannot yet succeed. Never advance ClosedThroughWeek or fabricate actual production merely to expire reservations. |

## 8. Concurrency, consistency and recovery requirements

| ID | Requirement |
| --- | --- |
| CON-001 | Concurrent reservations MUST NOT claim the same available units, including units carried between different target weeks. Locking only the target week's row is insufficient. |
| CON-002 | Every operational balance writer MUST acquire a shared Mill guard and exclusive Mill/product timeline guard, or a proven equivalent concurrency scheme. |
| CON-003 | Publication and whole-Mill close MUST acquire an exclusive Mill guard. All locks MUST be transaction-owned, acquired consistently, and released on commit/rollback. |
| CON-004 | Availability checks MUST read current committed data AFTER obtaining guards. Writers MUST use READ COMMITTED with RCSI in this implementation; stale SNAPSHOT writer transactions are prohibited. |
| CON-005 | Readers MUST see a consistent old or new complete publication and coherent committed transactions. One RCSI statement is sufficient; multiple related reads require a read-only snapshot transaction or equivalent consistency. |
| CON-006 | All write operations MUST support idempotency: identical committed operation/payload replay returns the original result; key reuse with different payload fails without changing business state. |
| CON-007 | Lock failures/deadlocks MAY use bounded retries after rollback with the same operation identity. Business insufficiency, ownership failures and stale edits MUST NOT be retried as blind transient errors. |
| CON-008 | Pending requests, prior version references and client display timestamps MUST NOT substitute for revalidation under the write protocol. |
| CON-009 | Multi-product transactions MUST acquire product guards in a stable order. No cross-Mill transfer is implied by retry or partial fulfillment. |
| CON-010 | Database correctness MUST NOT depend on timely notifications, in-memory post-commit callbacks or background cache refresh. Any authoritative cache MUST prove matching forecast and operational revisions. |

Short commit serialization is an architectural necessity, not a bulk forecast outage. The requirement for continuous availability means no planned unavailability during preparation/publication and no partial data, not an impossible guarantee of zero latency during every conflict, failure or infrastructure outage. Define measurable latency/availability targets in the decisions register before production sign-off.

## 9. Exceptions, audit, priority and Shop-facing output

| ID | Requirement |
| --- | --- |
| OPS-001 | Distinguish projected over-allocation, realized deficit, excess actual usage, expired reservation, missing final report, unpublished coverage, validation failure and transient contention. Pending demand alone is not over-consumption. |
| OPS-002 | Shop output MUST identify Mill/product/week, active publication/version, supply basis, actual usage, remaining commitments, projected opening/end balance, reservable quantity, realized carryover, deficits, reconciliation status and read timestamp. |
| OPS-003 | Request output MUST show requested, used, remaining reserved, pending and cancelled state separately. Negative position is visible as deficit; display available-to-reserve as zero rather than physical negative stock. |
| OPS-004 | Forecast/operational changes MUST make updated committed availability accessible immediately in authoritative reads. Push/polling refresh SHOULD keep connected clients current; disconnected screens MUST display age/version and writes MUST revalidate. |
| OPS-005 | Red expiry events MUST retain request/reservation/week/quantity identity, actor/service, reason and correlation to close. A disappeared live deficit MUST NOT erase historical events. |
| OPS-006 | Exception acknowledgement and resolution MUST be auditable; derived views alone do not provide case ownership/status. Add case management if operational ownership/status is needed. |
| OPS-007 | Notification delivery SHOULD be durable and idempotent. Identity values MUST NOT be assumed commit ordered when consuming audit events. Use outbox/CDC or a demonstrated no-loss alternative. |
| OPS-008 | Shop-set priorities MUST guide manual resolution. The backup MUST be transparent and business-approved; the current proposed default is advisory recommendations with human-confirmed application. |
| OPS-009 | Priority MUST NOT bypass published availability for a new reservation or silently delete/reduce another Shop's reservation. Ties and application authority require explicit business decisions. |

The proposed priority scale 1 (highest) to 5 (lowest), then target week, request age and stable ID, is a **Design**, not an independently agreed business policy. Automated fallback application is not approved or enabled.

## 10. Security, deployment and operational quality

| ID | Requirement |
| --- | --- |
| NFR-001 | Authenticated identity MUST constrain each operation to its authorized Mill/Shop. Caller-supplied actor/source IDs MUST NOT grant authority. Define approved shared-supply visibility separately from private demand/audit access. |
| NFR-002 | Application principals MUST NOT have direct table DML or unrestricted internal-helper access. Procedure permissions/ownership chains MUST enforce the write protocol and immutable history. |
| NFR-003 | The deployment MUST use GO-aware tooling, target-compatible SQL and ordered migrations. Initial schema scripts MUST NOT be rerun blindly against an existing database. |
| NFR-004 | Input validation MUST reject invalid/null identities, date keys, quantities, coverage and operation IDs with stable diagnosable errors. Scope/unit checks cannot be left only to UI validation. |
| NFR-005 | Backups, restore drills, retention, observability, recovery objectives and fault handling MUST be specified and tested for production. No numeric SLA is invented here. |
| NFR-006 | Timeline/index/query performance and activation/close lock duration MUST be measured at agreed data volumes and concurrency. An unmeasured scan is not proof of continuous availability. |
| NFR-007 | If using the skeleton limits, reject snapshots beyond 520 weeks and accounting timelines beyond 10,000 weeks. Limits are implementation bounds, not business expiry. Extend calendar capacity before supported bounds are reached. |
| NFR-008 | Test fixtures MUST run only in isolated disposable databases. Production deployment MUST exclude smoke-test inserts and fail-fast unfinished workflows. |

## 11. Acceptance scenarios with numeric or observable results

Tests MUST exercise actual database procedures/queries, not only reproduce arithmetic in another language. Save inputs, query results, row changes, audit evidence and isolation/lock behavior. Some scenarios require completed templates; mark them blocked rather than passing by manually updating tables.

| Test | Requirements | Given / operation | Expected result |
| --- | --- | --- | --- |
| AT-001 | BR-001, BR-002, DATA-013 | Mill A has 3 EA and Mill B has 20 EA; submit 4 EA reservation against A. | Reject against A; B supply unchanged; no auto split/reroute. |
| AT-002 | BR-005, BR-006, PUB-002 | Complete sparse snapshot covers P and weeks W1-W3; P/W2 omitted. Ask also for W4 and uncovered Q. | W2 forecast zero; W4/Q unpublished; incomplete upload cannot use omission-as-zero semantics. |
| AT-003 | BR-007, TXN-006 | Current week forecast 10, no usage/reservations and no actual production yet; reserve 6. Also reserve published future supply in a later week. | Accept supported quantities without requiring production to have occurred. |
| AT-004 | CAL-006, CAL-007, CON-001 | W1 supply 10, W2 supply zero; already reserve 10 for W2. Try reserving 1 for W1. | W1 projected end 10 but reservable zero; reject, preserving W2 allocation. |
| AT-005 | BR-003, TXN-007 | Need 18 from one Mill; W1 supply 10, W2 supply 12; Shop reserves 10/W1 then 8/W2. | Same source, two reservations, pending zero; projected ends 0 and 4. |
| AT-006 | BR-010, TXN-008 | Supply 10, reservation 8; report actual usage 5 against it. | Remaining 3, usage 5, projected end remains 2; no double deduction. |
| AT-007 | BR-009, TXN-009 | Supply 10, reservation 8; report usage 11. | Applied 8, full usage 11, remaining zero, projected deficit 1 and Red exception. |
| AT-008 | BR-017, PUB-008 | Published 20, reservations 8+7; publish corrected supply 12. | Both reservations unchanged, deficit 3, new reservations blocked; publish 18 later clears deficit and leaves 3. |
| AT-009 | BR-012, BR-014, TXN-013 | Actual production 10; reserve 8; use 5; close week. | Expire 3 and Red event; realized carryover 5; no automatic later reservation. |
| AT-010 | BR-013, TXN-016 | Following AT-009, next week forecast 4; rebook pending 3. | Fresh later reservation against 9 projected supply; remaining availability 6; old expiry untouched. |
| AT-011 | BR-015, CAL-009, CAL-010 | W1 closes with production 8 and usage 11; W2 production 10. | Carry -3; W2 offsets 3 first and leaves 7 before new usage. No duplicate usage or deficit charge. |
| AT-012 | BR-015, CAL-011 | Outstanding deficit origins 3 in W1 and 2 in W2; subsequent production 4. | Net deficit 1; where attribution required, evidence shows W1 fully settled and 1 of W2 settled. Net arithmetic alone is insufficient evidence of detailed FIFO. |
| AT-013 | BR-011, TXN-003 | Future request 10, reserved 10; reduce request to 6 or cancel fully. | Release 4 on reduction or all 10 on cancellation atomically; history retained; actualized units untouched. |
| AT-014 | TXN-004, DATA-013 | Increase request 6 to 9 or change desired week. | Increase adds pending 3 only; no automatic new/moved reservation; source fixed. |
| AT-015 | PUB-001, BR-018 | Slow staged upload while Shops repeatedly read/reserve the active version. | Shop operations continue against active snapshot; no partial new lines appear. |
| AT-016 | PUB-005, CON-005 | Inject failure between publication status writes and pointer/audit completion. | Whole activation rolls back; readers see only previous active version; no success audit. |
| AT-017 | PUB-006 | Two validated snapshots expect the same prior active pointer; publish both concurrently. | At most one succeeds against that expectation; other returns stale-pointer conflict, no lost update. |
| AT-018 | CON-001, CON-002 | Two sessions each reserve 7 against 10 available for same Mill/product. | At most one succeeds; other sees 3 or fails insufficiency; no 14 allocation. |
| AT-019 | CON-003, CON-004 | Race reservation with publication and separately with close. Test both possible orders. | Reservation checks consistent version ordered before/after publication; close leaves no late mutation/partial expiry. |
| AT-020 | CON-006 | Replay reserve/publish/usage/edit/close with identical OperationId/payload, then reuse key with different payload. | Original result returned once; no duplicate effects; changed payload rejected. |
| AT-021 | CON-007, TXN-010 | Force lock timeout/deadlock or fail between state and audit writes. | Rollback all effects; bounded identical-operation retry only when transient; no ghost success. |
| AT-022 | TXN-011, TXN-012 | Close with missing product report, skipped week, premature date, then valid report including zero. | Invalid close rolls back and flags reconciliation; valid consecutive close succeeds with explicit zeros. |
| AT-023 | DATA-014 | Forecast 0.1234 KG; reserve 0.0234. Also attempt fractional EA under whole-unit rule. | KG projected/reservable result 0.1000 exactly; invalid EA rejected, no silent rounding. |
| AT-024 | DATA-012, NFR-001 | Use wrong-Shop request, foreign-Mill publication or reservation from another request/week. | Reject without mutation; no authorization via submitted IDs. |
| AT-025 | CON-005, OPS-002 | Query during activation/close while other writes commit. | Each response has coherent version, basis and components; no mixed or multiplied rows. |
| AT-026 | PUB-009, CAL-003 | New snapshot removes an actively reserved week/product; or historical report is missing. | Coverage withdrawal rejected; unknown historical basis exposed and no reservation authorized from it. |
| AT-027 | OPS-008, OPS-009 | Priority recommendation under deficit. | Stable business-approved ranking, version/timestamp shown; no reservation mutation or availability override. |
| AT-028 | OPS-005, OPS-007 | Deficit later resolves; restart notifier around commit and retry delivery. | Current flag clears appropriately, historical records remain; no notification loss; duplicate delivery is deduplicated. |
| AT-029 | DATA-018, CAL-003 | Introduce product after earlier weeks already closed. | Historical applicability is explicitly determined; neither missing required reports nor nonexistent earlier production is invented. Document migration/applicability handling. |
| AT-030 | BR-012, CAL-013, TXN-017 | Week cutoff passes while the Mill's final report is missing; repeat expiry job, then receive the final report. | Reservations expire once with Red evidence at cutoff; report remains unreconciled; no fake actuals/premature close; later finalization does not duplicate expiry. |

### 11.1 Original example as a realized-balance fixture

For this test ONLY, assume the original forecast quantities were actually produced; use original Shop quantities as actual usage, opening balance zero, no outstanding reservations at close. W1/W2/W3 identify consecutive weeks.

| Mill/product | W1 supply / usage / ending | W2 supply / usage / ending | W3 supply / usage / ending |
| --- | --- | --- | --- |
| Mill_A/A1 | 10 / 5 / 5 | 30 / 25 / 10 | 35 / 15 / 30 |
| Mill_A/A2 | 20 / 15 / 5 | 10 / 12 / 3 | 15 / 17 / 1 |
| Mill_B/B1 | 20 / 15 / 5 | 30 / 32 / 3 | 25 / 32 / -4 |
| Mill_B/B2 | 10 / 8 / 2 | 15 / 17 / 0 | 20 / 10 / 10 |

Only Mill_B/B1 ends W3 with a realized deficit. Other product/Mill surpluses cannot cancel it. These cumulative results replace a misleading independent-week-only shortage assessment.

## 12. Traceability to the database package

Status meanings: **Reference** = partial executable skeleton, **Template** = error 51999 until implemented, **Gap** = additional hardening/model decision or object required. No status here means production complete.

| Requirement area | Package owner | Current status / verification obligation |
| --- | --- | --- |
| DATA-001 through DATA-010, source identity | 01_entities.sql | Reference: ten tables, composite source keys, audit and exact numerics. Permissions/temporal rules require procedures. |
| DATA-011, DATA-012 | Reservation/ActualUsage constraints and RecordActualUsage | Quantity constraints present; cross-week check and lifecycle writes remain Template. |
| CAL-001 through CAL-010, CAL-012 | 02_availability.sql / fnTimePhasedAvailability | Reference: prefix/suffix windows and basis flags. Validate all arithmetic against an independent oracle. |
| CAL-011 | Settlement attribution | Gap: ten tables provide net position, not detailed Shop-specific FIFO settlement. |
| CAL-013, TXN-017 | Cutoff-aware reconciliation and independent expiry | Gap: current close contract couples expiry to final-report success; implement guarded expiry and ended-unclosed-period status separately. |
| PUB-001 through PUB-004 | LoadForecastSnapshot, ValidateForecastPublication | Loader Template; validation Reference. Source checksum/scale/immutability permissions remain hardening. |
| PUB-005 through PUB-010 | PublishForecast | Reference: exclusive guard, expected pointer, coverage checks, atomic audit. Failure telemetry and complete payload replay remain hardening. |
| TXN-001 through TXN-005 | CreateDemandRequest, EditFutureDemand, CancelReservation | Templates; release ordering policy Open. |
| TXN-006, TXN-007 | ReserveSupply | Reference: guarded check and downstream protection. Trusted current week, unit scale, null input and authorization remain Gap. |
| TXN-008, TXN-009 | RecordActualUsage | Template; closed/late reporting semantics require review. |
| TXN-011 through TXN-016 | CloseMillWeek | Template; time zone/cutoff and required product applicability Open. |
| CON-001 through CON-009 | AcquireTransactionLock and writer procedures | Partial Reference; apply to every finished writer. Multi-session testing NOT yet demonstrated. |
| OPS-001 through OPS-004 | Views and read API | Reference values; API presentation and authorization remain implementation work. |
| OPS-005 through OPS-007 | BusinessAuditEvent and delivery/case extensions | Audit table present; expiry/history writers Template; durable notification/case management Gap. |
| OPS-008, OPS-009 | RecommendDeficitPriority | Template; scale/ties/application authority require approval. |
| NFR-001 through NFR-008 | Deployment/security/operations | Production hardening and measurable operational evidence required. |

Implementation references: [01_entities.sql](01_entities.sql), [02_availability.sql](02_availability.sql), [03_transactions.sql](03_transactions.sql), [04_workflow_templates.sql](04_workflow_templates.sql), [05_smoke_tests.sql](05_smoke_tests.sql), [Validate-Package.ps1](Validate-Package.ps1), [README.md](README.md), and [WORKFLOWS.md](WORKFLOWS.md).

The existing smoke tests cover a subset: publication/reservation replay, downstream protection, fractional balance precision, lowered-forecast deficit preservation and view row count. Structural PowerShell checks are not SQL acceptance tests. Do not claim AT-001 through AT-030 passed because compilation succeeded or a procedure signature exists.

## 13. Decisions and known gaps requiring closure

| Decision | Classification | Required owner/action |
| --- | --- | --- |
| Business calendar: Monday mapping, time zone, close cutoff and late-report handling | Design / Open | Business operations approves; developer implements trusted calendar and boundary tests. |
| Expiry when the final report is late | Agreed expiry timing; implementation Gap | Implement cutoff expiry independently from final accounting closure; revise existing close/read contracts before release. |
| Multiple future reservation release order and current-week edit rights | Open | Shop/business owner chooses affected-row contract; no silent arbitrary release. |
| Priority scale, cross-Shop ties, fallback deadline and applying authority | Design / Open | Business approves; advisory/human-confirmed is recommended initial mode, not automatic reallocation. |
| Detailed oldest-deficit settlement evidence | Agreed FIFO intent; attribution implementation Gap | Architect/business decides if net accounting suffices or adds settlement records for detailed verification. |
| Product introduced after accounting inception and required weekly report set | Open / Gap | Define product applicability/effective start; skeleton may flag nonexistent earlier rows as missing. Do not fabricate backdated final reports. |
| Existing opening inventory/deficit migration | Design / Gap | Approve opening-position extension and reconciliation before migrating a live operation. |
| Physical usable inventory versus forecast-backed commitments | Boundary | Weekly planning net is supported; receipts/movements needed if physical on-hand is required. |
| Historic correction after final report | Out of ordinary scope | Separate approved amendment policy required; do not silently reopen final facts. |
| Horizon/product withdrawal | Design | Current conservative retention safeguards apply; withdrawal needs explicit policy to preserve history and commitments. |
| Capacity limits, read/write latency, refresh interval, availability SLA, RPO/RTO, audit retention | Open | Agree measurable targets and benchmark/failure-test them; do not invent numbers. |
| Idempotency payload persistence, per-owner authorization, outbox/case model | Gap | Finish production hardening; core ten-entity limit must not hide needed supporting objects. |

## 14. Developer verification procedure and release evidence

1. Freeze an approved specification version and record every Open decision with owner/date. Identify approved scope exclusions. A waived requirement needs business approval, not an undocumented code shortcut.
2. Deploy initial scripts into a NEW disposable SQL Server 2019+ database with compatibility level 150 or higher and the intended isolation settings. Use migrations for existing environments; exclude test fixtures from production.
3. Inspect keys/constraints and procedure permissions. Verify wrong-source and direct-DML attempts fail. Compile every object; fail-fast templates count as NOT IMPLEMENTED.
4. Implement lifecycle templates and production hardening. Execute AT-001 through AT-030 with actual procedures, including independent calculation checks and full before/after/audit assertions.
5. Execute two-session/barrier-controlled concurrency tests for both publication/reservation orders, cross-week competition, close races, timeout/deadlock rollback and retry. Save lock/isolation and result evidence; single-session smoke tests cannot satisfy these requirements.
6. Benchmark large horizons and close/publication commit durations under representative concurrency. Record missing-report and delivery-restart tests, backup/restore evidence and approved SLA results.
7. Produce a requirement-by-requirement report: requirement ID, test ID, environment/build, result, evidence location, defect/waiver and approver. Reconcile all affected balance components, not only final availability.
8. Release only when all applicable MUST requirements pass, every required workflow is implemented, unresolved policies affecting behavior are approved, and accepted exceptions are signed off. Compilation plus smoke tests alone MUST NOT be marked production-ready.

Suggested result-record format:

| Requirement ID | Test ID | Build/environment | Pass / Fail / Blocked / Waived | Evidence | Defect/waiver | Reviewer/date |
| --- | --- | --- | --- | --- | --- | --- |
| CON-001 | AT-018 | Fill during execution | Blocked until multi-session test runs | Link to session scripts/results | Fill if applicable | Fill during review |

## 15. Completion statement

The agreed model is supply-constrained when accepting new reservations and exception-tolerant when recording actual facts or forecast revisions. Its essential guarantees are source/product isolation, trustworthy time-phased accounting, explicit lifecycle outcomes, atomic version publication, concurrency-safe writes, continuous committed-data visibility and retained audit history. Developers must verify these guarantees independently of the current skeleton and surface remaining implementation gaps before production approval.
