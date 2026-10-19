import AppKit

/// One continuous drag destination across a display. The wheel is a child,
/// while the dimmed background consumes the gesture's unused screen area.
/// It is installed only for a live file drag, never for normal desktop use.
@MainActor
final class WheelDragCaptureView: NSView {
    let wheel: WheelView?
    private let cancelled: () -> Void

    init(frame: NSRect, wheel: WheelView?, cancelled: @escaping () -> Void) {
        self.wheel = wheel
        self.cancelled = cancelled
        super.init(frame: frame)
        wantsLayer = true
        // Keep the window alpha at 1. Every pixel has actual content so gaps
        // between petals cannot be treated as transparent desktop regions.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        if let wheel { addSubview(wheel) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Flower file drag")
        setAccessibilityHelp("Drop on a wheel option. Drop elsewhere or press Escape to cancel.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func screenPoint(_ sender: NSDraggingInfo) -> NSPoint? {
        window?.convertPoint(toScreen: sender.draggingLocation)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let wheel, let point = screenPoint(sender) else { return [] }
        let accepts = wheel.acceptsDrag(sender)
        _ = wheel.updateDrag(sender, atScreenPoint: point)
        // AppKit only offers a final drop after an acceptable update. Keep
        // the whole surface eligible so a quick center-to-petal release does
        // not depend on an intervening update. Final validation remains exact.
        return accepts ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { wheel?.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { wheel?.draggingEnded(sender) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { wheel?.concludeDragOperation(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let wheel, let point = screenPoint(sender) else { return false }
        return wheel.prepareDrag(sender, atScreenPoint: point)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let wheel, let point = screenPoint(sender) else { return false }
        return wheel.performDrag(sender, atScreenPoint: point)
    }
    override func mouseDown(with event: NSEvent) {
        // An ordinary click during the short post-release grace cancels; it
        // must not reuse the previously observed files as a second operation.
        cancelled()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelled() }
    }
}
