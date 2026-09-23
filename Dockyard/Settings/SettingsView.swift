import DockyardCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                LabeledContent("Refresh every") {
                    HStack(spacing: 10) {
                        Slider(
                            value: $settings.pollIntervalSeconds,
                            in: AppSettings.pollIntervalRange,
                            step: 1
                        )
                        Text("\(Int(settings.pollIntervalSeconds))s")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                Text(
                    "The container runtime has no way to tell the app when something changes, "
                        + "so Dockyard asks. Polling stops entirely while the window is hidden."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the runtime's own images", isOn: $settings.showsInfrastructureImages)
                Text("The builder and init images Apple's runtime uses for itself. They cannot be deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start in the menu bar", isOn: $settings.startsHidden)
                Text("Dockyard opens without its window. The menu bar icon is always there either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LoginItemToggle()
            }

            Section {
                LabeledContent("Default platform") {
                    TextField("Chosen by the runtime", text: $settings.defaultPlatform)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Pre-fills the Pull and Run sheets, for example `linux/amd64`. Leave empty to let the runtime choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The login-item toggle, which has more states than a `Bool`.
private struct LoginItemToggle: View {
    @Environment(AppModel.self) private var model
    @State private var isOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: $isOn)
                .onChange(of: isOn) { _, wanted in
                    guard wanted != model.loginItem.state.isEnabled else { return }
                    if !model.loginItem.setEnabled(wanted) {
                        // The system refused; put the switch back rather than
                        // leaving it showing something that is not true.
                        isOn = model.loginItem.state.isEnabled
                    }
                }

            switch model.loginItem.state {
            case .blockedBySystemSettings:
                // The app cannot re-enable this itself once the user has turned
                // it off in System Settings, so pointing there is the only
                // honest thing to offer.
                HStack(spacing: 6) {
                    Text("Turned off in System Settings.")
                    Button("Open Login Items") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
                        )
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .enabled, .disabled:
                if let error = model.loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            model.loginItem.refresh()
            isOn = model.loginItem.state.isEnabled
        }
    }
}

private struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var deferredUntilIdle = false

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                LabeledContent("`container` command") {
                    HStack(spacing: 8) {
                        TextField(AppSettings.defaultCLIPath, text: $settings.cliPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(apply)
                        Button("Choose…", action: choose)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.tint)
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if settings.cliPath.isEmpty {
                        EmptyView()
                    } else {
                        Button("Use Default") {
                            settings.cliPath = ""
                            apply()
                        }
                        .buttonStyle(.link)
                    }
                }

                if deferredUntilIdle {
                    Text("The container system is starting or stopping. The new path takes effect once that finishes.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Only needed when Apple's package is installed somewhere other than \(AppSettings.defaultCLIPath).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.settings.cliPath) { apply() }
    }

    private func apply() {
        deferredUntilIdle = !model.applyCLIPath()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        panel.message = "Choose the container command"
        // `container` has no extension, so the panel is left open to any file
        // and the check below is what actually decides.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.cliPath = url.path
    }

    private var status: (symbol: String, tint: Color, message: String) {
        let path = model.settings.resolvedCLIPath
        let runner = CLIRunner(executablePath: path)
        if runner.isInstalled {
            return ("checkmark.circle.fill", .green, "Found at \(path)")
        }
        return ("exclamationmark.triangle.fill", .orange, "Nothing executable at \(path)")
    }
}
