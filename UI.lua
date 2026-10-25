local ADDON_NAME, ns = ...
local BL = ns.BL
local Call = BL.CallProvider

local ROW_H = 20
local NUM_ROWS = 17
local LIST_W = 300
local NOTE_W = 320
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

-- list tabs: tab key -> { kind, scope } (scope = "mine" or a provider id); built in BuildTabs
local TABS = {}
local TAB_ORDER = {}

local main
local rows = {}
local settingsChecks = {}
local state = {
    tab = "myplayers",
    selected = {}, -- tab -> id
    filter = "",
    data = {},
}

local function Kind() return TABS[state.tab].kind end
local function Scope() return TABS[state.tab].scope end
local function IsMine() return Scope() == "mine" end
local function CurrentProvider() return BL:Provider(Scope()) end

-- "your personal list" / "the Guild list"
local function ListText(scope, colored)
    if scope == "mine" then
        return colored and "your |cffffd100personal list|r" or "your personal list"
    end
    local p = BL:Provider(scope)
    local name = p and (p.label or p.id) or "other"
    return colored and ("the |cff40ff40" .. name .. " list|r") or ("the " .. name .. " list")
end

local function BuildTabs()
    wipe(TABS)
    wipe(TAB_ORDER)
    local hasProviders = #BL.providers > 0
    for _, p in ipairs(BL.providers) do
        local tabs = type(p.tabs) == "table" and p.tabs or {}
        local label = p.label or p.id
        for _, kind in ipairs({ "players", "guilds" }) do
            local key = p.id .. ":" .. kind
            TABS[key] = { kind = kind, scope = p.id }
            TAB_ORDER[#TAB_ORDER + 1] = { key, tabs[kind] or (label .. (kind == "players" and " Players" or " Guilds")) }
        end
    end
    TABS.myplayers = { kind = "players", scope = "mine" }
    TABS.myguilds = { kind = "guilds", scope = "mine" }
    TAB_ORDER[#TAB_ORDER + 1] = { "myplayers", hasProviders and "My Players" or "Players" }
    TAB_ORDER[#TAB_ORDER + 1] = { "myguilds", hasProviders and "My Guilds" or "Guilds" }
    TAB_ORDER[#TAB_ORDER + 1] = { "settings", "Settings" }
end

local function Panel(parent)
    local f = CreateFrame("Frame", nil, parent, BACKDROP_TEMPLATE)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.5)
    f:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
    return f
end

local function Text(parent, font, ...)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    if ... then fs:SetPoint(...) end
    fs:SetJustifyH("LEFT")
    return fs
end

local function Button(parent, label, width, ...)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    if ... then b:SetPoint(...) end
    return b
end

local function FormatDate(t)
    return t and date("%Y-%m-%d %H:%M", t) or "?"
end

local function ClassRGB(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function EntryLabel(kind, e)
    return kind == "guilds" and ("<" .. e.name .. ">") or BL:FullName(e.name, e.realm)
end

------------------------------------------------------------------------
-- Popups (add by name, confirm remove / copy)
------------------------------------------------------------------------

local function PopupEditBox(self)
    return self.editBox or self.EditBox
end

function BL:AddByName(tab, text)
    text = text and strtrim(text) or ""
    if text == "" or not TABS[tab] then return end
    local t = TABS[tab]
    local e
    if t.kind == "players" then
        e = self:AddTargetOrName(text, t.scope)
    else
        e = self:AddGuildOrTarget(text, t.scope)
    end
    if e then self:ShowMainFrame(tab, e.id) end
end

StaticPopupDialogs["REDFLAG_ADD_NAME"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 64,
    OnShow = function(self) PopupEditBox(self):SetFocus() end,
    OnAccept = function(self, tab) BL:AddByName(tab, PopupEditBox(self):GetText()) end,
    EditBoxOnEnterPressed = function(self, tab)
        local parent = self:GetParent()
        BL:AddByName(tab, self:GetText())
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["REDFLAG_CONFIRM_REMOVE"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data) BL:Remove(data.kind, data.id, data.scope) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["REDFLAG_CONFIRM_COPY"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data) BL:CopyToList(data.kind, data.id, data.scope) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Small dialog that sizes itself to its text (StaticPopup adds uneven padding with 3 buttons).
-- buttons: list of { label, func }; Escape closes it without doing anything.
local choiceDialog
local function ShowChoice(text, buttons)
    local PAD, GAP, BTN_W, BTN_H = 20, 16, 150, 22
    if not choiceDialog then
        local f = CreateFrame("Frame", "RedFlagChoiceDialog", UIParent, BACKDROP_TEMPLATE)
        f:SetWidth(3 * BTN_W + 2 * 8 + 2 * PAD)
        f:SetPoint("TOP", UIParent, "TOP", 0, -135)
        f:SetFrameStrata("DIALOG")
        f:SetToplevel(true)
        f:EnableMouse(true)
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.text:SetPoint("TOP", 0, -PAD - 4)
        f.text:SetWidth(f:GetWidth() - 2 * PAD - 16)
        f.text:SetJustifyH("CENTER")
        f.buttons = {}
        for i = 1, 3 do
            local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            b:SetSize(BTN_W, BTN_H)
            f.buttons[i] = b
        end
        f:Hide()
        tinsert(UISpecialFrames, "RedFlagChoiceDialog")
        choiceDialog = f
    end
    local f = choiceDialog
    f.text:SetText(text)
    local n = #buttons
    local rowW = n * BTN_W + (n - 1) * 8
    for i, b in ipairs(f.buttons) do
        local def = buttons[i]
        if def then
            b:SetText(def[1])
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", f, "BOTTOM", -rowW / 2 + (i - 1) * (BTN_W + 8), PAD)
            b:SetScript("OnClick", function()
                f:Hide()
                if def[2] then def[2]() end
            end)
            b:Show()
        else
            b:Hide()
        end
    end
    f:SetHeight(PAD + 4 + f.text:GetStringHeight() + GAP + BTN_H + PAD)
    f:Show()
end

------------------------------------------------------------------------
-- List view
------------------------------------------------------------------------

local function CreateListView(f)
    local lv = CreateFrame("Frame", nil, f)
    lv:SetPoint("TOPLEFT", 10, -58)
    lv:SetPoint("BOTTOMRIGHT", -10, 10)
    f.listView = lv

    -- search
    local search = CreateFrame("EditBox", "RedFlagSearchBox", lv, "InputBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("TOPLEFT", 12, -2)
    search:SetAutoFocus(false)
    local placeholder = Text(search, "GameFontDisable", "LEFT", 2, 0)
    placeholder:SetText("Search...")
    search:SetScript("OnTextChanged", function(self)
        placeholder:SetShown(self:GetText() == "")
        state.filter = self:GetText()
        BL:UpdateList()
    end)
    search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- add buttons
    f.addTarget = Button(lv, "Add Target", 130, "LEFT", search, "RIGHT", 10, 0)
    f.addTarget:SetScript("OnClick", function()
        local e
        if Kind() == "players" then
            e = BL:AddTargetOrName(nil, Scope())
        else
            e = BL:AddGuildOrTarget(nil, Scope())
        end
        if e then BL:ShowMainFrame(state.tab, e.id) end
    end)
    f.addName = Button(lv, "Add by Name", 110, "LEFT", f.addTarget, "RIGHT", 4, 0)
    f.addName:SetScript("OnClick", function()
        local what = Kind() == "players" and "player name (Name or Name-Realm)" or "guild name"
        StaticPopup_Show("REDFLAG_ADD_NAME", "Add to " .. ListText(Scope()) .. " - enter the " .. what .. ":", nil, state.tab)
    end)

    -- which list this is: right next to the add buttons
    f.scopeLabel = Text(lv, "GameFontNormal", "LEFT", f.addName, "RIGHT", 12, 0)
    f.scopeLabel:SetPoint("RIGHT", lv, "RIGHT", -4, 0)
    f.scopeLabel:SetWordWrap(false)

    -- list
    local listBg = Panel(lv)
    listBg:SetPoint("TOPLEFT", 0, -28)
    listBg:SetSize(LIST_W + 30, NUM_ROWS * ROW_H + 10)

    local scroll = CreateFrame("ScrollFrame", "RedFlagListScroll", listBg, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 5, -5)
    scroll:SetPoint("BOTTOMRIGHT", -27, 5)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() BL:UpdateList() end)
    end)
    f.scroll = scroll

    local function Wheel(_, delta)
        local bar = scroll.ScrollBar or _G["RedFlagListScrollScrollBar"]
        if bar and bar:IsShown() then bar:SetValue(bar:GetValue() - delta * ROW_H * 3) end
    end

    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, listBg)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 5, -5 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.2)
        row.sel:Hide()
        row.name = Text(row, "GameFontHighlight", "LEFT", 4, 0)
        row.name:SetWidth(130)
        row.name:SetWordWrap(false)
        row.note = Text(row, "GameFontDisableSmall", "LEFT", row.name, "RIGHT", 6, 0)
        row.note:SetPoint("RIGHT", -4, 0)
        row.note:SetWordWrap(false)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", Wheel)
        row:SetScript("OnClick", function(self)
            state.selected[state.tab] = self.id
            BL:UpdateMainFrame()
        end)
        rows[i] = row
    end

    f.count = Text(lv, "GameFontDisableSmall", "TOPLEFT", listBg, "BOTTOMLEFT", 4, -4)

    -- detail panel
    local d = CreateFrame("Frame", nil, lv)
    d:SetPoint("TOPLEFT", listBg, "TOPRIGHT", 12, 0)
    d:SetPoint("BOTTOMRIGHT", lv, "BOTTOMRIGHT", 0, 0)
    f.detail = d

    d.empty = Text(d, "GameFontDisable", "TOPLEFT", 4, -8)
    d.empty:SetText("Select an entry or add one.")

    d.content = CreateFrame("Frame", nil, d)
    d.content:SetAllPoints()
    local c = d.content

    d.name = Text(c, "GameFontNormalLarge", "TOPLEFT", 4, -4)
    d.info = Text(c, "GameFontHighlightSmall", "TOPLEFT", d.name, "BOTTOMLEFT", 0, -8)
    d.info:SetPoint("RIGHT", c, "RIGHT", -4, 0)
    d.info:SetJustifyV("TOP")
    d.info:SetSpacing(3)

    -- Provider-list entries: my personal note + the list's own note.
    -- Personal-list entries: only the personal note.
    local function NoteBox(name, y)
        local lbl = Text(c, "GameFontNormal", "TOPLEFT", 4, y)

        local bg = Panel(c)
        bg:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", -4, -4)
        bg:SetSize(NOTE_W + 36, 92)

        local scroll = CreateFrame("ScrollFrame", name, bg, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 8, -8)
        scroll:SetPoint("BOTTOMRIGHT", -28, 8)

        local box = CreateFrame("EditBox", nil, scroll)
        box:SetMultiLine(true)
        box:SetAutoFocus(false)
        box:SetFontObject(ChatFontNormal)
        box:SetWidth(NOTE_W)
        box:SetMaxLetters(BL.MAX_NOTE)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnCursorChanged", function(self, _, cy, _, h)
            -- keep the cursor visible while typing
            local top = scroll:GetVerticalScroll()
            cy = -cy
            if cy < top then
                scroll:SetVerticalScroll(cy)
            elseif cy + h > top + scroll:GetHeight() then
                scroll:SetVerticalScroll(cy + h - scroll:GetHeight())
            end
        end)
        scroll:SetScrollChild(box)
        bg:EnableMouse(true)
        bg:SetScript("OnMouseDown", function() box:SetFocus() end)

        box.chars = Text(c, "GameFontDisableSmall", "BOTTOMRIGHT", bg, "TOPRIGHT", -4, 3)
        box.label = lbl
        box.bg = bg
        return box
    end

    d.myBox = NoteBox("RedFlagMyNoteScroll", -112)
    d.comBox = NoteBox("RedFlagListNoteScroll", -230)

    d.save = Button(c, "Save Notes", 100)
    d.revert = Button(c, "Revert", 80, "LEFT", d.save, "RIGHT", 4, 0)
    d.remove = Button(c, "Remove", 90)
    -- top right, on the same line as the name: copy to the other list
    d.copy = Button(c, "", 130, "TOPRIGHT", c, "TOPRIGHT", -2, 0)
    d.name:SetWordWrap(false)
    d.name:SetWidth(215) -- keep long names clear of that button

    -- buttons sit under the last visible note box
    function d.Layout(scope)
        local mine = scope == "mine"
        local anchor = mine and d.myBox.bg or d.comBox.bg
        d.comBox.label:SetShown(not mine)
        d.comBox.bg:SetShown(not mine)
        d.comBox.chars:SetShown(not mine)
        if not mine then
            local p = BL:Provider(scope)
            d.comBox.label:SetText((p and p.noteLabel) or ((p and p.noteName or "List") .. " note"))
        end
        d.save:ClearAllPoints()
        d.save:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
        d.remove:ClearAllPoints()
        d.remove:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -6)
        d.save:SetText(mine and "Save Note" or "Save Notes")
        d.myBox.label:SetText("Personal note |cff888888(only for you)|r")
    end

    local function CurrentEntry()
        return BL:GetEntry(Kind(), Scope(), state.selected[state.tab])
    end

    -- the first box always holds the (single) personal note of the player/guild
    local function SavedMine(e)
        return BL:GetPersonalNote(Kind(), e) or ""
    end

    local function Len(box)
        local t = box:GetText()
        return strlenutf8 and strlenutf8(t) or #t
    end

    local function UpdateButtons()
        local e = CurrentEntry()
        local changed = false
        if e then
            changed = d.myBox:GetText() ~= SavedMine(e)
                or (not IsMine() and d.comBox:GetText() ~= (e.note or ""))
        end
        d.save:SetEnabled(changed)
        d.revert:SetEnabled(changed)
        d.myBox.chars:SetText(("%d / %d"):format(Len(d.myBox), BL.MAX_NOTE))
        d.comBox.chars:SetText(("%d / %d"):format(Len(d.comBox), BL.MAX_NOTE))
    end
    d.UpdateButtons = UpdateButtons
    d.myBox:SetScript("OnTextChanged", UpdateButtons)
    d.comBox:SetScript("OnTextChanged", UpdateButtons)

    d.save:SetScript("OnClick", function()
        local e = CurrentEntry()
        if not e then return end
        d.myBox:ClearFocus()
        d.comBox:ClearFocus()
        local kind, mine, com = Kind(), d.myBox:GetText(), d.comBox:GetText()
        if mine ~= SavedMine(e) then
            BL:SetPersonalNote(kind, e, mine)
        end
        -- only touch the list entry when its note actually changed
        if not IsMine() and com ~= (e.note or "") then
            BL:SetNote(kind, e.id, com, Scope())
        end
        d.shownId = nil -- reload the boxes from saved data
        BL:UpdateMainFrame()
    end)
    d.revert:SetScript("OnClick", function()
        d.myBox:ClearFocus()
        d.comBox:ClearFocus()
        d.shownId = nil
        BL:UpdateMainFrame()
    end)
    d.remove:SetScript("OnClick", function()
        local e = CurrentEntry()
        if not e then return end
        local label = EntryLabel(Kind(), e)
        local data = { kind = Kind(), id = e.id, scope = Scope() }
        local p = CurrentProvider()
        local other, otherProvider = BL:OtherList(Kind(), e)
        if other then
            -- on two lists: let the user pick this list only, or both (everything deleted)
            data.otherId = other.id
            data.otherScope = other.mine and "mine" or (otherProvider and otherProvider.id)
            local here, there = ListText(Scope(), true), ListText(data.otherScope, true)
            local extra = (p and p.removeText) or (otherProvider and otherProvider.removeText)
            ShowChoice(
                label .. " is on " .. here .. " and also on " .. there .. ".\n\n"
                .. "|cffffd100Both Lists|r removes it everywhere, including your personal note"
                .. (extra and (" (" .. extra .. ")") or "") .. ".\n\n"
                .. "|cffffd100This List Only|r removes it from " .. here .. " and keeps the other entry "
                .. "and your personal note.",
                {
                    { "Both Lists", function()
                        BL:RemoveBoth(data.kind, data.id, data.scope, data.otherId, data.otherScope)
                    end },
                    { CANCEL },
                    { "This List Only", function() BL:Remove(data.kind, data.id, data.scope) end },
                })
            return
        end
        local text = "Remove " .. label .. " from " .. ListText(Scope()) .. "?"
        if p and p.removeText then text = text .. "\n" .. p.removeText end
        if BL:GetPersonalNote(Kind(), e) then
            text = text .. "\n\nYour personal note on " .. label .. " is deleted too."
        end
        StaticPopup_Show("REDFLAG_CONFIRM_REMOVE", text, nil, data)
    end)
    d.copy:SetScript("OnClick", function()
        local e = CurrentEntry()
        if not e then return end
        if IsMine() then
            local target = d.copyTarget
            if not target then return end
            StaticPopup_Show("REDFLAG_CONFIRM_COPY",
                "Add " .. EntryLabel(Kind(), e) .. " to " .. ListText(target.id) .. "?\n\n"
                .. "It also stays on your personal list. Your personal note is not added.",
                nil, { kind = Kind(), id = e.id, scope = target.id })
        else
            BL:CopyToMine(Kind(), e)
        end
    end)
    d.CurrentEntry = CurrentEntry
end

function BL:UpdateList()
    if not main or not main:IsShown() or not TABS[state.tab] then return end
    local kind, scope = Kind(), Scope()
    local data = self:GetSorted(kind, state.filter, scope)
    state.data = data
    FauxScrollFrame_Update(main.scroll, #data, NUM_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(main.scroll)
    local selected = state.selected[state.tab]

    for i, row in ipairs(rows) do
        local e = data[offset + i]
        if e then
            row.id = e.id
            if kind == "players" then
                local pending = e.guid and "" or " |cffffaa00(?)|r"
                row.name:SetText(BL:FullName(e.name, e.realm) .. pending)
                row.name:SetTextColor(ClassRGB(e.class))
            else
                row.name:SetText("<" .. e.name .. ">")
                row.name:SetTextColor(1, 0.82, 0)
            end
            -- preview: my personal note first (highlighted), else the list note
            local mine = BL:GetPersonalNote(kind, e)
            if mine then
                row.note:SetText("|cffffd100" .. (mine:gsub("\n", "  ") or "") .. "|r")
            else
                row.note:SetText((e.note or ""):gsub("\n", "  ") or "")
            end
            row.sel:SetShown(e.id == selected)
            row:Show()
        else
            row.id = nil
            row:Hide()
        end
    end

    local total = #self:GetEntries(kind, scope)
    if #data == total then
        main.count:SetText(("%d entries"):format(total))
    else
        main.count:SetText(("%d of %d entries"):format(#data, total))
    end
end

function BL:UpdateDetail()
    local d = main.detail
    local e = d.CurrentEntry()
    if not e then
        state.selected[state.tab] = nil
        d.content:Hide()
        d.empty:Show()
        d.shownId = nil
        return
    end
    d.empty:Hide()
    d.content:Show()
    local kind, scope, mine = Kind(), Scope(), IsMine()
    if d.shownScope ~= scope then
        d.Layout(scope)
        d.shownScope = scope
        d.shownId = nil
    end

    local lines = {}
    local other, otherProvider = self:OtherList(kind, e)
    if kind == "players" then
        d.name:SetText(BL:FullName(e.name, e.realm))
        d.name:SetTextColor(ClassRGB(e.class))
        local className = e.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[e.class]
        lines[#lines + 1] = "Realm: |cffffffff" .. e.realm .. "|r" .. (className and ("    Class: |cffffffff" .. className .. "|r") or "")
        if e.guid then
            lines[#lines + 1] = "GUID: |cffaaaaaa" .. e.guid .. "|r"
        else
            lines[#lines + 1] = "|cffffaa00GUID pending - resolves once you see this player.|r"
        end
    else
        d.name:SetText("<" .. e.name .. ">")
        d.name:SetTextColor(1, 0.82, 0)
        lines[#lines + 1] = "Realm: |cffffffff" .. e.realm .. "|r"
    end
    if mine then
        lines[#lines + 1] = "Added on " .. FormatDate(e.added)
        lines[#lines + 1] = "|cffffd100Personal list - only on this account.|r"
        if other then lines[#lines + 1] = "|cff40ff40Also on " .. ListText(otherProvider and otherProvider.id) .. ".|r" end
    else
        lines[#lines + 1] = "Added by |cffffffff" .. (e.by or "?") .. "|r on " .. FormatDate(e.added)
        if e.mod then
            lines[#lines + 1] = "Last change: " .. FormatDate(e.mod) .. (e.ed and (" by |cffffffff" .. e.ed .. "|r") or "")
        end
        if other then lines[#lines + 1] = "|cffffd100Also on your personal list.|r" end
    end
    d.info:SetText(table.concat(lines, "\n"))

    -- top-right button: personal list -> first available other list; other list -> personal
    if mine then
        local target
        for _, p in ipairs(self.providers) do
            if self:ProviderAvailable(p) then target = p break end
        end
        d.copyTarget = target
        d.copy:SetShown(target ~= nil or other ~= nil)
        local caption = target and (target.shareText or ("Add to " .. (target.label or target.id))) or ""
        d.copy:SetEnabled(target ~= nil and not other)
        d.copy:SetText(other and "Added" or caption)
    else
        d.copyTarget = nil
        d.copy:Show()
        d.copy:SetEnabled(not other)
        d.copy:SetText(other and "On Personal List" or "Add to Personal")
    end

    -- don't clobber notes that are being edited when the list changes in the background
    local editing = d.myBox:HasFocus() or d.comBox:HasFocus()
    if d.shownId ~= e.id or not editing then
        d.myBox:SetText(self:GetPersonalNote(kind, e) or "")
        d.myBox:SetCursorPosition(0)
        d.comBox:SetText(mine and "" or (e.note or ""))
        d.comBox:SetCursorPosition(0)
    end
    d.shownId = e.id
    d.UpdateButtons()
end

------------------------------------------------------------------------
-- Settings view
------------------------------------------------------------------------

local function CreateSettingsView(f)
    local sv = CreateFrame("Frame", nil, f)
    sv:SetPoint("TOPLEFT", 14, -62)
    sv:SetPoint("BOTTOMRIGHT", -14, 14)
    f.settingsView = sv

    local function Header(text, x, y)
        local h = Text(sv, "GameFontNormalLarge", "TOPLEFT", x, y)
        h:SetText(text)
        return h
    end

    local function Check(key, label, x, y)
        local cb = CreateFrame("CheckButton", nil, sv, "UICheckButtonTemplate")
        cb:SetSize(26, 26)
        cb:SetPoint("TOPLEFT", x, y)
        local t = Text(cb, "GameFontHighlight", "LEFT", cb, "RIGHT", 2, 1)
        t:SetText(label)
        cb:SetScript("OnClick", function(self)
            BL.db.global.settings[key] = self:GetChecked() and true or false
            BL:UpdateSettings()
        end)
        cb.key = key
        settingsChecks[#settingsChecks + 1] = cb
        return cb
    end

    -- left column
    Header("Warn me when", 0, 0)
    Check("warnWhisper", "a blacklisted player whispers me", 0, -24)
    Check("warnInvite", "a blacklisted player invites me", 0, -50)
    Check("warnGroup", "a blacklisted player is in my group", 0, -76)
    Check("warnOutgoingInvite", "I invite a blacklisted player", 0, -102)

    Header("Warning output", 0, -144)
    Check("useChat", "Chat warning", 0, -168)
    Check("usePopup", "Popup window", 0, -194)
    Check("useSound", "Sound", 0, -220)

    local soundBtn = Button(sv, "", 140, "TOPLEFT", 120, -221)
    soundBtn:SetScript("OnClick", function()
        local s = BL.db.global.settings
        local idx = 1
        for i, snd in ipairs(BL.SOUNDS) do
            if snd.key == s.sound then idx = i end
        end
        s.sound = BL.SOUNDS[idx % #BL.SOUNDS + 1].key
        BL:PlayWarningSound()
        BL:UpdateSettings()
    end)
    f.soundBtn = soundBtn
    local play = Button(sv, "Play", 50, "LEFT", soundBtn, "RIGHT", 4, 0)
    play:SetScript("OnClick", function() BL:PlayWarningSound() end)

    Check("tooltip", "Show Red Flag notes in unit tooltips", 0, -258)

    -- how often the same player may trigger the same warning again
    local repeatLbl = Text(sv, "GameFontHighlight", "TOPLEFT", 4, -292)
    repeatLbl:SetText("Repeat warnings:")
    local repeatBtn = Button(sv, "", 170, "LEFT", repeatLbl, "RIGHT", 8, 0)
    repeatBtn:SetScript("OnClick", function()
        local s = BL.db.global.settings
        local idx = 0
        for i, opt in ipairs(BL.REPEAT_OPTIONS) do
            if opt.value == (s.cooldown or 60) then idx = i end
        end
        s.cooldown = BL.REPEAT_OPTIONS[idx % #BL.REPEAT_OPTIONS + 1].value
        BL:UpdateSettings()
    end)
    f.repeatBtn = repeatBtn

    local notesLbl = Text(sv, "GameFontHighlight", "TOPLEFT", 4, -324)
    notesLbl:SetText("Notes in warnings:")
    local notesBtn = Button(sv, "", 150, "LEFT", notesLbl, "RIGHT", 8, 0)
    notesBtn:SetScript("OnClick", function()
        local s = BL.db.global.settings
        local order = { both = "mine", mine = "community", community = "both" }
        s.noteDisplay = order[s.noteDisplay] or "both"
        BL:UpdateSettings()
    end)
    f.notesBtn = notesBtn
    f.notesLbl = notesLbl

    local test = Button(sv, "Test Warning", 120, "TOPLEFT", 0, -356)
    test:SetScript("OnClick", function() BL:TestWarning() end)

    local cdInfo = Text(sv, "GameFontDisableSmall", "LEFT", test, "RIGHT", 10, 0)
    cdInfo:SetWidth(200)
    cdInfo:SetText("Being in a group with someone warns once per group.")

    -- right column
    local x = 360
    Header("Your data", x, 0)
    local about = Text(sv, "GameFontHighlightSmall", "TOPLEFT", x + 4, -26)
    about:SetWidth(320)
    about:SetSpacing(2)
    about:SetText(
        "Your list and your personal notes are stored only on this computer and are " ..
        "available on all characters of this account.\n\n" ..
        "Red Flag never posts anything in chat and never contacts a flagged player - " ..
        "warnings are only shown to you.\n\n" ..
        "A backup is written every time you log out or reload. /rf restore brings back " ..
        "missing entries from it.")

    -- lists added by other addons (only shown when there are any)
    f.extHeader = Header("Other lists", x, -170)
    f.extRows = {}
    for i = 1, 3 do
        local y = -196 - (i - 1) * 46
        local r = {}
        r.title = Text(sv, "GameFontHighlight", "TOPLEFT", x + 4, y)
        r.status = Text(sv, "GameFontHighlightSmall", "TOPLEFT", x + 4, y - 18)
        r.status:SetWidth(210)
        r.button = Button(sv, "Settings", 100, "TOPLEFT", x + 220, y + 2)
        f.extRows[i] = r
    end
end

function BL:UpdateSettings()
    if not main then return end
    local s = self.db.global.settings
    for _, cb in ipairs(settingsChecks) do
        cb:SetChecked(s[cb.key] and true or false)
    end
    local label = "?"
    for _, snd in ipairs(self.SOUNDS) do
        if snd.key == s.sound then label = snd.label end
    end
    main.soundBtn:SetText(label)
    local repeatLabel = "?"
    for _, opt in ipairs(self.REPEAT_OPTIONS) do
        if opt.value == (s.cooldown or 60) then repeatLabel = opt.label end
    end
    main.repeatBtn:SetText(repeatLabel)

    -- the choice between personal and list notes only matters when other lists exist
    local hasProviders = #self.providers > 0
    main.notesLbl:SetShown(hasProviders)
    main.notesBtn:SetShown(hasProviders)
    local noteLabels = { both = "Personal + list notes", mine = "Personal only", community = "List notes only" }
    main.notesBtn:SetText(noteLabels[s.noteDisplay] or noteLabels.both)

    main.extHeader:SetShown(hasProviders)
    for i, r in ipairs(main.extRows) do
        local p = self.providers[i]
        r.title:SetShown(p ~= nil)
        r.status:SetShown(p ~= nil)
        r.button:SetShown(p ~= nil and type(p.OpenSettings) == "function")
        if p then
            r.title:SetText(p.label or p.id)
            r.status:SetText(Call(p, "StatusText") or "")
            r.button:SetScript("OnClick", function() Call(p, "OpenSettings") end)
        end
    end
end

------------------------------------------------------------------------
-- Main frame
------------------------------------------------------------------------

local function CreateTabs(f)
    f.tabs = f.tabs or {}
    f.tabButtons = f.tabButtons or {}
    wipe(f.tabs)
    for _, b in ipairs(f.tabButtons) do b:Hide() end
    for i, def in ipairs(TAB_ORDER) do
        local b = f.tabButtons[i]
        if not b then
            b = Button(f, "", 100, "TOPLEFT", 12 + (i - 1) * 104, -30)
            f.tabButtons[i] = b
        end
        local key = def[1]
        b:SetText(def[2])
        b:SetScript("OnClick", function() BL:SelectTab(key) end)
        b:Show()
        f.tabs[key] = b
    end
end

-- called when a list provider registers
function BL:RebuildTabs()
    BuildTabs()
    if not TABS[state.tab] and state.tab ~= "settings" then state.tab = TAB_ORDER[1][1] end
    if main then
        CreateTabs(main)
        self:UpdateMainFrame()
    end
end

function BL:CreateMainFrame()
    local f = CreateFrame("Frame", "RedFlagMainFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(720, 480)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "RedFlagMainFrame")
    main = f

    if f.TitleText then
        f.TitleText:SetText("Red Flag")
    else
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
        title:SetText("Red Flag")
    end

    BuildTabs()
    if not TABS[state.tab] then state.tab = TAB_ORDER[1][1] end
    CreateTabs(f)
    CreateListView(f)
    CreateSettingsView(f)
    f:SetScript("OnShow", function() BL:UpdateMainFrame() end)
end

function BL:SelectTab(tab)
    state.tab = tab
    self:UpdateMainFrame()
end

function BL:UpdateMainFrame()
    if not main or not main:IsShown() then return end
    for key, b in pairs(main.tabs) do
        if key == state.tab then b:LockHighlight() else b:UnlockHighlight() end
    end
    if not TABS[state.tab] then
        main.listView:Hide()
        main.settingsView:Show()
        self:UpdateSettings()
        return
    end
    main.settingsView:Hide()
    main.listView:Show()
    main.addTarget:SetText(Kind() == "players" and "Add Target" or "Add Target's Guild")
    local canAdd = true
    if IsMine() then
        main.scopeLabel:SetText("|cffffd100Personal list|r |cff888888- all your characters|r")
    else
        local p = CurrentProvider()
        local ok, reason = self:ProviderAvailable(p)
        canAdd = ok
        local status = Call(p, "StatusText")
        main.scopeLabel:SetText(status or (ok and ("|cff40ff40" .. (p and p.label or "") .. " list|r")
            or ("|cffff8040" .. (reason or "") .. "|r")))
    end
    main.addTarget:SetEnabled(canAdd)
    main.addName:SetEnabled(canAdd)
    self:UpdateDetail()
    self:UpdateList()
end

function BL:ShowMainFrame(tab, id)
    if not main then self:CreateMainFrame() end
    if tab then state.tab = tab end
    if not TABS[state.tab] and state.tab ~= "settings" then state.tab = TAB_ORDER[1][1] end
    if id and TABS[state.tab] then state.selected[state.tab] = id end
    if main:IsShown() then
        self:UpdateMainFrame()
    else
        main:Show()
    end
end

function BL:ToggleMainFrame()
    if main and main:IsShown() then
        main:Hide()
    else
        self:ShowMainFrame()
    end
end
