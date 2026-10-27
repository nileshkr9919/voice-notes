import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// The popover. One screen at a time: the note list, the editor, or settings.
/// Follows the Penpot spec ("08 Spec / macOS tokens"): native popover material, system
/// colors and controls, 16pt margins, 13pt body / 11pt detail text.
struct ContentView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var speech: SpeechRecognizer
    @EnvironmentObject var capture: CaptureModel

    @State private var tab: NoteTab = .reminders
    @State private var typed = ""
    @State private var search = ""
    @State private var showSettings = false
    @State private var editing: Note?
    /// Preview-only: show the recording state with this transcript.
    private let previewTranscript: String?

    init(editing: Note? = nil, settings: Bool = false, recordingTranscript: String? = nil) {
        _editing = State(initialValue: editing)
        _showSettings = State(initialValue: settings)
        previewTranscript = recordingTranscript
    }

    private var isRecording: Bool { speech.isRecording || previewTranscript != nil }
    private var transcript: String { previewTranscript ?? speech.transcript }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let note = editing {
                NoteEditor(note: note) { updated in
                    store.update(updated, from: note)
                    editing = nil
                } onCancel: {
                    editing = nil
                }
            } else if showSettings {
                SettingsView()
            } else {
                main
            }
        }
        .frame(width: VoiceStyle.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(VoiceStyle.surface.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: editing?.id)
        .animation(.easeInOut(duration: 0.2), value: showSettings)
        .onChange(of: speech.isRecording) { _, recording in
            // Make sure the live transcript and Stop button are visible whenever the mic is on.
            if recording {
                showSettings = false
                closeEditorKeepingChanges()
            }
        }
        .onChange(of: capture.focusTab) { _, newTab in
            guard let newTab else { return }
            tab = newTab
            search = ""
            capture.focusTab = nil
        }
    }

    /// Leaving the editor any way but Cancel keeps the person's edits (HIG: only Cancel discards).
    private func closeEditorKeepingChanges() {
        guard editing != nil else { return }
        NotificationCenter.default.post(name: .commitEdits, object: nil)
        editing = nil
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if editing != nil || showSettings {
                Button {
                    closeEditorKeepingChanges()
                    showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                .accessibilityLabel("Back")
            }
            Text(editing != nil ? "Edit Note" : showSettings ? "Settings" : "Voice Notes")
                .font(.headline)
                .foregroundStyle(VoiceStyle.primaryText)
            Spacer()
            if editing == nil && !showSettings {
                Text("⌥⇧N")
                    .font(.subheadline)
                    .foregroundStyle(VoiceStyle.secondaryText)
                    .help("Press ⌥⇧N anywhere to start a voice note")
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                    .accessibilityLabel("Settings")
            }
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Voice Notes")
                .accessibilityLabel("Quit")
        }
        .buttonStyle(.borderless)
        .font(.body)
        .foregroundStyle(VoiceStyle.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: Main screen

    private var main: some View {
        VStack(alignment: .leading, spacing: 8) {
            banners
            if isRecording { recordingBar } else { captureBar }
            statusLine
            if let answer = capture.answer { answerCard(answer) }
            FlatSegmented(options: NoteTab.allCases, selection: $tab, title: tabTitle)
                .padding(.top, 7)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(VoiceStyle.secondaryText)
                TextField("Search", text: $search)
                    .font(.subheadline)
                    .textFieldStyle(.plain)
            }
            .flatField(height: 22)
            noteList
                .padding(.horizontal, -16) // rows use the full width; they inset themselves
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tabTitle(_ tab: NoteTab) -> String {
        let count = store.notes(for: tab).count
        return count > 0 ? "\(tab.rawValue) \(count)" : tab.rawValue
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

    private var captureBar: some View {
        HStack(spacing: 8) {
            TextField("Type a note, or ask about your notes", text: $typed, axis: .vertical)
                .lineLimit(1...4)
                .padding(.vertical, 4)
                .flatField()
                .disabled(capture.isProcessing)
                .onSubmit {
                    let text = typed
                    typed = ""
                    Task { await capture.save(text) }
                }
            Button {
                Task { await capture.toggleRecording() }
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(VoiceStyle.primaryText)
                    .frame(width: 32, height: 24)
                    .background(VoiceStyle.field, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(capture.isProcessing)
            .help("Speak a note (⌥⇧N)")
            .accessibilityLabel("Record a voice note")
        }
    }

    private var recordingBar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Listening…", systemImage: "waveform")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(transcript.isEmpty ? "Say your note…" : transcript)
                    .font(.body)
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await capture.finish() }
            } label: {
                Image(systemName: "stop.fill").foregroundStyle(.red).frame(width: 16, height: 16)
            }
            .help("Stop and save")
            .accessibilityLabel("Stop recording and save")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        if capture.isProcessing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Understanding your note…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else if let failure = speech.failure {
            HStack {
                Text(failure.message).foregroundStyle(.red)
                Spacer()
                if failure == .permissionDenied {
                    Button("Open Settings") { openPrivacySettings() }.controlSize(.small)
                }
            }
            .font(.subheadline)
        } else if let status = capture.status {
            HStack {
                Text(status.text)
                    .foregroundStyle(status.isError ? Color.orange : Color.secondary)
                    .lineLimit(2)
                Spacer()
                if status.canUndoDelete {
                    Button("Undo") { capture.undoDelete() }.controlSize(.small)
                }
            }
            .font(.subheadline)
        }
    }

    /// The answer to a question about the notes, e.g. "what's the wifi password at mom's?".
    private func answerCard(_ answer: CaptureModel.Answer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass")
                Text(answer.question).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button { capture.answer = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss answer")
            }
            .font(.subheadline)
            .foregroundStyle(VoiceStyle.secondaryText)
            Text(answer.text)
                .font(.body)
                .foregroundStyle(VoiceStyle.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiceStyle.field, in: RoundedRectangle(cornerRadius: 6))
        .transition(.opacity)
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
            query.isEmpty || "\($0.title) \($0.plainText) \($0.tag)".lowercased().contains(query)
        }
        return FitScrollView {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: query.isEmpty ? emptySymbol : "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    Text(query.isEmpty ? emptyTitle : "No matching notes.")
                        .font(.body.weight(.semibold))
                    if query.isEmpty {
                        Text(emptyHint)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { note in
                        NoteRow(note: note, onEdit: { editing = note })
                        if note.id != items.last?.id {
                            VoiceStyle.separator.frame(height: 1).padding(.leading, 40).padding(.trailing, 16)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptySymbol: String {
        switch tab {
        case .reminders: "bell"
        case .notes: "note.text"
        case .done: "checkmark.circle"
        }
    }

    private var emptyTitle: String {
        switch tab {
        case .reminders: "No reminders."
        case .notes: "No notes yet."
        case .done: "Nothing completed yet."
        }
    }

    private var emptyHint: String {
        switch tab {
        case .reminders: "Try “Remind me to call Mom tomorrow at 6.”"
        case .notes: "Type above or click the mic."
        case .done: "Completed notes appear here."
        }
    }
}

extension Notification.Name {
    /// Asks an open editor to save its changes (popover closing, Back, recording starting).
    static let commitEdits = Notification.Name("VoiceNotesCommitEdits")
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
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            action().controlSize(.small)
        }
        .padding(8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Note row

struct NoteRow: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var capture: CaptureModel
    let note: Note
    let onEdit: () -> Void
    @State private var hovering = false

    private var overdue: Bool {
        guard let at = note.remindAt, !note.isDone, !note.isRepeating else { return false }
        return at < Date()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { store.toggleDone(note.id) } label: {
                Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(note.isDone ? Color.accentColor : VoiceStyle.secondaryText)
            }
            .buttonStyle(.plain)
            .help(note.isRepeating ? "Done for now" : note.isDone ? "Mark not done" : "Mark done")
            .accessibilityHidden(true) // covered by accessibilityActions

            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.body.weight(.semibold))
                    .strikethrough(note.isDone)
                    .foregroundStyle(note.isDone ? VoiceStyle.secondaryText : VoiceStyle.primaryText)
                    .lineLimit(2)
                if note.isChecklist {
                    checklist.padding(.vertical, 2)
                } else if note.body != note.title {
                    Text(note.body)
                        .font(.subheadline)
                        .foregroundStyle(VoiceStyle.secondaryText)
                        .lineLimit(2)
                }
                metadata.padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Circle at x 16, text at x 40 (Penpot), with the hover highlight inset 6pt.
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? VoiceStyle.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            // Hover actions float over the row so nothing reflows.
            if hovering { actionButtons.padding(6) }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onEdit() }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Edit", action: onEdit)
            Button("Speak") { Speaker.shared.say(note.plainText) }
            Button(note.isDone ? "Restore" : "Mark done") { store.toggleDone(note.id) }
            Button("Delete") { capture.delete(note.id) }
        }
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Speak") { Speaker.shared.say(note.plainText) }
            Button(note.isRepeating ? "Done for Now" : note.isDone ? "Mark Not Done" : "Mark Done") {
                store.toggleDone(note.id)
            }
            Divider()
            Button("Snooze 10 Minutes") { store.snooze(note.id, minutes: 10) }
            Button("Snooze 1 Hour") { store.snooze(note.id, minutes: 60) }
            Button("Tomorrow 9 AM") { store.setReminder(note.id, to: Self.tomorrowNine) }
            if note.remindAt != nil && !note.isRepeating {
                Button("Remove Reminder") { store.setReminder(note.id, to: nil) }
            }
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.plainText, forType: .string)
            }
            Button("Delete", role: .destructive) { capture.delete(note.id) }
        }
    }

    @ViewBuilder
    private var metadata: some View {
        HStack(spacing: 4) {
            if let rule = note.repeatRule {
                Image(systemName: "repeat")
                let count = rule.doneToday
                Text(rule.summary.prefix(1).uppercased() + rule.summary.dropFirst()
                     + (count > 0 ? " · \(count) today" : "") + " · " + note.tag.capitalized)
            } else if let at = note.remindAt {
                Image(systemName: overdue ? "bell.badge.fill" : "bell")
                Text(Self.rowDate(at, overdue: overdue))
                Text("· " + note.tag.capitalized).foregroundStyle(VoiceStyle.secondaryText)
            } else if note.isChecklist {
                Text("\(note.doneItemCount) of \(note.items.count) done · \(note.tag.capitalized)")
            } else {
                Text(note.tag.capitalized)
            }
        }
        .font(.subheadline)
        .foregroundStyle(overdue ? VoiceStyle.overdue : VoiceStyle.secondaryText)
        .lineLimit(1)
    }

    private static let visibleItems = 4

    /// Up to four items, tickable right in the list, then "+N more".
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(note.items.prefix(Self.visibleItems)) { item in
                Button { store.toggleItem(item.id, in: note.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(item.done ? Color.accentColor : VoiceStyle.secondaryText)
                        Text(item.text)
                            .font(.callout)
                            .strikethrough(item.done)
                            .foregroundStyle(item.done ? VoiceStyle.secondaryText : VoiceStyle.primaryText)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.text)
                .accessibilityAddTraits(item.done ? .isSelected : [])
            }
            if note.items.count > Self.visibleItems {
                Text("+\(note.items.count - Self.visibleItems) more")
                    .font(.subheadline)
                    .foregroundStyle(VoiceStyle.secondaryText)
                    .padding(.leading, 18)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button { Speaker.shared.say(note.plainText) } label: { Image(systemName: "speaker.wave.2") }
                .help("Speak")
            Button(action: onEdit) { Image(systemName: "pencil") }
                .help("Edit")
            Button { capture.delete(note.id) } label: { Image(systemName: "trash") }
                .help("Delete")
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(VoiceStyle.field, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true) // covered by accessibilityActions
    }

    /// "10 min ago", "Today, 3:00 PM", "Tomorrow, 9:00 AM", "Fri, 4:00 PM", "28 Nov, 9:00 AM".
    static func rowDate(_ date: Date, overdue: Bool, now: Date = Date()) -> String {
        if overdue {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: now)
        }
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today, \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow, \(time)" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: date).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))), \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }

    private static var tomorrowNine: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }
}

// MARK: - Note editor

/// Matches Penpot "04 Editor": title and notes as plain text, then a label/control form
/// with native popups and checkboxes, and Cancel / Save at the bottom.
struct NoteEditor: View {
    enum RepeatMode: String, CaseIterable {
        case off = "Off"
        case every = "Every N minutes"
        case range = "Random range"
    }

    let onSave: (Note) -> Void
    let onCancel: () -> Void
    @State private var draft: Note
    @State private var hasReminder: Bool
    @State private var date: Date
    @State private var mode: RepeatMode
    @State private var every: Int
    @State private var minMinutes: Int
    @State private var maxMinutes: Int
    @State private var limitHours: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var days: Set<Int>
    @State private var activeTimeOnly: Bool

    /// Monday-first, as macOS shows weeks; values are Calendar weekdays (1 = Sunday).
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let labelWidth: CGFloat = 96

    init(note: Note, onSave: @escaping (Note) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        let rule = note.repeatRule
        _draft = State(initialValue: note)
        _hasReminder = State(initialValue: note.remindAt != nil)
        _date = State(initialValue: note.remindAt ?? Date().addingTimeInterval(3600))
        _mode = State(initialValue: rule == nil ? .off : rule!.minMinutes == rule!.maxMinutes ? .every : .range)
        _every = State(initialValue: rule?.minMinutes ?? 30)
        _minMinutes = State(initialValue: rule?.minMinutes ?? 10)
        _maxMinutes = State(initialValue: rule?.maxMinutes ?? 20)
        _limitHours = State(initialValue: rule?.startMinute != nil)
        _startTime = State(initialValue: Self.time(rule?.startMinute ?? 9 * 60))
        _endTime = State(initialValue: Self.time(rule?.endMinute ?? 18 * 60))
        _days = State(initialValue: Set((rule?.weekdays ?? Array(1...7)).filter { (1...7).contains($0) }))
        _activeTimeOnly = State(initialValue: rule?.activeTimeOnly ?? false)
    }

    private var isEmpty: Bool {
        draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.body.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var repeatError: String? {
        guard hasReminder else { return nil }
        switch mode {
        case .off: return nil
        case .every: return every < 1 ? "Enter at least 1 minute." : nil
        case .range:
            if minMinutes < 1 { return "Enter at least 1 minute." }
            return minMinutes > maxMinutes ? "The first number can't be larger than the second." : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FitScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: $draft.title)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.semibold))
                    if !draft.isChecklist {
                        TextField("Notes", text: $draft.body, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(2...8)
                    }
                    ChecklistEditor(items: $draft.items)
                    Divider().padding(.vertical, 4)
                    form
                }
                .font(.body)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmpty || repeatError != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onReceive(NotificationCenter.default.publisher(for: .commitEdits)) { _ in
            // HIG: a popover that closes on its own keeps the person's work; only Cancel discards it.
            if !isEmpty && repeatError == nil { save() }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Tag") {
                Picker("Tag", selection: $draft.tag) {
                    ForEach(Ollama.tags, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
            }
            Toggle("Remind me", isOn: $hasReminder)
            if hasReminder {
                if mode == .off {
                    row("When") {
                        DatePicker("When", selection: $date, in: Date()...).labelsHidden()
                    }
                }
                row("Repeat") {
                    Picker("Repeat", selection: $mode) {
                        ForEach(RepeatMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                if mode == .every {
                    row("Every") {
                        HStack(spacing: 6) {
                            MinutesField(value: $every)
                            Text("minutes").foregroundStyle(.secondary).fixedSize()
                        }
                    }
                } else if mode == .range {
                    row("Interval") {
                        HStack(spacing: 6) {
                            MinutesField(value: $minMinutes)
                            Text("–").foregroundStyle(.secondary)
                            MinutesField(value: $maxMinutes)
                            Text("min").foregroundStyle(.secondary).fixedSize()
                        }
                    }
                }
                if let repeatError {
                    Text(repeatError).font(.subheadline).foregroundStyle(.red)
                        .padding(.leading, Self.labelWidth)
                }
                if mode != .off {
                    Divider().padding(.vertical, 4)
                    repeatOptions
                }
            }
        }
    }

    @ViewBuilder
    private var repeatOptions: some View {
        row("Active hours") {
            HStack(spacing: 6) {
                Toggle("Limit to active hours", isOn: $limitHours).labelsHidden()
                Group {
                    DatePicker("From", selection: $startTime, displayedComponents: .hourAndMinute).labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("To", selection: $endTime, displayedComponents: .hourAndMinute).labelsHidden()
                }
                .disabled(!limitHours)
            }
        }
        row("Weekdays") {
            HStack(spacing: 8) {
                ForEach(Self.weekdayOrder, id: \.self) { day in
                    VStack(spacing: 3) {
                        Text(Calendar.current.shortWeekdaySymbols[day - 1].prefix(2))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Toggle(isOn: Binding(
                            get: { days.contains(day) },
                            set: { if $0 { days.insert(day) } else if days.count > 1 { days.remove(day) } }
                        )) { EmptyView() }
                        .labelsHidden()
                        .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Only count time at my Mac", isOn: $activeTimeOnly)
            Text("Pauses while away or when this Mac sleeps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: Self.labelWidth, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    private func save() {
        var note = draft
        note.title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.title.isEmpty { note.title = String(note.body.prefix(40)) }
        if note.body.isEmpty { note.body = note.title }
        note.items = note.items.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        if hasReminder && mode != .off {
            var rule = RepeatRule(
                minMinutes: mode == .every ? every : minMinutes,
                maxMinutes: mode == .every ? every : maxMinutes,
                activeTimeOnly: activeTimeOnly,
                startMinute: limitHours ? Self.minuteOfDay(startTime) : nil,
                endMinute: limitHours ? Self.minuteOfDay(endTime) : nil,
                weekdays: days.count == 7 ? nil : days.sorted())
            rule.doneCount = draft.repeatRule?.doneCount ?? 0
            rule.doneDate = draft.repeatRule?.doneDate
            note.repeatRule = rule
            // An unchanged rule keeps its schedule; a new one is scheduled by the store.
            note.remindAt = draft.remindAt ?? rule.nextOccurrence(after: Date())
        } else {
            note.repeatRule = nil
            note.remindAt = hasReminder ? date : nil
        }
        onSave(note)
    }

    private static func time(_ minuteOfDay: Int) -> Date {
        Calendar.current.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: Date())!
    }

    private static func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return parts.hour! * 60 + parts.minute!
    }
}

/// Edits a note's checklist: tick, rename, delete (on hover) and add items.
private struct ChecklistEditor: View {
    @Binding var items: [ChecklistItem]
    @FocusState private var focused: UUID?
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($items) { $item in
                HStack(spacing: 8) {
                    Button { item.done.toggle() } label: {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(item.done ? Color.accentColor : VoiceStyle.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.done ? "Mark not done" : "Mark done")
                    TextField("Item", text: $item.text)
                        .textFieldStyle(.plain)
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? VoiceStyle.secondaryText : VoiceStyle.primaryText)
                        .focused($focused, equals: item.id)
                        .onSubmit { addItem(after: item.id) }
                    Button { items.removeAll { $0.id == item.id } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(VoiceStyle.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .opacity(hovered == item.id ? 1 : 0)
                    .allowsHitTesting(hovered == item.id)
                    .accessibilityLabel("Delete item")
                }
                .frame(minHeight: 22)
                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
            }
            Button { addItem(after: nil) } label: {
                Label(items.isEmpty ? "Add checklist item" : "Add item", systemImage: "plus")
                    .foregroundStyle(VoiceStyle.secondaryText)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 22)
        }
    }

    /// Return in an item adds a new one below it, like Apple Reminders.
    private func addItem(after id: UUID?) {
        items.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.id != id }
        let new = ChecklistItem(text: "")
        if let id, let i = items.firstIndex(where: { $0.id == id }) {
            items.insert(new, at: i + 1)
        } else {
            items.append(new)
        }
        // Focus once the new row exists.
        DispatchQueue.main.async { focused = new.id }
    }
}

/// A small number field with a stepper, for minute counts.
private struct MinutesField: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
            Stepper("", value: $value, in: 1...1440).labelsHidden()
        }
    }
}

// MARK: - Settings

/// Matches Penpot "05 Settings": uppercase section labels, native checkboxes and
/// controls, hairline dividers between sections.
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
        FitScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Capture") {
                    Toggle("Stop listening when I pause", isOn: $autoStop)
                    HStack(spacing: 12) {
                        Text("Language model")
                        TextField("gemma4", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }
                Divider()
                section("Reminders") {
                    Toggle("Speak reminders aloud", isOn: $speakReminders)
                    HStack(spacing: 8) {
                        Text("Voice")
                        Spacer()
                        Picker("Voice", selection: $voice) {
                            ForEach(voices.contains(voice) ? voices : [voice] + voices, id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Button { Speaker.shared.say("Hi! This is how your reminders will sound.") } label: {
                            Image(systemName: "play.fill")
                        }
                        .help("Preview voice")
                        .accessibilityLabel("Preview voice")
                    }
                    .disabled(!speakReminders)
                    Toggle("Ring reminders on this Mac", isOn: $ringOnThisMac)
                }
                Divider()
                section("Sync Across Macs") {
                    HStack {
                        Text("Notes folder")
                        Spacer()
                        Text(displayPath(store.folder.url))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(store.folder.url.path)
                    }
                    HStack {
                        Button("Choose…") { chooseFolder() }
                        Button("Show in Finder") { NSWorkspace.shared.open(store.folder.url) }
                        if !notesFolder.isEmpty {
                            Button("Use Default") { useFolder(NoteFolder.defaultURL, saveAs: "") }
                        }
                    }
                    if let folderError {
                        Text(folderError).font(.subheadline).foregroundStyle(.red)
                    }
                    caption("Choose a folder in iCloud Drive, Dropbox or similar, then the same folder on your other Macs. Your notes are copied there.")
                }
                Divider()
                section("General") {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                    if let loginError {
                        Text(loginError).font(.subheadline).foregroundStyle(.red)
                    }
                    caption("Everything stays on this Mac: speech is transcribed by macOS and notes are understood by Ollama on localhost. Version \(version).")
                }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .task { voices = (try? await Ollama.voices()) ?? [] }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

/// A scroll view that is exactly as tall as its content, up to a cap (which depends on
/// the screen), so the popover hugs short content and only scrolls when it must.
struct FitScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    private var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(VoiceStyle.scrollMaxHeight, screen - 200)
    }

    var body: some View {
        ScrollView {
            content()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
