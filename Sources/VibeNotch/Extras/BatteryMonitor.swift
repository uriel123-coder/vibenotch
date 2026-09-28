import Foundation
import IOKit.ps

struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var plugged: Bool
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is still estimating.
    var minutes: Int?

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var info: BatteryInfo?
    private var timer: Timer?

    func start() {
        info = Self.read()
        guard info != nil else { return }
        // Plug/unplug arrives instantly through this source; the timer only refreshes the estimate.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.refresh() }
        }
        timer?.tolerance = 10
    }

    private func refresh() {
        guard let new = Self.read() else { return }
        let old = info
        info = new
        if let old, old.plugged != new.plugged {
            NotchModel.shared.announce(Announcement(
                symbol: new.plugged ? "bolt.fill" : "powerplug",
                tint: new.plugged ? .ok : .white,
                title: new.plugged ? "Cargando · \(new.percent)%" : "Usando batería · \(new.percent)%",
                subtitle: new.minutes.map { new.plugged ? "Llena en \(Fmt.duration(minutes: $0))" : "Quedan \(Fmt.duration(minutes: $0))" } ?? ""))
        } else if let old, !new.plugged, old.percent > 10, new.percent <= 10 {
            NotchModel.shared.announce(Announcement(symbol: "battery.25percent", tint: .danger,
                                                    title: "Batería baja · \(new.percent)%", subtitle: "Conecta el cargador"))
        }
    }

    nonisolated static func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let raw = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            return BatteryInfo(percent: Int(Double(current) / Double(max) * 100), charging: charging, plugged: plugged,
                               minutes: (raw ?? -1) > 0 ? raw : nil)
        }
        return nil
    }
}
