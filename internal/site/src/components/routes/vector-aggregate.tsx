import { useLingui } from "@lingui/react/macro"
import {
	ActivityIcon,
	AlertTriangleIcon,
	ChevronDownIcon,
	ChevronUpIcon,
	CircleOffIcon,
	RefreshCwIcon,
	ServerIcon,
} from "lucide-react"
import { memo, useEffect, useMemo, useRef, useState } from "react"
import { FooterRepoLink } from "@/components/footer-repo-link"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { pb } from "@/lib/api"
import { $systems } from "@/lib/stores"
import { cn } from "@/lib/utils"
import {
	deriveHostStatus,
	deriveRate,
	formatBytes,
	formatBytesPerSec,
	formatEventsRate,
	formatNumber,
	type VectorHostStatus,
} from "@/lib/vector-aggregate"
import type { SystemRecord, VectorComponent, VectorStats } from "@/types"

const POLL_INTERVAL = 5000
const HISTORY_LENGTH = 60

interface ThroughputPoint {
	receivedEventsRate: number
	sentEventsRate: number
	receivedBytesRate: number
	sentBytesRate: number
	timestamp: number
}
type ThroughputHistory = Map<string, ThroughputPoint[]>

interface CounterSample {
	receivedEvents: number
	sentEvents: number
	receivedBytes: number
	sentBytes: number
	timestamp: number
}

interface VectorResponseItem {
	system: string
	vector?: VectorStats
}

const STATUS_CLASS: Record<VectorHostStatus, string> = {
	healthy: "bg-green-500/20 text-green-700 border-green-500/40",
	unhealthy: "bg-red-500/20 text-red-700 border-red-500/40",
	"no-data": "bg-orange-500/20 text-orange-700 border-orange-500/40",
	down: "bg-gray-500/20 text-gray-700 border-gray-500/40",
}

// Hint surfaced on the no-data badge — same pattern as LVS uses for CAP_NET_ADMIN.
const NO_DATA_HINT =
	"Agent up but no Vector data. Likely VECTOR_API_URL not set on the agent, " +
	"the local Vector instance is unreachable on the configured endpoint, " +
	"or the agent binary predates Vector support."

export default memo(function VectorAggregatePage() {
	const { t } = useLingui()
	const [statsMap, setStatsMap] = useState<Map<string, VectorStats>>(new Map())
	const [loading, setLoading] = useState(false)
	const [lastUpdate, setLastUpdate] = useState<Date | null>(null)
	const [allSystems, setAllSystems] = useState<SystemRecord[]>([])

	const mountedRef = useRef(true)
	const fetchingRef = useRef(false)
	const systemsRef = useRef<SystemRecord[]>([])

	// Per-system previous counter sample to derive rates between polls.
	const prevCountersRef = useRef<Map<string, CounterSample>>(new Map())
	const throughputHistoryRef = useRef<ThroughputHistory>(new Map())
	const [throughputHistory, setThroughputHistory] = useState<ThroughputHistory>(new Map())

	// Subscribe to systems store — Vector visibility is decided after fetch
	// (based on which systems have a `vec` field), so we hold *all* systems
	// here and filter inside `fetchStats`.
	useEffect(() => {
		const update = (all: SystemRecord[]) => {
			setAllSystems(all)
			systemsRef.current = all
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
			const response = await pb.send<VectorResponseItem[]>("/api/beszel/vector/stats", {
				method: "GET",
				query: { ids },
			})
			const next = new Map<string, VectorStats>()
			for (const item of response) {
				if (item.vector) next.set(item.system, item.vector)
			}
			if (!mountedRef.current) return

			// Derive rates per system from previous sample.
			const now = Date.now()
			const hist = throughputHistoryRef.current
			for (const [systemId, vec] of next) {
				const sample: CounterSample = {
					receivedEvents: vec.re ?? 0,
					sentEvents: vec.se ?? 0,
					receivedBytes: vec.rb ?? 0,
					sentBytes: vec.sb ?? 0,
					timestamp: now,
				}
				const prev = prevCountersRef.current.get(systemId)
				// If every cumulative counter is identical to the previous sample,
				// the hub hasn't written a new system_stats record between our polls.
				// Recomputing here would produce rate=0 and flap the display. Skip
				// and leave the last good rate in history.
				if (
					prev &&
					prev.receivedEvents === sample.receivedEvents &&
					prev.sentEvents === sample.sentEvents &&
					prev.receivedBytes === sample.receivedBytes &&
					prev.sentBytes === sample.sentBytes
				) {
					continue
				}
				if (prev) {
					const interval = now - prev.timestamp
					const point: ThroughputPoint = {
						receivedEventsRate: deriveRate(sample.receivedEvents, prev.receivedEvents, interval),
						sentEventsRate: deriveRate(sample.sentEvents, prev.sentEvents, interval),
						receivedBytesRate: deriveRate(sample.receivedBytes, prev.receivedBytes, interval),
						sentBytesRate: deriveRate(sample.sentBytes, prev.sentBytes, interval),
						timestamp: now,
					}
					let h = hist.get(systemId)
					if (!h) {
						h = []
						hist.set(systemId, h)
					}
					h.push(point)
					if (h.length > HISTORY_LENGTH) h.shift()
				}
				prevCountersRef.current.set(systemId, sample)
			}

			setStatsMap(next)
			setThroughputHistory(new Map(hist))
			setLastUpdate(new Date())
		} catch (err) {
			console.error("Failed to fetch Vector stats:", err)
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

	useEffect(() => {
		document.title = `${t`Vector Aggregate`} / Beszel`
	}, [t])

	const handleRefresh = () => {
		if (loading) return
		setLoading(true)
		fetchStats()
	}

	// Visibility rule: include any system that currently reports a vec field.
	const vectorSystems = useMemo(
		() => allSystems.filter((s) => statsMap.has(s.id)),
		[allSystems, statsMap],
	)

	const grandTotals = useMemo(() => {
		let receivedEventsRate = 0
		let sentEventsRate = 0
		let receivedBytesRate = 0
		let sentBytesRate = 0
		let receivedEvents = 0
		let sentEvents = 0
		let receivedBytes = 0
		let sentBytes = 0
		let errors = 0
		let healthy = 0
		let unhealthy = 0
		for (const s of vectorSystems) {
			const vec = statsMap.get(s.id)
			if (!vec) continue
			if (vec.hl) healthy++
			else unhealthy++
			receivedEvents += vec.re ?? 0
			sentEvents += vec.se ?? 0
			receivedBytes += vec.rb ?? 0
			sentBytes += vec.sb ?? 0
			errors += vec.e ?? 0
			const hist = throughputHistory.get(s.id)
			const latest = hist?.[hist.length - 1]
			if (latest) {
				receivedEventsRate += latest.receivedEventsRate
				sentEventsRate += latest.sentEventsRate
				receivedBytesRate += latest.receivedBytesRate
				sentBytesRate += latest.sentBytesRate
			}
		}
		return {
			healthy,
			unhealthy,
			receivedEventsRate,
			sentEventsRate,
			receivedBytesRate,
			sentBytesRate,
			receivedEvents,
			sentEvents,
			receivedBytes,
			sentBytes,
			errors,
		}
	}, [vectorSystems, statsMap, throughputHistory])

	if (allSystems.length === 0) {
		return (
			<div className="grid gap-4">
				<Card className="p-6">
					<div className="flex flex-col items-center justify-center gap-4 text-center">
						<ServerIcon className="h-12 w-12 text-muted-foreground/50" />
						<div>
							<h3 className="text-lg font-medium">{t`No Systems`}</h3>
							<p className="text-muted-foreground mt-1">{t`Waiting for system records to load…`}</p>
						</div>
					</div>
				</Card>
				<FooterRepoLink />
			</div>
		)
	}

	if (vectorSystems.length === 0) {
		return (
			<div className="grid gap-4">
				<Card className="p-6">
					<div className="flex flex-col items-center justify-center gap-4 text-center">
						<ActivityIcon className="h-12 w-12 text-muted-foreground/50" />
						<div>
							<h3 className="text-lg font-medium">{t`No Vector hosts found`}</h3>
							<p className="text-muted-foreground mt-1">
								{t`No agents are reporting Vector data yet.`}
							</p>
							<p className="text-muted-foreground text-sm mt-2">
								{t`Set VECTOR_API_URL (e.g. http://127.0.0.1:8686/graphql) on a beszel-agent and ensure the local Vector instance has its GraphQL API enabled.`}
							</p>
						</div>
					</div>
				</Card>
				<FooterRepoLink />
			</div>
		)
	}

	return (
		<div className="grid gap-4 mb-14">
			<Card>
				<div className="flex items-center justify-between px-4 sm:px-6 py-4">
					<div>
						<h1 className="text-[1.6rem] font-semibold">{t`Vector Aggregate`}</h1>
						<p className="text-sm text-muted-foreground mt-1">
							{t`${grandTotals.healthy} healthy, ${grandTotals.unhealthy} unhealthy across ${vectorSystems.length} hosts`}
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
			</Card>

			<SummaryCards totals={grandTotals} history={throughputHistory} />

			{vectorSystems
				.slice()
				.sort((a, b) => a.name.localeCompare(b.name))
				.map((sys) => (
					<HostCard
						key={sys.id}
						system={sys}
						vec={statsMap.get(sys.id)}
						history={throughputHistory.get(sys.id)}
					/>
				))}

			<FooterRepoLink />
		</div>
	)
})

const SummaryCards = memo(function SummaryCards({
	totals,
	history,
}: {
	totals: {
		receivedEventsRate: number
		sentEventsRate: number
		receivedBytesRate: number
		sentBytesRate: number
		receivedEvents: number
		sentEvents: number
		receivedBytes: number
		sentBytes: number
		errors: number
	}
	history: ThroughputHistory
}) {
	const { t } = useLingui()

	// Per-timestamp sum across hosts for the combined sparklines.
	const { evIn, evOut, byIn, byOut } = useMemo(() => {
		const byTs = new Map<number, { evIn: number; evOut: number; byIn: number; byOut: number }>()
		for (const points of history.values()) {
			for (const p of points) {
				const e = byTs.get(p.timestamp)
				if (e) {
					e.evIn += p.receivedEventsRate
					e.evOut += p.sentEventsRate
					e.byIn += p.receivedBytesRate
					e.byOut += p.sentBytesRate
				} else {
					byTs.set(p.timestamp, {
						evIn: p.receivedEventsRate,
						evOut: p.sentEventsRate,
						byIn: p.receivedBytesRate,
						byOut: p.sentBytesRate,
					})
				}
			}
		}
		const sorted = Array.from(byTs.entries())
			.sort(([a], [b]) => a - b)
			.map(([, v]) => v)
		return {
			evIn: sorted.map((p) => p.evIn),
			evOut: sorted.map((p) => p.evOut),
			byIn: sorted.map((p) => p.byIn),
			byOut: sorted.map((p) => p.byOut),
		}
	}, [history])

	return (
		<div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
			<SummaryCard
				title={t`Errors total`}
				value={formatNumber(totals.errors)}
				accent={totals.errors > 0 ? "text-amber-700" : undefined}
			/>
			<SummaryCardWithSparkline
				title={t`Events in/s`}
				value={formatEventsRate(totals.receivedEventsRate)}
				history={evIn}
				color="#3b82f6"
			/>
			<SummaryCardWithSparkline
				title={t`Events out/s`}
				value={formatEventsRate(totals.sentEventsRate)}
				history={evOut}
				color="#22c55e"
			/>
			<SummaryCardWithSparkline
				title={t`Bytes in/s`}
				value={formatBytesPerSec(totals.receivedBytesRate)}
				history={byIn}
				color="#3b82f6"
			/>
			<SummaryCardWithSparkline
				title={t`Bytes out/s`}
				value={formatBytesPerSec(totals.sentBytesRate)}
				history={byOut}
				color="#22c55e"
			/>
		</div>
	)
})

function SummaryCard({ title, value, accent }: { title: string; value: string; accent?: string }) {
	return (
		<Card className="p-4">
			<p className="text-sm text-muted-foreground">{title}</p>
			<p className={cn("text-2xl font-semibold mt-1 tabular-nums", accent)}>{value}</p>
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
				<p className="text-2xl font-semibold tabular-nums">{value}</p>
				<Sparkline data={history} color={color} />
			</div>
		</Card>
	)
}

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

const HostCard = memo(function HostCard({
	system,
	vec,
	history,
}: {
	system: SystemRecord
	vec: VectorStats | undefined
	history?: ThroughputPoint[]
}) {
	const { t } = useLingui()
	const [expanded, setExpanded] = useState(false)
	const status = deriveHostStatus(system.status, vec)
	const latest = history?.[history.length - 1]

	const byIn = useMemo(() => history?.map((p) => p.receivedBytesRate) ?? [], [history])
	const byOut = useMemo(() => history?.map((p) => p.sentBytesRate) ?? [], [history])

	return (
		<Card>
			<CardHeader className="pb-4">
				<div className="flex items-start justify-between gap-4 flex-wrap">
					<div>
						<CardTitle className="text-xl flex items-center gap-2">
							{system.name}
							<span
								title={status === "no-data" ? NO_DATA_HINT : undefined}
								className={cn(
									"inline-flex items-center gap-1.5 px-2 py-0.5 rounded border text-xs font-medium",
									STATUS_CLASS[status],
									status === "no-data" && "cursor-help",
								)}
							>
								{status === "no-data" && <AlertTriangleIcon className="h-3 w-3" />}
								{status === "down" && <CircleOffIcon className="h-3 w-3" />}
								<span className="uppercase opacity-80">
									{status === "no-data" ? t`no data` : status}
								</span>
							</span>
							{vec?.v && (
								<Badge variant="outline" className="font-mono text-xs">
									v{vec.v}
								</Badge>
							)}
						</CardTitle>
						{vec && (
							<CardDescription className="mt-1">
								{t`${vec.sc ?? 0} sources · ${vec.tc ?? 0} transforms · ${vec.sk ?? 0} sinks`}
								{(vec.e ?? 0) > 0 && (
									<span className="ml-3 text-amber-700">
										{t`${formatNumber(vec.e ?? 0)} errors`}
									</span>
								)}
							</CardDescription>
						)}
					</div>
					{vec && (
						<Button variant="ghost" size="sm" onClick={() => setExpanded((e) => !e)}>
							{expanded ? <ChevronUpIcon className="h-4 w-4" /> : <ChevronDownIcon className="h-4 w-4" />}
							<span className="ml-1">{expanded ? t`Collapse` : t`Expand`}</span>
						</Button>
					)}
				</div>
			</CardHeader>

			{vec && (
				<div className="px-6 pb-6 grid grid-cols-2 md:grid-cols-4 gap-4">
					<Metric
						label={t`Events in/s`}
						value={formatEventsRate(latest?.receivedEventsRate ?? 0)}
						sub={t`${formatNumber(vec.re ?? 0)} total`}
					/>
					<Metric
						label={t`Events out/s`}
						value={formatEventsRate(latest?.sentEventsRate ?? 0)}
						sub={t`${formatNumber(vec.se ?? 0)} total`}
					/>
					<Metric
						label={t`Bytes in/s`}
						value={formatBytesPerSec(latest?.receivedBytesRate ?? 0)}
						sub={formatBytes(vec.rb ?? 0)}
						sparkline={byIn}
						color="#3b82f6"
					/>
					<Metric
						label={t`Bytes out/s`}
						value={formatBytesPerSec(latest?.sentBytesRate ?? 0)}
						sub={formatBytes(vec.sb ?? 0)}
						sparkline={byOut}
						color="#22c55e"
					/>
				</div>
			)}

			{expanded && vec?.co && vec.co.length > 0 && <ComponentTable components={vec.co} />}
		</Card>
	)
})

function Metric({
	label,
	value,
	sub,
	sparkline,
	color,
}: {
	label: string
	value: string
	sub?: string
	sparkline?: number[]
	color?: string
}) {
	return (
		<div>
			<p className="text-xs text-muted-foreground">{label}</p>
			<div className="flex items-center gap-2 mt-1">
				<p className="text-lg font-semibold tabular-nums">{value}</p>
				{sparkline && color && <Sparkline data={sparkline} color={color} />}
			</div>
			{sub && <p className="text-xs text-muted-foreground tabular-nums">{sub}</p>}
		</div>
	)
}

const KIND_BADGE: Record<string, string> = {
	source: "bg-blue-500/20 text-blue-700 border-blue-500/40",
	transform: "bg-purple-500/20 text-purple-700 border-purple-500/40",
	sink: "bg-green-500/20 text-green-700 border-green-500/40",
}

function ComponentTable({ components }: { components: VectorComponent[] }) {
	const { t } = useLingui()
	const sorted = useMemo(() => {
		const order: Record<string, number> = { source: 0, transform: 1, sink: 2 }
		return [...components].sort((a, b) => {
			const ka = order[a.k] ?? 3
			const kb = order[b.k] ?? 3
			if (ka !== kb) return ka - kb
			return a.i.localeCompare(b.i)
		})
	}, [components])
	return (
		<div className="px-6 pb-6 overflow-x-auto">
			<table className="w-full text-sm">
				<thead>
					<tr className="text-left text-xs text-muted-foreground border-b">
						<th className="py-2 pr-3">{t`Component`}</th>
						<th className="py-2 pr-3">{t`Kind`}</th>
						<th className="py-2 pr-3">{t`Type`}</th>
						<th className="py-2 pr-3 text-right">{t`Received events`}</th>
						<th className="py-2 pr-3 text-right">{t`Sent events`}</th>
						<th className="py-2 pr-3 text-right">{t`Received bytes`}</th>
						<th className="py-2 pr-3 text-right">{t`Sent bytes`}</th>
						<th className="py-2 pr-3 text-right">{t`Errors`}</th>
					</tr>
				</thead>
				<tbody>
					{sorted.map((c) => {
						const errors = c.e ?? 0
						return (
							<tr key={c.i} className={cn("border-b last:border-0", errors > 0 && "bg-amber-500/5")}>
								<td className="py-2 pr-3 font-mono text-xs">{c.i}</td>
								<td className="py-2 pr-3">
									<span
										className={cn(
											"inline-block px-1.5 py-0.5 rounded border text-[10px] font-medium uppercase",
											KIND_BADGE[c.k] ?? "bg-gray-500/20 text-gray-700 border-gray-500/40",
										)}
									>
										{c.k}
									</span>
								</td>
								<td className="py-2 pr-3 text-xs text-muted-foreground">{c.t}</td>
								<td className="py-2 pr-3 text-right tabular-nums">
									{c.k === "sink" ? "—" : formatNumber(c.re ?? 0)}
								</td>
								<td className="py-2 pr-3 text-right tabular-nums">
									{c.k === "source" ? "—" : formatNumber(c.se ?? 0)}
								</td>
								<td className="py-2 pr-3 text-right tabular-nums text-xs">
									{c.k === "sink" ? "—" : formatBytes(c.rb ?? 0)}
								</td>
								<td className="py-2 pr-3 text-right tabular-nums text-xs">
									{c.k === "source" ? "—" : formatBytes(c.sb ?? 0)}
								</td>
								<td
									className={cn(
										"py-2 pr-3 text-right tabular-nums",
										errors > 0 && "text-amber-700 font-medium",
									)}
								>
									{formatNumber(errors)}
								</td>
							</tr>
						)
					})}
				</tbody>
			</table>
		</div>
	)
}
