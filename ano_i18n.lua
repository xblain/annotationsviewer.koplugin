local logger = require("logger")
local _dir   = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")

-- Minimal .po parser
local function parsePO(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local map = {}
    local msgid, msgstr, in_id, in_str = nil, nil, false, false
    -- Fuzzy entries are msgmerge's unconfirmed guesses (flagged `#, fuzzy`,
    -- usually after a string rename). Real gettext treats them as
    -- untranslated and falls back to the source msgid; we must too. Applying
    -- them surfaced stale pre-rename strings — e.g. en_GB titled the
    -- "Bar colours" menu "Border colour". `pending_fuzzy` accumulates from the
    -- comment block; it becomes `entry_fuzzy` once the entry's msgid is seen.
    local entry_fuzzy, pending_fuzzy = false, false

    local function flush()
        if msgid and msgstr and msgid ~= "" and msgstr ~= "" and not entry_fuzzy then
            map[msgid] = msgstr
        end
        msgid, msgstr, in_id, in_str = nil, nil, false, false
        entry_fuzzy = false
    end

    -- one pass, so an escaped backslash before "n" stays a backslash and an "n"
    local ESC = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }
    local function unescape(s)
        return (s:gsub("\\(.)", ESC))
    end

    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line:match("^#") or line == "" then
            if line:match("^#,") and line:find("fuzzy", 1, true) then
                pending_fuzzy = true
            end
            if line == "" then flush(); pending_fuzzy = false end
        elseif line:match('^msgid%s+"') then
            flush()
            entry_fuzzy = pending_fuzzy
            pending_fuzzy = false
            msgid  = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_id  = true; in_str = false
        elseif line:match('^msgstr%s+"') then
            msgstr = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_str = true; in_id  = false
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_id  and msgid  then msgid  = msgid  .. cont end
            if in_str and msgstr then msgstr = msgstr .. cont end
        end
    end
    flush()
    f:close()
    return map
end

local function detectLang()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if type(lang) == "string" and lang ~= "" then return lang end
    local lc = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    lang = lc:match("^([a-zA-Z_]+)")
    return lang or "en"
end

-- Build the translation function once at require time
local ko_gettext = require("gettext")
local translations

local lang = detectLang()
if lang ~= "en" and lang ~= "en_US" then
    local function try(name)
        local path = _dir .. "locale/" .. name .. ".po"
        local t = parsePO(path)
        if t and next(t) then
            local n = 0; for _ in pairs(t) do n = n + 1 end
            logger.info("AnnotationsViewer i18n: loaded " .. path .. " — " .. n .. " strings")
            return t
        end
    end
    translations = try(lang) or (function()
        local prefix = lang:match("^([a-zA-Z]+)")
        if prefix and prefix ~= lang then return try(prefix) end
    end)()

    if translations then
        logger.info("AnnotationsViewer i18n: installed for language: " .. lang)
    end
end

--- Translation function: checks .po first, then KOReader gettext.
local function gettext(msgid)
    if translations then
        local t = translations[msgid]
        if t then return t end
    end
    return ko_gettext(msgid)
end

return {
    gettext = gettext,
    getLang = detectLang,
    _parsePO = parsePO,  -- exposed for tests
}
