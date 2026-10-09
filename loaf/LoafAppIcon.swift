import AppKit

@MainActor enum LoafAppIcon {

    static var image: NSImage? { Bundle.main.image(forResource: "loaf") ?? NSApp.applicationIconImage }
}
