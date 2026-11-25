package server

import (
	"context"
	"regexp"
	"strings"

	pb "github.com/dynatrace/easytrade/dbadapter/proto"
	"github.com/dynatrace/easytrade/dbadapter/repository"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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

func (s *AlertServer) CreateAlert(ctx context.Context, req *pb.CreateAlertRequest) (*pb.AlertMessage, error) {
	if err := validateUUID(req.AccountId); err != nil {
		return nil, err
	}
	if err := validateUUID(req.InstrumentId); err != nil {
		return nil, err
	}
	if req.Type != repository.AlertTypeTargetPrice && req.Type != repository.AlertTypeProfitLoss {
		return nil, status.Errorf(codes.InvalidArgument, "%q is not a valid alert type", req.Type)
	}
	if req.Direction != repository.AlertDirectionAbove && req.Direction != repository.AlertDirectionBelow {
		return nil, status.Errorf(codes.InvalidArgument, "%q is not a valid alert direction", req.Direction)
	}
	if !thresholdPattern.MatchString(req.Threshold) {
		return nil, status.Errorf(codes.InvalidArgument, "%q is not a valid threshold", req.Threshold)
	}
	// In normalised form the only non-positive values are a leading "-" and "0"
	if req.Type == repository.AlertTypeTargetPrice && (strings.HasPrefix(req.Threshold, "-") || req.Threshold == "0") {
		return nil, status.Errorf(codes.InvalidArgument, "%q is not a positive target price threshold", req.Threshold)
	}
	return s.repo.Create(ctx, req)
}

// An empty account id lists every account's alerts, as the broker evaluator does with ArmedOnly
func (s *AlertServer) ListAlerts(ctx context.Context, req *pb.ListAlertsRequest) (*pb.AlertsResponse, error) {
	if req.AccountId != "" {
		if err := validateUUID(req.AccountId); err != nil {
			return nil, err
		}
	}
	return s.alertsResponse(s.repo.List(ctx, req))
}

func (s *AlertServer) GetAlert(ctx context.Context, req *pb.AlertIdRequest) (*pb.AlertMessage, error) {
	if err := validateUUID(req.Id); err != nil {
		return nil, err
	}
	return fetchOrNotFound(s.repo.GetByID(ctx, req.Id))
}

// The repository returns the snapshot it read inside the update's transaction; reading the row again
// here could show another update's revision or a later trigger
func (s *AlertServer) UpdateAlertEnabled(ctx context.Context, req *pb.UpdateAlertEnabledRequest) (*pb.AlertMessage, error) {
	if err := validateUUID(req.Id); err != nil {
		return nil, err
	}
	if req.Enabled == nil {
		return nil, status.Error(codes.InvalidArgument, "enabled is required")
	}
	return fetchOrNotFound(s.repo.UpdateEnabled(ctx, req.Id, req.Enabled.GetValue()))
}

func (s *AlertServer) DeleteAlert(ctx context.Context, req *pb.AlertIdRequest) (*pb.BatchResponse, error) {
	if err := validateUUID(req.Id); err != nil {
		return nil, err
	}
	return batchResponse(fetchOrNotFound(s.repo.Delete(ctx, req.Id)))
}

// Zero matching rows is triggered = false, not NotFound: another evaluator won, or the alert was
// disabled, deleted or re-armed since it was listed
func (s *AlertServer) TriggerAlert(ctx context.Context, req *pb.TriggerAlertRequest) (*pb.TriggerAlertResponse, error) {
	if err := validateUUID(req.Id); err != nil {
		return nil, err
	}
	if req.ArmingRevision < 1 {
		return nil, status.Errorf(codes.InvalidArgument, "%d is not a valid arming revision", req.ArmingRevision)
	}
	if !triggerValuePattern.MatchString(req.TriggerValue) {
		return nil, status.Errorf(codes.InvalidArgument, "%q is not a valid trigger value", req.TriggerValue)
	}
	triggered, err := s.repo.Trigger(ctx, req.Id, req.ArmingRevision, req.TriggerValue)
	if err != nil {
		return nil, err
	}
	return &pb.TriggerAlertResponse{Triggered: triggered}, nil
}

// An alert whose current arming has not triggered reports Affected: 0, so a later trigger is never
// acknowledged in advance
func (s *AlertServer) AcknowledgeAlert(ctx context.Context, req *pb.AlertIdRequest) (*pb.BatchResponse, error) {
	if err := validateUUID(req.Id); err != nil {
		return nil, err
	}
	return batchResponse(fetchOrNotFound(s.repo.Acknowledge(ctx, req.Id)))
}

func (s *AlertServer) alertsResponse(alerts []*pb.AlertMessage, err error) (*pb.AlertsResponse, error) {
	if err != nil {
		return nil, err
	}
	return &pb.AlertsResponse{Alerts: alerts}, nil
}
