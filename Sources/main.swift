import AppKit
import UniformTypeIdentifiers

func titleFor(_ status: String) -> String {
    switch status {
    case "ai_declared": return "IA declarada nos metadados"
    case "credentials_present": return "Credenciais presentes · revisar"
    case "no_signals": return "Nenhum sinal nos metadados lidos"
    default: return "Verificação inconclusiva"
    }
}
func colorFor(_ status: String) -> NSColor {
    switch status {
    case "ai_declared": return NSColor(srgbRed: 1, green: 0.46, blue: 0.36, alpha: 1)
    case "no_signals": return NSColor(srgbRed: 0.39, green: 0.8, blue: 0.75, alpha: 1)
    default: return NSColor(srgbRed: 0.98, green: 0.75, blue: 0.36, alpha: 1)
    }
}

if CommandLine.arguments.contains("--scan") {
    let index = CommandLine.arguments.firstIndex(of: "--scan")!
    let reports = CommandLine.arguments.dropFirst(index+1).map { path -> ScanReport in
        let url = URL(fileURLWithPath: path)
        return MediaScanner(url: url).scan(url)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let json = try? encoder.encode(reports) { FileHandle.standardOutput.write(json) }
    exit(0)
}

final class DropView: NSView {
    var receive: (([URL]) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL]); wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.065, green: 0.079, blue: 0.097, alpha: 1).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderWidth = 2; layer?.borderColor = NSColor.systemTeal.cgColor
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        receive?(urls); return true
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var root: DropView!
    var body: NSStackView!
    var resultsStack: NSStackView!
    var countLabel: NSTextField!
    var reports: [ScanReport] = []
    var pending = 0
    let queue = DispatchQueue(label: "local.metadados.scan", qos: .userInitiated)

    func label(_ text: String, _ size: CGFloat = 14, _ color: NSColor = .labelColor, _ weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        label.isSelectable = true
        return label
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        setupMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Sinal IA — Vídeos e imagens"
        window.minSize = NSSize(width: 660, height: 620)
        window.titlebarAppearsTransparent = true
        root = DropView(frame: window.contentView!.bounds)
        root.receive = { [weak self] urls in self?.scan(urls) }
        window.contentView = root

        body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 16
        body.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32), body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32), body.topAnchor.constraint(equalTo: root.topAnchor, constant: 26), body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)])
        body.addArrangedSubview(label("SINAL IA   /   VERIFICAÇÃO LOCAL", 12, .systemTeal, .semibold))
        body.addArrangedSubview(label("Antes de publicar, confira os sinais.", 27, .labelColor, .bold))
        body.addArrangedSubview(label("Arraste vídeos e imagens para esta janela. Veja se o arquivo carrega declarações de IA que podem levar a um rótulo no Instagram.", 14, .secondaryLabelColor))

        let drop = NSBox(); drop.boxType = .custom
        drop.cornerRadius = 14; drop.borderColor = NSColor(srgbRed: 0.25, green: 0.41, blue: 0.42, alpha: 1)
        drop.fillColor = NSColor(srgbRed: 0.09, green: 0.13, blue: 0.15, alpha: 1)
        let dropContent = NSStackView(); dropContent.orientation = .vertical; dropContent.spacing = 9
        dropContent.translatesAutoresizingMaskIntoConstraints = false; drop.contentView!.addSubview(dropContent)
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.viewfinder", accessibilityDescription: "Verificar arquivo")!)
        icon.contentTintColor = .systemTeal; icon.symbolConfiguration = .init(pointSize: 27, weight: .light)
        dropContent.addArrangedSubview(icon)
        dropContent.addArrangedSubview(label("Solte vídeos ou imagens aqui", 19, .labelColor, .semibold))
        let choose = NSButton(title: "Escolher arquivos…", target: self, action: #selector(chooseFiles)); choose.bezelStyle = .rounded
        dropContent.addArrangedSubview(choose)
        dropContent.addArrangedSubview(label("Vídeos · JPG · PNG · WebP · HEIC · AVIF · TIFF · PSD   /   Sem upload", 12, .secondaryLabelColor))
        body.addArrangedSubview(drop)
        NSLayoutConstraint.activate([drop.widthAnchor.constraint(equalTo: body.widthAnchor), drop.heightAnchor.constraint(equalToConstant: 178), dropContent.centerXAnchor.constraint(equalTo: drop.contentView!.centerXAnchor), dropContent.centerYAnchor.constraint(equalTo: drop.contentView!.centerYAnchor)])

        let toolbar = NSStackView(); toolbar.orientation = .horizontal
        countLabel = label("PRONTO PARA VERIFICAR", 11, .secondaryLabelColor, .semibold)
        toolbar.addArrangedSubview(countLabel)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(spacer)
        let export = NSButton(title: "Salvar relatório", target: self, action: #selector(exportReports)); export.bezelStyle = .rounded
        toolbar.addArrangedSubview(export)
        let clear = NSButton(title: "Limpar", target: self, action: #selector(clearResults)); clear.bezelStyle = .rounded; toolbar.addArrangedSubview(clear)
        body.addArrangedSubview(toolbar); toolbar.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        resultsStack = NSStackView(); resultsStack.orientation = .vertical; resultsStack.alignment = .leading; resultsStack.spacing = 12
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(resultsStack); scroll.documentView = document
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), resultsStack.topAnchor.constraint(equalTo: document.topAnchor), resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor), resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor), resultsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        body.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        body.addArrangedSubview(label("O resultado descreve metadados, não a decisão do Instagram. “Nenhum sinal” não garante ausência de rótulo. Não analisa pixels, áudio, marcas invisíveis nem autenticidade das assinaturas.", 11, .secondaryLabelColor))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let i = CommandLine.arguments.firstIndex(of: "--files") { scan(CommandLine.arguments.dropFirst(i+1).map { URL(fileURLWithPath: $0) }) }
        if CommandLine.arguments.contains("--preview") {
            let example = ScanReport(file: "imagem.png", status: "ai_declared", bytesRead: 260_000, fileSize: 4_542_820, milliseconds: 4, hasC2PA: true, evidence: [Evidence(kind: "ai_source", value: "trainedAlgorithmicMedia", location: "C2PA"), Evidence(kind: "software", value: "ChatGPT", location: "C2PA")])
            reports.append(example); addCard(example); updateCount()
            DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
                self.root.layoutSubtreeIfNeeded()
                if let bitmap = self.root.bitmapImageRepForCachingDisplay(in: self.root.bounds) {
                    self.root.cacheDisplay(in: self.root.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/preview.png"))
                }
                NSApp.terminate(nil)
            }
        }
    }
    func setupMenu() {
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sobre Sinal IA", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item)
        let edit = NSMenuItem(), editMenu = NSMenu(title: "Editar")
        editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; menu.addItem(edit); NSApp.mainMenu = menu
    }
    @objc func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaScanner.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { response in if response == .OK { self.scan(panel.urls) } }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        scan(filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success)
    }
    func scan(_ urls: [URL]) {
        pending += urls.count; updateCount()
        for url in urls {
            queue.async {
                let report = MediaScanner(url: url).scan(url)
                DispatchQueue.main.async {
                    self.pending -= 1; self.reports.append(report); self.addCard(report); self.updateCount()
                }
            }
        }
    }
    func updateCount() {
        countLabel?.stringValue = pending > 0 ? "VERIFICANDO \(pending) ARQUIVO(S)…" : "\(reports.count) ARQUIVO(S) VERIFICADO(S)"
    }
    func addCard(_ report: ScanReport) {
        let card = NSStackView(); card.orientation = .vertical; card.alignment = .leading; card.spacing = 7
        card.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        card.wantsLayer = true; card.layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.125, blue: 0.15, alpha: 1).cgColor; card.layer?.cornerRadius = 12
        card.addArrangedSubview(label(report.file, 16, .labelColor, .semibold))
        card.addArrangedSubview(label(titleFor(report.status), 15, colorFor(report.status), .semibold))
        let sources = Set(report.evidence.filter { $0.kind == "ai_source" }.map { $0.value.components(separatedBy: "/").last! }).sorted()
        let tools = Set(report.evidence.filter { $0.kind == "software" }.map { $0.value }).sorted()
        let detail: String
        switch report.status {
        case "ai_declared": detail = "Há declaração de IA no arquivo ou no histórico de materiais usados. Isso pode acionar o rótulo; não significa que todo o conteúdo foi gerado por IA."
        case "credentials_present": detail = "Há credenciais C2PA, mas nenhuma declaração de IA reconhecida. C2PA também registra conteúdo capturado por câmeras."
        case "no_signals": detail = "Nenhuma declaração de IA reconhecida nem credencial C2PA foi encontrada nos blocos examinados. O Instagram ainda pode aplicar um rótulo."
        default: detail = "Não foi possível concluir a leitura dos metadados. Este resultado não confirma ausência de sinais."
        }
        card.addArrangedSubview(label(detail, 13, .secondaryLabelColor))
        let sourceNames = sources.map { value -> String in
            switch value {
            case "trainedAlgorithmicMedia": return "Material gerado por IA"
            case "compositeWithTrainedAlgorithmicMedia": return "Composição com elementos gerados por IA"
            case "compositeSynthetic": return "Composição com elementos sintéticos de IA"
            default: return value
            }
        }
        if !sourceNames.isEmpty { card.addArrangedSubview(label("Declarações: " + sourceNames.joined(separator: " · "), 11, .secondaryLabelColor)) }
        if !tools.isEmpty { card.addArrangedSubview(label("Softwares no histórico: " + tools.joined(separator: " · "), 11, .secondaryLabelColor)) }
        let ingredients = Set(report.evidence.filter { $0.kind == "ingredient" }.map { $0.value }).sorted()
        if !ingredients.isEmpty { card.addArrangedSubview(label("Materiais no histórico: " + ingredients.prefix(4).joined(separator: " · "), 11, .secondaryLabelColor)) }
        for warning in report.warnings { card.addArrangedSubview(label(warning, 12, .systemOrange)) }
        let size = ByteCountFormatter.string(fromByteCount: Int64(report.fileSize), countStyle: .file)
        let read = report.additionalSystemReads ? "Metadados via macOS + leitura direta" : ByteCountFormatter.string(fromByteCount: Int64(report.bytesRead), countStyle: .file) + " lidos"
        card.addArrangedSubview(label(String(format: "%@  ·  %@  ·  %.0f ms  ·  C2PA %@", size, read, report.milliseconds, report.hasC2PA ? "presente" : "não encontrado"), 11, .tertiaryLabelColor))
        resultsStack.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        for view in card.arrangedSubviews { view.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -36).isActive = true }
    }
    @objc func clearResults() {
        guard pending == 0 else { NSSound.beep(); return }
        reports.removeAll()
        for view in resultsStack.arrangedSubviews { resultsStack.removeArrangedSubview(view); view.removeFromSuperview() }
        updateCount()
    }
    @objc func exportReports() {
        guard !reports.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "verificacao-ia.json"; panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
                try encoder.encode(self.reports).write(to: url, options: .atomic)
            } catch { let alert = NSAlert(error: error); alert.beginSheetModal(for: self.window) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
