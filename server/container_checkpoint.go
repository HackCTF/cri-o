package server

import (
	"fmt"
	"time"

	metadata "github.com/checkpoint-restore/checkpointctl/lib"
	"github.com/cri-o/cri-o/internal/lib"
	"github.com/cri-o/cri-o/internal/log"
	"golang.org/x/net/context"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	types "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// CheckpointContainer checkpoints a container
func (s *Server) CheckpointContainer(ctx context.Context, req *types.CheckpointContainerRequest) (*types.CheckpointContainerResponse, error) {
	if !s.config.RuntimeConfig.CheckpointRestore() {
		return nil, fmt.Errorf("checkpoint/restore support not available")
	}

	_, err := s.GetContainerFromShortID(ctx, req.ContainerId)
	if err != nil {
		return nil, status.Errorf(codes.NotFound, "could not find container %q: %v", req.ContainerId, err)
	}

	// If req.Timeout > 0, apply it as a context deadline.
	// This overrides the gRPC client's default deadline (which may be too short
	// for large CRIU dumps) with the user-specified timeout.
	if req.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(req.Timeout)*time.Second)
		defer cancel()
	}

	log.Infof(ctx, "Checkpointing container: %s", req.ContainerId)
	config := &metadata.ContainerConfig{
		ID: req.ContainerId,
	}
	opts := &lib.ContainerCheckpointOptions{
		TargetFile: req.Location,
		// For the forensic container checkpointing use case we
		// keep the container running after checkpointing it.
		KeepRunning: true,
		Timeout:     req.Timeout,
	}

	_, err = s.ContainerServer.ContainerCheckpoint(ctx, config, opts)
	if err != nil {
		return nil, err
	}

	log.Infof(ctx, "Checkpointed container: %s", req.ContainerId)

	return &types.CheckpointContainerResponse{}, nil
}
