import AppKit
import SwiftUI
import QuartzCore

/// AppKit owns the drag destination and immediate hover paint. SwiftUI renders
/// the static glass, so drag feedback does not await a SwiftUI render pass.
@MainActor
final class WheelView: NSView {
    let items: [WheelItem]
    let centerTitle: String
    let selected: (String, [URL]) -> Void
    var cancelled: (() -> Void)?
    private let observedURLs: [URL]
    private(set) var highlightedIndex: Int?
    private let readFileURLs: (NSPasteboard) -> [URL]
    private var cachedDrag: (sequence: Int, name: NSPasteboard.Name, change: Int, urls: [URL])?
    private var cachedPaths: [Path] = []
    private var pathBounds: CGRect = .null
    private var cursorTimer: Timer?
    private(set) var isPresentationTracking = false
    private struct DragIdentity: Hashable {
        let sequence: Int
        let pasteboardName: String
    }
    private var committedDrags: Set<DragIdentity> = []
    private var highlightOverlay: WheelHighlightOverlay!
    private var tracking: NSTrackingArea?
    private var hosting: NSHostingView<NativeWheelContent>?
    private var lastFeedback = Date.distantPast
    private let feedbackSound: NSSound?

    init(items: [WheelItem], centerTitle: String, observedURLs: [URL] = [], readFileURLs: ((NSPasteboard) -> [URL])? = nil, selected: @escaping (String, [URL]) -> Void) {
        self.items = items
        self.centerTitle = centerTitle
        self.observedURLs = observedURLs
        self.readFileURLs = readFileURLs ?? Self.fileURLs
        self.feedbackSound = Bundle.main.url(forResource: "HighlightSound", withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: false) }
        self.selected = selected
        super.init(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let content = NativeWheelContent(items: items)
        let view = NSHostingView(rootView: content)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        hosting = view
        let overlay = WheelHighlightOverlay(items: items, centerTitle: centerTitle)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        highlightOverlay = overlay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(centerTitle + " wheel")
        setAccessibilityHelp("Drop files on " + items.map { $0.fullTitle ?? $0.title }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }
    deinit { cursorTimer?.invalidate() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endHover() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidHide() { super.viewDidHide(); endHover() }

    // Keep AppKit in charge of every pointer/drag event. The hosting subtree
    // must not become a second drag destination or swallow mouse presses.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    /// Use the same rounded native path for painting and hit testing, including
    /// its 4pt gaps. A drop in the central hole or gap never chooses a neighbor.
    func slot(_ point: NSPoint) -> Int? {
        let swiftUIPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        if pathBounds != bounds {
            cachedPaths = items.indices.map { Self.shape(index: $0, count: items.count, expanded: true).path(in: bounds) }
            pathBounds = bounds
        }
        return cachedPaths.firstIndex { $0.contains(swiftUIPoint) }
    }

    static func shape(index: Int, count: Int, expanded: Bool) -> RecoveredPetalShape {
        let sector = 2 * Double.pi / Double(max(count, 1))
        let origin = count == 3 ? Double.pi : Double.pi / 2
        return RecoveredPetalShape(centerAngle: origin - Double(index) * sector,
                                   sectorAngle: sector, gapWidth: expanded ? 4 : 0,
                                   innerRadius: expanded ? 48.64 : 0,
                                   outerRadius: expanded ? 119.52 : 50.4)
    }

    private func updateHighlight(_ index: Int?) {
        guard highlightedIndex != index else { return }
        highlightedIndex = index
        highlightOverlay.setHighlight(index)
        setAccessibilityValue(index.map { items[$0].fullTitle ?? items[$0].title } ?? centerTitle)
        if index != nil, UserDefaults.standard.object(forKey: "localSound") as? Bool ?? true,
           Date().timeIntervalSince(lastFeedback) > 0.08 {
            feedbackSound?.stop()
            feedbackSound?.play()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            lastFeedback = Date()
        }
    }

    private func hoverURLs(_ sender: NSDraggingInfo) -> [URL] {
        let board = sender.draggingPasteboard
        let count = board.changeCount
        if let cachedDrag, cachedDrag.sequence == sender.draggingSequenceNumber,
           cachedDrag.name == board.name, cachedDrag.change == count { return cachedDrag.urls }
        let urls = readFileURLs(board)
        cachedDrag = (sender.draggingSequenceNumber, board.name, count, urls)
        return urls
    }

    /// A continuous capture surface may advertise copy for this valid payload
    /// even over the central hole. AppKit only calls prepare/drop after an
    /// accepted update; the actual release petal is still checked at that time.
    func acceptsDrag(_ sender: NSDraggingInfo) -> Bool { !hoverURLs(sender).isEmpty }

    private func beginCursorSampling() {
        guard cursorTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCursor() }
        }
        timer.tolerance = 0.001
        cursorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The app has already observed an active file drag when it presents this
    /// wheel. Start pointer tracking now, without waiting for AppKit to enter
    /// a newly ordered or transparent destination window. Observed URLs only
    /// authorize hover; they are never used by the native drop callback.
    func beginPresentedDragTracking(atScreenPoint point: NSPoint? = nil) {
        guard observedURLs.contains(where: \.isFileURL), window != nil else { return }
        isPresentationTracking = true
        beginCursorSampling()
        updateHighlight(slotAtScreenPoint(point ?? NSEvent.mouseLocation))
    }

    func cancelDragTracking() { endHover() }

    private func slotAtScreenPoint(_ point: NSPoint) -> Int? {
        guard let window else { return nil }
        return slot(convert(window.convertPoint(fromScreen: point), from: nil))
    }

    /// Explicit input state makes the pre-entry cursor path independently
    /// testable without synthesizing system mouse events or yielding to AppKit.
    func updateTrackedCursor(atScreenPoint point: NSPoint, primaryButtonDown: Bool, surfaceVisible: Bool) {
        guard surfaceVisible, primaryButtonDown,
              isPresentationTracking || cachedDrag?.urls.isEmpty == false else {
            endHover(); return
        }
        updateHighlight(slotAtScreenPoint(point))
    }

    // Drag sources do not promise one destination callback per pointer frame.
    // This tracking-mode timer samples only coordinates, never files/pasteboard.
    private func sampleCursor() {
        updateTrackedCursor(atScreenPoint: NSEvent.mouseLocation,
                            primaryButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
                            surfaceVisible: window?.isVisible == true && !isHiddenOrHasHiddenAncestor)
    }

    private func endHover() {
        cursorTimer?.invalidate(); cursorTimer = nil
        cachedDrag = nil
        isPresentationTracking = false
        updateHighlight(nil)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = DragGestureMonitor.fileURLs(from: pasteboard)
        var seen = Set<URL>()
        return urls.filter { url in
            url.isFileURL && FileManager.default.fileExists(atPath: url.path) && seen.insert(url.standardizedFileURL).inserted
        }
    }

    override func mouseMoved(with event: NSEvent) { updateHighlight(slot(convert(event.locationInWindow, from: nil))) }
    override func mouseDragged(with event: NSEvent) { updateHighlight(slot(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { updateHighlight(nil) }
    override func mouseDown(with event: NSEvent) {
        guard let index = slot(convert(event.locationInWindow, from: nil)), !observedURLs.isEmpty else { cancelled?(); return }
        selected(items[index].id, observedURLs)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { endHover(); cancelled?() }
        if event.keyCode == 36, let index = highlightedIndex, !observedURLs.isEmpty { selected(items[index].id, observedURLs) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        cachedDrag = nil
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender, atScreenPoint: screenPoint(for: sender))
    }
    private func screenPoint(for sender: NSDraggingInfo) -> NSPoint {
        (sender.draggingDestinationWindow ?? window)?.convertPoint(toScreen: sender.draggingLocation) ?? sender.draggingLocation
    }
    /// Capture surfaces may be a parent view or another window. Forward an
    /// explicit global point so neither case depends on the wheel's offset.
    func updateDrag(_ sender: NSDraggingInfo, atScreenPoint point: NSPoint) -> NSDragOperation {
        guard !hoverURLs(sender).isEmpty else { endHover(); return [] }
        beginCursorSampling()
        updateHighlight(slotAtScreenPoint(point))
        // The original returns raw operation 1 (.copy) for every valid petal
        // (0x1000610a4, return at 0x100061108). Do not intersect with a mask
        // filtered by Command/Control: those keys select our wheel mode, and
        // returning .move could ask a source application to remove its data.
        return highlightedIndex == nil ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        cachedDrag = nil
        updateHighlight(nil)
        // Presentation-wide tracking must survive a transparent gap, child
        // destination exit or capture-view handoff until release/hide/cancel.
        if !isPresentationTracking { endHover() }
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { endHover() }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { endHover() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        prepareDrag(sender, atScreenPoint: screenPoint(for: sender))
    }
    func prepareDrag(_ sender: NSDraggingInfo, atScreenPoint point: NSPoint) -> Bool {
        slotAtScreenPoint(point) != nil && !readFileURLs(sender.draggingPasteboard).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performDrag(sender, atScreenPoint: screenPoint(for: sender))
    }
    func performDrag(_ sender: NSDraggingInfo, atScreenPoint point: NSPoint) -> Bool {
        defer { endHover() }
        let identity = DragIdentity(sequence: sender.draggingSequenceNumber, pasteboardName: sender.draggingPasteboard.name.rawValue)
        guard let index = slotAtScreenPoint(point) else { return false }
        let urls = readFileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        // A capture parent and child can both receive the same session's drop.
        // Revalidate it, then acknowledge without running the action twice.
        if committedDrags.contains(identity) { return true }
        committedDrags.insert(identity)
        selected(items[index].id, urls)
        return true
    }
}

/// Hover paint stays in AppKit's drag-tracking loop. It never rebuilds the
/// SwiftUI glass hierarchy, and changes are drawn without implicit animation.
@MainActor
final class WheelHighlightOverlay: NSView {
    let items: [WheelItem]
    let centerTitle: String
    private(set) var highlight: Int?
    private let centerLabel = NSTextField(labelWithString: "")
    private var glass: Bool { UserDefaults.standard.object(forKey: "localGlassStyle") as? Bool ?? true }
    override var isFlipped: Bool { true }

    init(items: [WheelItem], centerTitle: String) {
        self.items = items; self.centerTitle = centerTitle
        super.init(frame: .zero)
        wantsLayer = true
        centerLabel.alignment = .center
        centerLabel.maximumNumberOfLines = 0
        (centerLabel.cell as? NSTextFieldCell)?.wraps = true
        (centerLabel.cell as? NSTextFieldCell)?.isScrollable = false
        alphaValue = 1
        addSubview(centerLabel)
        updateCenterLabel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); updateCenterLabel() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateCenterLabel(); needsDisplay = true }
    func setHighlight(_ index: Int?) {
        guard highlight != index else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit(); CATransaction.flush() }
        highlight = index
        layer?.removeAllAnimations()
        alphaValue = 1
        updateCenterLabel()
        needsDisplay = true
        // Native drawing is synchronous here even in NSEventTrackingRunLoopMode.
        displayIfNeeded()
        centerLabel.displayIfNeeded()
    }
    private func updateCenterLabel() {
        let text = highlight.map { items[$0].fullTitle ?? items[$0].title } ?? centerTitle
        let long = text.count > 12
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        centerLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: long ? 7.5 : 10, weight: long ? .semibold : .medium),
            .kern: long ? 0.2 : 0.35, .foregroundColor: glass ? NSColor.labelColor : NSColor.white,
            .paragraphStyle: paragraph
        ])
        let height = min(56, ceil(centerLabel.attributedStringValue.boundingRect(with: NSSize(width: 72, height: 56), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2)
        centerLabel.frame = CGRect(x: bounds.midX - 36, y: bounds.midY - height / 2, width: 72, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Reuse of the transparent backing must erase the previous petal.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        if let highlight { drawPetal(highlight) }
        for index in items.indices { drawLabel(index, highlighted: index == highlight) }
    }
    private func drawPetal(_ highlight: Int) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = WheelView.shape(index: highlight, count: items.count, expanded: true).path(in: bounds).cgPath
        context.saveGState()
        context.addPath(path); context.clip()
        if glass {
            let orange = NSColor.systemOrange
            let colors = [(orange.blended(withFraction: 0.42, of: .white) ?? orange).withAlphaComponent(0.98), orange.withAlphaComponent(0.96), NSColor(red: 0.92, green: 0.30, blue: 0.04, alpha: 0.94)]
            let gradient = CGGradient(colorsSpace: nil, colors: colors.map(\.cgColor) as CFArray, locations: [0.2, 0.56, 1])!
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: bounds.midX, y: bounds.midY), startRadius: 40, endCenter: CGPoint(x: bounds.midX, y: bounds.midY), endRadius: 126, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            let gradient = CGGradient(colorsSpace: nil, colors: [NSColor(white: 150.0 / 255, alpha: 1).cgColor, NSColor(white: 224.0 / 255, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.minY), end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
        }
        context.restoreGState()
        if glass {
            context.addPath(path); context.setStrokeColor(NSColor.black.withAlphaComponent(0.1).cgColor); context.setLineWidth(0.75); context.strokePath()
        } else {
            context.saveGState(); context.addPath(path); context.setLineWidth(1.5); context.replacePathWithStrokedPath(); context.clip()
            let gradient = CGGradient(colorsSpace: nil, colors: [NSColor.white.cgColor, NSColor(white: 70.0 / 255, alpha: 1).cgColor, NSColor.white.cgColor] as CFArray, locations: [0, 0.485577, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.minY), end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
            context.restoreGState()
        }
    }
    private func drawLabel(_ index: Int, highlighted: Bool) {
        let angle = (items.count == 3 ? Double.pi : Double.pi / 2) - Double(index) * 2 * Double.pi / Double(max(items.count, 1))
        let point = CGPoint(x: bounds.midX + cos(angle) * 84.5312, y: bounds.midY - sin(angle) * 84.5312)
        let item = items[index]
        let foreground = glass ? (highlighted ? NSColor.white : NSColor.labelColor) : (highlighted ? NSColor.black : NSColor.white)
        let symbol = NativeWheelContent.symbol(for: item.id)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let label = NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: symbol == nil ? 12 : 7.5, weight: .semibold), .kern: symbol == nil ? 0.35 : 0.2, .foregroundColor: foreground, .paragraphStyle: paragraph])
        let height = ceil(label.boundingRect(with: NSSize(width: 82, height: 44), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        var textY = point.y - height / 2
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12.6, weight: .medium).applying(.init(paletteColors: [foreground]))) {
            let startY = point.y - (image.size.height + 3 + height) / 2
            image.draw(in: CGRect(x: point.x - image.size.width / 2, y: startY, width: image.size.width, height: image.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textY = startY + image.size.height + 3
        }
        label.draw(with: CGRect(x: point.x - 41, y: textY, width: 82, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

/// Transcribed annulus dimensions from NativeFanDiskShape state. Even-odd
/// filling leaves the file-size/center label genuinely transparent.
struct RecoveredFanDiskShape: Shape {
    var innerRadius: Double
    var outerRadius: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { .init(innerRadius, outerRadius) }
        set { innerRadius = newValue.first; outerRadius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.midX - outerRadius, y: rect.midY - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
        if innerRadius > 0 {
            // Reversed inner contour makes the glass mask an annulus too.
            path.addPath(Path(CGPath(ellipseIn: CGRect(x: rect.midX - innerRadius, y: rect.midY - innerRadius, width: innerRadius * 2, height: innerRadius * 2), transform: nil)).reversedPath)
        }
        return path
    }
}

private extension Path {
    var reversedPath: Path {
        var result = Path()
        // This helper is used only with a circle. Four cubic segments retain the
        // reverse winding instead of relying on a fill rule unavailable to glass.
        let rect = boundingRect, x = rect.midX, y = rect.midY, r = rect.width / 2
        let k = r * 0.5522847498307936
        result.move(to: CGPoint(x: x + r, y: y))
        result.addCurve(to: CGPoint(x: x, y: y - r), control1: CGPoint(x: x + r, y: y - k), control2: CGPoint(x: x + k, y: y - r))
        result.addCurve(to: CGPoint(x: x - r, y: y), control1: CGPoint(x: x - k, y: y - r), control2: CGPoint(x: x - r, y: y - k))
        result.addCurve(to: CGPoint(x: x, y: y + r), control1: CGPoint(x: x - r, y: y + k), control2: CGPoint(x: x - k, y: y + r))
        result.addCurve(to: CGPoint(x: x + r, y: y), control1: CGPoint(x: x + k, y: y + r), control2: CGPoint(x: x + r, y: y + k))
        result.closeSubpath()
        return result
    }
}

private struct NativeWheelContent: View {
    let items: [WheelItem]
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("localGlassStyle") private var glass = true
    @Namespace private var glassNamespace
    @State private var expanded = false
    @State private var bordersVisible = false

    private var disk: RecoveredFanDiskShape { RecoveredFanDiskShape(innerRadius: expanded ? 42.24 : 0, outerRadius: expanded ? 125.92 : 50.4) }

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *), glass { nativeGlass }
            else { fallback }
        }
        .frame(width: 372, height: 372)
        .onAppear(perform: animateIntro)
        .accessibilityElement(children: .combine)
    }

    @available(macOS 26.0, *)
    private var nativeGlass: some View {
        ZStack {
            Color.clear.frame(width: 251.84, height: 251.84)
                .glassEffect(.clear.tint(Color(nsColor: colorScheme == .dark ? .black : .gray).opacity(0.5)), in: disk)
                .opacity(items.isEmpty ? 0 : 1)
            GlassEffectContainer(spacing: 0) {
                ZStack {
                    ForEach(items.indices, id: \.self) { index in
                        let shape = WheelView.shape(index: index, count: items.count, expanded: expanded)
                        Color.clear
                            .glassEffect(.regular.interactive(true), in: shape)
                            .glassEffectID(index, in: glassNamespace)
                            .overlay { decoration(shape: shape) }
                    }
                }
                .frame(width: 372, height: 372)
            }
        }
    }

    private var fallback: some View {
        ZStack {
            if glass { disk.fill(.ultraThinMaterial).frame(width: 251.84, height: 251.84) }
            else { disk.fill(.black).frame(width: 251.84, height: 251.84) }
            ForEach(items.indices, id: \.self) { index in
                let shape = WheelView.shape(index: index, count: items.count, expanded: expanded)
                if glass { shape.fill(.ultraThinMaterial).overlay { decoration(shape: shape) } }
                else { shape.fill(Color(white: 0.14)).overlay { decoration(shape: shape) } }
            }
        }
    }

    @ViewBuilder
    private func decoration(shape: RecoveredPetalShape) -> some View {
        if glass { shape.stroke(Color.black.opacity(0.1), lineWidth: 0.75).opacity(bordersVisible ? 1 : 0) }
    }

    private func animateIntro() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            expanded = true; bordersVisible = true
            return
        }
        withAnimation(.timingCurve(0.18, 0.82, 0.24, 1, duration: 0.20)) { expanded = true }
        withAnimation(.easeOut(duration: 0.06).delay(0.20)) { bordersVisible = true }
    }

    static func symbol(for id: String) -> String? {
        ["airDrop": "airplay.audio", "float": "macwindow.on.rectangle", "copy": "doc.on.doc", "move": "folder", "copyPath": "link", "terminal": "terminal",
         "createPDF": "doc.richtext", "createCollage": "square.grid.2x2", "compress": "arrow.down.right.and.arrow.up.left", "removeMetadata": "eraser", "rotateImage": "rotate.right", "flipImage": "arrow.left.and.right.righttriangle.left.righttriangle.right", "cropImage": "crop", "readQRCode": "qrcode.viewfinder",
         "mergePDF": "doc.on.doc", "splitPDF": "rectangle.split.2x1", "organizePDF": "list.number", "muteVideo": "speaker.slash", "trimVideo": "scissors", "changeVideoSpeed": "speedometer", "cropVideo": "crop", "videoSnapshots": "camera", "trimAudio": "scissors", "audioChannels": "waveform", "normalizeAudio": "waveform.path"] [id]
    }
}
