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
        case general = "General", tabs = "Pestañas", today = "Hoy", agents = "Agentes", phone = "Celular", clipboard = "Portapapeles",
             extras = "Llamadas y más", about = "Acerca de"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .tabs: "square.grid.2x2.fill"
            case .today: "sun.max.fill"
            case .agents: "sparkles"
            case .phone: "iphone.gen3"
            case .clipboard: "doc.on.clipboard.fill"
            case .extras: "phone.fill"
            case .about: "info.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .general: .gray
            case .tabs: .blue
            case .today: .orange
            case .agents: .claude
            case .phone: .teal
            case .clipboard: .green
            case .extras: .mint
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
                case .phone: PhonePage()
                case .clipboard: ClipboardPage()
                case .extras: ExtrasPage()
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
                FooterText("Automático usa el notch si tu Mac lo tiene y una isla flotante debajo de la barra de menús si no.")
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
                FooterText("Elige qué pestañas ves y en qué orden. Arrastrar archivos al notch siempre abre el estante.")
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
                FooterText("Se acomodan en dos columnas en el orden que elijas.")
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
                FooterText("Conectar agrega hooks a ~/.claude/settings.json o ~/.cursor/hooks.json sin tocar lo demás (guarda una copia). Si VibeNotch está cerrada, tus agentes siguen normal.")
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

            Section {
                Toggle("No dejar que la Mac se duerma mientras un agente trabaja", isOn: $s.keepAwake)
                Toggle("Mantener también la pantalla encendida", isOn: $s.keepScreenOn)
                    .disabled(!s.keepAwake)
            } header: {
                Text("Mac despierta")
            } footer: {
                FooterText("Solo mientras Claude, Codex o Cursor están trabajando; al terminar, la Mac vuelve a dormirse como siempre. Si cierras la tapa sin monitor externo, macOS la duerme de todos modos.")
            }
        }
    }
}

private struct PhonePage: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var phone = PhoneNotifier.shared
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Toggle("Avisarme en el celular", isOn: $s.phoneEnabled)
            } footer: {
                FooterText("Te llega una notificación cuando un agente termina o te necesita, aunque estés lejos de la Mac.")
            }

            Section("Conectar tu celular (1 minuto)") {
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Instala la app gratuita **ntfy** en tu iPhone o Android. No pide cuenta.")
                    Link("Descargar ntfy", destination: URL(string: "https://docs.ntfy.sh/subscribe/phone/")!)
                        .font(.callout)
                        .padding(.leading, 26)
                    step(2, "En ntfy toca **+** y escribe este código (o escanea el QR con la cámara):")
                    HStack(alignment: .center, spacing: 14) {
                        if let url = phone.subscribeURL, let qr = PhoneNotifier.qr(url.absoluteString) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 96, height: 96)
                                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.phoneTopic)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            Button(copied ? "Copiado ✓" : "Copiar código") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s.phoneTopic, forType: .string)
                                copied = true
                            }
                        }
                    }
                    .padding(.leading, 26)
                    step(3, "Prueba que llegue:")
                    HStack {
                        Button("Enviar prueba") { phone.test() }.disabled(phone.sending)
                        if phone.sending { ProgressView().controlSize(.small) }
                        if let r = phone.testResult { Text(r).foregroundStyle(.secondary) }
                    }
                    .padding(.leading, 26)
                }
                .padding(.vertical, 4)
            }

            Section("Cuándo avisarte") {
                Toggle("Cuando un agente termina", isOn: $s.phoneDone)
                Toggle("Cuando te pregunta algo o pide permiso", isOn: $s.phoneAsks)
                Toggle("Solo si no estás usando la Mac", isOn: $s.phoneOnlyAway)
                Toggle("Incluir el texto (resumen o pregunta)", isOn: $s.phoneDetails)
            }
            .disabled(!s.phoneEnabled)

            Section {
                TextField("Servidor", text: $s.phoneServer)
                Button("Crear un código nuevo") {
                    s.phoneTopic = PhoneNotifier.newTopic()
                    copied = false
                }
            } header: {
                Text("Avanzado")
            } footer: {
                FooterText("Los avisos pasan por el servidor gratuito de ntfy. El código es aleatorio y funciona como una contraseña: quien lo tenga puede leer tus avisos, así que no lo compartas. Si quieres que nada salga de tu red, pon aquí tu propio servidor ntfy. Sin “Incluir el texto”, solo se envía el nombre del proyecto.")
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.teal))
            Text(text)
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

private struct ExtrasPage: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var mail = MailCodes.shared
    @State private var trusted = AXIsProcessTrusted()
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Mostrar llamadas de WhatsApp en el notch", isOn: $s.whatsappCalls)
                LabeledContent("Permiso de Accesibilidad") {
                    if trusted {
                        Label("Listo", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Dar permiso") {
                            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        }
                    }
                }
            } header: {
                Text("Llamadas de WhatsApp")
            } footer: {
                FooterText("Cuando te llaman por WhatsApp en la Mac, el notch muestra quién es con Contestar y Rechazar; durante la llamada ves el tiempo, Silenciar y Colgar. Necesita la app de WhatsApp para Mac abierta y el permiso de Accesibilidad para presionar sus botones. Nada sale de tu Mac.")
            }

            Section {
                Toggle("Detectar códigos en los avisos", isOn: $s.codesEnabled)
                Toggle("Pegarlo solo en el campo donde estás", isOn: $s.codesAutoPaste)
                    .disabled(!s.codesEnabled)
                LabeledContent {
                    switch mail.status {
                    case .off:
                        Button("Conectar Mail") { mail.connect() }
                    case .connecting:
                        ProgressView().controlSize(.small)
                    case .connected(let accounts):
                        HStack {
                            Label(accounts.isEmpty ? "Conectado" : accounts.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).lineLimit(1)
                            Button("Desconectar") { mail.disconnect() }
                        }
                    case .mailClosed:
                        HStack {
                            Text("Mail está cerrado").foregroundStyle(.secondary)
                            Button("Abrir Mail") { mail.connect() }
                        }
                    case .denied:
                        Button("Dar permiso") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                    case .failed(let why):
                        HStack {
                            Text(why).foregroundStyle(.secondary).lineLimit(1)
                            Button("Reintentar") { mail.connect() }
                        }
                    }
                } label: {
                    Label("Leer tus correos (app Mail)", systemImage: "envelope.fill")
                }
                .disabled(!s.codesEnabled)
            } header: {
                Text("Códigos de verificación")
            } footer: {
                FooterText("Cuando llega un código por Mensajes (SMS del iPhone), Gmail, tu banco u otra app, aparece en el notch ya copiado con el botón Pegar y te dice de quién viene. No se guarda en el historial de Clips. Los avisos se leen con el permiso de Accesibilidad y solo si la app muestra la vista previa.\n\nConecta Mail para leer tus correos nuevos directamente: funciona con las cuentas que tengas en la app Mail (Gmail, iCloud, Outlook, Yahoo…; agrégalas en Ajustes del Sistema › Cuentas de Internet). Encuentra el código aunque venga más abajo en el correo o tengas las vistas previas ocultas, y te dice quién lo mandó y a qué cuenta. Solo lee los correos de los últimos minutos, mientras Mail esté abierto, y nada sale de tu Mac.")
            }

            Section {
                Picker("Idioma", selection: $s.dictationLanguage) {
                    ForEach(Dictation.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                LabeledContent("Dictar", value: "⌃⌥D")
                LabeledContent("Dónde se procesa") {
                    Text(Dictation.runsOnDevice() ? "En tu Mac, sin internet" : "En los servidores de Apple (este idioma no está en tu Mac)")
                        .foregroundStyle(.secondary)
                }
                .id(s.dictationLanguage)
            } header: {
                Text("Notas de voz")
            } footer: {
                FooterText("Presiona ⌃⌥D (o el micrófono en Clips › Notas), habla y toca Listo o ⌃⌥D otra vez. Ves el texto mientras hablas; al terminar se guarda como nota y queda copiado. La primera vez macOS pide permiso de micrófono y de reconocimiento de voz.")
            }

            Section {
                LabeledContent("Velocidad") {
                    Slider(value: $s.prompterSpeed, in: 8...160, step: 2) { EmptyView() }
                        .frame(width: 200)
                }
                LabeledContent("Tamaño de letra") {
                    Slider(value: $s.prompterFont, in: 14...44, step: 1) { EmptyView() }
                        .frame(width: 200)
                }
                Toggle("Cuenta regresiva 3, 2, 1 al empezar", isOn: $s.prompterCountdown)
                LabeledContent("Abrir con lo copiado", value: "⌃⌥P")
            } header: {
                Text("Teleprompter")
            } footer: {
                FooterText("El texto pasa justo debajo de la cámara para que leas mirando a la lente. Ábrelo desde una nota o un clip (botón ▶︎) o copia tu guion y presiona ⌃⌥P. Espacio pausa, ↑ ↓ cambian la velocidad, esc cierra; también puedes hacer clic en el texto o moverlo con el trackpad.")
            }

            Section {
                Picker("Traducir a", selection: $s.translateTo) {
                    ForEach(TextTools.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                LabeledContent("Traducir lo copiado", value: "⌃⌥T")
            } header: {
                Text("Traducir y corregir")
            } footer: {
                FooterText("En la pestaña Clips pasa el mouse sobre un texto: 💬 traduce y ᵃᵇᶜ corrige la ortografía. El resultado se copia listo para pegar. Usa el traductor y el corrector de macOS, sin internet; la primera vez macOS puede pedirte descargar el idioma (macOS 15 o más nuevo).")
            }
        }
        .onReceive(recheck) { _ in trusted = AXIsProcessTrusted() }
    }
}

private struct AboutPage: View {
    @ObservedObject private var updater = Updater.shared
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
                HStack {
                    switch updater.state {
                    case .available(let v):
                        Label("Hay una versión nueva: \(v)", systemImage: "arrow.down.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Actualizar ahora") { updater.install() }.buttonStyle(.borderedProminent)
                    case .downloading:
                        ProgressView().controlSize(.small)
                        Text("Descargando e instalando…")
                    case .checking:
                        ProgressView().controlSize(.small)
                        Text("Buscando…")
                    case .upToDate:
                        Label("Tienes la versión más reciente", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        Spacer()
                        Button("Buscar de nuevo") { updater.check(manual: true) }
                    case .failed(let why):
                        Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Reintentar") { updater.check(manual: true) }
                    case .idle:
                        Text("Actualizaciones")
                        Spacer()
                        Button("Buscar actualizaciones") { updater.check(manual: true) }
                    }
                }
            } footer: {
                FooterText("VibeNotch revisa una vez al día si hay versión nueva y te avisa en el notch. Al actualizar, la copia anterior se guarda en la carpeta temporal por si algo sale mal. macOS puede volver a pedirte algunos permisos después de actualizar.")
            }
            Section {
                Link("Ver en GitHub", destination: URL(string: "https://github.com/uriel123-coder/vibenotch")!)
                Link("Reportar un problema", destination: URL(string: "https://github.com/uriel123-coder/vibenotch/issues")!)
            }
        }
    }
}

private struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
