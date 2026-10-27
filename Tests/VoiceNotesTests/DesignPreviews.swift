import AppKit
import SwiftUI
import XCTest
@testable import VoiceNotes

/// Renders every screen and the menu bar icon to PNGs in build/previews/, so UI
/// changes can be reviewed without clicking through the app.
/// Run with: VOICENOTES_PREVIEWS=1 swift test --filter DesignPreviews
@MainActor
final class DesignPreviews: XCTestCase {
    private let out = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/previews")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOICENOTES_PREVIEWS"] == "1",
                          "set VOICENOTES_PREVIEWS=1")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    func testRenderScreens() throws {
        let store = NoteStore(folderURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), legacyFileURL: nil, startTimer: false)
        let now = Date()
        let samples: [(String, String, String, Double?)] = [
            ("Take clothes out of washer", "Take the clothes out of the washer.", "personal", -600),
            ("Call the bank", "Call the bank about the credit card fee.", "finance", 3600 * 14),
            ("Dentist appointment", "Dentist appointment on Friday at 4 pm.", "health", 3600 * 66),
            ("Send invoice to Acme", "Send the October invoice to Acme and cc accounting.", "work", 3600 * 90),
            ("Renew passport", "Renew passport before the December trip.", "personal", 3600 * 200),
            ("Pay rent", "Pay rent.", "finance", 3600 * 300),
            ("Groceries", "Milk, eggs, bread and coffee beans.", "shopping", nil),
            ("App idea", "A menu bar timer that logs focus sessions to a CSV.", "idea", nil),
        ]
        for s in samples {
            store.add(Note(title: s.0, body: s.1, tag: s.2, remindAt: s.3.map { now.addingTimeInterval($0) }))
        }
        var water = RepeatRule(minMinutes: 10, maxMinutes: 20)
        (0..<6).forEach { _ in water.recordDone() }
        var walk = RepeatRule(minMinutes: 45, maxMinutes: 45, activeTimeOnly: true)
        (0..<3).forEach { _ in walk.recordDone() }
        store.add(Note(title: "Drink water", body: "A small pause to hydrate.", tag: "health",
                       remindAt: now.addingTimeInterval(600), repeatRule: water))
        store.add(Note(title: "Get up and walk", body: "Stretch your legs for a few minutes.", tag: "health",
                       remindAt: now.addingTimeInterval(1800), repeatRule: walk))
        var groceries = Note(title: "Groceries", body: "Groceries", tag: "shopping")
        groceries.items = ["Milk", "Eggs", "Bread", "Coffee beans", "Bananas", "Yogurt"]
            .map { ChecklistItem(text: $0) }
        groceries.items[1].done = true
        store.add(groceries)
        store.checkDue()
        let speech = SpeechRecognizer()
        let capture = CaptureModel(store: store, speech: speech)
        let main = ContentView().environmentObject(store).environmentObject(speech).environmentObject(capture)
        let empty = NoteStore(folderURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), legacyFileURL: nil, startTimer: false)
        let emptyView = ContentView().environmentObject(empty).environmentObject(speech)
            .environmentObject(CaptureModel(store: empty, speech: speech))

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(main, "main-\(suffix)", appearance)
            try render(emptyView, "empty-\(suffix)", appearance)
            try render(ContentView(editing: store.reminders[1])
                .environmentObject(store).environmentObject(speech).environmentObject(capture),
                "editor-\(suffix)", appearance)
            try render(ContentView(editing: store.reminders.first { $0.title == "Drink water" })
                .environmentObject(store).environmentObject(speech).environmentObject(capture),
                "editor-repeat-\(suffix)", appearance)
            try render(ContentView(editing: groceries)
                .environmentObject(store).environmentObject(speech).environmentObject(capture),
                "editor-checklist-\(suffix)", appearance)
            try render(ContentView(settings: true)
                .environmentObject(store).environmentObject(speech).environmentObject(capture),
                "settings-\(suffix)", appearance)
            try render(ContentView(recordingTranscript: "Remind me to call Mom tomorrow")
                .environmentObject(store).environmentObject(speech).environmentObject(capture),
                "recording-\(suffix)", appearance)
        }
    }

    func testRenderMenuBarIcon() throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let bar = HStack(spacing: 14) {
                ForEach([false, true], id: \.self) { recording in
                    Image(nsImage: AppDelegate.statusImage(recording: recording))
                        .renderingMode(.template)
                }
                Text("Wed 23:30").font(.system(size: 13))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Color(nsColor: .windowBackgroundColor))
            try render(bar, "menubar-\(suffix)", appearance, size: NSSize(width: 160, height: 24))
        }
    }

    private func render<V: View>(_ view: V, _ name: String, _ appearance: NSAppearance.Name,
                                 size: NSSize? = nil) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme,
            appearance == .darkAqua ? .dark : .light))
        // Screens render at their natural size, as the popover shows them.
        host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        // Mirror NSPopover's material instead of painting a window background.
        let material = NSVisualEffectView(frame: host.frame)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        window.contentView = material
        material.addSubview(host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        // Let FitScrollView's measured content propagate into the final size.
        host.frame.size = size ?? host.fittingSize
        material.frame.size = host.frame.size
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let rep = material.bitmapImageRepForCachingDisplay(in: material.bounds)!
        material.cacheDisplay(in: material.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!
            .write(to: out.appendingPathComponent("\(name).png"))
    }
}
