@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Dictate first: the one control every Glyph app uses for typing-free input. Tap to talk,
/// words appear as you speak (Apple's on-device SpeechAnalyzer, the path Glyph Jot uses; nothing
/// leaves the device, no sound is kept), tap again to stop.
///
///     TextField("How are you feeling?", text: $note).dictatable($note)   // a mic in the field
///     DictateButton { words in fill(from: words) }                       // talk to fill a form: onFinal
///     DictateButton(text: $name, onFinal: { start(project: $0) })        // both: live words and the end
///     DictateButton.hostingView { words in ... }                         // AppKit (macOS): an NSView
///
/// From AppKit code without SwiftUI, use `LiveDictation` itself: `onText` while speaking, `onFinal` on stop.
///
/// Tests and the Simulator have no speech model: set `GLYPH_DICTATION_TEXT` in the environment, or
/// the `glyphDictationText` default (launch argument `-glyphDictationText "words"`), and those words
/// are what is "heard", streamed a word at a time.
@MainActor @Observable
public final class LiveDictation {
    public private(set) var on = false
    /// Paused: the microphone is open but nothing is heard until `resume()`.
    public private(set) var paused = false
    /// After stop: the model is finishing what it heard; the final words come with `onFinal`.
    public private(set) var finishing = false
    /// The words so far: final ones, then the guess for what is being said now.
    public private(set) var text = ""
    /// A message to show (the model downloading, the microphone refused...).
    public private(set) var problem: String?
    /// 0...1, the loudness right now, for level bars.
    public private(set) var level: Double = 0
    /// Which way the words are being heard, for diagnosis ("SpeechTranscriber en_US", "SFSpeechRecognizer").
    public private(set) var route = ""

    /// AppKit or any code without SwiftUI: the words as they change, and the final words on stop.
    public var onText: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var task: Task<Void, Never>?
    private var legacy: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacyDone = false

    public init() {}

    /// The injected transcript, when a test or the Simulator sets one.
    public static var injected: String? {
        if let words = ProcessInfo.processInfo.environment["GLYPH_DICTATION_TEXT"] { return words }
        // The launch argument, taken as given: read through defaults it is parsed as a property
        // list and loses commas and apostrophes.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-glyphDictationText"), i + 1 < args.count { return args[i + 1] }
        return UserDefaults.standard.string(forKey: "glyphDictationText")
    }

    /// A recording to hear instead of the microphone, through the real model (tests on a device):
    /// `GLYPH_DICTATION_AUDIO`, a path, or a name in the app's Documents folder.
    static var audioFile: URL? {
        guard let p = ProcessInfo.processInfo.environment["GLYPH_DICTATION_AUDIO"], !p.isEmpty else { return nil }
        return p.hasPrefix("/") ? URL(filePath: p) : URL.documentsDirectory.appending(path: p)
    }

    public func toggle() { on ? stop() : start() }

    public func start() {
        guard !on else { return }
        problem = nil
        text = ""
        on = true
        paused = false
        finished = false
        if let words = Self.injected {
            task = Task { [weak self] in
                var said: [Substring] = []
                for w in words.split(separator: " ") {
                    try? await Task.sleep(for: .milliseconds(40))
                    guard let self, self.on else { return }
                    while self.paused { try? await Task.sleep(for: .milliseconds(50)) }
                    said.append(w)
                    self.text = said.joined(separator: " ")
                    self.onText?(self.text)
                    self.level = 0.4
                }
            }
            return
        }
        task = Task { await run() }
    }

    /// Stops listening for a moment; the words so far stay.
    public func pause() {
        guard on, !paused else { return }
        paused = true
        level = 0
        if engine.isRunning { engine.pause() }
    }

    public func resume() {
        guard on, paused else { return }
        paused = false
        if Self.injected == nil, Self.audioFile == nil { try? engine.start() }
    }

    /// Stops listening. The model then finishes what it heard (a moment), and the final words
    /// arrive with `onFinal`; injected words arrive at once.
    public func stop() {
        guard on else { return }
        if engine.isRunning || paused {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        feed?.finish()
        feed = nil
        legacy?.endAudio()
        on = false
        paused = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if let words = Self.injected { text = words; finish(); return }  // a test's words arrive whole
        if task == nil { finish() } else { finishing = true }  // run() finishes after the model has
    }

    private var finished = false

    /// The final words, once per take.
    private func finish() {
        finishing = false
        task = nil
        guard !finished else { return }
        finished = true
        if !text.isEmpty { onFinal?(text) }
    }

    /// Stops with a message; always ends the take (never left "finishing").
    private func fail(_ message: String) {
        problem = message
        if on { stop() }
        finish()
    }

    private func set(_ words: String) {
        text = words
        onText?(words)
    }

    // MARK: The model

    /// The language, looked up and reserved once per launch (as Glyph Jot does): on iOS 26 an app
    /// must reserve a speech locale before it may download that locale's model.
    private static var locale: Locale?

    /// Glyph Jot's choice: the long-form SpeechTranscriber when the device has it (its model is
    /// shared by every app, so it is usually already there), else DictationTranscriber.
    private func module() async -> (any SpeechModule, AsyncThrowingStream<(String, Bool), Error>)? {
        func pieces<S: AsyncSequence & Sendable>(_ results: S, _ map: @escaping @Sendable (S.Element) -> (String, Bool)) -> AsyncThrowingStream<(String, Bool), Error> {
            AsyncThrowingStream { c in
                let t = Task { do { for try await r in results { c.yield(map(r)) }; c.finish() } catch { c.finish(throwing: error) } }
                c.onTermination = { _ in t.cancel() }
            }
        }
        if SpeechTranscriber.isAvailable {
            guard let locale = await Self.resolve({ await SpeechTranscriber.supportedLocale(equivalentTo: $0) }) else { return nil }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            route = "SpeechTranscriber \(locale.identifier)"
            return (t, pieces(t.results) { (String($0.text.characters), $0.isFinal) })
        }
        guard let locale = await Self.resolve({ await DictationTranscriber.supportedLocale(equivalentTo: $0) }) else { return nil }
        let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                     reportingOptions: [.volatileResults], attributeOptions: [])
        route = "DictationTranscriber \(locale.identifier)"
        return (t, pieces(t.results) { (String($0.text.characters), $0.isFinal) })
    }

    private static func resolve(_ supported: (Locale) async -> Locale?) async -> Locale? {
        if let locale { return locale }
        var found = await supported(.current)
        if found == nil { found = await supported(Locale(identifier: "en-US")) }
        guard let found else { return nil }
        _ = try? await AssetInventory.reserve(locale: found)  // so the model may be downloaded and is kept
        locale = found
        return found
    }

    /// The model on the device, downloading it the first time (with a message while it does).
    private func installed(_ m: any SpeechModule) async -> Bool {
        switch await AssetInventory.status(forModules: [m]) {
        case .installed: route += ", installed"; return true
        case .unsupported: route += ", unsupported"; return false
        default:
            problem = "Getting the speech model ready, one moment."
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [m]) { try? await request.downloadAndInstall() }
            let ok = await AssetInventory.status(forModules: [m]) == .installed
            route += ok ? ", downloaded" : ", download failed"
            if ok { problem = nil }
            return ok
        }
    }

    // MARK: Permission

    /// Speech recognition permission, asked once and waited for. TCC answers on its own XPC
    /// queue, so this must be built outside the main actor: a closure written anywhere in this
    /// class is main-actor code (the class is `@MainActor`), and when TCC calls it from that
    /// queue Swift's isolation check traps, on the very first talk, before a word is said
    /// (`dispatch_assert_queue` in `swift_task_isCurrentExecutor`). Same reason the audio taps
    /// are built in `nonisolated static func`s. So the callback stays off the actor and hops to
    /// the main actor itself, once it has the answer, before resuming.
    ///
    /// Any other permission with a completion handler belongs here too, built the same way.
    /// The async ones (`AVAudioApplication.requestRecordPermission()`,
    /// `AVCaptureDevice.requestAccess(for:)`) bridge safely already and need no wrapper.
    nonisolated static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                let ok = status == .authorized
                Task { @MainActor in c.resume(returning: ok) }
            }
        }
    }

    private func run() async {
        let micOK = Self.audioFile != nil ? true : await AVAudioApplication.requestRecordPermission()
        guard micOK else {
            return fail("Allow the microphone in Settings, Privacy and Security, to talk instead of type.")
        }
        #if os(iOS)
        do {
            // Glyph Jot's session: alongside other audio, so a song or another app's session doesn't make it "busy".
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            let e = error as NSError
            return fail("The microphone is busy (\(e.domain) \(e.code)).")
        }
        #endif
        guard on else { return finish() }
        if let (m, results) = await module(), await installed(m), on {
            if await analyze(m, results) { return finish() }
        }
        guard on else { return finish() }
        // Apple's older on-device recognizer, when the new models can't run here.
        await recognizeLegacy()
        finish()
    }

    /// SpeechAnalyzer with the microphone (or a recording). False when it couldn't start.
    private func analyze(_ m: any SpeechModule, _ results: AsyncThrowingStream<(String, Bool), Error>) async -> Bool {
        let source = Self.audioFile.flatMap { try? AVAudioFile(forReading: $0) }
        let input = source?.processingFormat ?? engine.inputNode.outputFormat(forBus: 0)
        route += source != nil ? ", from a recording" : ", from the microphone"
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m], considering: input),
              let converter = AVAudioConverter(from: input, to: format) else { route += ", no audio format"; return false }
        converter.primeMethod = .none
        let analyzer = SpeechAnalyzer(modules: [m])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.feed = feed
        let reader = Task { @MainActor [weak self] in
            var done = ""
            do {
                for try await (piece, final) in results {
                    let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    if final { done = done.isEmpty ? p : done + " " + p; self?.set(done) }
                    else { self?.set(done.isEmpty ? p : done + " " + p) }
                }
            } catch {}
        }
        do { try await analyzer.start(inputSequence: stream) } catch { route += ", start failed: \(error.localizedDescription)"; feed.finish(); self.feed = nil; return false }
        problem = nil
        if let source {
            // A recording, at about the speed it was said.
            let frames = AVAudioFrameCount(source.processingFormat.sampleRate / 10)
            while on, let buf = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames), (try? source.read(into: buf)) != nil, buf.frameLength > 0 {
                while paused && on { try? await Task.sleep(for: .milliseconds(50)) }
                if let out = Self.convert(buf, converter, format) { feed.yield(AnalyzerInput(buffer: out)) }
                level = Self.rms(buf)
                try? await Task.sleep(for: .milliseconds(100))
            }
        } else {
            // The tap runs on the audio thread: its block must not be main-actor code (a closure written here
            // would be, and Swift's isolation check traps on the first buffer on a real iPhone; the Simulator's
            // injected words never reach it). Built in a nonisolated function, as Glyph Jot does.
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input,
                                        block: Self.tap(feed, converter, format) { [weak self] rms in Task { @MainActor in self?.level = rms } })
            engine.prepare()
            do { try engine.start() } catch { fail("The microphone couldn't start."); return true }
        }
        while on { try? await Task.sleep(for: .milliseconds(100)) }
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await reader.value
        return true
    }

    /// SFSpeechRecognizer, on the device only (nothing is sent), the way Glyph Jot falls back.
    private func recognizeLegacy() async {
        route += route.isEmpty ? "SFSpeechRecognizer" : " -> SFSpeechRecognizer"
        let ok = await Self.speechAuthorized()
        guard ok else { return fail("Allow speech recognition in Settings, Privacy and Security, to talk instead of type.") }
        guard let r = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")), r.isAvailable,
              r.supportsOnDeviceRecognition else {
            return fail("Speech recognition on this device isn't ready. Open Settings, General, Keyboard, and turn on Dictation, then try again.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        legacy = request
        legacyDone = false
        // Both blocks run off the main thread: made outside the main actor (as the analyzer's tap).
        legacyTask = r.recognitionTask(with: request, resultHandler: Self.legacyHandler(
            words: { [weak self] w in Task { @MainActor in self?.set(w) } },
            done: { [weak self] in Task { @MainActor in self?.legacyDone = true } }))
        let input = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input,
                                    block: Self.legacyTap(request) { [weak self] rms in Task { @MainActor in self?.level = rms } })
        engine.prepare()
        do { try engine.start() } catch { return fail("The microphone couldn't start.") }
        problem = nil
        while on { try? await Task.sleep(for: .milliseconds(100)) }
        // endAudio() was sent on stop; wait a little for the final words.
        for _ in 0..<30 where !legacyDone { try? await Task.sleep(for: .milliseconds(100)) }
        legacyTask?.finish()
        legacy = nil
    }

    nonisolated static func legacyTap(_ request: SFSpeechAudioBufferRecognitionRequest, _ level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            level(rms(buffer))
        }
    }

    nonisolated static func legacyHandler(words: @escaping @Sendable (String) -> Void, done: @escaping @Sendable () -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let w = result?.bestTranscription.formattedString { words(w) }
            if result?.isFinal == true || error != nil { done() }
        }
    }

    // MARK: Self-test on a device

    nonisolated(unsafe) static var selfTested = false

    /// `GLYPH_DICTATION_SELFTEST=<seconds>` in an app's launch environment: the first talk button
    /// shown starts real dictation once (the microphone, no injected words), stops after that many
    /// seconds and prints "GLYPH-SELFTEST route=... heard=..." to the console. For checking every
    /// app on a real phone (xcrun devicectl device process launch --console).
    public func selfTestIfAsked() {
        guard !Self.selfTested, let s = ProcessInfo.processInfo.environment["GLYPH_DICTATION_SELFTEST"], let secs = Double(s) else { return }
        Self.selfTested = true
        let previous = onFinal
        onFinal = { [weak self] words in
            print("GLYPH-SELFTEST route=\(self?.route ?? "") heard=\(words)"); fflush(stdout)
            previous?(words)
        }
        Task { @MainActor [weak self] in
            // As a person would: once the app is up and active (iOS won't record for an app still launching).
            try? await Task.sleep(for: .seconds(2))
            self?.start()
            try? await Task.sleep(for: .seconds(secs))
            guard let self else { return }
            print("GLYPH-SELFTEST stopping route=\(self.route) problem=\(self.problem ?? "none") sofar=\(self.text)"); fflush(stdout)
            self.stop()
            try? await Task.sleep(for: .seconds(6))
            if self.text.isEmpty { print("GLYPH-SELFTEST route=\(self.route) heard= problem=\(self.problem ?? "none")"); fflush(stdout) }
        }
    }

    /// The microphone tap's block, made outside the main actor (it runs on the realtime audio thread).
    nonisolated static func tap(_ feed: AsyncStream<AnalyzerInput>.Continuation, _ converter: AVAudioConverter, _ format: AVAudioFormat,
                                _ level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let out = convert(buffer, converter, format) { feed.yield(AnalyzerInput(buffer: out)) }
            level(rms(buffer))
        }
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter, _ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, Double(sqrt(sum / Float(buffer.frameLength))) * 12)
    }
}

/// The mic. Tap to talk, tap to stop. With `text`, the words go into that text as you speak
/// (added after what is there); with `onWords`, you get them when you stop (talk to fill a form).
/// `label` shows a word beside the mic ("Talk"); without it the button is just the mic.
public struct DictateButton: View {
    @State private var dictation = LiveDictation()
    @State private var before = ""
    var text: Binding<String>?
    var onFinal: ((String) -> Void)?
    var label: String?
    var tint: Color
    var wide = false

    /// Live words into `text` (after what is there); `onFinal` gets this take's words on stop.
    /// `wide`: one long full-width button, only the mic (live level bars while talking), no words.
    public init(text: Binding<String>, label: String? = nil, tint: Color = .accentColor, wide: Bool = false, onFinal: ((String) -> Void)? = nil) {
        self.text = text; self.label = label; self.tint = tint; self.onFinal = onFinal; self.wide = wide
    }
    /// Talk to fill: `onFinal` gets the words when you stop.
    public init(label: String? = "Talk", tint: Color = .accentColor, wide: Bool = false, onFinal: @escaping (String) -> Void) {
        self.onFinal = onFinal; self.label = label; self.tint = tint; self.wide = wide
    }

    public var body: some View {
        HStack(spacing: 8) {
        Button { toggle() } label: {
            if wide { wideLabel } else { smallLabel }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.on ? "Stop talking" : "Talk instead of typing")
        .help(dictation.problem ?? (dictation.on ? "Tap to stop" : "Tap and say it"))
        .onChange(of: dictation.text) { _, words in
            guard let text, dictation.on || !words.isEmpty else { return }
            text.wrappedValue = before.isEmpty ? words : before + " " + words
        }
        .onAppear { if let onFinal { dictation.onFinal = { onFinal($0) } }; dictation.selfTestIfAsked() }
            if wide && dictation.on {
                Button { dictation.paused ? dictation.resume() : dictation.pause() } label: {
                    Image(systemName: dictation.paused ? "play.fill" : "pause.fill").font(.title3.weight(.semibold))
                        .frame(width: 56, height: 56)
                        .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.paused ? "Resume" : "Pause")
                .accessibilityIdentifier("glyph.pause")
            }
        }
    }

    var wideLabel: some View {
        ZStack {
            if dictation.on {
                HStack(spacing: 4) {
                    ForEach(0..<9, id: \.self) { i in
                        let shape = [0.45, 0.7, 0.9, 1.0, 0.85, 1.0, 0.9, 0.7, 0.45][i]
                        Capsule().fill(.white).frame(width: 4, height: max(6, 30 * min(1, dictation.level * 1.6 + 0.12) * shape))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: dictation.level)
            } else {
                Image(systemName: "mic.fill").font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(dictation.on ? Color.red.opacity(0.85) : tint, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }

    var smallLabel: some View {
            HStack(spacing: 6) {
                Image(systemName: dictation.on ? "stop.fill" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: dictation.on)
                if let label { Text(dictation.on ? "Done" : label).fontWeight(.semibold) }
            }
            .font(label == nil ? .body : .body.weight(.semibold))
            .foregroundStyle(label == nil && !dictation.on ? tint : .white)
            .padding(.horizontal, label == nil ? 8 : 14)
            .frame(minWidth: 36, minHeight: 36)
            .background(label == nil && !dictation.on ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(dictation.on ? Color.red.opacity(0.85) : tint), in: .capsule)
            .contentShape(.capsule)
    }

    func toggle() {
        if !dictation.on { before = text?.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        dictation.toggle()
    }
}

#if os(macOS)
public extension DictateButton {
    /// For AppKit: the button in an NSView, e.g. an NSAlert's `accessoryView` or beside a field.
    @MainActor static func hostingView(label: String? = "Talk", tint: Color = .accentColor, onFinal: @escaping (String) -> Void) -> NSView {
        let v = NSHostingView(rootView: DictateButton(label: label, tint: tint, onFinal: onFinal).padding(4))
        v.setFrameSize(v.fittingSize)
        return v
    }
}
#endif

public extension View {
    /// A mic at the trailing edge of a text field or editor: tap and talk, the words land in `text`.
    func dictatable(_ text: Binding<String>, tint: Color = .accentColor) -> some View {
        HStack(alignment: .center, spacing: 6) {
            self
            DictateButton(text: text, tint: tint)
        }
    }
}
