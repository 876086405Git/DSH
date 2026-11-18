/* Real extension fixture: deliberately no DT_NEEDED edge to libpython.
 * Distribution CPython extensions resolve this public ABI from the embedding
 * process. Keep PyList_New undefined so a local-only addon load is observable. */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

static PyObject *make_list(PyObject *self, PyObject *args) {
  (void)self; (void)args;
  return PyList_New(0);
}
static PyMethodDef methods[] = {
  {"make_list", make_list, METH_NOARGS, NULL},
  {NULL, NULL, 0, NULL}
};
static int module_exec(PyObject *module) { (void)module; return 0; }
static PyModuleDef_Slot slots[] = {
  {Py_mod_exec, module_exec},
  {Py_mod_multiple_interpreters, Py_MOD_MULTIPLE_INTERPRETERS_SUPPORTED},
  {0, NULL}
};
static struct PyModuleDef definition = {
  PyModuleDef_HEAD_INIT, "_dsh_link_probe", NULL, 0, methods, slots, NULL, NULL, NULL
};
PyMODINIT_FUNC PyInit__dsh_link_probe(void) { return PyModuleDef_Init(&definition); }
