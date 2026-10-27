import Foundation
import Testing
@testable import Orra

/// The claim check of a draft: sentences that say a file is attached, in English, Chinese,
/// Japanese and Spanish, and the other side's attachments and requests, which are none. The
/// cases are written for these tests.
struct DraftCheckAttachmentsTests {
    @Test(arguments: [
        "Attached is the floor plan.",
        "Please find attached the revised quote.",
        "Please see attached.",
        "I've attached both drawings.",
        "We have attached the signed contract.",
        "I’m attaching the schedule for next week.",
        "See attachment for the details.",
        "The numbers are in the attachment.",
        "I am sending the plan as an attachment.",
        "Enclosed is the invoice.",
        "附上平面图，请查收。",
        "随信附上报价单。",
        "附件是最新的施工图。",
        "详见附件。",
        "请查收附件。",
        "平面图已附在邮件中。",
        "図面を添付いたします。",
        "見積書を添付しました。",
        "添付の資料をご確認ください。",
        "Te adjunto el plano.",
        "Adjunto la cotización.",
        "Le adjunto el contrato firmado.",
        "Hemos adjuntado las fotos.",
        "Va adjunta la factura.",
        "Encontrarás adjunto el informe.",
        "Los datos están en el archivo adjunto.",
    ])
    func attachmentClaimsInFourLanguages(_ sentence: String) {
        let draft = "Hi Mei,\n\nThanks for the update. " + sentence + "\n\nBest,\nLin"
        #expect(DraftCheck.attachmentClaims(in: draft) == [sentence])
    }

    @Test(arguments: [
        "Thanks for the attached plan.",
        "Thank you for sending the attached drawings.",
        "Your attached file did not open.",
        "The file you attached is empty.",
        "Please attach the floor plan.",
        "Could you attach the budget?",
        "感谢您附上的文件。",
        "您附上的平面图很清楚。",
        "收到您的附件了。",
        "请附上平面图。",
        "麻烦附上报价单。",
        "ご添付いただいた資料を確認しました。",
        "図面を添付してください。",
        "Gracias por el archivo adjunto.",
        "El archivo que me adjuntaste no abre.",
        "Por favor adjunta el plano.",
        "Adjunte la factura, por favor.",
        "The samples ship on Friday, 23 October.",
        "样品周五发出。",
    ])
    func theOtherSidesAttachmentAndRequestsAreNoClaims(_ sentence: String) {
        #expect(DraftCheck.attachmentClaims(in: "Hi Mei,\n\n" + sentence + "\n\nLin").isEmpty)
    }

    /// A sentence about the other side's attachment that also makes a claim of its own
    /// still counts.
    @Test func aClaimBesideTheOtherSidesAttachmentCounts() {
        let sentence = "Thanks for the attached plan; attached is my markup."
        #expect(DraftCheck.attachmentClaims(in: sentence) == [sentence])
        #expect(DraftCheck.attachmentClaims(in: "感谢您附上的平面图。附上我的修改意见。") == ["附上我的修改意见。"])
    }

    /// The check of the model's draft does not read claims: a draft that says a file is
    /// attached comes out of it as it went in.
    @Test func checkLeavesAClaimAsItWas() async {
        let draft = "Hi Owen,\n\nAttached is the floor plan. The tiles arrive on Thursday, 22 October.\n\nBest,\nBai Lu"
        let owen = DraftCheckInput.Person(name: "Owen Pike", address: "owen@pike-build.example")
        let result = await DraftCheck.check(DraftCheckInput(
            draft: draft, language: .en, recipients: [owen], projectPeople: [owen],
            own: [DraftCheckInput.Person(name: "Bai Lu", address: "bai.lu@lumenhaus.example")],
            incomingText: "Hello Bai Lu.", today: DraftCheckTests.today
        ))
        #expect(result.draft == draft)
        #expect(result.removals.isEmpty)
        #expect(result.flags.isEmpty)
        #expect(DraftCheck.attachmentClaims(in: draft) == ["Attached is the floor plan."])
    }

    /// The check reads at most the first 20,000 characters, so a long paste stays quick.
    @Test(.timeLimit(.minutes(1)))
    func aLongDraftIsReadInPart() {
        let long = String(repeating: "Thanks for the attached plan. ", count: 2_000) + "Attached is the floor plan."
        #expect(DraftCheck.attachmentClaims(in: long).isEmpty)
        #expect(DraftCheck.attachmentClaims(in: "Attached is the floor plan. " + long).count == 1)
    }
}
