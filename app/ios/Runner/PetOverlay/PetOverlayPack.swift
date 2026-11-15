import Foundation
import CoreFoundation

struct PetOverlayPackFailure: Error {
  let code: String
  init(_ code: String = "overlay_pack_invalid") { self.code = code }
}

struct PetOverlayBox: Equatable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  var right: Double { x + width }
  var bottom: Double { y + height }

  func union(_ other: PetOverlayBox) -> PetOverlayBox {
    let left = min(x, other.x), top = min(y, other.y)
    return PetOverlayBox(x: left, y: top, width: max(right, other.right) - left,
      height: max(bottom, other.bottom) - top)
  }
}

struct PetOverlayFrame: Equatable {
  let cell: Int
  let milliseconds: Int
}

struct PetOverlayAnimation {
  let name: String
  let sheet: String
  let frameWidth: Int
  let frameHeight: Int
  let columns: Int
  let box: PetOverlayBox
  let frames: [PetOverlayFrame]
  let loops: Bool
  var duration: Int { frames.reduce(0) { $0 + $1.milliseconds } }

  func sourceRect(cell: Int) -> PetOverlayBox {
    PetOverlayBox(x: Double((cell % columns) * frameWidth),
      y: Double((cell / columns) * frameHeight),
      width: Double(frameWidth), height: Double(frameHeight))
  }

  // Same row-major cells, per-frame milliseconds, repeated-cell timing and
  // final-frame hold as PetSprite/FrameClock. No fixed-fps approximation.
  func frameIndex(at elapsedMilliseconds: Int) -> Int {
    let total = duration, elapsed = max(0, elapsedMilliseconds)
    if !loops && elapsed >= total { return frames.count - 1 }
    var remaining = elapsed % total
    for (index, frame) in frames.enumerated() {
      if remaining < frame.milliseconds { return index }
      remaining -= frame.milliseconds
    }
    return frames.count - 1
  }

  func nextChange(after elapsedMilliseconds: Int) -> Int? {
    let total = duration, elapsed = max(0, elapsedMilliseconds)
    guard loops || elapsed < total else { return nil }
    let current = frameIndex(at: elapsed), currentCell = frames[frameIndex(at: elapsed)].cell
    var boundary = elapsed / total * total
    for index in 0...current { boundary += frames[index].milliseconds }
    var next = current + 1
    for _ in frames.indices {
      if next == frames.count {
        guard loops else { return nil }
        next = 0
      }
      if frames[next].cell != currentCell { return boundary - elapsed }
      boundary += frames[next].milliseconds
      next += 1
    }
    return nil // A single-cell loop needs no redraw timer.
  }
}

struct PetOverlayTier { let minimum: Int; let animation: String }
struct PetOverlayIdle { let animation: String; let milliseconds: Int; let weight: Double }
struct PetOverlayBonus { let animations: [String]; let chance: Double }

struct PetOverlayPack {
  let id: String
  let pixelArt: Bool
  let scale: Int
  let canvasWidth: Double
  let canvasHeight: Double
  let anchorX: Double
  let baseline: Double
  let contentBox: PetOverlayBox
  let animations: [String: PetOverlayAnimation]
  let states: [String: [String]]
  let tiers: [String: [PetOverlayTier]]
  let idlePool: [PetOverlayIdle]
  let bonus: [String: PetOverlayBonus]

  init(data: Data, expectedID: String) throws {
    guard data.count <= 1_048_576,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Self.integer(json["schema"]) == 1,
      let id = json["id"] as? String, id == expectedID, PetOverlayState.safeAssetComponent(id),
      let canvas = json["canvas"] as? [String: Any],
      let width = Self.number(canvas["w"]), let height = Self.number(canvas["h"]),
      width > 0, height > 0, width <= 512, height <= 512,
      let scale = Self.integer(json["scale"]), (1...16).contains(scale),
      let content = Self.box(json["contentBox"]),
      let rawAnimations = json["animations"] as? [String: Any],
      !rawAnimations.isEmpty, rawAnimations.count <= 128 else { throw PetOverlayPackFailure() }
    var animations: [String: PetOverlayAnimation] = [:]
    for (name, raw) in rawAnimations {
      guard PetOverlayState.safeAssetComponent(name), let value = raw as? [String: Any],
        let sheet = value["sheet"] as? String,
        sheet.hasSuffix(".png"), PetOverlayState.safeAssetComponent(String(sheet.dropLast(4))),
        let frameWidth = Self.integer(value["frameW"]), (1...4096).contains(frameWidth),
        let frameHeight = Self.integer(value["frameH"]), (1...4096).contains(frameHeight),
        let columns = Self.integer(value["cols"]), (1...4096).contains(columns),
        let box = Self.box(value["box"]),
        abs(box.width * Double(scale) - Double(frameWidth)) < 0.000_001,
        abs(box.height * Double(scale) - Double(frameHeight)) < 0.000_001,
        let rawFrames = value["frames"] as? [[String: Any]],
        !rawFrames.isEmpty, rawFrames.count <= 10_000 else { throw PetOverlayPackFailure() }
      let frames = try rawFrames.map { frame -> PetOverlayFrame in
        guard let cell = Self.integer(frame["i"]), (0...1_000_000).contains(cell),
          let ms = Self.integer(frame["ms"]), (1...60_000).contains(ms) else { throw PetOverlayPackFailure() }
        return PetOverlayFrame(cell: cell, milliseconds: ms)
      }
      guard frames.reduce(0, { $0 + $1.milliseconds }) <= 86_400_000 else { throw PetOverlayPackFailure() }
      animations[name] = PetOverlayAnimation(name: name, sheet: sheet, frameWidth: frameWidth,
        frameHeight: frameHeight, columns: columns, box: box, frames: frames,
        loops: value["loop"] as? Bool != false)
    }
    func reference(_ value: Any?) throws -> String {
      guard let name = value as? String, animations[name] != nil else { throw PetOverlayPackFailure() }
      return name
    }
    var states: [String: [String]] = [:]
    for (name, raw) in json["states"] as? [String: Any] ?? [:] {
      guard let names = raw as? [Any] else { throw PetOverlayPackFailure() }
      if !names.isEmpty { states[name] = try names.map(reference) }
    }
    guard states["idle"]?.first != nil else { throw PetOverlayPackFailure() }
    var tiers: [String: [PetOverlayTier]] = [:]
    for (name, raw) in json["tiers"] as? [String: Any] ?? [:] {
      guard let values = raw as? [[String: Any]] else { throw PetOverlayPackFailure() }
      tiers[name] = try values.map {
        PetOverlayTier(minimum: Self.integer($0["min"]) ?? 1, animation: try reference($0["anim"]))
      }.sorted { $0.minimum > $1.minimum }
    }
    let rawPool = (json["idlePool"] as? [String: Any])?["anims"] ?? json["idlePool"]
    let pool: [PetOverlayIdle] = try (rawPool as? [[String: Any]] ?? []).map {
      let name = try reference($0["anim"])
      return PetOverlayIdle(animation: name,
        milliseconds: max(1, Self.integer($0["ms"]) ?? animations[name]!.duration),
        weight: min(1000, max(0, Self.number($0["weight"]) ?? 1)))
    }
    var bonus: [String: PetOverlayBonus] = [:]
    for (name, raw) in json["bonus"] as? [String: Any] ?? [:] {
      guard let value = raw as? [String: Any], let names = value["anims"] as? [Any] else {
        throw PetOverlayPackFailure()
      }
      bonus[name] = PetOverlayBonus(animations: try names.map(reference),
        chance: min(1, max(0, Self.number(value["chance"]) ?? 0)))
    }
    let anchor = json["anchor"] as? [String: Any] ?? [:]
    self.id = id
    pixelArt = json["pixelArt"] as? Bool != false
    self.scale = scale
    canvasWidth = width
    canvasHeight = height
    anchorX = Self.number(anchor["x"]) ?? width / 2
    baseline = Self.number(anchor["baseline"]) ?? height
    contentBox = content
    self.animations = animations
    self.states = states
    self.tiers = tiers
    idlePool = pool
    self.bonus = bonus
  }

  func primary(state: String, tier: Int) -> PetOverlayAnimation {
    if tier > 0, let selected = tiers[state]?.first(where: { tier >= $0.minimum }) {
      return animations[selected.animation]!
    }
    return animations[(states[state]?.first ?? states["idle"]!.first)!]!
  }

  /// Exact PetSprite size rule, in physical output pixels. The system may
  /// scale the finished video in its PiP window; that final scale is not ours.
  func artScale(size: PetOverlaySize, deviceScale: Double) -> Double {
    guard pixelArt else { return size.bodyHeight * deviceScale / contentBox.height }
    func pixels(_ size: PetOverlaySize) -> Double {
      max(1, (size.bodyHeight * deviceScale / contentBox.height).rounded())
    }
    let small = pixels(.small), medium = max(small + 1, pixels(.medium))
    switch size {
    case .small: return small
    case .medium: return medium
    case .large: return max(medium + 1, pixels(.large))
    }
  }

  private static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite else { return nil }
    return number.doubleValue
  }
  private static func integer(_ value: Any?) -> Int? {
    guard let number = number(value), number.rounded() == number,
      number >= 0, number <= 1_000_000_000 else { return nil }
    return Int(number)
  }
  private static func box(_ raw: Any?) -> PetOverlayBox? {
    guard let value = raw as? [String: Any],
      let x = number(value["x"]), let y = number(value["y"]),
      let width = number(value["w"]), let height = number(value["h"]),
      width > 0, height > 0, abs(x) <= 512, abs(y) <= 512,
      width <= 512, height <= 512 else { return nil }
    return PetOverlayBox(x: x, y: y, width: width, height: height)
  }
}

struct PetOverlayFrameSelection {
  let animation: PetOverlayAnimation
  let index: Int
  let nextMilliseconds: Int?
}

/// Presentation timing only. State/priority/tiers are already reduced in Dart.
/// Calm states use the documented overlay's 8–15 second idle rhythm.
struct PetOverlayFrameClock {
  private var key = ""
  private var primary: PetOverlayAnimation?
  private var playing: PetOverlayAnimation?
  private var started = 0
  private var until = 0
  private var nextIdle = 0
  private var calm = false
  private var frozenAt: Int?

  mutating func setPaused(_ paused: Bool, now: Int) {
    if paused {
      if frozenAt == nil { frozenAt = now }
    } else if let frozenAt {
      let shift = max(0, now - frozenAt)
      started += shift
      until += shift
      nextIdle += shift
      self.frozenAt = nil
    }
  }

  mutating func configure(pack: PetOverlayPack, state: PetOverlayState, now: Int,
    random: () -> Double = { Double.random(in: 0..<1) }) {
    let nextKey = "\(pack.id):\(state.state):\(state.tier):\(state.reduceMotion)"
    guard nextKey != key else { return }
    key = nextKey
    primary = pack.primary(state: state.state, tier: state.tier)
    calm = state.state == "idle" || state.state == "sleeping"
    playing = calm ? nil : primary
    if !calm, let bonus = pack.bonus[state.state], !bonus.animations.isEmpty,
      random() < bonus.chance {
      let index = min(bonus.animations.count - 1, max(0, Int(random() * Double(bonus.animations.count))))
      playing = pack.animations[bonus.animations[index]]
    }
    started = now
    nextIdle = now + gap(random())
  }

  mutating func frame(pack: PetOverlayPack, state: PetOverlayState, now: Int,
    random: () -> Double = { Double.random(in: 0..<1) }) -> PetOverlayFrameSelection {
    let now = frozenAt ?? now
    configure(pack: pack, state: state, now: now, random: random)
    let base = primary!
    if state.reduceMotion { return PetOverlayFrameSelection(animation: base, index: 0, nextMilliseconds: nil) }
    if calm {
      if playing != nil, now >= until {
        playing = nil
        nextIdle = now + gap(random())
      }
      if playing == nil, now >= nextIdle {
        // Match PetOverlay.kt: sleeping replays only sleeping, while idle
        // prefers one ordinary blink/breath (weight 3) over its extra actions.
        let ordinary = PetOverlayIdle(animation: base.name, milliseconds: base.duration,
          weight: state.state == "sleeping" ? 1 : 3)
        let pool = ([ordinary] + (state.state == "sleeping" ? [] : pack.idlePool)).filter { $0.weight > 0 }
        let total = pool.reduce(0.0) { $0 + $1.weight }
        var remaining = random() * total
        var selected: PetOverlayIdle?
        for item in pool {
          remaining -= item.weight
          if remaining < 0 { selected = item; break }
        }
        if let item = selected, let animation = pack.animations[item.animation] {
          playing = animation
          started = now
          until = now + item.milliseconds
        } else { nextIdle = now + gap(random()) }
      }
      guard let animation = playing else {
        return PetOverlayFrameSelection(animation: base, index: 0, nextMilliseconds: max(1, nextIdle - now))
      }
      let elapsed = max(0, now - started)
      return PetOverlayFrameSelection(animation: animation, index: animation.frameIndex(at: elapsed),
        nextMilliseconds: min(animation.nextChange(after: elapsed) ?? (until - now), max(1, until - now)))
    }
    let animation = playing ?? base, elapsed = max(0, now - started)
    return PetOverlayFrameSelection(animation: animation, index: animation.frameIndex(at: elapsed),
      nextMilliseconds: animation.nextChange(after: elapsed))
  }

  private func gap(_ random: Double) -> Int { 8_000 + min(7_000, max(0, Int(random * 7_001))) }
}
