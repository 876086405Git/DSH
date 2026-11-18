// Isolated negative experiment only. Never load this into an App.
#include <node.h>
#include <node_api.h>
namespace {
napi_value InitializeNullProbe(napi_env, napi_value exports) { return exports; }
__attribute__((constructor)) void CallWithoutEnvironment() {
  node::AddLinkedBinding(static_cast<node::Environment*>(nullptr),
                        "dsh_m6_null_environment", InitializeNullProbe, 8);
}
}  // namespace
