--[[
================================================================================
lilu_dev
https://www.nexusmods.com/dragonsdogma2/mods/1600
================================================================================
]]

local modname = "NpcDialogueThrottle"
local modversion = "3.2.1"
local configfile = modname .. ".json"

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------

local DefaultConfig = {
    Npc = {
        Enabled = true,
        GlobalCooldownSeconds = 5,  -- how often ANY NPC at all is allowed to speak
        CooldownSeconds = 30,       -- how often the SAME NPC may speak again
    },

    Pawn = {
        Enabled = true,
        NpcCooldownSeconds = 30,       -- per-speaker cooldown
        SameLineCooldownSeconds = 300, -- same exact line cooldown
        RepeatProbability = 20,        -- % chance a repeat is allowed once its cooldown passes
        KeepMinimapMarkers = true,
    },

    -- Tried, in order, to resolve "who is speaking" for the pawn bucket's per-speaker cooldown.
    -- Each is tried both as a zero-arg method call and as a field read; first one that returns a
    -- managed object with a usable address wins.
    SpeakerAccessors = {
        "get_Owner", "Owner", "_Owner",
        "get_Chara", "Chara", "_Chara",
        "get_Character", "Character", "_Character",
    },

    Debug = false,
}

local Config = {}

local function tableCopyDeep(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = dst[k] or {}
            tableCopyDeep(dst[k], v)
        else
            dst[k] = v
        end
    end
end

local function config_reset()
    Config = {}
    tableCopyDeep(Config, DefaultConfig)
end

local function config_load()
    config_reset()
    local loaded = json.load_file(configfile)
    if loaded then
        tableCopyDeep(Config, loaded)
    end
end

-- No Save/Reload/Reset buttons in the UI -- settings just autosave shortly after you stop
-- dragging a slider, same idea as MoreNPC.lua's debounced save (a slider fires many changes a
-- second while being dragged; writing the json on every single one would be wasteful).
local _savePending, _saveAt = false, 0
local function requestSave()
    _savePending = true
    _saveAt = os.clock() + 1.0
end
local function flushSave()
    if _savePending and os.clock() >= _saveAt then
        json.dump_file(configfile, Config)
        _savePending = false
    end
end
re.on_frame(flushSave)

config_load()

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function Log(msg)
    log.info("[" .. modname .. "] " .. tostring(msg))
end

local function Debug(msg)
    if Config.Debug then
        log.debug("[" .. modname .. "] " .. tostring(msg))
    end
end

local app_TalkEventManager = sdk.get_managed_singleton("app.TalkEventManager")

-- Native "this is a real quest/story conversation" flag (app.TalkEventManager.
-- IsQuestImportantTalkPlay). Always respected, not user-configurable -- there is no reason to
-- ever throttle an actual scripted conversation.
local function isQuestImportantTalkPlaying()
    if not app_TalkEventManager then return false end
    local ok, val = pcall(function() return app_TalkEventManager:call("get_IsQuestImportantTalkPlay") end)
    return ok and val == true
end

---------------------------------------------------------------------------
-- Pawn bucket: per-message-GUID throttle engine
---------------------------------------------------------------------------

local function makeBucket()
    local bucket = {
        cfg = nil, -- set on each check from Config.Pawn (so live UI edits apply)
        messages = {}, -- [msgid] = { last_spoken = t, times_spoken = n }
        speakers = {}, -- [speakerKey] = last_spoken_time
    }

    -- Try to resolve a stable identity for the character speaking, for the per-speaker cooldown.
    -- Returns a string key, or nil if nothing could be resolved (caller then skips that tier).
    function bucket:resolveSpeakerKey(entity)
        for _, accessorName in ipairs(Config.SpeakerAccessors) do
            local ok, obj = pcall(function() return entity:call(accessorName) end)
            if not ok or obj == nil then
                ok, obj = pcall(function() return entity[accessorName] end)
            end
            if ok and obj ~= nil then
                local ok2, addr = pcall(function() return obj:get_address() end)
                if ok2 and addr ~= nil then
                    return "owner:" .. tostring(addr)
                end
            end
        end
        -- Fallback: the TalkEntity's own address. Only meaningful as a per-speaker key if the
        -- game reuses one persistent TalkEntity per pawn.
        local ok, addr = pcall(function() return entity:get_address() end)
        if ok and addr ~= nil then
            return "entity:" .. tostring(addr)
        end
        return nil
    end

    -- key: string identifying the utterance attempt -- for pawns this is a group key built from
    -- every candidate's msgid in this play() call (see handlePawnTalkPlay), because multiple
    -- candidates in one call are alternate phrasings of ONE utterance the engine picks between,
    -- not independent lines. entity: the TalkEntity managed object (for speaker resolution).
    -- Returns true if the utterance should be BLOCKED.
    function bucket:shouldBlock(key, entity)
        local cfg = self.cfg
        local now = os.clock()
        local info = self.messages[key]

        -- 1. Same-line cooldown
        if info and info.last_spoken and (now - info.last_spoken) < cfg.SameLineCooldownSeconds then
            return true
        end

        -- 2. Repeated-line probability (only applies once a line has actually played before)
        if info and info.times_spoken and info.times_spoken > 0 then
            if math.random(1, 100) > cfg.RepeatProbability then
                return true
            end
        end

        -- 3. Per-speaker cooldown (any line from the same speaker)
        local speakerKey = self:resolveSpeakerKey(entity)
        if speakerKey then
            local lastForSpeaker = self.speakers[speakerKey]
            if lastForSpeaker and (now - lastForSpeaker) < cfg.NpcCooldownSeconds then
                return true
            end
        end

        self:recordSpoken(key, now, speakerKey)
        return false
    end

    function bucket:recordSpoken(key, now, speakerKey)
        local info = self.messages[key]
        if not info then
            info = { times_spoken = 0 }
            self.messages[key] = info
        end
        info.last_spoken = now
        info.times_spoken = info.times_spoken + 1

        if speakerKey then
            self.speakers[speakerKey] = now
        end
    end

    return bucket
end

local PawnBucket = makeBucket()

-- A single play() call's _Candidates are ALTERNATE PHRASINGS of one utterance the engine itself
-- picks between -- not independent lines. So the whole group is throttled as one unit (see
-- groupKey below): throttling each candidate separately would let the per-speaker cooldown, once
-- set by the first candidate, immediately block every other candidate in that same call.
local function handlePawnTalkPlay(bucket, args)
    local restoreList = nil

    local ok = pcall(function()
        if isQuestImportantTalkPlaying() then return end
        if not bucket.cfg.Enabled then return end

        local entity = sdk.to_managed_object(args[2])
        if not entity then return end

        local segment = entity:get_CurrentSegment()
        if not segment then return end

        -- Find every candidate line in this segment, same approach as Shut Up Pawns: the game
        -- picks one of _Candidates at random/by context.
        local candidateCount = 0
        pcall(function() candidateCount = #segment._Candidates end)

        local candidates, msgids = {}, {}
        for i = 0, candidateCount - 1 do
            local candidate = segment._Candidates[i]
            if candidate ~= nil and candidate._MsgId ~= nil then
                candidates[#candidates + 1] = candidate
                msgids[#msgids + 1] = candidate._MsgId:ToString()
            end
        end
        if #candidates == 0 then return end

        -- Group key: all candidate msgids together, sorted so the same phrasing pool always
        -- produces the same key regardless of array order. This is what actually gets throttled.
        table.sort(msgids)
        local groupKey = table.concat(msgids, "|")

        local blocked = bucket:shouldBlock(groupKey, entity)

        if blocked then
            for _, candidate in ipairs(candidates) do
                local originalMsgId = candidate._MsgId
                candidate._MsgId = nil -- suppress the whole utterance attempt, restored below
                restoreList = restoreList or {}
                restoreList[#restoreList + 1] = { candidate = candidate, msgid = originalMsgId }
            end

            if not bucket.cfg.KeepMinimapMarkers then
                entity:set_CurrentSegment(nil)
            end
        end
    end)

    if not ok then
        Debug("Pawn: hook body errored, falling back to CALL_ORIGINAL")
    end

    return restoreList
end

do
    local typeName = "app.PLPartyTalkController.TalkEntity"
    local td = sdk.find_type_definition(typeName)
    if td and td:get_method("play") then
        local pendingRestore = nil

        sdk.hook(
            td:get_method("play"),
            function(args)
                PawnBucket.cfg = Config.Pawn
                pendingRestore = handlePawnTalkPlay(PawnBucket, args)
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                if pendingRestore then
                    for _, item in ipairs(pendingRestore) do
                        item.candidate._MsgId = item.msgid
                    end
                    pendingRestore = nil
                end
                return retval
            end
        )
        Log("Pawn dialogue hook attached (" .. typeName .. ")")
    else
        Log("WARNING: could not find " .. typeName .. " -- pawn dialogue throttling is inactive")
    end
end

---------------------------------------------------------------------------
-- Town NPC bucket: two-tier cooldown on app.NpcTalkWorker::isNpcTalkRequestAble
---------------------------------------------------------------------------

local NpcNextEligible = {} -- [workerAddress] = os.clock() timestamp after which that NPC may speak again
local NpcGlobalNextEligible = 0 -- os.clock() timestamp after which ANY NPC may speak again

do
    local typeName = "app.NpcTalkWorker"
    local methodName = "isNpcTalkRequestAble"
    local td = sdk.find_type_definition(typeName)
    local method = td and td:get_method(methodName)

    if method then
        local pendingKey = nil -- handed from the pre-hook to the post-hook for this same call

        sdk.hook(
            method,
            function(args)
                local ok, self = pcall(function() return sdk.to_managed_object(args[2]) end)
                if ok and self then
                    local ok2, addr = pcall(function() return self:get_address() end)
                    pendingKey = (ok2 and addr) and tostring(addr) or nil
                else
                    pendingKey = nil
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                if not Config.Npc.Enabled then return retval end
                if isQuestImportantTalkPlaying() then return retval end
                if not pendingKey then return retval end

                -- Lua's only falsy values are nil and false -- treat anything else as "the game
                -- said yes" rather than comparing strictly to `true`.
                if retval == false or retval == nil then return retval end

                local now = os.clock()

                -- Tier 1: is a "turn" open at all right now, for anyone?
                if now < NpcGlobalNextEligible then
                    Debug("Npc: blocked (any-NPC cooldown), key=" .. pendingKey)
                    return false
                end

                -- Tier 2: a turn is open -- but is THIS specific NPC off their own cooldown? If
                -- not, we don't consume the open turn -- it stays open for the next eligible
                -- NPC's poll.
                local nextForSpeaker = NpcNextEligible[pendingKey]
                if nextForSpeaker and now < nextForSpeaker then
                    Debug("Npc: blocked (same-NPC cooldown), key=" .. pendingKey)
                    return false
                end

                -- Allowed. Jitter this speaker's own cooldown by +/-20% so a group of NPCs that
                -- all got a turn together doesn't stay locked in step on every future cycle.
                local jitter = 0.8 + math.random() * 0.4
                NpcNextEligible[pendingKey] = now + Config.Npc.CooldownSeconds * jitter
                NpcGlobalNextEligible = now + Config.Npc.GlobalCooldownSeconds
                return retval
            end
        )
        Log("Town NPC cooldown hook attached (" .. typeName .. "::" .. methodName .. ")")
    else
        Log("WARNING: " .. typeName .. "::" .. methodName .. " not found in this build -- town NPC throttling is inactive")
    end
end

---------------------------------------------------------------------------
-- UI -- one window, two fixed rounded panels (Town NPCs / Pawns), no collapsible
-- sub-sections, no buttons, no stats.
---------------------------------------------------------------------------

local UI_SECTION_TITLE_COLOR = 0xFFFFA040 -- blue (packed as AABBGGRR)
local UI_MUTED_COLOR = 0xFF808080
local UI_BOX_WIDTH = 640

-- begin_rect()/end_rect() (used by boxBegin/boxEnd below) auto-expands the rounded frame to fit
-- whatever is drawn inside it. imgui.slider_int stretches to the full available width by default,
-- which is wider than UI_BOX_WIDTH -- so left unconstrained, sliders would blow each box out past
-- 640 and the three boxes would end up different sizes. Narrowing sliders with push_item_width
-- keeps every box at exactly UI_BOX_WIDTH, same fix as TWINWV.lua's pushItemWidth/popItemWidth.
local UI_ITEM_WIDTH = 260
local itemWidthOk = true -- if push_item_width isn't exported by this imgui binding, quietly skip it
local function pushItemWidth(width)
    if not itemWidthOk then return end
    local ok = pcall(imgui.push_item_width, width or UI_ITEM_WIDTH)
    if not ok then itemWidthOk = false end
end
local function popItemWidth()
    if not itemWidthOk then return end
    pcall(imgui.pop_item_width)
end

-- Rounded-box chrome, copied from TWINWV.lua / helpers/utils.lua (boxBegin/boxEnd + the
-- matching push_style_var/push_style_color theme for the controls drawn inside it).
local boxIdCounter = 0
local function boxBegin(width)
    imgui.spacing()
    imgui.unindent(20)
    imgui.begin_rect()
    imgui.indent()
    boxIdCounter = boxIdCounter + 1
    local fontSizeOk, fontSize = pcall(function() return imgui.get_default_font_size() end)
    imgui.invisible_button("##ndt-box-" .. boxIdCounter, { width or UI_BOX_WIDTH, (fontSizeOk and fontSize) or 14 }, 0)
end

local function boxEnd()
    imgui.spacing()
    imgui.spacing()
    imgui.spacing()
    imgui.unindent()
    imgui.end_rect()
    imgui.indent(20)
    imgui.spacing()
end

local function pushBoxTheme()
    imgui.push_style_var(12, 4) -- ImGuiStyleVar_FrameRounding
    imgui.push_style_var(21, 3) -- ImGuiStyleVar_GrabRounding
    imgui.push_style_color(5, 0xFF464646)  -- Border
    imgui.push_style_color(7, 0xFF343434)  -- FrameBg
    imgui.push_style_color(8, 0xFF484848)  -- FrameBgHovered
    imgui.push_style_color(9, 0xFF565656)  -- FrameBgActive
    imgui.push_style_color(18, UI_SECTION_TITLE_COLOR) -- CheckMark
    imgui.push_style_color(21, 0xFF3A3A3A) -- Button
    imgui.push_style_color(22, 0xFF505050) -- ButtonHovered
    imgui.push_style_color(23, 0xFF606060) -- ButtonActive
    imgui.push_style_color(24, 0xFF343434) -- Header
    imgui.push_style_color(25, 0xFF484848) -- HeaderHovered
    imgui.push_style_color(26, 0xFF565656) -- HeaderActive
end

local function popBoxTheme()
    imgui.pop_style_color(11)
    imgui.pop_style_var(2)
end

local function drawSection(titleText, drawBody)
    pushBoxTheme()
    boxBegin(UI_BOX_WIDTH)
    imgui.text_colored(titleText, UI_SECTION_TITLE_COLOR)
    imgui.spacing()
    drawBody()
    boxEnd()
    popBoxTheme()
end

re.on_draw_ui(function()
    if not imgui.tree_node(modname) then return end

    local changed = false

    drawSection("Town NPCs", function()
        local cfg = Config.Npc
        local c

        c, cfg.Enabled = imgui.checkbox("Enabled##npc_enabled", cfg.Enabled); changed = changed or c

        imgui.spacing()
        pushItemWidth()
        c, cfg.GlobalCooldownSeconds = imgui.slider_int("Any-NPC cooldown (seconds)", cfg.GlobalCooldownSeconds, 1, 60)
        popItemWidth()
        changed = changed or c
        imgui.text_colored("How often you hear a line from any NPC nearby, no matter who says it.", UI_MUTED_COLOR)

        imgui.spacing()
        pushItemWidth()
        c, cfg.CooldownSeconds = imgui.slider_int("Same NPC cooldown (seconds)", cfg.CooldownSeconds, 5, 300)
        popItemWidth()
        changed = changed or c
        imgui.text_colored("How long one specific NPC stays quiet before they can speak again.", UI_MUTED_COLOR)
    end)

    drawSection("Pawns", function()
        local cfg = Config.Pawn
        local c

        c, cfg.Enabled = imgui.checkbox("Enabled##pawn_enabled", cfg.Enabled); changed = changed or c

        imgui.spacing()
        pushItemWidth()
        c, cfg.NpcCooldownSeconds = imgui.slider_int("Per-speaker cooldown (seconds)", cfg.NpcCooldownSeconds, 5, 60)
        popItemWidth()
        changed = changed or c

        imgui.spacing()
        pushItemWidth()
        c, cfg.SameLineCooldownSeconds = imgui.slider_int("Same line cooldown (seconds)", cfg.SameLineCooldownSeconds, 30, 300)
        popItemWidth()
        changed = changed or c

        imgui.spacing()
        pushItemWidth()
        c, cfg.RepeatProbability = imgui.slider_int("Repeated line probability (%)", cfg.RepeatProbability, 0, 100)
        popItemWidth()
        changed = changed or c

        imgui.spacing()
        c, cfg.KeepMinimapMarkers = imgui.checkbox("Keep minimap markers on blocked lines", cfg.KeepMinimapMarkers); changed = changed or c
    end)

    if changed then requestSave() end

    imgui.tree_pop()
end)

Log("Loaded " .. modname .. " v" .. modversion)
