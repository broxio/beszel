# Project Notes

## HAProxy Monitoring

### Architecture Decisions

#### Traffic Calculation (Frontend Only)
**Problem:** When aggregating traffic across HAProxy instances, counting both FRONTEND and BACKEND stats results in double-counting. This is because:
- Frontend In → Backend Out (same traffic)
- Backend In → Frontend Out (same traffic)

**Solution:** Only count FRONTEND stats for traffic metrics:
- `bytesIn`, `bytesOut`, `bytesInRate`, `bytesOutRate`
- `requestRate`, `totalRequests`
- HTTP responses (`resp1xx` - `resp5xx`)
- Sessions (`currentSessions`, `totalSessions`)

BACKEND stats are only used for:
- `activeServers`, `backupServers`
- `backendCount`

This aligns with network monitoring tools like Cacti that measure actual client-facing traffic.

#### Zone/Pre-Group Classification
HAProxy systems are classified into zones based on hostname patterns:
- `ha-pre-*` → **PRE** (Pre-production)
- `ha-uat-*` → **UAT** (User Acceptance Testing)
- `ha-lan*` → **LAN** (Internal/Local)
- `ha-*` (others) → **WAN** (External/Internet-facing)

#### Traffic Sparklines
- Client-side accumulation of polling data (no extra backend calls)
- 30 data points at 10-second intervals = 5-minute rolling window
- History stored in ref to avoid unnecessary re-renders
- Combined sparklines for filtered/selected groups in Summary and Traffic Overview cards

#### Connection Retry Logic (Agent)
HAProxy socket connections use exponential backoff for resilience:
- **Max retries:** 3 attempts per operation
- **Initial backoff:** 100ms
- **Backoff multiplier:** 2.0x (100ms → 200ms → 400ms)
- **Max backoff cap:** 2 seconds
- **Health tracking:** Consecutive failures tracked, warning logged after 5+ failures

Key functions in `agent/haproxy.go`:
- `dialSocketWithRetry()` - Socket connection with exponential backoff
- `executeSocketCommand()` - Unified helper for all socket commands
- `GetConnectionHealth()` - Exposes failure count for monitoring

All fetch operations use retry logic: `fetchInfo`, `fetchStats`, `fetchPools`, `fetchActivity`, `fetchServersState`

### File Structure
- `internal/site/src/components/routes/haproxy-aggregate.tsx` - Main aggregate page
- `internal/site/src/lib/haproxy-aggregate.ts` - Calculation utilities and types
- `agent/haproxy.go` - HAProxy agent with stats collection and retry logic

### Data Flow
1. Page polls `system_stats` collection every 10 seconds
2. Filters systems matching `ha-*` pattern
3. Groups systems by pattern (e.g., `ha-web-1`, `ha-web-2` → `ha-web`)
4. Calculates aggregates per group (FRONTEND stats only for traffic)
5. Accumulates traffic history for sparklines
6. Displays combined data based on zone/group selection
