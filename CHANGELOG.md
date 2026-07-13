# Changelog

All notable changes to this project are documented here.

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
- Apple Silicon compile/link/NEON assembly: verified.
- Apple Silicon real-device runtime: pending before stable v0.1.0.
