import { memo, useMemo } from "react"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import type { HAProxyServerState } from "@/types"

interface HAProxyServersProps {
	servers: HAProxyServerState[]
}

function formatDuration(seconds: number): string {
	if (seconds < 60) return `${seconds}s`
	if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
	if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`
	return `${Math.floor(seconds / 86400)}d`
}

function getOpStateLabel(state: number): string {
	switch (state) {
		case 0:
			return "STOPPED"
		case 1:
			return "STARTING"
		case 2:
			return "RUNNING"
		case 3:
			return "STOPPING"
		default:
			return `STATE_${state}`
	}
}

function getOpStateColor(state: number): string {
	switch (state) {
		case 2: // RUNNING
			return "bg-green-500/20 text-green-600 dark:text-green-400 border-green-500/30"
		case 0: // STOPPED
			return "bg-red-500/20 text-red-600 dark:text-red-400 border-red-500/30"
		case 1: // STARTING
		case 3: // STOPPING
			return "bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 border-yellow-500/30"
		default:
			return "bg-gray-500/20 text-gray-600 dark:text-gray-400 border-gray-500/30"
	}
}

function getAdminStateLabel(state: number): string {
	if (state === 0) return "READY"
	const flags: string[] = []
	if (state & 0x01) flags.push("FMAINT")
	if (state & 0x02) flags.push("IMAINT")
	if (state & 0x04) flags.push("CMAINT")
	if (state & 0x08) flags.push("FDRAIN")
	if (state & 0x10) flags.push("IDRAIN")
	return flags.length > 0 ? flags.join(", ") : "READY"
}

function getCheckStatusLabel(status: number): string {
	switch (status) {
		case 0:
			return "—"
		case 1:
			return "OK"
		case 2:
			return "INI"
		case 3:
			return "SOCKERR"
		case 4:
			return "L4OK"
		case 5:
			return "L4TOUT"
		case 6:
			return "L4CON"
		case 7:
			return "L6OK"
		case 8:
			return "L6TOUT"
		case 9:
			return "L6RSP"
		case 10:
			return "L7OK"
		case 11:
			return "L7OKC"
		case 12:
			return "L7TOUT"
		case 13:
			return "L7RSP"
		case 14:
			return "L7STS"
		default:
			return `CHK_${status}`
	}
}

export default memo(function HAProxyServers({ servers }: HAProxyServersProps) {
	// Group by backend
	const groupedServers = useMemo(() => {
		const groups: Record<string, HAProxyServerState[]> = {}
		for (const server of servers) {
			if (!groups[server.bk]) {
				groups[server.bk] = []
			}
			groups[server.bk].push(server)
		}
		// Sort backends
		const sortedBackends = Object.keys(groups).sort()
		return sortedBackends.map((bk) => ({
			backend: bk,
			servers: groups[bk].sort((a, b) => a.sv.localeCompare(b.sv)),
		}))
	}, [servers])

	if (servers.length === 0) {
		return <div className="text-muted-foreground text-sm p-4">No server state data available</div>
	}

	return (
		<div className="overflow-x-auto">
			<Table>
				<TableHeader>
					<TableRow>
						<TableHead>Backend / Server</TableHead>
						<TableHead>Address</TableHead>
						<TableHead>State</TableHead>
						<TableHead>Admin</TableHead>
						<TableHead className="text-right">Weight</TableHead>
						<TableHead>Check</TableHead>
						<TableHead className="text-right">Since Change</TableHead>
					</TableRow>
				</TableHeader>
				<TableBody>
					{groupedServers.map((group) => (
						<>
							{/* Backend header row */}
							<TableRow key={`bk-${group.backend}`} className="bg-muted/50">
								<TableCell colSpan={7} className="font-medium">
									<span className="font-mono text-green-500 mr-2">←</span>
									{group.backend}
									<span className="text-muted-foreground ml-2">({group.servers.length} servers)</span>
								</TableCell>
							</TableRow>
							{/* Server rows */}
							{group.servers.map((server) => (
								<TableRow key={`srv-${server.bk}-${server.sv}`}>
									<TableCell className="pl-8">
										<span className="font-mono text-muted-foreground mr-2">●</span>
										{server.sv}
									</TableCell>
									<TableCell className="font-mono text-sm">
										{server.addr}
										{server.port > 0 && <span className="text-muted-foreground">:{server.port}</span>}
									</TableCell>
									<TableCell>
										<Badge variant="outline" className={cn("text-xs", getOpStateColor(server.os))}>
											{getOpStateLabel(server.os)}
										</Badge>
									</TableCell>
									<TableCell className="text-sm text-muted-foreground">
										{getAdminStateLabel(server.as)}
									</TableCell>
									<TableCell className="text-right tabular-nums">{server.w}</TableCell>
									<TableCell className="text-sm">
										{server.cks !== undefined ? getCheckStatusLabel(server.cks) : "—"}
									</TableCell>
									<TableCell className="text-right tabular-nums text-muted-foreground">
										{server.lc !== undefined ? formatDuration(server.lc) : "—"}
									</TableCell>
								</TableRow>
							))}
						</>
					))}
				</TableBody>
			</Table>
		</div>
	)
})
