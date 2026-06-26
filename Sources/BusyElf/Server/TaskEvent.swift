import Foundation

/// 中立协议 body。除 `id` 外字段全可选;解析容错:
/// 非 JSON、缺字段、字段类型不符都只做展示降级,绝不影响休眠逻辑。
struct TaskEvent {
    var id: String?
    var name: String?
    var agent: String?
    var cwd: String?
    var tool: String?
    var detail: String?
    var reply: String?
    var message: String?

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
        var e = TaskEvent()
        e.id = str("id")
        e.name = str("name")
        e.agent = str("agent")
        e.cwd = str("cwd")
        e.tool = str("tool")
        e.detail = str("detail")
        e.reply = str("reply")
        e.message = str("message")
        return e
    }
}
