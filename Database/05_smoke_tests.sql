SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF EXISTS (SELECT 1 FROM planning.Mill)
    THROW 52000, 'Run smoke tests only in a new disposable database with empty tables.', 1;
DECLARE @MillId int, @ShopId int, @ProductId int, @FractionalProductId int;
DECLARE @PublicationId bigint, @RequestId bigint, @OtherRequestId bigint, @FractionalRequestId bigint;
DECLARE @OperationId uniqueidentifier = NEWID();
INSERT planning.Mill(MillCode, MillName, AccountingStartWeek) VALUES ('TEST_MILL', 'Test Mill', '20261005');
SET @MillId = CONVERT(int, SCOPE_IDENTITY());
INSERT planning.Shop(ShopCode, ShopName) VALUES ('TEST_SHOP', 'Test Shop');
SET @ShopId = CONVERT(int, SCOPE_IDENTITY());
INSERT planning.Product(ProductCode, ProductName, CanonicalUnit) VALUES ('TEST_EA', 'Test Product', 'EA');
SET @ProductId = CONVERT(int, SCOPE_IDENTITY());
INSERT planning.Product(ProductCode, ProductName, CanonicalUnit) VALUES ('TEST_KG', 'Fractional Product', 'KG');
SET @FractionalProductId = CONVERT(int, SCOPE_IDENTITY());
DECLARE @Coverage nvarchar(max) = CONCAT('[', @ProductId, ',', @FractionalProductId, ']');
INSERT planning.ForecastPublication(MillId, VersionNumber, HorizonStartWeek, HorizonEndWeek,
    CoveredProductIds, UploadComplete, ExpectedSourceRows, LoadedSourceRows, SourceSha256, CreatedBy)
VALUES (@MillId, 1, '20261005', '20261019', @Coverage, 1, 3, 3, HASHBYTES('SHA2_256', 'test-v1'), 'SmokeTest');
SET @PublicationId = CONVERT(bigint, SCOPE_IDENTITY());
INSERT planning.ForecastLine VALUES (@PublicationId, @ProductId, '20261005', 10),
    (@PublicationId, @ProductId, '20261019', 12), (@PublicationId, @FractionalProductId, '20261005', 0.1234);
EXEC planning.ValidateForecastPublication @PublicationId;
EXEC planning.PublishForecast @MillId, @PublicationId, NULL, @OperationId;
EXEC planning.PublishForecast @MillId, @PublicationId, NULL, @OperationId;
INSERT planning.DemandRequest(ShopId, MillId, ProductId, DesiredWeek, RequestedQuantity, ShopPriority)
VALUES (@ShopId, @MillId, @ProductId, '20261012', 10, 1);
SET @RequestId = CONVERT(bigint, SCOPE_IDENTITY());
SET @OperationId = NEWID();
EXEC planning.ReserveSupply @RequestId, '20261012', 10, @OperationId;
EXEC planning.ReserveSupply @RequestId, '20261012', 10, @OperationId;
IF (SELECT COUNT(*) FROM planning.Reservation WHERE DemandRequestId = @RequestId) <> 1
    THROW 52001, 'Idempotent reservation replay duplicated a record.', 1;
IF (SELECT ReservableQuantity FROM planning.fnTimePhasedAvailability(@MillId, @ProductId) WHERE WeekStart = '20261005') <> 0
    THROW 52002, 'Earlier week can steal carryover supporting later reservation.', 1;
INSERT planning.DemandRequest(ShopId, MillId, ProductId, DesiredWeek, RequestedQuantity, ShopPriority)
VALUES (@ShopId, @MillId, @ProductId, '20261005', 1, 1);
SET @OtherRequestId = CONVERT(bigint, SCOPE_IDENTITY());
DECLARE @Rejected bit = 0;
SET @OperationId = NEWID();
BEGIN TRY
    EXEC planning.ReserveSupply @OtherRequestId, '20261005', 1, @OperationId;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 51015 THROW;
    SET @Rejected = 1;
END CATCH;
IF @Rejected = 0 THROW 52003, 'Expected insufficient availability rejection.', 1;
INSERT planning.DemandRequest(ShopId, MillId, ProductId, DesiredWeek, RequestedQuantity, ShopPriority)
VALUES (@ShopId, @MillId, @FractionalProductId, '20261005', 0.0234, 1);
SET @FractionalRequestId = CONVERT(bigint, SCOPE_IDENTITY());
SET @OperationId = NEWID();
EXEC planning.ReserveSupply @FractionalRequestId, '20261005', 0.0234, @OperationId;
IF (SELECT ProjectedEnd FROM planning.fnTimePhasedAvailability(@MillId, @FractionalProductId) WHERE WeekStart = '20261005') <> 0.1000
    THROW 52004, 'Decimal balance arithmetic lost fractional precision.', 1;
DECLARE @NewPublicationId bigint;
INSERT planning.ForecastPublication(MillId, VersionNumber, HorizonStartWeek, HorizonEndWeek,
    CoveredProductIds, UploadComplete, ExpectedSourceRows, LoadedSourceRows, SourceSha256, CreatedBy)
VALUES (@MillId, 2, '20261005', '20261019', @Coverage, 1, 3, 3, HASHBYTES('SHA2_256', 'test-v2'), 'SmokeTest');
SET @NewPublicationId = CONVERT(bigint, SCOPE_IDENTITY());
INSERT planning.ForecastLine VALUES (@NewPublicationId, @ProductId, '20261005', 5),
    (@NewPublicationId, @ProductId, '20261019', 12), (@NewPublicationId, @FractionalProductId, '20261005', 0.1234);
EXEC planning.ValidateForecastPublication @NewPublicationId;
SET @OperationId = NEWID();
EXEC planning.PublishForecast @MillId, @NewPublicationId, @PublicationId, @OperationId;
IF (SELECT ProjectedDeficit FROM planning.fnTimePhasedAvailability(@MillId, @ProductId) WHERE WeekStart = '20261012') <> 5
    THROW 52005, 'Forecast decrease failed to reveal deficit.', 1;
IF (SELECT RemainingQuantity FROM planning.Reservation WHERE DemandRequestId = @RequestId) <> 10
    THROW 52006, 'Publication changed an existing reservation.', 1;
IF (SELECT COUNT(*) FROM planning.vShopAvailability WHERE MillId = @MillId) <> 6
    THROW 52007, 'Shop availability view duplicated or omitted covered weeks.', 1;
PRINT 'PASS: SQL compilation, publication replay, reservation replay, downstream protection, decimal precision, and forecast deficit.';
PRINT 'Workflow templates and multi-session concurrency still require implementation/testing.';
GO