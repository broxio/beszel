import { memo, useMemo, useState } from "react"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { decimalString } from "@/lib/utils"
import type { HAProxyPool, HAProxyPoolSummary } from "@/types"
import { ChevronDown, ChevronUp, Database } from "lucide-react"

interface HAProxyPoolsProps {
	pools: HAProxyPool[]
	summary?: HAProxyPoolSummary
}

function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B"
	const k = 1024
	const sizes = ["B", "KB", "MB", "GB"]
	const i = Math.floor(Math.log(bytes) / Math.log(k))
	return `${decimalString(bytes / Math.pow(k, i))} ${sizes[i]}`
}

function formatNumber(num: number): string {
	if (num >= 1_000_000) {
		return `${decimalString(num / 1_000_000)}M`
	}
	if (num >= 1_000) {
		return `${decimalString(num / 1_000)}K`
	}
	return num.toString()
}

export default memo(function HAProxyPools({ pools, summary }: HAProxyPoolsProps) {
	const [expanded, setExpanded] = useState(false)
	const maxVisible = 10

	// Sort pools by allocated bytes descending
	const sortedPools = useMemo(() => {
		return [...pools].sort((a, b) => b.a - a.a)
	}, [pools])

	const visiblePools = expanded ? sortedPools : sortedPools.slice(0, maxVisible)
	const hasMore = sortedPools.length > maxVisible

	if (pools.length === 0) {
		return <div className="text-muted-foreground text-sm p-4">No pool data available</div>
	}

	return (
		<div className="space-y-4">
			{/* Summary Card */}
			{summary && (
				<div className="grid grid-cols-2 md:grid-cols-4 gap-3">
					<div className="flex items-center gap-3 p-3 rounded-lg bg-muted/50">
						<div className="p-2 rounded-md bg-background">
							<Database className="h-4 w-4 text-blue-500" />
						</div>
						<div>
							<p className="text-xs text-muted-foreground">Total Pools</p>
							<p className="text-lg font-semibold tabular-nums">{summary.tp}</p>
						</div>
					</div>
					<div className="flex items-center gap-3 p-3 rounded-lg bg-muted/50">
						<div>
							<p className="text-xs text-muted-foreground">Allocated</p>
							<p className="text-lg font-semibold tabular-nums">{formatBytes(summary.ta)}</p>
						</div>
					</div>
					<div className="flex items-center gap-3 p-3 rounded-lg bg-muted/50">
						<div>
							<p className="text-xs text-muted-foreground">Used</p>
							<p className="text-lg font-semibold tabular-nums">{formatBytes(summary.tu)}</p>
						</div>
					</div>
					{(summary.tc ?? 0) > 0 && (
						<div className="flex items-center gap-3 p-3 rounded-lg bg-muted/50">
							<div>
								<p className="text-xs text-muted-foreground">In Thread Caches</p>
								<p className="text-lg font-semibold tabular-nums">{formatBytes(summary.tc ?? 0)}</p>
							</div>
						</div>
					)}
				</div>
			)}

			{/* Pools Table */}
			<div className="overflow-x-auto">
				<Table>
					<TableHeader>
						<TableRow>
							<TableHead>Pool Name</TableHead>
							<TableHead className="text-right">Size</TableHead>
							<TableHead className="text-right">Allocated</TableHead>
							<TableHead className="text-right">Used</TableHead>
							<TableHead className="text-right">In Cache</TableHead>
							<TableHead className="text-right">Failures</TableHead>
						</TableRow>
					</TableHeader>
					<TableBody>
						{visiblePools.map((pool) => (
							<TableRow key={pool.n}>
								<TableCell className="font-mono text-sm">{pool.n}</TableCell>
								<TableCell className="text-right tabular-nums">{formatBytes(pool.sz)}</TableCell>
								<TableCell className="text-right tabular-nums">{formatBytes(pool.a)}</TableCell>
								<TableCell className="text-right tabular-nums">{formatNumber(pool.u)}</TableCell>
								<TableCell className="text-right tabular-nums text-muted-foreground">
									{pool.ic ? formatNumber(pool.ic) : "—"}
								</TableCell>
								<TableCell className="text-right tabular-nums">
									{(pool.f ?? 0) > 0 ? (
										<span className="text-red-500">{pool.f}</span>
									) : (
										<span className="text-muted-foreground">0</span>
									)}
								</TableCell>
							</TableRow>
						))}
					</TableBody>
				</Table>
			</div>

			{/* Expand/Collapse Button */}
			{hasMore && (
				<button
					onClick={() => setExpanded(!expanded)}
					className="w-full flex items-center justify-center gap-1 py-2 text-sm text-muted-foreground hover:text-foreground transition-colors"
				>
					{expanded ? (
						<>
							<ChevronUp className="h-4 w-4" />
							Show less
						</>
					) : (
						<>
							<ChevronDown className="h-4 w-4" />
							Show all {sortedPools.length} pools
						</>
					)}
				</button>
			)}
		</div>
	)
})
