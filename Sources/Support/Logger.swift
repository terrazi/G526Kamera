import Foundation

/// Uygulama içi günlük. "Tanı" ekranında görünür; Mac olmadan hata ayıklamayı sağlar.
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []
    private let maxLines = 500
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
        #if DEBUG
        print(line)
        #endif
    }

    func clear() {
        DispatchQueue.main.async { self.lines.removeAll() }
    }
}

func tlog(_ message: String) {
    AppLog.shared.log(message)
}
