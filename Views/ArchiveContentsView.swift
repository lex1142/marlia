import SwiftUI

/// Browses an archive's contents without extracting it — a list of files/folders with
/// sizes, opened in its own window from the context menu ("View Contents"), like Get
/// Info.
struct ArchiveContentsView: View {
    let url: URL

    @State private var entries: [ArchiveService.Entry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let service = ArchiveService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(12)
            Divider()
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if entries.isEmpty {
                Text("Empty archive")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack {
                        // Fixed width: "folder" is wider than "doc", which shifted
                        // folder names to the right of file names.
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(entry.isDirectory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if !entry.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 480)
        .onAppear { load() }
    }

    /// Finder order: compared component by component, so a folder comes right before its
    /// own contents and names compare the way Finder does ("v2" before "v10"). Archive
    /// tools list entries in storage order, which is whatever order they were added in.
    /// A plain string sort isn't enough: it would put "a b/x" between "a/" and "a/x".
    static func finderOrder(_ a: ArchiveService.Entry, _ b: ArchiveService.Entry) -> Bool {
        let ca = a.path.split(separator: "/"), cb = b.path.split(separator: "/")
        for (x, y) in zip(ca, cb) where x != y {
            return String(x).localizedStandardCompare(String(y)) == .orderedAscending
        }
        return ca.count < cb.count
    }

    private func load() {
        guard let format = ArchiveFormat(url: url) else {
            errorMessage = "Unrecognized archive format"
            isLoading = false
            return
        }
        service.listContents(url: url, format: format) { result in
            isLoading = false
            switch result {
            case .success(let items): entries = items.sorted(by: Self.finderOrder)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }
}
