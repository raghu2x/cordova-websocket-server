import Foundation
import Network
import CommonCrypto
import Cordova

// MARK: - WebSocket Frame Opcodes
private enum WSOpcode: UInt8 {
    case continuationFrame = 0x0
    case textFrame        = 0x1
    case binaryFrame      = 0x2
    case connectionClose  = 0x8
    case ping             = 0x9
    case pong             = 0xA
}

// MARK: - WebSocket Connection
private class WSConnection: Hashable {

    let uuid: String
    let connection: NWConnection
    let remoteHost: String
    let urlRequest: URLRequest

    private var fragmentBuffer: Data = Data()
    private var fragmentOpcode: WSOpcode = .textFrame
    private var isFragmenting: Bool = false

    weak var delegate: WSConnectionDelegate?

    init(uuid: String, connection: NWConnection, remoteHost: String, urlRequest: URLRequest) {
        self.uuid = uuid
        self.connection = connection
        self.remoteHost = remoteHost
        self.urlRequest = urlRequest
    }

    func startReceiving() {
        receiveNextFrame()
    }

    func send(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let frame = makeFrame(opcode: .textFrame, payload: data)
        connection.send(content: frame, completion: .idempotent)
    }

    func send(binary: Data) {
        let frame = makeFrame(opcode: .binaryFrame, payload: binary)
        connection.send(content: frame, completion: .idempotent)
    }

    func close(code: Int = 1000, reason: String? = nil) {
        var payload = Data()
        var c = UInt16(code).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &c) { Array($0) })
        if let r = reason, let rd = r.data(using: .utf8) {
            payload.append(rd)
        }
        let frame = makeFrame(opcode: .connectionClose, payload: payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // MARK: - Frame Building

    private func makeFrame(opcode: WSOpcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue) // FIN + opcode
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            var len16 = UInt16(length).bigEndian
            frame.append(contentsOf: withUnsafeBytes(of: &len16) { Array($0) })
        } else {
            frame.append(127)
            var len64 = UInt64(length).bigEndian
            frame.append(contentsOf: withUnsafeBytes(of: &len64) { Array($0) })
        }
        frame.append(payload)
        return frame
    }

    // MARK: - Frame Parsing

    private func receiveNextFrame() {
        // Read at least 2 bytes (basic header)
        receive(minLength: 2, maxLength: 2) { [weak self] data in
            guard let self = self, let data = data, data.count >= 2 else { return }

            let byte0 = data[0]
            let byte1 = data[1]
            let fin = (byte0 & 0x80) != 0
            let opcodeRaw = byte0 & 0x0F
            let masked = (byte1 & 0x80) != 0
            let payloadLen7 = Int(byte1 & 0x7F)

            self.readExtendedLength(payloadLen7: payloadLen7) { payloadLength in
                self.readMaskAndPayload(masked: masked, length: payloadLength) { maskKey, payload in
                    let unmasked = masked ? self.unmask(payload: payload, key: maskKey!) : payload
                    self.handleFrame(fin: fin, opcode: opcodeRaw, payload: unmasked)
                }
            }
        }
    }

    private func readExtendedLength(payloadLen7: Int, completion: @escaping (Int) -> Void) {
        if payloadLen7 < 126 {
            completion(payloadLen7)
        } else if payloadLen7 == 126 {
            receive(minLength: 2, maxLength: 2) { data in
                guard let data = data, data.count == 2 else { return }
                let len = Int(data[0]) << 8 | Int(data[1])
                completion(len)
            }
        } else {
            receive(minLength: 8, maxLength: 8) { data in
                guard let data = data, data.count == 8 else { return }
                var len: UInt64 = 0
                for i in 0..<8 { len = (len << 8) | UInt64(data[i]) }
                completion(Int(len))
            }
        }
    }

    private func readMaskAndPayload(masked: Bool, length: Int, completion: @escaping ([UInt8]?, Data) -> Void) {
        let maskLen = masked ? 4 : 0
        let totalLen = maskLen + length
        if totalLen == 0 {
            completion(nil, Data())
            return
        }
        receive(minLength: totalLen, maxLength: totalLen) { data in
            guard let data = data else { return }
            var maskKey: [UInt8]? = nil
            var payload: Data
            if masked {
                maskKey = [data[0], data[1], data[2], data[3]]
                payload = data.subdata(in: 4..<data.count)
            } else {
                payload = data
            }
            completion(maskKey, payload)
        }
    }

    private func unmask(payload: Data, key: [UInt8]) -> Data {
        var result = Data(count: payload.count)
        for i in 0..<payload.count {
            result[i] = payload[i] ^ key[i % 4]
        }
        return result
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        guard let op = WSOpcode(rawValue: opcode) else {
            receiveNextFrame()
            return
        }

        switch op {
        case .connectionClose:
            let code: Int
            let reason: String
            if payload.count >= 2 {
                code = Int(payload[0]) << 8 | Int(payload[1])
                reason = String(data: payload.subdata(in: 2..<payload.count), encoding: .utf8) ?? ""
            } else {
                code = 1000
                reason = ""
            }
            // Echo close frame
            let frame = makeFrame(opcode: .connectionClose, payload: payload)
            connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            delegate?.connection(self, didCloseWithCode: code, reason: reason, wasClean: true)

        case .ping:
            let pong = makeFrame(opcode: .pong, payload: payload)
            connection.send(content: pong, completion: .idempotent)
            receiveNextFrame()

        case .pong:
            receiveNextFrame()

        case .textFrame, .binaryFrame, .continuationFrame:
            if op == .continuationFrame {
                fragmentBuffer.append(payload)
                if fin {
                    let fullPayload = fragmentBuffer
                    let fullOpcode = fragmentOpcode
                    fragmentBuffer = Data()
                    isFragmenting = false
                    deliverMessage(opcode: fullOpcode, payload: fullPayload)
                }
            } else if !fin {
                // Start of fragmented message
                fragmentOpcode = op
                fragmentBuffer = payload
                isFragmenting = true
            } else {
                // Single complete frame
                deliverMessage(opcode: op, payload: payload)
            }
            receiveNextFrame()
        }
    }

    private func deliverMessage(opcode: WSOpcode, payload: Data) {
        if opcode == .textFrame {
            let text = String(data: payload, encoding: .utf8) ?? ""
            delegate?.connection(self, didReceiveText: text)
        } else if opcode == .binaryFrame {
            delegate?.connection(self, didReceiveBinary: payload)
        }
    }

    private func receive(minLength: Int, maxLength: Int, completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: minLength, maximumLength: maxLength) { [weak self] content, _, isComplete, error in
            if let content = content, !content.isEmpty {
                completion(content)
            } else if isComplete || error != nil {
                self?.handleConnectionEnd()
                completion(nil)
            } else {
                completion(nil)
            }
        }
    }

    private func handleConnectionEnd() {
        delegate?.connection(self, didCloseWithCode: 1006, reason: "Connection lost", wasClean: false)
    }

    // MARK: - Hashable
    static func == (lhs: WSConnection, rhs: WSConnection) -> Bool { lhs.uuid == rhs.uuid }
    func hash(into hasher: inout Hasher) { hasher.combine(uuid) }
}

private protocol WSConnectionDelegate: AnyObject {
    func connection(_ conn: WSConnection, didReceiveText text: String)
    func connection(_ conn: WSConnection, didReceiveBinary data: Data)
    func connection(_ conn: WSConnection, didCloseWithCode code: Int, reason: String, wasClean: Bool)
}

// MARK: - WebSocket Server (pure Swift, Network.framework)
private class WSServer {

    private var listener: NWListener?
    private let port: UInt16
    private let tcpNoDelay: Bool
    private let queue = DispatchQueue(label: "com.cordova.wsserver", qos: .userInitiated)

    var onDidStart: ((UInt16) -> Void)?
    var onDidStop: ((Error?) -> Void)?
    var onDidFail: ((Error) -> Void)?
    var onShouldAccept: ((URLRequest) -> (accepted: Bool, responseHeaders: [String: String]))?
    var onWebSocketDidOpen: ((WSConnection) -> Void)?

    private(set) var realPort: UInt16 = 0

    init(port: UInt16, tcpNoDelay: Bool = false) {
        self.port = port
        self.tcpNoDelay = tcpNoDelay
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if tcpNoDelay {
                if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                    tcpOptions.noDelay = true
                }
            }
            let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
            listener = try NWListener(using: params, on: nwPort)
            listener?.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleNewConnection(conn)
            }
            listener?.start(queue: queue)
        } catch {
            onDidFail?(error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            realPort = listener?.port?.rawValue ?? port
            onDidStart?(realPort)
        case .failed(let error):
            onDidFail?(error)
        case .cancelled:
            onDidStop?(nil)
        default:
            break
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Read the HTTP upgrade request
        readHTTPRequest(conn: conn) { [weak self] request in
            guard let self = self, let request = request else {
                conn.cancel()
                return
            }
            // Validate and decide
            let result = self.onShouldAccept?(request) ?? (accepted: true, responseHeaders: [:])
            if !result.accepted {
                self.sendHTTPForbidden(conn: conn)
                return
            }
            // Perform WebSocket handshake
            guard let key = request.value(forHTTPHeaderField: "Sec-WebSocket-Key") else {
                self.sendHTTPBadRequest(conn: conn)
                return
            }
            let accept = self.makeAcceptKey(key)
            var headers = result.responseHeaders
            headers["Upgrade"] = "websocket"
            headers["Connection"] = "Upgrade"
            headers["Sec-WebSocket-Accept"] = accept
            self.sendHTTPSwitchingProtocols(conn: conn, extraHeaders: headers) { [weak self] in
                guard let self = self else { return }
                let remote = self.remoteHost(conn: conn)
                let uuid = UUID().uuidString
                let wsConn = WSConnection(uuid: uuid, connection: conn, remoteHost: remote, urlRequest: request)
                self.onWebSocketDidOpen?(wsConn)
                wsConn.startReceiving()
            }
        }
    }

    // MARK: - HTTP Handshake Helpers

    private func readHTTPRequest(conn: NWConnection, completion: @escaping (URLRequest?) -> Void) {
        var accumulated = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, isComplete, error in
                if let data = content { accumulated.append(data) }
                if let idx = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = accumulated.subdata(in: accumulated.startIndex..<idx.lowerBound)
                    completion(self.parseHTTPRequest(headerData))
                } else if isComplete || error != nil {
                    completion(nil)
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private func parseHTTPRequest(_ data: Data) -> URLRequest? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let path = parts[1]
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "localhost"
        components.path = path.contains("?") ? String(path.prefix(upTo: path.firstIndex(of: "?")!)) : path
        if path.contains("?") {
            components.query = String(path.suffix(from: path.index(path.firstIndex(of: "?")!, offsetBy: 1)))
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = parts[0]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIdx = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    private func makeAcceptKey(_ clientKey: String) -> String {
        let combined = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        guard let data = combined.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest).base64EncodedString()
    }

    private func sendHTTPSwitchingProtocols(conn: NWConnection, extraHeaders: [String: String], completion: @escaping () -> Void) {
        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        for (k, v) in extraHeaders { response += "\(k): \(v)\r\n" }
        response += "\r\n"
        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in completion() })
    }

    private func sendHTTPForbidden(conn: NWConnection) {
        let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendHTTPBadRequest(conn: NWConnection) {
        let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func remoteHost(conn: NWConnection) -> String {
        if case .hostPort(let host, _) = conn.endpoint {
            return "\(host)"
        }
        return "unknown"
    }
}

// MARK: - Cordova Plugin

@objc(WebSocketServer) public class WebSocketServer: CDVPlugin, WSConnectionDelegate {

    private var wsserver: WSServer?
    private var port: Int = 0
    private var origins: [String]?
    private var protocols: [String]?
    private var connections: [String: WSConnection] = [:]
    private var didCloseUUIDs: [String] = []
    private var startCallbackId: String?
    private var stopCallbackId: String?
    private var didStopOrDidFail: Bool = false
    private let syncQueue = DispatchQueue(label: "com.cordova.wsserver.sync")

    override public func pluginInitialize() {
        connections = [:]
        didCloseUUIDs = []
    }

    override public func onAppTerminate() {
        wsserver?.stop()
        wsserver = nil
        syncQueue.sync {
            connections.removeAll()
            didCloseUUIDs.removeAll()
        }
    }

    // MARK: - Cordova Commands

    @objc public func getInterfaces(_ command: CDVInvokedUrlCommand) {
        commandDelegate?.run(inBackground: {
            var obj = [String: [String: [String]]]()
            for intf in Interface.allInterfaces() {
                if !intf.isLoopback {
                    var intfobj = obj[intf.name] ?? ["ipv4Addresses": [], "ipv6Addresses": []]
                    if intf.family == .ipv6 {
                        if !intfobj["ipv6Addresses"]!.contains(intf.address!) {
                            intfobj["ipv6Addresses"]!.append(intf.address!)
                        }
                    } else if intf.family == .ipv4 {
                        if !intfobj["ipv4Addresses"]!.contains(intf.address!) {
                            intfobj["ipv4Addresses"]!.append(intf.address!)
                        }
                    }
                    if !(intfobj["ipv4Addresses"]!.isEmpty && intfobj["ipv6Addresses"]!.isEmpty) {
                        obj[intf.name] = intfobj
                    }
                }
            }
            #if DEBUG
            print("WebSocketServer: getInterfaces: \(obj)")
            #endif
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: obj)
            pluginResult?.setKeepCallbackAs(false)
            self.commandDelegate?.send(pluginResult, callbackId: command.callbackId)
        })
    }

    @objc public func start(_ command: CDVInvokedUrlCommand) {
        #if DEBUG
        print("WebSocketServer: start")
        #endif

        if didStopOrDidFail {
            wsserver = nil
            didStopOrDidFail = false
        }

        if wsserver != nil {
            let r = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Server already running")
            commandDelegate?.send(r, callbackId: command.callbackId)
            return
        }

        guard let p = command.argument(at: 0) as? Int, p >= 0, p <= 65535 else {
            let r = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Port number error")
            commandDelegate?.send(r, callbackId: command.callbackId)
            return
        }
        port = p
        origins = command.argument(at: 1) as? [String]
        protocols = command.argument(at: 2) as? [String]
        let tcpNoDelay = (command.argument(at: 3) as? Bool) ?? false

        startCallbackId = command.callbackId

        let server = WSServer(port: UInt16(port), tcpNoDelay: tcpNoDelay)
        wsserver = server

        server.onDidStart = { [weak self] realPort in
            guard let self = self else { return }
            #if DEBUG
            print("WebSocketServer: Server did start on port \(realPort)")
            #endif
            let status: [String: Any] = ["addr": "0.0.0.0", "port": Int(realPort)]
            let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
            result?.setKeepCallbackAs(true)
            self.commandDelegate?.send(result, callbackId: self.startCallbackId)
        }

        server.onDidStop = { [weak self] _ in
            guard let self = self else { return }
            #if DEBUG
            print("WebSocketServer: Server did stop")
            #endif
            self.didStopOrDidFail = true
            self.syncQueue.sync {
                self.connections.removeAll()
                self.didCloseUUIDs.removeAll()
            }
            let status: [String: Any] = ["addr": "0.0.0.0", "port": self.port]
            let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
            result?.setKeepCallbackAs(false)
            self.commandDelegate?.send(result, callbackId: self.stopCallbackId)
        }

        server.onDidFail = { [weak self] error in
            guard let self = self else { return }
            #if DEBUG
            print("WebSocketServer: Server did fail: \(error)")
            #endif
            self.wsserver?.stop()
            self.didStopOrDidFail = true
            self.syncQueue.sync {
                self.connections.removeAll()
                self.didCloseUUIDs.removeAll()
            }
            let status: [String: Any] = ["action": "onFailure", "addr": "0.0.0.0", "port": self.port, "reason": error.localizedDescription]
            let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
            result?.setKeepCallbackAs(false)
            self.commandDelegate?.send(result, callbackId: self.startCallbackId)
        }

        server.onShouldAccept = { [weak self] request in
            guard let self = self else { return (false, [:]) }
            if let o = self.origins {
                guard let origin = request.value(forHTTPHeaderField: "Origin"), o.contains(origin) else {
                    #if DEBUG
                    print("WebSocketServer: Origin denied")
                    #endif
                    return (false, [:])
                }
            }
            var extraHeaders: [String: String] = [:]
            if let _ = self.protocols {
                if let accepted = self.getAcceptedProtocol(request) {
                    extraHeaders["Sec-WebSocket-Protocol"] = accepted
                } else {
                    #if DEBUG
                    print("WebSocketServer: Sec-WebSocket-Protocol denied")
                    #endif
                    return (false, [:])
                }
            }
            return (true, extraHeaders)
        }

        server.onWebSocketDidOpen = { [weak self] wsConn in
            guard let self = self else { return }
            self.handleWebSocketDidOpen(wsConn)
        }

        commandDelegate?.run(inBackground: {
            server.start()
        })

        let result = CDVPluginResult(status: CDVCommandStatus_NO_RESULT)
        result?.setKeepCallbackAs(true)
    }

    @objc public func stop(_ command: CDVInvokedUrlCommand) {
        #if DEBUG
        print("WebSocketServer: stop")
        #endif

        if didStopOrDidFail {
            wsserver = nil
            didStopOrDidFail = false
        }

        guard wsserver != nil else {
            let r = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Server is not running")
            commandDelegate?.send(r, callbackId: command.callbackId)
            return
        }

        stopCallbackId = command.callbackId
        commandDelegate?.run(inBackground: { [weak self] in
            self?.wsserver?.stop()
        })

        let result = CDVPluginResult(status: CDVCommandStatus_NO_RESULT)
        result?.setKeepCallbackAs(true)
    }

    @objc public func send(_ command: CDVInvokedUrlCommand) {
        guard let uuid = command.argument(at: 0) as? String,
              let msg = command.argument(at: 1) as? String else {
            #if DEBUG
            print("WebSocketServer: Send: UUID or msg not specified.")
            #endif
            return
        }
        let wsConn = syncQueue.sync { connections[uuid] }
        guard let wsConn = wsConn else {
            #if DEBUG
            print("WebSocketServer: Send: unknown socket.")
            #endif
            return
        }
        commandDelegate?.run(inBackground: { wsConn.send(text: msg) })
    }

    @objc public func send_binary(_ command: CDVInvokedUrlCommand) {
        guard let uuid = command.argument(at: 0) as? String,
              let b64 = command.argument(at: 1) as? String,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            #if DEBUG
            print("WebSocketServer: Send: UUID or msg not specified.")
            #endif
            return
        }
        let wsConn = syncQueue.sync { connections[uuid] }
        guard let wsConn = wsConn else {
            #if DEBUG
            print("WebSocketServer: Send: unknown socket.")
            #endif
            return
        }
        commandDelegate?.run(inBackground: { wsConn.send(binary: data) })
    }

    @objc public func close(_ command: CDVInvokedUrlCommand) {
        guard let uuid = command.argument(at: 0) as? String else {
            #if DEBUG
            print("WebSocketServer: Close: UUID not specified.")
            #endif
            return
        }
        let code = (command.argument(at: 1, withDefault: -1) as? Int) ?? -1
        let reason = command.argument(at: 2) as? String

        let wsConn = syncQueue.sync { connections[uuid] }
        guard let wsConn = wsConn else {
            #if DEBUG
            print("WebSocketServer: Close: unknown socket.")
            #endif
            return
        }
        commandDelegate?.run(inBackground: {
            if code == -1 {
                wsConn.close()
            } else {
                wsConn.close(code: code, reason: reason)
            }
        })
    }

    // MARK: - WSConnectionDelegate

    fileprivate func handleWebSocketDidOpen(_ wsConn: WSConnection) {
        #if DEBUG
        print("WebSocketServer: WebSocket did open")
        #endif

        syncQueue.sync {
            for closedUUID in didCloseUUIDs {
                connections.removeValue(forKey: closedUUID)
            }
            didCloseUUIDs.removeAll()
            connections[wsConn.uuid] = wsConn
        }

        wsConn.delegate = self

        let request = wsConn.urlRequest
        let acceptedProtocol = protocols != nil ? (getAcceptedProtocol(request) ?? "") : ""
        let httpFields = request.allHTTPHeaderFields ?? [:]
        let resource = request.url?.query ?? ""

        let conn: [String: Any] = [
            "uuid": wsConn.uuid,
            "remoteAddr": wsConn.remoteHost,
            "acceptedProtocol": acceptedProtocol,
            "httpFields": httpFields,
            "resource": resource
        ]
        let status: [String: Any] = ["action": "onOpen", "conn": conn]
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        result?.setKeepCallbackAs(true)
        commandDelegate?.send(result, callbackId: startCallbackId)
    }

    func connection(_ conn: WSConnection, didReceiveText text: String) {
        #if DEBUG
        print("WebSocketServer: Websocket did receive text message")
        #endif
        let status: [String: Any] = ["action": "onMessage", "uuid": conn.uuid, "msg": text, "is_binary": false]
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        result?.setKeepCallbackAs(true)
        commandDelegate?.send(result, callbackId: startCallbackId)
    }

    func connection(_ conn: WSConnection, didReceiveBinary data: Data) {
        #if DEBUG
        print("WebSocketServer: Websocket did receive binary message")
        #endif
        let b64 = data.base64EncodedString()
        let status: [String: Any] = ["action": "onMessage", "uuid": conn.uuid, "msg": b64, "is_binary": true]
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        result?.setKeepCallbackAs(true)
        commandDelegate?.send(result, callbackId: startCallbackId)
    }

    func connection(_ conn: WSConnection, didCloseWithCode code: Int, reason: String, wasClean: Bool) {
        #if DEBUG
        print("WebSocketServer: WebSocket did close with code: \(code), reason: \(reason), wasClean: \(wasClean)")
        #endif
        lock.lock()
        didCloseUUIDs.append(conn.uuid)
        lock.unlock()

        let status: [String: Any] = ["action": "onClose", "uuid": conn.uuid, "code": code, "reason": reason, "wasClean": wasClean]
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        result?.setKeepCallbackAs(true)
        commandDelegate?.send(result, callbackId: startCallbackId)
    }

    // MARK: - Helpers

    private func getAcceptedProtocol(_ request: URLRequest) -> String? {
        guard let secProto = request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") else { return nil }
        let requested = secProto.components(separatedBy: ", ")
        for p in requested {
            if protocols!.contains(p) { return p }
        }
        return nil
    }
}
