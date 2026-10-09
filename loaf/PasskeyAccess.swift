import AuthenticationServices
import Combine

@MainActor final class PasskeyAccess: ObservableObject {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"
    @Published private(set) var state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState?
    @Published private(set) var requesting = false
    var entitled: Bool { SecurityStatus.entitlements[Self.entitlement] as? Bool == true }
    private var manager: ASAuthorizationWebBrowserPublicKeyCredentialManager?
    init() { refresh() }
    func refresh() {
        guard entitled else {
            state = nil
            return
        }
        if manager == nil { manager = ASAuthorizationWebBrowserPublicKeyCredentialManager() }
        state = manager?.authorizationStateForPlatformCredentials
    }
    var summary: String {
        guard entitled else { return "this build needs Apple’s browser passkey entitlement" }
        switch state {
        case .authorized: return "macOS passkey access authorized"
        case .denied: return "macOS passkey access denied"
        default: return "macOS passkey access has not been authorized"
        }
    }

    func requestAccess() {
        guard entitled, let manager, !requesting else { return }
        requesting = true
        manager.requestAuthorizationForPublicKeyCredentials { [weak self] state in
            Task { @MainActor [weak self] in
                self?.state = state
                self?.requesting = false
            }
        }
    }
}
