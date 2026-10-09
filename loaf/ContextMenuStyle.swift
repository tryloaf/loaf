import AppKit

@MainActor enum ContextMenuStyle {
    static func apply(_ menu: NSMenu, parent: String = "") {
        LowercaseMenus.normalize(menu)
        menu.font = .systemFont(ofSize: 13)
        for item in menu.items {
            item.attributedTitle = nil
            item.image = nil
            if let submenu = item.submenu { apply(submenu) }
        }
    }
}
