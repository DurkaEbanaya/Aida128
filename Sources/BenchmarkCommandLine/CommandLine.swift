import BenchmarkKit
import Foundation

public enum OutputFormat: String, Sendable {
    case text
    case json
}

public struct CommandLineOptions: Sendable, Equatable {
    public let sampleCount: UInt32
    public let durationMilliseconds: UInt64
    public let format: OutputFormat
    public let outputPath: String?
    public let workerCount: UInt32

    public init(
        sampleCount: UInt32,
        durationMilliseconds: UInt64,
        format: OutputFormat,
        outputPath: String?,
        workerCount: UInt32 = 0
    ) {
        self.sampleCount = sampleCount
        self.durationMilliseconds = durationMilliseconds
        self.format = format
        self.outputPath = outputPath
        self.workerCount = workerCount
    }

    public var benchmarkConfiguration: BenchmarkConfiguration {
        BenchmarkConfiguration(
            sampleCount: sampleCount,
            minimumSampleDuration: .milliseconds(durationMilliseconds),
            throughputWorkerCount: workerCount
        )
    }
}

public enum CommandLineAction: Sendable, Equatable {
    case run(CommandLineOptions)
    case help
}

public enum CommandLineParseError: Error, LocalizedError, Equatable {
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(option: String, value: String, requirement: String)

    public var errorDescription: String? {
        switch self {
        case let .unknownArgument(argument):
            "Unknown argument: \(argument)"
        case let .missingValue(option):
            "Missing value for \(option)"
        case let .invalidValue(option, value, requirement):
            "Invalid value for \(option): \(value) (expected \(requirement))"
        }
    }
}

public enum CommandLineParser {
    public static let usage = """
    Usage: aida128-bench [options]

      --samples <3...100>       Number of measured samples (default: 5)
      --duration-ms <10...60000>
                                Minimum duration of each sample (default: 200)
      --format <text|json>      Output format (default: text)
      --workers <auto|1...256>  Throughput worker count (default: auto)
      --output <path>           Write output atomically to a file
      -h, --help                Show this help without running the benchmark
    """

    public static func parse(_ arguments: [String]) throws -> CommandLineAction {
        var samples: UInt32 = 5
        var duration: UInt64 = 200
        var format = OutputFormat.text
        var outputPath: String?
        var workers: UInt32 = 0
        var index = 0

        func value(after option: String) throws -> String {
            guard index + 1 < arguments.count else { throw CommandLineParseError.missingValue(option) }
            return arguments[index + 1]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return .help
            case "--samples":
                let raw = try value(after: argument)
                guard let parsed = UInt32(raw), (3...100).contains(parsed) else {
                    throw CommandLineParseError.invalidValue(
                        option: argument, value: raw, requirement: "an integer from 3 through 100"
                    )
                }
                samples = parsed
                index += 2
            case "--duration-ms":
                let raw = try value(after: argument)
                guard let parsed = UInt64(raw), (10...60_000).contains(parsed) else {
                    throw CommandLineParseError.invalidValue(
                        option: argument, value: raw, requirement: "an integer from 10 through 60000"
                    )
                }
                duration = parsed
                index += 2
            case "--format":
                let raw = try value(after: argument)
                guard let parsed = OutputFormat(rawValue: raw) else {
                    throw CommandLineParseError.invalidValue(
                        option: argument, value: raw, requirement: "text or json"
                    )
                }
                format = parsed
                index += 2
            case "--workers":
                let raw = try value(after: argument)
                if raw == "auto" {
                    workers = 0
                } else if let parsed = UInt32(raw), (1...256).contains(parsed) {
                    workers = parsed
                } else {
                    throw CommandLineParseError.invalidValue(
                        option: argument, value: raw, requirement: "auto or an integer from 1 through 256"
                    )
                }
                index += 2
            case "--output":
                let raw = try value(after: argument)
                guard !raw.isEmpty else {
                    throw CommandLineParseError.invalidValue(
                        option: argument, value: raw, requirement: "a non-empty path"
                    )
                }
                outputPath = raw
                index += 2
            default:
                throw CommandLineParseError.unknownArgument(argument)
            }
        }

        return .run(CommandLineOptions(
            sampleCount: samples,
            durationMilliseconds: duration,
            format: format,
            outputPath: outputPath,
            workerCount: workers
        ))
    }
}

public enum ReportRenderer {
    public static func render(_ report: BenchmarkReport, format: OutputFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(report) + Data("\n".utf8)
        case .text:
            return Data((text(report) + "\n").utf8)
        }
    }

    private static func text(_ report: BenchmarkReport) -> String {
        var lines = [
            "Aida128 Cache & Memory Benchmark",
            "CPU: \(report.system.cpuName)",
            "Architecture: \(report.system.architecture), backend: \(report.system.backend)",
            "Aggregate throughput workers: \(report.throughputWorkerCount)",
            "",
            "\(column("Level", width: 20)) \(column("Read", width: 12)) \(column("Write", width: 12)) \(column("Copy", width: 12)) \(column("Latency", width: 12)) \(column("Spread", width: 9))",
        ]
        let order: [CacheLevel] = [.memory, .l1, .l2, .l3]
        for level in order {
            guard let value = report.aidaMeasurements.first(where: { $0.level == level }) else {
                if !report.system.isAvailable(level) {
                    lines.append("\(column(report.system.displayName(for: level), width: 20, rightAligned: false)) \(column("N/A", width: 12)) \(column("N/A", width: 12)) \(column("N/A", width: 12)) \(column("N/A", width: 12)) \(column("—", width: 9))")
                }
                continue
            }
            let read = metric(value.readGigabytesPerSecond, unit: "GB/s")
            let write = metric(value.writeGigabytesPerSecond, unit: "GB/s")
            let copy = metric(value.copyGigabytesPerSecond, unit: "GB/s")
            let latency = metric(value.latencyNanoseconds, unit: "ns")
            let spread = String(format: "%.1f%%", value.maximumRelativeSpread * 100)
            lines.append("\(column(report.system.displayName(for: value.level), width: 20, rightAligned: false)) \(column(read, width: 12)) \(column(write, width: 12)) \(column(copy, width: 12)) \(column(latency, width: 12)) \(column(spread, width: 9))")
        }
        return lines.joined(separator: "\n")
    }

    private static func column(_ value: String, width: Int, rightAligned: Bool = true) -> String {
        guard value.count < width else { return value }
        let padding = String(repeating: " ", count: width - value.count)
        return rightAligned ? padding + value : value + padding
    }

    private static func metric(_ value: Double?, unit: String) -> String {
        value.map { String(format: "%.2f %@", $0, unit) } ?? "—"
    }
}
