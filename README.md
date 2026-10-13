# loaf

a browser for Mac, built with SwiftUI and WebKit. designed and developed by [owen van vooren](https://owen.uno) as a multi-year project.

profiles, split view, a customizable startpage, and a miniplayer. optional, experimental iCloud sync for profiles, pinned tabs, browser preferences, and tabs from other Macs. Chrome extension support is experimental, including userscript managers like Tampermonkey. [compatibility notes](docs/EXTENSIONS.md). no tracking or telemetry.

[download](https://tryloaf.app) · [updates](https://tryloaf.app/updates) · [report a bug](https://tryloaf.app/report)

requires macOS 15.4 or later. open `loaf.xcodeproj` in Xcode 27 to build it.

Golzheim is bundled in the distributed app, so users don’t need to install it. the font files are excluded from this source repository. to build locally, supply your own licensed copy at `loaf/Fonts/GolzheimSansVAR.ttf`; loaf’s source license does not grant a font license. build and release checks reject an app with a missing or mismatched font.

the code is here for review. the [license](LICENSE) allows private builds for testing, but doesn’t allow redistribution.
