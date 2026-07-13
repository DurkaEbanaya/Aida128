import BenchmarkCommandLine
import BenchmarkKit
import Foundation

@main
struct Aida128CLI {
    static func main() async {
        do {
            switch try CommandLineParser.parse(Array(CommandLine.arguments.dropFirst())) {
            case .help:
                print(CommandLineParser.usage)
            case let .run(options):
                let nativeReport = try BenchmarkRunner.run(configuration: options.benchmarkConfiguration)
                let report = await BenchmarkRunner.enriched(nativeReport)
                let data = try ReportRenderer.render(report, format: options.format)
                if let outputPath = options.outputPath {
                    try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                } else {
                    FileHandle.standardOutput.write(data)
                }
            }
        } catch {
            FileHandle.standardError.write(Data(
                "error: \(error.localizedDescription)\n\n\(CommandLineParser.usage)\n".utf8
            ))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}
