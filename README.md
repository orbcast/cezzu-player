# cezzu-player

iOS 17+ / macOS 14+ 的在线视频播放器（SwiftUI，Swift 6），界面是原 Cezzu 的首页 / 搜索 / 详情 / 追剧 / 设置。

播放器本身**不内置任何内容来源**。搜索、首页、详情元数据、选集、取流都由你添加的 **ref** 提供，ref 遵循 **cezzu-refs 协议**。数据不再依赖任何固定的元数据站点。

## 它做什么

- 添加 ref（清单 URL 或本地目录），添加前列出它能访问的域名和能力，由你确认；同一时间使用一个当前 ref，可随时切换。
- 首页、搜索、详情、选集、播放沿用原来的界面。ref 没提供的内容（比如没有 `home()`）对应位置留空。
- 追剧、观看历史、搜索历史存在本机（SwiftData）。
- 播放层：AVPlayer、本地反向代理（注入 Referer / UA / 签名头、HLS 重写、分片缓存）、Anime4K 超分、弹幕（DanDanPlay，按作品标题加集数匹配）、AirPlay、画中画。

## 它不做什么

- 不带任何 ref，也不带默认的 ref 来源。首次启动是空状态，需要你自己添加。
- 没有账号，也不上传任何数据。

## cezzu-refs 协议

一个 ref = `manifest.json` + 入口文件。入口是一段 JS 脚本，实现三个函数，运行在 JavaScriptCore 沙箱里：

```js
search(keyword)    -> [{ id, title, cover?, group?, summary?, rating?, tags?, ... }]
episodes(id)       -> [{ name, episodes: [{ id, title }] }]
resolve(episodeId) -> { url, kind?, headers?, expiresAt? } | { sniff, ... }
// 可选，没实现则界面留空
home()             -> [{ title, items: [Item] }]
browse({tag,page}) -> [Item]
detail(id)         -> Item | null
```

沙箱里只有 `http`（受 `allowedHosts` 约束）、`html`（XPath）、`crypto`（需声明）、`log`、`now`。完整规范见协议仓库。

## 构建

```bash
cd cezzu/CezzuKit
swift build          # 库 + CezzuMac 可执行文件
swift test
swift run CezzuMac   # 直接运行 macOS 版
```

Xcode 工程由 XcodeGen 生成：`cd cezzu && xcodegen generate`（`project.yml` 是唯一权威）。

## 许可

MIT，见 `LICENSE`。弹幕来自 DanDanPlay 公开 API，超分使用 Anime4K，XPath 解析使用 Kanna，详见 `cezzu/CezzuKit/LICENSES.md`。
