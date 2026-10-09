# Shared implementation rules: code examples

These examples extend the reservation pattern; they do not replace the existing deployment scripts or silently add a thirteenth deployed procedure. The SQL block defines a demonstration procedure only if explicitly executed in a disposable database after deployment scripts 01-03. The C# block is caller guidance using Microsoft.Data.SqlClient, not a complete application.

## 1. Prerequisites and trust boundary

- Writers use READ COMMITTED with READ_COMMITTED_SNAPSHOT enabled. The example verifies the setting and rejects an ambient transaction or another isolation level. Set application connection policy accordingly.
- This example authenticates a dedicated SQL Server login for each Shop. Its database user must be named `shop:<ShopId>` and mapped to that login SID. Provision this mapping administratively. Shared service logins cannot identify the human Shop using ORIGINAL_LOGIN alone; use an explicitly secured identity propagation/mapping design instead.
- No submitted ShopId, Actor or client-set SESSION_CONTEXT value grants authority. Do not let untrusted clients create mappings, impersonate principals, alter procedures, or write tables.
- Grant clients EXECUTE on the approved public entry point only. Normal same-owner SQL procedure ownership chaining can support access to underlying tables without granting clients DML. Remove access to unprotected legacy write entry points before exposing the example. Sysadmin/db_owner test accounts are not representative least-privilege clients.
- The example uses Monday weeks and an explicitly assumed UTC business calendar. Replace this with the approved server-owned time zone/cutoff calendar for production. EA must be whole units; additional product-unit policies need their own validated scale rules.
- All writers must honor the shared Mill/exclusive product guards. For this example, a global operation-key guard comes FIRST to serialize identical keys even if reused against different resources: Operation -> Mill -> Product. Adopt consistent ordering when adding this pattern to other workflows.

## 2. SQL: ownership, complete payload replay, guarded reads and atomic audit

```sql
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE planning.ReserveSupplyExample
    @DemandRequestId bigint,
    @TargetWeek date,
    @Quantity decimal(19,4),
    @OperationId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT <> 0
        THROW 51100, 'Ambient transactions are not supported.', 1;
    IF NOT EXISTS (SELECT 1 FROM sys.databases
        WHERE database_id = DB_ID() AND is_read_committed_snapshot_on = 1)
        THROW 51100, 'READ_COMMITTED_SNAPSHOT must be enabled.', 1;
    IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_sessions
        WHERE session_id = @@SPID AND transaction_isolation_level = 2)
        THROW 51100, 'Use READ COMMITTED for this writer.', 1;
    IF @DemandRequestId IS NULL OR @TargetWeek IS NULL OR @OperationId IS NULL
        OR @Quantity IS NULL OR @Quantity <= 0
        THROW 51101, 'Invalid reservation arguments.', 1;
    IF DATEDIFF(day, CONVERT(date, '19000101', 112), @TargetWeek) % 7 <> 0
        THROW 51101, 'TargetWeek must be a Monday.', 1;

    DECLARE @ShopId int;
    SELECT @ShopId = Shop.ShopId
    FROM planning.Shop AS Shop
    JOIN sys.database_principals AS Principal
        ON Principal.name = CONCAT('shop:', Shop.ShopId)
        AND Principal.sid = SUSER_SID(ORIGINAL_LOGIN())
        AND Principal.type IN ('S', 'U');
    IF @ShopId IS NULL
        THROW 51103, 'No authenticated Shop mapping.', 1;

    DECLARE @Payload nvarchar(max) = (
        SELECT 'ReserveSupply/v1' AS OperationType, @ShopId AS ShopId,
            @DemandRequestId AS DemandRequestId,
            CONVERT(char(10), @TargetWeek, 23) AS TargetWeek,
            CONVERT(varchar(40), @Quantity) AS Quantity
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );
    DECLARE @PayloadHash varchar(64) = CONVERT(varchar(64),
        HASHBYTES('SHA2_256', CONVERT(varbinary(max), @Payload)), 2);

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @OperationResource nvarchar(255) = CONCAT('operation:', @OperationId);
        DECLARE @LockResult int;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @OperationResource, @LockMode = 'Exclusive',
            @LockOwner = 'Transaction', @LockTimeout = 2000;
        IF @LockResult IN (-1, -3)
            THROW 51110, 'Transient operation lock contention.', 1;
        IF @LockResult < 0
            THROW 51111, 'Operation lock cancelled or invalid.', 1;

        DECLARE @Details nvarchar(max), @SavedPayload nvarchar(max), @SavedHash varchar(64);
        DECLARE @ReservationId bigint, @PublicationId bigint;
        SELECT @Details = Details FROM planning.BusinessAuditEvent
        WHERE OperationId = @OperationId;
        IF @Details IS NOT NULL
        BEGIN
            SELECT @SavedPayload = Payload, @SavedHash = PayloadSha256,
                @ReservationId = ReservationId, @PublicationId = AcceptedPublicationId
            FROM OPENJSON(@Details) WITH (
                Payload nvarchar(max) '$.Payload',
                PayloadSha256 varchar(64) '$.PayloadSha256',
                ReservationId bigint '$.ReservationId',
                AcceptedPublicationId bigint '$.AcceptedPublicationId'
            );
            IF @SavedPayload IS NULL OR @SavedHash IS NULL
                OR @SavedHash <> @PayloadHash
                OR DATALENGTH(@SavedPayload) <> DATALENGTH(@Payload)
                OR @SavedPayload COLLATE Latin1_General_100_BIN2
                    <> @Payload COLLATE Latin1_General_100_BIN2
                OR @ReservationId IS NULL OR @PublicationId IS NULL
                THROW 51104, 'OperationId reused with different payload or result type.', 1;
            COMMIT;
            SELECT @ReservationId AS ReservationId, @PublicationId AS AcceptedPublicationId;
            RETURN;
        END;

        DECLARE @MillId int, @ProductId int;
        SELECT @MillId = MillId, @ProductId = ProductId
        FROM planning.DemandRequest
        WHERE DemandRequestId = @DemandRequestId AND ShopId = @ShopId;
        IF @MillId IS NULL
            THROW 51103, 'Request not found or not owned by authenticated Shop.', 1;

        DECLARE @MillResource nvarchar(255) = CONCAT('forecast:mill:', @MillId);
        DECLARE @ProductResource nvarchar(255) = CONCAT('balance:', @MillId, ':', @ProductId);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @MillResource, @LockMode = 'Shared',
            @LockOwner = 'Transaction', @LockTimeout = 2000;
        IF @LockResult IN (-1, -3)
            THROW 51110, 'Transient Mill lock contention.', 1;
        IF @LockResult < 0
            THROW 51111, 'Mill lock cancelled or invalid.', 1;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @ProductResource, @LockMode = 'Exclusive',
            @LockOwner = 'Transaction', @LockTimeout = 2000;
        IF @LockResult IN (-1, -3)
            THROW 51110, 'Transient product lock contention.', 1;
        IF @LockResult < 0
            THROW 51111, 'Product lock cancelled or invalid.', 1;

        DECLARE @Pending decimal(38,4), @IsCancelled bit;
        SELECT @Pending = PendingQuantity, @IsCancelled = IsCancelled
        FROM planning.vDemandPosition
        WHERE DemandRequestId = @DemandRequestId AND ShopId = @ShopId;
        IF @Pending IS NULL OR @IsCancelled = 1 OR @Quantity > @Pending
            THROW 51114, 'Insufficient pending demand.', 1;

        DECLARE @Today date = CONVERT(date, SYSUTCDATETIME());
        DECLARE @CurrentWeek date = DATEADD(day,
            -(DATEDIFF(day, CONVERT(date, '19000101', 112), @Today) % 7), @Today);
        IF @TargetWeek < @CurrentWeek
            THROW 51101, 'Cannot create a new reservation for a past week.', 1;
        IF EXISTS (SELECT 1 FROM planning.Product
            WHERE ProductId = @ProductId AND CanonicalUnit = 'EA'
            AND @Quantity <> FLOOR(@Quantity))
            THROW 51101, 'EA quantity must be a whole number.', 1;

        DECLARE @Reservable decimal(38,4);
        SELECT @PublicationId = PublicationId, @Reservable = ReservableQuantity
        FROM planning.fnTimePhasedAvailability(@MillId, @ProductId)
        WHERE WeekStart = @TargetWeek;
        IF @PublicationId IS NULL OR @Reservable IS NULL OR @Quantity > @Reservable
            THROW 51115, 'Insufficient published time-phased availability.', 1;

        INSERT planning.Reservation(DemandRequestId, MillId, ProductId, TargetWeek,
            ReservedQuantity, AcceptedPublicationId, OperationId)
        VALUES (@DemandRequestId, @MillId, @ProductId, @TargetWeek,
            @Quantity, @PublicationId, @OperationId);
        SET @ReservationId = CONVERT(bigint, SCOPE_IDENTITY());

        SET @Details = (
            SELECT @Payload AS Payload, @PayloadHash AS PayloadSha256,
                @ReservationId AS ReservationId, @PublicationId AS AcceptedPublicationId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );
        INSERT planning.BusinessAuditEvent(OperationId, EventType, MillId, ProductId,
            DemandRequestId, PublicationId, WeekStart, Actor, Details)
        VALUES (@OperationId, 'SupplyReserved', @MillId, @ProductId,
            @DemandRequestId, @PublicationId, @TargetWeek, ORIGINAL_LOGIN(), @Details);

        COMMIT;
        SELECT @ReservationId AS ReservationId, @PublicationId AS AcceptedPublicationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
```

The first request lookup discovers immutable Mill/product identity, not availability. Authoritative request need and forecast-based capacity are read AFTER the coordination guards. The shared Mill guard prevents an active-pointer switch during the check/write; the exclusive product guard prevents competing allocations across weeks.

The audit contains both canonical original payload and original result. Canonicalization includes operation/schema version, authenticated Shop identity, request, ISO target date and fixed-scale typed quantity. OperationId is the key, not a mutable payload field. Hash plus binary text comparison protects replay against payload differences; it is not an authorization mechanism. Decimal parameters may already have been rounded by a driver/database conversion: validate original client precision before binding, rather than assuming decimal(19,4) can detect discarded digits.

For replay of a committed operation, return its ORIGINAL result before current demand/calendar checks; an old successfully committed reservation should not fail replay because its week has since passed or its remaining quantity changed. Do not return saved responses to a different authenticated owner. Map authenticated principals through provisioning that guarantees one Shop per login; revise the model for users serving multiple Shops.

Audit insertion failure rolls back reservation insertion. A lost response AFTER commit does not roll back the committed operation: replay with the same key returns its saved result. Retain payload/result for at least the approved retry window; archival must preserve replay semantics.

## 3. C#: bounded retry only for classified transient failures

```csharp
using System.Data;
using Microsoft.Data.SqlClient;

public sealed record ReserveCommand(
    long DemandRequestId, DateTime TargetWeek, decimal Quantity, Guid OperationId);

public sealed record ReserveResult(long ReservationId, long AcceptedPublicationId);

public static async Task<ReserveResult> ReserveWithRetryAsync(
    string connectionString, ReserveCommand request, CancellationToken cancellationToken)
{
    const int maxAttempts = 3;
    for (int attempt = 1; ; attempt++)
    {
        try
        {
            using var connection = new SqlConnection(connectionString);
            await connection.OpenAsync(cancellationToken);
            using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "planning.ReserveSupplyExample";
            command.CommandTimeout = 15;
            command.Parameters.Add("@DemandRequestId", SqlDbType.BigInt).Value = request.DemandRequestId;
            command.Parameters.Add("@TargetWeek", SqlDbType.Date).Value = request.TargetWeek.Date;
            var quantity = command.Parameters.Add("@Quantity", SqlDbType.Decimal);
            quantity.Precision = 19;
            quantity.Scale = 4;
            quantity.Value = request.Quantity;
            command.Parameters.Add("@OperationId", SqlDbType.UniqueIdentifier).Value = request.OperationId;

            using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                throw new InvalidOperationException("Missing committed reservation result.");
            return new ReserveResult(reader.GetInt64(0), reader.GetInt64(1));
        }
        catch (SqlException exception) when (
            attempt < maxAttempts && exception.Number is 1205 or 51110)
        {
            int delayMs = 100 * (1 << (attempt - 1)) + Random.Shared.Next(0, 100);
            await Task.Delay(delayMs, cancellationToken);
        }
    }
}
```

This is a method/type excerpt for a static service class in .NET 6+ with Microsoft.Data.SqlClient installed. Construct the ReserveCommand and its OperationId once before the retry loop; do not generate a new ID per attempt. The SQL CATCH rolls back the transaction before returning the classified error; disposing the connection prevents carrying session/transaction state into a retry. Do not use an ambient TransactionScope or layer another automatic retry policy around this loop.

| Error | Meaning / caller action |
| --- | --- |
| 1205 | SQL Server deadlock victim; transaction rolled back; bounded retry allowed. |
| 51110 | Explicitly classified application-lock timeout/deadlock; SQL rollback completed; bounded retry allowed. |
| 51115 | Insufficient published availability; NO automatic retry. Return a business outcome and refresh the screen. |
| 51114 | Insufficient remaining request need; NO automatic retry. |
| 51103 | Ownership/mapping failure; NO automatic retry. |
| 51104 | Operation key reused with different payload; NO automatic retry. |
| 51111 | Cancelled/invalid application-lock request; do not blindly retry. |
| -2 / transport disconnect | Outcome may be UNKNOWN, especially around COMMIT. Not handled by this narrow retry policy; reconcile using the original OperationId before deciding what to do. Never assume rollback or issue a new key. |
| 51001 from original helper | Aggregates different negative lock results; do NOT classify all of them transient. Extend that helper's error taxonomy before adopting retries. |

Network uncertainty differs from a known rolled-back transient failure. A dedicated operation-status API or authenticated identical replay can resolve whether the operation committed. If there is no saved result, ensure the original in-flight operation has completed or serialize recovery through its operation guard before resubmitting. Cancellation does not prove that COMMIT did not happen.

## 4. Required example tests

1. Two sessions reserve against the same Mill/product: the second checks availability only after the first commit; no oversubscription.
2. Race publication against reservation: the accepted publication reference and calculation use one guarded version.
3. Replay identical input returns the same reservation ID with one reservation and one audit success event.
4. Reuse OperationId with different quantity, request, week or authenticated Shop: reject without mutation, including concurrent reuse across resources.
5. Attempt another Shop's request under a genuine least-privilege login: reject without revealing saved results.
6. Force audit insertion failure: reservation insertion rolls back. Verify zero business rows and no phantom success.
7. Force lock timeout/deadlock: verify rollback and bounded identical-key retry; insufficient-availability error is attempted once.
8. Lose the response after successful commit: identical replay resolves original result; no extra reservation.
9. Run under SNAPSHOT, an ambient transaction or disabled RCSI: reject before business mutation.

The complete example requires identity provisioning and integration tests; compilation alone is insufficient. Existing ten-table deployment and its twelve declared procedures remain unchanged. See [03_transactions.sql](03_transactions.sql), [SPECIFICATION.md](SPECIFICATION.md) and [README.md](README.md) for the base implementation and requirements.

Verification on 2026-10-09: SQL example compiled and single-session LocalDB tests passed authenticated mapping, identical replay, changed-payload conflict, foreign-owner rejection, insufficient availability and rollback after injected audit-insert failure. These ran with an administrative test connection; genuine least-privilege access, multi-session contention, failure recovery and the C# excerpt have not been executed. The injected trigger existed only in the disposable test database and is not a proposed deployment component.

Deployment note: do not grant application access to the demonstration procedure until its identity prerequisites, permission boundaries and remaining tests are satisfied.
