package sql

import (
	"context"
	dbsql "database/sql"
	"database/sql/driver"
	"fmt"
	"strings"
	"time"

	pb "github.com/dynatrace/easytrade/dbadapter/proto"
	"github.com/dynatrace/easytrade/dbadapter/repository"
	"github.com/google/uuid"
	"google.golang.org/protobuf/types/known/timestamppb"
	"gorm.io/gorm"
)

// Enabled, ArmingRevision and Acknowledged carry no gorm default tag on purpose: GORM leaves a
// zero-valued field with a default out of the INSERT, so false and 0 would never be written.
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

func NewAlertRepository(db *gorm.DB) repository.AlertRepository {
	return &AlertRepository{db: db}
}

func (repo *AlertRepository) Create(ctx context.Context, req *pb.CreateAlertRequest) (*pb.AlertMessage, error) {
	dbAlert := alertCreateFromProto(req, alertNow())
	if err := repo.db.WithContext(ctx).Create(dbAlert).Error; err != nil {
		return nil, err
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
	orderColumn := repository.ColCreatedAt
	if req.TriggeredOnly {
		orderColumn = repository.ColTriggeredAt
	}
	return findAndMapAll(query.Order(q(orderColumn)+" DESC, "+q(repository.ColID)+" DESC"), (*Alert).toProto)
}

func (repo *AlertRepository) GetByID(ctx context.Context, id string) (*pb.AlertMessage, error) {
	return firstOptional(repo.db.WithContext(ctx).Where(q(repository.ColID)+" = ?", id), (*Alert).toProto)
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
	if err != nil {
		return nil, err
	}
	return snapshot, nil
}

func (repo *AlertRepository) Delete(ctx context.Context, id string) (int32, error) {
	affected, err := affectedRows(repo.db.WithContext(ctx).Where(q(repository.ColID)+" = ?", id).Delete(&Alert{}))
	if err != nil {
		return 0, err
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
		return false, res.Error
	}
	return res.RowsAffected > 0, nil
}

func (repo *AlertRepository) Acknowledge(ctx context.Context, id string) (int32, error) {
	affected, err := affectedRows(repo.db.WithContext(ctx).Exec(alertAcknowledgeSQL, true, id))
	if err != nil {
		return 0, err
	}
	if affected > 0 {
		return affected, nil
	}
	// Zero rows is an unknown id or an arming that has not triggered. Only the latter is a no-op,
	// which never pre-acknowledges a future trigger
	if _, err := repo.GetByID(ctx, id); err != nil {
		return 0, err
	}
	return 0, nil
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

func (src *Alert) toProto() *pb.AlertMessage {
	msg := &pb.AlertMessage{
		Id:             uuidString(src.Id),
		AccountId:      uuidString(src.AccountId),
		Type:           src.Type,
		InstrumentId:   uuidString(src.InstrumentId),
		Direction:      src.Direction,
		Threshold:      src.Threshold.Text,
		Enabled:        src.Enabled,
		ArmingRevision: src.ArmingRevision,
		Acknowledged:   src.Acknowledged,
		CreatedAt:      timestamppb.New(src.CreatedAt),
	}
	if src.TriggeredAt != nil {
		msg.TriggeredAt = timestamppb.New(*src.TriggeredAt)
	}
	if src.TriggerValue.Valid {
		msg.TriggerValue = src.TriggerValue.Text
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

// Value sends the validated, normalised text unchanged; the database converts it to DECIMAL exactly
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

// normalizeDecimalText turns the column's fixed-scale text ("1.50000000") into the form the broker
// writes ("1.5"): no trailing fractional zeros, no trailing point, a leading 0 before the point and no
// negative zero, so every accepted value reads back as the identical string
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
