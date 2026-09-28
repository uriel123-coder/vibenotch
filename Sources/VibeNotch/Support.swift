import AppKit
import SwiftUI

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = ensure(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VibeNotch", isDirectory: true))
    static let bridge = ensure(home.appendingPathComponent(".vibenotch", isDirectory: true))

    static func folder(_ name: String) -> URL { ensure(support.appendingPathComponent(name, isDirectory: true)) }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Disk {
    /// Screenshot/demo runs must never read or overwrite the user's real history.
    nonisolated(unsafe) static var demo = false

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard !demo, let data = try? Data(contentsOf: Paths.support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard !demo, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: Paths.support.appendingPathComponent(name), options: .atomic)
    }
}

enum Prefs {
    private static let d = UserDefaults.standard
    static var claudeKeychain: Bool {
        get { d.bool(forKey: "claudeKeychain") }
        set { d.set(newValue, forKey: "claudeKeychain") }
    }
    static var sounds: Bool {
        get { d.object(forKey: "sounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "sounds") }
    }
    static var autoPaste: Bool {
        get { d.bool(forKey: "autoPaste") }
        set { d.set(newValue, forKey: "autoPaste") }
    }
    static var showMusic: Bool {
        get { d.object(forKey: "showMusic") as? Bool ?? true }
        set { d.set(newValue, forKey: "showMusic") }
    }
    static var screenChoice: String {
        get { d.string(forKey: "screenChoice") ?? "mouse" }
        set { d.set(newValue, forKey: "screenChoice") }
    }
    static var clipboardPaused: Bool {
        get { d.bool(forKey: "clipboardPaused") }
        set { d.set(newValue, forKey: "clipboardPaused") }
    }
}

enum Sound {
    case done, ask
    static func play(_ s: Sound) {
        guard Prefs.sounds else { return }
        NSSound(named: s == .done ? "Glass" : "Ping")?.play()
    }
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1e3) }
        return "\(n)"
    }

    static func countdown(to date: Date, now: Date = .now) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return m > 0 ? "\(m) min" : "<1 min"
    }

    static func ago(_ date: Date, now: Date = .now) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 45 { return "ahora" }
        if s < 3_600 { return "hace \(max(1, s / 60)) min" }
        if s < 86_400 { return "hace \(s / 3_600) h" }
        return "hace \(s / 86_400) d"
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

enum JSONDate {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parse(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            return v > 0 ? Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v) : nil
        }
        if let s = value as? String { return iso.date(from: s) ?? isoPlain.date(from: s) }
        return nil
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func dbl(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func obj(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Reads only the lines appended to a JSONL file since the previous call.
final class JSONLTail {
    private var offset: UInt64 = 0
    private var started = false

    func read(_ path: String, maxInitial: UInt64 = 2_000_000, filter: (String) -> Bool = { _ in true }) -> [[String: Any]] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        var skipFirst = false
        if !started {
            started = true
            if size > maxInitial { offset = size - maxInitial; skipFirst = true }
        }
        guard size > offset else { return [] }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.read(upToCount: Int(size - offset)), !data.isEmpty,
              let lastNL = data.lastIndex(of: 0x0A) else { return [] }
        offset += UInt64(lastNL - data.startIndex + 1)

        var out: [[String: Any]] = []
        for (i, line) in data[data.startIndex...lastNL].split(separator: 0x0A).enumerated() {
            if i == 0 && skipFirst { continue }
            guard let s = String(data: line, encoding: .utf8), filter(s),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            out.append(obj)
        }
        return out
    }
}

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.56, green: 0.78, blue: 1.0)
    static let cursorTint = Color(red: 0.78, green: 0.78, blue: 0.86)
    static let ok = Color(red: 0.36, green: 0.86, blue: 0.52)
    static let warn = Color(red: 1.0, green: 0.62, blue: 0.22)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)
}
