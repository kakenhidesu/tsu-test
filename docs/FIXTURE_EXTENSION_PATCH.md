<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# 验收 fixture 扩展的本地改动

> **2026-09-17 更正**：2026-09-16 的说明记错了。独立仓库
> [`Chachaanteng/tsuyomi-extensions`](https://github.com/Chachaanteng/tsuyomi-extensions) 的
> `1d7062e` 与其后的 `53b7dc5`（0.2.33）都**没有**含 `isRequestedPage()` 顺序修正，`classifyPage`
> 仍先问 `sessionRemediation`。`Tsuyomi-main/tsuyomi-extensions` 自刷新起是 `1d7062e` 的原样快照，
> 因此顺序修正随刷新丢失。
>
> **现行本地补丁（2026-09-17）**：wenku8 开始向完整送达的详情页注入 Cloudflare 的被动评分脚本
> `/cdn-cgi/challenge-platform/scripts/jsd/main.js`，路径里的 `challenge-platform` 命中验证页判据，
> 每本书详情都成了"需要验证"。补丁比早先的顺序修正更窄：`src/wenku8/index.mts` 的
> `sessionRemediation` 在匹配 `captcha|cf-chl-|challenge-platform|人机验证|安全验证|验证码` 之前，先用
> `PASSIVE_CLOUDFLARE_SCRIPT`（`/\/cdn-cgi\/challenge-platform\/scripts\/jsd\/[^\s'"<>]*/gi`）把这条
> 引用去掉；判据本身、顺序与其余分支一字未动，真验证页、登录页和自带的 `challenge`/`login` 用例判定不变。
> `test/wenku8.test.mjs` 增一用例：带被动脚本的详情页与目录页判 `ok`，带被动脚本的验证页仍判
> `verification-required`。同一改动在独立克隆的 `fix/wenku8-passive-cloudflare-script` 分支上备好提交，
> 等用户决定是否向上游开 PR。（已由用户合入上游 `4f7f28e`，0.2.34。）
>
> **第二处本地补丁（2026-09-17）**：书架刷新（`update-check-v2`）报"需要验证"。这次是站点真的拦：
> wenku8 的 Cloudflare 规则对**不带 Referer** 的 `/modules/article/reader.php` 返回 403 拦截页
> （`Just a moment`），带任意 Referer 即 200。目录请求带了 `referrerUrl`（书页），更新检查请求没带。
> 宿主按签名策略要求请求的 referrer 与 `updateCheck.referrerPath` 严格相等，所以修法是两处一起：
> 清单（`release/sources.json` 与 `tools/build-fixture.mjs`）的 `updateCheck` 声明
> `referrerPath: "/index.php"`，`buildUpdateCheckV2Request` 发 `referrerUrl: ${ORIGIN}/index.php`，
> 测试里请求形状的断言同步。宿主侧未改一行。以下为 2026-09 初的历史记录。

本仓库交付的是 iOS 宿主，不是扩展。这里记录的是对**参考实现里的验收 fixture 扩展**
（`Tsuyomi-main/tsuyomi-extensions`，`org.tsuyomi.wenku8`）所做的本地改动——因为
`Tsuyomi-main/` 在 `.gitignore` 里，那份源码不进本仓库的历史，改动只能记在这里。

改动经用户明示同意后进行。

## 为什么改

真机联调发现：登录有效、首页与搜索正常、书籍详情页也正常，但点进任何一本书都在目录那一步
失败，错误码 `VERIFICATION_REQUIRED · directory-classify · verification-required`。

排查结论是宿主无责：

- 同一个会话、同一个 URL，在受控登录窗口里能正常显示章节列表；
- 失败发生在 `directory-classify`，说明**详情页已经通过了同一道判定**——同样的 UA、同样的
  请求头、同样的 origin，只有路径不同。若是站点按 UA 拦截宿主，`/book/N.htm` 不会通过。

也就是说宿主抓回来的是好页面，是扩展把它判成了验证页。

原因在 `classifyPage` 的判定顺序。它对每个具体操作先问「是不是要验证」，再问「是不是我要的
页」：

```js
const remediation = sessionRemediation(html);
if (remediation !== null) return remediation;      // 先问原因
if (operation === 'directory') { ...看是不是目录页... }
```

而 `sessionRemediation` 的判据是六个字符串之一——
`captcha|cf-chl-|challenge-platform|人机验证|安全验证|验证码`——除非页面同时含「欢迎您」和
「退出登录」才短路放行。`/modules/article/reader.php?aid=N` 没有站点顶栏，短路不成立；页面里
只要有一处「验证码」字样的表单，或 Cloudflare 注入到普通页面里的
`/cdn-cgi/challenge-platform/...` 脚本路径，整页就被判成验证页。

扩展自己的 `generic` 分支本来就是对的写法——先确认内容，没有内容才追问原因：

```js
if (operation === 'generic') {
  if (hasConcreteBookAnchor(html) || ...) return 'ok';
  return sessionRemediation(html) ?? 'ok';
}
```

其余分支顺序反了。

## 改了什么

`src/wenku8/index.mts`，`classifyPage` 一处：把各操作原有的形状判断原封不动收进
`isRequestedPage()`，然后

```js
return isRequestedPage() ? 'ok' : (sessionRemediation(html) ?? 'malformed');
```

**没有放宽任何判据**：每个操作的形状检查逐字保留，`sessionRemediation` 也逐字保留，只是从
前置门变成后置解释。真的验证页没有目录/详情/搜索结果的结构，`isRequestedPage()` 一样返回
false，仍然被判为 `verification-required`；真的登录页同理仍是 `session-required`。扩展自带
测试里的 `challenge`、`login` 两个用例覆盖的正是这两条，CI 会跑它们。

`tools/build-fixture.mjs`：版本 `0.2.25` → `0.2.26`，使设备上是一次明确的更新而不是重装。

## 怎么构建

本机没有 node，因此 fixture 在 CI 里从源码重建（`.github/workflows/ci.yml` 的
「Rebuild the acceptance fixture extension」步骤）：先跑扩展自带的测试套件，再
`npm run package:fixture`，最后校验 `wenku8-fixture.sha256`。产物作为
`wenku8-fixture-hxp` 构件上传，可直接在设备上导入。

签名用的是 `tools/build-fixture.mjs` 里公开的确定性测试种子（`1..32`，注释写明 test-only），
只有 Debug 构建信任它；Release 构建按设计拒绝。

## 对验收的影响

M0–M6 的自动化验收此后跑的是**这个改过的 fixture**，不是参考实现原样的那一份。宿主侧代码
没有为此改动任何一行。若要复现参考实现的原始行为，把上面那一处顺序改回去重新打包即可。

上游同样需要这个修正：本地改的是 `Tsuyomi-main` 里的源码，安卓端拿去是同一个修法。
