import SwiftUI

struct ExternalAppLinkSettingsRow: View {
    @ObservedObject var store: BrowserStore
    let identity: String

    private var preference: ExternalAppLinkPreference? { store.externalAppLinkPreference(identity: identity, profileID: store.selectedProfileID) }

    var body: some View {
        if let preference {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: preference.applicationPath))
                    .resizable().scaledToFit().frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(preference.name).lineLimit(2)
                Spacer(minLength: 12)
                Picker(
                    "\(preference.name) links",
                    selection: Binding(
                        get: { self.preference?.policy ?? .ask },
                        set: { policy in
                            guard var preference = self.preference else { return }
                            preference.policy = policy
                            store.setExternalAppLinkPreference(
                                preference, identity: identity, profileID: store.selectedProfileID)
                        })
                ) {
                    ForEach(ExternalAppLinkPolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Button("reset") {
                    store.resetExternalAppLinkPreference(identity: identity)
                }
                .controlSize(.small)
                .help("forget this app’s link preference and ask next time")
                .accessibilityLabel("reset \(preference.name) link preference")
            }
        }
    }
}

struct ExternalAppLinkSitePicker: View {
    let selection: Binding<ExternalAppLinkPolicy?>
    var body: some View {
        SiteControlPicker("open apps", selection: selection) {
            Text("follow app settings").tag(ExternalAppLinkPolicy?.none)
            Text("automatically").tag(ExternalAppLinkPolicy?.some(.allow))
            Text("ask every time").tag(ExternalAppLinkPolicy?.some(.ask))
            Text("never").tag(ExternalAppLinkPolicy?.some(.block))
        }.help("a block or an explicit ask setting for either this website or the app takes priority.")
    }
}
