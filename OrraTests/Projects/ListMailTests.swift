import Testing
@testable import Orra

struct ListMailTests {
    @Test func readsTheHeadersWhateverTheCaseOfTheirNames() {
        let list = ListMail(headers: [
            (name: "Subject", value: "Weekly notes"),
            (name: "list-id", value: "Paper Lantern Weekly <weekly.paperlantern.example>"),
            (name: "LIST-UNSUBSCRIBE", value: "<mailto:leave@paperlantern.example>"),
            (name: "Precedence", value: "bulk"),
            (name: "List-Id", value: "<second.paperlantern.example>"),
        ])
        #expect(list.listID == "Paper Lantern Weekly <weekly.paperlantern.example>")
        #expect(list.listUnsubscribe == "<mailto:leave@paperlantern.example>")
        #expect(list.precedence == "bulk")
        #expect(list.listIdentifier == "weekly.paperlantern.example")
    }

    @Test func emptyHeadersCountAsNone() {
        let list = ListMail(listID: "  ", listUnsubscribe: "", precedence: nil)
        #expect(list == ListMail())
        #expect(list.sign(sender: "mei.tan@orchard.example", text: "See you at three.") == nil)
    }

    @Test func listIdentifierIsTheValueInAngleBracketsLowercased() {
        #expect(ListMail.identifier("\"Garden Club\" <Garden.Club.example>") == "garden.club.example")
        #expect(ListMail.identifier("  garden.club.example ") == "garden.club.example")
        #expect(ListMail.identifier("<>") == nil)
    }

    @Test func eachHeaderIsASign() {
        let text = "Here is this month's update."
        let sender = "mei.tan@orchard.example"
        #expect(ListMail(listID: "<club.orchard.example>").sign(sender: sender, text: text) == .listID)
        #expect(ListMail(listUnsubscribe: "<https://orchard.example/leave>").sign(sender: sender, text: text) == .listUnsubscribe)
        for precedence in ["bulk", "List", " junk "] {
            #expect(ListMail(precedence: precedence).sign(sender: sender, text: text) == .bulkPrecedence)
        }
        for precedence in ["first-class", "auto_reply"] {
            #expect(ListMail(precedence: precedence).sign(sender: sender, text: text) == nil)
        }
    }

    @Test func theStrongestSignWins() {
        let list = ListMail(listID: "<club.orchard.example>", listUnsubscribe: "<mailto:x@orchard.example>")
        #expect(list.sign(sender: "noreply@orchard.example", text: "Unsubscribe here.") == .listID)
        #expect(ListMail().sign(sender: "noreply@orchard.example", text: "Unsubscribe here.") == .noReplySender)
    }

    @Test(arguments: [
        "noreply@shop.example", "no-reply@shop.example", "no_reply@shop.example", "do-not-reply@shop.example",
        "donotreply@shop.example", "noreply+orders@shop.example", "noreply-billing@shop.example",
        "newsletter@shop.example", "digest@forum.example", "billing@power.example", "orders@shop.example",
        "alumni@college.example", "cfp@conference.example", "Mailer-Daemon@relay.example",
    ])
    func sendersPeopleDoNotWriteFrom(_ address: String) {
        #expect(ListMail.isNoReplySender(address))
    }

    @Test(arguments: [
        "bill.chen@orchard.example", "bill@orchard.example", "hello@orchard.example", "info@orchard.example",
        "nora@orchard.example", "noel.reyes@orchard.example", "news.desk.lead@paper.example", "no-at-sign",
    ])
    func sendersPeopleWriteFrom(_ address: String) {
        #expect(!ListMail.isNoReplySender(address))
    }

    @Test(arguments: [
        "To stop these emails, unsubscribe here.",
        "Click to Unsubscribe.",
        "Please do not reply to this message.",
        "This is an automated message from the booking system.",
        "如不想再收到此类邮件，请回复 TD 退订。",
        "点击这里取消订阅。",
        "本邮件由系统自动发送，请勿直接回复。",
        "此邮件为系统自动生成。",
    ])
    func footerWordingIsASign(_ text: String) {
        #expect(ListMail.hasUnsubscribeText(text))
        #expect(ListMail().sign(sender: "mei.tan@orchard.example", text: text) == .unsubscribeText)
    }

    @Test(arguments: [
        "Can we reply to the council by Friday?",
        "I subscribed to the print shop's samples last week.",
        "请尽快回复，周五前要定稿。",
        "订阅的杂志到了。",
    ])
    func ordinaryWordingIsNoSign(_ text: String) {
        #expect(!ListMail.hasUnsubscribeText(text))
    }
}
