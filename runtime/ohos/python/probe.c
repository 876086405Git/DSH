/* Scoped embedding experiment, NOT the production dsh-python-1 host. */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <node_api.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdatomic.h>
#include <pthread.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static PyThreadState *saved;
static _Atomic int cancelled;
static double deadline;
static napi_env output_env;
static napi_value output_callback;
static PyObject *emit(PyObject *self, PyObject *args) {
  (void)self; const char *stream, *text; Py_ssize_t size;
  if (!PyArg_ParseTuple(args, "ss#", &stream, &text, &size)) return NULL;
  napi_value values[2], receiver, result;
  napi_create_string_utf8(output_env, stream, NAPI_AUTO_LENGTH, &values[0]);
  napi_create_buffer_copy(output_env, (size_t)size, text, NULL, &values[1]);
  napi_get_undefined(output_env, &receiver);
  if (napi_call_function(output_env, receiver, output_callback, 2, values, &result) != napi_ok) {
    PyErr_SetString(PyExc_RuntimeError, "Node output callback failed"); return NULL;
  }
  return PyLong_FromSsize_t(size);
}
static PyMethodDef emit_def = {"_emit", emit, METH_VARARGS, NULL};
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int trace(PyObject *obj, PyFrameObject *frame, int what, PyObject *arg) {
  (void)obj; (void)frame; (void)what; (void)arg;
  if (atomic_load(&cancelled) || (deadline && now() >= deadline)) {
    atomic_store(&cancelled, 0); deadline = 0; PyEval_SetTrace(NULL, NULL);
    PyErr_SetString(PyExc_KeyboardInterrupt, "embedded Python cancelled or timed out"); return -1;
  }
  return 0;
}
static PyObject *begin_trace(PyObject *self, PyObject *args) {
  (void)self; (void)args; PyEval_SetTrace(trace, NULL); Py_RETURN_NONE;
}
static PyMethodDef trace_def = {"_begin_trace", begin_trace, METH_NOARGS, NULL};
static napi_value prepare(napi_env env, napi_callback_info info) {
  (void)info; atomic_store(&cancelled, 0); napi_value out; napi_get_undefined(env, &out); return out;
}
static napi_value cancel(napi_env env, napi_callback_info info) {
  (void)info; atomic_store(&cancelled, 1); napi_value out; napi_get_undefined(env, &out); return out;
}
static napi_value run(napi_env env, napi_callback_info info) {
  size_t argc = 3, size; napi_value args[3], out;
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 2 || napi_get_value_string_utf8(env, args[0], NULL, 0, &size) != napi_ok) {
    napi_throw_type_error(env, NULL, "run(source, timeoutMs) requires a string"); return NULL;
  }
  double timeout; if (napi_get_value_double(env, args[1], &timeout) != napi_ok || timeout <= 0 || timeout > 2147483647) {
    napi_throw_range_error(env, NULL, "timeoutMs must be positive and bounded"); return NULL;
  }
  char *source = malloc(size + 1); if (!source) { napi_throw_error(env, NULL, "allocation failed"); return NULL; }
  napi_get_value_string_utf8(env, args[0], source, size + 1, &size);
  if (strlen(source) != size) { free(source); napi_throw_type_error(env, NULL, "NUL in source"); return NULL; }
  if (pthread_mutex_trylock(&lock)) { free(source); napi_throw_error(env, "ERR_OHOS_PYTHON_BUSY", "Python probe already running"); return NULL; }
  deadline = now() + timeout / 1000;
  if (!saved) {
    PyConfig config; PyConfig_InitIsolatedConfig(&config); config.install_signal_handlers = 0;
    PyStatus status = Py_InitializeFromConfig(&config); PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) { free(source); pthread_mutex_unlock(&lock); napi_throw_error(env, NULL, status.err_msg); return NULL; }
  } else PyEval_RestoreThread(saved);
  PyObject *globals = PyDict_New();
  PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
  PyObject *trace_fn = PyCFunction_New(&trace_def, NULL);
  PyDict_SetItemString(globals, "_begin_trace", trace_fn); Py_DECREF(trace_fn);
  if (argc == 3) {
    napi_valuetype type; napi_typeof(env, args[2], &type);
    if (type == napi_function) {
      output_env = env; output_callback = args[2];
      PyObject *fn = PyCFunction_New(&emit_def, NULL);
      PyDict_SetItemString(globals, "_emit", fn); Py_DECREF(fn);
    }
  }
  PyObject *text = PyUnicode_FromStringAndSize(source, size); free(source);
  PyDict_SetItemString(globals, "_source", text); Py_DECREF(text);
  /* Callback mode streams on this Node Worker; direct test mode captures text. */
  const char *bootstrap =
    "import sys, io, json, traceback\n"
    "_oldout, _olderr, _oldin = sys.stdout, sys.stderr, sys.stdin\n"
    "class _NoStdin(io.TextIOBase):\n"
    " def read(self, *args): raise RuntimeError('ERR_OHOS_PYTHON_STDIN: stdin is unavailable; use App Linux')\n"
    " readline = read\n"
    " @property\n"
    " def buffer(self): return self\n"
    "sys.stdin = _NoStdin()\n"
    "_out, _err = io.StringIO(), io.StringIO()\n"
    "if '_emit' in globals():\n"
    " class _Stream(io.TextIOBase):\n"
    "  def __init__(self, name): self.name = name\n"
    "  def write(self, text): _emit(self.name, text); return len(text)\n"
    "  def getvalue(self): return ''\n"
    " _out, _err = _Stream('stdout'), _Stream('stderr')\n"
    "sys.stdout, sys.stderr = _out, _err\n"
    "_code = 0\n"
    "try:\n"
    " _begin_trace()\n"
    " exec(compile(_source, '<embedded-probe>', 'exec'), {'__name__': '__main__'})\n"
    "except SystemExit as e:\n"
    " _code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)\n"
    " if e.code is not None and not isinstance(e.code, int): print(e.code, file=_err)\n"
    "except KeyboardInterrupt:\n"
    " _code = 130\n"
    "except BaseException:\n"
    " _code = 1; traceback.print_exc(file=_err)\n"
    "finally:\n"
    " sys.stdout, sys.stderr, sys.stdin = _oldout, _olderr, _oldin\n"
    "_result = json.dumps({'stdout': _out.getvalue(), 'stderr': _err.getvalue(), 'exitCode': _code & 255})\n";
  // Load helpers before installing the deadline trace.
  PyObject *setup = PyRun_String("import sys, io, json, traceback", Py_file_input, globals, globals);
  Py_XDECREF(setup);
  PyObject *result = PyRun_String(bootstrap, Py_file_input, globals, globals);
  PyEval_SetTrace(NULL, NULL);
  if (!result) { PyErr_Clear(); napi_throw_error(env, NULL, "probe bootstrap failed"); out = NULL; }
  else {
    Py_DECREF(result); PyObject *json = PyDict_GetItemString(globals, "_result");
    const char *encoded = PyUnicode_AsUTF8(json);
    napi_create_string_utf8(env, encoded, NAPI_AUTO_LENGTH, &out);
  }
  Py_DECREF(globals); saved = PyEval_SaveThread(); pthread_mutex_unlock(&lock); return out;
}
static napi_value init(napi_env env, napi_value exports) {
  napi_value f; napi_create_function(env, "run", NAPI_AUTO_LENGTH, run, NULL, &f); napi_set_named_property(env, exports, "run", f);
  napi_create_function(env, "cancel", NAPI_AUTO_LENGTH, cancel, NULL, &f); napi_set_named_property(env, exports, "cancel", f);
  napi_create_function(env, "prepare", NAPI_AUTO_LENGTH, prepare, NULL, &f); napi_set_named_property(env, exports, "prepare", f);
  return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
