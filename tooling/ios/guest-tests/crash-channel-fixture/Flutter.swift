// A transport-only substitute for standalone macOS contract tests. All channel
// state transitions still run the production GuestChannel implementation.
import Foundation
public typealias FlutterResult = (Any?) -> Void
public typealias FlutterEventSink = (Any?) -> Void
public protocol FlutterBinaryMessenger: AnyObject {}
public final class FlutterError: NSObject {
  public let code: String
  public let message: String?
  public let details: Any?
  public init(code: String, message: String?, details: Any?) {
    self.code = code; self.message = message; self.details = details
  }
}
public let FlutterMethodNotImplemented: Any = "FlutterMethodNotImplemented"
public final class FlutterMethodCall {
  public let method: String
  public let arguments: Any?
  public init(methodName: String, arguments: Any?) {
    method = methodName; self.arguments = arguments
  }
}
public protocol FlutterStreamHandler: AnyObject {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError?
  func onCancel(withArguments arguments: Any?) -> FlutterError?
}
public final class ContractMessenger: FlutterBinaryMessenger {
  fileprivate var methodHandlers: [String: (FlutterMethodCall, @escaping FlutterResult) -> Void] = [:]
  public init() {}
  public func invoke(_ method: String, arguments: Any? = nil, result: @escaping FlutterResult) {
    methodHandlers["dsh/guest"]?(FlutterMethodCall(methodName: method, arguments: arguments), result)
  }
}
public final class FlutterMethodChannel {
  private let name: String
  private let messenger: ContractMessenger
  public init(name: String, binaryMessenger: FlutterBinaryMessenger) {
    self.name = name; messenger = binaryMessenger as! ContractMessenger
  }
  public func setMethodCallHandler(_ handler: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?) {
    messenger.methodHandlers[name] = handler
  }
}
public final class FlutterEventChannel {
  public init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
  public func setStreamHandler(_ handler: FlutterStreamHandler?) {}
}
