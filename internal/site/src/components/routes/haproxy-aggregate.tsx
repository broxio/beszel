import { useLingui } from "@lingui/react/macro"
import { memo, useEffect, useMemo, useRef, useState } from "react"
import { Bar, BarChart, Cell, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"
import { pb } from "@/lib/api"
import { $systems } from "@/lib/stores"
import {
	calculateGroupAggregates,
	extractHAProxyData,
	filterHAProxySystems,
	formatBytesPerSec,
	formatNumber,
	groupSystemsByPattern,
	type GroupAggregates,
} from "@/lib/haproxy-aggregate"
import type { SystemRecord, SystemStats, SystemStatsRecord } from "@/types"
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { FooterRepoLink } from "@/components/footer-repo-link"
import { Button } from "@/components/ui/button"
import { ChevronDownIcon, ChevronUpIcon, RefreshCwIcon, ServerIcon } from "lucide-react"
import { cn } from "@/lib/utils"

// Colors for HTTP response codes
const RESPONSE_COLORS = {
	"2xx": "#22c55e", // green
	"3xx": "#3b82f6", // blue
	"4xx": "#eab308", // yellow
	"5xx": "#ef4444", // red
	"1xx": "#6b7280", // gray
}

const POLL_INTERVAL = 10000 // 10 seconds

export default memo(function HAProxyAggregatePage() {
	const { t } = useLingui()
	const [statsMap, setStatsMap] = useState<Map<string, SystemStats>>(new Map())
	const [loading, setLoading] = useState(false)
	const [lastUpdate, setLastUpdate] = useState<Date | null>(null)

	// Get systems only once on mount to avoid re-renders from store updates
	const [haproxySystems, setHaproxySystems] = useState<SystemRecord[]>([])

	// Refs for polling
	const mountedRef = useRef(true)
	const fetchingRef = useRef(false)
	const systemsRef = useRef<SystemRecord[]>([])

	// Initialize systems on mount
	useEffect(() => {
		const allSystems = $systems.get()
		const filtered = filterHAProxySystems(allSystems)
		setHaproxySystems(filtered)
		systemsRef.current = filtered
	}, [])

	// Fetch stats for all systems in a single batched request
	const fetchStats = async () => {
		const systems = systemsRef.current
		if (systems.length === 0 || fetchingRef.current || !mountedRef.current) return

		fetchingRef.current = true

		try {
			// Build OR filter for all system IDs to fetch in one request
			const systemIds = systems.map((s) => s.id)

			// Fetch latest stats for all systems in one query
			// Use a large page size and sort by created desc, then dedupe client-side
			const filter = systemIds.map((id) => `system="${id}"`).join("||")

			const records = await pb.collection<SystemStatsRecord>("system_stats").getList(1, systemIds.length * 2, {
				filter,
				sort: "-created",
				fields: "system,stats,created",
			})

			// Dedupe to get only the latest record per system
			const newStatsMap = new Map<string, SystemStats>()
			const seen = new Set<string>()

			for (const record of records.items) {
				if (!seen.has(record.system) && record.stats) {
					newStatsMap.set(record.system, record.stats)
					seen.add(record.system)
				}
			}

			if (mountedRef.current) {
				setStatsMap(newStatsMap)
				setLastUpdate(new Date())
			}
		} catch (err) {
			console.error("Failed to fetch HAProxy stats:", err)
		} finally {
			fetchingRef.current = false
			if (mountedRef.current) {
				setLoading(false)
			}
		}
	}

	// Setup polling
	useEffect(() => {
		mountedRef.current = true

		// Initial fetch after short delay
		const initialTimer = setTimeout(() => {
			fetchStats()
		}, 300)

		// Poll every 10 seconds
		const pollTimer = setInterval(() => {
			fetchStats()
		}, POLL_INTERVAL)

		return () => {
			mountedRef.current = false
			clearTimeout(initialTimer)
			clearInterval(pollTimer)
		}
	}, [])

	// Group by pattern
	const groups = useMemo(() => groupSystemsByPattern(haproxySystems), [haproxySystems])

	// Calculate aggregates per group
	const groupAggregates = useMemo(() => {
		const result = new Map<string, GroupAggregates>()

		for (const [groupName, groupSystems] of groups) {
			const groupStatsMap = new Map<string, SystemStats>()
			for (const sys of groupSystems) {
				const stats = statsMap.get(sys.id)
				if (stats) {
					groupStatsMap.set(sys.id, stats)
				}
			}

			if (groupStatsMap.size > 0) {
				const { statsPerSystem, infosPerSystem } = extractHAProxyData(groupStatsMap)
				if (statsPerSystem.size > 0) {
					const aggregates = calculateGroupAggregates(statsPerSystem, infosPerSystem)
					result.set(groupName, aggregates)
				}
			}
		}

		return result
	}, [groups, statsMap])

	// Set page title
	useEffect(() => {
		document.title = `${t`HAProxy Aggregate`} / Beszel`
	}, [t])

	// Manual refresh handler
	const handleRefresh = () => {
		if (loading) return
		setLoading(true)
		fetchStats()
	}

	// Show empty state if no HA systems
	if (haproxySystems.length === 0) {
		return (
			<div className="grid gap-4">
				<Card className="p-6">
					<div className="flex flex-col items-center justify-center gap-4 text-center">
						<ServerIcon className="h-12 w-12 text-muted-foreground/50" />
						<div>
							<h3 className="text-lg font-medium">{t`No HAProxy Systems Found`}</h3>
							<p className="text-muted-foreground mt-1">
								{t`No systems matching the "ha-*" pattern were found.`}
							</p>
							<p className="text-muted-foreground text-sm mt-2">
								{t`HAProxy systems should be named like "ha-web-1", "ha-api-2", etc.`}
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
			{/* Header */}
			<Card>
				<div className="flex items-center justify-between px-4 sm:px-6 py-4">
					<div>
						<h1 className="text-[1.6rem] font-semibold">{t`HAProxy Aggregate`}</h1>
						<p className="text-sm text-muted-foreground mt-1">
							{t`Aggregated statistics from ${haproxySystems.length} HAProxy systems in ${groups.size} groups`}
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

			{/* Summary Cards */}
			<SummaryCards groups={groups} aggregates={groupAggregates} />

			{/* Group Cards */}
			{Array.from(groups.entries())
				.sort(([a], [b]) => a.localeCompare(b))
				.map(([groupName, groupSystems]) => (
					<GroupCard
						key={groupName}
						groupName={groupName}
						systems={groupSystems}
						aggregates={groupAggregates.get(groupName)}
						statsMap={statsMap}
					/>
				))}

			<FooterRepoLink />
		</div>
	)
})

// Summary cards
const SummaryCards = memo(function SummaryCards({
	groups,
	aggregates,
}: {
	groups: Map<string, SystemRecord[]>
	aggregates: Map<string, GroupAggregates>
}) {
	const { t } = useLingui()

	const grandTotals = useMemo(() => {
		let totalSessions = 0
		let totalBytesIn = 0
		let totalBytesOut = 0
		let totalRequestRate = 0
		let totalSystemCount = 0

		for (const [, agg] of aggregates) {
			totalSessions += agg.totals.currentSessions
			totalBytesIn += agg.totals.bytesInRate
			totalBytesOut += agg.totals.bytesOutRate
			totalRequestRate += agg.totals.requestRate
			totalSystemCount += agg.totals.systemCount
		}

		return {
			sessions: totalSessions,
			bytesIn: totalBytesIn,
			bytesOut: totalBytesOut,
			requestRate: totalRequestRate,
			systemCount: totalSystemCount,
			groupCount: groups.size,
		}
	}, [aggregates, groups])

	return (
		<div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
			<SummaryCard title={t`Groups`} value={grandTotals.groupCount.toString()} />
			<SummaryCard title={t`Systems`} value={grandTotals.systemCount.toString()} />
			<SummaryCard title={t`Sessions`} value={formatNumber(grandTotals.sessions)} />
			<SummaryCard title={t`Request Rate`} value={`${formatNumber(grandTotals.requestRate)}/s`} />
			<SummaryCard title={t`Traffic In`} value={formatBytesPerSec(grandTotals.bytesIn)} />
			<SummaryCard title={t`Traffic Out`} value={formatBytesPerSec(grandTotals.bytesOut)} />
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

// Group card
const GroupCard = memo(function GroupCard({
	groupName,
	systems,
	aggregates,
	statsMap,
}: {
	groupName: string
	systems: SystemRecord[]
	aggregates?: GroupAggregates
	statsMap: Map<string, SystemStats>
}) {
	const { t } = useLingui()
	const [expanded, setExpanded] = useState(false)

	const hasData = aggregates !== undefined

	return (
		<Card>
			<CardHeader className="pb-4">
				<div className="flex items-center justify-between">
					<div>
						<CardTitle className="text-xl">{groupName}</CardTitle>
						<CardDescription>
							{t`${systems.length} systems`}
							{hasData && ` | ${aggregates.totals.activeServers} ${t`active servers`}`}
						</CardDescription>
					</div>
					<Button variant="ghost" size="sm" onClick={() => setExpanded(!expanded)}>
						{expanded ? <ChevronUpIcon className="h-4 w-4" /> : <ChevronDownIcon className="h-4 w-4" />}
						<span className="ml-1">{expanded ? t`Collapse` : t`Expand`}</span>
					</Button>
				</div>
			</CardHeader>

			{hasData ? (
				<div className="px-6 pb-4">
					{/* Primary Stats Row */}
					<div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-8 gap-4 text-sm">
						<StatItem label={t`Sessions`} value={formatNumber(aggregates.totals.currentSessions)} />
						<StatItem label={t`Connections`} value={formatNumber(aggregates.totals.currentConnections)} />
						<StatItem label={t`Request Rate`} value={`${formatNumber(aggregates.totals.requestRate)}/s`} />
						<StatItem label={t`Avg Response`} value={`${aggregates.averages.responseTime.toFixed(1)}ms`} />
						<StatItem label={t`Traffic In`} value={formatBytesPerSec(aggregates.totals.bytesInRate)} />
						<StatItem label={t`Traffic Out`} value={formatBytesPerSec(aggregates.totals.bytesOutRate)} />
						<StatItem label={t`Active Servers`} value={formatNumber(aggregates.totals.activeServers)} />
						<StatItem label={t`Backup Servers`} value={formatNumber(aggregates.totals.backupServers)} />
					</div>

					{/* Totals Row */}
					<div className="mt-4 pt-4 border-t">
						<p className="text-sm text-muted-foreground mb-2">{t`Cumulative Totals`}</p>
						<div className="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
							<StatItem label={t`Total Sessions`} value={formatNumber(aggregates.totals.totalSessions)} />
							<StatItem label={t`Total Requests`} value={formatNumber(aggregates.totals.totalRequests)} />
							<StatItem label={t`Total Connections`} value={formatNumber(aggregates.totals.totalConnections)} />
							<StatItem label={t`Frontends/Backends`} value={`${aggregates.totals.frontendCount}/${aggregates.totals.backendCount}`} />
						</div>
					</div>

					{/* HTTP Responses Row with Bar Chart */}
					<div className="mt-4 pt-4 border-t">
						<p className="text-sm text-muted-foreground mb-2">{t`HTTP Responses (Total)`}</p>
						<div className="grid grid-cols-1 md:grid-cols-2 gap-4">
							{/* Bar Chart */}
							<div className="h-32">
								<ResponseBarChart
									data={[
										{ name: "2xx", value: aggregates.totals.resp2xx, color: RESPONSE_COLORS["2xx"] },
										{ name: "3xx", value: aggregates.totals.resp3xx, color: RESPONSE_COLORS["3xx"] },
										{ name: "4xx", value: aggregates.totals.resp4xx, color: RESPONSE_COLORS["4xx"] },
										{ name: "5xx", value: aggregates.totals.resp5xx, color: RESPONSE_COLORS["5xx"] },
										{ name: "1xx", value: aggregates.totals.resp1xx, color: RESPONSE_COLORS["1xx"] },
									]}
								/>
							</div>
							{/* Numbers */}
							<div className="grid grid-cols-5 gap-2 text-sm content-center">
								<StatItem label="2xx" value={formatNumber(aggregates.totals.resp2xx)} className="text-green-600" />
								<StatItem label="3xx" value={formatNumber(aggregates.totals.resp3xx)} className="text-blue-600" />
								<StatItem label="4xx" value={formatNumber(aggregates.totals.resp4xx)} className="text-yellow-600" />
								<StatItem label="5xx" value={formatNumber(aggregates.totals.resp5xx)} className="text-red-600" />
								<StatItem label="1xx" value={formatNumber(aggregates.totals.resp1xx)} className="text-gray-600" />
							</div>
						</div>
					</div>

					{expanded && (
						<div className="mt-4 pt-4 border-t">
							<p className="text-sm text-muted-foreground mb-3">{t`Individual Systems`}</p>
							<div className="space-y-2">
								{systems.map((system) => {
									const stats = statsMap.get(system.id)
									const hapStats = stats?.hap
									const totalSessions =
										hapStats?.reduce(
											(sum, p) => sum + (p.t === "FRONTEND" || p.t === "BACKEND" ? p.sc : 0),
											0
										) ?? 0

									return (
										<div key={system.id} className="flex items-center justify-between p-2 rounded bg-muted/50">
											<div className="flex items-center gap-2">
												<span
													className={cn("h-2 w-2 rounded-full", {
														"bg-green-500": system.status === "up",
														"bg-red-500": system.status === "down",
														"bg-yellow-500": system.status === "pending",
														"bg-gray-400": system.status === "paused",
													})}
												/>
												<span className="font-medium">{system.name}</span>
											</div>
											<div className="flex items-center gap-4 text-sm text-muted-foreground">
												<span>
													{t`Sessions`}: {totalSessions}
												</span>
												<span className="capitalize">{system.status}</span>
											</div>
										</div>
									)
								})}
							</div>
						</div>
					)}
				</div>
			) : (
				<div className="px-6 pb-4 text-muted-foreground text-sm">{t`Click refresh to load data`}</div>
			)}
		</Card>
	)
})

function StatItem({ label, value, className }: { label: string; value: string; className?: string }) {
	return (
		<div>
			<p className="text-muted-foreground">{label}</p>
			<p className={cn("font-semibold", className)}>{value}</p>
		</div>
	)
}

// Simple bar chart for HTTP response distribution
interface ResponseBarChartProps {
	data: Array<{ name: string; value: number; color: string }>
}

function ResponseBarChart({ data }: ResponseBarChartProps) {
	// Filter out zero values for cleaner display
	const filteredData = data.filter((d) => d.value > 0)

	if (filteredData.length === 0) {
		return <div className="h-full flex items-center justify-center text-muted-foreground text-sm">No data</div>
	}

	return (
		<ResponsiveContainer width="100%" height="100%">
			<BarChart data={filteredData} layout="vertical" margin={{ top: 5, right: 30, left: 20, bottom: 5 }}>
				<XAxis type="number" tickFormatter={(v) => formatNumber(v)} fontSize={11} />
				<YAxis type="category" dataKey="name" fontSize={11} width={30} />
				<Tooltip
					formatter={(value: number) => [formatNumber(value), "Responses"]}
					contentStyle={{
						backgroundColor: "hsl(var(--card))",
						border: "1px solid hsl(var(--border))",
						borderRadius: "6px",
						fontSize: "12px",
					}}
				/>
				<Bar dataKey="value" radius={[0, 4, 4, 0]}>
					{filteredData.map((entry, index) => (
						<Cell key={`cell-${index}`} fill={entry.color} />
					))}
				</Bar>
			</BarChart>
		</ResponsiveContainer>
	)
}
