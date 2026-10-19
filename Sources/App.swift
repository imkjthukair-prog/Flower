import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if !GESTURE_TEST
@main
struct LocalConverterApp {
    static func main() {
        let args = CommandLine.arguments
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        if args.count > 1 && args[1] == "--convert" {
            guard args.count == 5 else { fputs("Usage: Flower --convert SOURCE TARGET DESTINATION\n", stderr); exit(2) }
            _ = NSApplication.shared
            Task { @MainActor in
                do {
                    try await ConversionEngine(resources: resources).convert(source: URL(fileURLWithPath: args[2]), destination: URL(fileURLWithPath: args[4]), target: args[3])
                    print(args[4]); exit(0)
                } catch { fputs("Conversion failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        if args.count > 1 && args[1] == "--tool" {
            guard args.count >= 6 else { toolUsage() }
            var inputs: [URL] = [], destination: URL?, parameters: [String: String] = [:]
            var index = 3
            while index < args.count {
                if args[index] == "--output" {
                    guard index + 1 < args.count else { toolUsage() }
                    destination = URL(fileURLWithPath: args[index + 1]); index += 2
                } else if args[index] == "--param" {
                    guard index + 1 < args.count else { toolUsage() }
                    let pair = args[index + 1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2 && !pair[0].isEmpty else { toolUsage() }
                    parameters[String(pair[0])] = String(pair[1]); index += 2
                } else if args[index].hasPrefix("--") { toolUsage() }
                else { inputs.append(URL(fileURLWithPath: args[index])); index += 1 }
            }
            guard !inputs.isEmpty, let destination else { toolUsage() }
            _ = NSApplication.shared
            Task { @MainActor in
                do {
                    try await FileToolEngine(resources: resources).perform(args[2], sources: inputs, destination: destination, parameters: parameters)
                    print(destination.path); exit(0)
                } catch { fputs("Tool failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
    private static func toolUsage() -> Never {
        fputs("Usage: Flower --tool ID SOURCE [SOURCE...] --output DESTINATION [--param key=value ...]\n", stderr)
        exit(2)
    }
}

#endif

enum WorkMode: String, CaseIterable, Identifiable {
    case convert = "Convert", tools = "Tools", actions = "Actions"
    var id: String { rawValue }
}

enum FileAction: String, CaseIterable, Identifiable {
    case airDrop, float, copy, move, copyPath, terminal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }
    var detail: String {
        switch self {
        case .airDrop: return "Open AirDrop and choose a recipient."
        case .float: return "Keep files in a floating panel and drag them into other apps."
        case .copy: return "Choose a folder for a copy. The originals stay where they are."
        case .move: return "Choose a folder to move the selected files into."
        case .copyPath: return "Copy the selected file paths to the clipboard."
        case .terminal: return "Open the containing folders in Terminal. No command is run."
        }
    }
}

struct ConversionRecord: Identifiable {
    let id = UUID()
    let source: URL
    let target: String
    var destination: URL?
    var error: String?
    var note: String?
    var running = true
}

struct ToolField: Identifiable {
    let id: String
    let title: String
    let initial: String
    let hint: String
    var required = false
    var choices: [String] = []
}

struct ToolRequest: Identifiable {
    let id = UUID()
    let tool: LocalTool
    let files: [URL]
    var fields: [ToolField] { Self.fields(for: tool.id, files: files) }
    var note: String {
        switch tool.id {
        case "compress": return FileToolEngine.isImageCompressionSource(files[0]) ? "Keeps the image format and original dimensions. PNG transparency is preserved. If it is already optimized, the result is an unchanged copy." : "Creates an MP3 using the default bitrate. The original stays unchanged."
        case "removeMetadata": return "Creates an upright PNG from the first image frame, without the source metadata fields."
        case "createCollage", "createPDF", "mergePDF": return "Uses the files in the order shown in the selection."
        case "organizePDF": return "Enter pages in the output order. You can omit or repeat pages."
        default: return "Creates a new result beside the source. The original stays unchanged."
        }
    }
    static func fields(for id: String, files: [URL]) -> [ToolField] {
        switch id {
        case "compress":
            if let source = files.first, FileToolEngine.isImageCompressionSource(source) { return [ToolField(id: "quality", title: "Quality", initial: "0.62", hint: "0.05–1; higher means better quality")] }
            return [ToolField(id: "bitrate", title: "Bitrate", initial: "128", hint: "32–320 kbps")]
        case "rotateImage": return [ToolField(id: "degrees", title: "Clockwise rotation", initial: "90", hint: "Degrees", choices: ["90", "180", "270"])]
        case "flipImage": return [ToolField(id: "axis", title: "Direction", initial: "horizontal", hint: "", choices: ["horizontal", "vertical"])]
        case "cropImage", "cropVideo": return [ToolField(id: "x", title: "Left edge", initial: "0", hint: "Pixels from the left"), ToolField(id: "y", title: "Top edge", initial: "0", hint: "Pixels from the top"), ToolField(id: "width", title: "Width", initial: "", hint: "Pixels", required: true), ToolField(id: "height", title: "Height", initial: "", hint: "Pixels", required: true)]
        case "createCollage": return [ToolField(id: "columns", title: "Columns", initial: String(Int(ceil(sqrt(Double(max(1, files.count)))))), hint: "1–20"), ToolField(id: "cellSize", title: "Cell size", initial: "512", hint: "32–2048 pixels"), ToolField(id: "gap", title: "Spacing", initial: "16", hint: "0–200 pixels")]
        case "organizePDF": return [ToolField(id: "pages", title: "Page order", initial: "", hint: "For example: 3,1,2. Page numbers start at 1.", required: true)]
        case "trimAudio", "trimVideo": return [ToolField(id: "start", title: "Start time", initial: "0", hint: "Seconds"), ToolField(id: "end", title: "End time", initial: "", hint: "Seconds; must be after the start", required: true)]
        case "audioChannels": return [ToolField(id: "channels", title: "Channels", initial: "2", hint: "1 = mono, 2 = stereo", choices: ["1", "2"])]
        case "normalizeAudio": return [ToolField(id: "loudness", title: "Target loudness", initial: "-16", hint: "−70 to −5 LUFS")]
        case "changeVideoSpeed": return [ToolField(id: "speed", title: "Speed multiplier", initial: "1.5", hint: "0.25–4; 2 means twice as fast")]
        case "videoSnapshots": return [ToolField(id: "time", title: "Snapshot time", initial: "0", hint: "Seconds")]
        default: return []
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var records: [ConversionRecord] = []
    @Published var busy = false
    @Published var mode: WorkMode = .convert
    @Published var selectedFormat = ""
    @Published var selectedTool = ""
    @Published var selectedAction: FileAction = .airDrop
    @Published var pendingTool: ToolRequest?
    @Published var message: String?
    var onProgress: (() -> Void)?
    @Published var activityIDs: [UUID] = []
    @Published var diagnostics: [String] = []
    func log(_ event: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        diagnostics.append(stamp + "  " + event)
        if diagnostics.count > 120 { diagnostics.removeFirst(diagnostics.count - 120) }
    }
    let resources: URL
    lazy var engine = ConversionEngine(resources: resources)
    lazy var toolEngine = FileToolEngine(resources: resources)
    init() { resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources") }
    var formats: [String] {
        guard let first = files.first else { return [] }
        return ConversionEngine.targets(for: first.pathExtension.lowercased()).filter { format in files.dropFirst().allSatisfy { ConversionEngine.targets(for: $0.pathExtension.lowercased()).contains(format) } }
    }
    var tools: [LocalTool] { FileToolEngine.tools(for: files) }
    func accept(_ urls: [URL]) {
        files = Array(NSOrderedSet(array: urls.filter(\.isFileURL))) as? [URL] ?? []
        selectedFormat = formats.first ?? ""
        selectedTool = tools.first?.id ?? ""
        message = nil
    }
    func choose() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose Files"
        if panel.runModal() == .OK { accept(panel.urls) }
    }
    func uniqueOutput(_ input: URL, ext: String, label: String? = nil) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + (label.map { " - " + $0 } ?? "")
        let name = ext.isEmpty ? base : base + "." + ext
        return availableURL(in: input.deletingLastPathComponent(), name: name)
    }
    private func availableURL(in folder: URL, name: String) -> URL {
        let original = folder.appendingPathComponent(name)
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        var candidate = original, suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = "\(base) (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
            candidate = folder.appendingPathComponent(next); suffix += 1
        }
        return candidate
    }
    private func complete(_ id: UUID, destination: URL? = nil, error: Error? = nil, note: String? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].destination = destination
        records[index].error = error?.localizedDescription
        records[index].note = note
        records[index].running = false
        log(error == nil ? "Finished: " + (destination?.lastPathComponent ?? "result") : "Failed: " + (error?.localizedDescription ?? "Unknown error"))
        onProgress?()
    }
    func convert(_ target: String, urls: [URL]? = nil) {
        guard !busy, !target.isEmpty else { return }
        let inputs = urls ?? files
        guard !inputs.isEmpty else { return }
        busy = true; message = nil; activityIDs = []
        Task { @MainActor in
            defer { busy = false; onProgress?() }
            for input in inputs {
                let output = uniqueOutput(input, ext: target)
                let record = ConversionRecord(source: input, target: target.uppercased())
                records.insert(record, at: 0); activityIDs.append(record.id); onProgress?()
                do { try await engine.convert(source: input, destination: output, target: target); complete(record.id, destination: output) }
                catch { complete(record.id, error: error) }
            }
        }
    }
    func prepareTool(_ id: String, urls: [URL]? = nil) {
        guard !busy else { return }
        let inputs = urls ?? files
        guard let tool = FileToolEngine.tools(for: inputs).first(where: { $0.id == id }) else { message = "This tool is unavailable for the selection."; return }
        let request = ToolRequest(tool: tool, files: inputs)
        if request.fields.isEmpty || id == "compress" {
            let isImageCompression = id == "compress" && inputs.first.map(FileToolEngine.isImageCompressionSource) == true
            let defaults = id == "compress" && !isImageCompression ? Dictionary(uniqueKeysWithValues: request.fields.map { ($0.id, $0.initial) }) : [:]
            runTool(id, urls: inputs, parameters: defaults)
        }
        else { pendingTool = request }
    }
    func runTool(_ id: String, urls: [URL], parameters: [String: String]) {
        guard !busy, let first = urls.first, let tool = FileToolEngine.tools(for: urls).first(where: { $0.id == id }) else { return }
        let output = uniqueOutput(first, ext: FileToolEngine.outputExtension(for: id, source: first), label: tool.title)
        let record = ConversionRecord(source: first, target: tool.title)
        records.insert(record, at: 0)
        busy = true; message = nil; activityIDs = [record.id]; onProgress?()
        Task { @MainActor in
            defer { busy = false; onProgress?() }
            do {
                try await toolEngine.perform(id, sources: urls, destination: output, parameters: parameters)
                var note: String?
                if id == "compress", FileToolEngine.isImageCompressionSource(first),
                   let originalBytes = try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   let resultBytes = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   originalBytes > 0 {
                    note = resultBytes >= originalBytes ? "Already optimized · unchanged copy" : String(Int((1 - Double(resultBytes) / Double(originalBytes)) * 100)) + "% smaller · " + output.pathExtension.uppercased()
                }
                complete(record.id, destination: output, note: note)
                if id == "readQRCode", let text = try? String(contentsOf: output, encoding: .utf8) { message = "QR codes: " + String(text.prefix(1200)) }
            } catch { complete(record.id, error: error) }
        }
    }
    func copyOrMove(_ move: Bool, urls: [URL], folder: URL) {
        guard !busy, !urls.isEmpty else { return }
        busy = true; message = nil; activityIDs = []
        Task { @MainActor in
            defer { busy = false; onProgress?() }
            for input in urls {
                let output = availableURL(in: folder, name: input.lastPathComponent)
                let record = ConversionRecord(source: input, target: move ? "Move" : "Copy")
                records.insert(record, at: 0); activityIDs.append(record.id); onProgress?()
                do {
                    try await Task.detached(priority: .userInitiated) {
                        if move { try FileManager.default.moveItem(at: input, to: output) }
                        else { try FileManager.default.copyItem(at: input, to: output) }
                    }.value
                    complete(record.id, destination: output)
                    if move, let index = files.firstIndex(of: input) { files[index] = output }
                } catch { complete(record.id, error: error) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    var window: NSWindow?
    var settingsWindow: NSWindow?
    var configurationWindow: NSPanel?
    var diagnosticsWindow: NSWindow?
    var statusItem: NSStatusItem!
    var wheel: NSPanel?
    private(set) var wheelPanels: [WheelPanel] = []
    private(set) var wheelGeneration = 0
    private var wheelActivity: NSObjectProtocol?
    var feedbackPanel: NSPanel?
    var feedbackClose: DispatchWorkItem?
    var floatingPanel: NSPanel?
    var floatingView: FloatingFilesView?
    var sharingService: NSSharingService?
    var dragMonitor: DragGestureMonitor?
    var lastGesturePoint: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenus()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Flower")
        statusItem.button?.contentTintColor = .systemOrange
        statusItem.button?.toolTip = "Drag a file · ⇧ Formats / PDF · ⌘ AirDrop / Compress · ⌃ Actions"
        statusItem.menu = statusMenu()
        model.onProgress = { [weak self] in self?.refreshProgress() }
        dragMonitor = DragGestureMonitor(onMode: { [weak self] urls, mode, point in
            guard let self, !self.model.busy else { return }
            self.showWheel(urls, mode: mode, at: point)
            self.model.log("Drag + " + mode.rawValue + " · " + String(urls.count) + " file(s)")
        }, onEnded: { [weak self] in
            self?.endWheelGesture()
        })
        dragMonitor?.onTrace = { [weak self] trace in self?.model.log(trace) }
        dragMonitor?.start()
        model.log("Ready · hold ⇧ / ⌘ / ⌃ while dragging a local file")
    }
    func applicationWillTerminate(_ notification: Notification) { dragMonitor?.stop(); dismissWheel() }
    func setupMenus() {
        let main = NSMenu(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Flower", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Gesture Diagnostics…", action: #selector(diagnostics), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Flower", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    func statusMenu() -> NSMenu {
        let menu = NSMenu()
        for title in ["Drag a file, then hold:", "⇧  Formats and PDF", "⌘  AirDrop and Compress", "⌃  File actions", "Drop onto an option to run it"] { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Recent Results…", action: #selector(showMain), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "")
        menu.addItem(withTitle: "Gesture Diagnostics…", action: #selector(diagnostics), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Flower", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in menu.items { item.target = item.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        return menu
    }
    @objc func showMain() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Recent Results"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: RecentResultsView(model: model)); panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func diagnostics() {
        if diagnosticsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Gesture Diagnostics"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: GestureDiagnosticsView(model: model)); panel.center(); diagnosticsWindow = panel
        }
        diagnosticsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Flower · وردة", .applicationVersion: "0.2.4", .credits: NSAttributedString(string: "Local reconstruction based on inspected Tangerine 2.0.2 behavior.")]) }
    @objc func settings() {
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Flower Settings"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SettingsView()); panel.center(); settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        showWheel(filenames.map { URL(fileURLWithPath: $0) }, mode: .convert, at: nil)
        sender.reply(toOpenOrPrint: .success)
    }
    static func wheelItems(for urls: [URL], mode: WorkMode) -> [WheelItem] {
        guard let first = urls.first, urls.allSatisfy(\.isFileURL) else { return [] }
        switch mode {
        case .convert:
            var formats = ConversionEngine.targets(for: first.pathExtension.lowercased()).filter { target in urls.dropFirst().allSatisfy { ConversionEngine.targets(for: $0.pathExtension.lowercased()).contains(target) } }
            if FileToolEngine.tools(for: urls).contains(where: { $0.id == "createPDF" }), !formats.contains("pdf") {
                formats.append("pdf")
            }
            return formats.map { WheelItem(id: $0, title: $0.uppercased()) }
        case .tools:
            var items = [WheelItem(id: FileAction.airDrop.id, title: FileAction.airDrop.title)]
            if FileToolEngine.tools(for: urls).contains(where: { $0.id == "compress" }) {
                items.append(WheelItem(id: "compress", title: "Compress"))
            }
            return items
        case .actions:
            return FileAction.allCases.filter { $0 != .airDrop }.map { WheelItem(id: $0.id, title: $0.title) }
        }
    }
    func showWheel(_ urls: [URL], mode: WorkMode, at position: NSPoint?) {
        guard !model.busy, !urls.isEmpty else { return }
        let items = Self.wheelItems(for: urls, mode: mode)
        lastGesturePoint = position ?? NSEvent.mouseLocation
        guard !items.isEmpty else {
            dismissWheel()
            showMessage("No " + mode.rawValue.lowercased() + " available for these files.")
            return
        }
        feedbackPanel?.orderOut(nil); dismissWheel()
        wheelGeneration += 1
        let generation = wheelGeneration
        let panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 372), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = false; panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue: 101)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let byteCount = urls.reduce(Int64(0)) { total, url in total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let centerLabel = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        let view = WheelView(items: items, centerTitle: centerLabel, observedURLs: urls) { [weak self] id, dropped in
            guard let self, self.wheelGeneration == generation, self.wheel != nil else { return }
            self.dragMonitor?.cancelCurrentDrag(); self.dismissWheel(generation: generation)
            DispatchQueue.main.async { [weak self] in self?.dispatchWheel(id: id, urls: dropped, mode: mode, at: position) }
        }
        let cancel = { [weak self] in
            guard let self, self.wheelGeneration == generation, self.wheel != nil else { return }
            self.dragMonitor?.cancelCurrentDrag(); self.dismissWheel(generation: generation)
        }
        view.cancelled = cancel
        let point = position ?? NSEvent.mouseLocation
        wheel = panel; wheelPanels = [panel]
        if position != nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            // A continuous, faintly dimmed surface owns this file drag. Clear
            // gaps in the wheel no longer expose Finder or another destination.
            panel.setFrame(screen.frame, display: false)
            let capture = WheelDragCaptureView(frame: NSRect(origin: .zero, size: screen.frame.size), wheel: view, cancelled: cancel)
            let wheelScreenFrame = Self.wheelFrame(near: point, in: screen.visibleFrame)
            view.frame = wheelScreenFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            panel.contentView = capture
            for other in NSScreen.screens where other !== screen {
                let shield = WheelPanel(contentRect: other.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                shield.isReleasedWhenClosed = false; shield.hidesOnDeactivate = false
                shield.isOpaque = false; shield.backgroundColor = .clear; shield.hasShadow = false
                shield.ignoresMouseEvents = false; shield.animationBehavior = .none
                shield.level = panel.level; shield.collectionBehavior = panel.collectionBehavior
                shield.contentView = WheelDragCaptureView(frame: NSRect(origin: .zero, size: other.frame.size), wheel: nil, cancelled: cancel)
                wheelPanels.append(shield)
            }
            wheelActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Track a Flower file drag")
            for capturePanel in wheelPanels { capturePanel.orderFrontRegardless() }
            panel.makeFirstResponder(capture)
            view.beginPresentedDragTracking(atScreenPoint: point)
        } else {
            panel.contentView = view
            place(panel, near: point, centered: true)
            panel.makeFirstResponder(view); panel.makeKeyAndOrderFront(nil)
        }
    }
    static func wheelFrame(near point: NSPoint, in available: NSRect) -> NSRect {
        let size = CGFloat(372)
        return NSRect(x: max(available.minX, min(point.x - size / 2, available.maxX - size)),
                      y: max(available.minY, min(point.y - size / 2, available.maxY - size)),
                      width: size, height: size)
    }
    func endWheelGesture() {
        // Leave the destination alive for AppKit's final drop callback. A late
        // mouse-up from this gesture must never close a newer presentation.
        let generation = wheelGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.dismissWheel(generation: generation)
        }
    }
    func dismissWheel(generation: Int? = nil) {
        guard generation == nil || generation == wheelGeneration else { return }
        for panel in wheelPanels {
            if let capture = panel.contentView as? WheelDragCaptureView { capture.wheel?.cancelDragTracking() }
            else if let view = panel.contentView as? WheelView { view.cancelDragTracking() }
            panel.orderOut(nil)
            panel.close()
        }
        wheelPanels = []; wheel = nil
        if let activity = wheelActivity { ProcessInfo.processInfo.endActivity(activity); wheelActivity = nil }
    }
    func dispatchWheel(id: String, urls: [URL], mode: WorkMode, at point: NSPoint?) {
        guard !model.busy, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return }
        configurationWindow?.orderOut(nil); model.pendingTool = nil
        dragMonitor?.cancelCurrentDrag(); dismissWheel()
        lastGesturePoint = point ?? NSEvent.mouseLocation
        model.accept(urls); model.mode = mode
        model.log("Drop → " + mode.rawValue + " / " + id + " · " + String(urls.count) + " file(s)")
        guard Self.wheelItems(for: urls, mode: mode).contains(where: { $0.id == id }) else {
            showMessage("That option is unavailable for the dropped files."); return
        }
        switch mode {
        case .convert:
            model.selectedFormat = id
            if id == "pdf", FileToolEngine.tools(for: urls).contains(where: { $0.id == "createPDF" }) {
                model.prepareTool("createPDF", urls: urls)
            } else { model.convert(id, urls: urls) }
        case .tools:
            if id == FileAction.airDrop.id {
                model.selectedAction = .airDrop; performAction(.airDrop, urls: urls)
            } else {
                model.selectedTool = id; model.prepareTool(id, urls: urls)
                if let request = model.pendingTool { presentConfiguration(request) }
                else if let message = model.message { showMessage(message) }
            }
        case .actions:
            if let action = FileAction(rawValue: id) { model.selectedAction = action; performAction(action, urls: urls) }
        }
    }
    func presentConfiguration(_ request: ToolRequest) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 522, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = request.tool.title; panel.isReleasedWhenClosed = false; panel.delegate = self
        let view = NSHostingView(rootView: ToolConfigurationView(request: request, run: { [weak self, weak panel] values in
            panel?.orderOut(nil); self?.model.pendingTool = nil
            self?.model.runTool(request.tool.id, urls: request.files, parameters: values)
        }, cancel: { [weak self, weak panel] in panel?.orderOut(nil); self?.model.pendingTool = nil }))
        panel.contentView = view; panel.setContentSize(view.fittingSize); panel.center()
        configurationWindow = panel; panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === configurationWindow { model.pendingTool = nil }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { settings() }; return true
    }
    func refreshProgress() {
        guard statusItem != nil else { return }
        statusItem.button?.contentTintColor = model.busy ? .secondaryLabelColor : .systemOrange
        feedbackClose?.cancel()
        let active = model.records.filter { model.activityIDs.contains($0.id) }
        guard !active.isEmpty else { return }
        let panel = makeFeedbackPanel()
        panel.contentView = NSHostingView(rootView: OperationFeedbackView(model: model, dismiss: { [weak self] in self?.feedbackPanel?.orderOut(nil) }))
        place(panel, near: lastGesturePoint ?? NSEvent.mouseLocation, centered: false)
        panel.orderFrontRegardless()
        if !model.busy && !active.contains(where: { $0.error != nil }) { closeFeedback(after: 5) }
    }
    func showMessage(_ text: String) {
        guard statusItem != nil else { return }
        model.log(text)
        let panel = makeFeedbackPanel()
        panel.contentView = NSHostingView(rootView: MessageFeedbackView(text: text, dismiss: { [weak self] in self?.feedbackPanel?.orderOut(nil) }))
        place(panel, near: lastGesturePoint ?? NSEvent.mouseLocation, centered: false)
        panel.orderFrontRegardless(); closeFeedback(after: 5)
    }
    private func makeFeedbackPanel() -> NSPanel {
        feedbackClose?.cancel()
        if let feedbackPanel { return feedbackPanel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 310, height: 86), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.level = .floating; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        feedbackPanel = panel; return panel
    }
    private func closeFeedback(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in self?.feedbackPanel?.orderOut(nil) }
        feedbackClose = work; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func place(_ panel: NSPanel, near point: NSPoint, centered: Bool) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame, size = panel.frame.size
        let x = point.x - size.width / 2, y = point.y - (centered ? size.height / 2 : size.height + 30)
        panel.setFrameOrigin(NSPoint(x: min(max(x, visible.minX), visible.maxX - size.width), y: min(max(y, visible.minY), visible.maxY - size.height)))
    }
    func performAction(_ action: FileAction, urls: [URL]) {
        guard !model.busy, !urls.isEmpty else { return }
        model.message = nil
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { showMessage("AirDrop is unavailable for these files on this Mac."); return }
            sharingService = service
            service.perform(withItems: urls)
            model.message = "AirDrop opened. Choose a recipient in its window."
        case .float:
            if floatingPanel == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
                panel.title = "Floating Files"; panel.isReleasedWhenClosed = false; panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = FloatingFilesView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
                panel.contentView = view; panel.center(); floatingPanel = panel; floatingView = view
            }
            floatingView?.urls = urls; floatingPanel?.makeKeyAndOrderFront(nil)
        case .copy, .move:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Choose where to \(action == .move ? "move" : "copy") \(urls.count == 1 ? urls[0].lastPathComponent : "these files"). Name conflicts receive a numbered suffix."
            panel.prompt = action == .move ? "Move Here" : "Copy Here"
            if panel.runModal() == .OK, let folder = panel.url { model.copyOrMove(action == .move, urls: urls, folder: folder) }
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            showMessage(urls.count == 1 ? "File path copied." : "\(urls.count) file paths copied.")
        case .terminal:
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { showMessage("Terminal could not be found."); return }
            var seen = Set<URL>()
            let folders = urls.map { $0.deletingLastPathComponent() }.filter { seen.insert($0).inserted }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in self?.showMessage(error.map { "Terminal: " + $0.localizedDescription } ?? "Opened the containing folders in Terminal.") }
            }
        }
    }
}

struct RecentResultsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drag a file · ⇧ Formats / PDF · ⌘ AirDrop / Compress").font(.callout).foregroundStyle(.secondary)
            if model.records.isEmpty { Spacer(); Text("Your results will appear here.").foregroundStyle(.secondary); Spacer() }
            else { List(model.records) { record in
                HStack {
                    if record.running { ProgressView().controlSize(.small) }
                    else { Image(systemName: record.error == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(record.error == nil ? Color.green : Color.red) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.source.lastPathComponent + " → " + record.target).lineLimit(1)
                        if let note = record.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        if let error = record.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }
                    Spacer()
                    if let url = record.destination { Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small) }
                }.padding(.vertical, 4)
            }.listStyle(.inset) }
        }.padding(18).frame(minWidth: 420, minHeight: 260)
    }
}

struct GestureDiagnosticsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag → modifier → drop → result").font(.headline)
            Text("Hold Shift for formats and PDF, Command for AirDrop and Compress, or Control for file actions. A drop onto the wheel starts the operation.").font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(model.diagnostics.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20)
    }
}

struct OperationFeedbackView: View {
    @ObservedObject var model: AppModel
    var dismiss: () -> Void
    var active: [ConversionRecord] { model.records.filter { model.activityIDs.contains($0.id) } }
    var body: some View {
        HStack(spacing: 12) {
            if model.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: active.contains { $0.error != nil } ? "exclamationmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(active.contains { $0.error != nil } ? Color.orange : Color.green) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.busy ? "Working…" : active.contains { $0.error != nil } ? "Couldn’t finish" : (active.first?.note ?? "Done")).font(.system(size: 12, weight: .semibold))
                if let record = active.first {
                    if let error = record.error { Text(error).font(.system(size: 10)).lineLimit(3).help(error) }
                    else if !model.busy, let destination = record.destination {
                        Button(active.count == 1 ? destination.lastPathComponent : "Show \(active.count) results") { NSWorkspace.shared.activateFileViewerSelecting(active.compactMap(\.destination)) }.buttonStyle(.link).font(.system(size: 11)).lineLimit(1)
                    } else { Text(record.source.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
        }.padding(16).frame(width: 310, height: 86).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.25)))
    }
}
struct MessageFeedbackView: View {
    let text: String
    var dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) { Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0); Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).accessibilityLabel("Dismiss") }
            .padding(16).frame(width: 310, height: 86).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct ToolConfigurationView: View {
    let request: ToolRequest
    let run: ([String: String]) -> Void
    let cancel: () -> Void
    @State private var values: [String: String]
    init(request: ToolRequest, run: @escaping ([String: String]) -> Void, cancel: @escaping () -> Void) {
        self.request = request; self.run = run; self.cancel = cancel
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: request.fields.map { ($0.id, $0.initial) }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.tool.title).font(.title2.weight(.semibold))
            Text(request.files.count == 1 ? request.files[0].lastPathComponent : "\(request.files.count) selected files").foregroundStyle(.secondary).lineLimit(2)
            Form { ForEach(request.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    if field.choices.isEmpty {
                        HStack { Text(field.title); Spacer(); TextField(field.required ? "Required" : field.initial, text: Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })).textFieldStyle(.roundedBorder).frame(width: 180) }
                    } else {
                        Picker(field.title, selection: Binding(get: { values[field.id] ?? field.initial }, set: { values[field.id] = $0 })) { ForEach(field.choices, id: \.self) { Text($0.capitalized).tag($0) } }
                    }
                    if !field.hint.isEmpty { Text(field.hint).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            } }
            Text(request.note).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction); Button("Create Result") { run(values) }.buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut(.defaultAction).disabled(request.fields.contains { $0.required && (values[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
        }.padding(26).frame(width: 470)
    }
}

final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: URL] = [:]
    func add(_ url: URL, at index: Int) { lock.lock(); items[index] = url; lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items.sorted { $0.key < $1.key }.map(\.value) }
}

struct SettingsView: View {
    @AppStorage("localGlassStyle") var glass = true
    @AppStorage("localSound") var sound = true
    var body: some View {
        TabView {
            Form {
                Section("Appearance") { Picker("Wheel style", selection: $glass) { Text("Glass").tag(true); Text("Solid").tag(false) }.pickerStyle(.segmented) }
                Section("General") {
                    Toggle("Sound and haptic feedback on wheel selection", isOn: $sound)
                    LabeledContent("Formats and PDF", value: "⇧ Shift")
                    LabeledContent("AirDrop and Compress", value: "⌘ Command")
                    LabeledContent("Actions wheel", value: "⌃ Control")
                    Text("Drop on PDF to create a PDF from your images. Command shows AirDrop and, when available, Compress. Results appear beside the source.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Results") { Text("Conversion and tool results are saved beside their originals. Copy and Move let you choose a folder. Name conflicts receive a numbered suffix.").foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            VStack(alignment: .leading, spacing: 12) { Text("Available formats").font(.title2); Text("Hold Shift while dragging files to choose an output format. Images include PDF; dropping multiple images on PDF creates one document. Hold Command for AirDrop or supported compression.").foregroundStyle(.secondary); Text("Images · Documents · Spreadsheets · Audio · Video · Subtitles · Archives"); Spacer() }.padding(30).tabItem { Label("Formats", systemImage: "slider.horizontal.3") }
            VStack(spacing: 12) { Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle).foregroundStyle(.orange); Text("Flower · وردة").font(.title); Text("Local reconstruction · 0.2.4").foregroundStyle(.secondary); Text("Built from static analysis, recovered resource contracts, and controlled converter tests. See the coverage report for verified behavior and remaining differences.").multilineTextAlignment(.center).frame(maxWidth: 440) }.frame(maxWidth: .infinity, maxHeight: .infinity).tabItem { Label("About", systemImage: "info.circle") }
        }.padding(16).frame(width: 660, height: 450)
    }
}

struct WheelItem { let id: String; let title: String; var fullTitle: String? = nil }

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A reusable local file shelf. Drag-out writes file URLs, never file contents to
/// another service. The destination app/user decides what to do with those URLs.
@MainActor
final class FloatingFilesView: NSView, NSDraggingSource {
    var urls: [URL] = [] { didSet { needsDisplay = true; setAccessibilityLabel("Floating files: " + urls.map(\.lastPathComponent).joined(separator: ", ")) } }
    private var dragStart: NSPoint?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(true) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { dragStart = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, !urls.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        dragStart = nil
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(NSRect(x: point.x + CGFloat(min(index, 5)) * 4, y: point.y, width: 48, height: 48), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .link] }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard let first = urls.first else { return }
        let icon = NSWorkspace.shared.icon(forFile: first.path)
        icon.draw(in: NSRect(x: bounds.midX - 28, y: bounds.height - 74, width: 56, height: 56))
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingMiddle
        let title = (urls.count == 1 ? first.lastPathComponent : "\(urls.count) files") as NSString
        title.draw(in: NSRect(x: 14, y: 65, width: bounds.width - 28, height: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        ("Drag files from here" as NSString).draw(in: NSRect(x: 14, y: 31, width: bounds.width - 28, height: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
    }
}
