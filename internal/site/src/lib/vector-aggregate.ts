import type { SystemRecord, SystemStats, VectorComponent, VectorStats } from "@/types"

/**
 * Visibility rule for Vector hosts: any system whose latest stats include a
 * `vec` field is considered a Vector host. Unlike HAProxy/LVS (which filter by
 * hostname pattern) Vector is opt-in via the VECTOR_API_URL env var on the
 * agent, so presence of the field IS the opt-in signal.
 */
export function filterVectorSystems(
	systems: SystemRecord[],
	statsMap: Map<string, SystemStats>,
): SystemRecord[] {
	return systems.filter((s) => !!statsMap.get(s.id)?.vec)
}

export function extractVectorData(statsMap: Map<string, SystemStats>): Map<string, VectorStats> {
	const out = new Map<string, VectorStats>()
	for (const [systemId, stats] of statsMap) {
		if (stats.vec) out.set(systemId, stats.vec)
	}
	return out
}

/**
 * Aggregate totals across multiple Vector hosts. Vector pipelines are
 * independent per host so a plain sum is correct — there's no double-count
 * concern like the HAProxy frontend/backend or IPVS service/destination pairs.
 */
export interface VectorGroupTotals {
	systemCount: number
	healthyCount: number
	unhealthyCount: number
	componentCount: number
	sourceCount: number
	transformCount: number
	sinkCount: number
	receivedEvents: number
	sentEvents: number
	receivedBytes: number
	sentBytes: number
	errorsTotal: number
	discardedTotal: number
}

export function calculateGroupTotals(perHost: Map<string, VectorStats>): VectorGroupTotals {
	const totals: VectorGroupTotals = {
		systemCount: perHost.size,
		healthyCount: 0,
		unhealthyCount: 0,
		componentCount: 0,
		sourceCount: 0,
		transformCount: 0,
		sinkCount: 0,
		receivedEvents: 0,
		sentEvents: 0,
		receivedBytes: 0,
		sentBytes: 0,
		errorsTotal: 0,
		discardedTotal: 0,
	}

	for (const [, stats] of perHost) {
		if (stats.hl) totals.healthyCount++
		else totals.unhealthyCount++
		totals.componentCount += stats.cc ?? 0
		totals.sourceCount += stats.sc ?? 0
		totals.transformCount += stats.tc ?? 0
		totals.sinkCount += stats.sk ?? 0
		totals.receivedEvents += stats.re ?? 0
		totals.sentEvents += stats.se ?? 0
		totals.receivedBytes += stats.rb ?? 0
		totals.sentBytes += stats.sb ?? 0
		totals.errorsTotal += stats.e ?? 0
		totals.discardedTotal += stats.d ?? 0
	}

	return totals
}

export interface TaggedComponent extends VectorComponent {
	hostId: string
	hostName: string
}

export function flattenComponents(
	perHost: Map<string, VectorStats>,
	hostNames: Map<string, string>,
): TaggedComponent[] {
	const out: TaggedComponent[] = []
	for (const [hostId, stats] of perHost) {
		if (!stats.co) continue
		for (const comp of stats.co) {
			out.push({ ...comp, hostId, hostName: hostNames.get(hostId) ?? hostId })
		}
	}
	return out
}

/**
 * Per-host status for the Vector aggregate page. Mirrors the LVS status badges:
 * - **healthy** — system is up and Vector reports health=true
 * - **unhealthy** — system is up and Vector reports health=false
 * - **no-data** — system is up but no vec field (env var not set, port unreachable,
 *   or agent older than the build that introduced Vector support)
 * - **down** — agent isn't reporting
 */
export type VectorHostStatus = "healthy" | "unhealthy" | "no-data" | "down"

export function deriveHostStatus(
	systemStatus: SystemRecord["status"] | undefined,
	vec: VectorStats | undefined,
): VectorHostStatus {
	if (systemStatus !== "up") return "down"
	if (!vec) return "no-data"
	return vec.hl ? "healthy" : "unhealthy"
}

export function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B"
	const k = 1024
	const sizes = ["B", "KB", "MB", "GB", "TB", "PB"]
	const i = Math.floor(Math.log(bytes) / Math.log(k))
	return `${Number.parseFloat((bytes / k ** i).toFixed(1))} ${sizes[i]}`
}

export function formatEventsRate(eventsPerSec: number): string {
	if (eventsPerSec === 0) return "0/s"
	if (eventsPerSec < 1) return `${eventsPerSec.toFixed(2)}/s`
	if (eventsPerSec < 1000) return `${eventsPerSec.toFixed(1)}/s`
	const k = 1000
	const sizes = ["", "K", "M", "B"]
	const i = Math.floor(Math.log(eventsPerSec) / Math.log(k))
	return `${(eventsPerSec / k ** i).toFixed(1)}${sizes[i]}/s`
}

export function formatBytesPerSec(bytesPerSec: number): string {
	const bitsPerSec = bytesPerSec * 8
	if (bitsPerSec === 0) return "0 bps"
	const k = 1000
	const sizes = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
	const i = Math.floor(Math.log(bitsPerSec) / Math.log(k))
	return `${Number.parseFloat((bitsPerSec / k ** i).toFixed(1))} ${sizes[i]}`
}

export function formatNumber(num: number): string {
	return num.toLocaleString()
}

/**
 * Compute per-second rate between two cumulative counter samples. Returns 0
 * when intervalMs is non-positive or when the counter has wrapped/reset
 * (latest < previous — Vector restart, hostname change, etc).
 */
export function deriveRate(latest: number, previous: number, intervalMs: number): number {
	if (intervalMs <= 0) return 0
	const delta = latest - previous
	if (delta < 0) return 0
	return (delta * 1000) / intervalMs
}
