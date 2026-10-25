local ADDON_NAME, ns = ...
local BL = ns.BL

BL.SOUNDS = {
    { key = "ding",  label = "Soft ding",    id = (SOUNDKIT and SOUNDKIT.TELL_MESSAGE) or 3081 },
    { key = "ping",  label = "Map ping",     id = (SOUNDKIT and SOUNDKIT.MAP_PING) or 3175 },
    { key = "alarm", label = "Raid warning", id = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959 },
}

local REASONS = {
    whisper   = { setting = "warnWhisper",        text = "%s whispered you." },
    invite    = { setting = "warnInvite",         text = "%s invited you to a group." },
    group     = { setting = "warnGroup",          text = "%s is in your group." },
    outinvite = { setting = "warnOutgoingInvite", text = "You invited %s." },
}

local guildCache = {}  -- guid -> { name, realm } learned from units we've seen
local lastWarn = {}    -- reason:id -> GetTime()
local groupWarned = {} -- guid -> true for the current group

------------------------------------------------------------------------
-- Output
------------------------------------------------------------------------

function BL:PlayWarningSound(key)
    key = key or self.db.global.settings.sound
    for _, s in ipairs(self.SOUNDS) do
        if s.key == key then
            PlaySound(s.id, "Master")
            return
        end
    end
end

local function ColoredName(e)
    local c = e and e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
    local name = BL:FullName(e.name, e.realm)
    if c then return ("|c%s%s|r"):format(c.colorStr or "ffffffff", name) end
    return name
end

-- who: display name; p: player entry or nil; g: guild entry or nil
function BL:Warn(reason, who, p, g, throttleId)
    local r = REASONS[reason]
    local s = self.db.global.settings
    if not r or not s[r.setting] then return end

    local key = reason .. ":" .. (throttleId or who or "?")
    local now = GetTime()
    if lastWarn[key] and now - lastWarn[key] < (s.cooldown or 60) then return end
    lastWarn[key] = now

    local display = p and ColoredName(p) or who
    local headline = r.text:format("|cffffd100" .. display .. "|r")
    local lines = {}
    local function AddEntry(kind, e, title)
        lines[#lines + 1] = "|cffff6060" .. title .. "|r"
        for _, n in ipairs(self:DisplayNotes(kind, e)) do
            lines[#lines + 1] = "  " .. n[1] .. ": |cffffffff" .. n[2] .. "|r"
        end
    end
    if p then AddEntry("players", p, "Blacklisted player") end
    if g then
        AddEntry("guilds", g, "Member of blacklisted guild <" .. g.name .. ">")
    end

    if s.useChat then
        self:Print("|cffff4040WARNING:|r " .. headline)
        for _, l in ipairs(lines) do
            DEFAULT_CHAT_FRAME:AddMessage("    " .. l)
        end
    end
    if s.useSound then self:PlayWarningSound() end
    if s.usePopup then self:ShowPopup(headline, table.concat(lines, "\n")) end
end

function BL:TestWarning()
    local s = self.db.global.settings
    local saved = s.warnWhisper
    s.warnWhisper = true
    lastWarn["whisper:test"] = nil
    self:Warn("whisper", "Testplayer", { name = "Testplayer", realm = self:MyRealm(), class = "ROGUE", note = "Community test note.", myNote = "My personal test note." },
        { name = "Test Guild", note = "Test guild note." }, "test")
    s.warnWhisper = saved
end

------------------------------------------------------------------------
-- Popup
------------------------------------------------------------------------

function BL:CreatePopup()
    local f = CreateFrame("Frame", "RedFlagWarningPopup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(380, 170)
    f:SetPoint("TOP", UIParent, "TOP", 0, -160)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    f:SetBackdropBorderColor(1, 0.25, 0.25)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
    icon:SetSize(36, 36)
    icon:SetPoint("TOPLEFT", 16, -16)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    title:SetText("|cffff4040Red Flag Warning|r")

    f.headline = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.headline:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -10)
    f.headline:SetPoint("RIGHT", -16, 0)
    f.headline:SetJustifyH("LEFT")

    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.body:SetPoint("TOPLEFT", f.headline, "BOTTOMLEFT", 0, -8)
    f.body:SetPoint("RIGHT", -16, 0)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetTextColor(1, 0.6, 0.6)

    local ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ok:SetSize(90, 22)
    ok:SetPoint("BOTTOMRIGHT", -14, 14)
    ok:SetText(OKAY or "OK")
    ok:SetScript("OnClick", function() f:Hide() end)

    local open = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    open:SetSize(110, 22)
    open:SetPoint("RIGHT", ok, "LEFT", -6, 0)
    open:SetText("Open List")
    open:SetScript("OnClick", function() f:Hide(); BL:ShowMainFrame() end)

    tinsert(UISpecialFrames, "RedFlagWarningPopup") -- Escape closes it
    self.popup = f
end

function BL:ShowPopup(headline, body)
    if not self.popup then self:CreatePopup() end
    local f = self.popup
    f.headline:SetText(headline)
    f.body:SetText(body)
    local h = 16 + 36 + 10 + f.headline:GetStringHeight() + 8 + f.body:GetStringHeight() + 50
    f:SetHeight(math.max(140, h))
    f:Show()
end

------------------------------------------------------------------------
-- Detection
------------------------------------------------------------------------

-- Remember guild + resolve GUIDs for any player unit we come across
function BL:ObserveUnit(unit)
    local info = self:InfoFromUnit(unit)
    if not info or not info.guid then return info end
    local gName, _, _, gRealm = GetGuildInfo(unit)
    if gName then
        guildCache[info.guid] = { gName, (gRealm and gRealm ~= "") and gRealm or self:MyRealm() }
    end
    self:ObservePlayer(info)
    return info
end

function BL:LookupGUID(guid, name)
    local info = guid and self:InfoFromGUID(guid)
    if info then self:ObservePlayer(info) end
    local n, r
    if info then n, r = info.name, info.realm else n, r = self:SplitName(name) end
    local p = self:FindPlayer(guid, n, r)
    local gc = guid and guildCache[guid]
    local g = gc and self:FindGuild(gc[1], gc[2])
    return p, g, n and self:FullName(n, r) or name
end

function BL:CHAT_MSG_WHISPER(_, _, sender, _, _, _, flags, _, _, _, _, _, guid)
    if flags == "GM" then return end
    local p, g, display = self:LookupGUID(guid, sender)
    if p or g then self:Warn("whisper", display, p, g, guid or sender) end
end

function BL:PARTY_INVITE_REQUEST(_, inviter, ...)
    local guid = select(6, ...)
    if type(guid) ~= "string" then guid = nil end
    local p, g, display = self:LookupGUID(guid, inviter)
    if not p and not guid and inviter then p = self:FindPlayerByName(inviter) end
    if p or g then self:Warn("invite", display or inviter, p, g, guid or inviter) end
end

function BL:CheckGroup()
    if not IsInGroup() then
        wipe(groupWarned)
        return
    end
    local prefix, count = "party", GetNumSubgroupMembers()
    if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end
    for i = 1, count do
        local unit = prefix .. i
        if not UnitIsUnit(unit, "player") then
            local info = self:ObserveUnit(unit)
            if info and info.guid and not groupWarned[info.guid] then
                local p = self:FindPlayer(info.guid, info.name, info.realm)
                local gName, _, _, gRealm = GetGuildInfo(unit)
                local g = gName and self:FindGuild(gName, (gRealm and gRealm ~= "") and gRealm or nil)
                if p or g then
                    groupWarned[info.guid] = true
                    self:Warn("group", self:FullName(info.name, info.realm), p, g, info.guid)
                end
            end
        end
    end
end

local function OnOutgoingInvite(target)
    if type(target) ~= "string" or target == "" then return end
    local p, g, display
    if UnitExists(target) then
        local info = BL:ObserveUnit(target)
        if info then
            p = BL:FindPlayer(info.guid, info.name, info.realm)
            local gName, _, _, gRealm = GetGuildInfo(target)
            g = gName and BL:FindGuild(gName, (gRealm and gRealm ~= "") and gRealm or nil)
            display = BL:FullName(info.name, info.realm)
        end
    end
    if not p and not g then
        p = BL:FindPlayerByName(target)
        display = target
    end
    if p or g then BL:Warn("outinvite", display, p, g, (p and p.id) or target:lower()) end
end

------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------

local function TooltipUnit(tooltip)
    if not BL.db.global.settings.tooltip or tooltip ~= GameTooltip then return end
    if tooltip.redFlagDone then return end -- both hooks may fire for the same tooltip
    local _, unit = tooltip:GetUnit()
    if not unit and UnitExists("mouseover") then unit = "mouseover" end
    if not unit or not UnitIsPlayer(unit) then return end
    tooltip.redFlagDone = true
    local info = BL:ObserveUnit(unit)
    if not info then return end
    local p = BL:FindPlayer(info.guid, info.name, info.realm)
    local gName, _, _, gRealm = GetGuildInfo(unit)
    local g = gName and BL:FindGuild(gName, (gRealm and gRealm ~= "") and gRealm or nil)
    local function AddEntry(kind, e, title)
        tooltip:AddLine(title, 1, 0.25, 0.25)
        for _, n in ipairs(BL:DisplayNotes(kind, e)) do
            tooltip:AddLine(n[1] .. ": |cffffffff" .. n[2] .. "|r", 1, 0.6, 0.6, true)
        end
    end
    if p then AddEntry("players", p, "Blacklisted") end
    if g then AddEntry("guilds", g, "Blacklisted guild <" .. g.name .. ">") end
    if p or g then tooltip:Show() end
end

------------------------------------------------------------------------

function BL:SetupWarnings()
    self:RegisterEvent("CHAT_MSG_WHISPER")
    self:RegisterEvent("PARTY_INVITE_REQUEST")
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "CheckGroup")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "CheckGroup")
    self:RegisterEvent("PLAYER_TARGET_CHANGED", function() BL:ObserveUnit("target") end)

    if InviteUnit then hooksecurefunc("InviteUnit", OnOutgoingInvite) end
    if C_PartyInfo and C_PartyInfo.InviteUnit then hooksecurefunc(C_PartyInfo, "InviteUnit", OnOutgoingInvite) end

    -- Hook every mechanism the client offers; which one fires differs between client builds.
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, TooltipUnit)
    end
    if GameTooltip:HasScript("OnTooltipSetUnit") then
        GameTooltip:HookScript("OnTooltipSetUnit", TooltipUnit)
    end
    GameTooltip:HookScript("OnTooltipCleared", function(tt) tt.redFlagDone = nil end)
    GameTooltip:HookScript("OnHide", function(tt) tt.redFlagDone = nil end)
    -- last resort: mouseover event (e.g. if another addon rebuilds the tooltip)
    self:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
        BL:ObserveUnit("mouseover")
        if GameTooltip:IsShown() then
            local _, unit = GameTooltip:GetUnit()
            if unit and UnitIsUnit(unit, "mouseover") then TooltipUnit(GameTooltip) end
        end
    end)
end
