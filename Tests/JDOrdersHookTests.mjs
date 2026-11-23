import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const swift = fs.readFileSync("App/NativeWebOrders.swift", "utf8");
function script(name) {
  const re = new RegExp("(?:static|private static) let " + name + " = #\"\"\"\\n([\\s\\S]*?)\\n\\s*\"\"\"#");
  const match = swift.match(re);
  assert.ok(match, name + " exists");
  return match[1];
}
const hook = script("jdDocumentHook");
const orders = script("jdOrdersJS");
const tracking = script("jdTrackingJS");
for (const [name, text] of Object.entries({hook, orders, tracking})) {
  assert.doesNotThrow(() => new vm.Script(text), name + " parses");
}

class FakeXHR {
  constructor() { this.callbacks = {}; this.responseType = ""; this.responseText = ""; }
  addEventListener(type, callback) { this.callbacks[type] = callback; }
  send() { this.callbacks.load?.call(this); }
}
const win = {};
win.top = win;
const location = {protocol: "https:", hostname: "trade.m.jd.com", href: "https://trade.m.jd.com/order/orderlist_jdm.shtml"};
const context = {window: win, location, XMLHttpRequest: FakeXHR, URL, document: {body: {innerText: "待收货"}, querySelectorAll: () => []}};
vm.runInNewContext(hook, context);
assert.equal(typeof win.ParcelHelperJD.snapshot, "function", "JD hook installed");

const normal = {
  orderId: "123456789012",
  orderStatusInfo: {orderStatusName: "待收货"},
  progressInfo: {
    progressId: "logistics",
    progressLink: "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789012",
    content: "【东城自提点】包裹已到达，取件码：A-123456"
  },
  wareInfoList: [{wareName: "测试鞋子", skuId: "A123"}],
  shopInfo: {shopId: "654"}
};
const instant = {
  orderId: "998877665544",
  orderStatusInfo: {orderStatusName: "待收货"},
  progressInfo: {progressId: "logistics", content: "骑手正在配送"},
  specialDealList: [{isStore2Home: true}]
};
const xhr = new FakeXHR();
xhr.responseURL = "https://api.m.jd.com/client.action?functionId=order_list_m";
xhr.responseText = JSON.stringify({body: {orderList: [normal, instant]}});
xhr.send();

const list = win.ParcelHelperJD.snapshot();
assert.equal(list.received, true);
assert.equal(list.orders.length, 1, "instant delivery filtered");
assert.equal(list.orders[0].id, normal.orderId);
assert.equal(list.orders[0].link, normal.progressInfo.progressLink);
assert.equal(list.orders[0].verified, true);
assert.equal(list.orders[0].code, "A-123456");
assert.equal(list.orders[0].title, "测试鞋子");

// Structured snapshots take precedence over fragile DOM href scraping.
const result = JSON.parse(vm.runInNewContext(orders, context));
assert.equal(result.structured, true);
assert.equal(result.orders.length, 1);

const logisticsXHR = new FakeXHR();
logisticsXHR.responseURL = "https://api.m.jd.com/client.action?functionId=get_logistics_list_by_order_m";
logisticsXHR.responseText = JSON.stringify({
  body: {
    carriageId: "SF123456789012",
    carrier: "顺丰速运",
    tracePointVOList: [{createTime: "2026-11-23 07:30", wlStateDesc: "包裹运输中"}]
  }
});
logisticsXHR.send();
const route = win.ParcelHelperJD.logistics();
assert.equal(route.mail, "SF123456789012");
assert.equal(route.tracks[0].text, "包裹运输中");
const parsedTracking = JSON.parse(vm.runInNewContext(tracking, context));
assert.equal(parsedTracking.mail, "SF123456789012");
assert.equal(parsedTracking.tracks.length, 1);

// Responses outside JD's HTTPS origins cannot be read as authorized data.
const oldList = win.ParcelHelperJD.snapshot();
const evilXHR = new FakeXHR();
evilXHR.responseURL = "https://other.example.com/orderList";
evilXHR.responseText = JSON.stringify({body: {orderList: [{
  orderId: "333344445555", orderStatusInfo: {orderStatusName: "待收货"},
  progressInfo: {progressId: "logistics", content: "hello"}
}]}});
evilXHR.send();
assert.equal(win.ParcelHelperJD.snapshot().orders.length, oldList.orders.length);
assert.equal(win.ParcelHelperJD.snapshot().orders[0].id, normal.orderId);

// No verified logistics signal must not create a delivery card.
const plainXHR = new FakeXHR();
plainXHR.responseURL = "https://api.m.jd.com/client.action?functionId=order_list_m";
plainXHR.responseText = JSON.stringify({body: {orderList: [{
  orderId: "111122223333", orderStatusInfo: {orderStatusName: "交易成功"}
}]}});
plainXHR.send();
assert.equal(win.ParcelHelperJD.snapshot().orders.length, 1, "last rich snapshot preserved");

console.log("PASS: JD document-start hook, structured link, pickup code, logistics, origin guard and instant filter");
