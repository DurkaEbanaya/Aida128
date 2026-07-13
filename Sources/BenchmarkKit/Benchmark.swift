import BenchmarkCore
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
        var native = A128SystemInfo()
        try check(a128_read_system_info(&native))
        return convert(native)
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
            system: convert(nativeReport.system),
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
        return convertReport(nativeReport)
    }

    private static func check(_ status: A128Status) throws {
        guard status != A128_STATUS_OK else { return }
        let message = String(cString: a128_status_message(status))
        throw BenchmarkError.nativeFailure(code: status.rawValue, message: message)
    }

    private static func convert(_ native: A128SystemInfo) -> SystemInformation {
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
            firmware: string(from: native.firmware)
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

    private static func convertReport(_ nativeReport: A128Report) -> BenchmarkReport {
        var report = nativeReport
        let nativeMeasurements = withUnsafeBytes(of: &report.measurements) { bytes in
            Array(bytes.bindMemory(to: A128Measurement.self).prefix(Int(report.measurement_count)))
        }
        return BenchmarkReport(
            system: convert(report.system),
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
