package sql

import (
	"context"
	dbsql "database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"net"
	"slices"
	"strings"
	"time"

	pb "github.com/dynatrace/easytrade/dbadapter/proto"
	"github.com/dynatrace/easytrade/dbadapter/repository"
	"github.com/google/uuid"
	"google.golang.org/protobuf/types/known/timestamppb"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// Enabled, ArmingRevision and Acknowledged carry no gorm default tags, so GORM writes the fields as
// they are and the adapter sends its initial values (true, 1, false) explicitly in the INSERT.
// CreatedAt is stamped by the adapter clock, never by GORM.
type Alert struct {
	Id             *uuid.UUID `gorm:"primaryKey;default:(-)"`
	AccountId      *uuid.UUID
	Type           string
	InstrumentId   *uuid.UUID
	Direction      string
	Threshold      decimalText
	Enabled        bool
	ArmingRevision int32
	TriggeredAt    *time.Time
	TriggerValue   decimalText
	Acknowledged   bool
	CreatedAt      time.Time `gorm:"autoCreateTime:false"`
}

func (Alert) TableName() string { return repository.TableAlerts }

// AfterFind gives every Alert read, through First or Find, the UTC location the adapter writes in:
// pgx scans timestamptz into time.Local and go-mssqldb scans datetimeoffset into its stored offset.
// The instant and its microseconds are unchanged, and a nil TriggeredAt stays nil
func (src *Alert) AfterFind(*gorm.DB) error {
	src.CreatedAt = src.CreatedAt.UTC()
	if src.TriggeredAt != nil {
		triggeredAt := src.TriggeredAt.UTC()
		src.TriggeredAt = &triggeredAt
	}
	return nil
}

// Every value, booleans included, is a bound parameter: a boolean literal is valid on only one of
// the two dialects
var (
	// The only writer that clears the trigger fields and advances the arming revision
	alertRearmSQL = "UPDATE " + q(repository.TableAlerts) + " SET " +
		q(repository.ColEnabled) + " = ?, " +
		q(repository.ColTriggeredAt) + " = NULL, " +
		q(repository.ColTriggerValue) + " = NULL, " +
		q(repository.ColAcknowledged) + " = ?, " +
		q(repository.ColArmingRevision) + " = " + q(repository.ColArmingRevision) + " + 1" +
		" WHERE " + q(repository.ColID) + " = ?"

	alertDisableSQL = "UPDATE " + q(repository.TableAlerts) + " SET " +
		q(repository.ColEnabled) + " = ?" +
		" WHERE " + q(repository.ColID) + " = ?"

	// The only writer of a non-null TriggeredAt. The predicate tests the column the statement sets
	// and the arming revision, so concurrent or stale evaluators affect zero rows once one has won
	alertTriggerSQL = "UPDATE " + q(repository.TableAlerts) + " SET " +
		q(repository.ColTriggeredAt) + " = ?, " +
		q(repository.ColTriggerValue) + " = ?, " +
		q(repository.ColAcknowledged) + " = ?" +
		" WHERE " + q(repository.ColID) + " = ?" +
		" AND " + q(repository.ColArmingRevision) + " = ?" +
		" AND " + q(repository.ColEnabled) + " = ?" +
		" AND " + q(repository.ColTriggeredAt) + " IS NULL"

	alertAcknowledgeSQL = "UPDATE " + q(repository.TableAlerts) + " SET " +
		q(repository.ColAcknowledged) + " = ?" +
		" WHERE " + q(repository.ColID) + " = ?" +
		" AND " + q(repository.ColTriggeredAt) + " IS NOT NULL"
)

var _ repository.AlertRepository = (*AlertRepository)(nil)

type AlertRepository struct{ db *gorm.DB }

// Alert statements log through alertLogger, a session on the shared connection, so only their own
// error lines change; the shared gorm.Config and the other repositories' logging stay as they are
func NewAlertRepository(db *gorm.DB) repository.AlertRepository {
	return &AlertRepository{db: db.Session(&gorm.Session{NewDB: true, Logger: alertLogger{Interface: db.Logger}})}
}

func (repo *AlertRepository) Create(ctx context.Context, req *pb.CreateAlertRequest) (*pb.AlertMessage, error) {
	dbAlert := alertCreateFromProto(req, alertNow())
	if err := repo.db.WithContext(ctx).Create(dbAlert).Error; err != nil {
		return nil, safeAlertError(err)
	}
	return dbAlert.toProto(), nil
}

func (repo *AlertRepository) List(ctx context.Context, req *pb.ListAlertsRequest) ([]*pb.AlertMessage, error) {
	query := repo.db.WithContext(ctx)
	if req.AccountId != "" {
		query = query.Where(q(repository.ColAccountID)+" = ?", req.AccountId)
	}
	if req.ArmedOnly {
		query = query.Where(q(repository.ColEnabled)+" = ?", true).Where(q(repository.ColTriggeredAt) + " IS NULL")
	}
	if req.TriggeredOnly {
		query = query.Where(q(repository.ColTriggeredAt) + " IS NOT NULL")
	}
	if req.UnacknowledgedOnly {
		query = query.Where(q(repository.ColAcknowledged)+" = ?", false)
	}
	order := q(repository.ColCreatedAt) + " DESC, " + q(repository.ColID) + " DESC"
	if req.TriggeredOnly {
		order = q(repository.ColTriggeredAt) + " DESC"
	}
	alerts, err := findAndMapAll(query.Order(order), (*Alert).toProto)
	if err != nil {
		return nil, safeAlertError(err)
	}
	return alerts, nil
}

func (repo *AlertRepository) GetByID(ctx context.Context, id string) (*pb.AlertMessage, error) {
	alert, err := firstOptional(repo.db.WithContext(ctx).Where(q(repository.ColID)+" = ?", id), (*Alert).toProto)
	if err != nil {
		return nil, safeAlertError(err)
	}
	return alert, nil
}

func (repo *AlertRepository) UpdateEnabled(ctx context.Context, id string, enabled bool) (*pb.AlertMessage, error) {
	var snapshot *pb.AlertMessage
	err := repo.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var res *gorm.DB
		if enabled {
			res = tx.Exec(alertRearmSQL, true, false, id)
		} else {
			res = tx.Exec(alertDisableSQL, false, id)
		}
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return repository.ErrNotFound
		}
		// Read while this update's row lock is held, so the reply is exactly the state it wrote and
		// never another PATCH's revision or a later trigger
		msg, err := firstOptional(tx.Where(q(repository.ColID)+" = ?", id), (*Alert).toProto)
		if err != nil {
			return err
		}
		snapshot = msg
		return nil
	})
	// Transaction returns the callback's error or the one from Begin or Commit
	if err != nil {
		return nil, safeAlertError(err)
	}
	return snapshot, nil
}

func (repo *AlertRepository) Delete(ctx context.Context, id string) (int32, error) {
	affected, err := affectedRows(repo.db.WithContext(ctx).Where(q(repository.ColID)+" = ?", id).Delete(&Alert{}))
	if err != nil {
		return 0, safeAlertError(err)
	}
	if affected == 0 {
		return 0, repository.ErrNotFound
	}
	return affected, nil
}

func (repo *AlertRepository) Trigger(ctx context.Context, id string, armingRevision int32, triggerValue string) (bool, error) {
	res := repo.db.WithContext(ctx).Exec(
		alertTriggerSQL,
		alertNow(), decimalText{Text: triggerValue, Valid: true}, false,
		id, armingRevision, true,
	)
	if res.Error != nil {
		return false, safeAlertError(res.Error)
	}
	return res.RowsAffected > 0, nil
}

func (repo *AlertRepository) Acknowledge(ctx context.Context, id string) (int32, error) {
	affected, err := affectedRows(repo.db.WithContext(ctx).Exec(alertAcknowledgeSQL, true, id))
	if err != nil {
		return 0, safeAlertError(err)
	}
	if affected > 0 {
		return affected, nil
	}
	// Zero rows is an unknown id or an arming that has not triggered. Only the latter is a no-op,
	// which never pre-acknowledges a future trigger
	if _, err := repo.GetByID(ctx, id); err != nil {
		return 0, safeAlertError(err)
	}
	return 0, nil
}

// alertStorageError is how a failed alert statement is reported and logged. Driver errors can carry
// the database user, database name, host and constraint names, so Error gives only their
// classification. The driver error stays reachable through errors.Is and errors.As for a caller that
// branches on its code, and never appears in the text a log line or a status prints. A failure that
// stands for a repository sentinel matches it through errors.Is and is reported as that sentinel
type alertStorageError struct {
	class string
	// sentinel is the repository error the failure stands for, or nil for a storage failure
	sentinel error
	cause    error
}

func (e *alertStorageError) Error() string {
	if e.sentinel != nil {
		return e.sentinel.Error() + ": " + e.class
	}
	return "alert storage failure: " + e.class
}

func (e *alertStorageError) Unwrap() error { return e.cause }

func (e *alertStorageError) Is(target error) bool { return e.sentinel != nil && target == e.sentinel }

const (
	// PostgreSQL's foreign_key_violation
	pgForeignKeyViolation = "23503"
	// SQL Server reports CHECK and FOREIGN KEY conflicts under one number
	mssqlConstraintConflict = 547
)

// alertForeignKeys names the Alerts table's two foreign keys. SQL Server words error 547 in the
// session language but inserts the constraint name unchanged in every language, so the name, never
// the wording, tells a foreign-key conflict from a CHECK conflict: the table's CHECK constraints are
// unnamed, and SQL Server names them CK__Alerts__...
var alertForeignKeys = []string{"FK_Alerts_Accounts", "FK_Alerts_Instruments"}

// safeAlertError keeps the sentinels callers branch on and replaces any other error with its class:
// a SQLSTATE (pgx), a SQL Server error number (go-mssqldb), a connection failure or unclassified. A
// foreign-key violation, an account or instrument id that names no row, also matches
// ErrAlertReferenceNotFound
func safeAlertError(err error) error {
	var (
		safe   *alertStorageError
		pgErr  interface{ SQLState() string }
		msErr  interface{ SQLErrorNumber() int32 }
		netErr net.Error
	)
	switch {
	case err == nil:
		return nil
	// Already classified, as GetByID's error is when Acknowledge returns it
	case errors.As(err, &safe):
		return safe
	case errors.Is(err, repository.ErrNotFound):
		return repository.ErrNotFound
	case errors.Is(err, gorm.ErrRecordNotFound):
		return gorm.ErrRecordNotFound
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case errors.As(err, &pgErr):
		// pgx copies the server's code field unchecked, so a malformed reply could carry any text,
		// control characters included, into the logs. Only the SQLSTATE form (five characters, each
		// 0-9 or A-Z) is kept
		code := pgErr.SQLState()
		if len(code) != 5 {
			return &alertStorageError{class: "unclassified", cause: err}
		}
		for i := range len(code) {
			if c := code[i]; (c < '0' || c > '9') && (c < 'A' || c > 'Z') {
				return &alertStorageError{class: "unclassified", cause: err}
			}
		}
		if code == pgForeignKeyViolation {
			return &alertStorageError{class: "SQLSTATE " + code, sentinel: repository.ErrAlertReferenceNotFound, cause: err}
		}
		return &alertStorageError{class: "SQLSTATE " + code, cause: err}
	case errors.As(err, &msErr):
		number := msErr.SQLErrorNumber()
		class := fmt.Sprintf("SQL Server error %d", number)
		// go-mssqldb's Error also gives the message. A 547 naming one of the Alerts foreign keys is a
		// reference to no row, whatever the session language; any other 547, or one without a
		// message, keeps the generic class
		if msg, ok := msErr.(interface{ SQLErrorMessage() string }); ok && number == mssqlConstraintConflict &&
			slices.ContainsFunc(alertForeignKeys, func(name string) bool { return strings.Contains(msg.SQLErrorMessage(), name) }) {
			return &alertStorageError{class: class, sentinel: repository.ErrAlertReferenceNotFound, cause: err}
		}
		return &alertStorageError{class: class, cause: err}
	case errors.As(err, &netErr), errors.Is(err, driver.ErrBadConn), errors.Is(err, dbsql.ErrConnDone):
		return &alertStorageError{class: "connection failure", cause: err}
	default:
		return &alertStorageError{class: "unclassified", cause: err}
	}
}

// alertLogger passes each alert statement's error to the shared GORM logger as safeAlertError's
// classification. The statement text, duration and row count are logged as before; GORM reports
// Trace below as the caller, so the statement text identifies the call. An unknown account or
// instrument is the caller's mistake, not a storage failure, so its statement is logged as a warning
// in GORM's trace layout instead of as an error
type alertLogger struct{ logger.Interface }

var (
	_ logger.Interface  = alertLogger{}
	_ gorm.ParamsFilter = alertLogger{}
)

func (l alertLogger) LogMode(level logger.LogLevel) logger.Interface {
	return alertLogger{l.Interface.LogMode(level)}
}

func (l alertLogger) Trace(ctx context.Context, begin time.Time, fc func() (string, int64), err error) {
	safe := safeAlertError(err)
	if !errors.Is(safe, repository.ErrAlertReferenceNotFound) {
		l.Interface.Trace(ctx, begin, fc, safe)
		return
	}
	sql, rows := fc()
	// GORM prints an unknown row count as "-"
	var shownRows any = rows
	if rows == -1 {
		shownRows = "-"
	}
	l.Interface.Warn(ctx, "%v\n[%.3fms] [rows:%v] %s", safe, float64(time.Since(begin).Nanoseconds())/1e6, shownRows, sql)
}

// ParamsFilter keeps the shared logger's parameter setting, which the embedded interface would hide
func (l alertLogger) ParamsFilter(ctx context.Context, sql string, params ...any) (string, []any) {
	if filter, ok := l.Interface.(gorm.ParamsFilter); ok {
		return filter.ParamsFilter(ctx, sql, params...)
	}
	return sql, params
}

// Both timestamp column types hold microseconds, so the value returned equals the value stored
func alertNow() time.Time { return time.Now().UTC().Truncate(time.Microsecond) }

func alertCreateFromProto(req *pb.CreateAlertRequest, createdAt time.Time) *Alert {
	return &Alert{
		AccountId:      parseUUID(req.AccountId),
		Type:           req.Type,
		InstrumentId:   parseUUID(req.InstrumentId),
		Direction:      req.Direction,
		Threshold:      decimalText{Text: req.Threshold, Valid: true},
		Enabled:        true,
		ArmingRevision: 1,
		Acknowledged:   false,
		CreatedAt:      createdAt,
	}
}

// Create replies from the request's text, which the RPC pattern accepts as "-0", while a read scans
// the column back; normalising both decimals here gives every reply the canonical text a read gives
func (src *Alert) toProto() *pb.AlertMessage {
	msg := &pb.AlertMessage{
		Id:             uuidString(src.Id),
		AccountId:      uuidString(src.AccountId),
		Type:           src.Type,
		InstrumentId:   uuidString(src.InstrumentId),
		Direction:      src.Direction,
		Threshold:      normalizeDecimalText(src.Threshold.Text),
		Enabled:        src.Enabled,
		ArmingRevision: src.ArmingRevision,
		Acknowledged:   src.Acknowledged,
		CreatedAt:      timestamppb.New(src.CreatedAt),
	}
	if src.TriggeredAt != nil {
		msg.TriggeredAt = timestamppb.New(*src.TriggeredAt)
	}
	if src.TriggerValue.Valid {
		msg.TriggerValue = normalizeDecimalText(src.TriggerValue.Text)
	}
	return msg
}

// decimalText carries a DECIMAL column as exact decimal text, so no value passes through a float.
// Text must stay the first field: GORM takes a Valuer struct's data type from its first field, as
// it does for sql.NullString.
type decimalText struct {
	Text  string
	Valid bool
}

var (
	_ driver.Valuer = decimalText{}
	_ dbsql.Scanner = (*decimalText)(nil)
)

// Value sends the validated text unchanged, "-0" included; the database converts it to DECIMAL exactly
func (d decimalText) Value() (driver.Value, error) {
	if !d.Valid {
		return nil, nil
	}
	return d.Text, nil
}

// Scan reads each driver's text form: pgx returns numeric as string, go-mssqldb returns DECIMAL as []byte
func (d *decimalText) Scan(src any) error {
	switch v := src.(type) {
	case nil:
		*d = decimalText{}
	case string:
		*d = decimalText{Text: normalizeDecimalText(v), Valid: true}
	case []byte:
		*d = decimalText{Text: normalizeDecimalText(string(v)), Valid: true}
	default:
		return fmt.Errorf("decimalText: unsupported scan source %T", src)
	}
	return nil
}

// normalizeDecimalText turns the column's fixed-scale text ("1.50000000") into the broker's normalised
// form ("1.5"): no trailing fractional zeros or point, a leading 0 before the point, no negative zero.
// A read returns the exact stored value as canonical text: the text written, except "-0" reads as "0"
func normalizeDecimalText(s string) string {
	sign, digits := "", s
	if strings.HasPrefix(digits, "-") {
		sign, digits = "-", digits[1:]
	}
	if strings.HasPrefix(digits, ".") {
		digits = "0" + digits
	}
	if strings.Contains(digits, ".") {
		digits = strings.TrimSuffix(strings.TrimRight(digits, "0"), ".")
	}
	if digits == "0" {
		return digits
	}
	return sign + digits
}
