import AppKit
import SwiftUI

/// Synchronize Folders (⌥⇧F2): the two panes' folders compared recursively, every
/// difference with its planned action, nothing touched until Synchronize. Logic and the
/// data-safety rules are in Models/FolderSync.swift.
@MainActor
final class FolderSyncModel: ObservableObject {
    let left: URL
    let right: URL
    /// Called after a sync, so the panes showing these folders reload.
    let onFinish: () -> Void

    @Published var direction: FolderSync.Direction = .both { didSet { resetActions() } }
    @Published var deleteExtras = false { didSet { resetActions() } }
    @Published var showIdentical = false
    @Published var items: [FolderSync.Item] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var failures: [FolderSync.Failure] = []
    @Published private(set) var lastRunSummary: String?
    private var scanControl = OperationControl()
    private var runControl = OperationControl()

    init(left: URL, right: URL, onFinish: @escaping () -> Void) {
        self.left = left
        self.right = right
        self.onFinish = onFinish
    }

    var visibleItems: [FolderSync.Item] {
        showIdentical ? items : items.filter { $0.status != .same }
    }

    var pending: [FolderSync.Item] { items.filter { $0.action != .skip } }

    func count(_ action: FolderSync.Action) -> Int { items.filter { $0.action == action }.count }

    func scan() {
        scanControl.cancel()
        let control = OperationControl()
        scanControl = control
        isScanning = true
        let (left, right, direction, deleteExtras) = (left, right, direction, deleteExtras)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FolderSync.scan(left: left, right: right, direction: direction, deleteExtras: deleteExtras,
                                isCancelled: { control.isCancelled })
            }.value
            guard let self, !control.isCancelled else { return }
            self.isScanning = false
            self.items = result ?? []
        }
    }

    func stopScan() {
        scanControl.cancel()
        isScanning = false
    }

    /// Direction and "delete extras" decide every default; changing them redoes the plan
    /// (overriding choices made by hand — the alternative, keeping some, would leave a
    /// plan nobody chose as a whole).
    private func resetActions() {
        for index in items.indices {
            items[index].action = FolderSync.defaultAction(items[index].status, direction: direction, deleteExtras: deleteExtras)
        }
    }

    func setAction(_ action: FolderSync.Action, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].action = action
    }

    func run() {
        let work = pending
        guard !work.isEmpty, !isRunning else { return }
        let control = OperationControl()
        runControl = control
        isRunning = true
        done = 0
        failures = []
        lastRunSummary = nil
        let (left, right) = (left, right)
        // Through the app-wide disk queue, like every other file operation.
        DiskOperationQueue.shared.addOperation {
            let failures = FolderSync.execute(work, left: left, right: right,
                                              isCancelled: { control.isCancelled },
                                              waitIfPaused: { control.waitWhilePaused() },
                                              progress: { count in
                                                  Task { @MainActor [weak self] in self?.done = count }
                                              })
            let stopped = control.isCancelled
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.failures = failures
                let succeeded = self.done - failures.count
                self.lastRunSummary = stopped
                    ? "Stopped after \(self.done) of \(work.count)."
                    : failures.isEmpty ? "Done: \(succeeded) item\(succeeded == 1 ? "" : "s")." : "\(failures.count) of \(work.count) failed."
                self.onFinish()
                self.scan()
            }
        }
    }

    func stopRun() { runControl.cancel() }
}

struct FolderSyncView: View {
    @StateObject private var model: FolderSyncModel
    @State private var confirming = false

    init(left: URL, right: URL, onFinish: @escaping () -> Void) {
        _model = StateObject(wrappedValue: FolderSyncModel(left: left, right: right, onFinish: onFinish))
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(12)
            Divider()
            list
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { model.scan() }
        .onDisappear { model.stopScan() }
        .alert("Synchronize these folders?", isPresented: $confirming) {
            Button("Synchronize") { model.run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                folderLabel(model.left)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                folderLabel(model.right)
            }
            HStack(spacing: 14) {
                Picker("Direction", selection: $model.direction) {
                    Text("Both Ways").tag(FolderSync.Direction.both)
                    Text("Left → Right").tag(FolderSync.Direction.leftToRight)
                    Text("Right → Left").tag(FolderSync.Direction.rightToLeft)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Delete extras on the target", isOn: $model.deleteExtras)
                    .disabled(model.direction == .both)
                    .help("One-way only: items that exist only on the target side go to the Trash")
                Toggle("Show identical", isOn: $model.showIdentical)
                Spacer()
                Button {
                    model.scan()
                } label: {
                    Label("Compare Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRunning)
            }
        }
    }

    private func folderLabel(_ url: URL) -> some View {
        HStack(spacing: 5) {
            Image(nsImage: IconCache.shared.icon(forFileURL: url)).resizable().frame(width: 16, height: 16)
            Text(url.path).lineLimit(1).truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(url.path)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if model.isScanning && model.items.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("Comparing…").foregroundStyle(.secondary)
                Button("Stop") { model.stopScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleItems.isEmpty {
            Text(model.items.isEmpty ? "Nothing to compare." : "The folders are in sync.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.visibleItems) {
                TableColumn("Item") { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isFolder ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.displayPath).lineLimit(1).truncationMode(.middle)
                            Text(statusText(item.status)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(item.displayPath)
                }
                .width(min: 220, ideal: 320)
                TableColumn("Left") { item in sideText(item.left) }
                    .width(min: 110, ideal: 150)
                TableColumn("") { item in actionMenu(item) }
                    .width(56)
                TableColumn("Right") { item in sideText(item.right) }
                    .width(min: 110, ideal: 150)
            }
        }
    }

    private func sideText(_ side: FolderSync.Side?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let side {
                Text(side.isFolder ? "Folder" : ByteCountFormatter.string(fromByteCount: side.size, countStyle: .file))
                    .monospacedDigit()
                Text(side.modified.formatted(date: .numeric, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    private func actionMenu(_ item: FolderSync.Item) -> some View {
        Menu {
            ForEach(FolderSync.possibleActions(for: item)) { action in
                Button {
                    model.setAction(action, for: item.id)
                } label: {
                    Label(actionTitle(action), systemImage: actionSymbol(action))
                }
            }
        } label: {
            // Both deletes are a trash can; the letter says which side.
            HStack(spacing: 1) {
                Image(systemName: actionSymbol(item.action))
                if item.action == .deleteLeft { Text("L").font(.caption2.bold()) }
                if item.action == .deleteRight { Text("R").font(.caption2.bold()) }
            }
            .foregroundStyle(actionColor(item.action))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A borderless menu paints its label with the tint, not foregroundStyle.
        .tint(actionColor(item.action))
        .fixedSize()
        .help(actionTitle(item.action))
        .disabled(model.isRunning)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            summaryBadge("arrow.right", model.count(.toRight), .accentColor)
            summaryBadge("arrow.left", model.count(.toLeft), .accentColor)
            summaryBadge("trash", model.count(.deleteLeft) + model.count(.deleteRight), .red)
            if model.isRunning {
                ProgressView(value: Double(model.done), total: Double(max(model.pending.count, 1)))
                    .frame(maxWidth: 220)
                Button("Stop") { model.stopRun() }
            } else if let summary = model.lastRunSummary {
                Text(summary).foregroundStyle(model.failures.isEmpty ? Color.secondary : Color.red)
                    .help(model.failures.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
            }
            Spacer()
            Button("Synchronize") { confirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(model.pending.isEmpty || model.isRunning || model.isScanning)
        }
    }

    private func summaryBadge(_ symbol: String, _ count: Int, _ color: Color) -> some View {
        Label("\(count)", systemImage: symbol)
            .foregroundStyle(count == 0 ? Color.secondary : color)
            .monospacedDigit()
    }

    private var confirmationText: String {
        var parts: [String] = []
        let toRight = model.count(.toRight), toLeft = model.count(.toLeft)
        let deletes = model.count(.deleteLeft) + model.count(.deleteRight)
        if toRight > 0 { parts.append("copy \(toRight) item\(toRight == 1 ? "" : "s") to the right") }
        if toLeft > 0 { parts.append("copy \(toLeft) item\(toLeft == 1 ? "" : "s") to the left") }
        if deletes > 0 { parts.append("move \(deletes) item\(deletes == 1 ? "" : "s") to the Trash") }
        let plan = parts.joined(separator: ", ")
        return plan.prefix(1).uppercased() + plan.dropFirst()
            + ". Files that get replaced go to the Trash, so nothing is lost."
    }

    // MARK: Labels

    private func statusText(_ status: FolderSync.Status) -> String {
        switch status {
        case .onlyLeft: return "only on the left"
        case .onlyRight: return "only on the right"
        case .leftNewer: return "newer on the left"
        case .rightNewer: return "newer on the right"
        case .conflict: return "same date, different size"
        case .kindMismatch: return "a file on one side, a folder on the other"
        case .same: return "identical"
        }
    }

    private func actionTitle(_ action: FolderSync.Action) -> String {
        switch action {
        case .toRight: return "Copy to the Right"
        case .toLeft: return "Copy to the Left"
        case .skip: return "Skip"
        case .deleteLeft: return "Move Left Item to Trash"
        case .deleteRight: return "Move Right Item to Trash"
        }
    }

    private func actionSymbol(_ action: FolderSync.Action) -> String {
        switch action {
        case .toRight: return "arrow.right"
        case .toLeft: return "arrow.left"
        case .skip: return "minus"
        case .deleteLeft, .deleteRight: return "trash"
        }
    }

    private func actionColor(_ action: FolderSync.Action) -> Color {
        switch action {
        case .toRight, .toLeft: return .accentColor
        case .skip: return .secondary
        case .deleteLeft, .deleteRight: return .red
        }
    }
}
