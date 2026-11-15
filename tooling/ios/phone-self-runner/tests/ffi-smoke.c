#define _POSIX_C_SOURCE 200809L
#include "dsh_phone_self_runner.h"
#include <assert.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>
#include <time.h>

/* This links the actual Rust archive. The accepted fixture uses a nonexistent
 * legacy pairing file, so it must fail or be cancelled before any TCP connect.
 * It does not emulate successful device services or send an input. */
static const char config[] =
    "{\"runId\":\"12345678-1234-4234-8234-123456789abc\","
    "\"pairingFile\":\"/nonexistent/dsh-c-abi-smoke.plist\","
    "\"host\":\"10.7.0.1\",\"port\":49152}";
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int starting;
static int release_start;
static int terminal;
static uint64_t observed_handle;

static struct timespec deadline(void) {
  struct timespec value;
  assert(clock_gettime(CLOCK_REALTIME, &value) == 0);
  value.tv_sec += 5;
  return value;
}
static void impossible_legacy_event(const char *run_id, int32_t kind,
                                    const char *payload) {
  (void)run_id; (void)kind; (void)payload;
  assert(!"invalid legacy input must not start a callback thread");
}
static void impossible_result(uint64_t handle, uint64_t request_id,
    int32_t status, const char *json, const uint8_t *bytes, size_t len) {
  (void)handle; (void)request_id; (void)status; (void)json;
  (void)bytes; (void)len;
  assert(!"rejected request must not get a callback");
}
static void event(uint64_t handle, const char *run_id, int32_t kind,
                  const char *json) {
  assert(handle != 0);
  assert(strcmp(run_id, "12345678-1234-4234-8234-123456789abc") == 0);
  assert(strnlen(json, 8193) <= 8192);
  pthread_mutex_lock(&mutex);
  observed_handle = handle;
  if (kind == 0 && !starting) {
    starting = 1;
    pthread_cond_broadcast(&condition);
    struct timespec limit = deadline();
    while (!release_start)
      assert(pthread_cond_timedwait(&condition, &mutex, &limit) == 0);
  } else if (kind >= 2 && kind <= 4) {
    assert(terminal == 0);
    assert(kind != 4);
    assert(strstr(json, "\"cleanupConfirmed\":true") != NULL);
    if (kind == 3)
      assert(strstr(json, "ERR_PHONE_PAIRING_REQUIRED") != NULL);
    terminal = kind;
    pthread_cond_broadcast(&condition);
  }
  pthread_mutex_unlock(&mutex);
}
static void run_case(int cancel) {
  pthread_mutex_lock(&mutex);
  starting = release_start = terminal = 0;
  observed_handle = 0;
  pthread_mutex_unlock(&mutex);
  uint64_t handle = 0;
  assert(dsh_phone_core_start((const uint8_t *)config, sizeof(config) - 1,
                             event, &handle) == 0);
  assert(handle != 0);
  pthread_mutex_lock(&mutex);
  struct timespec limit = deadline();
  while (!starting)
    assert(pthread_cond_timedwait(&condition, &mutex, &limit) == 0);
  assert(observed_handle == handle);
  pthread_mutex_unlock(&mutex);

  uint64_t rejected = 999;
  assert(dsh_phone_core_start((const uint8_t *)config, sizeof(config) - 1,
                             event, &rejected) == 2);
  assert(rejected == 0);
  static const uint8_t request[] = "{\"op\":\"screenshot\"}";
  assert(dsh_phone_core_request(handle, 1, request, sizeof(request) - 1,
                               impossible_result) == 4);
  dsh_phone_core_cancel(UINT64_MAX, 1);
  dsh_phone_core_stop(UINT64_MAX);
  if (cancel) dsh_phone_core_stop(handle);
  pthread_mutex_lock(&mutex);
  release_start = 1;
  pthread_cond_broadcast(&condition);
  limit = deadline();
  while (!terminal)
    assert(pthread_cond_timedwait(&condition, &mutex, &limit) == 0);
  assert(terminal == (cancel ? 2 : 3));
  pthread_mutex_unlock(&mutex);
  assert(dsh_phone_core_request(handle, 2, request, sizeof(request) - 1,
                               impossible_result) == 3);
}
int main(void) {
  const char *identity = dsh_phone_core_build_identity();
  assert(identity == dsh_phone_core_build_identity());
  assert(strcmp(identity,
      "dsh-phone-core:1;idevice=3854a5df4a5a6dee71ffce4d8befc2ea356a8065") == 0);
  assert(dsh_phone_xctest_start(NULL, impossible_legacy_event) == 0);
  assert(dsh_phone_xctest_start("{}", impossible_legacy_event) == 0);
  assert(dsh_phone_xctest_start("not-json", impossible_legacy_event) == 0);
  assert(dsh_phone_xctest_start("{}", NULL) == 0);
  dsh_phone_xctest_stop(0);
  dsh_phone_xctest_stop(UINT64_MAX);
  uint64_t handle = 9;
  assert(dsh_phone_core_start(NULL, 1, event, &handle) == 1 && handle == 0);
  assert(dsh_phone_core_start((const uint8_t *)"{}", 2, event, &handle) == 1);
  assert(dsh_phone_core_start((const uint8_t *)config, sizeof(config) - 1,
                             NULL, &handle) == 1);
  /* The length is rejected before the pointer could be read out of bounds. */
  assert(dsh_phone_core_start((const uint8_t *)"x", 96 * 1024 + 1,
                             event, &handle) == 7);
  run_case(0);
  run_case(1);
  return 0;
}
