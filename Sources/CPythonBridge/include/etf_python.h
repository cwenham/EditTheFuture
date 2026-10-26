// The app's bridge to the bundled CPython (docs/DESIGN.md, 6.4): starting it once, audit hooks
// that keep scripts off the network and the file system, and time limits for each call.
// Strings these functions return are malloc'd; free them with etf_py_free.
#ifndef ETF_PYTHON_H
#define ETF_PYTHON_H

#include <stddef.h>

/// The folder holding lib/python3.14 in the loaded Python framework, or NULL.
char *etf_py_framework_prefix(void);

/// Starts CPython, once for the whole process. `search_paths` are separated by newlines.
/// `prelude` is the script API's source, run as the module `_etf`. Returns 0, or -1 with `*error` set.
int etf_py_start(const char *home, const char *search_paths, const char *prelude, char **error);

int etf_py_is_started(void);

/// Loads a script. Returns its program, with its declarations as JSON in `*description`, or NULL
/// with the error as JSON ({"message": ..., "line": ...}) in `*error`.
void *etf_py_load(const char *source, const char *library_paths, double seconds, char **description, char **error);

void etf_py_release(void *program);

/// Runs the script's start (`is_step` 0) or a step (1). `values` is read back in place. Events go
/// in as JSON, or NULL for none; events sent come back as JSON in `*emitted`, or NULL.
/// Returns 0, or -1 with the error as JSON in `*error`.
int etf_py_call(void *program, int is_step, double *values, int count, const double *inputs, int input_count,
                const double *time, int time_count, const char *date, unsigned long long seed, long long index,
                const char *events_json, double seconds, char **emitted, char **error);

void etf_py_free(char *text);

#endif
