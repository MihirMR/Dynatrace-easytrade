-- Portfolio Insights alerts; guarded for reruns and manual applies. Kept in sync with src/db/mssql/sql-scripts/sql-alerts.sql.
-- PostgreSQL drops spaces beyond the declared width of "Type"/"Direction"; the CHECKs then validate the remaining value, so only exact values are stored.
CREATE TABLE IF NOT EXISTS "Alerts" (
    "Id" uuid NOT NULL DEFAULT gen_random_uuid(),
    "AccountId" uuid NOT NULL,
    "Type" varchar(12) NOT NULL CHECK("Type" IN('TARGET_PRICE', 'PROFIT_LOSS')),
    "InstrumentId" uuid NOT NULL,
    "Direction" varchar(5) NOT NULL CHECK("Direction" IN('ABOVE', 'BELOW')),
    "Threshold" numeric(18, 8) NOT NULL,
    "Enabled" boolean NOT NULL DEFAULT true,
    "ArmingRevision" integer NOT NULL DEFAULT 1,
    "TriggeredAt" timestamptz NULL,
    "TriggerValue" numeric(28, 8) NULL,
    "Acknowledged" boolean NOT NULL DEFAULT false,
    "CreatedAt" timestamptz NOT NULL,
    CONSTRAINT "PK_Alerts" PRIMARY KEY ("Id"),
    CONSTRAINT "FK_Alerts_Accounts" FOREIGN KEY ("AccountId") REFERENCES "Accounts"("Id") ON DELETE CASCADE,
    CONSTRAINT "FK_Alerts_Instruments" FOREIGN KEY ("InstrumentId") REFERENCES "Instruments"("Id")
);
CREATE INDEX IF NOT EXISTS "IX_Alerts_AccountId" ON "Alerts" ("AccountId", "CreatedAt");
