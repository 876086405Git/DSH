// Test boundary only: actual Linux libz streaming, exposed to the exact ETS
// algorithm. This is not the OpenHarmony zlib NAPI binary or an Ark SDK test.
#include <node_api.h>
#include <zlib.h>
#include <cstring>
#include <string>

struct Stream {
  z_stream state{};
  bool initialized = false;
};
static int active = 0;

static napi_value Fail(napi_env env, const char* message, int code = 17800004) {
  napi_value text, error, number;
  napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &text);
  napi_create_error(env, nullptr, text, &error);
  napi_create_int32(env, code, &number);
  napi_set_named_property(env, error, "code", number);
  napi_throw(env, error);
  return nullptr;
}

static napi_value Number(napi_env env, double value) {
  napi_value result;
  napi_create_double(env, value, &result);
  return result;
}

static Stream* Get(napi_env env, napi_value value) {
  void* pointer = nullptr;
  if (napi_get_value_external(env, value, &pointer) != napi_ok) {
    Fail(env, "invalid test stream");
    return nullptr;
  }
  return static_cast<Stream*>(pointer);
}

static bool Has(napi_env env, napi_value object, const char* name, napi_value* value) {
  bool has = false;
  napi_has_named_property(env, object, name, &has);
  if (has) napi_get_named_property(env, object, name, value);
  return has;
}

static bool Update(napi_env env, Stream* stream, napi_value object) {
  napi_value value;
  void* bytes;
  size_t length;
  uint32_t available;
  if (Has(env, object, "nextIn", &value)) {
    if (napi_get_arraybuffer_info(env, value, &bytes, &length) != napi_ok) {
      Fail(env, "input must be an ArrayBuffer", 401); return false;
    }
    stream->state.next_in = static_cast<Bytef*>(bytes);
  }
  if (Has(env, object, "availableIn", &value)) {
    if (napi_get_value_uint32(env, value, &available) != napi_ok) return false;
    stream->state.avail_in = available;
  }
  if (Has(env, object, "nextOut", &value)) {
    if (napi_get_arraybuffer_info(env, value, &bytes, &length) != napi_ok) {
      Fail(env, "output must be an ArrayBuffer", 401); return false;
    }
    stream->state.next_out = static_cast<Bytef*>(bytes);
  }
  if (Has(env, object, "availableOut", &value)) {
    if (napi_get_value_uint32(env, value, &available) != napi_ok) return false;
    stream->state.avail_out = available;
  }
  return true;
}

static napi_value Create(napi_env env, napi_callback_info) {
  auto* stream = new Stream();
  napi_value result;
  napi_create_external(env, stream, [](napi_env, void* pointer, void*) {
    auto* item = static_cast<Stream*>(pointer);
    if (item->initialized) { inflateEnd(&item->state); --active; }
    delete item;
  }, nullptr, &result);
  return result;
}

static napi_value Init(napi_env env, napi_callback_info info) {
  size_t argc = 3; napi_value args[3];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc != 3) return Fail(env, "init arity", 401);
  auto* stream = Get(env, args[0]);
  if (!stream || stream->initialized || !Update(env, stream, args[1])) return Fail(env, "init state");
  int32_t bits; napi_get_value_int32(env, args[2], &bits);
  int status = inflateInit2(&stream->state, bits);
  if (status != Z_OK) return Fail(env, "inflateInit2 failed");
  stream->initialized = true; ++active;
  return Number(env, status);
}

static napi_value Inflate(napi_env env, napi_callback_info info) {
  size_t argc = 3; napi_value args[3];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc != 3) return Fail(env, "inflate arity", 401);
  auto* stream = Get(env, args[0]);
  if (!stream || !stream->initialized || !Update(env, stream, args[1])) return Fail(env, "inflate state");
  int32_t flush; napi_get_value_int32(env, args[2], &flush);
  int status = inflate(&stream->state, flush);
  if (status < 0) return Fail(env, stream->state.msg ? stream->state.msg : "inflate failed",
      status == Z_DATA_ERROR ? 17800005 : status == Z_BUF_ERROR ? 17800007 : 17800004);
  return Number(env, status);
}

static napi_value State(napi_env env, napi_callback_info info) {
  size_t argc = 1; napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  auto* stream = argc == 1 ? Get(env, args[0]) : nullptr;
  if (!stream || !stream->initialized) return Fail(env, "state without init");
  napi_value result; napi_create_object(env, &result);
  napi_set_named_property(env, result, "availableIn", Number(env, stream->state.avail_in));
  napi_set_named_property(env, result, "availableOut", Number(env, stream->state.avail_out));
  napi_set_named_property(env, result, "totalIn", Number(env, stream->state.total_in));
  napi_set_named_property(env, result, "totalOut", Number(env, stream->state.total_out));
  return result;
}

static napi_value End(napi_env env, napi_callback_info info) {
  size_t argc = 2; napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  auto* stream = argc == 2 ? Get(env, args[0]) : nullptr;
  if (!stream || !stream->initialized || !Update(env, stream, args[1])) return Fail(env, "end without init");
  int status = inflateEnd(&stream->state);
  if (status != Z_OK) return Fail(env, "inflateEnd failed");
  stream->initialized = false; --active;
  return Number(env, status);
}

static napi_value Active(napi_env env, napi_callback_info) { return Number(env, active); }
static napi_value Version(napi_env env, napi_callback_info) {
  napi_value value; napi_create_string_utf8(env, zlibVersion(), NAPI_AUTO_LENGTH, &value); return value;
}

static napi_value Register(napi_env env, napi_value exports) {
  struct Method { const char* name; napi_callback function; } methods[] = {
    {"create", Create}, {"init", Init}, {"inflate", Inflate}, {"state", State}, {"end", End}, {"active", Active}, {"version", Version}
  };
  for (const auto& method : methods) {
    napi_value value;
    napi_create_function(env, method.name, NAPI_AUTO_LENGTH, method.function, nullptr, &value);
    napi_set_named_property(env, exports, method.name, value);
  }
  return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Register)
