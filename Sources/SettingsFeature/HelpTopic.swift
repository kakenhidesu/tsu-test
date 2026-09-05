// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The help content. It answers the questions this app's own design creates — why a source has to be
/// installed, why a login happens in a browser, why nothing syncs — rather than restating the UI.
public struct HelpTopic: Identifiable, Hashable, Sendable {
    public let id: String
    public let question: String
    public let answer: String

    public static func matching(_ query: String) -> [HelpTopic] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.question.contains(trimmed) || $0.answer.contains(trimmed) }
    }

    static let all: [HelpTopic] = [
        HelpTopic(
            id: "sources",
            question: "为什么书架里没有内容？",
            answer: "应用本身不带任何来源。你需要先添加一个扩展仓库并安装来源扩展，才能搜索和阅读。"
        ),
        HelpTopic(
            id: "trust",
            question: "安装扩展意味着什么？",
            answer: "扩展在应用进程内运行，QuickJS 不是进程级沙箱。宿主限制了它能访问的站点、Cookie 作用域、"
                + "响应大小、内存与执行时间，但信任一个发布者仍然等同于信任它的代码。"
        ),
        HelpTopic(
            id: "login",
            question: "为什么登录要在浏览器里完成？",
            answer: "登录与人工验证由你在一个受控的浏览器窗口里亲手完成。应用不会替你点击、填写或绕过验证，"
                + "只在你明确点“我已完成”后保存该站点的 Cookie。"
        ),
        HelpTopic(
            id: "remote",
            question: "“加入书架”会同步到网站吗？",
            answer: "不会。加入书架永远只写在这台设备上。网站收藏是只读拉取，复制到本地也不会在网站上新增任何内容。"
        ),
        HelpTopic(
            id: "progress",
            question: "换了字号，阅读位置还准吗？",
            answer: "进度记录的是段落与其中的字符位置，不是页码或滚动比例。改字号、边距或翻页方式后，"
                + "同一个位置只是落在不同的页上。"
        ),
        HelpTopic(
            id: "privacy",
            question: "有没有账号或数据上传？",
            answer: "没有账号、没有使用统计、没有远程开关、没有崩溃上报、没有 iCloud 同步。"
                + "要把数据带到另一台设备，用数据迁移导出一个文件。"
        ),
        HelpTopic(
            id: "transfer",
            question: "迁移文件里有什么？",
            answer: "书架、收藏夹与智能规则、本地标签、评分、稍后再读、阅读进度、历史与阅读偏好。"
                + "不含登录凭据、Cookie、缓存正文与已安装的扩展。"
        ),
        HelpTopic(
            id: "dormant",
            question: "来源显示“休眠”是什么意思？",
            answer: "它的扩展被卸载、撤销或验签失败了。书架条目与进度都还在，重新安装该来源后即可继续阅读。"
        )
    ]
}
