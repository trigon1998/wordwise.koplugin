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
local SHA256 = require("wordwise_sha256")

local OTA = {
    owner = "trigon1998",
    repo = "wordwise.koplugin",
    asset_name = "wordwise.koplugin.zip",
    current_version = "0.2.13",
}
OTA.checksum_name = OTA.asset_name .. ".sha256"
OTA.api_url = "https://api.github.com/repos/" .. OTA.owner .. "/" .. OTA.repo .. "/releases/latest"

local MAX_DOWNLOAD_SIZE = 32 * 1024 * 1024
local MAX_EXTRACTED_SIZE = 64 * 1024 * 1024
local MAX_ARCHIVE_ENTRIES = 512
local BACKGROUND_CHECK_INTERVAL = 60 * 60

-- Session-only cache used by the optional wake-time check. A failed attempt is
-- also throttled so waking a device without working internet cannot repeatedly
-- block on the same request.
local cached_release
local cached_error
local last_check_time

local REQUIRED_FILES = {
    ["main.lua"] = true,
    ["_meta.lua"] = true,
    ["wordwise_db.lua"] = true,
    ["wordwise_hint_dialog.lua"] = true,
    ["wordwise_l10n.lua"] = true,
    ["wordwise_ota.lua"] = true,
    ["wordwise_sha256.lua"] = true,
    ["wordwise.db"] = true,
}

local function version_parts(v)
    local a, b, c = tostring(v or ""):match("^[vV]?(%d+)%.(%d+)%.(%d+)$")
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

local function request_url(url, make_sink, timeout_pair, max_bytes)
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
        local received = 0
        if max_bytes then
            local raw_sink = sink
            sink = function(chunk, err)
                if chunk then
                    received = received + #chunk
                    if received > max_bytes then
                        raw_sink(nil, "download exceeds size limit")
                        return nil, "download exceeds size limit"
                    end
                end
                return raw_sink(chunk, err)
            end
        end
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
        if call_ok and result == 1 and code == 200 then return headers, nil, received end
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
    local socketutil = require("socketutil")
    local _, err = request_url(self.api_url, function()
        chunks = {}
        return socketutil.table_sink(chunks)
    end, { socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT }, 1024 * 1024)
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
    local asset, checksum_asset
    for _, candidate in ipairs(release.assets or {}) do
        if candidate.name == self.asset_name then
            asset = candidate
        elseif candidate.name == self.checksum_name then
            checksum_asset = candidate
        end
    end
    if not asset or type(asset.browser_download_url) ~= "string"
            or not asset.browser_download_url:match("^https://") then
        return nil, "expected plugin ZIP asset is missing"
    end
    if type(asset.size) ~= "number" or asset.size <= 0 or asset.size > MAX_DOWNLOAD_SIZE then
        return nil, "plugin ZIP size is invalid or exceeds the safety limit"
    end
    if not checksum_asset or type(checksum_asset.browser_download_url) ~= "string"
            or not checksum_asset.browser_download_url:match("^https://") then
        return nil, "expected SHA-256 checksum asset is missing"
    end
    return {
        version = tag:gsub("^[vV]", ""),
        tag = tag,
        name = release.name or tag,
        notes = release.body or "",
        asset_url = asset.browser_download_url,
        asset_size = asset.size,
        checksum_url = checksum_asset.browser_download_url,
    }
end

-- Perform a quiet release lookup at most once per hour. The third return value
-- is true only when this call actually contacted GitHub, allowing callers to
-- avoid repeating a notification for a cached result on every wake.
function OTA:fetch_latest_cached()
    local now = os.time()
    if last_check_time and now - last_check_time < BACKGROUND_CHECK_INTERVAL then
        return cached_release, cached_error, false
    end
    last_check_time = now
    cached_release, cached_error = self:fetch_latest()
    return cached_release, cached_error, true
end

local function safe_archive_path(path)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true)
            or path:find("\\", 1, true) or path:sub(1, 1) == "/"
            or path:match("^[A-Za-z]:") or path:find("//", 1, true) then
        return false
    end
    for component in path:gmatch("[^/]+") do
        if component == "." or component == ".." then return false end
    end
    return true
end
OTA.safe_archive_path = safe_archive_path

function OTA:validate_archive(zip_path, staging_dir, expected_version)
    local arc = Archiver.Reader:new()
    local ok, err = arc:open(zip_path)
    if not ok then arc:close(); return nil, err or "cannot open update archive" end
    local files = {}
    local valid = true
    local total_size = 0
    local entry_count = 0
    for entry in arc:iterate() do
        local path = entry.path
        if not safe_archive_path(path) then valid = false; err = "unsafe archive path"; break end
        entry_count = entry_count + 1
        if entry_count > MAX_ARCHIVE_ENTRIES then valid = false; err = "too many archive entries"; break end
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            valid = false; err = "archive contains links or unsupported entry types"; break
        end
        local first = path:match("^([^/]+)/")
        if not first or first ~= "wordwise.koplugin" then
            valid = false; err = "archive root must be wordwise.koplugin"; break
        end
        local relative = path:sub(#"wordwise.koplugin/" + 1)
        if relative ~= "" and entry.mode == "file" then
            if files[relative] then valid = false; err = "duplicate archive entry: " .. relative; break end
            local entry_size = tonumber(entry.size)
            if not entry_size or entry_size < 0 then
                valid = false; err = "archive entry has an invalid size"; break
            end
            files[relative] = true
            total_size = total_size + entry_size
            if total_size > MAX_EXTRACTED_SIZE then
                valid = false; err = "extracted update exceeds size limit"; break
            end
        end
    end
    if valid then
        for required in pairs(REQUIRED_FILES) do
            if not files[required] then valid = false; err = "required file missing: " .. required; break end
        end
    end
    if not valid then arc:close(); return nil, err end
    if lfs.attributes(staging_dir, "mode") then
        local purged = ffiUtil.purgeDir(staging_dir)
        if not purged then arc:close(); return nil, "cannot clear staging directory" end
    end
    if not ensure_dir(staging_dir) then arc:close(); return nil, "cannot create staging directory" end
    for entry in arc:iterate() do
        if not arc:extractToPath(entry.path, staging_dir .. "/" .. entry.path) then
            valid = false; err = arc.err or "archive extraction failed"; break
        end
    end
    arc:close()
    if not valid then ffiUtil.purgeDir(staging_dir); return nil, err end
    local new_dir = staging_dir .. "/wordwise.koplugin"
    local meta = util.readFromFile(new_dir .. "/_meta.lua")
    local archive_version = meta and meta:match("version%s*=%s*['\"]([^'\"]+)['\"]")
    if expected_version and archive_version ~= expected_version then
        ffiUtil.purgeDir(staging_dir)
        return nil, "archive version does not match release tag"
    end
    return new_dir
end

function OTA:install(release, plugin_dir)
    local ota_dir = DataStorage:getDataDir() .. "/wordwise/ota"
    if not ensure_dir(ota_dir) then return nil, "cannot create OTA directory" end
    local zip_path = ota_dir .. "/" .. self.asset_name
    local checksum_path = ota_dir .. "/" .. self.checksum_name
    local staging = ota_dir .. "/staging"
    local socketutil = require("socketutil")
    local _, err = request_url(release.checksum_url, function()
        local file = io.open(checksum_path, "wb")
        if not file then return nil, "cannot create checksum file" end
        return socketutil.file_sink(file)
    end, { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT }, 4096)
    if err then os.remove(checksum_path); return nil, err end
    local checksum_text = util.readFromFile(checksum_path) or ""
    os.remove(checksum_path)
    local expected_hash = checksum_text:match("^%s*([%x]+)")
    if not expected_hash or #expected_hash ~= 64 then return nil, "invalid SHA-256 checksum asset" end
    expected_hash = expected_hash:lower()

    _, err = request_url(release.asset_url, function()
        local file = io.open(zip_path, "wb")
        if not file then return nil, "cannot create download file" end
        return socketutil.file_sink(file)
    end, { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT }, MAX_DOWNLOAD_SIZE)
    if err then os.remove(zip_path); return nil, err end
    local downloaded_size = lfs.attributes(zip_path, "size")
    if downloaded_size ~= release.asset_size then
        os.remove(zip_path)
        return nil, "downloaded ZIP size does not match release metadata"
    end
    local actual_hash, hash_error = SHA256.digest_file(zip_path)
    if not actual_hash or actual_hash ~= expected_hash then
        os.remove(zip_path)
        return nil, hash_error or "SHA-256 checksum mismatch"
    end
    local new_dir, validation_error = self:validate_archive(zip_path, staging, release.version)
    os.remove(zip_path)
    if not new_dir then return nil, validation_error end

    local backup = plugin_dir .. ".ota-backup"
    if lfs.attributes(backup, "mode") and not ffiUtil.purgeDir(backup) then
        ffiUtil.purgeDir(staging)
        return nil, "cannot remove previous OTA backup"
    end
    local ok, rename_error = os.rename(plugin_dir, backup)
    if not ok then ffiUtil.purgeDir(staging); return nil, rename_error or "cannot stage current plugin" end
    ok, rename_error = os.rename(new_dir, plugin_dir)
    if not ok then
        local restored, restore_error = os.rename(backup, plugin_dir)
        ffiUtil.purgeDir(staging)
        if not restored then
            return nil, "installation and rollback failed; backup remains at "
                .. backup .. ": " .. tostring(restore_error or rename_error)
        end
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
