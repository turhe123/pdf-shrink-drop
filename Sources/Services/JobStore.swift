import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the file list and runs compression / merge jobs, publishing per-file progress.
@MainActor
final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isRunning = false
    @Published var notice: String?

    private var job: Task<Void, Never>?

    // MARK: Adding files

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Adds PDFs (skipping non-PDFs and duplicates) and loads their thumbnails in the background.
    func add(_ urls: [URL]) {
        var skipped = 0
        for url in urls {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .pdf) == true else { skipped += 1; continue }
            guard !items.contains(where: { $0.url == url }) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let item = FileItem(url: url, originalSize: size)
            items.append(item)
            loadPreview(for: item.id, url: url)
        }
        notice = skipped > 0 ? "Skipped \(skipped) file(s) that are not PDFs." : nil
    }

    private func loadPreview(for id: UUID, url: URL) {
        Task.detached(priority: .utility) {
            let doc = PDFDocument(url: url)
            let locked = doc?.isLocked ?? false
            let thumb = locked ? nil : doc?.page(at: 0)?.thumbnail(of: NSSize(width: 80, height: 104), for: .cropBox)
            await MainActor.run {
                JobStore.shared.update(id) { item in
                    item.thumbnail = thumb
                    if doc == nil { item.status = .unreadable } else if locked { item.status = .locked }
                }
            }
        }
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
        notice = nil
    }

    private func update(_ id: UUID, _ change: (inout FileItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: Locked files

    /// Prompts for a password and unlocks the row if it is correct.
    func unlock(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "“\(item.url.lastPathComponent)” is password protected"
        alert.informativeText = "Enter the password to open and compress it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let password = field.stringValue
        guard let doc = PDFDocument(url: item.url), doc.unlock(withPassword: password) else {
            notice = "Incorrect password for \(item.url.lastPathComponent)."
            return
        }
        let thumb = doc.page(at: 0)?.thumbnail(of: NSSize(width: 80, height: 104), for: .cropBox)
        update(id) { $0.password = password; $0.status = .ready; $0.thumbnail = thumb }
        notice = nil
    }

    // MARK: Compression

    func compressAll() {
        guard !isRunning else { return }
        let settings = CompressionSettings.current()
        let defaults = UserDefaults.standard
        let folder = defaults.string(forKey: Keys.outputFolder) ?? ""
        let replace = defaults.bool(forKey: Keys.replaceOriginal)
        let queue = items.filter(\.isProcessable).map(\.id)
        guard !queue.isEmpty else { notice = "Nothing to compress."; return }

        isRunning = true
        notice = nil
        job = Task {
            for id in queue {
                if Task.isCancelled { break }
                await process(id, settings: settings, folder: folder, replace: replace)
            }
            isRunning = false
            job = nil
        }
    }

    func cancel() { job?.cancel() }

    private func process(_ id: UUID, settings: CompressionSettings, folder: String, replace: Bool) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let original = item.url
        let password = item.password
        let destination = Compressor.destination(for: original, folderPath: folder, replace: replace)
        update(id) { $0.status = .working; $0.progress = 0; $0.newSize = nil }

        let scratch: URL
        do { scratch = try Compressor.scratchDirectory(near: destination) } catch {
            update(id) { $0.status = .error(error.localizedDescription) }
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(destination.lastPathComponent)

        let worker = Task.detached(priority: .userInitiated) {
            try Compressor.compress(original, to: temp, password: password, settings: settings) { fraction in
                Task { @MainActor in JobStore.shared.update(id) { $0.progress = fraction } }
            }
        }
        do {
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let newSize = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let originalSize = (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? item.originalSize
            guard newSize > 0, newSize < originalSize else {
                update(id) { $0.status = .optimal; $0.progress = 1; $0.newSize = originalSize; $0.outputURL = original }
                return
            }
            try Compressor.install(temp, at: destination, replacingOriginal: replace)
            update(id) {
                $0.status = .done; $0.progress = 1; $0.originalSize = originalSize
                $0.newSize = newSize; $0.outputURL = destination
            }
        } catch is CancellationError {
            update(id) { $0.status = .cancelled; $0.progress = 0 }
        } catch {
            update(id) { $0.status = .error(error.localizedDescription); $0.progress = 0 }
        }
    }

    // MARK: Merge

    /// Joins all readable files, in list order, into one PDF chosen with a save panel.
    func merge() {
        guard !isRunning else { return }
        let inputs = items.filter { $0.status != .unreadable && ($0.status != .locked) }
            .map { (url: $0.url, password: $0.password) }
        guard inputs.count > 1 else { notice = "Add at least two readable PDFs to merge."; return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Merged.pdf"
        panel.directoryURL = inputs.first?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isRunning = true
        job = Task {
            do {
                let scratch = try Compressor.scratchDirectory(near: destination)
                defer { try? FileManager.default.removeItem(at: scratch) }
                let temp = scratch.appendingPathComponent(destination.lastPathComponent)
                let worker = Task.detached(priority: .userInitiated) { try Compressor.merge(inputs, to: temp) }
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Compressor.install(temp, at: destination, replacingOriginal: false)
                notice = "Merged \(inputs.count) files into \(destination.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                notice = "Merge cancelled."
            } catch {
                notice = "Merge failed: \(error.localizedDescription)"
            }
            isRunning = false
            job = nil
        }
    }

    func reveal(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.outputURL ?? item.url])
    }
}
