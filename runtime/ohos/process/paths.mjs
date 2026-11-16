import { sep } from 'node:path';

export const isInside = (root, path) => path === root || path.startsWith(root + sep);
export const distinctRoots = roots => [...new Set(roots)].filter(root => !roots.some(other => other !== root && isInside(other, root)));
