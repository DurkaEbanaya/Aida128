import BenchmarkKit

let information = try BenchmarkRunner.systemInformation()
print("\(information.architecture): \(information.backend)")
