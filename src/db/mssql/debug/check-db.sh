#!/usr/bin/env bash
# Usage: check-db.sh
# Shows row counts for all tables, all accounts with balances,
# and the latest price per instrument.
# Exits 1 after the full report when [dbo].[Alerts] is missing or could not be counted.

set -euo pipefail

source "$(dirname "$0")/_sqlcmd.sh"

echo "=== Row Counts ==="
# sqlcmd exits 0 on SQL errors here, so the count batch's output decides the exit status.
# Alerts is reported by its missing-table notice or by its own count row. Output with
# neither means the batch did not complete, such as after a SQL error or a deadlock.
# Departs from the unit-test rule: tests never mock the database, so these branches
# are verified by running this script against MSSQL with and without dbo.Alerts.
alerts_missing_notice="Table [dbo].[Alerts] is missing; sql-alerts.sql must be applied."
row_counts_status=0
row_counts="$(sqlcmd "
SET NOCOUNT ON;
-- Alerts is counted through dynamic SQL, so a missing table leaves the other counts intact.
DECLARE @Alerts TABLE ([Table] VARCHAR(6), [Rows] INT);
IF OBJECT_ID(N'dbo.Alerts', N'U') IS NOT NULL
    INSERT INTO @Alerts EXEC (N'SELECT ''Alerts'', COUNT(*) FROM [dbo].[Alerts]');
SET NOCOUNT OFF;
SELECT 'Accounts'          AS [Table], COUNT(*) AS [Rows] FROM [dbo].[Accounts]
UNION ALL
SELECT 'Balance',                       COUNT(*)           FROM [dbo].[Balance]
UNION ALL
SELECT 'BalanceHistory',                COUNT(*)           FROM [dbo].[BalanceHistory]
UNION ALL
SELECT 'Instruments',                   COUNT(*)           FROM [dbo].[Instruments]
UNION ALL
SELECT 'OwnedInstruments',              COUNT(*)           FROM [dbo].[Ownedinstruments]
UNION ALL
SELECT 'Packages',                      COUNT(*)           FROM [dbo].[Packages]
UNION ALL
SELECT 'Pricing',                       COUNT(*)           FROM [dbo].[Pricing]
UNION ALL
SELECT 'Products',                      COUNT(*)           FROM [dbo].[Products]
UNION ALL
SELECT 'Trades',                        COUNT(*)           FROM [dbo].[Trades]
UNION ALL
SELECT 'CreditCardOrders',              COUNT(*)           FROM [dbo].[CreditCardOrders]
UNION ALL
SELECT 'CreditCardOrderStatus',         COUNT(*)           FROM [dbo].[CreditCardOrderStatus]
UNION ALL
SELECT 'CreditCards',                   COUNT(*)           FROM [dbo].[CreditCards]
UNION ALL
SELECT [Table],                         [Rows]             FROM @Alerts
ORDER BY [Table];
IF NOT EXISTS (SELECT 1 FROM @Alerts) PRINT '${alerts_missing_notice}';
")" || row_counts_status=$?
if [[ -n "$row_counts" ]]; then
    printf '%s\n' "$row_counts"
fi
# A client or login failure exits nonzero with its error on stderr, which is not captured.
if [[ "$row_counts_status" -ne 0 ]]; then
    exit "$row_counts_status"
fi
alerts_missing=false
alerts_uncounted=false
if grep -qxF "$alerts_missing_notice" <<< "$row_counts"; then
    alerts_missing=true
elif ! grep -qE '^Alerts\|[0-9]+$' <<< "$row_counts"; then
    alerts_uncounted=true
    echo "The [dbo].[Alerts] row count could not be produced; the count batch did not complete." >&2
fi

echo ""
echo "=== Accounts ==="
sqlcmd "
SELECT
    a.[Id],
    a.[Username],
    a.[Origin],
    b.[Value] AS [Balance]
FROM [dbo].[Accounts] a
LEFT JOIN [dbo].[Balance] b ON b.[AccountId] = a.[Id]
ORDER BY a.[Id];
"

echo ""
echo "=== Latest Price Per Instrument ==="
sqlcmd "
SELECT
    i.[Code] AS [Instrument],
    p.[Timestamp],
    p.[Open],
    p.[High],
    p.[Low],
    p.[Close]
FROM [dbo].[Pricing] p
JOIN [dbo].[Instruments] i ON i.[Id] = p.[InstrumentId]
WHERE p.[Id] IN (
    SELECT MAX([Id]) FROM [dbo].[Pricing] GROUP BY [InstrumentId]
)
ORDER BY i.[Id];
"

if [[ "$alerts_missing" == true || "$alerts_uncounted" == true ]]; then
    exit 1
fi
