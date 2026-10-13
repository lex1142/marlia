import AppKit
import SwiftUI

/// The keyboard-shortcut settings screen (phase 3): commands by category, recording a
/// new shortcut, conflict highlighting, reset.
///
/// Recording goes through a LOCAL NSEvent MONITOR rather than a plain keyDown:
/// main-menu key equivalents are dispatched in NSApplication.sendEvent(_:) before the
/// event reaches the first responder, so trying to record, say, ⌘C without a monitor
/// would simply perform "Copy". The monitor sees the event before sendEvent and
/// swallows it by returning nil — so any combination can be recorded, including ones
/// the menu already uses.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: AppCommand?
    /// The last assignment error (e.g. an attempt to take a system shortcut).
    @Published var message: String?

    private var monitor: Any?
    private var onCapture: ((AppCommand, Shortcut) -> Void)?

    func start(_ command: AppCommand, onCapture: @escaping (AppCommand, Shortcut) -> Void) {
        stop()
        recording = command
        self.onCapture = onCapture
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let target = self.recording else { return event }
            // Escape cancels recording; nothing is assigned.
            if event.keyCode == 53 {
                self.stop()
                return nil
            }
            let shortcut = Shortcut(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                // charactersIgnoringModifiers already accounts for the current
                // keyboard layout — no separate keyCode→character conversion is
                // needed.
                character: event.charactersIgnoringModifiers?.lowercased() ?? ""
            )
            let capture = self.onCapture
            self.stop()
            capture?(target, shortcut)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        onCapture = nil
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject private var store = ShortcutStore.shared
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                ForEach(CommandCategory.allCases, id: \.self) { category in
                    let commands = AppCommand.allCases.filter { $0.category == category }
                    if !commands.isEmpty {
                        Section(category.title) {
                            ForEach(commands, id: \.self) { row(for: $0) }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 520, minHeight: 460)
        .onDisappear { recorder.stop() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard Shortcuts").font(.headline)
                Text(recorder.recording == nil
                     ? "Click a shortcut to record a new one. Escape cancels."
                     : "Press the new shortcut… (Escape to cancel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset All") {
                store.resetAll()
                MainMenuController.shared.refreshShortcuts()
            }
        }
        .padding(14)
        .overlay(alignment: .bottomLeading) {
            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
            }
        }
    }

    @ViewBuilder
    private func row(for command: AppCommand) -> some View {
        let conflicts = store.conflicts(for: command)
        HStack(spacing: 8) {
            Text(command.title)
            if !conflicts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Same shortcut as: " + conflicts.map(\.title).joined(separator: ", "))
            }
            Spacer()
            Button(label(for: command)) {
                recorder.message = nil
                recorder.start(command, onCapture: assign)
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 90)

            Button {
                store.setShortcut(nil, for: command)
                MainMenuController.shared.refreshShortcuts()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
            .disabled(store.overrides[command] == nil)
        }
        .padding(.vertical, 2)
    }

    private func label(for command: AppCommand) -> String {
        if recorder.recording == command { return "Press keys…" }
        guard let shortcut = store.shortcuts(for: command).first else { return "—" }
        return shortcut.displayString
    }

    /// Assigning the recorded shortcut: system combinations are off-limits,
    /// otherwise the user could lock themselves out of quitting the app or
    /// closing a window.
    private func assign(_ command: AppCommand, _ shortcut: Shortcut) {
        guard !ShortcutStore.isReserved(shortcut) else {
            recorder.message = "\(shortcut.displayString) is reserved by macOS and can't be reassigned."
            return
        }
        store.setShortcut(shortcut, for: command)
        MainMenuController.shared.refreshShortcuts()
        let conflicts = store.conflicts(for: command)
        recorder.message = conflicts.isEmpty
            ? nil
            : "\(shortcut.displayString) is also assigned to: " + conflicts.map(\.title).joined(separator: ", ")
    }
}
