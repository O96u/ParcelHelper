import AppIntents
import Foundation
import UIKit

/// Native Shortcuts action: receives explicitly shared text, never reads SMS or
/// another application's private data without user action.
struct AddParcelFromTextIntent: AppIntent {
    static var title: LocalizedStringResource = "从文字添加包裹"
    static var description = IntentDescription("识别用户提供的快递短信或物流文本，并添加到包裹助手。")
    static var openAppWhenRun = false

    @Parameter(title: "快递短信或物流文字")
    var content: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .result(dialog: "没有收到文字，请输入快递短信或物流信息。") }
        let parsed = SMSParser.parse(raw)
        guard !parsed.code.isEmpty || !parsed.trackingNumber.isEmpty else {
            return .result(dialog: "未找到取件码或运单号，请检查输入内容。")
        }
        var parcel = Parcel()
        parcel.code = parsed.code
        parcel.mailNo = parsed.trackingNumber.isEmpty ? nil : parsed.trackingNumber
        parcel.courierStationName = parsed.station
        parcel.address = parsed.address
        parcel.trackCompany = parsed.company.isEmpty ? nil : parsed.company
        parcel.smsContent = raw
        parcel.userTitle = "快捷指令导入"
        parcel.source = "shortcuts"
        if !parsed.code.isEmpty { parcel.arrivedAt = Date().timeIntervalSince1970 * 1000 }
        let updated = ParcelStore.shared.upsertRecognizedText(parcel)
        if updated { return .result(dialog: "已更新已存在的包裹。") }
        return .result(dialog: "已将包裹添加到包裹助手。")
    }
}

/// Runs directly from Shortcuts without asking the user to paste inside our App.
/// Because the user deliberately ran the action, iOS may still ask for paste permission.
struct AddParcelFromClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "识别剪贴板快递"
    static var description = IntentDescription("读取刚复制的快递短信并添加到包裹助手。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return .result(dialog: "剪贴板没有文字，请先复制一条取件短信。")
        }
        guard raw.count <= 2000 else {
            return .result(dialog: "剪贴板文字太长，请复制一条取件短信。")
        }
        let parsed = SMSParser.parse(raw)
        guard !parsed.code.isEmpty || !parsed.trackingNumber.isEmpty else {
            return .result(dialog: "未识别到取件码或运单号。")
        }
        var parcel = Parcel()
        parcel.code = parsed.code
        parcel.mailNo = parsed.trackingNumber.isEmpty ? nil : parsed.trackingNumber
        parcel.courierStationName = parsed.station
        parcel.address = parsed.address
        parcel.trackCompany = parsed.company.isEmpty ? nil : parsed.company
        parcel.smsContent = raw
        parcel.source = "shortcuts"
        parcel.userTitle = "快捷指令导入"
        if !parsed.code.isEmpty { parcel.arrivedAt = Date().timeIntervalSince1970 * 1000 }
        let updated = ParcelStore.shared.upsertRecognizedText(parcel)
        if updated { return .result(dialog: "已更新已有包裹。") }
        return .result(dialog: "已导入快递取件信息。")
    }
}

struct ParcelHelperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddParcelFromTextIntent(), phrases: [
            "用\(.applicationName)添加快递",
            "在\(.applicationName)导入取件码"
        ], shortTitle: "导入快递文字", systemImageName: "shippingbox")
        AppShortcut(intent: AddParcelFromClipboardIntent(), phrases: [
            "用\(.applicationName)识别剪贴板",
            "在\(.applicationName)导入剪贴板快递"
        ], shortTitle: "识别剪贴板", systemImageName: "doc.on.clipboard")
    }
}
