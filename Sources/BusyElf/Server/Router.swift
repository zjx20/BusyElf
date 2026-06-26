import Foundation

enum TaskVerb {
    case start, update, wait, end
}

/// 路径 → 动词 → 调 TaskStore。休眠逻辑只依赖路径 + `id`,与 body 其它字段解耦。
struct Router {
    let store: TaskStore

    /// 由服务器在解析出一条完整 HTTP 请求后调用。非 POST / 未知路径 / 无 id 一律静默忽略。
    func route(method: String, path: String, body: Data) {
        guard method.uppercased() == "POST" else { return }
        guard let verb = Self.verb(for: path) else { return }
        guard let event = TaskEvent.parse(body),
              let id = event.id, !id.isEmpty else { return }

        switch verb {
        case .start:
            store.start(id: id, name: event.name, agent: event.agent, cwd: event.cwd)
        case .update:
            store.update(id: id, tool: event.tool, detail: event.detail,
                         reply: event.reply, agent: event.agent, cwd: event.cwd)
        case .wait:
            store.wait(id: id, message: event.message)
        case .end:
            store.end(id: id)
        }
    }

    /// 去掉 query 串后精确匹配 `/v1/task/{verb}`。
    static func verb(for rawPath: String) -> TaskVerb? {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        switch path {
        case "/v1/task/start":  return .start
        case "/v1/task/update": return .update
        case "/v1/task/wait":   return .wait
        case "/v1/task/end":    return .end
        default:                return nil
        }
    }
}
