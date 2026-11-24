import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
const source = fs.readFileSync("App/NativeSettings.swift","utf8");
const script = source.match(/static let phaseJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const origin = "https://page.cainiao.com";
const location = {origin, pathname:"/cn-app-web/identity-code/index.html",href:origin+"/cn-app-web/identity-code/index.html#/"};
const image = {getClientRects:()=>[1], complete:true, naturalWidth:200};
const login = {getClientRects:()=>[1],type:"tel"};
const frame = {getClientRects:()=>[1], getAttribute:()=>"https://login.taobao.com/member/login.jhtml",getBoundingClientRect:()=>({width:320,height:500})};
function phase({code=image, controls=[], frames=[], loc=location, root=null}={}) {
    return vm.runInNewContext(script,{URL,location:loc,innerWidth:390,innerHeight:700,
        getComputedStyle:()=>({display:"block",visibility:"visible",opacity:"1"}),
        document:{querySelectorAll:sel=>sel==="iframe"?frames:controls,getElementById:()=>code,querySelector:()=>root}});
}
assert.equal(phase(),"ready");
assert.equal(phase({code:null}),"loading");
assert.equal(phase({code:{...image,naturalWidth:0}}),"loading");
assert.equal(phase({controls:[login]}),"authorizationRequired");
assert.equal(phase({frames:[frame]}),"authorizationRequired");
assert.equal(phase({frames:[{...frame,getBoundingClientRect:()=>({width:320,height:500,right:-1})}]}),"ready");
assert.equal(phase({frames:[{...frame,getBoundingClientRect:()=>({width:0,height:0})}]}),"ready");
assert.equal(phase({frames:[{...frame,getBoundingClientRect:()=>({width:320,height:500,top:800})}]}),"ready");
assert.equal(phase({controls:[{getClientRects:()=>[1]}]}),"authorizationRequired");
assert.equal(phase({loc:{origin:"https://login.taobao.com",pathname:"/member/login.jhtml"}}),"authorizationRequired");
assert.equal(phase({controls:[{...login,getClientRects:()=>[]}]}),"ready");
const taobaoLoc = {origin:"https://pages-fast.m.taobao.com", pathname:"/wow/z/uniapp/1011717/last-mile-fe/end-collect-platform/identity-code"};
assert.equal(phase({loc:taobaoLoc}),"authorizationRequired");
assert.equal(phase({loc:{origin:"https://example.com",pathname:location.pathname}}),"authorizationRequired");
const accounts = fs.readFileSync("App/AccountProfiles.swift","utf8");
assert.ok(!accounts.includes('Label("身份码授权"'));
assert.ok(!accounts.includes("cainiaoIdentityAccount"));
assert.ok(source.includes("web.isUserInteractionEnabled = false"));
assert.ok(!source.includes("case loading, ready, taobaoReady"));
assert.ok(source.includes("cainiaoCertificationUnavailable"));
console.log("PASS: Cainiao identity display phases and authentication isolation");
