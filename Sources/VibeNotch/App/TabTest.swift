import AppKit
import SwiftUI

/// `VIBENOTCH_TABTEST=1`: switches through every tab and prints the longest main-thread stall after each switch.
@MainActor
enum TabTest {
    static func run() {
        let model = NotchModel.shared
        let tabs = AppSettings.shared.tabs
        var last = CACurrentMediaTime()
        var worst = 0.0
        let ticker = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime()
            worst = max(worst, now - last)
            last = now
        }
        RunLoop.main.add(ticker, forMode: .common)

        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

        func measure(_ label: String, _ change: @escaping () -> Void, then next: @escaping () -> Void) {
            last = CACurrentMediaTime()
            worst = 0
            let start = cpu()
            change()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                print(label.padding(toLength: 18, withPad: " ", startingAt: 0),
                      String(format: "pausa %4.0f ms · cpu %4.0f ms", worst * 1000, cpu() - start))
                fflush(stdout)
                next()
            }
        }

        var steps: [(String, () -> Void)] = [("cerrado", {}), ("abrir", { model.open(tabs.first) }), ("quieto", {})]
        for _ in 0..<3 {
            for tab in tabs.dropFirst() + [tabs[0]] { steps.append((tab.rawValue, { model.tab = tab })) }
        }
        for tab in tabs.dropFirst() + [tabs[0]] {
            steps.append(("sin anim " + tab.rawValue, {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { model.tab = tab }
            }))
        }
        for tab in tabs { steps.append(("quieto-" + tab.rawValue, { model.tab = tab })); steps.append(("  quieto", {})) }
        steps.append(("cerrar", { model.close() }))
        steps.append(("cerrado", {}))

        func step(_ i: Int) {
            guard i < steps.count else { exit(0) }
            measure(steps[i].0, steps[i].1) { step(i + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { step(0) }
    }
}
