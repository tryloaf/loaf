import Foundation
import Security

enum SecurityStatus {
    static var signing: [String: Any] {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess
        else { return [:] }
        return info as? [String: Any] ?? [:]
    }
    static var entitlements: [String: Any] { signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:] }
    static var weatherKit: Bool { entitlements["com.apple.developer.weatherkit"] as? Bool == true }
    static var identity: String {
        signing[kSecCodeInfoTeamIdentifier as String] as? String ?? "ad-hoc development build"
    }
}
