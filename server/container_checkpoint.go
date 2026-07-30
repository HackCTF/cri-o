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

const defaultCheckpointTimeout = 180

// CheckpointContainer checkpoints a container
func (s *Server) CheckpointContainer(ctx context.Context, req *types.CheckpointContainerRequest) (*types.CheckpointContainerResponse, error) {
	if !s.config.RuntimeConfig.CheckpointRestore() {
		return nil, fmt.Errorf("checkpoint/restore support not available")
	}

	_, err := s.GetContainerFromShortID(ctx, req.ContainerId)
	if err != nil {
		return nil, status.Errorf(codes.NotFound, "could not find container %q: %v", req.ContainerId, err)
	}

	// Apply timeout from request, or use default if not set.
	// This ensures the gRPC handler has a bounded deadline even when the client
	// doesn't specify one (e.g. crictl checkpoint without --timeout).
	checkpointTimeout := req.Timeout
	if checkpointTimeout == 0 {
		checkpointTimeout = defaultCheckpointTimeout
	}
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(ctx, time.Duration(checkpointTimeout)*time.Second)
	defer cancel()

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
