// The app's bridge to Lua: a sandboxed state with a memory cap and a time limit, and the few
// helpers Swift needs where Lua's API uses macros (docs/DESIGN.md, 6.4).
#ifndef ETF_LUA_H
#define ETF_LUA_H

#include <stddef.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/// A new state with only the safe libraries: base (without dofile and loadfile), coroutine, math,
/// string, table and utf8, plus `require` for the Libraries folder. NULL if memory runs out.
lua_State *etf_lua_open(size_t memory_limit);
void etf_lua_close(lua_State *L);

/// Calls made from now on fail once `seconds` pass. 0 means no limit.
void etf_lua_set_time_limit(lua_State *L, double seconds);

/// Bytes the state has allocated.
size_t etf_lua_memory_used(lua_State *L);

/// Folders `require` searches, separated by newlines.
void etf_lua_set_library_paths(lua_State *L, const char *paths);

/// Loads text (never bytecode) as a chunk and pushes it, or pushes the error message.
int etf_lua_load(lua_State *L, const char *source, size_t length, const char *chunkname);

/// Calls the function below the arguments. On error, the message is left on the stack.
int etf_lua_pcall(lua_State *L, int nargs, int nresults);

const char *etf_lua_tostring(lua_State *L, int index, size_t *length);
void etf_lua_pop(lua_State *L, int count);

/// Keeps the value on top of the stack in the registry (popping it) and returns its reference.
int etf_lua_ref(lua_State *L);
void etf_lua_push_ref(lua_State *L, int ref);

/// Pushes field `name` of the table referenced by `ref`.
void etf_lua_push_field(lua_State *L, int ref, const char *name);

/// Writes values[0..count) to t[1..count] of the table at `index`.
void etf_lua_write_numbers(lua_State *L, int index, const double *values, int count);

/// Reads t[1..count] of the table at `index` into values. Returns 0, or the 1-based position of the
/// first value that isn't a number.
int etf_lua_read_numbers(lua_State *L, int index, double *values, int count);

/// Appends an event to the list referenced by `ref` and leaves the event's table on the stack.
void etf_lua_push_event(lua_State *L, int list_ref, const char *kind, const char *slot, const char *date);

/// Sets a number field on the table on top of the stack.
void etf_lua_set_number_field(lua_State *L, const char *name, double value);

#endif
