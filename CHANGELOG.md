## [2.0.0] - 2026-11-04

### Breaking changes

- Requires `cordova-android` >= 14.0.0 and `cordova-ios` >= 6.0.0 (enforced via `<engines>`), and iOS 15 or later. The plugin sets the iOS `deployment-target` to 15.0 and `SwiftVersion` to 5.0 by default; an app's own `config.xml` values take precedence
- [iOS] Dropped the `cordova-plugin-add-swift-support` dependency (`cordova-ios` 6+ builds Swift plugins natively)
- [Android] Removed the unused `ACCESS_WIFI_STATE` permission

### Build fixes

- [Android] Fix build failure with `Java-WebSocket` 1.6.0 (`stop()` no longer throws `IOException`), broken since 1.1.0
- [iOS] Fix compile error in `onClose` handling (undeclared `lock`)
- [iOS] Builds on `cordova-ios` 6/7 (`unable to resolve module dependency: 'Cordova'`: `Cordova` is only imported where it is a module) and on `cordova-ios` 8 (stricter Swift annotations made `CDVPluginResult` non-optional)

### Fixed: both platforms

- Stop the server on page reload/navigation (`onReset`), so the new page can call `start()` again
- Messages and close requests are delivered in the order they were sent

### Fixed: Android

- Race conditions on the connection maps, and `NullPointerException`s after a server failure
- `start()`/`stop()` race: the server is created and registered before `start()` returns, so an immediate `stop()` or second `start()` sees it
- `onDestroy` no longer stops the server on the UI thread (possible ANR)
- `close(conn, code)` without a reason no longer sends the reason `"null"`
- `onOpen` now includes `acceptedProtocol`, as documented
- Address reuse is enabled, so the server can restart on the same port immediately
- `getInterfaces` returns an empty result instead of crashing on devices without network interfaces
- Error results are no longer followed by a second `INVALID_ACTION` result

### Fixed: iOS

- Out-of-bounds read and NULL-pointer crashes in `getInterfaces`; IPv6 link-local addresses now include the scope (e.g. `fe80::1%en0`), as on Android
- Crashes on invalid close codes from JS and on oversized 64-bit frame lengths from clients
- Data races: plugin state is only touched on the main thread, and the listener only on its own queue (a `stop()` right after `start()` could leave the port bound)
- A server that fails to start no longer sends a result to an earlier `stop()` call's callback; each server's events go only to the callback of the `start()` that created it
- `stop()` closes connected clients with code 1001 and reports `onClose` for each before the stop callback, as on Android. It frees the plugin immediately for a new `start()`, and its result reports the actual port when started on port 0
- Server-initiated `close()` performs the closing handshake: `onClose` reports the client's code with `wasClean: true` (1006 only if the client doesn't answer within 5 s); no data is sent after a close
- `resource` is the full request target (e.g. `/?param1=value1`) instead of only the query string, matching Android
- Closed connections are removed right away instead of when the next client connects
- Subprotocol negotiation accepts `a,b`, extra spaces, and repeated `Sec-WebSocket-Protocol` headers
- A connection no longer stops reading after an empty or short read from the network

### Changed

- [iOS] Incoming messages are limited to 16 MiB; larger ones close the connection with code 1009
- [iOS] `close()` rejects invalid close codes with an error and truncates reasons to 123 bytes
- [iOS] Use CryptoKit for the handshake accept key instead of the deprecated `CC_SHA1`; drop the unused `Security.framework`
- [iOS] Faster unmasking of incoming frames
- [Android] Binary messages are Base64-encoded without line wrapping
- [Android] Subprotocols are negotiated by a single draft; message bodies and HTTP headers are no longer logged
- [Android] Replace the deprecated `initialize()` override with `pluginInitialize()`
- [JS] `start()` accepts a missing `options` argument; `send()` handles typed-array views correctly and encodes large buffers faster

## [1.1.0] - 2026-04-01

- [Android] Replace deprecated `jcenter()` with `mavenCentral()` in build config
- [Android] Upgrade `Java-WebSocket` dependency from `1.4.0` to `1.6.0`

## [1.0.0] - 2026-03-31

- Simplified Android package from `net.becvert.cordova` to `cordova.wsserver`
- [iOS] Removed `libPocketSocket` dependency — replaced with pure Swift implementation using `Network.framework`
- [iOS] Removed bridging header (`WebSocketServer-Bridging-Header.h`)
- [iOS] Removed `CFNetwork.framework` and `libz.tbd` from plugin dependencies
