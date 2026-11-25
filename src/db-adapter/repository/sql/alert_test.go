package sql

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dynatrace/easytrade/dbadapter/config"
	pb "github.com/dynatrace/easytrade/dbadapter/proto"
	"github.com/dynatrace/easytrade/dbadapter/repository"
	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"
)

// The real-database cases opt in through a test-binary flag rather than an environment variable, so
// no test-only setting needs a place in the deployment manifests. They reuse DB_TYPE and DB_URL:
//
//	go test ./repository/sql/ -run TestAlertRepository -args -integration
var integration = flag.Bool("integration", false, "run alert repository tests against the database in DB_TYPE/DB_URL")

const (
	// Seeded INTERNAL owner account and first instrument, identical on both dialects. The account has
	// no holdings, so a broker evaluator on the same database skips its PROFIT_LOSS alerts
	testOwnerAccountID = "a0000000-0000-4000-8000-000000000000"
	testInstrumentID   = "c0000000-0000-4000-8000-000000000001"
	// The threshold domain maximum: a TARGET_PRICE ABOVE it is never crossed, so a broker evaluator on
	// the same database never triggers the rows these tests trigger themselves
	neverReachedThreshold = "9999999999.99999999"
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
	// With the flag set, a missing or unreachable database fails the run instead of skipping it
	if alertBackendErr != nil {
		t.Fatalf("alert repository tests need a database: %v", alertBackendErr)
	}
	return alertBackend
}

func connectAlertTestBackend(cfg config.DatabaseConfig) (*sqlBackend, error) {
	if cfg.Url == "" {
		return nil, errors.New("DB_URL is not set")
	}
	var backend repository.DBBackend
	var err error
	switch cfg.Type {
	case "postgres":
		backend, err = NewPostgresBackend(cfg)
	case "mssql":
		backend, err = NewMSSQLBackend(cfg)
	default:
		return nil, fmt.Errorf("unsupported DB_TYPE %q", cfg.Type)
	}
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

// createArmedTestAlert creates an alert that only the test itself can trigger
func createArmedTestAlert(t *testing.T, repo repository.AlertRepository) *pb.AlertMessage {
	t.Helper()
	return createTestAlert(t, repo, repository.AlertTypeTargetPrice, repository.AlertDirectionAbove, neverReachedThreshold)
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
	ctx := context.Background()
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
	// The raw insert bypasses the adapter's validation, so only the table's CHECKs stand between it
	// and an inexact value. The explicit id lets the test read the row back and clean it up.
	insert := func(t *testing.T, typ, direction string) (string, error) {
		t.Helper()
		id := uuid.New().String()
		t.Cleanup(func() {
			if _, err := repo.Delete(context.Background(), id); err != nil && !errors.Is(err, repository.ErrNotFound) {
				t.Errorf("cleanup Delete(%s): %v", id, err)
			}
		})
		err := b.gormDB.WithContext(ctx).Exec(insertSQL,
			id, testOwnerAccountID, typ, testInstrumentID, direction,
			"1", true, 1, false, time.Now().UTC().Truncate(time.Microsecond),
		).Error
		return id, err
	}

	rejected := []struct {
		name      string
		typ       string
		direction string
	}{
		{"lowercaseType", "target_price", repository.AlertDirectionAbove},
		{"lowercaseDirection", repository.AlertTypeTargetPrice, "above"},
		// Fits varchar(12), so only the CHECK can refuse it; SQL Server's = ignores trailing spaces
		{"trailingSpaceTypeWithinWidth", "PROFIT_LOSS ", repository.AlertDirectionAbove},
	}
	for _, tc := range rejected {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := insert(t, tc.typ, tc.direction); err == nil {
				t.Errorf("insert of Type %q Direction %q succeeded, want a CHECK violation", tc.typ, tc.direction)
			}
		})
	}

	// One space beyond the column width: PostgreSQL truncates excess spaces before the CHECK, and SQL
	// Server may too, so the guarantee is only that no inexact value is ever stored
	overWidth := []struct {
		name      string
		typ       string
		direction string
	}{
		{"trailingSpaceTypeOverWidth", "TARGET_PRICE ", repository.AlertDirectionAbove},
		{"trailingSpaceDirectionOverWidth", repository.AlertTypeTargetPrice, "ABOVE "},
	}
	for _, tc := range overWidth {
		t.Run(tc.name, func(t *testing.T) {
			id, err := insert(t, tc.typ, tc.direction)
			if err != nil {
				t.Logf("insert of Type %q Direction %q refused: %v", tc.typ, tc.direction, err)
				return
			}

			got := getTestAlert(t, repo, id)

			if got.Type != repository.AlertTypeTargetPrice || got.Direction != repository.AlertDirectionAbove {
				t.Errorf("stored Type %q Direction %q, want exactly %q %q",
					got.Type, got.Direction, repository.AlertTypeTargetPrice, repository.AlertDirectionAbove)
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
