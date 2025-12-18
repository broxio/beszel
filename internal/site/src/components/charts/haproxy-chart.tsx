import { memo, useMemo } from "react"
import { Area, AreaChart, CartesianGrid, YAxis } from "recharts"
import { ChartContainer, ChartTooltip, ChartTooltipContent, pinnedAxisDomain, xAxis } from "@/components/ui/chart"
import { chartMargin, cn, decimalString, formatShortDate, toFixedFloat } from "@/lib/utils"
import type { ChartData, HAProxyStats } from "@/types"
import { useYAxisWidth } from "./hooks"

type HAProxyChartType = "sessions" | "traffic" | "requests" | "errors" | "response_time"

interface HAProxyChartProps {
	chartData: ChartData
	chartType: HAProxyChartType
	proxyFilter?: string
}

// Generate colors for proxies
function getProxyColor(index: number): string {
	const colors = [
		"hsl(var(--chart-1))",
		"hsl(var(--chart-2))",
		"hsl(var(--chart-3))",
		"hsl(var(--chart-4))",
		"hsl(var(--chart-5))",
		"hsl(200, 70%, 50%)",
		"hsl(280, 70%, 50%)",
		"hsl(30, 70%, 50%)",
		"hsl(160, 70%, 50%)",
		"hsl(320, 70%, 50%)",
	]
	return colors[index % colors.length]
}

export default memo(function HAProxyChart({ chartData, chartType, proxyFilter }: HAProxyChartProps) {
	const { yAxisWidth, updateYAxisWidth } = useYAxisWidth()
	const { systemStats } = chartData

	// Get unique proxy names from latest data
	const proxyNames = useMemo(() => {
		const lastStats = systemStats.at(-1)?.stats?.hap
		if (!lastStats) return []

		const names = new Set<string>()
		for (const proxy of lastStats) {
			// Response time is only available for backends
			if (chartType === "response_time") {
				if (proxy.t === "BACKEND") {
					names.add(proxy.n)
				}
			} else {
				// Only include frontends and backends, not individual servers
				if (proxy.t === "FRONTEND" || proxy.t === "BACKEND") {
					names.add(proxy.n)
				}
			}
		}
		return Array.from(names)
	}, [systemStats, chartType])

	// Build chart config
	const chartConfig = useMemo(() => {
		const config: Record<string, { label: string; color: string }> = {}
		proxyNames.forEach((name, i) => {
			config[name] = {
				label: name,
				color: getProxyColor(i),
			}
		})
		return config
	}, [proxyNames])

	// Data accessor based on chart type
	const getDataValue = useMemo(() => {
		switch (chartType) {
			case "sessions":
				return (proxy: HAProxyStats) => proxy.sc
			case "traffic":
				// Use rate fields (bytes per second) instead of cumulative bytes
				return (proxy: HAProxyStats) => (proxy.bir ?? 0) + (proxy.bor ?? 0)
			case "requests":
				return (proxy: HAProxyStats) => proxy.rr ?? 0
			case "errors":
				// Use rate fields (errors per second) instead of cumulative
				return (proxy: HAProxyStats) => (proxy.r4r ?? 0) + (proxy.r5r ?? 0)
			case "response_time":
				return (proxy: HAProxyStats) => proxy.rsp ?? 0
		}
	}, [chartType])

	// Tick formatter based on chart type
	const tickFormatter = useMemo(() => {
		switch (chartType) {
			case "sessions":
				return (val: number) => {
					const formatted = `${toFixedFloat(val, 0)}`
					return updateYAxisWidth(formatted)
				}
			case "traffic":
				// Show bytes per second with appropriate unit
				return (val: number) => {
					const kb = val / 1024
					const mb = kb / 1024
					if (mb >= 1) {
						return updateYAxisWidth(`${toFixedFloat(mb, 1)} MB/s`)
					}
					if (kb >= 1) {
						return updateYAxisWidth(`${toFixedFloat(kb, 0)} KB/s`)
					}
					return updateYAxisWidth(`${toFixedFloat(val, 0)} B/s`)
				}
			case "requests":
				return (val: number) => {
					const formatted = `${toFixedFloat(val, 0)}/s`
					return updateYAxisWidth(formatted)
				}
			case "errors":
				return (val: number) => {
					const formatted = `${toFixedFloat(val, 0)}/s`
					return updateYAxisWidth(formatted)
				}
			case "response_time":
				return (val: number) => {
					if (val >= 1000) {
						return updateYAxisWidth(`${toFixedFloat(val / 1000, 1)}s`)
					}
					return updateYAxisWidth(`${toFixedFloat(val, 0)}ms`)
				}
		}
	}, [chartType, updateYAxisWidth])

	// Tooltip formatter
	const tooltipFormatter = useMemo(() => {
		switch (chartType) {
			case "sessions":
				return (item: any) => `${decimalString(item.value)} sessions`
			case "traffic":
				// Show bytes per second with appropriate unit
				return (item: any) => {
					const bytes = item.value
					const kb = bytes / 1024
					const mb = kb / 1024
					if (mb >= 1) {
						return `${decimalString(mb)} MB/s`
					}
					if (kb >= 1) {
						return `${decimalString(kb)} KB/s`
					}
					return `${decimalString(bytes)} B/s`
				}
			case "requests":
				return (item: any) => `${decimalString(item.value)} req/s`
			case "errors":
				return (item: any) => `${decimalString(item.value)} err/s`
			case "response_time":
				return (item: any) => {
					const ms = item.value
					if (ms >= 1000) {
						return `${decimalString(ms / 1000)}s`
					}
					return `${decimalString(ms)}ms`
				}
		}
	}, [chartType])

	// Filter function
	const filteredKeys = useMemo(() => {
		if (!proxyFilter) return new Set<string>()
		const filterTerms = proxyFilter.toLowerCase().split(" ").filter((term) => term.length > 0)
		return new Set(
			proxyNames.filter((name) => {
				const nameLower = name.toLowerCase()
				return !filterTerms.some((term) => nameLower.includes(term))
			})
		)
	}, [proxyNames, proxyFilter])

	if (systemStats.length === 0 || proxyNames.length === 0) {
		return null
	}

	return (
		<div>
			<ChartContainer
				className={cn("h-full w-full absolute aspect-auto bg-card opacity-0 transition-opacity", {
					"opacity-100": yAxisWidth,
				})}
			>
				<AreaChart accessibilityLayer data={systemStats} margin={chartMargin} reverseStackOrder={true}>
					<CartesianGrid vertical={false} />
					<YAxis
						direction="ltr"
						domain={pinnedAxisDomain()}
						orientation={chartData.orientation}
						className="tracking-tighter"
						width={yAxisWidth}
						tickFormatter={tickFormatter}
						tickLine={false}
						axisLine={false}
					/>
					{xAxis(chartData)}
					<ChartTooltip
						animationEasing="ease-out"
						animationDuration={150}
						truncate={true}
						labelFormatter={(_, data) => formatShortDate(data[0].payload.created)}
						content={<ChartTooltipContent contentFormatter={tooltipFormatter} showTotal={chartType === "sessions"} />}
					/>
					{proxyNames.map((name) => {
						const filtered = filteredKeys.has(name)
						const fillOpacity = filtered ? 0.05 : 0.4
						const strokeOpacity = filtered ? 0.1 : 1
						// Response time: only backends, no stacking
						const proxyTypeFilter = chartType === "response_time"
							? (p: HAProxyStats) => p.t === "BACKEND"
							: (p: HAProxyStats) => p.t === "FRONTEND" || p.t === "BACKEND"
						return (
							<Area
								key={name}
								isAnimationActive={false}
								dataKey={({ stats }) => {
									const proxy = stats?.hap?.find((p: HAProxyStats) => p.n === name && proxyTypeFilter(p))
									return proxy ? getDataValue(proxy) : null
								}}
								name={name}
								type="monotoneX"
								fill={chartConfig[name]?.color}
								fillOpacity={fillOpacity}
								stroke={chartConfig[name]?.color}
								strokeOpacity={strokeOpacity}
								activeDot={{ opacity: filtered ? 0 : 1 }}
								stackId={chartType === "response_time" ? undefined : "a"}
							/>
						)
					})}
				</AreaChart>
			</ChartContainer>
		</div>
	)
})
