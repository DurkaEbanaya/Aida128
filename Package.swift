// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Aida128",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BenchmarkKit", targets: ["BenchmarkKit"]),
        .executable(name: "aida128-bench", targets: ["Aida128CLI"]),
        .executable(name: "aida128", targets: ["Aida128App"]),
    ],
    targets: [
        .target(
            name: "BenchmarkCore",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("AIDA128_VERSION", to: "\"0.1.0\""),
            ],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "BenchmarkKit", dependencies: ["BenchmarkCore"]),
        .target(name: "BenchmarkCommandLine", dependencies: ["BenchmarkKit"]),
        .executableTarget(
            name: "Aida128CLI",
            dependencies: ["BenchmarkKit", "BenchmarkCommandLine"]
        ),
        .executableTarget(name: "Aida128App", dependencies: ["BenchmarkKit"]),
        .testTarget(name: "BenchmarkKitTests", dependencies: ["BenchmarkKit", "BenchmarkCore"]),
        .testTarget(name: "BenchmarkCommandLineTests", dependencies: ["BenchmarkCommandLine"]),
    ],
    cxxLanguageStandard: .cxx20
)
