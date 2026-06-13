//go:build !linux

package agent

import (
	"errors"

	"github.com/henrygd/beszel/internal/entities/system"
)

var errConntrackUnavailable = errors.New("conntrack monitoring is Linux-only")

func conntrackAvailable() bool { return false }

func (cm *ConntrackManager) fetch() (*system.ConntrackStats, error) {
	return nil, errConntrackUnavailable
}
