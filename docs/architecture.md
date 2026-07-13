# Architecture

Aida128 separates user intent, result modeling, and SIMD implementation.

```text
SwiftUI app ───────────────┐
                           ├─ BenchmarkKit ── C ABI ── C++ benchmark core
CLI parser and renderer ───┘
```

## Targets

- `BenchmarkCore`: system discovery, workload planning, AVX2/NEON kernels, worker synchronization, latency chains, and the stable C ABI.
- `BenchmarkKit`: architecture-neutral Swift configuration, selection, progress, report, and C callback lifetime handling.
- `BenchmarkCommandLine`: CLI grammar and text/JSON rendering.
- `Aida128CLI`: executable CLI entry point.
- `Aida128App`: SwiftUI/AppKit GUI, Acrylic/Reveal material, partial result state, and file export.

## Contract boundaries

Swift callers pass only intent: selected levels/metrics, total duration, sample count, and optional worker count. They do not pass cache sizes, ISA identifiers, kernel iteration counts, or downstream topology knowledge. The native core discovers those facts and returns typed results.

The original unversioned `A128SystemInfo` and `A128Report` remain byte-for-byte stable. Extended topology, SoC, GPU, firmware, system-cache, and provenance data use the separately sized `A128SystemInfoV2` contract. Callers provide writable capacity; the returned `struct_size` is the byte count actually written, so each tail field is consumed only when its complete range is present. Swift merges that static metadata into reports without changing the legacy benchmark ABI.

The benchmark report's embedded legacy system snapshot is authoritative for the run because it is the state used by the native planner. Optional `system_profiler` enrichment is an explicit asynchronous presentation step; it cannot fail a completed benchmark or replace cache capacities and topology used for measurement planning.

The V2 callback is synchronous on the native orchestration thread. Swift retains one callback context for exactly the duration of the native call and transfers ordered events to the main actor through `AsyncStream`.

## Measurement model

- Throughput is aggregate across a native worker team.
- Latency is one dependent pointer chain.
- A full UI run has four visible stages per discovered level and no hidden throughput passes. Requested levels are intersected with native availability; an entirely unavailable selection returns a typed error.
- Native benchmark runs are process-wide serialized because overlapping runs invalidate both measurements. A concurrent or callback-reentrant run is rejected immediately with `A128_STATUS_BUSY`; callers never wait behind another measurement.
- x86_64 uses AVX2; arm64 uses NEON/ASIMD. The legacy L3 level is presented as `System Cache (SLC)` on Apple Silicon, while its numeric ABI identity remains unchanged.
- Architecture-specific knowledge stays behind the C++ adapters.

See [methodology.md](methodology.md) for physical details and [verification.md](verification.md) for confirmed external contracts.
