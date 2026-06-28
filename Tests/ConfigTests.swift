import XCTest
import Network
@testable import BusyElf

/// 白盒:AppConfig 纯解析(env > UserDefaults > 默认 + clamp/越界回默认)
/// 与 LoopbackServer 的端口候选 / 监听参数构造。
final class ConfigTests: XCTestCase {
    // MARK: - AppConfig

    func testResolveTimeoutClampAndPrecedence() {
        XCTAssertEqual(AppConfig.resolveTimeout(env: nil, stored: 0), AppConfig.defaultInactivityTimeout)   // 未设 → 默认
        XCTAssertEqual(AppConfig.resolveTimeout(env: nil, stored: 30), AppConfig.minInactivityTimeout)       // < 60 → clamp
        XCTAssertEqual(AppConfig.resolveTimeout(env: nil, stored: 300), 300)
        XCTAssertEqual(AppConfig.resolveTimeout(env: "120", stored: 300), 120)                               // env 优先
        XCTAssertEqual(AppConfig.resolveTimeout(env: "5", stored: 300), AppConfig.minInactivityTimeout)      // env 也 clamp
        XCTAssertEqual(AppConfig.resolveTimeout(env: "x", stored: 300), 300)                                 // env 无法解析 → 退 stored
    }

    func testResolvePort() {
        XCTAssertEqual(AppConfig.resolvePort(env: nil, stored: 0), AppConfig.defaultPort)        // 未设 → 默认
        XCTAssertEqual(AppConfig.resolvePort(env: nil, stored: 12345), 12345)
        XCTAssertEqual(AppConfig.resolvePort(env: "9999", stored: 12345), 9999)                  // env 优先
        XCTAssertEqual(AppConfig.resolvePort(env: nil, stored: 70000), AppConfig.defaultPort)    // 越界 → 默认
        XCTAssertEqual(AppConfig.resolvePort(env: "0", stored: 12345), AppConfig.defaultPort)    // env 越界 → 默认
    }

    func testResolvePinned() {
        // 首启:无 env、非调试、未持久化 → 不钉死(走探测/回退)
        XCTAssertFalse(AppConfig.resolvePinned(envOverridden: false, debug: false, storedPinned: false))
        // 首启绑定后持久化 → 钉死(此后精确绑定)
        XCTAssertTrue(AppConfig.resolvePinned(envOverridden: false, debug: false, storedPinned: true))
        // env 覆盖(测试)→ 永远钉死,无视持久化
        XCTAssertTrue(AppConfig.resolvePinned(envOverridden: true, debug: false, storedPinned: false))
        // 调试模式 → 忽略已持久化的钉死(测试隔离),除非 env 显式钉
        XCTAssertFalse(AppConfig.resolvePinned(envOverridden: false, debug: true, storedPinned: true))
        XCTAssertTrue(AppConfig.resolvePinned(envOverridden: true, debug: true, storedPinned: false))
    }

    func testShouldPersistBoundPort() {
        XCTAssertTrue(AppConfig.shouldPersistBoundPort(envOverridden: false, debug: false))   // 生产首启 → 持久化钉死
        XCTAssertFalse(AppConfig.shouldPersistBoundPort(envOverridden: true, debug: false))   // env 覆盖 → 不写
        XCTAssertFalse(AppConfig.shouldPersistBoundPort(envOverridden: false, debug: true))   // 调试 → 不写(不污染)
        XCTAssertFalse(AppConfig.shouldPersistBoundPort(envOverridden: true, debug: true))
    }

    func testResolveListenAll() {
        XCTAssertFalse(AppConfig.resolveListenAll(env: nil, stored: false))
        XCTAssertTrue(AppConfig.resolveListenAll(env: nil, stored: true))
        XCTAssertTrue(AppConfig.resolveListenAll(env: "1", stored: false))      // env 优先
        XCTAssertFalse(AppConfig.resolveListenAll(env: "off", stored: true))
        XCTAssertTrue(AppConfig.resolveListenAll(env: "garbage", stored: true)) // env 无法解析 → 退 stored
    }

    func testResolveLanguage() {
        XCTAssertEqual(AppConfig.resolveLanguage(env: nil, stored: nil), .auto)             // 未设 → auto
        XCTAssertEqual(AppConfig.resolveLanguage(env: nil, stored: "english"), .english)
        XCTAssertEqual(AppConfig.resolveLanguage(env: nil, stored: "chinese"), .chinese)
        XCTAssertEqual(AppConfig.resolveLanguage(env: "zh", stored: "english"), .chinese)   // env 优先
        XCTAssertEqual(AppConfig.resolveLanguage(env: "en", stored: "chinese"), .english)
        XCTAssertEqual(AppConfig.resolveLanguage(env: "zh-Hant", stored: nil), .chinese)    // 繁体也归 chinese
        XCTAssertEqual(AppConfig.resolveLanguage(env: "auto", stored: "chinese"), .auto)    // 显式 auto 覆盖 stored
        XCTAssertEqual(AppConfig.resolveLanguage(env: "garbage", stored: "chinese"), .chinese) // env 坏值 → 退 stored
        XCTAssertEqual(AppConfig.resolveLanguage(env: nil, stored: "weird"), .auto)         // stored 坏值 → auto
    }

    func testPrefersChinese() {
        XCTAssertTrue(AppConfig.prefersChinese(preferred: ["zh-Hans-CN", "en"]))
        XCTAssertTrue(AppConfig.prefersChinese(preferred: ["zh-Hant-TW"]))
        XCTAssertTrue(AppConfig.prefersChinese(preferred: ["zh"]))
        XCTAssertFalse(AppConfig.prefersChinese(preferred: ["en-US", "zh-Hans"]))   // 仅看 first
        XCTAssertFalse(AppConfig.prefersChinese(preferred: []))                     // 空 → 英文兜底
        XCTAssertFalse(AppConfig.prefersChinese(preferred: ["ja-JP"]))
    }

    // MARK: - LoopbackServer

    func testCandidatePortsPreferredFirstDeduped() {
        XCTAssertEqual(LoopbackServer.candidatePorts(preferred: 12345), [12345, 17872, 17873, 17874, 17875])
        XCTAssertEqual(LoopbackServer.candidatePorts(preferred: 17873), [17873, 17872, 17874, 17875]) // 去重
    }

    func testMakeParametersInterfaceBinding() {
        XCTAssertEqual(LoopbackServer.makeParameters(allInterfaces: false).requiredInterfaceType, .loopback)
        // .other = SDK 的"无接口类型要求"哨兵(见 nw_parameters_get_required_interface_type 文档)→ 绑所有网口。
        XCTAssertEqual(LoopbackServer.makeParameters(allInterfaces: true).requiredInterfaceType, .other)
    }
}
