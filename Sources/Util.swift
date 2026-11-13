import Foundation

extension String {
    /// Baştaki ve sondaki boşluk / satır sonları atılmış hâli
    var trimmed: String { return trimmingCharacters(in: .whitespacesAndNewlines) }
}
