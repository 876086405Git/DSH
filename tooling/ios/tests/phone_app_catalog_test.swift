import Foundation

@main
enum AppCatalogTests {
  static func main() {
    precondition(PhoneRunnerAppCatalog.bundleID(for: "设置") == "com.apple.Preferences")
    precondition(PhoneRunnerAppCatalog.bundleID(for: "系统设置") == "com.apple.Preferences")
    precondition(PhoneRunnerAppCatalog.bundleID(for: "System Settings") == "com.apple.Preferences")
    precondition(PhoneRunnerAppCatalog.bundleID(for: " Settings ") == "com.apple.Preferences")
    precondition(PhoneRunnerAppCatalog.bundleID(for: "com.apple.Preferences") == "com.apple.Preferences")
    let catalog = [["name": "购物应用", "id": "com.example.shop"]]
    precondition(PhoneRunnerAppCatalog.bundleID(for: "购物应用", apps: catalog) == "com.example.shop")
    precondition(PhoneRunnerAppCatalog.bundleID(for: "购物", apps: catalog) == nil)
    precondition(PhoneRunnerAppCatalog.bundleID(for: "不存在的应用", apps: catalog) == nil)
    precondition(PhoneRunnerAppCatalog.bundleID(for: "com.example/app") == nil)
    print("9 app-name resolution checks passed")
  }
}
