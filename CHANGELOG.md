## [1.1.0] - 2026-04-01

- [Android] Replace deprecated `jcenter()` with `mavenCentral()` in build config
- [Android] Upgrade `Java-WebSocket` dependency from `1.4.0` to `1.6.0`

## [1.0.0] - 2026-03-31

- Simplified Android package from `net.becvert.cordova` to `cordova.wsserver`
- [iOS] Removed `libPocketSocket` dependency — replaced with pure Swift implementation using `Network.framework`
- [iOS] Removed bridging header (`WebSocketServer-Bridging-Header.h`)
- [iOS] Removed `CFNetwork.framework` and `libz.tbd` from plugin dependencies
