import XCTest
@testable import BusyElf

/// 白盒:L.pick 按有效语言二选一、effectiveLanguage 解析 + setLanguage 清缓存立即生效。
/// 注:这些用例切 AppConfig.shared 的语言(写 UserDefaults),tearDown 复位避免污染后续。
final class LocalizationTests: XCTestCase {
    private var saved: AppConfig.Language = .auto

    override func setUp() {
        super.setUp()
        saved = AppConfig.shared.language
    }
    override func tearDown() {
        AppConfig.shared.setLanguage(saved)
        super.tearDown()
    }

    func testPickFollowsEffectiveLanguage() {
        AppConfig.shared.setLanguage(.english)
        XCTAssertEqual(L.current, .en)
        XCTAssertEqual(L.pick("Idle", "空闲"), "Idle")
        XCTAssertTrue(L.Header.failed(2, total: 3).contains("failed"))

        AppConfig.shared.setLanguage(.chinese)
        XCTAssertEqual(L.current, .zh)
        XCTAssertEqual(L.pick("Idle", "空闲"), "空闲")
        XCTAssertTrue(L.Header.failed(2, total: 3).contains("失败"))
    }

    /// 英文计数单复数:1 个用单数,>1 用复数。
    func testEnglishPluralization() {
        AppConfig.shared.setLanguage(.english)
        XCTAssertTrue(L.Header.blocking(1).contains("1 task"))
        XCTAssertFalse(L.Header.blocking(1).contains("1 tasks"))
        XCTAssertTrue(L.Header.blocking(3).contains("3 tasks"))
    }

    /// setLanguage 清缓存 → 运行期切换立即反映(不被首次解析锚死)。
    func testSetLanguageClearsEffectiveCache() {
        AppConfig.shared.setLanguage(.english)
        XCTAssertEqual(L.current, .en)
        AppConfig.shared.setLanguage(.chinese)
        XCTAssertEqual(L.current, .zh)
    }
}
