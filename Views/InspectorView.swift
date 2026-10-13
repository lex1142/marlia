import SwiftUI

/// The info panel: shows details of what is selected in the active pane and updates
/// live.
///
/// It lives in its own split item with its own NSHostingController rather than inside
/// PanesRootView, and that matters. PanesRootView deliberately does NOT observe the
/// panes (see its comment): otherwise every arrow-key selection step would redraw the
/// whole window along with both panes. The inspector has to observe the pane — so it's
/// moved into its own SwiftUI tree, where a redraw on a selection step only touches the
/// inspector itself.
struct InspectorHostView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        // The outer view follows which side is active, the inner one follows the pane
        // itself. The split is needed so @ObservedObject points at the pane that's
        // currently active: switching sides recreates the inner view with the other
        // model.
        InspectorContent(pane: appState.activePane)
    }
}

/// What exactly to show. A separate type because debouncing is keyed on it — the
/// comparison has to be of "the whole target", not of individual fields.
private enum InspectorTarget: Equatable {
    /// Nothing selected — show the open folder itself, like Finder's inspector.
    case folder(URL)
    case item(URL)
    case multiple(items: [FileItem])
}

private struct InspectorContent: View {
    @ObservedObject var pane: PaneViewModel

    /// What is actually rendered. Lags behind `target` by the debounce
    /// interval.
    @State private var shown: InspectorTarget?

    private var target: InspectorTarget {
        let selected = pane.selectedItems
        switch selected.count {
        case 0: return .folder(pane.currentURL)
        case 1: return .item(selected[0].url)
        default: return .multiple(items: selected)
        }
    }

    var body: some View {
        ScrollView {
            switch shown {
            case .folder(let url):
                VStack(spacing: 0) {
                    caption("Nothing selected")
                    ItemDetailsView(url: url, thumbnailSize: 96, showsPath: false)
                }
            case .item(let url):
                ItemDetailsView(url: url, thumbnailSize: 96, showsPath: false)
            case .multiple(let items):
                multipleSummary(items)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: target) {
            // Debounced, like the preview column in Columns mode: a held arrow key passes
            // over dozens of items, each of which means reading metadata, plus a subtree
            // walk for a folder's size. Without a delay that would hammer the disk on
            // every navigation step.
            if shown == nil {
                shown = target        // first display — immediately, nothing to wait for
                return
            }
            guard shown != target else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            shown = target
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
    }

    /// A summary of several items. Folder sizes aren't summed — that needs a subtree
    /// walk, which can't be done on every selection change; the fact that folders aren't
    /// counted is stated outright, otherwise the number would simply look wrong.
    private func multipleSummary(_ items: [FileItem]) -> some View {
        let folders = items.filter(\.isNavigableFolder)
        let files = items.filter { !$0.isNavigableFolder }
        let totalSize = files.reduce(Int64(0)) { $0 + $1.size }

        return VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .padding(.top, 20)

            Text("\(items.count) items selected")
                .font(.title3.bold())

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if !files.isEmpty {
                    GridRow {
                        Text("Files").foregroundStyle(.secondary)
                        Text("\(files.count)")
                    }
                }
                if !folders.isEmpty {
                    GridRow {
                        Text("Folders").foregroundStyle(.secondary)
                        Text("\(folders.count)")
                    }
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                }
            }
            .font(.callout)

            if !folders.isEmpty {
                Text("Folder contents are not included in the size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A list of names: knowing what exactly is selected matters more than seeing
            // just a count.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.prefix(50)) { item in
                    Text(item.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if items.count > 50 {
                    Text("and \(items.count - 50) more…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
    }
}
