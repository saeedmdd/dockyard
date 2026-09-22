import Foundation

/// Progress while creating a container.
///
/// Creating one can involve fetching and unpacking an image and a kernel, which
/// is most of what a pull does, so the same progress model is reused.
public enum CreateProgress: Sendable, Equatable {
    case working(PullProgress)
    /// The container exists; this carries its id.
    case created(id: String)
}
