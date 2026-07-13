# Building Aida128

## Requirements

- macOS 13 or later
- Xcode and the macOS SDK
- Swift 6.2-compatible toolchain or newer

## Local build

```bash
swift build
swift test
swift build -c release
```

The products are:

- `aida128`: SwiftUI GUI
- `aida128-bench`: CLI
- `BenchmarkKit`: Swift API
- `BenchmarkCore`: C ABI and C++ SIMD kernels

## Architecture-specific builds

```bash
swift build -c release \
  --triple x86_64-apple-macosx13.0 \
  --scratch-path .build-x86

swift build -c release \
  --triple arm64-apple-macosx13.0 \
  --scratch-path .build-arm
```

## Universal 2 app and CLI

```bash
VERSION=1.0.0 scripts/build-universal.sh
```

The script builds each architecture independently and combines corresponding executables with `lipo`. It verifies both slices and ad-hoc signs the app bundle.

## Sanitizers

ASan and TSan are run natively on the current host:

```bash
swift test --sanitize=address
swift test --sanitize=thread
```

Cross-compilation verifies ARM source and linkage but cannot execute ARM tests on an Intel host.
