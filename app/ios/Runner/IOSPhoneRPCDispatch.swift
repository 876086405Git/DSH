import Foundation

enum IOSPhoneRPCDispatchError: Error {
  case notAdmitted
  case invalidated
}

/// The actual HTTP boundary rechecks live authorization immediately before
/// sending, while waiting, and before publishing a reply. Cancelling transport
/// is not an acknowledgement that a remote XCTest action was undone.
@MainActor
enum IOSPhoneRPCDispatch {
  typealias Send = @MainActor (URLRequest) async throws -> (Data, URLResponse)

  static func perform(_ request: URLRequest, permitted: @escaping () -> Bool,
                      send: @escaping Send) async throws -> (Data, URLResponse) {
    guard !Task.isCancelled, permitted() else { throw IOSPhoneRPCDispatchError.notAdmitted }
    let transfer = Task { @MainActor in
      // The task can start after this actor has processed another UI event.
      guard !Task.isCancelled, permitted() else { throw IOSPhoneRPCDispatchError.notAdmitted }
      return try await send(request)
    }
    let monitor = Task { @MainActor in
      while !Task.isCancelled {
        guard permitted() else { transfer.cancel(); return }
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
      }
    }
    defer { monitor.cancel() }
    let result = try await withTaskCancellationHandler(operation: {
      try await transfer.value
    }, onCancel: { transfer.cancel() })
    // Cancellation is sticky even if UI state subsequently becomes admissible
    // again, or an injected/remote transport ignores cancellation and replies.
    guard !Task.isCancelled, !transfer.isCancelled, permitted() else { throw IOSPhoneRPCDispatchError.invalidated }
    return result
  }
}
