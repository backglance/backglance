import BackglanceCapture
import Foundation

// FixtureGenerator writes the synthetic store fixtures under Tests/Fixtures/SystemStore/.
// It is an executable rather than a shell script because hand-building a bplist in bash
// is not something anyone should maintain; Scripts/make_fixture.sh shells out to it.
//
// The generator is implemented in Phase 1 alongside the adapters it produces fixtures for.
// It never reads a real store and never emits a real verification code: every value comes
// from a seeded SplitMix64, so a fixture is reproducible and contains no personal data.

let supported = BackglanceCapture.supportedOSMajorVersions
    .map(String.init)
    .joined(separator: ", ")
FileHandle.standardError.write(Data(
    "FixtureGenerator: not implemented yet (Phase 1.8). Supported macOS majors: \(supported).\n".utf8
))
exit(EXIT_FAILURE)
