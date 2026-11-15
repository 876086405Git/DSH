import CoreGraphics
import ImageIO
import UIKit

/// The exact bundled PNG cells, not a re-created mascot. At most two decoded
/// sheets are kept; a pack is never fully decoded. All methods are main-thread
/// confined by IOSPetOverlay (the simulator capture fixture uses them likewise).
final class PetOverlayFrameRenderer {
  typealias AssetURL = (String) -> URL?
  private let assetURL: AssetURL
  private var sheets: [String: CGImage] = [:]
  private var recency: [String] = []
  private(set) var pack: PetOverlayPack?

  init(assetURL: @escaping AssetURL) { self.assetURL = assetURL }

  func load(packID: String) throws -> PetOverlayPack {
    if let pack, pack.id == packID { return pack }
    guard PetOverlayState.safeAssetComponent(packID),
      let url = assetURL("assets/pets/\(packID)/pack.json") else {
      throw PetOverlayPackFailure("overlay_pack_missing")
    }
    let parsed = try PetOverlayPack(data: Data(contentsOf: url), expectedID: packID)
    // Decode before replacing the old pack, so a malformed/missing first sheet
    // cannot leave an apparently usable, empty video source.
    let idle = parsed.primary(state: "idle", tier: 0)
    _ = try sheet(pack: parsed, animation: idle)
    pack = parsed
    return parsed
  }

  func clear() {
    pack = nil
    sheets.removeAll()
    recency.removeAll()
  }

  func render(state: PetOverlayState, frame: PetOverlayFrameSelection,
    phoneTask: PetOverlayPhoneTask?, paused: Bool, nowMilliseconds: Double,
    size: CGSize = CGSize(width: 480, height: 318), dark: Bool = false) throws -> CGImage {
    guard let pack, pack.id == state.packID, frame.animation.frames.indices.contains(frame.index),
      size.width >= 160, size.height >= 106, size.width <= 960, size.height <= 640 else {
      throw PetOverlayPackFailure("overlay_render_invalid")
    }
    let animation = frame.animation, cell = animation.frames[frame.index].cell
    let image = try sheet(pack: pack, animation: animation)
    let source = animation.sourceRect(cell: cell)
    guard let cropped = image.cropping(to: CGRect(x: source.x, y: source.y,
      width: source.width, height: source.height)) else { throw PetOverlayPackFailure() }
    let density = Double(size.width / 160)
    let margin = max(8, size.width / 60)
    let footerHeight: CGFloat = phoneTask?.line == nil && phoneTask?.progress == nil ? 0 : 22 * size.width / 480
    let headerHeight = CGFloat(30 * density / 3)
    let reach = visibleReach(pack)
    var k = pack.artScale(size: state.size, deviceScale: density)
    let fit = min(Double(size.width - 2 * margin) / reach.width,
      Double(size.height - 2 * margin - headerHeight - footerHeight) / reach.height)
    k = min(k, fit)
    if pack.pixelArt { k = max(1, floor(k)) }
    guard k > 0, reach.width * k <= Double(size.width - margin),
      reach.height * k <= Double(size.height - headerHeight - footerHeight) else {
      throw PetOverlayPackFailure("overlay_render_too_small")
    }
    // Stable anchor/baseline across animation changes. The reach includes every
    // state/tier/idle frame, so clouds, notes, shadows and jumps remain visible.
    let originX = (Double(size.width) / 2 - pack.anchorX * k).rounded()
    let belowFoot = max(0, reach.bottom - pack.baseline) * k
    let footY = Double(size.height - margin - footerHeight) - belowFoot
    let originY = (footY - pack.baseline * k).rounded()
    let box = animation.box
    let destination = CGRect(x: originX + box.x * k, y: originY + box.y * k,
      width: box.width * k, height: box.height * k)
    let actualTop = CGFloat(originY + min(pack.contentBox.y, box.y) * k)
    let title = paused ? Self.pausedLine : state.visibleBubble(at: nowMilliseconds)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    format.preferredRange = .standard
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
      let background = dark ? UIColor(red: 0.07, green: 0.10, blue: 0.14, alpha: 1)
        : UIColor(red: 0.94, green: 0.97, blue: 0.98, alpha: 1)
      background.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      let cg = context.cgContext
      // PetSprite's current painter uses nearest-neighbour for pixelArt,
      // including the lossless 5x Deepy sheets; no tint, outline or mirroring.
      cg.interpolationQuality = pack.pixelArt ? .none : .medium
      cg.setShouldAntialias(false)
      UIImage(cgImage: cropped).draw(in: destination)
      cg.setShouldAntialias(true)
      if let title {
        let bubbleHeight = min(headerHeight, max(24, actualTop - margin - 8))
        let rect = CGRect(x: margin, y: max(margin, actualTop - bubbleHeight - 8),
          width: size.width - 2 * margin, height: bubbleHeight)
        (dark ? UIColor(white: 0.19, alpha: 1) : UIColor.white).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 12 * size.width / 480).fill()
        draw(title, in: rect.insetBy(dx: 10, dy: 4), size: 18 * size.width / 480,
          color: dark ? .white : UIColor(white: 0.16, alpha: 1), weight: .medium)
      }
      if !state.quiet, let line = phoneTask?.line {
        draw(line, in: CGRect(x: margin, y: size.height - footerHeight - 2,
          width: size.width - 2 * margin, height: 18 * size.width / 480),
          size: 15 * size.width / 480,
          color: dark ? UIColor(white: 0.82, alpha: 1) : UIColor(white: 0.30, alpha: 1), weight: .regular)
      }
      if let progress = phoneTask?.progress {
        let track = CGRect(x: margin, y: size.height - 7, width: size.width - 2 * margin, height: 3)
        UIColor(white: dark ? 0.28 : 0.83, alpha: 1).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: 1.5).fill()
        UIColor(red: 0.12, green: 0.48, blue: 0.62, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY,
          width: track.width * CGFloat(progress), height: track.height), cornerRadius: 1.5).fill()
      }
    }
    guard let result = rendered.cgImage else { throw PetOverlayPackFailure("overlay_render_failed") }
    return result
  }

  private func visibleReach(_ pack: PetOverlayPack) -> PetOverlayBox {
    var names = Set(pack.states.filter { PetOverlayState.names.contains($0.key) }.flatMap { $0.value })
    for list in pack.tiers.values { names.formUnion(list.map { $0.animation }) }
    names.formUnion(pack.idlePool.map { $0.animation })
    for value in pack.bonus.values { names.formUnion(value.animations) }
    return names.compactMap { pack.animations[$0]?.box }.reduce(pack.contentBox) { $0.union($1) }
  }

  private func sheet(pack: PetOverlayPack, animation: PetOverlayAnimation) throws -> CGImage {
    let key = "\(pack.id)/\(animation.sheet)"
    if let cached = sheets[key] { touch(key); return cached }
    guard let url = assetURL("assets/pets/\(key)"),
      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      (1...4096).contains(width), (1...4096).contains(height),
      width % animation.frameWidth == 0, height % animation.frameHeight == 0,
      width / animation.frameWidth == animation.columns,
      animation.frames.allSatisfy({ frame in
        let box = animation.sourceRect(cell: frame.cell)
        return box.right <= Double(width) && box.bottom <= Double(height)
      }),
      let image = CGImageSourceCreateImageAtIndex(source, 0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
      throw PetOverlayPackFailure("overlay_sheet_invalid")
    }
    sheets[key] = image
    touch(key)
    while recency.count > 2 { sheets.removeValue(forKey: recency.removeFirst()) }
    return image
  }

  private func touch(_ key: String) {
    recency.removeAll { $0 == key }
    recency.append(key)
  }

  private func draw(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor,
    weight: UIFont.Weight) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
      attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
  }

  private static var pausedLine: String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true
      ? "已暂停 · 返回 DSH Go 继续或停止" : "Paused · Return to DSH Go to continue or stop"
  }
}
