-- Small streaming SHA-256 implementation for OTA verification.
-- KOReader ships LuaJIT's bit module, but not a portable SHA-256 command on
-- every Android device, so the updater cannot rely on sha256sum/openssl.

local ok_bit, bit = pcall(require, "bit")
if not ok_bit then
    bit = require("bit32")
    bit.ror = bit.rrotate
    bit.tobit = function(value) return value % 0x100000000 end
end
local band, bnot, bxor = bit.band, bit.bnot, bit.bxor
local rshift, ror, tobit = bit.rshift, bit.ror, bit.tobit

local K_HEX = {
    "428a2f98","71374491","b5c0fbcf","e9b5dba5","3956c25b","59f111f1","923f82a4","ab1c5ed5",
    "d807aa98","12835b01","243185be","550c7dc3","72be5d74","80deb1fe","9bdc06a7","c19bf174",
    "e49b69c1","efbe4786","0fc19dc6","240ca1cc","2de92c6f","4a7484aa","5cb0a9dc","76f988da",
    "983e5152","a831c66d","b00327c8","bf597fc7","c6e00bf3","d5a79147","06ca6351","14292967",
    "27b70a85","2e1b2138","4d2c6dfc","53380d13","650a7354","766a0abb","81c2c92e","92722c85",
    "a2bfe8a1","a81a664b","c24b8b70","c76c51a3","d192e819","d6990624","f40e3585","106aa070",
    "19a4c116","1e376c08","2748774c","34b0bcb5","391c0cb3","4ed8aa4a","5b9cca4f","682e6ff3",
    "748f82ee","78a5636f","84c87814","8cc70208","90befffa","a4506ceb","bef9a3f7","c67178f2",
}
local K = {}
for i, value in ipairs(K_HEX) do K[i - 1] = tobit(tonumber(value, 16)) end

local INITIAL_HEX = {
    "6a09e667", "bb67ae85", "3c6ef372", "a54ff53a",
    "510e527f", "9b05688c", "1f83d9ab", "5be0cd19",
}

local function add(...)
    local total = 0
    for i = 1, select("#", ...) do total = total + select(i, ...) end
    return tobit(total)
end

local function process(ctx, block)
    local w = {}
    for i = 0, 15 do
        local a, b, c, d = block:byte(i * 4 + 1, i * 4 + 4)
        w[i] = tobit(a * 0x1000000 + b * 0x10000 + c * 0x100 + d)
    end
    for i = 16, 63 do
        local s0 = bxor(ror(w[i - 15], 7), ror(w[i - 15], 18), rshift(w[i - 15], 3))
        local s1 = bxor(ror(w[i - 2], 17), ror(w[i - 2], 19), rshift(w[i - 2], 10))
        w[i] = add(w[i - 16], s0, w[i - 7], s1)
    end

    local a, b, c, d = ctx.h[1], ctx.h[2], ctx.h[3], ctx.h[4]
    local e, f, g, h = ctx.h[5], ctx.h[6], ctx.h[7], ctx.h[8]
    for i = 0, 63 do
        local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = add(h, s1, ch, K[i], w[i])
        local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local t2 = add(s0, maj)
        h, g, f, e, d, c, b, a = g, f, e, add(d, t1), c, b, a, add(t1, t2)
    end
    ctx.h[1], ctx.h[2], ctx.h[3], ctx.h[4] = add(ctx.h[1], a), add(ctx.h[2], b), add(ctx.h[3], c), add(ctx.h[4], d)
    ctx.h[5], ctx.h[6], ctx.h[7], ctx.h[8] = add(ctx.h[5], e), add(ctx.h[6], f), add(ctx.h[7], g), add(ctx.h[8], h)
end

local function encode_u32(value)
    return string.char(
        band(rshift(value, 24), 0xff), band(rshift(value, 16), 0xff),
        band(rshift(value, 8), 0xff), band(value, 0xff))
end

local SHA256 = {}

function SHA256.digest_file(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local ctx = { h = {}, buffer = "", length = 0 }
    for i, value in ipairs(INITIAL_HEX) do ctx.h[i] = tobit(tonumber(value, 16)) end

    while true do
        local chunk = file:read(65536)
        if not chunk then break end
        ctx.length = ctx.length + #chunk
        local data = ctx.buffer .. chunk
        local usable = #data - (#data % 64)
        for offset = 1, usable, 64 do process(ctx, data:sub(offset, offset + 63)) end
        ctx.buffer = data:sub(usable + 1)
    end
    file:close()

    local bit_low = (ctx.length * 8) % 0x100000000
    local bit_high = math.floor(ctx.length / 0x20000000)
    local padding_len = (55 - ctx.length) % 64
    local final = ctx.buffer .. "\128" .. string.rep("\0", padding_len)
        .. encode_u32(bit_high) .. encode_u32(bit_low)
    for offset = 1, #final, 64 do process(ctx, final:sub(offset, offset + 63)) end

    local out = {}
    for i = 1, 8 do
        local value = ctx.h[i]
        if value < 0 then value = value + 0x100000000 end
        out[i] = string.format("%08x", value)
    end
    return table.concat(out)
end

return SHA256
