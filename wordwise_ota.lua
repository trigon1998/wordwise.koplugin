-- Word Wise OTA updater for the public fork.
-- The updater is intentionally release-based: it never installs a moving branch
-- archive and it never writes to KOReader's user-data directory except under the
-- plugin's own temporary ota directory.

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local logger = require("logger")
local util = require("util")

local OTA = {
    owner = "trigon1998",
    repo = "wordwise.koplugin",
    asset_name = "wordwise.koplugin.zip",
    current_version = "0.2.4",
}
OTA.api_url = "https://api.github.com/repos/" .. OTA.owner .. "/" .. OTA.repo .. "/releases/latest"

local REQUIRED_FILES = {
    ["main.lua"] = true,
    ["_meta.lua"] = true,
    ["wordwise_db.lua"] = true,
    ["wordwise.db"] = true,
}

local function version_parts(v)
    local a, b, c = tostring(v or ""):match("^[vV]?(%d+)%.(%d+)%.(%d+)")
    if not a then return nil end
    return tonumber(a), tonumber(b), tonumber(c)
end

function OTA.compare_versions(a, b)
    local aa, ab, ac = version_parts(a)
    local ba, bb, bc = version_parts(b)
    if not aa or not ba then return nil end
    if aa ~= ba then return aa > ba and 1 or -1 end
    if ab ~= bb then return ab > bb and 1 or -1 end
    if ac ~= bc then return ac > bc and 1 or -1 end
    return 0
end

local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    return util.makePath(path)
end

local function request_url(url, make_sink, timeout_pair)
    local https = require("ssl.https")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local redirects = 0
    local last_error
    local attempts = 0
    while redirects <= 3 and attempts < 4 do
        attempts = attempts + 1
        local sink, sink_err = make_sink()
        if not sink then return nil, sink_err or "cannot create network sink" end
        socketutil:set_timeout(
            (timeout_pair and timeout_pair[1]) or socketutil.LARGE_BLOCK_TIMEOUT,
            (timeout_pair and timeout_pair[2]) or socketutil.LARGE_TOTAL_TIMEOUT)
        local call_ok, result, code, headers, status = pcall(function()
            return https.request{
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = "WordWise-KOReader-OTA/1",
                    ["Accept"] = "application/vnd.github+json",
                },
                sink = sink,
            }
        end)
        socketutil:reset_timeout()
        if call_ok and result == 1 and code == 200 then return headers end
        local transport_error = call_ok and (status or code or result or "network request failed")
            or tostring(result or "network request failed")
        if transport_error == "wantread" or transport_error == "timeout"
                or transport_error == "sink timeout" then
            last_error = transport_error
            logger.warn("Word Wise OTA transient network error", transport_error, "attempt", attempts)
            if socket.sleep then socket.sleep(0.25) end
        elseif (code == 301 or code == 302 or code == 303 or code == 307 or code == 308)
                and headers and headers.location and headers.location:match("^https://") then
            url = headers.location
            redirects = redirects + 1
        else
            return nil, transport_error
        end
    end
    return nil, last_error or "too many HTTPS redirects"
end

function OTA:fetch_latest()
    local JSON = require("json")
    local chunks = {}
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local _, err = request_url(self.api_url, function()
        chunks = {}
        return socketutil.table_sink(chunks)
    end, { socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT })
    if err then return nil, err end
    local ok, release = pcall(JSON.decode, table.concat(chunks))
    if not ok or type(release) ~= "table" then
        return nil, "invalid GitHub release response"
    end
    if release.draft or release.prerelease then
        return nil, "latest release is not a stable release"
    end
    local tag = release.tag_name
    if not version_parts(tag) then return nil, "release tag is not semantic versioning" end
    local asset
    for _, candidate in ipairs(release.assets or {}) do
        if candidate.name == self.asset_name then
            asset = candidate
            break
        end
    end
    if not asset or type(asset.browser_download_url) ~= "string"
            or not asset.browser_download_url:match("^https://") then
        return nil, "expected plugin ZIP asset is missing"
    end
    return {
        version = tag:gsub("^[vV]", ""),
        tag = tag,
        name = release.name or tag,
        notes = release.body or "",
        asset_url = asset.browser_download_url,
        asset_size = asset.size,
    }
end

local function safe_archive_path(path)
    return type(path) == "string"
        and not path:match("^/")
        and not path:match("^[A-Za-z]:")
        and not path:match("(^|/)%.%.(/|$)")
end

function OTA:validate_archive(zip_path, staging_dir)
    local arc = Archiver.Reader:new()
    local ok, err = arc:open(zip_path)
    if not ok then arc:close(); return nil, err or "cannot open update archive" end
    local root
    local files = {}
    local valid = true
    for entry in arc:iterate() do
        local path = entry.path
        if not safe_archive_path(path) then valid = false; err = "unsafe archive path"; break end
        local first = path:match("^([^/]+)/")
        if not first or first ~= "wordwise.koplugin" then
            valid = false; err = "archive root must be wordwise.koplugin"; break
        end
        local relative = path:sub(#"wordwise.koplugin/" + 1)
        if relative ~= "" and not path:match("/$") then files[relative] = true end
    end
    if valid then
        for required in pairs(REQUIRED_FILES) do
            if not files[required] then valid = false; err = "required file missing: " .. required; break end
        end
    end
    if not valid then arc:close(); return nil, err end
    if not ensure_dir(staging_dir) then arc:close(); return nil, "cannot create staging directory" end
    if lfs.attributes(staging_dir, "mode") then ffiUtil.purgeDir(staging_dir); ensure_dir(staging_dir) end
    for entry in arc:iterate() do
        if not arc:extractToPath(entry.path, staging_dir .. "/" .. entry.path) then
            valid = false; err = arc.err or "archive extraction failed"; break
        end
    end
    arc:close()
    if not valid then ffiUtil.purgeDir(staging_dir); return nil, err end
    return staging_dir .. "/wordwise.koplugin"
end

function OTA:install(release, plugin_dir)
    local ota_dir = DataStorage:getDataDir() .. "/wordwise/ota"
    if not ensure_dir(ota_dir) then return nil, "cannot create OTA directory" end
    local zip_path = ota_dir .. "/" .. self.asset_name
    local staging = ota_dir .. "/staging"
    local socketutil = require("socketutil")
    local _, err = request_url(release.asset_url, function()
        local file = io.open(zip_path, "wb")
        if not file then return nil, "cannot create download file" end
        return socketutil.file_sink(file)
    end, { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT })
    if err then os.remove(zip_path); return nil, err end
    local new_dir, validation_error = self:validate_archive(zip_path, staging)
    os.remove(zip_path)
    if not new_dir then return nil, validation_error end

    local backup = plugin_dir .. ".ota-backup"
    if lfs.attributes(backup, "mode") then ffiUtil.purgeDir(backup) end
    local ok, rename_error = os.rename(plugin_dir, backup)
    if not ok then ffiUtil.purgeDir(staging); return nil, rename_error or "cannot stage current plugin" end
    ok, rename_error = os.rename(new_dir, plugin_dir)
    if not ok then
        os.rename(backup, plugin_dir)
        ffiUtil.purgeDir(staging)
        return nil, rename_error or "cannot install new plugin" end
    ffiUtil.purgeDir(staging)
    LuaSettings:open(ota_dir .. "/installed.lua")
        :saveSetting("version", release.version)
        :saveSetting("backup", backup)
        :flush()
    return true
end

function OTA:cleanup_backup(plugin_dir)
    local ota_dir = DataStorage:getDataDir() .. "/wordwise/ota"
    local marker = ota_dir .. "/installed.lua"
    if lfs.attributes(marker, "mode") ~= "file" then return end
    local settings = LuaSettings:open(marker)
    local backup = settings:readSetting("backup")
    if backup == plugin_dir .. ".ota-backup" and lfs.attributes(backup, "mode") then
        ffiUtil.purgeDir(backup)
    end
    settings:purge()
end

return OTA
