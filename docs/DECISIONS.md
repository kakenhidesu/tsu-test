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
- 导入 `.hxp` 不用 SwiftUI `.fileImporter`，而是把 `UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)` 交给 `ArchivePickerController` 承载、由 `ArchivePicker`（一个 `UIViewControllerRepresentable` 锚点）呈现：`.fileImporter` 是就地打开，选中一个文件要等系统向本进程签发安全作用域授权，这一步失败时选择器既不关闭也不回调，应用里没有任何代码能观察到；`asCopy` 让系统把文件复制进本应用的临时目录，读取不再依赖授权；`.item` 是所有类型的根，动态推断类型的文件也能选中。选择器不放进 SwiftUI sheet：屏幕背景里一个不可见的锚点控制器以 UIKit 模态呈现 `ArchivePickerController`，它把选择器作为子控制器承载；审批 sheet 因此是这个屏幕上唯一的 SwiftUI 呈现。
- `LSSupportsOpeningDocumentsInPlace` 显式声明为 `false`：本应用只导入归档、不就地编辑，文件 App 交来的是 `Documents/Inbox` 里的副本。两条入口拿到的都是自己拥有的副本，`importPackage(at:)` 读一次即删，`startAccessingSecurityScopedResource` 随之消失。
- `.onOpenURL` 先等 `AppContainer.loadTrust()`，且只在扩展页不在栈顶时才推入它；`loadTrust()` 记住第一次的 Task 供后续调用等待：冷启动时校验若跑在信任列表读完之前会误报 `UNKNOWN_PUBLISHER`，而两个扩展页观察同一个 `pendingInstall` 会触发两次 sheet 呈现。模型正忙时导入报 `BUSY` 而不是静默丢弃。
- 导入过程逐段报告状态（已选择文件 → 已读取 N 字节 → 校验结果）：一次停下来的导入必须说清停在哪一步，否则用户只能看到"点了没反应"。校验通过的状态保留到审批被接受或拒绝为止：审批 sheet 若没弹出，这一行就是导入其实已经完成的唯一证据。
- 设备构建的 `CFBundleVersion` 取 CI run number，关于页显示版本号：旁加载的两份包在外观上无法区分，装了哪一版必须能在应用里读出来。
- 宿主 API 版本常量为 `1.1.0`，与 Android 端 `HxpArchiveVerifier` 的默认值一致：扩展声明的 `hostApi` 区间是拿这个值去比对的，填低了会拒绝掉每一个为真实 API 构建的包。端到端测试改为读取 `AppContainer.hostApiVersion` 而不是写死字面量——先前测试写死正确值、应用里是错值，两边各自自洽，缺陷因此一路到了设备上。
- 选中文件后的导入不在 SwiftUI sheet 的 `onDismiss` 里启动，而是由承载选择器的容器控制器在 `viewDidDisappear`（且 `isBeingDismissed`）里上报，再经一次主执行器调度才开始：系统文档选择器在回调代理后会自行关闭自己所在的呈现，它被包在 SwiftUI sheet 里时，这次关闭与 SwiftUI 因 `isPresented` 变化发起的关闭是同一个呈现的两个关闭者，而 `onDismiss` 只在 SwiftUI 自己那次关闭跑完时触发，谁先谁后取决于远程选择器进程的回调时序——全新安装后的第一次导入正是没触发的那种顺序，表现为"选完没反应"，第二次却正常。容器的 `viewDidDisappear` 与谁发起关闭无关、只在过渡结束时触发一次；UIKit 在同一调用栈里清掉 `presentedViewController`，之后才调度的导入任务再设置 `pendingInstall` 时呈现点已经空出，审批 sheet 不会撞上仍在关闭的选择器。代理回调里只在尚未开始关闭时才调用 `dismiss`，避免与选择器的自行关闭叠成两次（UIKit 会把第二次关闭转给再上一层的呈现者）。
- 安装审批屏的「安装」按钮不调用 `dismiss()`：这个 sheet 是由 `pendingInstall` 驱动呈现的，同步 dismiss 会在 `approvePendingInstall()` 的 Task 真正跑起来之前把它清空，那个方法的 `guard let prepared = pendingInstall` 随即失败并静默返回——表现为点了安装、页面关闭、什么也没装、也没有错误。改由模型在安装落定后清空该状态，sheet 随之关闭。
- 扩展市场入口先 `await loadTrust()` 再压栈：全新安装后第一次导入若跑在信任列表读完之前，校验会失败而看起来像"没弹审批"。
- List / Form 行内不再显式写 `minHeight: 44`：系统行本身已保证不小于触控目标，额外的高度约束会叠加在行的内边距上，把 44pt 的标准行撑到 60pt 以上，看起来就不像 iOS 的设置列表。自绘的横条、覆盖层与阅读器控件不在此列，那里没有系统行高可依赖。
- **偏离规范硬约束（用户明示要求）**：受控登录窗口内，声明主机上的跳转允许回落到明文 http。理由：安卓端事实上就是这么工作的——它的 `shouldOverrideUrlLoading` 对服务端重定向不触发，https→http 的 302 被静默跟随；而 WKWebView 每次重定向都会询问策略，于是同一条规则在 iOS 上把登录挡死了。放开的范围只有 scheme：主机仍受声明 origin 约束，端口仍需匹配。（这一条后来按用户要求扩展到了宿主的网络抓取，见下方"宿主网络抓取同样允许……"一条；`openVerifiedPage` 与已落定页面的判定仍是仅 HTTPS。）
- 只有确定为主框架的导航才清空已落定页面绑定（对齐安卓的 `request.isForMainFrame`）：`targetFrame` 为 nil 表示新窗口而非主框架，把它当主框架会在遇到一个 http 子框架或弹窗时抹掉绑定，登录成功后"我已完成"反而失败。
- 登录起始页在协议里没有可选项：`webLogin` 只有 `enabled` 与 `origins`（schema `additionalProperties: false`，`HxpManifestParser.requireKeys` 同样拒绝多余键），宿主只能从声明 origin 的根开始；站点把根 302 到 http 时，在"仅 HTTPS"规则下不存在任何正确的起始页，这与 origin 匹配或规范化无关。安卓端规则相同（`originOf` 要求 https），只是 `shouldOverrideUrlLoading` 看不到服务端重定向，登录因此"碰巧"能完成。不放宽规则的出路只有两条：协议给 `webLogin` 加一个 HTTPS 登录入口路径字段，或站点本身在 HTTPS 上提供登录页；宿主侧无代码可改。
- 验证页只保留流程说明一句，不再显示任何拦截/明文提示（用户要求）。随之删掉了 `onBlockedNavigation` 回调与 `WebNavigationBlock`：没有消费者的上报通道就是冗余代码。代价是被拒绝的跳转此后没有任何界面痕迹，只表现为页面不动。
- 文档选择器必须 `present`，不能 `addChild` 嵌入：它是跨进程的远程视图控制器，嵌入后界面画得出来但选择回调依赖自身的呈现生命周期，那条链断了就表现为"选完文件什么都不发生"。它从一个无交互的锚点控制器呈现，不放在 SwiftUI sheet 里——picker 答复后会关闭自己所在的呈现，在 sheet 里那关掉的是 sheet，答案随之丢失。
- 选中的归档在 picker 完全离开屏幕后才交出（`dismiss` 的完成回调；若它已自行开始关闭则直接交出），审批 sheet 因此不会在一次关闭进行中请求呈现。
- `NSAllowsArbitraryLoadsInWebContent = true`：放行 WebView 内的明文跳转之后，还必须让 App Transport Security 也放行，否则请求在网络层就被系统拦掉，表现为登录页一片空白且无任何提示。这个键只作用于 WebView 内容，`URLSession`（即 `HostNetworkGateway` 的全部抓取）仍受 ATS 强制 TLS，范围与"仅登录窗口可回落明文"的决定一致。不使用按域名的 `NSExceptionDomains`：宿主里不允许出现任何具体站点。
- `URLSessionHostHttpTransport` 把 `finalUrl` 报告为"请求时给它的那个 URL"，而不是 `HTTPURLResponse.url`：`HostTransportDelegate` 对每一次重定向都答 `nil`，这条传输在结构上不可能跟随跳转，因此响应必然属于所请求的 URL。`HTTPURLResponse.url` 给出的是 CFNetwork 规范化之后的请求 URL——空路径补成 `/`、百分号转义改写为大写、默认端口被去掉——而网关用 `response.finalUrl == url` 判断"传输是否偷偷跟随了跳转"，规范化改动任何一处都会被读成一次并不存在的重定向，报 `NETWORK_REDIRECT_DISALLOWED`。安卓端 `connection.url` 返回的就是原样的 `java.net.URL`，这条不变式恒真，网关那道判断只用于约束测试替身；iOS 直译时把恒真的不变式变成了一次 URL 规范化比较。表现为首页（裸 origin，`HttpsOrigin.canonical` 不带结尾斜杠）与站内搜索（查询串里手写的小写百分号转义）都在第一跳就失败。
- **偏离规范硬约束（用户明示要求，第二次）**：宿主网络抓取同样允许"站点自己发起的、落到明文 http 的跳转"，规则与受控登录窗口那条逐字一致。理由：wenku8 把自己的页面 302 到明文，登录窗口放行之后能登进去，但之后每一次浏览/搜索/详情/章节抓取都在同一次 302 上被拒，报 `NETWORK_REDIRECT_DISALLOWED`——放行了登录却用不了来源，这条硬约束只剩下让来源不可用这一个效果。安卓端网关同样是 https-only，因此它的 wenku8 搜索多半也是坏的，这不是 iOS 独有的问题。放开的边界：`allowedUrl`（扩展请求的 URL、referrer、封面初始 URL）仍然仅 HTTPS——宿主永远不主动发起明文；只有站点发来的 `Location` 与响应落定的 URL 走 `reachableUrl`，主机与端口仍须属于已授予的 origin，scheme 是唯一放开的东西。仓库索引/签名/扩展包下载（`fetchStaticResource`）不跟随跳转，保持不变。Cookie 归属改为按主机+端口判定（`declaredOrigin(of:within:)`），否则登录拿到的会话在明文那一跳上会被静默丢掉；代价即为此：**会话 Cookie 会以明文经过网络**——用户已在登录窗口接受了更重的那一半（密码本身就走明文）。远程书架写入面（`matchesSurface`）同样按忽略 scheme 判定，明文形态是同一个受保护面，不构成绕过铸造 add 上下文的路径；签名的 redirect policy 仍要求 HTTPS 目标，因为它声明的就是 `HttpsOrigin`。
- `NSAllowsArbitraryLoads = true`：策略放行之后 App Transport Security 仍会在网络层挡掉 `URLSession` 的明文请求，因此这个键必须一起放开。它不放宽任何应用内规则——`fetchStaticResource` 与 `allowedUrl` 仍在代码里强制 https，ATS 在这里只是第二道重复的闸门。仍然不使用按域名的 `NSExceptionDomains`：宿主里不允许出现任何具体站点。
- 网络网关向扩展报告的 `finalUrl` 一律还原成声明 origin 的形态（`GrantedUrl.settled`）：授权里只能出现 `HttpsOrigin`，扩展没有任何办法表达一个明文 origin——它的代码写的就是 `ORIGIN = 'https://…'`，wenku8 扩展在章节路径上直接 `if (!normalized.startsWith(ORIGIN + '/')) throw 'ORIGIN_NOT_GRANTED'`。把重定向落到的那个 http URL原样交回去，扩展会拒绝它自己的页面。路径、查询、片段一律不动，只把 origin 写回声明形态；"明文那一跳属于同一个 origin"这条判定与 Cookie 归属、受保护写入面用的是同一条规则，`finalUrl` 若单独按 scheme 判定就成了三处里唯一不一致的那处。
- URL 准入的三条规则收在 `GrantedUrl` 里（`requested` / `reachable` / `settled`）：它们的差别只在"这个 URL 是谁选的"，而这正是明文规则的全部内容，放在一起才看得出区别；`HostNetworkGateway` 也因此回到 400 行以内。
- 失败码后附上 `stage` 与 `safeCode`（`EXTENSION_RUNTIME_FAILURE · search · js_exception`），与安卓搜索失败屏显示的信息一致（`SearchScreen.kt` 显示 `diagnostic.stage` 与 `diagnostic.safeCode`）。两者都由宿主代码用字面量与枚举 raw value 构造，并由 `SourceDiagnostic` 限长，因此不可能带上页面文本、Cookie 或 JS 栈。不附的话，扩展的每一种崩溃在界面上都是同一个 `EXTENSION_RUNTIME_FAILURE`，停在哪一步只能靠猜——真机联调里这已经代价过高。
- 受控登录窗口存下的会话由 `SourceRegistry` 在打开来源通道时载入网关（`adoptStoredSession`），对齐安卓的 `SourceGatewayFactory`：网关的 Cookie 罐是进程内的、按 `(sourceId, extensionVersion)` 分区，除此之外没有任何代码往里放东西——此前登录只写进 `VerifiedBrowserSessionStore` 就结束了，宿主的每一次抓取都是匿名的，站点回一个登录表单，扩展的 `classifyPage` 据此返回 `session-required`，界面显示"需要先在受控浏览器中登录"，而用户明明刚登录过。载入点选在开通道处而不是每次请求：Cookie 罐的归属是授权，授权在通道打开时才成形。因此"我已完成"之后要关掉该来源的通道（`VerificationModel.finish`），否则新会话要等到下次启动才生效。
- 不复制安卓的按 origin 注入 User-Agent：安卓需要它是因为它的 WebView 用的是系统 UA，而 iOS 的 `ControlledWebLoginSession` 显式把 `customUserAgent` 设成 `AppContainer.userAgent`，与 `URLSessionHostHttpTransport` 用的是同一个常量，两边本来就一致。加一层没有差异可传的注入就是无消费者的代码。
- 阅读器的视口测量放在状态分支之外（`GeometryReader` 包住 `StateView` 而不是待在 content 闭包里）：分页是 `.content` 状态的产物，而分页要先知道页面尺寸——测量只在 content 存在时进行，阅读器就永远停在"加载中"。这是直译安卓布局的产物：Compose 的测量与状态分支无关，SwiftUI 里把 `GeometryReader` 放进 content 闭包就构成了自循环。端到端测试看不见，因为测试自己调了 `reader.resize(_:)`，正好补上了真实界面从来没做过的那一步。
- 阅读器子树显式设置 `\.colorScheme` 为阅读主题自身的明暗（`ReaderTheme.colorScheme`）：阅读主题是读者的选择，与系统外观无关，而画在它上面的加载/失败状态与控件解析的是语义色。系统处于深色、主题是纸色时，`.secondaryLabel` 会在近白底上写近白字——表现为一整屏白、中间一行几乎看不见的"加载中"。
- 书架 tab 有自己的导航栈（`LibraryRoute`），不复用 `Route`：`Route` 归 `SourceFlowController` 管，它要按来源快照恢复现场，而从书架打开的书不属于任何来源流程。`BookHost` 与 `ReaderHost` 因此不再自己决定往哪里压栈，由承载它们的栈注入——此前从书架点章节会把 reader 压进浏览 tab 的栈里，那个栈书架永远不显示，表现为"点了没反应"。
- `AppRootView` 直接观察 `AppPreferences`：偏好发布在它自己身上，不发布在 `AppContainer` 上，通过 `container.preferences` 读取会把根视图排除在更新之外，深浅色选择要等下一次别的原因触发重绘（比如切 tab）才生效。
- 来源失败的可行动提示收敛到 `SourceFailureGuidance`：同一个错误码在哪个屏上都是同一个意思，每屏各写一份的结果就是书籍页对着一个"站点要求人工验证"显示"来源返回的页面无法解析"。
- 受控登录窗口实现 `WKUIDelegate.createWebViewWith`，把请求新窗口的导航（`target="_blank"`，这些站点链到自己页面的常用写法）在原窗口里加载，并始终返回 nil：这个会话按设计只有一个受控窗口，不实现这个回调时 WebKit 会直接丢掉那次导航，表现为"点哪本书都没反应"——而且登录本身不受影响，因为登录表单是同框架提交的，于是这个缺陷在"能登录"的表象下藏着。新窗口请求仍走同一条 `isReachable` 判定，不构成第二条放宽的入口。
- `isReachable` 提为 `nonisolated static`（按声明 origin 集合判定）：这条规则决定窗口能去哪里，已经两次成为缺陷来源，而它本身是纯逻辑，没有理由不可测。
- 验收 fixture 扩展（`org.tsuyomi.wenku8`）带一处本地改动：`classifyPage` 把 `sessionRemediation` 从前置门改为后置解释，与它自己的 `generic` 分支一致。理由、逐字改动、构建方式与对验收的影响记在 `docs/FIXTURE_EXTENSION_PATCH.md`——`Tsuyomi-main/` 不进本仓库历史，那份源码只能靠文档留痕。宿主侧未因此改动任何一行：页面判定按规范就是扩展说了算，宿主不得改判。
- fixture 扩展在 CI 里从源码重建而不是当作二进制信任：本机没有 node，且带了本地补丁的归档必须由那份源码产出。重建前先跑扩展自带的测试套件——这个扩展不归本仓库所有，改它得先对它自己的测试负责。
- 阅读器正文的颜色由 `ReaderTextLayout.apply(textColor:)` 写进属性串，而不是设在视图上：TextKit 2 的 `NSTextLayoutFragment.draw` 取的是字符串自带的属性，`ReaderPageView.textColor` 从来没有被 `draw` 读过——正文因此永远是 TextKit 的默认黑色，夜墨与纯黑主题下等于看不见。颜色不是度量，只改颜色不改任何一页的边界，所以它不进 `layoutKey`，主题切换仍然不重排。
- 翻页由 `ReaderPagingView` 做横向滑出/滑入，旧页取快照、始终只画一页；只有"同一份分页计划上正负一页"才动画，换章、重排、切换阅读流一律直接替换。Reduce Motion 打开时不动画。翻页是读者唯一的连续反馈，硬切读起来像掉帧而不像翻页。同时加了左右滑动手势；三分屏点击保留，因为大屏单手时边缘点击是唯一还能用的操作。
- 阅读器隐藏底部 tab bar（`.toolbar(.hidden, for: .tabBar)`）：阅读占满整屏，正文下面压一条 tab 既容易在翻页时误触，也在暗示阅读器是某个 tab 里的一个面板，而它不是。
- 列表行的可点区域显式声明 `.contentShape(Rectangle())`（书籍目录与阅读器目录两处）：`Spacer` 与行内边距本身不带命中区域，不声明的话只有文字那一小块能点中，表现为"点了没反应"。
- 书籍页新增「开始阅读/继续阅读」主操作：目录页的目的就是开始读，此前唯一入口是滚到章节列表里自己找。落点取上次读到的那一章，没有则取来源顺序的第一章——与目录当前是正序还是倒序无关。
- 标签改为逐个 badge，按 `TsuyomiWrappingRow` 自动折行：来源声明多少个标签、每个多长都无法预知，单行 `HStack` 只能裁掉或挤成看不清的窄条。
- 简介默认限制 4 行，可展开：简介可以很长，而读者点进这一页是为了目录。
- 阅读器本轮只做到"滑动翻页 + 手势"，不照搬安卓的翻页实现；卷页/仿真翻页与拖拽跟手留待后续（用户明示按 iOS 系统阅读应用的形态逐步扩展）。
- 翻页效果是读者的选项（`ReaderPageTransition`：滑动/卷页/无），由 `UIPageViewController` 承载：它的 `.scroll` 就是滑动、`.pageCurl` 就是卷页，两者都自带跟手拖拽，不必自己实现两套动画。transitionStyle 只能在构造时确定，所以改设置是重建子控制器而不是改属性。选「无」时不设 dataSource——没有 dataSource 就没有可交互的翻页手势，这正是「无动画」的含义。Reduce Motion 打开时无条件按「无」处理：卷页是一次幅度很大的运动，那个设置是用来遵守的，不是用来绕开的。
- 卷页样式自带的边缘点击被禁用（`gestureRecognizers` 里的 tap），只保留它的拖拽：三分屏点击已经承担了上一页/下一页/呼出控件三件事，两套点击叠在一起会一次翻两页。
- 拖拽落定后由 `didFinishAnimating(transitionCompleted:)` 上报页码，`ReaderModel.turned(toPage:)` 记录落点；弹回的拖拽不上报。与 `step(_:)` 不同，拖拽到章首/章尾不会翻到相邻章——数据源在两端返回 nil，越章只能由点击或目录发起。
- `pageTransition` 不进 `layoutKey`，也不进 `tsuyomi-transfer` 的可导出子集：它是呈现方式，既不改变任何一页的边界，也不是跨端可移植的阅读偏好。
- 阅读器设置只有一份：设置 tab 的「阅读器设置」（原「阅读器默认值」）与阅读器内的设置面板共用同一个 `ReaderSettingsForm`，写的也是同一个 `AppPreferences.reader`。此前是两份手写的控件列表，已经漂移——设置屏用 Picker、缺「翻页效果」，而且阅读器里改完根本不落盘，退出即丢。「默认值」这个名字本身就是错的：不存在"默认值"与"每本书的设置"两层，只有一份设置。
- 设置屏直接按绑定读写 `preferences.reader`，不再在构造时取一份 `@State` 快照：快照会在书里改过设置之后显示旧值。
- 页面颜色即应用外观：删掉阅读器自己的主题选择（`ReaderSettings.theme`），正文明暗由 `ColorSchemePreference` 决定（浅色→纸白、深色→夜墨）。`ReaderTheme` 这个类型保留，因为它是 `tsuyomi-transfer` 说的词汇：导出时按当前外观推导，导入时把主题映射回外观，而不是落到一个没有任何代码会读的阅读器字段上。
- 删掉「沉浸模式」开关：状态栏与主屏手势条现在跟随控件显隐——控件收起时整屏只有正文，点一下中间三者一起回来（Apple Books 的行为）。开关留着就是一个不再决定任何事情的死设置。
- 阅读器控件按 Apple Books 的形状重做：章节标题常驻顶部（它属于页面，不是控件），页码常驻底部；点中间才出现右上角关闭圆钮、右下角「更多」圆钮，页码同时变成「N/M 页」。控件是浮在页面上的圆形按钮而不是上下工具条，因此呼出控件不会让正文重排一个字。目录、主题与设置、上一章/下一章收进「更多」菜单。
- 标签改为按标签名派生颜色的 tinted pill（`TsuyomiTagBadge`）：用自己算的稳定哈希而不是 `hashValue`（后者每个进程重新播种，会导致每次启动换一次色）。颜色只用于一眼区分，不承载任何含义。
- 书籍页改为 plain list：目录才是这一页的主体，上面的封面/简介/标签/开始阅读是报头。加入书架与稍后再读降为图标按钮——它们不是打开这一页的目的。
- 进度滑杆一度被误判为"没用"而删除，实际是**单位错了**：`ReaderModel.scrub(_ fraction:)` 收的是 0…1 的比例，而旧的 `Slider` 声明成 `in: 0...Double(pageCount - 1)` 并把原始页码传了进去，于是拖动一离开起点 `fraction * last` 就越界、钳到最后一页——看起来就是"拖了没反应，或者直接跳到结尾"。回归后按 Apple Books 的形态重做（`ReaderScrubber`）：圆角轨道 + 细竖条拇指，拖动时轨道上方浮出章节名与页码。`onScrub` 的参数类型在协议注释里写明是比例而不是页码。
- 阅读器控件占据固定高度（`ReaderChromeMetrics`），正文按「屏幕减去控件」的高度分页并内缩绘制：此前正文是全屏绘制、控件浮在其上，页眉那行小字直接压在第一行正文上；只挪绘制不改分页高度则会把多出来的行排到页外。
- 「更多」面板是自绘的圆角行，不是系统 `Menu`：系统菜单放不下「目录」旁边那个进度百分比，而且它在打开 sheet 前会先自行消失，看起来像面板闪了一下。面板里只有真实 handler——目录、主题与设置、上一章/下一章。
- 书籍页「开始阅读」的宽度加在 label 上而不是按钮外框上：bordered 按钮的背景是围着 label 画的，只放大外框会得到一个大盒子里的小按钮。加入书架/稍后再读固定为 44×44 的图标方钮并靠左收拢，否则 bordered 按钮会在宽列里自行拉伸。
