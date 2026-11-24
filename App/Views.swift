import SwiftUI
import UIKit
import MapKit
import WebKit

// Colors and card spacing follow theme.ts in the original Scripting project.
enum AppTheme {
    static func color(_ key: String) -> Color {
        switch key {
        case "green": return Color(red: 0.482, green: 0.714, blue: 0.38)
        case "orange": return Color(red: 0.941, green: 0.541, blue: 0.18)
        case "purple": return Color(red: 0.42, green: 0.36, blue: 0.82)
        default: return Color(red: 47/255, green: 123/255, blue: 246/255)
        }
    }
    static var accent: Color { color(UserDefaults.standard.string(forKey: "native.appearance.color") ?? "blue") }
}
private var accent: Color { AppTheme.accent }
private enum PH {
    static let page = Color(uiColor: UIColor { t in t.userInterfaceStyle == .dark ? .black : UIColor(red: 241/255, green: 241/255, blue: 245/255, alpha: 1) })
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let soft = Color(uiColor: .tertiarySystemGroupedBackground)
    static let orange = Color(red: 240/255, green: 138/255, blue: 46/255)
    static let green = Color(red: 52/255, green: 168/255, blue: 83/255)
    static var purple: Color { AppTheme.accent }
}
struct MainView: View {
    @AppStorage("native.appearance.color") private var themeColor = "blue"
    var body: some View {
        TabView {
            NavigationStack { PickupHome() }.tabItem { Label("取件", systemImage: "tray.and.arrow.down.fill") }
            NavigationStack { ParcelsHome() }.tabItem { Label("包裹", systemImage: "shippingbox.fill") }
            NavigationStack { StatsHome() }.tabItem { Label("统计", systemImage: "chart.bar.fill") }
            NavigationStack { SettingsHome() }.tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(AppTheme.color(themeColor))
        .id(themeColor)
        .background(alignment: .topLeading) {
            NativeWebAutoSyncHost()
        }
    }
}
struct BigHeading: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 35, weight: .bold)).tracking(-1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4).padding(.bottom, 7)
    }
}
struct NumberCard: View {
    let label: String; let value: String; let icon: String; let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint).font(.system(size: 20))
                Spacer()
            }
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).frame(height: 123)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 22))
    }
}
struct PHCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content().background(PH.card, in: RoundedRectangle(cornerRadius: 22)) }
}
struct PHSectionHeader: View {
    let title: String; var count: Int? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
            if let count { Text("(\(count))").font(.system(size: 16)).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
    }
}

// Reusable, intentionally lightweight dashboard design language.
private struct DashboardHero: View {
    let eyebrow: String
    let value: String
    let unit: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [accent, Color(red: 0.15, green: 0.30, blue: 0.57)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

private struct DashboardSection: View {
    let title: String
    let subtitle: String?
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 21, weight: .bold))
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

private struct DashboardEmpty: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 74, height: 74)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 36)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct PickupParcelRow: View {
    let parcel: Parcel
    var body: some View {
        HStack(spacing: 12) {
            CourierBrandView(company: parcel.trackCompany ?? "",
                             shipperCode: parcel.shipperCode ?? "",
                             source: parcel.srcApp?.id == "douyin" ? "douyin" :
                                  (parcel.source ?? parcel.srcApp?.id), size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(parcel.displayCode.isEmpty ? "待取件" : parcel.displayCode)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(parcel.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 20))
    }
}
struct ParcelCell: View {
    @EnvironmentObject private var store: ParcelStore
    let parcel: Parcel
    private var resolvedStation: String {
        store.snapshot.stations.first(where: { $0.id == parcel.courierStationUuid })?
            .courierStationName ?? parcel.stationText
    }
    private var statusColor: Color {
        parcel.isDone || parcel.isSigned ? PH.green : parcel.isPending ? PH.orange : accent
    }
    private var mainTitle: String {
        if parcel.isPending, !parcel.displayCode.isEmpty { return parcel.displayCode }
        if let name = parcel.userTitle, !name.isEmpty { return name }
        if let name = parcel.itemTitle, !name.isEmpty { return name }
        if parcel.isDone { return "已完成取件" }
        return parcel.title
    }
    private var status: String {
        parcel.displayStatus
    }
    var body: some View {
        HStack(spacing: 12) {
            CourierBrandView(company: parcel.trackCompany ?? "",
                             shipperCode: parcel.shipperCode ?? "",
                             source: parcel.srcApp?.id == "douyin" ? "douyin" :
                                  (parcel.source ?? parcel.srcApp?.id), size: 48)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(mainTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.80)
                    Spacer(minLength: 0)
                    Text(status)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }
                if let company = parcel.trackCompany, !company.isEmpty {
                    Text(company)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let latest = parcel.trackLatest, !latest.isEmpty {
                    Text(latest).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(accent.opacity(0.78))
                    Text(resolvedStation)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
    }
}
private struct PickupGroup: Identifiable { let name: String; let items: [Parcel]; var id: String { name } }
struct PickupHome: View {
    @EnvironmentObject private var store: ParcelStore
    @State private var refreshing = false
    @State private var refreshNotice: String?
    @State private var batchPickup = false
    @AppStorage("native.id.taobao.enabled") private var showTaobaoIdentity = true
    @AppStorage("native.id.cainiao.enabled") private var showCainiaoIdentity = true
    @AppStorage("native.id.pdd.enabled") private var showPddIdentity = true
    @AppStorage("native.id.jd.enabled") private var showJDIdentity = true

    private var pending: [Parcel] {
        store.snapshot.parcels
            .filter { $0.type == "delivery" && $0.isPending }
            .sorted { ($0.arrivedAt ?? $0.createdAt) > ($1.arrivedAt ?? $1.createdAt) }
    }
    private var picked: [Parcel] {
        store.snapshot.parcels.filter { $0.type == "delivery" && $0.isDone }
    }
    private var monthPicked: Int {
        picked.filter {
            guard let timestamp = $0.pickedAt else { return false }
            return Calendar.current.isDate(
                Date(timeIntervalSince1970: timestamp / 1000),
                equalTo: Date(), toGranularity: .month)
        }.count
    }
    private var groups: [PickupGroup] {
        let grouped = Dictionary(grouping: pending) { parcel -> String in
            let text = [parcel.address, parcel.courierStationName, parcel.smsContent]
                .joined(separator: " ")
            if let linked = store.snapshot.stations.first(where: {
                $0.id == parcel.courierStationUuid
            }) {
                return linked.courierStationName
            }
            return StationMatcher.match(store.snapshot.stations, text: text)?
                .courierStationName ?? parcel.stationText
        }
        return grouped.map { PickupGroup(name: $0.key, items: $0.value) }
            .sorted { ($0.name == "其他驿站" ? 1 : 0, $0.name) <
                      ($1.name == "其他驿站" ? 1 : 0, $1.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("取件").font(.system(size: 32, weight: .bold))
                    Spacer()
                    Text(Date.now, format: .dateTime.month().day().weekday(.wide))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                DashboardHero(
                    eyebrow: "我的取件清单",
                    value: "\(pending.count)",
                    unit: "件待领取",
                    detail: pending.isEmpty ? "当前没有待取包裹，轻松的一天" :
                        "分布在 \(groups.count) 个取件点，记得及时取件",
                    symbol: "tray.and.arrow.down.fill"
                )
                HStack(spacing: 10) {
                    statChip("本月已取", value: "\(monthPicked)", symbol: "checkmark.circle.fill", tint: PH.green)
                    statChip("累计已取", value: "\(picked.count)", symbol: "archivebox.fill", tint: accent)
                }

                if showTaobaoIdentity || showCainiaoIdentity || showPddIdentity || showJDIdentity {
                    VStack(alignment: .leading, spacing: 10) {
                        DashboardSection("身份码", subtitle: "到站后快速出示")
                        HStack(spacing: 9) {
                            if showTaobaoIdentity { identityButton("淘宝", platform: "taobao") }
                            if showCainiaoIdentity { identityButton("菜鸟", platform: "cainiao") }
                            if showPddIdentity { identityButton("拼多多", platform: "pdd") }
                            if showJDIdentity { identityButton("京东", platform: "jd") }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(accent)
                            Text("身份码快捷入口 · 不影响取件列表")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            NavigationLink {
                                IdentitySettingsPage()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("身份码设置")
                                    Image(systemName: "chevron.right")
                                }
                                .fontWeight(.medium)
                            }
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 5)
                    }
                }

                if pending.isEmpty {
                    DashboardEmpty(title: "包裹都取完啦", subtitle: "新包裹到站后会出现在这里",
                                   symbol: "checkmark.seal.fill")
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 11) {
                            DashboardSection(group.name, subtitle: "\(group.items.count) 件")
                            ForEach(group.items) { parcel in
                                NavigationLink {
                                    ParcelDetail(parcelID: parcel.uuid)
                                } label: {
                                    PickupParcelRow(parcel: parcel)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = parcel.displayCode
                                    } label: {
                                        Label("复制取件码", systemImage: "doc.on.doc")
                                    }
                                    .disabled(parcel.displayCode.isEmpty)
                                    Button {
                                        store.markDone(parcel.uuid, done: true)
                                        ParcelNotifications.cancel(parcel.uuid)
                                    } label: {
                                        Label("标记已取", systemImage: "checkmark.circle")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 110)
        }
        .background(PH.page)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refreshAllAsync() } } label: {
                    if refreshing { ProgressView() }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .accessibilityLabel("同步包裹")
                .disabled(refreshing)
            }
        }
        .refreshable { await refreshAllAsync() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { batchPickup = true } label: {
                    Label("批量取件", systemImage: "checklist")
                }.disabled(pending.isEmpty)
            }
        }
        .sheet(isPresented: $batchPickup) {
            NavigationStack { BatchPickupPage() }
        }
        .task { _ = await NativeHomeRefresh.refresh() }
        .alert("同步结果", isPresented: Binding(
            get: { refreshNotice != nil },
            set: { if !$0 { refreshNotice = nil } })) {
                Button("确定") { refreshNotice = nil }
            } message: {
                Text(refreshNotice ?? "")
            }
    }

    private func statChip(_ label: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 27, height: 27)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 17))
    }

    private func identityButton(_ name: String, platform: String) -> some View {
        NavigationLink {
            if platform == "jd" {
                JDIdentityPage()
            } else {
                IdentityDetailPage(title: name, platform: platform)
            }
        } label: {
            VStack(spacing: 7) {
                Image("brand_" + platform)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("动态取件码")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(PH.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func refreshAllAsync() async {
        guard !refreshing else { return }
        refreshing = true
        let result = await ParcelManualSync.refreshAll()
        refreshing = false
        refreshNotice = result.joined(separator: "\n")
    }
}
struct ParcelsHome: View {
    @EnvironmentObject private var store: ParcelStore
    @State private var filter = 0
    @State private var search = ""
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool
    @State private var finding = false
    @State private var importing = false
    @State private var batchImport = false
    @State private var deleteTarget: Parcel?
    @State private var selectedParcel: Parcel?

    private var counts: [Int] {
        let rows = store.snapshot.parcels.filter { $0.type == "delivery" }
        return [rows.count, rows.filter(\.isTransit).count,
                rows.filter(\.isPending).count,
                rows.filter { $0.isDone || $0.isSigned }.count]
    }
    private var visible: [Parcel] {
        store.snapshot.parcels.filter { p in
            guard p.type == "delivery" else { return false }
            let state = filter == 0 || (filter == 1 && p.isTransit) ||
                (filter == 2 && p.isPending) ||
                (filter == 3 && (p.isDone || p.isSigned))
            let text = [p.title, p.displayCode, p.mailNo ?? "", p.stationText,
                        p.smsContent, p.trackLatest ?? "", p.trackCompany ?? ""]
                .joined(separator: " ")
            return state && (search.isEmpty || text.localizedCaseInsensitiveContains(search))
        }
        .sorted { (($0.isDone || $0.isSigned) ? 1 : 0, -$0.createdAt) <
                  (($1.isDone || $1.isSigned) ? 1 : 0, -$1.createdAt) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text("包裹")
                            .font(.system(size: 32, weight: .bold))
                        Spacer()
                        Text("共 \(counts[0]) 件")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("物流总览")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.80))
                            Text("\(counts[1]) 件运输中")
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("\(counts[2]) 件待取 · \(counts[3]) 件已完成")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.77))
                        }
                        Spacer()
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 33))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 60, height: 60)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 20))
                    }
                    .padding(20)
                    .background(LinearGradient(
                        colors: [accent, Color(red: 0.12, green: 0.26, blue: 0.50)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 25))

                    if searchExpanded {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                            TextField("搜索取件码、商品、快递或驿站", text: $search)
                                .font(.system(size: 14))
                                .textInputAutocapitalization(.never)
                                .focused($searchFocused)
                                .submitLabel(.search)
                            if !search.isEmpty {
                                Button {
                                    search = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("清除搜索内容")
                            }
                        }
                        .padding(.horizontal, 15)
                        .frame(height: 47)
                        .background(PH.card, in: RoundedRectangle(cornerRadius: 16))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Picker("包裹状态", selection: $filter) {
                        Text("全部 \(counts[0])").tag(0)
                        Text("在途 \(counts[1])").tag(1)
                        Text("待取 \(counts[2])").tag(2)
                        Text("完成 \(counts[3])").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.bottom, 8)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 5, trailing: 18))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if visible.isEmpty {
                DashboardEmpty(
                    title: search.isEmpty ? "还没有这类包裹" : "没有搜索结果",
                    subtitle: search.isEmpty ? "点击右上角加号，添加或查找包裹" : "试试取件码、运单号或驿站名称",
                    symbol: "shippingbox"
                )
                .listRowInsets(EdgeInsets(top: 20, leading: 18, bottom: 12, trailing: 18))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(visible) { p in
                    Button {
                        selectedParcel = p
                    } label: {
                        ParcelCell(parcel: p)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { deleteTarget = p } label: {
                            Label("删除", systemImage: "trash.fill")
                        }
                        .tint(.red)
                        Button {
                            store.markDone(p.uuid, done: !p.isDone)
                            if !p.isDone { ParcelNotifications.cancel(p.uuid) }
                        } label: {
                            Label(p.isDone ? "恢复" : "已取",
                                  systemImage: p.isDone ? "arrow.uturn.backward" : "checkmark")
                        }
                        .tint(accent)
                    }
                    .contextMenu {
                        Button(p.isDone ? "恢复待取" : "标记已取") {
                            store.markDone(p.uuid, done: !p.isDone)
                        }
                        Button("删除包裹", role: .destructive) { deleteTarget = p }
                    }
                }
            }
            Color.clear.frame(height: 65)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(PH.page)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchExpanded.toggle()
                        if !searchExpanded {
                            search = ""
                            searchFocused = false
                        }
                    }
                    if searchExpanded { searchFocused = true }
                } label: {
                    Image(systemName: searchExpanded ? "xmark" : "magnifyingglass")
                }
                .accessibilityLabel(searchExpanded ? "收起搜索" : "搜索包裹")
                Button { importing = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("导入包裹")
                Menu {
                    Button("添加运单", systemImage: "plus") { finding = true }
                    Button("批量导入运单", systemImage: "list.bullet") { batchImport = true }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加包裹")
            }
        }
        .refreshable { _ = await ParcelManualSync.refreshAll() }
        .sheet(isPresented: $finding) {
            NavigationStack { NativeTrackSearchPage() }
        }
        .sheet(isPresented: $importing) {
            NavigationStack { PlatformsHome() }
        }
        .sheet(isPresented: $batchImport) {
            NavigationStack { BatchWaybillPage() }
        }
        .navigationDestination(item: $selectedParcel) { target in
            ParcelDetail(parcelID: target.uuid)
        }
        .alert("删除包裹？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                guard let target = deleteTarget else { return }
                store.delete(target.uuid)
                ParcelNotifications.cancel(target.uuid)
                deleteTarget = nil
            }
        } message: {
            Text("删除后将无法恢复。")
        }
    }
}
struct ParcelEditor: View {
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss
    @State var parcel: Parcel
    @State private var sms = ""
    var body: some View {
        Form {
            Section("包裹信息") {
                TextField("商品 / 备注标题", text: Binding(get: { parcel.userTitle ?? "" }, set: { parcel.userTitle = $0 }))
                TextField("取件码", text: $parcel.code)
                TextField("运单号", text: Binding(get: { parcel.mailNo ?? "" }, set: { parcel.mailNo = $0 })).textInputAutocapitalization(.characters)
                TextField("快递公司", text: Binding(get: { parcel.trackCompany ?? "" }, set: { parcel.trackCompany = $0 }))
                TextField("驿站名称", text: $parcel.courierStationName)
                TextField("地址", text: $parcel.address)
                TextField("手机号", text: $parcel.phone).keyboardType(.phonePad)
                TextField("备注", text: $parcel.notes, axis: .vertical)
            }
            Section("短信识别 · 本机解析") {
                TextField("粘贴短信", text: $sms, axis: .vertical).lineLimit(3...6)
                Button("识别短信") {
                    let parsed = SMSParser.parse(sms)
                    if !parsed.code.isEmpty { parcel.code = parsed.code }
                    if !parsed.trackingNumber.isEmpty { parcel.mailNo = parsed.trackingNumber }
                    if !parsed.station.isEmpty { parcel.courierStationName = parsed.station }
                    if !parsed.address.isEmpty { parcel.address = parsed.address }
                    if !parsed.company.isEmpty { parcel.trackCompany = parsed.company }
                    parcel.smsContent = sms
                    if !parsed.code.isEmpty { parcel.arrivedAt = Date().timeIntervalSince1970 * 1000 }
                }
                Button("从剪贴板粘贴") { sms = UIPasteboard.general.string ?? "" }
            }
            Section("状态") { Toggle("已取件", isOn: Binding(get: { parcel.isDone }, set: { parcel.status = $0 ? 2 : 1; parcel.pickedByUser = $0 })) }
        }
        .navigationTitle("编辑包裹")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") {
                store.upsert(parcel)
                if store.snapshot.preferences.reminderEnabled {
                    Task { await ParcelNotifications.schedule(parcel, afterHours: store.snapshot.preferences.reminderAfterHours) }
                }
                if store.snapshot.preferences.liveActivityEnabled { Task { await LiveActivityCoordinator.update(with: store.snapshot.parcels) } }
                dismiss()
            } }
        }
    }
}
// A geocoded destination pin, not a live parcel route.
private struct ParcelDestinationMap: View {
    let address: String
    @State private var position: MapCameraPosition = .automatic
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let coordinate {
                Map(position: $position) {
                    Marker("收货地", systemImage: "mappin.circle.fill", coordinate: coordinate)
                        .tint(.blue)
                }
                .mapControlVisibility(.hidden)
                .overlay(alignment: .bottomLeading) {
                    Label("收货地位置 · 非实时运输轨迹", systemImage: "location")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                }
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemGroupedBackground)
                    VStack(spacing: 9) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 29))
                            .foregroundStyle(.secondary)
                        Text(isLoading ? "正在定位收货地…" : "暂时无法定位收货地")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(address)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                }
            }
        }
        .task(id: address) {
            isLoading = true
            coordinate = nil
            defer { isLoading = false }
            guard let result = try? await CLGeocoder().geocodeAddressString(address),
                  let coordinate = result.first?.location?.coordinate else { return }
            self.coordinate = coordinate
            position = .region(MKCoordinateRegion(center: coordinate,
                              span: MKCoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)))
        }
    }
}

struct ParcelDetail: View {
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss
    let parcelID: String
    @State private var edit = false
    @State private var isRefreshing = false
    @State private var detailProvider: String?
    @State private var detailError: String?
    @State private var deleteConfirm = false
    @State private var toast: String?
    private var parcel: Parcel? { store.snapshot.parcels.first { $0.uuid == parcelID } }
    private var calendar: Calendar { Calendar.current }

    var body: some View {
        Group {
            if let p = parcel {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let destination = [p.receiverAddress, p.receiverCity]
                            .compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                            ParcelDestinationMap(address: destination)
                                .frame(height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        courierHeader(p)
                        if isRefreshing { ProgressView("正在依次查询物流接口…").padding(.vertical,8) }
                        if let detailProvider, !detailProvider.isEmpty {
                            Text("物流数据来源：" + detailProvider)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let detailError { Text(detailError).font(.caption).foregroundStyle(.orange) }
                        HStack(spacing: 7) {
                            Image(systemName: p.isDone || p.isSigned ? "checkmark.seal.fill" :
                                      p.isPending ? "checkmark.circle.fill" : "shippingbox.fill")
                                .foregroundStyle(p.isDone || p.isSigned ? PH.green :
                                                    p.isPending ? PH.orange : accent)
                            Text(p.isDone ? "已完成取件" :
                                 p.isSigned ? "物流显示已签收" :
                                 p.isPending ? "包裹已到站" : "运输中")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(PH.card, in: RoundedRectangle(cornerRadius: 18))
                        if p.isPending || !p.displayCode.isEmpty { infoCard(p) }
                        if let updated = p.trackUpdatedAt {
                            Text("最近查询：" + Date(timeIntervalSince1970: updated / 1000).formatted(date: .numeric, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let eta = p.eta, !eta.isEmpty {
                            HStack {
                                Image(systemName: "clock").foregroundStyle(accent)
                                Text("预计到达")
                                Spacer()
                                Text(eta).fontWeight(.semibold).foregroundStyle(accent)
                            }
                            .padding(17).background(PH.card, in: RoundedRectangle(cornerRadius: 20))
                        }
                        trackCard(p)
                        HStack(spacing: 9) {
                            detailAction(
                                label: p.isDone ? "恢复待取" : "标记已取",
                                icon: p.isDone ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill",
                                tint: accent
                            ) {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    store.markDone(p.uuid, done: !p.isDone)
                                }
                                if !p.isDone { ParcelNotifications.cancel(p.uuid) }
                                showToast(p.isDone ? "已恢复待取" : "已标记为已取")
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            detailAction(
                                label: "复制取件码",
                                icon: "doc.on.doc.fill",
                                tint: accent,
                                disabled: p.displayCode.isEmpty
                            ) {
                                UIPasteboard.general.string = p.displayCode
                                showToast("取件码已复制")
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            }
                            detailAction(
                                label: "删除包裹",
                                icon: "trash.fill",
                                tint: .red
                            ) {
                                deleteConfirm = true
                            }
                        }
                    }.padding(18).padding(.bottom, 24)
                }
                .background(PH.page)
                .overlay(alignment: .bottom) {
                    if let toast {
                        Label(toast, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(Color.primary.opacity(0.80), in: Capsule())
                            .padding(.bottom, 20)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .allowsHitTesting(false)
                    }
                }
                .navigationTitle("物流详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement:.topBarTrailing) {
                        Button { refreshDetail() } label:{Image(systemName:"arrow.clockwise")}
                            .disabled(isRefreshing || p.mailNo == nil)
                        Button("编辑") {edit=true}
                    }
                }
                .task(id:parcelID) {
                    guard let p=parcel, p.mailNo != nil,
                          p.trackNodes.isEmpty || p.trackUpdatedAt == nil else {return}
                    refreshDetail()
                }
                .sheet(isPresented: $edit) {
                    NavigationStack { ParcelEditor(parcel: p) }
                }
                .alert("删除包裹？", isPresented: $deleteConfirm) {
                    Button("取消", role: .cancel) { deleteConfirm = false }
                    Button("删除", role: .destructive) {
                        store.delete(p.uuid)
                        ParcelNotifications.cancel(p.uuid)
                        dismiss()
                    }
                } message: {
                    Text("删除后将无法恢复。")
                }
            } else {
                ContentUnavailableView("包裹不存在", systemImage: "shippingbox")
            }
        }
    }


    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.18)) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_650_000_000)
            if toast == message {
                withAnimation(.easeIn(duration: 0.18)) { toast = nil }
            }
        }
    }

    private func detailAction(
        label: String, icon: String, tint: Color, disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 61)
            .background(tint.opacity(disabled ? 0.05 : 0.10),
                        in: RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func refreshDetail() {
        guard !isRefreshing, let p=parcel, let mail=p.mailNo, !mail.isEmpty else {return}
        isRefreshing=true
        detailError=nil
        detailProvider=nil
        Task {
            defer {isRefreshing=false}
            do {
                let latest=try await NativeTracking.lookup(mail,source:p.source ?? p.srcApp?.id,
                    shipperCode:p.shipperCode ?? "",phone:NativeTracking.phone(for: mail),
                    accountIDs:p.linkedAccounts ?? [])
                guard var current=store.snapshot.parcels.first(where:{$0.uuid == parcelID}) else {return}
                TrackMerge.apply(to: &current, nodes: latest.nodes, summary: latest.latest)
                if !latest.company.isEmpty {current.trackCompany=latest.company}
                if !latest.shipperCode.isEmpty {current.shipperCode=latest.shipperCode}
                current.trackUpdatedAt=Date().timeIntervalSince1970*1000
                store.upsert(current)
                detailProvider = latest.provider
            } catch {
                detailError=error.localizedDescription
            }
        }
    }

    private func courierHeader(_ p: Parcel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                CourierBrandView(company:p.trackCompany ?? "",
                    shipperCode:p.shipperCode ?? "",
                    source:p.srcApp?.id == "douyin" ? "douyin" :
                         (p.source ?? p.srcApp?.id),size:57)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.trackCompany ?? p.title)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(2)
                    Text(p.displayStatus)
                        .font(.subheadline)
                        .foregroundStyle(p.isDone || p.isSigned ? PH.green : p.isPending ? PH.orange : accent)
                }
                Spacer(minLength: 0)
            }
            if let mail = p.mailNo, !mail.isEmpty {
                HStack(spacing: 8) {
                    Text(mail).font(.system(.subheadline, design: .rounded))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = mail
                        showToast("运单号已复制")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .labelStyle(.titleOnly)
                    }.font(.subheadline).foregroundStyle(accent)
                }
            }
            if let title = p.itemTitle, !title.isEmpty {
                Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
        }.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PH.card, in: RoundedRectangle(cornerRadius: 22))
    }
    private func infoCard(_ p: Parcel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("取件信息", systemImage: "shippingbox")
                .font(.headline)
            if p.isPending || !p.displayCode.isEmpty {
                HStack {
                    Text("取件码").foregroundStyle(.secondary)
                    Spacer()
                    Text(p.displayCode.isEmpty ? "暂无取件码" : p.displayCode)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                }
            }
            HStack(alignment: .top) {
                Text("驿站").foregroundStyle(.secondary)
                Spacer()
                Text(store.snapshot.stations.first(where: { $0.id == p.courierStationUuid })?
                     .courierStationName ?? p.stationText)
                    .multilineTextAlignment(.trailing)
            }
            if let city = p.receiverCity, !city.isEmpty {
                HStack {
                    Text("收货地").foregroundStyle(.secondary)
                    Spacer()
                    Text(city)
                }
            }
        }
        .font(.subheadline)
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 22))
    }
    private func routeCard(_ p: Parcel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("物流路线", systemImage: "map").font(.headline)
            if let origin = p.address.isEmpty ? nil : p.address,
               let destination = p.receiverCity ?? p.receiverAddress, !destination.isEmpty {
                HStack(spacing: 8) {
                    Text(origin).lineLimit(2)
                    Image(systemName: "arrow.right").foregroundStyle(accent)
                    Text(destination).lineLimit(2)
                }.font(.subheadline)
            } else {
                Text("暂未获取可用的运输地点")
                    .foregroundStyle(.secondary).font(.subheadline)
            }
            if let latest = p.trackLatest, !latest.isEmpty {
                Text(latest).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(PH.card, in: RoundedRectangle(cornerRadius: 22))
    }
    private func trackCard(_ p: Parcel) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("物流轨迹", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.headline)
            if p.trackNodes.isEmpty {
                Text(p.trackLatest ?? "暂无物流轨迹")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(p.trackNodes.enumerated()), id: \.offset) { index, node in
                        HStack(alignment: .top, spacing: 13) {
                            Circle()
                                .fill(index == 0 ? accent : Color.secondary.opacity(0.6))
                                .frame(width: 10, height: 10)
                                .frame(width: 14, height: 14)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(node.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !node.time.isEmpty {
                                    Text(node.time)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.bottom, index == p.trackNodes.count - 1 ? 0 : 21)
                        .background(alignment: .topLeading) {
                            if index < p.trackNodes.count - 1 {
                                GeometryReader { geometry in
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.24))
                                        .frame(width: 2, height: geometry.size.height)
                                        .offset(x: 6, y: 11)
                                }
                            }
                        }
                    }
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(PH.card, in: RoundedRectangle(cornerRadius: 22))
    }
}
struct StatsHome: View {
    @EnvironmentObject private var store: ParcelStore

    private var parcels: [Parcel] { store.snapshot.parcels.filter { $0.type == "delivery" } }
    private var picked: [Parcel] { parcels.filter(\.isDone) }
    private var signed: [Parcel] { parcels.filter(\.isSigned) }
    private var pending: Int { parcels.filter(\.isPending).count }
    private var inTransit: Int { parcels.filter(\.isTransit).count }
    private var monthCount: Int {
        picked.filter {
            guard let timestamp = $0.pickedAt else { return false }
            return Calendar.current.isDate(
                Date(timeIntervalSince1970: timestamp / 1000),
                equalTo: Date(), toGranularity: .month)
        }.count
    }
    private var ranking: [(String, Int)] {
        Dictionary(grouping: picked) { p in
            store.snapshot.stations.first(where: { $0.id == p.courierStationUuid })?
                .courierStationName ?? p.stationText
        }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(3).map { $0 }
    }
    private var months: [(String, Int)] {
        let cal = Calendar.current
        return (0..<5).reversed().compactMap { offset -> (String, Int)? in
            guard let d = cal.date(byAdding: .month, value: -offset, to: Date()) else { return nil }
            let count = picked.filter {
                guard let timestamp = $0.pickedAt else { return false }
                return cal.isDate(Date(timeIntervalSince1970: timestamp / 1000), equalTo: d, toGranularity: .month)
            }.count
            return ("\(cal.component(.month, from: d))月", count)
        }
    }
    // Estimate the average *clock time of arrival*, not elapsed delivery duration.
    // Only timestamped last-mile arrival events count. "codeTime" is pickup
    // code metadata and is not a trustworthy logistics arrival timestamp.
    private var arrivalSamples: [Int] {
        parcels.compactMap { parcel -> Int? in
            let matching = parcel.trackNodes.filter { node in
                let text = node.text
                let arrivals = ["已到达", "已到站", "已入库", "入库成功", "已入柜",
                                "已放入", "已存放", "已暂存", "代收点", "驿站签收",
                                "派送至", "已投递", "送达驿站", "已代收", "已送达"]
                let exclusions = ["预计", "即将", "将于", "转运中心", "分拨中心",
                                  "集散中心", "运转中心", "揽收", "已取走", "已领取",
                                  "本人签收", "运输中", "派送中", "正在派送"]
                return arrivals.contains(where: { text.contains($0) }) &&
                       !exclusions.contains(where: { text.contains($0) })
            }
            // Most carriers return newest -> oldest; retain the earliest
            // matching arrival for each parcel, never double-count its updates.
            return TrackMerge.ordered(matching).reversed().compactMap { clockMinute(from: $0.time) }.first
        }
    }
    private func clockMinute(from raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Some logistics backends return Unix timestamps rather than text.
        if let epoch = Double(text), epoch > 1_000_000_000 {
            let seconds = epoch > 1_000_000_000_000 ? epoch / 1000 : epoch
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let parts = calendar.dateComponents([.hour, .minute],
                from: Date(timeIntervalSince1970: seconds))
            if let hour = parts.hour, let minute = parts.minute {
                return hour * 60 + minute
            }
        }
        // Accept 2026-11-16 17:41:53, 2026/11/16 17:41 or ISO 8601
        // but never dates without a time of day.
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?(?!\d)"#),
              let match = expression.firstMatch(in: text, range:
                NSRange(text.startIndex..., in: text)),
              let hoursRange = Range(match.range(at: 1), in: text),
              let minutesRange = Range(match.range(at: 2), in: text),
              let hour = Int(text[hoursRange]), let minute = Int(text[minutesRange])
        else { return nil }
        return hour * 60 + minute
    }
    private var averageArrivalMinute: Int? {
        let values = arrivalSamples
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text("统计")
                        .font(.system(size: 32, weight: .bold))
                    Spacer()
                    Text("取件报告")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 9),
                    GridItem(.flexible(), spacing: 9)
                ], spacing: 9) {
                    metricTile("全部包裹", value: "\(parcels.count)",
                               symbol: "shippingbox.fill", color: accent)
                    metricTile("已签收", value: "\(signed.count)",
                               symbol: "checkmark.seal.fill", color: PH.green)
                    metricTile("待取件", value: "\(pending)",
                               symbol: "tray.and.arrow.down.fill", color: PH.orange)
                    metricTile("运输中", value: "\(inTransit)",
                               symbol: "truck.box.fill", color: accent)
                    metricTile("累计已取", value: "\(picked.count)",
                               symbol: "checkmark.circle.fill", color: PH.green)
                    metricTile("本月已取", value: "\(monthCount)",
                               symbol: "calendar", color: PH.orange)
                }

                Text("“已签收”来自物流状态，与本人已取件分开统计；取件趋势仅统计已取件包裹。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)

                DashboardSection("取件趋势", subtitle: "最近 5 个月")
                trendPanel

                DashboardSection("常用驿站", subtitle: "按已取件数量")
                rankingPanel

                DashboardSection("平均到站时间", subtitle: "基于真实物流轨迹")
                arrivalPanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 118)
        }
        .background(PH.page)
    }

    private func metricTile(
        _ title: String, value: String, symbol: String, color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var trendPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每月完成件数")
                        .font(.system(size: 14, weight: .semibold))
                    Text("按标记已取时间统计")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("\(months.reduce(0) { $0 + $1.1 }) 件")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }
            let ceiling = max(1, months.map { $0.1 }.max() ?? 0)
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(months.enumerated()), id: \.offset) { _, month in
                    VStack(spacing: 6) {
                        Text("\(month.1)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(height: 16)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LinearGradient(
                                colors: month.1 == 0 ?
                                    [accent.opacity(0.13), accent.opacity(0.13)] :
                                    [accent, accent.opacity(0.55)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(height: CGFloat(max(8, month.1 * 80 / ceiling)))
                            .frame(height: 84, alignment: .bottom)
                        Text(month.0)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(height: 17)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 129, alignment: .bottom)
        }
        .padding(18)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private var rankingPanel: some View {
        VStack(spacing: 12) {
            if ranking.isEmpty {
                DashboardEmpty(
                    title: "还没有驿站排行",
                    subtitle: "实际取件后才会计入排行；物流签收不等于本人已取",
                    symbol: "mappin.and.ellipse"
                )
            } else {
                ForEach(Array(ranking.enumerated()), id: \.offset) { rank, item in
                    HStack(spacing: 12) {
                        Text("\(rank + 1)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(rank == 0 ? accent : .secondary)
                            .frame(width: 32, height: 32)
                            .background(accent.opacity(rank == 0 ? 0.13 : 0.06),
                                        in: RoundedRectangle(cornerRadius: 10))
                        Text(item.0)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(item.1) 件")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    if rank != ranking.count - 1 { Divider().opacity(0.5) }
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private var arrivalPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let minutes = averageArrivalMinute {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%02d:%02d", minutes / 60, minutes % 60))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Text("\(arrivalSamples.count) 件有效记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(accent)
                                .frame(width: geo.size.width * CGFloat(
                                    max(0, min(14 * 60, minutes - 8 * 60))) /
                                       CGFloat(14 * 60))
                        }
                }
                .frame(height: 8)
                HStack {
                    Text("08:00")
                    Spacer()
                    Text("15:00")
                    Spacer()
                    Text("22:00")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                Text("取物流记录中首次有效的到站时间计算平均值，不使用取件码生成时间。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 25))
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("暂无有效到站时间")
                            .font(.system(size: 15, weight: .semibold))
                        Text("需要真实物流轨迹中的到站或入库时间才能计算。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PH.card, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct SettingsHome: View {
    @EnvironmentObject private var store: ParcelStore
    @StateObject private var update = ParcelUpdateCenter.shared
    private var nickname: String {
        let value = store.snapshot.preferences.nickName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "包裹助手" : value
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BigHeading(text: "设置")
                NavigationLink { ProfileSettingsPage() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: UserDefaults.standard.string(forKey: "native.profile.avatar") ?? "person.crop.circle.fill")
                            .font(.system(size: 52)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(nickname).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                            Text("尚未授权平台 · 本地数据").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(16)
                        .background(PH.card, in: RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain)
                settingsGroup {
                    nativeRow("账号授权", "checkmark.shield.fill", PH.orange) { PlatformAccountsPage() }
                }
                settingsGroup {
                    nativeRow("快捷指令与自动化", "bolt.fill", PH.orange) { ShortcutsSettingsPage() }
                    Divider().padding(.leading, 58)
                    nativeRow("驿站管理", "building.2.fill", .cyan) { StationsHome() }
                    Divider().padding(.leading, 58)
                    nativeRow("身份码", "qrcode", .blue) { IdentitySettingsPage() }
                    Divider().padding(.leading, 58)
                    nativeRow("取件提醒", "bell.fill", .blue) { ReminderSettingsPage() }
                }
                settingsGroup {
                    nativeRow("外观与显示", "circle.lefthalf.filled", .purple) { AppearanceSettingsPage() }
                    Divider().padding(.leading, 58)
                    nativeRow("实时活动（灵动岛）", "iphone.gen3", .blue) { LiveSettingsPage() }
                    Divider().padding(.leading, 58)
                    nativeRow("小组件", "square.grid.2x2.fill", .blue) { HomeWidgetSettingsPage() }
                    Divider().padding(.leading, 58)
                    nativeRow("刷新频率", "arrow.triangle.2.circlepath", .red) { RefreshSettingsPage() }
                }
                settingsGroup {
                    nativeRow("常见问题", "questionmark.circle.fill", .blue) { FAQSettingsPage() }
                    Divider().padding(.leading, 58)
                    nativeRow("运行日志", "list.bullet.rectangle.portrait.fill", .blue) { ParcelRunLogPage() }
                    Divider().padding(.leading, 58)
                    nativeRow("数据备份", "externaldrive.fill", .blue) { LocalBackupPage() }
                    Divider().padding(.leading, 58)
                    nativeRow("清除缓存", "trash.fill", .gray) { CacheSettingsPage() }
                }
                settingsGroup {
                    NavigationLink {
                        ParcelUpdatePage()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.green, in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("软件更新")
                                    .font(.system(size: 15)).foregroundStyle(.primary)
                                Text("当前版本 \(ParcelUpdateVersions.installed)")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if let release = update.available {
                                Text("可更新 \(release.version)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.blue)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 57)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("版本 \(ParcelUpdateVersions.installed)")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.top, 27)
            }.padding(.horizontal, 20).padding(.bottom, 130)
        }
        .background(PH.page)

    }
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(PH.card, in: RoundedRectangle(cornerRadius: 22))
            .padding(.top, 26)
    }
    private func settingsLabel(_ title: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 9))
            Text(title).font(.system(size: 15)).foregroundStyle(.primary)
            Spacer(minLength: 5)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).frame(minHeight: 49)
            .contentShape(Rectangle())
    }
    private func nativeRow<Destination: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) { settingsLabel(title, icon, color) }.buttonStyle(.plain)
    }
}
// Inline station directory inspired by the Scripting app. Keep the existing
// Station model and ParcelStore persistence; no data migration is required.
struct StationsHome: View {
    @EnvironmentObject private var store: ParcelStore
    @State private var searchText = ""
    @State private var expandedID: String?
    @State private var adding = false
    @State private var newStation = Station()
    @State private var deleting: Station?

    private var stations: [Station] {
        store.snapshot.stations.sorted {
            $0.courierStationName.localizedStandardCompare($1.courierStationName) == .orderedAscending
        }
    }
    private var filtered: [Station] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return stations }
        return stations.filter {
            [$0.courierStationName, $0.address, $0.phone,
             $0.businessHours, $0.notes].contains {
                $0.localizedCaseInsensitiveContains(query)
            } || $0.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("已添加").foregroundStyle(.secondary).font(.subheadline)
                    Spacer()
                    Text("\(stations.count) 个驿站")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)

                if stations.isEmpty && !adding {
                    ContentUnavailableView(
                        "还没有驿站", systemImage: "building.2",
                        description: Text("识别到明确的取件站点会自动建档，也可以点击右上角添加。")
                    )
                    .frame(maxWidth: .infinity)
                } else if filtered.isEmpty && !adding {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    VStack(spacing: 0) {
                        if adding {
                            StationInlineCard(
                                station: newStation, expanded: true, isNew: true,
                                onToggle: { adding = false },
                                onSaved: {
                                    adding = false
                                    expandedID = nil
                                    newStation = Station()
                                },
                                onDelete: { adding = false })
                                .id(newStation.id)
                            if !filtered.isEmpty { Divider().padding(.leading, 72) }
                        }
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, station in
                            StationInlineCard(
                                station: station, expanded: expandedID == station.id,
                                onToggle: {
                                    if expandedID == station.id { expandedID = nil }
                                    else {
                                        adding = false
                                        expandedID = station.id
                                    }
                                },
                                onSaved: { expandedID = nil },
                                onDelete: { deleting = station })
                            if index < filtered.count - 1 {
                                Divider().padding(.leading, 72).padding(.trailing, 18)
                            }
                        }
                    }
                    .background(PH.card, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
                }

                if !stations.isEmpty || adding {
                    Text("点击驿站展开编辑。关键词会匹配包裹短信和取件点名称；多个关键词可用逗号分隔。保存后仍保留已有包裹，不会覆盖手动修改。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 115)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PH.page)
        .navigationTitle("驿站管理")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "搜索驿站、地址或电话")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newStation = Station()
                    expandedID = nil
                    adding = true
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加驿站")
            }
        }
        .alert("删除驿站？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("删除驿站", role: .destructive) {
                if let station = deleting { store.removeStation(station.id) }
                deleting = nil
                expandedID = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("只删除驿站档案，不会删除已有包裹。")
        }
    }
}

private struct StationInlineCard: View {
    @EnvironmentObject private var store: ParcelStore
    let station: Station
    let expanded: Bool
    var isNew = false
    let onToggle: () -> Void
    let onSaved: () -> Void
    let onDelete: () -> Void

    @State private var draft: Station
    @State private var keywordText: String
    @State private var problem = ""

    init(station: Station, expanded: Bool, isNew: Bool = false,
         onToggle: @escaping () -> Void,
         onSaved: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.station = station
        self.expanded = expanded
        self.isNew = isNew
        self.onToggle = onToggle
        self.onSaved = onSaved
        self.onDelete = onDelete
        _draft = State(initialValue: station)
        _keywordText = State(initialValue: station.keywords.joined(separator: "，"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(accent)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isNew ? "新增驿站" : station.courierStationName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(isNew ? "填写名称与匹配关键词" :
                             (station.keywords.first ?? (station.address.isEmpty
                                ? "未设置关键词" : station.address)))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    field("名称", text: $draft.courierStationName, placeholder: "驿站名称")
                    field("关键词", text: $keywordText, placeholder: "用于自动匹配")
                    HStack {
                        Text("将匹配：")
                        Text(keywordText.isEmpty ? "未设置" : keywordText)
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)

                    field("地址", text: $draft.address, placeholder: "选填")
                    field("手机号", text: $draft.phone, placeholder: "选填", phone: true)
                    field("营业时间", text: $draft.businessHours, placeholder: "例如 08:00 - 22:00")
                    field("备注", text: $draft.notes, placeholder: "选填", last: true)

                    if !problem.isEmpty {
                        Text(problem).foregroundStyle(.red).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    HStack(spacing: 0) {
                        Button(isNew ? "取消" : "删除", role: isNew ? .cancel : .destructive) {
                            onDelete()
                        }
                        .frame(maxWidth: .infinity)
                        Divider().frame(height: 23)
                        Button("保存", action: save)
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .padding(.top, 17).padding(.bottom, 6)
                }
                .padding(.leading, 20).padding(.trailing, 18).padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .onChange(of: expanded) { _, value in
            if value {
                draft = station
                keywordText = station.keywords.joined(separator: "，")
                problem = ""
            }
        }
    }

    private func field(_ label: String, text: Binding<String>,
                       placeholder: String, phone: Bool = false,
                       last: Bool = false) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 10) {
                Text(label).foregroundStyle(.primary).frame(width: 86, alignment: .leading)
                if phone {
                    TextField(placeholder, text: text).keyboardType(.phonePad)
                        .multilineTextAlignment(.trailing)
                } else {
                    TextField(placeholder, text: text)
                        .multilineTextAlignment(.trailing)
                }
            }
            .font(.system(size: 15))
            .padding(.vertical, 14)
        }
    }

    private func save() {
        let name = draft.courierStationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { problem = "请填写驿站名称"; return }
        let phone = draft.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = phone.filter(\.isNumber)
        if !phone.isEmpty && (digits.count < 7 || digits.count > 15 ||
            phone.range(of: #"^[+0-9() -]+$"#, options: .regularExpression) == nil) {
            problem = "请输入有效的联系电话"; return
        }
        let keys = keywordText.components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if keys.contains(where: { $0.count > 50 }) {
            problem = "单个匹配关键词不能超过 50 字"; return
        }
        let address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = store.snapshot.stations.contains {
            $0.id != draft.id &&
            $0.courierStationName.localizedCaseInsensitiveCompare(name) == .orderedSame &&
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(address) == .orderedSame
        }
        guard !duplicate else { problem = "相同名称与地址的驿站已存在"; return }
        draft.courierStationName = name
        draft.address = address
        draft.phone = phone
        draft.keywords = Array(Set(keys)).sorted()
        store.upsertStation(draft)
        onSaved()
    }
}
struct StationEditor: View {
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss
    @State var station: Station
    @State private var keywordText = ""
    @State private var errorMessage = ""
    private var name: String { station.courierStationName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var address: String { station.address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var phone: String { station.phone.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        Form {
            Section("驿站信息") {
                TextField("驿站名称（必填）", text: $station.courierStationName)
                    .textInputAutocapitalization(.never)
                TextField("详细地址（可补全）", text: $station.address)
                TextField("联系电话", text: $station.phone)
                    .keyboardType(.phonePad)
                TextField("营业时间", text: $station.businessHours)
            }
            Section("匹配规则") {
                Text("自动识别的驿站可能没有完整地址。请核对名称与位置；修改后不会被物流同步覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("关键词（逗号分隔）", text: $keywordText)
                TextField("备注", text: $station.notes)
            }
        }
        .navigationTitle("编辑驿站")
        .onAppear { keywordText = station.keywords.joined(separator: ",") }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(name.isEmpty)
            }
        }
        .alert("无法保存驿站", isPresented: Binding(get: { !errorMessage.isEmpty }, set: { if !$0 { errorMessage = "" } })) {
            Button("确定", role: .cancel) { errorMessage = "" }
        } message: { Text(errorMessage) }
    }
    private func save() {
        guard !name.isEmpty else { errorMessage = "请填写驿站名称"; return }
        let digits = phone.filter(\.isNumber)
        if !phone.isEmpty && (digits.count < 7 || digits.count > 15 || phone.range(of: "^[+0-9()\\- ]+$", options: .regularExpression) == nil) {
            errorMessage = "请输入有效的联系电话"; return
        }
        let keys = keywordText.components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keys.contains(where: { $0.count > 50 }) else { errorMessage = "单个匹配关键词不能超过 50 字"; return }
        let duplicate = store.snapshot.stations.contains {
            $0.id != station.id && $0.courierStationName.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(name) == .orderedSame && $0.address.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(address) == .orderedSame
        }
        guard !duplicate else { errorMessage = "相同名称和地址的驿站已存在"; return }
        station.courierStationName = name
        station.address = address
        station.phone = phone
        station.keywords = Array(Set(keys)).sorted()
        store.upsertStation(station)
        dismiss()
    }
}
struct PlatformsHome: View {
    private let platforms: [(String, String, String)] = [
        ("淘宝", "taobao", "bag"),
        ("京东", "jd", "shippingbox"),
        ("拼多多", "pdd", "cart"),
        ("抖音商城", "douyin", "play.rectangle"),
        ("菜鸟", "cainiao", "shippingbox.fill"),
        ("丰巢", "fengchao", "square.grid.2x2"),
        ("小米", "xiaomi", "cube.box")
    ]
    var body: some View {
        List {
            Section {
                Label("抖音提供打开官网、返回自动识别剪贴板的快速导入；其他平台可手动粘贴物流文字。自动读取完整订单需要对应平台开放授权。", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("物流导入") {
                ForEach(platforms, id: \.1) { item in
                    NavigationLink {
                        if item.1 == "douyin" {
                            DouyinImportView()
                        } else {
                            PlatformImportView(platformName: item.0, platformID: item.1)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.2).frame(width: 28).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.0)
                                Text("粘贴物流详情 · 识别运单/取件码")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("授权状态") {
                Label("普通网页版登录不等于订单 API 授权", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("不会请求账号密码，也不会把账号 Cookie 上传到第三方服务器。官方接口获得授权后，才能增加自动订单同步。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("平台导入")
    }
}
struct CourierSettings: View {
    @State private var confirmClearCredentials = false
    @State private var businessID = NativeTracking.get("businessID")
    @State private var key = NativeTracking.get("apiKey")
    @State private var configured = NativeTracking.isConfigured
    @State private var loggedIn = NativeTracking.hasOfficialLogin
    @State private var officialLogin = false
    @State private var notice: String?

    var body: some View {
        Form {
            Section("快递鸟") {
                LabeledContent("状态", value: NativeTracking.accountStatus)
                Button("官方账号授权") { officialLogin = true }
                Text("授权后可尝试自动读取 API 密钥。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("API 密钥") {
                TextField("EBusinessID", text: $businessID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $key)
                Button("保存配置") {
                    do {
                        try NativeTracking.setCredential(
                            businessID: businessID, apiKey: key)
                        configured = true
                        loggedIn = NativeTracking.hasOfficialLogin
                        notice = "配置已保存"
                    } catch { notice = error.localizedDescription }
                }
                Button("清除配置", role: .destructive) {
                    confirmClearCredentials = true
                }
                .disabled(!configured)
                .alert("确认清除快递鸟配置？", isPresented: $confirmClearCredentials) {
                    Button("取消", role: .cancel) {}
                    Button("清除配置", role: .destructive) {
                        NativeTracking.clearCredential()
                        businessID = ""
                        key = ""
                        configured = false
                        loggedIn = false
                        notice = "已清除配置"
                    }
                } message: {
                    Text("将清除本机保存的快递鸟 API 授权信息，之后需重新配置才能使用备用查询。")
                }
            }
        }
        .navigationTitle("快递鸟")
        .onAppear {
            businessID = NativeTracking.get("businessID")
            key = NativeTracking.get("apiKey")
            configured = NativeTracking.isConfigured
            loggedIn = NativeTracking.hasOfficialLogin
        }
        .sheet(isPresented: $officialLogin) {
            NavigationStack {
                KdniaoOfficialLoginPage {
                    businessID = NativeTracking.get("businessID")
                    key = NativeTracking.get("apiKey")
                    configured = NativeTracking.isConfigured
                    loggedIn = NativeTracking.hasOfficialLogin
                    officialLogin = false
                    notice = "快递鸟授权成功"
                }
            }
        }
        .alert("快递鸟", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("确定") { notice = nil }
        } message: { Text(notice ?? "") }
    }
}

struct Kuaidi100Settings: View {
    @State private var confirmClearCredentials = false
    @State private var customer = NativeTracking.get("kuaidi100Customer")
    @State private var key = NativeTracking.get("kuaidi100Key")
    @State private var configured = NativeTracking.isKuaidi100Configured
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Kuaidi100BrandMark(size: 47)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("快递100").font(.headline)
                        Text("独立的备用物流查询服务")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }
            Section("快递100 API") {
                LabeledContent("状态", value: configured ? "已配置" : "未配置")
                TextField("Customer 授权码", text: $customer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Key", text: $key)
                Button("保存配置") {
                    do {
                        try NativeTracking.setKuaidi100(customer: customer, key: key)
                        configured = true
                        notice = "配置已保存"
                    } catch { notice = error.localizedDescription }
                }
                Button("清除配置", role: .destructive) {
                    confirmClearCredentials = true
                }
                .disabled(!configured)
                .alert("确认清除快递100配置？", isPresented: $confirmClearCredentials) {
                    Button("取消", role: .cancel) {}
                    Button("清除配置", role: .destructive) {
                        NativeTracking.clearKuaidi100()
                        customer = ""
                        key = ""
                        configured = false
                        notice = "已清除配置"
                    }
                } message: {
                    Text("将清除本机保存的快递100 Customer 和 Key，之后需重新配置。")
                }
            }
            Section {
                Text("需要自行申请 API 密钥；查询可能产生费用，同一单号有查询间隔限制。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("快递100")
        .onAppear {
            customer = NativeTracking.get("kuaidi100Customer")
            key = NativeTracking.get("kuaidi100Key")
            configured = NativeTracking.isKuaidi100Configured
        }
        .alert("快递100", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("确定") { notice = nil }
        } message: { Text(notice ?? "") }
    }
}

private struct KdniaoOfficialLoginPage: View {
    @Environment(\.dismiss) private var dismiss
    let onConfigured: () -> Void
    @State private var exchanging = false
    @State private var status = "请在官方网页登录或注册，完成验证后将自动读取 API 密钥"

    var body: some View {
        VStack(spacing: 0) {
            KdniaoOfficialLoginWeb { token, maskedPhone in
                guard !exchanging else { return }
                exchanging = true
                status = "网页登录成功，正在读取账号 API 密钥…"
                Task { @MainActor in
                    do {
                        try await NativeTracking.configureFromOfficialLogin(token: token)
                        NativeTracking.rememberOfficialLogin(maskedPhone: maskedPhone)
                        onConfigured()
                    } catch {
                        status = error.localizedDescription
                        exchanging = false
                    }
                }
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .navigationTitle("登录快递鸟")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回") { dismiss() }
            }
        }
    }
}

private struct KdniaoOfficialLoginWeb: UIViewRepresentable {
    let onToken: (String, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Fresh session prevents an old login token from immediately
        // short-circuiting the manual verification step.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "kdniaoAuth")
        let javascript = #"""
        (function() {
          function poll() {
            try {
              if (!/(^|\.)kdniao\.com$/i.test(location.hostname)) return;
              var token = (localStorage.getItem('token') || '').trim();
              if (!token) {
                var raw = localStorage.getItem('app-sso');
                if (raw) {
                  var data = JSON.parse(raw);
                  token = String((data.state && data.state.accessToken) ||
                                  data.accessToken || '').trim();
                }
              }
              if (token.length < 12) return;
              // Only read explicit account phone fields on the official site;
              // the native app receives a masked value, never the raw number.
              function maskPhone(value) {
                var p = String(value || '').replace(/[\s-]/g,'').replace(/^\+?86/,'');
                if (/^1[3-9]\d{9}$/.test(p)) return p.slice(0,3)+'****'+p.slice(-4);
                if (/^1[3-9]\d\*{4}\d{4}$/.test(p)) return p;
                return '';
              }
              function findPhone(obj,depth) {
                if (!obj || typeof obj !== 'object' || depth > 4) return '';
                var fields = ['mobile','mobilePhone','phone','phoneNumber',
                              'userMobile','userPhone','loginPhone'];
                for(var j=0;j<fields.length;j++) {
                  var found = maskPhone(obj[fields[j]]);
                  if(found) return found;
                }
                var nested = ['state','userInfo','user','profile','account','memberInfo'];
                for(var k=0;k<nested.length;k++) {
                  var inside = findPhone(obj[nested[k]],depth+1);
                  if(inside) return inside;
                }
                return '';
              }
              var phone = '', keys = ['app-sso','userInfo','user-info','accountInfo'];
              for(var i=0;i<keys.length && !phone;i++) {
                try {
                  var raw = localStorage.getItem(keys[i]);
                  if(raw) phone = findPhone(JSON.parse(raw),0);
                } catch(e) {}
              }
              if(!phone) {
                window.__parcelKdnSeenAt = window.__parcelKdnSeenAt || Date.now();
                if(Date.now() - window.__parcelKdnSeenAt < 1500) return;
              }
              if(window.__parcelKdnSent === token) return;
              window.__parcelKdnSent = token;
              window.webkit.messageHandlers.kdniaoAuth.postMessage({
                token:token, maskedPhone:phone
              });
            } catch (e) {}
          }
          poll();
          setInterval(poll, 1100);
        })();
        """#
        config.userContentController.addUserScript(
            WKUserScript(source: javascript, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: URL(string: "https://m.kdniao.com/#/register")!))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onToken = onToken
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "kdniaoAuth")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var onToken: (String, String?) -> Void

        init(onToken: @escaping (String, String?) -> Void) { self.onToken = onToken }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            let host = message.frameInfo.securityOrigin.host.lowercased()
            guard (host == "kdniao.com" || host.hasSuffix(".kdniao.com")),
                  let result = message.body as? [String: Any],
                  let token = result["token"] as? String,
                  token.count >= 12, token.count < 4096 else { return }
            let masked = result["maskedPhone"] as? String
            let valid = masked?.range(of: #"^1[3-9][0-9]\*{4}[0-9]{4}$"#,
                                      options: .regularExpression) != nil
            onToken(token, valid ? masked : nil)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased()
            decisionHandler(
                scheme == "https" || scheme == "http" || scheme == "about"
                ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard action.targetFrame == nil,
                  let scheme = action.request.url?.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return nil }
            webView.load(action.request)
            return nil
        }
    }
}


// Independent presentation modules: keep batch changes explicit and reversible
// through the existing parcel editor.
private struct BatchPickupPage: View {
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var confirm = false
    private var pending: [Parcel] { store.snapshot.parcels.filter { $0.type == "delivery" && $0.isPending } }
    var body: some View {
        List {
            Button("全选 / 取消全选") {
                let all = Set(pending.map(\.uuid))
                selected = selected == all ? [] : all
            }
            ForEach(pending) { parcel in
                Button {
                    if selected.contains(parcel.uuid) { selected.remove(parcel.uuid) }
                    else { selected.insert(parcel.uuid) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(parcel.uuid) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(parcel.displayCode.isEmpty ? parcel.title : parcel.displayCode)
                            Text(parcel.stationText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }.buttonStyle(.plain)
            }
        }
        .navigationTitle("批量取件")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("已取 \(selected.count) 件") { confirm = true }.disabled(selected.isEmpty)
            }
        }
        .alert("确认标记已取？", isPresented: $confirm) {
            Button("取消", role: .cancel) {}
            Button("确认") {
                store.markPickedBatch(selected)
                for id in selected { ParcelNotifications.cancel(id) }
                dismiss()
            }
        } message: { Text("仅修改本地取件状态，不会向驿站发送取件指令。") }
    }
}

private struct BatchWaybillPage: View {
    @EnvironmentObject private var store: ParcelStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var result: Int?
    private var candidates: [String] {
        input.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；")))
            .map { $0.uppercased() }
            .filter { $0.range(of: #"^[A-Z0-9-]{8,40}$"#, options: .regularExpression) != nil && $0.contains(where: \.isNumber) }
    }
    var body: some View {
        Form {
            Section("运单号") {
                TextEditor(text: $input).frame(minHeight: 160).textInputAutocapitalization(.characters)
                Text("每行一个运单号，也可用空格或逗号分隔。请核对纯数字单号。").font(.footnote)
            }
            Section {
                LabeledContent("有效候选", value: "\(Set(candidates).count) 件")
                Button("确认导入") { result = store.importWaybills(candidates) }.disabled(candidates.isEmpty)
            }
        }
        .navigationTitle("批量导入")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .alert("导入完成", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("确定") { dismiss() }
        } message: { Text("新增 \(result ?? 0) 件，重复运单已跳过。") }
    }
}

private struct LocalBackupPage: View {
    @EnvironmentObject private var store: ParcelStore
    @State private var confirm = false
    @State private var notice: String?
    var body: some View {
        Form {
            Section("本地恢复") {
                LabeledContent("最近有效备份", value: store.recoveryBackupDate?.formatted(date: .numeric, time: .shortened) ?? "暂无")
                Button("恢复上一份备份", role: .destructive) { confirm = true }
                    .disabled(store.recoveryBackupDate == nil)
            } footer: { Text("恢复会替换当前包裹、驿站和本地偏好，不会恢复平台登录凭据。") }
        }
        .navigationTitle("数据备份")
        .alert("确认恢复？", isPresented: $confirm) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                do { try store.restoreRecoveryBackup(); notice = "已恢复本地备份" }
                catch { notice = "恢复失败，原有数据未被替换" }
            }
        }
        .alert("备份结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("确定") { notice = nil }
        } message: { Text(notice ?? "") }
    }
}
