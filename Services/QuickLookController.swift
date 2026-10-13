import AppKit
import Quartz

/// The system Quick Look panel (Space, as in Finder). One coordinator for the
/// whole app — the list of preview items is simply overwritten on every
/// toggle(urls:) call, so the panel always shows the selection of the pane/window
/// where Space was pressed last.
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    private var urls: [URL] = []

    func toggle(urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}
