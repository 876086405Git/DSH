// Runs the production Foundation installer on the CI Mac, before simulator boot.
// The resulting fakefs is consumed unchanged by the real iSH kernel.
import Foundation
@main struct GuestInstallFixture {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else { fatalError("guest-install <fixed archive> <new private base>") }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let base = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    let token = GuestCancellation()
    try GuestRootfsArchive.verify(source, cancel: token) { _, _, _ in }
    try FileManager.default.copyItem(at: source, to: base.appendingPathComponent("rootfs.tar.gz"))
    let installer = GuestRootfsInstaller(base: base)
    try installer.install(cancel: token) { _, _, _ in }
    guard try installer.installed() else { fatalError("installer did not publish rootfs") }
    print(installer.root.path)
  }
}
