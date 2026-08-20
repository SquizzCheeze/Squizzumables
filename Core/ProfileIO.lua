-- Core/ProfileIO.lua
-- Turn a profile into a shareable string, and back.
--
-- Two decisions worth explaining, because both had obvious-looking alternatives
-- that are wrong:
--
-- 1. The serialised form is parsed, never executed.
--    Emitting a Lua table constructor and running it through loadstring is the
--    quick way to do this, and it means anyone who can get you to paste a
--    string can run arbitrary code in your client. So this uses a small
--    self-describing format with a hand-written reader instead. It cannot do
--    anything but produce data.
--
-- 2. Only differences from the defaults are exported.
--    The addon has ~130 settings and a typical profile changes a handful. Most
--    addons solve the resulting string length by compressing with LibDeflate;
--    exporting deltas instead gets short strings without vendoring a
--    2,000-line library, and has the side benefit that importing an old string
--    into a newer version picks up any new defaults rather than pinning them
--    to whatever they were when the string was made.
--
-- Format:  SQ1!<base64 payload>
--
--    N            nil
--    T  F         true / false
--    #<num>;      number
--    $<len>;<..>  string, length-prefixed so any byte is safe
--    {  k v ... } table, alternating key and value

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local ProfileIO = {}
ns.ProfileIO = ProfileIO

local PREFIX = "SQ1!"

-- ============================================================================
-- Base64
--
-- The payload travels through chat, Discord and forum posts, so it has to
-- survive whitespace mangling and be selectable as one blob.
-- ============================================================================

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function EncodeBase64(data)
    local out, len = {}, #data
    local i = 1
    while i <= len do
        local a, b, c = data:byte(i, i + 2)
        b, c = b or 0, c or 0
        local n = a * 65536 + b * 256 + c
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. ((i + 1 <= len) and B64:sub(c3 + 1, c3 + 1) or "=")
            .. ((i + 2 <= len) and B64:sub(c4 + 1, c4 + 1) or "=")
        i = i + 3
    end
    return table.concat(out)
end

local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

local function DecodeBase64(text)
    text = text:gsub("[^%w%+/=]", "")     -- tolerate pasted line breaks and spaces
    local out = {}
    local i = 1
    while i <= #text do
        local chunk = text:sub(i, i + 3)
        if #chunk < 4 then break end
        local n, pad = 0, 0
        for j = 1, 4 do
            local ch = chunk:sub(j, j)
            if ch == "=" then
                n = n * 64
                pad = pad + 1
            else
                local v = B64_INDEX[ch]
                if not v then return nil end  -- not our alphabet: reject
                n = n * 64 + v
            end
        end
        local b1 = math.floor(n / 65536) % 256
        local b2 = math.floor(n / 256) % 256
        local b3 = n % 256
        out[#out + 1] = string.char(b1)
        if pad < 2 then out[#out + 1] = string.char(b2) end
        if pad < 1 then out[#out + 1] = string.char(b3) end
        i = i + 4
    end
    return table.concat(out)
end

-- ============================================================================
-- Serialise / parse
-- ============================================================================

local function Write(value, out)
    local t = type(value)
    if value == nil then
        out[#out + 1] = "N"
    elseif t == "boolean" then
        out[#out + 1] = value and "T" or "F"
    elseif t == "number" then
        out[#out + 1] = "#" .. tostring(value) .. ";"
    elseif t == "string" then
        out[#out + 1] = "$" .. #value .. ";" .. value
    elseif t == "table" then
        out[#out + 1] = "{"
        for k, v in pairs(value) do
            -- Skip anything we cannot represent rather than emitting a broken
            -- payload that fails on import.
            local kt, vt = type(k), type(v)
            if (kt == "string" or kt == "number")
                and (vt == "string" or vt == "number" or vt == "boolean" or vt == "table") then
                Write(k, out)
                Write(v, out)
            end
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = "N"
    end
end

-- Returns value, nextPos -- or nil, nil on malformed input. Every caller checks,
-- so a corrupt paste produces a clean error rather than a partial profile.
local function Read(s, pos)
    local tag = s:sub(pos, pos)
    if tag == "" then return nil, nil end
    if tag == "N" then return nil, pos + 1, true end
    if tag == "T" then return true, pos + 1, true end
    if tag == "F" then return false, pos + 1, true end

    if tag == "#" then
        local stop = s:find(";", pos + 1, true)
        if not stop then return nil, nil end
        local n = tonumber(s:sub(pos + 1, stop - 1))
        if not n then return nil, nil end
        return n, stop + 1, true
    end

    if tag == "$" then
        local stop = s:find(";", pos + 1, true)
        if not stop then return nil, nil end
        local len = tonumber(s:sub(pos + 1, stop - 1))
        if not len or len < 0 then return nil, nil end
        local str = s:sub(stop + 1, stop + len)
        if #str ~= len then return nil, nil end
        return str, stop + 1 + len, true
    end

    if tag == "{" then
        local tbl = {}
        pos = pos + 1
        while true do
            if s:sub(pos, pos) == "}" then return tbl, pos + 1, true end
            if pos > #s then return nil, nil end
            local key, nextPos, ok = Read(s, pos)
            if not ok then return nil, nil end
            local value
            value, nextPos, ok = Read(s, nextPos)
            if not ok then return nil, nil end
            if key ~= nil then tbl[key] = value end
            pos = nextPos
        end
    end

    return nil, nil
end

-- ============================================================================
-- Delta against defaults
-- ============================================================================

-- Keep only what differs from `defaults`, recursively. This is what keeps the
-- exported string short without a compression library.
local function DiffFromDefaults(value, defaults)
    if type(value) ~= "table" or type(defaults) ~= "table" then
        if value == defaults then return nil end
        return value
    end
    local out, any = {}, false
    for k, v in pairs(value) do
        local diff = DiffFromDefaults(v, defaults[k])
        if diff ~= nil then
            out[k] = diff
            any = true
        end
    end
    return any and out or nil
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Export the named profile (or the active one) as a shareable string.
function ProfileIO.Export(profileName)
    if not SquizzumablesDB or not SquizzumablesDB.profiles then return nil, "No profiles to export." end
    profileName = profileName or BH:GetActiveProfileName()
    -- The active profile's live values live in SquizzumablesDB rather than in
    -- the stored profile until something writes them back, so flush first.
    if profileName == BH:GetActiveProfileName() then BH:SaveToProfile() end

    local profile = SquizzumablesDB.profiles[profileName]
    if not profile then return nil, "Profile '" .. tostring(profileName) .. "' not found." end

    local payload = {
        name        = profileName,
        settings    = DiffFromDefaults(profile.settings, BH.defaultSettings),
        disabled    = profile.disabled,
        minDuration = profile.minDuration,
        customItems = profile.customItems,
        positions   = profile.positions,
    }

    local out = {}
    Write(payload, out)
    return PREFIX .. EncodeBase64(table.concat(out))
end

-- Decode a string without applying it, so the UI can name the profile it holds
-- and reject bad input before touching anything.
function ProfileIO.Decode(text)
    if type(text) ~= "string" then return nil, "Nothing to import." end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "Nothing to import." end
    if text:sub(1, #PREFIX) ~= PREFIX then
        return nil, "That does not look like a Squizzumables profile string."
    end
    local raw = DecodeBase64(text:sub(#PREFIX + 1))
    if not raw or raw == "" then return nil, "Could not decode that string -- it looks damaged." end
    local data, _, ok = Read(raw, 1)
    if not ok or type(data) ~= "table" then
        return nil, "Could not read that profile -- it looks damaged or truncated."
    end
    return data
end

-- Apply a decoded payload as a profile. Creates it if new, overwrites if not.
function ProfileIO.Apply(data, profileName)
    if type(data) ~= "table" then return false, "Nothing to import." end
    profileName = profileName or data.name or "Imported"
    if not SquizzumablesDB.profiles then SquizzumablesDB.profiles = {} end

    -- Start from the defaults and lay the imported differences on top, so a
    -- string made on an older version still gets any settings added since.
    local settings = CopyTable(BH.defaultSettings)
    if type(data.settings) == "table" then
        local function merge(dst, src)
            for k, v in pairs(src) do
                if type(v) == "table" and type(dst[k]) == "table" then
                    merge(dst[k], v)
                else
                    dst[k] = v
                end
            end
        end
        merge(settings, data.settings)
    end

    SquizzumablesDB.profiles[profileName] = {
        settings    = settings,
        disabled    = type(data.disabled) == "table" and CopyTable(data.disabled) or {},
        minDuration = type(data.minDuration) == "table" and CopyTable(data.minDuration) or {},
        customItems = type(data.customItems) == "table" and CopyTable(data.customItems)
                      or { food = {}, flask = {}, oil = {} },
        positions   = type(data.positions) == "table" and CopyTable(data.positions) or {},
    }
    return true, profileName
end
