import AppKit
import BenchmarkKit
import Foundation

@MainActor
final class BenchmarkViewModel: ObservableObject {
    @Published private(set) var systemInformation: SystemInformation?
    @Published private(set) var report: BenchmarkReport?
    @Published private(set) var measurements: [CacheLevel: BenchmarkMeasurement] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var progress: BenchmarkProgress?
    @Published private(set) var activeLevel: CacheLevel?
    @Published private(set) var activeMetric: BenchmarkMetric?
    @Published var totalDurationSeconds = 30
    private var enrichmentTask: Task<Void, Never>?
    private var benchmarkTask: Task<Void, Never>?

    init() {
        do {
            let initial = try BenchmarkRunner.systemInformation()
            systemInformation = initial
            enrichmentTask = Task { [weak self] in
                let enriched = await BenchmarkRunner.enriched(initial)
                guard !Task.isCancelled else { return }
                self?.applyHardwareMetadata(enriched.hardwareMetadata)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    deinit {
        enrichmentTask?.cancel()
        benchmarkTask?.cancel()
    }

    var visibleMeasurements: [BenchmarkMeasurement] {
        let order: [CacheLevel] = [.memory, .l1, .l2, .l3]
        return order.compactMap { measurements[$0] }
    }

    func isAvailable(_ level: CacheLevel) -> Bool {
        systemInformation?.isAvailable(level) == true
    }

    func runBenchmark(selection: BenchmarkSelection = .all) {
        guard !isRunning else { return }
        guard let discoveredSystem = systemInformation else { return }
        let effectiveSelection = BenchmarkSelection(
            levels: selection.levels.intersection(discoveredSystem.availableLevels),
            metrics: selection.metrics
        )
        guard !effectiveSelection.levels.isEmpty else {
            errorMessage = "The selected cache level is unavailable on this system."
            return
        }
        clear(selection: effectiveSelection)
        isRunning = true
        errorMessage = nil
        progress = nil
        let duration = Duration.seconds(totalDurationSeconds)

        benchmarkTask = Task { [weak self] in
            let (updates, continuation) = AsyncStream.makeStream(of: BenchmarkProgress.self)
            let run = Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                return try BenchmarkRunner.runSelected(
                    selection: effectiveSelection,
                    totalDuration: duration
                ) { update in
                    continuation.yield(update)
                }
            }
            do {
                for await update in updates { self?.receive(update) }
                let completedReport = try await run.value
                guard let self else { return }
                systemInformation = completedReport.system.replacingHardwareMetadata(
                    systemInformation?.hardwareMetadata
                )
                merge(completedReport.measurements)
                rebuildReport(workerCount: completedReport.throughputWorkerCount)
            } catch {
                run.cancel()
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.activeLevel = nil
                self?.activeMetric = nil
                self?.benchmarkTask = nil
            }
        }
    }

    func runRow(_ level: CacheLevel) {
        runBenchmark(selection: .row(level))
    }

    func runCell(level: CacheLevel, metric: BenchmarkMetric) {
        runBenchmark(selection: .cell(level: level, metric: metric))
    }

    func saveReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.title = "Save Benchmark Report"
        panel.nameFieldStringValue = "aida128-report.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try (encoder.encode(report) + Data("\n".utf8)).write(to: destination, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receive(_ update: BenchmarkProgress) {
        progress = update
        activeLevel = update.metric == nil ? nil : update.level
        activeMetric = update.metric
        if update.phase == .stageCompleted, let measurement = update.measurement {
            merge([measurement])
            rebuildReport(workerCount: report?.throughputWorkerCount ?? systemInformation?.logicalCPUCount ?? 0)
        }
    }

    private func merge(_ updates: [BenchmarkMeasurement]) {
        for update in updates {
            let previous = measurements[update.level]
            measurements[update.level] = BenchmarkMeasurement(
                level: update.level,
                workingSetBytes: update.workingSetBytes > 0
                    ? update.workingSetBytes : previous?.workingSetBytes ?? 0,
                readGigabytesPerSecond: update.readGigabytesPerSecond ?? previous?.readGigabytesPerSecond,
                writeGigabytesPerSecond: update.writeGigabytesPerSecond ?? previous?.writeGigabytesPerSecond,
                copyGigabytesPerSecond: update.copyGigabytesPerSecond ?? previous?.copyGigabytesPerSecond,
                latencyNanoseconds: update.latencyNanoseconds ?? previous?.latencyNanoseconds,
                maximumRelativeSpread: max(
                    update.maximumRelativeSpread, previous?.maximumRelativeSpread ?? 0
                )
            )
        }
    }

    private func clear(selection: BenchmarkSelection) {
        for level in selection.levels {
            let previous = measurements[level]
            measurements[level] = BenchmarkMeasurement(
                level: level,
                workingSetBytes: previous?.workingSetBytes ?? 0,
                readGigabytesPerSecond: selection.metrics.contains(.read) ? nil : previous?.readGigabytesPerSecond,
                writeGigabytesPerSecond: selection.metrics.contains(.write) ? nil : previous?.writeGigabytesPerSecond,
                copyGigabytesPerSecond: selection.metrics.contains(.copy) ? nil : previous?.copyGigabytesPerSecond,
                latencyNanoseconds: selection.metrics.contains(.latency) ? nil : previous?.latencyNanoseconds,
                maximumRelativeSpread: previous?.maximumRelativeSpread ?? 0
            )
        }
    }

    private func rebuildReport(workerCount: UInt32) {
        guard let systemInformation else { return }
        report = BenchmarkReport(
            system: systemInformation,
            measurements: visibleMeasurements,
            throughputWorkerCount: workerCount
        )
    }

    private func applyHardwareMetadata(_ metadata: HardwareMetadata?) {
        guard let current = systemInformation else { return }
        systemInformation = current.replacingHardwareMetadata(metadata)
        if let workerCount = report?.throughputWorkerCount {
            rebuildReport(workerCount: workerCount)
        }
    }
}
