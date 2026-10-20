import AppKit
import SwiftUI

/// Preset picker plus the two Custom sliders; shared by the main window and Settings.
struct PresetControls: View {
    @AppStorage(Keys.preset) private var preset: Preset = .medium
    @AppStorage(Keys.customMaxDimension) private var maxDimension: Double = 1600
    @AppStorage(Keys.customQuality) private var quality: Double = 0.65

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Preset", selection: $preset) {
                ForEach(Preset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(preset.help).font(.caption).foregroundStyle(.secondary)

            if preset == .custom {
                Grid(alignment: .leading, horizontalSpacing: 10) {
                    GridRow {
                        Text("Max image size")
                        Slider(value: $maxDimension, in: 512...4096, step: 128)
                        Text("\(Int(maxDimension)) px").monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                    GridRow {
                        Text("JPEG quality")
                        Slider(value: $quality, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(quality * 100)) %").monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Output folder chooser and the Replace Original toggle; shared by the main window and Settings.
struct OutputControls: View {
    @AppStorage(Keys.outputFolder) private var folderPath = ""
    @AppStorage(Keys.replaceOriginal) private var replaceOriginal = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            Text(folderPath.isEmpty ? "Next to original (-shrunk)" : (folderPath as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(replaceOriginal ? .secondary : .primary)
            Button("Choose…", action: chooseFolder).disabled(replaceOriginal)
            if !folderPath.isEmpty {
                Button { folderPath = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Save next to the original instead")
            }
            Toggle("Replace original", isOn: $replaceOriginal)
                .help("Moves the original to the Trash and puts the smaller file in its place.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }
}

/// The donation button required on every AppFactory app.
struct DonateButton: View {
    var body: some View {
        Button("Support / Donate ❤️") { Links.openDonate() }
    }
}
