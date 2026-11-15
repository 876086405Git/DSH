// A command's environment must not insert code ahead of the inherited product
// --import that establishes the Node script Worker's path and stdin behavior.
// This closes that startup ordering hole; it is not a Node security sandbox.
export function workerEnvironment(env) {
  const clean = { ...env };
  delete clean.NODE_OPTIONS;
  delete clean.NODE_PATH;
  return clean;
}
