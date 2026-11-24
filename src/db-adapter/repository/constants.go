package repository

const (
	TableAccounts              = "Accounts"
	TableAlerts                = "Alerts"
	TableBalances              = "Balance"
	TableBalanceHistory        = "Balancehistory"
	TableCreditCardOrders      = "CreditCardOrders"
	TableCreditCardOrderStatus = "CreditCardOrderStatus"
	TableCreditCards           = "CreditCards"
	TableInstruments           = "Instruments"
	TableOwnedInstruments      = "Ownedinstruments"
	TablePackages              = "Packages"
	TablePrices                = "Pricing"
	TableProducts              = "Products"
	TableTrades                = "Trades"
)

const (
	ColID                = "Id"
	ColAccountID         = "AccountId"
	ColInstrumentID      = "InstrumentId"
	ColCreditCardOrderID = "CreditCardOrderId"
	ColUsername          = "Username"
	ColOrigin            = "Origin"
	ColCreationDate      = "CreationDate"
	ColActionDate        = "ActionDate"
	ColTimestamp         = "Timestamp"
	ColStatus            = "Status"
	ColDirection         = "Direction"
	ColTradeClosed       = "TradeClosed"
	ColTimestampOpen     = "TimestampOpen"
	ColTimestampClose    = "TimestampClose"
	ColType              = "Type"
	ColThreshold         = "Threshold"
	ColEnabled           = "Enabled"
	ColArmingRevision    = "ArmingRevision"
	ColTriggeredAt       = "TriggeredAt"
	ColTriggerValue      = "TriggerValue"
	ColAcknowledged      = "Acknowledged"
	ColCreatedAt         = "CreatedAt"
)

const (
	StatusOrderCreated   = "order_created"
	DirectionLongBuy     = "longbuy"
	DirectionLongSell    = "longsell"
	AlertTypeTargetPrice = "TARGET_PRICE"
	AlertTypeProfitLoss  = "PROFIT_LOSS"
	AlertDirectionAbove  = "ABOVE"
	AlertDirectionBelow  = "BELOW"
)
