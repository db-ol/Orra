import Foundation
import Testing
@testable import Orra

/// The extractor of names on the screen, with texts of the context experiment of
/// 2026-10-15. The common words are the words of the speech model's tokenizer that these
/// texts hold, so the results match the experiment's without the model on the Mac.
struct ScreenNamesTests {
    /// The words of Qwen3-ASR's vocab.json among those the texts below ask about.
    static let common = CommonWords(
        latin: Set("""
            a ack agre agree agreed an analytic analytics and approve approves are as ask asked at back beta bill billing \
            bram brand but by cache call calls can cause chapter check client confirm confirmed confuse confusing contract \
            coordinate cousin dana dear depend depends did discussion draft endpoint english every everyone figur figure \
            figures final finance finish first follow following for four from gateway group grpc half halfway handle \
            handling have hi high him hour i identity in incident ine inn integration is issu issue issued it keep keeps \
            kristen latency launch legal lena library man mention mentioned migration mist mister morgan morning most mostly \
            narrator need new next night node not note notes novel numb number numbers oauth old on once only open our pag \
            page path philip phillip phillips pilot plan planning procurement qa quick quote read reading ready recap \
            refresh refreshed reject rejecting rest retention roll rolled root rumor said saw schedule scheduler see service \
            set settle settles shard side skipped so solver start started step steps still summary support team term terms \
            thank thanks that the them theodore there thi this thought through timeline to token tokens too two update \
            updated vendor visitor visitors want wants was we week well went will window with within word wording writ write \
            writing you young younger zero
            """.split(whereSeparator: \.isWhitespace).map(String.init)),
        han: Set("""
            一下 一直 上周 上线 下周 下面 不用 临时 事情 交付 今天 付款 以下 任务 休假 会议 你好 依赖 保留 关于 内容 内部 刷新 另外 司马 合同 同事 周五 回复 地方 外面 大家 如果 \
            完成 对方 已经 帮忙 建议 开会 我们 技术 抓紧 报销 抱歉 接口 接手 收到 整理 文件 文档 方案 日期 昨天 最近 有点 本周 条款 根据 格式 欧阳 测试 清楚 直接 相关 确认 科技 \
            第二 结论 统一 补充 计划 讨论 议题 记得 设计 评审 调整 负责 财务 辛苦 迁移 过来 还有 遗漏 那边 部分 问题 阶段 附件 随时 需要 项目 预算
            """.split(whereSeparator: \.isWhitespace).map(String.init))
    )

    private func terms(_ before: String, title: String? = nil) -> [String] {
        ScreenNames.terms(in: ScreenText(beforeCursor: before, windowTitle: title), common: Self.common)
    }

    @Test func namesInAnEmailComeOutWithoutTheirTitleOrGreeting() {
        let found = terms("Hi Kristen,\n\nThanks for the Quorvia launch notes. Dana and I went through them this morning, and the beta can still open to the pilot group on schedule. Kirsten Ahlgren from legal wants to read the retention wording first. Teodor Halvik is handling the billing integration with Theodore Brandt on the vendor side. ")
        #expect(found == ["Theodore Brandt", "Teodor Halvik", "Kirsten Ahlgren", "Quorvia"])
    }

    @Test func aCourtesyTitleIsNoPartOfTheName() {
        let found = terms("Reading group notes, week four\n\nWe are halfway through the novel. The narrator keeps confusing the two visitors at the inn, Mister Jago and the younger man everyone calls Philip. Cora thought Jago was English, but this chapter settles it. Iago Phillips, the innkeeper's cousin, is only mentioned as a rumor. Quote for the discussion: ")
        for name in ["Jago", "Philip", "Cora", "Iago Phillips"] {
            #expect(found.contains(name), "\(name) in \(found)")
        }
        for word in ["Mister Jago", "Mister", "Reading", "Quote", "novel", "English"] {
            #expect(!found.contains(word), "\(word) in \(found)")
        }
        // Said twice, so first.
        #expect(found.first == "Jago")
    }

    @Test func rareWordsAcronymsAndCodesAreTerms() {
        let contract = terms("Dear Imogen,\n\nFollowing our call, I have updated the Velloria contract summary. Fenwick Ashdown will countersign once finance approves the escrow terms, and Imogene Thackeray from procurement asked for the final numbers in writing. To recap the figures we agreed: ")
        for term in ["Imogene Thackeray", "Fenwick Ashdown", "Velloria", "Imogen", "escrow", "countersign"] {
            #expect(contract.contains(term), "\(term) in \(contract)")
        }
        #expect(!contract.contains("Dear") && !contract.contains("Following") && !contract.contains("procurement"))

        let chat = terms("Joaquin Arevalo: did the Kelpstone migration finish?\nYusuf Demirel: mostly. p99 latency is still high on the read path\nJoaquin Arevalo: Joachim said the cache warmup was skipped\nYusuf Demirel: I'll check with him, Yosef from QA saw it too\n")
        for term in ["Joaquin Arevalo", "Yusuf Demirel", "Kelpstone", "p99", "warmup", "QA", "Joachim", "Yosef"] {
            #expect(chat.contains(term), "\(term) in \(chat)")
        }

        let incident = terms("Incident summary (draft)\n\nAt night the Marrowind gateway started rejecting tokens issued by the new OAuth client. Lena Brandvold paged the identity team, and Rowan Achterberg rolled the gateway back within half an hour. Root cause: the hysteresis window in the token refresher was set to zero, so every node refreshed at once. Ronan Acker from SRE and Lina Brand from support confirmed the timeline. Next steps: ")
        for term in ["Marrowind", "OAuth", "hysteresis", "SRE", "Lena Brandvold", "Rowan Achterberg", "Ronan Acker", "Lina Brand"] {
            #expect(incident.contains(term), "\(term) in \(incident)")
        }

        let update = terms("Hi Ines,\n\nQuick update on the gRPC migration for the Tessaro scheduler. The client library is ready, but the eigenvalue solver in the planning service still calls the old REST endpoint. Agnes Morgan on the analytics side depends on that endpoint as well, so we need to coordinate. ")
        for term in ["gRPC", "Tessaro", "eigenvalue", "REST", "Agnes Morgan"] {
            #expect(update.contains(term), "\(term) in \(update)")
        }
        #expect(!update.contains("Quick") && !update.contains("endpoint"))
    }

    @Test func chineseNamesTheWordBreakerDoesNotKnowAreFound() {
        let mail = terms("霖悦你好，\n\n最近辛苦了。抱歉回复晚了，这几天一直在外面开会。相关同事我都抄送了。如果下面有不清楚的地方，随时找我。附件是青岚计划第二阶段的排期。林悦那边已经确认了设计稿，凌越下周休假，测试由甄若岚临时接手。预算部分还有两个问题需要你拍板，")
        for term in ["霖悦", "林悦", "凌越", "甄若岚", "青岚计划", "拍板", "排期"] {
            #expect(mail.contains(term), "\(term) in \(mail)")
        }
        // Inside 青岚计划 only, so not on its own.
        #expect(!mail.contains("青岚"))

        let report = terms("鹭岛项目周报\n\n这份文档仅供内部讨论，请勿外传。以下内容根据上周的讨论整理，如有遗漏请直接在文档里补充。格式先不用管，内容确认后再统一调整。本周完成了埋点方案的评审，覃思远负责的分库分表方案已经上线灰度。秦思远提出熔断阈值偏低，需要再压测一轮。濮雨桐整理了接口文档，蒲雨彤从市场部借调过来帮忙。下周计划：")
        for term in ["鹭岛项目", "覃思远", "秦思远", "濮雨桐", "蒲雨彤", "灰度", "分库分表"] {
            #expect(report.contains(term), "\(term) in \(report)")
        }
    }

    @Test func aNameSaidMoreOftenComesFirst() {
        let chat = terms("欧阳澈：大家早\n司马晴：早\n欧阳澈：昨天的会议纪要发了吗\n司马晴：发了，在群文件里\n欧阳澈：好，我晚点看\n司马晴：另外报销单记得周五前交，财务那边催了两次\n欧阳澈：收到，今天事情有点多，我们抓紧对一下\n欧阳澈：星澜科技的合同今天能签吗\n司马晴：法务还在看付款条款\n祁砚：齐燕说对方要改交付日期，司马青也在问\n欧阳澈：改到哪天？\n")
        #expect(Array(chat.prefix(2)) == ["欧阳澈", "司马晴"])
        for term in ["司马青", "齐燕", "祁砚", "星澜科技"] {
            #expect(chat.contains(term), "\(term) in \(chat)")
        }
    }

    @Test func englishTermsInChineseTextAreKeptWhole() {
        let review = terms("技术评审纪要\n\n这份文档仅供内部讨论，请勿外传。以下内容根据上周的讨论整理，如有遗漏请直接在文档里补充。议题一：Tessaro 的 backfill 任务太慢，覃思远建议按租户做 sharding。议题二：Marrowind 网关的 OAuth token 刷新有抖动。Bram Oosthuizen 列席。结论：")
        for term in ["Tessaro", "backfill", "sharding", "Marrowind", "OAuth token", "Bram Oosthuizen", "覃思远"] {
            #expect(review.contains(term), "\(term) in \(review)")
        }
        let mail = terms("Ines 你好，\n\n最近辛苦了。关于 gRPC 迁移，Tessaro scheduler 的 client 已经改完了，planning service 里的 eigenvalue solver 还在调旧接口。Agnes 那边的 analytics 也依赖旧的 REST endpoint，闻溪建议先保留两周。")
        for term in ["gRPC", "Tessaro scheduler", "eigenvalue solver", "REST endpoint", "Agnes", "闻溪"] {
            #expect(mail.contains(term), "\(term) in \(mail)")
        }
    }

    @Test func namesComeBeforeOtherTerms() {
        let ranked = ScreenNames.rankedTerms(in: ScreenText(beforeCursor: "Joaquin Arevalo: did the Kelpstone migration finish?\nYusuf Demirel: mostly. p99 latency is still high on the read path\nJoaquin Arevalo: Joachim said the cache warmup was skipped\n"), common: Self.common)
        let sources = ranked.map(\.source)
        #expect(sources.contains(.name) && sources.contains { $0 != .name })
        #expect(sources == sources.sorted { ($0 == .name ? 0 : 1) < ($1 == .name ? 0 : 1) })
    }

    @Test func overTheLimitTheTermsNearestTheCursorStay() {
        let text = (1...50).map { "Q\($0)x" }.joined(separator: ", ")
        let found = terms(text)
        #expect(found.count == ScreenNames.limit)
        #expect(found == (11...50).reversed().map { "Q\($0)x" })
        #expect(ScreenNames.terms(in: ScreenText(beforeCursor: text), common: Self.common, limit: 5) == ["Q50x", "Q49x", "Q48x", "Q47x", "Q46x"])
    }

    @Test func theWindowTitleCountsAsTheFarthestText() {
        #expect(terms("Thanks, see you there. ", title: "Re: Quorvia launch plan") == ["Quorvia"])
        // Over the limit, the title goes first.
        let near = (1...40).map { "Q\($0)x" }.joined(separator: ", ")
        let found = terms(near, title: "Kelpstone")
        #expect(found.count == ScreenNames.limit)
        #expect(!found.contains("Kelpstone"))
    }

    @Test func emptyOrPlainTextGivesNoTerms() {
        #expect(terms("").isEmpty)
        #expect(terms("", title: "").isEmpty)
        #expect(terms("Thanks, see you there. ").isEmpty)
    }

    @Test func commonWordsComeFromTheTokenizerVocabulary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orra-vocab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("vocab.json")
        // Byte level BPE: Ġ is a space, and ä½łå¥½ the UTF-8 bytes of 你好.
        try Data(#"{"Ġthe": 1, "Ġhello": 2, "ä½łå¥½": 3, "abc": 4, "Ġ123": 5, "ä½ł": 6}"#.utf8).write(to: file)
        let words = CommonWords.load(from: file)
        #expect(words.latin == ["the", "hello"])
        #expect(words.han == ["你好"])
        #expect(words.isCommonLatin("Hellos"))
        #expect(!words.isCommonLatin("Quorvia"))
        let missing = CommonWords.load(from: folder.appendingPathComponent("missing.json"))
        #expect(missing.latin.isEmpty && missing.han.isEmpty)
    }

    @Test func theSwitchIsOffUntilTurnedOnAndSaved() throws {
        let suite = "orra-screen-names-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!ScreenNamesPreference.load(from: defaults))
        ScreenNamesPreference.save(true, to: defaults)
        #expect(ScreenNamesPreference.load(from: defaults))
        ScreenNamesPreference.save(false, to: defaults)
        #expect(!ScreenNamesPreference.load(from: defaults))
    }
}
