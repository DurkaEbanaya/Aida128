import SwiftUI

@main
struct Aida128App: App {
    var body: some Scene {
        WindowGroup("Aida128 Cache & Memory Benchmark") {
            BenchmarkView()
                .frame(
                    minWidth: 640,
                    idealWidth: 760,
                    minHeight: 560,
                    idealHeight: 790
                )
        }
        .defaultSize(width: 760, height: 790)
        .windowResizability(.contentMinSize)
    }
}
