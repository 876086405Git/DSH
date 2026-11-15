// The first six programs are the unchanged independent v2 review cases.
export const independentOpenFiles = {
  'result.bin': Buffer.from('seed'),
  b: Buffer.from([0, 255, 195, 169, 128, 10]),
  e: Buffer.from([254, 240, 159, 152, 128, 10]),
};
export const independentOpenCases = [
  { name: 'scoped-live-stderr-alias', command: '{ printf C; printf E >&2; } 2>&1 > result.bin' },
  { name: 'scoped-capture-live-stderr-alias', command: '{ printf "<%s>" "$(printf C; printf E >&2)"; } 2>&1 > result.bin' },
  { name: 'scoped-pipeline-live-stderr-alias', command: '{ { printf C; printf E >&2; } | cat; } 2>&1 > result.bin' },
  { name: 'persistent-capture-live-stderr-alias', command: 'exec 2>&1; printf "<%s>" "$(printf C; printf E >&2)" > result.bin' },
  { name: 'same-file-capture-positive', command: '{ printf "<%s>" "$(printf C; printf E >&2)"; } > result.bin 2>&1' },
  { name: 'numeric-live-capture', command: 'exec 3>&1; { printf "<%s>" "$(printf C; printf E >&3)"; } > result.bin' },
  { name: 'if-live-alias', command: 'if true; then printf C; printf E >&2; fi 2>&1 > result.bin' },
  { name: 'for-live-alias', command: 'for x in 1; do printf C; printf E >&2; done 2>&1 > result.bin' },
  { name: 'c-for-live-alias', command: 'for ((i=0;i<1;i++)); do printf C; printf E >&2; done 2>&1 > result.bin' },
  { name: 'while-live-alias', command: 'while true; do printf C; printf E >&2; break; done 2>&1 > result.bin' },
  { name: 'until-live-alias', command: 'until false; do printf C; printf E >&2; break; done 2>&1 > result.bin' },
  { name: 'case-live-alias', command: 'case x in x) printf C; printf E >&2;; esac 2>&1 > result.bin' },
  { name: 'subshell-live-alias', command: '(printf C; printf E >&2) 2>&1 > result.bin' },
  { name: 'function-return-live-alias', command: 'f(){ printf C; printf E >&2; return 7; }; f 2>&1 > result.bin' },
  { name: 'function-capture-live-alias', command: 'f(){ printf C; printf E >&2; return 7; }; printf "<%s>" "$(f 2>&1 > result.bin)"' },
  { name: 'nested-shell-live-alias', command: "bash -c 'printf C; printf E >&2' 2>&1 > result.bin" },
  { name: 'input-process-substitution-live-alias', command: '{ cat <(printf C; printf E >&2); } 2>&1 > result.bin' },
  { name: 'raw-bytes-live-alias', command: '{ cat b; cat e >&2; } 2>&1 > result.bin' },
  { name: 'utf8-live-alias', command: '{ printf 中文; printf 错误 >&2; } 2>&1 > result.bin' },
  { name: 'numeric-swap-live-alias', command: 'exec 3>&1; { printf C; printf E >&2; } 1>&2 2>&3 > result.bin' },
  { name: 'pipe-captures-both-live-streams', command: '{ printf C; printf E >&2; } 2>&1 | cat > result.bin' },
  { name: 'nested-capture-keeps-numeric-live-alias', command: 'exec 3>&1; printf "<%s>" "$(printf "%s" "$(printf C; printf E >&3)")" > result.bin' },
  { name: 'root-prefix-and-tail-order', command: 'printf B; { printf C; printf E >&2; } 2>&1 > result.bin; printf A' },
];
export const independentOpenAdjacentCases = [];
