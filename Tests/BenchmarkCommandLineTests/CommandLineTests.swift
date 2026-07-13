import BenchmarkCommandLine
import BenchmarkKit
import Foundation
import Testing

@Test func defaultsAreStable() throws {
    let action = try CommandLineParser.parse([])
    #expect(action == .run(CommandLineOptions(
        sampleCount: 5,
        durationMilliseconds: 200,
        format: .text,
        outputPath: nil,
        workerCount: 0
    )))
}

@Test func allRunOptionsAreTyped() throws {
    let action = try CommandLineParser.parse([
        "--samples", "7", "--duration-ms", "500", "--format", "json", "--output", "result.json",
        "--workers", "14",
    ])
    #expect(action == .run(CommandLineOptions(
        sampleCount: 7,
        durationMilliseconds: 500,
        format: .json,
        outputPath: "result.json",
        workerCount: 14
    )))
}

@Test(arguments: ["-h", "--help"])
func helpStopsParsing(_ flag: String) throws {
    #expect(try CommandLineParser.parse([flag]) == .help)
}

@Test(arguments: [
    ["--samples"],
    ["--samples", "2"],
    ["--samples", "101"],
    ["--duration-ms", "9"],
    ["--duration-ms", "60001"],
    ["--format", "xml"],
    ["--workers", "0"],
    ["--workers", "257"],
    ["--unknown"],
])
func invalidGrammarIsRejected(_ arguments: [String]) {
    #expect(throws: CommandLineParseError.self) {
        try CommandLineParser.parse(arguments)
    }
}

@Test func textRendererPresentsOneAIDALikeTable() throws {
    let report = BenchmarkReport(
        system: try BenchmarkRunner.systemInformation(),
        measurements: CacheLevel.allCases.map { level in
            BenchmarkMeasurement(
                level: level,
                workingSetBytes: 64 * 1024,
                readGigabytesPerSecond: 10,
                writeGigabytesPerSecond: 9,
                copyGigabytesPerSecond: 8,
                latencyNanoseconds: 7
            )
        },
        throughputWorkerCount: 1
    )
    let rendered = String(decoding: try ReportRenderer.render(report, format: .text), as: UTF8.self)
    for label in ["Memory", "L1 Cache", "L2 Cache", "L3 Cache"] {
        #expect(rendered.contains(label))
    }
    #expect(!rendered.contains("Single worker hierarchy"))
    #expect(!rendered.contains("Aggregate throughput\n"))
}
