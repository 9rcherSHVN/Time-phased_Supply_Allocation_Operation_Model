I’ll use the existing reservation procedure as the anchor and add SQL examples for guarded reads, atomic audit writes, authenticated ownership, and full-payload replay checks, plus a caller-side transient retry example.

[Reference: Database \ SQL scripts]


Added the complete SQL and C# examples in `SHARED_RULES_EXAMPLES.md`. The excerpts below highlight the rules; parameter declarations and supporting checks are in that file.

**1. Lock Before Reading Availability**
Resolve the request’s immutable Mill/product identity first. Then acquire guards and read current availability:

```sql
BEGIN TRANSACTION;

EXEC planning.AcquireTransactionLock @MillResource, 'Shared';
EXEC planning.AcquireTransactionLock @ProductResource, 'Exclusive';

SELECT @PublicationId = PublicationId,
       @Reservable = ReservableQuantity
FROM planning.fnTimePhasedAvailability(@MillId, @ProductId)
WHERE WeekStart = @TargetWeek;

IF @PublicationId IS NULL OR @Quantity > @Reservable
    THROW 51115, 'Insufficient published availability.', 1;
```

The shared Mill guard prevents publication from switching during this transaction. The exclusive product guard prevents competing reservations from taking the same supply.

**2. Authenticated Ownership**
The example uses administratively provisioned per-Shop database users mapped to authenticated login SIDs:

```sql
SELECT @ShopId = Shop.ShopId
FROM planning.Shop AS Shop
JOIN sys.database_principals AS Principal
  ON Principal.name = CONCAT('shop:', Shop.ShopId)
 AND Principal.sid = SUSER_SID(ORIGINAL_LOGIN())
 AND Principal.type IN ('S', 'U');

IF @ShopId IS NULL
    THROW 51103, 'No authenticated Shop mapping.', 1;
```

The subsequent request lookup requires `DemandRequest.ShopId = @ShopId`. A submitted `ShopId` or client-set session context must not grant authority. Shared service logins require a different secured identity-propagation design.

**3. State, Audit, and Full-Payload Idempotency**
The complete procedure builds a canonical payload containing operation version, authenticated Shop, request, target week, and quantity. It stores that payload, its hash, and the original result in `BusinessAuditEvent.Details`.

Before mutation, it serializes the operation key and checks for replay:
- Same complete payload: return the original reservation/result.
- Different payload: reject.
- No committed result: perform the operation.

State and audit share one transaction:

```sql
BEGIN TRY
    BEGIN TRANSACTION;
    -- Acquire guards, check replay, ownership and availability.
    INSERT planning.Reservation (...) VALUES (...);
    INSERT planning.BusinessAuditEvent (...) VALUES (...);
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
```

This is a structural excerpt; the linked example contains executable inserts. If audit insertion fails, reservation insertion rolls back too.

**4. Retry Only Known Transient Failures**
The caller retains the **same OperationId and payload** across bounded retries:

```csharp
catch (SqlException exception) when (
    attempt < maxAttempts &&
    exception.Number is 1205 or 51110)
{
    int delayMs = 100 * (1 << (attempt - 1))
                + Random.Shared.Next(0, 100);
    await Task.Delay(delayMs, cancellationToken);
}
```

`1205` is a deadlock victim; `51110` is explicitly classified lock contention after SQL rollback. **Do not automatically retry `51115` insufficient availability.** Transport failures around commit have an unknown outcome and require reconciliation using the original operation key.

**Verified:** SQL compilation, replay/conflict handling, foreign-owner rejection, insufficiency, and rollback after injected audit failure passed in LocalDB. Least-privilege/concurrent-session tests and the C# retry example remain unverified.

Made changes.
