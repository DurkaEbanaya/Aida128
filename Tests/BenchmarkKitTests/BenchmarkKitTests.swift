import BenchmarkKit
import BenchmarkCore
import Foundation
import Testing

@Suite(.serialized)
struct NativeBenchmarkTests {

@Test func systemInformationReflectsNativeProcess() throws {
    let information = try BenchmarkRunner.systemInformation()
    #expect(information.l1DataBytes > 0)
    #expect(information.l2Bytes > information.l1DataBytes)
    #expect(information.memoryBytes > information.l2Bytes)
    #if arch(x86_64)
    #expect(information.architecture == "x86_64")
    #expect(information.backend == "AVX2 cached")
    #expect(information.cpuFamily > 0)
    #expect(information.cpuModel > 0)
    #expect(information.cpuSignature > 0)
    #expect(information.cpuBaseMegahertz > 0)
    #expect(information.cpuMaxMegahertz >= information.cpuBaseMegahertz)
    if information.cpuFamily == 6 && information.cpuModel == 0xB7 {
        #expect(information.cpuStepping == 1)
        #expect(information.cpuMicroarchitecture == "Raptor Lake-S")
        #expect(information.cpuSocket == "LGA1700")
        #expect(information.cpuBaseMegahertz == 3500)
        #expect(information.cpuMaxMegahertz == 5300)
        #expect(information.referenceClockMegahertz == 100)
    }
    #expect(!information.memoryType.isEmpty)
    #expect(information.memoryDataRate > 0)
    #expect(information.memoryModuleCount > 0)
    #expect(information.cpuFeatures.contains("AVX2"))
    #elseif arch(arm64)
    #expect(information.architecture == "arm64")
    #expect(information.backend == "ARM NEON cached")
    #expect(information.cpuFeatures.contains("NEON"))
    #endif
    #expect(information.hardwareMetadata != nil)
    #expect(information.hardwareMetadata?.physicalCoreCount ?? 0 > 0)
    #expect(information.displayName(for: .l3) == (information.architecture == "arm64"
        ? "System Cache (SLC)" : "L3 Cache"))
}

@Test func extendedSystemInfoHonorsCallerBufferSize() {
    let minimumSize = MemoryLayout<A128SystemInfoV2>.offset(of: \A128SystemInfoV2.legacy)! +
        MemoryLayout<A128SystemInfo>.size
    let fullSize = MemoryLayout<A128SystemInfoV2>.size
    let guardSize = 64
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: fullSize + guardSize,
        alignment: MemoryLayout<A128SystemInfoV2>.alignment
    )
    defer { storage.deallocate() }
    storage.initializeMemory(as: UInt8.self, repeating: 0xA5, count: fullSize + guardSize)
    let output = storage.assumingMemoryBound(to: A128SystemInfoV2.self)
    #expect(a128_read_system_info_v2(output, minimumSize - 1) == A128_STATUS_INVALID_ARGUMENT)
    let status = a128_read_system_info_v2(output, minimumSize)
    #expect(status == A128_STATUS_OK)
    #expect(output.pointee.struct_size == UInt32(minimumSize))
    #expect(output.pointee.schema_version == UInt32(A128_SYSTEM_INFO_V2_SCHEMA_VERSION))
    let guardBytes = UnsafeRawBufferPointer(
        start: storage + minimumSize,
        count: fullSize + guardSize - minimumSize
    )
    #expect(guardBytes.allSatisfy { $0 == 0xA5 })

    storage.initializeMemory(as: UInt8.self, repeating: 0xA5, count: fullSize + guardSize)
    #expect(a128_read_system_info_v2(output, fullSize + guardSize) == A128_STATUS_OK)
    #expect(output.pointee.struct_size == UInt32(fullSize))
    let oversizedGuard = UnsafeRawBufferPointer(start: storage + fullSize, count: guardSize)
    #expect(oversizedGuard.allSatisfy { $0 == 0xA5 })
}

@Test func legacyABILayoutIsStable() {
    #expect(MemoryLayout<A128SystemInfo>.size == 1968)
    #expect(MemoryLayout<A128Report>.size == 2488)
    #expect(MemoryLayout<A128Report>.offset(of: \A128Report.system) == 0)
    #expect(MemoryLayout<A128Report>.offset(of: \A128Report.measurements) == 1968)
    #expect(MemoryLayout<A128Report>.offset(of: \A128Report.measurement_count) == 2480)
}

@Test func reportsWithoutHardwareMetadataStillDecode() throws {
    let system = try BenchmarkRunner.systemInformation()
    let report = BenchmarkReport(system: system, measurements: [], throughputWorkerCount: 1)
    let encoded = try JSONEncoder().encode(report)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var legacySystem = try #require(object["system"] as? [String: Any])
    legacySystem.removeValue(forKey: "hardwareMetadata")
    object["system"] = legacySystem
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: legacyData)
    #expect(decoded.system.hardwareMetadata == nil)
    #expect(decoded.system.architecture == system.architecture)
}

@Test func reportsWithLegacyHardwareMetadataStillDecode() throws {
    let system = try BenchmarkRunner.systemInformation()
    let report = BenchmarkReport(system: system, measurements: [], throughputWorkerCount: 1)
    let encoded = try JSONEncoder().encode(report)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var legacySystem = try #require(object["system"] as? [String: Any])
    guard var metadata = legacySystem["hardwareMetadata"] as? [String: Any] else { return }
    metadata.removeValue(forKey: "superCoreCount")
    legacySystem["hardwareMetadata"] = metadata
    object["system"] = legacySystem
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: legacyData)
    #expect(decoded.system.hardwareMetadata?.superCoreCount == 0)
    #expect(decoded.system.architecture == system.architecture)
}

@Test func swiftAvailabilityMatchesNativeLLCContainmentBoundary() throws {
    let system = try BenchmarkRunner.systemInformation()
    func replacingCacheHierarchy(l2Bytes: UInt64, l3Bytes: UInt64) throws -> SystemInformation {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(system)) as? [String: Any]
        )
        object["l2Bytes"] = l2Bytes
        object["l3Bytes"] = l3Bytes
        return try JSONDecoder().decode(
            SystemInformation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
    let unavailable = try replacingCacheHierarchy(l2Bytes: 8, l3Bytes: 15)
    let available = try replacingCacheHierarchy(l2Bytes: 8, l3Bytes: 16)
    #expect(!unavailable.isAvailable(.l3))
    #expect(available.isAvailable(.l3))
}

@Test func experimentalSystemCacheIsExplicitRunIntent() throws {
    let system = try BenchmarkRunner.systemInformation()
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(system)) as? [String: Any]
    )
    var metadata = try #require(object["hardwareMetadata"] as? [String: Any])
    object["architecture"] = "arm64"
    object["l2Bytes"] = UInt64(8)
    object["l3Bytes"] = UInt64(0)
    metadata["systemCacheBytes"] = UInt64(16)
    object["hardwareMetadata"] = metadata
    let experimentalCandidate = try JSONDecoder().decode(
        SystemInformation.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(!experimentalCandidate.isAvailable(.l3))
    #expect(!experimentalCandidate.isRunnable(.l3))
    #expect(experimentalCandidate.isRunnable(.l3, options: [.experimentalSystemCache]))
}

@Test func runConfigurationPrefixSizeAndOptionBitsAreContracted() throws {
    let prefixSize = MemoryLayout<A128RunConfiguration>
        .offset(of: \A128RunConfiguration.total_run_nanoseconds)! + MemoryLayout<UInt64>.size
    var prefixConfiguration = A128RunConfiguration(
        struct_size: UInt32(prefixSize),
        level_mask: UInt32(A128_LEVEL_MASK_MEMORY),
        metric_mask: UInt32(A128_METRIC_READ.rawValue),
        sample_count: 3,
        throughput_worker_count: 1,
        total_run_nanoseconds: 30_000_000,
        options: UInt32.max,
        reserved: UInt32.max
    )
    var report = A128Report()
    #expect(a128_run_benchmark_v2(&prefixConfiguration, nil, nil, &report) == A128_STATUS_OK)
    #expect(report.measurement_count == 1)

    var invalidOptions = prefixConfiguration
    invalidOptions.struct_size = UInt32(MemoryLayout<A128RunConfiguration>.size)
    invalidOptions.options = 1 << 31
    invalidOptions.reserved = 0
    #expect(a128_run_benchmark_v2(&invalidOptions, nil, nil, &report) == A128_STATUS_INVALID_ARGUMENT)

    var invalidReserved = prefixConfiguration
    invalidReserved.struct_size = UInt32(MemoryLayout<A128RunConfiguration>.size)
    invalidReserved.options = UInt32(A128_RUN_OPTION_EXPERIMENTAL_SYSTEM_CACHE.rawValue)
    invalidReserved.reserved = 1
    #expect(a128_run_benchmark_v2(&invalidReserved, nil, nil, &report) == A128_STATUS_INVALID_ARGUMENT)
}

@Test func selectedCellRunsOnlyRequestedStage() throws {
    let events = ProgressRecorder()
    let report = try BenchmarkRunner.runSelected(
        selection: .cell(level: .l2, metric: .copy),
        totalDuration: .milliseconds(30),
        sampleCount: 3,
        progress: events.record
    )
    #expect(report.measurements.count == 1)
    #expect(report.measurements[0].level == .l2)
    #expect(report.measurements[0].copyGigabytesPerSecond != nil)
    #expect(report.measurements[0].readGigabytesPerSecond == nil)
    #expect(report.measurements[0].writeGigabytesPerSecond == nil)
    #expect(report.measurements[0].latencyNanoseconds == nil)
    let completed = events.values.filter { $0.phase == .stageCompleted }
    #expect(completed.count == 1)
    #expect(completed[0].level == .l2)
    #expect(completed[0].metric == .copy)
}

@Test func selectedFullRowIsDirectlyRenderable() throws {
    let report = try BenchmarkRunner.runSelected(
        selection: .row(.l1),
        totalDuration: .milliseconds(120),
        sampleCount: 3,
        progress: { _ in }
    )
    #expect(report.aidaMeasurements.count == 1)
    #expect(report.aidaMeasurements[0].level == .l1)
    #expect(report.aidaMeasurements[0].latencyNanoseconds != nil)
}

@Test func aidaMeasurementsMergeAggregateThroughputWithSingleLatency() throws {
    let system = try BenchmarkRunner.systemInformation()
    let report = BenchmarkReport(
        system: system,
        measurements: [
            BenchmarkMeasurement(
                level: .l1,
                scope: .singleWorker,
                workingSetBytes: 24 * 1024,
                readGigabytesPerSecond: 1,
                writeGigabytesPerSecond: 2,
                copyGigabytesPerSecond: 3,
                latencyNanoseconds: 4,
                maximumRelativeSpread: 0.1
            ),
            BenchmarkMeasurement(
                level: .l1,
                scope: .aggregate,
                workingSetBytes: 480 * 1024,
                readGigabytesPerSecond: 10,
                writeGigabytesPerSecond: 20,
                copyGigabytesPerSecond: 30,
                latencyNanoseconds: nil,
                maximumRelativeSpread: 0.2
            ),
        ],
        throughputWorkerCount: 20
    )
    let row = try #require(report.aidaMeasurements.first)
    #expect(row.scope == .aggregate)
    #expect(row.workingSetBytes == 480 * 1024)
    #expect(row.readGigabytesPerSecond == 10)
    #expect(row.writeGigabytesPerSecond == 20)
    #expect(row.copyGigabytesPerSecond == 30)
    #expect(row.latencyNanoseconds == 4)
    #expect(row.maximumRelativeSpread == 0.2)
}

@Test func selectedRowUsesVisibleMetricOrder() throws {
    let events = ProgressRecorder()
    _ = try BenchmarkRunner.runSelected(
        selection: .row(.memory),
        totalDuration: .milliseconds(120),
        sampleCount: 3,
        progress: events.record
    )
    let order = events.values.compactMap { event in
        event.phase == .stageCompleted ? event.metric : nil
    }
    #expect(order == [.read, .write, .copy, .latency])
}

@Test func fullSelectionUsesVisibleLevelOrderAndMonotonicProgress() throws {
    let information = try BenchmarkRunner.systemInformation()
    let events = ProgressRecorder()
    _ = try BenchmarkRunner.runSelected(
        selection: .all,
        totalDuration: .milliseconds(480),
        sampleCount: 3,
        progress: events.record
    )
    let completed = events.values.filter { $0.phase == .stageCompleted }
    let expectedLevels = [CacheLevel.memory, .l1, .l2, .l3].filter(information.isAvailable)
    #expect(completed.count == expectedLevels.count * 4)
    #expect(Array(completed.prefix(4)).allSatisfy { $0.level == .memory })
    #expect(Array(completed[4..<8]).allSatisfy { $0.level == .l1 })
    #expect(Array(completed[8..<12]).allSatisfy { $0.level == .l2 })
    if information.isAvailable(.l3) {
        #expect(Array(completed[12..<16]).allSatisfy { $0.level == .l3 })
    }
    let fractions = events.values.map(\.fractionCompleted)
    #expect(zip(fractions, fractions.dropFirst()).allSatisfy(<=))
    #expect(events.values.last?.phase == .runCompleted)
    #expect(events.values.last?.fractionCompleted == 1)
}

@Test func callbackReentrantRunIsRejectedWithoutBlocking() throws {
    let rejection = NativeFailureRecorder()
    _ = try BenchmarkRunner.runSelected(
        selection: .cell(level: .l1, metric: .read),
        totalDuration: .milliseconds(30),
        sampleCount: 3
    ) { progress in
        guard progress.phase == .started, rejection.code == nil else { return }
        do {
            _ = try BenchmarkRunner.run(configuration: .init(
                sampleCount: 3,
                minimumSampleDuration: .milliseconds(10),
                throughputWorkerCount: 1
            ))
        } catch let BenchmarkError.nativeFailure(code, _) {
            rejection.record(code)
        } catch {
            Issue.record("Unexpected reentrant-run error: \(error)")
        }
    }
    #expect(rejection.code == 5)
}

@Test func undiscoveredL3IsRejectedAsUnavailable() throws {
    let information = try BenchmarkRunner.systemInformation()
    guard !information.isAvailable(.l3) else { return }
    do {
        _ = try BenchmarkRunner.runSelected(
            selection: .row(.l3),
            totalDuration: .milliseconds(120),
            sampleCount: 3,
            progress: { _ in }
        )
        Issue.record("An undiscovered L3 level must not produce a successful run")
    } catch let BenchmarkError.nativeFailure(code, _) {
        #expect(code == 6)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BenchmarkProgress] = []

    var values: [BenchmarkProgress] {
        lock.withLock { storage }
    }

    func record(_ progress: BenchmarkProgress) {
        lock.withLock { storage.append(progress) }
    }
}

private final class NativeFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt32?

    var code: UInt32? {
        lock.withLock { storage }
    }

    func record(_ code: UInt32) {
        lock.withLock { storage = code }
    }
}

@Test func invalidConfigurationIsRejectedAtContractBoundary() {
    #expect(throws: BenchmarkError.self) {
        try BenchmarkRunner.run(configuration: .init(sampleCount: 2, minimumSampleDuration: .milliseconds(10)))
    }
}

@Test func unavailableWorkerCountIsRejectedByNativePlanner() throws {
    let information = try BenchmarkRunner.systemInformation()
    #expect(throws: BenchmarkError.self) {
        try BenchmarkRunner.run(configuration: .init(
            sampleCount: 3,
            minimumSampleDuration: .milliseconds(10),
            throughputWorkerCount: information.logicalCPUCount + 1
        ))
    }
}

@Test func shortBenchmarkProducesFiniteOrderedMeasurements() throws {
    let report = try BenchmarkRunner.run(
        configuration: .init(sampleCount: 3, minimumSampleDuration: .milliseconds(20))
    )
    #expect(report.throughputWorkerCount == report.system.logicalCPUCount)
    let levelCount = report.system.availableLevels.count
    #expect(report.measurements.count == levelCount * 2)
    #expect(report.measurements.filter { $0.scope == .singleWorker }.count == levelCount)
    #expect(report.measurements.filter { $0.scope == .aggregate }.count == levelCount)
    #expect(report.aidaMeasurements.count == levelCount)
    for measurement in report.measurements {
        #expect(measurement.readGigabytesPerSecond?.isFinite == true)
        #expect(measurement.readGigabytesPerSecond ?? 0 > 0)
        #expect(measurement.writeGigabytesPerSecond?.isFinite == true)
        #expect(measurement.writeGigabytesPerSecond ?? 0 > 0)
        #expect(measurement.copyGigabytesPerSecond?.isFinite == true)
        #expect(measurement.copyGigabytesPerSecond ?? 0 > 0)
        if measurement.scope == .singleWorker {
            #expect(measurement.latencyNanoseconds?.isFinite == true)
            #expect(measurement.latencyNanoseconds ?? 0 > 0)
        } else {
            #expect(measurement.latencyNanoseconds == nil)
        }
    }
    let encoded = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: encoded)
    #expect(decoded.measurements.count == report.measurements.count)
    #expect(decoded.measurements.filter { $0.latencyNanoseconds == nil }.count == levelCount)
}

}
