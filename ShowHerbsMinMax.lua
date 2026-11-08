-- ShowHerbsMinMax: small icon above the nearest herb, ore or skinnable corpse.
-- The game's interact targeting ("softinteract") picks the nearest interactable object. Its own
-- soft target icon is only switched on while that object is a herb / ore (or a skinnable corpse),
-- so nothing else gets an icon. The player's settings are restored when everything is switched off.

-- game object entry IDs (part of the GUID); works in every client language
local HERB_IDS = {
    1617, 1618, 1619, 1620, 1621, 1622, 1623, 1624, 1628, 2041, 2042, 2043, 2044, 2045, 2046, 2866,
    3724, 3725, 3726, 3727, 3729, 3730,
    142140, 142141, 142142, 142143, 142144, 142145, 176583, 176584, 176586, 176587, 176588, 176589,
}
local MINE_IDS = {
    324, 1731, 1732, 1733, 1734, 1735, 2040, 2047, 3763, 3764, 73940, 73941,
    103711, 103713, 123309, 123310, 165658, 175404, 177388,
}
local KIND = {}   -- object entry ID -> "herb" | "mine"
for _, id in ipairs(HERB_IDS) do KIND[id] = "herb" end
for _, id in ipairs(MINE_IDS) do KIND[id] = "mine" end

-- gathering spells (any rank, compared by localized name): learn object IDs not in the lists
local HERB_SPELL_IDS = { 2366, 2368, 3570, 11993 }
local MINE_SPELL_IDS = { 2575, 2576, 3564, 10248 }

local SKIN_ICON = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01"   -- own icon on a corpse nameplate
local ICON_MIN, ICON_MAX, ICON_STEP = 10, 100, 10              -- icon size slider (percent)

-- game settings that size the soft target icon; scaled from their normal value by the slider
local SIZE_CVARS = {
    { name = "SoftTargetNameplateSize", integer = true },
    { name = "SoftTargetWorldtextSize", integer = true },   -- only takes whole numbers
    { name = "SoftTargetWorldtextNearScale" },
}

-- game settings while icons are on
local LIVE_CVARS = {
    SoftTargetInteract = "3",          -- interact targeting always active
    SoftTargetInteractArc = "2",       -- all around you
    SoftTargetInteractRange = "60",    -- the game clamps this to its maximum
    SoftTargetNameplateInteract = "1", -- nameplate on targeted units (corpses)
    SoftTargetIconGameObject = "0",    -- switched per target in SetGameIcon
    SoftTargetIconInteract = "0",
    graphicsOutlineMode = "2",         -- object outlines; the soft target icon may need them
}

local DEFAULTS = {
    showHerbs = true,
    showMines = true,
    showSkin = true,
    iconScale = 100,
    sizeBase = {},     -- sizeBase[cvar] = the game's value before scaling
    learnedIDs = {},   -- learnedIDs[object entry ID] = "herb" | "mine"
    savedCVars = nil,  -- the player's own values, restored when everything is switched off
    minimapAngle = 200,
}

local db
local function Print(...) print("|cff40ff40ShowHerbsMinMax:|r", ...) end

-- ===== Helpers =====
local function Clean(v)   -- drop "secret" values this client may return
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function SpellName(id)
    if not id or not Clean(id) then return nil end
    local getName = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
    local ok, name = pcall(getName, id)
    return ok and type(name) == "string" and name or nil
end

local gatherSpells = {}   -- localized spell name -> kind
local function RegisterSpells()
    for _, id in ipairs(HERB_SPELL_IDS) do local n = SpellName(id); if n then gatherSpells[n] = "herb" end end
    for _, id in ipairs(MINE_SPELL_IDS) do local n = SpellName(id); if n then gatherSpells[n] = "mine" end end
end

local function InitDB()
    ShowHerbsMinMaxDB = ShowHerbsMinMaxDB or {}
    db = ShowHerbsMinMaxDB
    if db.showIcons == false then   -- older versions: one main switch
        db.showHerbs, db.showMines, db.showSkin = false, false, false
    end
    db.showIcons, db.types, db.learned = nil, nil, nil
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = type(v) == "table" and {} or v end
    end
    db.iconScale = math.max(ICON_MIN, math.min(ICON_MAX, tonumber(db.iconScale) or 100))
end

local function AnyOn() return db.showHerbs or db.showMines or db.showSkin end

local function ObjectEntry(guid)
    if type(guid) ~= "string" then return nil end
    local unitType, _, _, _, _, id = strsplit("-", guid)
    if unitType ~= "GameObject" then return nil end
    return tonumber(id)
end

-- soft target GUID (herbs / ore are game objects: UnitExists is false, the GUID still works)
local softGUID   -- from PLAYER_SOFT_INTERACT_CHANGED, fallback
local function SoftGUID()
    local ok, guid = pcall(UnitGUID, "softinteract")
    guid = ok and Clean(guid) or nil
    return type(guid) == "string" and guid or softGUID
end

-- "herb" / "mine" or nil
local function NodeKind(guid)
    local entry = ObjectEntry(guid)
    return entry and (KIND[entry] or db.learnedIDs[entry])
end

-- ===== Skinnable corpses: dead soft target with the "Skinnable" tooltip line =====
local scanTip
local function TooltipHas(unit, needle)
    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
        if ok and type(data) == "table" and data.lines then
            for _, l in ipairs(data.lines) do
                local t = Clean(l.leftText)
                if type(t) == "string" and t:find(needle, 1, true) then return true end
            end
            return false
        end
    end
    scanTip = scanTip or CreateFrame("GameTooltip", "ShowHerbsMinMaxScanTip", nil, "GameTooltipTemplate")
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    pcall(scanTip.SetUnit, scanTip, unit)
    local found = false
    for i = 1, scanTip:NumLines() do
        local fs = _G["ShowHerbsMinMaxScanTipTextLeft" .. i]
        local t = fs and Clean(fs:GetText())
        if type(t) == "string" and t:find(needle, 1, true) then found = true; break end
    end
    scanTip:Hide()
    return found
end

local skinCache = {}   -- tooltip read at most every 0.5 s per corpse
local function IsSkinnable(guid)
    if not db.showSkin or type(guid) ~= "string" then return false end
    local okE, exists = pcall(UnitExists, "softinteract")
    local okD, dead = pcall(UnitIsDead, "softinteract")
    if not (okE and Clean(exists)) or not (okD and Clean(dead)) then return false end
    local now = GetTime()
    if skinCache.guid ~= guid or now - skinCache.t >= 0.5 then
        skinCache.guid, skinCache.t = guid, now
        skinCache.result = TooltipHas("softinteract", UNIT_SKINNABLE_LEATHER or "Skinnable")
    end
    return skinCache.result
end

-- ===== Game settings =====
local function ApplyCVars(on)
    if InCombatLockdown() then return end
    if on then
        db.savedCVars = db.savedCVars or {}
        for k in pairs(LIVE_CVARS) do   -- save the player's value once per setting
            if db.savedCVars[k] == nil then db.savedCVars[k] = GetCVar(k) end
        end
        for k, v in pairs(LIVE_CVARS) do
            if GetCVar(k) ~= nil then pcall(SetCVar, k, v) end
        end
    elseif db.savedCVars then
        for k, v in pairs(db.savedCVars) do
            if GetCVar(k) ~= nil then pcall(SetCVar, k, v) end
        end
        db.savedCVars = nil
    end
end

-- own icon, used only when the target has a nameplate (corpses; herbs never get one)
local iconFrame = CreateFrame("Frame", "ShowHerbsMinMaxIcon", UIParent)
iconFrame:SetFrameStrata("BACKGROUND")
iconFrame:Hide()
local iconTex = iconFrame:CreateTexture(nil, "ARTWORK")
iconTex:SetAllPoints()
iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
iconTex:SetTexture(SKIN_ICON)

-- scale the game's icon size settings; restore = put the game's own values back
local function ApplyIconSize(restore)
    local scale = db.iconScale / 100
    iconFrame:SetSize(32 * scale, 32 * scale)
    if InCombatLockdown() then return end
    for _, c in ipairs(SIZE_CVARS) do
        local current = tonumber(GetCVar(c.name) or "")
        if current then
            if not db.sizeBase[c.name] and current > 0 then db.sizeBase[c.name] = current end
            local base = db.sizeBase[c.name]
            if base then
                local v = restore and base or base * scale
                pcall(SetCVar, c.name, c.integer and tostring(math.floor(v + 0.5)) or string.format("%.2f", v))
            end
        end
    end
    if restore then db.sizeBase = {} end
end

-- the game's own soft target icon: "object" (herb / ore), "interact" (corpse) or false (none)
-- Checks the real setting every time (not a remembered state): the game or a combat reset can
-- change it, and then the icon must be switched on again.
-- Herbs / ore need BOTH settings on: IconInteract is the main switch, IconGameObject adds game
-- objects (either one alone shows nothing on herbs, tested). Corpses only need IconInteract.
local gameIcon
local function SetCVarIfDifferent(name, value)
    if GetCVar(name) ~= value then pcall(SetCVar, name, value) end
end
local function SetGameIcon(mode)
    gameIcon = mode or false
    SetCVarIfDifferent("SoftTargetIconInteract", gameIcon and "1" or "0")
    SetCVarIfDifferent("SoftTargetIconGameObject", gameIcon == "object" and "1" or "0")
end

local function SoftPlate()
    return C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("softinteract")
end

local function Update()
    if not AnyOn() then iconFrame:Hide(); return end
    local guid = SoftGUID()
    local kind = NodeKind(guid)
    if (kind == "herb" and db.showHerbs) or (kind == "mine" and db.showMines) then
        iconFrame:Hide()
        SetGameIcon("object")
    elseif IsSkinnable(guid) then
        local plate = SoftPlate()
        if plate then
            SetGameIcon(false)
            iconFrame:ClearAllPoints()
            iconFrame:SetPoint("BOTTOM", plate, "TOP", 0, 4)
            iconFrame:Show()
        else
            iconFrame:Hide()
            SetGameIcon("interact")
        end
    else
        iconFrame:Hide()
        SetGameIcon(false)
    end
end

-- switch the game settings to match the options (all off = player's own settings back)
local function ApplyAll()
    gameIcon = nil
    skinCache.guid = nil
    ApplyCVars(AnyOn())
    ApplyIconSize(not AnyOn())
    Update()
end

-- ===== Options window =====
local panel, checks = nil, {}

local function RefreshChecks()
    for key, cb in pairs(checks) do cb:SetChecked(db[key]) end
end

local function BuildPanel()
    panel = CreateFrame("Frame", "ShowHerbsMinMaxOptions", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(340, 210)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    tinsert(UISpecialFrames, "ShowHerbsMinMaxOptions")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("ShowHerbsMinMax")
    CreateFrame("Button", nil, panel, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -4, -4)

    local y = -44
    local function Check(key, label)
        local name = "ShowHerbsMinMaxCheck_" .. key
        local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 20, y)
        _G[name .. "Text"]:SetText(label)
        cb:SetScript("OnClick", function(self)
            if InCombatLockdown() then
                Print("cannot change this during combat.")
                self:SetChecked(db[key])
                return
            end
            db[key] = self:GetChecked() and true or false
            ApplyAll()
        end)
        checks[key] = cb
        y = y - 26
    end
    Check("showHerbs", "Icon above herbs")
    Check("showMines", "Icon above ore")
    Check("showSkin", "Icon above skinnable corpses")

    -- icon size slider (no template: OptionsSliderTemplate is missing in some clients)
    local slider = CreateFrame("Slider", "ShowHerbsMinMaxSizeSlider", panel)
    slider:SetPoint("TOPLEFT", 28, y - 30)
    slider:SetSize(280, 17)
    slider:SetOrientation("HORIZONTAL")
    slider:EnableMouse(true)
    slider:SetHitRectInsets(0, 0, -10, -10)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(6)
    track:SetColorTexture(0, 0, 0, 0.8)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetMinMaxValues(ICON_MIN, ICON_MAX)
    slider:SetValueStep(ICON_STEP)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    local label = slider:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("BOTTOM", slider, "TOP", 0, 2)
    local low = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
    low:SetText(ICON_MIN .. "%")
    local high = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)
    high:SetText(ICON_MAX .. "%")
    slider:SetValue(db.iconScale)
    label:SetText("Icon size: " .. db.iconScale .. "%")
    slider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value / ICON_STEP + 0.5) * ICON_STEP
        if value == db.iconScale then return end
        db.iconScale = value
        label:SetText("Icon size: " .. value .. "%")
        if AnyOn() then ApplyIconSize() end
    end)

    RefreshChecks()
end

local function TogglePanel()
    if not panel then return end
    if panel:IsShown() then panel:Hide() else RefreshChecks(); panel:Show() end
end

-- ===== Minimap button =====
local function BuildMinimapButton()
    local btn = CreateFrame("Button", "ShowHerbsMinMaxMinimapButton", UIParent)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Herb_07")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    local function UpdatePosition()
        local angle = math.rad(db.minimapAngle)
        local radius = Minimap:GetWidth() / 2 + 5
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
    end
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            UpdatePosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnClick", TogglePanel)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ShowHerbsMinMax")
        GameTooltip:AddLine("Click: options", 1, 1, 1)
        GameTooltip:AddLine("Drag: move button", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UpdatePosition()
end

-- ===== Slash command: /shm (options), /shm live (what is targeted right now) =====
SLASH_SHOWHERBSMINMAX1 = "/shm"
SLASH_SHOWHERBSMINMAX2 = "/smm"   -- old command
SlashCmdList["SHOWHERBSMINMAX"] = function(msg)
    if (msg or ""):lower() == "live" then
        local guid = SoftGUID()
        local okN, name = pcall(UnitName, "softinteract")
        skinCache.guid = nil
        Print("name: " .. tostring(okN and Clean(name)) .. ", guid: " .. tostring(guid)
            .. ", object id: " .. tostring(ObjectEntry(guid)) .. ", kind: " .. tostring(NodeKind(guid))
            .. ", skinnable: " .. tostring(IsSkinnable(guid)))
        Print("herbs: " .. tostring(db.showHerbs) .. ", ore: " .. tostring(db.showMines)
            .. ", game icon: " .. tostring(gameIcon)
            .. ", IconGameObject=" .. tostring(GetCVar("SoftTargetIconGameObject"))
            .. ", Interact=" .. tostring(GetCVar("SoftTargetInteract"))
            .. ", IconInteract=" .. tostring(GetCVar("SoftTargetIconInteract"))
            .. ", Outline=" .. tostring(GetCVar("graphicsOutlineMode")))
        Print("size " .. db.iconScale .. "%: WorldtextSize=" .. tostring(GetCVar("SoftTargetWorldtextSize"))
            .. ", NearScale=" .. tostring(GetCVar("SoftTargetWorldtextNearScale"))
            .. ", NameplateSize=" .. tostring(GetCVar("SoftTargetNameplateSize")))
    else
        TogglePanel()
    end
end

-- ===== Events =====
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("UNIT_SPELLCAST_SENT")
pcall(ev.RegisterEvent, ev, "PLAYER_SOFT_INTERACT_CHANGED")
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        InitDB()
        -- each step on its own: one failing part must not stop the rest
        local function Step(label, fn)
            local ok, err = pcall(fn)
            if not ok then Print("error in " .. label .. ": " .. tostring(err)) end
        end
        Step("spells", RegisterSpells)
        Step("game settings", function()
            if AnyOn() then ApplyIconSize(); ApplyCVars(true) else ApplyCVars(false) end
        end)
        local elapsedSum, lastError = 0, nil
        ev:SetScript("OnUpdate", function(_, elapsed)
            elapsedSum = elapsedSum + elapsed
            if elapsedSum < 0.03 then return end
            elapsedSum = 0
            local ok, err = pcall(Update)
            if not ok and err ~= lastError then
                lastError = err
                Print("error in update: " .. tostring(err))
            end
        end)
        Step("options window", BuildPanel)
        Step("minimap button", BuildMinimapButton)
    elseif not db then
        return
    elseif event == "PLAYER_REGEN_ENABLED" then
        if AnyOn() then ApplyCVars(true) end   -- in case login happened during combat
    elseif event == "PLAYER_SOFT_INTERACT_CHANGED" then
        local _, newGUID = ...
        newGUID = Clean(newGUID)
        softGUID = type(newGUID) == "string" and newGUID or nil
    elseif event == "UNIT_SPELLCAST_SENT" then
        -- learn herb / ore object IDs that are not in the lists, from your own gather casts
        local unit, _, _, spellID = ...
        if unit ~= "player" then return end
        local name = SpellName(spellID)
        local kind = name and gatherSpells[name]
        local entry = kind and ObjectEntry(SoftGUID())
        if entry and not KIND[entry] and db.learnedIDs[entry] ~= kind then
            db.learnedIDs[entry] = kind
            Print("learned object " .. entry .. " as " .. kind)
        end
    end
end)
