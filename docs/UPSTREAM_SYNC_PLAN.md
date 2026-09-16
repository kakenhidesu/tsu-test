<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# 上游同步计划（Xfire233/Tsuyomi 73b30de → c704480，2026-09-04 → 09-12）

用户决定（2026-09-16）：**全部同步**；功能相同时 UI 采用 iOS 风格设计；UI 放在最后并由用户把关。
本文件记录里程碑与状态，随进度更新。行为规范来自对上游 Android 代码与协议的逐项整理；
协议部分以 `Tsuyomi-main/tsuyomi-protocol` 的 schema/fixture 为准。

## 里程碑

| # | 范围 | 状态 |
|---|---|---|
| S1 协议 | `tsuyomi-transfer` v2/v3 严格导入与 v3 导出；`hxp-update-check-v2` 结果模型；Detail `lastUpdatedDate`；仓库 v1 与订阅链接（已在上一轮完成） | 完成 |
| S2 数据层 | SQLite `user_version` 4 → 10（逐步对应 Android Room v5–v10）：逐操作回写授权列、对账行的操作/目标、网站镜像三表、完读章节、更新收件箱八表、`local_pin`；书架"钉住 / 保留记录"语义；完读章节存储；镜像存储；更新存储；传输 v3 导入应用与导出 | 进行中 |
| S3 来源运行时 | 网络层操作种类扩到 READ/TARGETS/ADD/REMOVE/MOVE/UPDATE_CHECK 与逐操作签名策略；受保护写面；`SourceExtensionClient` 新增作者搜索、目标发现、移除、移动、更新检查、`parseRemoteLibraryAdd(finalUrl)`；`classifyPage` 的 `update-check` 操作 | 待办 |
| S4 扩展生命周期与信任 | 包级执行授权（非官方发布者）、来源发布者钉住与迁移回执、复合解析器的信任层级与作用域撤销、订阅启用/停用与墓碑、冷启动休眠对账、卸载围栏与导航清理、下载总时限与截断重试、失败分类、验证页返回前重开会话 | 待办 |
| S5 功能逻辑 | 网站镜像协调器（快照/分组/ADD·MOVE·REMOVE/JIT 授权/ADD→MOVE 续作）、更新协调器（会话/锚点/收件箱/排除/撤销/BGTaskScheduler 调度）、书架（钉住与保留、稍后再读独立、本地搜索、筛选排序面板、智能排序）、详情（作者搜索、拆分按钮语义、MOVE/REMOVE、更新排除）、阅读器（章节完读、码点进度、主题）、界面偏好重置 | 待办 |
| S6 UI（iOS 风格） | 浏览页"已安装 / 可安装"、仓库管理、发布者公钥输入、安装审批卡、镜像页、详情六行版式（`Menu` 代替拆分下拉）、书架搜索/筛选面板/固定分段、更新设置与报告、横幅；产出截图交用户把关 | 待办 |

## 不移植的部分（平台差异）
- Android 音量键翻页（`volumePaging`）：iOS 无音量键回调；偏好值只在传输里透传。
- E-ink 显示配置：上游已冻结，规范第 4 节剔除。
- WorkManager 前台服务与通知权限：iOS 用 `BGAppRefreshTask`/`BGProcessingTask` 表达"默认关闭、可选周期"，进度与结果一律在应用内的会话行里。
