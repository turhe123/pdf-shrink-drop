import AppKit
import Foundation

/// UserDefaults keys shared by `@AppStorage` in the main window and Settings.
enum Keys {
    static let preset = "preset"
    static let customMaxDimension = "customMaxDimension"
    static let customQuality = "customQuality"
    static let outputFolder = "outputFolderPath"
    static let replaceOriginal = "replaceOriginal"
}

/// Compression presets; each maps to a maximum image dimension and JPEG quality.
enum Preset: String, CaseIterable, Identifiable {
    case small, medium, high, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .high: return "High"
        case .custom: return "Custom"
        }
    }

    var help: String {
        switch self {
        case .small: return "Smallest files, fine for screen reading."
        case .medium: return "Balanced size and quality for sharing."
        case .high: return "Keeps images sharp enough for print."
        case .custom: return "Choose your own limits. Image-heavy pages are re-rendered as JPEG."
        }
    }
}

/// The resolved parameters handed to the compressor for one batch.
struct CompressionSettings: Sendable {
    var maxDimension: Int
    var quality: Double
    /// Presets use the Quartz filter route; Custom uses the page-by-page route.
    var useQuartzFilter: Bool

    /// Reads the current choice from UserDefaults.
    static func current() -> CompressionSettings {
        let d = UserDefaults.standard
        let preset = Preset(rawValue: d.string(forKey: Keys.preset) ?? "") ?? .medium
        switch preset {
        case .small: return .init(maxDimension: 1024, quality: 0.5, useQuartzFilter: true)
        case .medium: return .init(maxDimension: 1600, quality: 0.65, useQuartzFilter: true)
        case .high: return .init(maxDimension: 2600, quality: 0.82, useQuartzFilter: true)
        case .custom:
            let dim = d.object(forKey: Keys.customMaxDimension) as? Double ?? 1600
            let q = d.object(forKey: Keys.customQuality) as? Double ?? 0.65
            return .init(maxDimension: Int(dim), quality: q, useQuartzFilter: false)
        }
    }
}

/// One row in the file list.
struct FileItem: Identifiable {
    /// Lifecycle of a single file.
    enum Status: Equatable {
        case ready, locked, working, done, optimal, cancelled
        case unreadable
        case error(String)

        var label: String {
            switch self {
            case .ready: return "Ready"
            case .locked: return "Locked — password required"
            case .working: return "Compressing…"
            case .done: return "Done"
            case .optimal: return "Already optimal — original kept"
            case .cancelled: return "Cancelled"
            case .unreadable: return "Damaged or unreadable PDF"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    let id = UUID()
    var url: URL
    var originalSize: Int64
    var newSize: Int64?
    var progress: Double = 0
    var status: Status = .ready
    var thumbnail: NSImage?
    var password: String?
    var outputURL: URL?

    var isProcessable: Bool { status != .locked && status != .unreadable && status != .working }

    var savedPercent: Int? {
        guard let newSize, originalSize > 0, status == .done else { return nil }
        return Int((Double(originalSize - newSize) / Double(originalSize) * 100).rounded())
    }
}

extension Int64 {
    var fileSizeString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
