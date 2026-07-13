import BenchmarkCore
import Darwin
import Foundation

public struct BenchmarkConfiguration: Sendable {
    public var sampleCount: UInt32
    public var minimumSampleDuration: Duration
    public var throughputWorkerCount: UInt32

    public init(
        sampleCount: UInt32 = 5,
        minimumSampleDuration: Duration = .milliseconds(200),
        throughputWorkerCount: UInt32 = 0
    ) {
        self.sampleCount = sampleCount
        self.minimumSampleDuration = minimumSampleDuration
        self.throughputWorkerCount = throughputWorkerCount
    }
}

public struct SystemInformation: Codable, Sendable {
    public let cpuName: String
    public let architecture: String
    public let backend: String
    public let memoryBytes: UInt64
    public let l1DataBytes: UInt64
    public let l2Bytes: UInt64
    public let l3Bytes: UInt64
    public let logicalCPUCount: UInt32
    public let cpuMicroarchitecture: String
    public let cpuSocket: String
    public let cpuFeatures: String
    public let cpuFamily: UInt32
    public let cpuModel: UInt32
    public let cpuStepping: UInt32
    public let cpuSignature: UInt32
    public let microcodeVersion: UInt32
    public let cpuBaseMegahertz: UInt32
    public let cpuMaxMegahertz: UInt32
    public let referenceClockMegahertz: UInt32
    public let memoryType: String
    public let memoryDataRate: UInt32
    public let memoryModuleCount: UInt32
    public let memoryManufacturer: String
    public let memoryPartNumber: String
    public let platformName: String
    public let motherboard: String
    public let chipset: String
    public let firmware: String
    public let hardwareMetadata: HardwareMetadata?

    public func isAvailable(_ level: CacheLevel) -> Bool {
        level != .l3 || (l2Bytes > 0 && l2Bytes <= l3Bytes / 2)
    }

    public var availableLevels: Set<CacheLevel> {
        Set(CacheLevel.allCases.filter(isAvailable))
    }

    public func displayName(for level: CacheLevel) -> String {
        level == .l3 && architecture == "arm64" ? "System Cache (SLC)" : level.rawValue
    }

    public func replacingHardwareMetadata(_ metadata: HardwareMetadata?) -> SystemInformation {
        BenchmarkRunner.replacingMetadata(in: self, with: metadata)
    }
}

public enum ProvenanceKind: String, Codable, Sendable {
    case unavailable
    case reported
    case derived
    case mapped
    case experimental
    case synthetic
}

public struct DiscoveryProvenance: Codable, Sendable {
    public let kind: ProvenanceKind
    public let source: String
    public let detail: String

    public var tooltip: String {
        [detail, source.isEmpty ? nil : "Source: \(source)"].compactMap { $0 }.joined(separator: "\n")
    }
}

public struct CPUPerformanceLevel: Codable, Sendable {
    public let name: String
    public let physicalCoreCount: UInt32
    public let logicalCPUCount: UInt32
    public let l1InstructionBytes: UInt64
    public let l1DataBytes: UInt64
    public let l2Bytes: UInt64
}

public struct HardwareMetadata: Codable, Sendable {
    public let socName: String
    public let socIdentifier: String
    public let processNode: String
    public let instructionSet: String
    public let hardwareModel: String
    public let boardIdentifier: String
    public let memoryTechnology: String
    public let gpuName: String?
    public let systemFirmware: String
    public let osLoaderVersion: String
    public let physicalCoreCount: UInt32
    public let performanceCoreCount: UInt32
    public let efficiencyCoreCount: UInt32
    public let performanceMaxMegahertz: UInt32
    public let efficiencyMaxMegahertz: UInt32
    public let gpuCoreCount: UInt32
    public let gpuMaxMegahertz: UInt32
    public let neuralEngineCoreCount: UInt32
    public let memoryBandwidthGigabytesPerSecond: UInt32
    public let memoryDataRateMTPS: UInt32
    public let performanceLevels: [CPUPerformanceLevel]
    public let systemCacheBytes: UInt64
    public let socProvenance: DiscoveryProvenance
    public let clockProvenance: DiscoveryProvenance
    public let topologyProvenance: DiscoveryProvenance
    public let memoryProvenance: DiscoveryProvenance
    public let gpuProvenance: DiscoveryProvenance
    public let systemCacheProvenance: DiscoveryProvenance
    public let firmwareProvenance: DiscoveryProvenance
    public let hardwareModelProvenance: DiscoveryProvenance?
    public let osLoaderProvenance: DiscoveryProvenance?
}

public enum CacheLevel: String, Codable, Sendable, CaseIterable {
    case l1 = "L1 Cache"
    case l2 = "L2 Cache"
    case l3 = "L3 Cache"
    case memory = "Memory"
}

public enum BenchmarkMetric: String, Codable, Sendable, CaseIterable {
    case read = "Read"
    case write = "Write"
    case copy = "Copy"
    case latency = "Latency"
}

public struct BenchmarkSelection: Sendable, Equatable {
    public let levels: Set<CacheLevel>
    public let metrics: Set<BenchmarkMetric>

    public init(levels: Set<CacheLevel>, metrics: Set<BenchmarkMetric>) {
        self.levels = levels
        self.metrics = metrics
    }

    public static let all = BenchmarkSelection(
        levels: Set(CacheLevel.allCases), metrics: Set(BenchmarkMetric.allCases)
    )

    public static func row(_ level: CacheLevel) -> BenchmarkSelection {
        BenchmarkSelection(levels: [level], metrics: Set(BenchmarkMetric.allCases))
    }

    public static func cell(level: CacheLevel, metric: BenchmarkMetric) -> BenchmarkSelection {
        BenchmarkSelection(levels: [level], metrics: [metric])
    }

    public var stageCount: Int { levels.count * metrics.count }
}

public enum BenchmarkProgressPhase: Sendable, Equatable {
    case started
    case calibrating
    case sampleCompleted
    case stageCompleted
    case runCompleted
}

public struct BenchmarkProgress: Sendable {
    public let phase: BenchmarkProgressPhase
    public let level: CacheLevel
    public let metric: BenchmarkMetric?
    public let completedStages: Int
    public let totalStages: Int
    public let completedSamples: Int
    public let sampleCount: Int
    public let measurement: BenchmarkMeasurement?

    public var fractionCompleted: Double {
        guard totalStages > 0 else { return 0 }
        let sampleFraction = phase == .sampleCompleted && sampleCount > 0
            ? Double(completedSamples) / Double(sampleCount) : 0
        return min(1, (Double(completedStages) + sampleFraction) / Double(totalStages))
    }
}

public enum MeasurementScope: String, Codable, Sendable {
    case singleWorker
    case aggregate
}

public struct BenchmarkMeasurement: Codable, Sendable {
    public let level: CacheLevel
    public let scope: MeasurementScope
    public let workingSetBytes: UInt64
    public let readGigabytesPerSecond: Double?
    public let writeGigabytesPerSecond: Double?
    public let copyGigabytesPerSecond: Double?
    public let latencyNanoseconds: Double?
    public let maximumRelativeSpread: Double

    public init(
        level: CacheLevel,
        scope: MeasurementScope = .aggregate,
        workingSetBytes: UInt64 = 0,
        readGigabytesPerSecond: Double? = nil,
        writeGigabytesPerSecond: Double? = nil,
        copyGigabytesPerSecond: Double? = nil,
        latencyNanoseconds: Double? = nil,
        maximumRelativeSpread: Double = 0
    ) {
        self.level = level
        self.scope = scope
        self.workingSetBytes = workingSetBytes
        self.readGigabytesPerSecond = readGigabytesPerSecond
        self.writeGigabytesPerSecond = writeGigabytesPerSecond
        self.copyGigabytesPerSecond = copyGigabytesPerSecond
        self.latencyNanoseconds = latencyNanoseconds
        self.maximumRelativeSpread = maximumRelativeSpread
    }
}

public struct BenchmarkReport: Codable, Sendable {
    public let system: SystemInformation
    public let measurements: [BenchmarkMeasurement]
    public let throughputWorkerCount: UInt32

    public init(
        system: SystemInformation,
        measurements: [BenchmarkMeasurement],
        throughputWorkerCount: UInt32
    ) {
        self.system = system
        self.measurements = measurements
        self.throughputWorkerCount = throughputWorkerCount
    }

    public var aidaMeasurements: [BenchmarkMeasurement] {
        CacheLevel.allCases.compactMap { level in
            if let combined = measurements.first(where: {
                $0.level == level && $0.readGigabytesPerSecond != nil &&
                    $0.writeGigabytesPerSecond != nil && $0.copyGigabytesPerSecond != nil &&
                    $0.latencyNanoseconds != nil
            }) {
                return combined
            }
            guard let throughput = measurements.first(where: {
                $0.level == level && $0.scope == .aggregate
            }), let latency = measurements.first(where: {
                $0.level == level && $0.scope == .singleWorker
            }) else { return nil }
            return BenchmarkMeasurement(
                level: level,
                scope: .aggregate,
                workingSetBytes: throughput.workingSetBytes,
                readGigabytesPerSecond: throughput.readGigabytesPerSecond,
                writeGigabytesPerSecond: throughput.writeGigabytesPerSecond,
                copyGigabytesPerSecond: throughput.copyGigabytesPerSecond,
                latencyNanoseconds: latency.latencyNanoseconds,
                maximumRelativeSpread: max(
                    throughput.maximumRelativeSpread, latency.maximumRelativeSpread
                )
            )
        }
    }
}

public enum BenchmarkError: Error, LocalizedError {
    case nativeFailure(code: UInt32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .nativeFailure(code, message): "Benchmark core failed (\(code)): \(message)"
        }
    }
}

public enum BenchmarkRunner {
    public static func systemInformation() throws -> SystemInformation {
        try readExtendedSystemInformation()
    }

    public static func enrichedSystemInformation() async throws -> SystemInformation {
        await enriched(try systemInformation())
    }

    public static func enriched(_ system: SystemInformation) async -> SystemInformation {
        await enrich(system)
    }

    public static func enriched(_ report: BenchmarkReport) async -> BenchmarkReport {
        let system = await enrich(report.system)
        return BenchmarkReport(
            system: system,
            measurements: report.measurements,
            throughputWorkerCount: report.throughputWorkerCount
        )
    }

    public static func run(configuration: BenchmarkConfiguration = .init()) throws -> BenchmarkReport {
        let components = configuration.minimumSampleDuration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            throw BenchmarkError.nativeFailure(code: 1, message: "sample duration must be positive")
        }
        let nanoseconds = UInt64(components.seconds) * 1_000_000_000 +
            UInt64(components.attoseconds / 1_000_000_000)
        var nativeConfiguration = A128Configuration(
            sample_count: configuration.sampleCount,
            minimum_sample_nanoseconds: nanoseconds,
            throughput_worker_count: configuration.throughputWorkerCount
        )
        var nativeReport = A128Report()
        try check(a128_run_benchmark(&nativeConfiguration, &nativeReport))

        let nativeMeasurements = withUnsafeBytes(of: &nativeReport.measurements) { bytes in
            Array(bytes.bindMemory(to: A128Measurement.self).prefix(Int(nativeReport.measurement_count)))
        }
        return BenchmarkReport(
            system: systemInformation(from: nativeReport.system),
            measurements: nativeMeasurements.map(convertMeasurement),
            throughputWorkerCount: nativeReport.throughput_worker_count
        )
    }

    public static func runSelected(
        selection: BenchmarkSelection,
        totalDuration: Duration,
        sampleCount: UInt32 = 5,
        throughputWorkerCount: UInt32 = 0,
        progress: @escaping @Sendable (BenchmarkProgress) -> Void
    ) throws -> BenchmarkReport {
        guard !selection.levels.isEmpty, !selection.metrics.isEmpty else {
            throw BenchmarkError.nativeFailure(code: 1, message: "benchmark selection must not be empty")
        }
        let components = totalDuration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            throw BenchmarkError.nativeFailure(code: 1, message: "total duration must be positive")
        }
        let nanoseconds = UInt64(components.seconds) * 1_000_000_000 +
            UInt64(components.attoseconds / 1_000_000_000)
        var nativeConfiguration = A128RunConfiguration(
            struct_size: UInt32(MemoryLayout<A128RunConfiguration>.size),
            level_mask: levelMask(selection.levels),
            metric_mask: metricMask(selection.metrics),
            sample_count: sampleCount,
            throughput_worker_count: throughputWorkerCount,
            total_run_nanoseconds: nanoseconds
        )
        var nativeReport = A128Report()
        let box = ProgressBox(callback: progress)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }
        try check(a128_run_benchmark_v2(
            &nativeConfiguration,
            nativeProgressCallback,
            context,
            &nativeReport
        ))
        return try convertReport(nativeReport)
    }

    private static func check(_ status: A128Status) throws {
        guard status != A128_STATUS_OK else { return }
        let message = String(cString: a128_status_message(status))
        throw BenchmarkError.nativeFailure(code: status.rawValue, message: message)
    }

    private static func convert(
        _ native: A128SystemInfo,
        metadata: HardwareMetadata? = nil
    ) -> SystemInformation {
        SystemInformation(
            cpuName: string(from: native.cpu_name),
            architecture: string(from: native.architecture),
            backend: string(from: native.backend),
            memoryBytes: native.memory_bytes,
            l1DataBytes: native.l1_data_bytes,
            l2Bytes: native.l2_bytes,
            l3Bytes: native.l3_bytes,
            logicalCPUCount: native.logical_cpu_count,
            cpuMicroarchitecture: string(from: native.cpu_microarchitecture),
            cpuSocket: string(from: native.cpu_socket),
            cpuFeatures: string(from: native.cpu_features),
            cpuFamily: native.cpu_family,
            cpuModel: native.cpu_model,
            cpuStepping: native.cpu_stepping,
            cpuSignature: native.cpu_signature,
            microcodeVersion: native.microcode_version,
            cpuBaseMegahertz: native.cpu_base_megahertz,
            cpuMaxMegahertz: native.cpu_max_megahertz,
            referenceClockMegahertz: native.reference_clock_megahertz,
            memoryType: string(from: native.memory_type),
            memoryDataRate: native.memory_data_rate,
            memoryModuleCount: native.memory_module_count,
            memoryManufacturer: string(from: native.memory_manufacturer),
            memoryPartNumber: string(from: native.memory_part_number),
            platformName: string(from: native.platform_name),
            motherboard: string(from: native.motherboard),
            chipset: string(from: native.chipset),
            firmware: string(from: native.firmware),
            hardwareMetadata: metadata
        )
    }

    private static func readExtendedSystemInformation() throws -> SystemInformation {
        var native = A128SystemInfoV2()
        try check(a128_read_system_info_v2(&native, MemoryLayout<A128SystemInfoV2>.size))
        guard native.schema_version >= UInt32(A128_SYSTEM_INFO_V2_SCHEMA_VERSION),
              native.struct_size >= UInt32(
                MemoryLayout<A128SystemInfoV2>.offset(of: \A128SystemInfoV2.legacy)! +
                    MemoryLayout<A128SystemInfo>.size
              ) else {
            throw BenchmarkError.nativeFailure(code: 4, message: "unsupported system metadata schema")
        }
        return convert(native.legacy, metadata: convertMetadata(native))
    }

    private static func systemInformation(from legacy: A128SystemInfo) -> SystemInformation {
        var native = A128SystemInfoV2()
        let metadata: HardwareMetadata?
        if a128_read_system_info_v2(&native, MemoryLayout<A128SystemInfoV2>.size) == A128_STATUS_OK,
           native.schema_version >= UInt32(A128_SYSTEM_INFO_V2_SCHEMA_VERSION) {
            metadata = convertMetadata(native)
        } else {
            metadata = nil
        }
        return convert(legacy, metadata: metadata)
    }

    private static func enrich(_ system: SystemInformation) async -> SystemInformation {
        guard let metadata = system.hardwareMetadata,
              let profiler = await SystemProfilerSnapshot.read() else {
            return system
        }
        return replacingMetadata(in: system, with: enrich(metadata, profiler: profiler))
    }

    private static func enrich(
        _ metadata: HardwareMetadata,
        profiler: SystemProfilerSnapshot
    ) -> HardwareMetadata {
        let profilerFirmware = metadata.firmwareProvenance.kind == .synthetic
            ? nil : profiler.systemFirmware
        let gpuProvenance = profiler.gpuName == nil ? metadata.gpuProvenance : DiscoveryProvenance(
            kind: .reported,
            source: "system_profiler SPDisplaysDataType",
            detail: profiler.gpuCoreCount == nil
                ? "Integrated GPU identity reported by macOS; enabled core count was unavailable."
                : "Integrated GPU identity and enabled core count reported by macOS."
        )
        return HardwareMetadata(
            socName: metadata.socName,
            socIdentifier: metadata.socIdentifier,
            processNode: metadata.processNode,
            instructionSet: metadata.instructionSet,
            hardwareModel: profiler.hardwareModel ?? metadata.hardwareModel,
            boardIdentifier: metadata.boardIdentifier,
            memoryTechnology: metadata.memoryTechnology,
            gpuName: profiler.gpuName ?? metadata.gpuName,
            systemFirmware: profilerFirmware ?? metadata.systemFirmware,
            osLoaderVersion: profiler.osLoaderVersion ?? metadata.osLoaderVersion,
            physicalCoreCount: metadata.physicalCoreCount,
            performanceCoreCount: metadata.performanceCoreCount,
            efficiencyCoreCount: metadata.efficiencyCoreCount,
            performanceMaxMegahertz: metadata.performanceMaxMegahertz,
            efficiencyMaxMegahertz: metadata.efficiencyMaxMegahertz,
            gpuCoreCount: profiler.gpuCoreCount ?? metadata.gpuCoreCount,
            gpuMaxMegahertz: metadata.gpuMaxMegahertz,
            neuralEngineCoreCount: metadata.neuralEngineCoreCount,
            memoryBandwidthGigabytesPerSecond: metadata.memoryBandwidthGigabytesPerSecond,
            memoryDataRateMTPS: metadata.memoryDataRateMTPS,
            performanceLevels: metadata.performanceLevels,
            systemCacheBytes: metadata.systemCacheBytes,
            socProvenance: metadata.socProvenance,
            clockProvenance: metadata.clockProvenance,
            topologyProvenance: metadata.topologyProvenance,
            memoryProvenance: metadata.memoryProvenance,
            gpuProvenance: gpuProvenance,
            systemCacheProvenance: metadata.systemCacheProvenance,
            firmwareProvenance: profilerFirmware == nil
                ? metadata.firmwareProvenance : DiscoveryProvenance(
                    kind: .reported,
                    source: "system_profiler SPHardwareDataType",
                    detail: "System firmware version reported by macOS."
                ),
            hardwareModelProvenance: profiler.hardwareModel == nil
                ? metadata.hardwareModelProvenance : DiscoveryProvenance(
                    kind: .reported,
                    source: "system_profiler SPHardwareDataType",
                    detail: "Hardware model reported by macOS."
                ),
            osLoaderProvenance: profiler.osLoaderVersion == nil
                ? metadata.osLoaderProvenance : DiscoveryProvenance(
                    kind: .reported,
                    source: "system_profiler SPHardwareDataType",
                    detail: "OS loader version reported by macOS."
                )
        )
    }

    fileprivate static func replacingMetadata(
        in system: SystemInformation,
        with metadata: HardwareMetadata?
    ) -> SystemInformation {
        SystemInformation(
            cpuName: system.cpuName, architecture: system.architecture, backend: system.backend,
            memoryBytes: system.memoryBytes, l1DataBytes: system.l1DataBytes,
            l2Bytes: system.l2Bytes, l3Bytes: system.l3Bytes,
            logicalCPUCount: system.logicalCPUCount,
            cpuMicroarchitecture: system.cpuMicroarchitecture, cpuSocket: system.cpuSocket,
            cpuFeatures: system.cpuFeatures, cpuFamily: system.cpuFamily,
            cpuModel: system.cpuModel, cpuStepping: system.cpuStepping,
            cpuSignature: system.cpuSignature, microcodeVersion: system.microcodeVersion,
            cpuBaseMegahertz: system.cpuBaseMegahertz, cpuMaxMegahertz: system.cpuMaxMegahertz,
            referenceClockMegahertz: system.referenceClockMegahertz,
            memoryType: system.memoryType, memoryDataRate: system.memoryDataRate,
            memoryModuleCount: system.memoryModuleCount,
            memoryManufacturer: system.memoryManufacturer,
            memoryPartNumber: system.memoryPartNumber, platformName: system.platformName,
            motherboard: system.motherboard, chipset: system.chipset,
            firmware: system.firmware, hardwareMetadata: metadata
        )
    }

    private static func convertMetadata(_ native: A128SystemInfoV2) -> HardwareMetadata {
        var copy = native
        let levels = withUnsafeBytes(of: &copy.performance_levels) { bytes in
            Array(bytes.bindMemory(to: A128PerformanceLevel.self)
                .prefix(Int(min(copy.performance_level_count, UInt32(A128_MAX_PERFORMANCE_LEVELS)))))
                .map { level in
                    CPUPerformanceLevel(
                        name: string(from: level.name),
                        physicalCoreCount: level.physical_core_count,
                        logicalCPUCount: level.logical_cpu_count,
                        l1InstructionBytes: level.l1_instruction_bytes,
                        l1DataBytes: level.l1_data_bytes,
                        l2Bytes: level.l2_bytes
                    )
                }
        }
        let nativeGPUName = string(from: native.gpu_name).nilIfEmpty
        let nativeFirmwareProvenance = convertProvenance(native.firmware_provenance)
        return HardwareMetadata(
            socName: string(from: native.soc_name),
            socIdentifier: string(from: native.soc_identifier),
            processNode: string(from: native.process_node),
            instructionSet: string(from: native.instruction_set),
            hardwareModel: string(from: native.hardware_model),
            boardIdentifier: string(from: native.board_identifier),
            memoryTechnology: string(from: native.memory_technology),
            gpuName: nativeGPUName,
            systemFirmware: string(from: native.system_firmware),
            osLoaderVersion: string(from: native.os_loader_version),
            physicalCoreCount: native.physical_core_count,
            performanceCoreCount: native.performance_core_count,
            efficiencyCoreCount: native.efficiency_core_count,
            performanceMaxMegahertz: native.performance_max_megahertz,
            efficiencyMaxMegahertz: native.efficiency_max_megahertz,
            gpuCoreCount: native.gpu_core_count,
            gpuMaxMegahertz: native.gpu_max_megahertz,
            neuralEngineCoreCount: native.neural_engine_core_count,
            memoryBandwidthGigabytesPerSecond: native.memory_bandwidth_gigabytes_per_second,
            memoryDataRateMTPS: native.memory_data_rate_mtps,
            performanceLevels: levels,
            systemCacheBytes: native.system_cache_bytes,
            socProvenance: convertProvenance(native.soc_provenance),
            clockProvenance: convertProvenance(native.clock_provenance),
            topologyProvenance: convertProvenance(native.topology_provenance),
            memoryProvenance: convertProvenance(native.memory_provenance),
            gpuProvenance: convertProvenance(native.gpu_provenance),
            systemCacheProvenance: convertProvenance(native.system_cache_provenance),
            firmwareProvenance: nativeFirmwareProvenance,
            hardwareModelProvenance: nil,
            osLoaderProvenance: nil
        )
    }

    private static func convertProvenance(_ native: A128Provenance) -> DiscoveryProvenance {
        let kind: ProvenanceKind = switch native.kind {
        case A128_PROVENANCE_REPORTED: .reported
        case A128_PROVENANCE_DERIVED: .derived
        case A128_PROVENANCE_MAPPED: .mapped
        case A128_PROVENANCE_EXPERIMENTAL: .experimental
        case A128_PROVENANCE_SYNTHETIC: .synthetic
        default: .unavailable
        }
        return DiscoveryProvenance(
            kind: kind,
            source: string(from: native.source),
            detail: string(from: native.detail)
        )
    }

    fileprivate static func convertMeasurement(_ native: A128Measurement) -> BenchmarkMeasurement {
        let level: CacheLevel = switch native.level {
        case A128_LEVEL_L1: .l1
        case A128_LEVEL_L2: .l2
        case A128_LEVEL_L3: .l3
        default: .memory
        }
        let scope: MeasurementScope = native.scope == A128_SCOPE_AGGREGATE ? .aggregate : .singleWorker
        let metrics = native.available_metrics
        return BenchmarkMeasurement(
            level: level,
            scope: scope,
            workingSetBytes: native.working_set_bytes,
            readGigabytesPerSecond: metrics & UInt32(A128_METRIC_READ.rawValue) != 0
                ? native.read_gigabytes_per_second : nil,
            writeGigabytesPerSecond: metrics & UInt32(A128_METRIC_WRITE.rawValue) != 0
                ? native.write_gigabytes_per_second : nil,
            copyGigabytesPerSecond: metrics & UInt32(A128_METRIC_COPY.rawValue) != 0
                ? native.copy_gigabytes_per_second : nil,
            latencyNanoseconds: metrics & UInt32(A128_METRIC_LATENCY.rawValue) != 0
                ? native.latency_nanoseconds : nil,
            maximumRelativeSpread: native.maximum_relative_spread
        )
    }

    private static func convertReport(_ nativeReport: A128Report) throws -> BenchmarkReport {
        var report = nativeReport
        let nativeMeasurements = withUnsafeBytes(of: &report.measurements) { bytes in
            Array(bytes.bindMemory(to: A128Measurement.self).prefix(Int(report.measurement_count)))
        }
        return BenchmarkReport(
            system: systemInformation(from: report.system),
            measurements: nativeMeasurements.map(convertMeasurement),
            throughputWorkerCount: report.throughput_worker_count
        )
    }

    fileprivate static func convertLevel(_ native: A128Level) -> CacheLevel {
        switch native {
        case A128_LEVEL_L1: .l1
        case A128_LEVEL_L2: .l2
        case A128_LEVEL_L3: .l3
        default: .memory
        }
    }

    private static func levelMask(_ levels: Set<CacheLevel>) -> UInt32 {
        levels.reduce(0) { result, level in
            let bit: UInt32 = switch level {
            case .l1: UInt32(A128_LEVEL_MASK_L1)
            case .l2: UInt32(A128_LEVEL_MASK_L2)
            case .l3: UInt32(A128_LEVEL_MASK_L3)
            case .memory: UInt32(A128_LEVEL_MASK_MEMORY)
            }
            return result | bit
        }
    }

    private static func metricMask(_ metrics: Set<BenchmarkMetric>) -> UInt32 {
        metrics.reduce(0) { result, metric in
            let bit: UInt32 = switch metric {
            case .read: UInt32(A128_METRIC_READ.rawValue)
            case .write: UInt32(A128_METRIC_WRITE.rawValue)
            case .copy: UInt32(A128_METRIC_COPY.rawValue)
            case .latency: UInt32(A128_METRIC_LATENCY.rawValue)
            }
            return result | bit
        }
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            let characters = bytes.prefix { $0 != 0 }
            return String(decoding: characters, as: UTF8.self)
        }
    }
}

private func nativeProgressCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<A128ProgressEvent>?
) {
    guard let context, let event else { return }
    Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().receive(event.pointee)
}

private final class ProgressBox: @unchecked Sendable {
    let callback: @Sendable (BenchmarkProgress) -> Void
    init(callback: @escaping @Sendable (BenchmarkProgress) -> Void) {
        self.callback = callback
    }

    func receive(_ event: A128ProgressEvent) {
        let metric: BenchmarkMetric? = switch event.metric {
        case UInt32(A128_METRIC_READ.rawValue): .read
        case UInt32(A128_METRIC_WRITE.rawValue): .write
        case UInt32(A128_METRIC_COPY.rawValue): .copy
        case UInt32(A128_METRIC_LATENCY.rawValue): .latency
        default: nil
        }
        let phase: BenchmarkProgressPhase = switch event.phase {
        case A128_PROGRESS_STAGE_STARTED: .started
        case A128_PROGRESS_CALIBRATING: .calibrating
        case A128_PROGRESS_SAMPLE_COMPLETED: .sampleCompleted
        case A128_PROGRESS_STAGE_COMPLETED: .stageCompleted
        default: .runCompleted
        }
        callback(BenchmarkProgress(
            phase: phase,
            level: BenchmarkRunner.convertLevel(event.level),
            metric: metric,
            completedStages: Int(event.completed_stage_count),
            totalStages: Int(event.total_stage_count),
            completedSamples: Int(event.completed_sample_count),
            sampleCount: Int(event.sample_count),
            measurement: phase == .stageCompleted
                ? BenchmarkRunner.convertMeasurement(event.measurement) : nil
        ))
    }
}

private struct SystemProfilerSnapshot: Sendable {
    let hardwareModel: String?
    let systemFirmware: String?
    let osLoaderVersion: String?
    let gpuName: String?
    let gpuCoreCount: UInt32?

    static func read() async -> SystemProfilerSnapshot? {
        let operation = SystemProfilerOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.start(continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    fileprivate static func load(registerRunning: (Process) -> Void) -> SystemProfilerSnapshot? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "SPDisplaysDataType", "-json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
            registerRunning(process)
            try? output.fileHandleForWriting.close()
            let reader = ProfilerOutputReader(handle: output.fileHandleForReading)
            reader.start()
            if terminated.wait(timeout: .now() + 8) == .timedOut {
                process.terminate()
                if terminated.wait(timeout: .now() + 1) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    terminated.wait()
                }
            }
            reader.wait()
            let data = reader.data
            guard process.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let hardware = (root["SPHardwareDataType"] as? [[String: Any]])?.first
            let display = (root["SPDisplaysDataType"] as? [[String: Any]])?.first(where: { item in
                let name = item["sppci_model"] as? String ?? item["_name"] as? String
                return name?.contains("Apple") == true
            })
            return SystemProfilerSnapshot(
                hardwareModel: hardware?["machine_model"] as? String,
                systemFirmware: hardware?["boot_rom_version"] as? String,
                osLoaderVersion: hardware?["os_loader_version"] as? String,
                gpuName: display?["sppci_model"] as? String ?? display?["_name"] as? String,
                gpuCoreCount: uint32(display?["sppci_cores"])
            )
        } catch {
            return nil
        }
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        if let string = value as? String {
            return UInt32(string.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
        }
        return nil
    }
}

private final class SystemProfilerOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(continuation: CheckedContinuation<SystemProfilerSnapshot?, Never>) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = SystemProfilerSnapshot.load { candidate in
                lock.withLock {
                    process = candidate
                    if cancelled { Darwin.kill(candidate.processIdentifier, SIGKILL) }
                }
            }
            lock.withLock { process = nil }
            continuation.resume(returning: result)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            guard let process, process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class ProfilerOutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.durkaebanaya.aida128.system-profiler")
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var storage = Data()

    init(handle: FileHandle) { self.handle = handle }

    var data: Data { lock.withLock { storage } }

    func start() {
        group.enter()
        queue.async { [self] in
            let value = handle.readDataToEndOfFile()
            lock.withLock { storage = value }
            group.leave()
        }
    }

    func wait() { group.wait() }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
