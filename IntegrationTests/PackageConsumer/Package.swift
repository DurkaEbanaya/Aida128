// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Aida128PackageConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "Aida128", path: "../..")],
    targets: [
        .executableTarget(
            name: "Aida128PackageConsumer",
            dependencies: [.product(name: "BenchmarkKit", package: "Aida128")]
        ),
    ]
)
