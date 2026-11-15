import Flutter
import UIKit
import WebKit
import webview_flutter_wkwebview

// dsh/islands, after android/.../islands/IslandsPlugin.kt and ohos/.../IslandsPlugin.ets: what
// webview_flutter doesn't do for a WKWebView. `id` is
// WebKitWebViewController.webViewIdentifier; every WebView of the app that attaches gets the
// app's light or dark and text size, and a dead page reported, not only the web islands.
//
// Where iOS differs from the contract:
// - `pause` only suspends the page's audio and video. The system itself freezes a page once
//   the app is in the background; there's no public way to freeze one on screen.
// - `crashed` is always false: iOS doesn't say why a page's process ended.
// - Each WKWebView can have a process of its own, where Android's share one. Dart closes every
//   island when one goes; here that's more than it had to, and a tap reopens them.
// - `appPss` is this process's own footprint. The pages' processes aren't counted.

final class IslandsChannel: NSObject {
  /// `ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL`: iOS has one level of warning, the serious kind.
  private static let trimOnWarning = 15

  private let channel: FlutterMethodChannel
  private let registrar: any FlutterPluginRegistrar

  /// A WKWebView holds its navigation delegate weakly.
  private var guards: [Int64: PageGuard] = [:]
  private var zooms: [Int64: Int] = [:]

  init(registrar: any FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "dsh/islands", binaryMessenger: registrar.messenger())
    self.registrar = registrar
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      self.handle(call, result: result)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(memoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = arguments(call)
    switch call.method {
    case "device": result(Self.device())
    case "appPss": result(Self.footprintKb())
    case "attach": result(attach(args))
    case "setDark":
      if let page = webView(args) { Self.setDark(page.view, args["dark"] as? Bool == true) }
      result(nil)
    case "setTextZoom":
      if let page = webView(args), let zoom = args["zoom"] as? Int { setTextZoom(page.id, page.view, zoom) }
      result(nil)
    case "pause":
      webView(args)?.view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
      result(nil)
    case "resume":
      webView(args)?.view.setAllMediaPlaybackSuspended(false, completionHandler: nil)
      result(nil)
    case "destroy":
      if let page = webView(args) { destroy(page.id, page.view) }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func webView(_ args: [String: Any]) -> (id: Int64, view: WKWebView)? {
    guard let id = (args["id"] as? NSNumber)?.int64Value else { return nil }
    guard let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(forIdentifier: id, withPluginRegistrar: registrar)
    else { return nil }
    return (id, view)
  }

  private func attach(_ args: [String: Any]) -> Bool {
    guard let page = webView(args) else { return false }
    Self.setDark(page.view, args["dark"] as? Bool == true)
    if let zoom = args["textZoom"] as? Int { setTextZoom(page.id, page.view, zoom) }
    guardPage(page.id, page.view)
    return true
  }

  /// `prefers-color-scheme` goes by the view's own trait, so this needs nothing from the page.
  private static func setDark(_ view: WKWebView, _ dark: Bool) {
    view.overrideUserInterfaceStyle = dark ? .dark : .light
  }

  /// WKWebView has no text zoom like Android's, only `pageZoom`, which scales everything. So
  /// this is WebKit's own CSS for it, on the document now and on each one loaded from here on.
  /// A page that sets the property lower down in its tree keeps its own size there.
  private func setTextZoom(_ id: Int64, _ view: WKWebView, _ percent: Int) {
    let zoom = min(max(percent, 50), 300)
    guard zooms[id] != zoom, zooms[id] != nil || zoom != 100 else { return }
    zooms[id] = zoom
    let property = "'-webkit-text-size-adjust','\(zoom)%','important'"
    let script = "(function(){var e=document.documentElement;if(e)e.style.setProperty(\(property));})();"
    // Added and never removed: taking one script out would take webview_flutter's JavaScript
    // channels with it. Each runs in turn, so the last size set wins.
    view.configuration.userContentController.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    )
    view.evaluateJavaScript(script, completionHandler: nil)
  }

  private func guardPage(_ id: Int64, _ view: WKWebView) {
    if let current = guards[id], view.navigationDelegate === current { return }
    let installed = PageGuard(inner: view.navigationDelegate) { [weak self] in
      let gone: [String: Any] = ["id": id, "crashed": false]
      self?.channel.invokeMethod("rendererGone", arguments: gone)
    }
    guards[id] = installed
    view.navigationDelegate = installed
  }

  /// Dart keeps its controller until a garbage collection: the page stops now, not then.
  private func destroy(_ id: Int64, _ view: WKWebView) {
    guards[id] = nil
    zooms[id] = nil
    view.navigationDelegate = nil
    view.stopLoading()
    view.loadHTMLString("", baseURL: nil)
    view.removeFromSuperview()
  }

  @objc private func memoryWarning() {
    channel.invokeMethod("trimMemory", arguments: ["level": Self.trimOnWarning])
  }

  /// `lowRam` is left to the memory figure: iOS has no such flag, and below 5.5 GiB Dart
  /// keeps to one island as it is.
  private static func device() -> [String: Any] {
    [
      "totalMem": Int(clamping: ProcessInfo.processInfo.physicalMemory),
      "lowRam": false,
      "webView": "WebKit (iOS \(UIDevice.current.systemVersion))",
    ]
  }

  private static func footprintKb() -> Int? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
      }
    }
    guard status == KERN_SUCCESS else { return nil }
    return Int(info.phys_footprint / 1024)
  }
}

/// webview_flutter's delegate with one thing added, as Android's GuardedWebViewClient has it:
/// everything goes on to the delegate it wraps except the page's process ending, which reaches
/// Dart as `rendererGone` and not also as a load error.
private final class PageGuard: NSObject, WKNavigationDelegate {
  private let inner: (any WKNavigationDelegate)?
  private let onGone: () -> Void

  init(inner: (any WKNavigationDelegate)?, onGone: @escaping () -> Void) {
    self.inner = inner
    self.onGone = onGone
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || inner?.responds(to: aSelector) == true
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    inner
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    onGone()
  }
}
