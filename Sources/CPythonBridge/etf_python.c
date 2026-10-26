// The app's bridge to the bundled CPython. See include/etf_python.h.
#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>

#include "etf_python.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <libgen.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int started = 0;
/// Why starting failed. CPython can't be started twice, so a failure is final.
static char *start_error = NULL;
static pthread_mutex_t start_lock = PTHREAD_MUTEX_INITIALIZER;
/// The prelude's functions and exception, kept for the life of the process.
static PyObject *load_function = NULL;
static PyObject *describe_error_function = NULL;
static PyObject *took_too_long = NULL;

static char *copy_string(const char *text) {
    return text ? strdup(text) : NULL;
}

void etf_py_free(char *text) {
    free(text);
}

char *etf_py_framework_prefix(void) {
    Dl_info info;
    if (!dladdr((const void *)&Py_Initialize, &info) || !info.dli_fname) return NULL;
    char *path = strdup(info.dli_fname);
    char *folder = copy_string(dirname(path));
    free(path);
    return folder;
}

// MARK: Audit hooks

static int blocked(const char *what) {
    PyErr_Format(PyExc_PermissionError, "Scripts in Edit The Future can't %s.", what);
    return -1;
}

static int starts_with(const char *text, const char *prefix) {
    return strncmp(text, prefix, strlen(prefix)) == 0;
}

/// Whether an "open" event is for writing: a mode with w, a, x or +, or flags that write.
static int opens_for_writing(PyObject *args) {
    if (!PyTuple_Check(args) || PyTuple_GET_SIZE(args) < 3) return 0;
    // An open file descriptor, like Python's own output streams, was opened already.
    if (PyLong_Check(PyTuple_GET_ITEM(args, 0))) return 0;
    PyObject *mode = PyTuple_GET_ITEM(args, 1);
    PyObject *flags = PyTuple_GET_ITEM(args, 2);
    if (mode && PyUnicode_Check(mode)) {
        const char *text = PyUnicode_AsUTF8(mode);
        if (text && strpbrk(text, "wax+")) return 1;
    }
    if (flags && PyLong_Check(flags)) {
        long value = PyLong_AsLong(flags);
        if (value == -1 && PyErr_Occurred()) { PyErr_Clear(); return 0; }
        if (value & (O_WRONLY | O_RDWR | O_CREAT | O_APPEND | O_TRUNC)) return 1;
    }
    return 0;
}

/// Installed in C before Python starts, so scripts can't remove it (PEP 578).
static int audit_hook(const char *event, PyObject *args, void *user_data) {
    (void)user_data;
    // Starting CPython and running the prelude are the app's own code.
    if (!started) return 0;
    if (starts_with(event, "socket.")) return blocked("use the network");
    if (strcmp(event, "subprocess.Popen") == 0 || strcmp(event, "os.system") == 0 || strcmp(event, "os.exec") == 0
        || strcmp(event, "os.posix_spawn") == 0 || strcmp(event, "os.spawn") == 0 || strcmp(event, "os.fork") == 0
        || strcmp(event, "os.forkpty") == 0 || strcmp(event, "os.startfile") == 0 || strcmp(event, "pty.spawn") == 0
        || strcmp(event, "os.kill") == 0 || strcmp(event, "os.killpg") == 0) {
        return blocked("start or signal other programs");
    }
    if (starts_with(event, "ctypes.")) return blocked("use ctypes");
    // ctypes reaches raw memory, and catches the error from loading libraries itself, so it
    // can't be imported at all.
    if (strcmp(event, "import") == 0 && PyTuple_Check(args) && PyTuple_GET_SIZE(args) > 0) {
        PyObject *module = PyTuple_GET_ITEM(args, 0);
        const char *name = module && PyUnicode_Check(module) ? PyUnicode_AsUTF8(module) : NULL;
        if (name && (strcmp(name, "ctypes") == 0 || strcmp(name, "_ctypes") == 0 || starts_with(name, "ctypes."))) {
            return blocked("use ctypes");
        }
    }
    if (strcmp(event, "webbrowser.open") == 0) return blocked("open web pages");
    if (strcmp(event, "open") == 0 && opens_for_writing(args)) return blocked("write files");
    if (strcmp(event, "os.remove") == 0 || strcmp(event, "os.rmdir") == 0 || strcmp(event, "os.rename") == 0
        || strcmp(event, "os.mkdir") == 0 || strcmp(event, "os.truncate") == 0 || strcmp(event, "os.chmod") == 0
        || strcmp(event, "os.chown") == 0 || strcmp(event, "os.link") == 0 || strcmp(event, "os.symlink") == 0
        || strcmp(event, "os.utime") == 0 || strcmp(event, "shutil.rmtree") == 0 || strcmp(event, "shutil.move") == 0) {
        return blocked("change files");
    }
    return 0;
}

// MARK: Time limits

/// A call that's running, so the watchdog can stop it once its time is up.
typedef struct {
    unsigned long thread;
    uint64_t deadline;
    int fired;
    int used;
} Running;

enum { kMaxRunning = 64 };
static Running running[kMaxRunning];
static pthread_mutex_t running_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/// Called holding the GIL. Returns the slot, or -1 when too many calls are running.
static int begin_call(double seconds) {
    if (seconds <= 0) return -1;
    pthread_mutex_lock(&running_lock);
    int slot = -1;
    for (int i = 0; i < kMaxRunning; i++) {
        if (!running[i].used) {
            running[i] = (Running){PyThread_get_thread_ident(), now_ns() + (uint64_t)(seconds * 1e9), 0, 1};
            slot = i;
            break;
        }
    }
    pthread_mutex_unlock(&running_lock);
    return slot;
}

/// Called holding the GIL, so the watchdog can't fire in between.
static void end_call(int slot) {
    if (slot < 0) return;
    pthread_mutex_lock(&running_lock);
    int fired = running[slot].fired;
    unsigned long thread = running[slot].thread;
    running[slot].used = 0;
    pthread_mutex_unlock(&running_lock);
    // An exception the watchdog asked for but that never got raised mustn't leak into the next call.
    if (fired) PyThreadState_SetAsyncExc(thread, NULL);
}

static void *watchdog(void *unused) {
    (void)unused;
    for (;;) {
        usleep(20000);
        uint64_t now = now_ns();
        int due = 0;
        pthread_mutex_lock(&running_lock);
        for (int i = 0; i < kMaxRunning; i++) {
            if (running[i].used && !running[i].fired && now > running[i].deadline) due = 1;
        }
        pthread_mutex_unlock(&running_lock);
        if (!due) continue;

        // Holding the GIL, any call still listed is still running Python code.
        PyGILState_STATE gil = PyGILState_Ensure();
        pthread_mutex_lock(&running_lock);
        now = now_ns();
        for (int i = 0; i < kMaxRunning; i++) {
            if (running[i].used && !running[i].fired && now > running[i].deadline) {
                PyThreadState_SetAsyncExc(running[i].thread, took_too_long);
                running[i].fired = 1;
            }
        }
        pthread_mutex_unlock(&running_lock);
        PyGILState_Release(gil);
    }
    return NULL;
}

// MARK: Starting

/// The current exception as the prelude describes it, in JSON. Clears the exception.
static char *error_json(void) {
    PyObject *exception = PyErr_GetRaisedException();
    if (!exception) return copy_string("{\"message\": \"Python failed without saying why.\"}");
    char *result = NULL;
    if (describe_error_function) {
        PyObject *text = PyObject_CallOneArg(describe_error_function, exception);
        if (text && PyUnicode_Check(text)) result = copy_string(PyUnicode_AsUTF8(text));
        Py_XDECREF(text);
        PyErr_Clear();
    }
    if (!result) {
        PyObject *text = PyObject_Str(exception);
        const char *message = text ? PyUnicode_AsUTF8(text) : NULL;
        PyErr_Clear();
        PyObject *wrapped = Py_BuildValue("{s:s}", "message", message ? message : "Python failed.");
        PyObject *json = PyImport_ImportModule("json");
        PyObject *dumped = json && wrapped ? PyObject_CallMethod(json, "dumps", "O", wrapped) : NULL;
        result = copy_string(dumped ? PyUnicode_AsUTF8(dumped) : "{\"message\": \"Python failed.\"}");
        Py_XDECREF(dumped);
        Py_XDECREF(json);
        Py_XDECREF(wrapped);
        Py_XDECREF(text);
        PyErr_Clear();
    }
    Py_DECREF(exception);
    return result;
}

static int append_paths(PyWideStringList *list, const char *paths) {
    if (!paths) return 0;
    char *copy = strdup(paths);
    char *rest = copy, *line;
    while ((line = strsep(&rest, "\n")) != NULL) {
        if (!*line) continue;
        wchar_t *wide = Py_DecodeLocale(line, NULL);
        if (!wide) { free(copy); return -1; }
        PyStatus status = PyWideStringList_Append(list, wide);
        PyMem_RawFree(wide);
        if (PyStatus_Exception(status)) { free(copy); return -1; }
    }
    free(copy);
    return 0;
}

int etf_py_start(const char *home, const char *search_paths, const char *prelude, char **error) {
    pthread_mutex_lock(&start_lock);
    if (started) {
        pthread_mutex_unlock(&start_lock);
        return 0;
    }
    if (start_error) {
        *error = copy_string(start_error);
        pthread_mutex_unlock(&start_lock);
        return -1;
    }
    PySys_AddAuditHook(audit_hook, NULL);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.write_bytecode = 0;
    config.site_import = 0;
    config.user_site_directory = 0;
    config.parse_argv = 0;
    config.configure_c_stdio = 0;
    config.buffered_stdio = 0;
    PyStatus status = PyConfig_SetBytesString(&config, &config.program_name, "EditTheFuture");
    if (!PyStatus_Exception(status) && home) status = PyConfig_SetBytesString(&config, &config.home, home);
    if (!PyStatus_Exception(status)) {
        config.module_search_paths_set = 1;
        if (append_paths(&config.module_search_paths, search_paths) != 0) status = PyStatus_Error("bad search path");
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        *error = copy_string(status.err_msg ? status.err_msg : "CPython couldn't start.");
        start_error = copy_string(*error);
        pthread_mutex_unlock(&start_lock);
        return -1;
    }

    PyObject *module = PyImport_AddModuleRef("_etf");
    PyObject *globals = module ? PyModule_GetDict(module) : NULL;
    PyObject *result = NULL;
    if (globals) {
        PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
        result = PyRun_String(prelude, Py_file_input, globals, globals);
    }
    if (result) {
        load_function = PyDict_GetItemString(globals, "load");
        describe_error_function = PyDict_GetItemString(globals, "describe_error");
        took_too_long = PyDict_GetItemString(globals, "TookTooLong");
        Py_XINCREF(load_function);
        Py_XINCREF(describe_error_function);
        Py_XINCREF(took_too_long);
    }
    if (!result || !load_function || !describe_error_function || !took_too_long) {
        if (PyErr_Occurred()) {
            PyObject *exception = PyErr_GetRaisedException();
            PyObject *text = exception ? PyObject_Str(exception) : NULL;
            *error = copy_string(text ? PyUnicode_AsUTF8(text) : "The script API didn't load.");
            Py_XDECREF(text);
            Py_XDECREF(exception);
        } else {
            *error = copy_string("The script API didn't load.");
        }
        Py_XDECREF(result);
        Py_XDECREF(module);
        start_error = copy_string(*error);
        PyEval_SaveThread();
        pthread_mutex_unlock(&start_lock);
        return -1;
    }
    Py_DECREF(result);
    Py_DECREF(module);

    pthread_t thread;
    pthread_create(&thread, NULL, watchdog, NULL);
    pthread_detach(thread);

    // Let other threads take the GIL.
    PyEval_SaveThread();
    started = 1;
    pthread_mutex_unlock(&start_lock);
    return 0;
}

int etf_py_is_started(void) {
    return started;
}

// MARK: Programs

void *etf_py_load(const char *source, const char *library_paths, double seconds, char **description, char **error) {
    PyGILState_STATE gil = PyGILState_Ensure();
    int slot = begin_call(seconds);
    PyObject *program = PyObject_CallFunction(load_function, "ssd", source, library_paths ? library_paths : "", seconds);
    PyObject *described = program ? PyObject_CallMethod(program, "describe", NULL) : NULL;
    end_call(slot);
    if (!described) {
        *error = error_json();
        Py_XDECREF(program);
        PyGILState_Release(gil);
        return NULL;
    }
    *description = copy_string(PyUnicode_AsUTF8(described));
    Py_DECREF(described);
    PyGILState_Release(gil);
    return program;
}

void etf_py_release(void *program) {
    if (!program) return;
    PyGILState_STATE gil = PyGILState_Ensure();
    Py_DECREF((PyObject *)program);
    PyGILState_Release(gil);
}

static PyObject *list_of(const double *values, int count) {
    PyObject *list = PyList_New(count);
    if (!list) return NULL;
    for (int i = 0; i < count; i++) PyList_SET_ITEM(list, i, PyFloat_FromDouble(values[i]));
    return list;
}

int etf_py_call(void *program, int is_step, double *values, int count, const double *inputs, int input_count,
                const double *time, int time_count, const char *date, unsigned long long seed, long long index,
                const char *events_json, double seconds, char **emitted, char **error) {
    *emitted = NULL;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *value_list = list_of(values, count);
    PyObject *input_list = list_of(inputs, input_count);
    PyObject *time_list = list_of(time, time_count);
    PyObject *events = events_json ? PyUnicode_FromString(events_json) : Py_NewRef(Py_None);
    PyObject *result = NULL;
    if (value_list && input_list && time_list && events) {
        int slot = begin_call(seconds);
        result = PyObject_CallMethod((PyObject *)program, "call", "iOOOsKLOd", is_step, value_list, input_list, time_list,
                                     date, seed, index, events, seconds);
        end_call(slot);
    }
    Py_XDECREF(value_list);
    Py_XDECREF(input_list);
    Py_XDECREF(time_list);
    Py_XDECREF(events);

    int ok = 0;
    if (result && PyTuple_Check(result) && PyTuple_GET_SIZE(result) == 2) {
        PyObject *out = PyTuple_GET_ITEM(result, 0);
        PyObject *sent = PyTuple_GET_ITEM(result, 1);
        if (PyList_Check(out) && PyList_GET_SIZE(out) == count) {
            ok = 1;
            for (int i = 0; i < count; i++) {
                double value = PyFloat_AsDouble(PyList_GET_ITEM(out, i));
                if (value == -1.0 && PyErr_Occurred()) { ok = 0; break; }
                values[i] = value;
            }
        }
        if (ok && sent != Py_None && PyUnicode_Check(sent)) *emitted = copy_string(PyUnicode_AsUTF8(sent));
    }
    if (!ok) {
        *error = result && !PyErr_Occurred() ? copy_string("{\"message\": \"The script's state couldn't be read.\"}") : error_json();
    }
    Py_XDECREF(result);
    PyGILState_Release(gil);
    return ok ? 0 : -1;
}
