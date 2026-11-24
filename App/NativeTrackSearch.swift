import SwiftUI
import UIKit

// Port of the original Scripting ui/trackSearch.tsx search + recent history.
// The page does not manufacture a parcel from an unverified order number.
struct NativeTrackSearchPage: View {
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss
    @State private var mailNo = ""
    @State private var shipperCode = ""
    @State private var phoneTail = ""
    @State private var loading = false
    @State private var result: NativeTrackLookup?
    @State private var history: [String] = NativeTracking.history()
    @State private var errorNotice: String?
    @State private var manualAdd = false
    private let blue = Color(red:47/255,green:123/255,blue:246/255)

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack(spacing:10) {
                    Image(systemName:"magnifyingglass")
                        .font(.system(size:20)).foregroundStyle(.secondary)
                    TextField("搜索运单号",text:$mailNo)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { search() }
                    if !mailNo.isEmpty {
                        Button { mailNo = ""; result = nil } label: {
                            Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal,18).frame(height:52)
                .background(Color(uiColor:.tertiarySystemFill),in:Capsule())
                HStack(spacing:12) {
                    Picker("快递公司",selection:$shipperCode) {
                        ForEach(NativeTracking.shippers.indices,id:\.self) { index in
                            Text(NativeTracking.shippers[index].1).tag(NativeTracking.shippers[index].0)
                        }
                    }.tint(blue)
                    TextField("收件手机尾号（可选）",text:$phoneTail)
                        .keyboardType(.numberPad)
                        .onChange(of:phoneTail) { _, next in
                            phoneTail=String(next.filter(\.isNumber).prefix(4))
                        }
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .padding(14)
                .background(Color(uiColor:.secondarySystemGroupedBackground),
                            in:RoundedRectangle(cornerRadius:19))
                Button(action:search) {
                    HStack {
                        Spacer()
                        if loading { ProgressView().tint(.white) }
                        else { Image(systemName:"magnifyingglass") }
                        Text(loading ? "正在查询物流…" : "查快递")
                        Spacer()
                    }
                    .font(.headline)
                    .frame(height:48)
                }
                .buttonStyle(.borderedProminent)
                .tint(blue)
                .disabled(loading || mailNo.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if let result {
                    resultCard(result)
                } else if !history.isEmpty {
                    HStack {
                        Text("最近查询").font(.headline)
                        Spacer()
                        Button("清空") { NativeTracking.clearHistory();history=[] }
                            .font(.caption)
                    }.padding(.top,14)
                    ForEach(history,id:\.self) { number in
                        HStack {
                            Button {
                                mailNo=number
                                phoneTail=NativeTracking.phone(for:number)
                                search()
                            } label: {
                                HStack {
                                    Image(systemName:"clock.arrow.circlepath")
                                    Text(number).font(.system(.subheadline,design:.monospaced))
                                    Spacer()
                                    Image(systemName:"chevron.right")
                                }
                                .foregroundStyle(.primary)
                            }
                            Button {
                                NativeTracking.forget(number)
                                history=NativeTracking.history()
                            } label: {
                                Image(systemName:"xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(16)
                        .background(Color(uiColor:.secondarySystemGroupedBackground),
                                    in:RoundedRectangle(cornerRadius:16))
                    }
                }
                Button {
                    manualAdd = true
                } label: {
                    Label("无法查询？手动添加包裹",systemImage:"square.and.pencil")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top,15)
            }
            .padding(.horizontal,20)
            .padding(.top,16)
            .padding(.bottom,100)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor:.systemGroupedBackground))
        .navigationTitle("查快递")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.topBarLeading) {
                Button("取消") { dismiss() }
            }
        }
        .sheet(isPresented:$manualAdd) {
            NavigationStack {
                ParcelEditor(parcel:Parcel())
            }
        }
        .alert("查询结果",isPresented:Binding(
            get:{errorNotice != nil},set:{ if !$0 {errorNotice=nil} })) {
            Button("确定") {errorNotice=nil}
        } message: { Text(errorNotice ?? "") }
    }

    @ViewBuilder private func resultCard(_ r:NativeTrackLookup) -> some View {
        VStack(alignment:.leading,spacing:15) {
            HStack(spacing:11) {
                CourierBrandView(company:r.company,shipperCode:r.shipperCode,size:50)
                VStack(alignment:.leading,spacing:4) {
                    Text(r.company.isEmpty ? "物流包裹" : r.company)
                        .font(.headline)
                    Text(r.mailNo)
                        .font(.system(.caption,design:.monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string=r.mailNo
                } label: {
                    Image(systemName:"doc.on.doc").foregroundStyle(blue)
                }
            }
            if !r.latest.isEmpty {
                Text(r.latest).font(.subheadline).fixedSize(horizontal:false,vertical:true)
            }
            Text("数据来源："+r.provider)
                .font(.caption).foregroundStyle(.secondary)
            if !r.nodes.isEmpty {
                Divider()
                ForEach(Array(r.nodes.prefix(10).enumerated()),id:\.offset) { index,node in
                    HStack(alignment:.top,spacing:11) {
                        Circle().fill(index == 0 ? blue : Color.gray)
                            .frame(width:8,height:8).padding(.top,5)
                        VStack(alignment:.leading,spacing:5) {
                            Text(node.text).font(.subheadline)
                            if !node.time.isEmpty {
                                Text(node.time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Button {
                save(r)
            } label: {
                Label("加入包裹",systemImage:"plus.circle.fill")
                    .frame(maxWidth:.infinity)
            }
            .buttonStyle(.borderedProminent).tint(blue)
        }
        .padding(18)
        .background(Color(uiColor:.secondarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:24))
    }
    private func search() {
        guard !loading else { return }
        let mail=mailNo.trimmingCharacters(in:.whitespacesAndNewlines)
        loading=true
        result=nil
        Task {
            defer { loading=false }
            do {
                result=try await NativeTracking.lookup(mail,shipperCode:shipperCode,phone:phoneTail)
                history=NativeTracking.history()
            } catch {
                errorNotice=error.localizedDescription
            }
        }
    }
    private func save(_ r:NativeTrackLookup) {
        guard !r.nodes.isEmpty || !r.latest.isEmpty else {
            errorNotice="没有取得有效物流数据，不能自动导入"
            return
        }
        var item=store.snapshot.parcels.first {
            ($0.mailNo ?? "").caseInsensitiveCompare(r.mailNo) == .orderedSame
        } ?? Parcel()
        item.mailNo=r.mailNo
        if !r.company.isEmpty { item.trackCompany=r.company }
        if !r.shipperCode.isEmpty { item.shipperCode=r.shipperCode }
        TrackMerge.apply(to: &item, nodes: r.nodes, summary: r.latest)
        if !r.receiverCity.isEmpty { item.receiverCity=r.receiverCity }
        if !r.receiverAddress.isEmpty { item.receiverAddress=r.receiverAddress }
        item.trackUpdatedAt=Date().timeIntervalSince1970*1000
        if item.source == nil {
            // Preserve the successful backend's provenance. A free/public
            // lookup must never be presented as a KDniao-authenticated item.
            let source: (id: String, name: String)
            switch r.provider {
            case "快递鸟": source = ("kdniao", "快递鸟")
            case "快递100": source = ("kuaidi100", "快递100")
            case "菜鸟": source = ("cainiao", "菜鸟")
            case "拼多多": source = ("pdd", "拼多多")
            default:
                source = r.provider.hasPrefix("快递100") ?
                    ("kuaidi100", "快递100") : ("public", "公开物流查询")
            }
            item.source = source.id
            item.srcApp = SourceApp(id: source.id, name: source.name)
        }
        store.upsert(item)
        dismiss()
    }
}
