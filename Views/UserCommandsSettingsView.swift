import AppKit
import SwiftUI

/// The Settings window: keyboard shortcuts and user commands. The selected tab is kept in
/// UserDefaults so "Commands ▸ Edit Commands…" can open straight on its tab.
struct SettingsView: View {
    static let tabKey = "Marlia.SettingsTab"
    @AppStorage(SettingsView.tabKey) private var tab = "shortcuts"

    var body: some View {
        TabView(selection: $tab) {
            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag("shortcuts")
            UserCommandsSettingsView()
                .tabItem { Label("Commands", systemImage: "terminal") }
                .tag("commands")
        }
        .padding(.top, 6)
        .frame(minWidth: 640, minHeight: 520)
    }
}

/// Records one key combination for a user command. Same technique as ShortcutRecorder (a
/// local monitor sees the event before the main menu would perform it), but not tied to
/// AppCommand.
@MainActor
final class UserCommandShortcutRecorder: ObservableObject {
    @Published private(set) var recordingID: UUID?
    private var monitor: Any?

    func start(_ id: UUID, onCapture: @escaping (Shortcut) -> Void) {
        stop()
        recordingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recordingID != nil else { return event }
            self.stop()
            if event.keyCode == 53 { return nil }   // Escape cancels
            onCapture(Shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags,
                               character: event.charactersIgnoringModifiers?.lowercased() ?? ""))
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
    }
}

struct UserCommandsSettingsView: View {
    @ObservedObject private var store = UserCommandStore.shared
    @StateObject private var recorder = UserCommandShortcutRecorder()
    @State private var selectedID: UUID?

    private var selectedIndex: Int? { store.commands.firstIndex { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider()
            Group {
                if let index = selectedIndex {
                    editor(for: index)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { if selectedID == nil { selectedID = store.commands.first?.id } }
        .onDisappear { recorder.stop() }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.commands) { command in
                    HStack {
                        Text(command.name.isEmpty ? "Untitled" : command.name).lineLimit(1)
                        Spacer()
                        if let shortcut = command.shortcut {
                            Text(shortcut.displayString).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(command.id)
                }
                .onMove { store.commands.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            Divider()
            HStack(spacing: 2) {
                Menu {
                    Button("Empty Command") { add(UserCommand(name: "New Command", script: "")) }
                    Divider()
                    ForEach(UserCommand.templates, id: \.name) { template in
                        Button(template.name) { add(template) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a command or start from an example")
                Button {
                    guard let index = selectedIndex else { return }
                    store.commands.remove(at: index)
                    selectedID = store.commands.indices.contains(index) ? store.commands[index].id : store.commands.last?.id
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedIndex == nil)
                Spacer()
            }
            .padding(8)
        }
    }

    private func add(_ template: UserCommand) {
        var command = template
        command.id = UUID()
        store.commands.append(command)
        selectedID = command.id
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("User Commands").font(.headline)
            Text("Run your own shell scripts on the selected files, from the Commands menu, the command palette (⇧⌘P) or a shortcut. Click + to add one or to start from an example.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            variablesHelp
        }
        .padding(20)
    }

    // MARK: Editor

    private func editor(for index: Int) -> some View {
        let command = $store.commands[index]
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: command.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Script").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: command.script)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                }

                HStack(spacing: 8) {
                    Text("Shortcut")
                    Button(recorder.recordingID == command.wrappedValue.id
                           ? "Press keys…"
                           : (command.wrappedValue.shortcut?.displayString ?? "None")) {
                        let id = command.wrappedValue.id
                        recorder.start(id) { shortcut in
                            if let i = store.commands.firstIndex(where: { $0.id == id }) { store.commands[i].shortcut = shortcut }
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 90)
                    if command.wrappedValue.shortcut != nil {
                        Button { command.wrappedValue.shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Remove the shortcut")
                    }
                    Spacer()
                }
                if let warning = shortcutWarning(for: command.wrappedValue) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Refresh both panes when it finishes", isOn: command.refreshAfter)
                Picker("Show output", selection: command.output) {
                    ForEach(UserCommand.OutputMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Divider()
                variablesHelp
            }
            .padding(20)
        }
    }

    private var variablesHelp: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Available to the script").font(.caption.weight(.semibold))
            Group {
                Text("\"$@\" — the selected items (no selection, no arguments)")
                Text("$MARLIA_DIR — the active pane's folder (also the working directory)")
                Text("$MARLIA_OTHER_DIR — the other pane's folder")
                Text("$MARLIA_SELECTION — selected paths, one per line; $MARLIA_FILE — the first")
                Text("Runs in a zsh login shell, so your ~/.zprofile PATH (Homebrew) applies.")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A shortcut without ⌘ (other than a function key) never reaches the menu: the file
    /// panes see the key first and swallow it (see CLAUDE.md). Clashes are reported too.
    private func shortcutWarning(for command: UserCommand) -> String? {
        guard let shortcut = command.shortcut else { return nil }
        if ShortcutStore.isReserved(shortcut) {
            return "\(shortcut.displayString) is reserved by macOS and won't work."
        }
        let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        if !shortcut.modifierFlags.contains(.command), !functionKeys.contains(shortcut.keyCode) {
            return "Add ⌘ to this shortcut: without it the file list takes the key first and the command never runs."
        }
        let builtIn = AppCommand.allCases.filter { c in
            ShortcutStore.shared.shortcuts(for: c).contains { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers }
        }
        if let clash = builtIn.first { return "\(shortcut.displayString) is also \(clash.title)." }
        let others = store.commands.filter { $0.id != command.id && $0.shortcut.map { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers } == true }
        if let other = others.first { return "\(shortcut.displayString) is also used by “\(other.name)”." }
        return nil
    }
}
