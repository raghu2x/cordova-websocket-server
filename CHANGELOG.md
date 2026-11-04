## [Unreleased]

- **Breaking:** requires `cordova-android` >= 14.0.0 and `cordova-ios` >= 6.0.0 (enforced via `<engines>`); iOS 15 or later; the plugin sets `deployment-target` 15.0 and `SwiftVersion` 5.0 by default (an app's own `config.xml` values take precedence)
- Stop the server on page reload/navigation (`onReset`), so a new page can call `start()` again (both platforms)
- [iOS] `stop()` now closes connected clients with code 1001 and reports `onClose` for each before the stop callback, as on Android
- [iOS] Server-initiated `close()` performs the closing handshake: `onClose` reports the client's code with `wasClean: true` (1006 only if the client doesn't answer within 5 s); no data is sent after a close
- [iOS] `resource` is the full request target (e.g. `/?param1=value1`) instead of only the query string, matching Android and the README
- [Android] `close(conn, code)` without a reason no longer sends the reason `"null"`
- [Android] `onOpen` now includes `acceptedProtocol`, as documented
- [Android] Enable address reuse so the server can restart on the same port immediately
- [Android] Fix `start()`/`stop()` race: the server is created and registered before `start()` returns, so an immediate `stop()` or second `start()` sees it
- [Android] `onDestroy` no longer stops the server on the UI thread (possible ANR)
- [Android] `getInterfaces` returns an empty result instead of crashing on devices without network interfaces
- [Android] Error results are no longer followed by a second `INVALID_ACTION` result
- [iOS] Fix data races: plugin state is now only touched on the main thread, and the server's listener only on its own queue (a `stop()` right after `start()` could leave the port bound)
- [iOS] A server that fails to start no longer sends a result to an earlier `stop()` call's callback; each server's events go only to the callback of the `start()` that created it
- [iOS] `stop()` frees the plugin immediately for a new `start()`, as on Android, and its result reports the actual port when started on port 0
- [iOS] Closed connections are removed right away instead of when the next client connects
- [iOS] Subprotocol negotiation accepts `a,b` and extra spaces, and repeated `Sec-WebSocket-Protocol` headers
- [iOS] A connection no longer stops reading after an empty or short read from the network
- [iOS] Use CryptoKit for the handshake accept key instead of deprecated `CC_SHA1`; drop unused `Security.framework`
- [Android] Fix build failure with `Java-WebSocket` 1.6.0 (`stop()` no longer throws `IOException`), broken since 1.1.0
- [Android] Replace deprecated `initialize()` override with `pluginInitialize()`
- [iOS] Fix compile error in `onClose` handling (undeclared `lock`)
- [iOS] Fix out-of-bounds read and NULL-pointer crashes in `getInterfaces`; IPv6 link-local addresses now include the scope (e.g. `fe80::1%en0`), as on Android
- [iOS] Reject invalid close codes and truncate close reasons to 123 bytes
- [iOS] Cap incoming messages at 16 MiB (connection closed with code 1009) and fix crash on oversized 64-bit frame lengths
- [iOS] Faster unmasking of incoming frames
- [iOS] Require `cordova-ios` >= 6.0.0; drop the `cordova-plugin-add-swift-support` dependency
- [Android] Fix race conditions on connection maps and `NullPointerException`s after a server failure
- [Android] Binary messages are Base64-encoded without line wrapping
- [Android] Subprotocols are negotiated by a single draft; message bodies and HTTP headers are no longer logged
- [Android] Remove unused `ACCESS_WIFI_STATE` permission
- Messages and close requests are now delivered in the order they were sent (both platforms)
- [JS] `start()` accepts a missing `options` argument; `send()` handles typed-array views correctly and encodes large buffers faster

## [1.1.0] - 2026-04-01

- [Android] Replace deprecated `jcenter()` with `mavenCentral()` in build config
- [Android] Upgrade `Java-WebSocket` dependency from `1.4.0` to `1.6.0`

## [1.0.0] - 2026-03-31

- Simplified Android package from `net.becvert.cordova` to `cordova.wsserver`
- [iOS] Removed `libPocketSocket` dependency — replaced with pure Swift implementation using `Network.framework`
- [iOS] Removed bridging header (`WebSocketServer-Bridging-Header.h`)
- [iOS] Removed `CFNetwork.framework` and `libz.tbd` from plugin dependencies
