SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE TYPE planning.ForecastInput AS TABLE (
    ProductId int NOT NULL, WeekStart date NOT NULL, Quantity decimal(19,4) NOT NULL,
    PRIMARY KEY (ProductId, WeekStart)
);
GO
CREATE TYPE planning.ProductionInput AS TABLE (
    ProductId int NOT NULL PRIMARY KEY, Quantity decimal(19,4) NOT NULL
);
GO
CREATE OR ALTER PROCEDURE planning.LoadForecastSnapshot
    @MillId int, @VersionNumber int, @HorizonStartWeek date, @HorizonEndWeek date,
    @CoveredProductIds nvarchar(max), @ExpectedSourceRows int, @SourceSha256 binary(32),
    @Lines planning.ForecastInput READONLY, @OperationId uniqueidentifier
AS
BEGIN
    THROW 51999, 'Template only: implement workflow contract in database/README.md before enabling.', 1;
END;
GO
CREATE OR ALTER PROCEDURE planning.CreateDemandRequest
    @ShopId int, @MillId int, @ProductId int, @DesiredWeek date,
    @Quantity decimal(19,4), @ShopPriority smallint, @OperationId uniqueidentifier
AS
BEGIN
    THROW 51999, 'Template only: implement workflow contract in database/README.md before enabling.', 1;
END;
GO
CREATE OR ALTER PROCEDURE planning.EditFutureDemand
    @DemandRequestId bigint, @NewQuantity decimal(19,4), @NewDesiredWeek date,
    @ShopPriority smallint, @Cancel bit, @ExpectedRowVersion binary(8), @OperationId uniqueidentifier
AS
BEGIN
    THROW 51999, 'Template only: implement workflow contract in database/README.md before enabling.', 1;
END;
GO
CREATE OR ALTER PROCEDURE planning.CancelReservation
    @ReservationId bigint, @Quantity decimal(19,4), @OperationId uniqueidentifier
AS
BEGIN
    THROW 51999, 'Template only: implement workflow contract in database/README.md before enabling.', 1;
END;
GO
CREATE OR ALTER PROCEDURE planning.RecordActualUsage
    @DemandRequestId bigint, @ReservationId bigint = NULL,
    @WeekStart date = NULL, @Quantity decimal(19,4) = NULL, @OperationId uniqueidentifier = NULL
AS
BEGIN
    THROW 51999, 'Template only: implement workflow contract in database/README.md before enabling.', 1;
END;
GO
CREATE OR ALTER PROCEDURE planning.CloseMillWeek
    @MillId int, @WeekStart date, @Production planning.ProductionInput READONLY,
    @OperationId uniqueidentifier
AS
BEGIN
    THROW 51999, 'Template only: implement workflow contract in database/README.md before enabling.', 1;
END;
GO
CREATE OR ALTER PROCEDURE planning.RecommendDeficitPriority @MillId int, @ProductId int
AS
BEGIN
    THROW 51999, 'Template only: implement human-confirmed recommendation contract in database/README.md.', 1;
END;
GO