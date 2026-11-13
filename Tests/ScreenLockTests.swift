import XCTest
@testable import G526CameraDrive

/// Sahte kilit penceresi: açma/kaldırma çağrılarını sayar, istenirse açılamaz
@MainActor
private final class FakePresenter: LockPresenting {
    var canPresent = true
    private(set) var presented = 0
    private(set) var dismissed = 0
    private(set) var onUnlock: (() -> Void)?

    func present(onUnlock: @escaping () -> Void) -> Bool {
        guard canPresent else { return false }
        presented += 1
        self.onUnlock = onUnlock
        return true
    }

    func dismiss() { dismissed += 1 }
}

/// Dokunmatik ekran kilidi (kilit mantığı) ve "yatay önizleme varsayılan" kararı
@MainActor
final class ScreenLockTests: XCTestCase {
    private func make(canPresent: Bool = true) -> (ScreenLock, FakePresenter, () -> [Bool]) {
        let presenter = FakePresenter()
        presenter.canPresent = canPresent
        let lock = ScreenLock(presenter: presenter)
        var events: [Bool] = []
        lock.onChange = { events.append($0) }
        return (lock, presenter, { events })
    }

    func testStartsUnlocked() {
        let (lock, presenter, events) = make()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(presenter.presented, 0)
        XCTAssertTrue(events().isEmpty)
    }

    func testLockShowsWindowAndReports() {
        let (lock, presenter, events) = make()
        XCTAssertTrue(lock.lock())
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(presenter.presented, 1)
        XCTAssertEqual(events(), [true])
    }

    func testLockTwiceDoesNotStackWindows() {
        let (lock, presenter, events) = make()
        lock.lock()
        XCTAssertTrue(lock.lock())
        XCTAssertEqual(presenter.presented, 1)
        XCTAssertEqual(events(), [true])
    }

    func testUnlockRemovesWindowAndReports() {
        let (lock, presenter, events) = make()
        lock.lock()
        lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(presenter.dismissed, 1)
        XCTAssertEqual(events(), [true, false])
    }

    func testUnlockWhenNotLockedDoesNothing() {
        let (lock, presenter, events) = make()
        lock.unlock()
        XCTAssertEqual(presenter.dismissed, 0)
        XCTAssertTrue(events().isEmpty)
    }

    func testHoldCallbackFromWindowUnlocks() {
        let (lock, presenter, events) = make()
        lock.lock()
        presenter.onUnlock?()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(events(), [true, false])
    }

    func testWindowThatCannotOpenLeavesScreenUnlocked() {
        let (lock, presenter, events) = make(canPresent: false)
        XCTAssertFalse(lock.lock())
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(presenter.presented, 0)
        XCTAssertTrue(events().isEmpty)
    }

    func testCanLockAgainAfterUnlock() {
        let (lock, presenter, events) = make()
        lock.lock()
        lock.unlock()
        XCTAssertTrue(lock.lock())
        XCTAssertEqual(presenter.presented, 2)
        XCTAssertEqual(events(), [true, false, true])
    }

    func testUnlockNeedsThreeSecondHold() {
        XCTAssertEqual(ScreenLock.holdSeconds, 3)
    }

    // MARK: Önizleme kutusu varsayılan olarak yatay

    func testPreviewFrameDefaultsToHorizontal() {
        XCTAssertEqual(AppSettings.defaultFrame, 0)
        // Yatay kadrajda kamera görüntüsü çevrilmez (varsayılan görüntü yönü normal)
        XCTAssertEqual(AppSettings.orientation(.normal, forFrame: AppSettings.defaultFrame), .normal)
        // Eskiden dikey için kaydedilmiş çeyrek dönüş yatay kadrajda normale iner
        XCTAssertEqual(AppSettings.orientation(.right90, forFrame: AppSettings.defaultFrame), .normal)
        XCTAssertEqual(AppSettings.orientation(.left90, forFrame: AppSettings.defaultFrame), .normal)
        // Ters takılı kamera (180°) yatayda korunur
        XCTAssertEqual(AppSettings.orientation(.rotate180, forFrame: AppSettings.defaultFrame), .rotate180)
    }

    func testFreshInstallUsesHorizontalFrame() {
        let suite = "ScreenLockTests.fresh"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(d.object(forKey: "guidanceFrame"))
        let frame = d.object(forKey: "guidanceFrame") as? Int ?? AppSettings.defaultFrame
        XCTAssertEqual(frame, 0)
        XCTAssertEqual(AppSettings.orientation(AppSettings.migratedOrientation(d), forFrame: frame), .normal)
        // Kullanıcı daha önce dikeyi kaydettiyse o korunur
        d.set(1, forKey: "guidanceFrame")
        XCTAssertEqual(d.object(forKey: "guidanceFrame") as? Int ?? AppSettings.defaultFrame, 1)
    }
}
