export interface MetroPresetOptions {
  /** False for an app with no web target: leaves the web fixes out. */
  web?: boolean;
}

/**
 * The part of Expo's Metro configuration this preset reads and changes. The
 * resolver's own types are Metro's, so its arguments are left untyped here.
 */
export interface MetroConfigLike {
  projectRoot: string;
  resolver: {
    blockList?: RegExp | RegExp[];
    assetExts: string[];
    resolveRequest?: ((context: any, moduleName: string, platform: string | null) => any) | null;
  };
}

export function worktreeBlock(projectRoot: string): RegExp;
export function workflowsBlock(projectRoot: string): RegExp;
export function webResolveRequest(defaultResolveRequest?: ((...args: any[]) => any) | null): (context: any, moduleName: string, platform: string | null) => any;
export function withSharedMetroConfig<T extends MetroConfigLike>(config: T, options?: MetroPresetOptions): T;
