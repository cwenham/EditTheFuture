// The app's bridge to Lua. See include/etf_lua.h.
#include "etf_lua.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/// What a state may use, kept as the allocator's user data.
typedef struct {
    size_t used;
    size_t limit;
    /// Monotonic nanoseconds after which calls fail; 0 for no limit.
    uint64_t deadline;
    double seconds;
    char *paths;
} Limits;

/// Instructions between checks of the clock.
static const int kHookInterval = 10000;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static Limits *limits_of(lua_State *L) {
    void *ud = NULL;
    lua_getallocf(L, &ud);
    return (Limits *)ud;
}

static void *limited_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    Limits *limits = (Limits *)ud;
    size_t old = ptr ? osize : 0;
    if (nsize == 0) {
        free(ptr);
        limits->used -= old;
        return NULL;
    }
    if (nsize > old && limits->limit > 0 && limits->used - old + nsize > limits->limit) {
        return NULL;
    }
    void *block = realloc(ptr, nsize);
    if (block) limits->used = limits->used - old + nsize;
    return block;
}

static void time_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    Limits *limits = limits_of(L);
    if (limits->deadline != 0 && now_ns() > limits->deadline) {
        limits->deadline = 0;
        luaL_error(L, "took longer than %g seconds. Is there an endless loop?", limits->seconds);
    }
}

// MARK: require

/// Library names are dotted identifiers: "stats", "money.tax".
static int valid_library_name(const char *name) {
    if (!name || !*name) return 0;
    for (const char *c = name; *c; c++) {
        if (!((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '_' || *c == '.')) {
            return 0;
        }
    }
    return name[0] != '.' && strstr(name, "..") == NULL;
}

static char *read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    char *buffer = NULL;
    size_t size = 0, capacity = 0;
    char chunk[8192];
    size_t got;
    while ((got = fread(chunk, 1, sizeof chunk, file)) > 0) {
        if (size + got > capacity) {
            capacity = (size + got) * 2;
            char *grown = realloc(buffer, capacity);
            if (!grown) { free(buffer); fclose(file); return NULL; }
            buffer = grown;
        }
        memcpy(buffer + size, chunk, got);
        size += got;
    }
    fclose(file);
    if (!buffer) buffer = malloc(1);
    *length = size;
    return buffer;
}

static int etf_require(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, "etf.loaded");
    lua_getfield(L, -1, name);
    if (!lua_isnil(L, -1)) return 1;
    lua_pop(L, 1);
    if (!valid_library_name(name)) {
        return luaL_error(L, "'%s' isn't a library name. Use letters, digits, underscores and dots.", name);
    }

    char relative[512];
    snprintf(relative, sizeof relative, "%s", name);
    for (char *c = relative; *c; c++) if (*c == '.') *c = '/';

    Limits *limits = limits_of(L);
    const char *paths = limits->paths ? limits->paths : "";
    char *source = NULL;
    size_t length = 0;
    const char *start = paths;
    while (*start && !source) {
        const char *end = strchr(start, '\n');
        size_t dir_length = end ? (size_t)(end - start) : strlen(start);
        if (dir_length > 0 && dir_length < 1024) {
            char path[2048];
            snprintf(path, sizeof path, "%.*s/%s.lua", (int)dir_length, start, relative);
            source = read_file(path, &length);
            if (!source) {
                snprintf(path, sizeof path, "%.*s/%s/init.lua", (int)dir_length, start, relative);
                source = read_file(path, &length);
            }
        }
        start = end ? end + 1 : start + dir_length;
    }
    if (!source) {
        return luaL_error(L, "There's no Lua library called '%s' in the Libraries folder.", name);
    }

    char chunkname[600];
    snprintf(chunkname, sizeof chunkname, "=%s.lua", relative);
    int status = luaL_loadbufferx(L, source, length, chunkname, "t");
    free(source);
    if (status != LUA_OK) return lua_error(L);
    lua_pushstring(L, name);
    lua_call(L, 1, 1);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_pushboolean(L, 1);
    }
    lua_pushvalue(L, -1);
    lua_setfield(L, -3, name);
    return 1;
}

// MARK: The state

lua_State *etf_lua_open(size_t memory_limit) {
    Limits *limits = calloc(1, sizeof(Limits));
    if (!limits) return NULL;
    limits->limit = memory_limit;
    // A fixed seed keeps string hashing, and so `pairs` order, the same on every run.
    lua_State *L = lua_newstate(limited_alloc, limits, 0x5EEDu);
    if (!L) { free(limits); return NULL; }

    static const luaL_Reg libraries[] = {
        {LUA_GNAME, luaopen_base},
        {LUA_COLIBNAME, luaopen_coroutine},
        {LUA_MATHLIBNAME, luaopen_math},
        {LUA_STRLIBNAME, luaopen_string},
        {LUA_TABLIBNAME, luaopen_table},
        {LUA_UTF8LIBNAME, luaopen_utf8},
        {NULL, NULL},
    };
    for (const luaL_Reg *library = libraries; library->func; library++) {
        luaL_requiref(L, library->name, library->func, 1);
        lua_pop(L, 1);
    }
    lua_pushnil(L);
    lua_setglobal(L, "dofile");
    lua_pushnil(L);
    lua_setglobal(L, "loadfile");

    lua_newtable(L);
    lua_setfield(L, LUA_REGISTRYINDEX, "etf.loaded");
    lua_pushcfunction(L, etf_require);
    lua_setglobal(L, "require");

    lua_sethook(L, time_hook, LUA_MASKCOUNT, kHookInterval);
    return L;
}

void etf_lua_close(lua_State *L) {
    if (!L) return;
    Limits *limits = limits_of(L);
    lua_close(L);
    free(limits->paths);
    free(limits);
}

void etf_lua_set_time_limit(lua_State *L, double seconds) {
    Limits *limits = limits_of(L);
    limits->seconds = seconds;
    limits->deadline = seconds > 0 ? now_ns() + (uint64_t)(seconds * 1e9) : 0;
}

size_t etf_lua_memory_used(lua_State *L) {
    return limits_of(L)->used;
}

void etf_lua_set_library_paths(lua_State *L, const char *paths) {
    Limits *limits = limits_of(L);
    free(limits->paths);
    limits->paths = paths ? strdup(paths) : NULL;
}

int etf_lua_load(lua_State *L, const char *source, size_t length, const char *chunkname) {
    return luaL_loadbufferx(L, source, length, chunkname, "t");
}

static int message_handler(lua_State *L) {
    if (lua_type(L, 1) == LUA_TSTRING) return 1;
    if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) return 1;
    lua_pushfstring(L, "(an error of type %s)", luaL_typename(L, 1));
    return 1;
}

int etf_lua_pcall(lua_State *L, int nargs, int nresults) {
    int base = lua_gettop(L) - nargs;
    lua_pushcfunction(L, message_handler);
    lua_insert(L, base);
    int status = lua_pcall(L, nargs, nresults, base);
    lua_remove(L, base);
    return status;
}

const char *etf_lua_tostring(lua_State *L, int index, size_t *length) {
    return lua_tolstring(L, index, length);
}

void etf_lua_pop(lua_State *L, int count) {
    lua_pop(L, count);
}

int etf_lua_ref(lua_State *L) {
    return luaL_ref(L, LUA_REGISTRYINDEX);
}

void etf_lua_push_ref(lua_State *L, int ref) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
}

void etf_lua_push_field(lua_State *L, int ref, const char *name) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
}

void etf_lua_write_numbers(lua_State *L, int index, const double *values, int count) {
    index = lua_absindex(L, index);
    for (int i = 0; i < count; i++) {
        lua_pushnumber(L, values[i]);
        lua_rawseti(L, index, i + 1);
    }
}

int etf_lua_read_numbers(lua_State *L, int index, double *values, int count) {
    index = lua_absindex(L, index);
    for (int i = 0; i < count; i++) {
        lua_rawgeti(L, index, i + 1);
        int isnum = 0;
        double value = (double)lua_tonumberx(L, -1, &isnum);
        lua_pop(L, 1);
        if (!isnum) return i + 1;
        values[i] = value;
    }
    return 0;
}

void etf_lua_push_event(lua_State *L, int list_ref, const char *kind, const char *slot, const char *date) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, list_ref);
    lua_Integer count = (lua_Integer)lua_rawlen(L, -1);
    lua_createtable(L, 0, 4);
    lua_pushstring(L, kind);
    lua_setfield(L, -2, "kind");
    if (slot) {
        lua_pushstring(L, slot);
        lua_setfield(L, -2, "slot");
    }
    lua_pushstring(L, date);
    lua_setfield(L, -2, "date");
    lua_pushvalue(L, -1);
    lua_rawseti(L, -3, count + 1);
    lua_remove(L, -2);
}

void etf_lua_set_number_field(lua_State *L, const char *name, double value) {
    lua_pushnumber(L, value);
    lua_setfield(L, -2, name);
}
