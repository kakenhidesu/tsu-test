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
- 智能规则编译结果用 `SmartRuleCompilation { ready, rejected }` 而不是 `Result`：`[SmartRuleViolation]` 不是 `Error`，把它包成 error 只是为了迁就 `Result`。
- `更多` tab 随数据迁移一起落地，只有真实入口，M6 再往里加行；这样每个 tab 从第一天起就是可用的，而不是先摆一个空壳。
- 导入文件类型按内容自辨（`TransferCodec.parse`），文件选择器只用来拿字节；不依据扩展名或选择器返回的名字判断格式。
- 进度落盘取的是"当前实际绘制的那一页"的位置（`ReaderTextLayout.position(atPageIndex:)` + `ReaderDocumentSession.locator(atBlock:)`），而不是解析器的起始猜测：读者没翻页也应当得到精确定位符；未完成排版时不写入，因为此时并不知道读者看到了什么。
- `tsuyomi-repository` v0 是 iOS 的临时索引格式，待 protocol 标准落地后只替换 `RepositoryIndexCodec.swift` 与其 fixtures；全部字段限于 `hxp-package-v1.md` §Trust §Updates 已要求宿主校验的信息，索引本身不授予任何东西。
- 撤销条目只接受"由该仓库自己的发布者密钥签名"的记录：否则一个镜像就能给别人的密钥注入撤销。
- `PublisherTrustStore` 是 actor（持久信任），但 `HxpArchiveVerifier` 需要同步解析器，因此由它产出一次性 `InMemoryPublisherKeyStore` 快照：一次校验只对着一份一致的信任视图。
- 内置官方仓库本轮不实现：基址与根公钥未定，不写占位 URL，不建 `OfficialRepository.swift`。
- 仓库索引、签名与 `.hxp` 下载走 `HostNetworkGateway.fetchStaticResource`：请求构造留在宿主网络 actor 内，且不携带任何来源 Cookie，仓库因此既读不到也写不了任何来源会话。
- 市场里的包状态只有四种（可安装/已安装/可更新/不兼容/已撤销）由索引与已安装版本推导，不额外持久化：任何第二份状态都会与实际安装状态不一致。
- `InstallReviewScreen` 是所有安装路径（仓库下载、本地 `.hxp` 导入）的唯一确认点；拒绝后旧版本保持激活。
- 移除发布者信任会让它签名的包立即验签失败 → 关闭运行时通道并置来源为休眠，但保留书架与凭据：撤销的是"运行代码的许可"，不是用户的数据。
- 索引与 manifest 的四项一致性检查（摘要、身份与版本、能力集、hostApi 区间）以及回滚判定收敛到 `RepositoryInstallPolicy`：索引只是提示，真正授权的是归档内的 manifest，两者能不一致的每一种方式都必须在同一处拒绝。
- 关于页的第三方声明与 `THIRD_PARTY_NOTICES.md` 同源同文：应用内显示的许可证不能与仓库里的版本漂移。
- 帮助内容回答的是这套设计本身造成的问题（为什么要装扩展、为什么在浏览器里登录、为什么不同步），不复述界面上已经写着的东西。
- `NSUserActivity` 只携带「哪本书的哪一章」，不携带任何进度：位置存在本地库里，恢复时按 locator 重新解析，因此活动对象本身永远不含阅读位置，也不参与 Handoff（`isEligibleForHandoff = false`）。
- Reduce Motion 打开时，插入位让位与快捷栏收折的动画降级为无动画的直接状态切换，而不是缩短时长：这两处的反馈本来就有持久的文字/几何表达，不依赖动画。
- v0 索引里 `revocations[].target.packageDigest` 指的是 manifest 的 `integrity.contentDigest`，不是归档文件的 sha256：`HxpArchiveVerifier` 按内容摘要判定撤销，因此把同一份内容重新打包不能绕过撤销。索引里的 `sha256` 仍是归档摘要，只用于下载完整性比对。
- CI 额外产出一个未签名的 Debug 设备构建（`Tsuyomi-unsigned.ipa`）供 TrollStore 之类的工具旁加载：Debug 是唯一信任验收 fixture 发布者的配置，因此在没有可用仓库时也能导入测试扩展。Release 构建按设计拒绝该密钥。
- 本地 `.hxp` 导入与仓库下载走同一条 `HxpArchiveVerifier → ExtensionInstaller` 路径与同一个审批屏，只是字节来源不同；不存在第二条更宽松的安装路径。
- App target 声明 `org.tsuyomi.hxp` 导出类型与 `CFBundleDocumentTypes`，因此文件 App 里点一个 `.hxp` 会交给本应用；打开后仍然走同一个安装审批屏，系统的"打开方式"不构成一条免审批的安装路径。
- 每个视图只挂一个 `.sheet`：iOS 16 上同一视图挂第二个 `.sheet` 会静默地永远不弹出。需要多种弹层时用一个 `.sheet` 加内容分支（扩展市场的"仓库授信/安装审批"、仓库详情的"包详情/安装审批"、阅读器的"设置/目录"三处都按此收敛）。
- 导入 `.hxp` 的文件选择器接受任意文件类型：扩展是靠校验字节而不是靠文件名被接纳的，按扩展名过滤只会把文件从选择器里藏起来，却挡不住任何东西。
- 失败提示画在内容分支之外：全新安装时扩展页处于空状态，错误如果只画在内容里就永远看不见。
- 导入 `.hxp` 不用 SwiftUI `.fileImporter`，而是把 `UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)` 包成 `UIViewControllerRepresentable`（`ArchivePicker`）：`.fileImporter` 是就地打开，选中一个文件要等系统向本进程签发安全作用域授权，这一步失败时选择器既不关闭也不回调，应用里没有任何代码能观察到；`asCopy` 让系统把文件复制进本应用的临时目录，读取不再依赖授权；`.item` 是所有类型的根，动态推断类型的文件也能选中。选择器 sheet 挂在分段 `Picker` 上（与容器的审批 sheet 分属不同视图），导入在它的 `onDismiss` 里启动，审批 sheet 因此不会与选择器的关闭动画争抢同一个呈现点。
- `LSSupportsOpeningDocumentsInPlace` 显式声明为 `false`：本应用只导入归档、不就地编辑，文件 App 交来的是 `Documents/Inbox` 里的副本。两条入口拿到的都是自己拥有的副本，`importPackage(at:)` 读一次即删，`startAccessingSecurityScopedResource` 随之消失。
- `.onOpenURL` 先等 `AppContainer.loadTrust()`，且只在扩展页不在栈顶时才推入它；`loadTrust()` 记住第一次的 Task 供后续调用等待：冷启动时校验若跑在信任列表读完之前会误报 `UNKNOWN_PUBLISHER`，而两个扩展页观察同一个 `pendingInstall` 会触发两次 sheet 呈现。模型正忙时导入报 `BUSY` 而不是静默丢弃。
- 导入过程逐段报告状态（已选择文件 → 已读取 N 字节 → 校验结果）：一次停下来的导入必须说清停在哪一步，否则用户只能看到"点了没反应"。
- 设备构建的 `CFBundleVersion` 取 CI run number，关于页显示版本号：旁加载的两份包在外观上无法区分，装了哪一版必须能在应用里读出来。
- 宿主 API 版本常量为 `1.1.0`，与 Android 端 `HxpArchiveVerifier` 的默认值一致：扩展声明的 `hostApi` 区间是拿这个值去比对的，填低了会拒绝掉每一个为真实 API 构建的包。端到端测试改为读取 `AppContainer.hostApiVersion` 而不是写死字面量——先前测试写死正确值、应用里是错值，两边各自自洽，缺陷因此一路到了设备上。
- 选中文件后的导入只在选择器 sheet 的 `onDismiss` 里启动，不用 `.task(id:)`：`onDismiss` 在关闭动画结束后才触发，而 `.task(id:)` 在代理一设置状态时就开始校验，小包在关闭动画结束前就能校验完，审批 sheet 便会在选择器仍在关闭时请求呈现——iOS 16 上这种呈现会静默失败。导入的结果全是 `@Published`，何时改变都会触发重绘，不存在"结束得太早而无从显示"的情况。
- 安装审批屏的「安装」按钮不调用 `dismiss()`：这个 sheet 是由 `pendingInstall` 驱动呈现的，同步 dismiss 会在 `approvePendingInstall()` 的 Task 真正跑起来之前把它清空，那个方法的 `guard let prepared = pendingInstall` 随即失败并静默返回——表现为点了安装、页面关闭、什么也没装、也没有错误。改由模型在安装落定后清空该状态，sheet 随之关闭。
- 受控浏览器的拦截提示区分原因（`WebNavigationBlock`）：跳转到明文 HTTP 与跳转出声明范围是两回事，都说成"不在声明范围内"会让读者去查扩展的声明，而那里并没有问题。
- 扩展市场入口先 `await loadTrust()` 再压栈：全新安装后第一次导入若跑在信任列表读完之前，校验会失败而看起来像"没弹审批"。
- List / Form 行内不再显式写 `minHeight: 44`：系统行本身已保证不小于触控目标，额外的高度约束会叠加在行的内边距上，把 44pt 的标准行撑到 60pt 以上，看起来就不像 iOS 的设置列表。自绘的横条、覆盖层与阅读器控件不在此列，那里没有系统行高可依赖。
