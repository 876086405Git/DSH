// Runs the engine on the iOS Simulator with no app around it, through the same dlopen
// and C surface the app uses. drive.mjs is the other half.
//
//   smoke <frameworks dir> <runtime root> <guest root> <cache dir>
//
// Prints each host event as a JSON line. A file named `restart` in the guest root makes
// it stop the engine and start it again in this process; `quit` ends the run.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*StartFn)(const char*, const char*, const char*, const char*, const char*, const char*, int, const char**,
                       const char**, char**, char**);
typedef void (*StopFn)(void);
typedef char* (*TextFn)(void);
typedef void (*FreeFn)(char*);

static StartFn start_engine;
static StopFn stop_engine;
static TextFn host_state;
static TextFn host_drain;
static FreeFn host_free;
static char dsh_home[4096];
static char workspace[4096];
// The engine takes over fds 1 and 2 while it runs, so this has its own copy of stdout.
static FILE* out;

static void die(const char* message, const char* detail) {
  fprintf(out, "{\"kind\":\"fatal\",\"message\":\"%s: %s\"}\n", message, detail ? detail : "");
  fflush(out);
  exit(1);
}

static int exists_then_remove(const char* root, const char* name) {
  char path[4096];
  struct stat info;
  snprintf(path, sizeof path, "%s/%s", root, name);
  if (stat(path, &info) != 0) return 0;
  unlink(path);
  return 1;
}

static void drain(void) {
  char* events = host_drain();
  fprintf(out, "%s\n", events);
  fflush(out);
  host_free(events);
}

static int phase_is(const char* phase) {
  char* state = host_state();
  char wanted[64];
  snprintf(wanted, sizeof wanted, "\"phase\":\"%s\"", phase);
  const int matches = strstr(state, wanted) != NULL;
  host_free(state);
  return matches;
}

typedef int (*ArmFn)(const char*, const char*);
typedef void (*ClearFn)(const char*);
static ArmFn phone_arm;
static ClearFn phone_clear;

static void begin(char** argv) {
  // What IOSPhoneBridge does before each run: the backend takes this token from memory.
  const char* run = getenv("DSH_IOS_SMOKE_PHONE_RUN");
  if (run != NULL) {
    phone_clear(run);
    if (phone_arm(run, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") != 0) {
      die("phone arm", run);
    }
  }
  const char* keys[] = {"DSH_OHOS_TEST_KEY", "DSH_PERMISSION_MODE"};
  const char* values[] = {"ohos-local-fixture-only", "workspace-write"};
  char* code = NULL;
  char* message = NULL;
  if (start_engine(argv[2], argv[3], dsh_home, argv[4], argv[1], workspace, 2, keys, values, &code, &message) != 0) {
    die(code ? code : "start refused", message);
  }
}

int main(int argc, char** argv) {
  out = fdopen(dup(STDOUT_FILENO), "w");
  if (argc != 5) die("usage", "smoke <frameworks> <runtime root> <guest root> <cache>");
  // The simulator smoke must consume the same addon layout as the app bundle.
  for (size_t i = 0; i < 2; ++i) {
    const char* addons[] = {"DshFlock.framework/DshFlock", "DshRequireBuiltin.framework/DshRequireBuiltin"};
    char addon[4096];
    int length = snprintf(addon, sizeof addon, "%s/%s", argv[1], addons[i]);
    if (length < 0 || (size_t)length >= sizeof addon || access(addon, R_OK) != 0) {
      die("addon-layout", "Required addon framework executable is missing");
    }
  }
  char library[4096];
  snprintf(library, sizeof library, "%s/DshNodeHost.framework/DshNodeHost", argv[1]);
  void* host = dlopen(library, RTLD_NOW | RTLD_GLOBAL);
  if (host == NULL) die("dlopen", dlerror());
  start_engine = (StartFn)dlsym(host, "dsh_host_start");
  stop_engine = (StopFn)dlsym(host, "dsh_host_stop");
  host_state = (TextFn)dlsym(host, "dsh_host_state");
  host_drain = (TextFn)dlsym(host, "dsh_host_drain");
  host_free = (FreeFn)dlsym(host, "dsh_host_free");
  phone_arm = (ArmFn)dlsym(host, "dsh_ios_phone_arm");
  phone_clear = (ClearFn)dlsym(host, "dsh_ios_phone_clear");
  if (!start_engine || !stop_engine || !host_state || !host_drain || !host_free || !phone_arm || !phone_clear) {
    die("dlsym", dlerror());
  }
  snprintf(dsh_home, sizeof dsh_home, "%s/root/.dsh", argv[3]);
  snprintf(workspace, sizeof workspace, "%s/root/workspace", argv[3]);

  begin(argv);
  for (;;) {
    drain();
    if (exists_then_remove(argv[3], "quit")) {
      stop_engine();
      while (!phase_is("exited") && !phase_is("error")) usleep(100000);
      drain();
      return 0;
    }
    if (exists_then_remove(argv[3], "restart")) {
      fprintf(out, "{\"kind\":\"restarting\"}\n");
      stop_engine();
      while (!phase_is("exited") && !phase_is("error")) { drain(); usleep(100000); }
      drain();
      begin(argv);
    }
    // Often enough that the host's bounded queue keeps the first lines of a burst.
    usleep(10000);
  }
}
