// Launcher: the settings screen shown before the game starts, adapted from nxnative's dm/ios/Sources/Launcher.swift and LauncherRow.swift (MIT, see
// THIRD_PARTY_NOTICES.md). The game's icon, name and Play on the left; the settings file's choices (host/settings.h, Documents/work/settings.json) and the
// cloud-save folder on the right. Play writes the settings and hands over to main.m (zelda_launcher_play). The in-game gear key edits the same settings while playing.
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private let gameTitle = "The Legend of Zelda: Tears of the Kingdom"

/// One choice of a menu row: the value stored and its label.
private struct Choice: Identifiable { let value: Int; let label: String; var id: Int { value } }

/// The settings file's player-facing fields, edited on the screen and written once on Play.
private final class LauncherModel: ObservableObject {
    @Published var settings = zelda_settings()
    @Published var language = String(cString: zelda_language_choice())   // "" follows the system

    // Each language in its own name (the CJK ones as escapes, as the repository's English-only rule asks): Japanese, Korean, Simplified and Traditional Chinese.
    static let languages: [(String, String)] = [("", "System"), ("ja", "\u{65E5}\u{672C}\u{8A9E}"), ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("fr", "Français"),
        ("fr-CA", "Français (Canada)"), ("de", "Deutsch"), ("it", "Italiano"), ("es", "Español"), ("es-419", "Español (Latinoamérica)"), ("nl", "Nederlands"),
        ("ru", "Русский"), ("ko", "\u{D55C}\u{AD6D}\u{C5B4}"), ("zh-Hans", "\u{7B80}\u{4F53}\u{4E2D}\u{6587}"), ("zh-Hant", "\u{7E41}\u{9AD4}\u{4E2D}\u{6587}")]
    static let frameRates = [Choice(value: 30, label: "30 fps"), Choice(value: 60, label: "60 fps")]
    static let renders = [Choice(value: Int(ZELDA_RENDER_ORIGINAL), label: "Original"), Choice(value: Int(ZELDA_RENDER_1080), label: "1080p"),
                          Choice(value: Int(ZELDA_RENDER_720), label: "720p"), Choice(value: Int(ZELDA_RENDER_640), label: "640p")]

    func apply() {
        if !zelda_settings_store(settings) { fputs("SETTINGS could not be saved from the launcher\n", stderr) }
        if !zelda_settings_store_language(language) { fputs("SETTINGS could not save the language from the launcher\n", stderr) }
    }
}

/// Cloud saves: the iCloud Drive folder shared with the Mac (its control panel chooses the same folder). The startup sync brings the newest save in
/// and each save goes out after it is written (host/cloud_save.m); the folder is kept as a bookmark (main.m).
private struct CloudSavesSection: View {
    @State private var folder: String? = zelda_cloud_folder_name()
    @State private var note = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder ?? "Off").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder == nil ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
            if folder != nil {
                Button("Turn off cloud saves", role: .destructive) { zelda_cloud_clear(); folder = nil; note = "" }
            }
        } footer: {
            Text(note.isEmpty ? "Choose the Zelda-Mobile folder in iCloud Drive, the one the Mac uses. The newest save comes in when the game starts and each save goes out after it is written; a save that is replaced is kept in work/save-backups." : note)
        }
        .sheet(isPresented: $picking) {
            DocumentPicker { url in
                picking = false
                if zelda_cloud_store(url) { folder = url.lastPathComponent; note = "Saved. The game syncs with this folder when you press Play." }
                else { note = "That folder could not be remembered — try a different one." }
            } onCancel: { picking = false }
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) { self.onPick = onPick; self.onCancel = onCancel }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    if let icon = UIImage(named: "AppIcon") {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text(gameTitle).font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text("Version \((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                List {
                    Section("Game") {
                        Picker("Language", selection: $m.language) {
                            ForEach(LauncherModel.languages, id: \.0) { Text($0.1).tag($0.0) }
                        }.pickerStyle(.menu)
                        menu("Frame rate", LauncherModel.frameRates, Binding(get: { Int(m.settings.target_fps) }, set: { m.settings.target_fps = UInt32($0) }))
                        menu("Render resolution", LauncherModel.renders, Binding(get: { Int(m.settings.render) }, set: { m.settings.render = Int32($0) }))
                        Toggle("Compile new shaders in background", isOn: Binding(get: { !m.settings.shader_wait }, set: { m.settings.shader_wait = !$0 }))
                        Toggle("Sound", isOn: Binding(get: { !m.settings.muted }, set: { m.settings.muted = !$0 }))
                        Toggle("Controller rumble", isOn: Binding(get: { Int(m.settings.vibration) == Int(ZELDA_VIBRATION_ON) }, set: { m.settings.vibration = Int32($0 ? Int(ZELDA_VIBRATION_ON) : Int(ZELDA_VIBRATION_OFF)) }))
                        Toggle("Performance panel", isOn: Binding(get: { !m.settings.hide_performance }, set: { m.settings.hide_performance = !$0 }))
                    }
                    CloudSavesSection()
                    Section {
                        HStack {
                            Text("Memory available")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("The language takes effect at the next start. The gear key in the game changes the other settings while playing.")
                    }
                }
                .listStyle(.insetGrouped)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func menu(_ label: String, _ choices: [Choice], _ value: Binding<Int>) -> some View {
        Picker(label, selection: value) { ForEach(choices) { Text($0.label).tag($0.value) } }.pickerStyle(.menu)
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }
}

// Shows the launcher over the root view controller; Play writes the settings, dismisses it and calls zelda_launcher_play (main.m).
@_cdecl("zelda_show_launcher")
public func zeldaShowLauncher(_ viewController: UnsafeMutableRawPointer) {
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel()
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { zelda_launcher_play() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
}
