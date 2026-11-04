import Foundation
import Network
import CryptoKit
// cordova-ios 8+ builds CordovaLib as a module. On cordova-ios 6/7 it isn't one, and the
// app's Bridging-Header.h (#import <Cordova/CDV.h>) exposes CDVPlugin etc. to Swift instead.
#if canImport(Cordova)
import Cordova
#endif

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
    /// Raw request target from the handshake, e.g. "/chat?token=abc".
    let resource: String

    private var fragmentBuffer: Data = Data()
    private var fragmentOpcode: WSOpcode = .textFrame
    private var isFragmenting: Bool = false
    private var didNotifyClose: Bool = false

    // Set once a close frame has been sent. Read and written from the plugin (main) thread
    // and the connection queue, hence the lock.
    private let closeLock = NSLock()
    private var closeSent: Bool = false

    /// Largest message (single frame or reassembled fragments) accepted from a client.
    static let maxPayloadSize = 16 * 1024 * 1024

    /// How long to wait for the client to answer our close frame before dropping the connection.
    static let closeTimeout: TimeInterval = 5

    /// Close codes an endpoint may send (RFC 6455 §7.4 + IANA registry).
    static func isValidCloseCode(_ code: Int) -> Bool {
        return (1000...1003).contains(code) || (1007...1014).contains(code) || (3000...4999).contains(code)
    }

    weak var delegate: WSConnectionDelegate?

    init(uuid: String, connection: NWConnection, remoteHost: String, urlRequest: URLRequest, resource: String) {
        self.uuid = uuid
        self.connection = connection
        self.remoteHost = remoteHost
        self.urlRequest = urlRequest
        self.resource = resource
    }

    func startReceiving() {
        receiveNextFrame()
    }

    func send(text: String) {
        // No data frames may follow a close frame (RFC 6455 §5.5.1)
        guard !isCloseSent, let data = text.data(using: .utf8) else { return }
        let frame = makeFrame(opcode: .textFrame, payload: data)
        connection.send(content: frame, completion: .idempotent)
    }

    func send(binary: Data) {
        guard !isCloseSent else { return }
        let frame = makeFrame(opcode: .binaryFrame, payload: binary)
        connection.send(content: frame, completion: .idempotent)
    }

    /// Starts the closing handshake: sends a close frame and keeps reading until the client
    /// answers with its own close frame (see `handleFrame`), which reports `onClose` with
    /// `wasClean: true`. If the client doesn't answer within `closeTimeout`, the connection is
    /// dropped and reported as 1006.
    func close(code: Int = 1000, reason: String? = nil) {
        guard markCloseSent() else { return }
        connection.send(content: makeCloseFrame(code: code, reason: reason), completion: .idempotent)
        let connection = self.connection
        DispatchQueue.global().asyncAfter(deadline: .now() + WSConnection.closeTimeout) {
            connection.cancel()
        }
    }

    /// Sends a close frame, drops the connection without waiting for the client's answer and
    /// reports `onClose` right away. Used for protocol violations and when the server stops.
    /// Must be called on the connection's queue.
    func terminate(code: Int, reason: String) {
        if markCloseSent() {
            connection.send(content: makeCloseFrame(code: code, reason: reason), completion: .contentProcessed { [connection = self.connection] _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
        notifyClose(code: code, reason: reason, wasClean: false)
    }

    private var isCloseSent: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return closeSent
    }

    /// Returns false if a close frame was already sent.
    private func markCloseSent() -> Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        if closeSent { return false }
        closeSent = true
        return true
    }

    private func makeCloseFrame(code: Int, reason: String?) -> Data {
        var payload = Data()
        var c = UInt16(WSConnection.isValidCloseCode(code) ? code : 1000).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &c) { Array($0) })
        if let r = reason {
            // Control frame payload is limited to 125 bytes, 2 of which are the code.
            // Drop whole characters so the reason stays valid UTF-8.
            var truncated = r
            while truncated.utf8.count > 123 { truncated.removeLast() }
            payload.append(Data(truncated.utf8))
        }
        return makeFrame(opcode: .connectionClose, payload: payload)
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
                guard payloadLength <= UInt64(WSConnection.maxPayloadSize) else {
                    self.terminate(code: 1009, reason: "Message too big")
                    return
                }
                self.readMaskAndPayload(masked: masked, length: Int(payloadLength)) { maskKey, payload in
                    let unmasked = masked ? self.unmask(payload: payload, key: maskKey!) : payload
                    self.handleFrame(fin: fin, opcode: opcodeRaw, payload: unmasked)
                }
            }
        }
    }

    private func readExtendedLength(payloadLen7: Int, completion: @escaping (UInt64) -> Void) {
        if payloadLen7 < 126 {
            completion(UInt64(payloadLen7))
        } else if payloadLen7 == 126 {
            receive(minLength: 2, maxLength: 2) { data in
                guard let data = data, data.count == 2 else { return }
                let len = UInt64(data[0]) << 8 | UInt64(data[1])
                completion(len)
            }
        } else {
            receive(minLength: 8, maxLength: 8) { data in
                guard let data = data, data.count == 8 else { return }
                var len: UInt64 = 0
                for i in 0..<8 { len = (len << 8) | UInt64(data[i]) }
                completion(len)
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
        // XOR in place over raw bytes; per-index Data subscripting is slow for large payloads.
        var result = payload
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for i in 0..<bytes.count {
                bytes[i] ^= key[i & 3]
            }
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
            if markCloseSent() {
                // Client started the closing handshake: echo its close frame, then drop the connection
                let frame = makeFrame(opcode: .connectionClose, payload: payload)
                connection.send(content: frame, completion: .contentProcessed { [connection = self.connection] _ in
                    connection.cancel()
                })
            } else {
                // Client answered the close frame we sent: handshake complete
                connection.cancel()
            }
            notifyClose(code: code, reason: reason, wasClean: true)

        case .ping:
            let pong = makeFrame(opcode: .pong, payload: payload)
            connection.send(content: pong, completion: .idempotent)
            receiveNextFrame()

        case .pong:
            receiveNextFrame()

        case .textFrame, .binaryFrame, .continuationFrame:
            if op == .continuationFrame {
                guard fragmentBuffer.count + payload.count <= WSConnection.maxPayloadSize else {
                    terminate(code: 1009, reason: "Message too big")
                    return
                }
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

    /// Reads exactly `minLength`...`maxLength` bytes. Short or empty deliveries on an open
    /// connection are accumulated and the read is re-issued, instead of silently stopping.
    private func receive(minLength: Int, maxLength: Int, accumulated: Data = Data(), completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: minLength - accumulated.count,
                           maximumLength: maxLength - accumulated.count) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            var data = accumulated
            if let content = content { data.append(content) }
            if data.count >= minLength {
                completion(data)
            } else if isComplete || error != nil {
                // Stream ended, possibly in the middle of a frame
                self.handleConnectionEnd()
                completion(nil)
            } else {
                self.receive(minLength: minLength, maxLength: maxLength, accumulated: data, completion: completion)
            }
        }
    }

    private func handleConnectionEnd() {
        notifyClose(code: 1006, reason: "Connection lost", wasClean: false)
    }

    private func notifyClose(code: Int, reason: String, wasClean: Bool) {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        delegate?.connection(self, didCloseWithCode: code, reason: reason, wasClean: wasClean)
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
    /// Port requested in start(); 0 means "any".
    let port: UInt16
    private let tcpNoDelay: Bool
    /// Listener and all connections run on this queue.
    let queue = DispatchQueue(label: "com.cordova.wsserver", qos: .userInitiated)

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

    /// Cancels the listener; `onDidStop` fires once it is cancelled. Like `start()`, call on `queue`.
    func stop() {
        guard let listener = listener else {
            // Never created (NWListener init failed): nothing to wait for
            onDidStop?(nil)
            return
        }
        listener.cancel()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            realPort = listener?.port?.rawValue ?? port
            onDidStart?(realPort)
        case .failed(let error):
            onDidFail?(error)
        case .cancelled:
            listener = nil
            onDidStop?(nil)
        default:
            break
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Read the HTTP upgrade request
        readHTTPRequest(conn: conn) { [weak self] parsed in
            guard let self = self, let parsed = parsed else {
                conn.cancel()
                return
            }
            let (request, resource) = parsed
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
                let wsConn = WSConnection(uuid: uuid, connection: conn, remoteHost: remote, urlRequest: request, resource: resource)
                self.onWebSocketDidOpen?(wsConn)
                wsConn.startReceiving()
            }
        }
    }

    // MARK: - HTTP Handshake Helpers

    private func readHTTPRequest(conn: NWConnection, completion: @escaping ((URLRequest, String)?) -> Void) {
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

    /// Returns the request and its raw request target (path + query, as sent by the client).
    private func parseHTTPRequest(_ data: Data) -> (URLRequest, String)? {
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
                // addValue folds repeated headers into one comma-separated value (RFC 7230 §3.2.2)
                request.addValue(value, forHTTPHeaderField: name)
            }
        }
        return (request, path)
    }

    private func makeAcceptKey(_ clientKey: String) -> String {
        // SHA-1 is mandated by RFC 6455 for the accept key; it is not used for security here.
        let digest = Insecure.SHA1.hash(data: Data((clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
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

    /// A connection known to JS, and the start() callback its events are sent to.
    private struct Registration {
        let conn: WSConnection
        let callbackId: String
    }

    // All plugin state is confined to the main thread: Cordova runs commands there, and every
    // server/connection callback (which arrive on the server's queue) hops to it before
    // touching state or sending results.
    private var wsserver: WSServer?
    private var connections: [String: Registration] = [:]

    override public func onReset() {
        // Page reload or navigation: the JS that started the server is gone, and a new page
        // calling start() would otherwise get "Server already running".
        // Dropping the registrations also drops any late events of a server still stopping.
        let conns = connections.values.map { $0.conn }
        connections.removeAll()
        guard let server = wsserver else { return }
        wsserver = nil
        shutdown(server, connections: conns, detach: true)
    }

    override public func onAppTerminate() {
        if let server = wsserver {
            server.queue.sync { server.stop() }
        }
        wsserver = nil
        connections.removeAll()
    }

    // MARK: - Cordova Commands

    @objc public func getInterfaces(_ command: CDVInvokedUrlCommand) {
        commandDelegate?.run(inBackground: {
            var obj = [String: [String: [String]]]()
            for intf in Interface.allInterfaces() {
                if !intf.isLoopback, let address = intf.address {
                    var intfobj = obj[intf.name] ?? ["ipv4Addresses": [], "ipv6Addresses": []]
                    if intf.family == .ipv6 {
                        if !intfobj["ipv6Addresses"]!.contains(address) {
                            intfobj["ipv6Addresses"]!.append(address)
                        }
                    } else if intf.family == .ipv4 {
                        if !intfobj["ipv4Addresses"]!.contains(address) {
                            intfobj["ipv4Addresses"]!.append(address)
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

        guard wsserver == nil else {
            sendError("Server already running", to: command.callbackId)
            return
        }

        guard let p = command.argument(at: 0) as? Int, p >= 0, p <= 65535 else {
            sendError("Port number error", to: command.callbackId)
            return
        }
        let origins = command.argument(at: 1) as? [String]
        let protocols = command.argument(at: 2) as? [String]
        let tcpNoDelay = (command.argument(at: 3) as? Bool) ?? false
        // Every event of this server goes to the callback of the start() that created it
        let callbackId: String = command.callbackId

        let server = WSServer(port: UInt16(p), tcpNoDelay: tcpNoDelay)
        wsserver = server

        server.onDidStart = { [weak self, weak server] realPort in
            DispatchQueue.main.async {
                guard let self = self, let server = server, self.wsserver === server else { return }
                #if DEBUG
                print("WebSocketServer: Server did start on port \(realPort)")
                #endif
                self.sendEvent(["addr": "0.0.0.0", "port": Int(realPort)], to: callbackId)
            }
        }

        server.onDidFail = { [weak self, weak server] error in
            DispatchQueue.main.async {
                // Ignore failures of a server that was already stopped or replaced
                guard let self = self, let server = server, self.wsserver === server else { return }
                #if DEBUG
                print("WebSocketServer: Server did fail: \(error)")
                #endif
                self.wsserver = nil
                let conns = self.removeConnections(of: callbackId)
                // Close its clients and stop the listener silently: the onFailure result below
                // is the final result of the start() callback, as on Android.
                self.shutdown(server, connections: conns, detach: true)
                let status: [String: Any] = ["action": "onFailure", "addr": "0.0.0.0", "port": Int(server.port), "reason": error.localizedDescription]
                self.sendEvent(status, to: callbackId, keepCallback: false)
            }
        }

        // Called on the server's queue; only uses values captured here
        server.onShouldAccept = { request in
            WebSocketServer.shouldAccept(request, origins: origins, protocols: protocols)
        }

        server.onWebSocketDidOpen = { [weak self, weak server] wsConn in
            // Set before the connection starts reading, so no message is missed
            wsConn.delegate = self
            DispatchQueue.main.async {
                guard let self = self, let server = server, self.wsserver === server else {
                    // The server was stopped while this client was completing its handshake
                    (wsConn.connection.queue ?? DispatchQueue.global()).async {
                        wsConn.delegate = nil
                        wsConn.terminate(code: 1001, reason: "Server stopping")
                    }
                    return
                }
                self.handleWebSocketDidOpen(wsConn, protocols: protocols, callbackId: callbackId)
            }
        }

        // On the server's queue, like everything else in WSServer, so a stop() issued right
        // after start() can't run before the listener exists. start() doesn't block.
        server.queue.async {
            server.start()
        }
    }

    @objc public func stop(_ command: CDVInvokedUrlCommand) {
        #if DEBUG
        print("WebSocketServer: stop")
        #endif

        guard let server = wsserver else {
            sendError("Server is not running", to: command.callbackId)
            return
        }

        // As on Android, the plugin is free for a new start() right away
        wsserver = nil
        let stopCallbackId: String = command.callbackId
        let conns = connections.values.map { $0.conn }
        shutdown(server, connections: conns, detach: false) { [weak self] port in
            guard let self = self else { return }
            // Each client's onClose was sent before this point; drop any registration left over
            for conn in conns where self.connections[conn.uuid]?.conn === conn {
                self.connections.removeValue(forKey: conn.uuid)
            }
            self.sendEvent(["addr": "0.0.0.0", "port": port], to: stopCallbackId, keepCallback: false)
        }
    }

    @objc public func send(_ command: CDVInvokedUrlCommand) {
        guard let uuid = command.argument(at: 0) as? String,
              let msg = command.argument(at: 1) as? String else {
            #if DEBUG
            print("WebSocketServer: Send: UUID or msg not specified.")
            #endif
            return
        }
        guard let wsConn = connections[uuid]?.conn else {
            #if DEBUG
            print("WebSocketServer: Send: unknown socket.")
            #endif
            return
        }
        // NWConnection.send is non-blocking and preserves call order; dispatching to a
        // concurrent background queue could reorder consecutive messages.
        wsConn.send(text: msg)
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
        guard let wsConn = connections[uuid]?.conn else {
            #if DEBUG
            print("WebSocketServer: Send: unknown socket.")
            #endif
            return
        }
        wsConn.send(binary: data)
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

        if code != -1 && !WSConnection.isValidCloseCode(code) {
            sendError("Invalid close code: \(code)", to: command.callbackId)
            return
        }

        guard let wsConn = connections[uuid]?.conn else {
            #if DEBUG
            print("WebSocketServer: Close: unknown socket.")
            #endif
            return
        }
        // Run on the calling thread so a close is ordered after any preceding sends.
        if code == -1 {
            wsConn.close()
        } else {
            wsConn.close(code: code, reason: reason)
        }
    }

    // MARK: - WSConnectionDelegate (called on the server's queue)

    private func handleWebSocketDidOpen(_ wsConn: WSConnection, protocols: [String]?, callbackId: String) {
        #if DEBUG
        print("WebSocketServer: WebSocket did open")
        #endif

        connections[wsConn.uuid] = Registration(conn: wsConn, callbackId: callbackId)

        let request = wsConn.urlRequest
        let acceptedProtocol = protocols.flatMap { WebSocketServer.acceptedProtocol(request, supported: $0) } ?? ""
        let conn: [String: Any] = [
            "uuid": wsConn.uuid,
            "remoteAddr": wsConn.remoteHost,
            "acceptedProtocol": acceptedProtocol,
            "httpFields": request.allHTTPHeaderFields ?? [:],
            "resource": wsConn.resource
        ]
        sendEvent(["action": "onOpen", "conn": conn], to: callbackId)
    }

    fileprivate func connection(_ conn: WSConnection, didReceiveText text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let registration = self.registration(of: conn) else { return }
            self.sendEvent(["action": "onMessage", "uuid": conn.uuid, "msg": text, "is_binary": false], to: registration.callbackId)
        }
    }

    fileprivate func connection(_ conn: WSConnection, didReceiveBinary data: Data) {
        let b64 = data.base64EncodedString()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let registration = self.registration(of: conn) else { return }
            self.sendEvent(["action": "onMessage", "uuid": conn.uuid, "msg": b64, "is_binary": true], to: registration.callbackId)
        }
    }

    fileprivate func connection(_ conn: WSConnection, didCloseWithCode code: Int, reason: String, wasClean: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let registration = self.registration(of: conn) else { return }
            #if DEBUG
            print("WebSocketServer: WebSocket did close with code: \(code), reason: \(reason), wasClean: \(wasClean)")
            #endif
            self.connections.removeValue(forKey: conn.uuid)
            let status: [String: Any] = ["action": "onClose", "uuid": conn.uuid, "code": code, "reason": reason, "wasClean": wasClean]
            self.sendEvent(status, to: registration.callbackId)
        }
    }

    // MARK: - Helpers

    /// The registration of `conn`, if it is still the connection JS knows under its uuid.
    private func registration(of conn: WSConnection) -> Registration? {
        guard let registration = connections[conn.uuid], registration.conn === conn else { return nil }
        return registration
    }

    /// Removes and returns the connections whose events go to `callbackId`.
    private func removeConnections(of callbackId: String) -> [WSConnection] {
        let owned = connections.values.filter { $0.callbackId == callbackId }
        for registration in owned { connections.removeValue(forKey: registration.conn.uuid) }
        return owned.map { $0.conn }
    }

    /// Closes every client with 1001 and stops the listener. Runs on the server's queue, so each
    /// client's onClose is sent before `completion` (matching Android, where onClose events come
    /// before the stop result). `completion` gets the port the server was listening on and runs on
    /// the main thread. With `detach`, the clients are cut off from the plugin first, so none of
    /// their events reach JS (used after a page reset or a server failure).
    private func shutdown(_ server: WSServer, connections conns: [WSConnection], detach: Bool, completion: ((Int) -> Void)? = nil) {
        server.queue.async {
            server.onDidStart = nil
            server.onDidFail = nil
            server.onShouldAccept = { _ in (false, [:]) }
            let port = Int(server.realPort != 0 ? server.realPort : server.port)
            // The closure holds the server strongly so it (and its listener) stays alive until
            // the listener reports it is cancelled; clearing it then breaks the cycle.
            server.onDidStop = { _ in
                server.onDidStop = nil
                if let completion = completion {
                    DispatchQueue.main.async { completion(port) }
                }
            }
            for conn in conns {
                if detach { conn.delegate = nil }
                conn.terminate(code: 1001, reason: "Server stopping")
            }
            server.stop()
        }
    }

    private func sendEvent(_ status: [String: Any], to callbackId: String, keepCallback: Bool = true) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        result?.setKeepCallbackAs(keepCallback)
        commandDelegate?.send(result, callbackId: callbackId)
    }

    private func sendError(_ message: String, to callbackId: String) {
        let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message)
        commandDelegate?.send(result, callbackId: callbackId)
    }

    private static func shouldAccept(_ request: URLRequest, origins: [String]?, protocols: [String]?) -> (accepted: Bool, responseHeaders: [String: String]) {
        if let origins = origins {
            guard let origin = request.value(forHTTPHeaderField: "Origin"), origins.contains(origin) else {
                #if DEBUG
                print("WebSocketServer: Origin denied")
                #endif
                return (false, [:])
            }
        }
        guard let protocols = protocols else { return (true, [:]) }
        guard let accepted = acceptedProtocol(request, supported: protocols) else {
            #if DEBUG
            print("WebSocketServer: Sec-WebSocket-Protocol denied")
            #endif
            return (false, [:])
        }
        return (true, ["Sec-WebSocket-Protocol": accepted])
    }

    /// The first protocol offered by the client that the server supports. The header is a
    /// comma-separated list, with or without spaces ("a, b" or "a,b").
    private static func acceptedProtocol(_ request: URLRequest, supported: [String]) -> String? {
        guard let header = request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") else { return nil }
        return header.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { supported.contains($0) }
    }
}
