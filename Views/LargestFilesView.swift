import AppKit
import SwiftUI

/// The scan behind the Largest Files window: runs LargestFiles.scan off the main thread,
/// publishes progress, can be stopped.
@MainActor
final class LargestFilesModel: ObservableObject {
    let root: URL
    @Published private(set) var result: LargestFiles.Result?
    @Published private(set) var scannedSoFar = 0
    @Published private(set) var isScanning = false
    @Published private(set) var wasStopped = false
    private var task: Task<Void, Never>?
    private let cancelFlag = CancelFlag()

    /// Read from the background walk, set from the main actor.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    init(root: URL) { self.root = root }

    func start() {
        guard task == nil else { return }
        isScanning = true
        let root = root
        let flag = cancelFlag
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LargestFiles.scan(root, isCancelled: { flag.isSet }) { count in
                    Task { @MainActor [weak self] in self?.scannedSoFar = count }
                }
            }.value
            guard let self else { return }
            self.isScanning = false
            if let result { self.result = result } else { self.wasStopped = true }
        }
    }

    func stop() { cancelFlag.set() }
}

/// Largest Files (⌥⌘L): the biggest files and packages anywhere under the active pane's
/// folder, largest first, each with a bar relative to the first. Double-click (or Show in
/// Pane) opens the item's folder in the pane that asked and selects it — deleting happens
/// there, with the usual Trash and undo, rather than from a second place with its own rules.
struct LargestFilesView: View {
    @StateObject private var model: LargestFilesModel
    @State private var selection: URL?
    let reveal: (URL) -> Void

    init(root: URL, reveal: @escaping (URL) -> Void) {
        _model = StateObject(wrappedValue: LargestFilesModel(root: root))
        self.reveal = reveal
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { model.start() }
        // The biggest one starts selected, so Return (Show in Pane) works straight away.
        .onChange(of: model.result) { result in
            if selection == nil { selection = result?.entries.first?.url }
        }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning… \(model.scannedSoFar.formatted()) items")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Stop") { model.stop() }
            } else if let result = model.result {
                let shown = result.entries.reduce(Int64(0)) { $0 + $1.size }
                Text("The \(result.entries.count) largest take \(Self.bytes(shown)) of \(Self.bytes(result.total)) in \(result.scanned.formatted()) items")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Pane") { if let selection { reveal(selection) } }
                    .disabled(selection == nil)
                    .keyboardShortcut(.defaultAction)
            } else {
                Text(model.wasStopped ? "Stopped." : "")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.result {
            if result.entries.isEmpty {
                Text("No files here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let largest = max(result.entries[0].size, 1)
                // Double-click through primaryAction, not a tap gesture on the row: gestures
                // on List rows break its native selection (see CLAUDE.md, sidebar rows).
                List(result.entries, selection: $selection) { entry in
                    row(entry, share: Double(entry.size) / Double(largest))
                        .tag(entry.url)
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: URL.self) { urls in
                    if let url = urls.first {
                        Button("Show in Pane") { reveal(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } primaryAction: { urls in
                    if let url = urls.first { reveal(url) }
                }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ entry: LargestFiles.Entry, share: Double) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.shared.icon(forFileURL: entry.url))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(relativeFolder(entry.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 12)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(3, geometry.size.width * share))
            }
            .frame(width: 90, height: 8)
            Text(Self.bytes(entry.size))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .help(entry.url.path)
    }

    /// The containing folder relative to the scanned one ("Photos/2024"), or "—" at the top.
    /// Both sides through realpath(3): resolvingSymlinksInPath strips "/private" from
    /// /private/tmp while the enumerator keeps it, so the prefixes never matched.
    private func relativeFolder(_ url: URL) -> String {
        let rootPath = Self.realPath(model.root.path)
        let folder = Self.realPath(url.deletingLastPathComponent().path)
        guard folder.hasPrefix(rootPath) else { return folder }
        let rest = folder.dropFirst(rootPath.count).drop(while: { $0 == "/" })
        return rest.isEmpty ? "—" : String(rest)
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
