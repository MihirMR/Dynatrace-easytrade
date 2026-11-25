-- Portfolio Insights alerts; guarded for reruns and manual applies. Kept in sync with src/db/mssql/sql-scripts/sql-alerts.sql.
-- PostgreSQL drops spaces beyond the declared width of "Type"/"Direction"; the CHECKs then validate the remaining value, so only exact values are stored.
-- PostgreSQL numeric admits NaN and timestamptz admits infinity and -infinity, which the SQL Server types reject; the CHECKs on "Threshold", "TriggerValue", "CreatedAt" and "TriggeredAt" refuse them, so both dialects store one value domain.
CREATE TABLE IF NOT EXISTS "Alerts" (
    "Id" uuid NOT NULL DEFAULT gen_random_uuid(),
    "AccountId" uuid NOT NULL,
    "Type" varchar(12) NOT NULL CHECK("Type" IN('TARGET_PRICE', 'PROFIT_LOSS')),
    "InstrumentId" uuid NOT NULL,
    "Direction" varchar(5) NOT NULL CHECK("Direction" IN('ABOVE', 'BELOW')),
    "Threshold" numeric(18, 8) NOT NULL CHECK("Threshold" <> 'NaN'),
    "Enabled" boolean NOT NULL DEFAULT true,
    "ArmingRevision" integer NOT NULL DEFAULT 1,
    "TriggeredAt" timestamptz NULL CHECK("TriggeredAt" IS NULL OR isfinite("TriggeredAt")),
    "TriggerValue" numeric(28, 8) NULL CHECK("TriggerValue" IS NULL OR "TriggerValue" <> 'NaN'),
    "Acknowledged" boolean NOT NULL DEFAULT false,
    "CreatedAt" timestamptz NOT NULL CHECK(isfinite("CreatedAt")),
    CONSTRAINT "PK_Alerts" PRIMARY KEY ("Id"),
    CONSTRAINT "FK_Alerts_Accounts" FOREIGN KEY ("AccountId") REFERENCES "Accounts"("Id") ON DELETE CASCADE,
    CONSTRAINT "FK_Alerts_Instruments" FOREIGN KEY ("InstrumentId") REFERENCES "Instruments"("Id")
);
CREATE INDEX IF NOT EXISTS "IX_Alerts_AccountId" ON "Alerts" ("AccountId", "CreatedAt");
