# ci-test-compile (claude lead)

- consult · codex · 1 min · exit: 0 · changed outcome: n — confirmed the tests-only fix; verified both AlignmentTests helpers are stateless and the two `AlignmentTests()` calls are the only test-case constructions · 01a163f2-f6ec

Inspected: CI run 39790235448 and earlier failed runs; four test lines that compile on local Swift 6.4 but not on CI's Swift 6.1 (Linux) / Xcode 16 (macos-15): DataTests.swift:162, LandCoverTests.swift:59, LensTests.swift:157, PhotoImportTests.swift:177.
Applied: dropped the ambiguous `Int16(...)`, split the slow LandCover expression, made `AlignmentTests.horizon`/`farHeading` static instead of constructing `AlignmentTests()` (no `init()` in corelibs XCTest).
Declined: none. Limits: no Swift 6.1 or Linux toolchain locally (no Docker), so the CI run after the push is the Linux check.
Lesson: tests that pass on local Swift 6.4 can still fail to compile on CI's Swift 6.1/Linux; check the run after pushing.
