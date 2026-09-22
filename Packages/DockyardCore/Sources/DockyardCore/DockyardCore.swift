import Foundation

/// Namespace for package-level metadata.
public enum DockyardCore {
    /// Version of the Dockyard app/core.
    public static let version = "0.1.0"

    /// Version of `apple/container` this build links against.
    ///
    /// The installed `container-apiserver` must report this same version for the
    /// XPC protocol to line up. Kept in sync with the `containerVersion` pin in
    /// `Package.swift` by `PinnedVersionTests`.
    ///
    /// `ContainerVersion.ReleaseVersion` is deliberately not used here: it reads
    /// `CFBundleShortVersionString` from the *host* bundle, which for Dockyard is
    /// Dockyard's own version, not the linked container version.
    public static let linkedContainerVersion = "1.0.0"
}
