# Tsuyomi iOS 移植任务规范（Prompt）

> 用途：将本 prompt 完整交给执行 agent。它是唯一的任务输入；`Tsuyomi-main/` 是只读参考源。
> 目标平台：**iOS 16.4 及以上**。

---

## 0. 角色与执行纪律

你是 Tsuyomi 的 iOS 宿主实现者。任务是把 `Tsuyomi-main/tsuyomi-android`（Kotlin/Compose，Phase 0–4A 已完成）**独立重实现**为原生 Swift/SwiftUI 宿主，消费同一份 `tsuyomi-protocol` 契约和同一批签名 `.hxp` 扩展。

执行纪律（违反任一条即视为交付缺陷）：

1. **不重新讨论已决策项。** 第 3 节的平台映射表、第 4 节的剔除项、第 7 节的 schema 都是冻结输入。只在遇到本文档未覆盖的问题时才做决策，且决策必须写入 `docs/DECISIONS.md` 一行，不写长篇论证。
2. **不做无关探索。** 读 Android 源码只为回答"这个行为的精确规则是什么"。不阅读 `prototype/ui-atlas`、`docs/design/UI_ATLAS.md`、`docs/design/DESIGN_*`、`tools/skills/`、所有 `*Test.kt`（除非第 9 节点名要求移植）、`docs/process/*`、`docs/phases/*`。
3. **不产生冗余代码。** 每个类型、函数、协议只在拥有它的最低层定义一次。禁止：只有一个实现且无第二实现计划的 protocol；包装系统 API 的透传层；"以防万一"的可配置项；未被消费的枚举值/字段/设置项；重复的 DTO（Swift 模型直接对应 protocol schema，不做"领域模型 + 传输模型"双份）。
4. **不做占位 UI。** 没有真实 handler、持久反馈和失败恢复的控件不出现。禁止"即将推出"、空入口、灰掉的假按钮。
5. **不写解释性注释。** 注释只允许两种：SPDX 头；说明某个非显然的安全/协议约束（引用协议文档段落）。
6. **每个里程碑结束时只输出**：变更文件列表、通过的测试命令与结果、未完成项及原因。不输出总结性散文。
7. 出现编译错误或测试失败时直接修根因，不加 `@unchecked`、`try!`、`as!`、`// swiftlint:disable`、`#if false` 之类的绕过。

---

## 1. 输入与输出

| 项 | 值 |
|---|---|
| 参考源（只读，不修改，不纳入工程） | `Tsuyomi-main/tsuyomi-android`、`Tsuyomi-main/tsuyomi-protocol`、`Tsuyomi-main/tsuyomi-extensions` |
| 输出根目录 | 本仓库根目录（与 `README.md`、`LICENSE` 同级） |
| `.gitignore` 追加 | `Tsuyomi-main/`、`*.xcuserstate`、`xcuserdata/`、`.build/`、`DerivedData/` |
| 许可证 | 仓库根 `LICENSE` 为 AGPL-3.0（iOS 仓库既有）。新建源文件 SPDX 头统一为 `SPDX-License-Identifier: AGPL-3.0-only`；`THIRD_PARTY_NOTICES.md` 记录 QuickJS-ng（MIT）及其源码 SHA-256 |
| 工具链 | 最新稳定 Xcode；Swift 6 语言模式；`-strict-concurrency=complete`；`IPHONEOS_DEPLOYMENT_TARGET = 16.4` |
| 分发假设 | 当前阶段 GitHub Releases IPA / 自签名侧载；App Store 上架**后置**，本轮不为其增加编译开关或降级路径。扩展市场（第 6.8 节）是一等功能。唯一需保持的余地：`ExtensionsFeature` 保持独立可摘除，未来 App Store 构建可整体排除远端仓库能力而不触及运行时 |
| 语言 | UI 文案 zh-Hans 为主，英文为次；使用 `String Catalog`（`.xcstrings`）。文案从 Android 各模块 `res/values/strings.xml` 逐条迁移，不新造措辞 |

---

## 2. 不变量（从 Android 继承，逐条生效）

- **本地优先**：无账号、无遥测、无远程开关、无崩溃自动上报、无 iCloud 同步。
- **协议优先**：与 Android 只通过 `tsuyomi-protocol` 的 JSON Schema、fixtures、`.hxp` 包规则互操作。iOS 不导入任何 Kotlin/Android 源码，也不引入 KMP。
- **来源隔离**：扩展只见 Host API；宿主拥有网络、Cookie、WebView、存储、资源上限、诊断脱敏。扩展不得获得任何 Foundation/UIKit 对象。
- **语义进度**：持久化 `ReaderLocator`（块 ID + 文本锚点摘要 + 码点偏移 + 有界回退），绝不持久化页码、像素、滚动百分比、布局缓存键。
- **用户介导验证**：登录/挑战只在受控 WKWebView 中由用户手动完成；不实现 CAPTCHA/Cloudflare 自动绕过；WebView 关闭不触发任何远端写入。
- **远端写入六条件**（`ANDROID_RUNTIME.md` §Source request path）逐条移植；`加入书架` 无条件仅本地。
- **可见性规则**：`docs/design/OPTION_APPLICABILITY.md` 的五步判定和可见性矩阵原样适用于每个设置项和动作。
- **错误模型**：跨层错误只允许 `SourceErrorCode` / `HostNetworkError` / `CredentialStorageError` 等既有枚举；原始 HTML、Cookie、Token、JS 堆栈永不进入 UI、日志、fixture、transfer 文件。

---

## 3. 平台决策表（冻结）

| Android | iOS 决策 | 约束 |
|---|---|---|
| Kotlin / Compose / Material 3 | Swift / SwiftUI；系统 HIG 组件（`List`、`NavigationStack`、`TabView`、`.sheet` + `presentationDetents`、`Menu`、`ContextMenu`、`Toolbar`） | 不引入第三方 UI 库；不复刻 Material 视觉，复刻**交互语义与信息架构** |
| Navigation Compose | `NavigationStack` + 每个 Tab 独立 `NavigationPath`；路由为 `Hashable` enum（第 6.7 节） | 无字符串路由 |
| ViewModel + StateFlow | `ObservableObject` + `@Published` + `@MainActor`；异步用 Swift Concurrency，取消用 `Task` 取消传播 | 不用 `@Observable`（iOS 17） |
| Room v4 | 系统 `SQLite3` + 一个内部薄封装（`Database` actor：open/migrate/transaction/query）。表结构与 Room v4 **逐列相同**（第 7 节） | 不用 SwiftData（iOS 17）、不用 Core Data、不引入 GRDB |
| DataStore | `UserDefaults(suiteName: "org.tsuyomi.ios")` | 只存非秘密偏好 |
| QuickJS-ng JNI（in-process） | **同版本 QuickJS-ng 0.16.1 源码作为 C target 内嵌**（文件集与 `source/quickjs-runtime/src/main/cpp/CMakeLists.txt` 相同：`dtoa.c libregexp.c libunicode.c quickjs.c cutils.c`）；桥接 C 文件 `tsuyomi_quickjs_bridge.c` 暴露与 `QuickJsNative` 同名同义的 6 个函数：`create / prepareOperation / evaluateModule / callJson / cancel / close` | 不用 JavaScriptCore（无公开的内存/中断/超时 API）。每个 `(extensionId, version)` 一个 `actor QuickJsRuntimeLane`，串行、不跨线程移动 context、超时后丢弃 context |
| OkHttp/UrlConnection 传输 | `URLSession(configuration: .ephemeral)`：`httpShouldSetCookies=false`、`httpCookieAcceptPolicy=.never`、`httpCookieStorage=nil`、`urlCache=nil`；重定向由 delegate `willPerformHTTPRedirection` 手动裁决（≤5 跳、必须命中声明 origin） | 宿主注入 `Cookie`/`User-Agent`；缓存由宿主 `HostNetworkCache` 实现，不用系统缓存 |
| 字符集解码 | `auto/utf-8` 用 Foundation；`gb18030` 用 `kCFStringEncodingGB_18030_2000`，`big5-hkscs` 用 `kCFStringEncodingBig5_HKSCS_1999`（经 `CFStringConvertEncodingToNSStringEncoding`）；解码失败 → `NETWORK_DECODE` | 不实现自定义码表 |
| Android Keystore AES-GCM | CryptoKit `AES.GCM`；主密钥 256-bit `SymmetricKey` 存 Keychain，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，`kSecAttrSynchronizable=false`；别名 `org.tsuyomi.ios.source-credentials.v1`；AAD 绑定规则与 ADR 0018 相同（格式版本 + sourceId + 精确 origin） | 不使用 Secure Enclave（不支持 AES）；不要求每次解密做生物认证 |
| Ed25519 / SHA-256 / RFC 8785 | CryptoKit `Curve25519.Signing` + `SHA256`；RFC 8785 规范化自实现（约 100 行，含数字序列化规则） | 不引入第三方 JSON 规范化库 |
| commons-compress ZIP 检查 | 内部最小 ZIP 读取器：只解析 central directory，仅支持 stored/deflate（`Compression` 框架 `COMPRESSION_ZLIB` 原始 deflate），先校验条目数/单文件大小/总解压大小/压缩比/路径安全再解压 | 拒绝加密、symlink、`..`、重复名、非 NFC 路径；不引入 ZIPFoundation |
| 受控 WebView | `WKWebView` + `WKWebsiteDataStore.nonPersistent()` 每会话新建；`customUserAgent` 与 URLSession 的 UA 字符串**完全一致**；`decidePolicyFor` 限制到声明 origin；完成后从 `WKHTTPCookieStore` 只读取声明 origin 的 Cookie 写入凭据分区；随后 `removeData(ofTypes: allWebsiteDataTypes)` | 禁止 `WKUserContentController.add`、`evaluateJavaScript`、user script |
| Coil/封面加载 | `HostCoverLoader` 移植为 actor；解码用 `UIImage(data:)` + `preparingThumbnail(of:)` 限制到显示尺寸；磁盘缓存键 = 源摘要 | 不引入 Kingfisher/Nuke |
| Compose TextMeasurer + Canvas | **TextKit 2**：`NSTextContentStorage` + `NSTextLayoutManager`，分页用 `enumerateTextLayoutFragments`，绘制用同一批 `NSTextLayoutFragment.draw(at:in:)` 于 `UIViewRepresentable` 自定义 `UIView` | "测量对象即绘制对象"是硬约束；不用 `UITextView`、不用 SwiftUI `Text` 做正文 |
| SAF 文件选择 | `.fileImporter` / `.fileExporter`（`UTType.json`），读取前 `startAccessingSecurityScopedResource` | transfer 文件限制 32 MiB |
| 音量键翻页 | **删除**（iOS 无公开 API） | 只保留点击区翻页 |
| 进程重建恢复 | `ScenePhase` 变化 + `NSUserActivity`（每 Tab 一个恢复态） | 恢复只从语义 locator |

---

## 4. 剔除项（不移植，不预留）

- **E-ink 全局显示 profile 整体删除**（iOS 无墨水屏设备）：不移植 `core/display` 的 `DisplayPreference.EINK`、`DisplayProfile`、`DeviceClassification`、`DisplayDecisionReason`、`redrawEpoch`、`displayRedrawLayer`、`MotionPolicy`；不移植 `docs/architecture/EINK.md`、ADR 0014；设置页无 profile 选择、无"立即重绘"。
  - 保留：`ColorSchemePreference { system, light, dark }`、阅读器主题（含低刺激/纸色主题）。
  - `defaultReaderPresentation(isEInk:)` 在 iOS 上固定为 `.paged`。
  - 动效遵守系统 `accessibilityReduceMotion`，这不是 E-ink 的替代品，不新增 motion policy 抽象。
- `reader/tts`（Android 为空）：**不创建**。（`feature/extensions` 在 Android 为空目录，iOS **实现为扩展市场**，见第 6.8 节。）
- `prototype/ui-atlas`、screenshot golden、Review Graph、`tools/skills`：不移植。
- 动态取色（Material You）：不移植，`dynamicColorEnabled` 字段不出现在 iOS 偏好中。
- Phase 4B（远端 remove/move）、Phase 4C（更新协调中心）、ESJZone/Yamibo、EPUB/TXT：不在范围。但 `ForumThreadNavigation` 与 `post` 块的**协议模型与校验**必须移植（第 6.1 节），只是无 UI 消费者。

---

## 5. 工程结构

单 Swift Package + 一个 Xcode App target。Package 名 `Tsuyomi`，target 与依赖方向如下（编译器强制，`Package.swift` 不允许反向依赖）：

```text
TsuyomiApp (Xcode app target, 组合根)
  → Feature*（LibraryFeature, BrowseFeature, SearchFeature, BookFeature, ReaderFeature, SettingsFeature, BackupFeature, ExtensionsFeature）
      → TsuyomiReader, TsuyomiSource, TsuyomiCore, TsuyomiUI, TsuyomiProtocol
  → TsuyomiReader → TsuyomiCore, TsuyomiProtocol
  → TsuyomiSource → CQuickJS, TsuyomiCore, TsuyomiProtocol
  → TsuyomiCore   → TsuyomiProtocol            （可 import Foundation/SQLite3/CryptoKit/WebKit/UIKit）
  → TsuyomiUI     → TsuyomiProtocol            （SwiftUI 语义组件，无业务能力判定）
  → TsuyomiProtocol                            （仅 Foundation；对应 Android shared/*）
  → CQuickJS                                   （C target，vendored quickjs-ng + bridge）
```

规则：
- Feature 之间不互相依赖。跨 feature 的共享类型下沉到 `TsuyomiProtocol` 或 `TsuyomiCore`。
- `TsuyomiProtocol` 禁止 import UIKit/SwiftUI/SQLite3/WebKit/CryptoKit。
- 测试 target 与源 target 一一对应；fixtures 以 SPM `resources` 引用 `Tsuyomi-main/tsuyomi-protocol/fixtures`、`Tsuyomi-main/tsuyomi-extensions/fixtures` 的**符号链接或构建期拷贝脚本**，不手工复制 JSON/HTML 进仓库。

---

## 6. 模块规范

每节格式：职责 → Android 参考路径 → iOS 实现要点 → 禁止项 → 必须的测试。类型名沿用 Android 名称（去掉 Kotlin 特有前缀），便于双端对照。

### 6.1 TsuyomiProtocol（对应 `shared/*`）

**参考**：`shared/model/BookIdentity.kt`、`shared/locator/ReaderLocator.kt`、`shared/source-contract/SourceContracts.kt`、`shared/smart-shelf/SmartShelf.kt`、`shared/backup/{TransferModels,TransferCodec,ImportPlanCodec,HikariBackupCodec}.kt`。

**实现**：
- 全部为 `struct`/`enum`，`Sendable`、`Equatable`，`Codable` 直接对应 schema 字段名；`init` 中执行与 Kotlin `init { require(...) }` **逐条相同**的校验，失败抛 `ProtocolError`（一个枚举，case 名 = Android 的 require 消息 slug）。
- `SourceId`、`HttpsOrigin`（含 `canonical`）、`DecodeMode`、`NetworkMethod`、`NetworkCacheMode`、`SourceNetworkRequest`（含"POST 必须 network-only"等规则）、`SourceNetworkResponse`、`SourceErrorCode`、`SourceDiagnostic`、`SourceException`、`SourceBookSummary`、`SourceHome*`（Filter/Option/Feature/Section/Page，含 16/16/4/100 上限）、`RemoteLibraryPage`、`RemoteLibraryAddOutcome/Result`、`SourceBookDetail`、`SourceChapter`、`SourceDirectory`、`ReaderBlock`（heading/paragraph/image/divider/quote/post）、`ReaderDocument`、`DocumentIdentity`、`LocatorPrecision`、`ReaderLocator`、`ForumThreadNavigation`。
- `SmartRule` AST + `SmartRuleValidator` + `SmartRuleCodec` + `HikariSmartRuleTranslator`。
- `TransferCodec`（导出排序 `(sourceId, remoteBookId)` 升序；导入拒绝重复身份/重复 shelf/悬空引用/父环；进度冲突取更新的 `updatedAt`，相等保留宿主记录）、`ImportPlanCodec`、`HikariBackupCodec`（schemaVersion 1；密钥字段只产生 warning 并丢弃）。
- JSON 用 `JSONSerialization` + 手写映射或 `Codable`，**二选一全模块统一**（决策：`Codable` + 自定义 `init(from:)` 只在需要校验/宽松解析处）。

**禁止**：任何 UI/DB 类型；Kotlin 的 `Instant` 用 `Date`，序列化固定 ISO-8601 UTC 无小数。

**测试**（XCTest）：加载 `tsuyomi-protocol/fixtures/**` 全部 JSON，valid 必须解析成功且再序列化后语义相等，invalid 必须抛对应错误；`conformance-progress-conflict.json`、`noncanonical-order.json`、`duplicate-book-identity.json` 逐条断言；`SmartRule` 的 validator 违规码与 Android 一致。

### 6.2 TsuyomiCore

#### 6.2.1 Database（对应 `core/database`）
- `actor TsuyomiDatabase`：`sqlite3_open_v2` + WAL + `PRAGMA foreign_keys=ON`；`user_version` 从 0 直接建到 **4**（新安装无历史，不移植 1→2→3→4 迁移代码，但 v4 DDL 逐字采用第 7 节）。
- 仓储按 Android 文件对应：`LibraryRepository`（books/library_entries/tags/history）、`CollectionStore`（collections/manual memberships/display_order 重排）、`LibraryCatalogStore`、`ReadingProgressStore`（写入合并：阅读中节流，章节切换/后台/退出/显式导航时 flush）、`RemoteLibraryStore`（reconciliation/grants/verified source）、`TransferRepository`（import_sessions/import_warnings）、`SmartShelfQueryCompiler`（AST → SQL，参数化，禁止字符串拼接值）。
- 观察：每个仓储对外暴露 `AsyncStream<Snapshot>`，由一个数据库级 `changeSequence` 触发重查（不做行级 diff）。

**测试**：每个仓储的事务不变量（外键级联、`display_order` 重排幂等、进度冲突规则、智能书架编译结果对固定数据集的命中集合）。

#### 6.2.2 Files（对应 `core/files`）
- `QuotaFileStore`：根目录 `Application Support/org.tsuyomi/{extensions,cache,credentials,media}`；`isExcludedFromBackup=true` 对 `credentials`、`cache`、`extensions`；文件保护 `.completeUntilFirstUserAuthentication`；`isSafeRelativePath` 规则相同；配额超限抛 `StorageException`。

#### 6.2.3 Preferences（对应 `core/preferences` + `core/display` 剩余部分）
- `AppPreferences`（`UserDefaults`）：`colorScheme`、`LibraryPresentationPreferences { shortcutOrder, shortcutLocked }`、`PortableReaderPreferences { flow, fontScale, lineHeight, theme }`、阅读器本地设置（`ReaderSettings` 第 6.4 节）。
- 通过 `AsyncStream` 或 `@Published` 暴露；无 profile 解析器。

#### 6.2.4 Network（对应 `core/network`）
- `HostNetworkGateway`（actor）：输入 `SourceNetworkGrant`（origins、cookie 分区、并发、超时、响应上限）+ `SourceNetworkRequest` + `SourceOperationContext`；执行顺序：origin 校验 → 头白名单 → body ≤64 KiB → 结构化 `query` + `queryEncoding` 序列化 → 缓存查询（`default/validate/offline-only`）→ 传输 → 逐跳重定向校验（≤5，origin 命中，远端操作必须精确命中签名 `redirects`）→ 响应大小上限 → 解码 → 缓存准入 → `SourceNetworkResponse`。
- `HostHttpTransport` 协议 + `URLSessionHostHttpTransport`（唯一实现；协议存在的理由是测试 fake，允许）。
- `HostNetworkCache`：`FileHostNetworkCache`（键 = extensionId + version + method + finalUrl + decode + semanticCacheKey）。
- `DirectActionTokenRegistry`、`SourceOperationContext`（`remoteLibraryReadContext/AddContext`，cursor 出现规则："宿主无 cursor 则省略，否则恰好出现一次"）。
- 错误映射到 `HostNetworkError`，`diagnosticId` 为随机 `[A-Za-z0-9_-]{8,128}`。

**测试**：移植 `HostNetworkGatewayPolicyTest / DirectActionTest / RemotePolicyTest / FileHostNetworkCacheTest / DirectActionTokenRegistryTest` 的每个用例（用 fake transport）。

#### 6.2.5 Security（对应 `core/security`）
- `AeadPort` 协议 + `KeychainAesGcm`（唯一生产实现；测试用内存实现）。
- `SourceCredentialStore`：记录 = `{schemaVersion, keyVersion, iv, ciphertext, nonsecret bookkeeping}`；AAD = `format-version || sourceId || canonical origin`；密钥不可用 → 只作废受影响记录并要求重新登录。
- `VerifiedBrowserSessionStore`：与 Android 字段一致。

**测试**：AAD 绑定、IV 唯一、source/origin 互换拒绝、密钥轮换与半程恢复、无明文进入 DB/UserDefaults/日志。

#### 6.2.6 Media（对应 `core/media`）
- `CoverRepository`/`HostCoverLoader`/`MediaOriginPolicy`：只允许声明 origin；解码上限到显示尺寸；`CoverUiState` 枚举一致；封面 URL 不进入 feature 层。

#### 6.2.7 WebView（对应 `core/webview`）
- `ControlledWebLoginSession`：输入 `(sourceId, 允许 origins, 起始 URL, UA)`；输出 `CapturedVerifiedPage` 或取消；`VerifiedPageNavigationTracker` 规则相同（只接受用户交互后到达的声明 origin 页面）。
- 每个终止路径（完成/取消/错误/后台杀死）都清空 data store。

### 6.3 TsuyomiSource（对应 `source/*`）

- `CQuickJS`：vendored quickjs-ng 0.16.1（校验源码包 SHA-256 `4b3c11f37dab2c58bdeccbaeb23b923fa4a9798a45e50be6af55f3e75b616ea0`）+ `tsuyomi_quickjs_bridge.c`。桥接行为逐条对齐 `tsuyomi_quickjs_jni.cpp`：`JS_SetMemoryLimit`、`JS_SetMaxStackSize`、`JS_SetInterruptHandler`（检查 deadline 与 cancel 标志）、`JS_Eval(... JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_BACKTRACE_BARRIER)`、模块加载器拒绝一切 import、`callJson` 以 JSON 字符串进出，返回非 JSON → `NON_JSON_RESULT`。
- `actor QuickJsRuntimeLane`：`QuickJsRuntimeLimits`（内存 1 MiB–64 MiB，墙钟 100–30000 ms）、`QuickJsRuntimeError` 九个 case 一致；超时/内存/取消后 `resetRequired`，下次操作用保存的 `VerifiedModule` 重建。
- `HxpModels`（`SemanticVersion`、各 `Hxp*Capability`、`HxpManifest`、`PublisherKey/Trust`、`HxpVerificationError`）、`HxpManifestParser`（键集合与 Android 相同：capabilities 必含 `network cookies webLogin remoteLibrary storage`，可选 `home`）、`HxpArchiveVerifier`（顺序：archive 限制 → 路径安全 → `integrity.files` 完整性 → `contentDigest` = SHA-256(RFC8785(files)) → Ed25519 消息 `"tsuyomi-hxp-v1\0" || RFC8785(manifest) || 0x00 || contentDigest`）、`ExtensionInstaller`（能力集比较：新增 origin/cookie/webLogin/remote 操作/storage 配额需新授权；资源上限增加需在审批 UI 展示）、`InstalledExtensionStore`。
- `SourceExtensionClient`：调用约定为 `globalThis.tsuyomiExtension.<fn>(...)`，函数名与参数顺序严格照 Android：`buildSearchRequest(query,page)`、`parseSearch(html,...)`、`buildHomeRequest(cursor,selectedFilters)`、`parseHome(html,cursor,selectedFilters)`、`buildDetailRequest(remoteBookId)`、`parseDetail(html,remoteBookId)`、`buildDirectoryRequest`、`parseDirectory`、`buildChapterRequest(url,remoteBookId,chapterId)`、`parseChapter(html,remoteBookId,chapterId,fallbackTitle)`、`buildRemoteLibraryRequest(cursor)`、`parseRemoteLibrary(html)`、`buildRemoteLibraryAddRequest(remoteBookId)`、`parseRemoteLibraryAdd(html,remoteBookId)`、`classifyPage(...)`。每个阶段名（`search-network`、`detail-parse` 等）沿用，作为诊断 `stage`。
- `Phase2TestPublisher`：`keyId = "tsuyomi-phase2-fixture"`，公钥 hex `79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664`，trust = `builtInTest`；只在 DEBUG 配置注册。
- `PublisherTrustStore`：`PublisherKeyResolver` 的持久实现（Android 只有内存版），记录 `{keyId, publicKey, fingerprint, trust, addedAt, sourceRepositoryId?}`，存 `QuotaFileStore` 的 `extensions/trust.json`；信任以公钥指纹为键，不以显示名为键（hxp-package-v1 §Trust）。
- `ExtensionRepositoryClient` + `RepositoryIndexCodec`：见第 6.8 节；`RepositoryIndexCodec` 是**唯一**在 Android 标准落地时需要改动的文件。

**测试**：安装/拒绝 `wenku8-fixture.hxp`（改一字节 → 签名失败；改 manifest 版本 → 回滚拒绝）；`package-policy-cases.json` 全部用例；死循环/内存压力/栈深/取消/非 JSON 返回/超时后不复用 context；用 `fixtures/wenku8/*.html` 回放 search/home/detail/directory/chapter/remote-library/remote-add 并与 Android 侧 `wenku8.test.mjs` 断言的字段值一致。

### 6.4 TsuyomiReader（对应 `reader/engine` + `reader/ui`）

**engine（纯 Swift，无 UIKit）**：逐文件移植 `ReaderEpochs`（`LayoutKey`、`ReaderEpochs`、`VisualCommitWitness`）、`SettledPositionSnapshot` + `SettledPositionCache` + `CaptureAdmission`、`ReaderDocumentSession`（locator 解析：精确块/锚点/偏移 → 邻近锚点 → 块进度 → 全文回退；`ResolvedReaderPosition`）、`ReaderDocumentCache(capacity: 5)`、`PresentationSwitchTransaction`（状态机与拒绝原因一致）、`PreviewSession`（WYSIWYG 拖动预览，冻结计划、合并输入、释放时需视觉见证）。`ReaderPresentation { scroll, paged, dualPage }`。

**measurement port**：engine 定义 `protocol TextMeasurementPort`（存在第二实现：测试用确定性 fake），生产实现在 ui 层用 TextKit 2。

**ui**：
- `ReaderSurface`（`UIViewRepresentable`）：一个 `NSTextContentStorage` 装载整章块序列（块→段落属性，heading/quote/divider/image 用 `NSTextAttachment` 或独立 fragment provider）；分页 = 按视口高度切 `NSTextLayoutFragment` 序列，页面计划不可变、增量扩展（先可见页 + 小方向窗口，空闲时扩展，任何 epoch 变化即丢弃）。
- locator ↔ 文本位置：块 ID → 该块在 storage 中的 `NSTextRange`；码点偏移 ↔ UTF-16 偏移转换只在此处做一次。
- 翻页：点击区（左/中/右）、横向 `UIPageViewController` 风格由自定义手势实现或 `TabView(.page)` **不采用**（无法与 TextKit fragment 精确对齐）；scroll 模式用 `UIScrollView` 承载同一 layout manager。
- `ReaderSettings { fontSize=18, lineHeight=1.6, horizontalMargin=24, paragraphSpacing=12, flow=.paged, lockPortrait=false, progressVisible=true, immersive=false, keepAwake=true }`；`keepAwake` → `UIApplication.isIdleTimerDisabled` 只在阅读器可见时为 true。
- `ReaderChrome`：顶栏（返回、标题、章节）、底栏（上一章/下一章、进度滑杆 = PreviewSession、设置）、辅助 sheet（目录/设置，`presentationDetents([.medium, .large])`）。

**测试**：移植 engine 全部 JVM 测试语义（capture 优先级、切换事务顺序、陈旧代取消、视觉提交门控、字体/宽度重排、内容修订、缺失锚点、相邻章节过渡、有意后退）；ui 层 XCTest 断言"分页边界来自与绘制相同的 fragment 集合"、进程重建后从 locator 恢复到同一块与偏移。

### 6.5 TsuyomiUI（对应 `core/ui`）

只移植有多处消费者的语义组件，每个组件对应一个 SwiftUI `View` 或 `ViewModifier`：`TsuyomiScaffold`（顶栏+内容+底栏插槽）、`StateViews`（loading/empty/error+retry/offline，统一一处）、`PaginationBar`、`SegmentedSelector`（`Picker(.segmented)` 封装带语义标签）、`SettingsRow`、`TsuyomiStatusBadge`、`CoverImage`（消费 `CoverUiState`）、`TsuyomiCoverGridCard`、`TsuyomiFilterCapsules`、`TsuyomiTabs`、`TsuyomiNavigationCard`。其余（Button/Switch/Dialog/OverflowMenu/PullToRefresh/ModalSheet/TopBar/AdaptiveListFab）**直接用系统控件，不封装**。

主题：`TsuyomiTheme` 只含颜色/字体 token（浅/深两套）+ 阅读器主题集（含纸色/低刺激）；全部走 `Color`/`Font` 语义名，遵守 Dynamic Type。

### 6.6 Features

每个 feature：一个 `*Screen` 树 + 一个 `*Model: ObservableObject`（屏幕生命周期）+ 路由 enum 中的 case。业务协调若跨屏幕，放在 App 层的 controller（对应 Android `app/` 下的 `*Controller/*Owner/*Coordinator`），不放 feature。

| Feature | Android 参考 | 必须行为 |
|---|---|---|
| Library | `feature/library/*`、`app/LibraryFlowController.kt`、`app/LibraryRoutes.kt` | 三布局（grid 三列/list/compact）；长按进入多选 + 选择栏（计数/全选/清空/批量加入或移动到收藏夹/本地删除）；书拖到书 → 建收藏夹，书拖入收藏夹，根目录插入位让位动画（`Layout` 协议实现），快捷栏重排；快捷栏锁定/内联收折（收折为 ≥44pt 手柄，点击/反向滚动/拖拽悬停展开）；单次长按连续拖拽；`display_order` 持久化；系统节点（历史/稍后读/未读更新）可隐藏/重建；标签页（本地/来源）；收藏夹管理与智能规则编辑（真实控件、内联 AST 错误、未保存返回确认） |
| Browse | `feature/browse/*`、`app/Source*.kt` | 已安装来源列表（登录状态、进入 Home/搜索/网站收藏）；顶栏入口进入扩展市场；Source Home：显式加载/筛选/下一页才发请求，≤16 筛选、≤16 栏目、≤4 特色目的地，等宽 4 tab，标签容器展开/收起；远端书架只读拉取 + 复制选中/全部到本地（零远端写入） |
| Extensions | 无 Android 对应（`feature/extensions` 为空）；规则来源 `tsuyomi-protocol/docs/hxp-package-v1.md` §Trust §Updates | 第 6.8 节 |
| Search | `feature/search/*` | 单会话/单进度/单结果流；提交在输入框内；历史（`search_history`）；离线时展示 `stale-offline` 标记 |
| Book | `feature/book/*` | 单一稳定身份详情页（封面、评分徽章、标签/稍后读、`加入书架` 本地、缓存动作）+ 集成目录（全章节、左对齐工具）；进入精确章节 |
| Reader | `feature/reader/ReaderScreen.kt` | 组合 6.4；只跨到相邻章节；退出/后台/切章 flush 进度 |
| Settings | `feature/settings/*` | 更多页（紧凑分组）；显示设置（外观 system/light/dark；无 profile）；阅读器默认值（排版/翻页/导航分组）；数据页（导入/导出/报告入口，明确 transfer 含/不含项）；帮助（可搜索折叠）与关于（许可证文本） |
| Backup | `feature/backup/TransferScreen.kt`、`app/Transfer*.kt` | 导出 `tsuyomi-transfer` v1；导入 `tsuyomi-transfer` 与 `hikari_novel_backup` v1 → 预览计划 → 执行 → 报告（警告折叠阈值 50）；导入会话审计写入 `import_sessions/import_warnings` |

### 6.7 App 组合根与导航

- `TsuyomiApp` → `RootTabs { library, browse, more }`，每个 tab 一个 `NavigationStack(path:)`。
- 路由 enum（与 Android `Routes` 一一对应，去掉 E-ink/验证页族的多余分裂只保留一个 `verification(kind:)`）：
  `library`, `librarySystem(filter)`, `libraryCollection(id)`, `libraryTags`, `libraryTag(tag)`, `collections`, `browse`, `sourceHome(sourceId)`, `search(sourceId)`, `detail(BookIdentity)`, `directory(BookIdentity)`, `reader(BookIdentity, chapterId)`, `verification(sourceId, VerificationKind)`, `remoteLibrary(sourceId)`, `extensions`, `extensionRepository(repositoryId)`, `extensionPackage(repositoryId, extensionId)`, `extensionInstallReview(PreparedExtensionInstall)`, `publisherKeys`, `more`, `display`, `readerDefaults`, `data`, `transfer`, `importReport(sessionId)`, `help`, `about`。`extensions*` 与 `publisherKeys` 的根为 `browse`。
- `rootRouteFor`、`routeOwnsSourceFlow`、`restorationTargetForRoute` 的语义迁移为 enum 的计算属性。
- 依赖组合：一个 `AppContainer`（普通 final class，构造器注入，无 DI 框架），在 `@main` 中创建一次，经 `environmentObject` 下发各 controller。
- `Source*Controller/Owner/Coordinator`、`TransferCoordinator`、`NormalizedSourceStore`、`SourceFlowSnapshotStore`、`RemoteExecutionLease`、`DisplayWriteArbiter`（改名 `LibraryWriteArbiter`，去掉 display 语义）按 Android `app/` 逐文件移植；`Phase2LocalTrust/Phase2SourceGateway` 用 `#if DEBUG` 区分，不做三套 build flavor。

### 6.8 扩展市场（ExtensionsFeature + TsuyomiSource 仓库层）

**定位**：可浏览、可添加第三方仓库的扩展市场。仓库 = 一个 HTTPS 基址（典型为 GitHub Pages 或 `raw.githubusercontent.com` 下的目录），其下静态托管签名索引与 `.hxp` 文件。宿主拉取索引、校验、展示、下载、安装；安装本身完全复用 6.3 的 `HxpArchiveVerifier → ExtensionInstaller` 路径，市场不引入第二条安装路径。

**索引格式状态**：Android 端的仓库标准尚未发布。iOS 先按下方 **`tsuyomi-repository` v0（临时）** 实现，全部字段限于 `hxp-package-v1.md` §Trust §Updates 已要求宿主校验的信息；标准落地后只替换 `RepositoryIndexCodec.swift` 与其 fixtures，其余代码不变。在 `docs/DECISIONS.md` 记一行"v0 为 iOS 临时格式，待 protocol 标准替换"。

```jsonc
// <base>/index.json —— 由 <base>/index.sig（64 字节 Ed25519 detached）签名
// 签名消息 = ASCII("tsuyomi-repository-v0\0") || UTF8(RFC8785(index.json))
{
  "format": "tsuyomi-repository",
  "version": 0,
  "repositoryId": "org.example.repo",          // [a-z][a-z0-9]*([.-][a-z0-9]+)+，与 SourceId 同规则
  "display": { "name": "…", "summary": "…" }, // 各 ≤ 120 码点
  "publisher": { "keyId": "…", "publicKey": "<64 hex>" },
  "issuedAt": "2026-09-05T00:00:00Z",
  "expiresAt": "2026-10-05T00:00:00Z",         // 必填；过期索引拒绝
  "packages": [{
    "id": "org.tsuyomi.wenku8", "version": "0.2.0",
    "hostApi": { "minInclusive": "1.0.0", "maxExclusive": "2.0.0" },
    "display": { "name": "…", "summary": "…" },
    "capabilities": { /* 与 manifest.capabilities 同结构，仅供安装前预览 */ },
    "file": "packages/org.tsuyomi.wenku8-0.2.0.hxp", // 相对 base 的安全路径，禁止绝对 URL
    "sha256": "<64 hex>", "sizeBytes": 123456
  }],
  "revocations": [{                             // 可为空数组
    "target": { "keyId": "…" } | { "packageDigest": "<64 hex>" },
    "reasonCode": "compromised|malicious|superseded|other",
    "issuedAt": "…", "expiresAt": "…",
    "signature": "<128 hex>"                    // 消息 = ASCII("tsuyomi-revocation-v0\0") || RFC8785(该条目去掉 signature 字段)
  }]
}
```

**宿主规则（全部为硬约束）**：
- 仅 HTTPS；索引 ≤ 1 MiB；单包 `sizeBytes` ≤ `HxpArchiveLimits` 的归档上限；下载后先比对 `sha256` 再进入 `HxpArchiveVerifier`。索引里的 `capabilities` 只用于预览；授权依据是下载后 manifest 的实际能力集，二者不一致 → 拒绝安装并显示 `INDEX_MANIFEST_MISMATCH`。
- 内置官方仓库：**本轮不实现**。官方仓库基址与根公钥均待定，不创建 `OfficialRepository.swift`，不写占位 URL，不在 DECISIONS 之外的任何位置提及"官方仓库"。市场首页在没有任何仓库时直接展示"添加仓库"入口与一段说明（仓库是什么、需要 HTTPS 基址）。将来官方仓库确定后，新增一个只含基址与根公钥的文件，首次启动时以 `trust = builtInOfficial` 预填一条 `PublisherTrustStore` 记录并预添加该仓库，其余逻辑不变。
- 添加第三方仓库：用户输入基址 → 拉取并验签 → 展示 `repositoryId`、显示名、发布者 `keyId` 与公钥指纹（SHA-256 前 16 字节，分组 hex）→ 用户确认后把发布者写入 `PublisherTrustStore`（trust = `userAdded`）。指纹变更 = 新发布者，必须重新确认；没有"自动接受新密钥"。
- 信任风险文案（`hxp-package-v1` §Trust、ADR 0013）：第三方发布者审批页必须写明"扩展在应用进程内运行，QuickJS 不是进程级沙箱；信任发布者等同于信任其代码"。
- 更新：同 `id` 只接受**严格更高**版本；相等/更低视为回滚拒绝。能力扩张（新增 origin / cookie / webLogin / remoteLibrary 操作 / storage 配额 / home）→ 进入 `extensionInstallReview` 重新授权；用户拒绝则旧版本保持激活。
- 撤销：索引中对本仓库发布者密钥或已装包摘要的有效撤销 → 停用受影响已装包并拒绝重装；仅接受由**已信任**密钥签名、未过期、目标匹配的撤销；较新的有效撤销优先。
- 密钥轮换（hxp-package-v1 §Trust）：v0 索引不承载轮换数据；轮换在 v0 下等同"新发布者，需用户重新确认"。
- 刷新只由用户显式触发（进入市场页的下拉/刷新按钮、包详情页的"检查更新"）；无后台刷新、无启动自动刷新。
- 每个仓库独立缓存目录 `extensions/repositories/<repositoryId>/`；删除仓库删除其缓存，但**不**卸载已装扩展、不删除其发布者信任（信任在 `publisherKeys` 页单独管理）。
- 卸载扩展：删除包文件、runtime lane、网络缓存分区、`source_availability` 行；**保留**凭据分区（用户在 `publisherKeys`/来源设置中单独清除）与书架数据（来源变为休眠）。

**屏幕**：
- `extensions`：分段（已安装 / 仓库）。已安装：版本、发布者、可更新徽章、卸载；仓库：仓库列表 + 添加仓库。
- `extensionRepository(id)`：包列表（名称、版本、已装/可更新/不兼容 hostApi/已撤销 四态）、刷新、删除仓库。
- `extensionPackage(repo, id)`：显示信息、能力预览（按 origin / cookie / webLogin / remoteLibrary / home / storage 分组）、资源上限、安装或更新按钮。
- `extensionInstallReview(prepared)`：复用本地导入 `.hxp` 的审批页（能力差异高亮、资源上限增量、发布者信任状态），是所有安装路径的唯一确认点。
- `publisherKeys`：已信任发布者列表（keyId、指纹、来源仓库、信任类型），可移除；移除会停用该发布者的全部已装包并给出确认。

**工具**：`tools/repository/build-index.mjs`（Node，仅 `node:crypto`）：输入包目录与 Ed25519 私钥文件，输出 `index.json` + `index.sig`，RFC 8785 规范化与 `tsuyomi-extensions/tools/build-fixture.mjs` 共用同一实现（复制该文件的规范化函数并注明来源）。测试 fixtures 用 `Phase2TestPublisher` 的公开种子在测试构建时生成，不提交生成物。

---

## 7. 数据库 schema（冻结，`user_version = 4`）

逐字采用；列类型、默认值、主键、外键、级联、索引不得改动：

```sql
CREATE TABLE books (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, title TEXT NOT NULL, authors_json TEXT NOT NULL DEFAULT '[]', author_sort_key BLOB, cover_url TEXT, canonical_url TEXT, status TEXT, remote_tags_json TEXT NOT NULL DEFAULT '[]', source_update_key TEXT, has_unread_update INTEGER NOT NULL DEFAULT 0, added_at_epoch_second INTEGER NOT NULL, added_at_nano INTEGER NOT NULL, metadata_updated_at_epoch_second INTEGER NOT NULL, metadata_updated_at_nano INTEGER NOT NULL, PRIMARY KEY(source_id, remote_book_id));
CREATE TABLE collections (collection_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, parent_collection_id TEXT, display_order INTEGER NOT NULL, created_at_epoch_second INTEGER NOT NULL DEFAULT 0, created_at_nano INTEGER NOT NULL DEFAULT 0, updated_at_epoch_second INTEGER NOT NULL DEFAULT 0, updated_at_nano INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(collection_id), FOREIGN KEY(parent_collection_id) REFERENCES collections(collection_id) ON UPDATE NO ACTION ON DELETE SET NULL);
CREATE INDEX index_collections_parent_collection_id ON collections(parent_collection_id);
CREATE TABLE library_entries (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, added_at_epoch_second INTEGER NOT NULL, added_at_nano INTEGER NOT NULL, rating INTEGER, read_later INTEGER NOT NULL DEFAULT 0, display_order INTEGER NOT NULL DEFAULT 2147483647, PRIMARY KEY(source_id, remote_book_id), FOREIGN KEY(source_id, remote_book_id) REFERENCES books(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE);
CREATE TABLE local_book_tags (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, normalized_tag TEXT NOT NULL, display_tag TEXT NOT NULL, PRIMARY KEY(source_id, remote_book_id, normalized_tag), FOREIGN KEY(source_id, remote_book_id) REFERENCES library_entries(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE);
CREATE TABLE manual_collection_memberships (collection_id TEXT NOT NULL, source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, added_at_epoch_second INTEGER NOT NULL, added_at_nano INTEGER NOT NULL, display_order INTEGER NOT NULL, PRIMARY KEY(collection_id, source_id, remote_book_id), FOREIGN KEY(collection_id) REFERENCES collections(collection_id) ON UPDATE NO ACTION ON DELETE CASCADE, FOREIGN KEY(source_id, remote_book_id) REFERENCES library_entries(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE);
CREATE INDEX index_manual_collection_memberships_source_id_remote_book_id ON manual_collection_memberships(source_id, remote_book_id);
CREATE TABLE reading_progress (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, content_id TEXT NOT NULL, revision TEXT, block_id TEXT, text_anchor_digest TEXT, character_offset INTEGER, chapter_progress REAL, book_progress REAL, updated_at_epoch_second INTEGER NOT NULL, updated_at_nano INTEGER NOT NULL, PRIMARY KEY(source_id, remote_book_id), FOREIGN KEY(source_id, remote_book_id) REFERENCES books(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE);
CREATE TABLE remote_library_reconciliation (id TEXT NOT NULL, source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, package_digest TEXT NOT NULL, package_version TEXT NOT NULL, capability_set_fingerprint TEXT NOT NULL, registry_generation INTEGER NOT NULL, state TEXT NOT NULL, created_at_epoch_second INTEGER NOT NULL, updated_at_epoch_second INTEGER NOT NULL, diagnostic_id TEXT, PRIMARY KEY(id));
CREATE INDEX index_remote_library_reconciliation_source_id_remote_book_id ON remote_library_reconciliation(source_id, remote_book_id);
CREATE TABLE source_availability (source_id TEXT NOT NULL, verified_version TEXT, available INTEGER NOT NULL, generation INTEGER NOT NULL, PRIMARY KEY(source_id));
CREATE TABLE source_remote_policy (source_id TEXT NOT NULL, trusted_publisher_fingerprint TEXT NOT NULL, capability_set_fingerprint TEXT NOT NULL, approved_origin TEXT NOT NULL, add_writeback_enabled INTEGER NOT NULL, first_import_prompt_dismissed INTEGER NOT NULL, PRIMARY KEY(source_id));
CREATE TABLE browsing_history (source_id TEXT NOT NULL, remote_book_id TEXT NOT NULL, last_viewed_at_epoch_second INTEGER NOT NULL, last_viewed_at_nano INTEGER NOT NULL, PRIMARY KEY(source_id, remote_book_id), FOREIGN KEY(source_id, remote_book_id) REFERENCES books(source_id, remote_book_id) ON UPDATE NO ACTION ON DELETE CASCADE);
CREATE TABLE import_sessions (id TEXT NOT NULL, kind TEXT NOT NULL, plan_digest TEXT NOT NULL, normalized_plan_path TEXT NOT NULL, status TEXT NOT NULL, source_created_at_epoch_second INTEGER NOT NULL, started_at_epoch_second INTEGER NOT NULL, completed_at_epoch_second INTEGER, preference_patch_json TEXT NOT NULL, summary_json TEXT, PRIMARY KEY(id));
CREATE TABLE import_warnings (session_id TEXT NOT NULL, ordinal INTEGER NOT NULL, safe_code TEXT NOT NULL, safe_record_ref TEXT, field_name TEXT, severity TEXT NOT NULL, PRIMARY KEY(session_id, ordinal), FOREIGN KEY(session_id) REFERENCES import_sessions(id) ON UPDATE NO ACTION ON DELETE CASCADE);
CREATE TABLE search_history (source_id TEXT NOT NULL, normalized_query TEXT NOT NULL, display_query TEXT NOT NULL, last_used_at_epoch_second INTEGER NOT NULL, last_used_at_nano INTEGER NOT NULL, PRIMARY KEY(source_id, normalized_query));
CREATE TABLE smart_rules (collection_id TEXT NOT NULL, rule_version INTEGER NOT NULL, ast_json TEXT NOT NULL, compiled_projection_version INTEGER NOT NULL, PRIMARY KEY(collection_id), FOREIGN KEY(collection_id) REFERENCES collections(collection_id) ON UPDATE NO ACTION ON DELETE CASCADE);
CREATE TABLE subscription_drafts (collection_id TEXT NOT NULL, mode TEXT NOT NULL, source_scope_json TEXT NOT NULL, query_json TEXT NOT NULL, enabled INTEGER NOT NULL, import_session_id TEXT, PRIMARY KEY(collection_id), FOREIGN KEY(collection_id) REFERENCES collections(collection_id) ON UPDATE NO ACTION ON DELETE CASCADE);
```

表名已按 `4.json` 的 `tableName` 逐一核对（`local_book_tags`、`source_availability`、`source_remote_policy`、`search_history`、`smart_rules` 为 Room 实际表名）。

---

## 8. 交付里程碑与验收门

每个里程碑必须：全部测试通过、无编译警告、模拟器（iPhone，iOS 16.4 runtime）冷启动可用。后一里程碑不得在前一里程碑未过门时开始。

| # | 范围 | 验收门（全部满足才算过） |
|---|---|---|
| M0 工程与协议 | Package/App 骨架、依赖方向、SPDX/REUSE、`TsuyomiProtocol` 全量 | 6.1 的 fixture 测试全绿；`swift build` 零警告；依赖图反向 import 编译失败（写一个故意反向 import 的测试 target 验证后删除） |
| M1 宿主基础 | Database v4、Files、Preferences、Security、Network、Media | 6.2 各测试全绿；凭据分区无明文（grep DB/UserDefaults/日志 fixture）；重定向/origin/限额/解码用例全绿 |
| M2 扩展运行时 | CQuickJS、RuntimeLane、HXP 校验/安装、SourceExtensionClient | 安装 `wenku8-fixture.hxp` 成功且篡改后拒绝；死循环 1s 内被中断且 context 重建；HTML fixture 回放字段与 `wenku8.test.mjs` 断言一致 |
| M3 阅读闭环 | Reader engine + TextKit UI、受控 WKWebView、Browse/Search/Book/Reader 屏幕 | 端到端：安装 → （需要时）手动登录 → 搜索 → 详情+目录 → 章节 → 跨到相邻章 → 杀进程 → 从 Library 恢复到同一 `blockId + characterOffset`；scroll/paged/dualPage 三种呈现共享一个 locator；字体/边距变更后位置保持 |
| M4 书架与迁移 | Library 全部交互、收藏夹/智能规则/标签/系统节点、Transfer 导入导出、Hikari 导入、远端书架只读 + 复制 | 拖拽建收藏夹/入收藏夹/根目录插入/快捷栏重排均持久化到 `display_order`；导出→清空→导入后库与进度逐字段相等；`conformance-progress-conflict` 规则在真实 DB 上成立；远端书架任何操作零 POST（网络 fake 断言） |
| M5 扩展市场 | 6.8 全部：`RepositoryIndexCodec`、`ExtensionRepositoryClient`、`PublisherTrustStore`、ExtensionsFeature 五个屏幕、`build-index.mjs` | 本地 HTTP fake 提供签名索引：添加仓库 → 确认发布者 → 安装 → 索引升版本 → 更新（能力扩张走重新授权）→ 索引含撤销 → 已装包停用；HTTP 基址、过期索引、错误签名、`sha256` 不匹配、`capabilities` 与 manifest 不一致、回滚版本六种输入全部拒绝且有对应错误文案；删除仓库后已装扩展仍可用 |
| M6 设置、帮助、打磨 | Settings/Backup 报告/帮助/关于、Dynamic Type、VoiceOver、Reduce Motion、深色模式、`NSUserActivity` 恢复 | 所有屏幕在 `.accessibility3` 字号无裁切、无不可达焦点；VoiceOver 可完成 M3 与 M5 端到端；深色/浅色两套截图人工核对；`OPTION_APPLICABILITY` 矩阵逐项记录在 `docs/OPTION_APPLICABILITY_IOS.md` |

M5 只依赖 M2，可与 M3/M4 并行开始；其余顺序不变。

---

## 9. 测试与 fixtures

- 框架：XCTest；不引入第三方断言库。
- 网络：一律 fake transport；**禁止任何测试访问真实站点**。
- fixtures 引用路径：`Tsuyomi-main/tsuyomi-protocol/fixtures`、`Tsuyomi-main/tsuyomi-extensions/fixtures/wenku8`（含 `wenku8-fixture.hxp` 与 `.sha256`）。
- 必须移植的 Android 测试（按语义，不按代码）：`core/network/src/test/**`、`core/security/src/test/**`、`core/database/src/androidTest/**`（改为 SQLite 内存库）、`reader/engine` 的 JVM 测试、`source/quickjs-runtime` 与 `source/extension-manager` 测试、`app/src/androidTest/LibraryProductionJourneyInstrumentedTest.kt`（改为 XCUITest 端到端，对应 M3/M4 门）。
- 扩展市场测试：`package-policy-cases.json` 中 successful update / capability expansion / revoked publisher / repository rollback / invalid origin subset 各用例必须通过仓库路径复现；索引 fixtures 在测试 `setUp` 中用 fixture 种子生成并签名，覆盖 6.8 列出的六种拒绝输入。
- 每个 bug 修复附带一个回归测试；无测试的修复不接受。

---

## 10. 代码规范（反冗余）

- 文件 ≤ 400 行；超过即按职责拆分，不按"models/utils"拆分。
- 命名沿用 Android 类型名；不加 `TSY`/`Tsuyomi` 前缀（模块已隔离），例外是第 6.5 节已有前缀的组件名。
- `enum` 优先于 `struct + 静态常量`；`struct` 优先于 `class`；`class` 只用于需要引用语义或 `ObservableObject` 处；`actor` 只用于持有可变共享状态且被多任务访问处。
- 不写 `Utils`、`Helpers`、`Extensions+Foo` 杂物文件；扩展方法就近放在唯一消费者文件。
- 不为单实现写 protocol，例外：测试需要 fake 的 I/O 边界（transport、AEAD、measurement port、时钟）。
- 错误：一处 `enum` 每层；不用 `NSError`、不用 `String` 错误。
- 日志：`os.Logger`，子系统 `org.tsuyomi.ios`；只记录稳定错误码 + `diagnosticId`。
- 并发：主线程只做 UI；DB/网络/JS/解码在各自 actor；跨 actor 传值必须 `Sendable`。
- 禁止 iOS 17+ API：`@Observable`、`SwiftData`、`ContentUnavailableView`、`.scrollTargetBehavior`、`.scrollPosition`、`.onChange(of:) { old, new }`（用单参数版本）、`.sensoryFeedback`、`TipKit`、`.symbolEffect`、`NavigationSplitView` 的 17 新增修饰符。允许的 16.4 专属：`presentationBackgroundInteraction`、`presentationCornerRadius`、`presentationContentInteraction`、`presentationCompactAdaptation`、`scrollBounceBehavior`。
- 第三方依赖：**零**（QuickJS-ng 为 vendored C 源码，不是 SPM 依赖）。

---

## 11. 完成定义

全部满足才算完成：

1. M0–M6 验收门全部通过，结果附在 `docs/ACCEPTANCE.md`（命令 + 输出摘要 + 模拟器型号/iOS 版本）。
2. `docs/DECISIONS.md` 记录了本文档之外的每个决策（一行一条）。
3. `docs/OPTION_APPLICABILITY_IOS.md` 逐项回答"为什么可见、何时生效、无效时为何隐藏或禁用"。
4. `THIRD_PARTY_NOTICES.md`、`README.md`（更新状态徽章、构建步骤、与 Android 的功能对照表）完成。
5. 仓库中不存在：`Tsuyomi-main` 的任何拷贝、Kotlin 文件、E-ink 相关符号、TODO/FIXME、被注释掉的代码、未被引用的文件。
6. `git status` 干净，提交按里程碑分组，提交信息为 `M<n>: <范围>`。

---

## 附录 A：Android → iOS 文件映射摘要

| Android | iOS target / 文件 |
|---|---|
| `shared/model/BookIdentity.kt` | `TsuyomiProtocol/BookIdentity.swift` |
| `shared/locator/ReaderLocator.kt` | `TsuyomiProtocol/ReaderLocator.swift` |
| `shared/source-contract/SourceContracts.kt` | `TsuyomiProtocol/SourceContracts.swift`（可拆 Network / Home / Reader 三文件） |
| `shared/smart-shelf/SmartShelf.kt` | `TsuyomiProtocol/SmartShelf.swift` |
| `shared/backup/*.kt` | `TsuyomiProtocol/Transfer/*.swift` |
| `core/database/**` | `TsuyomiCore/Database/{TsuyomiDatabase,Schema,LibraryRepository,CollectionStore,ReadingProgressStore,RemoteLibraryStore,TransferRepository,SmartShelfQueryCompiler}.swift` |
| `core/files/**` | `TsuyomiCore/Files/{QuotaFileStore,StorageRoots}.swift` |
| `core/preferences/**` + `core/display` 保留部分 | `TsuyomiCore/Preferences/AppPreferences.swift` |
| `core/network/**` | `TsuyomiCore/Network/{HostNetworkGateway,HostNetworkCache,URLSessionHostHttpTransport,SourceOperationContext,DirectActionTokenRegistry}.swift` |
| `core/security/**` | `TsuyomiCore/Security/{KeychainAesGcm,SourceCredentialStore,VerifiedBrowserSessionStore,CredentialModels}.swift` |
| `core/media/**` | `TsuyomiCore/Media/{CoverApi,HostCoverLoader,DefaultCoverRepository}.swift` |
| `core/webview/ControlledWebLoginSession.kt` | `TsuyomiCore/WebView/ControlledWebLoginSession.swift` |
| `source/quickjs-runtime/**` | `CQuickJS/` + `TsuyomiSource/QuickJsRuntimeLane.swift` |
| `source/extension-manager/**` | `TsuyomiSource/{HxpModels,HxpManifestParser,HxpArchiveVerifier,ZipReader,Rfc8785,ExtensionInstaller,InstalledExtensionStore,SourceExtensionClient}.swift` |
| （无对应；hxp-package-v1 §Trust §Updates） | `TsuyomiSource/{PublisherTrustStore,RepositoryIndexCodec,ExtensionRepositoryClient}.swift`、`ExtensionsFeature/*.swift`、`tools/repository/build-index.mjs` |
| `source/extension-testkit/Phase2TestPublisher.kt` | `TsuyomiSource/Phase2TestPublisher.swift`（`#if DEBUG`） |
| `reader/engine/**` | `TsuyomiReader/Engine/*.swift`（同名） |
| `reader/ui/**` | `TsuyomiReader/UI/{ReaderSurface,ReaderPagination,ReaderChrome,ReaderSettingsSheet,ReaderModels}.swift` |
| `core/ui/components/**` | `TsuyomiUI/*.swift`（仅 6.5 列出的组件） |
| `feature/<x>/**` | `<X>Feature/*.swift` |
| `app/**` | `TsuyomiApp/{TsuyomiApp,AppContainer,Routes,RootTabs,Source*,Library*,Transfer*,NormalizedSourceStore,RemoteExecutionLease}.swift` |

## 附录 B：必须阅读的 Android 文档（仅此清单）

`docs/architecture/{MODULES,ANDROID_RUNTIME,SOURCES,READER,DATA,SHELVES,MIGRATION}.md`、`docs/design/OPTION_APPLICABILITY.md`、`docs/adr/{0003,0004,0005,0006,0007,0008,0009,0012,0013,0015,0016,0017,0018}.md`、`tsuyomi-protocol/docs/*.md`、`tsuyomi-extensions/docs/DEVELOPMENT.md`。其他文档不读。
