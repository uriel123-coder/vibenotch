import AVFoundation
import AppKit
import Speech

/// Voice notes: records from the mic, shows the words live in the notch and saves them as a note (also copied).
/// Recognition runs on the Mac when macOS has the language installed.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase { case idle, starting, recording, finishing }
    /// A voice note saved to Notes, text typed into the app you're in (hold right ⌥), or an order for the assistant (⌃⌥J).
    enum Mode { case note, type, assistant }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: Mode = .note
    @Published private(set) var transcript = ""
    /// Mic loudness 0…1 for the little waveform.
    @Published private(set) var level: Float = 0
    @Published private(set) var startedAt = Date()

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var endpoint: DispatchWorkItem?
    private var committed = ""
    private var segment = ""

    var active: Bool { phase != .idle }

    static let languages: [(code: String, name: String)] = [
        ("auto", "El idioma de la Mac"), ("es-MX", "Español (México)"), ("es-ES", "Español (España)"), ("es-US", "Español (EE. UU.)"),
        ("en-US", "Inglés (EE. UU.)"), ("en-GB", "Inglés (Reino Unido)"), ("pt-BR", "Portugués (Brasil)"), ("fr-FR", "Francés"),
        ("it-IT", "Italiano"), ("de-DE", "Alemán"),
    ]

    static var locale: Locale {
        let pick = AppSettings.shared.dictationLanguage
        return pick == "auto" ? Locale.current : Locale(identifier: pick)
    }

    static func runsOnDevice() -> Bool { SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false }

    func demo(_ text: String = "Comprar pan y leche, llamar al dentista el jueves y mandarle a Ana la presentación de ventas") {
        phase = .recording
        startedAt = Date().addingTimeInterval(-14)
        level = 0.55
        transcript = text
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: finish()
        case .starting, .finishing: break
        }
    }

    func start(_ mode: Mode = .note) {
        guard phase == .idle else { return }
        self.mode = mode
        phase = .starting
        transcript = ""
        level = 0
        NotchModel.shared.close()
        Task { @MainActor in
            let allowed = await Self.authorize()
            let d = Dictation.shared
            guard d.phase == .starting else { return }
            guard allowed else {
                d.phase = .idle
                var a = Announcement(symbol: "mic.slash.fill", tint: .warn, title: "Falta permiso para dictar",
                                     subtitle: "Micrófono y Reconocimiento de voz en Privacidad")
                a.action = ("Abrir", {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                })
                NotchModel.shared.announce(a, for: 8)
                return
            }
            do {
                try d.begin()
            } catch {
                d.cleanup()
                d.phase = .idle
                NotchModel.shared.announce(Announcement(symbol: "mic.slash.fill", tint: .warn, title: "No pude usar el micrófono",
                                                        subtitle: error.localizedDescription))
            }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        phase = .finishing
        stopAudio()
        request?.endAudio()
        let gen = generation
        // The final result usually lands within a second; don't hang if it never does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                let d = Dictation.shared
                if d.generation == gen && d.phase == .finishing { d.save() }
            }
        }
    }

    func cancel() {
        cleanup()
        phase = .idle
        transcript = ""
    }

    private static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    private func begin() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw DictationError(why: "El reconocimiento de voz no está disponible para \(Self.locale.identifier)")
        }
        generation += 1
        let gen = generation
        committed = ""
        segment = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        if #available(macOS 13, *) { req.addsPunctuation = true }
        req.contextualStrings = Memory.vocabulary()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw DictationError(why: "No encontré un micrófono") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(req))
        engine.prepare()
        try engine.start()

        self.engine = engine
        request = req
        task = recognizer.recognitionTask(with: req, resultHandler: Self.handler(gen))
        startedAt = Date()
        phase = .recording
        if mode == .assistant { stopAfterSilence(Assistant.shared.followUp ? 5 : 8) }
    }

    /// Talking to the assistant ends on its own when you pause, like Siri.
    private func stopAfterSilence(_ seconds: Double) {
        endpoint?.cancel()
        let gen = generation
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let d = Dictation.shared
                if d.generation == gen && d.phase == .recording { d.finish() }
            }
        }
        endpoint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in
            req.append(buffer)
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 45))
            DispatchQueue.main.async { MainActor.assumeIsolated { Dictation.shared.level = level } }
        }
    }

    nonisolated private static func handler(_ gen: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Dictation.shared.update(text, final: final, failed: failed, gen: gen) }
            }
        }
    }

    private func update(_ text: String?, final: Bool, failed: Bool, gen: Int) {
        guard gen == generation, phase == .recording || phase == .finishing else { return }
        if let text, !text.isEmpty {
            // On-device recognition starts over after a pause and reports only the new words: keep what came before.
            if segment.count > 12, text.count < segment.count / 2 {
                committed = (committed + " " + segment).trimmingCharacters(in: .whitespaces)
            }
            segment = text
            transcript = (committed + " " + text).trimmingCharacters(in: .whitespaces)
            // Room to think mid-sentence; a little more when it's barely started.
            let words = transcript.split(separator: " ").count
            if mode == .assistant && phase == .recording { stopAfterSilence(words < 4 ? 3 : 2.2) }
        }
        // Server recognition stops on its own after about a minute; keep what was said.
        if final || failed { save() }
    }

    private func save() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup()
        phase = .idle
        guard !text.isEmpty else {
            if mode != .note {
                if Assistant.shared.phase == .listening && !Assistant.shared.followUp { Assistant.shared.fail("No te escuché, intenta otra vez") }
                return
            }
            NotchModel.shared.announce(Announcement(symbol: "mic.fill", tint: .warn, title: "No escuché nada",
                                                    subtitle: "Revisa que el micrófono correcto esté elegido en Ajustes del Sistema"))
            return
        }
        if mode != .note {
            VoiceKey.deliver(text, forceAgent: mode == .assistant)
            return
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let note = Note(title: "Nota de voz · \(f.string(from: Date()))", text: text, color: 3)
        NotesStore.shared.save(note)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ClipboardStore.shared.skipCurrentChange()
        var a = Announcement(symbol: "waveform", tint: .ok, title: "Nota de voz guardada · copiada", subtitle: String(text.prefix(70)))
        a.action = ("Ver", {
            NotchModel.shared.clipSection = .notes
            NotchModel.shared.open(.clipboard)
        })
        NotchModel.shared.announce(a, for: 6)
        Sound.play(.done)
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }

    private func cleanup() {
        endpoint?.cancel()
        endpoint = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        generation += 1
    }

    /// `VIBENOTCH_DICTATIONTEST=/ruta/audio.aiff`: transcribes a file with the same settings and prints it.
    static func selfTest(_ path: String) {
        Task { @MainActor in
            guard await authorize() else { print("Sin permiso de reconocimiento de voz o micrófono"); exit(1) }
            guard let recognizer = SFSpeechRecognizer(locale: locale) else { print("Idioma no disponible"); exit(1) }
            print("Idioma: \(locale.identifier) · en la Mac: \(recognizer.supportsOnDeviceRecognition)")
            let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            if #available(macOS 13, *) { req.addsPunctuation = true }
            recognizer.recognitionTask(with: req) { result, error in
                if let error { print("Error: \(error.localizedDescription)"); exit(1) }
                if let result, result.isFinal { print("Texto: \(result.bestTranscription.formattedString)"); exit(0) }
            }
        }
    }
}

private struct DictationError: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}
