import { memo, useMemo } from "react"
import { Area, AreaChart, CartesianGrid, YAxis } from "recharts"
import {
	ChartContainer,
	ChartLegend,
	ChartLegendContent,
	ChartTooltip,
	ChartTooltipContent,
	pinnedAxisDomain,
	xAxis,
} from "@/components/ui/chart"
import { chartMargin, cn, decimalString, formatShortDate, toFixedFloat } from "@/lib/utils"
import type { ChartData } from "@/types"
import { useYAxisWidth } from "./hooks"

interface HAProxyResponsesChartProps {
	chartData: ChartData
	proxyFilter?: string
}

// Fixed colors for HTTP response codes
const responseColors = {
	r1r: "hsl(210, 50%, 60%)", // 1xx - gray-blue (informational)
	r2r: "hsl(142, 70%, 45%)", // 2xx - green (success)
	r3r: "hsl(217, 90%, 60%)", // 3xx - blue (redirect)
	r4r: "hsl(45, 90%, 50%)",  // 4xx - yellow (client error)
	r5r: "hsl(0, 85%, 55%)",   // 5xx - red (server error)
}

const responseLabels = {
	r1r: "1xx",
	r2r: "2xx",
	r3r: "3xx",
	r4r: "4xx",
	r5r: "5xx",
}

type ResponseKey = keyof typeof responseColors

export default memo(function HAProxyResponsesChart({ chartData, proxyFilter }: HAProxyResponsesChartProps) {
	const { yAxisWidth, updateYAxisWidth } = useYAxisWidth()
	const { systemStats } = chartData

	// Get proxy names for filtering
	const proxyNames = useMemo(() => {
		const lastStats = systemStats.at(-1)?.stats?.hap
		if (!lastStats) return []

		const names = new Set<string>()
		for (const proxy of lastStats) {
			if (proxy.t === "FRONTEND" || proxy.t === "BACKEND") {
				names.add(proxy.n)
			}
		}
		return Array.from(names)
	}, [systemStats])

	// Filter function
	const filteredNames = useMemo(() => {
		if (!proxyFilter) return new Set(proxyNames)
		const filterTerms = proxyFilter.toLowerCase().split(" ").filter((term) => term.length > 0)
		return new Set(
			proxyNames.filter((name) => {
				const nameLower = name.toLowerCase()
				return filterTerms.some((term) => nameLower.includes(term))
			})
		)
	}, [proxyNames, proxyFilter])

	// Transform data to sum response rates across all (filtered) proxies
	const transformedData = useMemo(() => {
		return systemStats.map((record) => {
			const hap = record.stats?.hap ?? []
			let r1r = 0, r2r = 0, r3r = 0, r4r = 0, r5r = 0

			for (const proxy of hap) {
				// Only include frontends and backends
				if (proxy.t !== "FRONTEND" && proxy.t !== "BACKEND") continue
				// Apply filter
				if (proxyFilter && !filteredNames.has(proxy.n)) continue

				r1r += proxy.r1r ?? 0
				r2r += proxy.r2r ?? 0
				r3r += proxy.r3r ?? 0
				r4r += proxy.r4r ?? 0
				r5r += proxy.r5r ?? 0
			}

			return {
				created: record.created,
				r1r,
				r2r,
				r3r,
				r4r,
				r5r,
			}
		})
	}, [systemStats, proxyFilter, filteredNames])

	const tickFormatter = (val: number) => {
		if (val >= 1000) {
			return updateYAxisWidth(`${toFixedFloat(val / 1000, 1)}k/s`)
		}
		return updateYAxisWidth(`${toFixedFloat(val, 0)}/s`)
	}

	const tooltipFormatter = (item: any) => `${decimalString(item.value)}/s`

	// Response keys to display (in stack order, bottom to top)
	const responseKeys: ResponseKey[] = ["r5r", "r4r", "r3r", "r2r", "r1r"]

	if (systemStats.length === 0) {
		return null
	}

	return (
		<div>
			<ChartContainer
				className={cn("h-full w-full absolute aspect-auto bg-card opacity-0 transition-opacity", {
					"opacity-100": yAxisWidth,
				})}
			>
				<AreaChart accessibilityLayer data={transformedData} margin={chartMargin} reverseStackOrder={true}>
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
						labelFormatter={(_, data) => formatShortDate(data[0]?.payload?.created)}
						content={<ChartTooltipContent contentFormatter={tooltipFormatter} showTotal={true} />}
					/>
					{responseKeys.map((key) => (
						<Area
							key={key}
							isAnimationActive={false}
							dataKey={key}
							name={responseLabels[key]}
							type="monotoneX"
							fill={responseColors[key]}
							fillOpacity={0.6}
							stroke={responseColors[key]}
							strokeOpacity={1}
							stackId="responses"
						/>
					))}
					<ChartLegend content={<ChartLegendContent reverse={true} />} />
				</AreaChart>
			</ChartContainer>
		</div>
	)
})
