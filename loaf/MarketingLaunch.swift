import AppKit
import Combine

@MainActor enum MarketingLaunch {
    static let bundleIdentifier = BrowserBrand.bundleIdentifier + ".studio"

    static func application() -> BrowserApplication {
        guard Bundle.main.bundleIdentifier == bundleIdentifier else { return BrowserApplication() }

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("loaf/Studio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let session = directory.appendingPathComponent("session.json")
            if !FileManager.default.fileExists(atPath: session.path) {
                UserDefaults.standard.set("light", forKey: "loaf.appearance")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot()).write(to: session, options: .atomic)
            }
        } catch {
            let application = BrowserApplication(directory: directory)
            application.error = "The studio workspace couldn’t be prepared: \(error.localizedDescription)"
            return application
        }
        return BrowserApplication(directory: directory)
    }

    static func snapshot() -> BrowserSnapshot {

        let profileID = UUID(uuidString: "639DA9B1-E79E-4981-ACB0-35E834FA5F66")!
        let windowID = UUID(uuidString: "025545D0-8C87-486A-A0B1-2BE5E5B7BFA0")!
        let fonts = TabGroup(name: "fonts", icon: LoafIcon.book.rawValue, color: 5)
        let inspiration = TabGroup(name: "inspiration", icon: LoafIcon.sparkle.rawValue, color: 4)
        func tab(_ title: String, _ address: String, group: UUID? = nil) -> SavedTab {
            SavedTab(title: title, address: address, customTitle: title, groupID: group)
        }
        func pin(_ title: String, _ address: String) -> SavedTab {
            SavedTab(title: title, address: address, pinned: true, pinnedTitle: title, pinnedAddress: address)
        }
        let start = SavedTab(title: "start page", customTitle: "start page")
        let tabs = [
            start,
            tab("fern · YouTube", "https://www.youtube.com/@fern-tv"),
            tab(
                "Film Score Essentials",
                "https://music.apple.com/us/playlist/film-score-essentials/pl.3b89144df9054dc3a8502c8a74cc1686"),
            tab("Human Interface Guidelines", "https://developer.apple.com/design/human-interface-guidelines/"),
            tab("owen.uno", "https://owen.uno/"),
            tab("Uncut", "https://uncut.wtf/", group: fonts.id),
            tab("Typewolf", "https://www.typewolf.com/", group: fonts.id),
            tab("Cassette · Displaay", "https://displaay.net/typeface/cassette", group: fonts.id),
            tab("Hardware · Dinamo", "https://abcdinamo.com/hardware", group: fonts.id),
            tab("now · teenage engineering", "https://teenage.engineering/now", group: inspiration.id),
            tab("Awwwards", "https://www.awwwards.com/", group: inspiration.id),
            tab("Fabrica · Framer", "https://www.framer.com/marketplace/templates/fabrica/", group: inspiration.id),
        ]
        let pins = [
            pin("Are.na", "https://www.are.na/"), pin("Figma", "https://www.figma.com/"),
            pin("Cosmos", "https://www.cosmos.so/"),
        ]
        let personalization = Personalization(
            customTint: ProfileColor(hue: 0.11, red: 0.97, green: 0.94, blue: 0.87),
            sidebarWeather: false, tintStrength: 0.16, windowTransparency: 0.18,
            background: "profile", widgets: ["clock", "weather", "pins", "notes", "calendar"],
            notes: "Collect good things.\nLeave room for a little wandering."
        )
        let profile = Profile(
            id: profileID, name: "studio", emoji: LoafIcon.leaf.rawValue,
            pinShortcuts: pins,
            favorites: pins.map { Favorite(title: $0.title, address: $0.address!) },
            personalization: personalization)
        var preferences = BrowserPreferences()
        preferences.sidebarWidth = 256
        preferences.weatherCity = "Minneapolis"
        preferences.fahrenheit = true
        preferences.weatherProvider = "open-meteo"
        preferences.googleSuggestions = false
        preferences.remoteSites = false
        preferences.sidebarOnlyChrome = true
        preferences.insetCollapsedPage = true
        preferences.restoreSession = true
        let workspace = WindowWorkspace(
            sidebarOrder: Array(tabs.prefix(5).map(\.id)) + [fonts.id, inspiration.id],
            groups: [fonts, inspiration], tabs: tabs, selectedTab: start.id
        )
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: min(1360, max(800, screen.width - 120)), height: min(880, max(540, screen.height - 100)))
        let frame = NSRect(
            x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        let window = SavedWindow(
            id: windowID, selectedProfile: profileID,
            workspaces: [profileID: workspace], frame: NSStringFromRect(frame))
        return BrowserSnapshot(
            version: 2, profiles: [profile], selectedProfile: profileID, preferences: preferences, windows: [window])
    }

    static func prepareIcons(in application: BrowserApplication) {
        guard Bundle.main.bundleIdentifier == bundleIdentifier else { return }
        Task {
            for await ready in application.$ready.values { if ready { break } }

            let declaredIcons = [
                "thecreativeindependent.com": "https://thecreativeindependent.com/images/favicon.png",
                "owen.uno": "https://framerusercontent.com/images/I9RfMv1WLN5LgPzAL2BPklM0NM.png",
                "www.itsnicethat.com": "https://www.itsnicethat.com/favicon-32x32.png",
                "www.dezeen.com":
                    "https://www.dezeen.com/wp-content/themes/2016dezeen/assets/img/favicons/dezeen/favicon-96x96.png",
                "www.cosmos.so": "https://www.cosmos.so/apple-icon.png?apple-icon.2e21fxh1087ib.png",
            ]
            await prepareExtensions(in: application)
            for window in application.windows {
                for tab in window.tabs + window.pinnedTabs {
                    guard let url = tab.url else { continue }
                    Task {
                        let declared = declaredIcons[url.host ?? ""].flatMap(URL.init(string:)).map { [$0] } ?? []
                        let image = await application.favicons.image(for: url, declared: declared)
                        guard !tab.isDisposed, tab.url == url, tab.favicon == nil else { return }
                        tab.favicon = image
                    }
                }
            }
        }
    }

    private static func prepareExtensions(in application: BrowserApplication) async {
        let marker = application.directory.appendingPathComponent("studio-extensions-prepared")
        guard !FileManager.default.fileExists(atPath: marker.path),
            let resources = Bundle.main.resourceURL,
            let window = application.windows.first
        else { return }
        let manager = application.runtime(for: window.selectedProfileID).extensions
        await application.runtime(for: window.selectedProfileID).extensionRestoration?.value
        do {
            for (name, id) in [
                ("ublock-lite", "ddkjiahejlhfcafbddmgiahcphecmpfh"),
                ("dark-reader", "eimadpbcbfnmbkopoojfekhnkhdbieeh"),
                ("sponsorblock", "mnjggcdmjocbbbhaepdhchncahnbgone"),
            ] {
                if application.profiles.first(where: { $0.id == window.selectedProfileID })?.extensions.contains(
                    where: { $0.storeID == id }) == true
                {
                    continue
                }
                let package = try Data(
                    contentsOf: resources.appendingPathComponent("StudioExtensions/" + name + ".crx"))
                let verified = try CRXVerifier.verify(package, expectedID: id, requirePublisher: true)
                try await manager.installPackage(package, verified: verified, confirm: false, owner: window)
            }
            try Data().write(to: marker, options: .atomic)
        } catch {
            application.error = "Studio extensions couldn’t be prepared: \(error.localizedDescription)"
        }
    }

}
