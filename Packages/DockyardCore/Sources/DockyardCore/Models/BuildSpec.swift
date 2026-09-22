import Foundation

/// What to build, and how.
///
/// Mirrors `container build`'s options, because that is what runs it: the build
/// pipeline lives in the CLI rather than in a client library, so this describes
/// a command line rather than an API call.
public struct BuildSpec: Sendable, Equatable, Codable {
    /// The build context — the folder sent to the builder.
    public var contextDirectory: URL
    /// Path to the Dockerfile, relative to the context unless absolute.
    public var dockerfile: String = "Dockerfile"
    /// `name[:tag]` for the result. Required: an untagged build lands under a
    /// generated UUID, which is no use to anyone afterwards.
    public var tag: String = ""
    public var platform: String = ""
    public var target: String = ""
    public var buildArguments: [RunSpec.KeyValue] = []
    public var labels: [RunSpec.KeyValue] = []
    public var noCache = false

    public init(contextDirectory: URL) {
        self.contextDirectory = contextDirectory
    }

    /// Dockerfile names to look for, in the order `container build` prefers.
    public static let dockerfileNames = ["Dockerfile", "Containerfile"]

    /// Finds a Dockerfile in a folder, if there is one.
    public static func detectDockerfile(in directory: URL) -> String? {
        dockerfileNames.first { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    public var trimmedTag: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The arguments for `container build`.
    ///
    /// `--progress plain` is not optional here: the default (`auto`) emits a
    /// redrawing TTY display full of escape sequences, which is meaningless
    /// piped into a text view.
    public func commandArguments() -> [String] {
        var arguments = ["build", "--progress", "plain"]

        if !trimmedTag.isEmpty {
            arguments += ["--tag", trimmedTag]
        }
        if dockerfile != "Dockerfile" && !dockerfile.isEmpty {
            arguments += ["--file", dockerfile]
        }
        let platform = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        if !platform.isEmpty {
            arguments += ["--platform", platform]
        }
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty {
            arguments += ["--target", target]
        }
        if noCache {
            arguments.append("--no-cache")
        }
        for argument in buildArguments where !argument.isEmpty {
            arguments += ["--build-arg", argument.joined]
        }
        for label in labels where !label.isEmpty {
            arguments += ["--label", label.joined]
        }

        // The context goes last, as the command's positional argument.
        arguments.append(contextDirectory.path)
        return arguments
    }

    /// Problems worth stopping for before starting a build.
    public var validationProblems: [String] {
        var problems: [String] = []
        if trimmedTag.isEmpty {
            problems.append("Give the image a name, or you won’t be able to find it afterwards.")
        } else if !Self.isValidTag(trimmedTag) {
            problems.append("“\(trimmedTag)” isn’t a valid image name.")
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: contextDirectory.path, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue {
            problems.append("The build folder doesn’t exist.")
        } else if resolvedDockerfileURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            problems.append("No \(dockerfile) in that folder.")
        }
        return problems
    }

    public var isBuildable: Bool { validationProblems.isEmpty }

    /// Where the Dockerfile actually is, resolving relative paths against the
    /// context the way the CLI does.
    public var resolvedDockerfileURL: URL? {
        guard !dockerfile.isEmpty else { return nil }
        if dockerfile.hasPrefix("/") { return URL(fileURLWithPath: dockerfile) }
        return contextDirectory.appendingPathComponent(dockerfile)
    }

    /// Accepts `name`, `name:tag`, and registry-qualified forms with ports.
    public static func isValidTag(_ tag: String) -> Bool {
        tag.range(
            of: #"^[a-zA-Z0-9][a-zA-Z0-9._/-]*(:[0-9]+)?(/[a-zA-Z0-9._/-]+)*(:[a-zA-Z0-9._-]+)?$"#,
            options: .regularExpression
        ) != nil
    }
}
