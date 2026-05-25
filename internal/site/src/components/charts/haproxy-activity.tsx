import { memo, useMemo } from "react"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { decimalString } from "@/lib/utils"
import type { HAProxyActivity } from "@/types"
import { Cpu, Activity, Zap } from "lucide-react"

interface HAProxyActivityProps {
	activity: HAProxyActivity[]
}

function formatNumber(num: number): string {
	if (num >= 1_000_000_000) {
		return `${decimalString(num / 1_000_000_000)}B`
	}
	if (num >= 1_000_000) {
		return `${decimalString(num / 1_000_000)}M`
	}
	if (num >= 1_000) {
		return `${decimalString(num / 1_000)}K`
	}
	return num.toString()
}

export default memo(function HAProxyActivity({ activity }: HAProxyActivityProps) {
	// Calculate totals
	const totals = useMemo(() => {
		return activity.reduce(
			(acc, t) => ({
				ctxSwitches: acc.ctxSwitches + t.cs,
				taskSwitches: acc.taskSwitches + t.ts,
				loops: acc.loops + t.lp,
				accepted: acc.accepted + (t.acc ?? 0),
				avgCpu: acc.avgCpu + t.cpu,
			}),
			{ ctxSwitches: 0, taskSwitches: 0, loops: 0, accepted: 0, avgCpu: 0 }
		)
	}, [activity])

	const avgCpuPct = activity.length > 0 ? totals.avgCpu / activity.length : 0

	if (activity.length === 0) {
		return <div className="text-muted-foreground text-sm p-4">No activity data available</div>
	}

	return (
		<div className="space-y-4">
			{/* Summary Cards */}
			<div className="grid grid-cols-2 md:grid-cols-4 gap-3">
				<div className="flex items-center gap-3 p-3 rounded-lg bg-muted/50">
					<div className="p-2 rounded-md bg-background">
						<Cpu className="h-4 w-4 text-purple-500" />
					</div>
					<div>
						<p className="text-xs text-muted-foreground">Threads</p>
						<p className="text-lg font-semibold tabular-nums">{activity.length}</p>
					</div>
				</div>
				<div className="flex items-center gap-3 p-3 rounded-lg bg-muted/50">
					<div className="p-2 rounded-md bg-background">
						<Activity className="h-4 w-4 text-cyan-500" />
					</div>
					<div>
						<p className="text-xs text-muted-foreground">Avg CPU</p>
						<p className="text-lg font-semibold tabular-nums">{decimalString(avgCpuPct)}%</p>
					</div>
				</div>
				<div className="flex items-center gap-3 p-3 rounded-lg bg-muted/50">
					<div className="p-2 rounded-md bg-background">
						<Zap className="h-4 w-4 text-yellow-500" />
					</div>
					<div>
						<p className="text-xs text-muted-foreground">Context Switches</p>
						<p className="text-lg font-semibold tabular-nums">{formatNumber(totals.ctxSwitches)}</p>
					</div>
				</div>
				<div className="flex items-center gap-3 p-3 rounded-lg bg-muted/50">
					<div>
						<p className="text-xs text-muted-foreground">Total Accepted</p>
						<p className="text-lg font-semibold tabular-nums">{formatNumber(totals.accepted)}</p>
					</div>
				</div>
			</div>

			{/* Thread Activity Table */}
			<div className="overflow-x-auto">
				<Table>
					<TableHeader>
						<TableRow>
							<TableHead className="w-[80px]">Thread</TableHead>
							<TableHead className="text-right">CPU %</TableHead>
							<TableHead className="text-right">Loop (us)</TableHead>
							<TableHead className="text-right">Ctx Switches</TableHead>
							<TableHead className="text-right">Task Switches</TableHead>
							<TableHead className="text-right">Loops</TableHead>
							<TableHead className="text-right">Accepted</TableHead>
							<TableHead className="text-right">Poll I/O</TableHead>
						</TableRow>
					</TableHeader>
					<TableBody>
						{activity.map((thread) => (
							<TableRow key={thread.tid}>
								<TableCell className="font-mono">#{thread.tid}</TableCell>
								<TableCell className="text-right tabular-nums">
									<span
										className={
											thread.cpu > 80
												? "text-red-500"
												: thread.cpu > 50
													? "text-yellow-500"
													: "text-green-500"
										}
									>
										{thread.cpu}%
									</span>
								</TableCell>
								<TableCell className="text-right tabular-nums">{thread.lus}</TableCell>
								<TableCell className="text-right tabular-nums">{formatNumber(thread.cs)}</TableCell>
								<TableCell className="text-right tabular-nums">{formatNumber(thread.ts)}</TableCell>
								<TableCell className="text-right tabular-nums">{formatNumber(thread.lp)}</TableCell>
								<TableCell className="text-right tabular-nums">
									{thread.acc ? formatNumber(thread.acc) : "—"}
								</TableCell>
								<TableCell className="text-right tabular-nums">
									{thread.pio ? formatNumber(thread.pio) : "—"}
								</TableCell>
							</TableRow>
						))}
					</TableBody>
				</Table>
			</div>
		</div>
	)
})
