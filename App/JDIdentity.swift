import SwiftUI
import WebKit

// 京东身份码展示参考 HandyCode (MIT License).
// Only official JD-generated SVG content is shown; no code, cookie or
// credentials are sent through the WKWebView-to-Swift message bridge.
private struct JDBarcodeImage: Identifiable {
    let id = UUID()
    let bitmap: UIImage
}
private struct JDBarcodeFullscreen: View {
    let bitmap: UIImage
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // Every empty point is a valid exit, not just a small icon.
                Color.white
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                Image(uiImage: bitmap)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: min(geometry.size.height * 0.75, 720),
                           height: min(geometry.size.width * 0.58, 240))
                    .rotationEffect(.degrees(90))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                Button(action: onClose) {
                    Label("关闭", systemImage: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Color(white: 0.93), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭京东条形码")
                // The close control is anchored at the top, within the safe
                // area, and is never rotated together with the barcode.
                .padding(.trailing, 18)
                .padding(.top, 12)
                .zIndex(10)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 32).onEnded { value in
                    // Support a rightward back swipe and downward dismiss.
                    if value.translation.width > 80 || value.translation.height > 100 {
                        onClose()
                    }
                }
            )
        }
        .preferredColorScheme(.light)
        .statusBarHidden(false)
    }
}
private enum JDIdentityState: Equatable {
    case loading
    case ready
    case loginRequired
    case failed(String)
}

struct JDIdentityPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var accountID = ""
    @State private var state: JDIdentityState = .loading
    @State private var refreshIndex = 0
    @State private var sessionValid = false
    @State private var zoom: JDBarcodeImage?
    private let accent = Color(red: 0.19, green: 0.49, blue: 0.96)
    private var accountName: String {
        ParcelAccounts.displayName(accountID, platform: "jd")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("默认账号：" + accountName, systemImage: "person.crop.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    NavigationLink {
                        MultiAccountPage(platformID: "jd")
                    } label: {
                        Text("管理默认账号").font(.subheadline)
                    }
                    .tint(accent)
                }

                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        Image("brand_jd")
                            .resizable().scaledToFit()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("京东官方身份码")
                                .font(.system(size: 17, weight: .semibold))
                            Text("动态条形码")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(accent)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .disabled(state == .loading)
                        .accessibilityLabel("刷新京东身份码")
                    }

                    ZStack {
                        if !accountID.isEmpty && sessionValid {
                            JDIdentityWebView(
                                accountID: accountID,
                                refreshIndex: refreshIndex,
                                dark: false,
                                onUpdate: { newState, _ in
                                    guard accountID == ParcelAccounts.activeID(for: "jd") else { return }
                                    state = newState
                                    if newState != .ready { zoom = nil }
                                },
                                onZoom: { bitmap in
                                    guard state == .ready,
                                          accountID == ParcelAccounts.activeID(for: "jd") else { return }
                                    zoom = JDBarcodeImage(bitmap: bitmap)
                                }
                            )
                            .id(accountID)
                            .frame(height: 265)
                            .opacity(state == .ready ? 1 : 0)
                            .allowsHitTesting(state == .ready)
                            .accessibilityHidden(state != .ready)
                        }
                        if state != .ready {
                            VStack(spacing: 14) {
                                switch state {
                                case .loading:
                                    ProgressView()
                                    Text("正在获取京东官方身份码…")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                case .loginRequired:
                                    Image(systemName: "person.badge.key")
                                        .font(.system(size: 38)).foregroundStyle(accent)
                                    Text("当前账号暂时无法获取身份码").font(.headline)
                                    NavigationLink {
                                        PlatformAccountsPage()
                                    } label: {
                                        Text("管理账号授权")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                case .failed(let reason):
                                    Image(systemName: "exclamationmark.circle")
                                        .font(.system(size: 38)).foregroundStyle(.orange)
                                    Text(reason)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                    Button("重新获取") { reload() }
                                        .buttonStyle(.bordered)
                                case .ready:
                                    EmptyView()
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 265)
                            .padding(.horizontal, 16)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 265)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
                    .clipShape(RoundedRectangle(cornerRadius: 15))

                    if state == .ready {
                        Text("点击条形码可全屏出示")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 24))
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 90)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("京东身份码")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $zoom) { item in
            JDBarcodeFullscreen(bitmap: item.bitmap, onClose: { zoom = nil })
        }
        .task { syncDefault() }
        .onAppear { syncDefault() }
        .onChange(of: scenePhase) { _, next in
            if next == .active { syncDefault() }
        }
        .task(id: accountID + ":" + String(refreshIndex)) {
            guard !accountID.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(22)) } catch { return }
            if state == .loading {
                state = .failed("京东身份码暂未加载成功，请刷新重试")
            }
        }
    }

    private func syncDefault() {
        let selected = ParcelAccounts.activeID(for: "jd")
        if accountID != selected {
            accountID = selected
            sessionValid = false
            state = .loading
            refreshIndex = 0
        }
        Task { @MainActor in
            let valid = await ParcelAccounts.hasSession("jd", accountID: selected)
            guard selected == accountID,
                  selected == ParcelAccounts.activeID(for: "jd") else { return }
            sessionValid = valid
            if !valid {
                state = .loginRequired
                zoom = nil
            } else if state == .loginRequired {
                state = .loading
                refreshIndex &+= 1
            }
        }
    }
    private func reload() {
        guard !accountID.isEmpty else { return }
        state = .loading
        zoom = nil
        refreshIndex &+= 1
        syncDefault()
    }
}

private struct JDIdentityWebView: UIViewRepresentable {
    let accountID: String
    let refreshIndex: Int
    let dark: Bool
    let onUpdate: (JDIdentityState, Bool) -> Void
    let onZoom: (UIImage) -> Void
    private static let entry = URL(
        string: "https://convenient-h5.jd.com/identityCode?channel=xueshengjirukou")!

    func makeCoordinator() -> Coordinator {
        Coordinator(revision: refreshIndex, onUpdate: onUpdate, onZoom: onZoom)
    }
    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "parcelJDIdentity")
        controller.addUserScript(WKUserScript(source: Self.requestObserver,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.identityProjection,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ParcelAccounts.webStore(for: "jd", accountID: accountID)
        config.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.allowsBackForwardNavigationGestures = false
        view.load(URLRequest(url: Self.entry))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onUpdate = onUpdate
        context.coordinator.onZoom = onZoom
        if context.coordinator.dark != dark {
            context.coordinator.dark = dark
            view.evaluateJavaScript("window.PHJDIdentity&&window.PHJDIdentity.setDark(" +
                (dark ? "true" : "false") + ");", completionHandler: nil)
        }
        guard context.coordinator.revision != refreshIndex else { return }
        context.coordinator.revision = refreshIndex
        if let url = view.url, Self.isIdentity(url) {
            view.evaluateJavaScript("Boolean(window.PHJDIdentity&&window.PHJDIdentity.refresh())") { result, _ in
                if (result as? Bool) != true {
                    view.load(URLRequest(url: Self.entry))
                }
            }
        } else {
            view.load(URLRequest(url: Self.entry))
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.onUpdate = { _, _ in }
        coordinator.onZoom = { _ in }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "parcelJDIdentity")
    }
    private static func permitted(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "jd.com" || host.hasSuffix(".jd.com")
    }
    private static func isIdentity(_ url: URL) -> Bool {
        permitted(url) && url.host?.lowercased() == "convenient-h5.jd.com" &&
            url.path == "/identityCode"
    }
    private static func needsLogin(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "plogin.m.jd.com" ||
            (host.hasSuffix(".jd.com") && url.path.lowercased().contains("/login"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var revision: Int
        var dark = false
        var onUpdate: (JDIdentityState, Bool) -> Void
        var onZoom: (UIImage) -> Void
        init(revision: Int, onUpdate: @escaping (JDIdentityState, Bool) -> Void,
             onZoom: @escaping (UIImage) -> Void) {
            self.revision = revision
            self.onUpdate = onUpdate
            self.onZoom = onZoom
        }
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "parcelJDIdentity",
                  let webView = message.webView, let url = webView.url,
                  JDIdentityWebView.isIdentity(url),
                  let payload = message.body as? [String: Any],
                  let state = payload["state"] as? String else { return }
            let expanded = payload["expanded"] as? Bool ?? false
            switch state {
            case "ready": onUpdate(.ready, expanded)
            case "loading": onUpdate(.loading, false)
            case "failed": onUpdate(.failed("京东未返回有效身份码，请刷新重试"), false)
            case "expired": onUpdate(.failed("京东身份码已过期，请刷新重试"), false)
            case "zoom": snapshotBarcode(in: webView)
            default: break
            }
        }
        private func snapshotBarcode(in webView: WKWebView) {
            // Capture the actual official JD SVG rendering, not an inferred
            // numeric code or a locally fabricated verification image.
            let geometryScript = #"""
            (() => {
              const element=document.getElementById('ph-jd-barcode');
              if (!element || !element.querySelector('svg')) return null;
              const box=element.getBoundingClientRect();
              return {x:box.left,y:box.top,w:box.width,h:box.height,viewport:innerWidth};
            })()
            """#
            webView.evaluateJavaScript(geometryScript) { [weak self, weak webView] result, _ in
                guard let self, let webView, let data = result as? [String: NSNumber],
                      let viewport = data["viewport"]?.doubleValue, viewport > 0,
                      let x = data["x"]?.doubleValue,
                      let y = data["y"]?.doubleValue,
                      let width = data["w"]?.doubleValue,
                      let height = data["h"]?.doubleValue,
                      width > 40, height > 20 else { return }
                let scale = Double(webView.bounds.width) / viewport
                let rect = CGRect(x: x * scale, y: y * scale,
                                  width: width * scale, height: height * scale)
                    .intersection(webView.bounds)
                guard !rect.isNull, rect.width > 40, rect.height > 20 else { return }
                let config = WKSnapshotConfiguration()
                config.rect = rect
                webView.takeSnapshot(with: config) { image, error in
                    guard error == nil, let image else { return }
                    self.onZoom(image)
                }
            }
        }
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  JDIdentityWebView.permitted(url) else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame?.isMainFrame != false,
               JDIdentityWebView.needsLogin(url) {
                onUpdate(.loginRequired, false)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url,
                  JDIdentityWebView.permitted(url) else { return nil }
            if JDIdentityWebView.needsLogin(url) {
                onUpdate(.loginRequired, false)
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            onUpdate(JDIdentityWebView.needsLogin(url) ? .loginRequired : .loading, false)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if JDIdentityWebView.needsLogin(url) {
                onUpdate(.loginRequired, false)
            } else if !JDIdentityWebView.isIdentity(url) {
                onUpdate(.failed("请通过京东官方页面完成登录验证"), false)
            } else {
                webView.evaluateJavaScript("window.PHJDIdentity&&window.PHJDIdentity.setDark(" +
                    (dark ? "true" : "false") + ");", completionHandler: nil)
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                onUpdate(.failed("京东身份码页面无法连接，请检查网络"), false)
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                onUpdate(.failed("京东身份码页面加载失败"), false)
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onUpdate(.failed("京东身份码网页已停止，请重新加载"), false)
        }
    }

    private static let requestObserver = #"""
    (function(){
      'use strict';
      if (window.top!==window || location.origin!=='https://convenient-h5.jd.com' ||
          location.pathname!=='/identityCode') return;
      var state={pending:false,failed:false,generated:0};
      window.PHJDRequest=state;
      var xhrOpen=XMLHttpRequest.prototype.open;
      var xhrSend=XMLHttpRequest.prototype.send;
      var matched=new WeakMap();
      XMLHttpRequest.prototype.open=function(method,url){
        var yes=false;
        try {
          var u=new URL(url,location.href);
          yes=u.origin==='https://lop-proxy.jd.com' && u.pathname==='/generateIdentityCode';
        } catch(e){}
        matched.set(this,yes);
        return xhrOpen.apply(this,arguments);
      };
      XMLHttpRequest.prototype.send=function(){
        if(matched.get(this)){
          state.pending=true;state.failed=false;
          if(state.changed)state.changed();
          this.addEventListener('loadend',function(){
            var response;
            try {response=this.responseType==='json'?this.response:JSON.parse(this.responseText);}
            catch(e){}
            var data=response&&response.data;
            var success=this.status>=200 && this.status<300 && response &&
               (Number(response.errorCode)===0 || Number(response.code)===1) &&
               data && typeof data.identityCode==='string' && data.identityCode.length>0;
            state.pending=false;state.failed=!success;
            if(success)state.generated=Date.now();
            if(state.changed)state.changed();
          },{once:true});
        }
        return xhrSend.apply(this,arguments);
      };
    })();
    """#

    private static let identityProjection = #"""
    (function(){
      'use strict';
      if(window.top!==window || location.origin!=='https://convenient-h5.jd.com' ||
         location.pathname!=='/identityCode' || window.PHJDIdentity) return;
      var requests=window.PHJDRequest||{pending:false,failed:false,generated:0};
      var style=document.createElement('style');
      style.textContent=[
        'html,body{margin:0!important;padding:0!important;background:transparent!important;overflow:hidden!important}',
        '#root{position:fixed!important;left:-20000px!important;top:0!important;width:100vw!important;visibility:hidden!important;pointer-events:none!important}',
        '#ph-jd{box-sizing:border-box;width:100%;height:265px;padding:18px 16px;display:flex;align-items:center;justify-content:center;color:#222;font-family:-apple-system,sans-serif;overflow:hidden}',
        '#ph-jd *{box-sizing:border-box}',
        '#ph-jd-inner{width:100%;text-align:center;transition:transform .3s}',
        '#ph-jd-phone{font-size:16px;line-height:24px;margin:2px 0 15px}',
        '#ph-jd-barcode{display:block;width:100%;background:white;padding:12px;border-radius:12px;outline:none;touch-action:manipulation;user-select:none;-webkit-user-select:none;-webkit-touch-callout:none}',
        '#ph-jd-barcode svg{width:100%;height:90px;display:block;pointer-events:none;user-select:none;-webkit-user-select:none}',
        '#ph-jd-note{font-size:12px;color:#7a8290;margin:13px 0 0}',
        'html[data-ph-jd-dark] #ph-jd{color:#f0f2f7}',
        'html[data-ph-jd-dark] #ph-jd-note{color:#9da6b7}',
        '@media(prefers-reduced-motion:reduce){#ph-jd-inner{transition:none}}'
      ].join('');
      (document.head||document.documentElement).appendChild(style);
      var mount=document.createElement('main');mount.id='ph-jd';
      var inner=document.createElement('div');inner.id='ph-jd-inner';
      var phone=document.createElement('p');phone.id='ph-jd-phone';
      var barcode=document.createElement('div');barcode.id='ph-jd-barcode';
      var note=document.createElement('p');note.id='ph-jd-note';
      barcode.tabIndex=0;barcode.setAttribute('role','button');
      inner.appendChild(phone);inner.appendChild(barcode);inner.appendChild(note);
      mount.appendChild(inner);
      (document.body||document.documentElement).appendChild(mount);
      var ready=false,expanded=false,last='',signature='',observer,observed;
      function emit(state){
        var mark=state+':'+expanded;
        if(mark===last)return;
        last=mark;
        try{window.webkit.messageHandlers.parcelJDIdentity.postMessage({state:state,expanded:expanded});}
        catch(e){}
      }
      function probe(){
        var root=document.getElementById('root');
        if(!root){emit('loading');return;}
        if(observed!==root){
          if(observer)observer.disconnect();
          observed=root;
          observer=new MutationObserver(function(){setTimeout(probe,80);});
          observer.observe(root,{childList:true,subtree:true,characterData:true});
        }
        var svg=root.querySelector('.qr svg');
        var mobile=root.querySelector('.font-18');
        var busy=!!root.querySelector('.van-loading');
        var hasCode=!!svg && svg.querySelectorAll('rect').length>10 &&
                    !!mobile && !!mobile.textContent.trim();
        var expired=requests.generated && Date.now()-requests.generated >= 20*60*1000;
        if(requests.failed||expired){
          mount.style.visibility='hidden';ready=false;emit(requests.failed?'failed':'expired');return;
        }
        if(requests.pending||busy||!hasCode){
          mount.style.visibility='hidden';ready=false;emit('loading');return;
        }
        var next=svg.outerHTML+mobile.textContent;
        if(next!==signature){
          signature=next;
          phone.textContent=mobile.textContent.trim().replace(/(1\d{2})\d{4}(\d{4})/g,'$1****$2');
          barcode.replaceChildren(svg.cloneNode(true));
        }
        var hint=root.querySelector('.content-right > div');
        note.textContent=hint && /分钟.*更新/.test(hint.textContent)?
            hint.textContent.trim():'官方动态条形码 · 点击放大';
        mount.style.visibility='visible';ready=true;emit('ready');
      }
      requests.changed=probe;
      function showZoom(event){
        if(event){event.preventDefault();event.stopPropagation();}
        if(!ready)return;
        try{window.webkit.messageHandlers.parcelJDIdentity.postMessage({state:'zoom'});}
        catch(e){}
      }
      barcode.addEventListener('click',showZoom);
      barcode.addEventListener('keydown',function(event){
        if(event.key==='Enter'||event.key===' '){showZoom(event);}
      });
      window.PHJDIdentity={
        setDark:function(d){document.documentElement.toggleAttribute('data-ph-jd-dark',!!d);},
        refresh:function(){
          if(requests.pending)return true;
          var root=document.getElementById('root');
          var button=root&&root.querySelector('.refresh');
          if(!button)return false;
          requests.pending=true;requests.failed=false;
          mount.style.visibility='hidden';ready=false;expanded=false;
          mount.classList.remove('expanded');last='';emit('loading');
          button.click();
          return true;
        }
      };
      setInterval(probe,800);probe();
    })();
    """#
}
