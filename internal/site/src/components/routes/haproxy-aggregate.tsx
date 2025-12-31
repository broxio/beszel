import { useLingui } from "@lingui/react/macro"
import { memo, useEffect, useMemo, useRef, useState } from "react"
import { Bar, BarChart, Cell, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"
import { pb } from "@/lib/api"
import { $systems } from "@/lib/stores"
import {
	calculateGroupAggregates,
	extractHAProxyData,
	extractPreGroup,
	filterHAProxySystems,
	formatBytesPerSec,
	formatNumber,
	groupByPreGroup,
	groupSystemsByPattern,
	type GroupAggregates,
	type PreGroupType,
} from "@/lib/haproxy-aggregate"
import type { SystemRecord, SystemStats, SystemStatsRecord } from "@/types"
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { FooterRepoLink } from "@/components/footer-repo-link"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { ChevronDownIcon, ChevronUpIcon, RefreshCwIcon, ServerIcon, FilterIcon, LayersIcon } from "lucide-react"
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
const HISTORY_LENGTH = 30 // Keep last 30 data points (5 minutes at 10s intervals)

// Traffic history data point
interface TrafficDataPoint {
	bytesIn: number
	bytesOut: number
	timestamp: number
}

// Traffic history per group
type TrafficHistory = Map<string, TrafficDataPoint[]>

// Pre-group display configuration
const PRE_GROUP_CONFIG: Record<PreGroupType, { label: string; color: string }> = {
	pre: { label: "PRE", color: "bg-orange-500 hover:bg-orange-600" },
	uat: { label: "UAT", color: "bg-purple-500 hover:bg-purple-600" },
	lan: { label: "LAN", color: "bg-blue-500 hover:bg-blue-600" },
	wan: { label: "WAN", color: "bg-green-500 hover:bg-green-600" },
}

export default memo(function HAProxyAggregatePage() {
	const { t } = useLingui()
	const [statsMap, setStatsMap] = useState<Map<string, SystemStats>>(new Map())
	const [loading, setLoading] = useState(false)
	const [lastUpdate, setLastUpdate] = useState<Date | null>(null)
	const [selectedGroups, setSelectedGroups] = useState<Set<string>>(new Set())
	const [selectedPreGroups, setSelectedPreGroups] = useState<Set<PreGroupType>>(new Set())

	// Get systems only once on mount to avoid re-renders from store updates
	const [haproxySystems, setHaproxySystems] = useState<SystemRecord[]>([])

	// Refs for polling
	const mountedRef = useRef(true)
	const fetchingRef = useRef(false)
	const systemsRef = useRef<SystemRecord[]>([])

	// Traffic history for sparklines (ref to avoid re-renders during accumulation)
	const trafficHistoryRef = useRef<TrafficHistory>(new Map())
	const [trafficHistory, setTrafficHistory] = useState<TrafficHistory>(new Map())

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

	// Group groups by pre-group type (pre, uat, lan, wan)
	const preGroups = useMemo(() => groupByPreGroup(groups), [groups])

	// Calculate aggregates per group (only systems with HAProxy data)
	const { groupAggregates, groupStats } = useMemo(() => {
		const aggregates = new Map<string, GroupAggregates>()
		const stats = new Map<string, { online: number; offline: number; total: number }>()

		for (const [groupName, groupSystems] of groups) {
			const groupStatsMap = new Map<string, SystemStats>()
			let onlineCount = 0
			let offlineCount = 0

			for (const sys of groupSystems) {
				const sysStats = statsMap.get(sys.id)
				// Only include if system has HAProxy data (hap array with items)
				if (sysStats?.hap && sysStats.hap.length > 0) {
					groupStatsMap.set(sys.id, sysStats)
					onlineCount++
				} else {
					offlineCount++
				}
			}

			stats.set(groupName, {
				online: onlineCount,
				offline: offlineCount,
				total: groupSystems.length,
			})

			if (groupStatsMap.size > 0) {
				const { statsPerSystem, infosPerSystem } = extractHAProxyData(groupStatsMap)
				if (statsPerSystem.size > 0) {
					const agg = calculateGroupAggregates(statsPerSystem, infosPerSystem)
					aggregates.set(groupName, agg)
				}
			}
		}

		return { groupAggregates: aggregates, groupStats: stats }
	}, [groups, statsMap])

	// Update traffic history when aggregates change
	useEffect(() => {
		if (groupAggregates.size === 0) return

		const now = Date.now()
		const historyMap = trafficHistoryRef.current

		for (const [groupName, agg] of groupAggregates) {
			let history = historyMap.get(groupName)
			if (!history) {
				history = []
				historyMap.set(groupName, history)
			}

			history.push({
				bytesIn: agg.totals.bytesInRate,
				bytesOut: agg.totals.bytesOutRate,
				timestamp: now,
			})

			// Keep only last N data points
			if (history.length > HISTORY_LENGTH) {
				history.shift()
			}
		}

		// Update state to trigger re-render with new history
		setTrafficHistory(new Map(historyMap))
	}, [groupAggregates])

	// Filter groups based on selection (empty = show all)
	// Pre-groups take precedence: if any pre-group is selected, filter by pre-group first
	const filteredGroups = useMemo(() => {
		// If no filters at all, show everything
		if (selectedPreGroups.size === 0 && selectedGroups.size === 0) return groups

		const filtered = new Map<string, SystemRecord[]>()

		for (const [name, systems] of groups) {
			const groupPreGroup = extractPreGroup(name)

			// If pre-groups are selected, check if this group belongs to any selected pre-group
			if (selectedPreGroups.size > 0) {
				if (!selectedPreGroups.has(groupPreGroup)) continue
			}

			// If individual groups are also selected, further filter
			if (selectedGroups.size > 0) {
				if (!selectedGroups.has(name)) continue
			}

			filtered.set(name, systems)
		}

		return filtered
	}, [groups, selectedGroups, selectedPreGroups])

	// Toggle group selection
	const toggleGroup = (groupName: string) => {
		setSelectedGroups((prev) => {
			const next = new Set(prev)
			if (next.has(groupName)) {
				next.delete(groupName)
			} else {
				next.add(groupName)
			}
			return next
		})
	}

	// Toggle pre-group selection
	const togglePreGroup = (preGroupType: PreGroupType) => {
		setSelectedPreGroups((prev) => {
			const next = new Set(prev)
			if (next.has(preGroupType)) {
				next.delete(preGroupType)
			} else {
				next.add(preGroupType)
			}
			return next
		})
		// Clear individual group selection when pre-group changes
		setSelectedGroups(new Set())
	}

	// Clear all selections
	const clearAllSelections = () => {
		setSelectedGroups(new Set())
		setSelectedPreGroups(new Set())
	}

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

	// Calculate total online/offline
	const totalOnline = Array.from(groupStats.values()).reduce((sum, s) => sum + s.online, 0)
	const totalOffline = Array.from(groupStats.values()).reduce((sum, s) => sum + s.offline, 0)

	return (
		<div className="grid gap-4 mb-14">
			{/* Header */}
			<Card>
				<div className="flex items-center justify-between px-4 sm:px-6 py-4">
					<div>
						<h1 className="text-[1.6rem] font-semibold">{t`HAProxy Aggregate`}</h1>
						<p className="text-sm text-muted-foreground mt-1">
							{t`${totalOnline} online, ${totalOffline} offline across ${groups.size} groups`}
							{(selectedPreGroups.size > 0 || selectedGroups.size > 0) && (
								<span className="ml-1">
									({selectedPreGroups.size > 0 && `${selectedPreGroups.size} zone`}
									{selectedPreGroups.size > 0 && selectedGroups.size > 0 && ", "}
									{selectedGroups.size > 0 && `${selectedGroups.size} group`}
									{" "}{t`selected`})
								</span>
							)}
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

				{/* Pre-Group Filter (Zone/Environment) */}
				{groups.size > 0 && (
					<div className="px-4 sm:px-6 pb-4 border-t pt-4">
						<div className="flex items-center gap-2 mb-2">
							<LayersIcon className="h-4 w-4 text-muted-foreground" />
							<span className="text-sm text-muted-foreground">{t`Filter by zone:`}</span>
							{(selectedPreGroups.size > 0 || selectedGroups.size > 0) && (
								<Button variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={clearAllSelections}>
									{t`Clear All`}
								</Button>
							)}
						</div>
						<div className="flex flex-wrap gap-2">
							{(["pre", "uat", "lan", "wan"] as PreGroupType[]).map((preGroupType) => {
								const groupList = preGroups.get(preGroupType) || []
								if (groupList.length === 0) return null

								const isSelected = selectedPreGroups.has(preGroupType)
								const config = PRE_GROUP_CONFIG[preGroupType]

								// Calculate totals for this pre-group
								let totalOnlineInPreGroup = 0
								let totalSystemsInPreGroup = 0
								for (const gName of groupList) {
									const stats = groupStats.get(gName)
									if (stats) {
										totalOnlineInPreGroup += stats.online
										totalSystemsInPreGroup += stats.total
									}
								}

								return (
									<Badge
										key={preGroupType}
										variant="default"
										className={cn(
											"cursor-pointer transition-colors text-white",
											isSelected ? config.color : "bg-muted-foreground/30 hover:bg-muted-foreground/50"
										)}
										onClick={() => togglePreGroup(preGroupType)}
									>
										{config.label}
										<span className="ml-1 opacity-80">
											({totalOnlineInPreGroup}/{totalSystemsInPreGroup})
										</span>
									</Badge>
								)
							})}
						</div>
					</div>
				)}

				{/* Group Filter */}
				{groups.size > 0 && (
					<div className="px-4 sm:px-6 pb-4 border-t pt-4">
						<div className="flex items-center gap-2 mb-2">
							<FilterIcon className="h-4 w-4 text-muted-foreground" />
							<span className="text-sm text-muted-foreground">{t`Filter groups:`}</span>
						</div>
						<div className="flex flex-wrap gap-2">
							{Array.from(groups.keys())
								.sort()
								.map((groupName) => {
									const groupPreGroup = extractPreGroup(groupName)
									const isSelected = selectedGroups.has(groupName)
									const isInSelectedPreGroup = selectedPreGroups.size === 0 || selectedPreGroups.has(groupPreGroup)
									const stats = groupStats.get(groupName)
									const hasOffline = stats && stats.offline > 0

									// Dim groups that are not in selected pre-groups
									if (!isInSelectedPreGroup) {
										return (
											<Badge
												key={groupName}
												variant="outline"
												className="cursor-not-allowed opacity-30"
											>
												{groupName}
											</Badge>
										)
									}

									return (
										<Badge
											key={groupName}
											variant={(selectedGroups.size === 0 && selectedPreGroups.size === 0) || isSelected ? "default" : "outline"}
											className={cn(
												"cursor-pointer transition-colors",
												(selectedGroups.size === 0 && selectedPreGroups.size === 0) || isSelected
													? "bg-primary hover:bg-primary/80"
													: "hover:bg-muted"
											)}
											onClick={() => toggleGroup(groupName)}
										>
											{groupName}
											{stats && (
												<span className="ml-1 opacity-70">
													({stats.online}{hasOffline && `/${stats.total}`})
												</span>
											)}
										</Badge>
									)
								})}
						</div>
					</div>
				)}

			</Card>

			{/* Summary Cards */}
			<SummaryCards groups={filteredGroups} aggregates={groupAggregates} trafficHistory={trafficHistory} />

			{/* Group Cards */}
			{Array.from(filteredGroups.entries())
				.sort(([a], [b]) => a.localeCompare(b))
				.map(([groupName, groupSystems]) => (
					<GroupCard
						key={groupName}
						groupName={groupName}
						systems={groupSystems}
						aggregates={groupAggregates.get(groupName)}
						statsMap={statsMap}
						groupStats={groupStats.get(groupName)}
						trafficHistory={trafficHistory.get(groupName)}
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
	trafficHistory,
}: {
	groups: Map<string, SystemRecord[]>
	aggregates: Map<string, GroupAggregates>
	trafficHistory: TrafficHistory
}) {
	const { t } = useLingui()

	// Calculate grand totals and combined traffic history
	const { grandTotals, combinedHistory } = useMemo(() => {
		let totalSessions = 0
		let totalBytesIn = 0
		let totalBytesOut = 0
		let totalRequestRate = 0
		let totalSystemCount = 0

		// Combine traffic history from all filtered groups
		const historyByTimestamp = new Map<number, { bytesIn: number; bytesOut: number }>()

		// Only sum aggregates for groups that are in the filtered groups map
		for (const groupName of groups.keys()) {
			const agg = aggregates.get(groupName)
			if (agg) {
				totalSessions += agg.totals.currentSessions
				totalBytesIn += agg.totals.bytesInRate
				totalBytesOut += agg.totals.bytesOutRate
				totalRequestRate += agg.totals.requestRate
				totalSystemCount += agg.totals.systemCount
			}

			// Combine traffic history for this group
			const groupHistory = trafficHistory.get(groupName)
			if (groupHistory) {
				for (const point of groupHistory) {
					const existing = historyByTimestamp.get(point.timestamp)
					if (existing) {
						existing.bytesIn += point.bytesIn
						existing.bytesOut += point.bytesOut
					} else {
						historyByTimestamp.set(point.timestamp, {
							bytesIn: point.bytesIn,
							bytesOut: point.bytesOut,
						})
					}
				}
			}
		}

		// Sort by timestamp and extract arrays
		const sortedHistory = Array.from(historyByTimestamp.entries())
			.sort(([a], [b]) => a - b)
			.map(([, data]) => data)

		return {
			grandTotals: {
				sessions: totalSessions,
				bytesIn: totalBytesIn,
				bytesOut: totalBytesOut,
				requestRate: totalRequestRate,
				systemCount: totalSystemCount,
				groupCount: groups.size,
			},
			combinedHistory: sortedHistory,
		}
	}, [aggregates, groups, trafficHistory])

	const bytesInHistory = combinedHistory.map((d) => d.bytesIn)
	const bytesOutHistory = combinedHistory.map((d) => d.bytesOut)

	return (
		<div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
			<SummaryCard title={t`Groups`} value={grandTotals.groupCount.toString()} />
			<SummaryCard title={t`Systems`} value={grandTotals.systemCount.toString()} />
			<SummaryCard title={t`Sessions`} value={formatNumber(grandTotals.sessions)} />
			<SummaryCard title={t`Request Rate`} value={`${formatNumber(grandTotals.requestRate)}/s`} />
			<SummaryCardWithSparkline
				title={t`Traffic In`}
				value={formatBytesPerSec(grandTotals.bytesIn)}
				history={bytesInHistory}
				color="#22c55e"
			/>
			<SummaryCardWithSparkline
				title={t`Traffic Out`}
				value={formatBytesPerSec(grandTotals.bytesOut)}
				history={bytesOutHistory}
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
				<Sparkline data={history} color={color} width={60} height={20} />
			</div>
		</Card>
	)
}

// Group card
const GroupCard = memo(function GroupCard({
	groupName,
	systems,
	aggregates,
	statsMap,
	groupStats,
	trafficHistory,
}: {
	groupName: string
	systems: SystemRecord[]
	aggregates?: GroupAggregates
	statsMap: Map<string, SystemStats>
	groupStats?: { online: number; offline: number; total: number }
	trafficHistory?: TrafficDataPoint[]
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
							{groupStats ? (
								<>
									<span className="text-green-600">{groupStats.online} {t`online`}</span>
									{groupStats.offline > 0 && (
										<span className="text-red-500 ml-2">{groupStats.offline} {t`offline`}</span>
									)}
								</>
							) : (
								t`${systems.length} systems`
							)}
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
					<div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4 text-sm">
						<StatItem label={t`Sessions`} value={formatNumber(aggregates.totals.currentSessions)} />
						<StatItem label={t`Connections`} value={formatNumber(aggregates.totals.currentConnections)} />
						<StatItem label={t`Request Rate`} value={`${formatNumber(aggregates.totals.requestRate)}/s`} />
						<StatItem label={t`Avg Response`} value={`${aggregates.averages.responseTime.toFixed(1)}ms`} />
						<StatItem label={t`Active Servers`} value={formatNumber(aggregates.totals.activeServers)} />
						<StatItem label={t`Backup Servers`} value={formatNumber(aggregates.totals.backupServers)} />
					</div>

					{/* Traffic with Sparklines */}
					<div className="mt-4 pt-4 border-t">
						<p className="text-sm text-muted-foreground mb-2">{t`Traffic`}</p>
						<div className="flex flex-wrap gap-6">
							<TrafficStatItem
								label={t`In`}
								value={formatBytesPerSec(aggregates.totals.bytesInRate)}
								history={trafficHistory?.map((d) => d.bytesIn) || []}
								color="#22c55e"
							/>
							<TrafficStatItem
								label={t`Out`}
								value={formatBytesPerSec(aggregates.totals.bytesOutRate)}
								history={trafficHistory?.map((d) => d.bytesOut) || []}
								color="#3b82f6"
							/>
						</div>
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
									const hasHAProxyData = hapStats && hapStats.length > 0
									const totalSessions = hasHAProxyData
										? hapStats.reduce(
												(sum, p) => sum + (p.t === "FRONTEND" || p.t === "BACKEND" ? p.sc : 0),
												0
											)
										: 0

									return (
										<div
											key={system.id}
											className={cn(
												"flex items-center justify-between p-2 rounded",
												hasHAProxyData ? "bg-muted/50" : "bg-red-500/10"
											)}
										>
											<div className="flex items-center gap-2">
												<span
													className={cn("h-2 w-2 rounded-full", {
														"bg-green-500": hasHAProxyData && system.status === "up",
														"bg-red-500": !hasHAProxyData || system.status === "down",
														"bg-yellow-500": system.status === "pending",
														"bg-gray-400": system.status === "paused",
													})}
												/>
												<span className="font-medium">{system.name}</span>
												{!hasHAProxyData && (
													<span className="text-xs text-red-500">({t`HAProxy offline`})</span>
												)}
											</div>
											<div className="flex items-center gap-4 text-sm text-muted-foreground">
												{hasHAProxyData ? (
													<span>{t`Sessions`}: {totalSessions}</span>
												) : (
													<span className="text-red-500">{t`No data`}</span>
												)}
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

// Sparkline component for traffic trends
interface SparklineProps {
	data: number[]
	color?: string
	height?: number
	width?: number
}

function Sparkline({ data, color = "#3b82f6", height = 24, width = 80 }: SparklineProps) {
	if (data.length < 2) {
		return (
			<div
				className="flex items-center justify-center text-muted-foreground text-xs"
				style={{ width, height }}
			>
				--
			</div>
		)
	}

	const min = Math.min(...data)
	const max = Math.max(...data)
	const range = max - min || 1

	// Generate SVG path
	const points = data.map((value, index) => {
		const x = (index / (data.length - 1)) * width
		const y = height - ((value - min) / range) * (height - 4) - 2
		return `${x},${y}`
	})

	const pathD = `M ${points.join(" L ")}`

	return (
		<svg width={width} height={height} className="inline-block">
			<path
				d={pathD}
				fill="none"
				stroke={color}
				strokeWidth={1.5}
				strokeLinecap="round"
				strokeLinejoin="round"
			/>
		</svg>
	)
}

// Traffic stat item with sparkline
interface TrafficStatItemProps {
	label: string
	value: string
	history: number[]
	color: string
}

function TrafficStatItem({ label, value, history, color }: TrafficStatItemProps) {
	return (
		<div className="flex items-center gap-2">
			<div className="min-w-[80px]">
				<p className="text-muted-foreground text-xs">{label}</p>
				<p className="font-semibold">{value}</p>
			</div>
			<Sparkline data={history} color={color} />
		</div>
	)
}
