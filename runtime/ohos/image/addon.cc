// Node-only TU: fixed Node 24.22.1 headers, production full napi-rename.h.
// No Ark/NDK/uv headers. Backend work never calls a Node-API function.
#include <node_api.h>
#include "codec_bridge.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#ifdef DSH_IMAGE_HOST_FIXTURE
#include "image-codec-fake.h"
#endif

namespace {
struct State;
struct Job;
struct Frame;
enum class Kind { Inspect, Open, Encode, Close, Cleanup };

struct Frame {
  State* state = nullptr;                 // Cleared before State can be deleted.
  napi_env owner_env = nullptr;
  DshImageFrame* native = nullptr;
  std::vector<uint8_t> input;             // Retained until confirmed close.
  DshImageFacts source{};
  DshImageFacts working{};
  std::deque<Job*> waiting;               // Created but not yet queued work.
  Job* active = nullptr;
  Job* close_job = nullptr;               // Pre-created before open dispatch.
  bool close_requested = false;
  bool closed = false;
  bool wrapper_gone = false;
  bool close_unconfirmed = false;
  napi_deferred close_deferred = nullptr;
  napi_ref close_promise = nullptr;
  napi_deferred failed_open = nullptr;    // Reject only after close has settled.
  DshImageStatus open_error = DSH_IMAGE_INTERNAL;
  int32_t open_native_status = 0;
  const char* open_stage = "open";
};

struct State {
  napi_env env = nullptr;
  const DshImageBackend* backend = nullptr;
  bool available = false;
  bool closing = false;
  bool cleanup_queued = false;
  bool quarantined = false;
  size_t scheduled = 0;                  // Includes running, until complete.
  size_t cleanup_unconfirmed = 0;
  napi_async_cleanup_hook_handle cleanup_hook = nullptr;
  Job* cleanup_job = nullptr;             // Created at module initialization.
  std::unordered_map<Frame*, std::shared_ptr<Frame>> frames;
};

struct Job {
  State* state;
  Kind kind;
  std::shared_ptr<Frame> frame;
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  bool queued = false;
  std::vector<uint8_t> input;
  DshImageLimits limits{};
  DshImageTarget target{};
  DshImageFacts facts{};
  DshImageEncoded output{};
  DshImageStatus result = DSH_IMAGE_OK;
  DshImageError error{};
  const char* stage = nullptr;
  Job(State* s, Kind k) : state(s), kind(k) {}
};

constexpr napi_type_tag kFrameTag = {
  UINT64_C(0x8edc941364b70aa2), UINT64_C(0xb1f04e5d53c77269)
};
constexpr uint32_t kAllKnown = (1u << 9) - 1u;
constexpr double kMaxSafe = 9007199254740991.0;

void Execute(napi_env, void*);
void Complete(napi_env, napi_status, void*);
void MaybeStartCleanup(State*);
void PumpFrame(const std::shared_ptr<Frame>&, bool);
void FrameFinalizer(napi_env, void*, void*);
napi_value Encode(napi_env, napi_callback_info);
napi_value Close(napi_env, napi_callback_info);

bool Check(napi_env env, napi_status status) {
  if (status == napi_ok) return true;
  bool pending = false;
  if (napi_is_exception_pending(env, &pending) == napi_ok && !pending)
    napi_throw_error(env, "OHOS_IMAGE_BRIDGE_ERROR", "Node image bridge operation failed");
  return false;
}

napi_value Undefined(napi_env env) {
  napi_value value = nullptr;
  return Check(env, napi_get_undefined(env, &value)) ? value : nullptr;
}

bool Put(napi_env env, napi_value object, const char* key, napi_value value) {
  return value && Check(env, napi_set_named_property(env, object, key, value));
}

napi_value String(napi_env env, const char* text) {
  napi_value value = nullptr;
  return Check(env, napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &value))
      ? value : nullptr;
}

napi_value UInt(napi_env env, uint32_t number) {
  napi_value value = nullptr;
  return Check(env, napi_create_uint32(env, number, &value)) ? value : nullptr;
}

napi_value Bool(napi_env env, bool flag) {
  napi_value value = nullptr;
  return Check(env, napi_get_boolean(env, flag, &value)) ? value : nullptr;
}

napi_value Null(napi_env env) {
  napi_value value = nullptr;
  return Check(env, napi_get_null(env, &value)) ? value : nullptr;
}

const char* Mime(uint32_t format) {
  switch (format) {
    case DSH_IMAGE_CODEC_FORMAT_PNG: return "image/png";
    case DSH_IMAGE_CODEC_FORMAT_JPEG: return "image/jpeg";
    case DSH_IMAGE_CODEC_FORMAT_WEBP: return "image/webp";
    case DSH_IMAGE_CODEC_FORMAT_GIF: return "image/gif";
    default: return nullptr;
  }
}

const char* Code(DshImageStatus status) {
  switch (status) {
    case DSH_IMAGE_UNAVAILABLE: return "OHOS_IMAGE_CODEC_UNAVAILABLE";
    case DSH_IMAGE_INVALID: return "INVALID_IMAGE";
    case DSH_IMAGE_EDGE_LIMIT: return "IMAGE_DIMENSION_TOO_LARGE";
    case DSH_IMAGE_PIXEL_LIMIT: return "IMAGE_TOO_MANY_PIXELS";
    case DSH_IMAGE_CLEANUP_UNCONFIRMED: return "OHOS_IMAGE_CLEANUP_UNCONFIRMED";
    default: return "ATTACHMENT_WRITE_FAILED";
  }
}

napi_value Error(napi_env env, const char* code, const char* stage,
                 int32_t native_status, bool retired = false) {
  napi_value error = nullptr, raw = nullptr;
  napi_value c = String(env, code);
  napi_value message = String(env, "OH image codec operation did not complete");
  if (!c || !message || !Check(env, napi_create_error(env, c, message, &error)) ||
      !Check(env, napi_create_int32(env, native_status, &raw)) ||
      !Put(env, error, "stage", String(env, stage)) ||
      !Put(env, error, "nativeStatus", raw) ||
      !Put(env, error, "encodingCapBytes", UInt(env, static_cast<uint32_t>(DSH_IMAGE_ENCODE_CAP))) ||
      !Put(env, error, "resourcesRetired", Bool(env, retired))) return nullptr;
  return error;
}

void Reject(napi_env env, napi_deferred deferred, const char* code,
            const char* stage, int32_t raw = 0, bool retired = false) {
  if (!deferred) return;
  bool pending = false;
  napi_value error = nullptr;
  if (napi_is_exception_pending(env, &pending) == napi_ok && pending)
    napi_get_and_clear_last_exception(env, &error);
  if (!error) error = Error(env, code, stage, raw, retired);
  if (error) napi_reject_deferred(env, deferred, error);
}

napi_value Rejected(napi_env env, const char* code, const char* stage) {
  napi_deferred deferred = nullptr;
  napi_value promise = nullptr;
  if (!Check(env, napi_create_promise(env, &deferred, &promise))) return nullptr;
  Reject(env, deferred, code, stage);
  return promise;
}

bool ValidFacts(const DshImageFacts& f) {
  if (f.struct_size != sizeof(f) || (f.known & ~kAllKnown)) return false;
  if ((f.known & DSH_IMAGE_FACT_DIMENSIONS) && (!f.width || !f.height)) return false;
  if ((f.known & DSH_IMAGE_FACT_FORMAT) && !Mime(f.format)) return false;
  if ((f.known & DSH_IMAGE_FACT_FRAMES) && !f.frame_count) return false;
  if ((f.known & DSH_IMAGE_FACT_ORIENTATION) && (f.orientation < 1 || f.orientation > 8)) return false;
  if ((f.known & DSH_IMAGE_FACT_ALPHA) && f.has_alpha > 1) return false;
  if ((f.known & DSH_IMAGE_FACT_DEPTH) && !f.bit_depth) return false;
  if ((f.known & DSH_IMAGE_FACT_COLOR) &&
      f.color_space != DSH_IMAGE_COLOR_SRGB && f.color_space != DSH_IMAGE_COLOR_OTHER) return false;
  if ((f.known & DSH_IMAGE_FACT_METADATA) && f.retained_metadata > 1) return false;
  return true;
}

napi_value Facts(napi_env env, const DshImageFacts& f) {
  napi_value out = nullptr;
  if (!ValidFacts(f) || !Check(env, napi_create_object(env, &out))) return nullptr;
  const auto number = [&](uint32_t bit, uint32_t n) {
    return (f.known & bit) ? UInt(env, n) : Null(env);
  };
  if (!Put(env, out, "width", number(DSH_IMAGE_FACT_DIMENSIONS, f.width)) ||
      !Put(env, out, "height", number(DSH_IMAGE_FACT_DIMENSIONS, f.height)) ||
      !Put(env, out, "mimeType", (f.known & DSH_IMAGE_FACT_FORMAT) ? String(env, Mime(f.format)) : Null(env)) ||
      !Put(env, out, "frameCount", number(DSH_IMAGE_FACT_FRAMES, f.frame_count)) ||
      !Put(env, out, "orientation", number(DSH_IMAGE_FACT_ORIENTATION, f.orientation)) ||
      !Put(env, out, "hasAlpha", (f.known & DSH_IMAGE_FACT_ALPHA) ? Bool(env, f.has_alpha != 0) : Null(env)) ||
      !Put(env, out, "bitDepth", number(DSH_IMAGE_FACT_DEPTH, f.bit_depth)) ||
      !Put(env, out, "colorSpace", (f.known & DSH_IMAGE_FACT_COLOR)
          ? String(env, f.color_space == DSH_IMAGE_COLOR_SRGB ? "srgb" : "other") : Null(env)) ||
      !Put(env, out, "retainedMetadata", (f.known & DSH_IMAGE_FACT_METADATA)
          ? Bool(env, f.retained_metadata != 0) : Null(env))) return nullptr;
  // Decimal text keeps this uint64_t exact; it is not a pixel-memory estimate.
  const std::string allocation = std::to_string(f.allocation_bytes);
  if (!Put(env, out, "allocationBytes", (f.known & DSH_IMAGE_FACT_ALLOCATION)
      ? String(env, allocation.c_str()) : Null(env))) return nullptr;
  return out;
}

bool PositiveInteger(napi_env env, napi_value object, const char* key,
                     double maximum, uint64_t* out, double minimum = 1) {
  napi_value value = nullptr;
  double number = 0;
  if (!Check(env, napi_get_named_property(env, object, key, &value)) ||
      !Check(env, napi_get_value_double(env, value, &number))) return false;
  if (!std::isfinite(number) || number < minimum || number > maximum || std::floor(number) != number) {
    napi_throw_range_error(env, "ERR_OUT_OF_RANGE", key);
    return false;
  }
  *out = static_cast<uint64_t>(number);
  return true;
}

bool Snapshot(napi_env env, napi_value value, std::vector<uint8_t>* result) {
  bool typed = false, ordinary = false;
  napi_typedarray_type type;
  size_t length = 0, offset = 0;
  void* bytes = nullptr;
  napi_value buffer = nullptr;
  if (!Check(env, napi_is_typedarray(env, value, &typed))) return false;
  if (!typed) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "Expected Buffer or Uint8Array");
    return false;
  }
  if (!Check(env, napi_get_typedarray_info(env, value, &type, &length, &bytes, &buffer, &offset)) ||
      !Check(env, napi_is_arraybuffer(env, buffer, &ordinary))) return false;
  if (type != napi_uint8_array || !ordinary || (length && !bytes)) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "Expected a non-shared Uint8Array");
    return false;
  }
  if (length) result->assign(static_cast<const uint8_t*>(bytes),
                             static_cast<const uint8_t*>(bytes) + length);
  return true;
}

bool CreateWork(Job* job, const char* name) {
  napi_value resource_name = String(job->state->env, name);
  return resource_name && Check(job->state->env, napi_create_async_work(
      job->state->env, nullptr, resource_name, Execute, Complete, job, &job->work));
}

bool Queue(Job* job) {
  napi_status result = napi_queue_async_work(job->state->env, job->work);
  if (result != napi_ok) return false;
  job->queued = true;
  ++job->state->scheduled;
  if (job->frame) job->frame->active = job;
  return true;
}

void DeleteUnqueued(Job* job) {
  if (!job) return;
  if (job->work) napi_delete_async_work(job->state->env, job->work);
  delete job;
}

void RecordFailedOpen(const std::shared_ptr<Frame>& f, Job* job) {
  f->failed_open = job->deferred;
  f->open_error = job->result == DSH_IMAGE_OK ? DSH_IMAGE_INTERNAL : job->result;
  f->open_native_status = job->error.native_status;
  f->open_stage = job->stage ? job->stage : "open";
  f->close_requested = true;
}

void SettleClose(napi_env env, const std::shared_ptr<Frame>& f,
                 DshImageStatus result, const char* stage, int32_t raw) {
  const bool retired = f->native == nullptr;
  if (f->failed_open) {
    if (result == DSH_IMAGE_OK && retired) {
      Reject(env, f->failed_open, Code(f->open_error), f->open_stage,
          f->open_native_status, true);
    } else {
      napi_value error = Error(env, retired ? Code(result) : "OHOS_IMAGE_CLEANUP_UNCONFIRMED",
          stage, raw, retired);
      napi_value cause = Error(env, Code(f->open_error), f->open_stage,
          f->open_native_status, false);
      if (error && cause && Put(env, error, "cause", cause))
        napi_reject_deferred(env, f->failed_open, error);
    }
    f->failed_open = nullptr;
  } else if (result == DSH_IMAGE_OK && retired) {
    napi_value value = Undefined(env);
    if (value && f->close_deferred) napi_resolve_deferred(env, f->close_deferred, value);
  } else Reject(env, f->close_deferred, retired ? Code(result) : "OHOS_IMAGE_CLEANUP_UNCONFIRMED",
      stage, raw, retired);
}

void ForgetClosed(const std::shared_ptr<Frame>& f) {
  if (f->native) return;
  State* state = f->state;
  f->closed = true;
  std::vector<uint8_t>().swap(f->input);
  f->state = nullptr;
  if (state) state->frames.erase(f.get());
}

void PumpFrame(const std::shared_ptr<Frame>& f, bool allow_js) {
  State* state = f->state;
  if (!state || state->closing || f->active || f->closed) return;
  while (!f->waiting.empty()) {
    if (!allow_js) return;
    Job* job = f->waiting.front();
    f->waiting.pop_front();
    if (Queue(job)) return;
    Reject(state->env, job->deferred, "OHOS_IMAGE_BRIDGE_ERROR", "queue-encode");
    DeleteUnqueued(job);
  }
  if (!f->close_requested || !f->close_job) return;
  Job* job = f->close_job;
  if (Queue(job)) return;
  f->close_job = nullptr;
  f->close_unconfirmed = true;
  state->quarantined = true;
  if (allow_js) SettleClose(state->env, f, DSH_IMAGE_CLEANUP_UNCONFIRMED, "queue-close", 0);
  // Native resources and input stay owned for the env cleanup pass.
  DeleteUnqueued(job);
}

void FrameFinalizer(napi_env env, void* data, void*) {
  auto* holder = static_cast<std::shared_ptr<Frame>*>(data);
  const auto f = *holder;
  f->wrapper_gone = true;
  f->close_requested = true;
  if (f->close_promise) {
    if (env) napi_delete_reference(env, f->close_promise);
    f->close_promise = nullptr;
  }
  // No creation/settlement of JS values from a GC finalizer. Queue is a
  // node_api_basic_env operation; work was created before the frame escaped.
  PumpFrame(f, false);
  delete holder;
}

std::shared_ptr<Frame> GetFrame(napi_env env, napi_callback_info info,
                                size_t* argc, napi_value* argv) {
  napi_value self = nullptr;
  bool tagged = false;
  void* data = nullptr;
  if (!Check(env, napi_get_cb_info(env, info, argc, argv, &self, nullptr)) ||
      !Check(env, napi_check_object_type_tag(env, self, &kFrameTag, &tagged))) return {};
  if (!tagged || napi_unwrap(env, self, &data) != napi_ok || !data) {
    napi_throw_type_error(env, "ERR_INVALID_THIS", "Expected this environment's image frame");
    return {};
  }
  auto f = *static_cast<std::shared_ptr<Frame>*>(data);
  if (f->owner_env != env) {
    napi_throw_type_error(env, "ERR_INVALID_THIS", "Image frame belongs to another environment");
    return {};
  }
  return f;
}

napi_value FrameObject(napi_env env, const std::shared_ptr<Frame>& f) {
  napi_value object = nullptr;
  if (!Check(env, napi_create_object(env, &object))) return nullptr;
  const napi_property_descriptor properties[] = {
    {"encode", nullptr, Encode, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr}
  };
  if (!Check(env, napi_define_properties(env, object, 2, properties)) ||
      !Put(env, object, "sourceFacts", Facts(env, f->source)) ||
      !Put(env, object, "workingFacts", Facts(env, f->working)) ||
      !Check(env, napi_type_tag_object(env, object, &kFrameTag))) return nullptr;
  auto* holder = new std::shared_ptr<Frame>(f);
  if (!Check(env, napi_wrap(env, object, holder, FrameFinalizer, nullptr, nullptr))) {
    delete holder;
    return nullptr;
  }
  return object;
}

void Execute(napi_env, void* data) {
  Job* job = static_cast<Job*>(data);
  State* state = job->state;
  const DshImageBackend* b = state->backend;
  // Only native data is accessed here. Never call any napi_* API.
  try {
    switch (job->kind) {
      case Kind::Inspect:
        job->facts.struct_size = sizeof(job->facts);
        job->result = b->inspect(job->input.data(), job->input.size(), &job->facts, &job->error);
        break;
      case Kind::Open:
        job->frame->source.struct_size = sizeof(DshImageFacts);
        job->frame->working.struct_size = sizeof(DshImageFacts);
        job->result = b->open(job->frame->input.data(), job->frame->input.size(), &job->limits,
            &job->frame->native, &job->frame->source, &job->frame->working, &job->error);
        break;
      case Kind::Encode:
        job->result = b->encode(job->frame->native, &job->target, &job->output, &job->error);
        break;
      case Kind::Close:
        job->result = b->close(&job->frame->native, &job->error);
        if (job->frame->native) job->result = DSH_IMAGE_CLEANUP_UNCONFIRMED;
        break;
      case Kind::Cleanup:
        for (auto& entry : state->frames) {
          auto& f = entry.second;
          DshImageError error{};
          if (f->native) b->close(&f->native, &error);
          if (f->native) {
            ++state->cleanup_unconfirmed;
          } else {
            f->closed = true;
            f->input.clear();
          }
        }
        break;
    }
    if (job->error.stage) job->stage = job->error.stage;
  } catch (...) {
    // A backend must not throw across the C ABI. Defensively retain ownership
    // rather than unwind through Node; real backend conformance is separate.
    job->result = DSH_IMAGE_INTERNAL;
    job->stage = "backend-contract";
    if (job->kind == Kind::Cleanup) ++state->cleanup_unconfirmed;
  }
}

void MaybeStartCleanup(State* state) {
  if (!state->closing || state->scheduled || state->cleanup_queued) return;
  Job* job = state->cleanup_job;
  state->cleanup_queued = true;
  if (job && Queue(job)) return;
  // No work can still touch a frame. This rare scheduling failure is a
  // synchronous native-only fallback, not an asynchronous latency claim.
  Execute(nullptr, job);
  Complete(state->env, napi_ok, job);
}

void CleanupHook(napi_async_cleanup_hook_handle handle, void* data) {
  State* state = static_cast<State*>(data);
  state->cleanup_hook = handle;
  state->closing = true;
#ifdef DSH_IMAGE_HOST_FIXTURE
  dsh_image_fake_cleanup_started();
#endif
  for (auto& entry : state->frames) {
    auto& f = entry.second;
    f->close_requested = true;
    for (Job* job : f->waiting) DeleteUnqueued(job);
    f->waiting.clear();
    if (f->close_job && !f->close_job->queued) {
      DeleteUnqueued(f->close_job);
      f->close_job = nullptr;
    }
  }
  // No cancellation claim: already queued/running work reaches its complete
  // callback. Do not delete it early, nor wait on the event loop synchronously.
  MaybeStartCleanup(state);
}

void Complete(napi_env env, napi_status status, void* data) {
  Job* job = static_cast<Job*>(data);
  State* state = job->state;
  auto frame = job->frame;
  if (job->queued) {
    --state->scheduled;
    if (frame) frame->active = nullptr;
  }
  // Even cancelled work is deleted only in its complete callback.
  if (job->work) napi_delete_async_work(env, job->work);
  job->work = nullptr;
  if (status != napi_ok) {
    job->result = DSH_IMAGE_INTERNAL;
    job->stage = "async-work-not-executed";
  }
  if (job->kind == Kind::Cleanup) {
    // Do not infer retirement from a success counter if execute was cancelled
    // or exited early. The actual remaining handle is the final authority.
    for (const auto& entry : state->frames)
      if (entry.second->native) ++state->cleanup_unconfirmed;
    state->cleanup_job = nullptr;
    delete job;
    if (state->cleanup_unconfirmed) {
      state->quarantined = true;
      std::fputs("OH image cleanup unconfirmed; environment retirement withheld\n", stderr);
      // Do not free still-owned input/handles, or falsely acknowledge teardown.
      // Real NDK backend must close this condition before production admission.
      return;
    }
    for (auto& entry : state->frames) {
      auto& f = entry.second;
      f->state = nullptr;
      if (f->close_promise) {
        napi_delete_reference(env, f->close_promise);
        f->close_promise = nullptr;
      }
    }
    state->frames.clear();
    const auto handle = state->cleanup_hook;
    state->cleanup_hook = nullptr;
    if (napi_remove_async_cleanup_hook(handle) != napi_ok) {
      state->quarantined = true;
      std::fputs("OH image async cleanup removal unconfirmed\n", stderr);
      return;
    }
    delete state;
    return;
  }
  if (job->kind == Kind::Close) {
    frame->close_job = nullptr;
    frame->close_unconfirmed = frame->native != nullptr;
    if (frame->close_unconfirmed) state->quarantined = true;
  }
  if (state->closing) {
    if (job->output.data) state->backend->release_encoded(&job->output);
    delete job;
    MaybeStartCleanup(state);
    return;
  }
  try {
    if (job->result == DSH_IMAGE_OK) {
      if (job->kind == Kind::Inspect && !ValidFacts(job->facts)) job->result = DSH_IMAGE_INTERNAL;
      if (job->kind == Kind::Open && (!frame->native || !ValidFacts(frame->source) ||
          !ValidFacts(frame->working))) job->result = DSH_IMAGE_INTERNAL;
      if (job->kind == Kind::Encode && (!job->output.data || !job->output.size ||
          job->output.size > job->output.capacity || job->output.capacity > DSH_IMAGE_ENCODE_CAP ||
          job->output.format != job->target.format || !ValidFacts(job->output.facts) ||
          (job->output.quality != 85 && job->output.quality != 75 && job->output.quality != 60)))
        job->result = DSH_IMAGE_INTERNAL;
    }
    if (job->kind == Kind::Close) {
      SettleClose(env, frame, job->result, job->stage ? job->stage : "close", job->error.native_status);
    } else if (job->kind == Kind::Open && job->result != DSH_IMAGE_OK && frame->native) {
      // A failed NDK open can still own source/PixelMap resources. The input
      // and deferred rejection stay alive until its automatic close completes.
      RecordFailedOpen(frame, job);
    } else if (job->result != DSH_IMAGE_OK) {
      Reject(env, job->kind == Kind::Close ? frame->close_deferred : job->deferred,
          Code(job->result), job->stage ? job->stage : "backend",
          job->error.native_status, frame && !frame->native);
    } else {
      napi_value result = nullptr;
      switch (job->kind) {
        case Kind::Inspect: result = Facts(env, job->facts); break;
        case Kind::Open: result = FrameObject(env, frame); break;
        case Kind::Encode: {
          napi_value buffer = nullptr;
          if (Check(env, napi_create_object(env, &result)) &&
              Check(env, napi_create_buffer_copy(env, job->output.size, job->output.data, nullptr, &buffer)) &&
              Put(env, result, "data", buffer) &&
              Put(env, result, "mimeType", String(env, Mime(job->output.format))) &&
              Put(env, result, "quality", UInt(env, job->output.quality)) &&
              Put(env, result, "encodedFacts", Facts(env, job->output.facts))) break;
          result = nullptr;
          break;
        }
        case Kind::Close: result = Undefined(env); break;
        case Kind::Cleanup: break;
      }
      napi_deferred deferred = job->kind == Kind::Close ? frame->close_deferred : job->deferred;
      if (result) {
        if (deferred && napi_resolve_deferred(env, deferred, result) != napi_ok && job->kind == Kind::Open)
          frame->close_requested = true;
      } else {
        if (job->kind == Kind::Open && frame->native) {
          bool pending = false;
          napi_value ignored = nullptr;
          if (napi_is_exception_pending(env, &pending) == napi_ok && pending)
            napi_get_and_clear_last_exception(env, &ignored);
          job->stage = "open-wrapper";
          RecordFailedOpen(frame, job);
        } else Reject(env, deferred, "OHOS_IMAGE_BRIDGE_ERROR", "complete");
      }
    }
  } catch (...) {
    if (job->kind == Kind::Open && frame->native) {
      job->stage = "open-wrapper-allocation";
      RecordFailedOpen(frame, job);
    } else Reject(env, job->kind == Kind::Close ? frame->close_deferred : job->deferred,
        "OHOS_IMAGE_BRIDGE_ERROR", "complete-allocation");
  }
  if (job->output.data) state->backend->release_encoded(&job->output);
  if (job->kind == Kind::Open && job->result != DSH_IMAGE_OK) {
    if (frame->native) frame->close_requested = true;
    else {
      DeleteUnqueued(frame->close_job);
      frame->close_job = nullptr;
      ForgetClosed(frame);
    }
  }
  if (job->kind == Kind::Close && !frame->native) ForgetClosed(frame);
  delete job;
  if (frame) PumpFrame(frame, true);
}

napi_value Start(napi_env env, napi_callback_info info, Kind kind) {
  size_t argc = 2;
  napi_value argv[2]{};
  void* data = nullptr;
  if (!Check(env, napi_get_cb_info(env, info, &argc, argv, nullptr, &data))) return nullptr;
  State* state = static_cast<State*>(data);
  if (state->closing) return Rejected(env, "OHOS_IMAGE_FRAME_CLOSED", "environment-closing");
  if (state->quarantined) return Rejected(env, "OHOS_IMAGE_CLEANUP_UNCONFIRMED", "environment-quarantined");
  if (!state->available) return Rejected(env, "OHOS_IMAGE_CODEC_UNAVAILABLE", "backend-unavailable");
  if (argc < (kind == Kind::Open ? 2u : 1u)) {
    napi_throw_type_error(env, "ERR_MISSING_ARGS", "Image bytes and open limits are required");
    return nullptr;
  }
  std::unique_ptr<Job> job(new (std::nothrow) Job(state, kind));
  if (!job) return Rejected(env, "OHOS_IMAGE_BRIDGE_ERROR", "allocation");
  std::shared_ptr<Frame> f;
  try {
    if (kind == Kind::Open) {
      f = std::make_shared<Frame>();
      f->state = state;
      f->owner_env = env;
      if (!Snapshot(env, argv[0], &f->input)) return nullptr;
      uint64_t side = 0, pixels = 0;
      if (!PositiveInteger(env, argv[1], "maxSide", UINT32_MAX, &side) ||
          !PositiveInteger(env, argv[1], "maxPixels", kMaxSafe, &pixels)) return nullptr;
      job->limits = {sizeof(DshImageLimits), static_cast<uint32_t>(side), pixels};
      job->frame = f;
      std::unique_ptr<Job> close_job(new Job(state, Kind::Close));
      close_job->frame = f;
      if (!CreateWork(close_job.get(), "dsh:image:close")) return nullptr;
      f->close_job = close_job.release();
      state->frames.emplace(f.get(), f);
    } else if (!Snapshot(env, argv[0], &job->input)) return nullptr;
    napi_value promise = nullptr;
    if (!Check(env, napi_create_promise(env, &job->deferred, &promise)) ||
        !CreateWork(job.get(), kind == Kind::Open ? "dsh:image:open" : "dsh:image:inspect")) {
      if (job->work) napi_delete_async_work(env, job->work);
      if (f) { DeleteUnqueued(f->close_job); f->close_job = nullptr; ForgetClosed(f); }
      return nullptr;
    }
    if (!Queue(job.get())) {
      Reject(env, job->deferred, "OHOS_IMAGE_BRIDGE_ERROR", "queue");
      napi_delete_async_work(env, job->work);
      if (f) { DeleteUnqueued(f->close_job); f->close_job = nullptr; ForgetClosed(f); }
      return promise;
    }
    job.release();
    return promise;
  } catch (...) {
    if (job->work) napi_delete_async_work(env, job->work);
    if (f) { DeleteUnqueued(f->close_job); f->close_job = nullptr; ForgetClosed(f); }
    return Rejected(env, "OHOS_IMAGE_BRIDGE_ERROR", "input-allocation");
  }
}

napi_value Inspect(napi_env env, napi_callback_info info) { return Start(env, info, Kind::Inspect); }
napi_value Open(napi_env env, napi_callback_info info) { return Start(env, info, Kind::Open); }

napi_value Encode(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1]{};
  auto f = GetFrame(env, info, &argc, argv);
  if (!f) return nullptr;
  if (!f->state || f->close_requested || f->closed || f->state->closing)
    return Rejected(env, "OHOS_IMAGE_FRAME_CLOSED", "encode-after-close");
  if (f->state->quarantined)
    return Rejected(env, "OHOS_IMAGE_CLEANUP_UNCONFIRMED", "environment-quarantined");
  if (argc != 1) {
    napi_throw_type_error(env, "ERR_MISSING_ARGS", "Encode target is required");
    return nullptr;
  }
  std::unique_ptr<Job> job(new (std::nothrow) Job(f->state, Kind::Encode));
  if (!job) return Rejected(env, "OHOS_IMAGE_BRIDGE_ERROR", "allocation");
  job->frame = f;
  uint64_t width = 0, height = 0, soft = 0;
  napi_value format_value = nullptr;
  char format[8]{};
  size_t length = 0;
  if (!PositiveInteger(env, argv[0], "width", UINT32_MAX, &width) ||
      !PositiveInteger(env, argv[0], "height", UINT32_MAX, &height) ||
      !PositiveInteger(env, argv[0], "softMaxBytes", kMaxSafe, &soft) ||
      !Check(env, napi_get_named_property(env, argv[0], "format", &format_value)) ||
      !Check(env, napi_get_value_string_utf8(env, format_value, format, sizeof(format), &length))) return nullptr;
  const uint32_t encoding = std::strcmp(format, "jpeg") == 0 ? DSH_IMAGE_CODEC_FORMAT_JPEG
      : std::strcmp(format, "webp") == 0 ? DSH_IMAGE_CODEC_FORMAT_WEBP : DSH_IMAGE_CODEC_FORMAT_UNKNOWN;
  if (!encoding || length > 4) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "Encode format must be jpeg or webp");
    return nullptr;
  }
  job->target = {sizeof(DshImageTarget), static_cast<uint32_t>(width),
      static_cast<uint32_t>(height), encoding, soft};
  napi_value promise = nullptr;
  if (!Check(env, napi_create_promise(env, &job->deferred, &promise)) ||
      !CreateWork(job.get(), "dsh:image:encode")) return nullptr;
  try { f->waiting.push_back(job.get()); }
  catch (...) {
    napi_delete_async_work(env, job->work);
    Reject(env, job->deferred, "OHOS_IMAGE_BRIDGE_ERROR", "encode-queue-allocation");
    return promise;
  }
  job.release();
  PumpFrame(f, true);
  return promise;
}

napi_value Close(napi_env env, napi_callback_info info) {
  size_t argc = 0;
  auto f = GetFrame(env, info, &argc, nullptr);
  if (!f) return nullptr;
  if (f->close_promise) {
    napi_value promise = nullptr;
    return Check(env, napi_get_reference_value(env, f->close_promise, &promise)) ? promise : nullptr;
  }
  napi_value promise = nullptr;
  if (!Check(env, napi_create_promise(env, &f->close_deferred, &promise)) ||
      !Check(env, napi_create_reference(env, promise, 1, &f->close_promise))) return nullptr;
  f->close_requested = true;              // Synchronous admission close.
  if (f->closed) {
    napi_value value = Undefined(env);
    if (value) napi_resolve_deferred(env, f->close_deferred, value);
  } else if (!f->state || f->state->closing || f->close_unconfirmed) {
    Reject(env, f->close_deferred, "OHOS_IMAGE_CLEANUP_UNCONFIRMED", "close-unconfirmed");
  } else PumpFrame(f, true);
  return promise;
}

#ifdef DSH_IMAGE_HOST_FIXTURE
napi_value FixtureStats(napi_env env, napi_callback_info) {
  DshImageFakeStats stats{};
  dsh_image_fake_stats(&stats);
  napi_value result = nullptr;
  if (!Check(env, napi_create_object(env, &result))) return nullptr;
  for (const auto& item : std::vector<std::pair<const char*, uint32_t>>{
      {"opens", stats.opens}, {"closes", stats.closes}, {"active", stats.active},
      {"encodes", stats.encodes}, {"overlaps", stats.overlaps},
      {"outputs", stats.outputs}, {"releasedOutputs", stats.released_outputs},
      {"inputMismatches", stats.input_mismatches}, {"cleanupStarts", stats.cleanup_starts}})
    if (!Put(env, result, item.first, UInt(env, item.second))) return nullptr;
  return result;
}

napi_value FixtureHold(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1]{};
  bool hold = false;
  if (!Check(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr))) return nullptr;
  if (argc != 1 || !Check(env, napi_get_value_bool(env, argv[0], &hold))) return nullptr;
  dsh_image_fake_hold_encodes(hold ? 1 : 0);
  return Undefined(env);
}
#endif

}  // namespace

NAPI_MODULE_INIT() {
  const napi_node_version* version = nullptr;
  if (!Check(env, napi_get_node_version(env, &version))) return nullptr;
  if (!version || version->major != 24 || version->minor != 22 || version->patch != 1) {
    napi_throw_error(env, "OHOS_IMAGE_CODEC_UNAVAILABLE", "This image bridge is pinned to Node 24.22.1");
    return nullptr;
  }
  std::unique_ptr<State> state(new (std::nothrow) State());
  if (!state) return nullptr;
  state->env = env;
  state->backend = dsh_image_codec_backend_v1();
  const auto* b = state->backend;
  bool valid = b && b->abi == DSH_IMAGE_CODEC_ABI && b->struct_size == sizeof(*b) &&
      b->build_id && std::strlen(b->build_id) <= 255 && b->inspect && b->open && b->encode &&
      b->release_encoded && b->close && b->color_getter_policy <= DSH_IMAGE_GETTER_BORROW;
#ifdef DSH_IMAGE_HOST_FIXTURE
  valid = valid && b->fixture_only == 1;
#else
  valid = valid && b->fixture_only == 0;
#endif
  state->available = valid;
  std::unique_ptr<Job> cleanup(new (std::nothrow) Job(state.get(), Kind::Cleanup));
  if (!cleanup || !CreateWork(cleanup.get(), "dsh:image:environment-cleanup")) return nullptr;
  state->cleanup_job = cleanup.get();
  if (!Check(env, napi_add_async_cleanup_hook(env, CleanupHook, state.get(), &state->cleanup_hook))) {
    napi_delete_async_work(env, cleanup->work);
    return nullptr;
  }
  State* raw = state.release();
  cleanup.release();
  const napi_property_descriptor properties[] = {
    {"inspect", nullptr, Inspect, nullptr, nullptr, nullptr, napi_default, raw},
    {"open", nullptr, Open, nullptr, nullptr, nullptr, napi_default, raw},
#ifdef DSH_IMAGE_HOST_FIXTURE
    {"fixtureStats", nullptr, FixtureStats, nullptr, nullptr, nullptr, napi_default, raw},
    {"fixtureHoldEncodes", nullptr, FixtureHold, nullptr, nullptr, nullptr, napi_default, raw},
#endif
  };
  if (!Check(env, napi_define_properties(env, exports,
      sizeof(properties) / sizeof(properties[0]), properties)) ||
      !Put(env, exports, "available", Bool(env, valid)) ||
      !Put(env, exports, "fixtureOnly", Bool(env, valid && b->fixture_only)) ||
      !Put(env, exports, "codecIdentity", String(env, valid ? b->build_id : "image-codec-unavailable")) ||
      !Put(env, exports, "colorGetterPolicy", String(env, !valid || b->color_getter_policy == DSH_IMAGE_GETTER_NOT_USED
          ? "not-used" : b->color_getter_policy == DSH_IMAGE_GETTER_DESTROY ? "destroy" : "borrow"))) return nullptr;
  return exports;
}
