import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let loafProfile = UTType(exportedAs: "app.tryloaf.loaf.profile", conformingTo: .data) }

struct ProfileReorderRow<Content: View>: View {
    let profile: Profile
    @ObservedObject var application: BrowserApplication
    @Binding var draggedID: UUID?
    @Binding var position: ProfileDropPosition?
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowSize = CGSize(width: 220, height: 40)
    var body: some View {
        HStack(spacing: 8) {
            ProfileDragHandle(
                profile: profile, application: application, rowSize: rowSize, draggedID: $draggedID, position: $position
            )
            .frame(width: 16, height: 28).help("drag to reorder \(profile.name)")
            content()
        }.contentShape(Rectangle())
            .opacity(draggedID == profile.id ? 0.45 : 1)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { rowSize = $0 }
            .overlay {
                ProfileDropZone(
                    profileID: profile.id, application: application,
                    draggedID: $draggedID, position: $position,
                    move: { id, target, after in
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                            application.moveProfile(id, relativeTo: target, after: after)
                        }
                    })
            }
            .accessibilityAction(named: Text("move profile up")) { move(-1) }
            .accessibilityAction(named: Text("move profile down")) { move(1) }
            .contextMenu {
                Button("move up") { move(-1) }.disabled(neighbor(-1) == nil)
                Button("move down") { move(1) }.disabled(neighbor(1) == nil)
            }
    }
    private func neighbor(_ offset: Int) -> UUID? {
        guard let index = application.profiles.firstIndex(where: { $0.id == profile.id }),
            application.profiles.indices.contains(index + offset)
        else { return nil }
        return application.profiles[index + offset].id
    }
    private func move(_ offset: Int) {
        guard let target = neighbor(offset) else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            application.moveProfile(profile.id, relativeTo: target, after: offset > 0)
        }
    }
}

struct ProfileDragHandle: NSViewRepresentable {
    let profile: Profile
    let application: BrowserApplication
    let rowSize: CGSize
    @Binding var draggedID: UUID?
    @Binding var position: ProfileDropPosition?
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {
        view.profile = profile
        view.application = application
        view.rowSize = rowSize
        view.begin = {
            draggedID = profile.id
            position = nil
        }
        view.finish = {
            draggedID = nil
            position = nil
        }
    }
    final class Handle: NSView, NSDraggingSource {
        var profile: Profile?
        weak var application: BrowserApplication?
        var rowSize = CGSize(width: 220, height: 40)
        override var mouseDownCanMoveWindow: Bool { false }
        var begin: (() -> Void)?
        var finish: (() -> Void)?
        private var down: NSEvent?
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            for y in [bounds.midY - 3, bounds.midY, bounds.midY + 3] {
                path.move(to: NSPoint(x: bounds.midX - 4, y: y))
                path.line(to: NSPoint(x: bounds.midX + 4, y: y))
            }
            path.stroke()
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { down = event }
        override func mouseUp(with event: NSEvent) { down = nil }
        override func mouseDragged(with event: NSEvent) {
            guard let down, let profile,
                hypot(
                    event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 4
            else { return }
            self.down = nil
            begin?()
            let item = NSPasteboardItem()
            item.setString(profile.id.uuidString, forType: .init(UTType.loafProfile.identifier))
            let drag = NSDraggingItem(pasteboardWriter: item)
            let image = Self.previewImage(profile: profile, rowSize: rowSize, appearance: effectiveAppearance)
            let size = image.size
            let pointer = convert(down.locationInWindow, from: nil)
            drag.setDraggingFrame(
                NSRect(
                    x: pointer.x - 12, y: pointer.y - size.height / 2,
                    width: size.width, height: size.height), contents: image)
            beginDraggingSession(with: [drag], event: event, source: self)
        }
        static func previewImage(profile: Profile, rowSize: CGSize, appearance: NSAppearance) -> NSImage {
            let size = NSSize(width: min(300, max(160, rowSize.width)), height: min(64, max(36, rowSize.height)))


            let glyph = Golzheim.image(profile.emoji, size: 20)
            return NSImage(size: size, flipped: false) { rect in
                appearance.performAsCurrentDrawingAppearance {
                    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                    NSColor.controlBackgroundColor.setFill()
                    outline.fill()
                    NSColor.separatorColor.setStroke()
                    outline.stroke()
                    if let glyph {
                        let tinted = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { bounds in
                            glyph.draw(in: bounds)
                            NSColor.labelColor.setFill()
                            bounds.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: NSRect(x: 10, y: rect.midY - 11, width: 22, height: 22))
                    } else {
                        profile.emoji.draw(
                            at: NSPoint(x: 12, y: rect.midY - 12),
                            withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
                    }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineBreakMode = .byTruncatingTail
                    profile.name.draw(
                        in: NSRect(x: 42, y: rect.midY - 8, width: rect.width - 54, height: 18),
                        withAttributes: [
                            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                        ])
                }
                return true
            }
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        {
            context == .withinApplication ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finish?()
        }
    }
}

struct ProfileDropPosition: Equatable {
    let target: UUID
    let after: Bool
    static func candidate(source: UUID, target: UUID, after: Bool, order: [UUID]) -> Self? {
        guard source != target, let sourceIndex = order.firstIndex(of: source),
            let targetIndex = order.firstIndex(of: target)
        else { return nil }
        let boundary = targetIndex + (after ? 1 : 0)
        guard boundary != sourceIndex && boundary != sourceIndex + 1 else { return nil }
        return .init(target: target, after: after)
    }
}

struct ProfileDropZone: NSViewRepresentable {
    let profileID: UUID
    let application: BrowserApplication
    @Binding var draggedID: UUID?
    @Binding var position: ProfileDropPosition?
    let move: (UUID, UUID, Bool) -> Void
    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes([.init(UTType.loafProfile.identifier)])
        return view
    }
    func updateNSView(_ view: DropView, context: Context) {
        view.profileID = profileID
        view.application = application
        view.draggedID = draggedID
        view.highlight = position?.target == profileID ? position : nil
        view.setPosition = { position = $0 }
        view.move = move
        view.finish = {
            draggedID = nil
            position = nil
        }
    }
    final class DropView: NSView {
        var profileID: UUID?
        weak var application: BrowserApplication?
        var draggedID: UUID?
        var highlight: ProfileDropPosition? { didSet { needsDisplay = true } }
        var setPosition: ((ProfileDropPosition?) -> Void)?
        var move: ((UUID, UUID, Bool) -> Void)?
        var finish: (() -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard draggedID != nil else { return nil }
            return super.hitTest(point)
        }
        func validatedSource(_ sender: any NSDraggingInfo) -> UUID? {
            guard let application, let source = sender.draggingSource as? ProfileDragHandle.Handle,
                source.application === application, source.window === window,
                sender.draggingDestinationWindow === window, sender.draggingSourceOperationMask.contains(.move),
                let id = source.profile?.id, id == draggedID,
                application.profiles.contains(where: { $0.id == id }),
                sender.draggingPasteboard.string(forType: .init(UTType.loafProfile.identifier)) == id.uuidString
            else { return nil }
            return id
        }
        func candidate(_ sender: any NSDraggingInfo) -> ProfileDropPosition? {
            guard let source = validatedSource(sender), let profileID, let application else { return nil }
            let point = convert(sender.draggingLocation, from: nil)
            return .candidate(
                source: source, target: profileID, after: point.y > bounds.midY,
                order: application.profiles.map(\.id))
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard validatedSource(sender) != nil else {
                setPosition?(nil)
                return []
            }
            sender.draggingFormation = .none
            setPosition?(candidate(sender))
            return .move
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            if highlight?.target == profileID { setPosition?(nil) }
        }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            sender.animatesToDestination = false
            return validatedSource(sender) != nil
        }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let source = validatedSource(sender) else { return false }
            if let position = candidate(sender) { move?(source, position.target, position.after) }
            finish?()
            return true
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let highlight else { return }
            NSColor.controlAccentColor.setFill()
            let y = highlight.after ? bounds.maxY - 2 : bounds.minY
            NSBezierPath(
                roundedRect: NSRect(x: 24, y: y, width: max(0, bounds.width - 24), height: 2),
                xRadius: 1, yRadius: 1
            ).fill()
        }
    }
}
