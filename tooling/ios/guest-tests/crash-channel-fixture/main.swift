import Foundation
import Flutter
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}
private func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
  guard condition() else { throw CheckFailure(description: label) }
  print("PASS " + label)
}

// The native gate is tested separately with real subprocesses. This fake models
// its published contract to verify the production Flutter boundary.
private final class ContractKernel: GuestKernelAccess {
  private let lock = NSLock()
  let marker: URL
  var available = true
  var active = false
  var statusFailure = false
  var leased = false
  private(set) var statusReads = 0
  init(base: URL) { marker = base.appendingPathComponent("active-task") }
  func isSuspended(in directory: URL) throws -> Bool {
    lock.lock(); defer { lock.unlock() }
    statusReads += 1
    if statusFailure { throw GuestFailure("io", "Contract read failure.") }
    return !active && FileManager.default.fileExists(atPath: marker.path)
  }
  func resume(in directory: URL) throws {
    lock.lock(); defer { lock.unlock() }
    if active || leased { throw GuestFailure("busy", "Contract native gate is busy.") }
    if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
  }
  func reserveRootfsMutation() throws -> GuestRootfsLease {
    lock.lock(); defer { lock.unlock() }
    if active || leased { throw GuestFailure("busy", "Contract mutation gate is busy.") }
    leased = true
    return ContractLease { [self] in lock.lock(); leased = false; lock.unlock() }
  }
}
private final class ContractLease: GuestRootfsLease {
  private var end: (() -> Void)?
  init(_ end: @escaping () -> Void) { self.end = end }
  func release() { let action = end; end = nil; action?() }
  deinit { release() }
}

private func invoke(_ messenger: ContractMessenger, _ name: String, _ args: Any? = nil) throws -> Any? {
  let done = DispatchSemaphore(value: 0)
  var response: Any?
  DispatchQueue.main.async {
    messenger.invoke(name, arguments: args) { value in response = value; done.signal() }
  }
  guard done.wait(timeout: .now() + 90) == .success else {
    throw CheckFailure(description: "channel timed out: " + name)
  }
  return response
}
private func status(_ messenger: ContractMessenger, _ name: String = "status") throws -> [String: Any] {
  guard let value = try invoke(messenger, name) as? [String: Any] else {
    throw CheckFailure(description: "missing status: " + name)
  }
  return value
}
private func publishFixture(_ installer: GuestRootfsInstaller) throws {
  let files = FileManager.default
  try files.createDirectory(at: installer.root.appendingPathComponent("data"), withIntermediateDirectories: true)
  try Data().write(to: installer.root.appendingPathComponent("meta.db"))
  try JSONEncoder().encode(GuestInstalled.current).write(to: installer.root.appendingPathComponent("installed.json"))
}

@main struct CrashChannelContract {
  static func main() {
    // The production channel replies on DispatchQueue.main. Run assertions on
    // a worker and keep the main dispatcher alive, as the real app does.
    DispatchQueue.global().async {
      do { try run(); exit(0) }
      catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
    dispatchMain()
  }
  static func run() throws {
    let files = FileManager.default
    let support = files.temporaryDirectory.appendingPathComponent("dsh-guest-contract-" + UUID().uuidString)
    defer { try? files.removeItem(at: support) }
    let installer = GuestRootfsInstaller(base: support.appendingPathComponent("dsh-guest"))
    let kernel = ContractKernel(base: installer.base)
    let empty = GuestStartupState(installer: installer, kernel: kernel)
    try check(!empty.installed && !empty.suspended && !empty.available && kernel.statusReads == 0,
      "never-installed startup does not load the kernel")
    try publishFixture(installer)
    try Data("contract-owned-record\n".utf8).write(to: kernel.marker)
    let initial = GuestStartupState(installer: installer, kernel: kernel)
    try check(initial.installed && initial.suspended && !initial.available && initial.state == "suspended",
      "startup retains physical installation while suspending routing")
    let pausedSnapshot = initial.routingSnapshot
    try check(pausedSnapshot["installed"] as? Bool == false && pausedSnapshot["suspended"] as? Bool == true
      && (pausedSnapshot["metadata"] as? [String: Any])?["installed"] as? String == "present",
      "paused snapshot selects rejection owner while retaining installation metadata")
    let messenger = ContractMessenger()
    let channel = GuestChannel(messenger: messenger, kernel: kernel, support: .success(support))
    defer { withExtendedLifetime(channel) {} }
    var current = try status(messenger)
    try check(current["installed"] as? Bool == true && current["available"] as? Bool == true,
      "paused status preserves install capability")
    try check(current["suspended"] as? Bool == true && current["suspendedReason"] as? String == "crashed"
      && current["usable"] as? Bool == false, "paused status is explicit and unusable")
    let invalid = try invoke(messenger, "resume", ["force": true]) as? FlutterError
    try check(invalid?.code == "ios_guest_arguments", "resume rejects user-controlled reset arguments")
    kernel.active = true
    current = try status(messenger)
    try check(current["suspended"] as? Bool == false, "live owned marker is not reported as an earlier crash")
    let busy = try invoke(messenger, "resume") as? FlutterError
    try check(busy?.code == "ios_guest_busy" && files.fileExists(atPath: kernel.marker.path),
      "busy native gate cannot clear a live task record")
    kernel.active = false
    let lease = try kernel.reserveRootfsMutation()
    let installationBusy = try invoke(messenger, "resume") as? FlutterError
    try check(installationBusy?.code == "ios_guest_busy" && files.fileExists(atPath: kernel.marker.path),
      "resume cannot bypass an installation lease")
    lease.release()
    current = try status(messenger, "resume")
    try check(current["suspended"] as? Bool == false && current["suspendedReason"] is NSNull,
      "resume returns the updated persistent status")
    try check(initial.suspended && !initial.available, "resume cannot mutate the old startup snapshot")
    let restarted = GuestStartupState(installer: installer, kernel: kernel)
    try check(restarted.installed && !restarted.suspended && restarted.available,
      "only a new startup snapshot restores routing")
    kernel.statusFailure = true
    let unreadable = GuestStartupState(installer: installer, kernel: kernel)
    try check(unreadable.installed && !unreadable.available && unreadable.failure?.code == "ios_guest_io",
      "unreadable crash state fails closed without throwing from startup")
    let unreadableSnapshot = unreadable.routingSnapshot
    let roundTrip = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: unreadableSnapshot)) as! [String: Any]
    try check(roundTrip["installed"] as? Bool == false && roundTrip["suspended"] as? Bool == false
      && (roundTrip["metadata"] as? [String: Any])?["installed"] as? String == "present",
      "crash gate I/O error serializes a disabled guest owner so ordinary startup can continue")
    kernel.available = false
    kernel.statusFailure = false
    let unavailable = GuestStartupState(installer: installer, kernel: kernel)
    try check(unavailable.routingSnapshot["installed"] as? Bool == false && !unavailable.suspended,
      "missing native capability also disables the guest owner")
    kernel.available = true
    kernel.statusFailure = true
    current = try status(messenger)
    try check(current["usable"] as? Bool == false && (current["error"] as? [String: String])?["code"] == "ios_guest_io",
      "status exposes a read failure and disables use")
    kernel.statusFailure = false
    try Data("contract-owned-record\n".utf8).write(to: kernel.marker)
    current = try status(messenger, "install")
    try check(current["suspended"] as? Bool == true && files.fileExists(atPath: kernel.marker.path),
      "already-installed install does not clear suspension")
    current = try status(messenger, "uninstall")
    try check(current["installed"] as? Bool == false && current["suspended"] as? Bool == true
      && files.fileExists(atPath: kernel.marker.path), "uninstall preserves the crash record outside rootfs")
    let uninstalled = GuestStartupState(installer: installer, kernel: kernel)
    try check(!uninstalled.installed && uninstalled.suspended && uninstalled.state == "suspended",
      "uninstall cannot bypass a paused startup")
    if CommandLine.arguments.count == 2 {
      // The caller supplies the existing pinned archive; this test never downloads.
      let suppliedArchive = URL(fileURLWithPath: CommandLine.arguments[1])
      try GuestRootfsArchive.verify(suppliedArchive, cancel: GuestCancellation(), progress: { _, _, _ in })
      try files.copyItem(at: suppliedArchive, to: installer.base.appendingPathComponent("rootfs.tar.gz"))
      current = try status(messenger, "install")
      try check(current["installed"] as? Bool == true && current["suspended"] as? Bool == true
        && current["usable"] as? Bool == false && files.fileExists(atPath: kernel.marker.path),
        "verified archive installation also preserves suspension")
      _ = try status(messenger, "uninstall")
    } else {
      print("SKIP fresh archive install: pass the pinned Alpine archive to exercise extraction")
    }
    current = try status(messenger, "resume")
    try check(current["installed"] as? Bool == false && current["suspended"] as? Bool == false,
      "resume also works after uninstall")
    _ = try status(messenger, "resume")
    try check(!files.fileExists(atPath: kernel.marker.path), "resume is idempotent")
  }
}
