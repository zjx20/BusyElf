import Foundation

/// 全局运行期配置(agent 中立)。读取优先级:**环境变量 > UserDefaults > 内建默认**。
///
/// - 环境变量层复用既有 `BUSYELF_*` 模式,主要供测试 / E2E 用,且不污染用户真实 defaults。
/// - UserDefaults 是用户可持久化的"极简入口":`defaults write elf.busyelf <key> <值>`(改后重开生效)。
///   bundle id 见 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER = elf.busyelf`。
/// - 全部 best-effort + 容错降级:解析不出就回默认,绝不影响休眠 / 服务核心。
///
/// 解析逻辑抽成纯静态 `resolveXxx`(易单测),`init` 只负责把 env/UserDefaults 喂进去。
final class AppConfig {
    static let shared = AppConfig()

    // 内建默认
    static let defaultInactivityTimeout: TimeInterval = 15 * 60   // 15 分钟
    static let minInactivityTimeout: TimeInterval = 60            // 下限,防误设成几秒乱放行
    static let defaultPort: UInt16 = 17872

    /// 任务无活动超过它就视为"可能已断",不再阻止休眠(看门狗)。可经面板运行期改并持久化。
    private(set) var inactivityTimeout: TimeInterval
    /// HTTP 首选端口(被占用仍按候选表回退)。可经面板运行期改并持久化(改后需重启监听)。
    private(set) var preferredPort: UInt16
    /// 是否监听所有网口(0.0.0.0)。可经面板/右键菜单运行期切换并持久化。
    private(set) var listenOnAllInterfaces: Bool

    private let defaults = UserDefaults.standard

    private init() {
        // 注册默认值,使未设时 `defaults read` 也能看到键、`defaults write` 即时生效。
        defaults.register(defaults: [
            Keys.inactivityTimeout: Self.defaultInactivityTimeout,
            Keys.httpPort: Int(Self.defaultPort),
            Keys.listenAll: false,
        ])
        let env = ProcessInfo.processInfo.environment
        inactivityTimeout = Self.resolveTimeout(
            env: env["BUSYELF_INACTIVITY_TIMEOUT"], stored: defaults.double(forKey: Keys.inactivityTimeout))
        preferredPort = Self.resolvePort(
            env: env["BUSYELF_HTTP_PORT"], stored: defaults.integer(forKey: Keys.httpPort))
        listenOnAllInterfaces = Self.resolveListenAll(
            env: env["BUSYELF_LISTEN_ALL"], stored: defaults.bool(forKey: Keys.listenAll))
    }

    /// UI 切换"监听所有网口"后写回 UserDefaults(供下次启动 / 热重启读取)。
    func setListenOnAllInterfaces(_ on: Bool) {
        listenOnAllInterfaces = on
        defaults.set(on, forKey: Keys.listenAll)
    }

    /// UI 改端口后持久化(合法 1...65535 才接受;改后调用方需重启监听)。返回是否被接受。
    @discardableResult
    func setPreferredPort(_ port: Int) -> Bool {
        guard port >= 1 && port <= 65535 else { return false }
        preferredPort = UInt16(port)
        defaults.set(port, forKey: Keys.httpPort)
        return true
    }

    /// UI 改看门狗无活动阈值后持久化(clamp 下限 60s)。返回归一化后的实际值。
    @discardableResult
    func setInactivityTimeout(_ seconds: TimeInterval) -> TimeInterval {
        inactivityTimeout = max(Self.minInactivityTimeout, seconds)
        defaults.set(inactivityTimeout, forKey: Keys.inactivityTimeout)
        return inactivityTimeout
    }

    // MARK: - 纯解析(单测直接喂构造值,不碰单例 / UserDefaults)

    static func resolveTimeout(env: String?, stored: Double) -> TimeInterval {
        let raw = envDouble(env) ?? stored
        let v = raw > 0 ? raw : defaultInactivityTimeout
        return max(minInactivityTimeout, v)
    }

    static func resolvePort(env: String?, stored: Int) -> UInt16 {
        let raw = envInt(env) ?? stored
        return (raw >= 1 && raw <= 65535) ? UInt16(raw) : defaultPort
    }

    static func resolveListenAll(env: String?, stored: Bool) -> Bool {
        envBool(env) ?? stored
    }

    // MARK: - 私有

    private enum Keys {
        static let inactivityTimeout = "inactivityTimeoutSeconds"
        static let httpPort = "httpPort"
        static let listenAll = "listenAllInterfaces"
    }

    private static func envDouble(_ s: String?) -> Double? { s.flatMap(Double.init) }
    private static func envInt(_ s: String?) -> Int? { s.flatMap(Int.init) }
    private static func envBool(_ s: String?) -> Bool? {
        guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if ["1", "true", "yes", "on"].contains(s) { return true }
        if ["0", "false", "no", "off"].contains(s) { return false }
        return nil
    }
}
