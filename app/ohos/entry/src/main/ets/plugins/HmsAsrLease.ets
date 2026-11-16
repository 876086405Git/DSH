// Core Speech recognition has one physical owner, including idle/prewarmed engines.
export class HmsAsrToken {}

export class HmsAsrLease {
  private static held: HmsAsrToken | null = null;
  static claim(token: HmsAsrToken): boolean {
    if (HmsAsrLease.held !== null && HmsAsrLease.held !== token) return false;
    HmsAsrLease.held = token; return true;
  }
  static release(token: HmsAsrToken): void {
    if (HmsAsrLease.held === token) HmsAsrLease.held = null;
  }
}
