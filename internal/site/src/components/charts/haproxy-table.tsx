import { memo, useMemo } from "react"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Badge } from "@/components/ui/badge"
import { cn, decimalString } from "@/lib/utils"
import type { HAProxyStats } from "@/types"

interface HAProxyTableProps {
	stats: HAProxyStats[]
}

function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B"
	const k = 1024
	const sizes = ["B", "KB", "MB", "GB", "TB"]
	const i = Math.floor(Math.log(bytes) / Math.log(k))
	return `${decimalString(bytes / Math.pow(k, i))} ${sizes[i]}`
}

function getStatusColor(status: string): string {
	switch (status.toUpperCase()) {
		case "UP":
		case "OPEN":
			return "bg-green-500/20 text-green-600 dark:text-green-400 border-green-500/30"
		case "DOWN":
			return "bg-red-500/20 text-red-600 dark:text-red-400 border-red-500/30"
		case "MAINT":
		case "DRAIN":
			return "bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 border-yellow-500/30"
		case "NO CHECK":
		case "NOLB":
			return "bg-gray-500/20 text-gray-600 dark:text-gray-400 border-gray-500/30"
		default:
			return "bg-gray-500/20 text-gray-600 dark:text-gray-400 border-gray-500/30"
	}
}

function getTypeIcon(type: string): string {
	switch (type) {
		case "FRONTEND":
			return "→"
		case "BACKEND":
			return "←"
		case "SERVER":
			return "●"
		default:
			return "○"
	}
}

export default memo(function HAProxyTable({ stats }: HAProxyTableProps) {
	// Group and sort stats
	const groupedStats = useMemo(() => {
		const frontends: HAProxyStats[] = []
		const backends: HAProxyStats[] = []
		const servers: HAProxyStats[] = []

		for (const stat of stats) {
			switch (stat.t) {
				case "FRONTEND":
					frontends.push(stat)
					break
				case "BACKEND":
					backends.push(stat)
					break
				case "SERVER":
					servers.push(stat)
					break
			}
		}

		// Sort by name
		frontends.sort((a, b) => a.n.localeCompare(b.n))
		backends.sort((a, b) => a.n.localeCompare(b.n))
		servers.sort((a, b) => a.n.localeCompare(b.n))

		return { frontends, backends, servers }
	}, [stats])

	if (stats.length === 0) {
		return <div className="text-muted-foreground text-sm p-4">No HAProxy stats available</div>
	}

	return (
		<div className="overflow-x-auto">
			<Table>
				<TableHeader>
					<TableRow>
						<TableHead className="w-[50px]">Type</TableHead>
						<TableHead>Name</TableHead>
						<TableHead>Status</TableHead>
						<TableHead className="text-right">Sessions</TableHead>
						<TableHead className="text-right">Req/s</TableHead>
						<TableHead className="text-right">1xx</TableHead>
						<TableHead className="text-right">2xx</TableHead>
						<TableHead className="text-right">3xx</TableHead>
						<TableHead className="text-right">4xx</TableHead>
						<TableHead className="text-right">5xx</TableHead>
						<TableHead className="text-right">Traffic In</TableHead>
						<TableHead className="text-right">Traffic Out</TableHead>
						<TableHead className="text-right">Servers</TableHead>
					</TableRow>
				</TableHeader>
				<TableBody>
					{/* Frontends */}
					{groupedStats.frontends.map((proxy) => (
						<TableRow key={`fe-${proxy.n}`}>
							<TableCell className="font-mono text-blue-500">{getTypeIcon(proxy.t)}</TableCell>
							<TableCell className="font-medium">{proxy.n}</TableCell>
							<TableCell>
								<Badge variant="outline" className={cn("text-xs", getStatusColor(proxy.s))}>
									{proxy.s}
								</Badge>
							</TableCell>
							<TableCell className="text-right tabular-nums">
								{proxy.sc}
								{proxy.sl ? <span className="text-muted-foreground">/{proxy.sl}</span> : null}
							</TableCell>
							<TableCell className="text-right tabular-nums">{proxy.rr ?? 0}</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">{proxy.r1r ?? 0}</TableCell>
							<TableCell className="text-right tabular-nums text-green-500">{proxy.r2r ?? 0}</TableCell>
							<TableCell className="text-right tabular-nums text-blue-500">{proxy.r3r ?? 0}</TableCell>
							<TableCell className="text-right tabular-nums">
								{(proxy.r4r ?? 0) > 0 ? (
									<span className="text-yellow-500">{proxy.r4r}</span>
								) : (
									<span className="text-muted-foreground">0</span>
								)}
							</TableCell>
							<TableCell className="text-right tabular-nums">
								{(proxy.r5r ?? 0) > 0 ? (
									<span className="text-red-500">{proxy.r5r}</span>
								) : (
									<span className="text-muted-foreground">0</span>
								)}
							</TableCell>
							<TableCell className="text-right tabular-nums">{formatBytes(proxy.bi)}</TableCell>
							<TableCell className="text-right tabular-nums">{formatBytes(proxy.bo)}</TableCell>
							<TableCell className="text-right text-muted-foreground">—</TableCell>
						</TableRow>
					))}

					{/* Backends */}
					{groupedStats.backends.map((proxy) => (
						<TableRow key={`be-${proxy.n}`}>
							<TableCell className="font-mono text-green-500">{getTypeIcon(proxy.t)}</TableCell>
							<TableCell className="font-medium">{proxy.n}</TableCell>
							<TableCell>
								<Badge variant="outline" className={cn("text-xs", getStatusColor(proxy.s))}>
									{proxy.s}
								</Badge>
							</TableCell>
							<TableCell className="text-right tabular-nums">
								{proxy.sc}
								{proxy.sl ? <span className="text-muted-foreground">/{proxy.sl}</span> : null}
							</TableCell>
							<TableCell className="text-right tabular-nums">{proxy.rr ?? 0}</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">{proxy.r1r ?? 0}</TableCell>
							<TableCell className="text-right tabular-nums text-green-500">{proxy.r2r ?? 0}</TableCell>
							<TableCell className="text-right tabular-nums text-blue-500">{proxy.r3r ?? 0}</TableCell>
							<TableCell className="text-right tabular-nums">
								{(proxy.r4r ?? 0) > 0 ? (
									<span className="text-yellow-500">{proxy.r4r}</span>
								) : (
									<span className="text-muted-foreground">0</span>
								)}
							</TableCell>
							<TableCell className="text-right tabular-nums">
								{(proxy.r5r ?? 0) > 0 ? (
									<span className="text-red-500">{proxy.r5r}</span>
								) : (
									<span className="text-muted-foreground">0</span>
								)}
							</TableCell>
							<TableCell className="text-right tabular-nums">{formatBytes(proxy.bi)}</TableCell>
							<TableCell className="text-right tabular-nums">{formatBytes(proxy.bo)}</TableCell>
							<TableCell className="text-right tabular-nums">
								{proxy.as !== undefined ? (
									<span>
										<span className="text-green-500">{proxy.as}</span>
										{proxy.bs ? <span className="text-muted-foreground">+{proxy.bs}</span> : null}
									</span>
								) : (
									"—"
								)}
							</TableCell>
						</TableRow>
					))}

					{/* Servers (indented under their backends) */}
					{groupedStats.servers.map((proxy) => (
						<TableRow key={`srv-${proxy.n}`} className="bg-muted/30">
							<TableCell className="font-mono text-muted-foreground pl-6">{getTypeIcon(proxy.t)}</TableCell>
							<TableCell className="text-muted-foreground pl-4">{proxy.n}</TableCell>
							<TableCell>
								<Badge variant="outline" className={cn("text-xs", getStatusColor(proxy.s))}>
									{proxy.s}
								</Badge>
							</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">{proxy.sc}</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">—</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">—</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">—</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">—</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">—</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">—</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">{formatBytes(proxy.bi)}</TableCell>
							<TableCell className="text-right tabular-nums text-muted-foreground">{formatBytes(proxy.bo)}</TableCell>
							<TableCell className="text-right text-muted-foreground">—</TableCell>
						</TableRow>
					))}
				</TableBody>
			</Table>
		</div>
	)
})
