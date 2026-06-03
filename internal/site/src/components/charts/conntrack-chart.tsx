import { memo } from "react"
import { Area, AreaChart, CartesianGrid, YAxis } from "recharts"
import { ChartContainer, ChartTooltip, ChartTooltipContent, pinnedAxisDomain, xAxis } from "@/components/ui/chart"
import { chartMargin, cn, decimalString, formatShortDate, toFixedFloat } from "@/lib/utils"
import type { ChartData, ConntrackStats } from "@/types"
import { useYAxisWidth } from "./hooks"

type ConntrackChartType = "utilization" | "connections"

interface ConntrackChartProps {
	chartData: ChartData
	chartType: ConntrackChartType
}

// Time-series chart of netfilter conntrack table usage for a single host. Reads
// stats.ct off each systemStats record, so it updates live from the same realtime
// stream as the CPU/mem charts. utilization = 100*conns/max (the table-fill signal);
// connections = the raw tracked-entry count.
export default memo(function ConntrackChart({ chartData, chartType }: ConntrackChartProps) {
	const { yAxisWidth, updateYAxisWidth } = useYAxisWidth()
	const { systemStats } = chartData

	if (systemStats.length === 0) {
		return null
	}

	const tickFormatter = (val: number) => {
		if (chartType === "utilization") {
			return updateYAxisWidth(`${toFixedFloat(val, 0)}%`)
		}
		return updateYAxisWidth(`${toFixedFloat(val, 0)}`)
	}

	const tooltipFormatter = (item: { value: number }) =>
		chartType === "utilization" ? `${decimalString(item.value)}%` : `${decimalString(item.value)} conns`

	const value = (ct?: ConntrackStats): number | null => {
		if (!ct) return null
		if (chartType === "utilization") {
			return ct.m ? (100 * ct.c) / ct.m : null
		}
		return ct.c
	}

	return (
		<div>
			<ChartContainer
				className={cn("h-full w-full absolute aspect-auto bg-card opacity-0 transition-opacity", {
					"opacity-100": yAxisWidth,
				})}
			>
				<AreaChart accessibilityLayer data={systemStats} margin={chartMargin}>
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
						labelFormatter={(_, data) => formatShortDate(data[0].payload.created)}
						content={<ChartTooltipContent contentFormatter={tooltipFormatter} />}
					/>
					<Area
						isAnimationActive={false}
						dataKey={({ stats }) => value(stats?.ct)}
						name={chartType === "utilization" ? "Utilization" : "Connections"}
						type="monotoneX"
						fill="hsl(var(--chart-1))"
						fillOpacity={0.4}
						stroke="hsl(var(--chart-1))"
						activeDot={{ opacity: 1 }}
					/>
				</AreaChart>
			</ChartContainer>
		</div>
	)
})
