import DockyardCore
import SwiftUI
import UniformTypeIdentifiers

/// Sign in to a registry, and manage the sign-ins already stored.
struct RegistrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var credentials = RegistryCredentials()
    @State private var scheme: RegistryScheme = .auto
    @FocusState private var isHostFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Registries")
                .font(.title3.weight(.semibold))

            if !model.registry.logins.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signed in")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.registry.logins) { login in
                        HStack(spacing: 8) {
                            Image(systemName: "key")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(login.hostname).font(.callout)
                                Text(login.username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sign Out") {
                                model.registry.logOut(hostname: login.hostname)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                Divider()
            }

            Text("Add a registry")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LabeledField("Registry", required: true) {
                TextField("ghcr.io", text: $credentials.hostname)
                    .textFieldStyle(.roundedBorder)
                    .focused($isHostFocused)
            }
            LabeledField("Username", required: true) {
                TextField("", text: $credentials.username)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Password or token", required: true) {
                SecureField("", text: $credentials.password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(signIn)
            }

            Text("Credentials are stored in your login keychain, in the same place the `container` command uses.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = model.registry.actionError {
                Label(error.errorDescription ?? "Could not sign in", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Divider()
            HStack {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.registry.isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Sign In", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!credentials.isValid || model.registry.isWorking)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            model.registry.refreshLogins()
            isHostFocused = true
        }
    }

    private func signIn() {
        guard credentials.isValid else { return }
        let entered = credentials
        Task {
            if await model.registry.logIn(entered, scheme: scheme) {
                // Only the password is cleared: signing in to a second
                // registry usually means the same username.
                credentials.password = ""
            }
        }
    }
}

/// Push an image to its registry.
struct PushSheet: View {
    let image: ImageItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var reference: String
    @State private var scheme: RegistryScheme = .auto

    init(image: ImageItem) {
        self.image = image
        _reference = State(initialValue: image.displayReference)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Push image")
                .font(.title3.weight(.semibold))

            LabeledField("Reference") {
                TextField("ghcr.io/me/app:1.0", text: $reference)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(push)
            }

            Picker("Connection", selection: $scheme) {
                ForEach(RegistryScheme.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Push", action: push)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { model.registry.refreshLogins() }
    }

    private var trimmed: String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Warns before the push fails, when nothing is signed in for the registry
    /// this reference points at.
    private var hint: String {
        let host = trimmed.split(separator: "/").first.map(String.init) ?? ""
        let knows = model.registry.logins.contains { host.contains($0.hostname) || $0.hostname.contains(host) }
        if host.contains(".") && !knows {
            return "You’re not signed in to \(host). Sign in first if it needs credentials."
        }
        if scheme == .auto && (host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost")) {
            return "A registry on this Mac usually speaks plain HTTP — choose HTTP if the push is refused."
        }
        return "The image is pushed to the registry in its name."
    }

    private func push() {
        let target = trimmed
        guard !target.isEmpty else { return }
        Task {
            // Pushing under a different name means tagging first, exactly as
            // the CLI requires.
            if target != image.reference && target != image.displayReference {
                await model.images.tag(image.reference, as: target)
            }
            model.registry.push(reference: target, scheme: scheme)
        }
        dismiss()
    }
}
