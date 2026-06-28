import Foundation

/// 集中式中英双语文案表(零资源、纯 Swift)。所有用户可见字符串只走这里,
/// 中英两份译文相邻、便于核对;天然支持字符串插值与运行时切换。
///
/// - 仅 `import Foundation`,不碰 AppKit/SwiftUI,可被 UI / Notifier / State(Format)共用。
/// - **硬性约定**:无参文案一律 `static var`(每次访问按运行时 `current` 取),**绝不能用 `static let`**——
///   `let` 在类型首次访问时求值并永久锚死首语言,运行时切换会失效。带参插值文案用 `static func`。
/// - 中文一侧保持与当前 UI 完全一致(连 "Idle"/"Blocking sleep" 这类既有英文用词也照旧),只补英文一侧。
enum L {
    /// 有效语言(二态)。AppConfig 的三态 Language(含 auto)在此之前已解析为确定二态。
    enum Lang { case en, zh }

    /// 当前有效语言(读 AppConfig 的缓存计算属性,auto 已在那里解析成 en/zh)。
    static var current: Lang { AppConfig.shared.effectiveLanguage }

    /// 核心 helper:按当前有效语言二选一。所有静态文案都过它。
    /// `@autoclosure` 让两份字面量只构造被选中的那份(带插值时省一次无谓拼接)。
    static func pick(_ en: @autoclosure () -> String, _ zh: @autoclosure () -> String) -> String {
        current == .zh ? zh() : en()
    }

    /// 英文计数的单复数后缀("1 task" / "2 tasks");中文无复数。
    private static func tasks(_ n: Int) -> String { "\(n) task\(n == 1 ? "" : "s")" }
}

// MARK: - 菜单栏图标 tooltip(StatusItemController)

extension L {
    enum Tip {
        static var idle: String { pick("BusyElf · idle, sleep allowed", "BusyElf · 空闲,允许休眠") }
        static func working(_ n: Int) -> String { pick("\(n) working (blocking sleep)", "\(n) 个在干活(阻止休眠)") }
        static func waiting(_ n: Int) -> String { pick("\(n) waiting on you", "\(n) 个等你处理") }
        static var hasFailed: String { pick("failures, click to view", "有失败,点开查看") }
        static var hasDone: String { pick("completed, click to view", "有完成,点开查看") }
        static var unreachable: String { pick("port in use, not receiving events — click to view", "端口被占用,未在接收事件 — 点开查看") }
    }
}

// MARK: - popover 表头状态(PopoverController.updateHeader)

extension L {
    enum Header {
        static var idle: String { pick("Idle · sleep allowed", "空闲 · 允许休眠") }
        static func failed(_ n: Int, total: Int) -> String {
            pick("\(n) failed · \(total) total", "\(n) 个失败 · 共 \(total) 个")
        }
        static func blocking(_ total: Int) -> String {
            pick("Blocking sleep · \(tasks(total))", "阻止休眠 · \(total) 个任务")
        }
        static func waiting(_ total: Int) -> String {
            pick("Waiting on you · \(tasks(total))", "等你处理 · \(total) 个任务")
        }
        static func stalled(_ total: Int) -> String {
            pick("Likely stalled · sleep allowed · \(tasks(total))", "可能已断 · 已放行休眠 · \(total) 个任务")
        }
        static func allDone(_ total: Int) -> String {
            pick("All done · \(tasks(total))", "已完成 · \(total) 个任务")
        }
    }
}

// MARK: - popover 任务行(AgentRowView)

extension L {
    enum Row {
        // 状态点 tooltip / 第二行默认文案
        static var working: String { pick("Working", "在干活") }
        static var waiting: String { pick("Waiting on you", "等你处理") }
        static var done: String { pick("Done", "已完成") }
        static var failed: String { pick("Failed", "执行失败") }
        static var thinking: String { pick("Thinking…", "在思考…") }
        static var needsYou: String { pick("Needs your input", "需要你处理") }

        // 子任务 / 第三行短词
        static var subtask: String { pick("Subtask", "子任务") }
        static var subtaskTip: String { pick("Subtask (subagent)", "子任务(subagent)") }
        static var stalledShort: String { pick("likely stalled", "可能已断") }
        static var doneShort: String { pick("done", "完成") }
        static var failedShort: String { pick("failed", "失败") }

        // 图标 tooltip
        static var stalledTip: String {
            pick("Past the inactivity threshold; sleep allowed (auto-resumes on new progress)",
                 "超过无响应阈值,已放行休眠(收到新进展会自动恢复)")
        }
        static var stuckTip: String { pick("No progress for a while; may be stuck", "长时间无进展,可能已卡死") }
        static var stalledDot: String { pick("Likely stalled · sleep allowed", "可能已断 · 已放行休眠") }
        static var errorKindTip: String { pick("Error type", "失败类型") }

        // 移除 × / 行内确认
        static var removeTip: String {
            pick("Remove this task (releases the sleep block; does not kill the process)",
                 "移除此任务(解除休眠阻止,不杀进程)")
        }
        static var confirmRemove: String { pick("Confirm remove", "确认移除") }
        static var confirmRemoveActive: String { pick("⚠ Confirm remove", "⚠ 确认移除") }

        /// working 动作行失败 tooltip(activity + 原因)。
        static func toolFailedTip(_ activity: String, reason: String) -> String {
            pick("\(activity)\nFailed: \(reason)", "\(activity)\n失败:\(reason)")
        }
        /// 强制移除"似乎仍活跃"确认警示(ago 自身已本地化,见 L.Time)。
        static func activeWarn(_ ago: String) -> String {
            pick("⚠ This task still looks active (progress \(ago)). Remove anyway?",
                 "⚠ 该任务似乎仍在活动(\(ago)还有进展),仍要移除?")
        }
    }
}

// MARK: - popover 底部 / 更多设置 / 空态

extension L {
    enum Footer {
        static var keepDisplayAwake: String { pick("Keep screen awake", "保持屏幕唤醒") }
        static var launchAtLogin: String { pick("Launch at login", "开机启动") }
        static var listenAll: String { pick("Listen on all interfaces (0.0.0.0)", "监听所有网口 (0.0.0.0)") }
        static var moreSettings: String { pick("More settings", "更多设置") }
        static var more: String { pick("More", "更多") }
        static var port: String { pick("Port", "端口") }
        static var timeout: String { pick("Inactivity timeout", "无响应超时") }
        static var minutes: String { pick("min", "分钟") }
        static var edit: String { pick("Edit", "修改") }
        static var cancel: String { pick("Cancel", "取消") }
        static var quit: String { pick("Quit", "退出") }
        static var language: String { pick("Language", "语言") }
        static var langAuto: String { pick("Auto", "自动") }

        /// 监听地址行:前缀 + 地址(或"未就绪")。
        static func listening(_ addr: String) -> String { pick("Listening \(addr)", "监听 \(addr)") }
        static var notReady: String { pick("not ready", "未就绪") }
        static var listenAddrTip: String {
            pick("BusyElf's actual listen address; point your adapter/hook URL here",
                 "BusyElf 实际监听地址;把适配器/hook 的 URL 指到这里")
        }

        // 全部结束
        static func stopAll(_ count: Int) -> String { pick("Stop all (\(count))", "全部结束 (\(count))") }
        static func stopAllConfirm(_ count: Int) -> String {
            pick("Stop all \(tasks(count))?", "结束全部 \(count) 个任务?")
        }
        static var stopConfirm: String { pick("Stop", "结束") }

        // 空态三行
        static var emptyTitle: String { pick("The workbench is empty.", "工作台是空的。") }
        static var emptyBody: String {
            pick("No agents are working. Your Mac will sleep normally when idle.",
                 "当前没有 agent 在工作,Mac 空闲时会正常休眠。")
        }
        static var emptyHint: String {
            pick("(Note: closing the lid still sleeps — keep it open & plugged in for long tasks)",
                 "(注:合上盖子仍会休眠 — 长任务请开盖接电)")
        }
    }
}

// MARK: - 右键菜单 / overflow 菜单(AppDelegate / PopoverController)

extension L {
    enum Menu {
        static var openPanel: String { pick("Open panel", "打开面板") }
        static var about: String { pick("About BusyElf", "关于 BusyElf") }
        static var quit: String { pick("Quit", "退出") }
        static var language: String { pick("Language", "语言") }
        static var listenAllTip: String {
            pick("Let other machines/containers on the LAN report tasks (no auth; triggers the system local-network permission prompt)",
                 "允许局域网内其它机器/容器上报任务(无鉴权,会触发系统本地网络授权弹窗)")
        }
        static func listening(host: String, port: UInt16) -> String {
            pick("Listening: \(host):\(port)", "监听:\(host):\(port)")
        }
        static var notReady: String { pick("Listening: not ready", "监听:未就绪") }
        static var setup: String { pick("Connect an agent…", "接入 agent…") }
    }
}

// MARK: - 端口冲突横幅(PopoverController)

extension L {
    enum Banner {
        static func unreachable(port: UInt16) -> String {
            pick("Port \(port) is in use — not receiving events", "端口 \(port) 被占用 — 未在接收事件")
        }
        static var retry: String { pick("Retry", "重试") }
        static var changePort: String { pick("Change port", "改端口") }
    }
}

// MARK: - 接入向导(PopoverController「接入 agent…」)

extension L {
    enum Setup {
        static var title: String { pick("Connect an agent to BusyElf", "把 agent 接入 BusyElf") }
        static var tutorial: String {
            pick("Find the agent you use below, click its “Copy prompt”, then paste into that agent's chat — it configures BusyElf for you. Then run a task and watch the ⚡.",
                 "在下面找到你正在用的 agent,点它的「复制提示词」,粘进那个 agent 的对话框 —— 它会替你配好 BusyElf。然后跑个任务,看菜单栏 ⚡。")
        }
        static var moreComing: String { pick("More agents coming soon.", "后续会支持更多 agent。") }
        static var copy: String { pick("Copy prompt", "复制提示词") }
        static var copied: String { pick("Copied ✓", "已复制 ✓") }
        static var viewDocs: String { pick("View docs", "查看文档") }
        static var close: String { pick("Close", "关闭") }
        static var otherHarness: String { pick("Other", "其他") }
        static var notReady: String {
            pick("Service not ready — resolve the port conflict first.", "服务未就绪 — 请先解决端口冲突再接入。")
        }
    }
}

// MARK: - 系统通知(Notifier)

extension L {
    enum Notify {
        static func waitingTitle(_ project: String) -> String { "🔔 \(project)" }   // emoji + 项目名,两语言通用
        static var waitingBody: String { pick("Needs your input", "需要你处理") }
        static func failedTitle(_ project: String) -> String {
            pick("⚠️ \(project) failed", "⚠️ \(project) 执行失败")
        }
        static var failedFallback: String { pick("agent stopped abnormally", "agent 异常停止") }
    }
}

// MARK: - Claude 适配层生成的"等待/批准"提示(写进 waitingMessage,展示用)

extension L {
    enum Wait {
        /// 权限弹窗:需批准某工具(可带细节)。注:写进 session.waitingMessage,语言在解析时定,
        /// 运行期切语言后已存的旧消息不回溯(下次权限事件即新语言),与系统通知同一边界。
        static func approveTool(_ tool: String, detail: String?) -> String {
            if let d = detail { return pick("Approve \(tool): \(d)", "需批准 \(tool):\(d)") }
            return pick("Approve \(tool)", "需批准 \(tool)")
        }
        static var approveToolGeneric: String { pick("Approval needed for a tool call", "需批准工具调用") }
        static var approvePlan: String { pick("Waiting for plan approval", "等待批准计划") }
    }
}

// MARK: - 相对时间后缀(Format.ago)

extension L {
    enum Time {
        /// "12s ago" / "3m 前":数字+单位由 Format 给,这里只管语序与 ago/前。
        static func ago(seconds s: Int, unit: String) -> String { pick("\(s)\(unit) ago", "\(s)\(unit) 前") }
    }
}
