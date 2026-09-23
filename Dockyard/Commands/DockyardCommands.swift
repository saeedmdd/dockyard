import DockyardCore
import SwiftUI

/// Every keyboard shortcut in the app, in the menus where people look for them.
///
/// Shortcuts live here rather than on the buttons that also perform these
/// actions: a shortcut attached to a toolbar button only works while that
/// button is on screen, which makes ⌘. stop working the moment the user opens a
/// detail pane. A menu command works wherever the window is focused, and it is
/// also the only way the shortcut becomes discoverable.
struct DockyardCommands: Commands {
    let model: AppModel

    private var actions: ContainerActions { ContainerActions(model: model) }
    private var selected: ContainerItem? { model.selectedContainer }

    var body: some Commands {
        // The app creates containers and images, not documents; leaving File ▸
        // New pointing at nothing is worse than replacing it.
        CommandGroup(replacing: .newItem) {
            Button("Run Container…") {
                model.selectedSection = .containers
                model.runSheetRequest = RunSheetRequest(image: nil)
            }
            .keyboardShortcut("n")

            Button("Pull Image…") {
                model.selectedSection = .images
                model.pullSheetRequest += 1
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Build Image…") {
                model.selectedSection = .images
                model.buildSheetRequest += 1
            }
            .keyboardShortcut("b")
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            // ⌘F is what people press to filter a list, so the list gets it and
            // the log search — which is only reachable with a container open —
            // takes the shifted variant.
            Button("Find") {
                model.findRequest += 1
            }
            .keyboardShortcut("f")
            .disabled(model.selectedSection == .system)

            Button("Find in Logs") {
                model.logSearchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.selectedSection != .containers || selected == nil)
        }

        CommandMenu("Container") {
            Button("Start") {
                if let selected { actions.start(selected) }
            }
            .keyboardShortcut(.return)
            .disabled(selected.map { !actions.canStart($0) || actions.isBusy($0) } ?? true)

            Button("Stop") {
                if let selected { actions.stop(selected) }
            }
            .keyboardShortcut(".")
            .disabled(selected.map { !actions.canStop($0) || actions.isBusy($0) } ?? true)

            Divider()

            // Named for what is selected, so the menu never offers to delete a
            // container while the Images list is on screen.
            Button("Delete \(model.selectedSection.deletableNoun)…") {
                model.requestDeleteSelection()
            }
            .keyboardShortcut(.delete)
            .disabled(!model.hasDeletableSelection)
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") {
                Task { await model.refreshNow() }
            }
            .keyboardShortcut("r")

            Divider()

            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { model.selectedSection = section }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")),
                        modifiers: .command
                    )
            }

            Divider()
        }

        SidebarCommands()
    }
}

extension SidebarSection {
    /// What ⌘⌫ removes in this section, singular, for the menu item's title.
    var deletableNoun: String {
        switch self {
        case .containers: "Container"
        case .images: "Image"
        case .volumes: "Volume"
        case .networks: "Network"
        case .system: "Selection"
        }
    }
}
