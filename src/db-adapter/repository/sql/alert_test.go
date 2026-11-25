package sql

import (
	"bytes"
	"context"
	dbsql "database/sql"
	"database/sql/driver"
	"errors"
	"flag"
	"fmt"
	"io"
	stdlog "log"
	"net"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dynatrace/easytrade/dbadapter/config"
	"github.com/dynatrace/easytrade/dbadapter/db"
	pb "github.com/dynatrace/easytrade/dbadapter/proto"
	"github.com/dynatrace/easytrade/dbadapter/repository"
	"github.com/dynatrace/easytrade/dbadapter/server"
	"github.com/google/uuid"
	log "github.com/sirupsen/logrus"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/wrapperspb"
	"gorm.io/driver/postgres"
	"gorm.io/driver/sqlserver"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// The real-database cases opt in through a test-binary flag rather than an environment variable, so
// no test-only setting needs a place in the deployment manifests. They reuse DB_TYPE and DB_URL:
//
//	go test ./repository/sql/ -run TestAlertRepository -args -integration
var integration = flag.Bool("integration", false, "run alert repository tests against the database in DB_TYPE/DB_URL")

const (
	// Seeded INTERNAL owner account and first instrument, identical on both dialects. The account is
	// seeded with no holdings, but an evaluator checks TARGET_PRICE alerts without consulting holdings
	testOwnerAccountID = "a0000000-0000-4000-8000-000000000000"
	testInstrumentID   = "c0000000-0000-4000-8000-000000000001"
	// The threshold domain maximum: the largest accepted threshold and the DECIMAL(18, 8) maximum. It
	// bounds thresholds, not observed prices, so a TARGET_PRICE ABOVE it only makes a stray trigger
	// unlikely. The rows these tests create are isolated from a live evaluator only while no broker
	// evaluates this database's alerts: no broker-service uses the database, or
	// portfolio-insights-enabled stays off for the whole run and every evaluation cycle that started
	// while it was on has finished. A broker checks the flag only as a cycle starts, and a cycle past
	// that check still lists armed alerts and triggers the crossed ones after the flag is switched off
	thresholdDomainMax = "9999999999.99999999"
)

var (
	alertBackendOnce sync.Once
	alertBackend     *sqlBackend
	alertBackendErr  error
)

// alertTestBackend connects once per test binary. Skip and Fatal stay outside the Once: both end the
// goroutine, which would mark the Once done and leave every later test with a nil backend.
func alertTestBackend(t *testing.T) *sqlBackend {
	t.Helper()
	if !*integration {
		t.Skip("needs -integration and DB_TYPE/DB_URL")
	}
	alertBackendOnce.Do(func() {
		alertBackend, alertBackendErr = connectAlertTestBackend(config.Load().Database)
	})
	// With the flag set, a missing or unreachable database fails the run instead of skipping it. The
	// error names the setting or the stage that failed and never carries DB_URL or a parser message
	if alertBackendErr != nil {
		t.Fatalf("alert repository tests need a database: %v", alertBackendErr)
	}
	return alertBackend
}

// connectAlertTestBackend validates the settings, then connects through the backend for DB_TYPE. Its
// errors name a setting or a stage, never the DB_URL value
func connectAlertTestBackend(cfg config.DatabaseConfig) (*sqlBackend, error) {
	if cfg.Url == "" {
		return nil, errors.New("DB_URL is not set")
	}
	// db.Connect hands the interval to time.NewTicker, which panics on the zero and negative durations
	// the shared loader accepts
	if cfg.RetryInterval <= 0 {
		return nil, fmt.Errorf("DB_RETRY_INTERVAL must be a positive duration, got %s", cfg.RetryInterval)
	}
	// Each probe is the dialector NewPostgresBackend or NewMSSQLBackend builds from DB_URL, and onPool
	// is the same driver over the pool that probe opens
	var probe gorm.Dialector
	var onPool func(*dbsql.DB) gorm.Dialector
	switch cfg.Type {
	case "postgres":
		probe = postgres.Open(cfg.Url)
		onPool = func(pool *dbsql.DB) gorm.Dialector { return postgres.New(postgres.Config{Conn: pool}) }
	case "mssql":
		probe = sqlserver.Open(withGuidConversion(cfg.Url))
		onPool = func(pool *dbsql.DB) gorm.Dialector { return sqlserver.New(sqlserver.Config{Conn: pool}) }
	default:
		return nil, fmt.Errorf("unsupported DB_TYPE %q", cfg.Type)
	}
	pool, err := openAlertTestPool(cfg.Type, probe)
	if err != nil {
		return nil, err
	}
	sb, err := connectAlertTestPool(cfg, pool, onPool(pool))
	if err != nil {
		err = fmt.Errorf("connecting with DB_TYPE=%s within DB_CONNECT_TIMEOUT=%s: %w", cfg.Type, cfg.ConnectTimeout, err)
		if closeErr := pool.Close(); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("closing the DB_URL pool for DB_TYPE=%s: %w", cfg.Type, closeErr))
		}
		return nil, err
	}
	return sb, nil
}

// openAlertTestPool parses DB_URL, the only time it is parsed, through the probe dialector into a pool,
// without connecting or logging. A parser error can echo the connection string and its password: pgx
// redacts on a best-effort basis and go-mssqldb repeats rejected values, so the error reports neither
func openAlertTestPool(dbType string, probe gorm.Dialector) (*dbsql.DB, error) {
	opened, err := gorm.Open(probe, &gorm.Config{Logger: logger.Discard, DisableAutomaticPing: true})
	if err != nil {
		return nil, fmt.Errorf("checking DB_URL for DB_TYPE=%s: the connection string is invalid (value and parser message withheld: either can contain the password)", dbType)
	}
	pool, err := opened.DB()
	if err != nil {
		return nil, fmt.Errorf("checking DB_URL for DB_TYPE=%s: %w", dbType, err)
	}
	return pool, nil
}

// connectAlertTestPool waits until pool answers a ping, then builds through newBackend the backend
// NewPostgresBackend or NewMSSQLBackend builds, with their dialector over the pool DB_URL was parsed
// into once. No attempt parses DB_URL again, so db.Connect's retry log and error carry connection
// failures only. The wait comes first because gorm.Open, inside newBackend, closes the pool when its
// own ping fails
func connectAlertTestPool(cfg config.DatabaseConfig, pool *dbsql.DB, dialector gorm.Dialector) (*sqlBackend, error) {
	if _, err := db.Connect(context.Background(), db.ConnectOptions{
		Timeout:       cfg.ConnectTimeout,
		RetryInterval: cfg.RetryInterval,
	}, func() (struct{}, error) { return struct{}{}, pool.Ping() }); err != nil {
		return nil, err
	}
	backend, err := newBackend(cfg, dialector)
	if err != nil {
		return nil, err
	}
	sb, ok := backend.(*sqlBackend)
	if !ok {
		return nil, fmt.Errorf("DB_TYPE %q gave a %T backend, not *sqlBackend", cfg.Type, backend)
	}
	return sb, nil
}

// createTestAlert creates an alert on the seeded owner account and instrument and deletes it when the
// test ends. Cleanup uses context.Background because t.Context is cancelled before cleanups run.
func createTestAlert(t *testing.T, repo repository.AlertRepository, typ, direction, threshold string) *pb.AlertMessage {
	t.Helper()
	alert, err := repo.Create(context.Background(), &pb.CreateAlertRequest{
		AccountId:    testOwnerAccountID,
		Type:         typ,
		InstrumentId: testInstrumentID,
		Direction:    direction,
		Threshold:    threshold,
	})
	if err != nil {
		t.Fatalf("Create(%s %s %s): %v", typ, direction, threshold, err)
	}
	t.Cleanup(func() {
		if _, err := repo.Delete(context.Background(), alert.Id); err != nil && !errors.Is(err, repository.ErrNotFound) {
			t.Errorf("cleanup Delete(%s): %v", alert.Id, err)
		}
	})
	return alert
}

// createArmedTestAlert creates an armed TARGET_PRICE ABOVE alert at the threshold domain maximum. Only
// the test itself triggers it while no broker-service uses the database, or while
// portfolio-insights-enabled stays off for the whole run and every evaluation cycle that started while
// it was on has finished (see thresholdDomainMax)
func createArmedTestAlert(t *testing.T, repo repository.AlertRepository) *pb.AlertMessage {
	t.Helper()
	return createTestAlert(t, repo, repository.AlertTypeTargetPrice, repository.AlertDirectionAbove, thresholdDomainMax)
}

func getTestAlert(t *testing.T, repo repository.AlertRepository, id string) *pb.AlertMessage {
	t.Helper()
	alert, err := repo.GetByID(context.Background(), id)
	if err != nil {
		t.Fatalf("GetByID(%s): %v", id, err)
	}
	return alert
}

func mustTrigger(t *testing.T, repo repository.AlertRepository, id string, armingRevision int32, triggerValue string) {
	t.Helper()
	triggered, err := repo.Trigger(context.Background(), id, armingRevision, triggerValue)
	if err != nil {
		t.Fatalf("Trigger(%s, %d, %s): %v", id, armingRevision, triggerValue, err)
	}
	if !triggered {
		t.Fatalf("Trigger(%s, %d, %s) = false, want true", id, armingRevision, triggerValue)
	}
}

func mustUpdateEnabled(t *testing.T, repo repository.AlertRepository, id string, enabled bool) *pb.AlertMessage {
	t.Helper()
	snapshot, err := repo.UpdateEnabled(context.Background(), id, enabled)
	if err != nil {
		t.Fatalf("UpdateEnabled(%s, %t): %v", id, enabled, err)
	}
	return snapshot
}

// awaitAdapterClockAfter returns once the adapter clock reads later than ts. Two sequential calls can
// land in one wall-clock tick (about 0.3 ms on Windows), which ties their timestamps and leaves the
// order to the Id tie-break; this waits on that clock condition, never for a fixed time.
func awaitAdapterClockAfter(ts time.Time) {
	for !alertNow().After(ts) {
		runtime.Gosched()
	}
}

// listOwnAlertIDs lists with req and keeps only the given ids, in the order returned, because other
// rows (a running stack's, another test run's) may share the table
func listOwnAlertIDs(t *testing.T, repo repository.AlertRepository, req *pb.ListAlertsRequest, own ...string) []string {
	t.Helper()
	alerts, err := repo.List(context.Background(), req)
	if err != nil {
		t.Fatalf("List(%v): %v", req, err)
	}
	ids := []string{}
	for _, alert := range alerts {
		if slices.Contains(own, alert.Id) {
			ids = append(ids, alert.Id)
		}
	}
	return ids
}

func sortedIDs(ids ...string) []string {
	sorted := slices.Clone(ids)
	slices.Sort(sorted)
	return sorted
}

func cloneAlert(alert *pb.AlertMessage) *pb.AlertMessage {
	return proto.Clone(alert).(*pb.AlertMessage)
}

// deleteAlertAtCleanup deletes the alert by id when the test ends; a row already absent is clean
func deleteAlertAtCleanup(t *testing.T, repo repository.AlertRepository, id string) {
	t.Helper()
	t.Cleanup(func() {
		if _, err := repo.Delete(context.Background(), id); err != nil && !errors.Is(err, repository.ErrNotFound) {
			t.Errorf("cleanup Delete(%s): %v", id, err)
		}
	})
}

// insertRawAlert inserts an alert on the seeded owner account and instrument with a plain INSERT
// and deletes it by id when the test ends. It bypasses the repository and its validation, so only
// the table's own constraints judge the values; the caller's id and CreatedAt let a test read the
// row back and fix the creation order.
func insertRawAlert(t *testing.T, b *sqlBackend, id, typ, direction string, createdAt time.Time) error {
	t.Helper()
	deleteAlertAtCleanup(t, b.Alert(), id)
	columns := []string{
		repository.ColID, repository.ColAccountID, repository.ColType, repository.ColInstrumentID,
		repository.ColDirection, repository.ColThreshold, repository.ColEnabled, repository.ColArmingRevision,
		repository.ColAcknowledged, repository.ColCreatedAt,
	}
	quoted := make([]string, len(columns))
	for i, column := range columns {
		quoted[i] = q(column)
	}
	insertSQL := "INSERT INTO " + q(repository.TableAlerts) + " (" + strings.Join(quoted, ", ") + ")" +
		" VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
	return b.gormDB.WithContext(context.Background()).Exec(insertSQL,
		id, testOwnerAccountID, typ, testInstrumentID, direction, "1", true, 1, false, createdAt,
	).Error
}

// pgDriverError and mssqlDriverError hold the methods of the drivers' error types, pgconn.PgError
// and mssql.Error. Matching through them classifies a rejection without importing either driver,
// which the module carries only indirectly through GORM.
type pgDriverError interface {
	error
	SQLState() string
}

type mssqlDriverError interface {
	error
	SQLErrorNumber() int32
}

// dialectError is one kind of database rejection as each dialect reports it. An error matches when
// its driver's code is listed for that dialect and its message contains every listed fragment.
type dialectError struct {
	name         string
	pgStates     []string
	pgText       []string
	mssqlNumbers []int32
	mssqlText    []string
}

func (want dialectError) matches(err error) bool {
	var pgErr pgDriverError
	if errors.As(err, &pgErr) {
		return slices.Contains(want.pgStates, pgErr.SQLState()) && containsAll(pgErr.Error(), want.pgText)
	}
	var mssqlErr mssqlDriverError
	if errors.As(err, &mssqlErr) {
		return slices.Contains(want.mssqlNumbers, mssqlErr.SQLErrorNumber()) && containsAll(mssqlErr.Error(), want.mssqlText)
	}
	return false
}

func containsAll(s string, fragments []string) bool {
	for _, fragment := range fragments {
		if !strings.Contains(s, fragment) {
			return false
		}
	}
	return true
}

// checkViolation is the rejection by a column's CHECK. PostgreSQL names an unnamed column CHECK
// <table>_<column>_check; SQL Server generates the name and gives the column in the message.
func checkViolation(column string) dialectError {
	return dialectError{
		name:         "CHECK violation on " + column,
		pgStates:     []string{"23514"},
		pgText:       []string{`"` + repository.TableAlerts + "_" + column + `_check"`},
		mssqlNumbers: []int32{547},
		mssqlText:    []string{"CHECK constraint", "column '" + column + "'"},
	}
}

// foreignKeyViolation is the rejection by a named FOREIGN KEY. SQL Server reports CHECK and FOREIGN
// KEY conflicts under one number, so its message decides which.
func foreignKeyViolation(constraint string) dialectError {
	return dialectError{
		name:         "FOREIGN KEY violation on " + constraint,
		pgStates:     []string{"23503"},
		pgText:       []string{`"` + constraint + `"`},
		mssqlNumbers: []int32{547},
		mssqlText:    []string{"FOREIGN KEY constraint", `"` + constraint + `"`},
	}
}

var (
	// A value longer than its column; SQL Server reports 8152, or 2628 from compatibility level 150
	stringTruncation = dialectError{name: "string truncation", pgStates: []string{"22001"}, mssqlNumbers: []int32{8152, 2628}}
	// Text that does not convert to uuid or uniqueidentifier
	invalidUUIDText = dialectError{name: "invalid uuid text", pgStates: []string{"22P02"}, mssqlNumbers: []int32{8169}}
)

func TestAlertRepository_createAndGet_roundTrip(t *testing.T) {
	repo := alertTestBackend(t).Alert()

	created := createTestAlert(t, repo, repository.AlertTypeTargetPrice, repository.AlertDirectionAbove, "123.45")

	if _, err := uuid.Parse(created.Id); err != nil {
		t.Fatalf("Create returned id %q, want a database-generated UUID: %v", created.Id, err)
	}
	if created.CreatedAt == nil || created.CreatedAt.AsTime().IsZero() {
		t.Fatalf("Create returned CreatedAt %v, want the adapter clock", created.CreatedAt)
	}
	want := &pb.AlertMessage{
		Id:             created.Id,
		AccountId:      testOwnerAccountID,
		Type:           repository.AlertTypeTargetPrice,
		InstrumentId:   testInstrumentID,
		Direction:      repository.AlertDirectionAbove,
		Threshold:      "123.45",
		Enabled:        true,
		ArmingRevision: 1,
		Acknowledged:   false,
		CreatedAt:      created.CreatedAt,
	}
	if !proto.Equal(created, want) {
		t.Errorf("Create = %v, want %v", created, want)
	}
	if got := getTestAlert(t, repo, created.Id); !proto.Equal(got, created) {
		t.Errorf("GetByID = %v, want the created alert %v", got, created)
	}
}

func TestAlertRepository_decimalBoundaries_roundTripExact(t *testing.T) {
	repo := alertTestBackend(t).Alert()

	thresholds := []struct {
		name      string
		typ       string
		direction string
		threshold string
	}{
		{"smallestTargetPrice", repository.AlertTypeTargetPrice, repository.AlertDirectionBelow, "0.00000001"},
		{"largestTargetPrice", repository.AlertTypeTargetPrice, repository.AlertDirectionAbove, "9999999999.99999999"},
		{"mostNegativeProfitLoss", repository.AlertTypeProfitLoss, repository.AlertDirectionBelow, "-9999999999.99999999"},
		// The column returns 1.50000000; normalisation must give back the text the broker sent
		{"fixedScaleNormalized", repository.AlertTypeTargetPrice, repository.AlertDirectionBelow, "1.5"},
	}
	for _, tc := range thresholds {
		t.Run("threshold/"+tc.name, func(t *testing.T) {
			created := createTestAlert(t, repo, tc.typ, tc.direction, tc.threshold)

			if got := getTestAlert(t, repo, created.Id).Threshold; got != tc.threshold {
				t.Errorf("Threshold read back as %q, want %q", got, tc.threshold)
			}
		})
	}

	triggerValues := []struct {
		name  string
		value string
	}{
		{"largest", "99999999999999999999.99999999"},
		{"mostNegative", "-99999999999999999999.99999999"},
	}
	for _, tc := range triggerValues {
		t.Run("triggerValue/"+tc.name, func(t *testing.T) {
			created := createArmedTestAlert(t, repo)
			mustTrigger(t, repo, created.Id, 1, tc.value)

			if got := getTestAlert(t, repo, created.Id).TriggerValue; got != tc.value {
				t.Errorf("TriggerValue read back as %q, want %q", got, tc.value)
			}
		})
	}
}

// The RPC pattern accepts "-0" for PROFIT_LOSS and the adapter binds it unchanged; the reply to Create
// and every later read must both give the canonical "0"
func TestAlertRepository_createNegativeZeroThreshold_canonicalZero(t *testing.T) {
	repo := alertTestBackend(t).Alert()

	created := createTestAlert(t, repo, repository.AlertTypeProfitLoss, repository.AlertDirectionBelow, "-0")

	read := getTestAlert(t, repo, created.Id)
	if created.Threshold != "0" || read.Threshold != "0" {
		t.Errorf("Threshold from Create %q and GetByID %q, want both %q", created.Threshold, read.Threshold, "0")
	}
}

// utcInstant reports whether got is want's instant, to the nanosecond, in the UTC location itself
func utcInstant(got, want time.Time) bool { return got.Location() == time.UTC && got.Equal(want) }

// pgx gives a scanned timestamptz the process zone, time.Local, and go-mssqldb gives a datetimeoffset
// its stored offset. Both are made non-UTC here, so only the alert read path can return UTC. Setting
// time.Local is why this test must not run in parallel with another
func TestAlertRepository_readInNonUTCZone_timestampsUTC(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	session := repo.(*AlertRepository).db
	ctx := context.Background()
	processLocal := time.Local
	time.Local = time.FixedZone("UTC+05:30", 5*60*60+30*60)
	t.Cleanup(func() { time.Local = processLocal })

	alert := createArmedTestAlert(t, repo)
	wantCreatedAt := alert.CreatedAt.AsTime()
	// The trigger statement with a known instant in a third zone, at the microseconds both columns hold
	wantTriggeredAt := time.Date(2025, time.March, 30, 1, 2, 3, 456789000, time.FixedZone("UTC-03:30", -(3*60*60+30*60)))
	res := session.WithContext(ctx).Exec(alertTriggerSQL,
		wantTriggeredAt, decimalText{Text: "5", Valid: true}, false, alert.Id, alert.ArmingRevision, true)
	if res.Error != nil || res.RowsAffected != 1 {
		t.Fatalf("trigger at %v = (%d rows, %v), want (1 row, nil)", wantTriggeredAt, res.RowsAffected, res.Error)
	}

	byID := func() *gorm.DB { return session.WithContext(ctx).Where(q(repository.ColID)+" = ?", alert.Id) }
	model := func(a *Alert) *Alert { return a }
	reads := []struct {
		name string
		read func() (*Alert, error)
	}{
		// GetByID and UpdateEnabled's in-transaction snapshot read one row through First
		{"first", func() (*Alert, error) { return firstOptional(byID(), model) }},
		// List reads its rows through Find
		{"find", func() (*Alert, error) {
			alerts, err := findAndMapAll(byID(), model)
			if err != nil {
				return nil, err
			}
			if len(alerts) != 1 {
				return nil, fmt.Errorf("found %d rows, want 1", len(alerts))
			}
			return alerts[0], nil
		}},
	}
	for _, tc := range reads {
		t.Run(tc.name, func(t *testing.T) {
			got, err := tc.read()
			if err != nil {
				t.Fatalf("reading alert %s: %v", alert.Id, err)
			}

			if !utcInstant(got.CreatedAt, wantCreatedAt) || got.TriggeredAt == nil || !utcInstant(*got.TriggeredAt, wantTriggeredAt) {
				t.Errorf("read CreatedAt %v and TriggeredAt %v, want %v and %v, both in UTC",
					got.CreatedAt, got.TriggeredAt, wantCreatedAt.UTC(), wantTriggeredAt.UTC())
			}
		})
	}
}

func TestAlertRepository_list_newestFirst(t *testing.T) {
	repo := alertTestBackend(t).Alert()

	older := createArmedTestAlert(t, repo)
	awaitAdapterClockAfter(older.CreatedAt.AsTime())
	newer := createArmedTestAlert(t, repo)

	alerts, err := repo.List(context.Background(), &pb.ListAlertsRequest{AccountId: testOwnerAccountID})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	var own []*pb.AlertMessage
	for _, alert := range alerts {
		if alert.Id == older.Id || alert.Id == newer.Id {
			own = append(own, alert)
		}
	}
	if len(own) != 2 || own[0].Id != newer.Id || own[1].Id != older.Id {
		t.Fatalf("List returned own alerts %v, want [%s %s]", own, newer.Id, older.Id)
	}
	if !own[0].CreatedAt.AsTime().After(own[1].CreatedAt.AsTime()) {
		t.Errorf("newest CreatedAt %v is not after %v", own[0].CreatedAt.AsTime(), own[1].CreatedAt.AsTime())
	}
}

func TestAlertRepository_listFilters_apply(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	ctx := context.Background()

	armed := createArmedTestAlert(t, repo)
	triggered := createArmedTestAlert(t, repo)
	acknowledged := createArmedTestAlert(t, repo)
	disabled := createArmedTestAlert(t, repo)
	// acknowledged was created after triggered but triggers first, so the triggered-only order (by
	// TriggeredAt) is the reverse of the creation order
	mustTrigger(t, repo, acknowledged.Id, 1, "5")
	awaitAdapterClockAfter(getTestAlert(t, repo, acknowledged.Id).TriggeredAt.AsTime())
	mustTrigger(t, repo, triggered.Id, 1, "6")
	if n, err := repo.Acknowledge(ctx, acknowledged.Id); err != nil || n != 1 {
		t.Fatalf("Acknowledge(%s) = (%d, %v), want (1, nil)", acknowledged.Id, n, err)
	}
	mustUpdateEnabled(t, repo, disabled.Id, false)
	all := []string{armed.Id, triggered.Id, acknowledged.Id, disabled.Id}

	sets := []struct {
		name string
		req  *pb.ListAlertsRequest
		want []string
	}{
		{"armedOnly", &pb.ListAlertsRequest{AccountId: testOwnerAccountID, ArmedOnly: true}, []string{armed.Id}},
		{
			"triggeredUnacknowledged",
			&pb.ListAlertsRequest{AccountId: testOwnerAccountID, TriggeredOnly: true, UnacknowledgedOnly: true},
			[]string{triggered.Id},
		},
		{
			"unacknowledgedOnly",
			&pb.ListAlertsRequest{AccountId: testOwnerAccountID, UnacknowledgedOnly: true},
			[]string{armed.Id, triggered.Id, disabled.Id},
		},
		{"account", &pb.ListAlertsRequest{AccountId: testOwnerAccountID}, all},
		{"allAccounts", &pb.ListAlertsRequest{}, all},
		{"otherAccount", &pb.ListAlertsRequest{AccountId: uuid.New().String()}, []string{}},
	}
	for _, tc := range sets {
		t.Run(tc.name, func(t *testing.T) {
			got := listOwnAlertIDs(t, repo, tc.req, all...)

			if !slices.Equal(sortedIDs(got...), sortedIDs(tc.want...)) {
				t.Errorf("List(%v) own ids = %v, want %v", tc.req, got, tc.want)
			}
		})
	}

	t.Run("triggeredOnlyNewestTriggerFirst", func(t *testing.T) {
		req := &pb.ListAlertsRequest{AccountId: testOwnerAccountID, TriggeredOnly: true}

		got := listOwnAlertIDs(t, repo, req, all...)

		if want := []string{triggered.Id, acknowledged.Id}; !slices.Equal(got, want) {
			t.Errorf("List(%v) own ids = %v, want %v", req, got, want)
		}
	})
}

func TestAlertRepository_triggerTwice_secondNotTriggered(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	alert := createArmedTestAlert(t, repo)
	mustTrigger(t, repo, alert.Id, 1, "5")
	first := getTestAlert(t, repo, alert.Id)

	triggered, err := repo.Trigger(context.Background(), alert.Id, 1, "6")

	if err != nil || triggered {
		t.Fatalf("second Trigger = (%t, %v), want (false, nil)", triggered, err)
	}
	if got := getTestAlert(t, repo, alert.Id); !proto.Equal(got, first) {
		t.Errorf("row after second Trigger = %v, want it unchanged from %v", got, first)
	}
}

func TestAlertRepository_triggerDisabled_notTriggered(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	alert := createArmedTestAlert(t, repo)
	mustUpdateEnabled(t, repo, alert.Id, false)

	triggered, err := repo.Trigger(context.Background(), alert.Id, 1, "5")

	if err != nil || triggered {
		t.Fatalf("Trigger on a disabled alert = (%t, %v), want (false, nil)", triggered, err)
	}
	if got := getTestAlert(t, repo, alert.Id); got.TriggeredAt != nil || got.TriggerValue != "" {
		t.Errorf("disabled alert has TriggeredAt %v, TriggerValue %q; want no trigger", got.TriggeredAt, got.TriggerValue)
	}
}

func TestAlertRepository_updateEnabled_appliesRules(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	alert := createArmedTestAlert(t, repo)
	mustTrigger(t, repo, alert.Id, 1, "12.5")
	if n, err := repo.Acknowledge(context.Background(), alert.Id); err != nil || n != 1 {
		t.Fatalf("Acknowledge = (%d, %v), want (1, nil)", n, err)
	}
	notified := getTestAlert(t, repo, alert.Id)
	if notified.TriggeredAt == nil || notified.TriggerValue != "12.5" || !notified.Acknowledged || notified.ArmingRevision != 1 {
		t.Fatalf("setup row = %v, want an acknowledged trigger of 12.5 at revision 1", notified)
	}

	t.Run("disableKeepsTriggerData", func(t *testing.T) {
		want := cloneAlert(notified)
		want.Enabled = false

		snapshot := mustUpdateEnabled(t, repo, alert.Id, false)

		if !proto.Equal(snapshot, want) {
			t.Errorf("UpdateEnabled(false) = %v, want %v", snapshot, want)
		}
		if got := getTestAlert(t, repo, alert.Id); !proto.Equal(snapshot, got) {
			t.Errorf("UpdateEnabled(false) snapshot %v differs from the row %v", snapshot, got)
		}
	})

	t.Run("enableRearmsWithNextRevision", func(t *testing.T) {
		want := cloneAlert(notified)
		want.Enabled = true
		want.TriggeredAt = nil
		want.TriggerValue = ""
		want.Acknowledged = false
		want.ArmingRevision = 2

		snapshot := mustUpdateEnabled(t, repo, alert.Id, true)

		if !proto.Equal(snapshot, want) {
			t.Errorf("UpdateEnabled(true) = %v, want %v", snapshot, want)
		}
		if got := getTestAlert(t, repo, alert.Id); !proto.Equal(snapshot, got) {
			t.Errorf("UpdateEnabled(true) snapshot %v differs from the row %v", snapshot, got)
		}
	})
}

func TestAlertRepository_acknowledge_onlyTriggeredArming(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	ctx := context.Background()

	t.Run("triggered", func(t *testing.T) {
		alert := createArmedTestAlert(t, repo)
		mustTrigger(t, repo, alert.Id, 1, "5")

		n, err := repo.Acknowledge(ctx, alert.Id)

		if err != nil || n != 1 {
			t.Fatalf("Acknowledge = (%d, %v), want (1, nil)", n, err)
		}
		if !getTestAlert(t, repo, alert.Id).Acknowledged {
			t.Errorf("triggered alert is not acknowledged after Acknowledge")
		}
	})

	t.Run("notTriggered", func(t *testing.T) {
		alert := createArmedTestAlert(t, repo)
		before := getTestAlert(t, repo, alert.Id)

		n, err := repo.Acknowledge(ctx, alert.Id)

		if err != nil || n != 0 {
			t.Fatalf("Acknowledge = (%d, %v), want (0, nil)", n, err)
		}
		if got := getTestAlert(t, repo, alert.Id); !proto.Equal(got, before) {
			t.Errorf("row after Acknowledge = %v, want it unchanged from %v", got, before)
		}
	})
}

func TestAlertRepository_delete_removesRow(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	alert := createArmedTestAlert(t, repo)

	n, err := repo.Delete(context.Background(), alert.Id)

	if err != nil || n != 1 {
		t.Fatalf("Delete = (%d, %v), want (1, nil)", n, err)
	}
	if _, err := repo.GetByID(context.Background(), alert.Id); !errors.Is(err, repository.ErrNotFound) {
		t.Errorf("GetByID after Delete: err = %v, want ErrNotFound", err)
	}
}

func TestAlertRepository_unknownID_notFound(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	ctx := context.Background()
	id := uuid.New().String()

	calls := []struct {
		name string
		call func() error
	}{
		{"GetByID", func() error { _, err := repo.GetByID(ctx, id); return err }},
		{"UpdateEnabledTrue", func() error { _, err := repo.UpdateEnabled(ctx, id, true); return err }},
		{"UpdateEnabledFalse", func() error { _, err := repo.UpdateEnabled(ctx, id, false); return err }},
		{"Delete", func() error { _, err := repo.Delete(ctx, id); return err }},
		{"Acknowledge", func() error { _, err := repo.Acknowledge(ctx, id); return err }},
	}
	for _, tc := range calls {
		t.Run(tc.name, func(t *testing.T) {
			if err := tc.call(); !errors.Is(err, repository.ErrNotFound) {
				t.Errorf("%s(unknown id): err = %v, want ErrNotFound", tc.name, err)
			}
		})
	}

	t.Run("Trigger", func(t *testing.T) {
		triggered, err := repo.Trigger(ctx, id, 1, "5")

		if err != nil || triggered {
			t.Errorf("Trigger(unknown id) = (%t, %v), want (false, nil)", triggered, err)
		}
	})
}

func TestAlertRepository_inexactEnum_rejectedByCheck(t *testing.T) {
	b := alertTestBackend(t)
	repo := b.Alert()
	// The raw insert bypasses the adapter's validation, so only the table's CHECKs stand between it
	// and an inexact value
	storedExactly := func(t *testing.T, id string) {
		t.Helper()
		got := getTestAlert(t, repo, id)
		if got.Type != repository.AlertTypeTargetPrice || got.Direction != repository.AlertDirectionAbove {
			t.Errorf("stored Type %q Direction %q, want exactly %q %q",
				got.Type, got.Direction, repository.AlertTypeTargetPrice, repository.AlertDirectionAbove)
		}
	}

	// The same INSERT with exact values succeeds, so each rejection below is its value's alone
	t.Run("exactValuesControl", func(t *testing.T) {
		id := uuid.New().String()

		if err := insertRawAlert(t, b, id, repository.AlertTypeTargetPrice, repository.AlertDirectionAbove, alertNow()); err != nil {
			t.Fatalf("insert of exact Type and Direction: %v", err)
		}
		storedExactly(t, id)
	})

	rejected := []struct {
		name      string
		typ       string
		direction string
		column    string
	}{
		{"lowercaseType", "target_price", repository.AlertDirectionAbove, repository.ColType},
		{"lowercaseDirection", repository.AlertTypeTargetPrice, "above", repository.ColDirection},
		// Fits varchar(12), so only the CHECK can refuse it; SQL Server's = ignores trailing spaces
		{"trailingSpaceTypeWithinWidth", "PROFIT_LOSS ", repository.AlertDirectionAbove, repository.ColType},
	}
	for _, tc := range rejected {
		t.Run(tc.name, func(t *testing.T) {
			err := insertRawAlert(t, b, uuid.New().String(), tc.typ, tc.direction, alertNow())

			if want := checkViolation(tc.column); !want.matches(err) {
				t.Errorf("insert of Type %q Direction %q: err = %v, want the %s", tc.typ, tc.direction, err, want.name)
			}
		})
	}

	// One space beyond the column width: PostgreSQL truncates excess spaces before the CHECK, and SQL
	// Server does too at its default settings. The value is refused by its column's CHECK or width,
	// or exactly the canonical value is stored; any other outcome fails
	overWidth := []struct {
		name      string
		typ       string
		direction string
		column    string
	}{
		{"trailingSpaceTypeOverWidth", "TARGET_PRICE ", repository.AlertDirectionAbove, repository.ColType},
		{"trailingSpaceDirectionOverWidth", repository.AlertTypeTargetPrice, "ABOVE ", repository.ColDirection},
	}
	for _, tc := range overWidth {
		t.Run(tc.name, func(t *testing.T) {
			id := uuid.New().String()

			err := insertRawAlert(t, b, id, tc.typ, tc.direction, alertNow())

			if err != nil {
				if check := checkViolation(tc.column); !check.matches(err) && !stringTruncation.matches(err) {
					t.Errorf("insert of Type %q Direction %q: err = %v, want the %s, a %s, or the exact value stored",
						tc.typ, tc.direction, err, check.name, stringTruncation.name)
				}
				return
			}
			storedExactly(t, id)
		})
	}
}

// insertRawAlertValues inserts, as insertRawAlert does, an alert on the seeded owner account and
// instrument with a plain INSERT and deletes it by id when the test ends. It also binds Threshold,
// TriggerValue, CreatedAt and TriggeredAt, each exactly as values gives it: text reaches the
// column's own input conversion, as a direct SQL write's literal does, so only the table's types and
// constraints judge values such as NaN and infinity.
func insertRawAlertValues(t *testing.T, b *sqlBackend, id string, values map[string]any) error {
	t.Helper()
	deleteAlertAtCleanup(t, b.Alert(), id)
	columns := []string{
		repository.ColID, repository.ColAccountID, repository.ColType, repository.ColInstrumentID,
		repository.ColDirection, repository.ColEnabled, repository.ColArmingRevision, repository.ColAcknowledged,
	}
	args := []any{
		id, testOwnerAccountID, repository.AlertTypeTargetPrice, testInstrumentID,
		repository.AlertDirectionAbove, true, 1, false,
	}
	for _, column := range []string{
		repository.ColThreshold, repository.ColTriggerValue, repository.ColCreatedAt, repository.ColTriggeredAt,
	} {
		value, ok := values[column]
		if !ok {
			t.Fatalf("insertRawAlertValues: no value for %s", column)
		}
		columns = append(columns, column)
		args = append(args, value)
	}
	quoted := make([]string, len(columns))
	placeholders := make([]string, len(columns))
	for i, column := range columns {
		quoted[i] = q(column)
		placeholders[i] = "?"
	}
	insertSQL := "INSERT INTO " + q(repository.TableAlerts) + " (" + strings.Join(quoted, ", ") + ")" +
		" VALUES (" + strings.Join(placeholders, ", ") + ")"
	return b.gormDB.WithContext(context.Background()).Exec(insertSQL, args...).Error
}

// PostgreSQL's numeric admits NaN and its timestamptz admits infinity and -infinity, which SQL
// Server's DECIMAL and datetimeoffset refuse. A direct write of one must fail on both dialects, so
// neither stores a value outside the one domain the adapter and the broker read
func TestAlertRepository_nonFiniteValue_rejectedByDatabase(t *testing.T) {
	b := alertTestBackend(t)
	// ISO 8601 with microseconds, which timestamptz and datetimeoffset(6) both parse from text
	const timestampLayout = "2006-01-02T15:04:05.000000Z07:00"
	createdAt := alertNow()
	triggeredAt := createdAt.Add(time.Second)
	// Every value is bound as text, as a direct SQL write sends it. Each case below replaces exactly
	// one of these finite values, so its rejection is that value's alone
	finite := func() map[string]any {
		return map[string]any{
			repository.ColThreshold:    "1",
			repository.ColTriggerValue: "5",
			repository.ColCreatedAt:    createdAt.Format(timestampLayout),
			repository.ColTriggeredAt:  triggeredAt.Format(timestampLayout),
		}
	}

	t.Run("finiteValuesControl", func(t *testing.T) {
		id := uuid.New().String()

		if err := insertRawAlertValues(t, b, id, finite()); err != nil {
			t.Fatalf("insert of finite values: %v", err)
		}
		got := getTestAlert(t, b.Alert(), id)
		if got.Threshold != "1" || got.TriggerValue != "5" ||
			!got.CreatedAt.AsTime().Equal(createdAt) || !got.TriggeredAt.AsTime().Equal(triggeredAt) {
			t.Errorf("stored Threshold %q TriggerValue %q CreatedAt %v TriggeredAt %v, want %q %q %v %v",
				got.Threshold, got.TriggerValue, got.CreatedAt.AsTime(), got.TriggeredAt.AsTime(),
				"1", "5", createdAt, triggeredAt)
		}
	})

	// PostgreSQL refuses each value through its column's CHECK. SQL Server refuses the text while
	// converting it to the column's type, before any CHECK runs
	rejected := []struct {
		column      string
		value       string
		mssqlNumber int32
		mssqlText   string
	}{
		{repository.ColThreshold, "NaN", 8114, "to numeric"},
		{repository.ColTriggerValue, "NaN", 8114, "to numeric"},
		{repository.ColCreatedAt, "infinity", 241, "date and/or time"},
		{repository.ColTriggeredAt, "-infinity", 241, "date and/or time"},
	}
	for _, tc := range rejected {
		t.Run(tc.column+"_"+tc.value, func(t *testing.T) {
			values := finite()
			values[tc.column] = tc.value
			id := uuid.New().String()

			err := insertRawAlertValues(t, b, id, values)

			check := checkViolation(tc.column)
			want := dialectError{
				name:         fmt.Sprintf("%s or SQL Server conversion error %d", check.name, tc.mssqlNumber),
				pgStates:     check.pgStates,
				pgText:       check.pgText,
				mssqlNumbers: []int32{tc.mssqlNumber},
				mssqlText:    []string{tc.mssqlText},
			}
			if !want.matches(err) {
				t.Errorf("insert of %s %q: err = %v, want the %s", tc.column, tc.value, err, want.name)
			}
			var stored int64
			countSQL := "SELECT COUNT(*) FROM " + q(repository.TableAlerts) + " WHERE " + q(repository.ColID) + " = ?"
			if err := b.gormDB.WithContext(context.Background()).Raw(countSQL, id).Scan(&stored).Error; err != nil || stored != 0 {
				t.Errorf("rows with id %s after the rejected insert = (%d, %v), want (0, nil)", id, stored, err)
			}
		})
	}
}

func TestAlertRepository_cancelledContext_errorPropagated(t *testing.T) {
	repo := alertTestBackend(t).Alert()

	calls := []struct {
		name string
		// triggered triggers the alert first, so a call that ignored the cancellation would change it
		triggered bool
		// call reports the operation's result and whether that is its zero result
		call func(t *testing.T, ctx context.Context, id string) (result any, zero bool, err error)
	}{
		{"Create", false, func(t *testing.T, ctx context.Context, _ string) (any, bool, error) {
			alert, err := repo.Create(ctx, &pb.CreateAlertRequest{
				AccountId:    testOwnerAccountID,
				Type:         repository.AlertTypeTargetPrice,
				InstrumentId: testInstrumentID,
				Direction:    repository.AlertDirectionAbove,
				Threshold:    "1",
			})
			if alert != nil {
				deleteAlertAtCleanup(t, repo, alert.Id)
			}
			return alert, alert == nil, err
		}},
		{"List", false, func(_ *testing.T, ctx context.Context, _ string) (any, bool, error) {
			alerts, err := repo.List(ctx, &pb.ListAlertsRequest{AccountId: testOwnerAccountID})
			return alerts, alerts == nil, err
		}},
		{"GetByID", false, func(_ *testing.T, ctx context.Context, id string) (any, bool, error) {
			alert, err := repo.GetByID(ctx, id)
			return alert, alert == nil, err
		}},
		{"UpdateEnabledTrue", false, func(_ *testing.T, ctx context.Context, id string) (any, bool, error) {
			snapshot, err := repo.UpdateEnabled(ctx, id, true)
			return snapshot, snapshot == nil, err
		}},
		{"UpdateEnabledFalse", false, func(_ *testing.T, ctx context.Context, id string) (any, bool, error) {
			snapshot, err := repo.UpdateEnabled(ctx, id, false)
			return snapshot, snapshot == nil, err
		}},
		{"Delete", false, func(_ *testing.T, ctx context.Context, id string) (any, bool, error) {
			n, err := repo.Delete(ctx, id)
			return n, n == 0, err
		}},
		{"Trigger", false, func(_ *testing.T, ctx context.Context, id string) (any, bool, error) {
			triggered, err := repo.Trigger(ctx, id, 1, "5")
			return triggered, !triggered, err
		}},
		{"Acknowledge", true, func(_ *testing.T, ctx context.Context, id string) (any, bool, error) {
			n, err := repo.Acknowledge(ctx, id)
			return n, n == 0, err
		}},
	}
	for _, tc := range calls {
		t.Run(tc.name, func(t *testing.T) {
			alert := createArmedTestAlert(t, repo)
			if tc.triggered {
				mustTrigger(t, repo, alert.Id, 1, "5")
			}
			before := getTestAlert(t, repo, alert.Id)
			ctx, cancel := context.WithCancel(context.Background())
			cancel()

			result, zero, err := tc.call(t, ctx, alert.Id)

			if !errors.Is(err, context.Canceled) || errors.Is(err, repository.ErrNotFound) {
				t.Errorf("%s(cancelled context): err = %v, want context.Canceled, not ErrNotFound", tc.name, err)
			}
			if !zero {
				t.Errorf("%s(cancelled context) returned %v, want its zero result", tc.name, result)
			}
			if got := getTestAlert(t, repo, alert.Id); !proto.Equal(got, before) {
				t.Errorf("row after %s(cancelled context) = %v, want it unchanged from %v", tc.name, got, before)
			}
		})
	}
}

// unknownAlertReferences are well-formed create requests whose account or instrument id names no row,
// each with the foreign key that refuses it
var unknownAlertReferences = []struct {
	name       string
	req        *pb.CreateAlertRequest
	constraint string
}{
	{"unknownAccount", unknownReferenceRequest(uuid.NewString(), testInstrumentID), "FK_Alerts_Accounts"},
	{"unknownInstrument", unknownReferenceRequest(testOwnerAccountID, uuid.NewString()), "FK_Alerts_Instruments"},
	{"nilUUIDAccount", unknownReferenceRequest(uuid.Nil.String(), testInstrumentID), "FK_Alerts_Accounts"},
}

func unknownReferenceRequest(accountID, instrumentID string) *pb.CreateAlertRequest {
	return &pb.CreateAlertRequest{
		AccountId:    accountID,
		Type:         repository.AlertTypeTargetPrice,
		InstrumentId: instrumentID,
		Direction:    repository.AlertDirectionAbove,
		Threshold:    "1",
	}
}

// storedWithReferences lists the alerts of req's account that carry req's instrument
func storedWithReferences(t *testing.T, repo repository.AlertRepository, req *pb.CreateAlertRequest) []*pb.AlertMessage {
	t.Helper()
	alerts, err := repo.List(context.Background(), &pb.ListAlertsRequest{AccountId: req.AccountId})
	if err != nil {
		t.Fatalf("List(%s): %v", req.AccountId, err)
	}
	var stored []*pb.AlertMessage
	for _, alert := range alerts {
		if alert.InstrumentId == req.InstrumentId {
			stored = append(stored, alert)
		}
	}
	return stored
}

// The foreign key refuses the row; the error matches ErrAlertReferenceNotFound, keeps the driver's
// violation reachable and prints neither the constraint nor any other driver text
func TestAlertRepository_createUnknownReference_referenceNotFound(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	for _, ref := range unknownAlertReferences {
		t.Run(ref.name, func(t *testing.T) {
			alert, err := repo.Create(context.Background(), ref.req)

			if alert != nil {
				deleteAlertAtCleanup(t, repo, alert.Id)
				t.Errorf("Create(%s) returned %v, want nil", ref.name, alert)
			}
			want := foreignKeyViolation(ref.constraint)
			if !errors.Is(err, repository.ErrAlertReferenceNotFound) || !want.matches(err) || strings.Contains(err.Error(), ref.constraint) {
				t.Errorf("Create(%s): err = %v, want ErrAlertReferenceNotFound with the %s reachable and unprinted", ref.name, err, want.name)
			}
			if stored := storedWithReferences(t, repo, ref.req); len(stored) != 0 {
				t.Errorf("Create(%s) stored %v, want no row", ref.name, stored)
			}
		})
	}
}

// The real handler over the real backend: an account or instrument that names no row is NotFound
// with a fixed message, and nothing is stored
func TestAlertServer_createUnknownReference_notFound(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	srv := server.NewAlertServer(repo)
	for _, ref := range unknownAlertReferences {
		t.Run(ref.name, func(t *testing.T) {
			created, err := srv.CreateAlert(context.Background(), ref.req)

			if created != nil {
				deleteAlertAtCleanup(t, repo, created.Id)
			}
			if st := status.Convert(err); st.Code() != codes.NotFound || st.Message() != "account or instrument not found" {
				t.Errorf("CreateAlert(%s) = %v %q, want NotFound %q", ref.name, st.Code(), st.Message(), "account or instrument not found")
			}
			if stored := storedWithReferences(t, repo, ref.req); len(stored) != 0 {
				t.Errorf("CreateAlert(%s) stored %v, want no row", ref.name, stored)
			}
		})
	}
}

// mssqlMessageError adds the message go-mssqldb's Error gives beside its number
type mssqlMessageError interface {
	mssqlDriverError
	SQLErrorMessage() string
}

// The fixed wording of SQL Server's English message for error 547; no other language uses it
const mssqlEnglishConflictWording = "statement conflicted with the"

// setLanguageSQL is SET LANGUAGE with the name as a Unicode literal, its quotes doubled
func setLanguageSQL(language string) string {
	return "SET LANGUAGE N'" + strings.ReplaceAll(language, "'", "''") + "'"
}

// inSessionLanguage runs fn on one pooled SQL Server connection set to language, then gives the
// connection back in the language it had. Both SET LANGUAGE statements carry no parameters, so
// go-mssqldb sends each as a plain batch and the setting holds for the session; inside
// sp_executesql it would end with the call. A connection whose language cannot be restored is
// discarded instead of returned to the pool, where the other tests expect English messages
func inSessionLanguage(t *testing.T, b *sqlBackend, language string, fn func(session *gorm.DB)) {
	t.Helper()
	err := b.gormDB.WithContext(context.Background()).Connection(func(tx *gorm.DB) error {
		// Every statement through session gets a fresh statement on the pinned connection
		session := tx.Session(&gorm.Session{NewDB: true})
		var original string
		if err := session.Raw("SELECT @@LANGUAGE").Scan(&original).Error; err != nil {
			return fmt.Errorf("reading the session language: %w", err)
		}
		defer func() {
			if err := session.Exec(setLanguageSQL(original)).Error; err != nil {
				t.Errorf("restoring session language %s: %v; discarding the connection", original, err)
				if conn, ok := tx.Statement.ConnPool.(*dbsql.Conn); ok {
					// ErrBadConn from Raw makes database/sql close the connection rather than pool it
					_ = conn.Raw(func(any) error { return driver.ErrBadConn })
				}
			}
		}()
		if err := session.Exec(setLanguageSQL(language)).Error; err != nil {
			return fmt.Errorf("setting session language %s: %w", language, err)
		}
		var current string
		if err := session.Raw("SELECT @@LANGUAGE").Scan(&current).Error; err != nil || current != language {
			return fmt.Errorf("session language after setting %s = (%q, %v), want %q", language, current, err, language)
		}
		fn(session)
		return nil
	})
	if err != nil {
		t.Fatalf("on a connection in session language %s: %v", language, err)
	}
}

// SQL Server words error 547 in the session language, and a foreign-key conflict is still an unknown
// reference in every one. Each language delimits the constraint name differently: German quotes it,
// Dutch leaves it bare and Hungarian uses „”
func TestAlertRepository_createUnknownReferenceLocalizedSession_referenceNotFound(t *testing.T) {
	b := alertTestBackend(t)
	if dialect := b.gormDB.Dialector.Name(); dialect != "sqlserver" {
		t.Skipf("%s reports every foreign-key violation as SQLSTATE 23503 whatever lc_messages says; only SQL Server's error 547 needs its message to tell a foreign key from a CHECK", dialect)
	}
	for _, language := range []string{"Deutsch", "Nederlands", "magyar"} {
		t.Run(language, func(t *testing.T) {
			inSessionLanguage(t, b, language, func(session *gorm.DB) {
				repo := NewAlertRepository(session)
				for _, ref := range unknownAlertReferences {
					t.Run(ref.name, func(t *testing.T) {
						alert, err := repo.Create(context.Background(), ref.req)

						if alert != nil {
							deleteAlertAtCleanup(t, b.Alert(), alert.Id)
							t.Errorf("Create(%s) returned %v, want nil", ref.name, alert)
						}
						// The driver's own message proves the session's wording is not English
						var driverErr mssqlMessageError
						if !errors.As(err, &driverErr) || driverErr.SQLErrorNumber() != 547 ||
							!strings.Contains(driverErr.SQLErrorMessage(), ref.constraint) ||
							strings.Contains(driverErr.SQLErrorMessage(), mssqlEnglishConflictWording) {
							t.Fatalf("Create(%s): err = %v, want SQL Server error 547 naming %s in %s wording", ref.name, err, ref.constraint, language)
						}
						if !errors.Is(err, repository.ErrAlertReferenceNotFound) || strings.Contains(err.Error(), ref.constraint) {
							t.Errorf("Create(%s): err = %q, want ErrAlertReferenceNotFound without the constraint name", ref.name, err)
						}
						if stored := storedWithReferences(t, b.Alert(), ref.req); len(stored) != 0 {
							t.Errorf("Create(%s) stored %v, want no row", ref.name, stored)
						}
					})
				}
			})
		})
	}
}

func TestAlertRepository_updateEnabledStatementFails_errorPropagated(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	// The RPC validates ids before the repository sees them; here the malformed id makes the first
	// UPDATE inside the transaction fail, and that failure must surface rather than a miss
	const id = "not-a-uuid"

	cases := []struct {
		name    string
		enabled bool
	}{
		{"rearm", true},
		{"disable", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			snapshot, err := repo.UpdateEnabled(context.Background(), id, tc.enabled)

			if !invalidUUIDText.matches(err) || errors.Is(err, repository.ErrNotFound) {
				t.Errorf("UpdateEnabled(%q, %t): err = %v, want the %s, not ErrNotFound", id, tc.enabled, err, invalidUUIDText.name)
			}
			if snapshot != nil {
				t.Errorf("UpdateEnabled(%q, %t) returned %v, want nil", id, tc.enabled, snapshot)
			}
		})
	}
}

func TestAlertRepository_listSameCreatedAt_higherIdFirst(t *testing.T) {
	b := alertTestBackend(t)
	repo := b.Alert()

	orders := []struct {
		name              string
		insertHigherFirst bool
	}{
		{"lowerIdInsertedFirst", false},
		{"higherIdInsertedFirst", true},
	}
	for _, tc := range orders {
		t.Run(tc.name, func(t *testing.T) {
			// Ids differing only in the last hex digit order alike on both dialects: PostgreSQL compares
			// uuid bytes left to right, SQL Server compares the last six-byte group first
			base := uuid.New().String()
			lower, higher := base[:len(base)-1]+"0", base[:len(base)-1]+"f"
			inserted := []string{lower, higher}
			if tc.insertHigherFirst {
				inserted = []string{higher, lower}
			}
			createdAt := alertNow()
			for _, id := range inserted {
				if err := insertRawAlert(t, b, id, repository.AlertTypeTargetPrice, repository.AlertDirectionAbove, createdAt); err != nil {
					t.Fatalf("insert %s: %v", id, err)
				}
				if stored := getTestAlert(t, repo, id).CreatedAt.AsTime(); !stored.Equal(createdAt) {
					t.Fatalf("alert %s CreatedAt read back as %v, want the shared %v", id, stored, createdAt)
				}
			}

			got := listOwnAlertIDs(t, repo, &pb.ListAlertsRequest{AccountId: testOwnerAccountID}, lower, higher)

			if want := []string{higher, lower}; !slices.Equal(got, want) {
				t.Errorf("List own ids at one CreatedAt = %v, want the higher id first %v", got, want)
			}
		})
	}
}

// The concurrency cases release every goroutine through one closed channel and collect with a
// WaitGroup; goroutines only record results, and the test goroutine asserts after Wait.

func TestAlertRepository_triggerConcurrent_exactlyOne(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	const rounds, evaluators = 10, 8

	for round := range rounds {
		t.Run(fmt.Sprintf("round%d", round+1), func(t *testing.T) {
			alert := createArmedTestAlert(t, repo)
			values := make([]string, evaluators)
			triggered := make([]bool, evaluators)
			errs := make([]error, evaluators)
			start := make(chan struct{})
			var wg sync.WaitGroup
			for i := range evaluators {
				values[i] = fmt.Sprintf("%d.25", i+1)
				wg.Go(func() {
					<-start
					triggered[i], errs[i] = repo.Trigger(context.Background(), alert.Id, 1, values[i])
				})
			}

			close(start)
			wg.Wait()

			winner := -1
			for i := range evaluators {
				if errs[i] != nil {
					t.Fatalf("evaluator %d: Trigger: %v", i, errs[i])
				}
				if triggered[i] {
					if winner >= 0 {
						t.Fatalf("evaluators %d and %d both triggered arming 1", winner, i)
					}
					winner = i
				}
			}
			if winner < 0 {
				t.Fatalf("no evaluator triggered the armed alert")
			}
			if got := getTestAlert(t, repo, alert.Id).TriggerValue; got != values[winner] {
				t.Errorf("TriggerValue = %q, want the winner's %q", got, values[winner])
			}
		})
	}
}

func TestAlertRepository_staleRevisionAfterRearm_notTriggered(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	ctx := context.Background()
	alert := createArmedTestAlert(t, repo)
	mustTrigger(t, repo, alert.Id, 1, "5")
	if rearmed := mustUpdateEnabled(t, repo, alert.Id, true); rearmed.ArmingRevision != 2 {
		t.Fatalf("re-arm gave revision %d, want 2", rearmed.ArmingRevision)
	}

	// An evaluator still holding revision 1 sees TriggeredAt null again after the re-arm
	stale, staleErr := repo.Trigger(ctx, alert.Id, 1, "6")
	current, currentErr := repo.Trigger(ctx, alert.Id, 2, "7")
	repeat, repeatErr := repo.Trigger(ctx, alert.Id, 2, "8")

	if staleErr != nil || stale {
		t.Errorf("Trigger at stale revision 1 = (%t, %v), want (false, nil)", stale, staleErr)
	}
	if currentErr != nil || !current {
		t.Errorf("Trigger at revision 2 = (%t, %v), want (true, nil)", current, currentErr)
	}
	if repeatErr != nil || repeat {
		t.Errorf("repeated Trigger at revision 2 = (%t, %v), want (false, nil)", repeat, repeatErr)
	}
	final := getTestAlert(t, repo, alert.Id)
	if final.ArmingRevision != 2 || final.TriggerValue != "7" || final.TriggeredAt == nil {
		t.Errorf("final row = %v, want revision 2 triggered with 7", final)
	}
}

func TestAlertRepository_updateEnabledConcurrent_returnsOwnSnapshot(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	const rounds = 10
	writes := []bool{true, true, true, false, false}

	for round := range rounds {
		t.Run(fmt.Sprintf("round%d", round+1), func(t *testing.T) {
			alert := createArmedTestAlert(t, repo)
			startRevision := alert.ArmingRevision
			snapshots := make([]*pb.AlertMessage, len(writes))
			errs := make([]error, len(writes))
			var triggerErr error
			start := make(chan struct{})
			var wg sync.WaitGroup
			for i, enabled := range writes {
				wg.Go(func() {
					<-start
					snapshots[i], errs[i] = repo.UpdateEnabled(context.Background(), alert.Id, enabled)
				})
			}
			wg.Go(func() {
				<-start
				_, triggerErr = repo.Trigger(context.Background(), alert.Id, startRevision, "5")
			})

			close(start)
			wg.Wait()

			if triggerErr != nil {
				t.Fatalf("Trigger: %v", triggerErr)
			}
			var rearmRevisions []int32
			highest := startRevision
			for i, enabled := range writes {
				if errs[i] != nil {
					t.Fatalf("UpdateEnabled(%t) #%d: %v", enabled, i, errs[i])
				}
				snapshot := snapshots[i]
				if snapshot.Enabled != enabled {
					t.Errorf("UpdateEnabled(%t) #%d returned Enabled %t", enabled, i, snapshot.Enabled)
				}
				if enabled {
					if snapshot.TriggeredAt != nil || snapshot.TriggerValue != "" || snapshot.Acknowledged {
						t.Errorf("UpdateEnabled(true) #%d returned trigger data %v", i, snapshot)
					}
					rearmRevisions = append(rearmRevisions, snapshot.ArmingRevision)
				}
				highest = max(highest, snapshot.ArmingRevision)
			}
			slices.Sort(rearmRevisions)
			if want := []int32{startRevision + 1, startRevision + 2, startRevision + 3}; !slices.Equal(rearmRevisions, want) {
				t.Errorf("re-arm snapshots have revisions %v, want %v", rearmRevisions, want)
			}
			// A trigger at the starting revision can only precede every re-arm, so none survives them
			final := getTestAlert(t, repo, alert.Id)
			if final.ArmingRevision != highest || final.TriggeredAt != nil || final.TriggerValue != "" {
				t.Errorf("final row = %v, want revision %d with no trigger", final, highest)
			}
		})
	}
}

// alertUUIDSpelling rewrites a canonical UUID as other text that contains it
type alertUUIDSpelling struct {
	name  string
	spell func(id string) string
}

var (
	// The spellings AlertService accepts besides the canonical one. A dialect's UUID type does not
	// parse every one of them, so the handler must bind the canonical form for the statement to run
	alertServerUUIDSpellings = []alertUUIDSpelling{
		{"urn", func(id string) string { return "urn:uuid:" + id }},
		{"upperURN", func(id string) string { return "URN:UUID:" + strings.ToUpper(id) }},
		{"braces", func(id string) string { return "{" + id + "}" }},
		{"hexDigits", func(id string) string { return strings.ReplaceAll(id, "-", "") }},
		{"upperCase", strings.ToUpper},
	}
	// Text AlertService must refuse although it contains a valid id. uuid.Parse alone accepts the
	// 38-byte forms, because it ignores their outer two characters
	alertServerMalformedUUIDs = []alertUUIDSpelling{
		{"letterWrapped", func(id string) string { return "x" + id + "y" }},
		{"parenthesised", func(id string) string { return "(" + id + ")" }},
		{"unbalancedBraces", func(id string) string { return "{" + id + ")" }},
		{"badURNPrefix", func(id string) string { return "urn:uuix:" + id }},
	}
)

// The real handler over the real backend: every accepted spelling of an alert or account id reaches
// the row its canonical form names, on the configured dialect
func TestAlertServer_alternateUUIDSpelling_intendedRowSelected(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	srv := server.NewAlertServer(repo)
	ctx := context.Background()

	// Each call gets a fresh armed alert, sets its state through the repository with canonical ids,
	// calls one RPC with spelled ids and checks that the RPC acted on that alert, or for CreateAlert
	// that the row it stored carries the canonical ids
	rpcs := []struct {
		name string
		call func(t *testing.T, alert *pb.AlertMessage, spell func(string) string)
	}{
		{"CreateAlert", func(t *testing.T, _ *pb.AlertMessage, spell func(string) string) {
			req := &pb.CreateAlertRequest{
				AccountId:    spell(testOwnerAccountID),
				Type:         repository.AlertTypeTargetPrice,
				InstrumentId: spell(testInstrumentID),
				Direction:    repository.AlertDirectionAbove,
				Threshold:    thresholdDomainMax,
			}

			created, err := srv.CreateAlert(ctx, req)

			if err != nil {
				t.Fatalf("CreateAlert(%v): %v", req, err)
			}
			deleteAlertAtCleanup(t, repo, created.Id)
			got := getTestAlert(t, repo, created.Id)
			if got.AccountId != testOwnerAccountID || got.InstrumentId != testInstrumentID || !proto.Equal(created, got) {
				t.Errorf("CreateAlert(%v) = %v with the row %v, want account %s and instrument %s",
					req, created, got, testOwnerAccountID, testInstrumentID)
			}
		}},
		{"GetAlert", func(t *testing.T, alert *pb.AlertMessage, spell func(string) string) {
			id := spell(alert.Id)

			got, err := srv.GetAlert(ctx, &pb.AlertIdRequest{Id: id})

			if err != nil || !proto.Equal(got, alert) {
				t.Errorf("GetAlert(%q) = (%v, %v), want (%v, nil)", id, got, err, alert)
			}
		}},
		{"ListAlerts", func(t *testing.T, alert *pb.AlertMessage, spell func(string) string) {
			req := &pb.ListAlertsRequest{AccountId: spell(testOwnerAccountID)}

			resp, err := srv.ListAlerts(ctx, req)

			if err != nil {
				t.Fatalf("ListAlerts(%v): %v", req, err)
			}
			// Other rows of the owner account may share the table, so only this alert's presence and
			// the absence of every other account's rows are checked
			own := []string{}
			foreign := 0
			for _, listed := range resp.Alerts {
				if listed.Id == alert.Id {
					own = append(own, listed.Id)
				}
				if listed.AccountId != testOwnerAccountID {
					foreign++
				}
			}
			if want := []string{alert.Id}; !slices.Equal(own, want) || foreign != 0 {
				t.Errorf("ListAlerts(%v) listed own ids %v and %d other accounts' alerts, want %v and none",
					req, own, foreign, want)
			}
		}},
		{"UpdateAlertEnabledFalse", func(t *testing.T, alert *pb.AlertMessage, spell func(string) string) {
			req := &pb.UpdateAlertEnabledRequest{Id: spell(alert.Id), Enabled: wrapperspb.Bool(false)}
			want := cloneAlert(alert)
			want.Enabled = false

			snapshot, err := srv.UpdateAlertEnabled(ctx, req)

			if err != nil || !proto.Equal(snapshot, want) {
				t.Errorf("UpdateAlertEnabled(%v) = (%v, %v), want (%v, nil)", req, snapshot, err, want)
			}
		}},
		{"UpdateAlertEnabledTrue", func(t *testing.T, alert *pb.AlertMessage, spell func(string) string) {
			// Triggered, then disabled: re-arming clears the trigger and moves to the next revision
			mustTrigger(t, repo, alert.Id, alert.ArmingRevision, "5")
			mustUpdateEnabled(t, repo, alert.Id, false)
			req := &pb.UpdateAlertEnabledRequest{Id: spell(alert.Id), Enabled: wrapperspb.Bool(true)}
			want := cloneAlert(alert)
			want.ArmingRevision = alert.ArmingRevision + 1

			snapshot, err := srv.UpdateAlertEnabled(ctx, req)

			if err != nil || !proto.Equal(snapshot, want) {
				t.Errorf("UpdateAlertEnabled(%v) = (%v, %v), want (%v, nil)", req, snapshot, err, want)
			}
		}},
		{"TriggerAlert", func(t *testing.T, alert *pb.AlertMessage, spell func(string) string) {
			req := &pb.TriggerAlertRequest{Id: spell(alert.Id), ArmingRevision: alert.ArmingRevision, TriggerValue: "5"}

			resp, err := srv.TriggerAlert(ctx, req)

			got := getTestAlert(t, repo, alert.Id)
			if err != nil || !resp.GetTriggered() || got.TriggeredAt == nil || got.TriggerValue != "5" {
				t.Errorf("TriggerAlert(%v) = (%v, %v) with the row %v, want triggered with 5", req, resp, err, got)
			}
		}},
		{"AcknowledgeAlert", func(t *testing.T, alert *pb.AlertMessage, spell func(string) string) {
			mustTrigger(t, repo, alert.Id, alert.ArmingRevision, "5")
			id := spell(alert.Id)

			resp, err := srv.AcknowledgeAlert(ctx, &pb.AlertIdRequest{Id: id})

			got := getTestAlert(t, repo, alert.Id)
			if err != nil || resp.GetAffected() != 1 || !got.Acknowledged {
				t.Errorf("AcknowledgeAlert(%q) = (%v, %v) with the row %v, want affected 1 and the row acknowledged",
					id, resp, err, got)
			}
		}},
		{"DeleteAlert", func(t *testing.T, alert *pb.AlertMessage, spell func(string) string) {
			id := spell(alert.Id)

			resp, err := srv.DeleteAlert(ctx, &pb.AlertIdRequest{Id: id})

			_, getErr := repo.GetByID(ctx, alert.Id)
			if err != nil || resp.GetAffected() != 1 || !errors.Is(getErr, repository.ErrNotFound) {
				t.Errorf("DeleteAlert(%q) = (%v, %v) with GetByID error %v, want affected 1 and ErrNotFound",
					id, resp, err, getErr)
			}
		}},
	}
	for _, spelling := range alertServerUUIDSpellings {
		for _, rpc := range rpcs {
			t.Run(spelling.name+"/"+rpc.name, func(t *testing.T) {
				rpc.call(t, createArmedTestAlert(t, repo), spelling.spell)
			})
		}
	}
}

// Malformed id text is refused before any statement runs, so it neither fails in the driver nor
// reaches the row its inner 36 characters name
func TestAlertServer_malformedUUID_invalidArgumentRowUnchanged(t *testing.T) {
	repo := alertTestBackend(t).Alert()
	srv := server.NewAlertServer(repo)
	ctx := context.Background()

	// triggered sets up the state in which the call, had it reached the row, would change it
	rpcs := []struct {
		name      string
		triggered bool
		call      func(alert *pb.AlertMessage, spell func(string) string) error
	}{
		{"GetAlert", false, func(alert *pb.AlertMessage, spell func(string) string) error {
			_, err := srv.GetAlert(ctx, &pb.AlertIdRequest{Id: spell(alert.Id)})
			return err
		}},
		{"ListAlerts", false, func(_ *pb.AlertMessage, spell func(string) string) error {
			_, err := srv.ListAlerts(ctx, &pb.ListAlertsRequest{AccountId: spell(testOwnerAccountID)})
			return err
		}},
		{"UpdateAlertEnabledFalse", false, func(alert *pb.AlertMessage, spell func(string) string) error {
			_, err := srv.UpdateAlertEnabled(ctx, &pb.UpdateAlertEnabledRequest{Id: spell(alert.Id), Enabled: wrapperspb.Bool(false)})
			return err
		}},
		{"UpdateAlertEnabledTrue", true, func(alert *pb.AlertMessage, spell func(string) string) error {
			_, err := srv.UpdateAlertEnabled(ctx, &pb.UpdateAlertEnabledRequest{Id: spell(alert.Id), Enabled: wrapperspb.Bool(true)})
			return err
		}},
		{"TriggerAlert", false, func(alert *pb.AlertMessage, spell func(string) string) error {
			_, err := srv.TriggerAlert(ctx, &pb.TriggerAlertRequest{Id: spell(alert.Id), ArmingRevision: alert.ArmingRevision, TriggerValue: "5"})
			return err
		}},
		{"AcknowledgeAlert", true, func(alert *pb.AlertMessage, spell func(string) string) error {
			_, err := srv.AcknowledgeAlert(ctx, &pb.AlertIdRequest{Id: spell(alert.Id)})
			return err
		}},
		{"DeleteAlert", false, func(alert *pb.AlertMessage, spell func(string) string) error {
			_, err := srv.DeleteAlert(ctx, &pb.AlertIdRequest{Id: spell(alert.Id)})
			return err
		}},
	}
	for _, malformed := range alertServerMalformedUUIDs {
		for _, rpc := range rpcs {
			t.Run(malformed.name+"/"+rpc.name, func(t *testing.T) {
				alert := createArmedTestAlert(t, repo)
				if rpc.triggered {
					mustTrigger(t, repo, alert.Id, alert.ArmingRevision, "5")
				}
				before := getTestAlert(t, repo, alert.Id)

				err := rpc.call(alert, malformed.spell)

				after, getErr := repo.GetByID(ctx, alert.Id)
				if status.Code(err) != codes.InvalidArgument || getErr != nil || !proto.Equal(after, before) {
					t.Errorf("%s with a %s id = %v with the row (%v, %v), want InvalidArgument and the row unchanged from %v",
						rpc.name, malformed.name, err, after, getErr, before)
				}
			})
		}
	}

	// CreateAlert binds the ids it parses, so a malformed id it accepted would store a row
	createFields := []struct {
		name string
		set  func(req *pb.CreateAlertRequest, spell func(string) string)
	}{
		{"account_id", func(req *pb.CreateAlertRequest, spell func(string) string) {
			req.AccountId = spell(req.AccountId)
		}},
		{"instrument_id", func(req *pb.CreateAlertRequest, spell func(string) string) {
			req.InstrumentId = spell(req.InstrumentId)
		}},
	}
	for _, malformed := range alertServerMalformedUUIDs {
		for _, field := range createFields {
			t.Run(malformed.name+"/CreateAlert/"+field.name, func(t *testing.T) {
				req := &pb.CreateAlertRequest{
					AccountId:    testOwnerAccountID,
					Type:         repository.AlertTypeTargetPrice,
					InstrumentId: testInstrumentID,
					Direction:    repository.AlertDirectionAbove,
					Threshold:    thresholdDomainMax,
				}
				field.set(req, malformed.spell)

				created, err := srv.CreateAlert(ctx, req)

				if err == nil {
					deleteAlertAtCleanup(t, repo, created.GetId())
				}
				if status.Code(err) != codes.InvalidArgument {
					t.Errorf("CreateAlert(%v) = (%v, %v), want InvalidArgument", req, created, err)
				}
			})
		}
	}
}

func TestDecimalTextScan_driverSource_normalized(t *testing.T) {
	cases := []struct {
		name string
		src  any
		want decimalText
	}{
		{"pgxFixedScale", "1.50000000", decimalText{Text: "1.5", Valid: true}},
		{"mssqlFixedScaleInteger", []byte("10.00000000"), decimalText{Text: "10", Valid: true}},
		{"integer", "10", decimalText{Text: "10", Valid: true}},
		{"integerTrailingZeros", "100", decimalText{Text: "100", Valid: true}},
		{"negativeZero", "-0.00000000", decimalText{Text: "0", Valid: true}},
		{"smallestStep", "0.00000001", decimalText{Text: "0.00000001", Valid: true}},
		{"mssqlMostNegativeThreshold", []byte("-9999999999.99999999"), decimalText{Text: "-9999999999.99999999", Valid: true}},
		{"largestTriggerValue", "99999999999999999999.99999999", decimalText{Text: "99999999999999999999.99999999", Valid: true}},
		{"leadingPoint", ".5", decimalText{Text: "0.5", Valid: true}},
		{"negativeLeadingPoint", "-.5", decimalText{Text: "-0.5", Valid: true}},
		{"null", nil, decimalText{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := decimalText{Text: "stale", Valid: true}

			if err := got.Scan(tc.src); err != nil {
				t.Fatalf("Scan(%#v): %v", tc.src, err)
			}
			if got != tc.want {
				t.Errorf("Scan(%#v) = %+v, want %+v", tc.src, got, tc.want)
			}
		})
	}
}

func TestDecimalTextScan_unsupportedSource_error(t *testing.T) {
	for _, src := range []any{int64(5), float64(1.5)} {
		t.Run(fmt.Sprintf("%T", src), func(t *testing.T) {
			var got decimalText

			if err := got.Scan(src); err == nil {
				t.Errorf("Scan(%#v) = %+v, want an error rather than a float or integer conversion", src, got)
			}
		})
	}
}

func TestDecimalTextValue_validity_textOrNil(t *testing.T) {
	cases := []struct {
		name  string
		value decimalText
		want  any
	}{
		{"valid", decimalText{Text: "1.5", Valid: true}, "1.5"},
		{"null", decimalText{}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := tc.value.Value()

			if err != nil || got != tc.want {
				t.Errorf("Value() = (%#v, %v), want (%#v, nil)", got, err, tc.want)
			}
		})
	}
}

func TestAlertToProto_decimalText_canonicalWireForm(t *testing.T) {
	cases := []struct {
		name string
		text string
		want string
	}{
		// The one accepted spelling that is not canonical: both RPC patterns admit it, a read gives "0"
		{"acceptedNegativeZero", "-0", "0"},
		{"zero", "0", "0"},
		{"fraction", "1.5", "1.5"},
		{"negativeFraction", "-0.5", "-0.5"},
		{"smallestStep", "0.00000001", "0.00000001"},
		{"negativeTenIntegerDigits", "-9999999999.99999999", "-9999999999.99999999"},
		{"twentyIntegerDigits", "99999999999999999999.99999999", "99999999999999999999.99999999"},
	}
	for _, tc := range cases {
		t.Run("threshold/"+tc.name, func(t *testing.T) {
			// The model Create builds from the request and replies from
			created := alertCreateFromProto(&pb.CreateAlertRequest{
				AccountId:    testOwnerAccountID,
				Type:         repository.AlertTypeProfitLoss,
				InstrumentId: testInstrumentID,
				Direction:    repository.AlertDirectionBelow,
				Threshold:    tc.text,
			}, alertNow())

			if got := created.toProto().Threshold; got != tc.want {
				t.Errorf("toProto().Threshold for request threshold %q = %q, want %q", tc.text, got, tc.want)
			}
		})
		t.Run("triggerValue/"+tc.name, func(t *testing.T) {
			triggered := &Alert{TriggerValue: decimalText{Text: tc.text, Valid: true}}

			if got := triggered.toProto().TriggerValue; got != tc.want {
				t.Errorf("toProto().TriggerValue for %q = %q, want %q", tc.text, got, tc.want)
			}
		})
	}
}

func TestAlertAfterFind_driverLocation_utcSameInstant(t *testing.T) {
	// The locations the drivers scan into: a fixed offset (go-mssqldb) and the process zone (pgx)
	createdAt := time.Date(2025, time.March, 30, 6, 32, 3, 123456000, time.FixedZone("UTC+05:30", 5*60*60+30*60))
	triggeredAt := time.Date(2025, time.March, 29, 21, 32, 3, 456789000, time.Local)
	cases := []struct {
		name        string
		triggeredAt *time.Time
	}{
		{"triggered", &triggeredAt},
		{"notTriggered", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			alert := &Alert{CreatedAt: createdAt, TriggeredAt: tc.triggeredAt}

			if err := alert.AfterFind(nil); err != nil {
				t.Fatalf("AfterFind: %v", err)
			}
			triggeredMatches := alert.TriggeredAt == nil
			if tc.triggeredAt != nil {
				triggeredMatches = alert.TriggeredAt != nil && utcInstant(*alert.TriggeredAt, *tc.triggeredAt)
			}
			if !utcInstant(alert.CreatedAt, createdAt) || !triggeredMatches {
				t.Errorf("after AfterFind CreatedAt %v and TriggeredAt %v, want %v and %v, each in UTC",
					alert.CreatedAt, alert.TriggeredAt, createdAt, tc.triggeredAt)
			}
		})
	}
}

// safeAlertSecret stands for the connection and schema details a driver error can carry
const safeAlertSecret = "user=postgres database=TradeManagement"

// safeAlertSQLStateError has the shape of a pgx PgError
type safeAlertSQLStateError struct{ code string }

func (e safeAlertSQLStateError) Error() string {
	return `ERROR: violates foreign key constraint "FK_Alerts_Accounts" (` + safeAlertSecret + `) (SQLSTATE ` + e.code + `)`
}

func (e safeAlertSQLStateError) SQLState() string { return e.code }

// SQL Server's messages for error 547, which it reports for both kinds of constraint conflict
const (
	safeAlertForeignKeyMessage = `The INSERT statement conflicted with the FOREIGN KEY constraint "FK_Alerts_Accounts". The conflict occurred in database "TradeManagement", table "dbo.Accounts", column 'Id'.`
	safeAlertCheckMessage      = `The INSERT statement conflicted with the CHECK constraint "CK__Alerts__Type__3A81B327". The conflict occurred in database "TradeManagement", table "dbo.Alerts", column 'Type'.`
	// Another table's foreign key, which no alert statement can conflict with
	safeAlertOtherForeignKeyMessage = `The INSERT statement conflicted with the FOREIGN KEY constraint "FK_Trades_Accounts". The conflict occurred in database "TradeManagement", table "dbo.Accounts", column 'Id'.`
	// The same conflicts as SQL Server words them in a German or Dutch session. German quotes the
	// constraint name and Dutch leaves it bare
	safeAlertGermanAccountForeignKeyMessage    = `Die INSERT-Anweisung steht in Konflikt mit der FOREIGN KEY-Einschränkung "FK_Alerts_Accounts". Der Konflikt trat in der TradeManagement-Datenbank, Tabelle "dbo.Accounts", column 'Id' auf.`
	safeAlertGermanInstrumentForeignKeyMessage = `Die INSERT-Anweisung steht in Konflikt mit der FOREIGN KEY-Einschränkung "FK_Alerts_Instruments". Der Konflikt trat in der TradeManagement-Datenbank, Tabelle "dbo.Instruments", column 'Id' auf.`
	safeAlertDutchInstrumentForeignKeyMessage  = `De instructie INSERT is strijdig met de FOREIGN KEY-beperking FK_Alerts_Instruments. Het conflict is opgetreden in database TradeManagement, tabel dbo.Instruments, column 'Id'.`
	safeAlertGermanCheckMessage                = `Die INSERT-Anweisung steht in Konflikt mit der CHECK-Einschränkung "CK__Alerts__Type__03F0984C". Der Konflikt trat in der TradeManagement-Datenbank, Tabelle "dbo.Alerts", column 'Type' auf.`
	safeAlertGermanOtherForeignKeyMessage      = `Die INSERT-Anweisung steht in Konflikt mit der FOREIGN KEY-Einschränkung "FK_Trades_Accounts". Der Konflikt trat in der TradeManagement-Datenbank, Tabelle "dbo.Accounts", column 'Id' auf.`
)

// safeAlertSQLServerError has the shape of a go-mssqldb Error
type safeAlertSQLServerError struct {
	number  int32
	message string
}

func (e safeAlertSQLServerError) Error() string {
	return fmt.Sprintf(`mssql: %s (%s) (%d)`, e.message, safeAlertSecret, e.number)
}

func (e safeAlertSQLServerError) SQLErrorNumber() int32 { return e.number }

func (e safeAlertSQLServerError) SQLErrorMessage() string { return e.message }

// safeAlertSQLServerNumberError reports a SQL Server error number without the message
type safeAlertSQLServerNumberError struct{ number int32 }

func (e safeAlertSQLServerNumberError) Error() string {
	return fmt.Sprintf(`mssql: (%s) (%d)`, safeAlertSecret, e.number)
}

func (e safeAlertSQLServerNumberError) SQLErrorNumber() int32 { return e.number }

// safeAlertDialError is a refused connection as pgx reports it, naming the user and database
func safeAlertDialError() error {
	refused := &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connect: connection refused")}
	return fmt.Errorf("failed to connect to `%s`: %w", safeAlertSecret, refused)
}

// sameSafeAlertError compares classifications by class and the sentinel they stand for, and sentinels
// by identity, so a sentinel still wrapped in the original error does not match
func sameSafeAlertError(got, want error) bool {
	w, ok := want.(*alertStorageError)
	if !ok {
		return got == want
	}
	g, ok := got.(*alertStorageError)
	return ok && g.class == w.class && g.sentinel == w.sentinel
}

func TestSafeAlertError_errorKind_classifiedWithoutDetails(t *testing.T) {
	classified := &alertStorageError{class: "SQLSTATE 08006"}
	cases := []struct {
		name string
		err  error
		want error
	}{
		{"nil", nil, nil},
		{"repositoryNotFound", fmt.Errorf("lookup: %w", repository.ErrNotFound), repository.ErrNotFound},
		{"recordNotFound", fmt.Errorf("first: %w", gorm.ErrRecordNotFound), gorm.ErrRecordNotFound},
		{"canceled", fmt.Errorf("%s: %w", safeAlertSecret, context.Canceled), context.Canceled},
		{"deadlineExceeded", fmt.Errorf("%s: %w", safeAlertSecret, context.DeadlineExceeded), context.DeadlineExceeded},
		{"postgresError", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "23503"}), &alertStorageError{class: "SQLSTATE 23503", sentinel: repository.ErrAlertReferenceNotFound}},
		{"postgresErrorLetters", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "P0001"}), &alertStorageError{class: "SQLSTATE P0001"}},
		// A code outside the SQLSTATE form is not echoed, whatever the server sent
		{"postgresErrorControlCharacter", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "23\n03"}), &alertStorageError{class: "unclassified"}},
		{"postgresErrorInjectedLine", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "x\r\nFAKE LOG LINE"}), &alertStorageError{class: "unclassified"}},
		{"postgresErrorLowercase", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "2350a"}), &alertStorageError{class: "unclassified"}},
		{"postgresErrorFourCharacters", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "2350"}), &alertStorageError{class: "unclassified"}},
		{"postgresErrorSixCharacters", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "235030"}), &alertStorageError{class: "unclassified"}},
		{"postgresErrorEmpty", fmt.Errorf("create: %w", safeAlertSQLStateError{code: ""}), &alertStorageError{class: "unclassified"}},
		{"sqlServerError", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertForeignKeyMessage}), &alertStorageError{class: "SQL Server error 547", sentinel: repository.ErrAlertReferenceNotFound}},
		{"dialFailure", safeAlertDialError(), &alertStorageError{class: "connection failure"}},
		{"badConnection", fmt.Errorf("%s: %w", safeAlertSecret, driver.ErrBadConn), &alertStorageError{class: "connection failure"}},
		{"connectionDone", fmt.Errorf("%s: %w", safeAlertSecret, dbsql.ErrConnDone), &alertStorageError{class: "connection failure"}},
		{"alreadyClassified", fmt.Errorf("acknowledge: %w", classified), classified},
		{"other", errors.New("unexpected reply for " + safeAlertSecret), &alertStorageError{class: "unclassified"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := safeAlertError(tc.err)

			if !sameSafeAlertError(got, tc.want) || (got != nil && strings.Contains(got.Error(), safeAlertSecret)) {
				t.Errorf("safeAlertError(%v) = %#v, want %#v without %q", tc.err, got, tc.want, safeAlertSecret)
			}
		})
	}
}

// Callers can still branch on the driver's code, as the dialect matchers above do, while the text
// that reaches a log line or a status stays the classification
func TestSafeAlertError_driverError_codeReachableTextWithheld(t *testing.T) {
	cases := []struct {
		name    string
		err     error
		matches func(error) bool
	}{
		{"postgresError", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "23503"}), func(err error) bool {
			var pgErr pgDriverError
			return errors.As(err, &pgErr) && pgErr.SQLState() == "23503"
		}},
		{"sqlServerError", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertForeignKeyMessage}), func(err error) bool {
			var mssqlErr mssqlDriverError
			return errors.As(err, &mssqlErr) && mssqlErr.SQLErrorNumber() == 547
		}},
		{"dialFailure", safeAlertDialError(), func(err error) bool {
			var opErr *net.OpError
			return errors.As(err, &opErr)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := safeAlertError(tc.err)

			if !tc.matches(got) || strings.Contains(got.Error(), safeAlertSecret) || strings.Contains(fmt.Sprintf("%+v", got), safeAlertSecret) {
				t.Errorf("safeAlertError(%v) = %q, want the driver error reachable and the text without %q", tc.err, got, safeAlertSecret)
			}
		})
	}
}

// Only a foreign-key violation, an account or instrument that names no row, matches
// ErrAlertReferenceNotFound and prints as it. SQL Server reports CHECK conflicts under the same number
// and words both in the session language, so a 547 matches only when it names an Alerts foreign key,
// in any language. A CHECK violation, another table's foreign key or an error without a message stays
// a storage failure
func TestSafeAlertError_constraintViolation_referenceSentinelOnlyForForeignKey(t *testing.T) {
	cases := []struct {
		name          string
		err           error
		wantReference bool
		wantText      string
	}{
		{"postgresForeignKey", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "23503"}), true, "account or instrument not found: SQLSTATE 23503"},
		{"postgresCheck", fmt.Errorf("create: %w", safeAlertSQLStateError{code: "23514"}), false, "alert storage failure: SQLSTATE 23514"},
		{"sqlServerForeignKey", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertForeignKeyMessage}), true, "account or instrument not found: SQL Server error 547"},
		{"sqlServerCheck", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertCheckMessage}), false, "alert storage failure: SQL Server error 547"},
		{"sqlServerOtherTableForeignKey", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertOtherForeignKeyMessage}), false, "alert storage failure: SQL Server error 547"},
		{"sqlServerGermanAccountForeignKey", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertGermanAccountForeignKeyMessage}), true, "account or instrument not found: SQL Server error 547"},
		{"sqlServerGermanInstrumentForeignKey", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertGermanInstrumentForeignKeyMessage}), true, "account or instrument not found: SQL Server error 547"},
		{"sqlServerDutchUnquotedForeignKey", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertDutchInstrumentForeignKeyMessage}), true, "account or instrument not found: SQL Server error 547"},
		{"sqlServerGermanCheck", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertGermanCheckMessage}), false, "alert storage failure: SQL Server error 547"},
		{"sqlServerGermanOtherTableForeignKey", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 547, message: safeAlertGermanOtherForeignKeyMessage}), false, "alert storage failure: SQL Server error 547"},
		{"sqlServerOtherNumber", fmt.Errorf("create: %w", safeAlertSQLServerError{number: 2627, message: safeAlertForeignKeyMessage}), false, "alert storage failure: SQL Server error 2627"},
		{"sqlServerWithoutMessage", fmt.Errorf("create: %w", safeAlertSQLServerNumberError{number: 547}), false, "alert storage failure: SQL Server error 547"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := safeAlertError(tc.err)

			if errors.Is(got, repository.ErrAlertReferenceNotFound) != tc.wantReference || errors.Is(got, repository.ErrNotFound) || got.Error() != tc.wantText {
				t.Errorf("safeAlertError(%v) = %q (reference %t), want %q (reference %t)",
					tc.err, got, errors.Is(got, repository.ErrAlertReferenceNotFound), tc.wantText, tc.wantReference)
			}
		})
	}
}

// safeAlertRecordingLogger records the level it is set to and every error Trace receives
type safeAlertRecordingLogger struct {
	logger.Interface
	level  logger.LogLevel
	traced *[]error
}

func (l safeAlertRecordingLogger) LogMode(level logger.LogLevel) logger.Interface {
	l.level = level
	return l
}

func (l safeAlertRecordingLogger) Trace(_ context.Context, _ time.Time, _ func() (string, int64), err error) {
	*l.traced = append(*l.traced, err)
}

func TestAlertLogger_trace_safeErrorPassedOn(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want error
	}{
		{"success", nil, nil},
		// Kept, so a logger set to IgnoreRecordNotFoundError still recognises it
		{"recordNotFound", gorm.ErrRecordNotFound, gorm.ErrRecordNotFound},
		{"driverError", safeAlertDialError(), &alertStorageError{class: "connection failure"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var traced []error
			l := alertLogger{Interface: safeAlertRecordingLogger{Interface: logger.Discard, traced: &traced}}

			l.Trace(context.Background(), time.Now(), func() (string, int64) { return "SELECT 1", 0 }, tc.err)

			if len(traced) != 1 || !sameSafeAlertError(traced[0], tc.want) {
				t.Errorf("wrapped logger traced %v, want [%v]", traced, tc.want)
			}
		})
	}
}

// An unknown account or instrument is the caller's mistake: GORM's own logger prints the statement as
// a warning with the classification and nothing at its error-only level, and never the driver text
func TestAlertLogger_trace_referenceNotFoundLoggedBelowError(t *testing.T) {
	const statement = `INSERT INTO "Alerts" ("AccountId") VALUES ('0f0f0f0f-1111-4222-8333-444444444444')`
	referenceErr := fmt.Errorf("create: %w", safeAlertSQLStateError{code: "23503"})
	cases := []struct {
		name  string
		level logger.LogLevel
		rows  int64
		// The fragments the output holds in order; none means no output
		want []string
	}{
		{"warnLevel", logger.Warn, 0, []string{"[warn] account or instrument not found: SQLSTATE 23503\n[", "ms] [rows:0] " + statement + "\n"}},
		{"warnLevelUnknownRows", logger.Warn, -1, []string{"[warn] account or instrument not found: SQLSTATE 23503\n[", "ms] [rows:-] " + statement + "\n"}},
		{"errorLevel", logger.Error, 0, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			l := alertLogger{Interface: logger.New(stdlog.New(&out, "", 0), logger.Config{LogLevel: tc.level})}

			l.Trace(context.Background(), time.Now(), func() (string, int64) { return statement, tc.rows }, referenceErr)

			got := out.String()
			if (tc.want == nil && got != "") || !containsInOrder(got, tc.want) || strings.Contains(got, safeAlertSecret) {
				t.Errorf("GORM logger at level %d printed %q, want %q in order without %q", tc.level, got, tc.want, safeAlertSecret)
			}
		})
	}
}

// containsInOrder reports whether s holds every fragment, each after the one before it
func containsInOrder(s string, fragments []string) bool {
	for _, fragment := range fragments {
		_, after, found := strings.Cut(s, fragment)
		if !found {
			return false
		}
		s = after
	}
	return true
}

func TestAlertLogger_logMode_wrapperKept(t *testing.T) {
	l := alertLogger{Interface: safeAlertRecordingLogger{Interface: logger.Discard, traced: new([]error)}}

	got := l.LogMode(logger.Info)

	wrapper, ok := got.(alertLogger)
	if !ok {
		t.Fatalf("LogMode returned %T, want alertLogger", got)
	}
	if inner, ok := wrapper.Interface.(safeAlertRecordingLogger); !ok || inner.level != logger.Info {
		t.Errorf("LogMode wraps %#v, want the recording logger at level Info", wrapper.Interface)
	}
}

func TestAlertLogger_paramsFilter_wrappedSettingKept(t *testing.T) {
	params := []any{testOwnerAccountID, true}
	cases := []struct {
		name    string
		wrapped logger.Interface
		want    []any
	}{
		{"parameterizedQueries", logger.New(stdlog.New(io.Discard, "", 0), logger.Config{ParameterizedQueries: true}), nil},
		{"inlineParameters", logger.New(stdlog.New(io.Discard, "", 0), logger.Config{}), params},
		// The embedded interface alone hides the wrapped logger's ParamsFilter
		{"noFilter", struct{ logger.Interface }{logger.Discard}, params},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sql, got := alertLogger{Interface: tc.wrapped}.ParamsFilter(context.Background(), "SELECT ?, ?", params...)

			if sql != "SELECT ?, ?" || !slices.Equal(got, tc.want) {
				t.Errorf("ParamsFilter = (%q, %v), want (%q, %v)", sql, got, "SELECT ?, ?", tc.want)
			}
		})
	}
}

// The pgx driver names the user, database and socket path when a connection fails. Through the real
// driver and GORM's own logger, no alert method's error and no log line may carry them
func TestNewAlertRepository_unreachableDatabase_noConnectionDetails(t *testing.T) {
	// A host that is an absolute path makes pgx dial the Unix socket <host>/.s.PGSQL.5432. Nothing
	// creates one in a fresh test directory, so every dial fails at once, and no other process can
	// take the address between setup and dial as it can a freed TCP port
	socketDir := t.TempDir()
	if runtime.GOOS == "windows" {
		// pgx takes only an upper-case drive for a path; Windows ignores the drive letter's case
		socketDir = strings.ToUpper(socketDir[:1]) + socketDir[1:]
	}
	// A quoted keyword value unescapes backslashes, so the path's backslashes and quotes are escaped
	host := strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(socketDir)
	var logs bytes.Buffer
	db, err := gorm.Open(postgres.Open("host='"+host+"' user=alertuser password=secretpw dbname=alertdb sslmode=disable connect_timeout=5"), &gorm.Config{
		NamingStrategy:       dbNamer{},
		DisableAutomaticPing: true,
		Logger:               logger.New(stdlog.New(&logs, "", 0), logger.Config{LogLevel: logger.Warn}),
	})
	if err != nil {
		t.Fatalf("gorm.Open: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("DB: %v", err)
	}
	t.Cleanup(func() {
		if err := sqlDB.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	repo := NewAlertRepository(db)
	ctx := context.Background()
	id := uuid.NewString()
	secrets := []string{"alertuser", "alertdb", "secretpw", socketDir}
	carriesSecret := func(text string) bool {
		return slices.ContainsFunc(secrets, func(secret string) bool { return strings.Contains(text, secret) })
	}
	calls := []struct {
		name string
		call func() error
	}{
		{"Create", func() error {
			_, err := repo.Create(ctx, &pb.CreateAlertRequest{
				AccountId:    testOwnerAccountID,
				Type:         repository.AlertTypeTargetPrice,
				InstrumentId: testInstrumentID,
				Direction:    repository.AlertDirectionAbove,
				Threshold:    "1.5",
			})
			return err
		}},
		{"List", func() error {
			_, err := repo.List(ctx, &pb.ListAlertsRequest{AccountId: testOwnerAccountID, TriggeredOnly: true})
			return err
		}},
		{"GetByID", func() error { _, err := repo.GetByID(ctx, id); return err }},
		{"UpdateEnabled", func() error { _, err := repo.UpdateEnabled(ctx, id, true); return err }},
		{"Delete", func() error { _, err := repo.Delete(ctx, id); return err }},
		{"Trigger", func() error { _, err := repo.Trigger(ctx, id, 1, "1.5"); return err }},
		{"Acknowledge", func() error { _, err := repo.Acknowledge(ctx, id); return err }},
	}
	for _, tc := range calls {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.call()

			// connect_timeout ends a slow attempt with the bare deadline error instead
			connectionFailure := &alertStorageError{class: "connection failure"}
			if !sameSafeAlertError(err, connectionFailure) && !sameSafeAlertError(err, context.DeadlineExceeded) || carriesSecret(err.Error()) {
				t.Errorf("%s error = %#v, want %v", tc.name, err, connectionFailure)
			}
		})
	}
	t.Run("log", func(t *testing.T) {
		got := logs.String()

		if !strings.Contains(got, "alert storage failure: connection failure") || carriesSecret(got) {
			t.Errorf("GORM log = %q, want the connection failure class and none of %q", got, secrets)
		}
	})
}

// leakMarker is the password in the connection strings below, so a test can tell whether any output
// repeats it
const leakMarker = "Pw4LeakCheck"

// captureConnectorLog collects the logrus output, where db.Connect logs every failed attempt, until the
// test ends
func captureConnectorLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	previous := log.StandardLogger().Out
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(previous) })
	return &buf
}

// clearPostgresEnv blanks, until the test ends, every PG* variable pgx reads as a connection default.
// pgx treats an empty value as unset, so a developer's PGSERVICE, PGSSLMODE or similar cannot change
// how the synthetic connection strings below parse or connect
func clearPostgresEnv(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		"PGAPPNAME", "PGCHANNELBINDING", "PGCONNECT_TIMEOUT", "PGDATABASE", "PGHOST", "PGMAXPROTOCOLVERSION",
		"PGMINPROTOCOLVERSION", "PGOPTIONS", "PGPASSFILE", "PGPASSWORD", "PGPORT", "PGREQUIREAUTH",
		"PGSERVICE", "PGSERVICEFILE", "PGSSLCERT", "PGSSLKEY", "PGSSLMODE", "PGSSLNEGOTIATION",
		"PGSSLPASSWORD", "PGSSLROOTCERT", "PGSSLSNI", "PGTARGETSESSIONATTRS", "PGTZ", "PGUSER",
	} {
		t.Setenv(name, "")
	}
}

// closingDatabaseURLs returns, per DB_TYPE, a well-formed connection string with leakMarker as its
// password, aimed at a loopback listener that closes every connection it accepts. Connecting fails
// during the handshake at once, with no closed port or timeout to wait on
func closingDatabaseURLs(t *testing.T) map[string]string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen on loopback: %v", err)
	}
	t.Cleanup(func() {
		if err := listener.Close(); err != nil {
			t.Errorf("close loopback listener: %v", err)
		}
	})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_ = conn.Close()
		}
	}()
	addr := listener.Addr().String()
	return map[string]string{
		"postgres": "postgres://postgres:" + leakMarker + "@" + addr + "/TradeManagement?sslmode=disable",
		"mssql":    "sqlserver://sa:" + leakMarker + "@" + addr + "?database=TradeManagement&encrypt=disable",
	}
}

func TestConnectAlertTestBackend_malformedURL_errorWithholdsURL(t *testing.T) {
	clearPostgresEnv(t)
	cases := []struct {
		name   string
		dbType string
		url    string
	}{
		{"postgresNonNumericPort", "postgres", "postgres://postgres:" + leakMarker + "@localhost:notaport/TradeManagement"},
		{"postgresInvalidSslmode", "postgres", "postgres://postgres:" + leakMarker + "@localhost:5432/TradeManagement?sslmode=bogus"},
		{"postgresKeywordValueNonNumericPort", "postgres", "host=localhost user=postgres password=" + leakMarker + " port=notaport dbname=TradeManagement"},
		// pgx's best-effort redaction misses a password in the port position
		{"postgresMarkerInPort", "postgres", "postgres://postgres@localhost:" + leakMarker + "/TradeManagement"},
		{"mssqlNonNumericPort", "mssql", "sqlserver://sa:" + leakMarker + "@localhost:notaport?database=TradeManagement"},
		{"mssqlInvalidEncrypt", "mssql", "sqlserver://sa:" + leakMarker + "@localhost:1433?database=TradeManagement&encrypt=bogus"},
		// go-mssqldb repeats a rejected port value
		{"mssqlKeywordValueMarkerInPort", "mssql", "server=localhost," + leakMarker + ";user id=sa;password=x"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			connectorLog := captureConnectorLog(t)

			// A zero DB_CONNECT_TIMEOUT would end db.Connect after one attempt if the check let the URL through
			_, err := connectAlertTestBackend(config.DatabaseConfig{Type: tc.dbType, Url: tc.url, RetryInterval: time.Hour})

			if err == nil || !strings.Contains(err.Error(), "DB_URL") {
				t.Fatalf("connectAlertTestBackend = %v, want an error naming DB_URL", err)
			}
			for _, leaked := range []string{leakMarker, tc.url} {
				if strings.Contains(err.Error(), leaked) || strings.Contains(connectorLog.String(), leaked) {
					t.Errorf("error %q or connector log %q repeats %q", err, connectorLog, leaked)
				}
			}
		})
	}
}

func TestConnectAlertTestBackend_nonpositiveRetryInterval_errorNamesSetting(t *testing.T) {
	clearPostgresEnv(t)
	urls := closingDatabaseURLs(t)
	cases := []struct {
		name     string
		dbType   string
		interval time.Duration
	}{
		{"postgresZero", "postgres", 0},
		{"postgresNegative", "postgres", -time.Second},
		{"mssqlZero", "mssql", 0},
		{"mssqlNegative", "mssql", -time.Second},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Reaching time.NewTicker would panic and end the test binary instead of returning
			_, err := connectAlertTestBackend(config.DatabaseConfig{Type: tc.dbType, Url: urls[tc.dbType], RetryInterval: tc.interval})

			if err == nil || !strings.Contains(err.Error(), "DB_RETRY_INTERVAL") {
				t.Errorf("connectAlertTestBackend(RetryInterval %s) = %v, want an error naming DB_RETRY_INTERVAL", tc.interval, err)
			}
		})
	}
}

func TestConnectAlertTestBackend_unreachableDatabase_errorNamesConnectStage(t *testing.T) {
	clearPostgresEnv(t)
	urls := closingDatabaseURLs(t)
	for _, dbType := range []string{"postgres", "mssql"} {
		t.Run(dbType, func(t *testing.T) {
			connectorLog := captureConnectorLog(t)

			// A zero DB_CONNECT_TIMEOUT ends db.Connect after its first attempt
			_, err := connectAlertTestBackend(config.DatabaseConfig{Type: dbType, Url: urls[dbType], RetryInterval: time.Hour})

			if err == nil || !strings.Contains(err.Error(), "DB_CONNECT_TIMEOUT") {
				t.Fatalf("connectAlertTestBackend = %v, want an error naming the DB_CONNECT_TIMEOUT stage", err)
			}
			if strings.Contains(err.Error(), leakMarker) || strings.Contains(connectorLog.String(), leakMarker) {
				t.Errorf("error %q or connector log %q repeats the password", err, connectorLog)
			}
		})
	}
}
