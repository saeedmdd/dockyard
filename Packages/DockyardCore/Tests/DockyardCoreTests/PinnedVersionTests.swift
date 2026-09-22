import Foundation
import Testing

@testable import DockyardCore

/// Guards against drift between the upstream pin in `Package.swift` and the
/// version string the app compares against `container-apiserver` at runtime.
@Suite struct PinnedVersionTests {
    static var packageManifest: String {
        get throws {
            // <package>/Tests/DockyardCoreTests/PinnedVersionTests.swift
            let manifest = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Package.swift")
            return try String(contentsOf: manifest, encoding: .utf8)
        }
    }

    @Test func linkedVersionMatchesManifestPin() throws {
        let manifest = try Self.packageManifest
        let pin = try #require(
            manifest.firstMatch(of: /let containerVersion: Version = "([^"]+)"/),
            "containerVersion pin not found in Package.swift"
        )
        #expect(String(pin.1) == DockyardCore.linkedContainerVersion)
    }

    @Test func coreVersionIsSemver() {
        #expect(DockyardCore.version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
    }
}
