import AppKit

/// Checks GitHub Releases once a day and updates the app in place with one click.
/// The previous copy is moved to the temporary folder rather than deleted, so a failed swap can be rolled back.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate, available(String), downloading, failed(String)
    }

    @Published private(set) var state: State = .idle
    private var zipURL: URL?
    private var timer: Timer?
    private let api = URL(string: "https://api.github.com/repos/uriel123-coder/vibenotch/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/uriel123-coder/vibenotch/releases/latest")!

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var available: String? { if case .available(let v) = state { v } else { nil } }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MainActor.assumeIsolated { Updater.shared.check(manual: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check(manual: false) }
        }
        timer?.tolerance = 3600
    }

    func check(manual: Bool) {
        guard state != .checking, state != .downloading else { return }
        if manual { state = .checking }
        var req = URLRequest(url: api, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (json?["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let assets = json?["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String) == "VibeNotch.zip" }?["browser_download_url"] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Updater.shared.checked(tag: tag, zip: zip.flatMap(URL.init(string:)), failed: error != nil, manual: manual) }
            }
        }.resume()
    }

    private func checked(tag: String?, zip: URL?, failed: Bool, manual: Bool) {
        guard let tag, let zip else {
            state = manual ? .failed(failed ? "Sin conexión" : "No encontré la versión nueva") : .idle
            return
        }
        guard Self.isNewer(tag, than: current) else {
            state = manual ? .upToDate : .idle
            return
        }
        zipURL = zip
        state = .available(tag)
        let key = "announcedUpdate"
        if manual || UserDefaults.standard.string(forKey: key) != tag {
            UserDefaults.standard.set(tag, forKey: key)
            var a = Announcement(symbol: "arrow.down.circle.fill", tint: .ok, title: "VibeNotch \(tag) ya está lista",
                                 subtitle: "Toca Actualizar y en unos segundos se reabre")
            a.action = ("Actualizar", { Updater.shared.install() })
            NotchModel.shared.announce(a, for: 12)
        }
    }

    /// `VIBENOTCH_UPDATETEST=1` checks, installs whatever is newer and logs each step (run it on a copy outside /Applications).
    func selfTest() {
        print("Versión actual: \(current) · \(Bundle.main.bundleURL.path)")
        check(manual: true)
        Task { @MainActor in
            var last: State?
            while true {
                if state != last { print("Estado: \(state)"); fflush(stdout); last = state }
                switch state {
                case .available: install()
                case .upToDate, .failed: exit(0)
                default: break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func install() {
        guard let zipURL, let version = available else { return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        state = .downloading
        URLSession.shared.downloadTask(with: zipURL) { file, _, error in
            let result: Result<URL, UpdateError> = {
                guard let file, error == nil else { return .failure(UpdateError("No se pudo descargar")) }
                return Updater.unpack(file, expecting: version)
            }()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let app): Updater.shared.swap(to: app, target: target)
                    case .failure(let e): Updater.shared.state = .failed(e.why)
                    }
                }
            }
        }.resume()
    }

    /// Unzips next to the download and checks it is really VibeNotch at the expected version with a valid signature.
    nonisolated private static func unpack(_ zip: URL, expecting version: String) -> Result<URL, UpdateError> {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("VibeNotch-update-\(version)-\(UUID().uuidString.prefix(6))")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent("VibeNotch.zip")
        guard (try? fm.moveItem(at: zip, to: local)) != nil,
              run("/usr/bin/ditto", ["-x", "-k", local.path, dir.path]) == 0 else { return .failure(UpdateError("El archivo descargado está dañado")) }
        let app = dir.appendingPathComponent("VibeNotch.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version,
              run("/usr/bin/codesign", ["--verify", "--deep", app.path]) == 0 else { return .failure(UpdateError("La descarga no pasó la verificación")) }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return .success(app)
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A detached script waits for this process to quit, swaps the bundles and opens the new one.
    private func swap(to app: URL, target: URL) {
        let old = app.deletingLastPathComponent().appendingPathComponent("VibeNotch-anterior.app")
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        if mv "\(target.path)" "\(old.path)"; then
          mv "\(app.path)" "\(target.path)" || mv "\(old.path)" "\(target.path)"
        fi
        open "\(target.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("No se pudo instalar")
        }
    }
}

private struct UpdateError: Error {
    let why: String
    init(_ why: String) { self.why = why }
}
