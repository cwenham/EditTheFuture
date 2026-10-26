# Lua 5.5.1

The Lua interpreter, from https://www.lua.org/ftp/lua-5.5.1.tar.gz (398,643 bytes, sha256
`1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`). MIT licence; the notice
is at the end of `include/lua.h`.

`lua/` and `include/` are Lua's own `src/` files, unchanged, without:

- `lua.c` and `luac.c`, the command-line programs;
- `liolib.c`, `loslib.c`, `loadlib.c` and `ldblib.c`: the `io`, `os`, `package` and `debug`
  libraries, which scripts mustn't have (docs/DESIGN.md, 6.4);
- `linit.c`, which opens them.

`etf_lua.c` and `include/etf_lua.h` are the app's own: a sandboxed state with a memory cap, a
time limit, and `require` for the Libraries folder.
