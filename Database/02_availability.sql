SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER VIEW planning.vWeekOffsets AS
WITH Digits AS (
    SELECT Digit FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS Source(Digit)
)
SELECT Units.Digit + Tens.Digit * 10 + Hundreds.Digit * 100 + Thousands.Digit * 1000 AS OffsetNumber
FROM Digits AS Units CROSS JOIN Digits AS Tens CROSS JOIN Digits AS Hundreds CROSS JOIN Digits AS Thousands;
GO
CREATE OR ALTER VIEW planning.vActiveForecast AS
SELECT Publication.MillId, Publication.PublicationId, Publication.VersionNumber,
    Publication.HorizonStartWeek, Publication.HorizonEndWeek, Coverage.ProductId
FROM planning.Mill AS Mill
JOIN planning.ForecastPublication AS Publication ON Publication.PublicationId = Mill.ActiveForecastPublicationId
CROSS APPLY OPENJSON(Publication.CoveredProductIds) WITH (ProductId int '$') AS Coverage;
GO
CREATE OR ALTER VIEW planning.vOpenReservations AS
SELECT MillId, ProductId, TargetWeek AS WeekStart,
    CONVERT(decimal(28,4), SUM(CONVERT(decimal(38,4), RemainingQuantity))) AS ReservedQuantity
FROM planning.Reservation GROUP BY MillId, ProductId, TargetWeek;
GO
CREATE OR ALTER VIEW planning.vWeeklyUsage AS
SELECT MillId, ProductId, WeekStart, CONVERT(decimal(28,4), SUM(CONVERT(decimal(38,4), Quantity))) AS UsedQuantity
FROM planning.ActualUsage GROUP BY MillId, ProductId, WeekStart;
GO
CREATE OR ALTER VIEW planning.vDemandPosition AS
WITH UsageTotals AS (
    SELECT DemandRequestId, CONVERT(decimal(28,4), SUM(CONVERT(decimal(38,4), Quantity))) AS UsedQuantity
    FROM planning.ActualUsage GROUP BY DemandRequestId
), ReservationTotals AS (
    SELECT DemandRequestId, CONVERT(decimal(28,4), SUM(CONVERT(decimal(38,4), RemainingQuantity))) AS ReservedQuantity
    FROM planning.Reservation GROUP BY DemandRequestId
)
SELECT Request.DemandRequestId, Request.ShopId, Request.MillId, Request.ProductId,
    Request.RequestedQuantity, Request.DesiredWeek, Request.ShopPriority, Request.IsCancelled,
    COALESCE(UsageTotals.UsedQuantity, 0) AS UsedQuantity,
    COALESCE(ReservationTotals.ReservedQuantity, 0) AS ReservedQuantity,
    CASE WHEN Request.IsCancelled = 1 THEN CONVERT(decimal(28,4), 0)
         WHEN Request.RequestedQuantity > COALESCE(UsageTotals.UsedQuantity, 0) + COALESCE(ReservationTotals.ReservedQuantity, 0)
         THEN Request.RequestedQuantity - COALESCE(UsageTotals.UsedQuantity, 0) - COALESCE(ReservationTotals.ReservedQuantity, 0)
         ELSE CONVERT(decimal(28,4), 0) END AS PendingQuantity
FROM planning.DemandRequest AS Request
LEFT JOIN UsageTotals ON UsageTotals.DemandRequestId = Request.DemandRequestId
LEFT JOIN ReservationTotals ON ReservationTotals.DemandRequestId = Request.DemandRequestId;
GO
CREATE OR ALTER FUNCTION planning.fnTimePhasedAvailability(@MillId int, @ProductId int)
RETURNS TABLE AS RETURN (
    WITH Timeline AS (
        SELECT Mill.MillId, Mill.ClosedThroughWeek, Forecast.PublicationId, Forecast.VersionNumber,
            Forecast.HorizonStartWeek, Forecast.HorizonEndWeek,
            DATEADD(week, WeekNumbers.OffsetNumber, Mill.AccountingStartWeek) AS WeekStart
        FROM planning.Mill AS Mill
        JOIN planning.vActiveForecast AS Forecast ON Forecast.MillId = Mill.MillId AND Forecast.ProductId = @ProductId
        JOIN planning.vWeekOffsets AS WeekNumbers ON WeekNumbers.OffsetNumber <= DATEDIFF(week, Mill.AccountingStartWeek, Forecast.HorizonEndWeek)
        WHERE Mill.MillId = @MillId
    ), Components AS (
        SELECT Timeline.*, @ProductId AS ProductId,
            CASE WHEN Timeline.WeekStart <= Timeline.ClosedThroughWeek THEN COALESCE(Production.Quantity, 0)
                 ELSE COALESCE(Line.Quantity, 0) END AS SupplyQuantity,
            COALESCE(Usage.UsedQuantity, 0) AS UsedQuantity,
            COALESCE(Reservations.ReservedQuantity, 0) AS ReservedQuantity,
            CASE WHEN Timeline.WeekStart <= Timeline.ClosedThroughWeek AND Production.MillId IS NULL THEN 1
                 WHEN (Timeline.ClosedThroughWeek IS NULL OR Timeline.WeekStart > Timeline.ClosedThroughWeek)
                    AND Timeline.WeekStart < Timeline.HorizonStartWeek THEN 1 ELSE 0 END AS MissingBasis,
            CASE WHEN Timeline.WeekStart <= Timeline.ClosedThroughWeek
                 THEN COALESCE(Production.Quantity, 0) - COALESCE(Usage.UsedQuantity, 0) ELSE 0 END AS RealizedDelta
        FROM Timeline
        LEFT JOIN planning.ForecastLine AS Line ON Line.PublicationId = Timeline.PublicationId
            AND Line.ProductId = @ProductId AND Line.WeekStart = Timeline.WeekStart
        LEFT JOIN planning.ActualProduction AS Production ON Production.MillId = @MillId
            AND Production.ProductId = @ProductId AND Production.WeekStart = Timeline.WeekStart
        LEFT JOIN planning.vWeeklyUsage AS Usage ON Usage.MillId = @MillId
            AND Usage.ProductId = @ProductId AND Usage.WeekStart = Timeline.WeekStart
        LEFT JOIN planning.vOpenReservations AS Reservations ON Reservations.MillId = @MillId
            AND Reservations.ProductId = @ProductId AND Reservations.WeekStart = Timeline.WeekStart
    ), Balances AS (
        SELECT Components.*,
            CONVERT(decimal(28,4), SUM(SupplyQuantity - UsedQuantity - ReservedQuantity) OVER
                (ORDER BY WeekStart ROWS UNBOUNDED PRECEDING)) AS ProjectedEnd,
            SUM(MissingBasis) OVER (ORDER BY WeekStart ROWS UNBOUNDED PRECEDING) AS MissingBasisCount,
            CONVERT(decimal(28,4), SUM(RealizedDelta) OVER ()) AS RealizedCarryover
        FROM Components
    ), ProtectedBalances AS (
        SELECT Balances.*, MIN(ProjectedEnd) OVER
            (ORDER BY WeekStart ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS DownstreamMinimum
        FROM Balances
    )
    SELECT MillId, ProductId, PublicationId, VersionNumber, WeekStart, ClosedThroughWeek,
        SupplyQuantity, UsedQuantity, ReservedQuantity, MissingBasisCount,
        CASE WHEN MissingBasisCount = 0 THEN ProjectedEnd END AS ProjectedEnd,
        CASE WHEN MissingBasisCount = 0 THEN ProjectedEnd - SupplyQuantity + UsedQuantity + ReservedQuantity END AS ProjectedOpening,
        CASE WHEN MAX(MissingBasis) OVER () = 0 THEN RealizedCarryover END AS RealizedCarryover,
        CASE WHEN MissingBasisCount = 0 AND ProjectedEnd < 0 THEN -ProjectedEnd ELSE 0 END AS ProjectedDeficit,
        CASE WHEN MAX(MissingBasis) OVER () = 0 AND WeekStart BETWEEN HorizonStartWeek AND HorizonEndWeek
                  AND (ClosedThroughWeek IS NULL OR WeekStart > ClosedThroughWeek) AND DownstreamMinimum > 0
             THEN DownstreamMinimum ELSE CONVERT(decimal(28,4), 0) END AS ReservableQuantity
    FROM ProtectedBalances
);
GO
CREATE OR ALTER VIEW planning.vShopAvailability AS
SELECT Availability.*,
    CASE WHEN RealizedCarryover > 0 THEN RealizedCarryover ELSE 0 END AS UsableRealizedCarryover,
    CASE WHEN RealizedCarryover < 0 THEN -RealizedCarryover ELSE 0 END AS RealizedDeficit,
    SYSUTCDATETIME() AS ReadAtUtc
FROM planning.vActiveForecast AS Forecast
CROSS APPLY planning.fnTimePhasedAvailability(Forecast.MillId, Forecast.ProductId) AS Availability;
GO
CREATE OR ALTER VIEW planning.vDeficitExceptions AS
SELECT MillId, ProductId, PublicationId, WeekStart, ProjectedDeficit, RealizedDeficit, MissingBasisCount
FROM planning.vShopAvailability
WHERE ProjectedDeficit > 0 OR RealizedDeficit > 0 OR MissingBasisCount > 0;
GO