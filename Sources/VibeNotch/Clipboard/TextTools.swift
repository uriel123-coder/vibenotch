import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// Translate or spell-check a clip; the result is copied and added to the history. Both run on the Mac.
@MainActor
final class TextTools: ObservableObject {
    static let shared = TextTools()

    struct Request: Equatable {
        let id = UUID()
        let text: String
        let source: String?
        let target: String
    }

    /// Picked up by `TranslatorHost`, since Apple's translator only runs from inside a SwiftUI view.
    @Published var pending: Request?
    @Published private(set) var busy = false

    static let languages: [(code: String, name: String)] = [
        ("auto", "Automático (español ⇄ inglés)"), ("es", "Español"), ("en", "Inglés"), ("pt", "Portugués"), ("fr", "Francés"),
        ("it", "Italiano"), ("de", "Alemán"), ("zh", "Chino"), ("ja", "Japonés"), ("ko", "Coreano"), ("he", "Hebreo"), ("ar", "Árabe"),
    ]

    static func name(_ code: String) -> String {
        Locale(identifier: "es").localizedString(forLanguageCode: code) ?? code
    }

    func translate(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard #available(macOS 15, *) else {
            say("Traducir necesita macOS 15 o más nuevo", tint: .warn)
            return
        }
        let source = NLLanguageRecognizer.dominantLanguage(for: t)?.rawValue
        let pick = AppSettings.shared.translateTo
        let target = pick == "auto" ? (source?.hasPrefix("es") == true ? "en" : "es") : pick
        if let source, source.hasPrefix(target) {
            say("Ya está en \(Self.name(target))", tint: .warn)
            return
        }
        busy = true
        pending = Request(text: t, source: source, target: target)
    }

    /// `VIBENOTCH_TEXTTEST="texto"`: prints the correction and the translation, then quits.
    static func selfTest(_ text: String) {
        print("Corregido: \(corrected(text))")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TranslatorHost())
        window.orderBack(nil)
        testing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { TextTools.shared.translate(text) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("Traducción: sin respuesta en 30 s"); exit(1) }
        testWindow = window
    }
    private static var testing = false
    private static var testWindow: NSWindow?

    func translated(_ result: String?, to target: String, failure: String? = nil) {
        if Self.testing {
            print("Traducción (\(target)): \(result ?? "FALLÓ · \(failure ?? "")")")
            exit(result == nil ? 1 : 0)
        }
        busy = false
        pending = nil
        guard let result, !result.isEmpty else {
            say(failure ?? "No se pudo traducir", tint: .warn,
                subtitle: "Revisa Ajustes del Sistema › General › Idioma y región › Idiomas de traducción")
            return
        }
        ClipboardStore.shared.addResult(result, from: "Traducido al \(Self.name(target))")
        say("Traducido al \(Self.name(target)) · copiado", tint: .ok, subtitle: String(result.prefix(70)))
    }

    func correct(_ text: String) {
        let fixed = Self.corrected(text)
        guard fixed != text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            say("No encontré errores", tint: .ok)
            return
        }
        ClipboardStore.shared.addResult(fixed, from: "Corregido")
        say("Corregido · copiado", tint: .ok, subtitle: String(fixed.prefix(70)))
    }

    private func say(_ title: String, tint: Color, subtitle: String = "") {
        NotchModel.shared.announce(Announcement(symbol: "character.bubble.fill", tint: tint, title: title, subtitle: subtitle))
    }

    /// Spelling fixes from the system checker (same one as in Notes/Pages), plus a capital first letter.
    static func corrected(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        let checker = NSSpellChecker.shared
        let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        let language = lang.flatMap { l in checker.availableLanguages.first { $0.hasPrefix(l) } } ?? checker.language()
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.correction.rawValue
        let results = checker.check(text, range: NSRange(location: 0, length: (text as NSString).length), types: types,
                                    options: [.orthography: NSOrthography.defaultOrthography(forLanguage: language)],
                                    inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        let out = NSMutableString(string: text)
        for r in results.sorted(by: { $0.range.location > $1.range.location }) {
            let replacement: String?
            switch r.resultType {
            case .correction: replacement = r.replacementString
            case .spelling:
                replacement = checker.correction(forWordRange: r.range, in: text, language: language, inSpellDocumentWithTag: 0)
                    ?? checker.guesses(forWordRange: r.range, in: text, language: language, inSpellDocumentWithTag: 0)?.first
            default: replacement = nil
            }
            if let replacement { out.replaceCharacters(in: r.range, with: replacement) }
        }
        text = out as String
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        if let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        return text
    }
}

/// Invisible view that runs pending translations with Apple's on-device translator.
struct TranslatorHost: View {
    var body: some View {
        if #available(macOS 15, *) { TranslatorRunner() } else { Color.clear }
    }
}

@available(macOS 15, *)
private struct TranslatorRunner: View {
    @ObservedObject private var tools = TextTools.shared
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(config) { session in
                guard let request = TextTools.shared.pending else { return }
                do {
                    let response = try await session.translate(request.text)
                    TextTools.shared.translated(response.targetText, to: request.target)
                } catch {
                    let status = await LanguageAvailability().status(from: Locale.Language(identifier: request.source ?? "en"),
                                                                     to: Locale.Language(identifier: request.target))
                    TextTools.shared.translated(nil, to: request.target, failure: status == .unsupported
                                                ? "Ese idioma no se puede traducir aquí" : "Falta descargar el idioma para traducir")
                }
            }
            .onChange(of: tools.pending) { _, request in
                guard let request else { return }
                let source = request.source.map { Locale.Language(identifier: $0) }
                let target = Locale.Language(identifier: request.target)
                // The task only reruns when the configuration changes; same languages need an explicit invalidate.
                if config?.source == source && config?.target == target {
                    config?.invalidate()
                } else {
                    config = TranslationSession.Configuration(source: source, target: target)
                }
            }
    }
}
