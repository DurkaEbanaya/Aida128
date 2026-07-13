import AppKit
import BenchmarkKit
import SwiftUI

struct BenchmarkView: View {
    @StateObject private var model = BenchmarkViewModel()
    @AppStorage("appearance.theme") private var themeRaw = ThemePreference.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var theme: ThemePreference {
        get { ThemePreference(rawValue: themeRaw) ?? .dark }
        nonmutating set { themeRaw = newValue.rawValue }
    }

    private var palette: FluentPalette { .resolve(colorScheme) }
    private let levels: [CacheLevel] = [.memory, .l1, .l2, .l3]
    private let metrics: [BenchmarkMetric] = [.read, .write, .copy, .latency]
    private let durations = [5, 15, 30, 60, 90]

    var body: some View {
        ZStack {
            AcrylicBackdrop(isDark: colorScheme == .dark, reduceTransparency: reduceTransparency)
                .ignoresSafeArea()
            palette.background.opacity(reduceTransparency ? 1 : (colorScheme == .dark ? 0.36 : 0.26))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                commandBar
                VStack(spacing: 12) {
                    benchmarkPanel
                    ScrollView { systemPanel }
                        .frame(maxHeight: .infinity)
                    footer
                }
                .padding(14)
            }
        }
        .background(WindowConfigurator())
        .foregroundStyle(palette.text)
        .font(.system(size: 12, design: .default))
        .preferredColorScheme(theme.colorScheme)
    }

    private var commandBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aida128 Cache & Memory Benchmark")
                        .font(.system(size: 16, weight: .semibold))
                    Text(progressTitle)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Text("Total time")
                    .foregroundStyle(palette.secondaryText)
                Picker("Total time", selection: $model.totalDurationSeconds) {
                    ForEach(durations, id: \.self) { Text("\($0)s").tag($0) }
                }
                .labelsHidden()
                .frame(width: 82)
                .disabled(model.isRunning)
                HStack(spacing: 2) {
                    ForEach(ThemePreference.allCases, id: \.self) { option in
                        RevealButton(
                            enabled: !model.isRunning,
                            selected: theme == option,
                            action: { theme = option }
                        ) {
                            Text(option.label).frame(width: 54, height: 25)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            if model.isRunning || model.progress != nil {
                ProgressView(value: model.progress?.fractionCompleted ?? 0)
                    .progressViewStyle(.linear)
                    .tint(palette.accent)
                    .frame(height: 3)
            } else {
                Rectangle().fill(palette.border.opacity(0.55)).frame(height: 1)
            }
        }
        .background(palette.surface)
    }

    private var benchmarkPanel: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Click a row or cell to test")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 126, alignment: .leading)
                ForEach(metrics, id: \.self) { metric in
                    Text(metric.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(levels, id: \.self) { level in
                GridRow {
                    benchmarkRowButton(level)
                    ForEach(metrics, id: \.self) { metric in
                        benchmarkCell(level: level, metric: metric)
                    }
                }
            }
        }
        .padding(12)
        .background(palette.surface)
        .overlay(Rectangle().stroke(palette.border, lineWidth: 1))
    }

    private var systemPanel: some View {
        VStack(spacing: 3) {
            infoRow("CPU Type", cpuTypeText)
            infoRow("CPUID", cpuidText)
            infoRow("CPU Clock", cpuClockText)
            infoRow("Reference Clock", referenceClockText)
            infoRow("CPU Multiplier", multiplierText)
            infoRow("Microcode", model.systemInformation.map { "\($0.microcodeVersion)" } ?? "—")
            infoRow("CPU Topology", model.systemInformation.map { "\($0.logicalCPUCount) scheduler-visible logical CPUs" } ?? "—")
            infoRow("Memory", memoryText)
            infoRow("Memory Modules", memoryModulesText)
            infoRow("DRAM:Reference Ratio", memoryRatioText)
            infoRow("Memory Timings / CR", "Unavailable — memory-controller registers are not exposed by macOS")
            infoRow("Mainboard", model.systemInformation?.motherboard.nilIfEmpty ?? "Unavailable")
            infoRow("Chipset IDs", model.systemInformation?.chipset.nilIfEmpty ?? "Unavailable")
            infoRow("Platform", platformText)
            infoRow("Firmware", model.systemInformation?.firmware.nilIfEmpty ?? "Unavailable")
            infoRow("Benchmark Mode", model.report.map {
                "\($0.system.backend) · \($0.throughputWorkerCount) workers · selected total time \(model.totalDurationSeconds)s"
            } ?? (model.systemInformation?.backend ?? "Detecting SIMD backend"))
            infoRow("macOS-usable ISA", model.systemInformation?.cpuFeatures.nilIfEmpty ?? "Unavailable", height: 58)
        }
        .padding(10)
        .background(palette.surface)
        .overlay(Rectangle().stroke(palette.border, lineWidth: 1))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            HStack {
                fluentAction("Save") { model.saveReport() }
                    .disabled(model.report == nil || model.isRunning)
                Spacer()
                fluentAction(model.isRunning ? "Testing…" : "Start All") {
                    model.runBenchmark()
                }
                .disabled(model.isRunning || model.systemInformation == nil)
                Spacer()
                fluentAction("Close") { NSApplication.shared.keyWindow?.close() }
            }
        }
    }

    private func fluentAction(_ title: String, action: @escaping () -> Void) -> some View {
        RevealButton(enabled: true, selected: false, action: action) {
            Text(title)
                .fontWeight(.medium)
                .frame(minWidth: 112, minHeight: 30)
        }
    }

    private func benchmarkRowButton(_ level: CacheLevel) -> some View {
        RevealButton(
            enabled: !model.isRunning && model.isAvailable(level),
            selected: model.activeLevel == level && model.activeMetric == nil,
            action: { model.runRow(level) }
        ) {
            HStack {
                Text(level.rawValue).fontWeight(.medium)
                Spacer()
                Image(systemName: "play.fill").font(.caption2)
            }
            .padding(.horizontal, 8)
            .frame(width: 126)
            .frame(minHeight: 28)
        }
    }

    private func benchmarkCell(level: CacheLevel, metric: BenchmarkMetric) -> some View {
        RevealButton(
            enabled: !model.isRunning && model.isAvailable(level),
            selected: model.activeLevel == level && model.activeMetric == metric,
            action: { model.runCell(level: level, metric: metric) }
        ) {
            resultText(level: level, metric: metric)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
                .padding(.horizontal, 7)
        }
    }

    private func resultText(level: CacheLevel, metric: BenchmarkMetric) -> Text {
        guard model.isAvailable(level) else { return Text("N/A") }
        guard let measurement = model.measurements[level] else { return Text("") }
        let value: Double? = switch metric {
        case .read: measurement.readGigabytesPerSecond
        case .write: measurement.writeGigabytesPerSecond
        case .copy: measurement.copyGigabytesPerSecond
        case .latency: measurement.latencyNanoseconds
        }
        guard let value else {
            return Text(model.activeLevel == level && model.activeMetric == metric ? "…" : "")
        }
        if metric == .latency { return Text(String(format: "%.1f ns", value)) }
        if level == .memory { return Text("\(Int((value * 1000).rounded())) MB/s") }
        return Text(String(format: "%.2f GB/s", value))
    }

    private func infoRow(_ label: String, _ value: String, height: CGFloat = 23) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .foregroundStyle(palette.secondaryText)
                .frame(width: 140, alignment: .leading)
                .padding(.leading, 5)
            Text(value)
                .lineLimit(height > 23 ? 3 : 1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .background(palette.field)
                .overlay(Rectangle().stroke(palette.border.opacity(0.75), lineWidth: 0.5))
        }
        .frame(height: height)
    }

    private var progressTitle: String {
        guard model.isRunning, let progress = model.progress, let metric = progress.metric else {
            return "Ready — click Start All, a row, or an individual result cell"
        }
        let phase: String = switch progress.phase {
        case .started: "Starting"
        case .calibrating: "Calibrating"
        case .sampleCompleted: "Measuring sample \(progress.completedSamples) of \(progress.sampleCount)"
        case .stageCompleted: "Completed"
        case .runCompleted: "Completed"
        }
        return "\(phase) · \(progress.level.rawValue) · \(metric.rawValue)"
    }

    private var cpuTypeText: String {
        guard let system = model.systemInformation else { return "—" }
        let socket = system.cpuSocket.isEmpty ? "socket unavailable" : system.cpuSocket
        return "\(system.cpuName) · \(system.cpuMicroarchitecture) · \(socket) · \(system.architecture)"
    }

    private var cpuidText: String {
        guard let system = model.systemInformation else { return "—" }
        return String(format: "Family %u · Model 0x%02X · Stepping %u · Signature 0x%08X",
                      system.cpuFamily, system.cpuModel, system.cpuStepping, system.cpuSignature)
    }

    private var cpuClockText: String {
        guard let system = model.systemInformation, system.cpuBaseMegahertz > 0 else { return "Unavailable" }
        return "\(system.cpuBaseMegahertz) MHz base · \(system.cpuMaxMegahertz) MHz advertised max"
    }

    private var referenceClockText: String {
        guard let frequency = model.systemInformation?.referenceClockMegahertz, frequency > 0 else {
            return "Unavailable (modern Intel has no FSB)"
        }
        return "\(frequency) MHz (CPUID reference clock; no legacy FSB)"
    }

    private var multiplierText: String {
        guard let system = model.systemInformation, system.referenceClockMegahertz > 0 else { return "Unavailable" }
        return "\(system.cpuBaseMegahertz / system.referenceClockMegahertz)x base · \(system.cpuMaxMegahertz / system.referenceClockMegahertz)x advertised max"
    }

    private var memoryText: String {
        guard let system = model.systemInformation else { return "—" }
        return "\(bytes(system.memoryBytes)) · \(system.memoryType)-\(system.memoryDataRate)"
    }

    private var memoryModulesText: String {
        guard let system = model.systemInformation else { return "—" }
        return "\(system.memoryModuleCount)× \(system.memoryManufacturer) · \(system.memoryPartNumber)"
    }

    private var memoryRatioText: String {
        guard let system = model.systemInformation, system.referenceClockMegahertz > 0 else { return "Unavailable" }
        return String(format: "%.1f:1 (effective MT/s to reference clock)",
                      Double(system.memoryDataRate) / Double(system.referenceClockMegahertz))
    }

    private var platformText: String {
        guard let system = model.systemInformation else { return "—" }
        return "\(system.platformName) · SMBIOS supplied by OpenCore/Acidanthera"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
