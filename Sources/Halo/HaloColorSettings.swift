import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import HaloCore

private struct AppColorRow: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var bundleID: String
    var hex: String
    var appPath: String?
}

@MainActor
final class HaloColorSettingsWindow: NSWindowController {
    init() {
        let view = HaloColorSettingsView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Colores por app · Halo Color"
        window.minSize = NSSize(width: 820, height: 620)
        window.center()
        window.contentView = NSHostingView(rootView: view)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct HaloColorSettingsView: View {
    @State private var rows: [AppColorRow] = Self.loadRows()
    @State private var fallbackColor: String = Self.loadFallbackColor()
    @State private var previewBundleID: String = ""
    @State private var glowEnabled: Bool = HaloConfig.load().glow
    @State private var ringWidth: Double = Double(HaloConfig.load().width)
    @State private var borderStyle: String = Self.initialBorderStyle()
    @State private var orbitEffect: String = Self.initialOrbitEffect()
    @State private var focusFlash: Bool = HaloConfig.load().flashOnFocus
    @State private var showFocusedAppName: Bool = HaloConfig.load().showAppNameOnFocus
    @State private var shakeOnFocus: Bool = HaloConfig.load().shake
    @State private var soundPath: String = Self.initialSoundPath()
    @State private var dimAmount: Double = HaloConfig.load().dimInactive
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var message = "Los cambios se aplican automáticamente."
    @State private var autoSaveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Colores por aplicación")
                    .font(.title2.weight(.semibold))
                Text("El color se muestra en el borde de la ventana enfocada. Las apps sin asignación usan el color global de Halo.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("Color de respaldo para apps sin asignación")
                    .font(.subheadline)
                ColorPicker("", selection: colorBinding(for: $fallbackColor), supportsOpacity: false)
                    .labelsHidden()
                TextField("#RRGGBB", text: $fallbackColor)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 105)
                Spacer()
            }

            livePreview
            Text("Tipo de borde").font(.headline)
            HStack(spacing: 9) {
                styleCard("rounded", title: "Redondeado")
                styleCard("square", title: "Recto")
                styleCard("dashed", title: "Guiones")
                styleCard("dotted", title: "Puntos")
            }
            Text("Efecto que recorre el borde").font(.headline)
            HStack(spacing: 9) {
                effectCard("none", title: "Ninguno", symbol: "minus")
                effectCard("chomp", title: "Pac-Man", symbol: "circle.lefthalf.filled")
                effectCard("ghost", title: "Fantasma", symbol: "eyes")
                effectCard("spark", title: "Chispa", symbol: "sparkle")
                effectCard("comet", title: "Cometa", symbol: "sparkles")
            }
            GroupBox("Detalles y cambio de foco") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Toggle("Glow", isOn: $glowEnabled)
                    }
                    HStack(spacing: 16) {
                        Slider(value: $ringWidth, in: 1...8, step: 0.5) {
                            Text("Grosor")
                        }
                        .frame(width: 240)
                        Text("\(ringWidth, specifier: "%.1f") pt")
                            .font(.caption.monospaced())
                            .frame(width: 50, alignment: .leading)
                    }
                    Divider()
                    HStack(spacing: 18) {
                        Toggle("Destello al cambiar de ventana", isOn: $focusFlash)
                        Toggle("Sacudir ventana al cambiar", isOn: $shakeOnFocus)
                    }
                    Toggle("Mostrar nombre de la app enfocada", isOn: $showFocusedAppName)
                    Text("Aparece centrado con el color de la app y se desvanece después de 2 segundos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if shakeOnFocus {
                        HStack {
                            Label("La sacudida requiere permiso de Accesibilidad.", systemImage: "hand.raised")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Abrir Accesibilidad…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    HStack(spacing: 10) {
                        Picker("Sonido al cambiar", selection: $soundPath) {
                            Text("Sin sonido").tag("")
                            ForEach(Self.systemSounds, id: \.path) { sound in
                                Text(sound.name).tag(sound.path)
                            }
                        }
                        .frame(width: 300)
                        Button("▶︎") { previewSound() }
                            .disabled(soundPath.isEmpty)
                            .help("Escuchar sonido")
                    }
                    HStack(spacing: 12) {
                        Text("Oscurecer apps sin foco")
                            .frame(width: 190, alignment: .leading)
                        Slider(value: $dimAmount, in: 0...0.75, step: 0.05)
                            .frame(maxWidth: 260)
                        Text("\(Int(dimAmount * 100))%")
                            .font(.caption.monospaced())
                            .frame(width: 42, alignment: .trailing)
                    }
                    Text("Cada app conserva su color asignado; las demás usan el color de respaldo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            HStack {
                Text("Aplicación")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Color")
                    .frame(width: 150, alignment: .leading)
                Spacer().frame(width: 28)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rows) { row in appRow(row) }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120, maxHeight: 280)

            HStack {
                Button {
                    chooseApplication()
                } label: {
                    Label("Añadir app…", systemImage: "plus")
                }
                Spacer()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Toggle("Abrir Halo Color al iniciar sesión", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
        }
        .padding(22)
        .frame(minWidth: 800)
        }
        .onChange(of: rows) { scheduleSave() }
        .onChange(of: fallbackColor) { scheduleSave() }
        .onChange(of: glowEnabled) { scheduleSave() }
        .onChange(of: ringWidth) { scheduleSave() }
        .onChange(of: borderStyle) { scheduleSave() }
        .onChange(of: orbitEffect) { scheduleSave() }
        .onChange(of: focusFlash) { scheduleSave() }
        .onChange(of: showFocusedAppName) { scheduleSave() }
        .onChange(of: shakeOnFocus) { scheduleSave() }
        .onChange(of: soundPath) { scheduleSave() }
        .onChange(of: dimAmount) { scheduleSave() }
        .onAppear {
            if HaloConfig.load().borderStyle == "capsule" { scheduleSave() }
        }
    }

    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Vista previa", systemImage: "eye")
                    .font(.headline)
                Spacer()
                Picker("Color de", selection: $previewBundleID) {
                    Text("Respaldo").tag("")
                    ForEach(rows) { row in Text(row.name).tag(row.bundleID) }
                }
                .frame(width: 230)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.16))
                    .padding(18)
                previewRing(style: borderStyle, color: Self.color(from: previewHex), width: ringWidth)
                    .padding(18)
                if orbitEffect != "none" { orbitPreview }
                VStack(spacing: 4) {
                    Image(systemName: "macwindow").font(.title2)
                    Text("Ventana activa").font(.caption.weight(.medium))
                    Text("\(previewName) · \(effectTitle)").font(.caption2).foregroundStyle(.secondary)
                }.foregroundStyle(.white)
            }
            .frame(height: 118)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private var previewHex: String {
        rows.first(where: { $0.bundleID == previewBundleID })?.hex ?? fallbackColor
    }

    private var previewName: String {
        rows.first(where: { $0.bundleID == previewBundleID })?.name ?? "Respaldo"
    }

    private var orbitPreview: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 0.04)) { timeline in
                let position = orbitPreviewPoint(at: timeline.date.timeIntervalSinceReferenceDate,
                                                 size: geometry.size)
                Group {
                    if orbitEffect == "ghost" {
                        Text("👻").font(.system(size: 19))
                    } else if orbitEffect == "chomp" {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 18)).foregroundStyle(.yellow)
                    } else {
                        Image(systemName: orbitEffect == "comet" ? "sparkles" : "sparkle")
                            .font(.system(size: 18)).foregroundStyle(Self.color(from: previewHex))
                    }
                }
                .position(position)
            }
        }
        .allowsHitTesting(false)
    }

    private func orbitPreviewPoint(at time: Double, size: CGSize) -> CGPoint {
        let left: CGFloat = 25, top: CGFloat = 25
        let width = max(1, size.width - 50), height = max(1, size.height - 50)
        let perimeter = 2 * (width + height)
        var distance = CGFloat(time.truncatingRemainder(dividingBy: 5) / 5) * perimeter
        if distance < width { return CGPoint(x: left + distance, y: top) }
        distance -= width
        if distance < height { return CGPoint(x: left + width, y: top + distance) }
        distance -= height
        if distance < width { return CGPoint(x: left + width - distance, y: top + height) }
        distance -= width
        return CGPoint(x: left, y: top + height - distance)
    }

    private var effectTitle: String {
        ["none": "sin efecto", "chomp": "Pac-Man", "ghost": "Fantasma", "spark": "Chispa", "comet": "Cometa"][orbitEffect] ?? "sin efecto"
    }

    private func previewRing(style: String, color: Color, width: Double) -> some View {
        Canvas { context, size in
            let inset = CGFloat(width) / 2 + 5
            let rect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            let radius: CGFloat = style == "square" ? 0 : 10
            let path = Path(roundedRect: rect, cornerRadius: radius)
            let dash: [CGFloat] = style == "dashed" ? [12, 8] : (style == "dotted" ? [0.1, 9] : [])
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        }
        .shadow(color: glowEnabled ? color.opacity(0.85) : .clear, radius: glowEnabled ? 9 : 0)
    }

    private func styleCard(_ value: String, title: String) -> some View {
        Button { borderStyle = value } label: {
            VStack(spacing: 7) {
                previewRing(style: value, color: Self.color(from: previewHex), width: 3)
                    .frame(height: 35)
                Text(title).font(.caption.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(10)
            .background(borderStyle == value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderStyle == value ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain).accessibilityLabel("Borde \(title)")
    }

    private func effectCard(_ value: String, title: String, symbol: String) -> some View {
        Button { orbitEffect = value } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Self.color(from: previewHex)).frame(height: 35)
                Text(title).font(.caption.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(10)
            .background(orbitEffect == value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(orbitEffect == value ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain).accessibilityLabel("Efecto \(title)")
    }

    private func colorBinding(for hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Self.color(from: hex.wrappedValue) },
            set: { hex.wrappedValue = Self.hex(from: $0) }
        )
    }

    private static let quickColors = ["#28A9FF", "#39C5C8", "#28D98A", "#F4C542",
                                      "#FB8900", "#FF5B7F", "#B780F5", "#FFFFFF"]

    private func appRow(_ row: Binding<AppColorRow>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                appIcon(for: row.wrappedValue)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Nombre de app", text: row.name)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                    TextField("com.ejemplo.app", text: row.bundleID)
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ColorPicker("", selection: colorBinding(for: row.hex), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28)
                TextField("#RRGGBB", text: row.hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 105)
                Button { rows.removeAll { $0.id == row.wrappedValue.id } } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Quitar aplicación")
            }
            HStack(spacing: 7) {
                Text("Colores rápidos").font(.caption2).foregroundStyle(.secondary)
                ForEach(Self.quickColors, id: \.self) { hex in
                    quickColorButton(hex, row: row)
                }
            }
            .padding(.leading, 46)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func quickColorButton(_ hex: String, row: Binding<AppColorRow>) -> some View {
        Button { row.hex.wrappedValue = hex } label: {
            Circle()
                .fill(Self.color(from: hex))
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                .overlay {
                    if row.hex.wrappedValue.caseInsensitiveCompare(hex) == .orderedSame {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(hex)
        .accessibilityLabel("Usar color \(hex) para \(row.name.wrappedValue)")
    }

    @ViewBuilder
    private func appIcon(for row: AppColorRow) -> some View {
        if let path = row.appPath ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.bundleID)?.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private static func initialBorderStyle() -> String {
        let value = HaloConfig.load().borderStyle
        return ["rounded", "square", "dashed", "dotted"].contains(value) ? value : "rounded"
    }

    private func scheduleSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            save()
        }
    }

    private func previewSound() {
        guard !soundPath.isEmpty else { return }
        NSSound(contentsOfFile: soundPath, byReference: false)?.play()
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Elige una aplicación"
        panel.prompt = "Añadir"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            message = "No pude leer el identificador de esa app."
            return
        }
        guard !rows.contains(where: { $0.bundleID == bundleID }) else {
            message = "Esa app ya está en la lista."
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        rows.append(AppColorRow(name: name, bundleID: bundleID, hex: "#28A9FF", appPath: url.path))
        message = "Añadida: \(name)"
    }

    private func save() {
        let cleaned = rows.compactMap { row -> String? in
            let bundleID = row.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let color = Self.normalizedHex(row.hex)
            guard !bundleID.isEmpty, let color else { return nil }
            return "\(bundleID)=\(color)"
        }
        guard cleaned.count == rows.count else {
            message = "Revisa el identificador y el color de cada fila. Usa #RRGGBB."
            return
        }
        guard Set(rows.map { $0.bundleID.trimmingCharacters(in: .whitespacesAndNewlines) }).count == rows.count else {
            message = "Hay aplicaciones repetidas en la lista."
            return
        }
        do {
            guard let fallback = Self.normalizedHex(fallbackColor) else {
                message = "El color global debe usar el formato #RRGGBB."
                return
            }
            try Self.write(entries: cleaned, fallbackColor: fallback,
                           glow: glowEnabled, width: ringWidth, borderStyle: borderStyle,
                           focusFlash: focusFlash, shake: shakeOnFocus, sound: soundPath,
                           showFocusedAppName: showFocusedAppName,
                           dimAmount: dimAmount,
                           orbitEffect: orbitEffect)
            fallbackColor = fallback
            rows = rows.map { row in
                var copy = row
                copy.hex = Self.normalizedHex(row.hex) ?? row.hex
                return copy
            }
            message = "Cambios aplicados."
        } catch {
            message = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            message = enabled ? "Halo Color arrancará al iniciar sesión." : "Inicio automático desactivado."
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = "No se pudo cambiar el inicio automático: \(error.localizedDescription)"
        }
    }

    private static func loadRows() -> [AppColorRow] {
        HaloConfig.load().appColorEntries.compactMap { entry in
            guard let separator = entry.firstIndex(of: "=") else { return nil }
            let bundleID = String(entry[..<separator]).trimmingCharacters(in: .whitespaces)
            let hex = String(entry[entry.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty, let normalized = normalizedHex(hex) else { return nil }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let name = url?.deletingPathExtension().lastPathComponent ?? bundleID
            return AppColorRow(name: name, bundleID: bundleID, hex: normalized, appPath: url?.path)
        }
    }

    private static func loadFallbackColor() -> String {
        let rgb = HaloConfig.load().color.rgb
        return String(format: "#%06X", rgb)
    }

    private struct SystemSound: Hashable {
        let name: String
        let path: String
    }

    private static let systemSounds: [SystemSound] = {
        let directory = "/System/Library/Sounds"
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.lowercased().hasSuffix(".aiff") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { SystemSound(name: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent,
                               path: (directory as NSString).appendingPathComponent($0)) }
    }()

    private static func initialSoundPath() -> String {
        let configured = HaloConfig.load().sound
        return systemSounds.contains(where: { $0.path == configured }) ? configured : ""
    }

    private static func initialOrbitEffect() -> String {
        let config = HaloConfig.load()
        if config.orbitEffect != "none" { return config.orbitEffect }
        if config.linePets.contains(.chomp) { return "chomp" }
        if config.linePets.contains(.ghost) { return "ghost" }
        return "none"
    }

    private static func write(entries: [String], fallbackColor: String,
                              glow: Bool, width: Double, borderStyle: String,
                              focusFlash: Bool, shake: Bool, sound: String,
                              showFocusedAppName: Bool,
                              dimAmount: Double, orbitEffect: String) throws {
        let path = HaloConfig.configFilePath
        let fileURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var source = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let section = "[app-colors]\napps = [\n"
            + entries.map { "  \"\($0)\"," }.joined(separator: "\n")
            + (entries.isEmpty ? "" : "\n")
            + "]\n"
        let pattern = "(?ms)^\\[app-colors\\]\\s*\\n.*?(?=^\\[|\\z)"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        if let match = regex.firstMatch(in: source, range: range),
           let swiftRange = Range(match.range, in: source) {
            source.replaceSubrange(swiftRange, with: section + "\n")
        } else {
            if !source.isEmpty && !source.hasSuffix("\n") { source += "\n" }
            source += "\n" + section
        }
        try upsert(section: "border", key: "color", value: "\"\(fallbackColor)\"", source: &source)
        try upsert(section: "border", key: "effect", value: "\"off\"", source: &source)
        try upsert(section: "border", key: "glow", value: String(glow), source: &source)
        try upsert(section: "border", key: "width", value: String(width), source: &source)
        try upsert(section: "border", key: "style", value: "\"\(borderStyle)\"", source: &source)
        try upsert(section: "border", key: "cycle-colors", value: "false", source: &source)
        try upsert(section: "border", key: "min-width", value: String(width), source: &source)
        try upsert(section: "border", key: "max-width", value: String(width), source: &source)
        try upsert(section: "focus", key: "flash", value: String(focusFlash), source: &source)
        try upsert(section: "focus", key: "show-app-name", value: String(showFocusedAppName), source: &source)
        try upsert(section: "shake", key: "shake", value: String(shake), source: &source)
        let escapedSound = sound.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try upsert(section: "sound", key: "sound", value: "\"\(escapedSound)\"", source: &source)
        try upsert(section: "sound", key: "sound-volume", value: "0.3", source: &source)
        try upsert(section: "dim", key: "amount", value: String(dimAmount), source: &source)
        try upsert(section: "pets", key: "effect", value: "\"\(orbitEffect)\"", source: &source)
        try upsert(section: "pets", key: "line-pets", value: "[]", source: &source)
        try source.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func upsert(section: String, key: String, value: String,
                               source: inout String) throws {
        let sectionPattern = "(?ms)^\\[\(NSRegularExpression.escapedPattern(for: section))\\]\\s*\\n.*?(?=^\\[|\\z)"
        let sectionRegex = try NSRegularExpression(pattern: sectionPattern)
        let fullRange = NSRange(source.startIndex..., in: source)
        let keyPattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=.*$"
        let keyRegex = try NSRegularExpression(pattern: keyPattern)
        if let match = sectionRegex.firstMatch(in: source, range: fullRange),
           let sectionRange = Range(match.range, in: source) {
            var block = String(source[sectionRange])
            if let keyMatch = keyRegex.firstMatch(in: block,
                                                  range: NSRange(block.startIndex..., in: block)),
               let keyRange = Range(keyMatch.range, in: block) {
                block.replaceSubrange(keyRange, with: "\(key) = \(value)")
            } else {
                if !block.hasSuffix("\n") { block += "\n" }
                block += "\(key) = \(value)\n"
            }
            source.replaceSubrange(sectionRange, with: block)
        } else {
            if !source.isEmpty && !source.hasSuffix("\n") { source += "\n" }
            source += "\n[\(section)]\n\(key) = \(value)\n"
        }
    }

    private static func normalizedHex(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.hasPrefix("#") { value = "#" + value }
        guard value.count == 7,
              value.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return value.uppercased()
    }

    private static func color(from input: String) -> Color {
        guard let hex = normalizedHex(input) else { return .cyan }
        let value = Int(hex.dropFirst(), radix: 16) ?? 0x00BFFF
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    private static func hex(from color: Color) -> String {
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .cyan
        let r = Int((converted.redComponent * 255).rounded())
        let g = Int((converted.greenComponent * 255).rounded())
        let b = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
