import type { HAProxyInfo, HAProxyStats, SystemRecord, SystemStats } from "@/types"

/**
 * Extract group name from hostname.
 * Pattern: "ha-xxx-1", "ha-xxx-2" → "ha-xxx"
 * Pattern: "ha-web-api-1" → "ha-web-api"
 *
 * @returns group name or null if doesn't match ha-* pattern
 */
export function extractGroupName(hostname: string): string | null {
	if (!hostname.startsWith("ha-")) return null

	// Remove trailing number suffix (e.g., -1, -2, -10)
	const match = hostname.match(/^(ha-.+?)-(\d+)$/)
	if (match) {
		return match[1]
	}

	// If no number suffix, treat as its own group
	return hostname
}

/**
 * Filter systems to only those matching ha-* pattern
 */
export function filterHAProxySystems(systems: SystemRecord[]): SystemRecord[] {
	return systems.filter((s) => s.name.startsWith("ha-"))
}

/**
 * Group systems by extracted group name
 */
export function groupSystemsByPattern(systems: SystemRecord[]): Map<string, SystemRecord[]> {
	const groups = new Map<string, SystemRecord[]>()

	for (const system of systems) {
		const groupName = extractGroupName(system.name)
		if (!groupName) continue

		const existing = groups.get(groupName) || []
		existing.push(system)
		groups.set(groupName, existing)
	}

	// Sort systems within each group by name
	for (const [, systemList] of groups) {
		systemList.sort((a, b) => a.name.localeCompare(b.name))
	}

	return groups
}

export interface GroupTotals {
	/** SUM of current sessions across all frontends/backends */
	currentSessions: number
	/** SUM of total sessions */
	totalSessions: number
	/** SUM of bytes in */
	bytesIn: number
	/** SUM of bytes out */
	bytesOut: number
	/** SUM of bytes in per second */
	bytesInRate: number
	/** SUM of bytes out per second */
	bytesOutRate: number
	/** SUM of request rate */
	requestRate: number
	/** SUM of total requests */
	totalRequests: number
	/** SUM of 1xx responses */
	resp1xx: number
	/** SUM of 2xx responses */
	resp2xx: number
	/** SUM of 3xx responses */
	resp3xx: number
	/** SUM of 4xx responses */
	resp4xx: number
	/** SUM of 5xx responses */
	resp5xx: number
	/** SUM of active servers from backends */
	activeServers: number
	/** SUM of backup servers from backends */
	backupServers: number
	/** Number of systems in the group */
	systemCount: number
	/** Number of frontends */
	frontendCount: number
	/** Number of backends */
	backendCount: number
	/** Current connections from HAProxyInfo */
	currentConnections: number
	/** Total connections from HAProxyInfo */
	totalConnections: number
}

export interface GroupAverages {
	/** Weighted average response time (by request count) */
	responseTime: number
	/** Average sessions per system */
	sessionsPerSystem: number
	/** Average sessions per active server */
	sessionsPerServer: number
	/** Average CPU idle percent from HAProxyInfo */
	cpuIdlePercent: number
	/** Average connection rate */
	connectionRate: number
}

export interface GroupAggregates {
	totals: GroupTotals
	averages: GroupAverages
}

/**
 * Calculate totals by summing metrics across all systems in a group
 */
export function calculateTotals(
	groupStats: Map<string, HAProxyStats[]>,
	groupInfos: Map<string, HAProxyInfo>
): GroupTotals {
	const totals: GroupTotals = {
		currentSessions: 0,
		totalSessions: 0,
		bytesIn: 0,
		bytesOut: 0,
		bytesInRate: 0,
		bytesOutRate: 0,
		requestRate: 0,
		totalRequests: 0,
		resp1xx: 0,
		resp2xx: 0,
		resp3xx: 0,
		resp4xx: 0,
		resp5xx: 0,
		activeServers: 0,
		backupServers: 0,
		systemCount: groupStats.size,
		frontendCount: 0,
		backendCount: 0,
		currentConnections: 0,
		totalConnections: 0,
	}

	for (const [, stats] of groupStats) {
		for (const proxy of stats) {
			// Only aggregate frontends and backends, not individual servers
			if (proxy.t !== "FRONTEND" && proxy.t !== "BACKEND") continue

			totals.currentSessions += proxy.sc ?? 0
			totals.totalSessions += proxy.st ?? 0
			totals.bytesIn += proxy.bi ?? 0
			totals.bytesOut += proxy.bo ?? 0
			totals.bytesInRate += proxy.bir ?? 0
			totals.bytesOutRate += proxy.bor ?? 0
			totals.requestRate += proxy.rr ?? 0
			totals.totalRequests += proxy.rt ?? 0
			totals.resp1xx += proxy.r1 ?? 0
			totals.resp2xx += proxy.r2 ?? 0
			totals.resp3xx += proxy.r3 ?? 0
			totals.resp4xx += proxy.r4 ?? 0
			totals.resp5xx += proxy.r5 ?? 0

			if (proxy.t === "BACKEND") {
				totals.activeServers += proxy.as ?? 0
				totals.backupServers += proxy.bs ?? 0
				totals.backendCount++
			} else {
				totals.frontendCount++
			}
		}
	}

	// Sum connections from HAProxyInfo
	for (const [, info] of groupInfos) {
		totals.currentConnections += info.cc ?? 0
		totals.totalConnections += info.tc ?? 0
	}

	return totals
}

/**
 * Calculate averages for a group
 */
export function calculateAverages(
	groupStats: Map<string, HAProxyStats[]>,
	groupInfos: Map<string, HAProxyInfo>,
	totals: GroupTotals
): GroupAverages {
	// Response time: weighted average by total requests
	let totalResponseTime = 0
	let totalRequestCount = 0

	for (const [, stats] of groupStats) {
		for (const proxy of stats) {
			if (proxy.t === "BACKEND" && proxy.rsp !== undefined && proxy.rt) {
				totalResponseTime += proxy.rsp * proxy.rt
				totalRequestCount += proxy.rt
			}
		}
	}

	const avgResponseTime = totalRequestCount > 0 ? totalResponseTime / totalRequestCount : 0

	// CPU idle from HAProxyInfo
	let totalIdle = 0
	let totalConnectionRate = 0
	let infoCount = 0

	for (const [, info] of groupInfos) {
		if (info.ip !== undefined) {
			totalIdle += info.ip
			infoCount++
		}
		totalConnectionRate += info.cr ?? 0
	}

	return {
		responseTime: avgResponseTime,
		sessionsPerSystem: totals.systemCount > 0 ? totals.currentSessions / totals.systemCount : 0,
		sessionsPerServer: totals.activeServers > 0 ? totals.currentSessions / totals.activeServers : 0,
		cpuIdlePercent: infoCount > 0 ? totalIdle / infoCount : 0,
		connectionRate: infoCount > 0 ? totalConnectionRate / infoCount : 0,
	}
}

/**
 * Calculate all aggregates for a group
 */
export function calculateGroupAggregates(
	groupStats: Map<string, HAProxyStats[]>,
	groupInfos: Map<string, HAProxyInfo>
): GroupAggregates {
	const totals = calculateTotals(groupStats, groupInfos)
	const averages = calculateAverages(groupStats, groupInfos, totals)
	return { totals, averages }
}

/**
 * Format bytes to human readable string
 */
export function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B"
	const k = 1024
	const sizes = ["B", "KB", "MB", "GB", "TB"]
	const i = Math.floor(Math.log(bytes) / Math.log(k))
	return `${Number.parseFloat((bytes / k ** i).toFixed(1))} ${sizes[i]}`
}

/**
 * Format bytes per second to human readable string
 */
export function formatBytesPerSec(bytesPerSec: number): string {
	return `${formatBytes(bytesPerSec)}/s`
}

/**
 * Format number with commas
 */
export function formatNumber(num: number): string {
	return num.toLocaleString()
}

/**
 * Extract HAProxy stats from system stats
 */
export function extractHAProxyData(statsMap: Map<string, SystemStats>): {
	statsPerSystem: Map<string, HAProxyStats[]>
	infosPerSystem: Map<string, HAProxyInfo>
} {
	const statsPerSystem = new Map<string, HAProxyStats[]>()
	const infosPerSystem = new Map<string, HAProxyInfo>()

	for (const [systemId, stats] of statsMap) {
		if (stats.hap) {
			statsPerSystem.set(systemId, stats.hap)
		}
		if (stats.hapi) {
			infosPerSystem.set(systemId, stats.hapi)
		}
	}

	return { statsPerSystem, infosPerSystem }
}
