import AppKit
import DockyardCore
import SwiftUI

/// Where the container system itself is managed: whether it is running, what
/// versions are in play, what it is using on disk, and where its files live.
struct SystemView: View {
    @Environment(AppModel.self) private var model
    @State private var pruneTarget: PruneTarget?
    @State private var isConfirmingStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusSection
                versionsSection
                diskSection
                if let kernel = model.system.kernel {
                    kernelSection(kernel)
                }
                logsSection
                if !model.problems.isEmpty {
                    problemsSection
                }
                filesSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("System")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.system.refreshUsage() }
            }
            .help("Re-read disk usage")
            .accessibilityLabel("Refresh disk usage")
        }
        .task(id: model.system.status.summary) {
            await model.system.refreshUsage()
        }
        .pruneConfirmation(target: $pruneTarget)
        .confirmationDialog(
            "Stop the container system?",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) { model.system.stop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every running container stops with it. Nothing is deleted.")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        section("Status") {
            HStack(spacing: 10) {
                StatusDot(status: model.system.status, size: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.system.status.summary)
                        .font(.headline)
                    if let health = model.system.status.health {
                        Text(health.appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusActions
            }

            if let error = model.system.lastError {
                Label(error.errorDescription ?? "Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if !model.system.transcript.isEmpty {
                TranscriptView(lines: model.system.transcript)
                    .frame(height: 120)
            }
        }
    }

    @ViewBuilder
    private var statusActions: some View {
        if model.system.status.isTransitioning {
            ProgressView().controlSize(.small)
            Button("Cancel") { model.system.cancelOperation() }
        } else if model.system.status.isOperational {
            Button("Stop…", systemImage: "stop.fill") { isConfirmingStop = true }
                .accessibilityLabel("Stop the container system")
                .help("Stop the container system and everything running in it")
        } else {
            Button("Start", systemImage: "play.fill") { model.system.start() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Start the container system")
                .help("Start the container system")
        }
    }

    // MARK: - Versions

    private var versionsSection: some View {
        section("Versions") {
            LabeledContent("Dockyard", value: Self.appVersion)
            // The app is compiled against one version of Apple's client
            // libraries and talks to whatever apiserver is installed; when they
            // diverge, which one is which is the first thing worth knowing.
            LabeledContent("Linked client", value: DockyardCore.linkedContainerVersion)
            if let health = model.system.status.health {
                LabeledContent("Container system") {
                    HStack(spacing: 6) {
                        Text(health.semanticVersion ?? health.apiServerVersion)
                            .textSelection(.enabled)
                            .help(health.apiServerVersion)
                        if !health.matchesLinkedVersion {
                            Label("Mismatch", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                CopyableRow(label: "Commit", value: health.apiServerCommit, isMonospaced: true)
                LabeledContent("Build", value: health.apiServerBuild)
            } else {
                Text("Available once the container system is running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }()

    // MARK: - Disk usage

    @ViewBuilder
    private var diskSection: some View {
        let usage = model.system.diskUsage
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk usage").font(.headline)
                Spacer()
                if let usage {
                    Text("\(usage.totalLabel) used · \(usage.totalReclaimableLabel) reclaimable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if let usage {
                    usageRow(.containers, usage.containers)
                    Divider()
                    usageRow(.images, usage.images)
                    Divider()
                    usageRow(.volumes, usage.volumes)
                } else {
                    HStack(spacing: 8) {
                        if model.system.status.isOperational {
                            ProgressView().controlSize(.small)
                            Text("Measuring…")
                        } else {
                            Text("Available once the container system is running.")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if let result = model.system.lastPrune {
                    Divider()
                    pruneOutcome(result)
                }
                if let error = model.system.panelError {
                    Divider()
                    Label(error.errorDescription ?? "Something went wrong", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func usageRow(_ target: PruneTarget, _ usage: ResourceUsage) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(target.title).fontWeight(.medium)
                    Text("\(usage.active) of \(usage.total) in use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // The filled part is what is in use; the track behind it is the
                // total. Reading the bar as "how much I could get back" is the
                // point of the panel.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * (1 - usage.reclaimableFraction))
                    }
                }
                .frame(height: 5)
                .accessibilityLabel(
                    "\(target.title): \(usage.sizeLabel), \(usage.reclaimableLabel) reclaimable"
                )
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(usage.sizeLabel)
                    .font(.callout.monospacedDigit())
                Text("\(usage.reclaimableLabel) free-able")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .trailing)

            Button(target.actionTitle) { pruneTarget = target }
                .accessibilityLabel("\(target.actionTitle) \(target.title.lowercased())")
                .disabled(usage.idleCount == 0 || model.system.pruning != nil)
                .help(
                    usage.idleCount == 0
                        ? "Everything here is in use"
                        : target.confirmationMessage
                )
                .overlay(alignment: .trailing) {
                    if model.system.pruning == target {
                        ProgressView()
                            .controlSize(.small)
                            .offset(x: 22)
                    }
                }
        }
    }

    private func pruneOutcome(_ result: PruneResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: result.failedCount > 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(result.failedCount > 0 ? .orange : .green)
                Text(result.summary)
                Spacer()
                Button("Dismiss") { model.system.clearLastPrune() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            ForEach(result.failures, id: \.self) { failure in
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Kernel

    private func kernelSection(_ kernel: KernelInfo) -> some View {
        section("Kernel") {
            LabeledContent("Platform", value: kernel.platformDescription)
            CopyableRow(label: "File", value: kernel.path, isMonospaced: true)
            if !kernel.arguments.isEmpty {
                LabeledContent("Boot arguments") {
                    Text(kernel.arguments.joined(separator: " "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        @Bindable var system = model.system

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Logs").font(.headline)
                Spacer()
                Picker("", selection: $system.logWindow) {
                    ForEach(SystemLogWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
                Button(system.logLines.isEmpty ? "Show" : "Reload") {
                    Task { await system.loadLogs() }
                }
                .disabled(system.isLoadingLogs || !system.status.isOperational)
                .help("Read what the container runtime logged in this window")
            }

            VStack(alignment: .leading, spacing: 6) {
                if system.isLoadingLogs {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the system log…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else if system.logLines.isEmpty {
                    // Worth spelling out: people look for a file, and there
                    // isn't one.
                    Text(
                        "The container runtime writes to the unified system log rather than to a file. "
                            + "This reads the same entries `container system logs` prints."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    if system.droppedLogLines > 0 {
                        Text("Showing the most recent \(SystemStore.maximumLogLines) lines.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    PlainTextLogView(store: system, version: system.logVersion)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Problems

    /// What the toasts said, in full, for as long as the app is running.
    ///
    /// A toast is gone in six seconds — fine for noticing, useless for copying
    /// an upstream message into a bug report.
    private var problemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent problems").font(.headline)
                Spacer()
                Button("Clear") { model.clearProblems() }
                    .buttonStyle(.link)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.problems.enumerated()), id: \.element.id) { index, problem in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem.title)
                            .font(.callout.weight(.medium))
                            .textSelection(.enabled)
                        if let detail = problem.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        section("Files") {
            if let health = model.system.status.health {
                folderRow("Data", url: health.appRoot)
                folderRow("Installed at", url: health.installRoot)
                // Present only on installs that redirect the runtime's output
                // to files; on a normal one it is empty and the Logs section
                // above is where the output actually is.
                if let logRoot = health.logRoot {
                    folderRow("Logs", url: logRoot)
                }
            } else {
                Text("Available once the container system is running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func folderRow(_ label: String, url: URL) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Button("Open", systemImage: "folder") {
                    // `selectFile: nil` opens the folder rather than revealing
                    // it inside its parent, which is what "Open" promises.
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                }
                .buttonStyle(.link)
                .labelStyle(.titleOnly)
                .help("Show \(url.lastPathComponent) in Finder")
                .accessibilityLabel("Show \(label) folder in Finder")
            }
        }
    }

    // MARK: - Layout

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Confirmation before a prune, naming what it takes and what it leaves.
struct PruneConfirmation: ViewModifier {
    @Binding var target: PruneTarget?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target.map { "Remove unused \($0.title.lowercased())?" } ?? "Remove?",
            isPresented: .init(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible,
            presenting: target
        ) { target in
            Button("Remove", role: .destructive) {
                Task { await model.system.prune(target) }
                self.target = nil
            }
            Button("Cancel", role: .cancel) { self.target = nil }
        } message: { target in
            Text(target.confirmationMessage)
        }
    }
}

extension View {
    func pruneConfirmation(target: Binding<PruneTarget?>) -> some View {
        modifier(PruneConfirmation(target: target))
    }
}
