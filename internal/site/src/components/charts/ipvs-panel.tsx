import { useLingui } from "@lingui/react/macro"
import { AlertCircleIcon } from "lucide-react"
import { memo } from "react"
import { Badge } from "@/components/ui/badge"
import { formatBytesPerSec, formatNumber } from "@/lib/ipvs-aggregate"
import { cn } from "@/lib/utils"
import type { IPVSStats } from "@/types"

const ROLE_CLASS: Record<string, string> = {
	active: "bg-green-500/20 text-green-700 border-green-500/40",
	standby: "bg-gray-500/20 text-gray-700 border-gray-500/40",
	unknown: "bg-yellow-500/20 text-yellow-700 border-yellow-500/40",
}

/**
 * Per-system IPVS panel for /system/<id>. Mirrors the aggregate page's
 * service table but scoped to one host. Renders nothing if ipvs is undefined.
 */
export default memo(function IPVSPanel({ ipvs }: { ipvs: IPVSStats }) {
	const { t } = useLingui()
	const role = ipvs.r
	const services = ipvs.svc ?? []
	const drainedTotal = services.reduce(
		(n, s) => n + (s.d?.filter((d) => (d.w ?? 0) === 0).length ?? 0),
		0,
	)

	return (
		<div className="space-y-4">
			{/* Role + VIPs summary row */}
			<div className="flex flex-wrap items-center gap-2">
				<span
					className={cn(
						"inline-flex items-center gap-1.5 px-2.5 py-1 rounded border text-xs font-medium uppercase",
						ROLE_CLASS[role] ?? ROLE_CLASS.unknown,
					)}
				>
					{role}
				</span>
				{ipvs.v.length > 0 && (
					<>
						<span className="text-xs text-muted-foreground ml-2">{t`VIPs`}:</span>
						{ipvs.v.map((vip) => (
							<Badge key={vip} variant="outline" className="font-mono text-xs">
								{vip}
							</Badge>
						))}
					</>
				)}
				{drainedTotal > 0 && (
					<span className="text-xs text-amber-600 inline-flex items-center gap-1 ml-2">
						<AlertCircleIcon className="h-3 w-3" />
						{t`${drainedTotal} drained real server(s)`}
					</span>
				)}
			</div>

			{/* Aggregate metrics */}
			<div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
				<Metric label={t`Active conns`} value={formatNumber(ipvs.ac ?? 0)} />
				<Metric label={t`Conn rate`} value={`${formatNumber(ipvs.cps ?? 0)}/s`} />
				<Metric label={t`Traffic In`} value={formatBytesPerSec(ipvs.bir ?? 0)} />
				<Metric label={t`Traffic Out`} value={formatBytesPerSec(ipvs.bor ?? 0)} />
			</div>

			{/* Per-virtual-service table */}
			{services.length > 0 ? (
				<div className="overflow-x-auto">
					<table className="w-full text-sm">
						<thead>
							<tr className="text-left text-xs text-muted-foreground border-b">
								<th className="py-2 pr-3">{t`Virtual Service`}</th>
								<th className="py-2 pr-3">{t`Sched`}</th>
								<th className="py-2 pr-3">{t`Mode`}</th>
								<th className="py-2 pr-3 text-right">{t`Active`}</th>
								<th className="py-2 pr-3 text-right">{t`Inactive`}</th>
								<th className="py-2 pr-3 text-right">{t`CPS`}</th>
								<th className="py-2 pr-3 text-right">{t`In`}</th>
								<th className="py-2 pr-3 text-right">{t`Out`}</th>
								<th className="py-2 pr-3 text-right">{t`Reals`}</th>
							</tr>
						</thead>
						<tbody>
							{services.map((svc, i) => {
								const dests = svc.d ?? []
								const drained = dests.filter((d) => (d.w ?? 0) === 0).length
								return (
									<RealServerRows
										key={`${svc.v}:${svc.p}-${i}`}
										svc={svc}
										drained={drained}
										total={dests.length}
									/>
								)
							})}
						</tbody>
					</table>
				</div>
			) : (
				<div className="text-sm text-muted-foreground">{t`No virtual services configured.`}</div>
			)}
		</div>
	)
})

function Metric({ label, value }: { label: string; value: string }) {
	return (
		<div>
			<p className="text-xs text-muted-foreground">{label}</p>
			<p className="text-lg font-semibold mt-1">{value}</p>
		</div>
	)
}

function RealServerRows({
	svc,
	drained,
	total,
}: {
	svc: NonNullable<IPVSStats["svc"]>[number]
	drained: number
	total: number
}) {
	return (
		<>
			<tr className="border-b">
				<td className="py-2 pr-3 font-mono text-xs">
					{svc.v}:{svc.p}/{svc.pr}
				</td>
				<td className="py-2 pr-3 uppercase text-xs">{svc.sc}</td>
				<td className="py-2 pr-3 text-xs">{svc.fm ?? "—"}</td>
				<td className="py-2 pr-3 text-right">{formatNumber(svc.ac ?? 0)}</td>
				<td className="py-2 pr-3 text-right">{formatNumber(svc.ic ?? 0)}</td>
				<td className="py-2 pr-3 text-right">{formatNumber(svc.cps ?? 0)}</td>
				<td className="py-2 pr-3 text-right">{formatBytesPerSec(svc.bir ?? 0)}</td>
				<td className="py-2 pr-3 text-right">{formatBytesPerSec(svc.bor ?? 0)}</td>
				<td className="py-2 pr-3 text-right">
					{total - drained}/{total}
					{drained > 0 && <span className="text-amber-600 ml-1">⚠</span>}
				</td>
			</tr>
			{(svc.d ?? []).map((d, j) => (
				<tr
					key={`${d.a}:${d.p}-${j}`}
					className={cn("border-b last:border-0 text-xs", (d.w ?? 0) === 0 && "opacity-50")}
				>
					<td className="py-1 pl-6 pr-3 font-mono text-muted-foreground">
						↳ {d.a}:{d.p}
					</td>
					<td className="py-1 pr-3 text-muted-foreground">w={d.w}</td>
					<td className="py-1 pr-3 text-muted-foreground">{d.fm ?? "—"}</td>
					<td className="py-1 pr-3 text-right">{formatNumber(d.ac ?? 0)}</td>
					<td className="py-1 pr-3 text-right">{formatNumber(d.ic ?? 0)}</td>
					<td className="py-1 pr-3 text-right">{formatNumber(d.cps ?? 0)}</td>
					<td className="py-1 pr-3 text-right">{formatBytesPerSec(d.bir ?? 0)}</td>
					<td className="py-1 pr-3 text-right">{formatBytesPerSec(d.bor ?? 0)}</td>
					<td className="py-1 pr-3 text-right text-muted-foreground">
						{(d.w ?? 0) === 0 ? "drained" : ""}
					</td>
				</tr>
			))}
		</>
	)
}
