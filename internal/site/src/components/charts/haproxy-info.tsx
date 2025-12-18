import { memo } from "react"
import { decimalString } from "@/lib/utils"
import type { HAProxyInfo } from "@/types"
import { Activity, Clock, Cpu, HardDrive, Network, Server, Shield, Zap } from "lucide-react"

interface HAProxyInfoPanelProps {
	info: HAProxyInfo
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

function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B"
	const k = 1024
	const sizes = ["B", "KB", "MB", "GB", "TB"]
	const i = Math.floor(Math.log(bytes) / Math.log(k))
	return `${decimalString(bytes / Math.pow(k, i))} ${sizes[i]}`
}

function formatBytesRate(bytes: number): string {
	return `${formatBytes(bytes)}/s`
}

interface StatCardProps {
	icon: React.ReactNode
	label: string
	value: string | number
	subValue?: string
	className?: string
}

function StatCard({ icon, label, value, subValue, className = "" }: StatCardProps) {
	return (
		<div className={`flex items-center gap-3 p-3 rounded-lg bg-muted/50 ${className}`}>
			<div className="p-2 rounded-md bg-background">{icon}</div>
			<div className="min-w-0 flex-1">
				<p className="text-xs text-muted-foreground truncate">{label}</p>
				<p className="text-lg font-semibold tabular-nums">{value}</p>
				{subValue && <p className="text-xs text-muted-foreground">{subValue}</p>}
			</div>
		</div>
	)
}

export default memo(function HAProxyInfoPanel({ info }: HAProxyInfoPanelProps) {
	return (
		<div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6 gap-3">
			{/* Version & Uptime */}
			<StatCard
				icon={<Server className="h-4 w-4 text-blue-500" />}
				label="Version"
				value={info.v}
				subValue={info.nd ? `Node: ${info.nd}` : undefined}
			/>
			<StatCard
				icon={<Clock className="h-4 w-4 text-green-500" />}
				label="Uptime"
				value={info.up}
				subValue={info.pid ? `PID: ${info.pid}` : undefined}
			/>

			{/* Threads & Tasks */}
			<StatCard
				icon={<Cpu className="h-4 w-4 text-purple-500" />}
				label="Threads"
				value={info.nt}
				subValue={info.ip !== undefined ? `${info.ip}% idle` : undefined}
			/>

			{/* Connections */}
			<StatCard
				icon={<Network className="h-4 w-4 text-orange-500" />}
				label="Connections"
				value={`${info.cc} / ${info.mc}`}
				subValue={`Total: ${formatNumber(info.tc)}`}
			/>

			{/* Connection Rate */}
			<StatCard
				icon={<Zap className="h-4 w-4 text-yellow-500" />}
				label="Conn Rate"
				value={`${info.cr ?? 0}/s`}
				subValue={info.mcr ? `Max: ${info.mcr}/s` : undefined}
			/>

			{/* Session Rate */}
			<StatCard
				icon={<Activity className="h-4 w-4 text-cyan-500" />}
				label="Session Rate"
				value={`${info.sr ?? 0}/s`}
				subValue={info.msr ? `Max: ${info.msr}/s` : undefined}
			/>

			{/* Requests */}
			<StatCard
				icon={<Activity className="h-4 w-4 text-indigo-500" />}
				label="Total Requests"
				value={formatNumber(info.tr)}
			/>

			{/* Memory */}
			{(info.pu ?? 0) > 0 && (
				<StatCard
					icon={<HardDrive className="h-4 w-4 text-pink-500" />}
					label="Memory Pool"
					value={`${info.pu} MB`}
					subValue={info.pa ? `Allocated: ${info.pa} MB` : undefined}
				/>
			)}

			{/* SSL Connections */}
			{(info.csc ?? 0) > 0 || (info.tsc ?? 0) > 0 ? (
				<StatCard
					icon={<Shield className="h-4 w-4 text-emerald-500" />}
					label="SSL Connections"
					value={info.csc ?? 0}
					subValue={`Total: ${formatNumber(info.tsc ?? 0)}`}
				/>
			) : null}

			{/* SSL Rate */}
			{(info.slr ?? 0) > 0 || (info.mslr ?? 0) > 0 ? (
				<StatCard
					icon={<Shield className="h-4 w-4 text-teal-500" />}
					label="SSL Rate"
					value={`${info.slr ?? 0}/s`}
					subValue={info.mslr ? `Max: ${info.mslr}/s` : undefined}
				/>
			) : null}

			{/* SSL Session Reuse */}
			{info.srp !== undefined && info.srp > 0 ? (
				<StatCard
					icon={<Shield className="h-4 w-4 text-lime-500" />}
					label="SSL Reuse"
					value={`${info.srp}%`}
				/>
			) : null}

			{/* Bytes Out */}
			{(info.bo ?? 0) > 0 && (
				<StatCard
					icon={<Network className="h-4 w-4 text-rose-500" />}
					label="Total Out"
					value={formatBytes(info.bo ?? 0)}
					subValue={info.bor ? `Rate: ${formatBytesRate(info.bor)}` : undefined}
				/>
			)}
		</div>
	)
})
