import Foundation
import WebKit

nonisolated struct BrowsingPowerPolicy {
    let batterySaver: Bool
    let gameMode: Bool

    init(
        preferences: BrowserPreferences, hasInternalBattery: Bool, onACPower: Bool,
        batteryPercent: Int?, systemLowPower: Bool
    ) {
        gameMode = preferences.gameMode == true
        let threshold = preferences.powerSaverThreshold ?? 0
        batterySaver = hasInternalBattery && !gameMode && (
            preferences.powerSaver == true || systemLowPower
                || (!onACPower && threshold > 0 && batteryPercent.map { $0 <= threshold } == true))
    }

    func schedulingPolicy(foreground: Bool) -> WKPreferences.InactiveSchedulingPolicy {
        if gameMode && foreground { return .none }
        return batterySaver || gameMode ? .suspend : .throttle
    }
}
