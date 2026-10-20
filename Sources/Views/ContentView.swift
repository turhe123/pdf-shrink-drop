import SwiftUI
import UniformTypeIdentifiers

/// The single main window: presets on top, file list (or drop target) in the middle, actions at the bottom.
struct ContentView: View {
    @EnvironmentObject private var store: JobStore
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PresetControls().padding()
            Divider()
            Group {
                if store.items.isEmpty { emptyState } else { fileList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(6)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                store.add(urls)
                return true
            } isTargeted: { isTargeted = $0 }
            Divider()
            bottomBar.padding()
        }
        .frame(minWidth: 680, minHeight: 480)
        .toolbar {
            ToolbarItemGroup {
                Button { store.presentOpenPanel() } label: { Label("Add PDFs", systemImage: "plus") }
                Button { store.clear() } label: { Label("Clear List", systemImage: "trash") }
                    .disabled(store.items.isEmpty || store.isRunning)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop PDF files to shrink them").font(.title2.weight(.medium))
            Text("or press ⌘O to choose files").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.presentOpenPanel() }
    }

    private var fileList: some View {
        List(store.items) { item in
            FileRow(item: item)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            OutputControls()
            HStack {
                DonateButton()
                if let notice = store.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Merge…") { store.merge() }
                    .help("Join all files, in list order, into one PDF")
                    .disabled(store.isRunning || store.items.count < 2)
                if store.isRunning {
                    Button("Cancel", role: .cancel) { store.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Compress") { store.compressAll() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isRunning || store.items.isEmpty)
            }
        }
    }
}

/// One file: page-one thumbnail, sizes, status, progress and actions.
struct FileRow: View {
    @EnvironmentObject private var store: JobStore
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(sizeLine).font(.callout).monospacedDigit()
                if item.status == .working {
                    ProgressView(value: item.progress).progressViewStyle(.linear)
                } else {
                    Text(item.status.label).font(.caption).foregroundStyle(statusColor)
                }
            }
            Spacer()
            if item.status == .locked {
                Button("Unlock…") { store.unlock(item.id) }
            }
            Button { store.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
            Button { store.remove(item.id) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Remove from list")
                .disabled(store.isRunning)
        }
        .padding(.vertical, 4)
    }

    private var thumbnail: some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: item.status == .locked ? "lock.doc" : "doc").font(.title).foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 52)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var sizeLine: String {
        var line = item.originalSize.fileSizeString
        if let newSize = item.newSize, item.status == .done {
            line += " → \(newSize.fileSizeString)"
            if let saved = item.savedPercent { line += "  (−\(saved)%)" }
        }
        return line
    }

    private var statusColor: Color {
        switch item.status {
        case .done: return .green
        case .optimal: return .blue
        case .locked: return .orange
        case .unreadable, .error: return .red
        default: return .secondary
        }
    }
}
