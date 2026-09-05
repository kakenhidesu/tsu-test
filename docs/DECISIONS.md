<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# 决策记录

本文件只记录 `IOS_PORT_PROMPT.md` 未覆盖的决策，一行一条。

## M0

- SHA-256 由 `TsuyomiProtocol/Sha256.swift` 提供纯 Swift 实现并被所有上层复用；`TsuyomiProtocol` 被禁止 import CryptoKit，重复实现违反反冗余规则。
- JSON 统一走 `Codable`；需要严格未知字段拒绝或宽松遗留解析处，`init(from:)` 先解码到 `JSONValue`（本身是 `Codable`）再手写校验。
- `JSONValue` 编码固定 `[.sortedKeys, .withoutEscapingSlashes]`，使规范化输出与摘要在同一平台上确定。
- `ReaderDocument` 采用 `reader-document-v1` schema 形状（`kind`/`identity`/`contentDigest`），而非 Android 运行时的扁平中间形状；扁平形状是扩展宿主边界，由 `TsuyomiSource` 在 M2 转换。
- `ReaderBlock` 的文本上限取 schema 值（paragraph/quote 65536、heading 16384），Android 内存模型的 100000 更宽，不采用。
- `SourceNetworkRequest` 不含 `query`/`queryEncoding`；与 Android 一致，结构化 query 的百分号编码属于 `TsuyomiSource` 的 `SourceExtensionClient` 边界。
- 协议时间戳解析接受 RFC 3339 偏移与小数秒，但在解析时截断到整秒，保证"解析→再序列化"字节稳定。
- 字符串排序统一用 UTF-16 码元序（`CanonicalOrder`），与 Kotlin `String.compareTo` 一致，保证两端导出顺序相同。
- `TransferCodec.encodeBounded` 用"整体编码后比较长度"替代 Android 的流式截断；语义（超限返回 `nil`）相同，避免第二套编码器。
- `ImportPlan` 不含 `forceManualEInk`，Hikari 的 `browsingEInkMode`/`readerEInkMode` 不读取：iOS 无 E-ink profile（第 4 节），无消费者的字段不保留。
- Hikari 凭据字段扫描按规范化键名排序遍历，使警告 ordinal 在 Swift 字典无序的前提下确定。
- `tsuyomi-protocol/fixtures/hxp/**` 的用例在 M2 由其归属类型（`HxpManifestParser`、`SourceExtensionClient`）覆盖，M0 只覆盖 `reader/**` 与 `transfer/**`。

## M1

- `TsuyomiCore` 的 `LibraryRepository` 同时是 `books/library_entries/local_book_tags/history` 的 SQL 归属，不再另设只做转发的 `LibraryCatalogStore` 门面（反冗余规则禁止透传层）。
- `ReaderSettings`、`ReaderPresentation`、`ReaderTheme` 定义在 `TsuyomiCore/Preferences`（持久化它们的层），`TsuyomiReader` 从下层引用；反向会破坏 Package 的依赖方向。
- POST 表单体按键名排序序列化，使字节体在 Swift 字典无序的前提下确定；远端写策略按字典比较参数，与顺序无关。
- `URLSessionHostHttpTransport` 在会话级 delegate 中按 16 MiB 协议上限预检 `Content-Length`，每个授权的更小上限由 `HostNetworkGateway` 二次执行。
- `KeychainAesGcm` 的密钥在模拟器单元测试中不可用（无 keychain 授权），生产实现由集成路径覆盖；单元测试用内存 `AeadPort`。

## M2

- vendored QuickJS-ng 的实际文件集为 `dtoa.c libregexp.c libunicode.c quickjs.c`（0.16.1 无 `cutils.c`，`cutils.h` 为头文件实现），与 Android `CMakeLists.txt` 一致。
- `tsuyomi_qjs_prepare_operation` 每次调用 `JS_UpdateStackTop`，使 actor 串行执行器在不同线程上连续执行时栈上限判定仍然正确；因此不再固定专用线程。
- 桥接新增 `IMPORT_DISALLOWED` 状态并安装拒绝一切说明符的模块加载器（Android JNI 未安装加载器）。
- `ReaderDocument` 的 `contentDigest` 由宿主按 RFC 8785 规范化块负载计算；扩展未给出 `revision` 时取该摘要，扩展不能声称改动过的正文是同一修订。
- `ExtensionInstaller.evaluatePolicy` 是更新规则的唯一归属；`rotationApproved` 表示用户已重新确认新发布者指纹（v0 索引不承载交叉签名）。

## M3

- iOS 禁止 `evaluateJavaScript`/user script，因此 `ControlledWebLoginSession` 不从 WebView 读取 HTML：它只产出 `VerifiedPageNavigationBinding`（请求 URL 与落定页面 URL）与声明 origin 的 Cookie/UA，页面正文由宿主用这些凭据经 `HostNetworkGateway` 重新 GET 取得，`CapturedVerifiedPage` 由该结果构造。
- WKWebView 显式报告服务端重定向，因此导航追踪器比 Android 版更严格：只有宿主发起的加载与它观察到的重定向能落定，任何用户手势导航直接作废绑定。
- `TsuyomiUI` 依赖 `TsuyomiCore` 而非仅 `TsuyomiProtocol`：第 6.5 节要求 `CoverImage` 直接消费 `CoverUiState`（其载荷是 `UIImage`，不能下沉到禁止 UIKit 的 `TsuyomiProtocol`），复制一份等价 DTO 会违反反冗余规则。依赖方向仍是单向的，`TsuyomiUI` 不做任何能力判定。
- `TsuyomiReader` 依赖 `TsuyomiUI`：`ReaderChrome` 与 Android 的 `reader/ui`→`core:ui` 同构（后者 import `TsuyomiTopBar`/`TsuyomiSpacing`）；第 5 节箭头表未列出这条边，但方向仍是单向且不引入 feature 间依赖。
- `SafeErrorCode` 归属 `TsuyomiSource`：它同时映射 `TsuyomiCore` 与 `TsuyomiSource` 两层的错误，放在最低的共同拥有者处；每个 feature 各留一份等价映射会违反反冗余规则。
- `ReaderPageView` 上报实际绘制的页码（`onPageDrawn`）：预览提交需要"读者确实看见了这一页"的视觉见证，而见证只能来自绘制，不能来自状态赋值。
- `ReaderDocumentSession.locator(atBlock:)` 为不移动阅读位置的只读取点：滑块拖动期间必须能构造预览目标而不改变真实位置。
- 章节前后翻页越界时只进入相邻章；目录内任意跳转是显式选择，二者共用同一次 `flush`，因此进度写入点只有"换章/退出/离开前台"三处。
- 每本书只保留一个语义位置，因此目录中的"已读"标记由该位置之前的章节推导，而不是另设逐章已读表（第二份会与进度不一致）。
- 验证页族（`VerifiedPage`/`VerifiedDetailPage`/`VerifiedDirectoryPage`/`VerifiedChapterPage`）在 iOS 合并为单一 `verification(sourceId)`：Android 需要按页区分是因为它从 WebView 里取 HTML，而 iOS 禁用 `evaluateJavaScript`，落定后由宿主经 `HostNetworkGateway` 重新 GET，因此不存在"逐页验证变体"。
- `directory(BookIdentity)` 路由在 iOS 不存在：目录已整合进详情页（第 6.4 节），再留一个独立路由就是无消费者的重复入口。
- `RootTabs{library, browse, more}` 随 M4（书架）与 M6（更多）落地；M3 的组合根只有 browse 一个 `NavigationStack`，避免为尚不存在的屏留占位 tab。
- `@main` 放在 Xcode App target，库里只有 `TsuyomiRootScene`：SPM target 内的 `@main` 会与测试宿主冲突，且组合根需要保持可被单元测试构造。
- `SourceExtensionClient` 直接实现 `CoverMediaFetcher`：封面与正文共用同一份 `SourceNetworkGrant`（cookie 作用域、origin、响应上限），另建一个封面通道会复制一份可放宽的授权。
- `LibraryWriteArbiter`（Android `DisplayWriteArbiter`）随 M4 书架显示写入一起落地：M3 没有任何显示字段写入需要它仲裁。
- `RootTabs` 先只有 `library` 与 `browse` 两个 tab；`more`（设置/备份/帮助/关于）随 M6 加入，不为尚不存在的屏留占位。
- 书架封面用只读缓存取图（`CachedOnlyCoverFetcher`）：绘制书架不能为每个来源开一条 JS 运行时通道，因此只显示宿主已经下载过的封面。
- 封面分区键（package 摘要 + 凭据状态）由 `SourceCoverProvider.credentialRevision` 单点推导：浏览流与书架若各推一份，登录状态一变两边就会读到不同的缓存目录。
- 收藏夹是同一书架的一个视图（`LibraryModel.open(collection:)`），不是第二个书架：布局、筛选、多选全部复用，避免第二套列表状态。
- `LibraryCollection` 的展开/子层级与快捷栏重排随后续提交落地，本次只交付三布局、多选、系统节点显隐、拖拽建夹与拖入收藏夹。
- 快捷栏重排放在显式的编辑列表里（`List` + `onMove`）而不是就地长按拖动：就地拖动与"点按打开快捷方式"共用同一个手势起点，二者会互相误触发。
- 快捷栏收折后是一条 ≥44pt 的整宽手柄：点按展开，拖着书悬停也展开，因此收折状态永远不会把唯一的返回入口缩到触控目标以下。
- 收藏夹只出现在快捷栏里，不再另设一行"收藏夹"：同一份数据两处渲染会产生两套选中与拖放状态。
- 书架的拖拽有"排序整理"显式模式：同一个拖放手势不能既表示"排到这个位置"又表示"和这本书建收藏夹"，模式决定含义。进入该模式会把书架恢复成自定义排序、全部筛选、非收藏夹视图，否则持久化的顺序读者看不见。
- 插入位让位用 `Layout` 协议（`InsertionGridLayout`）实现：所有格子高度取实测最大值，使落点几何与实际排布不会不一致。
- 智能规则编辑器只编辑"一个组合子 + 一组谓词"的扁平结构：这是规则文法里不需要嵌套就能表达的全部形状；更深的嵌套规则可以导入并运行，但不在此处编辑，避免做一个无人使用的树编辑器。
- 规则校验失败时把违规按 `path` 定位回产生它的那一行内联显示，而不是弹一个笼统的错误：`SmartRuleViolation` 已经带路径，丢掉它等于让用户猜。
- `.gitattributes` 把 `Sources/CQuickJS/quickjs-ng/**` 标为 `linguist-vendored` 且 `-diff`：这些文件是逐字内嵌的上游源码，永不手改，不应计入本仓库的语言统计，也不应出现在代码评审 diff 里。引擎仍以源码形式内嵌（第 3 节要求），不改为预编译二进制。
