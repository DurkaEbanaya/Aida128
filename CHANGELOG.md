# Changelog

All notable changes to this project are documented here.

## [0.1.0-rc.2] - 2026-07-13

### Added

- Apple Silicon-specific system panel with SoC topology, unified memory, optional GPU, firmware, OS loader, and System Cache metadata provenance.
- Additive caller-sized `A128SystemInfoV2` metadata ABI while preserving the legacy benchmark ABI.

### Fixed

- Keep Apple Silicon experimental SLC capacities display-only; benchmark execution still requires a runtime-verified exact capacity.
- Keep benchmark reports tied to the native system snapshot used for workload planning.
- Align Swift and native last-level-cache availability rules.

### Validation status

- Intel runtime, ASan, TSan, CLI smoke, package consumer, and GUI launch smoke: verified.
- Apple Silicon arm64 cross-build and Universal 2 slice verification: verified.
- Physical Apple Silicon GUI/CLI validation remains pending before stable v0.1.0.

## [0.1.0-rc.1] - 2026-07-13

### Added

- AVX2 Intel benchmark backend.
- NEON/ASIMD Apple Silicon backend.
- Memory, L1, L2, system-cache/L3, Read, Write, Copy, and Latency tests.
- Whole-grid, row, and individual-cell execution.
- Native stage/sample progress callbacks.
- User-selectable total run duration.
- Fluent-inspired Acrylic/Reveal light and dark GUI.
- Detailed CPU, memory, platform, firmware, and ISA discovery.
- Text and JSON CLI output.
- Universal 2 packaging script and CI.

### Validation status

- Intel runtime, ASan, and TSan: verified.
- Apple Silicon compile/link, NEON assembly, native tests, and CLI smoke on a GitHub-hosted M1 VM: verified.
- Apple Silicon physical-device GUI runtime: pending before stable v0.1.0.
