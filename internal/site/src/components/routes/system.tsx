import { t } from "@lingui/core/macro"
import { memo, useState } from "react"
import { Trans } from "@lingui/react/macro"
import { compareSemVer, parseSemVer } from "@/lib/utils"

import type { GPUData } from "@/types"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Card, CardDescription, CardHeader, CardTitle } from "../ui/card"
import HAProxyChart from "@/components/charts/haproxy-chart"
import HAProxyResponsesChart from "@/components/charts/haproxy-responses-chart"
import HAProxyTable from "@/components/charts/haproxy-table"
import HAProxyInfoPanel from "@/components/charts/haproxy-info"
import HAProxyPools from "@/components/charts/haproxy-pools"
import HAProxyActivity from "@/components/charts/haproxy-activity"
import HAProxyServers from "@/components/charts/haproxy-servers"
import { ChartCard } from "./system/chart-card"
import InfoBar from "./system/info-bar"
import { useSystemData } from "./system/use-system-data"
import { CpuChart, ContainerCpuChart } from "./system/charts/cpu-charts"
import { MemoryChart, ContainerMemoryChart, SwapChart } from "./system/charts/memory-charts"
import { DiskCharts } from "./system/charts/disk-charts"
import { BandwidthChart, ContainerNetworkChart } from "./system/charts/network-charts"
import { TemperatureChart, BatteryChart } from "./system/charts/sensor-charts"
import { GpuPowerChart, GpuDetailCharts } from "./system/charts/gpu-charts"
import { ExtraFsCharts } from "./system/charts/extra-fs-charts"
import { LazyContainersTable, LazySmartTable, LazySystemdTable } from "./system/lazy-tables"
import { LoadAverageChart } from "./system/charts/load-average-chart"
import { ContainerIcon, CpuIcon, HardDriveIcon, NetworkIcon, TerminalSquareIcon } from "lucide-react"
import { GpuIcon } from "../ui/icons"
import SystemdTable from "../systemd-table/systemd-table"
import ContainersTable from "../containers-table/containers-table"

const SEMVER_0_14_0 = parseSemVer("0.14.0")
const SEMVER_0_15_0 = parseSemVer("0.15.0")

export default memo(function SystemDetail({ id }: { id: string }) {
	const {
		system,
		systemStats,
		containerData,
		chartData,
		containerChartConfigs,
		details,
		grid,
		setGrid,
		displayMode,
		setDisplayMode,
		activeTab,
		setActiveTab,
		mountedTabs,
		tabsRef,
		maxValues,
		isLongerChart,
		showMax,
		dataEmpty,
		isPodman,
		lastGpus,
		hasGpuData,
		hasGpuEnginesData,
		hasGpuPowerData,
	} = useSystemData(id)

	// extra margin to add to bottom of page, specifically for temperature chart,
	// where the tooltip can go past the bottom of the page if lots of sensors
	const [pageBottomExtraMargin, setPageBottomExtraMargin] = useState(0)

	if (!system.id) {
		return null
	}

	const hasContainers = containerData.length > 0
	const maybeHasSmartData = compareSemVer(chartData.agentVersion, SEMVER_0_15_0) >= 0
	const hasContainersTable = hasContainers && compareSemVer(chartData.agentVersion, SEMVER_0_14_0) >= 0
	const hasSystemd = system.info.sv
	const hasGpu = hasGpuData || hasGpuPowerData
	const hasHAProxyData = (systemStats.at(-1)?.stats?.hap?.length ?? 0) > 0

	// keep tabsRef in sync for keyboard navigation
	const tabs = ["core", "disk"]
	if (hasGpu) tabs.push("gpu")
	if (hasHAProxyData) tabs.push("haproxy")
	if (hasContainers) tabs.push("containers")
	if (hasSystemd) tabs.push("services")
	tabsRef.current = tabs

	// shared chart props
	const coreProps = { chartData, grid, dataEmpty, showMax, isLongerChart, maxValues }

	function defaultLayout() {
		return (
			<>
				{/* main charts */}
				<div className="grid xl:grid-cols-2 gap-4">
					<CpuChart {...coreProps} />

					{hasContainers && (
						<ContainerCpuChart
							chartData={chartData}
							grid={grid}
							dataEmpty={dataEmpty}
							isPodman={isPodman}
							cpuConfig={containerChartConfigs.cpu}
						/>
					)}

					<MemoryChart {...coreProps} />

					{hasContainers && (
						<ContainerMemoryChart
							chartData={chartData}
							grid={grid}
							dataEmpty={dataEmpty}
							isPodman={isPodman}
							memoryConfig={containerChartConfigs.memory}
						/>
					)}

					<DiskCharts {...coreProps} systemStats={systemStats} />

					<BandwidthChart {...coreProps} systemStats={systemStats} />

					{hasContainers && (
						<ContainerNetworkChart
							chartData={chartData}
							grid={grid}
							dataEmpty={dataEmpty}
							isPodman={isPodman}
							networkConfig={containerChartConfigs.network}
						/>
					)}

					<SwapChart chartData={chartData} grid={grid} dataEmpty={dataEmpty} systemStats={systemStats} />

					<LoadAverageChart chartData={chartData} grid={grid} dataEmpty={dataEmpty} />

					<TemperatureChart {...coreProps} />

					<BatteryChart {...coreProps} />

					{hasGpuPowerData && <GpuPowerChart chartData={chartData} grid={grid} dataEmpty={dataEmpty} />}
				</div>

				{hasGpuData && lastGpus && (
					<GpuDetailCharts
						chartData={chartData}
						grid={grid}
						dataEmpty={dataEmpty}
						lastGpus={lastGpus as Record<string, GPUData>}
						hasGpuEnginesData={hasGpuEnginesData}
					/>
				)}

				<ExtraFsCharts {...coreProps} systemStats={systemStats} />

				{/* HAProxy charts and table */}
				{hasHAProxyData && (
					<>
						{/* HAProxy Info Panel */}
						{systemStats.at(-1)?.stats?.hapi && (
							<Card className="p-4">
								<CardHeader className="pb-4 pt-0 px-0">
									<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Process Info`}</CardTitle>
									<CardDescription>{t`HAProxy process statistics and runtime information`}</CardDescription>
								</CardHeader>
								<HAProxyInfoPanel info={systemStats.at(-1)?.stats?.hapi!} />
							</Card>
						)}

						{/* HAProxy Charts */}
						<div className="grid xl:grid-cols-2 gap-4">
							<ChartCard
								empty={dataEmpty}
								grid={grid}
								title={t`HAProxy Sessions`}
								description={t`Current sessions across frontends and backends`}
							>
								<HAProxyChart chartData={chartData} chartType="sessions" />
							</ChartCard>
							<ChartCard
								empty={dataEmpty}
								grid={grid}
								title={t`HAProxy Traffic`}
								description={t`Total bytes transferred (in + out)`}
							>
								<HAProxyChart chartData={chartData} chartType="traffic" />
							</ChartCard>
							<ChartCard
								empty={dataEmpty}
								grid={grid}
								title={t`HAProxy Request Rate`}
								description={t`HTTP requests per second`}
							>
								<HAProxyChart chartData={chartData} chartType="requests" />
							</ChartCard>
							<ChartCard
								empty={dataEmpty}
								grid={grid}
								title={t`HAProxy Response Time`}
								description={t`Average backend response time (ms)`}
							>
								<HAProxyChart chartData={chartData} chartType="response_time" />
							</ChartCard>
							<ChartCard
								empty={dataEmpty}
								grid={grid}
								title={t`HAProxy Error Rate`}
								description={t`HTTP 4xx and 5xx errors per second`}
							>
								<HAProxyChart chartData={chartData} chartType="errors" />
							</ChartCard>
							<ChartCard
								empty={dataEmpty}
								grid={grid}
								title={t`HAProxy HTTP Responses`}
								description={t`HTTP response codes per second (1xx-5xx)`}
							>
								<HAProxyResponsesChart chartData={chartData} />
							</ChartCard>
						</div>

						{/* HAProxy Status Table */}
						<Card className="p-4">
							<CardHeader className="pb-4 pt-0 px-0">
								<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Status`}</CardTitle>
								<CardDescription>{t`Current status of all HAProxy frontends, backends, and servers`}</CardDescription>
							</CardHeader>
							<HAProxyTable stats={systemStats.at(-1)?.stats?.hap ?? []} />
						</Card>

						{/* HAProxy Memory Pools */}
						{(systemStats.at(-1)?.stats?.hpp?.length ?? 0) > 0 && (
							<Card className="p-4">
								<CardHeader className="pb-4 pt-0 px-0">
									<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Memory Pools`}</CardTitle>
									<CardDescription>{t`Memory pool allocation and usage statistics`}</CardDescription>
								</CardHeader>
								<HAProxyPools
									pools={systemStats.at(-1)?.stats?.hpp ?? []}
									summary={systemStats.at(-1)?.stats?.hpps}
								/>
							</Card>
						)}

						{/* HAProxy Thread Activity */}
						{(systemStats.at(-1)?.stats?.hpa?.length ?? 0) > 0 && (
							<Card className="p-4">
								<CardHeader className="pb-4 pt-0 px-0">
									<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Thread Activity`}</CardTitle>
									<CardDescription>{t`Per-thread CPU usage and activity statistics`}</CardDescription>
								</CardHeader>
								<HAProxyActivity activity={systemStats.at(-1)?.stats?.hpa ?? []} />
							</Card>
						)}

						{/* HAProxy Server States */}
						{(systemStats.at(-1)?.stats?.hpsv?.length ?? 0) > 0 && (
							<Card className="p-4">
								<CardHeader className="pb-4 pt-0 px-0">
									<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Server States`}</CardTitle>
									<CardDescription>{t`Detailed server state and configuration`}</CardDescription>
								</CardHeader>
								<HAProxyServers servers={systemStats.at(-1)?.stats?.hpsv ?? []} />
							</Card>
						)}
					</>
				)}

				{maybeHasSmartData && <LazySmartTable systemId={system.id} />}

				{hasContainersTable && <LazyContainersTable systemId={system.id} />}

				{hasSystemd && <LazySystemdTable systemId={system.id} />}
			</>
		)
	}

	function tabbedLayout() {
		return (
			<Tabs value={activeTab} onValueChange={setActiveTab} className="contents">
				<TabsList className="h-11 p-1.5 w-full shadow-xs overflow-auto justify-start">
					<TabsTrigger value="core" className="w-full flex items-center gap-1.5">
						<CpuIcon className="size-3.5" />
						<Trans context="Core system metrics">Core</Trans>
					</TabsTrigger>
					<TabsTrigger value="disk" className="w-full flex items-center gap-1.5">
						<HardDriveIcon className="size-3.5" />
						<Trans>Disk</Trans>
					</TabsTrigger>
					{hasGpu && (
						<TabsTrigger value="gpu" className="w-full flex items-center gap-2">
							<GpuIcon className="size-3.5" />
							<Trans>GPU</Trans>
						</TabsTrigger>
					)}
					{hasHAProxyData && (
						<TabsTrigger value="haproxy" className="w-full flex items-center gap-2">
							<NetworkIcon className="size-3.5" />
							<Trans>HAProxy</Trans>
						</TabsTrigger>
					)}
					{hasContainers && (
						<TabsTrigger value="containers" className="w-full flex items-center gap-2">
							<ContainerIcon className="size-3.5" />
							<Trans>Containers</Trans>
						</TabsTrigger>
					)}
					{hasSystemd && (
						<TabsTrigger value="services" className="w-full flex items-center gap-2">
							<TerminalSquareIcon className="size-3.5" />
							<Trans>Services</Trans>
						</TabsTrigger>
					)}
				</TabsList>

				<TabsContent value="core" forceMount className={activeTab === "core" ? "contents" : "hidden"}>
					<div className="grid xl:grid-cols-2 gap-4">
						<CpuChart {...coreProps} />
						<MemoryChart {...coreProps} />
						<LoadAverageChart chartData={chartData} grid={grid} dataEmpty={dataEmpty} />
						<BandwidthChart {...coreProps} systemStats={systemStats} />
						<TemperatureChart {...coreProps} setPageBottomExtraMargin={setPageBottomExtraMargin} />
						<SwapChart chartData={chartData} grid={grid} dataEmpty={dataEmpty} systemStats={systemStats} />
						{pageBottomExtraMargin > 0 && <div style={{ marginBottom: pageBottomExtraMargin }}></div>}
					</div>
				</TabsContent>

				<TabsContent value="disk" forceMount className={activeTab === "disk" ? "contents" : "hidden"}>
					{mountedTabs.has("disk") && (
						<>
							<div className="grid xl:grid-cols-2 gap-4">
								<DiskCharts {...coreProps} systemStats={systemStats} />
							</div>
							<ExtraFsCharts {...coreProps} systemStats={systemStats} />
							{maybeHasSmartData && <LazySmartTable systemId={system.id} />}
						</>
					)}
				</TabsContent>

				{hasGpu && (
					<TabsContent value="gpu" forceMount className={activeTab === "gpu" ? "contents" : "hidden"}>
						<div className="grid xl:grid-cols-2 gap-4">
							{hasGpuPowerData && <GpuPowerChart chartData={chartData} grid={grid} dataEmpty={dataEmpty} />}
						</div>
						{hasGpuData && lastGpus && (
							<GpuDetailCharts
								chartData={chartData}
								grid={grid}
								dataEmpty={dataEmpty}
								lastGpus={lastGpus as Record<string, GPUData>}
								hasGpuEnginesData={hasGpuEnginesData}
							/>
						)}
					</TabsContent>
				)}

				{hasHAProxyData && (
					<TabsContent value="haproxy" forceMount className={activeTab === "haproxy" ? "contents" : "hidden"}>
						{mountedTabs.has("haproxy") && (
							<>
								{/* HAProxy Info Panel */}
								{systemStats.at(-1)?.stats?.hapi && (
									<Card className="p-4">
										<CardHeader className="pb-4 pt-0 px-0">
											<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Process Info`}</CardTitle>
											<CardDescription>{t`HAProxy process statistics and runtime information`}</CardDescription>
										</CardHeader>
										<HAProxyInfoPanel info={systemStats.at(-1)?.stats?.hapi!} />
									</Card>
								)}

								{/* HAProxy Charts */}
								<div className="grid xl:grid-cols-2 gap-4">
									<ChartCard
										empty={dataEmpty}
										grid={grid}
										title={t`HAProxy Sessions`}
										description={t`Current sessions across frontends and backends`}
									>
										<HAProxyChart chartData={chartData} chartType="sessions" />
									</ChartCard>
									<ChartCard
										empty={dataEmpty}
										grid={grid}
										title={t`HAProxy Traffic`}
										description={t`Total bytes transferred (in + out)`}
									>
										<HAProxyChart chartData={chartData} chartType="traffic" />
									</ChartCard>
									<ChartCard
										empty={dataEmpty}
										grid={grid}
										title={t`HAProxy Request Rate`}
										description={t`HTTP requests per second`}
									>
										<HAProxyChart chartData={chartData} chartType="requests" />
									</ChartCard>
									<ChartCard
										empty={dataEmpty}
										grid={grid}
										title={t`HAProxy Response Time`}
										description={t`Average backend response time (ms)`}
									>
										<HAProxyChart chartData={chartData} chartType="response_time" />
									</ChartCard>
									<ChartCard
										empty={dataEmpty}
										grid={grid}
										title={t`HAProxy Error Rate`}
										description={t`HTTP 4xx and 5xx errors per second`}
									>
										<HAProxyChart chartData={chartData} chartType="errors" />
									</ChartCard>
									<ChartCard
										empty={dataEmpty}
										grid={grid}
										title={t`HAProxy HTTP Responses`}
										description={t`HTTP response codes per second (1xx-5xx)`}
									>
										<HAProxyResponsesChart chartData={chartData} />
									</ChartCard>
								</div>

								{/* HAProxy Status Table */}
								<Card className="p-4">
									<CardHeader className="pb-4 pt-0 px-0">
										<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Status`}</CardTitle>
										<CardDescription>{t`Current status of all HAProxy frontends, backends, and servers`}</CardDescription>
									</CardHeader>
									<HAProxyTable stats={systemStats.at(-1)?.stats?.hap ?? []} />
								</Card>

								{/* HAProxy Memory Pools */}
								{(systemStats.at(-1)?.stats?.hpp?.length ?? 0) > 0 && (
									<Card className="p-4">
										<CardHeader className="pb-4 pt-0 px-0">
											<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Memory Pools`}</CardTitle>
											<CardDescription>{t`Memory pool allocation and usage statistics`}</CardDescription>
										</CardHeader>
										<HAProxyPools
											pools={systemStats.at(-1)?.stats?.hpp ?? []}
											summary={systemStats.at(-1)?.stats?.hpps}
										/>
									</Card>
								)}

								{/* HAProxy Thread Activity */}
								{(systemStats.at(-1)?.stats?.hpa?.length ?? 0) > 0 && (
									<Card className="p-4">
										<CardHeader className="pb-4 pt-0 px-0">
											<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Thread Activity`}</CardTitle>
											<CardDescription>{t`Per-thread CPU usage and activity statistics`}</CardDescription>
										</CardHeader>
										<HAProxyActivity activity={systemStats.at(-1)?.stats?.hpa ?? []} />
									</Card>
								)}

								{/* HAProxy Server States */}
								{(systemStats.at(-1)?.stats?.hpsv?.length ?? 0) > 0 && (
									<Card className="p-4">
										<CardHeader className="pb-4 pt-0 px-0">
											<CardTitle className="text-xl sm:text-2xl">{t`HAProxy Server States`}</CardTitle>
											<CardDescription>{t`Detailed server state and configuration`}</CardDescription>
										</CardHeader>
										<HAProxyServers servers={systemStats.at(-1)?.stats?.hpsv ?? []} />
									</Card>
								)}
							</>
						)}
					</TabsContent>
				)}

				{hasContainers && (
					<TabsContent value="containers" forceMount className={activeTab === "containers" ? "contents" : "hidden"}>
						{mountedTabs.has("containers") && (
							<>
								<div className="grid xl:grid-cols-2 gap-4">
									<ContainerCpuChart
										chartData={chartData}
										grid={grid}
										dataEmpty={dataEmpty}
										isPodman={isPodman}
										cpuConfig={containerChartConfigs.cpu}
									/>
									<ContainerMemoryChart
										chartData={chartData}
										grid={grid}
										dataEmpty={dataEmpty}
										isPodman={isPodman}
										memoryConfig={containerChartConfigs.memory}
									/>
									<ContainerNetworkChart
										chartData={chartData}
										grid={grid}
										dataEmpty={dataEmpty}
										isPodman={isPodman}
										networkConfig={containerChartConfigs.network}
									/>
								</div>
								{hasContainersTable && <ContainersTable systemId={system.id} />}
							</>
						)}
					</TabsContent>
				)}

				{hasSystemd && (
					<TabsContent value="services" forceMount className={activeTab === "services" ? "contents" : "hidden"}>
						{mountedTabs.has("services") && <SystemdTable systemId={system.id} />}
					</TabsContent>
				)}
			</Tabs>
		)
	}

	return (
		<div className="grid gap-4 mb-14 overflow-x-clip">
			{/* system info */}
			<InfoBar
				system={system}
				chartData={chartData}
				grid={grid}
				setGrid={setGrid}
				displayMode={displayMode}
				setDisplayMode={setDisplayMode}
				details={details}
			/>

			{displayMode === "tabs" ? tabbedLayout() : defaultLayout()}
		</div>
	)
})
