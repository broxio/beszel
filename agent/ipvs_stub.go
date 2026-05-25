//go:build !linux

package agent

import (
	"errors"

	"github.com/henrygd/beszel/internal/entities/system"
)

var errIPVSUnavailable = errors.New("IPVS monitoring is Linux-only")

func ipvsAvailable() bool { return false }

func (im *IPVSManager) fetch() (*system.IPVSStats, error) {
	return nil, errIPVSUnavailable
}
