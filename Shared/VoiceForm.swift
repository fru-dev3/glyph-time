import Foundation
import GlyphCapture
import SwiftUI

/// Talk to fill a form (Fru, Message 17): one long green bar at the top, only a mic (a waveform
/// while listening). Say it; the words are read into the form's fields, which flash green so you
/// can see what was filled; you review and Save.
struct RecordBar: View {
    var tint: Color
    let onFinal: (String) -> Void
    @State private var dictation = LiveDictation()

    var body: some View {
        Button { dictation.toggle() } label: {
            Image(systemName: dictation.on ? "waveform" : "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: dictation.on)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(dictation.on ? Color.red.opacity(0.85) : tint, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.on ? "Stop talking" : "Say it instead of filling the form")
        .historyID("record-bar")
        .help(dictation.problem ?? (dictation.on ? "Tap to stop" : "Tap and say it"))
        .onAppear { dictation.onFinal = onFinal }
    }
}

/// A field that was just filled by voice: a green wash that fades.
extension View {
    func filled(_ on: Bool) -> some View {
        #if os(macOS)
        background(on ? Color.historyGreen.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.6), value: on)
        #else
        listRowBackground(on ? Color.historyGreen.opacity(0.18) : nil)
            .animation(.easeOut(duration: 0.6), value: on)
        #endif
    }
}

