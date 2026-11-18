import XCTest
import UIKit
@testable import Runner

@MainActor
final class IOSPhoneApprovalTests: XCTestCase {
  private final class Visibility {
    var active = true
    var protectedData = true
  }
  private func descendants<T: UIView>(_ root: UIView, of type: T.Type) -> [T] {
    var result = (root as? T).map { [$0] } ?? []
    for child in root.subviews { result += descendants(child, of: type) }
    return result
  }
  private func preview() throws -> Data {
    let picture = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
      context.cgContext.setFillColor(UIColor.red.cgColor)
      context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    return try XCTUnwrap(picture.pngData())
  }
  private func sheet(_ center: NotificationCenter, _ state: Visibility, image: Data? = nil,
                     answer: @escaping (Bool) -> Void = { _ in }) -> IOSPhoneApproval {
    IOSPhoneApproval(heading: "Synthetic title", detail: "Synthetic input: alpha beta",
      allow: "permit", deny: "decline", preview: image, notifications: center,
      mayReveal: { state.active && state.protectedData }, answer: answer)
  }
  private func stack(_ sheet: IOSPhoneApproval) throws -> UIStackView {
    try XCTUnwrap(sheet.view.subviews.compactMap { $0 as? UIStackView }.first)
  }
  private func text(_ sheet: IOSPhoneApproval) throws -> UITextView {
    try XCTUnwrap(descendants(sheet.view, of: UITextView.self).first)
  }

  func testResignActiveSynchronouslyClearsTextAndPreview() throws {
    let center = NotificationCenter(), state = Visibility()
    let controller = sheet(center, state, image: try preview())
    controller.loadViewIfNeeded()
    let content = try stack(controller), detail = try text(controller)
    let title = try XCTUnwrap(content.arrangedSubviews.first as? UILabel)
    let picture = try XCTUnwrap(descendants(controller.view, of: UIImageView.self).first { $0.image != nil })
    XCTAssertFalse(content.isHidden)
    XCTAssertEqual(detail.text, "Synthetic input: alpha beta")
    XCTAssertNotNil(picture.image)
    // Keep the injected active query true: the notification must itself redact
    // synchronously, even before a separate state query catches up.
    center.post(name: UIApplication.willResignActiveNotification, object: nil)
    XCTAssertTrue(content.isHidden)
    XCTAssertTrue(controller.view.accessibilityElementsHidden)
    XCTAssertFalse(controller.view.isUserInteractionEnabled)
    XCTAssertNil(title.text)
    XCTAssertTrue(detail.text?.isEmpty ?? true)
    XCTAssertFalse(detail.isSelectable)
    XCTAssertNil(picture.image)
    controller.viewWillAppear(false)
    XCTAssertTrue(content.isHidden)
    XCTAssertTrue(detail.text?.isEmpty ?? true)
  }

  func testWillEnterForegroundDoesNotRevealAndActivationRestoresSameValues() throws {
    let center = NotificationCenter(), state = Visibility()
    var answers: [Bool] = []
    let controller = sheet(center, state, image: try preview()) { answers.append($0) }
    controller.loadViewIfNeeded()
    let detail = try text(controller), content = try stack(controller)
    let picture = try XCTUnwrap(descendants(controller.view, of: UIImageView.self).first { $0.image != nil })
    let original = picture.image
    state.active = false
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    XCTAssertTrue(content.isHidden)
    XCTAssertNil(picture.image)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(content.isHidden)
    state.active = true
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertFalse(content.isHidden)
    XCTAssertFalse(controller.view.accessibilityElementsHidden)
    XCTAssertTrue(controller.view.isUserInteractionEnabled)
    XCTAssertEqual(detail.text, "Synthetic input: alpha beta")
    XCTAssertTrue(detail.isSelectable)
    XCTAssertTrue(picture.image === original)
    XCTAssertTrue(answers.isEmpty)
  }

  func testLockedContentDoesNotReturnOnActivationAlone() throws {
    let center = NotificationCenter(), state = Visibility()
    let controller = sheet(center, state)
    controller.loadViewIfNeeded()
    state.protectedData = false
    center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(try stack(controller).isHidden)
    XCTAssertTrue(try text(controller).text?.isEmpty ?? true)
    state.protectedData = true
    center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    XCTAssertFalse(try stack(controller).isHidden)
    XCTAssertEqual(try text(controller).text, "Synthetic input: alpha beta")
  }

  func testInitiallyInactiveSheetContainsNoDisplayedInput() throws {
    let center = NotificationCenter(), state = Visibility()
    state.active = false
    let controller = sheet(center, state, image: try preview())
    controller.loadViewIfNeeded()
    XCTAssertTrue(try stack(controller).isHidden)
    XCTAssertTrue(try text(controller).text?.isEmpty ?? true)
    XCTAssertTrue(descendants(controller.view, of: UIImageView.self).allSatisfy { $0.image == nil })
    controller.viewDidAppear(false)
    XCTAssertTrue(try stack(controller).isHidden)
  }

  func testRedactedOrInactiveButtonsCannotAnswer() throws {
    let center = NotificationCenter(), state = Visibility()
    var answers: [Bool] = []
    let controller = sheet(center, state) { answers.append($0) }
    controller.loadViewIfNeeded()
    let buttons = descendants(controller.view, of: UIButton.self)
    let permit = try XCTUnwrap(buttons.first { $0.title(for: .normal) == "permit" })
    let decline = try XCTUnwrap(buttons.first { $0.title(for: .normal) == "decline" })
    center.post(name: UIApplication.willResignActiveNotification, object: nil)
    permit.sendActions(for: .touchUpInside)
    decline.sendActions(for: .touchUpInside)
    XCTAssertTrue(answers.isEmpty)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    state.active = false
    permit.sendActions(for: .touchUpInside)
    XCTAssertTrue(answers.isEmpty)
    XCTAssertTrue(try stack(controller).isHidden)
    state.active = true
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    permit.sendActions(for: .touchUpInside)
    XCTAssertEqual(answers, [true])
  }

  func testSceneNotificationsRedactAnUnattachedSheetWithoutAnswering() throws {
    let center = NotificationCenter(), state = Visibility()
    var answers: [Bool] = []
    let controller = sheet(center, state) { answers.append($0) }
    controller.loadViewIfNeeded()
    center.post(name: UIScene.willDeactivateNotification, object: nil)
    XCTAssertTrue(try stack(controller).isHidden)
    center.post(name: UIScene.didEnterBackgroundNotification, object: nil)
    XCTAssertTrue(try text(controller).text?.isEmpty ?? true)
    state.active = false
    center.post(name: UIScene.didActivateNotification, object: nil)
    XCTAssertTrue(try stack(controller).isHidden)
    state.active = true
    center.post(name: UIScene.didActivateNotification, object: nil)
    XCTAssertFalse(try stack(controller).isHidden)
    XCTAssertTrue(answers.isEmpty)
  }

  func testSelectorObserversDoNotRetainTheSheet() {
    let center = NotificationCenter(), state = Visibility()
    weak var previous: IOSPhoneApproval?
    autoreleasepool {
      let controller = sheet(center, state)
      controller.loadViewIfNeeded()
      previous = controller
    }
    XCTAssertNil(previous)
    center.post(name: UIApplication.willResignActiveNotification, object: nil)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  func testDeactivationBeforeViewLoadCannotBeOverriddenByAppearance() throws {
    let center = NotificationCenter(), state = Visibility()
    let controller = sheet(center, state, image: try preview())
    XCTAssertFalse(controller.isViewLoaded)
    center.post(name: UIApplication.willResignActiveNotification, object: nil)
    XCTAssertFalse(controller.isViewLoaded, "redaction must not create a hidden view hierarchy")
    controller.loadViewIfNeeded()
    controller.viewWillAppear(false)
    controller.viewDidAppear(false)
    XCTAssertTrue(try stack(controller).isHidden)
    XCTAssertTrue(try text(controller).text?.isEmpty ?? true)
    XCTAssertTrue(descendants(controller.view, of: UIImageView.self).allSatisfy { $0.image == nil })
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    XCTAssertTrue(try stack(controller).isHidden)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertFalse(try stack(controller).isHidden)
    XCTAssertEqual(try text(controller).text, "Synthetic input: alpha beta")
  }
}
