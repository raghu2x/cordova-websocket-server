## [1.0.0] - 2026-03-31

- Simplified Android package from `net.becvert.cordova` to `cordova.wsserver`
- [iOS] Removed `libPocketSocket` dependency — replaced with pure Swift implementation using `Network.framework`
- [iOS] Removed bridging header (`WebSocketServer-Bridging-Header.h`)
- [iOS] Removed `CFNetwork.framework` and `libz.tbd` from plugin dependencies
