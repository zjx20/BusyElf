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

    func testResolveListenAll() {
        XCTAssertFalse(AppConfig.resolveListenAll(env: nil, stored: false))
        XCTAssertTrue(AppConfig.resolveListenAll(env: nil, stored: true))
        XCTAssertTrue(AppConfig.resolveListenAll(env: "1", stored: false))      // env 优先
        XCTAssertFalse(AppConfig.resolveListenAll(env: "off", stored: true))
        XCTAssertTrue(AppConfig.resolveListenAll(env: "garbage", stored: true)) // env 无法解析 → 退 stored
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
