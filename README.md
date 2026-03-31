# cordova-websocket-server

A lightweight WebSocket Server plugin for Cordova applications.

- Pure Swift implementation on iOS (no third-party libraries, uses `Network.framework`)
- Java implementation on Android (uses [Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket))
- Not a background service — the server stops when the Cordova view is destroyed

## Installation

```bash
cordova plugin add cordova-websocket-server
```

## Usage

```javascript
var wsserver = cordova.plugins.wsserver;
```

---

### `start(port, options, success, failure)`

Starts the server on the given port. Use `0` to bind to any free port.
Listens on all available network interfaces (`0.0.0.0`).

```javascript
wsserver.start(
  8080,
  {
    // Server-level handler
    onFailure: function (addr, port, reason) {
      console.log('Server failed on %s:%d — %s', addr, port, reason);
    },
    // Connection handlers
    onOpen: function (conn) {
      /* conn: {
            uuid: '8e176b14-a1af-70a7-3e3d-8b341977a16e',
            remoteAddr: '192.168.1.10',
            acceptedProtocol: 'my-protocol-v1',
            httpFields: { ... },
            resource: '/?param1=value1'
        } */
      console.log('Client connected from %s', conn.remoteAddr);
    },
    onMessage: function (conn, msg) {
      // msg is a String (text frame) or ArrayBuffer (binary frame)
      console.log('Message from %s: %o', conn.remoteAddr, msg);
    },
    onClose: function (conn, code, reason, wasClean) {
      console.log('Client disconnected from %s (code %d)', conn.remoteAddr, code);
    },
    // Options
    origins: ['file://'], // validate Origin header
    protocols: ['my-protocol-v1', 'my-protocol-v2'], // validate Sec-WebSocket-Protocol header
    tcpNoDelay: true, // disable Nagle's algorithm
  },
  function onStart(addr, port) {
    console.log('Listening on %s:%d', addr, port);
  },
  function onDidNotStart(reason) {
    console.log('Failed to start: %s', reason);
  },
);
```

---

### `stop(success, failure)`

Stops the server and closes all connections.

```javascript
wsserver.stop(function (addr, port) {
  console.log('Stopped listening on %s:%d', addr, port);
});
```

---

### `send(conn, msg)`

Sends a message to a connection.
Pass a `String` for a text frame, or a `TypedArray`/`ArrayBuffer` for a binary frame.

```javascript
// Text
wsserver.send(conn, 'hello!');

// Binary
wsserver.send(conn, Uint8Array.from([1, 2, 3, 4]));
```

---

### `close(conn, code, reason)`

Closes a connection. Code and reason are optional.

```javascript
wsserver.close(conn, 4000, 'bye');
```

---

### `getInterfaces(success, failure)`

Returns all non-loopback IPv4 and IPv6 network interfaces.

```javascript
wsserver.getInterfaces(function (result) {
  for (var iface in result) {
    if (result.hasOwnProperty(iface)) {
      console.log(iface, result[iface].ipv4Addresses, result[iface].ipv6Addresses);
    }
  }
});
```

---

## Platform Notes

| Platform | Min Version | WebSocket Implementation                                        |
| -------- | ----------- | --------------------------------------------------------------- |
| iOS      | 12.0        | Pure Swift (`Network.framework`)                                |
| Android  | —           | [Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket) |

## License

MIT
