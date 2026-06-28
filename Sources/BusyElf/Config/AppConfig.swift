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

    /// 界面语言(用户选择,三态)。auto = 跟随系统;其余强制。持久化 raw 到 UserDefaults。
    enum Language: String { case auto, english, chinese }

    // 内建默认
    static let defaultInactivityTimeout: TimeInterval = 15 * 60   // 15 分钟
    static let minInactivityTimeout: TimeInterval = 60            // 下限,防误设成几秒乱放行
    static let defaultPort: UInt16 = 17872

    /// 任务无活动超过它就视为"可能已断",不再阻止休眠(看门狗)。可经面板运行期改并持久化。
    private(set) var inactivityTimeout: TimeInterval
    /// HTTP 首选端口。首启探测(候选表回退 / port 0)选定后即"钉死"持久化,此后只绑这个端口(冲突报错不漂移)。
    /// 可经面板运行期改并持久化(改后需重启监听);改端口=重新钉死。
    private(set) var preferredPort: UInt16
    /// 端口是否被环境变量(`BUSYELF_HTTP_PORT`)覆盖。env 覆盖时按"精确绑定"语义、且**不回写持久化**,
    /// 供测试完全无视用户 defaults 里钉死的端口、保持确定性。
    let portEnvOverridden: Bool
    /// 是否调试/测试模式(`BUSYELF_DEBUG=1`)。调试实例**既不持久化端口、也不读取用户已钉死的端口**,
    /// 与用户真实 defaults 完全隔离(E2E 测试实例都带此 env,不污染、不受污染)。生产(无此 env)正常持久化。
    let debugMode: Bool
    /// 是否监听所有网口(0.0.0.0)。可经面板/右键菜单运行期切换并持久化。
    private(set) var listenOnAllInterfaces: Bool
    /// 界面语言(用户选择)。可经面板运行期切换并持久化。读有效二态用 `effectiveLanguage`。
    private(set) var language: Language

    /// `effectiveLanguage` 的缓存:auto 解析系统语言较贵,且 ticker 每秒会经 `L.pick` 反复读,
    /// 进程内系统语言基本不变,故缓存;`setLanguage` 时清空重判。
    private var cachedEffective: L.Lang?

    private let defaults = UserDefaults.standard

    private init() {
        // 注册默认值,使未设时 `defaults read` 也能看到键、`defaults write` 即时生效。
        defaults.register(defaults: [
            Keys.inactivityTimeout: Self.defaultInactivityTimeout,
            Keys.httpPort: Int(Self.defaultPort),
            Keys.listenAll: false,
            Keys.language: Language.auto.rawValue,
        ])
        let env = ProcessInfo.processInfo.environment
        portEnvOverridden = env["BUSYELF_HTTP_PORT"] != nil
        debugMode = env["BUSYELF_DEBUG"] == "1"
        inactivityTimeout = Self.resolveTimeout(
            env: env["BUSYELF_INACTIVITY_TIMEOUT"], stored: defaults.double(forKey: Keys.inactivityTimeout))
        preferredPort = Self.resolvePort(
            env: env["BUSYELF_HTTP_PORT"], stored: defaults.integer(forKey: Keys.httpPort))
        listenOnAllInterfaces = Self.resolveListenAll(
            env: env["BUSYELF_LISTEN_ALL"], stored: defaults.bool(forKey: Keys.listenAll))
        language = Self.resolveLanguage(
            env: env["BUSYELF_LANGUAGE"], stored: defaults.string(forKey: Keys.language))
    }

    /// UI 切换"监听所有网口"后写回 UserDefaults(供下次启动 / 热重启读取)。
    func setListenOnAllInterfaces(_ on: Bool) {
        listenOnAllInterfaces = on
        defaults.set(on, forKey: Keys.listenAll)
    }

    /// 端口是否"已钉死"——应只绑 `preferredPort`、冲突即报错、不回退。
    /// env 覆盖(测试)或首启成功绑定后(`persistBoundPort`)/ 用户显式改端口(`setPreferredPort`)即为 true;
    /// 调试模式忽略已持久化的钉死,保持测试隔离。
    var isPortPinned: Bool {
        Self.resolvePinned(envOverridden: portEnvOverridden, debug: debugMode, storedPinned: defaults.bool(forKey: Keys.portPinned))
    }

    /// 是否应把成功绑定的端口持久化钉死。env 覆盖 / 调试模式都不持久化(不污染用户 defaults)。
    var shouldPersistBoundPort: Bool {
        Self.shouldPersistBoundPort(envOverridden: portEnvOverridden, debug: debugMode)
    }

    /// 首启探测成功绑定后调用:把实际端口钉死持久化,此后每次只绑它。
    /// 仅当 `shouldPersistBoundPort` 为真时由调用方调用,以免污染用户 defaults。幂等。
    func persistBoundPort(_ port: UInt16) {
        preferredPort = port
        defaults.set(Int(port), forKey: Keys.httpPort)
        defaults.set(true, forKey: Keys.portPinned)
    }

    /// UI 改端口后持久化(合法 1...65535 才接受;改后调用方需重启监听)。返回是否被接受。
    /// 用户显式选端口=钉死(此后精确绑定、冲突报错),需重新复制接入指令。
    @discardableResult
    func setPreferredPort(_ port: Int) -> Bool {
        guard port >= 1 && port <= 65535 else { return false }
        preferredPort = UInt16(port)
        defaults.set(port, forKey: Keys.httpPort)
        defaults.set(true, forKey: Keys.portPinned)
        return true
    }

    /// UI 改看门狗无活动阈值后持久化(clamp 下限 60s)。返回归一化后的实际值。
    @discardableResult
    func setInactivityTimeout(_ seconds: TimeInterval) -> TimeInterval {
        inactivityTimeout = max(Self.minInactivityTimeout, seconds)
        defaults.set(inactivityTimeout, forKey: Keys.inactivityTimeout)
        return inactivityTimeout
    }

    /// UI 切换语言后持久化,并清掉有效语言缓存(选回 auto 要重判系统;切到显式档要即时生效)。
    func setLanguage(_ lang: Language) {
        language = lang
        defaults.set(lang.rawValue, forKey: Keys.language)
        cachedEffective = nil
    }

    /// 有效语言(二态)。auto → 按系统首选语言判 zh,默认英文;结果进程内缓存。
    var effectiveLanguage: L.Lang {
        if let c = cachedEffective { return c }
        let r: L.Lang
        switch language {
        case .english: r = .en
        case .chinese: r = .zh
        case .auto:    r = Self.prefersChinese(preferred: Locale.preferredLanguages) ? .zh : .en
        }
        cachedEffective = r
        return r
    }

    // MARK: - 纯解析(单测直接喂构造值,不碰单例 / UserDefaults)

    /// 解析语言枚举(env 优先;无法解析的 env 退回 stored;坏值/未设 → auto)。
    static func resolveLanguage(env: String?, stored: String?) -> Language {
        if let l = parseLanguage(env) { return l }
        return parseLanguage(stored) ?? .auto
    }

    /// 系统首选语言是否为中文(简/繁/任意 zh 变体都归 zh)。抽成纯函数便于单测。
    static func prefersChinese(preferred: [String]) -> Bool {
        preferred.first?.lowercased().hasPrefix("zh") ?? false
    }

    private static func parseLanguage(_ s: String?) -> Language? {
        guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "en", "english":                       return .english
        case "zh", "chinese", "zh-hans", "zh-hant":  return .chinese
        case "auto", "system":                       return .auto
        default:                                     return nil
        }
    }

    static func resolveTimeout(env: String?, stored: Double) -> TimeInterval {
        let raw = envDouble(env) ?? stored
        let v = raw > 0 ? raw : defaultInactivityTimeout
        return max(minInactivityTimeout, v)
    }

    static func resolvePort(env: String?, stored: Int) -> UInt16 {
        let raw = envInt(env) ?? stored
        return (raw >= 1 && raw <= 65535) ? UInt16(raw) : defaultPort
    }

    /// 端口是否钉死(纯逻辑,便于单测):env 覆盖 → 钉死;调试模式 → 忽略已存钉死;否则看持久化标志。
    static func resolvePinned(envOverridden: Bool, debug: Bool, storedPinned: Bool) -> Bool {
        envOverridden || (!debug && storedPinned)
    }

    /// 成功绑定后是否应持久化端口(纯逻辑):env 覆盖 / 调试模式都不持久化。
    static func shouldPersistBoundPort(envOverridden: Bool, debug: Bool) -> Bool {
        !envOverridden && !debug
    }

    static func resolveListenAll(env: String?, stored: Bool) -> Bool {
        envBool(env) ?? stored
    }

    // MARK: - 私有

    private enum Keys {
        static let inactivityTimeout = "inactivityTimeoutSeconds"
        static let httpPort = "httpPort"
        static let portPinned = "portPinned"   // 故意不进 register:未设即 false → 区分"首启探测"与"已钉死"
        static let listenAll = "listenAllInterfaces"
        static let language = "language"
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
