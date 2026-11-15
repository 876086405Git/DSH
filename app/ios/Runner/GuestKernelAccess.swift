// Apple SDK compilation and device execution have not been verified.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Resolves only the signed, bundled kernel. The handle deliberately lives for
/// the process lifetime: kernel threads and callbacks can outlive a Flutter view.
final class NativeGuestKernelAccess: GuestKernelAccess {
  static let shared = NativeGuestKernelAccess()
  private typealias Status = @convention(c) () -> Int32
  private typealias End = @convention(c) () -> Void
  private typealias CrashStatus = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> Int32
  private typealias CrashResume = @convention(c) (UnsafePointer<CChar>?) -> Int32
  private struct Symbols {
    let handle: UnsafeMutableRawPointer?
    let status: Status?
    let begin: Status?
    let end: End?
    let crashStatus: CrashStatus?
    let crashResume: CrashResume?
  }
  private let loadLock = NSLock()
  private var loaded: Symbols?

  private init() {}

  // Registering the Flutter channel does not map iSH into memory. Resolve on
  // the first explicit capability/install request or installed-engine start.
  private func symbols() -> Symbols {
    loadLock.lock()
    defer { loadLock.unlock() }
    if let loaded { return loaded }
    let path = Bundle.main.privateFrameworksPath.map { $0 + "/DshGuest.framework/DshGuest" }
    let handle = path.flatMap { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
    let value: Symbols
    if let handle,
       let statusSymbol = dlsym(handle, "dsh_guest_status"),
       let beginSymbol = dlsym(handle, "dsh_guest_begin_install_change"),
       let endSymbol = dlsym(handle, "dsh_guest_end_install_change"),
       let crashStatusSymbol = dlsym(handle, "dsh_guest_crash_status"),
       let crashResumeSymbol = dlsym(handle, "dsh_guest_crash_resume") {
      value = Symbols(handle: handle, status: unsafeBitCast(statusSymbol, to: Status.self),
        begin: unsafeBitCast(beginSymbol, to: Status.self), end: unsafeBitCast(endSymbol, to: End.self),
        crashStatus: unsafeBitCast(crashStatusSymbol, to: CrashStatus.self),
        crashResume: unsafeBitCast(crashResumeSymbol, to: CrashResume.self))
    } else { value = Symbols(handle: handle, status: nil, begin: nil, end: nil, crashStatus: nil, crashResume: nil) }
    loaded = value
    return value
  }

  var available: Bool {
    let value = symbols()
    guard let status = value.status, value.begin != nil, value.end != nil else { return false }
    // COLD, READY and RUNNING expose the capability; QUARANTINED cannot run.
    return (0...2).contains(status())
  }

  func isSuspended(in directory: URL) throws -> Bool {
    guard let query = symbols().crashStatus else {
      throw GuestFailure("unavailable", "The Linux crash gate is unavailable in this build.")
    }
    var suspended: Int32 = 0
    let result = directory.path.withCString { query($0, &suspended) }
    guard result == 0 else { throw crashFailure(result, "Cannot inspect the Linux crash record.") }
    return suspended != 0
  }

  func resume(in directory: URL) throws {
    guard let resume = symbols().crashResume else {
      throw GuestFailure("unavailable", "The Linux crash gate is unavailable in this build.")
    }
    // Swift never deletes the record itself. The native lock excludes active
    // and settling tasks, quarantine, and installation changes from this reset.
    let result = directory.path.withCString { resume($0) }
    guard result == 0 else { throw crashFailure(result, "Cannot clear the Linux crash record.") }
  }

  private func crashFailure(_ code: Int32, _ message: String) -> GuestFailure {
    if code == EBUSY {
      return GuestFailure("busy", "Linux is in use; retry after it stops, or restart the app if its kernel failed.")
    }
    return GuestFailure(code == ENOSPC ? "no_space" : "io", message)
  }

  func reserveRootfsMutation() throws -> GuestRootfsLease {
    let value = symbols()
    guard let status = value.status, let begin = value.begin, let end = value.end else {
      throw GuestFailure("unavailable", "The Linux backend is unavailable in this build.")
    }
    // The native gate, not this status observation, admits the mutation atomically.
    guard begin() == 0 else {
      if status() != 0 {
        throw GuestFailure("restart_required", "Restart the app before changing the Linux installation; its kernel has already started.")
      }
      throw GuestFailure("busy", "The Linux installation is in use; retry after the current operation finishes.")
    }
    return NativeGuestRootfsLease(end: end)
  }
}

/// Value-only routing state for one engine generation. Clearing the persistent
/// record cannot change an already published snapshot.
struct GuestStartupState {
  let installed: Bool
  let suspended: Bool
  let available: Bool
  let failure: GuestFailure?
  var state: String { suspended ? "suspended" : available ? "ready" : "unavailable" }
  var routingSnapshot: [String: Any] {
    // Keep the legacy top-level flag as admission, not physical installation.
    // Metadata and the Flutter status expose the actual image state. A failed
    // crash probe must not make preload open a guest bridge or stop the engine.
    ["installed": available, "suspended": suspended,
     "suspendedReason": suspended ? "crashed" as Any : NSNull(),
     "metadata": ["v": 1, "source": "ios-native-owner", "state": state,
                  "installed": installed ? "present" : "absent", "available": available,
                  "enforcement": "partial", "python": "unknown"]]
  }

  init(installer: GuestRootfsInstaller, kernel: GuestKernelAccess) {
    var installed = false
    var suspended = false
    var crashGateKnown = false
    var failure: GuestFailure?
    do { installed = try installer.installed() }
    catch { failure = guestFailure(error) }
    // Absence is only a no-record optimization, never a capability probe. There
    // is no reason to load the optional framework for a never-installed guest.
    if installed || FileManager.default.fileExists(atPath: installer.base.path) {
      do {
        suspended = try kernel.isSuspended(in: installer.base)
        crashGateKnown = true
      } catch { if failure == nil { failure = guestFailure(error) } }
    }
    self.installed = installed
    self.suspended = suspended
    self.available = installed && crashGateKnown && !suspended && kernel.available
    self.failure = failure
  }
}

private final class NativeGuestRootfsLease: GuestRootfsLease {
  private let lock = NSLock()
  private var end: (@convention(c) () -> Void)?
  init(end: @escaping @convention(c) () -> Void) { self.end = end }
  func release() {
    lock.lock()
    let action = end
    end = nil
    // Keep release linearized: a second caller cannot return before the native
    // gate has been released by the first caller.
    action?()
    lock.unlock()
  }
  deinit { release() }
}
