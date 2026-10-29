# Core

Platform-independent logic (Foundation / Network / CryptoKit only — no UIKit/SwiftUI).
Compiled into the iOS app and, via the root `Package.swift`, into the `BiliCore` library used by
`swift test`.

- `Networking/` — `BiliHTTP` client, WBI / app signing, API services.
- `Models/` — models built from lenient `JSON`.
- `Acceleration/` — BTR-style multi-CDN, multi-connection range downloader, local HTTP proxy,
  DASH(sidx) → HLS playlist generation.
- `Danmaku/` — protobuf segment decoding, filtering, layout model.
- `SmartSkip/` — Swift port of BiliSmartSkip (in-video ad segment detection).
- `Filter/` — feed filtering ("屏蔽广告视频").
- `Settings/` — persisted settings groups.
