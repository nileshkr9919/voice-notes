import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = NoteStore()
    private let speech = SpeechRecognizer()
    private lazy var capture = CaptureModel(store: store, speech: speech)
    private var notifier: Notifier!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []
    private var reminderActivity: NSObjectProtocol?
    private var briefingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        // Menu bar apps have no visible menu, but key equivalents like ⌘C/⌘V/⌘Z
        // only reach text fields through an Edit menu, so install a hidden one.
        NSApp.mainMenu = Self.makeMainMenu()

        store.ringsOnThisDevice = { UserDefaults.standard.bool(forKey: Prefs.ringOnThisMac) }
        store.context = { UserContext.current() }
        store.isInCall = { UserContext.captureDeviceInUse() }
        store.habitsPausedUntil = { Prefs.pausedUntil }
        notifier = Notifier(store: store)
        notifier.onOpen = { [weak self] in self?.showPopover() }
        store.onDue = { [weak self] due in
            due.forEach { self?.notifier.post($0) }
            guard UserDefaults.standard.bool(forKey: Prefs.speakReminders) else { return }
            // One announcement per batch, so a backlog after sleep isn't read out note by note.
            if due.count == 1 {
                Speaker.shared.say("Reminder. \(due[0].body)")
            } else {
                let titles = due.prefix(3).map(\.title).joined(separator: ", ")
                Speaker.shared.say("You have \(due.count) reminders: \(titles)\(due.count > 3 ? ", and more" : "").")
            }
        }
        // Keep the reminder timer on schedule; App Nap would otherwise throttle a windowless app.
        reminderActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Delivering reminders on time")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateIcon(recording: false)
        // Swap the icon while the microphone is live, so it's obvious when we're listening.
        speech.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] recording in
                self?.updateIcon(recording: recording)
                // Always show the live transcript and Stop button while the mic is on.
                if recording, let self, !self.popover.isShown { self.showPopover() }
            }
            .store(in: &cancellables)
        // Show how many reminders have gone off and still need attention.
        store.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: ContentView()
                .environmentObject(store)
                .environmentObject(speech)
                .environmentObject(capture)
        )
        hosting.sizingOptions = .preferredContentSize // the popover follows the content's height
        popover.contentViewController = hosting

        // ⌥⇧N: open and start listening straight away; press again to save.
        hotKey = HotKey(keyCode: kVK_ANSI_N, modifiers: optionKey | shiftKey) { [weak self] in
            Task { @MainActor in self?.quickCapture() }
        }

        // Reminders that came due while the Mac slept fire as soon as it wakes.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.store.reload()
                self?.store.systemDidWake()
                self?.store.checkDue()
            }
            .store(in: &cancellables)

        store.checkDue()
        Task { await capture.refreshHealth() }

        // Daily briefing: checked every 30 s; given once a day when the person is at the Mac.
        let briefingTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.giveBriefingIfDue() }
        }
        RunLoop.main.add(briefingTimer, forMode: .common)
        self.briefingTimer = briefingTimer
    }

    func popoverDidClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .commitEdits, object: nil)
        // A first-run permission prompt takes focus and closes the popover; keep going,
        // the popover reopens once recording starts.
        guard !speech.isRequestingPermission else { return }
        // Don't keep the microphone open behind a closed popover; save what was said.
        Task { await capture.finish() }
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Open calm, like the design: no field focused (and no focus ring) until clicked.
            popover.contentViewController?.view.window?.makeFirstResponder(nil)
            NotificationCenter.default.post(name: .popoverDidShow, object: nil)
            store.reload() // pick up notes synced from other Macs
        }
        Task { await capture.refreshHealth() }
    }

    private func quickCapture() {
        if speech.isRecording {
            Task { await capture.finish() }
            return
        }
        showPopover()
        Task { await capture.start() }
    }

    static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        return main
    }

    private func updateIcon(recording: Bool) {
        statusItem.button?.image = Self.statusImage(recording: recording)
    }

    /// The menu bar icon. A template image, so macOS tints it for light and dark menu bars.
    static func statusImage(recording: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: recording ? "record.circle.fill" : "waveform",
                             accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let size = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2,
                                   y: (rect.height - size.height) / 2,
                                   width: size.width, height: size.height))
            return true
        }
        image.accessibilityDescription = recording ? "Voice Notes – listening" : "Voice Notes"
        image.isTemplate = true
        return image
    }

    private func giveBriefingIfDue(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard Briefing.isDue(now: now, enabled: defaults.bool(forKey: Prefs.briefingEnabled),
                             minuteOfDay: defaults.integer(forKey: Prefs.briefingMinute),
                             lastDay: defaults.string(forKey: Prefs.lastBriefingDay)) else { return }
        // Wait until someone is actually at the Mac.
        let context = UserContext.current()
        guard !context.screenLocked, context.idleSeconds < NoteStore.awayAfter else { return }
        defaults.set(Briefing.dayKey(now), forKey: Prefs.lastBriefingDay)
        let text = Briefing.text(for: store.notes, now: now)
        notifier.postBriefing(text)
        Speaker.shared.say(text)
    }

    private func updateBadge() {
        let count = store.firedCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }
}
