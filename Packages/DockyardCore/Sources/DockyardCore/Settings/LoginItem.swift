import Foundation
import Observation
import ServiceManagement

/// Whether Dockyard opens when the user logs in.
///
/// `SMAppService.mainApp` registers the bundle itself with the system's Login
/// Items, which is the modern replacement for the deprecated
/// `SMLoginItemSetEnabled` and needs no helper target. It only works on a
/// bundle the system will accept: a development build run straight out of
/// DerivedData is often refused, and the error is reported rather than hidden,
/// because a toggle that silently springs back is worse than one that explains
/// itself.
@MainActor
@Observable
public final class LoginItem {
    public enum State: Sendable, Equatable {
        case enabled
        case disabled
        /// The user turned it off in System Settings; the app cannot turn it
        /// back on itself and must send them there.
        case blockedBySystemSettings
        case unavailable(String)

        public var isEnabled: Bool { self == .enabled }
    }

    public private(set) var state: State = .disabled
    /// Set when a register or unregister fails, so the UI can say why.
    public private(set) var lastError: String?

    private let service: LoginItemService

    public init(service: LoginItemService = SystemLoginItemService()) {
        self.service = service
        refresh()
    }

    public func refresh() {
        state = service.currentState()
    }

    /// Returns whether the change took, so the caller can put a toggle back.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        do {
            try enabled ? service.register() : service.unregister()
            refresh()
            // Registration is asynchronous in the system's own records, so the
            // state read back can lag by a moment; trust the call that did not
            // throw rather than showing the toggle snapping back.
            if state.isEnabled != enabled {
                state = enabled ? .enabled : .disabled
            }
            return true
        } catch {
            lastError = Self.explain(error, enabling: enabled)
            refresh()
            return false
        }
    }

    static func explain(_ error: any Error, enabling: Bool) -> String {
        let action = enabling ? "add Dockyard to your login items" : "remove Dockyard from your login items"
        let nsError = error as NSError
        // Code 1 is what a development build gets when the system will not take
        // the bundle; the plain message ("Operation not permitted") sends people
        // looking in the wrong place.
        if nsError.domain == "SMAppServiceErrorDomain" && nsError.code == 1 {
            return "macOS would not \(action). This usually means the app is not in /Applications, "
                + "or is a development build the system does not recognise."
        }
        return "Could not \(action): \(nsError.localizedDescription)"
    }
}

/// The part that talks to `ServiceManagement`, behind a protocol so the
/// surrounding logic can be tested without registering anything on the machine
/// running the tests.
@MainActor
public protocol LoginItemService {
    func currentState() -> LoginItem.State
    func register() throws
    func unregister() throws
}

public struct SystemLoginItemService: LoginItemService {
    public init() {}

    public func currentState() -> LoginItem.State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .blockedBySystemSettings
        case .notFound: .unavailable("macOS cannot find this copy of Dockyard.")
        @unknown default: .disabled
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
