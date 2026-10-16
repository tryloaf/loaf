import AppKit
import Combine
import WebKit

@MainActor enum MarketingLaunch {
    static let bundleIdentifier = BrowserBrand.bundleIdentifier + ".studio"
    static var isStudio: Bool { Bundle.main.bundleIdentifier == bundleIdentifier }
    static let captureDate = Date(timeIntervalSince1970: 1_791_590_940)
    static func displayDate(_ live: Date) -> Date { isStudio ? captureDate : live }

    static func prepareWeather(_ weather: WeatherService) {
        guard isStudio else { return }
        weather.city = "Minneapolis"
        weather.temperature = 64
        weather.condition = "clear skies"
        weather.icon = .sun
        weather.updated = captureDate
        weather.attribution = "Apple Weather"
        weather.attributionURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
        if let resources = Bundle.main.resourceURL {
            weather.attributionMarkLight = NSImage(contentsOf: resources.appendingPathComponent("StudioFixtures/apple-weather-light.png"))
            weather.attributionMarkDark = NSImage(contentsOf: resources.appendingPathComponent("StudioFixtures/apple-weather-dark.png"))
        }
    }

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
        let inspiration = TabGroup(name: "design stuff", icon: LoafIcon.sparkle.rawValue, color: 4)
        func tab(_ title: String, _ address: String, group: UUID? = nil) -> SavedTab {
            SavedTab(title: title, address: address, customTitle: title, groupID: group)
        }
        func pin(_ title: String, _ address: String) -> SavedTab {
            SavedTab(title: title, address: address, pinned: true, pinnedTitle: title, pinnedAddress: address)
        }
        let start = SavedTab(title: "new tab", customTitle: "new tab")
        let tabs = [
            start,
            tab("owen van vooren — portfolio", "https://owen.uno/"),
            tab("pingPong", "https://chat.owen.uno/"),
            tab("loaf - a native browser for Mac", "https://tryloaf.app/"),
            tab("Someday - Single - Album by Valley", "https://music.apple.com/us/song/someday/6789365001"),
            tab("Cassette - Displaay Type Foundry", "https://displaay.net/typeface/cassette", group: fonts.id),
            tab("NaN Future", "https://nan.xyz/fonts/nan-future/", group: fonts.id),
            tab("Areal — Dinamo Typefaces", "https://abcdinamo.com/typefaces/areal", group: fonts.id),
            tab("WWDC26: What’s new in WebKit", "https://www.youtube.com/@AppleDeveloper", group: inspiration.id),
            tab("Awwwards - Website Awards", "https://www.awwwards.com/", group: inspiration.id),
            tab("Human Interface Guidelines", "https://developer.apple.com/design/human-interface-guidelines/", group: inspiration.id),
            tab("now - teenage engineering", "https://teenage.engineering/now", group: inspiration.id),
        ]
        let pins = [
            pin("Are.na", "https://www.are.na/"), pin("Sketch", "https://www.sketch.com/"),
            pin("Cosmos", "https://www.cosmos.so/"), pin("Framer", "https://www.framer.com/"),
        ]
        let personalization = Personalization(
            customTint: ProfileColor(hue: 0.11, red: 0.98, green: 0.965, blue: 0.925),
            sidebarWeather: true, tintStrength: 0.16, windowTransparency: 0.06,
            background: "profile",
            notes: "Collect good things.\nLeave room for a little wandering."
        )
        let profile = Profile(
            id: profileID, name: "loaf", emoji: "☺",
            pinShortcuts: pins,
            favorites: [
                Favorite(title: "owen van vooren — portfolio", address: "https://owen.uno/"),
                Favorite(title: "pingPong", address: "https://chat.owen.uno/"),
                Favorite(title: "loaf - a native browser for Mac", address: "https://tryloaf.app/"),
                Favorite(title: "now - teenage engineering", address: "https://teenage.engineering/now"),
            ],
            personalization: personalization)
        var preferences = BrowserPreferences()
        preferences.sidebarWidth = 256
        preferences.weatherCity = "Minneapolis"
        preferences.fahrenheit = true
        preferences.weatherProvider = "apple"
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

            for _ in 0..<100 {
                if application.windows.contains(where: { $0.tabs.contains(where: { $0.url?.host == "music.apple.com" }) }) { break }
                try? await Task.sleep(for: .milliseconds(50))
            }

            let declaredIcons = [
                "thecreativeindependent.com": "https://thecreativeindependent.com/images/favicon.png",
                "owen.uno": "https://framerusercontent.com/images/I9RfMv1WLN5LgPzAL2BPklM0NM.png",
                "www.itsnicethat.com": "https://www.itsnicethat.com/favicon-32x32.png",
                "www.dezeen.com":
                    "https://www.dezeen.com/wp-content/themes/2016dezeen/assets/img/favicons/dezeen/favicon-96x96.png",
                "www.cosmos.so": "https://www.cosmos.so/apple-icon.png?apple-icon.2e21fxh1087ib.png",
            ]
            prepareWeather(application.weather)
            prepareCaptureMedia(in: application)
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


    private static func prepareCaptureMedia(in application: BrowserApplication) {
        guard isStudio else { return }
        let artwork = "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/6b/d2/a9/6bd2a9ca-5983-a76a-1b80-eb6c339af755/26UMGIM78799.rgb.jpg/256x256bb.jpg"
        for window in application.windows {
            guard let tab = window.tabs.first(where: { $0.url?.host == "music.apple.com" }) else { continue }
            let fixture = """
                if (document.querySelector('meta[name="loaf-studio-media"]')) {
                    const audio=document.getElementById('studio-track');
                    Object.defineProperties(audio, {
                      currentSrc:{get:()=> 'https://music.apple.com/studio/someday'},
                      currentTime:{get:()=>66,set:()=>{}}, duration:{get:()=>221}, paused:{get:()=>false}
                    });
                    navigator.mediaSession.metadata=new MediaMetadata({title:'Someday',artist:'Valley',album:'Someday - Single',
                      artwork:[{src:'\(artwork)',sizes:'256x256',type:'image/jpeg'}]});
                    audio.dispatchEvent(new Event('play'));
                }
                """
            tab.webView.configuration.userContentController.addUserScript(WKUserScript(
                source: fixture, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
            tab.webView.loadHTMLString("""
                <!doctype html><meta name="viewport" content="width=device-width"><meta name="loaf-studio-media" content="silent-preview">
                <title>Someday - Single - Album by Valley</title>
                <style>body{font:16px -apple-system;background:#faf7f0;color:#6d5936;padding:64px}img{width:256px;border-radius:12px}p{opacity:.65}</style>
                <img src="\(artwork)" alt="Someday by Valley"><h1>Someday</h1><h2>Valley</h2><p>loaf Studio · silent media preview</p>
                <audio id="studio-track"></audio>
                """, baseURL: tab.url)
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
