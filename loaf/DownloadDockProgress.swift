import AppKit

@MainActor final class DownloadDockProgress: NSView {
    var fraction: Double = 0
    var indeterminate = false
    override func draw(_ dirtyRect: NSRect) {
        let icon = LoafAppIcon.image ?? NSApp.applicationIconImage
        icon?.draw(in: bounds)
        let track = NSRect(
            x: bounds.width * 0.14, y: bounds.height * 0.10, width: bounds.width * 0.72,
            height: max(5, bounds.height * 0.055))
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5).fill()
        NSColor.white.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let progress = indeterminate ? 0.3 : min(1, max(0, fraction))
        let offset = indeterminate ? (sin(ProcessInfo.processInfo.systemUptime * 3) + 1) / 2 * (1 - progress) : 0
        let filled = NSRect(
            x: track.minX + track.width * offset, y: track.minY, width: track.width * progress, height: track.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
    }
}
