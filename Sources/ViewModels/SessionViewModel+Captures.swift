import Foundation

/// Telefondaki çekim klasörü (Ayarlar > Çekim klasörü). Çekimler kendiliğinden silinmez; bu işlemleri yalnız kullanıcı başlatır.
extension SessionViewModel {
    func captureFolderSummary() -> CaptureFolderSummary {
        return deps.captureStore.summary()
    }

    /// "Gönderilenleri sil": gönderilmiş soru çekimleri ve paragraf çekimleri silinir; bekleyenlere ve gönderilemeyenlere dokunulmaz.
    /// Test sürerken yapılmaz (paragraf görüntüleri kullanımda olabilir): 0 döner.
    @discardableResult
    func deleteSentCaptures() -> Int {
        guard phase.isAtRest else { return 0 }
        return deps.captureStore.deleteSent()
    }

    /// "Tümünü sil": bekleyenler dahil bütün çekimler silinir (bekleyenlerin cevabı artık alınamaz). Test sürerken yapılmaz: 0 döner.
    @discardableResult
    func deleteAllCaptures() -> Int {
        guard phase.isAtRest else { return 0 }
        let count = deps.captureStore.deleteAll()
        pendingShots.removeAll()
        retriedShots.removeAll()
        return count
    }
}
