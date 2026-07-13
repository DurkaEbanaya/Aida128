import BenchmarkKit

let information = try BenchmarkRunner.systemInformation()
print("\(information.architecture): \(information.backend)")
if let metadata = information.hardwareMetadata {
    print("\(metadata.hardwareModel): \(metadata.physicalCoreCount) physical cores")
}
