# Project: Aida128

Native macOS cache and memory benchmark with a SwiftUI GUI, CLI, and C++ SIMD core. Supports x86_64 AVX2 and arm64 NEON through one architecture-neutral API.

Tech stack: Swift 6 / SwiftUI / AppKit, C++20, Swift Package Manager, IOKit, Mach APIs.

## Workspace Overview

- `Sources/BenchmarkCore/` - C ABI, system discovery, workload planning, AVX2/NEON kernels.
- `Sources/BenchmarkKit/` - Swift configuration, selection, progress, and report bridge.
- `Sources/Aida128App/` - GUI and Fluent-inspired Acrylic/Reveal presentation.
- `Sources/BenchmarkCommandLine/`, `Sources/Aida128CLI/` - CLI parsing, rendering, and entry point.
- `Tests/` - contract, progress, selection, and integration tests.
- `IntegrationTests/PackageConsumer/` - external SwiftPM product-consumption gate.
- `scripts/build-universal.sh` - reproducible Universal 2 packaging.

## Architectural Invariants

- Swift passes benchmark intent only. Cache sizes, ISA, topology, and iteration calibration belong to `BenchmarkCore`.
- GUI progress must come from native callbacks after real work; never synthesize progress or parse LLM/text output.
- Throughput is aggregate; latency is a single dependent chain. Do not mix their semantics silently.
- Full V2 runs contain exactly 16 visible stages in `Memory → L1 → L2 → L3` and `Read → Write → Copy → Latency` order.
- Native runs are process-wide serialized; overlapping benchmarks are invalid.
- Preserve old `a128_run_benchmark` compatibility when evolving the versioned C ABI.
- ARM cross-build is not runtime proof. Stable release requires real Apple Silicon CI/device validation.

## Development Practices

- Build: `swift build`
- Release: `swift build -c release`
- Test: `swift test`
- ASan: `swift test --sanitize=address`
- TSan: `swift test --sanitize=thread`
- Universal 2: `VERSION=0.1.0-rc.1 scripts/build-universal.sh`

After shared API/core changes, run the full tests, both sanitizers, x86 release, arm64 release cross-build, and Universal 2 slice verification.

## Where To Find Details

- `docs/architecture.md` - component boundaries and data flow.
- `docs/methodology.md` - units, working sets, kernels, sampling, and progress semantics.
- `docs/verification.md` - verified host/API facts and platform limitations.
- `docs/building.md` - local and Universal 2 builds.
- `docs/releasing.md` - release gates, signing, and ARM validation.
