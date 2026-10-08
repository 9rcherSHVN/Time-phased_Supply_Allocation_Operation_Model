SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE planning.AcquireTransactionLock
    @Resource nvarchar(255), @Mode varchar(16), @TimeoutMs int = 5000
AS
BEGIN
    SET NOCOUNT ON;
    IF @@TRANCOUNT = 0 THROW 51000, 'Transaction-owned lock requires a transaction.', 1;
    DECLARE @Result int;
    EXEC @Result = sys.sp_getapplock @Resource = @Resource, @LockMode = @Mode,
        @LockOwner = 'Transaction', @LockTimeout = @TimeoutMs, @DbPrincipal = 'public';
    IF @Result < 0 THROW 51001, 'Coordination lock failed; roll back before bounded retry.', 1;
END;
GO
CREATE OR ALTER PROCEDURE planning.ValidateForecastPublication @PublicationId bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 THROW 51002, 'Call procedure without an ambient transaction.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Resource nvarchar(255) = CONCAT('snapshot:', @PublicationId);
        EXEC planning.AcquireTransactionLock @Resource, 'Exclusive';
        DECLARE @Coverage nvarchar(max), @Start date, @End date, @MillId int;
        SELECT @Coverage = CoveredProductIds, @Start = HorizonStartWeek, @End = HorizonEndWeek, @MillId = MillId
        FROM planning.ForecastPublication WHERE PublicationId = @PublicationId AND Status = 'Loading'
            AND UploadComplete = 1 AND LoadedSourceRows = ExpectedSourceRows;
        IF @MillId IS NULL THROW 51003, 'Snapshot missing, incomplete, or not Loading.', 1;
        IF EXISTS (SELECT 1 FROM planning.ForecastPublication AS Publication
            WHERE Publication.PublicationId = @PublicationId
            AND Publication.LoadedSourceRows <> (SELECT COUNT_BIG(*) FROM planning.ForecastLine WHERE PublicationId = @PublicationId))
            THROW 51003, 'Loaded line count does not match the completion manifest.', 1;
        IF LEFT(LTRIM(@Coverage), 1) <> '[' OR NOT EXISTS (SELECT 1 FROM OPENJSON(@Coverage))
            THROW 51004, 'Coverage must be a nonempty JSON integer array.', 1;
        IF EXISTS (SELECT 1 FROM OPENJSON(@Coverage) AS Coverage
            LEFT JOIN planning.Product AS Product ON Product.ProductId = TRY_CONVERT(int, Coverage.value)
            WHERE Coverage.type <> 2 OR Product.ProductId IS NULL)
            THROW 51004, 'Coverage contains an invalid product.', 1;
        IF EXISTS (SELECT value FROM OPENJSON(@Coverage) GROUP BY value HAVING COUNT(*) > 1)
            THROW 51004, 'Coverage contains duplicates.', 1;
        IF EXISTS (SELECT 1 FROM planning.ForecastLine AS Line WHERE Line.PublicationId = @PublicationId
            AND (Line.WeekStart NOT BETWEEN @Start AND @End OR DATEDIFF(day, @Start, Line.WeekStart) % 7 <> 0
            OR NOT EXISTS (SELECT 1 FROM OPENJSON(@Coverage) WHERE TRY_CONVERT(int, value) = Line.ProductId)))
            THROW 51005, 'Line lies outside declared coverage.', 1;
        IF EXISTS (SELECT 1 FROM planning.Mill WHERE MillId = @MillId
            AND (@Start < AccountingStartWeek OR DATEDIFF(week, AccountingStartWeek, @End) >= 10000))
            THROW 51005, 'Snapshot outside supported accounting calendar.', 1;
        UPDATE planning.ForecastPublication SET Status = 'Validated' WHERE PublicationId = @PublicationId;
        INSERT planning.BusinessAuditEvent(OperationId, EventType, MillId, PublicationId, Actor, Details)
        VALUES (NEWID(), 'ForecastValidated', @MillId, @PublicationId, ORIGINAL_LOGIN(), '{}');
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE planning.PublishForecast
    @MillId int, @PublicationId bigint, @ExpectedActivePublicationId bigint, @OperationId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 THROW 51002, 'Call procedure without an ambient transaction.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Resource nvarchar(255) = CONCAT('forecast:mill:', @MillId);
        EXEC planning.AcquireTransactionLock @Resource, 'Exclusive';
        IF EXISTS (SELECT 1 FROM planning.BusinessAuditEvent WHERE OperationId = @OperationId)
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM planning.BusinessAuditEvent WHERE OperationId = @OperationId
                AND EventType = 'ForecastPublished' AND MillId = @MillId AND PublicationId = @PublicationId)
                THROW 51006, 'Idempotency key reused with different arguments.', 1;
            COMMIT;
            RETURN;
        END;
        DECLARE @Active bigint, @Closed date, @AccountingStart date, @Start date, @End date, @Coverage nvarchar(max);
        SELECT @Active = ActiveForecastPublicationId, @Closed = ClosedThroughWeek, @AccountingStart = AccountingStartWeek
        FROM planning.Mill WHERE MillId = @MillId;
        IF @AccountingStart IS NULL THROW 51007, 'Unknown Mill.', 1;
        IF (@Active <> @ExpectedActivePublicationId) OR (@Active IS NULL AND @ExpectedActivePublicationId IS NOT NULL)
            OR (@Active IS NOT NULL AND @ExpectedActivePublicationId IS NULL)
            THROW 51008, 'Active publication changed; refresh before publishing.', 1;
        SELECT @Start = HorizonStartWeek, @End = HorizonEndWeek, @Coverage = CoveredProductIds
        FROM planning.ForecastPublication WHERE PublicationId = @PublicationId AND MillId = @MillId AND Status = 'Validated';
        IF @Start IS NULL THROW 51009, 'Snapshot must be validated and owned by this Mill.', 1;
        IF @Start > COALESCE(DATEADD(week, 1, @Closed), @AccountingStart)
            THROW 51010, 'Snapshot leaves an unreconciled open-week gap.', 1;
        IF @End < COALESCE(DATEADD(week, 1, @Closed), @AccountingStart)
            THROW 51010, 'Snapshot must cover at least the first unclosed week.', 1;
        IF EXISTS (SELECT 1 FROM planning.Reservation AS Reservation WHERE Reservation.MillId = @MillId
            AND Reservation.RemainingQuantity > 0 AND (Reservation.TargetWeek NOT BETWEEN @Start AND @End
            OR NOT EXISTS (SELECT 1 FROM OPENJSON(@Coverage) WHERE TRY_CONVERT(int, value) = Reservation.ProductId)))
            THROW 51011, 'Snapshot cannot remove coverage of active reservations.', 1;
        IF EXISTS (SELECT 1 FROM (
            SELECT ProductId FROM planning.ActualProduction WHERE MillId = @MillId
            UNION SELECT ProductId FROM planning.ActualUsage WHERE MillId = @MillId
        ) AS History WHERE NOT EXISTS (SELECT 1 FROM OPENJSON(@Coverage) WHERE TRY_CONVERT(int, value) = History.ProductId))
            THROW 51011, 'Retain historical products in coverage, including zero-supply products.', 1;
        UPDATE planning.ForecastPublication SET Status = 'Superseded' WHERE PublicationId = @Active;
        UPDATE planning.ForecastPublication SET Status = 'Published', PublishedAt = SYSUTCDATETIME()
        WHERE PublicationId = @PublicationId;
        UPDATE planning.Mill SET ActiveForecastPublicationId = @PublicationId WHERE MillId = @MillId;
        DECLARE @Details nvarchar(max) = (SELECT @Active AS PreviousPublicationId, @PublicationId AS NewPublicationId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
        INSERT planning.BusinessAuditEvent(OperationId, EventType, MillId, PublicationId, Actor, Details)
        VALUES (@OperationId, 'ForecastPublished', @MillId, @PublicationId, ORIGINAL_LOGIN(), @Details);
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE planning.ReserveSupply
    @DemandRequestId bigint, @TargetWeek date, @Quantity decimal(19,4), @OperationId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 THROW 51002, 'Call procedure without an ambient transaction.', 1;
    IF @Quantity <= 0 THROW 51012, 'Reservation quantity must be positive.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @MillId int, @ProductId int;
        SELECT @MillId = MillId, @ProductId = ProductId FROM planning.DemandRequest WHERE DemandRequestId = @DemandRequestId;
        IF @MillId IS NULL THROW 51013, 'Unknown demand request.', 1;
        DECLARE @MillResource nvarchar(255) = CONCAT('forecast:mill:', @MillId);
        DECLARE @ProductResource nvarchar(255) = CONCAT('balance:', @MillId, ':', @ProductId);
        EXEC planning.AcquireTransactionLock @MillResource, 'Shared';
        EXEC planning.AcquireTransactionLock @ProductResource, 'Exclusive';
        IF EXISTS (SELECT 1 FROM planning.BusinessAuditEvent WHERE OperationId = @OperationId)
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM planning.Reservation WHERE OperationId = @OperationId
                AND DemandRequestId = @DemandRequestId AND TargetWeek = @TargetWeek AND ReservedQuantity = @Quantity)
                THROW 51006, 'Idempotency key reused with different arguments.', 1;
            SELECT ReservationId, AcceptedPublicationId FROM planning.Reservation WHERE OperationId = @OperationId;
            COMMIT;
            RETURN;
        END;
        DECLARE @Pending decimal(38,4), @IsCancelled bit, @PublicationId bigint, @Reservable decimal(38,4);
        SELECT @Pending = PendingQuantity, @IsCancelled = IsCancelled FROM planning.vDemandPosition WHERE DemandRequestId = @DemandRequestId;
        IF @IsCancelled = 1 OR @Pending < @Quantity THROW 51014, 'Request has insufficient pending quantity.', 1;
        SELECT @PublicationId = PublicationId, @Reservable = ReservableQuantity
        FROM planning.fnTimePhasedAvailability(@MillId, @ProductId) WHERE WeekStart = @TargetWeek;
        IF @PublicationId IS NULL OR @Reservable < @Quantity THROW 51015, 'Insufficient published time-phased availability.', 1;
        INSERT planning.Reservation(DemandRequestId, MillId, ProductId, TargetWeek, ReservedQuantity, AcceptedPublicationId, OperationId)
        VALUES (@DemandRequestId, @MillId, @ProductId, @TargetWeek, @Quantity, @PublicationId, @OperationId);
        DECLARE @ReservationId bigint = CONVERT(bigint, SCOPE_IDENTITY());
        DECLARE @Details nvarchar(max) = (SELECT @ReservationId AS ReservationId, @Quantity AS Quantity
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        INSERT planning.BusinessAuditEvent(OperationId, EventType, MillId, ProductId, DemandRequestId, PublicationId, WeekStart, Actor, Details)
        VALUES (@OperationId, 'SupplyReserved', @MillId, @ProductId, @DemandRequestId, @PublicationId, @TargetWeek, ORIGINAL_LOGIN(), @Details);
        COMMIT;
        SELECT @ReservationId AS ReservationId, @PublicationId AS AcceptedPublicationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE planning.GetShopAvailability @MillId int, @ProductId int
AS
BEGIN
    SET NOCOUNT ON;
    SELECT *, SYSUTCDATETIME() AS ReadAtUtc
    FROM planning.fnTimePhasedAvailability(@MillId, @ProductId) ORDER BY WeekStart;
END;
GO