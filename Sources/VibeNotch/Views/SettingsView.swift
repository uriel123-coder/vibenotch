import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow: ObservableObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    @Published var page: SettingsView.Page = .general

    func show(_ page: SettingsView.Page? = nil) {
        if let page { self.page = page }
        NotchModel.shared.close()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Ajustes de VibeNotch"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", tabs = "Pestañas", today = "Hoy", agents = "Agentes", clipboard = "Portapapeles", about = "Acerca de"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .tabs: "square.grid.2x2.fill"
            case .today: "sun.max.fill"
            case .agents: "sparkles"
            case .clipboard: "doc.on.clipboard.fill"
            case .about: "info.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .general: .gray
            case .tabs: .blue
            case .today: .orange
            case .agents: .claude
            case .clipboard: .green
            case .about: .purple
            }
        }
    }

    @ObservedObject private var router = SettingsWindow.shared

    var body: some View {
        let page = router.page
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { router.page }, set: { if let p = $0 { router.page = p } })) { p in
                Label {
                    Text(p.rawValue)
                } icon: {
                    Image(systemName: p.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.tint.gradient))
                }
                .tag(p)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch page {
                case .general: GeneralPage()
                case .tabs: TabsPage()
                case .today: TodayPage()
                case .agents: AgentsPage()
                case .clipboard: ClipboardPage()
                case .about: AboutPage()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(page.rawValue)
        }
        .frame(minWidth: 620, minHeight: 560)
    }
}

private struct GeneralPage: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var model = NotchModel.shared
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var sounds = Prefs.sounds
    @State private var screen = Prefs.screenChoice

    var body: some View {
        Form {
            Section {
                Picker("Estilo", selection: $s.style) {
                    ForEach(NotchStyle.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Esta pantalla") {
                    Label(model.detectedNotch ? "Tiene notch" : "Sin notch · se usa la isla",
                          systemImage: model.detectedNotch ? "macbook" : "display")
                        .foregroundStyle(.secondary)
                }
                Picker("Mostrar en", selection: $screen) {
                    Text("Donde esté el mouse").tag("mouse")
                    Text("Pantalla principal").tag("main")
                    if NSScreen.screens.count > 1 {
                        Divider()
                        ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                    }
                }
                .onChange(of: screen) { _, v in
                    Prefs.screenChoice = v
                    AppDelegate.shared.screenChoiceChanged()
                }
            } header: {
                Text("Apariencia")
            } footer: {
                Text("Automático usa el notch si tu Mac lo tiene y una isla flotante debajo de la barra de menús si no.")
            }

            Section("Cómo se abre") {
                LabeledContent("Al pasar el mouse") {
                    Picker("", selection: $s.hoverDelay) {
                        Text("Al instante").tag(0.05)
                        Text("Rápido").tag(0.15)
                        Text("Normal").tag(0.3)
                        Text("Con calma").tag(0.6)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Mostrar una pequeña asa cuando la isla está vacía", isOn: $s.islandHandle)
                Toggle("Mostrar dónde soltar al arrastrar archivos", isOn: $s.dropHint)
            }

            Section("Sistema") {
                Toggle("Abrir al iniciar sesión", isOn: $login)
                    .onChange(of: login) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
                Toggle("Sonidos", isOn: $sounds).onChange(of: sounds) { _, v in Prefs.sounds = v }
                Toggle("Menos animaciones (gasta menos batería)", isOn: $s.reduceMotion)
            }

            Section("Atajos") {
                LabeledContent("Abrir o cerrar", value: "⌃⌥N")
                LabeledContent("Portapapeles", value: "⌃⌥V")
                LabeledContent("Buscar archivos", value: "⌃⌥F")
                LabeledContent("Copiar guardado 1…9", value: "⌃⌥1 … ⌃⌥9")
                LabeledContent("Cerrar", value: "esc")
            }
        }
    }
}

private struct TabsPage: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(NotchTab.allCases, id: \.self) { tab in
                    let on = s.tabs.contains(tab)
                    HStack {
                        Toggle(isOn: Binding(get: { on }, set: { _ in s.toggle(tab) })) {
                            Label(tab.title, systemImage: tab.symbol)
                        }
                        .disabled(on && s.tabs.count == 1)
                        Spacer()
                        if on { mover(tab) }
                    }
                }
            } header: {
                Text("Pestañas visibles")
            } footer: {
                Text("Elige qué pestañas ves y en qué orden. Arrastrar archivos al notch siempre abre el estante.")
            }
        }
    }

    private func mover(_ tab: NotchTab) -> some View {
        HStack(spacing: 2) {
            Button { s.move(tab, by: -1, in: \.tabs) } label: { Image(systemName: "chevron.up") }
                .disabled(s.tabs.first == tab)
            Button { s.move(tab, by: 1, in: \.tabs) } label: { Image(systemName: "chevron.down") }
                .disabled(s.tabs.last == tab)
        }
        .buttonStyle(.borderless)
    }
}

private struct TodayPage: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(TodayWidget.allCases) { w in
                    let on = s.widgets.contains(w)
                    HStack {
                        Toggle(isOn: Binding(get: { on }, set: { _ in s.toggle(w) })) {
                            Label(w.title, systemImage: w.symbol)
                        }
                        Spacer()
                        if on {
                            HStack(spacing: 2) {
                                Button { s.move(w, by: -1, in: \.widgets) } label: { Image(systemName: "chevron.up") }
                                    .disabled(s.widgets.first == w)
                                Button { s.move(w, by: 1, in: \.widgets) } label: { Image(systemName: "chevron.down") }
                                    .disabled(s.widgets.last == w)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("Widgets de la pestaña Hoy")
            } footer: {
                Text("Se acomodan en dos columnas en el orden que elijas.")
            }
        }
    }
}

private struct AgentsPage: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var claude = HookInstaller.claudeInstalled
    @State private var cursor = HookInstaller.cursorInstalled
    @State private var keychain = Prefs.claudeKeychain

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $claude) { Label("Claude Code", systemImage: "sparkle") }
                    .onChange(of: claude) { _, on in
                        if on { AppDelegate.shared.connect(.claude) } else { try? HookInstaller.setClaude(false) }
                        claude = HookInstaller.claudeInstalled
                    }
                Toggle(isOn: $cursor) { Label("Cursor", systemImage: "cursorarrow.rays") }
                    .onChange(of: cursor) { _, on in
                        if on { AppDelegate.shared.connect(.cursor) } else { try? HookInstaller.setCursor(false) }
                        cursor = HookInstaller.cursorInstalled
                    }
                LabeledContent {
                    Text("Automático").foregroundStyle(.secondary)
                } label: {
                    Label("Codex", systemImage: "terminal.fill")
                }
                Toggle(isOn: $s.followClaudeApp) { Label("App de Claude (Code y Cowork)", systemImage: "macwindow") }
            } header: {
                Text("Conectados")
            } footer: {
                Text("Conectar agrega hooks a ~/.claude/settings.json o ~/.cursor/hooks.json sin tocar lo demás (guarda una copia). Si VibeNotch está cerrada, tus agentes siguen normal.")
            }

            Section("Qué hace VibeNotch") {
                Toggle("Responder preguntas y aprobar planes desde el notch", isOn: $s.answerQuestions)
                Toggle("Mostrar el resumen de la respuesta al terminar", isOn: $s.showSummaries)
                Picker("Quitar los terminados de la lista", selection: $s.doneLinger) {
                    ForEach(AppSettings.lingerOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Límites de Claude desde tu cuenta (Llavero)", isOn: $keychain)
                    .onChange(of: keychain) { _, v in
                        Prefs.claudeKeychain = v
                        ClaudeUsage.shared.fetchPlanLimits()
                    }
            }
        }
    }
}

private struct ClipboardPage: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var clips = ClipboardStore.shared
    @State private var paused = Prefs.clipboardPaused
    @State private var autoPaste = Prefs.autoPaste
    @State private var showMusic = Prefs.showMusic

    var body: some View {
        Form {
            Section("Historial") {
                Toggle("Pausar historial", isOn: $paused).onChange(of: paused) { _, v in
                    if v != Prefs.clipboardPaused { clips.togglePause() }
                }
                Picker("Guardar los últimos", selection: $s.historySize) {
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                }
                Toggle("Pegar al elegir un clip", isOn: $autoPaste).onChange(of: autoPaste) { _, v in
                    Prefs.autoPaste = v
                    if v { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
                }
            }
            Section("Música") {
                Toggle("Mostrar la canción en el notch cerrado", isOn: $showMusic).onChange(of: showMusic) { _, v in
                    Prefs.showMusic = v
                    MusicStore.shared.objectWillChange.send()
                }
            }
        }
    }
}

private struct AboutPage: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("VibeNotch").font(.title2.bold())
                        Text("Versión \(version)").foregroundStyle(.secondary)
                        Text("Gratis y de código abierto · MIT").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Link("Ver en GitHub", destination: URL(string: "https://github.com/uriel123-coder/vibenotch")!)
                Link("Buscar actualizaciones", destination: URL(string: "https://github.com/uriel123-coder/vibenotch/releases/latest")!)
                Link("Reportar un problema", destination: URL(string: "https://github.com/uriel123-coder/vibenotch/issues")!)
            } footer: {
                Text("Para actualizar corre de nuevo: curl -fsSL https://raw.githubusercontent.com/uriel123-coder/vibenotch/main/scripts/install.sh | bash")
                    .textSelection(.enabled)
            }
        }
    }
}
