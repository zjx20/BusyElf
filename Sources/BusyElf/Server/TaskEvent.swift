import Foundation

/// 中立协议 body。除 `id` 外字段全可选;解析容错:
/// 非 JSON、缺字段、字段类型不符都只做展示降级,绝不影响休眠逻辑。
///
/// 字段是通用语义(不是任何 agent 的字段名)。子任务由客户端把子 id 折进 `id`、
/// 用 `parentId` 标识、标签放 `name` 表达;流式回复用 `reply` + `replyAppend`(replace/append)表达。
struct TaskEvent {
    var id: String?
    var name: String?           // 任务名 / 子任务标签
    var agent: String?          // 来源标签
    var cwd: String?
    var prompt: String?         // 用户提示词
    var tool: String?           // 当前工具名
    var toolInput: String?      // 工具参数摘要(与 detail 同义,优先 toolInput)
    var detail: String?
    var reply: String?          // 回复文本(或增量)
    var replyAppend: Bool?      // true=追加到现有回复,false/缺省=替换
    var toolComplete: Bool?   // true=当前动作(工具调用)已完成 → UI 打 ✓;缺省=进行中
    var toolFailed: Bool?     // true=当前动作(工具调用)失败 → UI 改打 ✗(优先于 ✓);缺省=未失败
    var toolError: String?    // 当前动作失败原因(best-effort,仅作 tooltip);常态非终态
    var message: String?        // wait 文案
    var errorKind: String?      // 失败类型
    var errorDetail: String?    // 失败细节
    var parentId: String?       // 父任务 id(非 nil = 子任务)
    var totalTokens: Int?       // 预留:token 消耗(本期不展示)

    /// 宽容解析:用 JSONSerialization 逐字段取,数字也强转字符串。
    /// 任一步失败即返回 nil(交由 Router 忽略),保证服务端永不因 body 崩。
    static func parse(_ data: Data) -> TaskEvent? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return nil
        }
        func str(_ key: String) -> String? {
            guard let v = dict[key] else { return nil }
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        func int(_ key: String) -> Int? {
            if let n = dict[key] as? NSNumber { return n.intValue }
            if let s = dict[key] as? String { return Int(s) }
            return nil
        }
        func bool(_ key: String) -> Bool? {
            if let n = dict[key] as? NSNumber { return n.boolValue }
            if let s = dict[key] as? String { return (s as NSString).boolValue }
            return nil
        }
        var e = TaskEvent()
        e.id = str("id")
        e.name = str("name")
        e.agent = str("agent")
        e.cwd = str("cwd")
        e.prompt = str("prompt")
        e.tool = str("tool")
        e.toolInput = str("toolInput")
        e.detail = str("detail")
        e.reply = str("reply")
        e.replyAppend = bool("replyAppend")
        e.toolComplete = bool("toolComplete")
        e.toolFailed = bool("toolFailed")
        e.toolError = str("toolError")
        e.message = str("message")
        e.errorKind = str("errorKind")
        e.errorDetail = str("errorDetail")
        e.parentId = str("parentId")
        e.totalTokens = int("totalTokens")
        return e
    }
}
