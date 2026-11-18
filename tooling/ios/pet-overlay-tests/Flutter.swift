// Standalone simulator fixture only. Apple UIKit/AVKit are real. This shim
// checks the native method-channel contract without embedding a Dart engine;
// it is not a substitute for the normal Runner build with Flutter's headers.
import Foundation

public typealias FlutterResult = (Any?) -> Void
public let FlutterMethodNotImplemented = NSObject()
public protocol FlutterBinaryMessenger: AnyObject {}
public protocol FlutterPluginRegistrar: AnyObject {
  func messenger() -> any FlutterBinaryMessenger
  func lookupKey(forAsset asset: String) -> String
}
public final class FlutterMethodCall {
  public let method: String
  public let arguments: Any?
  public init(method: String, arguments: Any?) { self.method = method; self.arguments = arguments }
}
public final class FlutterError: NSObject {
  public let code: String
  public let message: String?
  public let details: Any?
  public init(code: String, message: String?, details: Any?) {
    self.code = code; self.message = message; self.details = details
  }
}
public final class FlutterMethodChannel: NSObject {
  public static var testChannels: [String: FlutterMethodChannel] = [:]
  public var events: [(String, Any?)] = []
  private var handler: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?
  public init(name: String, binaryMessenger: any FlutterBinaryMessenger) {
    super.init()
    Self.testChannels[name] = self
  }
  public func setMethodCallHandler(_ handler: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?) {
    self.handler = handler
  }
  public func invokeMethod(_ method: String, arguments: Any?) { events.append((method, arguments)) }
  public func callTestMethod(_ method: String, arguments: Any? = nil, result: @escaping FlutterResult) {
    handler?(FlutterMethodCall(method: method, arguments: arguments), result)
  }
}
