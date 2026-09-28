local root = (... and ... ~= "") and ... or "."

for _, name in ipairs({
    "_meta.lua", "main.lua", "wordwise_db.lua", "wordwise_hint_dialog.lua",
    "wordwise_l10n.lua", "wordwise_ota.lua", "wordwise_sha256.lua",
}) do
    local chunk, err = loadfile(root .. "/" .. name)
    assert(chunk, name .. ": " .. tostring(err))
end

package.path = root .. "/?.lua;" .. package.path
local SHA256 = require("wordwise_sha256")
local vectors = {
    { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { string.rep("a", 56), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" },
    { string.rep("a", 1000), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3" },
    { string.rep("a", 65537), "008ffc88d3c96a9f307524eb361e47c5222a887fc45fa0c1fb8d429c5c23b430" },
}
for _, vector in ipairs(vectors) do
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    assert(file:write(vector[1]))
    file:close()
    local digest, err = SHA256.digest_file(path)
    os.remove(path)
    assert(digest, err)
    assert(digest == vector[2], digest)
end

package.loaded.wordwise_db = nil
package.preload["lua-ljsqlite3/init"] = function() return {} end
package.preload.logger = function() return { warn = function() end } end
local DB = require("wordwise_db")
local function index_of(items, wanted)
    for i, value in ipairs(items) do if value == wanted then return i end end
end
local rates = DB.candidates("rates")
assert(index_of(rates, "rate") < index_of(rates, "rat"))
local riding = DB.candidates("riding")
assert(index_of(riding, "ride") < index_of(riding, "rid"))
local hoping = DB.candidates("hoping")
assert(index_of(hoping, "hope") < index_of(hoping, "hop"))
assert(DB.candidates("does")[2] == "do")

local fake_rows = {
    { 1, "father", "a priest title", "B1", "noun", "priest", "oewn", "‘Father’ is a term of address for priests in some churches" },
    { 2, "father", "church writers", "B1", "noun", "theology", "oewn", "(Christianity) any of about 70 theologians in the period" },
    { 3, "father", "a male parent", "B1", "noun", "parent", "oewn", "a male parent" },
}
local stmt = {}
function stmt:reset() return self end
function stmt:clearbind() return self end
function stmt:bind() return self end
function stmt:rows()
    local index = 0
    return function()
        index = index + 1
        return fake_rows[index]
    end
end
local legacy_rank_db = setmetatable({
    stmt = stmt, legacy = false, has_full_def = true, has_sense_rank = false,
}, DB)
assert(legacy_rank_db:_query("father")[1].sense_key == "parent")

package.preload["ffi/archiver"] = function() return { Reader = {} } end
package.preload.datastorage = function() return {} end
package.preload["ffi/util"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function() return {} end
package.preload.luasettings = function() return {} end
package.preload.util = function() return {} end
local OTA = require("wordwise_ota")
assert(OTA.safe_archive_path("wordwise.koplugin/main.lua"))
for _, unsafe in ipairs({
    "wordwise.koplugin/../../main.lua", "wordwise.koplugin/../main.lua",
    "wordwise.koplugin/./main.lua", "/wordwise.koplugin/main.lua",
    "C:/wordwise.koplugin/main.lua", "wordwise.koplugin\\..\\main.lua",
    "wordwise.koplugin//main.lua",
}) do
    assert(not OTA.safe_archive_path(unsafe), unsafe)
end
assert(OTA.compare_versions("v0.2.13", "0.2.12") == 1)
assert(OTA.compare_versions("0.2.12-extra", "0.2.12") == nil)

print("lua_syntax_sha256_and_morphology_ok")
