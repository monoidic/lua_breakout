# Lua Breakout

`gen_payload.sh` generates a Lua script `payload.lua` which uses either ROP or a GOT overwrite to perform a local `system()` call in the context of the Lua interpreter running the script. Mostly based on the excellent article [Bytecode Breakdown](https://memorycorruption.net/posts/rce-lua-factorio).

Only tested on Lua 5.4.7, Ubuntu Linux 24.04, 64-bit and 32-bit x86, with static and dynamic linking.

Variants:
* ROP to `system()` in statically linked Lua interpreter
* ROP to `system()` in dynamically linked Lua interpreter
* GOT overwrite of `ldexp()` to `system()` in dynamically linked Lua interpreter

The GOT overwrite method requires Lua to be compiled with `-Wl,-z,norelro -no-pie` as well as `-DLUA_COMPAT_5_3` (or `-DLUA_COMPAT_MATHLIB`).

`-Wl,z,norelro` is required in order to disable RELRO and make GOT modification possible. `-no-pie` is required to ensure the heap is within the 32-bit address space, as the address is passed to `ldexp` in `EDI` and hence truncated to 32 bits. Unneeded under 32-bit builds.

`-DLUA_COMPAT_5_3` (or `-DLUA_COMPAT_MATHLIB`) is required to ensure the now-deprecated `math.ldexp` function is still available in the interpreter.

The generator script relies on `objdump`, `readelf` and `ROPgadget` for extracting various offsets, and expects symbols to be present.
