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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()

        store.ringsOnThisDevice = { UserDefaults.standard.bool(forKey: Prefs.ringOnThisMac) }
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
            .sink { [weak self] in self?.updateIcon(recording: $0) }
            .store(in: &cancellables)
        // Show how many reminders have gone off and still need attention.
        store.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(store)
                .environmentObject(speech)
                .environmentObject(capture)
        )

        // ⌥⇧N: open and start listening straight away; press again to save.
        hotKey = HotKey(keyCode: kVK_ANSI_N, modifiers: optionKey | shiftKey) { [weak self] in
            Task { @MainActor in self?.quickCapture() }
        }

        // Reminders that came due while the Mac slept fire as soon as it wakes.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.store.reload()
                self?.store.checkDue()
            }
            .store(in: &cancellables)

        store.checkDue()
        Task { await capture.refreshHealth() }
    }

    func popoverDidClose(_ notification: Notification) {
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

    private func updateIcon(recording: Bool) {
        // Mirrors the app icon (a note with a microphone); template images adapt to light/dark menu bars.
        let symbol = recording ? "record.circle.fill" : "mic.square.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: recording ? "Voice Notes – listening" : "Voice Notes")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func updateBadge() {
        let count = store.firedCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }
}
