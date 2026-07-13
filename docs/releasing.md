# Release process

## Release gates

1. `swift test`
2. `swift test --sanitize=address`
3. `swift test --sanitize=thread`
4. Intel release build and benchmark smoke run
5. ARM64 release build
6. Universal 2 packaging and architecture verification
7. Real Apple Silicon GUI and CLI smoke run
8. Real Apple Silicon JSON report review
9. Publish stable release only after all gates pass

## Apple Silicon validation

On an Apple Silicon Mac:

```bash
uname -m
./aida128-bench --samples 3 --duration-ms 100 --format json --output arm-smoke.json
open Aida128.app
```

Expected architecture is `arm64`, backend is `ARM NEON cached`, all selected metrics are finite and positive, and progress completes monotonically.

## Signing

The public script uses ad-hoc signing. A trusted distribution should use a Developer ID Application certificate, hardened runtime, notarization, and stapling. Do not describe an ad-hoc package as notarized.

## Release candidate policy

Artifacts may be published as a GitHub prerelease before real ARM validation, provided the release notes state the limitation. Stable `v0.1.0` requires real-device ARM validation.
