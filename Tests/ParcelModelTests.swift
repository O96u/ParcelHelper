import Foundation

/// Run with: swiftc -parse-as-library Shared/Models.swift
/// Tests/ParcelModelTests.swift -o /tmp/parcel-model-tests && /tmp/parcel-model-tests
@main
struct ParcelModelTests {
    static func main() {
        var incoming = Parcel()
        precondition(incoming.hasSyncedContentChange(comparedTo: nil),
                     "First import must write")
        let initial = incoming
        precondition(!incoming.hasSyncedContentChange(comparedTo: initial),
                     "Unchanged parcel should not rewrite")
        incoming.trackUpdatedAt = 12345
        precondition(!incoming.hasSyncedContentChange(comparedTo: initial),
                     "Fetch timestamp alone must not rewrite")
        incoming.itemTitle = "新增商品名称"
        precondition(incoming.hasSyncedContentChange(comparedTo: initial),
                     "Item title change must persist")
        incoming = initial
        incoming.eta = "明日送达"
        precondition(incoming.hasSyncedContentChange(comparedTo: initial),
                     "ETA change must persist")
        incoming = initial
        incoming.orderId = "taobao:order123"
        precondition(incoming.hasSyncedContentChange(comparedTo: initial),
                     "Order association must persist")
        incoming = initial
        incoming.srcApp = SourceApp(id: "douyin", name: "抖音")
        precondition(incoming.hasSyncedContentChange(comparedTo: initial),
                     "Platform source icon must persist")
        incoming = initial
        incoming.arrivedAt = 42
        incoming.code = "8-8-22054"
        precondition(incoming.isPending, "Arrived parcel must remain pending")
        incoming.trackLatest = "驿站代签收"
        precondition(!incoming.isDone && !incoming.isSigned,
                     "Station signature is not personal collection")
        incoming.trackLatest = "您已取走"
        precondition(incoming.isDone && !incoming.isPending,
                     "Confirmed collection closes the pickup item")
        incoming = initial
        incoming.trackLatest = "您的订单已送达，如有疑问您可以联系配送员确认。"
        precondition(incoming.isSigned && !incoming.isTransit && incoming.displayStatus == "已送达",
                     "JD delivered order must not appear in transit")
        incoming.trackLatest = "您的订单已送达菜鸟驿站，请凭码取件"
        precondition(!incoming.isSigned,
                     "Station arrival must not be mistaken for final delivery")
        incoming.trackLatest = "订单已送达收件人"
        precondition(incoming.isSigned, "Recipient delivery should be completed")
        incoming.trackLatest = "快递员正在派送中，预计今日送达"
        precondition(!incoming.isSigned, "Out for delivery is not delivered")
        incoming = initial
        let newest = TrackNode(time: "2026-11-24 13:50:00", text: "运输中，最新位置")
        let older = TrackNode(time: "2026-11-24 07:50:00", text: "运输中，旧位置")
        TrackMerge.apply(to: &incoming, nodes: [newest], summary: newest.text)
        TrackMerge.apply(to: &incoming, nodes: [older, older], summary: older.text)
        precondition(incoming.trackLatest == newest.text && incoming.trackNodes == [newest, older])
        let signed = TrackNode(time: "2026-11-23 09:00:00", text: "已签收")
        TrackMerge.apply(to: &incoming, nodes: [signed], summary: signed.text)
        precondition(!incoming.isSigned, "Historical signature must not override current transit")
        incoming = initial
        incoming.arrivedAt = 42
        incoming.trackLatest = "派送异常，退回寄件人"
        precondition(incoming.hasDeliveryException && !incoming.isPending && incoming.displayStatus == "退回中")
        incoming = initial
        incoming.arrivedAt = 1000
        incoming.pickedAt = 3601000
        precondition(incoming.pickupDuration == 3600)
        incoming.closed = "已取消"
        precondition(!incoming.isPending && !incoming.isTransit && incoming.displayStatus == "已取消")
        incoming = initial
        incoming.trackLatest = "快件已派送成功（14栋代收点）"
        precondition(incoming.isPending && !incoming.isSigned)
        incoming.trackLatest = "您的快件已派送至本人，如有疑问请联系快递员"
        precondition(incoming.isSigned && !incoming.isTransit)
        incoming.trackLatest = "包裹退回中"
        precondition(incoming.displayStatus == "退回中" && !incoming.isTransit)
        incoming = initial
        TrackMerge.apply(to: &incoming, nodes: [newest], summary: newest.text)
        TrackMerge.apply(to: &incoming, nodes: [], summary: "已派送成功（14栋代收点）")
        precondition(incoming.isPending && !incoming.isSigned)
        incoming = initial
        incoming.mailNo = "JT1234567890123"
        incoming.arrivedAt = 42
        incoming.trackLatest = "快件已签收，签收方式【本人】，已由【代收点】送达，如有问题请联系驿站"
        precondition(incoming.isSigned && !incoming.isPending && incoming.displayStatus == "已送达")
        precondition(incoming.carrierDisplayName == "极兔速递")
        incoming.trackLatest = "快件已派送成功（14栋代收点）"
        precondition(incoming.isPending && !incoming.isSigned)
        incoming.trackLatest = "包裹退回中"
        precondition(incoming.isOtherStatus && !incoming.isTransit)
        incoming = initial
        incoming.trackLatest = "派送异常"
        precondition(incoming.isOtherStatus && !incoming.isTransit && !incoming.isPending)
        incoming.trackLatest = "本人签收"
        precondition(incoming.isSigned && !incoming.isDone)
        incoming.closed = "已取消"
        precondition(incoming.isOtherStatus && !incoming.isSigned)
        incoming = initial
        incoming.mailNo = "SF123456789012"
        incoming.codes = ["sf123456789012"]
        precondition(incoming.isTransit)
        TrackMerge.apply(to: &incoming, nodes: [newest], summary: newest.text)
        let oldArrival = TrackNode(time: "2026-11-23 10:00:00", text: "已到站")
        TrackMerge.apply(to: &incoming, nodes: [oldArrival], summary: oldArrival.text)
        precondition(incoming.isTransit && !incoming.isPending)
        incoming.orderId = "jd:12345678"
        incoming.linkedOrderIDs = ["jd:12345678", "taobao:87654321"]
        precondition(incoming.allOrderIDs.count == 2)
        let roundTrip = try! JSONDecoder().decode(Parcel.self, from: JSONEncoder().encode(incoming))
        precondition(roundTrip == incoming)
        print("PASS: parcel content, pickup classification, exceptions, durations and stale tracking merge")
    }
}
