# Aida128

A native macOS cache and memory benchmark inspired by the compact workflow of AIDA64 Cache & Memory Benchmark. Aida128 is an independent project and is not affiliated with FinalWire or AIDA64.

![macOS](https://img.shields.io/badge/macOS-13%2B-black)
![architectures](https://img.shields.io/badge/architectures-x86__64%20%7C%20arm64-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## Features

- Memory and cache Read, Write, Copy, and dependent-load Latency.
- AVX2 backend on Intel and NEON/ASIMD backend on Apple Silicon.
- Aggregate throughput and single dependent-chain latency.
- Select the entire benchmark, one memory/cache row, or one metric cell.
- User-selectable total run budget: 5, 15, 30, 60, or 90 seconds.
- Real native progress events; cells update only after their measurement finishes.
- Windows 10-era Fluent-inspired interface with Acrylic, Reveal, light/dark themes, and a resizable window.
- JSON export and a separate CLI runner.
- Detailed CPUID, cache, memory, SMBIOS, PCI, and ISA information where macOS exposes trustworthy data.
- Apple Silicon SoC topology, unified memory, GPU, firmware, and System Cache metadata with source details on hover.

## Platform status

| Platform | Backend | Status |
| --- | --- | --- |
| Intel macOS x86_64 | AVX2 | Runtime, sanitizer, GUI, CLI, and Universal 2 packaging tested on Intel Core i5-14600KF |
| Apple Silicon arm64 | NEON/ASIMD | Native tests and CLI smoke verified on a GitHub-hosted Apple M1 VM; local release builds include an arm64 slice, but physical-device GUI validation remains pending |

The 1.0.0 package is ad-hoc signed and not notarized. GitHub Actions has executed the native tests and benchmark CLI on arm64, but a hosted VM does not replace GUI validation on a physical Apple Silicon Mac.

## Run from source

Requirements: macOS 13 or later and Xcode command-line tools.

```bash
git clone https://github.com/DurkaEbanaya/Aida128.git
cd Aida128
swift run -c release aida128
```

CLI:

```bash
swift run -c release aida128-bench --help
swift run -c release aida128-bench --samples 5 --duration-ms 200
swift run -c release aida128-bench --format json --output result.json
```

## Build Universal 2 release package

```bash
chmod +x scripts/build-universal.sh
VERSION=1.0.0 scripts/build-universal.sh
```

Artifacts are written to `dist/`. The app is ad-hoc signed because the project does not have a Developer ID certificate. On first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**.

## Methodology

The benchmark does not multiply results to imitate another product. The measured kernels, working sets, units, progress contract, and known platform limitations are documented in [docs/methodology.md](docs/methodology.md). Verified host/API facts are recorded in [docs/verification.md](docs/verification.md).

## Accuracy notes

- Copy reports source-read plus destination-write traffic.
- Memory results are shown in MB/s; cache results are shown in GB/s.
- Modern Intel processors do not have a legacy FSB; Aida128 reports CPUID reference clock instead.
- Current dynamic clocks, DRAM primary timings, and command rate are not exposed by public macOS APIs.
- On OpenCore systems, spoofed SMBIOS values are identified rather than presented as the physical motherboard or BIOS.
- macOS does not expose supported hard CPU affinity; scheduler migration remains visible through result spread.
- Apple Silicon System Cache metadata exposes provenance in tooltips. Experimental catalog capacities are not used in verified mode; they can enter benchmark planning only through the explicit **Experimental SLC** opt-in and remain marked as estimates.

## Development

```bash
swift test
swift test --sanitize=address
swift test --sanitize=thread
swift build -c release
```

See [docs/building.md](docs/building.md) and [docs/releasing.md](docs/releasing.md).

## License

MIT. See [LICENSE](LICENSE).
