import SwiftUI

struct ToolsView: View {
    @ObservedObject private var tools = ToolsStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            InputWell().frame(width: 158)
            VStack(spacing: 8) {
                ToolGrid()
                if tools.running != nil || tools.result != nil {
                    ResultBar().transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: tools.running)
            .animation(.snappy, value: tools.result?.id)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Files going in

private struct InputWell: View {
    @ObservedObject private var tools = ToolsStore.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var model = NotchModel.shared
    @State private var shake: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tools.inputs.isEmpty {
                empty.frame(maxHeight: .infinity)
            } else {
                list
                Spacer(minLength: 0)
            }
            saveToggle
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(model.dropTargeted ? 0.1 : 0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: model.dropTargeted ? 1.5 : 1, dash: tools.inputs.isEmpty || model.dropTargeted ? [5, 4] : []))
                .foregroundStyle(.white.opacity(model.dropTargeted ? 0.6 : tools.inputs.isEmpty ? 0.2 : 0.06))
        )
        .scaleEffect(model.dropTargeted ? 1.02 : 1)
        .modifier(Shake(amount: shake))
        .animation(.snappy, value: model.dropTargeted)
        .onChange(of: tools.nudge) { _, _ in withAnimation(.linear(duration: 0.4)) { shake += 1 } }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: model.dropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .symbolEffect(.bounce, value: model.dropTargeted)
                .contentTransition(.symbolEffect(.replace))
            Text(model.dropTargeted ? "Suéltalos" : "Suelta archivos aquí")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            Text("Fotos, PDF, videos, audio o .zip")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !shelf.items.isEmpty {
                Button { tools.add(shelf.urls) } label: {
                    Label("Usar el estante (\(shelf.items.count))", systemImage: "tray.full.fill")
                }
                .buttonStyle(PillStyle(fill: .white.opacity(0.14)))
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(tools.inputs.count == 1 ? "1 archivo" : "\(tools.inputs.count) archivos")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                if !shelf.items.isEmpty {
                    IconButton(symbol: "tray.and.arrow.up.fill", help: "Agregar lo del estante") { tools.add(shelf.urls) }
                }
                IconButton(symbol: "xmark", help: "Quitar todos") { tools.clear() }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(tools.inputs, id: \.self) { InputRow(url: $0) }
                }
            }
            .frame(maxHeight: 190)
        }
    }

    private var saveToggle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("GUARDAR EN").font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 2) {
                segment("Estante", "tray.fill", selected: !tools.nextToOriginal) { tools.nextToOriginal = false }
                segment("Original", "folder.fill", selected: tools.nextToOriginal) { tools.nextToOriginal = true }
            }
            .padding(2)
            .background(Capsule().fill(.white.opacity(0.07)))
        }
    }

    private func segment(_ title: String, _ symbol: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(title == "Estante" ? "Los resultados se guardan en el estante" : "Los resultados se guardan junto al archivo original")
    }
}

private struct InputRow: View {
    let url: URL
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            FileThumb(url: url, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).font(.system(size: 10.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: ToolsStore.size(url), countStyle: .file))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hover {
                Button { ToolsStore.shared.remove(url) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(PressStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
        .onHover { h in withAnimation(.snappy) { hover = h } }
        .help(url.path)
        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
    }
}

// MARK: - Tools

private struct ToolGrid: View {
    @ObservedObject private var tools = ToolsStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        let visible = tools.inputs.isEmpty ? tools.tools : tools.available
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if !tools.inputs.isEmpty && visible.isEmpty {
                    Text("No hay herramientas para estos archivos.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 20)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Tool.Section.allCases, id: \.self) { section in
                    let items = visible.filter { $0.section == section }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Image(systemName: section.symbol).font(.system(size: 9, weight: .bold))
                                Text(section.rawValue.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.leading, 2)
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(items) { ToolButton(tool: $0, idle: tools.inputs.isEmpty) }
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(.bottom, 4)
            .animation(.snappy, value: visible.map(\.id))
        }
    }
}

private struct ToolButton: View {
    let tool: Tool
    let idle: Bool
    @ObservedObject private var tools = ToolsStore.shared
    @State private var hover = false

    var body: some View {
        let running = tools.running == tool.id
        let count = tools.targets(for: tool).count
        Button { tools.run(tool) } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tool.tint.opacity(hover && !idle ? 0.32 : 0.2))
                    if running {
                        Spinner(color: tool.tint, size: 13)
                    } else {
                        Image(systemName: tool.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tool.tint)
                    }
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.title).font(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(!idle && count > 1 && !running ? "\(count) archivos" : tool.detail)
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(hover && !idle ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tool.tint.opacity(running ? 0.6 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .opacity(idle ? 0.5 : tools.running != nil && !running ? 0.55 : 1)
        .disabled(tools.running != nil)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(idle ? "Primero suelta un archivo a la izquierda" : "\(tool.title): \(tool.detail)")
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

// MARK: - Result

private struct ResultBar: View {
    @ObservedObject private var tools = ToolsStore.shared

    var body: some View {
        HStack(spacing: 10) {
            if tools.running != nil {
                let p = tools.progress
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .progressViewStyle(.linear).tint(.white).frame(width: 90)
                Text(p.total > 1 ? "Procesando \(min(p.done + 1, p.total)) de \(p.total)…" : "Procesando…")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if let r = tools.result {
                ZStack {
                    FileThumb(url: r.outputs[0], size: 30)
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(.white, Color.ok).offset(x: 13, y: 12)
                }
                .overlay(MultiFileDragSource { r.outputs })
                .help("Arrástralo a donde quieras")
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.outputs.count == 1 ? r.outputs[0].lastPathComponent : "\(r.outputs.count) archivos listos")
                        .font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(summary(r)).font(.system(size: 10)).foregroundStyle(saved(r) != nil ? Color.ok : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Label("Arrastrar", systemImage: "hand.draw.fill")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .overlay(MultiFileDragSource { r.outputs })
                IconButton(symbol: "folder", help: "Mostrar en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(r.outputs)
                }
                IconButton(symbol: "arrow.uturn.left", help: "Seguir editando el resultado") {
                    tools.clear()
                    tools.add(r.outputs)
                }
                IconButton(symbol: "xmark", help: "Cerrar") { withAnimation(.snappy) { tools.result = nil } }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }

    private func saved(_ r: ToolResult) -> Double? {
        guard r.shrinks, r.before > 0, r.after < r.before else { return nil }
        return 1 - Double(r.after) / Double(r.before)
    }

    private func summary(_ r: ToolResult) -> String {
        let after = ByteCountFormatter.string(fromByteCount: r.after, countStyle: .file)
        if let s = saved(r) {
            return "\(ByteCountFormatter.string(fromByteCount: r.before, countStyle: .file)) → \(after) · \(Int((s * 100).rounded()))% menos"
        }
        return "\(r.title) · \(after)"
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(amount * .pi * 4), y: 0))
    }
}
