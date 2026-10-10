import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarDivider: NSViewRepresentable {
    let store: BrowserStore
    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        view.store = store
        view.focusRingType = .none
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel("sidebar width")
        view.setAccessibilityHelp(
            "Use left and right arrows to resize; shift for larger steps. Return resets the width.")
        view.updateAccessibility()
        return view
    }
    func updateNSView(_ view: DividerView, context: Context) { view.updateAccessibility() }
    final class DividerView: NSView {
        weak var store: BrowserStore?
        private var start = 220.0
        private var startX = 0.0
        override var acceptsFirstResponder: Bool { true }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
        func updateAccessibility() {
            setAccessibilityValue(store?.preferences.sidebarWidth ?? 220)
            setAccessibilityMinValue(192)
            setAccessibilityMaxValue(360)
            setAccessibilityValueDescription("\(Int(store?.preferences.sidebarWidth ?? 220)) points")
        }
        @discardableResult private func resize(_ width: Double, snap: Bool = false, persist: Bool = true) -> Bool {
            guard let store else { return false }
            let bounded = min(360, max(192, width))
            let value = snap && abs(bounded - 220) <= 8 ? 220 : bounded
            guard store.preferences.sidebarWidth != value else { return false }
            store.preferences.sidebarWidth = value
            updateAccessibility()
            if persist { store.persistSoon() }
            return true
        }
        override func accessibilityPerformIncrement() -> Bool { resize((store?.preferences.sidebarWidth ?? 220) + 4) }
        override func accessibilityPerformDecrement() -> Bool { resize((store?.preferences.sidebarWidth ?? 220) - 4) }
        override func keyDown(with event: NSEvent) {
            let step = event.modifierFlags.contains(.shift) ? 16.0 : 4.0
            switch event.keyCode {
            case 123: resize((store?.preferences.sidebarWidth ?? 220) - step)
            case 124: resize((store?.preferences.sidebarWidth ?? 220) + step)
            case 36: resize(220)
            default: super.keyDown(with: event)
            }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) {
            guard let store else { return }
            window?.makeFirstResponder(self)
            if event.clickCount == 2 {
                resize(220)
                return
            }
            start = store.preferences.sidebarWidth
            startX = event.locationInWindow.x
        }
        override func mouseDragged(with event: NSEvent) {
            resize(start + event.locationInWindow.x - startX, snap: true, persist: false)
        }
        override func mouseUp(with event: NSEvent) { store?.persistSoon() }
    }
}

struct SidebarProfileGesture {
    struct Result {
        var consumed = false
        var direction: Int?
        var resistance = 0.0
        var translation = 0.0
    }
    private var active = false
    private var rejected = false
    private var captured = false
    private var committed = false
    private var switched = false
    private var horizontal = 0.0
    private var vertical = 0.0

    mutating func reset() { self = Self() }
    mutating func update(
        x: Double, y: Double, phase: NSEvent.Phase, momentum: NSEvent.Phase = [],
        startsInside: Bool, dragging: Bool = false, index: Int, count: Int
    ) -> Result {
        if dragging {
            reset()
            return Result()
        }
        if !momentum.isEmpty { return Result(consumed: captured) }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            reset()
            active = startsInside
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            active = false
            return Result(consumed: captured)
        }
        guard active, !rejected else { return Result() }
        horizontal += x
        vertical += y
        if !captured {
            if abs(vertical) > 12, abs(vertical) >= abs(horizontal) {
                rejected = true
                return Result()
            }
            guard abs(horizontal) > 12, abs(horizontal) > abs(vertical) * 2 else { return Result() }
            captured = true
        }
        let direction = horizontal < 0 ? 1 : -1
        let atEdge = !(0..<count).contains(index + direction)
        let resistance = atEdge && !switched ? max(-8, min(8, horizontal / 12)) : 0
        var result = Result(consumed: true, resistance: resistance, translation: max(-44, min(44, -horizontal / 2)))
        if abs(horizontal) > 72, !committed {
            committed = true
            if !atEdge {
                switched = true
                result.direction = direction
            }
        }
        return result
    }
}

struct SidebarMouseScroll {
    private var accumulated = 0.0
    private var lastEvent = -Double.infinity
    private var lastSwitch = -Double.infinity
    mutating func update(delta: Double, time: Double, index: Int, count: Int) -> Int? {
        guard delta.isFinite, time.isFinite, delta != 0 else { return nil }
        if time - lastEvent > 0.3 || accumulated * delta < 0 { accumulated = 0 }
        lastEvent = time
        guard time - lastSwitch >= 0.28 else { return nil }
        accumulated += delta
        guard abs(accumulated) >= 2 else { return nil }
        let direction = accumulated < 0 ? 1 : -1
        accumulated = 0
        lastSwitch = time
        return (0..<count).contains(index + direction) ? direction : nil
    }
}

struct TraySectionSwipe {
    struct Result {
        var consumed = false
        var translation: CGFloat = 0
        var direction: Int?
    }
    private var active = false
    private var captured = false
    private var rejected = false
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTime: TimeInterval?
    mutating func update(
        x deltaX: CGFloat, y deltaY: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase, time: TimeInterval,
        index: Int, count: Int, stride: CGFloat
    ) -> Result {
        guard deltaX.isFinite, deltaY.isFinite, stride > 0, count > 0 else { return Result() }
        if !momentum.isEmpty { return Result(consumed: captured) }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            self = Self()
            active = true
        }
        guard active, !rejected else { return Result() }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            active = false
            let projected = -x + (lastTime.map { time - $0 < 0.15 } == true ? velocity * 0.10 : 0)
            let direction = phase.contains(.cancelled) || abs(projected) < stride * 0.42 ? 0 : projected > 0 ? 1 : -1
            return Result(
                consumed: captured,
                direction: direction != 0 && (0..<count).contains(index + direction) ? direction : nil)
        }
        x += deltaX
        y += deltaY
        if let lastTime, time > lastTime {
            velocity = velocity * 0.6 + (-deltaX / CGFloat(max(1.0 / 120, time - lastTime))) * 0.4
        }
        lastTime = time
        if !captured {
            if abs(y) > 8, abs(y) >= abs(x) {
                rejected = true
                return Result()
            }
            guard abs(x) > 8, abs(x) > abs(y) * 1.4 else { return Result() }
            captured = true
        }
        let lower = index == 0 ? CGFloat.zero : -stride
        let upper = index == count - 1 ? CGFloat.zero : stride
        return Result(consumed: true, translation: min(upper, max(lower, -x)))
    }
}

struct SidebarInteractions: NSViewRepresentable {
    let store: BrowserStore
    var traySection: Binding<TraySection?>? = nil
    var trayProgress: CGFloat = 0
    func makeNSView(context: Context) -> GestureView {
        let view = GestureView()
        view.store = store
        view.traySection = traySection
        view.trayProgress = trayProgress
        return view
    }
    func updateNSView(_ view: GestureView, context: Context) {
        view.traySection = traySection
        view.trayProgress = trayProgress
    }
    final class GestureView: NSView {
        weak var store: BrowserStore?
        private var monitor: Any?
        private var gesture = SidebarProfileGesture()
        private var traySwipe = TraySectionSwipe()
        private var mouseScroll = SidebarMouseScroll()
        var traySection: Binding<TraySection?>?
        var trayProgress: CGFloat = 0
        private var swipingTray = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            gesture.reset()
            mouseScroll = SidebarMouseScroll()
            if let store, store.profileResistance != 0 { store.profileResistance = 0 }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) {
                [weak self] event in
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, event.window === self.window, let store = self.store else { return false }
                    if event.type == .leftMouseDown {
                        if self.bounds.contains(self.convert(event.locationInWindow, from: nil)), store.omnibarVisible {
                            store.omnibarVisible = false
                        }
                        return false
                    }
                    if event.type == .keyDown {
                        if event.keyCode == 53, store.draggedTabID != nil {
                            store.draggedTabID = nil
                            self.gesture.reset()
                        }
                        return false
                    }
                    return self.handleScroll(
                        event, startsInside: self.bounds.contains(self.convert(event.locationInWindow, from: nil)))
                }
                return consumed ? nil : event
            }
        }

        func handleScroll(_ event: NSEvent, startsInside: Bool, startsInTray: Bool? = nil) -> Bool {
            guard let store else { return false }
            let point = convert(event.locationInWindow, from: nil)
            let fromBottom = isFlipped ? bounds.maxY - point.y : point.y - bounds.minY
            let anchoredTray = store.trayGestureAnchor.map { anchor in
                anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
            }
            let overTray =
                startsInTray
                ?? (startsInside && trayProgress >= 0.95
                    && (anchoredTray
                        ?? (fromBottom >= 8 && fromBottom < 52 + TrayMetrics.contentHeight * min(1, trayProgress))))
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) || !event.hasPreciseScrollingDeltas {
                swipingTray = overTray && traySection?.wrappedValue != nil
            }
            let sections = TraySection.allCases
            let index =
                swipingTray
                ? sections.firstIndex(of: traySection?.wrappedValue ?? .downloads) ?? 0
                : store.application.profiles.firstIndex { $0.id == store.selectedProfileID } ?? 0
            let count = swipingTray ? sections.count : store.application.profiles.count
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            func switchDestination(_ direction: Int) {
                if swipingTray {
                    traySection?.wrappedValue = sections[index + direction]
                } else {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) { store.swipeProfile(direction) }
                }
            }
            if !event.hasPreciseScrollingDeltas {
                guard event.modifierFlags.contains(.shift), store.draggedTabID == nil, startsInside else {
                    return false
                }
                let delta = event.deltaX != 0 ? event.deltaX : event.deltaY
                if let direction = mouseScroll.update(delta: delta, time: event.timestamp, index: index, count: count) {
                    switchDestination(direction)
                }
                return true
            }
            if swipingTray {
                let stride = max(20, ((store.trayGestureAnchor?.bounds.width ?? 192) - 6) / CGFloat(sections.count))
                let result = traySwipe.update(
                    x: event.scrollingDeltaX, y: event.scrollingDeltaY, phase: event.phase,
                    momentum: event.momentumPhase, time: event.timestamp, index: index, count: count, stride: stride)
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0)) {
                        if let direction = result.direction { switchDestination(direction) }
                        store.traySwipeDistance = 0
                    }
                } else if store.traySwipeDistance != result.translation {
                    store.traySwipeDistance = reduceMotion ? 0 : result.translation
                }
                return result.consumed
            }
            let result = gesture.update(
                x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                phase: event.phase, momentum: event.momentumPhase, startsInside: startsInside,
                dragging: store.draggedTabID != nil, index: index, count: count)
            if let direction = result.direction {
                switchDestination(direction)
            }
            let trayDistance: CGFloat = swipingTray && !reduceMotion ? result.translation : 0
            if store.traySwipeDistance != trayDistance {
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        store.traySwipeDistance = trayDistance
                    }
                } else {
                    store.traySwipeDistance = trayDistance
                }
            }
            let resistance: CGFloat = reduceMotion || swipingTray ? 0 : result.resistance

            if store.profileResistance != resistance {
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        store.profileResistance = resistance
                    }
                } else {
                    store.profileResistance = resistance
                }
            }
            return result.consumed
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct PinDropZone: NSViewRepresentable {
    let store: BrowserStore
    var row = false
    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes(BrowserDragTypes.pasteboardTypes(.loafTab))
        return view
    }
    func updateNSView(_ view: DropView, context: Context) {
        view.store = store
        view.row = row
    }
    final class DropView: NSView {
        weak var store: BrowserStore?
        var row = false
        private var highlighted = false { didSet { needsDisplay = true } }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard store?.draggedTabID != nil else { return nil }
            return super.hitTest(point)
        }
        func validatedTab(_ sender: any NSDraggingInfo) -> BrowserTab? {
            guard let store, let source = sender.draggingSource as? TabDragArea.DragView, source.store === store,
                source.draggingWindow === window, sender.draggingDestinationWindow === window,
                sender.draggingSourceOperationMask.contains(.move),
                let tab = source.tab, !tab.isDisposed,
                tab.profileID == store.selectedProfileID, tab.windowID == store.id,
                store.sidebarSelectableTabs.contains(where: { $0 === tab }), store.draggedTabID == tab.id,
                let data = BrowserDragTypes.data(sender.draggingPasteboard, type: .loafTab), data.count <= 1024,
                let drag = try? JSONDecoder().decode(TabDrag.self, from: data), drag.window == store.id,
                drag.profile == tab.profileID, drag.tab == tab.id
            else { return nil }
            return tab
        }
        func position(at point: NSPoint, source: BrowserTab) -> TabDropPosition? {
            guard let store else { return nil }
            let pins = (row ? store.rowPinnedTabs : store.gridPinnedTabs).filter { $0.id != source.id }
            guard !pins.isEmpty else { return nil }
            if row { return TabDropPosition(target: pins.last!.id, after: true) }
            let list = store.preferences.pinnedLayout == "list"
            let columns = list ? 1 : PinGridLayout.columns(for: pins.count + 1)
            let cellWidth = max(1, (bounds.width + 6) / CGFloat(columns))
            let y = isFlipped ? point.y : bounds.height - point.y
            let column = min(columns - 1, max(0, Int(point.x / cellWidth)))
            let index = max(0, Int(y / (PinGridLayout.tileHeight + (list ? 4 : 6)))) * columns + column
            if index >= pins.count { return TabDropPosition(target: pins.last!.id, after: true) }
            let after =
                list
                ? y.truncatingRemainder(dividingBy: 36) > 16
                : point.x - CGFloat(column) * cellWidth > cellWidth / 2
            return TabDropPosition(target: pins[index].id, after: after)
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let tab = validatedTab(sender), let store else {
                highlighted = false
                return []
            }
            highlighted = true
            let preview = PinDropPreview(
                row: row, position: position(at: convert(sender.draggingLocation, from: nil), source: tab))
            if store.pinDropPreview != preview { store.pinDropPreview = preview }
            (sender.draggingSource as? TabDragArea.DragView)?.updateDraggingPreview(grid: !row)
            return .move
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            highlighted = false
            if store?.pinDropPreview?.row == row { store?.pinDropPreview = nil }
            (sender?.draggingSource as? TabDragArea.DragView)?.updateDraggingPreview(grid: false)
        }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { validatedTab(sender) != nil }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { highlighted = false }
            guard let tab = validatedTab(sender), let store else { return false }
            let destination = position(at: convert(sender.draggingLocation, from: nil), source: tab)
            store.setPinPresentation(tab, row: row)
            let pinned = store.pinnedTabs.first { $0.pinnedShortcutID == tab.pinnedShortcutID } ?? tab
            if let destination,
                let target = store.pinnedTabs.first(where: { $0.id == destination.target })
            {
                store.movePin(pinned, before: target, after: destination.after)
            }
            store.draggedTabID = nil
            return true
        }
        override func draw(_ dirtyRect: NSRect) {
            guard highlighted, row else { return }
            let color = store.map { NSColor(profileTint($0.profile)) } ?? .controlAccentColor
            color.withAlphaComponent(0.35).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 5), xRadius: 8, yRadius: 8).stroke()
        }
    }
}

struct TrayGestureAnchor: NSViewRepresentable {
    let store: BrowserStore
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { store.trayGestureAnchor = view }
    final class Anchor: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}
