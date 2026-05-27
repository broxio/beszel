import { useLingui } from "@lingui/react/macro"
import { ActivityIcon, AlertTriangleIcon, ArrowDownToLineIcon, ArrowUpFromLineIcon } from "lucide-react"
import { memo, useEffect, useMemo, useRef, useState } from "react"
import { Badge } from "@/components/ui/badge"
import {
	deriveRate,
	formatBytes,
	formatBytesPerSec,
	formatEventsRate,
	formatNumber,
} from "@/lib/vector-aggregate"
import { cn } from "@/lib/utils"
import type { VectorComponent, VectorStats } from "@/types"

const KIND_BADGE: Record<string, string> = {
	source: "bg-blue-500/20 text-blue-700 border-blue-500/40",
	transform: "bg-purple-500/20 text-purple-700 border-purple-500/40",
	sink: "bg-green-500/20 text-green-700 border-green-500/40",
}

interface RateSnapshot {
	receivedEvents: number
	sentEvents: number
	receivedBytes: number
	sentBytes: number
	errors: number
	discarded: number
	t: number
}

/**
 * Per-system Vector panel. Derives rates client-side from successive samples
 * of the cumulative counters — mirrors how the agent ships HAProxy data.
 * Renders nothing useful until two samples have been collected (rate is 0).
 *
 * `recordTs` is the latest system_stats record's `created` timestamp. We use
 * it to ignore renders that don't represent a new underlying record — without
 * that, rates flap to 0 every time the UI re-renders against the same record.
 */
export default memo(function VectorPanel({ vec, recordTs }: { vec: VectorStats; recordTs: string }) {
	const { t } = useLingui()
	const components = vec.co ?? []

	// Hold previous snapshot per-component to derive rates without re-renders.
	const prevRef = useRef<Map<string, RateSnapshot>>(new Map())
	const aggPrevRef = useRef<RateSnapshot | null>(null)
	const lastRecordTsRef = useRef<string>("")
	const [tick, setTick] = useState(0)

	// Bump tick only when a NEW underlying record arrives. Re-renders against
	// the same record don't advance the rate derivation.
	useEffect(() => {
		if (recordTs && recordTs !== lastRecordTsRef.current) {
			lastRecordTsRef.current = recordTs
			setTick((n) => n + 1)
		}
	}, [recordTs])

	const now = Date.now()

	const rates = useMemo(() => {
		const out = new Map<string, RateSnapshot & { receivedEventsRate: number; sentEventsRate: number; receivedBytesRate: number; sentBytesRate: number }>()
		for (const c of components) {
			const prev = prevRef.current.get(c.i)
			const snap: RateSnapshot = {
				receivedEvents: c.re ?? 0,
				sentEvents: c.se ?? 0,
				receivedBytes: c.rb ?? 0,
				sentBytes: c.sb ?? 0,
				errors: c.e ?? 0,
				discarded: c.d ?? 0,
				t: now,
			}
			const interval = prev ? now - prev.t : 0
			out.set(c.i, {
				...snap,
				receivedEventsRate: prev ? deriveRate(snap.receivedEvents, prev.receivedEvents, interval) : 0,
				sentEventsRate: prev ? deriveRate(snap.sentEvents, prev.sentEvents, interval) : 0,
				receivedBytesRate: prev ? deriveRate(snap.receivedBytes, prev.receivedBytes, interval) : 0,
				sentBytesRate: prev ? deriveRate(snap.sentBytes, prev.sentBytes, interval) : 0,
			})
			prevRef.current.set(c.i, snap)
		}
		return out
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [tick])

	const aggregateRates = useMemo(() => {
		const snap: RateSnapshot = {
			receivedEvents: vec.re ?? 0,
			sentEvents: vec.se ?? 0,
			receivedBytes: vec.rb ?? 0,
			sentBytes: vec.sb ?? 0,
			errors: vec.e ?? 0,
			discarded: vec.d ?? 0,
			t: now,
		}
		const prev = aggPrevRef.current
		const interval = prev ? now - prev.t : 0
		aggPrevRef.current = snap
		return {
			receivedEventsRate: prev ? deriveRate(snap.receivedEvents, prev.receivedEvents, interval) : 0,
			sentEventsRate: prev ? deriveRate(snap.sentEvents, prev.sentEvents, interval) : 0,
			receivedBytesRate: prev ? deriveRate(snap.receivedBytes, prev.receivedBytes, interval) : 0,
			sentBytesRate: prev ? deriveRate(snap.sentBytes, prev.sentBytes, interval) : 0,
		}
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [tick])

	const sortedComponents = useMemo(() => {
		const order: Record<string, number> = { source: 0, transform: 1, sink: 2 }
		return [...components].sort((a, b) => {
			const ka = order[a.k] ?? 3
			const kb = order[b.k] ?? 3
			if (ka !== kb) return ka - kb
			return a.i.localeCompare(b.i)
		})
	}, [components])

	return (
		<div className="space-y-4">
			{/* Header: version + health + counts */}
			<div className="flex flex-wrap items-center gap-2">
				<Badge
					variant="outline"
					className={cn(
						"font-medium uppercase",
						vec.hl
							? "bg-green-500/20 text-green-700 border-green-500/40"
							: "bg-red-500/20 text-red-700 border-red-500/40",
					)}
				>
					{vec.hl ? t`healthy` : t`unhealthy`}
				</Badge>
				{vec.v && (
					<Badge variant="outline" className="font-mono text-xs">
						v{vec.v}
					</Badge>
				)}
				<span className="text-xs text-muted-foreground ml-2">
					{t`${vec.sc ?? 0} sources · ${vec.tc ?? 0} transforms · ${vec.sk ?? 0} sinks`}
				</span>
				{(vec.e ?? 0) > 0 && (
					<span className="text-xs text-amber-600 inline-flex items-center gap-1 ml-2">
						<AlertTriangleIcon className="h-3 w-3" />
						{t`${formatNumber(vec.e ?? 0)} cumulative errors`}
					</span>
				)}
			</div>

			{/* Aggregate metrics — rates derived client-side from sample deltas */}
			<div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
				<Metric
					icon={<ArrowDownToLineIcon className="h-4 w-4 text-blue-500" />}
					label={t`Events in`}
					value={formatEventsRate(aggregateRates.receivedEventsRate)}
					sub={t`${formatNumber(vec.re ?? 0)} total`}
				/>
				<Metric
					icon={<ArrowUpFromLineIcon className="h-4 w-4 text-green-500" />}
					label={t`Events out`}
					value={formatEventsRate(aggregateRates.sentEventsRate)}
					sub={t`${formatNumber(vec.se ?? 0)} total`}
				/>
				<Metric
					icon={<ArrowDownToLineIcon className="h-4 w-4 text-blue-500" />}
					label={t`Bytes in`}
					value={formatBytesPerSec(aggregateRates.receivedBytesRate)}
					sub={formatBytes(vec.rb ?? 0)}
				/>
				<Metric
					icon={<ArrowUpFromLineIcon className="h-4 w-4 text-green-500" />}
					label={t`Bytes out`}
					value={formatBytesPerSec(aggregateRates.sentBytesRate)}
					sub={formatBytes(vec.sb ?? 0)}
				/>
			</div>

			{/* Per-component table */}
			{sortedComponents.length > 0 ? (
				<div className="overflow-x-auto">
					<table className="w-full text-sm">
						<thead>
							<tr className="text-left text-xs text-muted-foreground border-b">
								<th className="py-2 pr-3">{t`Component`}</th>
								<th className="py-2 pr-3">{t`Kind`}</th>
								<th className="py-2 pr-3">{t`Type`}</th>
								<th className="py-2 pr-3 text-right">{t`Events in/s`}</th>
								<th className="py-2 pr-3 text-right">{t`Events out/s`}</th>
								<th className="py-2 pr-3 text-right">{t`Bytes in/s`}</th>
								<th className="py-2 pr-3 text-right">{t`Bytes out/s`}</th>
								<th className="py-2 pr-3 text-right">{t`Errors`}</th>
							</tr>
						</thead>
						<tbody>
							{sortedComponents.map((c) => (
								<ComponentRow key={c.i} component={c} rates={rates.get(c.i)} />
							))}
						</tbody>
					</table>
				</div>
			) : (
				<div className="text-sm text-muted-foreground flex items-center gap-2">
					<ActivityIcon className="h-4 w-4" />
					{t`No components reported by Vector.`}
				</div>
			)}
		</div>
	)
})

function Metric({
	icon,
	label,
	value,
	sub,
}: {
	icon: React.ReactNode
	label: string
	value: string
	sub?: string
}) {
	return (
		<div>
			<p className="text-xs text-muted-foreground inline-flex items-center gap-1.5">
				{icon}
				{label}
			</p>
			<p className="text-lg font-semibold mt-1 tabular-nums">{value}</p>
			{sub && <p className="text-xs text-muted-foreground tabular-nums">{sub}</p>}
		</div>
	)
}

function ComponentRow({
	component,
	rates,
}: {
	component: VectorComponent
	rates:
		| {
				receivedEventsRate: number
				sentEventsRate: number
				receivedBytesRate: number
				sentBytesRate: number
		  }
		| undefined
}) {
	const errors = component.e ?? 0
	return (
		<tr className={cn("border-b last:border-0", errors > 0 && "bg-amber-500/5")}>
			<td className="py-2 pr-3 font-mono text-xs">{component.i}</td>
			<td className="py-2 pr-3">
				<span
					className={cn(
						"inline-block px-1.5 py-0.5 rounded border text-[10px] font-medium uppercase",
						KIND_BADGE[component.k] ?? "bg-gray-500/20 text-gray-700 border-gray-500/40",
					)}
				>
					{component.k}
				</span>
			</td>
			<td className="py-2 pr-3 text-xs text-muted-foreground">{component.t}</td>
			<td className="py-2 pr-3 text-right tabular-nums">
				{component.k === "sink" ? "—" : formatEventsRate(rates?.receivedEventsRate ?? 0)}
			</td>
			<td className="py-2 pr-3 text-right tabular-nums">
				{component.k === "source" ? "—" : formatEventsRate(rates?.sentEventsRate ?? 0)}
			</td>
			<td className="py-2 pr-3 text-right tabular-nums text-xs">
				{component.k === "sink" ? "—" : formatBytesPerSec(rates?.receivedBytesRate ?? 0)}
			</td>
			<td className="py-2 pr-3 text-right tabular-nums text-xs">
				{component.k === "source" ? "—" : formatBytesPerSec(rates?.sentBytesRate ?? 0)}
			</td>
			<td
				className={cn(
					"py-2 pr-3 text-right tabular-nums",
					errors > 0 && "text-amber-700 font-medium",
				)}
			>
				{formatNumber(errors)}
			</td>
		</tr>
	)
}
