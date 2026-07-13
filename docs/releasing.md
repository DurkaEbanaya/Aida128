# Release process

## Release gates

1. `swift test`
2. `swift test --sanitize=address`
3. `swift test --sanitize=thread`
4. Intel release build and benchmark smoke run
5. Package-consumer executable smoke run
6. ARM64 release build
7. Universal 2 packaging and architecture verification
8. Apple Silicon native tests, CLI smoke run, and JSON report review in CI
9. Physical Apple Silicon GUI and CLI smoke run when available

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

## Validation disclosure policy

Release notes must state which gates passed for that artifact. If physical Apple Silicon GUI validation, Developer ID signing, notarization, or stapling are unavailable, the release must say so explicitly instead of implying full platform/distribution validation.
