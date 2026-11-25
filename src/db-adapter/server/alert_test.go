package server

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"net"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/dynatrace/easytrade/dbadapter/proto"
	"github.com/dynatrace/easytrade/dbadapter/repository"
	log "github.com/sirupsen/logrus"
	logtest "github.com/sirupsen/logrus/hooks/test"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// The AlertService handlers against an in-memory repository at the gRPC seam: argument validation,
// delegation, NotFound and zero-row outcomes, which id spellings reach the repository and in what
// form, that rejections never echo their input, and that repository errors leave only a fixed status

const (
	// Hex letters in every group, so the upper-case spelling differs from the canonical one
	testAlertID        = "3f2b8c1d-9e4a-4b7c-8d2e-1a5f6b7c8d9e"
	testOtherAlertID   = "4e3c9d2e-af5b-4c8d-9e3f-2b6a7c8d9eaf"
	testAccountID      = "5a1e7c3b-2d4f-4e6a-9b8c-0d1e2f3a4b5c"
	testOtherAccountID = "6b2f8d4c-3e5a-4f7b-8c9d-1e2f3a4b5c6d"
	testInstrumentID   = "7c9d1e2f-3a4b-4c5d-8e6f-7a8b9c0d1e2f"
	// No fake holds an alert under it
	testUnknownID = "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a"
	// testSecret stands for the connection details a driver error can carry
	testSecret = "user=postgres database=TradeManagement"
)

// fakeTime is the fake repository's clock, so every time it stamps is known to the test
var fakeTime = time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC)

// alertCall is one repository call with the id it received; Create and List record the account id
type alertCall struct{ method, id string }

// fakeAlertRepository is an in-memory AlertRepository with the semantics its interface documents and
// the SQL repository implements. It records every call with the id it received and, with err set,
// fails every call with err before reading its alerts. The mutex orders a server goroutine's writes
// before the test's reads
type fakeAlertRepository struct {
	mu      sync.Mutex
	alerts  []*pb.AlertMessage // in creation order
	created int
	calls   []alertCall
	err     error
}

var _ repository.AlertRepository = (*fakeAlertRepository)(nil)

// newFakeAlertRepository holds copies of alerts, so a call never changes a test's fixture
func newFakeAlertRepository(alerts ...*pb.AlertMessage) *fakeAlertRepository {
	r := &fakeAlertRepository{}
	for _, a := range alerts {
		r.alerts = append(r.alerts, proto.CloneOf(a))
	}
	return r
}

// record notes a call and returns the injected error. The caller holds r.mu
func (r *fakeAlertRepository) record(method, id string) error {
	r.calls = append(r.calls, alertCall{method, id})
	return r.err
}

func (r *fakeAlertRepository) recorded() []alertCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.calls)
}

// find returns the held alert with id, or nil. The caller holds r.mu
func (r *fakeAlertRepository) find(id string) *pb.AlertMessage {
	for _, a := range r.alerts {
		if a.Id == id {
			return a
		}
	}
	return nil
}

// Create holds an armed alert: enabled, arming revision 1, not acknowledged, no trigger
func (r *fakeAlertRepository) Create(_ context.Context, req *pb.CreateAlertRequest) (*pb.AlertMessage, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.record("Create", req.AccountId); err != nil {
		return nil, err
	}
	r.created++
	a := &pb.AlertMessage{
		Id:             fakeAlertID(r.created),
		AccountId:      req.AccountId,
		Type:           req.Type,
		InstrumentId:   req.InstrumentId,
		Direction:      req.Direction,
		Threshold:      req.Threshold,
		Enabled:        true,
		ArmingRevision: 1,
		CreatedAt:      timestamppb.New(fakeTime),
	}
	r.alerts = append(r.alerts, a)
	return proto.CloneOf(a), nil
}

// List returns every account's alerts for an empty account id, combines the three filters with AND,
// and returns the alert held last first
func (r *fakeAlertRepository) List(_ context.Context, req *pb.ListAlertsRequest) ([]*pb.AlertMessage, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.record("List", req.AccountId); err != nil {
		return nil, err
	}
	var alerts []*pb.AlertMessage
	for _, a := range slices.Backward(r.alerts) {
		if (req.AccountId != "" && a.AccountId != req.AccountId) ||
			(req.ArmedOnly && (!a.Enabled || a.TriggeredAt != nil)) ||
			(req.TriggeredOnly && a.TriggeredAt == nil) ||
			(req.UnacknowledgedOnly && a.Acknowledged) {
			continue
		}
		alerts = append(alerts, proto.CloneOf(a))
	}
	return alerts, nil
}

func (r *fakeAlertRepository) GetByID(_ context.Context, id string) (*pb.AlertMessage, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.record("GetByID", id); err != nil {
		return nil, err
	}
	a := r.find(id)
	if a == nil {
		return nil, repository.ErrNotFound
	}
	return proto.CloneOf(a), nil
}

// UpdateEnabled with true re-arms: it enables, clears the trigger fields and acknowledged, and adds 1
// to the arming revision. With false it only disables. It returns the alert as it wrote it
func (r *fakeAlertRepository) UpdateEnabled(_ context.Context, id string, enabled bool) (*pb.AlertMessage, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.record("UpdateEnabled", id); err != nil {
		return nil, err
	}
	a := r.find(id)
	if a == nil {
		return nil, repository.ErrNotFound
	}
	a.Enabled = enabled
	if enabled {
		a.TriggeredAt = nil
		a.TriggerValue = ""
		a.Acknowledged = false
		a.ArmingRevision++
	}
	return proto.CloneOf(a), nil
}

func (r *fakeAlertRepository) Delete(_ context.Context, id string) (int32, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.record("Delete", id); err != nil {
		return 0, err
	}
	i := slices.IndexFunc(r.alerts, func(a *pb.AlertMessage) bool { return a.Id == id })
	if i < 0 {
		return 0, repository.ErrNotFound
	}
	r.alerts = slices.Delete(r.alerts, i, i+1)
	return 1, nil
}

// Trigger is the conditional write: only an enabled, untriggered alert in the given arming triggers.
// Any other alert, or none, is zero rows and returns (false, nil)
func (r *fakeAlertRepository) Trigger(_ context.Context, id string, armingRevision int32, triggerValue string) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.record("Trigger", id); err != nil {
		return false, err
	}
	a := r.find(id)
	if a == nil || a.ArmingRevision != armingRevision || !a.Enabled || a.TriggeredAt != nil {
		return false, nil
	}
	a.TriggeredAt = timestamppb.New(fakeTime)
	a.TriggerValue = triggerValue
	a.Acknowledged = false
	return true, nil
}

// Acknowledge acknowledges a triggered alert; a known alert whose current arming has not triggered
// returns (0, nil)
func (r *fakeAlertRepository) Acknowledge(_ context.Context, id string) (int32, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.record("Acknowledge", id); err != nil {
		return 0, err
	}
	a := r.find(id)
	if a == nil {
		return 0, repository.ErrNotFound
	}
	if a.TriggeredAt == nil {
		return 0, nil
	}
	a.Acknowledged = true
	return 1, nil
}

// fakeAlertID is the key the fake generates for its n-th created alert
func fakeAlertID(n int) string {
	return fmt.Sprintf("a1e7c0de-0000-4000-8000-%012d", n)
}

// nilBackend is a DBBackend whose nine accessors return nil repositories. Register calls each accessor
// and only stores the result
type nilBackend struct{}

var _ repository.DBBackend = nilBackend{}

func (nilBackend) Ping(context.Context) error                       { return nil }
func (nilBackend) Account() repository.AccountRepository            { return nil }
func (nilBackend) Balance() repository.BalanceRepository            { return nil }
func (nilBackend) CreditCard() repository.CreditCardOrderRepository { return nil }
func (nilBackend) Instrument() repository.InstrumentRepository      { return nil }
func (nilBackend) Package() repository.PackageRepository            { return nil }
func (nilBackend) Pricing() repository.PricingRepository            { return nil }
func (nilBackend) Product() repository.ProductRepository            { return nil }
func (nilBackend) Trade() repository.TradeRepository                { return nil }
func (nilBackend) Alert() repository.AlertRepository                { return nil }

// armedAlert is a held TARGET_PRICE alert in its first arming, enabled and not triggered
func armedAlert() *pb.AlertMessage {
	return &pb.AlertMessage{
		Id:             testAlertID,
		AccountId:      testAccountID,
		Type:           repository.AlertTypeTargetPrice,
		InstrumentId:   testInstrumentID,
		Direction:      repository.AlertDirectionAbove,
		Threshold:      "1.5",
		Enabled:        true,
		ArmingRevision: 1,
		CreatedAt:      timestamppb.New(fakeTime),
	}
}

// alertWith is armedAlert changed by set
func alertWith(set func(*pb.AlertMessage)) *pb.AlertMessage {
	a := armedAlert()
	set(a)
	return a
}

// markTriggered records a trigger of a's current arming at the value 2
func markTriggered(a *pb.AlertMessage) {
	a.TriggeredAt = timestamppb.New(fakeTime)
	a.TriggerValue = "2"
}

// createRequest is a valid TARGET_PRICE request changed by set
func createRequest(set func(*pb.CreateAlertRequest)) *pb.CreateAlertRequest {
	req := &pb.CreateAlertRequest{
		AccountId:    testAccountID,
		Type:         repository.AlertTypeTargetPrice,
		InstrumentId: testInstrumentID,
		Direction:    repository.AlertDirectionAbove,
		Threshold:    "1.5",
	}
	set(req)
	return req
}

// createdAlert is the alert a fake holds after its first Create, of req
func createdAlert(req *pb.CreateAlertRequest) *pb.AlertMessage {
	return &pb.AlertMessage{
		Id:             fakeAlertID(1),
		AccountId:      req.AccountId,
		Type:           req.Type,
		InstrumentId:   req.InstrumentId,
		Direction:      req.Direction,
		Threshold:      req.Threshold,
		Enabled:        true,
		ArmingRevision: 1,
		CreatedAt:      timestamppb.New(fakeTime),
	}
}

// alertField calls one RPC with value in one validated field and valid values in the others
type alertField struct {
	name   string
	method string // the repository method a valid call reaches
	call   func(ctx context.Context, s *AlertServer, value string) error
}

var (
	createAccountField = alertField{"CreateAlert/account_id", "Create", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.CreateAlert(ctx, createRequest(func(r *pb.CreateAlertRequest) { r.AccountId = v }))
		return err
	}}
	createInstrumentField = alertField{"CreateAlert/instrument_id", "Create", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.CreateAlert(ctx, createRequest(func(r *pb.CreateAlertRequest) { r.InstrumentId = v }))
		return err
	}}
	listAccountField = alertField{"ListAlerts/account_id", "List", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.ListAlerts(ctx, &pb.ListAlertsRequest{AccountId: v})
		return err
	}}
	getIDField = alertField{"GetAlert/id", "GetByID", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.GetAlert(ctx, &pb.AlertIdRequest{Id: v})
		return err
	}}
	updateIDField = alertField{"UpdateAlertEnabled/id", "UpdateEnabled", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.UpdateAlertEnabled(ctx, &pb.UpdateAlertEnabledRequest{Id: v, Enabled: wrapperspb.Bool(true)})
		return err
	}}
	deleteIDField = alertField{"DeleteAlert/id", "Delete", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.DeleteAlert(ctx, &pb.AlertIdRequest{Id: v})
		return err
	}}
	triggerIDField = alertField{"TriggerAlert/id", "Trigger", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.TriggerAlert(ctx, &pb.TriggerAlertRequest{Id: v, ArmingRevision: 1, TriggerValue: "1.5"})
		return err
	}}
	acknowledgeIDField = alertField{"AcknowledgeAlert/id", "Acknowledge", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.AcknowledgeAlert(ctx, &pb.AlertIdRequest{Id: v})
		return err
	}}
	createTypeField = alertField{"CreateAlert/type", "Create", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.CreateAlert(ctx, createRequest(func(r *pb.CreateAlertRequest) { r.Type = v }))
		return err
	}}
	createDirectionField = alertField{"CreateAlert/direction", "Create", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.CreateAlert(ctx, createRequest(func(r *pb.CreateAlertRequest) { r.Direction = v }))
		return err
	}}
	createThresholdField = alertField{"CreateAlert/threshold", "Create", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.CreateAlert(ctx, createRequest(func(r *pb.CreateAlertRequest) { r.Threshold = v }))
		return err
	}}
	triggerValueField = alertField{"TriggerAlert/trigger_value", "Trigger", func(ctx context.Context, s *AlertServer, v string) error {
		_, err := s.TriggerAlert(ctx, &pb.TriggerAlertRequest{Id: testAlertID, ArmingRevision: 1, TriggerValue: v})
		return err
	}}

	// CreateAlert validates its UUIDs and passes them on as sent
	createUUIDFields = []alertField{createAccountField, createInstrumentField}
	// The six RPCs that bind a UUID taken from the request in a predicate
	idFields   = []alertField{listAccountField, getIDField, updateIDField, deleteIDField, triggerIDField, acknowledgeIDField}
	uuidFields = slices.Concat(createUUIDFields, idFields)
	// The validated text fields that are not UUIDs
	textFields = []alertField{createTypeField, createDirectionField, createThresholdField, triggerValueField}
	// Every RPC once, each with a valid canonical id
	everyRPC = slices.Concat(createUUIDFields[:1], idFields)
)

// namedValue is one input of a table with the label its subtest carries
type namedValue struct{ name, value string }

var (
	// The spellings of testAlertID other than the canonical one that uuid.Validate admits
	alternateSpellings = []namedValue{
		{"urn", "urn:uuid:" + testAlertID},
		{"upperURN", "URN:UUID:" + strings.ToUpper(testAlertID)},
		{"braces", "{" + testAlertID + "}"},
		{"hexDigits", strings.ReplaceAll(testAlertID, "-", "")},
		{"upperCase", strings.ToUpper(testAlertID)},
	}
	// Values every UUID field rejects
	nonUUIDs = []namedValue{
		{"notUUID", "not-a-uuid"},
		// 38 bytes, which uuid.Parse alone accepts by ignoring the two outer characters
		{"letterWrapped", "x" + testAlertID + "y"},
		{"parenthesised", "(" + testAlertID + ")"},
		{"unbalancedBraces", "{" + testAlertID + ")"},
		{"badURNPrefix", "urn:uuix:" + testAlertID},
	}
)

func TestAlertRPCs_invalidInput_invalidArgument(t *testing.T) {
	type invalidCase struct {
		name string
		call func(ctx context.Context, s *AlertServer) error
	}
	withValue := func(field alertField, label, value string) invalidCase {
		return invalidCase{field.name + "/" + label, func(ctx context.Context, s *AlertServer) error {
			return field.call(ctx, s, value)
		}}
	}
	cases := []invalidCase{
		withValue(createTypeField, "lowerCase", "target_price"),
		withValue(createDirectionField, "unknown", "UP"),
		withValue(createThresholdField, "empty", ""),
		withValue(createThresholdField, "exponent", "1e5"),
		withValue(createThresholdField, "notNormalised", "1.50"),
		withValue(createThresholdField, "nineFractionalDigits", "0."+strings.Repeat("0", 8)+"1"),
		withValue(createThresholdField, "elevenIntegerDigits", "1"+strings.Repeat("0", 10)),
		withValue(createThresholdField, "targetPriceZero", "0"),
		withValue(createThresholdField, "targetPriceNegative", "-1"),
		{"UpdateAlertEnabled/enabled/omitted", func(ctx context.Context, s *AlertServer) error {
			_, err := s.UpdateAlertEnabled(ctx, &pb.UpdateAlertEnabledRequest{Id: testAlertID})
			return err
		}},
		{"TriggerAlert/arming_revision/zero", func(ctx context.Context, s *AlertServer) error {
			_, err := s.TriggerAlert(ctx, &pb.TriggerAlertRequest{Id: testAlertID, ArmingRevision: 0, TriggerValue: "1.5"})
			return err
		}},
		withValue(triggerValueField, "empty", ""),
		withValue(triggerValueField, "twentyOneIntegerDigits", "1"+strings.Repeat("0", 20)),
	}
	for _, id := range nonUUIDs {
		for _, field := range uuidFields {
			cases = append(cases, withValue(field, id.name, id.value))
		}
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeAlertRepository(armedAlert())

			err := tc.call(t.Context(), NewAlertServer(repo))

			if got := repo.recorded(); status.Code(err) != codes.InvalidArgument || len(got) != 0 {
				t.Errorf("%s = %v with repository calls %v, want InvalidArgument and none", tc.name, err, got)
			}
		})
	}
}

func TestAlertRPCs_validInput_delegated(t *testing.T) {
	type delegatedCase struct {
		name     string
		seed     []*pb.AlertMessage
		call     func(ctx context.Context, s *AlertServer) (proto.Message, error)
		wantCall alertCall
		want     proto.Message
	}
	createCase := func(label string, set func(*pb.CreateAlertRequest)) delegatedCase {
		req := createRequest(set)
		return delegatedCase{
			name:     "CreateAlert/" + label,
			call:     func(ctx context.Context, s *AlertServer) (proto.Message, error) { return s.CreateAlert(ctx, req) },
			wantCall: alertCall{"Create", testAccountID},
			want:     createdAlert(req),
		}
	}
	otherAccountAlert := alertWith(func(a *pb.AlertMessage) { a.Id = testOtherAlertID; a.AccountId = testOtherAccountID })
	triggeredOtherAlert := alertWith(func(a *pb.AlertMessage) { a.Id = testOtherAlertID; markTriggered(a) })
	largestTriggerValue := strings.Repeat("9", 20) + ".99999999"
	cases := []delegatedCase{
		createCase("targetPrice", func(*pb.CreateAlertRequest) {}),
		createCase("smallestTargetPrice", func(r *pb.CreateAlertRequest) { r.Threshold = "0.00000001" }),
		createCase("largestThreshold", func(r *pb.CreateAlertRequest) {
			r.Direction = repository.AlertDirectionBelow
			r.Threshold = "9999999999.99999999"
		}),
		createCase("negativeProfitLoss", func(r *pb.CreateAlertRequest) {
			r.Type = repository.AlertTypeProfitLoss
			r.Threshold = "-9999999999.99999999"
		}),
		{
			name: "ListAlerts/account",
			seed: []*pb.AlertMessage{armedAlert(), otherAccountAlert},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.ListAlerts(ctx, &pb.ListAlertsRequest{AccountId: testAccountID})
			},
			wantCall: alertCall{"List", testAccountID},
			want:     &pb.AlertsResponse{Alerts: []*pb.AlertMessage{armedAlert()}},
		},
		{
			// An empty account id lists every account's alerts
			name: "ListAlerts/allAccounts",
			seed: []*pb.AlertMessage{armedAlert(), otherAccountAlert},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.ListAlerts(ctx, &pb.ListAlertsRequest{ArmedOnly: true})
			},
			wantCall: alertCall{"List", ""},
			want:     &pb.AlertsResponse{Alerts: []*pb.AlertMessage{otherAccountAlert, armedAlert()}},
		},
		{
			name: "ListAlerts/unacknowledgedNotifications",
			seed: []*pb.AlertMessage{armedAlert(), triggeredOtherAlert},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.ListAlerts(ctx, &pb.ListAlertsRequest{AccountId: testAccountID, TriggeredOnly: true, UnacknowledgedOnly: true})
			},
			wantCall: alertCall{"List", testAccountID},
			want:     &pb.AlertsResponse{Alerts: []*pb.AlertMessage{triggeredOtherAlert}},
		},
		{
			name: "GetAlert",
			seed: []*pb.AlertMessage{armedAlert()},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.GetAlert(ctx, &pb.AlertIdRequest{Id: testAlertID})
			},
			wantCall: alertCall{"GetByID", testAlertID},
			want:     armedAlert(),
		},
		{
			name: "UpdateAlertEnabled/rearm",
			seed: []*pb.AlertMessage{alertWith(func(a *pb.AlertMessage) { markTriggered(a); a.Acknowledged = true })},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.UpdateAlertEnabled(ctx, &pb.UpdateAlertEnabledRequest{Id: testAlertID, Enabled: wrapperspb.Bool(true)})
			},
			wantCall: alertCall{"UpdateEnabled", testAlertID},
			want:     alertWith(func(a *pb.AlertMessage) { a.ArmingRevision = 2 }),
		},
		{
			name: "UpdateAlertEnabled/disable",
			seed: []*pb.AlertMessage{alertWith(markTriggered)},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.UpdateAlertEnabled(ctx, &pb.UpdateAlertEnabledRequest{Id: testAlertID, Enabled: wrapperspb.Bool(false)})
			},
			wantCall: alertCall{"UpdateEnabled", testAlertID},
			want:     alertWith(func(a *pb.AlertMessage) { markTriggered(a); a.Enabled = false }),
		},
		{
			name: "DeleteAlert",
			seed: []*pb.AlertMessage{armedAlert()},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.DeleteAlert(ctx, &pb.AlertIdRequest{Id: testAlertID})
			},
			wantCall: alertCall{"Delete", testAlertID},
			want:     &pb.BatchResponse{Affected: 1},
		},
		{
			name: "TriggerAlert/largestValue",
			seed: []*pb.AlertMessage{armedAlert()},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.TriggerAlert(ctx, &pb.TriggerAlertRequest{Id: testAlertID, ArmingRevision: 1, TriggerValue: largestTriggerValue})
			},
			wantCall: alertCall{"Trigger", testAlertID},
			want:     &pb.TriggerAlertResponse{Triggered: true},
		},
		{
			name: "TriggerAlert/smallestValue",
			seed: []*pb.AlertMessage{armedAlert()},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.TriggerAlert(ctx, &pb.TriggerAlertRequest{Id: testAlertID, ArmingRevision: 1, TriggerValue: "-" + largestTriggerValue})
			},
			wantCall: alertCall{"Trigger", testAlertID},
			want:     &pb.TriggerAlertResponse{Triggered: true},
		},
		{
			name: "AcknowledgeAlert/triggered",
			seed: []*pb.AlertMessage{alertWith(markTriggered)},
			call: func(ctx context.Context, s *AlertServer) (proto.Message, error) {
				return s.AcknowledgeAlert(ctx, &pb.AlertIdRequest{Id: testAlertID})
			},
			wantCall: alertCall{"Acknowledge", testAlertID},
			want:     &pb.BatchResponse{Affected: 1},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeAlertRepository(tc.seed...)

			got, err := tc.call(t.Context(), NewAlertServer(repo))

			wantCalls := []alertCall{tc.wantCall}
			if calls := repo.recorded(); err != nil || !slices.Equal(calls, wantCalls) || !proto.Equal(got, tc.want) {
				t.Errorf("%s = %v, %v with repository calls %v, want %v, nil with %v", tc.name, got, err, calls, tc.want, wantCalls)
			}
		})
	}
}

func TestAlertRPCs_unknownID_notFound(t *testing.T) {
	for _, field := range []alertField{getIDField, updateIDField, deleteIDField, acknowledgeIDField} {
		t.Run(field.name, func(t *testing.T) {
			repo := newFakeAlertRepository(armedAlert())

			err := field.call(t.Context(), NewAlertServer(repo), testUnknownID)

			want := []alertCall{{field.method, testUnknownID}}
			if got := repo.recorded(); status.Code(err) != codes.NotFound || !slices.Equal(got, want) {
				t.Errorf("%s(unknown id) = %v with repository calls %v, want NotFound with %v", field.name, err, got, want)
			}
		})
	}
}

// Zero matching rows is a lost or stale trigger, reported as triggered = false rather than an error
func TestTriggerAlert_zeroRows_triggeredFalse(t *testing.T) {
	cases := []struct {
		name string
		held *pb.AlertMessage
		id   string
	}{
		{"staleRevision", alertWith(func(a *pb.AlertMessage) { a.ArmingRevision = 2 }), testAlertID},
		{"alreadyTriggered", alertWith(markTriggered), testAlertID},
		{"disabled", alertWith(func(a *pb.AlertMessage) { a.Enabled = false }), testAlertID},
		{"unknownID", armedAlert(), testUnknownID},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeAlertRepository(tc.held)

			resp, err := NewAlertServer(repo).TriggerAlert(t.Context(), &pb.TriggerAlertRequest{Id: tc.id, ArmingRevision: 1, TriggerValue: "2"})

			want := []alertCall{{"Trigger", tc.id}}
			if got := repo.recorded(); err != nil || resp == nil || resp.Triggered || !slices.Equal(got, want) {
				t.Errorf("TriggerAlert(%s) = %v, %v with repository calls %v, want triggered false, nil with %v", tc.name, resp, err, got, want)
			}
		})
	}
}

// An alert whose current arming has not triggered is acknowledged by nothing: affected 0, no error
func TestAcknowledgeAlert_notTriggered_affectedZero(t *testing.T) {
	cases := []struct {
		name string
		held *pb.AlertMessage
	}{
		{"armed", armedAlert()},
		{"disabled", alertWith(func(a *pb.AlertMessage) { a.Enabled = false })},
		{"rearmed", alertWith(func(a *pb.AlertMessage) { a.ArmingRevision = 2 })},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeAlertRepository(tc.held)

			resp, err := NewAlertServer(repo).AcknowledgeAlert(t.Context(), &pb.AlertIdRequest{Id: testAlertID})

			want := []alertCall{{"Acknowledge", testAlertID}}
			if got := repo.recorded(); err != nil || resp == nil || resp.Affected != 0 || !slices.Equal(got, want) {
				t.Errorf("AcknowledgeAlert(%s) = %v, %v with repository calls %v, want affected 0, nil with %v", tc.name, resp, err, got, want)
			}
		})
	}
}

func TestRegister_alertService_registered(t *testing.T) {
	srv := grpc.NewServer()
	t.Cleanup(srv.Stop)

	Register(srv, nilBackend{})

	// Exactly the eight existing services and AlertService, sorted
	want := []string{
		"easytrade.dbadapter.account.AccountService",
		"easytrade.dbadapter.alert.AlertService",
		"easytrade.dbadapter.balance.BalanceService",
		"easytrade.dbadapter.creditcardorder.CreditCardOrderService",
		"easytrade.dbadapter.instrument.InstrumentService",
		"easytrade.dbadapter.packages.PackageService",
		"easytrade.dbadapter.pricing.PricingService",
		"easytrade.dbadapter.product.ProductService",
		"easytrade.dbadapter.trade.TradeService",
	}
	if got := slices.Sorted(maps.Keys(srv.GetServiceInfo())); len(got) != 9 || !slices.Equal(got, want) {
		t.Errorf("Register registered %d services %v, want the 9 services %v", len(got), got, want)
	}
}

func TestAlertRPCs_alternateUUIDSpelling_canonicalDelegated(t *testing.T) {
	for _, spelling := range alternateSpellings {
		for _, field := range idFields {
			t.Run(spelling.name+"/"+field.name, func(t *testing.T) {
				repo := newFakeAlertRepository(armedAlert())

				err := field.call(t.Context(), NewAlertServer(repo), spelling.value)

				want := []alertCall{{field.method, testAlertID}}
				if got := repo.recorded(); err != nil || !slices.Equal(got, want) {
					t.Errorf("%s(%q) = %v with repository calls %v, want nil with %v", field.name, spelling.value, err, got, want)
				}
			})
		}
	}
}

// CreateAlert passes its request on as sent: the repository binds the parsed UUIDs
func TestCreateAlert_alternateUUIDSpelling_accepted(t *testing.T) {
	for _, spelling := range alternateSpellings {
		for _, field := range createUUIDFields {
			t.Run(spelling.name+"/"+field.name, func(t *testing.T) {
				repo := newFakeAlertRepository()

				err := field.call(t.Context(), NewAlertServer(repo), spelling.value)

				if got := repo.recorded(); err != nil || len(got) != 1 || got[0].method != "Create" {
					t.Errorf("%s(%q) = %v with repository calls %v, want one Create", field.name, spelling.value, err, got)
				}
			})
		}
	}
}

func TestListAlerts_alternateAccountSpelling_requestUnchanged(t *testing.T) {
	sent := "urn:uuid:" + strings.ToUpper(testAccountID)
	req := &pb.ListAlertsRequest{AccountId: sent, ArmedOnly: true}
	before := proto.Clone(req)

	_, err := NewAlertServer(newFakeAlertRepository()).ListAlerts(t.Context(), req)

	if err != nil || !proto.Equal(req, before) {
		t.Errorf("ListAlerts(%v) = %v and left the request as %v, want nil and %v", before, err, req, before)
	}
}

func TestAlertRPCs_oversizedValue_shortInvalidArgument(t *testing.T) {
	oversized := strings.Repeat("7", 1<<20)
	for _, field := range slices.Concat(uuidFields, textFields) {
		t.Run(field.name, func(t *testing.T) {
			err := field.call(t.Context(), NewAlertServer(newFakeAlertRepository(armedAlert())), oversized)

			msg := status.Convert(err).Message()
			if status.Code(err) != codes.InvalidArgument || len(msg) > 128 || strings.Contains(msg, oversized[:32]) {
				t.Errorf("%s(1 MiB) = %v (%d-byte message), want InvalidArgument with a short message that omits the value", field.name, status.Code(err), len(msg))
			}
		})
	}
}

// Over a real HTTP/2 connection, a client that advertises the 64 KiB header list limit of the broker's
// .NET client must still receive InvalidArgument for a request that echoed would exceed it
func TestCreateAlert_oversizedThresholdOverWire_invalidArgument(t *testing.T) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	srv := grpc.NewServer()
	pb.RegisterAlertServiceServer(srv, NewAlertServer(newFakeAlertRepository()))
	served := make(chan error, 1)
	go func() { served <- srv.Serve(lis) }()
	t.Cleanup(func() {
		srv.Stop()
		if err := <-served; err != nil {
			t.Errorf("Serve: %v", err)
		}
	})
	conn, err := grpc.NewClient(lis.Addr().String(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithMaxHeaderListSize(64<<10))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	t.Cleanup(func() {
		if err := conn.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	req := createRequest(func(r *pb.CreateAlertRequest) { r.Threshold = strings.Repeat("7", 1<<20) })

	_, err = pb.NewAlertServiceClient(conn).CreateAlert(t.Context(), req)

	if status.Code(err) != codes.InvalidArgument {
		t.Errorf("CreateAlert(1 MiB threshold) over the wire = %v, want InvalidArgument", status.Code(err))
	}
}

func TestAlertRPCs_storageFailure_internalWithoutDetails(t *testing.T) {
	storageErr := fmt.Errorf("failed to connect to `%s`: dial tcp 10.0.0.5:5432: connection refused", testSecret)
	for _, rpc := range everyRPC {
		t.Run(rpc.name, func(t *testing.T) {
			err := rpc.call(t.Context(), NewAlertServer(&fakeAlertRepository{err: storageErr}), testAlertID)

			if st := status.Convert(err); st.Code() != codes.Internal || st.Message() != "alert storage failure" {
				t.Errorf("%s with a storage failure = %v %q, want Internal %q", rpc.name, st.Code(), st.Message(), "alert storage failure")
			}
		})
	}
}

func TestAlertRPCs_contextError_matchingCode(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want codes.Code
	}{
		{"canceled", fmt.Errorf("query: %w", context.Canceled), codes.Canceled},
		{"deadlineExceeded", fmt.Errorf("query: %w", context.DeadlineExceeded), codes.DeadlineExceeded},
	}
	for _, tc := range cases {
		for _, rpc := range everyRPC {
			t.Run(tc.name+"/"+rpc.name, func(t *testing.T) {
				err := rpc.call(t.Context(), NewAlertServer(&fakeAlertRepository{err: tc.err}), testAlertID)

				if got := status.Code(err); got != tc.want {
					t.Errorf("%s with %v = %v, want %v", rpc.name, tc.err, got, tc.want)
				}
			})
		}
	}
}

func TestAlertStatus_repositoryError_mappedStatus(t *testing.T) {
	invalid := status.Error(codes.InvalidArgument, "id is not a valid UUID")
	cases := []struct {
		name     string
		err      error
		wantCode codes.Code
		wantMsg  string
	}{
		{"nil", nil, codes.OK, ""},
		{"statusKept", invalid, codes.InvalidArgument, "id is not a valid UUID"},
		{"notFound", fmt.Errorf("trigger: %w", repository.ErrNotFound), codes.NotFound, "not found"},
		{"referenceNotFound", fmt.Errorf("%w: %s", repository.ErrAlertReferenceNotFound, testSecret), codes.NotFound, "account or instrument not found"},
		{"canceled", fmt.Errorf("query: %w", context.Canceled), codes.Canceled, context.Canceled.Error()},
		{"deadlineExceeded", fmt.Errorf("query: %w", context.DeadlineExceeded), codes.DeadlineExceeded, context.DeadlineExceeded.Error()},
		{"storageFailure", errors.New("alert storage failure: SQLSTATE 08006"), codes.Internal, "alert storage failure"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := status.Convert(alertStatus(tc.err))

			if got.Code() != tc.wantCode || got.Message() != tc.wantMsg {
				t.Errorf("alertStatus(%v) = %v %q, want %v %q", tc.err, got.Code(), got.Message(), tc.wantCode, tc.wantMsg)
			}
		})
	}
}

// A storage failure is logged once as an error and an unknown account or instrument once as a
// warning, each with the error the repository returned; no other outcome is logged
func TestAlertStatus_repositoryError_loggedOnceAtLevel(t *testing.T) {
	type logEntry struct {
		level log.Level
		msg   string
		err   any
	}
	storageErr := errors.New("alert storage failure: connection failure")
	referenceErr := fmt.Errorf("%w: SQLSTATE 23503", repository.ErrAlertReferenceNotFound)
	cases := []struct {
		name string
		err  error
		want []logEntry
	}{
		{"storageFailure", storageErr, []logEntry{{log.ErrorLevel, "Alert storage call failed", storageErr}}},
		{"referenceNotFound", referenceErr, []logEntry{{log.WarnLevel, "Alert references an unknown account or instrument", referenceErr}}},
		{"notFound", repository.ErrNotFound, nil},
		{"canceled", context.Canceled, nil},
		{"statusKept", status.Error(codes.NotFound, "not found"), nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			std := log.StandardLogger()
			hook := new(logtest.Hook)
			previous := std.ReplaceHooks(log.LevelHooks{})
			std.AddHook(hook)
			t.Cleanup(func() { std.ReplaceHooks(previous) })

			_ = alertStatus(tc.err)

			var got []logEntry
			for _, entry := range hook.AllEntries() {
				got = append(got, logEntry{entry.Level, entry.Message, entry.Data[log.ErrorKey]})
			}
			if !slices.Equal(got, tc.want) {
				t.Errorf("alertStatus(%v) logged %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

// An account or instrument id that names no row reaches the caller as NotFound with a fixed message
func TestCreateAlert_unknownReference_notFoundWithoutDetails(t *testing.T) {
	referenceErr := fmt.Errorf("%w: %s", repository.ErrAlertReferenceNotFound, testSecret)
	srv := NewAlertServer(&fakeAlertRepository{err: referenceErr})

	_, err := srv.CreateAlert(t.Context(), createRequest(func(*pb.CreateAlertRequest) {}))

	if st := status.Convert(err); st.Code() != codes.NotFound || st.Message() != "account or instrument not found" {
		t.Errorf("CreateAlert with an unknown reference = %v %q, want NotFound %q", st.Code(), st.Message(), "account or instrument not found")
	}
}
