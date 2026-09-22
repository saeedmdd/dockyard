import ContainerizationError
import Foundation

extension DockyardError {
    /// Translates an upstream failure into something the UI can branch on.
    ///
    /// Client calls wrap their failures, so a dead daemon arrives as
    /// `internalError("failed to list containers", cause: interrupted("XPC
    /// connection error: Connection invalid"))`. The signal is in the cause, so
    /// the whole chain is walked rather than only the outermost error.
    public init(mapping error: any Error) {
        if let mapped = error as? DockyardError {
            self = mapped
            return
        }

        let chain = Self.errorChain(from: error)

        for case let containerError as ContainerizationError in chain {
            if containerError.isCode(.interrupted) || containerError.message.contains(Self.xpcConnectionMarker) {
                self = .daemonUnreachable(containerError.message)
                return
            }
            if containerError.message.contains(Self.xpcTimeoutMarker) {
                self = .daemonTimeout(containerError.message)
                return
            }
        }

        if let containerError = chain.compactMap({ $0 as? ContainerizationError }).first {
            // Prefer the innermost message: the outer layers are generic
            // ("failed to create container"), the inner one says what was wrong.
            let innermost = chain.compactMap { $0 as? ContainerizationError }.last ?? containerError
            self = .upstream(
                code: containerError.code.description,
                message: innermost.message
            )
            return
        }

        self = .other(error.localizedDescription)
    }

    private static let xpcConnectionMarker = "XPC connection error"
    private static let xpcTimeoutMarker = "XPC timeout"

    /// The error plus every `cause` beneath it, outermost first.
    private static func errorChain(from error: any Error) -> [any Error] {
        var chain: [any Error] = []
        var current: (any Error)? = error
        // Bounded so a self-referencing cause cannot spin forever.
        while let error = current, chain.count < 16 {
            chain.append(error)
            current = (error as? ContainerizationError)?.cause
        }
        return chain
    }
}
