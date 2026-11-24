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
const pagination = script("jdLoadNextPage");
assert.doesNotThrow(() => new vm.Script(pagination));
let clicked = false;
const more = {textContent:"加载更多", disabled:false, getAttribute:()=>null, getClientRects:()=>[1], click:()=>{clicked=true}};
assert.equal(vm.runInNewContext(pagination,{document:{querySelectorAll:()=>[more]}}),true);
assert.equal(clicked,true);
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
assert.equal(list.orderResponses, 1);
assert.equal(list.responses, 1);
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
assert.ok(result.diagnostic.includes("捕获器已安装"));
assert.ok(result.diagnostic.includes("订单响应1"));
const external = {location:{protocol:"https:",hostname:"example.com"}};
const blocked = JSON.parse(vm.runInNewContext(orders, external));
assert.equal(blocked.foreign,true);
assert.equal(blocked.orders.length,0);
assert.equal(JSON.parse(vm.runInNewContext(tracking, external)).tracks.length,0);

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
assert.equal(parsedTracking.pickup, "", "missing data must stay missing");
context.document.body.innerText = "运单号：SF123456789012\n取件码：8-1-12345\n驿站名称：测试驿站";
const enriched = JSON.parse(vm.runInNewContext(tracking, context));
assert.equal(enriched.pickup, "8-1-12345", "DOM supplements structured tracking");
assert.equal(enriched.station, "测试驿站");
context.document.body.innerText = "运单号：SF987654321012\n取件码：1-2-34567";
assert.equal(JSON.parse(vm.runInNewContext(tracking, context)).pickup, "", "no cross-waybill code");
context.document.body.innerText = "待收货";

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

const delivering = new FakeXHR();
delivering.responseURL = "https://api.m.jd.com/client.action?functionId=order_list_m";
delivering.responseText = JSON.stringify({body:{orderList:[{
  dealId:"222233334444", orderStatusInfo:{orderStatusName:"配送中"},
  progressInfo:{content:"配送员正在配送，请保持电话畅通"}
},{
  orderId:"555566667777", orderStatusInfo:{orderStatusName:"配送中"},
  progressInfo:{content:"京东物流骑手正在配送",progressId:"logistics"}
}]}});
delivering.send();
const active = win.ParcelHelperJD.snapshot().orders;
assert.equal(active.find(x=>x.id==="222233334444")?.verified,true,"active delivery without waybill retained");
assert.equal(active.find(x=>x.id==="555566667777")?.verified,true,"ordinary delivery not rejected by rider wording");
assert.ok(active.some(x=>x.id===normal.orderId),"previous page retained");
const pending = new FakeXHR();
pending.responseURL = "https://api.m.jd.com/client.action?functionId=order_list_m";
pending.responseText = JSON.stringify({body:{orderList:[{orderId:"777788889999",orderStatusInfo:{orderStatusName:"待收货"},progressInfo:{subContent:"商品正在配送"}}]}});
pending.send();
assert.equal(win.ParcelHelperJD.snapshot().orders.find(x=>x.id==="777788889999")?.verified,true);
const explicitPickup = new FakeXHR();
explicitPickup.responseURL = "https://api.m.jd.com/client.action?functionId=get_logistics_list_by_order_m";
explicitPickup.responseText = JSON.stringify({body:{
  carriageId:"SF123456789012", carrier:"顺丰速运",
  pickupCode:"8-1-12345", stationName:"测试驿站",
  tracePointVOList:[{createTime:"2026-11-24 12:00", wlStateDesc:"已到站"}]
}});
explicitPickup.send();
assert.equal(win.ParcelHelperJD.logistics().pickup, "8-1-12345");
assert.equal(win.ParcelHelperJD.logistics().station, "测试驿站");
const empty = new FakeXHR();
empty.responseURL = "https://api.m.jd.com/client.action?functionId=order_list_m";
empty.responseText = JSON.stringify({body:{orderList:[]}});
const countBeforeEmpty = win.ParcelHelperJD.snapshot().orders.length;
empty.send();
assert.equal(win.ParcelHelperJD.snapshot().orders.length,countBeforeEmpty);
const busy = JSON.parse(vm.runInNewContext(orders,{
  window:{}, location, document:{body:{innerText:"服务繁忙，请稍后重试"}, querySelectorAll:()=>[]}
}));
assert.equal(busy.problem,"busy");
assert.equal(busy.orders.length,0);
console.log("PASS: JD order fixtures, pagination, explicit pickup, empty responses, busy page and origin isolation");
