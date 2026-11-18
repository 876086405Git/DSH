// Per-Environment N-API owner; the process-wide guest kernel lives separately.
// No JS/Env lifetime waits for a guest thread or for a JavaScript output ACK.
#include <node_api.h>
#include "../../host/activity_clock_api.h"
#include <uv.h>
#include <atomic>
#include <cerrno>
#include <charconv>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <condition_variable>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>
extern "C" {
#include "guest_backend.h"
}

namespace {
struct CapturedClock {
  dsh_activity_clock_v1 value{sizeof(dsh_activity_clock_v1), 1, nullptr, nullptr, nullptr};
  void *image = nullptr;
  ~CapturedClock() {
    if (value.context && value.release) value.release(value.context);
    if (image) dlclose(image);
  }
  int acquire() {
    dsh_activity_clock_acquire_v1 get = nullptr;
#ifdef __APPLE__
    Dl_info info{};
    if (!dladdr(reinterpret_cast<void *>(&locate), &info) || !info.dli_fname) return ENOSYS;
    const std::string own(info.dli_fname), suffix = "/DshGuestBridge.framework/DshGuestBridge";
    if (own.size() < suffix.size() || own.compare(own.size() - suffix.size(), suffix.size(), suffix)) return ENOSYS;
    const auto host = own.substr(0, own.size() - suffix.size()) + "/DshNodeHost.framework/DshNodeHost";
    image = dlopen(host.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (!image) return ENOSYS;
    get = reinterpret_cast<dsh_activity_clock_acquire_v1>(dlsym(image, "dsh_host_activity_clock_acquire_v1"));
    if (!get) return ENOSYS;
#else
    // Linux kernel/standalone addon probes have no embedded Host. A test Host
    // may export this same fixed ABI; there is no JS-configurable pointer/path.
    get = reinterpret_cast<dsh_activity_clock_acquire_v1>(dlsym(RTLD_DEFAULT, "dsh_host_activity_clock_acquire_v1"));
    if (!get) return 0;
    Dl_info info{};
    if (!dladdr(reinterpret_cast<void *>(get), &info) || !info.dli_fname) return ENOSYS;
    image = dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (!image) return ENOSYS;
#endif
    const int error = get(&value);
    if (error) return error;
    return value.context && value.now_ms && value.release ? 0 : EPROTO;
  }
  static void locate() {}
};
struct Job;
struct RootIdentity {
  int fd = -1;
  std::string path;
  uint64_t device = 0, inode = 0;
  ~RootIdentity() { if (fd >= 0) close(fd); }
};
struct Owner {
  napi_env env = nullptr;
  uv_async_t async{};
  napi_async_cleanup_hook_handle hook = nullptr;
  std::atomic<unsigned> refs{1}; // uv handle owns this reference until close.
  std::mutex mutex;
  std::condition_variable changed;
  bool closed = false;
  // Pin one installation inode until this Owner really retires. A Job retains
  // its Owner through initialize/start/wait, even after Env cleanup. JS dispose
  // or an unjoined cancellation must never release/reassign this identity.
  std::unique_ptr<RootIdentity> root_identity;
  std::shared_ptr<Job> active;
  std::shared_ptr<Job> finishing; // Kept visible to cleanup during an exit callback.
  std::pair<Owner *, int> methods[6];
};
void retain(Owner *o) { o->refs.fetch_add(1, std::memory_order_relaxed); }
void release(Owner *o) {
  if (o->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) delete o;
}
struct Chunk {
  uint64_t start = 0, end = 0;
  std::vector<char> bytes;
  bool delivered = false, acked = false;
};
struct Job {
  explicit Job(Owner *o) : owner(o) { retain(o); }
  ~Job() { release(owner); } // Never invoke N-API here: this may be a native thread.
  Owner *owner;
  CapturedClock clock;
  uint64_t id = 0, native_id = 0;
  std::string root, cwd, workspace, temporary;
  std::vector<std::string> argv, env, protected_paths;
  napi_ref callback = nullptr, resource = nullptr; // Node loop only.
  napi_async_context async_context = nullptr; // Node loop only.
  std::shared_ptr<Chunk> pending[2];
  uint64_t confirmed[2] = {0, 0};
  bool start_ready = false, started = false, start_sent = false;
  bool done = false, exit_sent = false, abandoned = false;
  bool close_stdin = false, cancel = false, kill = false;
  bool read_only = false, root_writable = false;
  uint64_t root_device = 0, root_inode = 0;
  int delivery_error = 0, error = 0;
  dsh_guest_result result{-1, 0, 0};
};
std::atomic<uint64_t> next_id{1};
// At most one unsettled kernel exists. Intentionally retained until process exit;
// no Env/JS handles survive cleanup, and no later job may enter a quarantined kernel.
std::mutex quarantine_mutex;
auto *quarantine = new std::shared_ptr<Job>();

napi_value fail(napi_env env, int error, const char *message) {
  bool pending = false;
  napi_is_exception_pending(env, &pending);
  if (pending) return nullptr;
  napi_value text, value, number, code;
  if (napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &text) != napi_ok ||
      napi_create_error(env, nullptr, text, &value) != napi_ok) return nullptr;
  napi_create_int32(env, error, &number);
  napi_set_named_property(env, value, "errno", number);
  napi_create_string_utf8(env, "ERR_IOS_GUEST_NATIVE", NAPI_AUTO_LENGTH, &code);
  napi_set_named_property(env, value, "code", code);
  napi_throw(env, value);
  return nullptr;
}
napi_value undefined(napi_env env) {
  napi_value value = nullptr;
  napi_get_undefined(env, &value);
  return value;
}
bool string(napi_env env, napi_value value, std::string &out, size_t limit) {
  napi_valuetype type;
  size_t length;
  if (napi_typeof(env, value, &type) != napi_ok || type != napi_string ||
      napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > limit) return false;
  std::vector<char> bytes(length + 1);
  if (napi_get_value_string_utf8(env, value, bytes.data(), bytes.size(), &length) != napi_ok) return false;
  out.assign(bytes.data(), length);
  return out.find('\0') == std::string::npos;
}
bool property_string(napi_env env, napi_value object, const char *name, std::string &out) {
  napi_value value;
  return napi_get_named_property(env, object, name, &value) == napi_ok &&
         string(env, value, out, 4096) && !out.empty();
}
bool identity_number(napi_env env, napi_value object, const char *name, uint64_t &out) {
  napi_value key; bool own = false; std::string value;
  if (napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &key) != napi_ok ||
      napi_has_own_property(env, object, key, &own) != napi_ok || !own ||
      !property_string(env, object, name, value) || value.size() > 20) return false;
  if (value.size() > 1 && value[0] == '0') return false;
  auto parsed = std::from_chars(value.data(), value.data() + value.size(), out);
  return parsed.ec == std::errc{} && parsed.ptr == value.data() + value.size();
}
bool strings(napi_env env, napi_value object, const char *name,
             std::vector<std::string> &out, size_t &budget) {
  napi_value values, value;
  bool array;
  uint32_t count;
  if (napi_get_named_property(env, object, name, &values) != napi_ok ||
      napi_is_array(env, values, &array) != napi_ok || !array ||
      napi_get_array_length(env, values, &count) != napi_ok || count > 256) return false;
  for (uint32_t i = 0; i < count; ++i) {
    std::string item;
    if (napi_get_element(env, values, i, &value) != napi_ok ||
        !string(env, value, item, budget) || item.size() + 1 > budget) return false;
    budget -= item.size() + 1;
    out.push_back(std::move(item));
  }
  return true;
}
std::vector<const char *> pointers(const std::vector<std::string> &strings) {
  std::vector<const char *> result;
  for (const auto &s : strings) result.push_back(s.c_str());
  result.push_back(nullptr);
  return result;
}
bool id_value(napi_env env, napi_value value, uint64_t &id) {
  bool exact = false;
  return napi_get_value_bigint_uint64(env, value, &id, &exact) == napi_ok && exact && id;
}
std::shared_ptr<Job> find_job(Owner *o, uint64_t id) {
  std::lock_guard<std::mutex> lock(o->mutex);
  return !o->closed && o->active && o->active->id == id ? o->active : nullptr;
}
// Called only with Owner.mutex held. Closing and every send use the same lock.
void wake(Owner *o) { if (!o->closed) uv_async_send(&o->async); }
void drop_js(const std::shared_ptr<Job> &job) {
  napi_env env = job->owner->env;
  if (job->async_context) { napi_async_destroy(env, job->async_context); job->async_context = nullptr; }
  if (job->resource) { napi_delete_reference(env, job->resource); job->resource = nullptr; }
  if (job->callback) { napi_delete_reference(env, job->callback); job->callback = nullptr; }
}
void abandon(const std::shared_ptr<Job> &job, int error) {
  uint64_t native_id;
  {
    std::lock_guard<std::mutex> lock(job->owner->mutex);
    job->abandoned = true;
    if (!job->delivery_error) job->delivery_error = error;
    native_id = job->native_id;
    job->owner->changed.notify_all();
  }
  if (native_id) dsh_guest_abandon(native_id); // Non-blocking request, never join.
}
int output(void *context, int stream, uint64_t end, const void *bytes, size_t size) {
  auto *job = static_cast<Job *>(context);
  auto *o = job->owner;
  if ((stream != 1 && stream != 2) || !size || size > 65536 || end < size) return EINVAL;
  try {
    auto chunk = std::make_shared<Chunk>();
    chunk->start = end - size;
    chunk->end = end;
    chunk->bytes.assign(static_cast<const char *>(bytes), static_cast<const char *>(bytes) + size);
    std::unique_lock<std::mutex> lock(o->mutex);
    // A backend may emit before start() returns its native id. No ACK is legal
    // until the coordinator publishes that id; teardown can always interrupt.
    o->changed.wait(lock, [&] { return job->start_ready || job->cancel || job->kill || job->abandoned || o->closed; });
    if (job->cancel || job->kill || job->abandoned || o->closed) return ECANCELED;
    if (job->pending[stream - 1] || chunk->start != job->confirmed[stream - 1]) return EPROTO;
    job->pending[stream - 1] = chunk;
    wake(o);
    o->changed.wait(lock, [&] { return chunk->acked || job->cancel || job->kill || job->abandoned || o->closed; });
    job->pending[stream - 1].reset();
    // ECANCELED makes the C bridge discard/drain, never falsely ACK bytes.
    // Signal choice remains in control(): cancel=TERM escalation, kill=KILL.
    return chunk->acked ? 0 : ECANCELED;
  } catch (const std::bad_alloc &) { return ENOMEM; }
}
void coordinate(std::shared_ptr<Job> job) {
  auto *o = job->owner;
  int error = 0;
  uint64_t native_id = 0;
  try {
    auto protected_paths = pointers(job->protected_paths);
    dsh_guest_options options{job->root.c_str(), protected_paths.data(), job->protected_paths.size()};
    bool stopped;
    { std::lock_guard<std::mutex> lock(o->mutex); stopped = job->abandoned || o->closed || job->cancel || job->kill; }
    error = stopped ? ECANCELED : dsh_guest_initialize(&options);
    // Successful initialize permanently excludes the Swift install-change lease.
    // Check the approved installation generation after that gate, not before it.
    if (!error && job->root_writable) {
      struct stat identity{};
      if (lstat(job->root.c_str(), &identity) != 0) error = errno;
      else if (!S_ISDIR(identity.st_mode) ||
          static_cast<uint64_t>(identity.st_dev) != job->root_device ||
          static_cast<uint64_t>(identity.st_ino) != job->root_inode) error = ESTALE;
    }
    if (!error) {
      auto argv = pointers(job->argv), env = pointers(job->env);
      dsh_guest_request request{argv.data(), job->argv.size(), env.data(), job->env.size(),
          job->cwd.c_str(), job->workspace.c_str(), job->temporary.c_str(), job->read_only ? 1 : 0};
      error = dsh_guest_start_with_permissions(&request, output, job.get(), &native_id,
          job->root_writable ? 1 : 0,
          job->clock.value.now_ms, job->clock.value.context);
    }
  } catch (const std::bad_alloc &) { error = ENOMEM; }
  bool cancelled, killed, dropped, stdin_closed;
  {
    std::lock_guard<std::mutex> lock(o->mutex);
    job->native_id = native_id;
    job->start_ready = true;
    job->started = !error;
    cancelled = job->cancel; killed = job->kill;
    dropped = job->abandoned || o->closed; stdin_closed = job->close_stdin;
    o->changed.notify_all();
    wake(o);
  }
  // A failed start borrows no callback context, but may have entered the
  // backend's permanent quarantine with partially constructed task/mounts.
  // Do not report those native resources as fully settled.
  dsh_guest_result result{-1, dropped ? 1 : 0,
      error && dsh_guest_status() != DSH_GUEST_QUARANTINED ? 1 : 0};
  if (!error) {
    if (dropped) dsh_guest_abandon(native_id);
    else if (killed) dsh_guest_kill(native_id);
    else if (cancelled) dsh_guest_cancel(native_id);
    if (stdin_closed) dsh_guest_stdin_close(native_id);
    // This is a cleanup budget after cancel/abandon, NOT a normal task deadline.
    error = dsh_guest_wait(native_id, 2000, &result);
    if (error || !result.resources_settled) {
      abandon(job, error ? error : EIO);
      // C still may borrow the output context. Keep it, without retaining JS.
      std::lock_guard<std::mutex> lock(quarantine_mutex);
      *quarantine = job;
    }
  }
  {
    std::lock_guard<std::mutex> lock(o->mutex);
    job->error = job->delivery_error ? job->delivery_error : error;
    job->result = result;
    job->done = true;
    wake(o);
  }
}
bool set(napi_env env, napi_value object, const char *name, napi_value value) {
  return napi_set_named_property(env, object, name, value) == napi_ok;
}
bool event_base(napi_env env, const std::shared_ptr<Job> &job, const char *type, napi_value &event) {
  napi_value name, id;
  return napi_create_object(env, &event) == napi_ok &&
         napi_create_string_utf8(env, type, NAPI_AUTO_LENGTH, &name) == napi_ok &&
         napi_create_bigint_uint64(env, job->id, &id) == napi_ok &&
         set(env, event, "type", name) && set(env, event, "id", id);
}
bool invoke(const std::shared_ptr<Job> &job, napi_value event) {
  napi_env env = job->owner->env;
  napi_value callback, global, ignored;
  napi_status status = napi_get_reference_value(env, job->callback, &callback);
  if (status == napi_ok) status = napi_get_global(env, &global);
  if (status == napi_ok) status = napi_make_callback(env, job->async_context, global, callback, 1, &event, &ignored);
  if (status != napi_ok) {
    bool pending = false;
    napi_is_exception_pending(env, &pending);
    if (pending) napi_get_and_clear_last_exception(env, &ignored);
    abandon(job, EIO); // Later exit reports the delivery error; never fake ACK.
    return false;
  }
  return true;
}
void dispatch(uv_async_t *handle) {
  auto *o = static_cast<Owner *>(handle->data);
  std::shared_ptr<Job> job;
  bool started = false;
  {
    std::lock_guard<std::mutex> lock(o->mutex);
    if (o->closed || !(job = o->active)) return;
    if (job->started && !job->start_sent) { job->start_sent = true; started = true; }
  }
  napi_handle_scope scope;
  if (napi_open_handle_scope(o->env, &scope) != napi_ok) { abandon(job, EIO); return; }
  napi_value event;
  if (started && (!event_base(o->env, job, "started", event) || !invoke(job, event))) abandon(job, EIO);
  for (int stream = 1; stream <= 2; ++stream) {
    std::shared_ptr<Chunk> chunk;
    {
      std::lock_guard<std::mutex> lock(o->mutex);
      if (!job->cancel && !job->kill && !job->abandoned &&
          (chunk = job->pending[stream - 1]) && !chunk->delivered)
        chunk->delivered = true;
      else chunk.reset();
    }
    if (!chunk) continue;
    napi_value end, bytes;
    if (!event_base(o->env, job, stream == 1 ? "stdout" : "stderr", event) ||
        napi_create_bigint_uint64(o->env, chunk->end, &end) != napi_ok ||
        napi_create_buffer_copy(o->env, chunk->bytes.size(), chunk->bytes.data(), nullptr, &bytes) != napi_ok ||
        !set(o->env, event, "end", end) || !set(o->env, event, "data", bytes) || !invoke(job, event)) abandon(job, EIO);
  }
  bool finished = false;
  int error = 0;
  dsh_guest_result result{};
  {
    std::lock_guard<std::mutex> lock(o->mutex);
    if (job->done && !job->exit_sent) {
      job->exit_sent = true;
      finished = true; error = job->error; result = job->result;
      if (o->active == job) o->active.reset();
      o->finishing = job;
    }
  }
  if (finished) {
    // Before invoking JS: an exit callback may synchronously start the next job.
    uv_unref(reinterpret_cast<uv_handle_t *>(&o->async));
    napi_value value;
    bool valid = event_base(o->env, job, "exit", event);
    valid = valid && napi_create_int32(o->env, result.exit_code, &value) == napi_ok && set(o->env, event, "exitCode", value);
    valid = valid && napi_create_int32(o->env, error, &value) == napi_ok && set(o->env, event, "error", value);
    // Host errno numbers differ between Darwin and Linux. Expose a stable
    // code for old snapshots that attempt a task after a record was retained.
    if (error == EOWNERDEAD)
      valid = valid && napi_create_string_utf8(o->env, "ios_guest_suspended", NAPI_AUTO_LENGTH, &value) == napi_ok && set(o->env, event, "errorCode", value);
    valid = valid && napi_get_boolean(o->env, result.abandoned != 0, &value) == napi_ok && set(o->env, event, "abandoned", value);
    valid = valid && napi_get_boolean(o->env, result.resources_settled != 0, &value) == napi_ok && set(o->env, event, "resourcesSettled", value);
    if (valid) invoke(job, event);
    drop_js(job);
    { std::lock_guard<std::mutex> lock(o->mutex); o->finishing.reset(); }
  }
  napi_close_handle_scope(o->env, scope);
}
void closed(uv_handle_t *handle) {
  auto *o = static_cast<Owner *>(handle->data);
  if (o->hook) { napi_remove_async_cleanup_hook(o->hook); o->hook = nullptr; }
  release(o);
}
void cleanup(napi_async_cleanup_hook_handle, void *context) {
  auto *o = static_cast<Owner *>(context);
  std::shared_ptr<Job> job;
  std::shared_ptr<Job> finishing;
  {
    std::lock_guard<std::mutex> lock(o->mutex);
    o->closed = true;
    job = std::move(o->active);
    finishing = std::move(o->finishing);
    if (job) job->abandoned = true;
    o->changed.notify_all();
  }
  if (job) { abandon(job, ECANCELED); drop_js(job); }
  if (finishing) drop_js(finishing);
  // There is no join, output flush, guest wait or ACK barrier on this thread.
  uv_close(reinterpret_cast<uv_handle_t *>(&o->async), closed);
}
napi_value start(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  void *context;
  if (napi_get_cb_info(env, info, &argc, args, nullptr, &context) != napi_ok || argc != 2)
    return fail(env, EINVAL, "start requires a request and an output callback");
  auto *o = static_cast<Owner *>(context);
  napi_valuetype type;
  if (napi_typeof(env, args[1], &type) != napi_ok || type != napi_function)
    return fail(env, EINVAL, "start callback must be a function");
  try {
    auto job = std::make_shared<Job>(o);
    size_t budget = 131072;
    napi_value read_only;
    if (!property_string(env, args[0], "root", job->root) ||
        !property_string(env, args[0], "cwd", job->cwd) ||
        !property_string(env, args[0], "workspace", job->workspace) ||
        !property_string(env, args[0], "temporary", job->temporary) ||
        !strings(env, args[0], "argv", job->argv, budget) || job->argv.empty() || job->argv[0].empty() ||
        !strings(env, args[0], "env", job->env, budget) ||
        napi_get_named_property(env, args[0], "readOnly", &read_only) != napi_ok ||
        napi_get_value_bool(env, read_only, &job->read_only) != napi_ok) return fail(env, EINVAL, "invalid guest request");
    // Trusted channel supplies this only after a separate per-call root grant.
    // Missing means false, including for a writable workspace.
    bool has_root_writable = false;
    napi_value root_writable, root_writable_key;
    if (napi_create_string_utf8(env, "rootWritable", NAPI_AUTO_LENGTH, &root_writable_key) != napi_ok ||
        napi_has_own_property(env, args[0], root_writable_key, &has_root_writable) != napi_ok ||
        (has_root_writable &&
         (napi_get_named_property(env, args[0], "rootWritable", &root_writable) != napi_ok ||
          napi_get_value_bool(env, root_writable, &job->root_writable) != napi_ok)))
      return fail(env, EINVAL, "rootWritable must be a boolean when present");
    if (job->root_writable &&
        (!identity_number(env, args[0], "expectedRootDevice", job->root_device) ||
         !identity_number(env, args[0], "expectedRootInode", job->root_inode)))
      return fail(env, EINVAL, "rootWritable requires the approved installation identity");
    budget = 131072;
    if (!strings(env, args[0], "protectedPaths", job->protected_paths, budget)) return fail(env, EINVAL, "invalid protected paths");
    {
      std::lock_guard<std::mutex> lock(o->mutex);
      if (o->closed || o->active) return fail(env, EBUSY, "this Environment already owns a guest task");
      const auto *identity = o->root_identity.get();
      if (job->root_writable && (!identity || identity->path != job->root ||
          identity->device != job->root_device || identity->inode != job->root_inode))
        return fail(env, ESTALE, "the approved Linux installation has no matching retained identity");
    }
    const int clock_error = job->clock.acquire();
    if (clock_error) return fail(env, clock_error, "embedded Host activity clock is unavailable; rebuild Host and Guest frameworks together");
    napi_value resource, name;
    if (napi_create_object(env, &resource) != napi_ok ||
        napi_create_string_utf8(env, "DshGuestTask", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_reference(env, resource, 1, &job->resource) != napi_ok ||
        napi_async_init(env, resource, name, &job->async_context) != napi_ok ||
        napi_create_reference(env, args[1], 1, &job->callback) != napi_ok) {
      drop_js(job);
      return fail(env, ENOMEM, "cannot create guest callback resources");
    }
    job->id = next_id.fetch_add(1);
    napi_value id;
    if (!job->id || napi_create_bigint_uint64(env, job->id, &id) != napi_ok) { drop_js(job); return fail(env, EOVERFLOW, "guest task id unavailable"); }
    { std::lock_guard<std::mutex> lock(o->mutex); o->active = job; }
    uv_ref(reinterpret_cast<uv_handle_t *>(&o->async));
    try { std::thread(coordinate, job).detach(); }
    catch (const std::system_error &) {
      { std::lock_guard<std::mutex> lock(o->mutex); o->active.reset(); }
      uv_unref(reinterpret_cast<uv_handle_t *>(&o->async));
      drop_js(job);
      return fail(env, EAGAIN, "cannot start guest coordinator");
    }
    return id;
  } catch (const std::bad_alloc &) { return fail(env, ENOMEM, "cannot allocate guest request"); }
}
napi_value control(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  void *context;
  if (napi_get_cb_info(env, info, &argc, args, nullptr, &context) != napi_ok || !argc) return fail(env, EINVAL, "guest task id required");
  auto *entry = static_cast<std::pair<Owner *, int> *>(context);
  uint64_t id;
  if (!id_value(env, args[0], id)) return fail(env, EINVAL, "guest task id must be a positive bigint");
  auto job = find_job(entry->first, id);
  if (!job) return fail(env, ESTALE, "guest task does not belong to this Environment");
  auto *o = job->owner;
  int error = 0;
  uint64_t native_id;
  if (entry->second == 1) { // ACK only a chunk already handed to JavaScript.
    int32_t stream;
    uint64_t end;
    bool exact = false;
    if (argc != 3 || napi_get_value_int32(env, args[1], &stream) != napi_ok || (stream != 1 && stream != 2) ||
        napi_get_value_bigint_uint64(env, args[2], &end, &exact) != napi_ok || !exact)
      return fail(env, EINVAL, "invalid output acknowledgement");
    {
      std::lock_guard<std::mutex> lock(o->mutex);
      // Cancellation discards pending output; a late ACK is no longer a
      // delivery confirmation. Do not call native ACK or advance confirmed.
      // After exit, find_job rejects this old id as ESTALE, including when
      // another job has already started in the same Environment.
      if (job->cancel || job->kill) return undefined(env);
      auto chunk = job->pending[stream - 1];
      if (!chunk || !chunk->delivered || chunk->acked || chunk->end != end ||
          chunk->start != job->confirmed[stream - 1] || job->abandoned) error = EINVAL;
      else if (!(error = dsh_guest_ack(job->native_id, stream, end))) {
        chunk->acked = true;
        job->confirmed[stream - 1] = end;
        o->changed.notify_all();
      }
    }
  } else if (entry->second == 2) {
    bool buffer = false;
    void *bytes; size_t size;
    if (argc != 2 || napi_is_buffer(env, args[1], &buffer) != napi_ok || !buffer ||
        napi_get_buffer_info(env, args[1], &bytes, &size) != napi_ok || size > 65536)
      return fail(env, EINVAL, "stdinWrite requires a Buffer of at most 65536 bytes");
    { std::lock_guard<std::mutex> lock(o->mutex); native_id = job->native_id; }
    if (!native_id) return fail(env, EAGAIN, "guest task is starting");
    size_t written = 0;
    error = dsh_guest_stdin_write(native_id, bytes, size, &written);
    if (!error) { napi_value value; napi_create_uint32(env, static_cast<uint32_t>(written), &value); return value; }
  } else if (entry->second == 6) {
    abandon(job, ECANCELED);
  } else {
    { std::lock_guard<std::mutex> lock(o->mutex);
      native_id = job->native_id;
      if (entry->second == 3) job->close_stdin = true;
      if (entry->second == 4) job->cancel = true;
      if (entry->second == 5) job->kill = true;
      if (job->cancel || job->kill) o->changed.notify_all();
    }
    if (native_id) {
      if (entry->second == 3) error = dsh_guest_stdin_close(native_id);
      if (entry->second == 4) error = dsh_guest_cancel(native_id);
      if (entry->second == 5) error = dsh_guest_kill(native_id);
    }
  }
  return error ? fail(env, error, "guest operation failed") : undefined(env);
}
napi_value status(napi_env env, napi_callback_info) {
  static const char *names[] = {"cold", "ready", "running", "quarantined"};
  auto state = dsh_guest_status();
  napi_value result, value;
  napi_create_object(env, &result);
  napi_create_string_utf8(env, names[static_cast<unsigned>(state) < 4 ? state : DSH_GUEST_QUARANTINED], NAPI_AUTO_LENGTH, &value);
  set(env, result, "state", value);
  napi_get_boolean(env, true, &value); set(env, result, "available", value);
  return result;
}
napi_value root_identity(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 2;
    napi_value args[2];
    void *context = nullptr;
    std::string path;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, &context) != napi_ok || argc != 1 ||
        !string(env, args[0], path, 4096) || path.empty() || path[0] != '/')
      return fail(env, EINVAL, "an installed Linux directory is required");
    auto *o = static_cast<Owner *>(context);
    std::lock_guard<std::mutex> lock(o->mutex);
    if (o->closed) return fail(env, ECANCELED, "guest Environment is closed");
    std::unique_ptr<RootIdentity> candidate;
    auto *identity = o->root_identity.get();
    if (identity && identity->path != path)
      return fail(env, ESTALE, "the Linux installation identity cannot be replaced");
    if (!identity) {
      candidate = std::make_unique<RootIdentity>();
      candidate->path = path;
      candidate->fd = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (candidate->fd < 0) return fail(env, errno, "cannot retain the Linux installation identity");
      identity = candidate.get();
    }
    struct stat retained{}, current{};
    if (fstat(identity->fd, &retained) != 0 || lstat(path.c_str(), &current) != 0)
      return fail(env, errno, "cannot inspect the Linux installation identity");
    if (!S_ISDIR(retained.st_mode) || !S_ISDIR(current.st_mode) ||
        retained.st_dev != current.st_dev || retained.st_ino != current.st_ino)
      return fail(env, ESTALE, "the Linux installation identity changed");
    if (candidate) {
      identity->device = static_cast<uint64_t>(retained.st_dev);
      identity->inode = static_cast<uint64_t>(retained.st_ino);
    }
    const auto device = std::to_string(identity->device), inode = std::to_string(identity->inode);
    napi_value result, value;
    if (napi_create_object(env, &result) != napi_ok ||
        napi_create_string_utf8(env, device.c_str(), NAPI_AUTO_LENGTH, &value) != napi_ok ||
        !set(env, result, "expectedRootDevice", value) ||
        napi_create_string_utf8(env, inode.c_str(), NAPI_AUTO_LENGTH, &value) != napi_ok ||
        !set(env, result, "expectedRootInode", value))
      return fail(env, ENOMEM, "cannot publish the Linux installation identity");
    if (candidate) o->root_identity = std::move(candidate);
    return result;
  } catch (const std::bad_alloc &) {
    return fail(env, ENOMEM, "cannot retain the Linux installation identity");
  }
}
napi_value init(napi_env env, napi_value exports);
bool pin_module() {
  static std::once_flag once;
  static void *resident = nullptr;
  std::call_once(once, [] {
    Dl_info image{};
    // Node Worker destruction dlcloses its addons. Native cleanup can outlive
    // that Worker, so retain this already loaded image once for the App process.
    // The path comes from our own code address, never from a caller or data file.
    if (dladdr(reinterpret_cast<void *>(init), &image) && image.dli_fname)
      resident = dlopen(image.dli_fname, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
  });
  return resident != nullptr;
}
// Callback data lives with Owner; never separately freed by a JS finalizer.
napi_value init(napi_env env, napi_value exports) {
  if (!pin_module()) return fail(env, EIO, "cannot retain guest addon during native cleanup");
  auto *o = new (std::nothrow) Owner;
  if (!o) return fail(env, ENOMEM, "cannot allocate guest Environment");
  o->env = env;
  uv_loop_t *loop;
  if (napi_get_uv_event_loop(env, &loop) != napi_ok || uv_async_init(loop, &o->async, dispatch)) {
    delete o; return fail(env, EIO, "cannot create guest event channel");
  }
  o->async.data = o;
  uv_unref(reinterpret_cast<uv_handle_t *>(&o->async));
  if (napi_add_async_cleanup_hook(env, cleanup, o, &o->hook) != napi_ok) {
    uv_close(reinterpret_cast<uv_handle_t *>(&o->async), closed);
    return fail(env, EIO, "cannot register guest cleanup");
  }
  const char *names[] = {"ack", "stdinWrite", "stdinClose", "cancel", "kill", "abandon"};
  napi_property_descriptor properties[9]{};
  properties[0] = {"start", nullptr, start, nullptr, nullptr, nullptr, napi_default, o};
  properties[1] = {"status", nullptr, status, nullptr, nullptr, nullptr, napi_default, nullptr};
  for (int i = 0; i < 6; ++i) {
    o->methods[i] = {o, i + 1};
    properties[i + 2] = {names[i], nullptr, control, nullptr, nullptr, nullptr, napi_default, &o->methods[i]};
  }
  properties[8] = {"rootIdentity", nullptr, root_identity, nullptr, nullptr, nullptr, napi_default, o};
  if (napi_define_properties(env, exports, 9, properties) != napi_ok) return fail(env, EIO, "cannot expose guest methods");
  return exports;
}
} // namespace
NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
