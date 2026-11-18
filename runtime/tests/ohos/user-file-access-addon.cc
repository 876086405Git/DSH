// Linux-only bridge to the production descriptor opener; not shipped in a HAP.
#include <node_api.h>
#include <string>
#include "../../../app/ohos/entry/src/main/cpp/file_access.h"

static std::string Text(napi_env env, napi_value value) {
  size_t length;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok)
    throw std::invalid_argument("Expected a string");
  std::string text(length + 1, '\0');
  napi_get_value_string_utf8(env, value, text.data(), text.size(), &length);
  text.resize(length);
  return text;
}

static napi_value Open(napi_env env, napi_callback_info info) {
  size_t count = 2;
  napi_value args[2], result;
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  try {
    if (count != 2) throw std::invalid_argument("Expected root and relative path");
    const int fd = dsh::OpenUserFile(Text(env, args[0]), Text(env, args[1]));
    napi_create_int32(env, fd, &result);
    return result;
  } catch (const std::exception& error) {
    napi_throw_error(env, nullptr, error.what());
    return nullptr;
  }
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_value open;
  napi_create_function(env, "openUserFile", NAPI_AUTO_LENGTH, Open, nullptr, &open);
  napi_set_named_property(env, exports, "openUserFile", open);
  return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
