import Foundation
import IOKit.ps
import notify

/// Power and thermal state that make auto quality keep the GPU free.
struct SystemConditions: Equatable, Sendable {
    var lowPowerMode: Bool
    var onBattery: Bool
    var thermalState: ProcessInfo.ThermalState

    static func current() -> SystemConditions {
        SystemConditions(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, onBattery: isOnBattery(),
                         thermalState: ProcessInfo.processInfo.thermalState)
    }

    /// The strongest reason to avoid the GPU, if any.
    var reason: AdaptiveReason? {
        if thermalState == .serious || thermalState == .critical { return .thermalState(thermalState) }
        if lowPowerMode { return .lowPowerMode }
        if onBattery { return .batteryPower }
        return nil
    }

    private static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPMBatteryPowerKey
    }
}

/// Calls `onChange` on `queue` when Low Power Mode, the power source or the thermal state may have changed.
final class SystemConditionsMonitor {
    private var observers: [any NSObjectProtocol] = []
    private var powerSourceToken = NOTIFY_TOKEN_INVALID

    init(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        observers = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in queue.async(execute: onChange) }
        }
        notify_register_dispatch(kIOPSNotifyPowerSource, &powerSourceToken, queue) { _ in onChange() }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        notify_cancel(powerSourceToken)
    }
}
