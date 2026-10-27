import AppKit
import SwiftUI

/// Layout metrics and colors, taken from the Penpot frames ("01 Main / Light|Dark").
enum VoiceStyle {
    static let popoverWidth: CGFloat = 340
    static let scrollMaxHeight: CGFloat = 440
    static let accent = Color.accentColor

    /// Solid popover surface, so whatever is behind the popover doesn't tint it.
    static let surface = dynamic(light: 0xF4F4F3, dark: 0x292A2C)
    /// Flat input fields and buttons (capture field, mic button, search).
    static let field = dynamic(light: 0xFFFFFF, dark: 0x363739)
    static let segmentTrack = dynamic(light: 0xE4E4E4, dark: 0x3A3B3D)
    static let segmentSelected = dynamic(light: 0xFFFFFF, dark: 0x68686A)
    static let primaryText = dynamic(light: 0x252628, dark: 0xF2F2F2)
    static let secondaryText = dynamic(light: 0x77797D, dark: 0xA3A4A7)
    static let overdue = dynamic(light: 0xCA5147, dark: 0xFF827A)
    static let separator = dynamic(light: 0xDFDFDE, dark: 0x414244)
    static let hover = dynamic(light: 0xE9E9E8, dark: 0x343537)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The flat, borderless rounded fill Penpot uses for inputs and small buttons.
struct FlatField: ViewModifier {
    var height: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 7)
            .frame(minHeight: height)
            .background(VoiceStyle.field, in: RoundedRectangle(cornerRadius: 5))
    }
}

extension View {
    func flatField(height: CGFloat = 24) -> some View { modifier(FlatField(height: height)) }
}

/// Penpot's segmented control: a flat track with a raised pill for the selection.
struct FlatSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.subheadline)
                        .foregroundStyle(selected ? VoiceStyle.primaryText : VoiceStyle.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(selected ? VoiceStyle.segmentSelected : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(1)
        .background(VoiceStyle.segmentTrack, in: RoundedRectangle(cornerRadius: 5))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}
