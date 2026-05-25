import type { IPVSDest, IPVSService, IPVSStats, SystemRecord, SystemStats } from "@/types"

/**
 * Zone classification for LVS hosts. Mirrors the HAProxy zone model so the
 * two pages share operator intuition (hostname prefix → environment).
 */
export type LVSZone = "pre" | "uat" | "lan" | "wan"

export function extractLVSZone(groupName: string): LVSZone {
	if (groupName.startsWith("lvs-pre-") || groupName === "lvs-pre") return "pre"
	if (groupName.startsWith("lvs-uat-") || groupName === "lvs-uat") return "uat"
	if (groupName.startsWith("lvs-lan")) return "lan"
	return "wan"
}

export function groupByLVSZone(groups: Map<string, unknown>): Map<LVSZone, string[]> {
	const zones = new Map<LVSZone, string[]>([
		["pre", []],
		["uat", []],
		["lan", []],
		["wan", []],
	])
	for (const groupName of groups.keys()) {
		zones.get(extractLVSZone(groupName))?.push(groupName)
	}
	for (const [, list] of zones) list.sort()
	return zones
}

/**
 * Pair grouping: `lvs-web-1` + `lvs-web-2` → `lvs-web`.
 * Standalone hosts (no `-<n>` suffix) become a single-member group named after themselves.
 */
export function extractGroupName(hostname: string): string | null {
	if (!hostname.startsWith("lvs-")) return null
	const m = hostname.match(/^(lvs-.+?)-(\d+)$/)
	return m ? m[1] : hostname
}

export function filterLVSSystems(systems: SystemRecord[]): SystemRecord[] {
	return systems.filter((s) => s.name.startsWith("lvs-"))
}

export function groupSystemsByPattern(systems: SystemRecord[]): Map<string, SystemRecord[]> {
	const groups = new Map<string, SystemRecord[]>()
	for (const sys of systems) {
		const g = extractGroupName(sys.name)
		if (!g) continue
		const existing = groups.get(g) || []
		existing.push(sys)
		groups.set(g, existing)
	}
	for (const [, list] of groups) {
		list.sort((a, b) => a.name.localeCompare(b.name))
	}
	return groups
}

/**
 * Per-pair (group) aggregate. All traffic fields sum SERVICE-level stats only —
 * summing service + destination would double-count. Across an active/standby
 * pair the standby contributes ~0, so a plain sum is correct.
 */
export interface LVSGroupTotals {
	systemCount: number
	activeNodes: number
	standbyNodes: number
	unknownNodes: number
	/** distinct VIPs seen across all hosts in the group */
	virtualIPs: string[]
	serviceCount: number
	realServerCount: number
	drainedServerCount: number
	activeConns: number
	inactiveConns: number
	connRate: number
	bytesInRate: number
	bytesOutRate: number
	pktInRate: number
	pktOutRate: number
	totalBytesIn: number
	totalBytesOut: number
	totalConns: number
}

export function calculateGroupTotals(perHost: Map<string, IPVSStats>): LVSGroupTotals {
	const vipSet = new Set<string>()
	const totals: LVSGroupTotals = {
		systemCount: perHost.size,
		activeNodes: 0,
		standbyNodes: 0,
		unknownNodes: 0,
		virtualIPs: [],
		serviceCount: 0,
		realServerCount: 0,
		drainedServerCount: 0,
		activeConns: 0,
		inactiveConns: 0,
		connRate: 0,
		bytesInRate: 0,
		bytesOutRate: 0,
		pktInRate: 0,
		pktOutRate: 0,
		totalBytesIn: 0,
		totalBytesOut: 0,
		totalConns: 0,
	}

	for (const [, stats] of perHost) {
		switch (stats.r) {
			case "active":
				totals.activeNodes++
				break
			case "standby":
				totals.standbyNodes++
				break
			default:
				totals.unknownNodes++
		}
		for (const v of stats.v) vipSet.add(v)
		totals.activeConns += stats.ac ?? 0
		totals.inactiveConns += stats.ic ?? 0
		totals.connRate += stats.cps ?? 0
		totals.bytesInRate += stats.bir ?? 0
		totals.bytesOutRate += stats.bor ?? 0
		totals.pktInRate += stats.pir ?? 0
		totals.pktOutRate += stats.por ?? 0
		totals.totalBytesIn += stats.tbi ?? 0
		totals.totalBytesOut += stats.tbo ?? 0
		totals.totalConns += stats.tc ?? 0
		if (stats.svc) {
			totals.serviceCount += stats.svc.length
			for (const svc of stats.svc) {
				if (svc.d) {
					totals.realServerCount += svc.d.length
					totals.drainedServerCount += svc.d.filter((d) => (d.w ?? 0) === 0).length
				}
			}
		}
	}

	totals.virtualIPs = [...vipSet].sort()
	return totals
}

export function extractIPVSData(statsMap: Map<string, SystemStats>): Map<string, IPVSStats> {
	const out = new Map<string, IPVSStats>()
	for (const [systemId, stats] of statsMap) {
		if (stats.ipvs) out.set(systemId, stats.ipvs)
	}
	return out
}

/**
 * Flatten services across hosts in a group, tagged with the host they came from.
 * Active-host services have the live traffic; standby contributes mostly zeros.
 */
export interface TaggedService extends IPVSService {
	hostId: string
	hostName: string
}

export function flattenServices(
	perHost: Map<string, IPVSStats>,
	hostNames: Map<string, string>
): TaggedService[] {
	const out: TaggedService[] = []
	for (const [hostId, stats] of perHost) {
		if (!stats.svc) continue
		for (const svc of stats.svc) {
			out.push({ ...svc, hostId, hostName: hostNames.get(hostId) ?? hostId })
		}
	}
	return out
}

/** A destination is "drained" when weight is 0 — keepalived/admin took it out of rotation. */
export function isDrained(d: IPVSDest): boolean {
	return (d.w ?? 0) === 0
}

export function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B"
	const k = 1024
	const sizes = ["B", "KB", "MB", "GB", "TB"]
	const i = Math.floor(Math.log(bytes) / Math.log(k))
	return `${Number.parseFloat((bytes / k ** i).toFixed(1))} ${sizes[i]}`
}

/**
 * Kernel reports BPSIn/BPSOut already in bytes/sec. Convert to bits and pick a unit.
 */
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
