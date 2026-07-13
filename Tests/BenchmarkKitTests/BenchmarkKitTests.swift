import BenchmarkKit
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
