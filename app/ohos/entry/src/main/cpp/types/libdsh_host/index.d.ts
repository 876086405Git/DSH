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
  env: Record<string, string>;
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
