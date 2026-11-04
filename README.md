# cordova-websocket-server

[![Build](https://github.com/raghu2x/cordova-websocket-server/actions/workflows/build.yml/badge.svg)](https://github.com/raghu2x/cordova-websocket-server/actions/workflows/build.yml)

A lightweight WebSocket Server plugin for Cordova applications.

- Pure Swift implementation on iOS (no third-party libraries, uses `Network.framework`)
- Java implementation on Android (uses [Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket))
- Not a background service — the server stops when the Cordova view is destroyed, or when the page reloads or navigates away

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

Stops the server and closes all connections with code `1001` (going away). `onClose` is called for each connection before the success callback, and `start()` can be called again right away.

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

Closes a connection. Code and reason are optional; without a code, the connection is closed with `1000` (normal closure).

- `code` must be a valid WebSocket close code: `1000`–`1003`, `1007`–`1014` or `3000`–`4999` (`4000`–`4999` are free for application use). On iOS, other codes are rejected with an error.
- `reason` is limited to 123 bytes of UTF-8 by the protocol; longer reasons are truncated on iOS.
- `onClose` is called when the client has answered the close (or the connection drops), with the code the client sent back.

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

| Platform | Cordova platform  | Min OS version | WebSocket Implementation                                        |
| -------- | ----------------- | -------------- | --------------------------------------------------------------- |
| iOS      | `cordova-ios` 6+  | iOS 15.0       | Pure Swift (`Network.framework`)                                |
| Android  | `cordova-android` 14+ | Android 7.0 (API 24) | [Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket) |

### Limits

- **iOS:** incoming messages are limited to 16 MiB (a single frame, or all fragments of one message together). A larger message closes the connection with code `1009` (message too big).
- Messages are passed between native code and JavaScript through the Cordova bridge; binary messages are Base64-encoded on the way, which adds about 33% overhead. Very large or very frequent messages are better split up.

### iOS deployment target

The plugin requires iOS 15 or later. It sets `deployment-target` to `15.0` and `SwiftVersion` to `5.0` for you, because the `cordova-ios` 6/7 templates default to iOS 11 and set no Swift version. Preferences in your app's `config.xml` take precedence, so you can still choose a higher target; a value below `15.0` will make the build fail:

```xml
<platform name="ios">
    <preference name="deployment-target" value="16.0" />
</platform>
```

## License

MIT
