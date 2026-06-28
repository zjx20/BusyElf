import Foundation
import Network

/// 事件驱动的本机回环 HTTP 服务端。两次请求之间阻塞在 kqueue 上,进程真正休眠 → 0 空闲 CPU。
///
/// - 默认仅 loopback 可达靠 `NWParameters.requiredInterfaceType = .loopback`(免本地网络隐私弹窗,
///   而非靠 bind 127.0.0.1)。可经 AppConfig 选"监听所有网口(0.0.0.0)"。
/// - 只手解析两个事:请求行(METHOD PATH)+ `Content-Length` 决定 body 长度。够用即止。
/// - 首选端口由 AppConfig 提供,被占用时按候选表回退;实际监听端口暴露在 `port`,供 UI/诊断显示。
final class LoopbackServer {
    private let router: Router
    private let queue = DispatchQueue(label: "elf.busyelf.server")
    private var listener: NWListener?

    /// 实际监听到的端口(0 = 尚未就绪)。协议默认 17872,占用则回退。
    private(set) var port: UInt16 = 0

    /// 单连接最多读多少字节的 body,超出直接丢弃(防被本机恶意进程撑爆内存)。
    private let maxBodyBytes = 1 << 20   // 1 MiB

    /// 内建回退端口表(首选端口由 AppConfig 提供,排在最前)。
    private static let fallbackPorts: [UInt16] = [17872, 17873, 17874, 17875]
    /// 本次启动实际尝试的候选端口序列,在 `start()` 时按配置算定。
    private var candidatePorts: [UInt16] = []

    init(router: Router) {
        self.router = router
    }

    func start() {
        candidatePorts = Self.candidatePorts(preferred: AppConfig.shared.preferredPort)
        startListener(candidateIndex: 0)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// 切换端口 / 网口配置后重启监听(右键菜单"监听所有网口"用)。
    func restart() {
        stop()
        start()
    }

    /// 候选端口:首选端口在前,其后接内建回退端口(去重)。
    static func candidatePorts(preferred: UInt16) -> [UInt16] {
        [preferred] + fallbackPorts.filter { $0 != preferred }
    }

    /// 构造监听参数。默认 `requiredInterfaceType = .loopback`(仅回环,免 macOS 本地网络隐私弹窗 TN3179);
    /// 选监听所有网口(0.0.0.0)时不设该约束 → 绑定全部接口(会触发隐私授权弹窗)。
    static func makeParameters(allInterfaces: Bool) -> NWParameters {
        let params = NWParameters.tcp
        if !allInterfaces { params.requiredInterfaceType = .loopback }
        params.allowLocalEndpointReuse = true
        return params
    }

    // MARK: - 监听

    private func startListener(candidateIndex index: Int) {
        guard index < candidatePorts.count else {
            NSLog("BusyElf: 所有候选端口均不可用,服务端未启动")
            return
        }
        let portNumber = candidatePorts[index]
        guard let nwPort = NWEndpoint.Port(rawValue: portNumber) else {
            startListener(candidateIndex: index + 1)
            return
        }

        let allInterfaces = AppConfig.shared.listenOnAllInterfaces
        let params = Self.makeParameters(allInterfaces: allInterfaces)

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            NSLog("BusyElf: 在 \(portNumber) 创建监听失败: \(error);尝试下一个端口")
            startListener(candidateIndex: index + 1)
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = portNumber
                NSLog("BusyElf: 监听 \(allInterfaces ? "0.0.0.0" : "127.0.0.1"):\(portNumber)")
            case .failed(let error):
                NSLog("BusyElf: 端口 \(portNumber) 监听失败: \(error);回退")
                listener.cancel()
                if self.listener === listener { self.listener = nil }
                self.startListener(candidateIndex: index + 1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        let parser = HTTPRequestParser(maxBodyBytes: maxBodyBytes)
        connection.start(queue: queue)
        receive(on: connection, parser: parser)
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            if let data, !data.isEmpty {
                switch parser.feed(data) {
                case .needMore:
                    break
                case .overflow:
                    connection.cancel()
                    return
                case .request(let req):
                    let responseBody = self.router.route(method: req.method, path: req.path, body: req.body)
                    self.respond(on: connection, body: responseBody)
                    return
                }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, parser: parser)
        }
    }

    private func respond(on connection: NWConnection, body: String) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// 极简增量 HTTP 请求解析器:头部用 `\r\n\r\n` 分界,body 长度取 `Content-Length`。
/// 只供本机受信适配器使用,不追求 RFC 完整(无 chunked、无 keep-alive 多请求)。
final class HTTPRequestParser {
    struct Request {
        let method: String
        let path: String
        let body: Data
    }
    enum Outcome {
        case needMore
        case overflow            // body 超过上限,放弃此连接
        case request(Request)
    }

    private var buffer = Data()
    private var finished = false
    private let maxBodyBytes: Int

    init(maxBodyBytes: Int) {
        self.maxBodyBytes = maxBodyBytes
    }

    func feed(_ data: Data) -> Outcome {
        guard !finished else { return .needMore }
        buffer.append(data)

        // 头部尚未收全
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // 头部本身异常膨胀也视为溢出
            return buffer.count > maxBodyBytes ? .overflow : .needMore
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .overflow
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .overflow }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .overflow }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            contentLength = max(0, Int(value) ?? 0)
        }

        if contentLength > maxBodyBytes { return .overflow }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return .needMore }   // 等更多 body

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        finished = true
        return .request(Request(method: method, path: path, body: body))
    }
}
