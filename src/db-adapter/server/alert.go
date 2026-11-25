package server

import (
	"context"
	"errors"
	"regexp"
	"strings"

	pb "github.com/dynatrace/easytrade/dbadapter/proto"
	"github.com/dynatrace/easytrade/dbadapter/repository"
	"github.com/google/uuid"
	log "github.com/sirupsen/logrus"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// Only the normalised decimal form is admitted: no exponent, no leading "+" or integer zeros and no
// trailing fractional zeros. An empty string fails both, so an omitted proto3 scalar never reads as 0
var (
	// At most 10 integer and 8 fractional digits, the DECIMAL(18, 8) Threshold column
	thresholdPattern = regexp.MustCompile(`^-?(0|[1-9][0-9]{0,9})(\.[0-9]{0,7}[1-9])?$`)
	// At most 20 integer and 8 fractional digits, the DECIMAL(28, 8) TriggerValue column
	triggerValuePattern = regexp.MustCompile(`^-?(0|[1-9][0-9]{0,19})(\.[0-9]{0,7}[1-9])?$`)
)

var _ pb.AlertServiceServer = (*AlertServer)(nil)

type AlertServer struct {
	pb.UnimplementedAlertServiceServer
	repo repository.AlertRepository
}

func NewAlertServer(repo repository.AlertRepository) *AlertServer {
	return &AlertServer{repo: repo}
}

// The repository binds the parsed account and instrument ids, so the request passes on as sent
func (s *AlertServer) CreateAlert(ctx context.Context, req *pb.CreateAlertRequest) (*pb.AlertMessage, error) {
	if _, err := alertUUID("account_id", req.AccountId); err != nil {
		return nil, err
	}
	if _, err := alertUUID("instrument_id", req.InstrumentId); err != nil {
		return nil, err
	}
	// No message echoes the input: a rejected value can be larger than the caller's metadata limit,
	// and a grpc-message over it resets the stream instead of delivering InvalidArgument
	if req.Type != repository.AlertTypeTargetPrice && req.Type != repository.AlertTypeProfitLoss {
		return nil, status.Error(codes.InvalidArgument, "type must be TARGET_PRICE or PROFIT_LOSS")
	}
	if req.Direction != repository.AlertDirectionAbove && req.Direction != repository.AlertDirectionBelow {
		return nil, status.Error(codes.InvalidArgument, "direction must be ABOVE or BELOW")
	}
	if !thresholdPattern.MatchString(req.Threshold) {
		return nil, status.Error(codes.InvalidArgument, "threshold is not a normalised decimal of at most 10 integer and 8 fractional digits")
	}
	// In normalised form the only non-positive values are a leading "-" and "0"
	if req.Type == repository.AlertTypeTargetPrice && (strings.HasPrefix(req.Threshold, "-") || req.Threshold == "0") {
		return nil, status.Error(codes.InvalidArgument, "threshold must be positive for a TARGET_PRICE alert")
	}
	return alertReply(s.repo.Create(ctx, req))
}

// An empty account id lists every account's alerts, as the broker evaluator does with ArmedOnly
func (s *AlertServer) ListAlerts(ctx context.Context, req *pb.ListAlertsRequest) (*pb.AlertsResponse, error) {
	if req.AccountId != "" {
		accountID, err := alertUUID("account_id", req.AccountId)
		if err != nil {
			return nil, err
		}
		// The repository gets a copy carrying the canonical id; the caller's request stays as sent
		req = proto.Clone(req).(*pb.ListAlertsRequest)
		req.AccountId = accountID
	}
	return s.alertsResponse(s.repo.List(ctx, req))
}

func (s *AlertServer) GetAlert(ctx context.Context, req *pb.AlertIdRequest) (*pb.AlertMessage, error) {
	id, err := alertUUID("id", req.Id)
	if err != nil {
		return nil, err
	}
	return alertReply(fetchOrNotFound(s.repo.GetByID(ctx, id)))
}

// The repository returns the snapshot it read inside the update's transaction; reading the row again
// here could show another update's revision or a later trigger
func (s *AlertServer) UpdateAlertEnabled(ctx context.Context, req *pb.UpdateAlertEnabledRequest) (*pb.AlertMessage, error) {
	id, err := alertUUID("id", req.Id)
	if err != nil {
		return nil, err
	}
	if req.Enabled == nil {
		return nil, status.Error(codes.InvalidArgument, "enabled is required")
	}
	return alertReply(fetchOrNotFound(s.repo.UpdateEnabled(ctx, id, req.Enabled.GetValue())))
}

func (s *AlertServer) DeleteAlert(ctx context.Context, req *pb.AlertIdRequest) (*pb.BatchResponse, error) {
	id, err := alertUUID("id", req.Id)
	if err != nil {
		return nil, err
	}
	return alertReply(batchResponse(fetchOrNotFound(s.repo.Delete(ctx, id))))
}

// Zero matching rows is triggered = false, not NotFound: another evaluator won, or the alert was
// disabled, deleted or re-armed since it was listed
func (s *AlertServer) TriggerAlert(ctx context.Context, req *pb.TriggerAlertRequest) (*pb.TriggerAlertResponse, error) {
	id, err := alertUUID("id", req.Id)
	if err != nil {
		return nil, err
	}
	if req.ArmingRevision < 1 {
		return nil, status.Error(codes.InvalidArgument, "arming_revision must be at least 1")
	}
	if !triggerValuePattern.MatchString(req.TriggerValue) {
		return nil, status.Error(codes.InvalidArgument, "trigger_value is not a normalised decimal of at most 20 integer and 8 fractional digits")
	}
	triggered, err := s.repo.Trigger(ctx, id, req.ArmingRevision, req.TriggerValue)
	if err != nil {
		return nil, alertStatus(err)
	}
	return &pb.TriggerAlertResponse{Triggered: triggered}, nil
}

// An alert whose current arming has not triggered reports Affected: 0, so a later trigger is never
// acknowledged in advance
func (s *AlertServer) AcknowledgeAlert(ctx context.Context, req *pb.AlertIdRequest) (*pb.BatchResponse, error) {
	id, err := alertUUID("id", req.Id)
	if err != nil {
		return nil, err
	}
	return alertReply(batchResponse(fetchOrNotFound(s.repo.Acknowledge(ctx, id))))
}

func (s *AlertServer) alertsResponse(alerts []*pb.AlertMessage, err error) (*pb.AlertsResponse, error) {
	if err != nil {
		return nil, alertStatus(err)
	}
	return &pb.AlertsResponse{Alerts: alerts}, nil
}

// alertUUID accepts the spellings uuid.Validate admits (hyphenated in either case, urn:uuid:, 32 hex
// digits, braces) and returns the canonical form the UUID columns bind. The shared validateUUID
// ignores the outer two characters of 38-byte input and echoes the input; the existing services keep it
func alertUUID(field, value string) (string, error) {
	id, err := uuid.Parse(value)
	if err != nil || uuid.Validate(value) != nil {
		return "", status.Errorf(codes.InvalidArgument, "%s is not a valid UUID", field)
	}
	return id.String(), nil
}

func alertReply[M any](msg M, err error) (M, error) {
	if err != nil {
		var zero M
		return zero, alertStatus(err)
	}
	return msg, nil
}

// alertStatus keeps a status already chosen (fetchOrNotFound's NotFound) and maps the repository's
// errors to codes with fixed messages, so no storage detail reaches the caller. The repository has
// already reduced a storage failure to its safe classification, which is logged here once. An
// unknown account or instrument is the caller's mistake and is logged once as a warning
func alertStatus(err error) error {
	if err == nil {
		return nil
	}
	if _, ok := status.FromError(err); ok {
		return err
	}
	switch {
	case errors.Is(err, repository.ErrNotFound):
		return errNotFound()
	case errors.Is(err, repository.ErrAlertReferenceNotFound):
		log.WithError(err).Warn("Alert references an unknown account or instrument")
		return status.Error(codes.NotFound, "account or instrument not found")
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, context.Canceled.Error())
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, context.DeadlineExceeded.Error())
	default:
		log.WithError(err).Error("Alert storage call failed")
		return status.Error(codes.Internal, "alert storage failure")
	}
}
