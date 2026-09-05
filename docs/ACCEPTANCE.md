<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# 验收记录

编译与测试在 GitHub Actions `macos-15` runner 上执行（Xcode 16.4，iPhone 模拟器）。命令：

```text
xcodebuild build -scheme Tsuyomi -destination "id=<iPhone simulator>" -skipMacroValidation SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
xcodebuild test  -scheme Tsuyomi -destination "id=<iPhone simulator>" -skipMacroValidation
```

## M0 工程与协议 — 通过

| 项 | 结果 |
|---|---|
| 零警告构建 | `** BUILD SUCCEEDED **`，`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |
| `TsuyomiProtocol` 测试 | `Executed 29 tests, with 0 failures` |
| `reader/**` fixture | `valid-reader-locator.json`、`valid-forum-navigation.json`、`valid-thread-page-document.json` 解析成功且再序列化语义相等 |
| `transfer/**` fixture | `valid-minimal.json` 往返、`noncanonical-order.json` 导出规范化、`duplicate-book-identity.json` 拒绝、`conformance-progress-conflict.json` 四条用例逐条断言 |
| `SmartRule` 违规码 | `empty-group`、`invalid-term-count`、`invalid-rating-range`、`invalid-time-window`、`invalid-text-length`、`max-depth`、`max-nodes` 与 Android 一致 |

## M1 宿主基础 — 通过

| 项 | 结果 |
|---|---|
| `TsuyomiCore` 测试 | `Executed 45 tests, with 0 failures` / `** TEST SUCCEEDED **` |
| 网络策略 | 未授权 origin、Cookie 头、重定向到未声明 origin、响应上限、gb18030 解码、POST 不入缓存与 64 KiB 体上限、按扩展版本分区的缓存与 Cookie 隔离 |
| 远端写面 | direct-action 令牌单次生效、拒绝时零传输、通用上下文无法到达签名 add 面、字面量/游标/声明重定向逐条校验 |
| 存储与凭据 | 路径遍历拒绝、持久根拒绝为写入牺牲已有数据、cache 根 LRU、AAD 绑定 source/origin、损坏记录就地作废 |
| 数据库 | `user_version = 4` 与 15 张表逐一存在、外键级联、`display_order` 重排幂等且要求全集、进度冲突（更新者胜/等值保留）、智能书架编译为参数化查询并命中预期集合、远端合并租约、导出→导入逐字段相等 |

## M2 扩展运行时 — 通过

| 项 | 结果 |
|---|---|
| `TsuyomiSource` 测试 | `Executed 22 tests, with 0 failures`（QuickJS 8 + HXP 校验 8 + wenku8 回放 6），另加 `package-policy-cases` 表驱动用例 |
| QuickJS-ng 0.16.1 | 作为 `CQuickJS` C target 内嵌并在 iOS 模拟器上构建通过；源码 SHA-256 见 `Sources/CQuickJS/quickjs-ng/UPSTREAM.md` |
| 运行时上限 | 死循环在 300 ms 墙钟内被中断、内存上限触发、栈深受限、取消后 context 丢弃并由已验证模块重建、`import` 被模块加载器拒绝、非 JSON 返回与缺失函数是不同错误 |
| `wenku8-fixture.hxp` | 校验通过（发布者指纹、`integrity.files`、RFC 8785 `contentDigest`、Ed25519 签名）；翻转一个字节后拒绝；未知/已撤销发布者、已撤销包摘要、不兼容 hostApi 各自拒绝 |
| HTML 回放 | search/detail/directory/chapter 的字段值与 `tsuyomi-extensions/test/wenku8.test.mjs` 的断言一致；challenge 页转为类型化 `SourceException` 且诊断不含原始 HTML；远端书架读取零 POST、零请求体 |
| 更新策略 | `package-policy-cases.json` 七条用例全部通过（无能力增长接受、新增 webLogin/home 需授权、已撤销先于版本判定、已确认轮换接受、未确认换钥拒绝、回滚拒绝） |

## M3 阅读闭环 — 进行中

| 项 | 结果 |
|---|---|
| reader engine | `Executed 10 tests`：精确/降级/邻近锚点解析、三种呈现共享同一 locator、capture 只推进时钟、降级捕获不顶替精确捕获、快照必须自证溯源、切换事务只接受自己的当前见证、陈旧代取消、文档缓存 LRU |
| TextKit 2 分页 | 页面计划恰好划分排版文本（无重叠、无空隙、末页对齐存储长度）；除末页外每页不超过视口高度；字号变更产生新 layout key 且语义位置仍可解析；仅换主题不改变 layout key；星际字符的码点/UTF-16 偏移换算正确 |
| 受控 WebView | 导航溯源测试 7 条：宿主发起的加载落定并绑定、观察到的服务端重定向保留请求溯源、用户手势导航作废绑定、无显式请求时不绑定、Cookie 主机匹配跟随声明 origin |
| 尚未完成 | `ReaderScreen` 与 Browse/Search/Book 三屏、`AppContainer`/路由/Xcode App target、端到端旅程 |

## 未完成项

| 项 | 原因 |
|---|---|
| 反向 import 编译失败验证 | 依赖图已由 `Package.swift` 强制（`TsuyomiProtocol` 无依赖、`TsuyomiCore → TsuyomiProtocol`、`TsuyomiSource → CQuickJS/TsuyomiCore`、`TsuyomiReader → TsuyomiCore`）；一次性反向 target 验证待 App target 建立后补记 |
| Xcode App target / 模拟器冷启动 | 随 M3 的第一块 UI 建立 |
| `KeychainAesGcm` 单元测试 | 模拟器 SPM 测试无 keychain 授权；分区语义由内存 `AeadPort` 覆盖，生产实现走集成路径 |
| M3–M6 | 进行中/未开始 |
