package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/henrygd/beszel/agent/utils"
	"github.com/henrygd/beszel/internal/entities/system"
)

// VectorManager polls a local Vector aggregator's GraphQL API and exposes
// per-component throughput, byte, and error counters. Activation is opt-in
// via the VECTOR_API_URL env var — when unset, NewVectorManager returns
// (nil, error) and the agent skips Vector collection.
//
// Unlike IPVS (kernel estimator) Vector exposes only cumulative counters; the
// UI derives rates client-side from the polling interval, same as HAProxy.
type VectorManager struct {
	sync.Mutex
	endpoint     string
	httpClient   *http.Client
	stats        *system.VectorStats
	lastUpdate   time.Time
	updatePeriod time.Duration

	consecutiveFailures int
	lastError           error
}

const (
	vectorDefaultUpdateInterval = 5 * time.Second
	vectorRequestTimeout        = 4 * time.Second
)

var errVectorDisabled = errors.New("VECTOR_API_URL not set")

// NewVectorManager returns a manager only when VECTOR_API_URL is set AND the
// endpoint answers the `health` query. Probe failures bubble up so the agent
// logs the reason at DEBUG and continues without Vector collection.
func NewVectorManager() (*VectorManager, error) {
	raw, ok := utils.GetEnv("VECTOR_API_URL")
	if !ok || strings.TrimSpace(raw) == "" {
		return nil, errVectorDisabled
	}
	endpoint, err := normalizeVectorEndpoint(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid VECTOR_API_URL: %w", err)
	}

	updatePeriod := vectorDefaultUpdateInterval
	if intervalStr, exists := utils.GetEnv("VECTOR_UPDATE_INTERVAL"); exists {
		if d, perr := time.ParseDuration(intervalStr); perr == nil && d > 0 {
			updatePeriod = d
			slog.Info("Vector update interval configured", "duration", d)
		}
	}

	vm := &VectorManager{
		endpoint:     endpoint,
		updatePeriod: updatePeriod,
		httpClient:   &http.Client{Timeout: vectorRequestTimeout},
	}

	if _, err := vm.fetch(); err != nil {
		return nil, err
	}
	slog.Info("Vector monitoring enabled", "endpoint", endpoint)
	return vm, nil
}

// normalizeVectorEndpoint accepts forms users typically set:
//   - http://host:8686                  → http://host:8686/graphql
//   - http://host:8686/                 → http://host:8686/graphql
//   - http://host:8686/graphql          → unchanged
//   - host:8686                         → http://host:8686/graphql
func normalizeVectorEndpoint(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if u.Host == "" {
		return "", fmt.Errorf("missing host")
	}
	if u.Path == "" || u.Path == "/" {
		u.Path = "/graphql"
	}
	return u.String(), nil
}

// GetStats returns a copy of the most recent Vector snapshot, refreshing if stale.
func (vm *VectorManager) GetStats() *system.VectorStats {
	vm.Lock()
	defer vm.Unlock()

	if time.Since(vm.lastUpdate) > vm.updatePeriod {
		if stats, err := vm.fetch(); err == nil {
			vm.stats = stats
			vm.lastUpdate = time.Now()
			vm.consecutiveFailures = 0
			vm.lastError = nil
		} else {
			vm.consecutiveFailures++
			vm.lastError = err
			if vm.consecutiveFailures > 5 {
				slog.Warn("Vector collection persistently failing",
					"consecutiveFailures", vm.consecutiveFailures, "err", err)
			} else {
				slog.Debug("Vector fetch failed", "err", err)
			}
		}
	}

	if vm.stats == nil {
		return nil
	}
	c := *vm.stats
	return &c
}

// GetConnectionHealth exposes the consecutive failure count for diagnostics.
func (vm *VectorManager) GetConnectionHealth() (failures int, lastErr error) {
	vm.Lock()
	defer vm.Unlock()
	return vm.consecutiveFailures, vm.lastError
}

// vectorQuery bundles everything we need in one round trip:
//   - health flag
//   - meta (version + hostname)
//   - all components with their cumulative metric counters
//
// We request `first: 10000` to skip cursor pagination — even large Vector
// pipelines stay well under that.
const vectorQuery = `query BeszelVectorSnapshot {
  health
  meta { versionString hostname }
  components(first: 10000) {
    edges {
      node {
        componentId
        componentType
        componentKind
        metrics {
          receivedEventsTotal { receivedEventsTotal }
          sentEventsTotal { sentEventsTotal }
          receivedBytesTotal { receivedBytesTotal }
          sentBytesTotal { sentBytesTotal }
          errorsTotal { errorsTotal }
          discardedEventsTotal { discardedEventsTotal }
        }
      }
    }
  }
}`

type vectorGQLResponse struct {
	Data struct {
		Health bool `json:"health"`
		Meta   struct {
			VersionString string `json:"versionString"`
			Hostname      string `json:"hostname"`
		} `json:"meta"`
		Components struct {
			Edges []struct {
				Node struct {
					ComponentID   string `json:"componentId"`
					ComponentType string `json:"componentType"`
					ComponentKind string `json:"componentKind"`
					Metrics       struct {
						ReceivedEventsTotal   *struct{ ReceivedEventsTotal float64 `json:"receivedEventsTotal"` }   `json:"receivedEventsTotal"`
						SentEventsTotal       *struct{ SentEventsTotal float64 `json:"sentEventsTotal"` }           `json:"sentEventsTotal"`
						ReceivedBytesTotal    *struct{ ReceivedBytesTotal float64 `json:"receivedBytesTotal"` }     `json:"receivedBytesTotal"`
						SentBytesTotal        *struct{ SentBytesTotal float64 `json:"sentBytesTotal"` }             `json:"sentBytesTotal"`
						ErrorsTotal           *struct{ ErrorsTotal float64 `json:"errorsTotal"` }                   `json:"errorsTotal"`
						DiscardedEventsTotal  *struct{ DiscardedEventsTotal float64 `json:"discardedEventsTotal"` } `json:"discardedEventsTotal"`
					} `json:"metrics"`
				} `json:"node"`
			} `json:"edges"`
		} `json:"components"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

func (vm *VectorManager) fetch() (*system.VectorStats, error) {
	body, _ := json.Marshal(map[string]any{"query": vectorQuery})

	ctx, cancel := context.WithTimeout(context.Background(), vectorRequestTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, vm.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("vector request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := vm.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("vector http: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("vector status %d: %s", resp.StatusCode, string(respBody))
	}

	var out vectorGQLResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("vector decode: %w", err)
	}
	if len(out.Errors) > 0 {
		return nil, fmt.Errorf("vector graphql: %s", out.Errors[0].Message)
	}

	stats := &system.VectorStats{
		Version:  out.Data.Meta.VersionString,
		Hostname: out.Data.Meta.Hostname,
		Healthy:  out.Data.Health,
	}

	for _, edge := range out.Data.Components.Edges {
		n := edge.Node
		comp := system.VectorComponent{
			ID:   n.ComponentID,
			Type: n.ComponentType,
			Kind: strings.ToLower(n.ComponentKind),
		}
		if m := n.Metrics.ReceivedEventsTotal; m != nil {
			comp.ReceivedEvents = uint64(m.ReceivedEventsTotal)
		}
		if m := n.Metrics.SentEventsTotal; m != nil {
			comp.SentEvents = uint64(m.SentEventsTotal)
		}
		if m := n.Metrics.ReceivedBytesTotal; m != nil {
			comp.ReceivedBytes = uint64(m.ReceivedBytesTotal)
		}
		if m := n.Metrics.SentBytesTotal; m != nil {
			comp.SentBytes = uint64(m.SentBytesTotal)
		}
		if m := n.Metrics.ErrorsTotal; m != nil {
			comp.Errors = uint64(m.ErrorsTotal)
		}
		if m := n.Metrics.DiscardedEventsTotal; m != nil {
			comp.Discarded = uint64(m.DiscardedEventsTotal)
		}

		stats.Components = append(stats.Components, comp)
		stats.ComponentCount++
		switch comp.Kind {
		case "source":
			stats.SourceCount++
			stats.ReceivedEvents += comp.ReceivedEvents
			stats.ReceivedBytes += comp.ReceivedBytes
		case "transform":
			stats.TransformCount++
		case "sink":
			stats.SinkCount++
			stats.SentEvents += comp.SentEvents
			stats.SentBytes += comp.SentBytes
		}
		stats.ErrorsTotal += comp.Errors
		stats.DiscardedTotal += comp.Discarded
	}

	return stats, nil
}
