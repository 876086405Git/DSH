// OpenHarmony Ark bridge. Target SDK compilation and device behavior require validation.
export interface HostOptions {
  runtimeRoot: string;
  // Same trusted Context as the runtime/file channels; not supplied by Dart.
  guestRoot: string;
  dshHome: string;
  workspaceRoots: string[];
  cacheDir: string;
  // Ark resolves this from its own Context installation paths; never from Dart.
  nativeLibraryDir: string;
  // Independent writable Linux data, derived from the same trusted Context.
  linuxDirectory: string;
  env: Record<string, string>;
  // Selects only the fixed rescue profile; no caller-supplied argv or paths.
  safeMode?: boolean;
}

export interface HostState {
  phase: 'idle' | 'starting' | 'running' | 'stopping' | 'exited' | 'error';
  consumed: boolean;
  baseUrl: string | null;
  token: string | null;
  exitCode: number | null;
  errorCode: string | null;
  errorMessage: string | null;
}

export interface HostEvent {
  kind: 'log' | 'ready' | 'exit' | 'error';
  stream?: 'stdout' | 'stderr' | 'system';
  line?: string;
  baseUrl?: string;
  token?: string;
  exitCode?: number;
  errorCode?: string;
  message?: string;
}

export const start: (options: HostOptions) => void;
export const stop: () => void;
export const getState: () => HostState;
export const drainEvents: () => HostEvent[];

// Ark supplies its trusted workspace/cache root. Caller owns and must close fd.
export const openUserFile: (root: string, relative: string) => number;

// Internal Ark bridge only; never expose these mutation methods on a Dart channel.
export interface HostLifecycleSnapshot {
  version: number; engineGeneration: number; ownerGeneration: number; revision: number;
  grantGeneration: number; nowMs: number; deadlineMs: number; drainAtMs: number;
  phase: number; available: number; foreground: number; clockFailed: number;
}
export const lifecycleUpdate: (operation: string, owner: number, grant: number, value: number) => number;
export const lifecycleSnapshot: () => HostLifecycleSnapshot;

export interface HostPhoneSnapshot {
  available: boolean; foreground: boolean; engineId: string; bridgeGeneration: number; nowMs: number; ownerHash: string;
}
export interface HostPhoneKey { engineId: string; bridgeGeneration: number; requestId: string; executionNonce: string; }
export const phoneAttach: (ownerHash: string, engine: number, owner: number) => number;
export const phoneSnapshot: () => HostPhoneSnapshot;
export const phoneRetire: (generation: number) => boolean;
export const phoneOperation: (operation: string, key: HostPhoneKey, result?: string) => string | boolean | null;

export interface WorkspaceGrantStatus { active: boolean; drained: boolean; writable: boolean; leases: number; generation: number; }
export const workspaceGrant: (operation: string, id: string, generation: number, fd?: number, writable?: boolean) => WorkspaceGrantStatus;
