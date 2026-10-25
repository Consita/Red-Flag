local ADDON_NAME, ns = ...

local BL = LibStub("AceAddon-3.0"):NewAddon(
    "RedFlag",
    "AceEvent-3.0",
    "AceConsole-3.0"
)
ns.BL = BL

BL.MAX_NOTE = 500

-- No player or guild names ship with the addon: all data lives in SavedVariables only.
--   mine      my personal list, account-wide
--   personal  my personal notes (one per player/guild), account-wide
-- Red Flag never sends or receives any data. Other addons can show additional lists through
-- the list provider interface at the end of this file.
-- Older versions kept more lists in this database (guildLists, characters); that data is
-- left untouched here for the addon that took it over.
local defaults = {
    global = {
        personal = { players = {}, guilds = {} }, -- [kind][id] = note
        mine = { players = {}, guilds = {} },     -- personal list, [kind][id] = entry
        settings = {
            noteDisplay = "both", -- notes in warnings/tooltips: "both" | "mine" | "community"
            warnWhisper = true,
            warnInvite = true,
            warnGroup = true,
            warnOutgoingInvite = true,
            useSound = true,
            useChat = true,
            usePopup = true,
            sound = "ding",
            tooltip = true,
            cooldown = 60,
        },
    },
}

BL.CHAT_PREFIX = "|cffff4040[Red Flag]|r "

function BL:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(self.CHAT_PREFIX .. tostring(msg))
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

function BL:Now()
    return GetServerTime and GetServerTime() or time()
end

function BL:MyRealm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if not r or r == "" then
        r = (GetRealmName() or ""):gsub("[%s%-]", "")
    end
    return r
end

-- realm names as used in "Name-Realm": no spaces
function BL:NormRealm(r)
    if not r or r == "" then return self:MyRealm() end
    return (r:gsub("%s", ""))
end

-- "Name-Realm" / "Name" -> "Name", "Realm"
function BL:SplitName(full, realm)
    if not full then return nil end
    local name, r = strsplit("-", full, 2)
    r = self:NormRealm((r and r ~= "") and r or realm)
    name = name and name:gsub("^%s+", ""):gsub("%s+$", "")
    if name and name ~= "" then
        -- normalize capitalisation (UTF-8 safe: only touches first byte if ASCII)
        name = name:sub(1, 1):upper() .. name:sub(2):lower()
    end
    return name, r
end

function BL:FullName(name, realm)
    if not realm or realm == self:MyRealm() then return name end
    return name .. "-" .. realm
end

function BL:NameKey(name, realm)
    return "N:" .. (name .. "-" .. realm):lower()
end

function BL:GuildKey(name, realm)
    return "G:" .. (name .. "-" .. realm):lower()
end

function BL:IsValidGUID(guid)
    return type(guid) == "string" and guid:match("^Player%-%d+%-%x+$") ~= nil
end

-- Collect identity of a player unit
function BL:InfoFromUnit(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local guid = UnitGUID(unit)
    local name, realm = UnitName(unit)
    if not name or name == UNKNOWNOBJECT then return nil end
    local _, class = UnitClass(unit)
    return {
        guid = self:IsValidGUID(guid) and guid or nil,
        name = name,
        realm = self:NormRealm(realm),
        class = class,
    }
end

function BL:InfoFromGUID(guid)
    if not self:IsValidGUID(guid) then return nil end
    local _, class, _, _, _, name, realm = GetPlayerInfoByGUID(guid)
    if not name or name == "" then return nil end
    return {
        guid = guid,
        name = name,
        realm = self:NormRealm(realm),
        class = class,
    }
end

------------------------------------------------------------------------
-- Lists
--   "mine":        my personal list (db.global.mine), always available
--   provider id:   a list shown on behalf of another addon (see the interface below)
-- Personal-list entries carry mine = true so lookups and the UI can tell them apart.
------------------------------------------------------------------------

BL.providers = {} -- registered list providers, in registration order

function BL:Provider(id)
    for _, p in ipairs(self.providers) do
        if p.id == id then return p end
    end
end

-- Calls a provider method; a broken provider must never break Red Flag itself.
local function Call(p, method, ...)
    local f = p and p[method]
    if type(f) ~= "function" then return nil end
    local ok, a, b = pcall(f, p, ...)
    if ok then return a, b end
    geterrorhandler()(a)
    return nil
end
BL.CallProvider = Call

-- true, or false + reason
function BL:ProviderAvailable(p)
    if not p then return false, "This list is not available." end
    local ok, reason = Call(p, "IsAvailable")
    if ok then return true end
    return false, reason or "This list is not available right now."
end

-- which provider an entry belongs to (nil for personal-list and unknown entries)
function BL:ProviderOfEntry(kind, e)
    if not e or e.mine or not e.id then return nil end
    for _, p in ipairs(self.providers) do
        if Call(p, "Get", kind, e.id) == e then return p end
    end
end

local function FindMinePlayer(self, guid, nameKey)
    local t = self.db.global.mine.players
    if guid and t[guid] then return t[guid] end
    if nameKey and t[nameKey] then return t[nameKey] end
end

-- scope: nil = every list (provider lists first), "mine", or a provider id.
-- Returns the entry and, for provider lists, the provider.
function BL:FindPlayer(guid, name, realm, scope)
    local n, r
    if name then n, r = self:SplitName(name, realm) end
    if scope ~= "mine" then
        for _, p in ipairs(self.providers) do
            if scope == nil or scope == p.id then
                local e = Call(p, "Find", "players", guid, n, r)
                if e then return e, p end
            end
        end
    end
    if scope == nil or scope == "mine" then
        return FindMinePlayer(self, guid, n and self:NameKey(n, r))
    end
end

-- Name-only match against every entry (used when only a name is known, e.g. InviteUnit)
function BL:FindPlayerByName(name, realm, scope)
    local n, r = self:SplitName(name, realm)
    if not n then return nil end
    if scope ~= "mine" then
        for _, p in ipairs(self.providers) do
            if scope == nil or scope == p.id then
                local e = Call(p, "Find", "players", nil, n, r)
                if e then return e, p end
            end
        end
    end
    if scope == nil or scope == "mine" then
        local ln, lr = n:lower(), r:lower()
        for _, e in pairs(self.db.global.mine.players) do
            if e.name:lower() == ln and (e.realm or ""):lower() == lr then return e end
        end
    end
end

function BL:FindGuild(name, realm, scope)
    if not name or name == "" then return nil end
    realm = self:NormRealm(realm)
    if scope ~= "mine" then
        for _, p in ipairs(self.providers) do
            if scope == nil or scope == p.id then
                local e = Call(p, "Find", "guilds", nil, name, realm)
                if e then return e, p end
            end
        end
    end
    if scope == nil or scope == "mine" then
        return self.db.global.mine.guilds[self:GuildKey(name, realm)]
    end
end

function BL:GetEntry(kind, scope, id)
    if not id then return nil end
    if scope == "mine" then return self.db.global.mine[kind][id] end
    return Call(self:Provider(scope), "Get", kind, id)
end

-- all entries of one list, as an array
function BL:GetEntries(kind, scope)
    if scope == "mine" then
        local out = {}
        for _, e in pairs(self.db.global.mine[kind]) do out[#out + 1] = e end
        return out
    end
    local p = self:Provider(scope)
    if not p or not self:ProviderAvailable(p) then return {} end
    local t = Call(p, "Iterate", kind)
    return type(t) == "table" and t or {}
end

-- The same player/guild on the other side ("mine" <-> provider lists), or nil.
-- Matches by GUID or name, since one list may know the GUID and the other only the name.
function BL:OtherList(kind, e)
    if not e then return nil end
    if e.mine then
        for _, p in ipairs(self.providers) do
            local o = Call(p, "Find", kind, e.guid, e.name, e.realm)
            if o then return o, p end
        end
        return nil
    end
    if kind == "players" then
        return self:FindPlayer(e.guid, e.name, e.realm, "mine")
    end
    return self:FindGuild(e.name, e.realm, "mine")
end

function BL:GetSorted(kind, filter, scope)
    local list = {}
    filter = filter and filter ~= "" and filter:lower() or nil
    for _, e in ipairs(self:GetEntries(kind, scope)) do
        if not filter
            or e.name:lower():find(filter, 1, true)
            or (not e.mine and (e.note or ""):lower():find(filter, 1, true))
            or (self:GetPersonalNote(kind, e) or ""):lower():find(filter, 1, true) then
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

------------------------------------------------------------------------
-- Personal notes: ONE per player/guild, shared by all lists, only stored locally.
-- Stored in db.global.personal[kind][id] (id = GUID when known, else the name key).
------------------------------------------------------------------------

-- every key the note of this entry may be stored under
local function NoteKeys(self, kind, e)
    if type(e) ~= "table" then return { e } end
    local keys = {}
    local function add(k)
        if not k then return end
        for _, x in ipairs(keys) do if x == k then return end end
        keys[#keys + 1] = k
    end
    add(e.id)
    if kind == "players" then
        add(e.guid)
        if e.name and e.realm then add(self:NameKey(e.name, e.realm)) end
    end
    local other = e.name and self:OtherList(kind, e)
    if other then add(other.id) end
    return keys
end

-- e: an entry (preferred) or an id
function BL:GetPersonalNote(kind, e)
    local store = self.db.global.personal[kind]
    for _, k in ipairs(NoteKeys(self, kind, e)) do
        local n = store[k]
        if n and n ~= "" then return n end
    end
    return nil
end

function BL:SetPersonalNote(kind, e, note)
    local store = self.db.global.personal[kind]
    for _, k in ipairs(NoteKeys(self, kind, e)) do store[k] = nil end
    local id = type(e) == "table" and (e.guid or e.id) or e
    note = note and note:sub(1, self.MAX_NOTE) or ""
    if note ~= "" then store[id] = note end
    self:RefreshUI()
end

-- delete the personal note of a player/guild that is on no list anymore
function BL:ForgetPersonalNote(kind, e)
    if not e then return end
    if kind == "players" then
        if self:FindPlayer(e.guid, e.name, e.realm) then return end
    elseif self:FindGuild(e.name, e.realm) then
        return
    end
    local store = self.db.global.personal[kind]
    if e.id then store[e.id] = nil end
    if e.guid then store[e.guid] = nil end
    if kind == "players" and e.name and e.realm then store[self:NameKey(e.name, e.realm)] = nil end
end

-- Notes to show in warnings/tooltips, honouring the noteDisplay setting.
-- Returns a list of { label, text }.
function BL:DisplayNotes(kind, e)
    local mode = self.db.global.settings.noteDisplay
    local out = {}
    if mode ~= "community" then
        local mine = e.myNote or self:GetPersonalNote(kind, e)
        if mine then out[#out + 1] = { "Personal", mine } end
    end
    -- list notes only exist on lists added by other addons
    if #self.providers > 0 and not e.mine and mode ~= "mine" and e.note and e.note ~= "" then
        local p = self:ProviderOfEntry(kind, e)
        out[#out + 1] = { (p and p.noteName) or "List note", e.note }
    end
    return out
end

------------------------------------------------------------------------
-- Personal list: plain local storage.
-- Its entries have no note of their own; they use the personal note above.
------------------------------------------------------------------------

function BL:SaveMine(kind, entry)
    entry.mine = true
    entry.note = ""
    self.db.global.mine[kind][entry.id] = entry
    self:RefreshUI()
end

-- A provider dropped an entry I have a personal note on: keep the player/guild on my
-- personal list so the note (and the warnings) aren't lost.
function BL:KeepAsPersonal(kind, e, by, listLabel)
    if not e or not e.name then return end
    if kind == "players" and self:FindPlayer(e.guid, e.name, e.realm, "mine") then return end
    if kind == "guilds" and self:FindGuild(e.name, e.realm, "mine") then return end
    self:SaveMine(kind, {
        id = e.guid or e.id, guid = e.guid, name = e.name, realm = e.realm, class = e.class,
        by = e.by, added = e.added, mod = self:Now(),
    })
    local label = kind == "guilds" and ("<" .. e.name .. ">") or self:FullName(e.name, e.realm)
    self:Print(("%s was removed from the %s list%s. It is kept on your personal list because you have a personal note on it.")
        :format(label, listLabel or "other", by and (" by " .. by) or ""))
end

------------------------------------------------------------------------
-- Adding / editing / removing
------------------------------------------------------------------------

-- add to a list: "mine" (default) or a provider id
local function AddEntry(self, kind, e, scope)
    if scope == nil or scope == "mine" then
        self:SaveMine(kind, e)
        return e
    end
    local p = self:Provider(scope)
    local ok, reason = self:ProviderAvailable(p)
    if not ok then return nil, reason end
    local added = Call(p, "Add", kind, e)
    if not added then return nil, "Could not add the entry." end
    self:RefreshUI()
    return added
end

-- note = the list note for provider lists (ignored for "mine")
function BL:AddPlayer(info, note, scope)
    if not info or not info.name then return nil, "No player given." end
    local n, r = self:SplitName(info.name, info.realm)
    local existing = self:FindPlayer(info.guid, n, r, scope or "mine")
    if existing then return existing, "already" end
    local now = self:Now()
    return AddEntry(self, "players", {
        id = info.guid or self:NameKey(n, r),
        guid = info.guid,
        name = n,
        realm = r,
        class = info.class,
        note = (note or ""):sub(1, self.MAX_NOTE),
        by = UnitName("player"),
        added = now,
        mod = now,
    }, scope)
end

function BL:AddGuild(name, realm, note, scope)
    if not name or name == "" then return nil, "No guild given." end
    realm = self:NormRealm(realm)
    local existing = self:FindGuild(name, realm, scope or "mine")
    if existing then return existing, "already" end
    local now = self:Now()
    return AddEntry(self, "guilds", {
        id = self:GuildKey(name, realm),
        name = name,
        realm = realm,
        note = (note or ""):sub(1, self.MAX_NOTE),
        by = UnitName("player"),
        added = now,
        mod = now,
    }, scope)
end

-- list note of a provider entry
function BL:SetNote(kind, id, note, scope)
    Call(self:Provider(scope), "SetNote", kind, id, (note or ""):sub(1, self.MAX_NOTE))
    self:RefreshUI()
end

-- The personal note is deleted only when the entry leaves my last list.
function BL:Remove(kind, id, scope)
    local e = self:GetEntry(kind, scope, id)
    if not e then return end
    if scope == "mine" then
        self.db.global.mine[kind][id] = nil
    else
        Call(self:Provider(scope), "Remove", kind, id)
    end
    self:ForgetPersonalNote(kind, e)
    self:RefreshUI()
end

-- Copy a personal-list entry to a provider list; it also stays on my personal list.
-- The personal note stays local; the new entry starts with an empty list note.
function BL:ShareMine(kind, id, scope)
    local m = self.db.global.mine[kind][id]
    if not m then return end
    if kind == "players" then
        return self:AddPlayer({ guid = m.guid, name = m.name, realm = m.realm, class = m.class }, "", scope)
    end
    return self:AddGuild(m.name, m.realm, "", scope)
end

-- Copy a provider entry to my personal list (works across all my characters).
function BL:CopyToMine(kind, e)
    if not e then return end
    if kind == "players" then
        return self:AddPlayer({ guid = e.guid, name = e.name, realm = e.realm, class = e.class }, nil, "mine")
    end
    return self:AddGuild(e.name, e.realm, nil, "mine")
end

-- Personal-list part of ObservePlayer: GUID fill-in / rename tracking.
local function ObserveMine(self, info, n, r, nameKey)
    local mine = self.db.global.mine.players
    local byName, byGuid = mine[nameKey], mine[info.guid]
    if byName then
        if not byGuid then
            byName.id, byName.guid = info.guid, info.guid
            byName.class = info.class or byName.class
            mine[info.guid] = byName
        end
        mine[nameKey] = nil
        self:RefreshUI()
    elseif byGuid and (byGuid.name ~= n or byGuid.realm ~= r or (info.class and byGuid.class ~= info.class)) then
        if byGuid.name ~= n then
            self:Print(("%s (personal list) is now named %s."):format(byGuid.name, n))
        end
        byGuid.name, byGuid.realm, byGuid.class = n, r, info.class or byGuid.class
        self:RefreshUI()
    end
end

-- Called whenever we see a player with a GUID. Fills in GUIDs for entries that were
-- added by name only, and tracks renames of GUID-based entries.
function BL:ObservePlayer(info)
    if not info or not info.guid or not info.name then return end
    local n, r = self:SplitName(info.name, info.realm)
    local nameKey = self:NameKey(n, r)

    -- personal note stored under the name moves to the GUID
    local personal = self.db.global.personal.players
    local oldNote, newNote = personal[nameKey], personal[info.guid]
    if oldNote then
        personal[info.guid] = (newNote and newNote ~= oldNote)
            and (newNote .. "\n" .. oldNote):sub(1, self.MAX_NOTE) or oldNote
        personal[nameKey] = nil
    end

    ObserveMine(self, info, n, r, nameKey)

    local seen = { guid = info.guid, name = n, realm = r, class = info.class }
    for _, p in ipairs(self.providers) do
        Call(p, "PlayerSeen", seen)
    end
end

function BL:RefreshUI()
    if self.UpdateMainFrame then self:UpdateMainFrame() end
end

------------------------------------------------------------------------
-- Data safety
--   * RedFlagDB (account-wide) is the real data. Its name must never change again:
--     WoW stores it in WTF\...\SavedVariables\RedFlag.lua under exactly this name.
--   * RedFlagBackupDB (per character, a separate file) holds a copy taken at every logout
--     and reload. If RedFlagDB ever loads empty while a backup has entries (unreadable
--     file, failed update, ...), the backup is restored automatically.
--   * Updates only ever add fields through numbered migrations; nothing is reset.
------------------------------------------------------------------------

BL.SCHEMA = 3

local MIGRATIONS = {
    -- [n] = function(global) ... end  -- upgrades data from schema n-1 to n; never deletes entries
    [1] = function(g)
        local s = g.settings
        if s and s.minRank ~= nil then -- old single "trusted ranks" setting
            s.shareRank, s.acceptRank, s.minRank = s.minRank, s.minRank, nil
        end
    end,
    -- one personal note per player/guild for both lists
    [2] = function(g)
        for _, kind in ipairs({ "players", "guilds" }) do
            local store = g.personal and g.personal[kind]
            local mine = g.mine and g.mine[kind]
            local com = g[kind]
            if type(store) == "table" and type(mine) == "table" then
                -- personal-list notes move into the shared personal note
                for id, m in pairs(mine) do
                    if type(m) == "table" then
                        if m.note and m.note ~= "" then
                            local cur = store[id]
                            store[id] = (cur and cur ~= "" and cur ~= m.note)
                                and (cur .. "\n" .. m.note):sub(1, BL.MAX_NOTE) or m.note
                        end
                        m.note = ""
                    end
                end
                -- removed entries that were only kept because of my note go to the personal list
                if type(com) == "table" then
                    for id, e in pairs(com) do
                        if type(e) == "table" and e.del and store[id] and store[id] ~= "" and not mine[id] then
                            mine[id] = {
                                id = id, guid = e.guid, name = e.name, realm = e.realm, class = e.class,
                                note = "", by = e.by, added = e.added, mod = e.mod, mine = true,
                            }
                        end
                    end
                end
            end
        end
    end,
    -- older data layout: the single shared list becomes guildLists[guild] (kept for the
    -- addon that took those lists over)
    [3] = function(g)
        if type(g.guildLists) ~= "table" then g.guildLists = {} end
        local s = type(g.settings) == "table" and g.settings or {}
        local hasData = (type(g.players) == "table" and next(g.players) ~= nil)
            or (type(g.guilds) == "table" and next(g.guilds) ~= nil)
        if hasData or s.syncGuild then
            local key = s.syncGuild or "?"
            local d = g.guildLists[key] or { players = {}, guilds = {} }
            for _, kind in ipairs({ "players", "guilds" }) do
                d[kind] = d[kind] or {}
                for id, e in pairs(type(g[kind]) == "table" and g[kind] or {}) do
                    if d[kind][id] == nil then d[kind][id] = e end
                end
            end
            if d.shareRank == nil then d.shareRank = s.shareRank end
            if d.acceptRank == nil then d.acceptRank = s.acceptRank end
            d.lastSync = d.lastSync or s.lastSync
            g.guildLists[key] = d
        end
        g.players, g.guilds = nil, nil
        s.syncGuild, s.shareRank, s.acceptRank, s.lastSync = nil, nil, nil, nil
    end,
}

-- bring a data table (live data or a backup copy) up to the current schema
local function Upgrade(g)
    local schema = g.schema or 0
    for v = schema + 1, BL.SCHEMA do
        if MIGRATIONS[v] then MIGRATIONS[v](g) end
    end
    g.schema = math.max(schema, BL.SCHEMA)
end

local function CountEntries(g)
    if type(g) ~= "table" then return 0 end
    local tables = { g.players, g.guilds } -- older layouts
    local mine = type(g.mine) == "table" and g.mine or {}
    tables[#tables + 1] = mine.players
    tables[#tables + 1] = mine.guilds
    for _, d in pairs(type(g.guildLists) == "table" and g.guildLists or {}) do
        if type(d) == "table" then
            tables[#tables + 1] = d.players
            tables[#tables + 1] = d.guilds
        end
    end
    local n = 0
    for _, t in pairs(tables) do
        if type(t) == "table" then
            for _ in pairs(t) do n = n + 1 end
        end
    end
    return n
end

-- runs before AceDB touches RedFlagDB
local function RestoreFromBackupIfEmpty()
    local main = type(RedFlagDB) == "table" and RedFlagDB.global or nil
    local backup = type(RedFlagBackupDB) == "table" and RedFlagBackupDB.global or nil
    if CountEntries(main) > 0 or CountEntries(backup) == 0 then return nil end
    if type(RedFlagDB) ~= "table" then RedFlagDB = {} end
    RedFlagDB.global = CopyTable(backup)
    return RedFlagBackupDB.saved or 0
end

-- Adds personal-list entries and personal notes from the backup that are missing in the
-- live data (never overwrites).
function BL:MergeBackup()
    local backup = type(RedFlagBackupDB) == "table" and RedFlagBackupDB.global or nil
    if CountEntries(backup) == 0 then
        self:Print("No backup available on this character.")
        return
    end
    local added = 0
    local function merge(src, dst)
        if type(src) ~= "table" then return end
        for id, e in pairs(src) do
            if dst[id] == nil then
                dst[id] = CopyTable(e)
                added = added + 1
            end
        end
    end
    local g = self.db.global
    backup = CopyTable(backup)
    Upgrade(backup) -- older backups use older layouts
    if type(backup.mine) == "table" then
        merge(backup.mine.players, g.mine.players)
        merge(backup.mine.guilds, g.mine.guilds)
    end
    if type(backup.personal) == "table" then
        for _, kind in ipairs({ "players", "guilds" }) do
            for id, note in pairs(backup.personal[kind] or {}) do
                if g.personal[kind][id] == nil then g.personal[kind][id] = note end
            end
        end
    end
    self:Print(("Restored %d entr%s from the backup."):format(added, added == 1 and "y" or "ies"))
    self:RefreshUI()
end

function BL:WriteBackup()
    if CountEntries(self.db.global) == 0 then return end -- never replace a good backup with nothing
    RedFlagBackupDB = { saved = time(), global = CopyTable(self.db.global) }
end

------------------------------------------------------------------------
-- Lifecycle / slash
------------------------------------------------------------------------

function BL:OnInitialize()
    local restoredFrom = RestoreFromBackupIfEmpty()
    self.db = LibStub("AceDB-3.0"):New("RedFlagDB", defaults, true)
    Upgrade(self.db.global)
    self:RegisterChatCommand("rf", "SlashCommand")
    self:RegisterChatCommand("redflag", "SlashCommand")
    self.restoredFrom = restoredFrom
end

function BL:OnEnable()
    self:SetupWarnings()
    self:RegisterEvent("PLAYER_LOGOUT", "WriteBackup") -- also fires on /reload
    if self.restoredFrom then
        self:Print(("|cffffd100Your list could not be loaded, so it was restored from the backup of %s.|r")
            :format(date("%Y-%m-%d %H:%M", self.restoredFrom)))
    end
end

local HELP = {
    "/rf - open the Red Flag window",
    "/rf add [Name[-Realm]] - add a player to your list (no name = your target)",
    "/rf addguild [Guild Name] - add a guild to your list (no name = your target's guild)",
    "/rf remove Name[-Realm] - remove a player from your list",
    "/rf test - show a test warning",
    "/rf restore - add back entries from this character's backup (never overwrites)",
    "/rf settings - open the settings",
}

local function ListName(scope)
    local p = scope and scope ~= "mine" and BL:Provider(scope)
    if p then return "the " .. (p.label or p.id) .. " list" end
    return "your personal list"
end

function BL:AddTargetOrName(arg, scope)
    local info
    if arg and arg ~= "" then
        if UnitExists(arg) then
            info = self:InfoFromUnit(arg)
        else
            local n, r = self:SplitName(arg)
            info = { name = n, realm = r }
        end
    else
        info = self:InfoFromUnit("target")
        if not info then
            self:Print("Target a player or give a name.")
            return
        end
    end
    local e, err = self:AddPlayer(info, nil, scope)
    if err == "already" then
        self:Print(e.name .. " is already on " .. ListName(scope) .. ".")
    elseif e then
        self:Print(("Added %s to %s%s."):format(e.name, ListName(scope), e.guid and "" or " (GUID pending until seen)"))
    else
        self:Print(err)
    end
    return e
end

function BL:AddGuildOrTarget(arg, scope)
    local name, realm
    if arg and arg ~= "" then
        name = arg
    else
        local gName, _, _, gRealm = GetGuildInfo("target")
        if not gName then
            self:Print("Target a guilded player or give a guild name.")
            return
        end
        name, realm = gName, gRealm
    end
    local e, err = self:AddGuild(name, realm, nil, scope)
    if err == "already" then
        self:Print("<" .. e.name .. "> is already on " .. ListName(scope) .. ".")
    elseif e then
        self:Print("Added guild <" .. e.name .. "> to " .. ListName(scope) .. ".")
    else
        self:Print(err)
    end
    return e
end

function BL:SlashCommand(input)
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "show" then
        self:ToggleMainFrame()
    elseif cmd == "add" or cmd == "my" then
        local e = self:AddTargetOrName(rest, "mine")
        if e then self:ShowMainFrame("myplayers", e.id) end
    elseif cmd == "addguild" or cmd == "myguild" then
        local e = self:AddGuildOrTarget(rest, "mine")
        if e then self:ShowMainFrame("myguilds", e.id) end
    elseif cmd == "remove" and rest ~= "" then
        local e = self:FindPlayerByName(rest, nil, "mine")
        if e then
            self:Remove("players", e.id, "mine")
            self:Print("Removed " .. e.name .. " from your personal list.")
        else
            self:Print("Not on your personal list: " .. rest)
        end
    elseif cmd == "restore" then
        self:MergeBackup()
    elseif cmd == "test" then
        self:TestWarning()
    elseif cmd == "config" or cmd == "settings" then
        self:ShowMainFrame("settings")
    else
        for _, line in ipairs(HELP) do self:Print(line) end
    end
end

------------------------------------------------------------------------
-- List provider interface (RedFlagAPI)
--
-- Lets another addon show an additional list in the Red Flag window, with the same
-- warnings, tooltips and notes as the personal list. This interface is kept stable:
-- providers written for version 1 keep working with every later Red Flag release.
--
-- A provider is a table:
--   id         unique string                      label     e.g. "Guild" (used in texts)
--   tabs       { players = "...", guilds = "..." } tab captions (optional)
--   noteName   label of its entry note (e.g. "Community")         (optional)
--   noteLabel  caption of its note box                             (optional)
--   shareText  caption of the "copy to this list" button          (optional)
--   removeText extra line in the remove confirmation               (optional)
-- and methods (kind = "players" | "guilds"; entries are tables with at least
-- id, name, realm and optionally guid, class, note, by, added, mod, ed):
--   :IsAvailable()                -> true | false, reason
--   :StatusText()                 -> header text for its tabs      (optional)
--   :Iterate(kind)                -> array of its entries
--   :Get(kind, id)                -> entry or nil
--   :Find(kind, guid, name, realm)-> entry or nil (by GUID, else by name + realm)
--   :Add(kind, entry)             -> the stored entry or nil
--   :SetNote(kind, id, note)
--   :Remove(kind, id)
--   :PlayerSeen(info)             a player with a GUID was seen     (optional)
--   :OpenSettings()               shows its settings               (optional)
------------------------------------------------------------------------

RedFlagAPI = {
    version = 1,
    MAX_NOTE = BL.MAX_NOTE,

    RegisterListProvider = function(p)
        if type(p) ~= "table" or type(p.id) ~= "string" or p.id == "mine" or BL:Provider(p.id) then
            return false
        end
        BL.providers[#BL.providers + 1] = p
        if BL.RebuildTabs then BL:RebuildTabs() end
        return true
    end,

    -- the provider's data changed (e.g. from elsewhere): redraw
    Refresh = function() BL:RefreshUI() end,

    Print = function(msg) BL:Print(msg) end,

    HasPersonalNote = function(kind, e) return BL:GetPersonalNote(kind, e) ~= nil end,

    -- the provider dropped an entry; keep it on the personal list if I have a note on it
    KeepAsPersonal = function(kind, e, by, listLabel) BL:KeepAsPersonal(kind, e, by, listLabel) end,

    -- delete the personal note of a player/guild that is on no list anymore
    ForgetPersonalNote = function(kind, e) BL:ForgetPersonalNote(kind, e) end,

    -- old data of lists that were kept in Red Flag's own database before (read-only use)
    LegacyData = function()
        local g = BL.db and BL.db.global
        return g and g.guildLists, g and g.characters
    end,

    ShowList = function(providerId, kind) BL:ShowMainFrame(providerId .. ":" .. (kind or "players")) end,
}
