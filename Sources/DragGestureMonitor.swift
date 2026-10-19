import AppKit

/// Decision state kept separate from AppKit polling so complete drag sequences
/// can be checked without posting synthetic mouse or keyboard events.
struct FileDragGestureState {
    enum Change {
        case show([URL], WorkMode, NSPoint)
        case ended
    }

    private var lastObservedPasteboardCount: Int
    private var pasteboardCountBeforeMouseDown: Int?
    private var wasPrimaryButtonDown = false
    private var sourceURLs: [URL] = []
    private var visibleMode: WorkMode?
    private var suppressedUntilMouseUp = false

    init(pasteboardCount: Int) { lastObservedPasteboardCount = pasteboardCount }

    mutating func cancelCurrentDrag() {
        // Escape and a committed drop must not reopen the wheel when another
        // modifier changes before the source application finishes its drag.
        suppressedUntilMouseUp = true
        visibleMode = nil
    }

    func expectsFilePayload(primaryButtonDown: Bool, pasteboardCount: Int) -> Bool {
        guard primaryButtonDown, !suppressedUntilMouseUp else { return false }
        let baseline = wasPrimaryButtonDown ? pasteboardCountBeforeMouseDown : lastObservedPasteboardCount
        return baseline.map { pasteboardCount != $0 } ?? false
    }

    mutating func update(primaryButtonDown: Bool, pasteboardCount: Int,
                         urls: [URL], modifiers: NSEvent.ModifierFlags,
                         location: NSPoint, escapeDown: Bool = false) -> Change? {
        defer {
            wasPrimaryButtonDown = primaryButtonDown
            lastObservedPasteboardCount = pasteboardCount
        }

        guard primaryButtonDown else {
            let hadVisibleWheel = visibleMode != nil
            pasteboardCountBeforeMouseDown = nil
            sourceURLs = []
            visibleMode = nil
            suppressedUntilMouseUp = false
            return hadVisibleWheel ? .ended : nil
        }

        if !wasPrimaryButtonDown {
            // Use the LAST idle observation, not this sample's count: Finder
            // may create the drag pasteboard between two timer ticks.
            pasteboardCountBeforeMouseDown = lastObservedPasteboardCount
            sourceURLs = []
            visibleMode = nil
        }
        if escapeDown {
            let hadVisibleWheel = visibleMode != nil
            cancelCurrentDrag()
            return hadVisibleWheel ? .ended : nil
        }
        guard !suppressedUntilMouseUp,
              let baseline = pasteboardCountBeforeMouseDown,
              pasteboardCount != baseline else { return nil }

        var seen = Set<URL>()
        let freshURLs = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        let payloadChanged = !freshURLs.isEmpty && freshURLs != sourceURLs
        if !freshURLs.isEmpty { sourceURLs = freshURLs }
        guard !sourceURLs.isEmpty else { return nil }

        let requestedMode: WorkMode?
        if modifiers.contains(.control) { requestedMode = .actions }
        else if modifiers.contains(.command) { requestedMode = .tools }
        else if modifiers.contains(.shift) { requestedMode = .convert }
        else { requestedMode = nil }

        // Releasing the shortcut leaves the wheel usable. A newly held
        // shortcut switches it, and releasing the mouse ends the gesture.
        guard let mode = requestedMode ?? visibleMode,
              mode != visibleMode || payloadChanged else { return nil }
        visibleMode = mode
        return .show(sourceURLs, mode, location)
    }
}

/// Watches public global input state without taking keyboard focus, installing
/// an event tap, or requiring Accessibility/Input Monitoring access.
@MainActor
final class DragGestureMonitor {
    var onMode: ([URL], WorkMode, NSPoint) -> Void
    var onEnded: () -> Void
    var onTrace: ((String) -> Void)?
    // The API constant's raw value is "Apple CFPasteboard drag" on macOS.
    // "NSDragPboard" is the old constant's *symbol*, not its string value.
    private let dragPasteboard = NSPasteboard(name: .drag)
    var observedPasteboardName: NSPasteboard.Name { dragPasteboard.name }
    private var state: FileDragGestureState?
    private var timer: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var isSampling = false
    private var pollingActively = false
    private var lastSampleUptime: TimeInterval?
    private var cachedPasteboardCount: Int?
    private var cachedURLs: [URL] = []
    private struct TraceInput: Equatable {
        let mouseDown: Bool
        let pasteboardCount: Int
        let fileCount: Int
        let modifiers: UInt
        let escapeDown: Bool
    }
    private var lastTraceInput: TraceInput?

    init(onMode: @escaping ([URL], WorkMode, NSPoint) -> Void,
         onEnded: @escaping () -> Void) {
        self.onMode = onMode
        self.onEnded = onEnded
    }

    func start() {
        guard timer == nil else { return }
        let count = dragPasteboard.changeCount
        state = FileDragGestureState(pasteboardCount: count)
        lastTraceInput = nil
        lastSampleUptime = nil
        onTrace?("Monitor started · pasteboard=\(dragPasteboard.name.rawValue) · count=\(count)")
        // NSEvent mouse-only monitoring requires no keyboard Accessibility
        // permission. Both handlers run on the main thread. Global covers
        // Finder; local covers our floating files and other own-app sources.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.poll() }
            return event
        }
        onTrace?("Mouse monitors · global=\(globalMouseMonitor == nil ? "unavailable" : "on") · local=\(localMouseMonitor == nil ? "unavailable" : "on")")
        // The timer remains necessary for modifier changes while the pointer
        // is still, and nested AppKit tracking loops that skip local monitors.
        installTimer(active: false)
    }

    private func installTimer(active: Bool) {
        timer?.invalidate()
        pollingActively = active
        let timer = Timer(timeInterval: active ? 1.0 / 120.0 : 0.025, repeats: true) { [weak self] _ in
            // The timer is installed only on the main run loop. Running the
            // callback synchronously avoids queuing stale pointer samples.
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = active ? 0.001 : 0.004
        self.timer = timer
        // Drag tracking and menu tracking do not run the default run-loop mode.
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        timer?.invalidate()
        timer = nil
        state = nil
        cachedPasteboardCount = nil
        cachedURLs = []
        lastTraceInput = nil
        lastSampleUptime = nil
        pollingActively = false
        onTrace?("Monitor stopped")
    }

    func cancelCurrentDrag() { state?.cancelCurrentDrag() }

    private func poll() {
        guard state != nil, !isSampling else { return }
        isSampling = true
        defer { isSampling = false }
        let start = ProcessInfo.processInfo.systemUptime
        let primaryButtonDown = NSEvent.pressedMouseButtons & 1 != 0
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let location = NSEvent.mouseLocation
        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: 53)
        var slowNotes: [String] = []
        if primaryButtonDown, let previous = lastSampleUptime, start - previous >= 0.050 {
            slowNotes.append("timer gap=\(Int((start - previous) * 1000))ms")
        }
        lastSampleUptime = start
        if primaryButtonDown != pollingActively { installTimer(active: primaryButtonDown) }
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if elapsed >= 0.050 { slowNotes.append("total=\(Int(elapsed * 1000))ms") }
            if !slowNotes.isEmpty { onTrace?("Slow drag sample · " + slowNotes.joined(separator: " · ")) }
        }
        let count = dragPasteboard.changeCount
        if state?.expectsFilePayload(primaryButtonDown: primaryButtonDown, pasteboardCount: count) == true,
           count != cachedPasteboardCount || cachedURLs.isEmpty {
            let readStart = ProcessInfo.processInfo.systemUptime
            cachedURLs = Self.fileURLs(from: dragPasteboard)
            cachedPasteboardCount = count
            let elapsed = ProcessInfo.processInfo.systemUptime - readStart
            if elapsed >= 0.050 { slowNotes.append("pasteboard read=\(Int(elapsed * 1000))ms") }
        } else if !primaryButtonDown {
            cachedPasteboardCount = nil
            cachedURLs = []
        }
        let input = TraceInput(mouseDown: primaryButtonDown, pasteboardCount: count,
                               fileCount: cachedURLs.count, modifiers: flags.rawValue,
                               escapeDown: escapeDown)
        if input != lastTraceInput {
            lastTraceInput = input
            let keys = [(NSEvent.ModifierFlags.shift, "Shift"), (.command, "Command"), (.control, "Control"), (.option, "Option")].compactMap { flags.contains($0.0) ? $0.1 : nil }.joined(separator: "+")
            onTrace?("Input · mouse=\(primaryButtonDown ? "down" : "up") · pasteboard=\(count) · files=\(cachedURLs.count) · keys=\(keys.isEmpty ? "none" : keys)\(escapeDown ? " · Escape" : "")")
        }
        guard let change = state?.update(primaryButtonDown: primaryButtonDown,
                                         pasteboardCount: count,
                                         urls: cachedURLs,
                                         modifiers: flags,
                                         location: location,
                                         escapeDown: escapeDown) else { return }
        switch change {
        case let .show(urls, mode, location):
            let callbackStart = ProcessInfo.processInfo.systemUptime
            onMode(urls, mode, location)
            let elapsed = ProcessInfo.processInfo.systemUptime - callbackStart
            if elapsed >= 0.050 { slowNotes.append("wheel callback=\(Int(elapsed * 1000))ms") }
        case .ended: onEnded()
        }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.filter(\.isFileURL)
        }
        // Older AppKit drag sources still provide the filename list flavor.
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
