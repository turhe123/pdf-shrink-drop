import SwiftUI

/// Minimal Settings window that reuses the main window's controls (same `@AppStorage` keys).
struct SettingsView: View {
    var body: some View {
        Form {
            Section("Default preset") { PresetControls() }
            Section("Output") { OutputControls() }
            Section {
                HStack {
                    Text("PdfShrinkDrop is free and open source.")
                    Spacer()
                    DonateButton()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
