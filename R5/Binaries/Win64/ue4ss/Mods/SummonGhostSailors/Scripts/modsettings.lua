--[[
 SummonGhostSailors / modsettings.lua — optional R5ModSettings integration, adapted from
 LivingBase's own modsettings.lua (2026-08-26, RedFalcon: "a mod settings lua generating").

 Entirely optional: every function here first checks whether the "R5ModSettings" UE4SS mod is
 actually installed (IsInstalled(), memoized) and no-ops harmlessly if not.

 Deliberately does NOT require("R5ModSettings") -- UE4SS mods aren't guaranteed to see each
 other's Scripts folder on the Lua path (same reasoning LivingBase's own modsettings.lua
 documents) -- this only reads/writes the same plain Lua-table files (registrations/*.lua,
 saved/*.lua) R5ModSettings itself reads/writes.

 Scope, deliberately smaller than LivingBase's: keybinds + the handful of tuning numbers/
 toggles a player would actually want to change, applied ONCE at mod load (config.lua calls
 ApplyOnce before main.lua reads Config). No live polling -- every setting here is either a
 keybind (always restart-only, same as LivingBase's) or read fresh from Config on every use
 anyway (GHOST_LIFETIME_MS/GHOST_MAX_ACTIVE/GHOST_FX_ENABLED are all read live inside follow.lua's
 own tick already), so a full poll timer would add real complexity for no real benefit here —
 revisit if that changes.
]]

local M = {}

M.MOD_ID = "SummonGhostSailors"
M.VERSION = "1.1.0"   -- keep equal to mod.txt
local RS_ROOTS = { "ue4ss/Mods/R5ModSettings/", "Mods/R5ModSettings/" }

local rsRootChecked, rsRoot = false, nil
function M.IsInstalled()
    if not rsRootChecked then
        rsRootChecked = true
        for _, root in ipairs(RS_ROOTS) do
            local f = io.open(root .. "enabled.txt", "r")
            if f then f:close(); rsRoot = root; break end
        end
    end
    return rsRoot
end

-- R5ModSettings' in-game keybind picker reads/saves standard Unreal FKey names, a different
-- convention from this UE4SS build's own Key[] table (e.g. "OEM_FIVE" here vs "Backslash"
-- there) -- ported directly from LivingBase's own LB_TO_UE table (confirmed-correct
-- translations, same UE4SS build). Only the entries actually relevant here plus the general
-- punctuation/nav-key set, in case a player remaps to something else via the picker.
local LB_TO_UE = {
    NUM_ONE = "NumPadOne", NUM_TWO = "NumPadTwo", NUM_THREE = "NumPadThree", NUM_FOUR = "NumPadFour",
    NUM_FIVE = "NumPadFive", NUM_SIX = "NumPadSix", NUM_SEVEN = "NumPadSeven", NUM_EIGHT = "NumPadEight",
    NUM_NINE = "NumPadNine", NUM_ZERO = "NumPadZero",
    NUM_ADD = "Add", NUM_SUBTRACT = "Subtract", NUM_MULTIPLY = "Multiply", NUM_DIVIDE = "Divide",
    NUM_DECIMAL = "Decimal",
    INS = "Insert", DEL = "Delete", PAGE_UP = "PageUp", PAGE_DOWN = "PageDown",
    OEM_COMMA = "Comma", OEM_PERIOD = "Period", OEM_FIVE = "Backslash",
    UP = "Up", DOWN = "Down", LEFT = "Left", RIGHT = "Right",
    HOME = "Home", END = "End", BACKSPACE = "BackSpace",
    DIGIT_0 = "Zero", DIGIT_1 = "One", DIGIT_2 = "Two", DIGIT_3 = "Three", DIGIT_4 = "Four",
    DIGIT_5 = "Five", DIGIT_6 = "Six", DIGIT_7 = "Seven", DIGIT_8 = "Eight", DIGIT_9 = "Nine",
    TAB = "Tab", ENTER = "Enter", ESCAPE = "Escape", SPACE = "SpaceBar",
    CAPS_LOCK = "CapsLock", NUM_LOCK = "NumLock", SCROLL_LOCK = "ScrollLock",
    PRINT_SCREEN = "PrintScreen", PAUSE = "Pause",
    LEFT_SHIFT = "LeftShift", RIGHT_SHIFT = "RightShift",
    LEFT_CONTROL = "LeftControl", RIGHT_CONTROL = "RightControl",
    LEFT_ALT = "LeftAlt", RIGHT_ALT = "RightAlt",
    OEM_SEMICOLON = "Semicolon", OEM_EQUALS = "Equals", OEM_MINUS = "Hyphen", OEM_SLASH = "Slash",
    OEM_TILDE = "Tilde", OEM_LEFT_BRACKET = "LeftBracket", OEM_RIGHT_BRACKET = "RightBracket",
    OEM_QUOTE = "Quote",
    MOUSE_LEFT = "LeftMouseButton", MOUSE_RIGHT = "RightMouseButton", MOUSE_MIDDLE = "MiddleMouseButton",
    MOUSE_THUMB1 = "ThumbMouseButton", MOUSE_THUMB2 = "ThumbMouseButton2",
}
local UE_TO_LB = {}
for lb, ue in pairs(LB_TO_UE) do UE_TO_LB[ue] = lb end

function M.ToUnreal(lbName) return LB_TO_UE[lbName] or lbName end
function M.ToLivingBase(ueName) return UE_TO_LB[ueName] or ueName end

-- `key` is both the R5ModSettings saved-value key AND the Config field name main.lua/config.lua
-- reads it back into.
M.KEYBIND_DEFS = {
    { key = "SUMMON_KEY",    title = "Summon Ghost Sailor",     description = "Summons a ghost sailor that follows you and fights alongside you, then despawns after the ghost lifetime. (Optionally a Grenadier, see below.) Restart the game after changing." },
    { key = "SENKAMATI_KEY", title = "Summon Senkamati Ally",   description = "Summons a corrupted Senkamati ally (Warrior, Hunter, Caster or Thrall) that fights alongside you, then despawns after the ghost lifetime. Restart the game after changing." },
}

-- RETRIED as real sliders (2026-08-26, RedFalcon: "can we not make them sliders to like 500
-- seconds and 15 ghosts"). Plain `type = "number"` is confirmed dead (silently coerced into a
-- checkbox, 0/1 only) -- but main.dll (R5ModSettings' native component) references the game's
-- own native settings-screen slider widget, WBP_Settings_EntryScalar, and contains the literal
-- lowercase strings "scalar"/"discrete" alongside a "[{}] Skipped unsupported setting
-- mod={} key={} type={} options={}" log line -- real evidence a `type = "scalar"` setting is
-- genuinely supported, just never tried before now. The exact field names EntryScalar expects
-- (min/max here are a first guess, not confirmed) live in that compiled DLL, unreachable from
-- Lua source -- if the panel doesn't render a slider, check ue4ss.log for that exact "Skipped
-- unsupported setting" line quoting these keys; that tells us definitively whether the type
-- string or the field shape is wrong, rather than guessing blind a second time.
-- CONFIRMED (2026-08-26, straight from Windrose Mod Settings' own author): the real type
-- string is "slider", not "scalar" -- "scalar" happened to render something (the fractional
-- 8.21-style values were real evidence of THAT), but was never the documented/intended type.
-- The real schema has a `step` field (movement increment) alongside `min`/`max` -- step = 1
-- makes the slider itself snap to whole numbers, so the math.floor(...) rounding in ApplyOnce
-- below is now just a defensive backstop, not the only thing keeping this sane.
-- `scale`: the UI operates in more human-friendly units than the underlying Config field —
-- GHOST_LIFETIME_MS is milliseconds internally, but a 500-SECOND slider reads far better than
-- a 500000-ms one, so the panel shows/saves SECONDS and ApplyOnce multiplies by `scale` back
-- into Config. GHOST_MAX_ACTIVE has no scale (1:1, already a plain count).
M.VALUE_DEFS = {
    { key = "GHOST_LIFETIME_MS", title = "Ghost Lifetime (seconds)", description = "How long every summon (sailors, Senkamati, Grenadier) lasts before it dissipates."..' Changes take effect after restarting the game.', min = 10, max = 500, step = 1, scale = 1000 },
    { key = "FOLLOW_WARP_UU",    title = "Teleport Distance (m)",     description = "How far behind you a summon can fall before it teleports back beside you. Summons walk at a fixed slow pace out of combat, so lower values keep them close. Changes take effect after restarting the game.", min = 10, max = 500, step = 1, scale = 100 },
    { key = "GHOST_MAX_ACTIVE",  title = "Max Simultaneous Ghosts",  description = "How many summons (sailors, Senkamati and Grenadiers combined) can be active at once."..' Changes take effect after restarting the game.'..'', min = 1, max = 15, step = 1 },
    { key = "GRENADIER_CHANCE",  title = "Grenadier Chance (%)",      description = "Chance that a sailor summon is a Grenadier instead. Only used when Grenadier Summons is on."..' Changes take effect after restarting the game.', min = 1, max = 50, step = 1, scale = 0.01, float = true },
}

M.TOGGLE_DEFS = {
    { key = "GHOST_FX_ENABLED", title = "Ground Light Effect", description = "Show the ground-light effect that follows each summon."..' Changes take effect after restarting the game.' },
    { key = "DISABLE_GHOST_EFFECT", title = "Disable Ghost Effect", description = "When on, summons keep their normal look instead of being reskinned as ghosts. Off by default. Restart the game after changing." },
    { key = "GRENADIER_ENABLED", title = "Grenadier Summons", description = "When on, a sailor summon can be a Grenadier instead (see Grenadier Chance). OFF by default: its grenades do a lot of damage, including to your own base. Restart the game after changing." },
}

local function is_identifier(s)
    return type(s) == "string" and s:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function serialize(value, indent)
    indent = indent or "    "
    local vt = type(value)
    if vt == "number" or vt == "boolean" then return tostring(value) end
    if vt == "string" then return string.format("%q", value) end
    if vt ~= "table" then return "nil" end
    local parts = { "{\n" }
    local numericKeys, stringKeys = {}, {}
    for k in pairs(value) do
        if type(k) == "number" then numericKeys[#numericKeys + 1] = k
        else stringKeys[#stringKeys + 1] = k end
    end
    table.sort(numericKeys, function(a, b) return a < b end)
    table.sort(stringKeys, function(a, b) return a < b end)
    local keys = numericKeys
    for _, k in ipairs(stringKeys) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        local kt = is_identifier(k) and k or ("[" .. serialize(k, indent .. "    ") .. "]")
        parts[#parts + 1] = indent .. kt .. " = " .. serialize(value[k], indent .. "    ") .. ",\n"
    end
    parts[#parts + 1] = indent:sub(1, math.max(#indent - 4, 0)) .. "}"
    return table.concat(parts)
end

function M.ReadSavedFile()
    local root = M.IsInstalled()
    if not root then return nil end
    local f = io.open(root .. "saved/" .. M.MOD_ID .. ".lua", "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return nil end
    if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
    local loader = load(content)
    if not loader then return nil end
    local ok, data = pcall(loader)
    return (ok and type(data) == "table") and data or nil
end

function M.WriteManifest(Config)
    local root = M.IsInstalled()
    if not root then return false end

    local settings = {}
    for _, def in ipairs(M.VALUE_DEFS) do
        local scale = def.scale or 1
        local dflt = (Config[def.key] or 0) / scale
        if def.float then dflt = math.floor(dflt + 0.5) end
        settings[#settings + 1] = {
            key = def.key, title = def.title, description = def.description, type = "slider",
            default = dflt, min = def.min, max = def.max, step = def.step or 1,
        }
    end
    for _, def in ipairs(M.TOGGLE_DEFS) do
        settings[#settings + 1] = {
            key = def.key, title = def.title, description = def.description, type = "toggle",
            default = Config[def.key] and true or false,
        }
    end
    for _, def in ipairs(M.KEYBIND_DEFS) do
        local lbDefault = Config[def.key] or "None"
        settings[#settings + 1] = {
            key = def.key, title = def.title, description = def.description, type = "keybind",
            default = { primary = M.ToUnreal(lbDefault), secondary = "None" },
        }
    end

    local manifest = {
        -- Display name only (2026-08-26, RedFalcon) -- internal folder/MOD_ID stays
        -- "SummonGhostSailors" (same pattern as LivingBase itself: internal folder "LivingBase",
        -- display "Living Base Enhanced") so the R5ModSettings install-check
        -- (mod_is_installed, keyed on the actual folder name) keeps working unchanged.
        name = M.MOD_ID, display = "LBE: Summonable Ghost Fighters", version = M.VERSION, nexus_id = "548",
        settings = settings,
    }
    local body = "-- Generated by SummonGhostSailors (modsettings.lua). Do not edit; regenerated on every mod load.\nreturn "
        .. serialize(manifest, "    ") .. "\n"

    local dir = root .. "registrations/"
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    local path = dir .. M.MOD_ID .. ".lua"
    local existingF = io.open(path, "r")
    if existingF then
        local existingBody = existingF:read("*all")
        existingF:close()
        if existingBody == body then return true end
    end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(body)
    f:close()
    return true
end

-- One-time apply: called by config.lua at mod load. Mutates Config[*] in place from whatever's
-- currently saved. A keybind changed here still needs a game restart to take effect (same as
-- LivingBase — RegisterKeyBind is confirmed unsafe to call outside the initial load pass).
function M.ApplyOnce(Config)
    if not M.IsInstalled() then return 0, 0 end
    M.WriteManifest(Config)
    local saved = M.ReadSavedFile()
    if not saved then return 0, 0 end
    local applied = 0
    for _, def in ipairs(M.KEYBIND_DEFS) do
        local v = saved[def.key]
        if type(v) == "table" and type(v.primary) == "string" and v.primary ~= "" and v.primary ~= "None" then
            local translated = M.ToLivingBase(v.primary)
            if translated ~= Config[def.key] then
                print(string.format("[GhostSailors] R5ModSettings: %s -> raw='%s' resolved='%s' (was '%s')\n",
                    def.key, v.primary, translated, tostring(Config[def.key])))
            end
            Config[def.key] = translated
            applied = applied + 1
        end
    end
    for _, def in ipairs(M.VALUE_DEFS) do
        local v = saved[def.key]
        if type(v) == "number" then
            -- Rounded to a whole number (2026-08-26, RedFalcon: "I can't summon 8.21 ghosts")
            -- -- the native EntryScalar slider is a continuous float with no integer-step field
            -- found anywhere in R5ModSettings' own main.dll (checked via string extraction:
            -- no "step"/"interval"/"integer"/"round"/"delta" hit at all), so it can't be made
            -- to snap on the UI side through this registration schema. Rounding here instead
            -- guarantees the value this mod actually USES is always a sane whole number,
            -- regardless of whatever fractional value the slider saved while being dragged.
            if def.float then Config[def.key] = v * (def.scale or 1)
            else Config[def.key] = math.floor(v * (def.scale or 1) + 0.5) end
            applied = applied + 1
        end
    end
    for _, def in ipairs(M.TOGGLE_DEFS) do
        local v = saved[def.key]
        if type(v) == "boolean" then
            Config[def.key] = v
            applied = applied + 1
        end
    end
    if applied > 0 then
        print(string.format("[GhostSailors] R5ModSettings: applied %d setting(s) from Settings > Mods.\n", applied))
    end
    return applied
end

return M
