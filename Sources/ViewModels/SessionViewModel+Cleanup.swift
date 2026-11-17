import Foundation

/// Ayarlar > Eski kayıtları sil: seçilen süredeki sınav kayıtları (cevap sesleri, cevaplar.txt) ve telefondaki çekimler silinir.
/// Bu işlemi yalnız kullanıcı başlatır ve test sürerken yapılmaz (açık kayıt klasörü ve çekimler kullanımda olabilir).
extension SessionViewModel {
    /// Seçenek için silinecek kayıt sayıları (silmeden önce gösterilir)
    func cleanupCounts(_ window: CleanupWindow) -> CleanupCounts {
        let cutoff = window.cutoff(now: deps.now())
        return CleanupCounts(exams: deps.library.examFolders(since: cutoff).count, captures: deps.captureStore.count(since: cutoff))
    }

    /// Seçilen süredeki kayıtları siler. Test sürüyorsa hiçbir şey silinmez ve nil döner.
    @discardableResult
    func deleteRecords(_ window: CleanupWindow) -> CleanupCounts? {
        guard phase.isAtRest else { return nil }
        let cutoff = window.cutoff(now: deps.now())
        let result = CleanupCounts(exams: deps.library.deleteExamFolders(since: cutoff), captures: deps.captureStore.delete(since: cutoff))
        // Klasörden silinen, gönderilmeyi bekleyen çekimler bellekten de düşer (silinen çekim gönderilmeye çalışılmasın). Klasöre hiç yazılamamış
        // (yalnız bellekte duran) çekimlere dokunulmaz: dosyaları silinmedi.
        pendingShots.removeAll { $0.archived && (cutoff == nil || $0.date >= cutoff!) }
        retriedShots = retriedShots.filter { id in pendingShots.contains { $0.id == id } }
        let fm = FileManager.default
        if let folder = examFolder, !fm.fileExists(atPath: folder.path) { examFolder = nil }
        if let folder = sessionFolder, !fm.fileExists(atPath: folder.path) { sessionFolder = nil }
        tlog("[temizlik] \(window.title): \(result.text)")
        return result
    }
}
