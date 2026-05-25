import { useLingui } from "@lingui/react/macro"
import {
	AlertCircleIcon,
	ChevronDownIcon,
	ChevronUpIcon,
	CircleOffIcon,
	FilterIcon,
	LayersIcon,
	RefreshCwIcon,
	ServerIcon,
} from "lucide-react"
import { memo, useEffect, useMemo, useRef, useState } from "react"
import { FooterRepoLink } from "@/components/footer-repo-link"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { pb } from "@/lib/api"
import {
	calculateGroupTotals,
	extractLVSZone,
	filterLVSSystems,
	formatBytesPerSec,
	formatNumber,
	groupByLVSZone,
	groupSystemsByPattern,
	type LVSGroupTotals,
	type LVSZone,
} from "@/lib/ipvs-aggregate"
import { $systems } from "@/lib/stores"
import { cn } from "@/lib/utils"
import type { IPVSStats, SystemRecord } from "@/types"

const POLL_INTERVAL = 5000
const HISTORY_LENGTH = 60

interface TrafficPoint {
	bytesIn: number
	bytesOut: number
	cps: number
	timestamp: number
}
type TrafficHistory = Map<string, TrafficPoint[]>

const ZONE_CONFIG: Record<LVSZone, { label: string; color: string }> = {
	pre: { label: "PRE", color: "bg-orange-500 hover:bg-orange-600" },
	uat: { label: "UAT", color: "bg-purple-500 hover:bg-purple-600" },
	lan: { label: "LAN", color: "bg-blue-500 hover:bg-blue-600" },
	wan: { label: "WAN", color: "bg-green-500 hover:bg-green-600" },
}

interface IPVSResponseItem {
	system: string
	ipvs?: IPVSStats
}

export default memo(function LVSAggregatePage() {
	const { t } = useLingui()
	const [statsMap, setStatsMap] = useState<Map<string, IPVSStats>>(new Map())
	const [loading, setLoading] = useState(false)
	const [lastUpdate, setLastUpdate] = useState<Date | null>(null)
	const [selectedGroups, setSelectedGroups] = useState<Set<string>>(new Set())
	const [selectedZones, setSelectedZones] = useState<Set<LVSZone>>(new Set())
	const [lvsSystems, setLvsSystems] = useState<SystemRecord[]>([])

	const mountedRef = useRef(true)
	const fetchingRef = useRef(false)
	const systemsRef = useRef<SystemRecord[]>([])
	const trafficHistoryRef = useRef<TrafficHistory>(new Map())
	const [trafficHistory, setTrafficHistory] = useState<TrafficHistory>(new Map())

	// Subscribe to systems store so we pick up async loads / refresh.
	useEffect(() => {
		const update = (all: SystemRecord[]) => {
			const filtered = filterLVSSystems(all)
			if (filtered.length > 0 || systemsRef.current.length === 0) {
				setLvsSystems(filtered)
				systemsRef.current = filtered
			}
		}
		update($systems.get())
		return $systems.subscribe(update)
	}, [])

	const fetchStats = async () => {
		const systems = systemsRef.current
		if (systems.length === 0 || fetchingRef.current || !mountedRef.current) return
		fetchingRef.current = true
		try {
			const ids = systems.map((s) => s.id).join(",")
			const response = await pb.send<IPVSResponseItem[]>("/api/beszel/ipvs/stats", {
				method: "GET",
				query: { ids },
			})
			const next = new Map<string, IPVSStats>()
			for (const item of response) {
				if (item.ipvs) next.set(item.system, item.ipvs)
			}
			if (mountedRef.current) {
				setStatsMap(next)
				setLastUpdate(new Date())
			}
		} catch (err) {
			console.error("Failed to fetch IPVS stats:", err)
		} finally {
			fetchingRef.current = false
			if (mountedRef.current) setLoading(false)
		}
	}

	useEffect(() => {
		mountedRef.current = true
		const initial = setTimeout(fetchStats, 300)
		const poll = setInterval(fetchStats, POLL_INTERVAL)
		return () => {
			mountedRef.current = false
			clearTimeout(initial)
			clearInterval(poll)
		}
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [])

	const groups = useMemo(() => groupSystemsByPattern(lvsSystems), [lvsSystems])
	const zones = useMemo(() => groupByLVSZone(groups), [groups])

	// Per-group aggregate (only counts hosts with IPVS data).
	const { groupTotals, groupHealth } = useMemo(() => {
		const totals = new Map<string, LVSGroupTotals>()
		const health = new Map<string, { withData: number; withoutData: number; total: number }>()
		for (const [groupName, members] of groups) {
			const perHost = new Map<string, IPVSStats>()
			let withData = 0
			let withoutData = 0
			for (const sys of members) {
				const ipvs = statsMap.get(sys.id)
				if (ipvs) {
					perHost.set(sys.id, ipvs)
					withData++
				} else {
					withoutData++
				}
			}
			health.set(groupName, { withData, withoutData, total: members.length })
			if (perHost.size > 0) totals.set(groupName, calculateGroupTotals(perHost))
		}
		return { groupTotals: totals, groupHealth: health }
	}, [groups, statsMap])

	// Accumulate per-group traffic history (client-side rolling 5-min window).
	useEffect(() => {
		if (groupTotals.size === 0) return
		const now = Date.now()
		const hist = trafficHistoryRef.current
		for (const [groupName, agg] of groupTotals) {
			let h = hist.get(groupName)
			if (!h) {
				h = []
				hist.set(groupName, h)
			}
			h.push({
				bytesIn: agg.bytesInRate,
				bytesOut: agg.bytesOutRate,
				cps: agg.connRate,
				timestamp: now,
			})
			if (h.length > HISTORY_LENGTH) h.shift()
		}
		setTrafficHistory(new Map(hist))
	}, [groupTotals])

	const filteredGroups = useMemo(() => {
		if (selectedZones.size === 0 && selectedGroups.size === 0) return groups
		const out = new Map<string, SystemRecord[]>()
		for (const [name, systems] of groups) {
			const zone = extractLVSZone(name)
			if (selectedZones.size > 0 && !selectedZones.has(zone)) continue
			if (selectedGroups.size > 0 && !selectedGroups.has(name)) continue
			out.set(name, systems)
		}
		return out
	}, [groups, selectedGroups, selectedZones])

	const toggleGroup = (name: string) =>
		setSelectedGroups((p) => {
			const n = new Set(p)
			n.has(name) ? n.delete(name) : n.add(name)
			return n
		})
	const toggleZone = (z: LVSZone) => {
		setSelectedZones((p) => {
			const n = new Set(p)
			n.has(z) ? n.delete(z) : n.add(z)
			return n
		})
		setSelectedGroups(new Set())
	}
	const clearAll = () => {
		setSelectedGroups(new Set())
		setSelectedZones(new Set())
	}

	useEffect(() => {
		document.title = `${t`LVS Aggregate`} / Beszel`
	}, [t])

	const handleRefresh = () => {
		if (loading) return
		setLoading(true)
		fetchStats()
	}

	if (lvsSystems.length === 0) {
		return (
			<div className="grid gap-4">
				<Card className="p-6">
					<div className="flex flex-col items-center justify-center gap-4 text-center">
						<ServerIcon className="h-12 w-12 text-muted-foreground/50" />
						<div>
							<h3 className="text-lg font-medium">{t`No LVS Systems Found`}</h3>
							<p className="text-muted-foreground mt-1">
								{t`No systems matching the "lvs-*" pattern were found.`}
							</p>
							<p className="text-muted-foreground text-sm mt-2">
								{t`LVS systems should be named like "lvs-web-1", "lvs-edge-2", etc.`}
							</p>
						</div>
					</div>
				</Card>
				<FooterRepoLink />
			</div>
		)
	}

	const totalWith = Array.from(groupHealth.values()).reduce((s, h) => s + h.withData, 0)
	const totalWithout = Array.from(groupHealth.values()).reduce((s, h) => s + h.withoutData, 0)

	return (
		<div className="grid gap-4 mb-14">
			<Card>
				<div className="flex items-center justify-between px-4 sm:px-6 py-4">
					<div>
						<h1 className="text-[1.6rem] font-semibold">{t`LVS Aggregate`}</h1>
						<p className="text-sm text-muted-foreground mt-1">
							{t`${totalWith} reporting, ${totalWithout} silent across ${groups.size} groups`}
						</p>
					</div>
					<div className="flex items-center gap-4">
						{lastUpdate && (
							<span className="text-xs text-muted-foreground hidden sm:block">
								{t`Updated`}: {lastUpdate.toLocaleTimeString()}
							</span>
						)}
						<Button variant="outline" size="icon" onClick={handleRefresh} disabled={loading}>
							<RefreshCwIcon className={cn("h-4 w-4", loading && "animate-spin")} />
						</Button>
					</div>
				</div>

				{groups.size > 0 && (
					<div className="px-4 sm:px-6 pb-4 border-t pt-4">
						<div className="flex items-center gap-2 mb-2">
							<LayersIcon className="h-4 w-4 text-muted-foreground" />
							<span className="text-sm text-muted-foreground">{t`Filter by zone:`}</span>
							{(selectedZones.size > 0 || selectedGroups.size > 0) && (
								<Button variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={clearAll}>
									{t`Clear All`}
								</Button>
							)}
						</div>
						<div className="flex flex-wrap gap-2">
							{(["pre", "uat", "lan", "wan"] as LVSZone[]).map((z) => {
								const list = zones.get(z) || []
								if (list.length === 0) return null
								const selected = selectedZones.has(z)
								const cfg = ZONE_CONFIG[z]
								let online = 0
								let total = 0
								for (const g of list) {
									const h = groupHealth.get(g)
									if (h) {
										online += h.withData
										total += h.total
									}
								}
								return (
									<Badge
										key={z}
										variant="default"
										className={cn(
											"cursor-pointer transition-colors text-white",
											selected ? cfg.color : "bg-muted-foreground/30 hover:bg-muted-foreground/50",
										)}
										onClick={() => toggleZone(z)}
									>
										{cfg.label}
										<span className="ml-1 opacity-80">
											({online}/{total})
										</span>
									</Badge>
								)
							})}
						</div>
					</div>
				)}

				{groups.size > 0 && (
					<div className="px-4 sm:px-6 pb-4 border-t pt-4">
						<div className="flex items-center gap-2 mb-2">
							<FilterIcon className="h-4 w-4 text-muted-foreground" />
							<span className="text-sm text-muted-foreground">{t`Filter groups:`}</span>
						</div>
						<div className="flex flex-wrap gap-2">
							{Array.from(groups.keys())
								.sort()
								.map((name) => {
									const zone = extractLVSZone(name)
									const selected = selectedGroups.has(name)
									const inZone = selectedZones.size === 0 || selectedZones.has(zone)
									const health = groupHealth.get(name)
									if (!inZone) {
										return (
											<Badge key={name} variant="outline" className="cursor-not-allowed opacity-30">
												{name}
											</Badge>
										)
									}
									return (
										<Badge
											key={name}
											variant={
												(selectedGroups.size === 0 && selectedZones.size === 0) || selected
													? "default"
													: "outline"
											}
											className={cn(
												"cursor-pointer transition-colors",
												(selectedGroups.size === 0 && selectedZones.size === 0) || selected
													? "bg-primary hover:bg-primary/80"
													: "hover:bg-muted",
											)}
											onClick={() => toggleGroup(name)}
										>
											{name}
											{health && (
												<span className="ml-1 opacity-70">
													({health.withData}
													{health.withoutData > 0 && `/${health.total}`})
												</span>
											)}
										</Badge>
									)
								})}
						</div>
					</div>
				)}
			</Card>

			<SummaryCards groups={filteredGroups} totals={groupTotals} trafficHistory={trafficHistory} />

			{Array.from(filteredGroups.entries())
				.sort(([a], [b]) => a.localeCompare(b))
				.map(([name, systems]) => (
					<GroupCard
						key={name}
						groupName={name}
						systems={systems}
						totals={groupTotals.get(name)}
						statsMap={statsMap}
						trafficHistory={trafficHistory.get(name)}
					/>
				))}

			<FooterRepoLink />
		</div>
	)
})

const SummaryCards = memo(function SummaryCards({
	groups,
	totals,
	trafficHistory,
}: {
	groups: Map<string, SystemRecord[]>
	totals: Map<string, LVSGroupTotals>
	trafficHistory: TrafficHistory
}) {
	const { t } = useLingui()
	const { grand, bytesInHist, bytesOutHist, cpsHist } = useMemo(() => {
		let conns = 0
		let bin = 0
		let bout = 0
		let cps = 0
		let active = 0
		let standby = 0
		const histBy = new Map<number, { bytesIn: number; bytesOut: number; cps: number }>()
		for (const name of groups.keys()) {
			const t2 = totals.get(name)
			if (t2) {
				conns += t2.activeConns
				bin += t2.bytesInRate
				bout += t2.bytesOutRate
				cps += t2.connRate
				active += t2.activeNodes
				standby += t2.standbyNodes
			}
			const h = trafficHistory.get(name)
			if (h) {
				for (const p of h) {
					const e = histBy.get(p.timestamp)
					if (e) {
						e.bytesIn += p.bytesIn
						e.bytesOut += p.bytesOut
						e.cps += p.cps
					} else {
						histBy.set(p.timestamp, { bytesIn: p.bytesIn, bytesOut: p.bytesOut, cps: p.cps })
					}
				}
			}
		}
		const sorted = Array.from(histBy.entries())
			.sort(([a], [b]) => a - b)
			.map(([, v]) => v)
		return {
			grand: { conns, bin, bout, cps, active, standby, groupCount: groups.size },
			bytesInHist: sorted.map((p) => p.bytesIn),
			bytesOutHist: sorted.map((p) => p.bytesOut),
			cpsHist: sorted.map((p) => p.cps),
		}
	}, [groups, totals, trafficHistory])

	return (
		<div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
			<SummaryCard title={t`Groups`} value={grand.groupCount.toString()} />
			<SummaryCard title={t`Active / Standby`} value={`${grand.active} / ${grand.standby}`} />
			<SummaryCard title={t`Connections`} value={formatNumber(grand.conns)} />
			<SummaryCardWithSparkline
				title={t`Conn rate`}
				value={`${formatNumber(grand.cps)}/s`}
				history={cpsHist}
				color="#a855f7"
			/>
			<SummaryCardWithSparkline
				title={t`Traffic In`}
				value={formatBytesPerSec(grand.bin)}
				history={bytesInHist}
				color="#22c55e"
			/>
			<SummaryCardWithSparkline
				title={t`Traffic Out`}
				value={formatBytesPerSec(grand.bout)}
				history={bytesOutHist}
				color="#3b82f6"
			/>
		</div>
	)
})

function SummaryCard({ title, value }: { title: string; value: string }) {
	return (
		<Card className="p-4">
			<p className="text-sm text-muted-foreground">{title}</p>
			<p className="text-2xl font-semibold mt-1">{value}</p>
		</Card>
	)
}

function SummaryCardWithSparkline({
	title,
	value,
	history,
	color,
}: {
	title: string
	value: string
	history: number[]
	color: string
}) {
	return (
		<Card className="p-4">
			<p className="text-sm text-muted-foreground">{title}</p>
			<div className="flex items-center gap-2 mt-1">
				<p className="text-2xl font-semibold">{value}</p>
				<Sparkline data={history} color={color} />
			</div>
		</Card>
	)
}

// Compact sparkline (right-anchored — new points enter from the right).
const Sparkline = memo(function Sparkline({ data, color }: { data: number[]; color: string }) {
	const { linePath, areaPath, last } = useMemo(() => {
		if (data.length < 2) return { linePath: null, areaPath: null, last: null }
		const max = Math.max(...data)
		if (max === 0) return { linePath: null, areaPath: null, last: null }
		const min = Math.min(...data)
		const range = max - min
		const baseline = Math.max(0, min - range)
		const scale = max - baseline || 1
		const offset = HISTORY_LENGTH - data.length
		const points = data.map((v, i) => {
			const x = ((i + offset) / (HISTORY_LENGTH - 1)) * 100
			const y = 100 - ((v - baseline) / scale) * 90 - 5
			return { x, y }
		})
		const line = `M ${points.map((p) => `${p.x},${p.y}`).join(" L ")}`
		const firstX = points[0].x
		const area = `${line} L 100,100 L ${firstX},100 Z`
		return { linePath: line, areaPath: area, last: points[points.length - 1] }
	}, [data])

	if (!linePath) return <div className="w-[60px] h-[20px]" />

	return (
		<svg viewBox="0 0 100 100" preserveAspectRatio="none" className="w-[60px] h-[20px]">
			<path d={areaPath ?? ""} fill={color} fillOpacity={0.1} />
			<path
				d={linePath}
				fill="none"
				stroke={color}
				strokeWidth={1.5}
				strokeLinecap="round"
				strokeLinejoin="round"
				vectorEffect="non-scaling-stroke"
			/>
			{last && <circle cx={last.x} cy={last.y} r={3} fill={color} vectorEffect="non-scaling-stroke" />}
		</svg>
	)
})

type HostStatus = "active" | "standby" | "unknown" | "no-data" | "down"

const STATUS_CLASS: Record<HostStatus, string> = {
	active: "bg-green-500/20 text-green-700 border-green-500/40",
	standby: "bg-gray-500/20 text-gray-700 border-gray-500/40",
	unknown: "bg-yellow-500/20 text-yellow-700 border-yellow-500/40",
	"no-data": "bg-orange-500/20 text-orange-700 border-orange-500/40",
	down: "bg-red-500/20 text-red-700 border-red-500/40",
}

/**
 * Tooltip text for the "no-data" state. Hosts named lvs-* but reporting no IPVS
 * field typically have a permission gap (the netlink call to ip_vs needs
 * CAP_NET_ADMIN, which the default agent service user doesn't have).
 */
const NO_DATA_HINT =
	"Agent up but no IPVS data. Likely missing CAP_NET_ADMIN " +
	"(add /etc/systemd/system/beszel-agent.service.d/ipvs.conf with " +
	"AmbientCapabilities=CAP_NET_ADMIN and restart), or ip_vs kernel " +
	"module not loaded (modprobe ip_vs), or agent older than v0.18.7-mp.1."

function deriveHostStatus(systemStatus: SystemRecord["status"], ipvs: IPVSStats | undefined): HostStatus {
	if (systemStatus !== "up") return "down"
	if (!ipvs) return "no-data"
	return ipvs.r
}

const GroupCard = memo(function GroupCard({
	groupName,
	systems,
	totals,
	statsMap,
	trafficHistory,
}: {
	groupName: string
	systems: SystemRecord[]
	totals?: LVSGroupTotals
	statsMap: Map<string, IPVSStats>
	trafficHistory?: TrafficPoint[]
}) {
	const { t } = useLingui()
	const [expanded, setExpanded] = useState(false)

	const bytesInHist = trafficHistory?.map((p) => p.bytesIn) ?? []
	const bytesOutHist = trafficHistory?.map((p) => p.bytesOut) ?? []

	return (
		<Card>
			<CardHeader className="pb-4">
				<div className="flex items-start justify-between gap-4 flex-wrap">
					<div>
						<CardTitle className="text-xl">{groupName}</CardTitle>
						<CardDescription className="mt-1 flex flex-wrap items-center gap-2">
							{systems.map((s) => {
								const ipvs = statsMap.get(s.id)
								const status = deriveHostStatus(s.status, ipvs)
								const tooltip = status === "no-data" ? NO_DATA_HINT : undefined
								return (
									<span
										key={s.id}
										title={tooltip}
										className={cn(
											"inline-flex items-center gap-1.5 px-2 py-0.5 rounded border text-xs font-medium",
											STATUS_CLASS[status],
											tooltip && "cursor-help",
										)}
									>
										{s.name}
										{status === "no-data" && <AlertCircleIcon className="h-3 w-3" />}
										{status === "down" && <CircleOffIcon className="h-3 w-3" />}
										<span className="uppercase opacity-80">
											{status === "no-data" ? t`no data` : status}
										</span>
									</span>
								)
							})}
							{totals && totals.drainedServerCount > 0 && (
								<span className="text-xs text-amber-600">
									{t`${totals.drainedServerCount} drained`}
								</span>
							)}
						</CardDescription>
					</div>
					<Button variant="ghost" size="sm" onClick={() => setExpanded((e) => !e)}>
						{expanded ? <ChevronUpIcon className="h-4 w-4" /> : <ChevronDownIcon className="h-4 w-4" />}
						<span className="ml-1">{expanded ? t`Collapse` : t`Expand`}</span>
					</Button>
				</div>

				{totals && totals.virtualIPs.length > 0 && (
					<div className="mt-3 flex flex-wrap items-center gap-1.5">
						<span className="text-xs text-muted-foreground mr-1">{t`VIPs`}:</span>
						{totals.virtualIPs.map((vip) => (
							<Badge key={vip} variant="outline" className="font-mono text-xs">
								{vip}
							</Badge>
						))}
					</div>
				)}
			</CardHeader>

			{totals && (
				<div className="px-6 pb-6 grid grid-cols-2 md:grid-cols-4 gap-4">
					<Metric label={t`Conns`} value={formatNumber(totals.activeConns)} />
					<Metric label={t`Conn rate`} value={`${formatNumber(totals.connRate)}/s`} />
					<Metric
						label={t`Traffic In`}
						value={formatBytesPerSec(totals.bytesInRate)}
						sparkline={bytesInHist}
						color="#22c55e"
					/>
					<Metric
						label={t`Traffic Out`}
						value={formatBytesPerSec(totals.bytesOutRate)}
						sparkline={bytesOutHist}
						color="#3b82f6"
					/>
				</div>
			)}

			{expanded && totals && <ServiceTable systems={systems} statsMap={statsMap} />}
		</Card>
	)
})

function Metric({
	label,
	value,
	sparkline,
	color,
}: {
	label: string
	value: string
	sparkline?: number[]
	color?: string
}) {
	return (
		<div>
			<p className="text-xs text-muted-foreground">{label}</p>
			<div className="flex items-center gap-2 mt-1">
				<p className="text-lg font-semibold">{value}</p>
				{sparkline && color && <Sparkline data={sparkline} color={color} />}
			</div>
		</div>
	)
}

function ServiceTable({
	systems,
	statsMap,
}: {
	systems: SystemRecord[]
	statsMap: Map<string, IPVSStats>
}) {
	const { t } = useLingui()
	const rows: { host: string; svc: NonNullable<IPVSStats["svc"]>[number] }[] = []
	for (const s of systems) {
		const ipvs = statsMap.get(s.id)
		if (!ipvs?.svc) continue
		for (const svc of ipvs.svc) rows.push({ host: s.name, svc })
	}
	if (rows.length === 0) {
		return (
			<div className="px-6 pb-6 text-sm text-muted-foreground">{t`No virtual services reported`}</div>
		)
	}
	return (
		<div className="px-6 pb-6 overflow-x-auto">
			<table className="w-full text-sm">
				<thead>
					<tr className="text-left text-xs text-muted-foreground border-b">
						<th className="py-2 pr-3">{t`Host`}</th>
						<th className="py-2 pr-3">{t`Virtual Service`}</th>
						<th className="py-2 pr-3">{t`Sched`}</th>
						<th className="py-2 pr-3">{t`Mode`}</th>
						<th className="py-2 pr-3 text-right">{t`Active`}</th>
						<th className="py-2 pr-3 text-right">{t`Inactive`}</th>
						<th className="py-2 pr-3 text-right">{t`CPS`}</th>
						<th className="py-2 pr-3 text-right">{t`In`}</th>
						<th className="py-2 pr-3 text-right">{t`Out`}</th>
						<th className="py-2 pr-3 text-right">{t`Reals`}</th>
					</tr>
				</thead>
				<tbody>
					{rows.map(({ host, svc }, i) => {
						const drained = (svc.d ?? []).filter((d) => (d.w ?? 0) === 0).length
						const total = svc.d?.length ?? 0
						return (
							<tr key={`${host}-${svc.v}:${svc.p}-${i}`} className="border-b last:border-0">
								<td className="py-2 pr-3 font-mono text-xs">{host}</td>
								<td className="py-2 pr-3 font-mono text-xs">
									{svc.v}:{svc.p}/{svc.pr}
								</td>
								<td className="py-2 pr-3 uppercase text-xs">{svc.sc}</td>
								<td className="py-2 pr-3 text-xs">{svc.fm ?? "—"}</td>
								<td className="py-2 pr-3 text-right">{formatNumber(svc.ac ?? 0)}</td>
								<td className="py-2 pr-3 text-right">{formatNumber(svc.ic ?? 0)}</td>
								<td className="py-2 pr-3 text-right">{formatNumber(svc.cps ?? 0)}</td>
								<td className="py-2 pr-3 text-right">{formatBytesPerSec(svc.bir ?? 0)}</td>
								<td className="py-2 pr-3 text-right">{formatBytesPerSec(svc.bor ?? 0)}</td>
								<td className="py-2 pr-3 text-right">
									{total - drained}/{total}
									{drained > 0 && <span className="text-amber-600 ml-1">⚠</span>}
								</td>
							</tr>
						)
					})}
				</tbody>
			</table>
		</div>
	)
}
