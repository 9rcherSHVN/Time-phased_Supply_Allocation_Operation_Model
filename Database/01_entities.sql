SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE SCHEMA planning AUTHORIZATION dbo;
GO
CREATE TABLE planning.Mill (
    MillId int IDENTITY PRIMARY KEY,
    MillCode varchar(40) NOT NULL UNIQUE,
    MillName nvarchar(200) NOT NULL,
    AccountingStartWeek date NOT NULL,
    ClosedThroughWeek date NULL,
    ActiveForecastPublicationId bigint NULL,
    RowVersion rowversion,
    CONSTRAINT CK_Mill_Weeks CHECK (
        DATEDIFF(day, CONVERT(date, '19000101', 112), AccountingStartWeek) % 7 = 0
        AND (ClosedThroughWeek IS NULL OR (ClosedThroughWeek >= AccountingStartWeek
        AND DATEDIFF(day, AccountingStartWeek, ClosedThroughWeek) % 7 = 0)))
);
CREATE TABLE planning.Shop (
    ShopId int IDENTITY PRIMARY KEY,
    ShopCode varchar(40) NOT NULL UNIQUE,
    ShopName nvarchar(200) NOT NULL
);
CREATE TABLE planning.Product (
    ProductId int IDENTITY PRIMARY KEY,
    ProductCode varchar(40) NOT NULL UNIQUE,
    ProductName nvarchar(200) NOT NULL,
    CanonicalUnit varchar(16) NOT NULL
);
CREATE TABLE planning.ForecastPublication (
    PublicationId bigint IDENTITY PRIMARY KEY,
    MillId int NOT NULL REFERENCES planning.Mill(MillId),
    VersionNumber int NOT NULL CHECK (VersionNumber > 0),
    HorizonStartWeek date NOT NULL,
    HorizonEndWeek date NOT NULL,
    CoveredProductIds nvarchar(max) NOT NULL,
    UploadComplete bit NOT NULL DEFAULT 0,
    ExpectedSourceRows int NOT NULL CHECK (ExpectedSourceRows >= 0),
    LoadedSourceRows int NOT NULL DEFAULT 0,
    SourceSha256 binary(32) NOT NULL,
    Status varchar(16) NOT NULL DEFAULT 'Loading',
    CreatedAt datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
    CreatedBy nvarchar(128) NOT NULL,
    PublishedAt datetime2(7) NULL,
    CONSTRAINT UQ_Forecast_MillVersion UNIQUE (MillId, VersionNumber),
    CONSTRAINT UQ_Forecast_MillPublication UNIQUE (MillId, PublicationId),
    CONSTRAINT CK_Forecast_Status CHECK (Status IN ('Loading', 'Validated', 'Published', 'Superseded')),
    CONSTRAINT CK_Forecast_Coverage CHECK (ISJSON(CoveredProductIds) = 1),
    CONSTRAINT CK_Forecast_Horizon CHECK (HorizonEndWeek >= HorizonStartWeek
        AND DATEDIFF(day, CONVERT(date, '19000101', 112), HorizonStartWeek) % 7 = 0
        AND DATEDIFF(day, HorizonStartWeek, HorizonEndWeek) % 7 = 0
        AND DATEDIFF(week, HorizonStartWeek, HorizonEndWeek) <= 519)
);
ALTER TABLE planning.Mill ADD CONSTRAINT FK_Mill_ActivePublication
    FOREIGN KEY (MillId, ActiveForecastPublicationId)
    REFERENCES planning.ForecastPublication(MillId, PublicationId);
CREATE TABLE planning.ForecastLine (
    PublicationId bigint NOT NULL REFERENCES planning.ForecastPublication(PublicationId),
    ProductId int NOT NULL REFERENCES planning.Product(ProductId),
    WeekStart date NOT NULL,
    Quantity decimal(19,4) NOT NULL CHECK (Quantity >= 0),
    PRIMARY KEY (PublicationId, ProductId, WeekStart)
);
CREATE TABLE planning.DemandRequest (
    DemandRequestId bigint IDENTITY PRIMARY KEY,
    ShopId int NOT NULL REFERENCES planning.Shop(ShopId),
    MillId int NOT NULL REFERENCES planning.Mill(MillId),
    ProductId int NOT NULL REFERENCES planning.Product(ProductId),
    DesiredWeek date NOT NULL,
    RequestedQuantity decimal(19,4) NOT NULL CHECK (RequestedQuantity >= 0),
    ShopPriority smallint NOT NULL CHECK (ShopPriority BETWEEN 1 AND 5),
    IsCancelled bit NOT NULL DEFAULT 0,
    CreatedAt datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
    RowVersion rowversion,
    CONSTRAINT UQ_Request_Source UNIQUE (DemandRequestId, MillId, ProductId),
    CONSTRAINT CK_Request_Week CHECK (DATEDIFF(day, CONVERT(date, '19000101', 112), DesiredWeek) % 7 = 0)
);
CREATE TABLE planning.Reservation (
    ReservationId bigint IDENTITY PRIMARY KEY,
    DemandRequestId bigint NOT NULL,
    MillId int NOT NULL,
    ProductId int NOT NULL,
    TargetWeek date NOT NULL,
    ReservedQuantity decimal(19,4) NOT NULL CHECK (ReservedQuantity > 0),
    ActualizedQuantity decimal(19,4) NOT NULL DEFAULT 0,
    CancelledQuantity decimal(19,4) NOT NULL DEFAULT 0,
    ExpiredQuantity decimal(19,4) NOT NULL DEFAULT 0,
    RemainingQuantity AS (ReservedQuantity - ActualizedQuantity - CancelledQuantity - ExpiredQuantity) PERSISTED,
    AcceptedPublicationId bigint NOT NULL,
    OperationId uniqueidentifier NOT NULL UNIQUE,
    CreatedAt datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
    RowVersion rowversion,
    CONSTRAINT UQ_Reservation_Request UNIQUE (ReservationId, DemandRequestId),
    CONSTRAINT FK_Reservation_Request FOREIGN KEY (DemandRequestId, MillId, ProductId)
        REFERENCES planning.DemandRequest(DemandRequestId, MillId, ProductId),
    CONSTRAINT FK_Reservation_Publication FOREIGN KEY (MillId, AcceptedPublicationId)
        REFERENCES planning.ForecastPublication(MillId, PublicationId),
    CONSTRAINT CK_Reservation_Quantities CHECK (ActualizedQuantity >= 0 AND CancelledQuantity >= 0
        AND ExpiredQuantity >= 0 AND ActualizedQuantity + CancelledQuantity + ExpiredQuantity <= ReservedQuantity),
    CONSTRAINT CK_Reservation_Week CHECK (DATEDIFF(day, CONVERT(date, '19000101', 112), TargetWeek) % 7 = 0)
);
CREATE TABLE planning.ActualProduction (
    MillId int NOT NULL REFERENCES planning.Mill(MillId),
    ProductId int NOT NULL REFERENCES planning.Product(ProductId),
    WeekStart date NOT NULL,
    Quantity decimal(19,4) NOT NULL CHECK (Quantity >= 0),
    ReportedAt datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
    ReportedBy nvarchar(128) NOT NULL,
    PRIMARY KEY (MillId, ProductId, WeekStart)
);
CREATE TABLE planning.ActualUsage (
    ActualUsageId bigint IDENTITY PRIMARY KEY,
    DemandRequestId bigint NOT NULL,
    MillId int NOT NULL,
    ProductId int NOT NULL,
    ReservationId bigint NULL,
    WeekStart date NOT NULL,
    Quantity decimal(19,4) NOT NULL CHECK (Quantity > 0),
    ReservationAppliedQuantity decimal(19,4) NOT NULL DEFAULT 0,
    OperationId uniqueidentifier NOT NULL UNIQUE,
    ReportedAt datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
    ReportedBy nvarchar(128) NOT NULL,
    CONSTRAINT FK_Usage_Request FOREIGN KEY (DemandRequestId, MillId, ProductId)
        REFERENCES planning.DemandRequest(DemandRequestId, MillId, ProductId),
    CONSTRAINT FK_Usage_Reservation FOREIGN KEY (ReservationId, DemandRequestId)
        REFERENCES planning.Reservation(ReservationId, DemandRequestId),
    CONSTRAINT CK_Usage_Applied CHECK (ReservationAppliedQuantity >= 0 AND ReservationAppliedQuantity <= Quantity
        AND (ReservationId IS NOT NULL OR ReservationAppliedQuantity = 0)),
    CONSTRAINT CK_Usage_Week CHECK (DATEDIFF(day, CONVERT(date, '19000101', 112), WeekStart) % 7 = 0)
);
CREATE TABLE planning.BusinessAuditEvent (
    AuditEventId bigint IDENTITY PRIMARY KEY,
    OperationId uniqueidentifier NOT NULL UNIQUE,
    EventType varchar(50) NOT NULL,
    MillId int NOT NULL REFERENCES planning.Mill(MillId),
    ProductId int NULL REFERENCES planning.Product(ProductId),
    DemandRequestId bigint NULL REFERENCES planning.DemandRequest(DemandRequestId),
    PublicationId bigint NULL REFERENCES planning.ForecastPublication(PublicationId),
    WeekStart date NULL,
    Severity varchar(10) NOT NULL DEFAULT 'Info' CHECK (Severity IN ('Info', 'Red')),
    Actor nvarchar(128) NOT NULL,
    OccurredAt datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
    Details nvarchar(max) NOT NULL CHECK (ISJSON(Details) = 1)
);
CREATE INDEX IX_Reservation_Timeline ON planning.Reservation(MillId, ProductId, TargetWeek)
    INCLUDE (RemainingQuantity, DemandRequestId);
CREATE INDEX IX_Usage_Timeline ON planning.ActualUsage(MillId, ProductId, WeekStart) INCLUDE (Quantity);
CREATE INDEX IX_Usage_Request ON planning.ActualUsage(DemandRequestId) INCLUDE (Quantity);
CREATE INDEX IX_Reservation_Request ON planning.Reservation(DemandRequestId) INCLUDE (RemainingQuantity);
CREATE INDEX IX_Audit_MillTime ON planning.BusinessAuditEvent(MillId, OccurredAt);
GO