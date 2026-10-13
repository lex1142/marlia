import Foundation
import SwiftUI

/// A file operation shown in the HUD. Copy/move/duplicate use an exact "done of N"
/// counter (by item count); for archive extraction the total is known a little later
/// (it needs the archive's listing); for archive creation an exact total is hard to
/// get without walking the tree up front, so it's just a spinner. total == 0 means
/// indeterminate progress.
@MainActor
final class OperationProgress: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published var completed: Int
    @Published var total: Int
    @Published private(set) var isPaused = false
    @Published private(set) var isCancelled = false

    /// The actual pause/cancel lives in OperationControl.swift. The @Published fields above
    /// merely mirror its state for the HUD; blocking/stopping the work happens there.
    let control = OperationControl()

    var isIndeterminate: Bool { total <= 0 }

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    init(title: String, total: Int = 0) {
        self.title = title
        self.total = total
        self.completed = 0
    }

    func togglePause() {
        if isPaused {
            control.resume()
        } else {
            control.pause()
        }
        isPaused.toggle()
    }

    func cancel() {
        control.cancel()
        isCancelled = true
    }
}

/// One row of the HUD overlay — the operation title plus a progress bar (or a
/// spinner while the total is unknown/unavailable, e.g. when creating an
/// archive).
struct OperationProgressRow: View {
    @ObservedObject var op: OperationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(op.isPaused ? "\(op.title) (Paused)" : op.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Button {
                    op.togglePause()
                } label: {
                    Image(systemName: op.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)
                .help(op.isPaused ? "Resume" : "Pause")
                .accessibilityLabel(op.isPaused ? "Resume" : "Pause")

                Button {
                    op.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .accessibilityLabel("Cancel")
            }
            .foregroundStyle(.primary)

            if op.isIndeterminate {
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView(value: op.fractionCompleted)
                Text("\(op.completed) of \(op.total)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 2)
        .opacity(op.isCancelled ? 0.5 : 1)
    }
}
