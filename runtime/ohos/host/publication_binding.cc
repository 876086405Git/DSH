#include "publication_binding.h"
#include "dsh_node_version.h"

#include <node.h>
#include <node_api.h>
#include <uv.h>
#if !defined(__APPLE__)
#include <deviceinfo.h>
#endif

#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <limits>
#if defined(__APPLE__)
#include <cstdio>
#include <sys/sysctl.h>
#else
#include <linux/fs.h>
#endif
#include <string>
#include <sys/file.h>
#if !defined(__APPLE__)
#include <sys/syscall.h>
#endif
#include <sys/xattr.h>
#include <unistd.h>
#include <vector>

namespace {

#if defined(__APPLE__)
constexpr int kMissingAttribute = ENOATTR;
int SetAttribute(int fd, const char* name, const void* value, size_t size) {
  return fsetxattr(fd, name, value, size, 0, XATTR_CREATE);
}
ssize_t GetAttribute(int fd, const char* name, void* value, size_t size) {
  return fgetxattr(fd, name, value, size, 0, 0);
}
std::string SystemString(const char* name) {
  size_t size = 0;
  if (sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || size == 0) return "";
  std::vector<char> bytes(size);
  if (sysctlbyname(name, bytes.data(), &size, nullptr, 0) != 0 || size == 0) return "";
  return std::string(bytes.data(), strnlen(bytes.data(), size));
}
#else
constexpr int kMissingAttribute = ENODATA;
int SetAttribute(int fd, const char* name, const void* value, size_t size) {
  return fsetxattr(fd, name, value, size, XATTR_CREATE);
}
ssize_t GetAttribute(int fd, const char* name, void* value, size_t size) {
  return fgetxattr(fd, name, value, size);
}
#endif

// POSIX syscalls report positive errno values; libuv's Unix enum is negative.
// Use the pinned header's complete map without importing bundled uv_* symbols.
const char* ErrorName(int error_number) {
  switch (-error_number) {
#define DSH_ERRNO_CASE(code, message) case UV_##code: return #code;
    UV_ERRNO_MAP(DSH_ERRNO_CASE)
#undef DSH_ERRNO_CASE
    default: return "UNKNOWN";
  }
}

napi_value GetSystemBuildIdentity(napi_env env, napi_callback_info) {
  // These are public OS build properties, never a device serial or user ID.
  const char* names[] = {"osFullName", "displayVersion", "incrementalVersion", "securityPatchTag"};
#if defined(__APPLE__)
  // iOS has no patch tag; the kernel's version string changes with every OS build.
  const std::string apple[] = {SystemString("kern.ostype"), SystemString("kern.osproductversion"),
                               SystemString("kern.osversion"), SystemString("kern.version")};
  const char* values[] = {apple[0].c_str(), apple[1].c_str(), apple[2].c_str(), apple[3].c_str()};
#else
  // Product builds resolve these four APIs from libdeviceinfo_ndk.z.so.
  const char* values[] = {OH_GetOSFullName(), OH_GetDisplayVersion(),
                          OH_GetIncrementalVersion(), OH_GetSecurityPatchTag()};
#endif
  constexpr size_t maximum_bytes = 1024;
  napi_value result;
  if (napi_create_object(env, &result) != napi_ok) return nullptr;
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
    // The public API permits NULL, and GetOSFullName can return an empty string.
    // A missing identity must not reset a previously armed/disabled crash fuse.
    const size_t length = values[i] == nullptr ? 0 : strnlen(values[i], maximum_bytes + 1);
    if (length == 0 || length > maximum_bytes) {
      napi_throw_error(env, "ERR_OHOS_SYSTEM_BUILD_IDENTITY",
                       "The operating-system build identity is unavailable or invalid");
      return nullptr;
    }
    napi_value value;
    if (napi_create_string_utf8(env, values[i], length, &value) != napi_ok ||
        napi_set_named_property(env, result, names[i], value) != napi_ok) return nullptr;
  }
  return result;
}

bool ReadPath(napi_env env, napi_value value, std::string* path) {
  napi_valuetype type;
  if (napi_typeof(env, value, &type) != napi_ok) return false;
  if (type != napi_string) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "Paths must be strings");
    return false;
  }
  size_t length;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return false;
  std::vector<char> bytes(length + 1);
  if (napi_get_value_string_utf8(env, value, bytes.data(), bytes.size(), &length) != napi_ok) return false;
  if (std::memchr(bytes.data(), '\0', length) != nullptr) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "Paths must not contain NUL");
    return false;
  }
  path->assign(bytes.data(), length);
  return true;
}

napi_value RenameNoReplace(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) return nullptr;
  if (argc < 2) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "Two path strings are required");
    return nullptr;
  }
  std::string source, destination;
  if (!ReadPath(env, argv[0], &source) || !ReadPath(env, argv[1], &destination)) return nullptr;

#if defined(__APPLE__)
  const int rename_result = renamex_np(source.c_str(), destination.c_str(), RENAME_EXCL);
  const int error_number = rename_result == 0 ? 0 : errno;
#elif defined(SYS_renameat2)
  const long rename_result = syscall(SYS_renameat2, AT_FDCWD, source.c_str(),
                              AT_FDCWD, destination.c_str(), RENAME_NOREPLACE);
  const int error_number = rename_result == 0 ? 0 : errno;
#else
  const int error_number = ENOSYS;
#endif
  if (error_number != 0) {
    napi_value message, code, error, number, operation;
    if (napi_create_string_utf8(env, "renameat2(RENAME_NOREPLACE) failed", NAPI_AUTO_LENGTH, &message) != napi_ok ||
        napi_create_string_utf8(env, ErrorName(error_number), NAPI_AUTO_LENGTH, &code) != napi_ok ||
        napi_create_error(env, code, message, &error) != napi_ok ||
        napi_create_int32(env, -error_number, &number) != napi_ok ||
        napi_set_named_property(env, error, "errno", number) != napi_ok ||
        napi_create_string_utf8(env, "renameat2", NAPI_AUTO_LENGTH, &operation) != napi_ok ||
        napi_set_named_property(env, error, "syscall", operation) != napi_ok) return nullptr;
    napi_throw(env, error);
    return nullptr;
  }
  napi_value result;
  if (napi_get_undefined(env, &result) != napi_ok) return nullptr;
  return result;
}

napi_value LockExclusive(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) return nullptr;
  if (argc < 1) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "A file descriptor is required");
    return nullptr;
  }
  napi_valuetype type;
  if (napi_typeof(env, argv[0], &type) != napi_ok) return nullptr;
  if (type != napi_number) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "File descriptor must be a number");
    return nullptr;
  }
  double value;
  if (napi_get_value_double(env, argv[0], &value) != napi_ok) return nullptr;
  if (!std::isfinite(value) || value < 0 || std::floor(value) != value ||
      value > std::numeric_limits<int>::max()) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "File descriptor must be a non-negative int");
    return nullptr;
  }
  const int lock_result = flock(static_cast<int>(value), LOCK_EX | LOCK_NB);
  const int error_number = lock_result == 0 ? 0 : errno;
  if (error_number != 0) {
    napi_value message, code, error, number, operation;
    if (napi_create_string_utf8(env, "flock(LOCK_EX | LOCK_NB) failed", NAPI_AUTO_LENGTH, &message) != napi_ok ||
        napi_create_string_utf8(env, ErrorName(error_number), NAPI_AUTO_LENGTH, &code) != napi_ok ||
        napi_create_error(env, code, message, &error) != napi_ok ||
        napi_create_int32(env, -error_number, &number) != napi_ok ||
        napi_set_named_property(env, error, "errno", number) != napi_ok ||
        napi_create_string_utf8(env, "flock", NAPI_AUTO_LENGTH, &operation) != napi_ok ||
        napi_set_named_property(env, error, "syscall", operation) != napi_ok) return nullptr;
    napi_throw(env, error);
    return nullptr;
  }
  napi_value result;
  if (napi_get_undefined(env, &result) != napi_ok) return nullptr;
  return result;
}

constexpr const char* kOwnershipAttribute = "user.dsh_go_ownership";
constexpr size_t kMaximumAttributeBytes = 65536;

bool ReadDescriptor(napi_env env, napi_value value, int* descriptor) {
  napi_valuetype type;
  if (napi_typeof(env, value, &type) != napi_ok) return false;
  if (type != napi_number) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "File descriptor must be a number");
    return false;
  }
  double number;
  if (napi_get_value_double(env, value, &number) != napi_ok) return false;
  if (!std::isfinite(number) || number < 0 || std::floor(number) != number ||
      number > std::numeric_limits<int>::max()) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "File descriptor must be a non-negative int");
    return false;
  }
  *descriptor = static_cast<int>(number);
  return true;
}

napi_value ThrowAttributeError(napi_env env, int error_number, const char* operation) {
  napi_value message, code, error, number, syscall_name;
  // Neither the path, the attribute value nor file content enters diagnostics.
  if (napi_create_string_utf8(env, "Ownership marker operation failed", NAPI_AUTO_LENGTH, &message) != napi_ok ||
      napi_create_string_utf8(env, ErrorName(error_number), NAPI_AUTO_LENGTH, &code) != napi_ok ||
      napi_create_error(env, code, message, &error) != napi_ok ||
      napi_create_int32(env, -error_number, &number) != napi_ok ||
      napi_set_named_property(env, error, "errno", number) != napi_ok ||
      napi_create_string_utf8(env, operation, NAPI_AUTO_LENGTH, &syscall_name) != napi_ok ||
      napi_set_named_property(env, error, "syscall", syscall_name) != napi_ok) return nullptr;
  napi_throw(env, error);
  return nullptr;
}

napi_value SetOwnershipMarker(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) return nullptr;
  if (argc < 2) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "A file descriptor and ownership token are required");
    return nullptr;
  }
  int descriptor;
  if (!ReadDescriptor(env, argv[0], &descriptor)) return nullptr;
  napi_valuetype type;
  if (napi_typeof(env, argv[1], &type) != napi_ok) return nullptr;
  if (type != napi_string) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "Ownership token must be a string");
    return nullptr;
  }
  size_t length;
  if (napi_get_value_string_utf8(env, argv[1], nullptr, 0, &length) != napi_ok) return nullptr;
  if (length == 0 || length > kMaximumAttributeBytes) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "Ownership token must contain 1 to 65536 UTF-8 bytes");
    return nullptr;
  }
  std::vector<char> bytes(length + 1);
  if (napi_get_value_string_utf8(env, argv[1], bytes.data(), bytes.size(), &length) != napi_ok) return nullptr;
  if (std::memchr(bytes.data(), '\0', length) != nullptr) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "Ownership token must not contain NUL");
    return nullptr;
  }
  const int result = SetAttribute(descriptor, kOwnershipAttribute, bytes.data(), length);
  const int error_number = result == 0 ? 0 : errno;
  if (error_number != 0) return ThrowAttributeError(env, error_number, "fsetxattr");
  napi_value undefined;
  if (napi_get_undefined(env, &undefined) != napi_ok) return nullptr;
  return undefined;
}

napi_value GetOwnershipMarker(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) return nullptr;
  if (argc < 1) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "A file descriptor is required");
    return nullptr;
  }
  int descriptor;
  if (!ReadDescriptor(env, argv[0], &descriptor)) return nullptr;
  const ssize_t expected = GetAttribute(descriptor, kOwnershipAttribute, nullptr, 0);
  const int first_error = expected < 0 ? errno : 0;
  napi_value result;
  if (first_error == kMissingAttribute) {
    if (napi_get_undefined(env, &result) != napi_ok) return nullptr;
    return result;
  }
  if (first_error != 0) return ThrowAttributeError(env, first_error, "fgetxattr");
  if (static_cast<size_t>(expected) > kMaximumAttributeBytes) {
    napi_throw_error(env, "ERR_OHOS_OWNERSHIP_MARKER_SIZE", "Ownership marker exceeds supported size");
    return nullptr;
  }
  // A zero-size query is not a read. Use at least one byte so a concurrent
  // growth cannot turn the second syscall into another successful size query.
  std::vector<char> bytes(expected == 0 ? 1 : static_cast<size_t>(expected));
  const ssize_t actual = GetAttribute(descriptor, kOwnershipAttribute, bytes.data(), bytes.size());
  const int read_error = actual < 0 ? errno : 0;
  if (read_error == kMissingAttribute) {
    if (napi_get_undefined(env, &result) != napi_ok) return nullptr;
    return result;
  }
  if (read_error != 0) return ThrowAttributeError(env, read_error, "fgetxattr");
  if (napi_create_string_utf8(env, bytes.data(), static_cast<size_t>(actual), &result) != napi_ok) return nullptr;
  return result;
}

napi_value Initialize(napi_env env, napi_value exports) {
  const napi_node_version* version;
  if (napi_get_node_version(env, &version) != napi_ok) return nullptr;
  if (version->major != DSH_NODE_VERSION_MAJOR || version->minor != DSH_NODE_VERSION_MINOR ||
      version->patch != DSH_NODE_VERSION_PATCH) {
    napi_throw_error(env, "ERR_OHOS_NATIVE_NODE_VERSION", "Publication binding requires Node " DSH_NODE_VERSION_STRING);
    return nullptr;
  }
  napi_value function;
  if (napi_create_function(env, "renameNoReplace", NAPI_AUTO_LENGTH, RenameNoReplace,
                           nullptr, &function) != napi_ok ||
      napi_set_named_property(env, exports, "renameNoReplace", function) != napi_ok) return nullptr;
  if (napi_create_function(env, "lockExclusive", NAPI_AUTO_LENGTH, LockExclusive,
                           nullptr, &function) != napi_ok ||
      napi_set_named_property(env, exports, "lockExclusive", function) != napi_ok) return nullptr;
  if (napi_create_function(env, "setOwnershipMarker", NAPI_AUTO_LENGTH, SetOwnershipMarker,
                           nullptr, &function) != napi_ok ||
      napi_set_named_property(env, exports, "setOwnershipMarker", function) != napi_ok) return nullptr;
  if (napi_create_function(env, "getOwnershipMarker", NAPI_AUTO_LENGTH, GetOwnershipMarker,
                           nullptr, &function) != napi_ok ||
      napi_set_named_property(env, exports, "getOwnershipMarker", function) != napi_ok) return nullptr;
  if (napi_create_function(env, "getSystemBuildIdentity", NAPI_AUTO_LENGTH, GetSystemBuildIdentity,
                           nullptr, &function) != napi_ok ||
      napi_set_named_property(env, exports, "getSystemBuildIdentity", function) != napi_ok) return nullptr;
  return exports;
}

// Node 24.22.1's pre-Start registration puts this descriptor in the linked list.
// NAPI_MODULE_X ignores its flags argument and is not a substitute for this call.
// Registration uses the default Node-API version (8), matching our test build.
napi_module publication_module = {
    NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
    "runtime/ohos/host/publication_binding.cc", Initialize,
    "dsh_ohos_publication", nullptr, {nullptr, nullptr, nullptr, nullptr}};

}  // namespace

void RegisterPublicationBinding() {
  napi_module_register(&publication_module);
}

#ifdef DSH_PUBLICATION_TEST_ADDON
NAPI_MODULE(dsh_ohos_publication, Initialize)
#endif

#ifdef DSH_PUBLICATION_TEST_PRELOAD
__attribute__((constructor)) static void TestPreStartRegistration() {
  RegisterPublicationBinding();
}
#endif
