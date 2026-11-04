## [Unreleased]

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
