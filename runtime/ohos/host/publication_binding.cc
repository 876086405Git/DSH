#include "publication_binding.h"
#include "phone_contract.h"
#include "dsh_node_version.h"

#include <node.h>
#include <node_api.h>
#include <uv.h>
#if !defined(__APPLE__)
#include <deviceinfo.h>
#endif

#include <cerrno>
#include <dirent.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <cstdlib>
#include <limits.h>
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

thread_local bool clone_owner_thread = false;

// Narrow Git-clone cleanup: all traversal is anchored to descriptors retained
// by the main job owner. Never recursively remove a pathname after checking it.
bool SameDirectory(const struct stat& a, const struct stat& b) {
  return S_ISDIR(a.st_mode) && S_ISDIR(b.st_mode) && a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}
int EmptyCloneDirectory(int descriptor, unsigned depth) {
  if (depth > 128) return ELOOP;
  const int copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0);
  if (copy < 0) return errno;
  DIR* directory = fdopendir(copy);
  if (!directory) { const int error = errno; close(copy); return error; }
  int error = 0;
  for (;;) {
    errno = 0;
    const dirent* entry = readdir(directory);
    if (!entry) { error = errno; break; }
    const char* name = entry->d_name;
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
    struct stat before;
    if (fstatat(descriptor, name, &before, AT_SYMLINK_NOFOLLOW) != 0) { error = errno; break; }
    if (S_ISDIR(before.st_mode)) {
      const int child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child < 0) { error = errno; break; }
      struct stat opened, current;
      if (fstat(child, &opened) != 0) error = errno;
      else if (!SameDirectory(before, opened)) error = ESTALE;
      else error = EmptyCloneDirectory(child, depth + 1);
      if (!error && fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) != 0) error = errno;
      if (!error && !SameDirectory(opened, current)) error = ESTALE;
      if (!error && unlinkat(descriptor, name, AT_REMOVEDIR) != 0) error = errno;
      close(child);
    } else {
      // unlinkat without AT_REMOVEDIR never follows a work-tree symlink.
      if (unlinkat(descriptor, name, 0) != 0) error = errno;
    }
    if (error) break;
  }
  closedir(directory);
  return error;
}
napi_value ClearOwnedClone(napi_env env, napi_callback_info info) {
  if (!clone_owner_thread) {
    napi_throw_error(env, "ERR_OHOS_OWNERSHIP_MAIN_THREAD", "Clone cleanup belongs to the main engine"); return nullptr;
  }
  size_t argc = 5; napi_value argv[5];
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) return nullptr;
  int directory, parent; std::string name, device, inode;
  if (argc != 5) { napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "Clone and parent descriptors, basename and owner receipt required"); return nullptr; }
  if (!ReadDescriptor(env, argv[0], &directory) || !ReadDescriptor(env, argv[1], &parent) || !ReadPath(env, argv[2], &name) || !ReadPath(env, argv[3], &device) || !ReadPath(env, argv[4], &inode)) return nullptr;
  if (name.empty() || name == "." || name == ".." || name.find('/') != std::string::npos) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "Clone cleanup requires one basename"); return nullptr;
  }
  struct stat opened, named; int error = 0;
  if (fstat(directory, &opened) != 0 || fstatat(parent, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0) error = errno;
  else if (!SameDirectory(opened, named) || device != std::to_string(opened.st_dev) || inode != std::to_string(opened.st_ino)) error = ESTALE;
  else error = EmptyCloneDirectory(directory, 0);
  if (!error && fstatat(parent, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0) error = errno;
  if (!error && !SameDirectory(opened, named)) error = ESTALE;
  // Keep the now-empty staging root. POSIX has no compare-inode-and-rmdir
  // primitive; even an empty foreign root must not be removed in that gap.
  if (error) { napi_throw_error(env, error == ESTALE ? "ERR_OHOS_GIT_CLONE_REPLACED" : ErrorName(error), "Owned clone cleanup refused or failed; remaining contents preserved"); return nullptr; }
  napi_value result; if (napi_get_undefined(env, &result) != napi_ok) return nullptr; return result;
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

struct LifecycleReader {
  bool bound = false;
  std::string library;
  void* handle = nullptr;
  DshReadHostLifecycleV1 read = nullptr;
  DshHostPhoneV1 phone = nullptr;
};
LifecycleReader& HostReader() { static thread_local LifecycleReader reader; return reader; }

napi_value GetHostLifecycleSnapshot(napi_env env, napi_callback_info) {
  if (!HostReader().bound) {
    napi_throw_error(env,"ERR_OHOS_LIFECYCLE_MAIN_THREAD","Host lifecycle belongs to the main engine");return nullptr;
  }
  if (!HostReader().read && !HostReader().library.empty()) {
    // Never load another owner. This must resolve the Ark module already hosting this engine.
    void* handle=dlopen(HostReader().library.c_str(),RTLD_NOW|RTLD_NOLOAD|RTLD_LOCAL);
    if(handle) {
      auto read=reinterpret_cast<DshReadHostLifecycleV1>(dlsym(handle,"dsh_host_lifecycle_snapshot_v1"));
      Dl_info info{};char actual[PATH_MAX];
      if(read && dladdr(reinterpret_cast<void*>(read),&info) && info.dli_fname &&
          realpath(info.dli_fname,actual) && HostReader().library==actual) {
        HostReader().handle=handle;HostReader().read=read;
      } else dlclose(handle);
    }
  }
  DshHostLifecycleSnapshotV1 data{};
  if(!HostReader().read || HostReader().read(&data,sizeof(data))!=0 || data.version!=1 || data.size!=sizeof(data) ||
      data.engine_generation>9007199254740991ULL || data.owner_generation>9007199254740991ULL ||
      data.revision>9007199254740991ULL || data.grant_generation>9007199254740991ULL ||
      data.now_ms>9007199254740991LL || data.deadline_ms>9007199254740991LL || data.drain_at_ms>9007199254740991LL) {
    napi_throw_error(env,"ERR_OHOS_LIFECYCLE_NATIVE","Trusted host lifecycle snapshot unavailable");return nullptr;
  }
  napi_value result;if(napi_create_object(env,&result)!=napi_ok)return nullptr;
  const auto put=[&](const char* key,double value){napi_value number;return napi_create_double(env,value,&number)==napi_ok && napi_set_named_property(env,result,key,number)==napi_ok;};
  if(!put("version",data.version)||!put("engineGeneration",data.engine_generation)||!put("ownerGeneration",data.owner_generation)||
      !put("revision",data.revision)||!put("grantGeneration",data.grant_generation)||!put("nowMs",data.now_ms)||
      !put("deadlineMs",data.deadline_ms)||!put("drainAtMs",data.drain_at_ms)||!put("phase",data.phase)||
      !put("available",data.available)||!put("foreground",data.foreground)||!put("clockFailed",data.clock_failed))return nullptr;
  return result;
}


bool PhoneText(napi_env env,napi_value value,char* output,size_t capacity) {
  std::string text;if(!ReadPath(env,value,&text))return false;
  if(text.size()>=capacity){napi_throw_range_error(env,"ERR_OHOS_PHONE_ARGUMENT","Phone identifier too long");return false;}
  memcpy(output,text.data(),text.size());output[text.size()]=0;return true;
}
bool PhoneProperty(napi_env env,napi_value object,const char* key,napi_value* value) {
  return napi_get_named_property(env,object,key,value)==napi_ok;
}
bool PhoneNumber(napi_env env,napi_value value,double* number) {
  if(napi_get_value_double(env,value,number)!=napi_ok)return false;
  if(!std::isfinite(*number)||*number<0||*number>9007199254740991.0||std::floor(*number)!=*number){
    napi_throw_range_error(env,"ERR_OHOS_PHONE_ARGUMENT","Phone integer out of range");return false;}
  return true;
}
bool PhoneJson(napi_env env,napi_value value,std::string* output,bool result) {
  napi_value global,json,stringify,encoded,input=value;
  if(result) {
    if(napi_create_object(env,&input)!=napi_ok)return false;
    for(const char* key:{"status","effect","evidence","dispatched","code","message"}) {
      napi_value field;if(!PhoneProperty(env,value,key,&field)||napi_set_named_property(env,input,key,field)!=napi_ok)return false;
    }
  }
  if(napi_get_global(env,&global)!=napi_ok||!PhoneProperty(env,global,"JSON",&json)||
    !PhoneProperty(env,json,"stringify",&stringify)||napi_call_function(env,json,stringify,1,&input,&encoded)!=napi_ok)return false;
  return ReadPath(env,encoded,output);
}
napi_value PhoneCall(napi_env env,napi_callback_info info) {
  size_t count=3;napi_value args[3];void* data=nullptr;
  if(napi_get_cb_info(env,info,&count,args,nullptr,&data)!=napi_ok)return nullptr;
  const auto operation=static_cast<uint32_t>(reinterpret_cast<uintptr_t>(data));
  // This also performs the main-registration-thread and fixed NOLOAD checks.
  if(!GetHostLifecycleSnapshot(env,nullptr))return nullptr;
  if(!HostReader().phone && HostReader().handle) {
    auto call=reinterpret_cast<DshHostPhoneV1>(dlsym(HostReader().handle,"dsh_host_phone_v1"));
    Dl_info symbol{};char actual[PATH_MAX];
    if(call&&dladdr(reinterpret_cast<void*>(call),&symbol)&&symbol.dli_fname&&
        realpath(symbol.dli_fname,actual)&&HostReader().library==actual)HostReader().phone=call;
  }
  if(!HostReader().phone){napi_throw_error(env,"ERR_OHOS_PHONE_NATIVE","Trusted phone host unavailable");return nullptr;}
  DshPhoneInputV1 in{};in.size=sizeof(in);in.version=1;in.operation=operation;std::string payload;
  if(operation==DshPhoneBind) {
    if(count!=1||!PhoneText(env,args[0],in.engine_id,sizeof(in.engine_id)))return nullptr;
  }else if(operation!=DshPhoneSnapshot) {
    if(count!=(operation==DshPhoneComplete?3u:2u)){napi_throw_type_error(env,"ERR_OHOS_PHONE_ARGUMENT","Phone request and nonce required");return nullptr;}
    napi_value value;double number;
    if(!PhoneProperty(env,args[0],"engineId",&value)||!PhoneText(env,value,in.engine_id,sizeof(in.engine_id))||
       !PhoneProperty(env,args[0],"bridgeGeneration",&value)||!PhoneNumber(env,value,&number))return nullptr;
    in.generation=static_cast<uint64_t>(number);
    if(!PhoneProperty(env,args[0],"requestId",&value)||!PhoneText(env,value,in.request_id,sizeof(in.request_id))||
       !PhoneText(env,args[1],in.nonce,sizeof(in.nonce)))return nullptr;
    if(operation==DshPhoneClaim) {
      if(!PhoneProperty(env,args[0],"tool",&value)||!PhoneText(env,value,in.tool,sizeof(in.tool))||
         !PhoneProperty(env,args[0],"deadlineMs",&value)||!PhoneNumber(env,value,&number))return nullptr;
      in.deadline_ms=static_cast<int64_t>(number);if(!PhoneJson(env,args[0],&payload,false))return nullptr;
    }else if(operation==DshPhoneComplete) {if(!PhoneJson(env,args[2],&payload,true))return nullptr;}
    if(payload.size()>4*1024*1024){napi_throw_range_error(env,"ERR_OHOS_PHONE_ARGUMENT","Phone payload too large");return nullptr;}
    in.data=payload.data();in.data_size=static_cast<uint32_t>(payload.size());
  }
  DshPhoneSnapshotV1 snapshot{};
  // Allocate boolean/null handles before a native state mutation.
  napi_value yes,no,nil;if(napi_get_boolean(env,true,&yes)!=napi_ok||napi_get_boolean(env,false,&no)!=napi_ok||napi_get_null(env,&nil)!=napi_ok)return nullptr;
  const int answer=HostReader().phone(&in,&snapshot);
  if(answer<0){napi_throw_error(env,"ERR_OHOS_PHONE_NATIVE","Phone native operation unavailable");return nullptr;}
  if(operation!=DshPhoneSnapshot)return answer==2?nil:(answer?yes:no);
  if(answer!=1||snapshot.size!=sizeof(snapshot)||snapshot.version!=1||snapshot.generation>9007199254740991ULL||
     !memchr(snapshot.engine_id,0,sizeof(snapshot.engine_id))||!memchr(snapshot.owner_hash,0,sizeof(snapshot.owner_hash))){
    napi_throw_error(env,"ERR_OHOS_PHONE_NATIVE","Invalid phone snapshot");return nullptr;}
  napi_value result,value;if(napi_create_object(env,&result)!=napi_ok)return nullptr;
  const auto putText=[&](const char* key,const char* text){return napi_create_string_utf8(env,text,NAPI_AUTO_LENGTH,&value)==napi_ok&&napi_set_named_property(env,result,key,value)==napi_ok;};
  const auto putNumber=[&](const char* key,double num){return napi_create_double(env,num,&value)==napi_ok&&napi_set_named_property(env,result,key,value)==napi_ok;};
  if(napi_set_named_property(env,result,"available",snapshot.available?yes:no)!=napi_ok||
     napi_set_named_property(env,result,"foreground",snapshot.foreground?yes:no)!=napi_ok||
     !putText("engineId",snapshot.engine_id)||!putText("ownerHash",snapshot.owner_hash)||
     !putNumber("bridgeGeneration",snapshot.generation)||!putNumber("nowMs",snapshot.now_ms))return nullptr;
  return result;
}

napi_value Initialize(napi_env env, napi_value exports) {
#ifdef DSH_PUBLICATION_TEST_ADDON
  // Standalone Linux test-addon entry; production is set at pre-Start registration.
  if (syscall(SYS_gettid) == getpid()) clone_owner_thread = true;
#endif
  const napi_node_version* version;
  if (napi_get_node_version(env, &version) != napi_ok) return nullptr;
  if (version->major != DSH_NODE_VERSION_MAJOR || version->minor != DSH_NODE_VERSION_MINOR ||
      version->patch != DSH_NODE_VERSION_PATCH) {
    napi_throw_error(env, "ERR_OHOS_NATIVE_NODE_VERSION", "Publication binding requires Node " DSH_NODE_VERSION_STRING);
    return nullptr;
  }
  napi_value function;
  if (napi_create_function(env, "clearOwnedClone", NAPI_AUTO_LENGTH, ClearOwnedClone,
                           nullptr, &function) != napi_ok ||
      napi_set_named_property(env, exports, "clearOwnedClone", function) != napi_ok) return nullptr;
  const char* phoneNames[]={"bindPhoneEngine","getPhoneSnapshot","claimPhonePermit","revokePhonePermit","completePhonePermit"};
  for(uint32_t i=0;i<5;++i) {
    if(napi_create_function(env,phoneNames[i],NAPI_AUTO_LENGTH,PhoneCall,reinterpret_cast<void*>(static_cast<uintptr_t>(i+1)),&function)!=napi_ok||
       napi_set_named_property(env,exports,phoneNames[i],function)!=napi_ok)return nullptr;
  }
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
  if (napi_create_function(env, "getHostLifecycleSnapshot", NAPI_AUTO_LENGTH, GetHostLifecycleSnapshot,
                           nullptr, &function) != napi_ok ||
      napi_set_named_property(env, exports, "getHostLifecycleSnapshot", function) != napi_ok) return nullptr;
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

void BindPublicationHost(DshReadHostLifecycleV1 read) {
  clone_owner_thread = true;
  HostReader().bound = true;
  HostReader().read = read;
}

void RegisterPublicationBinding() {
  BindPublicationHost(nullptr);
#if !defined(__APPLE__)
  const char* root=std::getenv("DSH_GO_OHOS_NATIVE_LIBRARY_DIR");char canonical[PATH_MAX];
  if(root && root[0]=='/') {
    const std::string path=std::string(root)+"/libdsh_host.so";
    if(realpath(path.c_str(),canonical) && path==canonical) HostReader().library=path;
  }
#endif
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
