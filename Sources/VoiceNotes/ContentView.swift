import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var speech: SpeechRecognizer
    @EnvironmentObject var capture: CaptureModel

    @State private var tab: NoteTab = .reminders
    @State private var typed = ""
    @State private var search = ""
    @State private var showSettings = false
    @State private var editing: Note?

    var body: some View {
        VStack(spacing: 10) {
            header
            if showSettings {
                SettingsView()
            } else {
                banners
                captureArea
                Picker("Show", selection: $tab) {
                    ForEach(NoteTab.allCases, id: \.self) { tab in
                        Text("\(tab.rawValue) (\(store.notes(for: tab).count))").tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                noteList
            }
        }
        .padding(12)
        .frame(width: 380, height: 560)
        .sheet(item: $editing) { note in
            NoteEditor(note: note) { updated in
                store.update(updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .onChange(of: speech.isRecording) { _, recording in
            // Make sure the live transcript and Stop button are visible whenever the mic is on.
            if recording {
                showSettings = false
                editing = nil
            }
        }
        .onChange(of: capture.focusTab) { _, newTab in
            guard let newTab else { return }
            tab = newTab
            search = ""
            capture.focusTab = nil
        }
    }

    // MARK: Header & banners

    private var header: some View {
        HStack {
            Image(systemName: "note.text").foregroundStyle(.yellow)
            Text("Voice Notes").font(.headline)
            Spacer()
            Text("⌥⇧N")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .help("Press ⌥⇧N anywhere to start a voice note")
            Button { showSettings.toggle() } label: {
                Image(systemName: showSettings ? "xmark.circle" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help(showSettings ? "Close settings" : "Settings")
            .accessibilityLabel(showSettings ? "Close settings" : "Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit Voice Notes")
                .accessibilityLabel("Quit")
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let problem = capture.ollamaProblem {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: problem) {
                Button("Retry") { Task { await capture.refreshHealth() } }
            }
        }
        if let error = store.loadError ?? store.saveError {
            Banner(systemImage: "exclamationmark.octagon.fill", tint: .red, text: error) {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([store.folder.url]) }
            }
        }
    }

    // MARK: Capture

    private var captureArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await capture.toggleRecording() }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                        .symbolEffect(.pulse, isActive: speech.isRecording)
                }
                .buttonStyle(.plain)
                .disabled(capture.isProcessing)
                .help(speech.isRecording ? "Stop and save" : "Speak a note")
                .accessibilityLabel(speech.isRecording ? "Stop recording and save" : "Record a voice note")

                TextField("…or type a note and press Return", text: $typed, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .disabled(capture.isProcessing || speech.isRecording)
                    .onSubmit {
                        let text = typed
                        typed = ""
                        Task { await capture.save(text) }
                    }
            }
            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if speech.isRecording {
            Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if capture.isProcessing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Understanding your note…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let failure = speech.failure {
            HStack {
                Text(failure.message).font(.caption).foregroundStyle(.red)
                Spacer()
                if failure == .permissionDenied {
                    Button("Open Settings") { openPrivacySettings() }.controlSize(.small)
                }
            }
        } else if let status = capture.status {
            HStack {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(status.isError ? Color.orange : Color.secondary)
                    .lineLimit(2)
                Spacer()
                if status.canUndoDelete {
                    Button("Undo") { capture.undoDelete() }.controlSize(.small)
                }
            }
        }
    }

    private func openPrivacySettings() {
        let anchor = AVAuthorizationHelper.microphoneDenied ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: List

    private var noteList: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let items = store.notes(for: tab).filter {
            query.isEmpty || "\($0.title) \($0.body) \($0.tag)".lowercased().contains(query)
        }
        return ScrollView {
            LazyVStack(spacing: 8) {
                if items.isEmpty {
                    Text(query.isEmpty ? emptyMessage : "No matches.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 30)
                }
                ForEach(items) { note in
                    NoteCard(note: note, onEdit: { editing = note })
                }
            }
        }
    }

    private var emptyMessage: String {
        switch tab {
        case .reminders: "No reminders.\nTry: “Remind me to call Mom tomorrow at 6.”"
        case .notes: "No notes yet.\nClick the mic and say anything."
        case .done: "Nothing completed yet."
        }
    }
}

private enum AVAuthorizationHelper {
    static var microphoneDenied: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }
}

struct Banner<Action: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(LocalizedStringKey(text)) // renders `code` spans
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            action().controlSize(.small)
        }
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Note card

struct NoteCard: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var capture: CaptureModel
    let note: Note
    let onEdit: () -> Void
    @State private var hovering = false

    private var overdue: Bool {
        guard let at = note.remindAt, !note.isDone else { return false }
        return at < Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(note.title)
                    .font(.system(.body, weight: .semibold))
                    .strikethrough(note.isDone)
                Spacer()
                actionButtons.opacity(hovering ? 1 : 0)
            }
            if note.body != note.title {
                Text(note.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Text(note.tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.primary.opacity(0.08), in: Capsule())
                if let at = note.remindAt {
                    Label(CaptureModel.format(at), systemImage: overdue ? "bell.badge.fill" : "bell")
                        .font(.caption)
                        .foregroundStyle(overdue ? Color.red : Color.secondary)
                }
                Spacer()
                Text(note.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(note.isDone ? 0.08 : 0.22), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onEdit() }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Edit", action: onEdit)
            Button(note.isDone ? "Restore" : "Mark done") { store.toggleDone(note.id) }
            Button("Delete") { capture.delete(note.id) }
        }
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Speak") { Speaker.shared.say(note.body) }
            Button(note.isDone ? "Mark not done" : "Mark done") { store.toggleDone(note.id) }
            Divider()
            Button("Snooze 10 minutes") { store.snooze(note.id, minutes: 10) }
            Button("Snooze 1 hour") { store.snooze(note.id, minutes: 60) }
            Button("Tomorrow 9 AM") { store.setReminder(note.id, to: Self.tomorrowNine) }
            if note.remindAt != nil {
                Button("Remove reminder") { store.setReminder(note.id, to: nil) }
            }
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.body, forType: .string)
            }
            Button("Delete", role: .destructive) { capture.delete(note.id) }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button { Speaker.shared.say(note.body) } label: { Image(systemName: "speaker.wave.2") }
                .help("Speak")
            Button(action: onEdit) { Image(systemName: "pencil") }
                .help("Edit")
            Button { store.toggleDone(note.id) } label: {
                Image(systemName: note.isDone ? "arrow.uturn.backward" : "checkmark.circle")
            }
            .help(note.isDone ? "Restore" : "Done")
            Button { capture.delete(note.id) } label: { Image(systemName: "trash") }
                .help("Delete")
        }
        .buttonStyle(.borderless)
        .accessibilityHidden(true) // covered by accessibilityActions
    }

    private static var tomorrowNine: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }
}

// MARK: - Note editor

struct NoteEditor: View {
    let onSave: (Note) -> Void
    let onCancel: () -> Void
    @State private var draft: Note
    @State private var hasReminder: Bool
    @State private var date: Date

    init(note: Note, onSave: @escaping (Note) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: note)
        _hasReminder = State(initialValue: note.remindAt != nil)
        _date = State(initialValue: note.remindAt ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit note").font(.headline)
            TextField("Title", text: $draft.title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $draft.body)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            Picker("Tag", selection: $draft.tag) {
                ForEach(Ollama.tags, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Toggle("Remind me", isOn: $hasReminder)
            if hasReminder {
                DatePicker("When", selection: $date, in: Date()...)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var note = draft
                    note.title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    note.body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if note.title.isEmpty { note.title = String(note.body.prefix(40)) }
                    note.remindAt = hasReminder ? date : nil
                    onSave(note)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty
                          && draft.body.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: NoteStore
    @AppStorage(Prefs.notesFolder) private var notesFolder = ""
    @AppStorage(Prefs.ringOnThisMac) private var ringOnThisMac = true
    @State private var folderError: String?
    @AppStorage(Prefs.voice) private var voice = "Freya"
    @AppStorage(Prefs.speakReminders) private var speakReminders = true
    @AppStorage(Prefs.model) private var model = "gemma4"
    @AppStorage(Prefs.autoStop) private var autoStop = true
    @State private var voices: [String] = []
    @State private var launchAtLogin = SMAppService.mainApp.status != .notRegistered
    @State private var loginError: String?
    @State private var syncingLoginToggle = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Stop listening when I pause", isOn: $autoStop)
                TextField("Language model", text: $model)
            }
            Section("Reminders") {
                Toggle("Speak reminders aloud", isOn: $speakReminders)
                Picker("Voice", selection: $voice) {
                    ForEach(voices.contains(voice) ? voices : [voice] + voices, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!speakReminders)
                Button("Preview voice") { Speaker.shared.say("Hi! This is how your reminders will sound.") }
                    .disabled(!speakReminders)
            }
            Section("Sync across Macs") {
                LabeledContent("Notes folder") {
                    Text(displayPath(store.folder.url))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.folder.url.path)
                }
                HStack {
                    Button("Choose…") { chooseFolder() }
                    if !notesFolder.isEmpty {
                        Button("Use default") { useFolder(NoteFolder.defaultURL, saveAs: "") }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.open(store.folder.url) }
                }
                if let folderError {
                    Text(folderError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Ring reminders on this Mac", isOn: $ringOnThisMac)
                Text("Pick a folder in iCloud Drive, Dropbox, Google Drive or Syncthing, and choose the same folder on your other Macs. Your current notes are copied into it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("Everything stays on this Mac. Speech is transcribed by macOS and notes are understood by Ollama at localhost:11434. Version \(version).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { voices = (try? await Ollama.voices()) ?? [] }
    }

    private func displayPath(_ url: URL) -> String {
        if url == NoteFolder.defaultURL { return "On this Mac only" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder for your notes. Use one inside iCloud Drive, Dropbox or similar to sync across Macs."
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) { panel.directoryURL = iCloud }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useFolder(url, saveAs: url.path)
    }

    private func useFolder(_ url: URL, saveAs path: String) {
        do {
            try store.changeFolder(to: url)
            notesFolder = path
            folderError = nil
        } catch {
            folderError = "Couldn't use that folder: \(error.localizedDescription)"
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        // Writing the toggle back below re-triggers onChange; ignore that echo.
        if syncingLoginToggle {
            syncingLoginToggle = false
            return
        }
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
        }
        if service.status == .requiresApproval {
            loginError = "Approve Voice Notes in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
        let actual = service.status != .notRegistered
        if actual != launchAtLogin {
            syncingLoginToggle = true
            launchAtLogin = actual
        }
    }
}
