import Foundation
import XCTest
@testable import Runner

/// Drives the production HTTP admission/cancellation boundary with synthetic
/// bytes and an injected transport. No URLSession, socket, device, or approval UI
/// is used. A cancellation notification is evidence about the local transport
/// task only; it cannot prove that a remote action was undone.
@MainActor
final class IOSPhoneRPCDispatchTests: XCTestCase {
  private typealias Reply = (Data, URLResponse)

  private enum SyntheticFailure: Error {
    case transport
    case cleanup
    case repeatedSend
  }

  @MainActor
  private final class Gate {
    var allowed = true
  }

  @MainActor
  private final class RunningCall {
    let finished: XCTestExpectation
    private(set) var result: Result<Reply, Error>?
    private var task: Task<Void, Never>?

    init(request: URLRequest, permitted: @escaping () -> Bool,
         send: @escaping IOSPhoneRPCDispatch.Send, finished: XCTestExpectation) {
      self.finished = finished
      task = Task { @MainActor [self] in
        do {
          result = .success(try await IOSPhoneRPCDispatch.perform(
            request, permitted: permitted, send: send))
        } catch {
          result = .failure(error)
        }
        finished.fulfill()
      }
    }

    func cancel() { task?.cancel() }
  }

  /// The continuation is installed before `entered` is fulfilled. Cancellation
  /// is reported by the actual task cancellation handler, then delivered to the
  /// main actor; tests never infer it from an elapsed delay. A test explicitly
  /// chooses whether cancellation throws or a cancellation-ignoring transport
  /// returns an otherwise valid reply.
  @MainActor
  private final class ControlledTransport {
    let entered: XCTestExpectation
    let cancellation: XCTestExpectation
    private(set) var requests: [URLRequest] = []
    private(set) var cancellationCount = 0
    var onCancellation: ((ControlledTransport) -> Void)?
    private var continuation: CheckedContinuation<Reply, Error>?
    private var outcome: Result<Reply, Error>?

    init(entered: XCTestExpectation, cancellation: XCTestExpectation) {
      self.entered = entered
      self.cancellation = cancellation
    }

    func send(_ request: URLRequest) async throws -> Reply {
      requests.append(request)
      guard requests.count == 1 else { throw SyntheticFailure.repeatedSend }
      return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
          self.continuation = continuation
          entered.fulfill()
          if let outcome {
            self.continuation = nil
            continuation.resume(with: outcome)
          }
        }
      }, onCancel: {
        Task { @MainActor [self] in
          cancellationCount += 1
          cancellation.fulfill()
          onCancellation?(self)
        }
      })
    }

    func finishIfPending(_ result: Result<Reply, Error>) {
      guard outcome == nil else { return }
      outcome = result
      if let continuation {
        self.continuation = nil
        continuation.resume(with: result)
      }
    }

    func cleanUp() {
      onCancellation = nil
      finishIfPending(.failure(SyntheticFailure.cleanup))
    }
  }

  private func request() -> URLRequest {
    // The reserved invalid domain is never accessed: every send is injected.
    var request = URLRequest(url: URL(string: "https://example.invalid/phone-rpc")!)
    request.httpMethod = "POST"
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue("synthetic-request-42", forHTTPHeaderField: "X-Request-ID")
    request.httpBody = Data("{\"id\":\"synthetic\",\"text\":\"中文🙂 é\",\"replace\":true}".utf8)
    return request
  }

  private func reply() -> Reply {
    let bytes = Data([0x00, 0x01, 0x7f, 0x80, 0xff]) + Data("synthetic 中文🙂".utf8)
    let response = HTTPURLResponse(url: URL(string: "https://example.invalid/phone-rpc")!,
      statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/octet-stream"])!
    return (bytes, response)
  }

  private func call(_ request: URLRequest, permitted: @escaping () -> Bool,
                    send: @escaping IOSPhoneRPCDispatch.Send) -> RunningCall {
    let finished = expectation(description: "dispatch settled")
    finished.assertForOverFulfill = true
    return RunningCall(request: request, permitted: permitted, send: send, finished: finished)
  }

  private func transport() -> ControlledTransport {
    let entered = expectation(description: "injected send entered")
    let cancelled = expectation(description: "injected send observed task cancellation")
    entered.assertForOverFulfill = true
    cancelled.assertForOverFulfill = true
    return ControlledTransport(entered: entered, cancellation: cancelled)
  }

  private func assertDispatchError(_ expected: IOSPhoneRPCDispatchError,
                                   in operation: RunningCall,
                                   file: StaticString = #filePath, line: UInt = #line) {
    guard case let .failure(error)? = operation.result,
          let actual = error as? IOSPhoneRPCDispatchError else {
      XCTFail("expected a dispatch rejection, never a published reply", file: file, line: line)
      return
    }
    switch (expected, actual) {
    case (.notAdmitted, .notAdmitted), (.invalidated, .invalidated): break
    default: XCTFail("wrong dispatch rejection category", file: file, line: line)
    }
  }

  func testInitiallyDeniedRequestNeverReachesTransport() async {
    var sends = 0
    var checks = 0
    let response = reply()
    let operation = call(request(), permitted: { checks += 1; return false }, send: { _ in
      sends += 1
      return response
    })
    defer { operation.cancel() }
    await fulfillment(of: [operation.finished], timeout: 5)
    assertDispatchError(.notAdmitted, in: operation)
    XCTAssertEqual(checks, 1)
    XCTAssertEqual(sends, 0)
  }

  func testParentCancelledBeforeAdmissionNeverReachesTransport() async {
    var sends = 0
    let response = reply()
    let operation = call(request(), permitted: { true }, send: { _ in
      sends += 1
      return response
    })
    // No await occurs between task creation and cancellation on this actor.
    operation.cancel()
    await fulfillment(of: [operation.finished], timeout: 5)
    assertDispatchError(.notAdmitted, in: operation)
    XCTAssertEqual(sends, 0)
  }

  func testQueuedTransferRechecksAfterInitialAdmissionAndSendsNothing() async {
    let gate = Gate()
    var decisions: [Bool] = []
    var sends = 0
    let response = reply()
    let operation = call(request(), permitted: {
      let decision = gate.allowed
      decisions.append(decision)
      if decisions.count == 1 { gate.allowed = false }
      // The first guard receives its already-captured true decision while the
      // queued transfer will see a revoked gate. This injects the boundary
      // deterministically without assuming any MainActor task ordering.
      return decision
    }, send: { _ in
      sends += 1
      return response
    })
    defer { operation.cancel() }
    await fulfillment(of: [operation.finished], timeout: 5)
    assertDispatchError(.notAdmitted, in: operation)
    XCTAssertEqual(decisions.first, true)
    XCTAssertTrue(decisions.dropFirst().contains(false))
    XCTAssertFalse(gate.allowed)
    XCTAssertEqual(sends, 0)
  }

  func testRevocationWhileWaitingCancelsTransportAndPublishesNoReply() async {
    let gate = Gate()
    let transport = transport()
    let operation = call(request(), permitted: { gate.allowed }, send: { request in
      try await transport.send(request)
    })
    defer { operation.cancel(); transport.cleanUp() }
    await fulfillment(of: [transport.entered], timeout: 5)
    XCTAssertEqual(transport.requests.count, 1)
    gate.allowed = false

    // This waits for the monitor's actual cancellation, not for a guessed
    // number of 50 ms polling intervals.
    await fulfillment(of: [transport.cancellation], timeout: 5)
    XCTAssertEqual(transport.cancellationCount, 1)
    transport.finishIfPending(.failure(CancellationError()))
    await fulfillment(of: [operation.finished], timeout: 5)
    guard case let .failure(error)? = operation.result else {
      XCTFail("revoked transfer must not publish a reply")
      return
    }
    XCTAssertTrue(error is CancellationError)
    XCTAssertEqual(transport.requests.count, 1)
  }

  func testPermissionRevokedByReplyBoundaryCannotPublishSuccessfulTransport() async {
    let gate = Gate()
    var sends = 0
    let response = reply()
    let operation = call(request(), permitted: { gate.allowed }, send: { _ in
      sends += 1
      gate.allowed = false
      return response
    })
    defer { operation.cancel() }
    await fulfillment(of: [operation.finished], timeout: 5)
    assertDispatchError(.invalidated, in: operation)
    XCTAssertEqual(sends, 1)
    XCTAssertFalse(gate.allowed)
  }

  func testCancelledTransferCannotReviveWhenTransportRestoresPermissionAndReplies() async {
    let gate = Gate()
    let transport = transport()
    let response = reply()
    transport.onCancellation = { transport in
      // A transport may swallow cancellation and complete successfully. The
      // transient false permission must remain sticky for this exact transfer.
      gate.allowed = true
      transport.finishIfPending(.success(response))
    }
    let operation = call(request(), permitted: { gate.allowed }, send: { request in
      try await transport.send(request)
    })
    defer { operation.cancel(); transport.cleanUp() }
    await fulfillment(of: [transport.entered], timeout: 5)
    gate.allowed = false
    await fulfillment(of: [transport.cancellation, operation.finished], timeout: 5)
    XCTAssertTrue(gate.allowed)
    XCTAssertEqual(transport.cancellationCount, 1)
    assertDispatchError(.invalidated, in: operation)
    XCTAssertEqual(transport.requests.count, 1)
  }

  func testParentCancellationPropagatesEvenIfTransportIgnoresItAndReplies() async {
    let gate = Gate()
    let transport = transport()
    let response = reply()
    transport.onCancellation = { transport in
      transport.finishIfPending(.success(response))
    }
    let operation = call(request(), permitted: { gate.allowed }, send: { request in
      try await transport.send(request)
    })
    defer { operation.cancel(); transport.cleanUp() }
    await fulfillment(of: [transport.entered], timeout: 5)
    operation.cancel()
    await fulfillment(of: [transport.cancellation, operation.finished], timeout: 5)
    XCTAssertTrue(gate.allowed)
    XCTAssertEqual(transport.cancellationCount, 1)
    assertDispatchError(.invalidated, in: operation)
    XCTAssertEqual(transport.requests.count, 1)
  }

  func testSuccessSendsCompleteRequestExactlyOnceAndReturnsExactReply() async throws {
    let expectedRequest = request()
    let expectedReply = reply()
    var requests: [URLRequest] = []
    let operation = call(expectedRequest, permitted: { true }, send: { request in
      requests.append(request)
      return expectedReply
    })
    defer { operation.cancel() }
    await fulfillment(of: [operation.finished], timeout: 5)
    XCTAssertEqual(requests.count, 1)
    let sent = try XCTUnwrap(requests.first)
    XCTAssertEqual(sent.url, expectedRequest.url)
    XCTAssertEqual(sent.httpMethod, "POST")
    XCTAssertEqual(sent.httpBody, expectedRequest.httpBody)
    XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"),
                   expectedRequest.value(forHTTPHeaderField: "Content-Type"))
    XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Request-ID"), "synthetic-request-42")
    guard case let .success(actual)? = operation.result else {
      XCTFail("admitted transport response was not returned")
      return
    }
    XCTAssertEqual(actual.0, expectedReply.0)
    XCTAssertTrue(actual.1 === expectedReply.1)
  }

  func testTransportFailureIsPropagatedWithoutReplay() async {
    var sends = 0
    let operation = call(request(), permitted: { true }, send: { _ in
      sends += 1
      throw SyntheticFailure.transport
    })
    defer { operation.cancel() }
    await fulfillment(of: [operation.finished], timeout: 5)
    guard case let .failure(error)? = operation.result,
          let synthetic = error as? SyntheticFailure,
          case .transport = synthetic else {
      XCTFail("transport failure must propagate without a reply or retry")
      return
    }
    XCTAssertEqual(sends, 1)
  }
}
