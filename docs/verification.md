# Verification record

Verified on 2026-07-13 before implementation.

## Native execution

Commands: `uname -m`, `arch`, `sysctl -n hw.machine`, `swiftc -print-target-info`.

- `uname -m`: `x86_64`
- `arch`: `i386`
- `hw.machine`: `x86_64`
- Swift target: `x86_64-apple-macosx26.0`

Conclusion: `arch` is not a reliable ABI source on this host. The core uses compile-time architecture and runtime CPU feature discovery.

## Intel host and caches

Command: `sysctl hw.cacheconfig hw.cachesize hw.l1dcachesize hw.l2cachesize hw.l3cachesize hw.memsize machdep.cpu.brand_string machdep.cpu.features machdep.cpu.leaf7_features`.

- CPU: `Intel(R) Core(TM) i5-14600KF`
- Memory: 34,359,738,368 bytes
- L1 data: 49,152 bytes
- L2: 2,097,152 bytes
- L3: 25,165,824 bytes
- AVX2 is present; AVX-512 is absent.

## Timing and toolchain

- `hw.tbfrequency`: 1,000,000,000 on this host.
- Code nevertheless converts Mach absolute ticks using `mach_timebase_info`.
- Apple Clang 21.0.0 and Swift 6.3.2 are installed.
- macOS SDK 26.5 is installed and Clang exposes x86-64 and AArch64 targets.
- CMake is absent; Swift Package Manager is the build authority.

## Scheduling limitation

The host CPU is heterogeneous. Public macOS APIs do not provide hard binding to a selected P-core. The report therefore exposes cross-sample spread. The AIDA-like headline is the best observed throughput (and lowest observed latency), not a claim that execution occurred on a particular core type.

## Apple Silicon cache discovery

Verified on GitHub's Apple M1 virtual runner in CI run `29249845148`. Raw `sysctl` output reported 128 KiB L1D and 12 MiB L2 through both aggregate and `hw.perflevel0` keys, while `hw.cacheconfig`, `hw.cachesize`, and `hw.l3cachesize` reported no L3/LLC capacity. The planner therefore treats L3 as unavailable on that host instead of inferring a size from L2.

CI run `29257079821` additionally verified `hw.perflevel*` topology/cache keys and sanitized `system_profiler` fields for chip name, hardware model, system firmware, and OS loader. The hosted VM exposes no GPU record, so GPU metadata remains optional.

For the base Apple M5 catalog, Apple specifications provide the CPU and Neural Engine configuration and memory bandwidth. Maximum fast-core/E-core clocks come from a device analysis, while the approximately 32 MiB SLC capacity is experimental third-party cache-analysis data. Those values are typed as mapped or experimental and expose their source in UI tooltips; they are not presented as live macOS readings. GPU identity and enabled core count are shown only when the running macOS system reports them through `system_profiler`. In default verified mode the SLC estimate is display-only; benchmark planning can use it only when the user enables the explicit experimental SLC option.

## Extended platform information

- Raw CPUID signature is `0x000B0671`: family 6, model `0xB7`, stepping 1. The corresponding verified platform is Raptor Lake-S / LGA1700.
- `sysctl machdep.cpu.model/stepping` reports spoofed model `0xA5`, stepping 5 on this OpenCore system and is therefore not used for CPU identity.
- CPUID leaf `0x16` reports 3500 MHz base, 5300 MHz advertised maximum, and 100 MHz reference clock.
- Modern Raptor Lake has no legacy FSB. `hw.busfrequency = 400 MHz` is not labeled as FSB/BCLK.
- DeviceTree reports four G.Skill `F4-3200C14-8GTZSW` DDR4 modules at 3800 MT/s.
- Primary DRAM timings and command rate are not exported by public macOS APIs or the available SMBIOS data. They remain explicitly unavailable rather than being inferred from the DIMM part number.
- SMBIOS is supplied by Acidanthera/OpenCore as `MacPro7,1`; firmware version `9999.999.999.999.999` is synthetic and is not presented as the real motherboard BIOS.
- PCI subsystem `1462:7D31` identifies MSI and a board-family ID, but the exact retail motherboard model is masked by spoofed SMBIOS.
