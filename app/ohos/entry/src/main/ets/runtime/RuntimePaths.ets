// 未经 HarmonyOS SDK 编译、未在真机核实；只从 P2 保存的应用 Context 派生。
export class RuntimePaths {
  readonly guestRoot: string;
  readonly home: string;
  readonly dshHome: string;
  readonly agentsHome: string;
  readonly workspace: string;
  readonly outputs: string;

  constructor(filesDir: string) {
    this.guestRoot = filesDir + '/runtime/rootfs';
    this.home = this.guestRoot + '/root';
    this.dshHome = this.home + '/.dsh';
    this.agentsHome = this.home + '/.agents';
    this.workspace = this.home + '/workspace';
    this.outputs = this.workspace + '/DSH-Go';
  }
}
