import ArgumentParser
import ContainerAPIClient
import ContainerResource
import Foundation

extension RunSpec {
    /// Translates the sheet's values into upstream's flag structs.
    ///
    /// `Flags.*` are `ParsableArguments`, and they are created by *parsing an
    /// empty argument list* rather than by calling `init()`.
    ///
    /// This is not a stylistic choice. ArgumentParser's property wrappers only
    /// populate their storage during parsing; a directly constructed value
    /// traps on the first read with "Can't read a value from a parsable
    /// argument definition". Parsing `[]` applies every declared default —
    /// host architecture, `linux`, scheme `auto`, three concurrent downloads —
    /// which is exactly what the CLI uses when a flag is absent, and is how the
    /// app inherits that behaviour rather than restating it.
    ///
    /// Nothing is validated here beyond dropping blanks. `containerConfigFromFlags`
    /// does the real validation, which is the point of going through these
    /// structs rather than building a `ContainerConfiguration` directly.
    func toFlags() throws -> (
        process: Flags.Process,
        management: Flags.Management,
        resource: Flags.Resource,
        registry: Flags.Registry,
        imageFetch: Flags.ImageFetch
    ) {
        var process = try Flags.Process.parse([])
        process.env = environmentStrings
        process.envFile = environmentFiles.compacted()
        process.user = user.nonEmpty
        process.cwd = workingDirectory.nonEmpty
        process.ulimits = ulimits.compacted()
        process.tty = allocateTerminal
        process.interactive = keepStdinOpen

        var dns = try Flags.DNS.parse([])
        dns.nameservers = dnsNameservers.compacted()
        dns.domain = dnsDomain.nonEmpty
        dns.searchDomains = dnsSearchDomains.compacted()
        dns.options = dnsOptions.compacted()

        var management = try Flags.Management.parse([])
        management.dns = dns
        management.name = trimmedName.nonEmpty
        management.entrypoint = entrypoint.nonEmpty
        management.publishPorts = publishedPorts.compacted()
        management.publishSockets = publishedSockets.compacted()
        management.networks = networks.compacted()
        management.volumes = volumes.compacted()
        management.mounts = mounts.compacted()
        management.tmpFs = tmpfs.compacted()
        management.labels = labelStrings
        management.capAdd = addedCapabilities.compacted()
        management.capDrop = droppedCapabilities.compacted()
        management.shmSize = shmSize.nonEmpty
        management.kernel = kernel.nonEmpty
        management.initImage = initImage.nonEmpty
        management.useInit = useInit
        management.readOnly = readOnlyRootFilesystem
        management.remove = removeWhenStopped
        management.rosetta = enableRosetta
        management.virtualization = enableVirtualization
        management.ssh = forwardSSHAgent
        management.dnsDisabled = disableDNS
        management.runtime = runtimeHandler.nonEmpty
        // Left at its default when blank, so the runtime resolves the host's
        // platform exactly as it would for `container run` with no --platform.
        management.platform = platform.nonEmpty

        var resource = try Flags.Resource.parse([])
        resource.cpus = cpus.nonEmpty.flatMap(Int64.init)
        resource.memory = memory.nonEmpty

        return (process, management, resource, try Flags.Registry.parse([]), try Flags.ImageFetch.parse([]))
    }
}

extension String {
    /// The string, or nil when it holds nothing but whitespace.
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension [String] {
    /// Drops blank entries, which the UI's list editors leave behind.
    fileprivate func compacted() -> [String] {
        compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}
