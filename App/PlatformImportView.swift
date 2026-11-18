import SwiftUI
import UIKit

struct PlatformImportView: View {
    let platformName: String
    let platformID: String
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss
    @State private var sourceText = ""
    @State private var preview: DouyinImportResult? = nil
    @State private var edited: Parcel? = nil
    @State private var confirmation = false
    @State private var finished = false
    @State private var merged = false
    @State private var validationMessage = ""

    private var duplicate: Bool {
        guard let no = edited?.mailNo, !no.isEmpty else { return false }
        return store.snapshot.parcels.contains { ($0.mailNo ?? "").caseInsensitiveCompare(no) == .orderedSame }
    }

    var body: some View {
        Form {
            Section {
                Text("打开对应平台的订单物流详情，复制运单号、快递公司、取件码等文字，返回此处粘贴。此功能不会登录平台账号。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $sourceText)
                    .frame(minHeight: 155)
                    .accessibilityLabel("物流文本")
                HStack {
                    Button("读取剪贴板") { sourceText = UIPasteboard.general.string ?? "" }
                    Spacer()
                    Button("识别内容") { parseText() }
                        .buttonStyle(.borderedProminent)
                        .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: { Text("物流文本") } footer: {
                Text("只支持用户主动粘贴的文字；无法自动获取个人购物订单，也不会自动查询物流轨迹。")
            }
            if preview != nil, edited != nil {
                Section("识别预览 · 可修改") {
                    TextField("商品名称", text: Binding(get: { edited?.userTitle ?? "" }, set: { edited?.userTitle = $0 }))
                    TextField("运单号", text: Binding(get: { edited?.mailNo ?? "" }, set: { edited?.mailNo = $0 })).textInputAutocapitalization(.characters)
                    TextField("快递公司", text: Binding(get: { edited?.trackCompany ?? "" }, set: { edited?.trackCompany = $0 }))
                    TextField("取件码", text: Binding(get: { edited?.code ?? "" }, set: { edited?.code = $0 }))
                    TextField("驿站 / 取件点", text: Binding(get: { edited?.courierStationName ?? "" }, set: { edited?.courierStationName = $0 }))
                    TextField("订单号（可不填）", text: Binding(get: { edited?.orderId ?? "" }, set: { edited?.orderId = $0 }))
                    TextField("最新物流文字", text: Binding(get: { edited?.trackLatest ?? "" }, set: { edited?.trackLatest = $0 }))
                    if duplicate {
                        Label("已存在相同运单号，保存后将合并缺失字段，保留原有取件状态和轨迹。", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange).font(.footnote)
                    }
                    Button(duplicate ? "确认合并包裹" : "保存包裹") {
                        guard let p = edited, !(p.mailNo ?? "").isEmpty || !p.code.isEmpty else {
                            validationMessage = "请至少填写运单号或取件码"
                            return
                        }
                        confirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
                Section("来源") {
                    LabeledContent("平台", value: "\(platformName) · 手动导入")
                    Text("原文将保存在包裹的短信/来源文本字段中，仅存储于应用数据。建议删除复制内容中的手机号、地址等不必要的个人信息。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("\(platformName)物流导入")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(duplicate ? "合并已有包裹？" : "保存包裹？", isPresented: $confirmation) {
            Button(duplicate ? "合并" : "保存") {
                guard var p = edited else { return }
                p.source = platformID
                p.srcApp = SourceApp(id: platformID, name: platformName)
                merged = store.importDouyin(p)
                finished = true
            }
        } message: { Text("只根据你主动粘贴和确认的信息保存到本地。") }
        .alert("导入结果", isPresented: $finished) {
            Button("完成") { dismiss() }
        } message: { Text(merged ? "已合并到同运单包裹，保留了原有状态。" : "包裹已保存，可在包裹页查看。") }
        .alert("无法导入", isPresented: Binding(get: { !validationMessage.isEmpty }, set: { if !$0 { validationMessage = "" } })) {
            Button("确定", role: .cancel) { validationMessage = "" }
        } message: { Text(validationMessage) }
    }

    private func parseText() {
        let value = DouyinTextParser.parse(sourceText)
        guard value.isValid else {
            preview = nil
            edited = nil
            validationMessage = "未识别到明确的运单号或取件码。请从物流详情复制包含“运单号：”等字段的文字，或手动补充后再导入。"
            return
        }
        preview = value
        edited = value.asParcel()
    }
}
