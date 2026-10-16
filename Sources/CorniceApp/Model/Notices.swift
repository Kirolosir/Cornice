import Foundation

@MainActor
protocol NoticePresenting: Sendable {
    func timerComplete(label: String)
    func lowBattery(level: Double)
    func focusTransition(_ message: String, quiet: Bool)
}

@MainActor
final class PreviewNotices: NoticePresenting {
    struct Notice { let title: String; let quiet: Bool }
    private(set) var delivered: [Notice] = []
    func timerComplete(label: String) { delivered.append(Notice(title: label, quiet: true)) }
    func lowBattery(level: Double) { delivered.append(Notice(title: "Low battery", quiet: false)) }
    func focusTransition(_ message: String, quiet: Bool) { delivered.append(Notice(title: message, quiet: quiet)) }
}
