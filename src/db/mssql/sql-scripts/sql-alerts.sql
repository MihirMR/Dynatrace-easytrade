USE [TradeManagement]
GO
IF OBJECT_ID(N'dbo.Alerts', N'U') IS NULL
BEGIN
    -- The index is declared inline so the table and its index are created by one statement.
    CREATE TABLE [dbo].[Alerts] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [AccountId] UNIQUEIDENTIFIER NOT NULL,
        [Type] VARCHAR(12) COLLATE Latin1_General_BIN2 NOT NULL CHECK (([Type] = 'TARGET_PRICE' AND DATALENGTH([Type]) = 12) OR ([Type] = 'PROFIT_LOSS' AND DATALENGTH([Type]) = 11)),
        [InstrumentId] UNIQUEIDENTIFIER NOT NULL,
        [Direction] VARCHAR(5) COLLATE Latin1_General_BIN2 NOT NULL CHECK ([Direction] IN ('ABOVE', 'BELOW') AND DATALENGTH([Direction]) = 5),
        [Threshold] DECIMAL (18, 8) NOT NULL,
        [Enabled] BIT NOT NULL DEFAULT 1,
        [ArmingRevision] INT NOT NULL DEFAULT 1,
        [TriggeredAt] datetimeoffset(6) NULL,
        [TriggerValue] DECIMAL (28, 8) NULL,
        [Acknowledged] BIT NOT NULL DEFAULT 0,
        [CreatedAt] datetimeoffset(6) NOT NULL,
        CONSTRAINT [PK_Alerts] PRIMARY KEY CLUSTERED ([Id] ASC) ON [PRIMARY],
        CONSTRAINT [FK_Alerts_Accounts] FOREIGN KEY ([AccountId]) REFERENCES [Accounts]([Id]) ON DELETE CASCADE,
        CONSTRAINT [FK_Alerts_Instruments] FOREIGN KEY ([InstrumentId]) REFERENCES [Instruments]([Id]),
        INDEX [IX_Alerts_AccountId] NONCLUSTERED ([AccountId], [CreatedAt])
    );
END
GO
