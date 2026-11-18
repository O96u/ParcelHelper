import SwiftUI
import UIKit

/// Douyin does not offer this app a consumer-order OAuth grant.
/// This flow is intentionally user-driven: official-site login, copying
/// visible shipment details, and optional carrier tracking lookup.
struct DouyinImportView: View {
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var sourceText = ""
    @State private var edited: Parcel?
    @State private var returningFromDouyin = false
    @State private var askingToSave = false
    @State private var syncing = false
    @State private var notice: String?
    @State private var invalidMessage: String?
    @State private var merged = false

    private var duplicate: Bool {
        guard let mail = edited?.mailNo, !mail.isEmpty else { return false }
        return store.snapshot.parcels.contains {
            ($0.mailNo ?? "").caseInsensitiveCompare(mail) == .orderedSame
        }
    }

    var body: some View {
        Form {
            Section("抖音商城") {
                Text("打开抖音官网，登录后进入「商城 → 我的订单 → 查看物流」，复制物流内容。返回包裹助手后会识别刚复制的文字。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    returningFromDouyin = true
                    if let url = URL(string: "https://www.douyin.com/") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开抖音官方页面", systemImage: "arrow.up.forward.app.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text("普通网页登录不等于第三方订单 API 授权，因此不能自动读取整个账户的购物订单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("物流详情") {
                TextEditor(text: $sourceText)
                    .frame(minHeight: 145)
                    .accessibilityLabel("抖音物流文字")
                HStack {
                    Button("粘贴剪贴板") {
                        sourceText = UIPasteboard.general.string ?? ""
                        recognize()
                    }
                    Spacer()
                    Button("识别物流") { recognize() }
                        .buttonStyle(.borderedProminent)
                        .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if edited != nil {
                Section("识别结果 · 可编辑") {
                    TextField("商品名称", text: binding(\.userTitle, defaultValue: ""))
                    TextField("物流单号", text: binding(\.mailNo, defaultValue: ""))
                        .textInputAutocapitalization(.characters)
                    TextField("快递公司", text: binding(\.trackCompany, defaultValue: ""))
                    TextField("取件码", text: Binding(
                        get: { edited?.code ?? "" },
                        set: { edited?.code = $0 }))
                    TextField("驿站/取件点", text: Binding(
                        get: { edited?.courierStationName ?? "" },
                        set: { edited?.courierStationName = $0 }))
                    TextField("订单号（选填）", text: binding(\.orderId, defaultValue: ""))
                    if duplicate {
                        Label("相同运单号会合并更新，不重置已取件状态。",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if syncing { ProgressView("正在查询当前运单的物流轨迹…") }
                    Button(duplicate ? "确认合并并同步" : "保存并同步物流") {
                        askingToSave = true
                    }
                    .disabled(syncing)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("抖音物流导入")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, returningFromDouyin else { return }
            returningFromDouyin = false
            let clipboard = UIPasteboard.general.string ?? ""
            if DouyinTextParser.parse(clipboard).isValid {
                sourceText = clipboard
                recognize()
            }
        }
        .confirmationDialog("保存这条抖音物流记录？",
                            isPresented: $askingToSave, titleVisibility: .visible) {
            Button("保存") { saveAndSync() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅保存你已检查的资料；读取其他订单仍需你主动授权或复制。")
        }
        .alert("导入结果", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("完成") { dismiss() }
        } message: {
            Text(notice ?? "")
        }
        .alert("无法识别", isPresented: Binding(
            get: { invalidMessage != nil },
            set: { if !$0 { invalidMessage = nil } }
        )) {
            Button("确定", role: .cancel) { invalidMessage = nil }
        } message: {
            Text(invalidMessage ?? "")
        }
    }

    private func binding(_ key: WritableKeyPath<Parcel, String?>,
                         defaultValue: String) -> Binding<String> {
        Binding(
            get: { edited?[keyPath: key] ?? defaultValue },
            set: { edited?[keyPath: key] = $0 }
        )
    }

    private func recognize() {
        let result = DouyinTextParser.parse(sourceText)
        guard result.isValid else {
            edited = nil
            invalidMessage = "未发现明确的运单号或取件码。请复制「查看物流」页的文字，或粘贴后补全。"
            return
        }
        edited = result.asParcel()
    }

    private func saveAndSync() {
        guard var parcel = edited,
              !(parcel.mailNo ?? "").isEmpty || !parcel.code.isEmpty else {
            invalidMessage = "至少需要运单号或取件码。"
            return
        }
        parcel.source = "douyin"
        parcel.srcApp = SourceApp(id: "douyin", name: "抖音商城")
        merged = store.importDouyin(parcel)

        guard let mail = parcel.mailNo, !mail.isEmpty else {
            notice = "包裹已保存。没有运单号，无法自动查询物流轨迹。"
            return
        }
        // Try previously authorized delivery-platform sessions first; if those
        // have no route, NativeTracking may fall back to a configured carrier API.
        syncing = true
        Task {
            defer { syncing = false }
            do {
                let result = try await NativeTracking.lookup(mail)
                if var saved = store.snapshot.parcels.first(where: {
                    $0.mailNo?.caseInsensitiveCompare(mail) == .orderedSame
                }) {
                    if !result.nodes.isEmpty { saved.trackNodes = result.nodes }
                    if !result.latest.isEmpty { saved.trackLatest = result.latest }
                    if !result.company.isEmpty { saved.trackCompany = result.company }
                    if !result.shipperCode.isEmpty { saved.shipperCode = result.shipperCode }
                    saved.trackUpdatedAt = Date().timeIntervalSince1970 * 1000
                    store.upsert(saved)
                }
                notice = "抖音包裹已保存，并已更新当前运单的物流轨迹。"
            } catch {
                notice = "抖音包裹已保存，但查询当前运单失败：" + error.localizedDescription
            }
        }
    }
}
