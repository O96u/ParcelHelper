import SwiftUI
import UIKit

/// Consumer order authorization is not available yet. Import a Douyin
/// shipment using a tracking number supplied by the user instead.
struct DouyinImportView: View {
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss

    @State private var trackingNumber = ""
    @State private var importing = false
    @State private var notice: String?
    @State private var errorMessage: String?

    private var normalizedTrackingNumber: String {
        trackingNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
    }

    private var validTrackingNumber: Bool {
        normalizedTrackingNumber.range(of: #"^[A-Z0-9-]{8,40}$"#,
                                      options: .regularExpression) != nil
    }

    var body: some View {
        Form {
            Section("抖音商城") {
                Label("登录授权待定", systemImage: "person.crop.circle.badge.clock")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("暂不支持抖音商城账号登录或自动读取购物订单。你可以从抖音订单的「查看物流」中复制快递单号，在下方直接导入，无需在包裹助手重复登录抖音。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("导入快递单号") {
                HStack(spacing: 10) {
                    TextField("请输入或粘贴运单号", text: $trackingNumber)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.done)
                    Button("粘贴") {
                        trackingNumber = UIPasteboard.general.string ?? ""
                    }
                    .font(.subheadline)
                    .disabled(importing)
                }

                if importing { ProgressView("正在查询物流…") }

                Button(action: importTrackingNumber) {
                    Label(importing ? "正在导入…" : "导入快递单号",
                          systemImage: "shippingbox.and.arrow.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!validTrackingNumber || importing)
            } footer: {
                Text("至少输入 8 位字母、数字或短横线组成的运单号。相同运单号会合并，不会清除已取件记录；物流自动查询取决于已授权平台或快递查询服务。")
            }
        }
        .navigationTitle("抖音物流导入")
        .navigationBarTitleDisplayMode(.inline)
        .alert("导入结果", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("完成") { dismiss() }
        } message: {
            Text(notice ?? "")
        }
        .alert("无法导入", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importTrackingNumber() {
        guard validTrackingNumber, !importing else {
            errorMessage = "请输入有效的快递单号（8 至 40 位字母、数字或短横线）。"
            return
        }
        let mail = normalizedTrackingNumber
        var parcel = Parcel()
        parcel.mailNo = mail
        parcel.userTitle = "抖音商城包裹"
        parcel.source = "douyin"
        parcel.srcApp = SourceApp(id: "douyin", name: "抖音商城")
        let merged = store.importDouyin(parcel)
        importing = true

        Task {
            defer { importing = false }
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
                notice = (merged ? "已合并相同单号包裹，" : "已导入包裹，") +
                         "物流轨迹查询完成。"
            } catch {
                notice = (merged ? "已合并相同单号包裹。" : "快递单号已保存。") +
                         "暂未获取物流轨迹：" + error.localizedDescription
            }
        }
    }
}
