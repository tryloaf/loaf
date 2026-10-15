import SwiftUI

struct ExternalAppLinkSettingsRow: View {
    @ObservedObject var store: BrowserStore
    let identity: String

    private var preference: ExternalAppLinkPreference? { store.profile.externalAppLinks?[identity] }

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
                            store.updateCurrent { profile in
                                profile.externalAppLinks?[identity]?.policy = policy
                            }
                        })
                ) {
                    ForEach(ExternalAppLinkPolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Button("reset") {
                    store.updateCurrent { $0.externalAppLinks?.removeValue(forKey: identity) }
                }
                .controlSize(.small)
                .help("forget this app’s link preference and ask next time")
                .accessibilityLabel("reset \(preference.name) link preference")
            }
        }
    }
}
