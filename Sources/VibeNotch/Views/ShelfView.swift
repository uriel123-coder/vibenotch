import SwiftUI

struct ShelfView: View {
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var model = NotchModel.shared

    var body: some View {
        VStack(spacing: 8) {
            if shelf.items.isEmpty {
                dropZone
            } else {
                header
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], spacing: 6) {
                        ForEach(shelf.items) { ShelfTile(item: $0) }
                    }
                    .animation(.snappy, value: shelf.items)
                }
            }
        }
        .overlay {
            if model.dropTargeted && !shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(.white.opacity(0.5))
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(shelf.items.count == 1 ? "1 elemento" : "\(shelf.items.count) elementos")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Label("Arrastrar todo", systemImage: "hand.draw.fill")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.12)))
                .overlay(MultiFileDragSource { ShelfStore.shared.urls })
                .help("Arrastra todos los archivos a la vez")
            if shelf.busy {
                ProgressView().controlSize(.small).transition(.opacity)
            }
            Button {
                ToolsStore.shared.add(shelf.urls)
                model.tab = .tools
            } label: {
                Label("Convertir", systemImage: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(PressStyle())
            .help("Abrir estos archivos en Convertir")
            Menu {
                Button("Copiar rutas (para pegar en un prompt)") { FileTools.copyPaths(shelf.urls) }
                Button("Reducir el peso de todo") { shelf.lighten(shelf.urls) }
                Button("Juntar todo en un .zip") { let urls = shelf.urls; shelf.produce { await FileTools.zip(urls) } }
                Button("Enviar todo por AirDrop") { FileTools.airDrop(shelf.urls) }
                Divider()
                Button("Vaciar estante", role: .destructive) { withAnimation(.snappy) { shelf.clear() } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.07)))
        }
        .padding(.horizontal, 4)
        .animation(.snappy, value: shelf.busy)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: model.dropTargeted ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 28, weight: .medium))
                .symbolEffect(.bounce, value: model.dropTargeted)
                .contentTransition(.symbolEffect(.replace))
            Text(model.dropTargeted ? "Suéltalo aquí" : "Arrastra archivos, carpetas o imágenes al notch")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            Text("Se quedan guardados aquí hasta que los saques. Tus originales no se mueven.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.white.opacity(model.dropTargeted ? 0.6 : 0.18))
        )
        .scaleEffect(model.dropTargeted ? 1.02 : 1)
        .animation(.snappy, value: model.dropTargeted)
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            FileThumb(url: item.url, size: 44)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(item.name.contains(" ") ? 2 : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(height: 26, alignment: .top)
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
        .frame(width: 82, height: 92)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0.04)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { withAnimation(.snappy) { ShelfStore.shared.remove(item) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.85), .black.opacity(0.6))
                }
                .buttonStyle(PressStyle())
                .padding(3)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(hover ? 1.03 : 1)
        .onHover { h in withAnimation(.snappy) { hover = h } }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onDrag {
            NotchModel.shared.isDraggingOut = true
            let provider = NSItemProvider(object: item.url as NSURL)
            provider.suggestedName = item.name
            return provider
        }
        .contextMenu {
            let shelf = ShelfStore.shared
            let url = item.url
            Button("Abrir") { NSWorkspace.shared.open(url) }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copiar archivo") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
            Button("Copiar ruta") { FileTools.copyPaths([url]) }
            Divider()
            Button("Abrir en Convertir…") {
                ToolsStore.shared.add([url])
                NotchModel.shared.tab = .tools
            }
            Button("Reducir peso") { shelf.lighten([url]) }
            Button("Hacer un .zip") { shelf.produce { await FileTools.zip([url]) } }
            Button("Enviar por AirDrop") { FileTools.airDrop([url]) }
            if FileTools.isImage(url) {
                Menu("Imagen") {
                    Button("Copiar texto de la imagen") { shelf.copyText(from: url) }
                    Divider()
                    Button("Convertir a JPG") { shelf.produce { await FileTools.convert(url, to: .jpeg) } }
                    Button("Convertir a PNG") { shelf.produce { await FileTools.convert(url, to: .png) } }
                    Button("Reducir al 50%") { shelf.produce { await FileTools.convert(url, to: .jpeg, scale: 0.5) } }
                }
            }
            Divider()
            Button("Quitar del estante") { shelf.remove(item) }
        }
        .help(item.path)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }
}
