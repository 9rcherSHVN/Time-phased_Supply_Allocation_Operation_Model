param()
$ErrorActionPreference = 'Stop'
$sqlFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.sql' | Sort-Object Name
$sqlText = ($sqlFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$tables = [regex]::Matches($sqlText, '(?im)^CREATE TABLE planning\.([A-Za-z]+)')
if ($tables.Count -ne 10) { throw "Expected 10 tables; found $($tables.Count)." }
if (($tables | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count -ne 10) {
    throw 'Duplicate table names.'
}
foreach ($required in @('fnTimePhasedAvailability', 'PublishForecast', 'ReserveSupply', 'CloseMillWeek', 'BusinessAuditEvent')) {
    if ($sqlText -notmatch [regex]::Escape($required)) { throw "Missing object: $required" }
}
if ($sqlText -notmatch 'ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING') {
    throw 'Missing downstream reservation protection.'
}
if ([regex]::Matches($sqlText, "THROW 51999").Count -ne 7) { throw 'Expected seven explicit fail-fast workflow templates.' }
function Get-Reservable([decimal[]] $endingBalances, [int] $targetIndex) {
    $minimum = ($endingBalances[$targetIndex..($endingBalances.Length - 1)] | Measure-Object -Minimum).Minimum
    return [Math]::Max([decimal]0, [decimal]$minimum)
}
if ((Get-Reservable @(10, 0) 0) -ne 0) { throw 'Earlier supply already promised later must not be reservable.' }
if ((Get-Reservable @(10, 12) 0) -ne 10) { throw 'Positive carryover case failed.' }
if ((Get-Reservable @(-3, 7) 1) -ne 7) { throw 'Recovered deficit case failed.' }
if ((Get-Reservable @(5, -2) 0) -ne 0) { throw 'Existing downstream deficit must block worsening reservations.' }
Write-Output 'PASS: 10 tables, required objects, fail-fast templates, and four balance-rule checks.'
Write-Output 'Static checks only. SQL Server compilation and transaction/concurrency tests are still required.'