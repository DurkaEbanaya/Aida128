# Benchmark methodology

## Units

Throughput uses decimal GB/s: one GB/s is 1,000,000,000 bytes per second. Headline Copy counts both source reads and destination writes, matching the traffic-bandwidth semantics used by the cache tests.

## Working sets

The native core owns cache discovery and working-set planning. Callers never provide cache sizes.

- L1: half the discovered L1D capacity.
- L2: half L2, and always at least twice L1D.
- L3: half L3, and always at least twice L2.
- Memory: at least 128 MiB and four times L3, capped at one eighth of physical memory.

Every working set is aligned to a 64-byte cache line. Allocation and page prefaulting happen before timed regions.

## Operations

- Read: eight independent aligned SIMD load/accumulator streams, avoiding a synthetic dependency bottleneck.
- Write: aligned cached SIMD stores.
- Copy: eight aligned SIMD load/store streams; `memcpy` is not used. Memory write and copy use non-temporal stores on x86_64 to avoid measuring write-allocate RFO as useful payload. Arm64 uses cached NEON stores because AArch64 has no equivalent general-purpose non-temporal store contract.
- Latency: one dependent access at a time through a deterministic, shuffled, single-cycle chain with one node per cache line.

Every completed throughput sweep crosses a compiler memory barrier. This makes each sweep observable and prevents dead-store elimination, repeated-copy elimination, and algebraic removal of repeated reads. The barrier emits no measured memory operation of its own.

The architecture-neutral native contract selects AVX2 on x86_64 and NEON/ASIMD on arm64. Both backends compile and link into the Universal 2 package, and generated arm64 assembly contains the intended vector load/store loops. Cross-compilation does not prove runtime behavior, so stable release remains gated on the real Apple Silicon validation described in `releasing.md`.

## Parallelism

The raw report contains two explicitly typed scopes. Single-worker measurements characterize all four hierarchy levels and include latency. Aggregate measurements provide throughput. The AIDA-like presentation combines aggregate Read/Write/Copy with single dependent-chain latency into one row per level. Workers persist across calibration and all measured samples, run at user-interactive QoS, and process private aligned buffers.

Native benchmark runs are serialized process-wide. Overlapping runs would compete for the same CPU caches and memory controllers and therefore cannot both produce valid machine measurements; callers are not required to coordinate this themselves.

## Selective runs and progress

The V2 run contract accepts explicit level and metric masks. A full GUI run consists of sixteen visible stages in `Memory → L1 → L2 → L3` order and `Read → Write → Copy → Latency` order within each level. Selecting a row executes only its four stages; selecting a cell executes only that stage. No hidden single-worker throughput pass is executed: throughput is aggregate and latency is a single dependent chain.

The user-selected duration is a total run budget divided across selected stages and samples. Each sample retains a physical minimum of 10 ms, so calibration, allocation, prefaulting, scheduling, and this lower bound can make wall-clock duration slightly longer than the selected budget. Native progress callbacks are emitted synchronously by the orchestration thread after real calibration/sample/stage events; the GUI does not synthesize intermediate results.

Aggregate L3 uses a private verified L3-sized working set per worker and limits the worker count so the combined footprint does not exceed discovered LLC capacity. This avoids partitioning each worker below private L2 capacity while also avoiding an aggregate footprint larger than LLC.

Latency remains single-threaded because aggregating independent pointer chains is not the latency of one dependent access. macOS does not expose a supported hard-affinity API, so the benchmark does not claim that latency ran on a specific P-core or E-core.

## Sampling

Each operation is calibrated outside the reported sample so a sample meets the configured duration. The default is five 200 ms samples. The headline is maximum throughput or minimum latency, matching the intent of AIDA-like peak measurement. Relative min/max spread is reported so scheduler migration, thermal instability, and background load remain visible.
