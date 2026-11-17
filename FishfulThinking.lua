-- Fishful Thinking: fishing without swapping gear by hand.
--
-- Fish button (panel, action bar or its own key binding). Each press does the next
-- missing step:
--   1. If the pole is not equipped, remember the weapon and equip the pole.
--   2. If the pole has no lure and you carry one, apply the best one.
--   3. Otherwise, cast Fishing.
-- While the bobber is out, the Fish keys act as "Interact" and reel in the catch.
-- In combat, with the pole equipped, Fish gives you your weapon back.
-- Weapon button: re-equip whatever you were holding before the pole.

local ADDON_NAME, ns = ...
local C, L = ns.C, ns.L

-- API with fallbacks across client versions ------------------------------------

local IsSecret = issecretvalue or function() return false end
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local IsUsableItem = (C_Item and C_Item.IsUsableItem) or IsUsableItem
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local GetItemInfoFull = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemSubClassInfo = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
local GetItemName = (C_Item and C_Item.GetItemNameByID) or function(itemID)
    return GetItemInfo and (GetItemInfo(itemID))
end
local GetContainerNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local GetContainerItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
local GetContainerNumFreeSlots = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
local PickupContainerItem = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
local GetActionTextFor = (C_ActionBar and C_ActionBar.GetActionText) or GetActionText
local GetCVarValue = (C_CVar and C_CVar.GetCVar) or GetCVar
local SetCVarValue = (C_CVar and C_CVar.SetCVar) or SetCVar
local Atan2 = math.atan2 or math.atan

-- State ----------------------------------------------------------------------------

local db -- FishfulThinkingCharDB (per character), available from ADDON_LOADED
local accountDB -- FishfulThinkingDB (account-wide: language)
local activeLanguage = C.DEFAULT_LANGUAGE
local panel, panelFishButton, panelWeaponButton, statusText, statusTicker, minimapButton
local fishingButtons, weaponButtons = {}, {}
local weaponUpdatePending = false
local panelSetupPending = false
local reelClearPending = false
local reelKeysActive = false
local reelKeysText
local reelHintShown = false
local fishingActive = false
local pendingLure
local lureFailures = {}
local equipmentToken = 0
local sessionToken = 0
local optionsApplyPending = false
-- optionsCanvas: what the game's Settings shows; optionsPanel: where the controls go
-- (a scrolling area inside it when the template exists).
local optionsCategory, optionsPanel, optionsCanvas
local optionControls = {}
local alertButton, alertTitle, alertHint, alertPulse
local alertTestToken = 0
local alertTesting = false
local alertDriverActive = false
local alertDriverPending = false
local alertDriverUnsupported = false
local alertDriverCondition
-- Newer features keep their functions and state in one table each.
local Gear = { bonusCache = {} }
local AutoEquip = { active = false, offHand = nil, armorPending = false, attemptAt = nil }
local Hints = { escapeZones = {}, zoneCatches = {}, notHookedShown = false, lureWatching = false, lureWasOn = nil }
local Keys = { capture = {} }
local Value = { hinted = {}, rows = {}, auctionOpen = false, openable = {} }
local Hud = { caughtAt = 0, peek = false, driverActive = false, visibilityPending = false }
-- Effects of the combat alert, and the notice when the weapon goes on by itself.
local Fx = { toastToken = 0 }
-- The main window: tabs, pages and their lists.
local Window = { tabs = {}, pages = {} }
-- The options pages: switches, key chips and the pages themselves.
local Options = {}
local bindingOwner = CreateFrame("Frame")
-- Defined with the options page further down; used earlier by the panel and minimap.
local RefreshOptions = function() end
local OpenOptions = function() end
-- Defined with the combat alert further down; used earlier by the weapon buttons.
local UpdateAlertDriver = function() end

local function PrintMessage(text)
    print(L.TITLE .. ": " .. text)
end

-- Options ---------------------------------------------------------------------------

local function GetOption(key)
    local value = db and db.options and db.options[key]
    if value == nil then
        return C.OPTION_DEFAULTS[key]
    end
    return value
end

-- Flags from earlier versions become options, once.
local function MigrateLegacyOptions()
    db.options = db.options or {}
    for _, legacy in ipairs(C.LEGACY_OPTION_FLAGS) do
        if db[legacy.flag] then
            db.options[legacy.option] = legacy.value
        end
        db[legacy.flag] = nil
    end
end

-- Equipment --------------------------------------------------------------------------

local function GetEquippedItemID(slot)
    local itemID = GetInventoryItemID(C.PLAYER_UNIT, slot)
    if IsSecret(itemID) then
        return nil
    end
    return itemID
end

local function IsFishingPole(itemID)
    if not itemID then
        return false
    end
    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(itemID)
    return classID == C.WEAPON_ITEM_CLASS and subclassID == C.FISHING_POLE_SUBCLASS
end

local function IsPoleEquipped()
    return IsFishingPole(GetEquippedItemID(C.MAIN_HAND_SLOT))
end

-- Prefers the last pole you used; otherwise the first one in your bags.
local function FindFishingPoleInBags()
    local firstPole
    for bag = C.FIRST_BAG, C.LAST_ITEM_BAG do
        for slot = 1, GetContainerNumSlots(bag) or 0 do
            local itemID = GetContainerItemID(bag, slot)
            if IsFishingPole(itemID) then
                if itemID == db.lastPoleID then
                    return itemID
                end
                firstPole = firstPole or itemID
            end
        end
    end
    return firstPole
end

local function GetFreeBagSlots()
    if not GetContainerNumFreeSlots then
        return nil
    end
    local free = 0
    for bag = C.FIRST_BAG, C.LAST_BAG do
        local ok, slots, bagType = pcall(GetContainerNumFreeSlots, bag)
        if ok and type(slots) == "number" and (bagType == nil or bagType == C.GENERIC_BAG_TYPE) then
            free = free + slots
        end
    end
    return free
end

-- Remembers what you hold, unless it is the pole.
local function RememberCurrentWeapons()
    local mainHand = GetEquippedItemID(C.MAIN_HAND_SLOT)
    if not mainHand or IsFishingPole(mainHand) then
        return false
    end
    local offHand = GetEquippedItemID(C.OFF_HAND_SLOT)
    local saved = db.weapons
    if saved and saved.mainHand == mainHand and saved.offHand == offHand then
        return false
    end
    db.weapons = { mainHand = mainHand, offHand = offHand }
    return true
end

local function GetWeaponIcon()
    local weapons = db and db.weapons
    local mainHand = weapons and weapons.mainHand
    return (mainHand and GetItemIcon(mainHand)) or C.WEAPON_ICON_FALLBACK
end

-- Lure -----------------------------------------------------------------------------

local LURE_MINUTES = {}
for _, lure in ipairs(C.LURES) do
    LURE_MINUTES[lure.itemID] = lure.minutes
end

-- Turns the client's format ("%s (%d min)") into a Lua pattern, so reading the
-- tooltip works in every language.
local ENCHANT_TIME_PATTERNS = {}
local function AddEnchantTimePattern(format, secondsPerUnit)
    if type(format) ~= "string" then
        return
    end
    local pattern = format
        :gsub("%%%d+%$", "%%")
        :gsub("([%(%)%.%-%+%[%]%^%$%?%*])", "%%%1")
        :gsub("|4[^;]*;", "%%S+")
        :gsub("%%s", ".+")
        :gsub("%%d", "(%%d+)")
    table.insert(ENCHANT_TIME_PATTERNS, { pattern = "^" .. pattern .. "$", secondsPerUnit = secondsPerUnit })
end
AddEnchantTimePattern(ITEM_ENCHANT_TIME_LEFT_SEC or C.ENCHANT_TIME_FALLBACK.SECONDS, 1)
AddEnchantTimePattern(ITEM_ENCHANT_TIME_LEFT_MIN or C.ENCHANT_TIME_FALLBACK.MINUTES, C.SECONDS_PER_MINUTE)
AddEnchantTimePattern(ITEM_ENCHANT_TIME_LEFT_HOURS or C.ENCHANT_TIME_FALLBACK.HOURS, C.SECONDS_PER_HOUR)

-- Forever's enchant functions are not reliable; the pole tooltip shows the lure
-- with its time left. Returns: seconds (nil if no lure line), tooltip readable.
local function ReadLureTooltip()
    if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then
        return nil, false
    end
    local ok, data = pcall(C_TooltipInfo.GetInventoryItem, C.PLAYER_UNIT, C.MAIN_HAND_SLOT)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then
        return nil, false
    end
    for _, line in ipairs(data.lines) do
        local text = line.leftText
        if not IsSecret(text) and type(text) == "string" then
            for _, entry in ipairs(ENCHANT_TIME_PATTERNS) do
                local amount = tonumber(text:match(entry.pattern))
                if amount then
                    return amount * entry.secondsPerUnit, true
                end
            end
        end
    end
    return nil, true
end

local function IsTrue(value)
    return not IsSecret(value) and value == true
end

local function HasLureFromApi()
    if C_PaperDollInfo and C_PaperDollInfo.GetTemporaryEnchantmentInfo then
        local ok, info = pcall(C_PaperDollInfo.GetTemporaryEnchantmentInfo, C.MAIN_HAND_SLOT)
        if ok and info ~= nil and not IsSecret(info) then
            return true
        end
    end
    if C_Item and C_Item.GetWeaponEnchantInfo then
        local ok, enchants = pcall(C_Item.GetWeaponEnchantInfo, C.WEAPON_SLOT_MAIN_HAND)
        if ok and type(enchants) == "table" then
            for _, enchant in ipairs(enchants) do
                local enchantType = enchant.enchantType
                if IsTrue(enchant.hasEnchant) and not IsSecret(enchantType)
                    and enchantType == C.ENCHANT_TYPE_TEMPORARY then
                    return true
                end
            end
        end
    end
    if GetWeaponEnchantInfo then
        local ok, hasMainHand = pcall(GetWeaponEnchantInfo)
        if ok and IsTrue(hasMainHand) then
            return true
        end
    end
    return false
end

-- Lure applied by this addon (fallback when nothing else can tell).
local function GetTrackedLureSeconds(poleID)
    local untilTime = db and db.lureUntil
    if not untilTime then
        return nil
    end
    if poleID and db.lurePoleID and db.lurePoleID ~= poleID then
        return nil
    end
    local secondsLeft = untilTime - time()
    if secondsLeft > 0 then
        return secondsLeft
    end
    return nil
end

local function RecordLure(poleID, seconds)
    db.lureUntil = time() + seconds
    db.lurePoleID = poleID
end

-- Returns: lure on the pole, seconds left (if known), where that came from.
local function GetLureState()
    -- Without the pole the tooltip would be the weapon's (poisons, stones...).
    local poleID = GetEquippedItemID(C.MAIN_HAND_SLOT)
    if not IsFishingPole(poleID) then
        return false
    end
    local seconds, readable = ReadLureTooltip()
    if seconds then
        db.tooltipShowsLure = true
        RecordLure(poleID, seconds)
        return true, seconds, C.LURE_SOURCE.TOOLTIP
    end
    if HasLureFromApi() then
        return true, nil, C.LURE_SOURCE.API
    end
    -- Once the tooltip has shown a lure, a readable tooltip without one means the
    -- lure is gone (except right after applying it, while the tooltip catches up).
    local justApplied = db.lureAppliedAt and time() - db.lureAppliedAt < C.LURE_TOOLTIP_GRACE_SECONDS
    if readable and db.tooltipShowsLure and not justApplied then
        db.lureUntil = nil
        return false
    end
    seconds = GetTrackedLureSeconds(poleID)
    if seconds then
        return true, seconds, C.LURE_SOURCE.TRACKED
    end
    return false
end

local function FindBestLure()
    for _, lure in ipairs(C.LURES) do
        local itemID = lure.itemID
        if (lureFailures[itemID] or 0) < C.LURE_MAX_FAILURES
            and (GetItemCount(itemID) or 0) > 0 and IsUsableItem(itemID) then
            return itemID
        end
    end
end

-- If the lure count drops after using one, it was applied: record its duration.
-- If the window passes without that, count a failure (e.g. not enough skill).
local function StartPendingLure(itemID)
    pendingLure = {
        itemID = itemID,
        count = GetItemCount(itemID) or 0,
        expiresAt = GetTime() + C.LURE_PENDING_SECONDS,
    }
end

local function CheckPendingLure()
    if not pendingLure then
        return false
    end
    local itemID = pendingLure.itemID
    if (GetItemCount(itemID) or 0) < pendingLure.count then
        pendingLure = nil
        lureFailures[itemID] = nil
        db.lureAppliedAt = time()
        db.lureFullSeconds = (LURE_MINUTES[itemID] or C.DEFAULT_LURE_MINUTES) * C.SECONDS_PER_MINUTE
        RecordLure(GetEquippedItemID(C.MAIN_HAND_SLOT), db.lureFullSeconds)
        return true
    end
    if GetTime() > pendingLure.expiresAt then
        pendingLure = nil
        lureFailures[itemID] = (lureFailures[itemID] or 0) + 1
        if lureFailures[itemID] >= C.LURE_MAX_FAILURES then
            PrintMessage(L.LURE_SKIPPED:format(GetItemName(itemID) or (C.ITEM_LINK_PREFIX .. itemID)))
        end
    end
    return false
end

-- Fishing spell ------------------------------------------------------------------

local function GetFishingSpellName()
    local name
    if C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(C.FISHING_SPELL_ID)
    elseif C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(C.FISHING_SPELL_ID)
        name = info and info.name
    elseif GetSpellInfo then
        name = GetSpellInfo(C.FISHING_SPELL_ID)
    end
    return name or C.FISHING_SPELL_FALLBACK_NAME
end

local function GetFishingIcon()
    local icon
    if C_Spell and C_Spell.GetSpellTexture then
        icon = C_Spell.GetSpellTexture(C.FISHING_SPELL_ID)
    elseif GetSpellTexture then
        icon = GetSpellTexture(C.FISHING_SPELL_ID)
    end
    return icon or C.FISHING_ICON_FALLBACK
end

local function IsFishingSpell(spellID)
    if spellID == nil or IsSecret(spellID) then
        return false
    end
    if C.FISHING_SPELL_IDS[spellID] then
        return true
    end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    return name ~= nil and not IsSecret(name) and name == GetFishingSpellName()
end

-- Is the bobber out? Confirmed with the game when possible.
local function IsFishingChannelActive()
    if UnitChannelInfo then
        local ok, name, _, _, _, _, _, _, spellID = pcall(UnitChannelInfo, C.PLAYER_UNIT)
        if ok and not IsSecret(name) then
            if name == nil then
                fishingActive = false
                return false
            end
            return IsFishingSpell(spellID) or name == GetFishingSpellName()
        end
    end
    return fishingActive
end

local function IsGamepadUI()
    if InputUtil and InputUtil.IsGamepadUIEnabled then
        local ok, enabled = pcall(InputUtil.IsGamepadUIEnabled)
        if ok and not IsSecret(enabled) then
            return enabled == true
        end
    end
    local ok, value = pcall(GetCVarValue, C.GAMEPAD_UI_CVAR)
    return ok and value == C.GAMEPAD_UI_VALUE
end

-- Fishing session tweaks -------------------------------------------------------------
-- While you fish: longer bobber range for Interact and auto loot (and, optionally,
-- sound mode). Your own values are saved and restored when the session ends.

local function GetSessionCVars()
    local list = {}
    if GetOption("sessionTweaks") then
        for _, cvar in ipairs(C.SESSION_CVARS) do
            table.insert(list, cvar)
        end
    end
    if GetOption("markBobber") then
        for _, cvar in ipairs(C.BOBBER_MARK_CVARS) do
            table.insert(list, cvar)
        end
    end
    if GetOption("soundMode") then
        for _, cvar in ipairs(C.SOUND_CVARS) do
            table.insert(list, cvar)
        end
    end
    return list
end

local function StartFishingSession()
    sessionToken = sessionToken + 1
    for _, cvar in ipairs(GetSessionCVars()) do
        db.cvarBackup = db.cvarBackup or {}
        if db.cvarBackup[cvar.name] == nil then
            local ok, current = pcall(GetCVarValue, cvar.name)
            if ok and type(current) == "string" and not IsSecret(current) then
                db.cvarBackup[cvar.name] = current
                pcall(SetCVarValue, cvar.name, cvar.value)
            end
        end
    end
end

local function EndFishingSession()
    sessionToken = sessionToken + 1
    local backup = db and db.cvarBackup
    if not backup then
        return
    end
    for name, value in pairs(backup) do
        if pcall(SetCVarValue, name, value) then
            backup[name] = nil
        end
    end
    if next(backup) == nil then
        db.cvarBackup = nil
    end
end

local function ScheduleSessionEnd()
    sessionToken = sessionToken + 1
    local token = sessionToken
    C_Timer.After(C.SESSION_IDLE_SECONDS, function()
        if token == sessionToken and not IsFishingChannelActive() then
            EndFishingSession()
        end
    end)
end

-- Keys that reel in the catch ---------------------------------------------------------
-- No button or macro can interact with the bobber; only the game's "Interact"
-- binding can. While the bobber is out, the Fish keys become that binding.

local function GetMacroIndex(name)
    local index = GetMacroIndexByName(name)
    if index and not IsSecret(index) and index > 0 then
        return index
    end
end

local function GetFrameActionSlot(frame)
    if type(frame) ~= "table" then
        return nil
    end
    local slot = frame.action
    if type(slot) ~= "number" and frame.GetAttribute then
        local ok, attribute = pcall(frame.GetAttribute, frame, "action")
        slot = ok and tonumber(attribute) or nil
    end
    if type(slot) ~= "number" or IsSecret(slot) then
        return nil
    end
    return slot
end

-- Fish button names a macro can /click: the current one and the old ones.
local FISH_BUTTON_NAMES = { C.MACRO_BUTTON_NAME }
for _, name in ipairs(C.LEGACY_FISH_BUTTON_NAMES) do
    table.insert(FISH_BUTTON_NAMES, name)
end

local function ClicksFishButton(body)
    for _, name in ipairs(FISH_BUTTON_NAMES) do
        if body:find(name, 1, true) then
            return true
        end
    end
    return false
end

-- A bar slot counts if it holds a macro that clicks the Fish button.
local function IsFishingMacroSlot(slot)
    local ok, actionType, actionID = pcall(GetActionInfo, slot)
    if not ok or IsSecret(actionType) or actionType ~= C.ACTION_INFO_MACRO then
        return false
    end
    local index = actionID
    if GetActionTextFor then
        local okName, name = pcall(GetActionTextFor, slot)
        if okName and type(name) == "string" and not IsSecret(name) then
            index = GetMacroIndex(name) or index
        end
    end
    local body = index and GetMacroBody(index)
    return type(body) == "string" and not IsSecret(body) and ClicksFishButton(body)
end

local function AddBindingKeys(keys, command)
    for _, key in ipairs({ GetBindingKey(command) }) do
        if not IsSecret(key) then
            keys[key] = true
        end
    end
end

local function CollectFishingKeys()
    local keys = {}
    -- Own key binding (Key Bindings > AddOns).
    AddBindingKeys(keys, C.FISH_BINDING_COMMAND)
    -- Blizzard action bars.
    for _, bar in ipairs(C.ACTION_BAR_BUTTONS) do
        for index = 1, C.BUTTONS_PER_BAR do
            local frameName = bar.frame:format(index)
            local slot = GetFrameActionSlot(_G[frameName])
            if slot and IsFishingMacroSlot(slot) then
                AddBindingKeys(keys, bar.command:format(index))
                AddBindingKeys(keys, C.CLICK_BINDING_FORMAT:format(frameName))
            end
        end
    end
    -- Other bars (addons, controller UI) bound as "CLICK Frame:Button".
    for index = 1, GetNumBindings() do
        local command = GetBinding(index)
        local frameName = type(command) == "string" and not IsSecret(command)
            and command:match(C.CLICK_BINDING_FRAME_PATTERN)
        if frameName and not ClicksFishButton(frameName) then
            local slot = GetFrameActionSlot(_G[frameName])
            if slot and IsFishingMacroSlot(slot) then
                AddBindingKeys(keys, command)
            end
        end
    end
    return keys
end

-- Whatever key you assigned to Interact also reels in, not only "1".
local function CollectInteractKeys()
    local keys = {}
    AddBindingKeys(keys, C.INTERACT_BINDING_COMMAND)
    return keys
end

local function GetKeyLabel(key)
    if GetBindingText then
        local ok, label = pcall(GetBindingText, key)
        if ok and type(label) == "string" and label ~= "" and not IsSecret(label) then
            return label
        end
    end
    return key
end

local function DescribeKeys(...)
    local seen, list = {}, {}
    for index = 1, select("#", ...) do
        for key in pairs(select(index, ...) or {}) do
            if not seen[key] then
                seen[key] = true
                table.insert(list, GetKeyLabel(key))
            end
        end
    end
    table.sort(list)
    if #list == 0 then
        return nil
    end
    return table.concat(list, C.KEY_SEPARATOR)
end

local function GetGlobalText(globalName, fallback)
    local text = _G[globalName]
    if type(text) == "string" and text ~= "" then
        return text
    end
    return fallback
end

-- Tells you once per login how to reel in, or that you need to assign a key.
local function AnnounceReelKeys(fishKeys)
    if reelHintShown or not GetOption("chatHints") then
        return
    end
    reelHintShown = true
    local keysText = DescribeKeys(fishKeys, CollectInteractKeys())
    if keysText then
        PrintMessage(L.REEL_KEYS_HINT:format(keysText))
    elseif IsGamepadUI() then
        PrintMessage(L.REEL_GAMEPAD_HINT)
    else
        PrintMessage(L.REEL_ASSIGN_KEY:format(
            GetGlobalText(C.KEY_BINDINGS_LABEL_GLOBAL, L.KEY_BINDINGS_FALLBACK),
            GetGlobalText(C.INTERACT_BINDING_LABEL_GLOBAL, L.INTERACT_BINDING_FALLBACK)))
    end
end

local function SetReelKeys(enabled)
    if InCombatLockdown() then
        reelClearPending = reelKeysActive and not enabled
        return
    end
    reelClearPending = false
    if reelKeysActive then
        ClearOverrideBindings(bindingOwner)
        reelKeysActive = false
    end
    reelKeysText = nil
    if not enabled then
        return
    end
    -- With the option off, only your own Interact keys reel in.
    local fishKeys = GetOption("reelWithFishKey") and CollectFishingKeys() or {}
    for key in pairs(fishKeys) do
        SetOverrideBinding(bindingOwner, true, key, C.INTERACT_BINDING_COMMAND)
        reelKeysActive = true
    end
    reelKeysText = DescribeKeys(fishKeys, CollectInteractKeys())
    AnnounceReelKeys(fishKeys)
end

-- Fishing gear ---------------------------------------------------------------------------
-- Pieces with a Fishing bonus in your bags (hat, gloves, boots...) go on with the pole, in
-- the same press. What you usually wear in those slots is remembered and comes back with
-- the weapon.

function Gear.FindInBags(itemID)
    for bag = C.FIRST_BAG, C.LAST_ITEM_BAG do
        for bagSlot = 1, GetContainerNumSlots(bag) or 0 do
            if GetContainerItemID(bag, bagSlot) == itemID then
                return bag, bagSlot
            end
        end
    end
end

-- The "+N" Fishing bonus on the item's tooltip, in the game's language. Nil while the
-- tooltip hasn't loaded yet.
function Gear.ReadBonus(itemID)
    if not (C_TooltipInfo and C_TooltipInfo.GetItemByID) then
        return 0
    end
    local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" or #data.lines == 0 then
        return nil
    end
    local fishingName = GetFishingSpellName()
    local word = type(fishingName) == "string" and fishingName:lower() or C.FISHING_WORD_FALLBACK
    for _, line in ipairs(data.lines) do
        local text = line.leftText
        if type(text) == "string" and not IsSecret(text) then
            local lower = text:lower()
            if lower:find(word, 1, true) or lower:find(C.FISHING_WORD_FALLBACK, 1, true) then
                local bonus = text:match(C.FISHING_BONUS_PATTERN)
                if bonus then
                    return tonumber(bonus)
                end
            end
        end
    end
    return 0
end

function Gear.GetBonus(itemID)
    if not itemID or IsSecret(itemID) then
        return 0
    end
    local cached = Gear.bonusCache[itemID]
    if cached then
        return cached
    end
    local bonus = Gear.ReadBonus(itemID)
    if bonus then
        Gear.bonusCache[itemID] = bonus
    end
    return bonus or 0
end

function Gear.GetSlot(itemID)
    local _, _, _, equipLocation = GetItemInfoInstant(itemID)
    return type(equipLocation) == "string" and C.GEAR_SLOTS[equipLocation] or nil
end

-- The best Fishing piece in your bags for each slot, when it beats what you wear there.
-- Biggest bonus first: { { slot =, itemID =, bonus = }, ... }.
function Gear.GetPlan()
    local plan = {}
    if not GetOption("fishingGear") then
        return plan
    end
    local best = {}
    for bag = C.FIRST_BAG, C.LAST_ITEM_BAG do
        for bagSlot = 1, GetContainerNumSlots(bag) or 0 do
            local itemID = GetContainerItemID(bag, bagSlot)
            local slot = itemID and not IsSecret(itemID) and Gear.GetSlot(itemID)
            if slot then
                local bonus = Gear.GetBonus(itemID)
                if bonus > 0 and (not best[slot] or bonus > best[slot].bonus) then
                    best[slot] = { slot = slot, itemID = itemID, bonus = bonus }
                end
            end
        end
    end
    for slot, pick in pairs(best) do
        if Gear.GetBonus(GetEquippedItemID(slot)) < pick.bonus then
            table.insert(plan, pick)
        end
    end
    table.sort(plan, function(a, b)
        if a.bonus ~= b.bonus then
            return a.bonus > b.bonus
        end
        return a.slot < b.slot
    end)
    return plan
end

-- While the pole is off: what you wear in each gear slot, unless it is a fishing piece.
function Gear.RememberUsual()
    if not db or IsPoleEquipped() then
        return
    end
    db.usualGear = db.usualGear or {}
    for _, slot in pairs(C.GEAR_SLOTS) do
        local itemID = GetEquippedItemID(slot)
        if itemID and Gear.GetBonus(itemID) == 0 then
            db.usualGear[slot] = itemID
        end
    end
end

-- Slots with a fishing piece on whose usual piece is in your bags.
function Gear.GetUsualToRestore()
    local list = {}
    local usual = db and db.usualGear
    if not usual or not GetOption("fishingGear") then
        return list
    end
    for slot, itemID in pairs(usual) do
        local worn = GetEquippedItemID(slot)
        if worn ~= itemID and Gear.GetBonus(worn) > 0 and Gear.FindInBags(itemID) then
            table.insert(list, { slot = slot, itemID = itemID })
        end
    end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    return list
end

-- The fishing pieces to put on now: only while the pole is still in your bags.
function Gear.GetEquipLines()
    local lines = {}
    if not db or IsPoleEquipped() or not FindFishingPoleInBags() then
        return lines
    end
    for _, pick in ipairs(Gear.GetPlan()) do
        table.insert(lines, C.MACRO_LINES.GEAR_EQUIP:format(pick.slot, pick.itemID))
    end
    return lines
end

-- Adds lines while the text stays within the game's limit for a macro.
function Gear.AppendWithinLimit(lines, extra, limit)
    local length = #table.concat(lines, C.MACRO_LINE_SEPARATOR)
    for _, line in ipairs(extra) do
        local added = (#lines > 0 and #C.MACRO_LINE_SEPARATOR or 0) + #line
        if length + added > limit then
            return
        end
        table.insert(lines, line)
        length = length + added
    end
end

-- Weapon (and, out of combat, your usual pieces instead of the fishing ones).
local function BuildWeaponMacroText(weapons)
    if not (weapons and weapons.mainHand) then
        return nil
    end
    local lines = { C.EQUIP_SLOT_LINE:format(C.MAIN_HAND_SLOT, weapons.mainHand) }
    if weapons.offHand then
        table.insert(lines, C.EQUIP_SLOT_LINE:format(C.OFF_HAND_SLOT, weapons.offHand))
    end
    local restore = {}
    for _, piece in ipairs(Gear.GetUsualToRestore()) do
        table.insert(restore, C.MACRO_LINES.NOCOMBAT_EQUIP:format(piece.slot, piece.itemID))
    end
    Gear.AppendWithinLimit(lines, restore, C.MACRO_MAX_CHARS)
    return table.concat(lines, C.MACRO_LINE_SEPARATOR)
end

-- Action bar macro for Fish: in combat it re-equips the weapon and stops; out of
-- combat it clears the target (Interact prefers it over the bobber), puts on your
-- fishing gear with the pole, and fishes.
local function BuildFishingMacroText()
    local lines = {}
    local weapons = db and db.weapons
    if GetOption("combatWeaponSwap") and weapons and weapons.mainHand then
        table.insert(lines, C.MACRO_LINES.COMBAT_EQUIP:format(C.MAIN_HAND_SLOT, weapons.mainHand))
        if weapons.offHand then
            table.insert(lines, C.MACRO_LINES.COMBAT_EQUIP:format(C.OFF_HAND_SLOT, weapons.offHand))
        end
    end
    table.insert(lines, C.MACRO_LINES.STOP_IN_COMBAT)
    if GetOption("clearTarget") then
        table.insert(lines, C.MACRO_LINES.CLEAR_TARGET)
    end
    local clickLine = C.MACRO_LINES.CLICK:format(C.MACRO_BUTTON_NAME, C.BAR_CLICK_BUTTON)
    Gear.AppendWithinLimit(lines, Gear.GetEquipLines(), C.MACRO_MAX_CHARS - #clickLine - #C.MACRO_LINE_SEPARATOR)
    table.insert(lines, clickLine)
    return table.concat(lines, C.MACRO_LINE_SEPARATOR)
end

-- Direct equip --------------------------------------------------------------------------
-- When combat starts with the pole on, the weapon is picked up from your bag and dropped
-- on your hand, as you would by hand. If the game refuses, the alert takes over.

function AutoEquip.CanEquip()
    return not (db and db.directEquipBlocked) and PickupContainerItem and PickupInventoryItem
        and ClearCursor and GetCursorInfo
end

function AutoEquip.Equip(itemID, slot)
    if not (itemID and AutoEquip.CanEquip()) then
        return false
    end
    if GetEquippedItemID(slot) == itemID then
        return true
    end
    local bag, bagSlot = Gear.FindInBags(itemID)
    if not bag then
        return false
    end
    AutoEquip.attemptAt = GetTime()
    ClearCursor()
    PickupContainerItem(bag, bagSlot)
    if GetCursorInfo() ~= C.CURSOR_ITEM then
        ClearCursor()
        return false
    end
    PickupInventoryItem(slot)
    ClearCursor()
    -- Refused on the drop: the item went back to the bag.
    return not db.directEquipBlocked
end

-- The game reported one of our actions as blocked right after trying: it doesn't allow
-- this here. Remembered, so the alert is used from now on.
function AutoEquip.OnActionBlocked(addonName)
    if addonName ~= ADDON_NAME or not AutoEquip.attemptAt
        or GetTime() - AutoEquip.attemptAt > C.DIRECT_EQUIP_BLOCK_WINDOW then
        return
    end
    AutoEquip.attemptAt = nil
    AutoEquip.offHand = nil
    AutoEquip.active = false
    if InCombatLockdown() then
        -- The main hand went on before combat locked; only the off hand was refused,
        -- so it isn't tried in later fights.
        if not AutoEquip.offHandBlocked then
            AutoEquip.offHandBlocked = true
            PrintMessage(L.AUTO_EQUIP_OFF_HAND_BLOCKED)
        end
        return
    end
    if db and not db.directEquipBlocked then
        db.directEquipBlocked = true
        PrintMessage(L.AUTO_EQUIP_BLOCKED)
    end
end

-- Combat starting with the pole on: put the weapon on right away.
function AutoEquip.StartForCombat()
    AutoEquip.offHand = nil
    AutoEquip.active = false
    if not (db and GetOption("combatAutoEquip") and IsPoleEquipped()) then
        return false
    end
    local weapons = db.weapons
    if not (weapons and weapons.mainHand) or not AutoEquip.Equip(weapons.mainHand, C.MAIN_HAND_SLOT) then
        return false
    end
    AutoEquip.offHand = weapons.offHand
    AutoEquip.active = true
    AutoEquip.startedAt = GetTime()
    return true
end

-- The main hand is back: the off hand follows (the two-handed pole had to leave first).
function AutoEquip.Continue()
    if not AutoEquip.active or IsPoleEquipped() then
        return
    end
    -- Only the swap started for this fight; a late or missed one is forgotten.
    if not AutoEquip.startedAt or GetTime() - AutoEquip.startedAt > C.AUTO_EQUIP_WINDOW_SECONDS then
        AutoEquip.active = false
        return
    end
    AutoEquip.active = false
    local offHand = AutoEquip.offHand
    AutoEquip.offHand = nil
    if offHand and not AutoEquip.offHandBlocked and GetEquippedItemID(C.OFF_HAND_SLOT) ~= offHand then
        AutoEquip.Equip(offHand, C.OFF_HAND_SLOT)
    end
    AutoEquip.armorPending = true
    PrintMessage(L.AUTO_EQUIP_DONE)
    Fx.ShowToast()
end

-- After that fight: your usual pieces back on (armor can't change in combat).
function AutoEquip.Finish()
    if InCombatLockdown() then
        return
    end
    AutoEquip.active = false
    AutoEquip.offHand = nil
    if not AutoEquip.armorPending then
        return
    end
    AutoEquip.armorPending = false
    if IsPoleEquipped() then
        return
    end
    for _, piece in ipairs(Gear.GetUsualToRestore()) do
        AutoEquip.Equip(piece.itemID, piece.slot)
    end
end

-- Action bar macros ---------------------------------------------------------------------

local function SaveMacro(name, icon, body)
    if InCombatLockdown() then
        PrintMessage(L.IN_COMBAT)
        return nil
    end
    local index = GetMacroIndex(name)
    if index then
        pcall(EditMacro, index, name, icon, body)
        return index
    end
    local numAccount, numCharacter = GetNumMacros()
    local perCharacter
    if (numAccount or 0) < (MAX_ACCOUNT_MACROS or C.DEFAULT_MAX_ACCOUNT_MACROS) then
        perCharacter = nil
    elseif (numCharacter or 0) < (MAX_CHARACTER_MACROS or C.DEFAULT_MAX_CHARACTER_MACROS) then
        perCharacter = true
    else
        PrintMessage(L.MACROS_FULL)
        return nil
    end
    local ok, created = pcall(CreateMacro, name, icon, body, perCharacter)
    if ok and created then
        return created
    end
    PrintMessage(L.MACRO_ERROR)
    return nil
end

-- Keeps already created macros up to date (never creates them on its own).
local function SyncMacro(name, icon, body)
    if InCombatLockdown() or not body then
        return
    end
    local index = GetMacroIndex(name)
    if index and GetMacroBody(index) ~= body then
        pcall(EditMacro, index, name, icon, body)
    end
end

local function SyncMacros()
    local fishBody = BuildFishingMacroText()
    local weaponBody = BuildWeaponMacroText(db and db.weapons)
    SyncMacro(C.MACRO_FISH_NAME, GetFishingIcon(), fishBody)
    SyncMacro(C.MACRO_WEAPON_NAME, GetWeaponIcon(), weaponBody)
    -- Macros made when this addon was PescaTodo keep their name (renaming a macro
    -- can move it in the macro list), but stay up to date.
    for _, legacyName in ipairs(C.LEGACY_FISH_MACRO_NAMES) do
        SyncMacro(legacyName, GetFishingIcon(), fishBody)
    end
    for _, legacyName in ipairs(C.LEGACY_WEAPON_MACRO_NAMES) do
        SyncMacro(legacyName, GetWeaponIcon(), weaponBody)
    end
end

local function PickUpFishingMacro()
    local index = SaveMacro(C.MACRO_FISH_NAME, GetFishingIcon(), BuildFishingMacroText())
    if index then
        PickupMacro(index)
    end
end

local function PickUpWeaponMacro()
    local body = BuildWeaponMacroText(db and db.weapons)
    if not body then
        PrintMessage(L.WEAPON_NONE)
        return
    end
    local index = SaveMacro(C.MACRO_WEAPON_NAME, GetWeaponIcon(), body)
    if index then
        PickupMacro(index)
    end
end

-- Secure buttons ---------------------------------------------------------------------

local function ConfigureSecureButton(button)
    button:RegisterForClicks(C.CLICK_REGISTRATION)
    -- /click, mouse and keys arrive as "release"; this avoids depending on the
    -- "Cast action keybinds on key down" option.
    button:SetAttribute(C.ATTR_USE_ON_KEY_DOWN, false)
end

local function SetFishingAction(button, actionType, value)
    button:SetAttribute(C.ATTR_TYPE, actionType)
    button:SetAttribute(C.ATTR_ITEM, actionType == C.ACTION_ITEM and value or nil)
    button:SetAttribute(C.ATTR_SPELL, actionType == C.ACTION_SPELL and value or nil)
    button:SetAttribute(C.ATTR_MACROTEXT, actionType == C.ACTION_MACRO and value or nil)
end

local function UpdateWeaponActions()
    if InCombatLockdown() then
        weaponUpdatePending = true
        return
    end
    weaponUpdatePending = false
    local body = BuildWeaponMacroText(db and db.weapons)
    for _, button in ipairs(weaponButtons) do
        SetFishingAction(button, body and C.ACTION_MACRO or nil, body)
    end
    SyncMacros()
    UpdateAlertDriver()
end

-- Decides what the next press does. Returns: type, value, chosen lure, chosen pole,
-- and why nothing happens (if so). For combat (forCombat) it never equips or lures.
local function DecideFishingAction(forCombat)
    if not IsPoleEquipped() then
        if forCombat then
            return nil
        end
        local poleID = FindFishingPoleInBags()
        if not poleID then
            return nil, nil, nil, nil, C.BLOCK_REASON.NO_POLE
        end
        -- The 2H pole sends the off-hand item to your bags.
        if GetEquippedItemID(C.OFF_HAND_SLOT) and GetFreeBagSlots() == 0 then
            return nil, nil, nil, nil, C.BLOCK_REASON.BAGS_FULL_FOR_POLE
        end
        -- The item action equips the pole.
        return C.ACTION_ITEM, C.ITEM_LINK_PREFIX .. poleID, nil, poleID
    end
    if not forCombat then
        CheckPendingLure()
        -- A lure just used is still being applied: fish instead of using another.
        if not pendingLure and GetOption("useLures") then
            -- If detection fails, fish: better than wasting a lure.
            local ok, hasLure = pcall(GetLureState)
            local lureID = ok and not hasLure and FindBestLure()
            if lureID then
                return C.ACTION_ITEM, C.ITEM_LINK_PREFIX .. lureID, lureID
            end
        end
        if GetFreeBagSlots() == 0 then
            return nil, nil, nil, nil, C.BLOCK_REASON.BAGS_FULL
        end
    end
    return C.ACTION_SPELL, GetFishingSpellName()
end

local BLOCK_MESSAGES = {
    [C.BLOCK_REASON.NO_POLE] = "NO_POLE",
    [C.BLOCK_REASON.BAGS_FULL] = "BAGS_FULL",
    [C.BLOCK_REASON.BAGS_FULL_FOR_POLE] = "BAGS_FULL_FOR_POLE",
}

-- The pole with your fishing gear, for a press that comes straight from a key or a
-- click (a macro can't run another button's macro text, so the bar macro carries
-- the gear lines itself).
function Gear.BuildPoleAndGearText(poleID)
    local gear = Gear.GetEquipLines()
    if #gear == 0 then
        return nil
    end
    local lines = { C.EQUIP_SLOT_LINE:format(C.MAIN_HAND_SLOT, poleID) }
    for _, line in ipairs(gear) do
        table.insert(lines, line)
    end
    return table.concat(lines, C.MACRO_LINE_SEPARATOR)
end

local function PrepareFishingClick(button, mouseButton)
    -- In combat the action can't change; the one prepared on entering combat is used.
    if InCombatLockdown() or not db then
        return
    end
    if IsFishingChannelActive() then
        -- With the bobber out a click can't reel in (only a key can), and recasting
        -- would lose the bite: do nothing.
        SetFishingAction(button, nil)
        return
    end
    if reelKeysActive then
        SetReelKeys(false)
    end
    local actionType, value, lureID, poleID, blockReason = DecideFishingAction(false)
    if poleID then
        if RememberCurrentWeapons() then
            UpdateWeaponActions()
        end
        Gear.RememberUsual()
        db.lastPoleID = poleID
        local poleAndGear = button.directPresses and mouseButton ~= C.BAR_CLICK_BUTTON and Gear.BuildPoleAndGearText(poleID)
        if poleAndGear then
            actionType, value = C.ACTION_MACRO, poleAndGear
        end
    end
    if lureID then
        StartPendingLure(lureID)
    end
    if blockReason then
        PrintMessage(L[BLOCK_MESSAGES[blockReason]])
    end
    SetFishingAction(button, actionType, value)
end

-- On entering combat: with the pole on and a saved weapon, Fish gives the weapon
-- back; with the pole on and none saved, it fishes; without the pole, it does nothing.
local function PrepareCombatFishing(button)
    local weaponBody = GetOption("combatWeaponSwap") and IsPoleEquipped() and BuildWeaponMacroText(db and db.weapons)
    if weaponBody then
        SetFishingAction(button, C.ACTION_MACRO, weaponBody)
    else
        local actionType, value = DecideFishingAction(true)
        SetFishingAction(button, actionType, value)
    end
end

-- directPresses: the button is pressed with a key or a click (not only from macros),
-- so its first press can put on the pole and the fishing gear together.
local function CreateFishingButton(name, parent, directPresses)
    local button = CreateFrame("Button", name, parent, C.SECURE_TEMPLATE)
    button.directPresses = directPresses
    table.insert(fishingButtons, button)
    ConfigureSecureButton(button)
    -- When the action is a lure, the game applies it to the equipped pole.
    button:SetAttribute(C.ATTR_TARGET_SLOT, C.MAIN_HAND_SLOT)
    button:SetScript("PreClick", PrepareFishingClick)
    return button
end

local function CreateWeaponButton(name, parent)
    local button = CreateFrame("Button", name, parent, C.SECURE_TEMPLATE)
    table.insert(weaponButtons, button)
    ConfigureSecureButton(button)
    return button
end

-- Hidden buttons for the action bar macro and the key bindings, plus the old
-- button names so macros made with earlier versions keep working.
CreateFishingButton(C.MACRO_BUTTON_NAME, nil, true)
for _, legacyName in ipairs(C.LEGACY_FISH_BUTTON_NAMES) do
    CreateFishingButton(legacyName, nil)
end
CreateWeaponButton(C.HIDDEN_WEAPON_BUTTON_NAME, nil)

-- Language -------------------------------------------------------------------------
-- English by default, whatever the game's language is. Other languages are used
-- only when chosen with /fishful language (or "auto" = the game's language).

local function ResolveLanguage(setting)
    if setting == C.LANGUAGE_AUTO then
        return GetLocale()
    end
    return setting or C.DEFAULT_LANGUAGE
end

local function SetBindingNames()
    _G["BINDING_NAME_" .. C.FISH_BINDING_COMMAND] = C.BINDING_NAME_FORMAT:format(L.TITLE, L.BINDING_FISH)
    _G["BINDING_NAME_" .. C.WEAPON_BINDING_COMMAND] = C.BINDING_NAME_FORMAT:format(L.TITLE, L.BINDING_WEAPON)
end

local function ApplyLanguage()
    local code = ResolveLanguage(accountDB and accountDB.language)
    for key in pairs(L) do
        L[key] = nil
    end
    for key, text in pairs(ns.LOCALE_BASE) do
        L[key] = text
    end
    local overrides = ns.LOCALES[code]
    if overrides then
        for key, text in pairs(overrides) do
            L[key] = text
        end
        activeLanguage = code
    else
        activeLanguage = C.DEFAULT_LANGUAGE
    end
    SetBindingNames()
end

local function DescribeLanguageSetting()
    if accountDB and accountDB.language == C.LANGUAGE_AUTO then
        return L.LANGUAGE_AUTO_NAME
    end
    return C.LANGUAGE_NAMES[activeLanguage] or activeLanguage
end

SetBindingNames()

-- Panel: the fishing HUD ---------------------------------------------------------------
-- The game's own look: action-button style Fish and Weapon buttons with their keys, the
-- bobber's state, a lure bar with the time left, your Fishing skill and how this water
-- treats you. It shows while you hold the pole and slides in when it appears.

local function GetStatusText()
    if not IsPoleEquipped() then
        return L.STATUS_POLE_STOWED
    end
    if IsFishingChannelActive() then
        if reelKeysText then
            return L.STATUS_REEL_WITH:format(reelKeysText)
        end
        return L.STATUS_FISHING
    end
    local ok, hasLure, seconds = pcall(GetLureState)
    if ok and hasLure then
        if seconds then
            return L.STATUS_LURE_MINUTES:format(math.ceil(seconds / C.SECONDS_PER_MINUTE))
        end
        return L.STATUS_LURE_ACTIVE
    end
    if FindBestLure() then
        return L.STATUS_NO_LURE
    end
    return L.STATUS_NO_LURES_LEFT
end

local function GetWeaponNames()
    local weapons = db and db.weapons
    if not (weapons and weapons.mainHand) then
        return nil
    end
    local names = {}
    for _, itemID in ipairs({ weapons.mainHand, weapons.offHand }) do
        table.insert(names, GetItemName(itemID) or (C.ITEM_LINK_PREFIX .. itemID))
    end
    return table.concat(names, L.WEAPON_SEPARATOR)
end

local function ShowTooltip(owner, title, lines)
    GameTooltip:SetOwner(owner, C.TOOLTIP_ANCHOR)
    GameTooltip:SetText(title)
    local r, g, b = unpack(C.COLORS.TOOLTIP_TEXT)
    for _, line in ipairs(lines) do
        GameTooltip:AddLine(line, r, g, b, true)
    end
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

function Hud.Clock(seconds)
    seconds = math.max(0, math.floor(seconds))
    return C.HUD_CLOCK_FORMAT:format(math.floor(seconds / C.SECONDS_PER_MINUTE), seconds % C.SECONDS_PER_MINUTE)
end

-- "SHIFT-F" -> "s-F", like the action bars.
function Hud.ShortKey(key)
    local text = key
    for _, pair in ipairs(C.HOTKEY_ABBREVIATIONS) do
        text = text:gsub(pair[1], pair[2])
    end
    return text
end

-- Fishing skill and its bonus (lure, gear, food): (rank, bonus) or nil.
function Hud.GetFishingSkill()
    if GetProfessions and GetProfessionInfo then
        local ok, _, _, _, fishing = pcall(GetProfessions)
        if ok and fishing then
            local okInfo, _, _, rank, _, _, _, _, bonus = pcall(GetProfessionInfo, fishing)
            if okInfo and type(rank) == "number" and not IsSecret(rank) then
                return rank, tonumber(bonus) or 0
            end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        local fishingName = GetFishingSpellName()
        for index = 1, GetNumSkillLines() or 0 do
            local ok, name, isHeader, _, rank, _, bonus = pcall(GetSkillLineInfo, index)
            if ok and not isHeader and name == fishingName and type(rank) == "number" then
                return rank, tonumber(bonus) or 0
            end
        end
    end
end

-- An action-button look for a secure button: slot frame, icon, pushed and highlight
-- states, its key in the corner and a golden glow that can pulse.
function Hud.StyleActionButton(button)
    local style = C.HUD
    local size = style.BUTTON_SIZE
    button:SetSize(size, size)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.icon:SetTexCoord(unpack(style.ICON_TEXCOORD))
    local slot = button:CreateTexture(nil, "OVERLAY")
    slot:SetTexture(style.SLOT_TEXTURE)
    slot:SetSize(size * style.SLOT_SCALE, size * style.SLOT_SCALE)
    slot:SetPoint("CENTER")
    button:SetHighlightTexture(C.TEXTURES.HIGHLIGHT, C.BLEND_ADD)
    button:SetPushedTexture(C.TEXTURES.PUSHED)
    button.hotkey = button:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_HOTKEY)
    button.hotkey:SetPoint("TOPRIGHT", button, "TOPRIGHT", style.HOTKEY_OFFSET_X, style.HOTKEY_OFFSET_Y)

    local glow = button:CreateTexture(nil, "OVERLAY", nil, 1)
    glow:SetTexture(style.GLOW_TEXTURE)
    glow:SetBlendMode(C.BLEND_ADD)
    glow:SetVertexColor(unpack(C.COLORS.HUD_GLOW))
    glow:SetSize(size * style.GLOW_SCALE, size * style.GLOW_SCALE)
    glow:SetPoint("CENTER")
    glow:Hide()
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(style.PULSE_MIN_ALPHA)
    fade:SetDuration(style.PULSE_SECONDS)
    button.glow, button.pulse = glow, pulse
end

function Hud.SetGlow(button, on)
    if on and not button.glow:IsShown() then
        button.glow:Show()
        button.pulse:Play()
    elseif not on and button.glow:IsShown() then
        button.pulse:Stop()
        button.glow:Hide()
    end
end

-- A small square button in the header, with a tooltip.
function Hud.CreateIconButton(parent, texture, title, tip, onClick)
    local style = C.HUD
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(style.ICON_BUTTON_SIZE, style.ICON_BUTTON_SIZE)
    button:SetNormalTexture(texture)
    local normal = button.GetNormalTexture and button:GetNormalTexture()
    if normal and normal.SetTexCoord then
        normal:SetTexCoord(unpack(style.ICON_TEXCOORD))
    end
    button:SetHighlightTexture(C.TEXTURES.HIGHLIGHT, C.BLEND_ADD)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        ShowTooltip(self, title, { tip })
    end)
    button:SetScript("OnLeave", HideTooltip)
    return button
end

-- The shortest of these keys, written short ("s-F", "M3"), or "".
function Hud.FirstKey(keys)
    local list = {}
    for key in pairs(keys) do
        table.insert(list, key)
    end
    table.sort(list, function(a, b) return #a < #b or (#a == #b and a < b) end)
    return list[1] and Hud.ShortKey(list[1]) or ""
end

-- Keys that press Fish or Weapon, shortened, for the corner of each button.
function Hud.RefreshHotkeys()
    if not panel then
        return
    end
    local okFish, fishKeys = pcall(CollectFishingKeys)
    panelFishButton.hotkey:SetText(okFish and Hud.FirstKey(fishKeys) or "")
    local weaponKeys = {}
    AddBindingKeys(weaponKeys, C.WEAPON_BINDING_COMMAND)
    panelWeaponButton.hotkey:SetText(Hud.FirstKey(weaponKeys))
end

-- The lure bar: time left against the lure's full time.
function Hud.RefreshLureBar()
    local bar = Hud.lureBar
    local ok, hasLure, seconds = pcall(GetLureState)
    if ok and hasLure then
        local total = math.max(seconds or 0, db.lureFullSeconds or C.HUD.DEFAULT_LURE_SECONDS)
        bar:SetMinMaxValues(0, total)
        bar:SetValue(seconds or total)
        bar.left:SetText(L.HUD_LURE)
        bar.right:SetText(seconds and Hud.Clock(seconds) or "")
        bar.shimmerGroup:Play()
    else
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        local bestLure = FindBestLure()
        bar.left:SetText(L.HUD_NO_LURE)
        bar.right:SetText(bestLure and L.HUD_LURES_LEFT:format(GetItemCount(bestLure) or 0) or L.STATUS_NO_LURES_LEFT)
        bar.shimmerGroup:Stop()
    end
end

function Hud.RefreshStatus()
    local fishing = IsFishingChannelActive()
    local justCaught = not fishing and GetTime() - (Hud.caughtAt or 0) < C.HUD.CAUGHT_SECONDS
    local title, sub
    if not IsPoleEquipped() then
        title, sub = L.STATUS_POLE_STOWED, L.HUD_SUB_EQUIP
    elseif fishing then
        title = L.STATUS_FISHING
        sub = reelKeysText and L.STATUS_REEL_WITH:format(reelKeysText) or ""
    elseif justCaught then
        title, sub = L.HUD_CAUGHT, L.HUD_RECAST
    else
        local okLure, hasLure = pcall(GetLureState)
        local needsLure = GetOption("useLures") and not (okLure and hasLure) and FindBestLure()
        title, sub = L.HUD_READY, needsLure and L.HUD_SUB_LURE_CAST or L.HUD_SUB_CAST
    end
    Hud.statusTitle:SetText(title)
    Hud.statusSub:SetText(sub)
    Hud.SetGlow(panelFishButton, fishing)
    Hud.ripple:SetShown(fishing)

    local rank, bonus = Hud.GetFishingSkill()
    if rank then
        Hud.skillText:SetText(bonus > 0 and L.HUD_SKILL_BONUS:format(rank, bonus) or L.HUD_SKILL:format(rank))
    else
        Hud.skillText:SetText("")
    end
    local zone = GetRealZoneText and GetRealZoneText()
    if type(zone) == "string" and Hints.escapeZones[zone] then
        Hud.zoneText:SetText(L.HUD_ZONE_ESCAPES)
        Hud.zoneText:SetTextColor(unpack(C.COLORS.HUD_BAD))
    elseif type(zone) == "string" and (Hints.zoneCatches[zone] or 0) > 0 then
        Hud.zoneText:SetText(L.HUD_ZONE_OK)
        Hud.zoneText:SetTextColor(unpack(C.COLORS.HUD_GOOD))
    else
        Hud.zoneText:SetText("")
    end
end

local function RefreshPanel()
    if not (panel and panel:IsShown()) then
        return
    end
    panelFishButton.icon:SetTexture(GetFishingIcon())
    local weapons = db.weapons
    local mainHand = weapons and weapons.mainHand
    panelWeaponButton.icon:SetTexture(GetWeaponIcon())
    local alreadyEquipped = mainHand and GetEquippedItemID(C.MAIN_HAND_SLOT) == mainHand
    panelWeaponButton.icon:SetDesaturated(not mainHand or alreadyEquipped)
    Hud.RefreshStatus()
    Hud.RefreshLureBar()
end

-- "+1 Raw Redgill" rises over the HUD and fades.
function Hud.ShowCatch(itemID, count)
    Hud.caughtAt = GetTime()
    if not (panel and panel:IsShown()) then
        return
    end
    local float = Hud.catchFloat
    float.icon:SetTexture(GetItemIcon(itemID))
    float.text:SetText(L.HUD_CATCH:format(count or 1, GetItemName(itemID) or (C.ITEM_LINK_PREFIX .. itemID)))
    float:Show()
    float.anim:Stop()
    float.anim:Play()
    RefreshPanel()
end

local function SavePanelPosition()
    local point, _, relativePoint, x, y = panel:GetPoint()
    db.panel = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function RestorePanelPosition()
    local saved = db.panel
    local layout = C.LAYOUT
    panel:ClearAllPoints()
    if saved and saved.point then
        panel:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
    else
        panel:SetPoint(layout.DEFAULT_POINT, UIParent, layout.DEFAULT_POINT, layout.DEFAULT_X, layout.DEFAULT_Y)
    end
end

local function SetPanelShown(shown)
    if not panel then
        return
    end
    if InCombatLockdown() then
        PrintMessage(L.IN_COMBAT)
        return
    end
    db.options.showPanel = shown and true or false
    -- Asked for by hand without the pole: shown until the pole goes on or off.
    Hud.peek = shown and not IsPoleEquipped()
    Hud.ApplyVisibility()
    RefreshOptions()
end

local function ResetPanelPosition()
    if InCombatLockdown() or not panel then
        PrintMessage(L.IN_COMBAT)
        return
    end
    db.panel = nil
    RestorePanelPosition()
    SetPanelShown(true)
    PrintMessage(L.RESET_DONE)
end

local function TogglePanel()
    if panel then
        SetPanelShown(not panel:IsShown())
    end
end

function Hud.CreateLureBar(parent)
    local style = C.HUD
    local holder = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and C.BACKDROP_TEMPLATE or nil)
    holder:SetHeight(style.BAR_HEIGHT)
    if holder.SetBackdrop then
        holder:SetBackdrop(style.BAR_BORDER)
        holder:SetBackdropBorderColor(unpack(C.COLORS.HUD_BORDER))
    end
    local bar = CreateFrame("StatusBar", nil, holder)
    bar:SetPoint("TOPLEFT", style.BAR_INSET, -style.BAR_INSET)
    bar:SetPoint("BOTTOMRIGHT", -style.BAR_INSET, style.BAR_INSET)
    bar:SetStatusBarTexture(style.BAR_TEXTURE)
    bar:SetStatusBarColor(unpack(C.COLORS.HUD_BAR))
    local back = bar:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(unpack(C.COLORS.HUD_BAR_BACK))
    if bar.SetClipsChildren then
        bar:SetClipsChildren(true)
    end
    -- A soft light sweeps across while a lure is on.
    local shimmer = bar:CreateTexture(nil, "OVERLAY")
    shimmer:SetColorTexture(1, 1, 1, style.SHIMMER_ALPHA)
    shimmer:SetBlendMode(C.BLEND_ADD)
    shimmer:SetPoint("TOP")
    shimmer:SetPoint("BOTTOM")
    shimmer:SetWidth((style.WIDTH - style.PADDING * 2) * style.SHIMMER_WIDTH)
    shimmer:SetPoint("RIGHT", bar, "LEFT")
    local group = shimmer:CreateAnimationGroup()
    group:SetLooping("REPEAT")
    local move = group:CreateAnimation("Translation")
    move:SetOffset(style.WIDTH * (1 + style.SHIMMER_WIDTH), 0)
    move:SetDuration(style.SHIMMER_SECONDS)
    bar.shimmerGroup = group
    bar.left = bar:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_BAR)
    bar.left:SetPoint("LEFT", style.BAR_TEXT_INSET, 0)
    bar.right = bar:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_BAR)
    bar.right:SetPoint("RIGHT", -style.BAR_TEXT_INSET, 0)
    return holder, bar
end

local function CreatePanel()
    local style = C.HUD
    local width = style.WIDTH
    local height = style.PADDING * 2 + style.HEADER_HEIGHT + style.ROW_GAP + style.BUTTON_SIZE
        + style.ROW_GAP + style.BAR_HEIGHT + style.ROW_GAP + style.FOOTER_HEIGHT

    panel = CreateFrame("Frame", C.PANEL_NAME, UIParent, BackdropTemplateMixin and C.BACKDROP_TEMPLATE or nil)
    panel:SetSize(width, height)
    if panel.SetBackdrop then
        panel:SetBackdrop(C.BACKDROP)
        panel:SetBackdropColor(unpack(C.COLORS.HUD_BACKGROUND))
        panel:SetBackdropBorderColor(unpack(C.COLORS.HUD_BORDER))
    end
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag(C.DRAG_BUTTON)
    panel:SetScript("OnDragStart", function(self)
        if not InCombatLockdown() then
            self:StartMoving()
        end
    end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePanelPosition()
    end)

    -- Header: icon, name, and buttons for the catch value, the options and closing.
    -- Everything sits on one line, centred, inside the border.
    local headerY = -(style.PADDING + style.HEADER_HEIGHT / 2)
    local logo = panel:CreateTexture(nil, "ARTWORK")
    logo:SetSize(style.LOGO_SIZE, style.LOGO_SIZE)
    logo:SetPoint("LEFT", panel, "TOPLEFT", style.PADDING, headerY)
    logo:SetTexture(C.MINIMAP_ICON)
    logo:SetTexCoord(unpack(style.ICON_TEXCOORD))

    local hasClose, close = pcall(CreateFrame, "Button", nil, panel, C.CLOSE_BUTTON_TEMPLATE)
    local rightmost
    if hasClose and close then
        close:SetSize(style.ICON_BUTTON_SIZE, style.ICON_BUTTON_SIZE)
        close:SetPoint("RIGHT", panel, "TOPRIGHT", -style.PADDING, headerY)
        close:SetScript("OnClick", function()
            SetPanelShown(false)
        end)
        rightmost = close
    end
    local optionsButton = Hud.CreateIconButton(panel, style.OPTIONS_ICON, L.HUD_OPTIONS, L.HUD_OPTIONS_TIP, function()
        OpenOptions()
    end)
    if rightmost then
        optionsButton:SetPoint("RIGHT", rightmost, "LEFT", -style.ICON_BUTTON_GAP, 0)
    else
        optionsButton:SetPoint("RIGHT", panel, "TOPRIGHT", -style.PADDING, headerY)
    end
    local valueButton = Hud.CreateIconButton(panel, C.VALUE.ICON, L.VALUE_TITLE, L.VALUE_BUTTON_TIP, function()
        Value.Toggle()
    end)
    valueButton:SetPoint("RIGHT", optionsButton, "LEFT", -style.ICON_BUTTON_GAP, 0)

    local title = panel:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_TITLE)
    title:SetPoint("LEFT", logo, "RIGHT", style.TEXT_GAP * 2, 0)
    title:SetPoint("RIGHT", valueButton, "LEFT", -style.TEXT_GAP * 2, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(L.TITLE)

    -- A thin line between the header and the rest.
    local dividerY = -(style.PADDING + style.HEADER_HEIGHT + style.ROW_GAP / 2)
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(C.COLORS.HUD_DIVIDER))
    divider:SetHeight(style.DIVIDER_HEIGHT)
    divider:SetPoint("TOPLEFT", panel, "TOPLEFT", style.PADDING, dividerY)
    divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -style.PADDING, dividerY)

    -- Buttons, then the bobber's state.
    local rowTop = -(style.PADDING + style.HEADER_HEIGHT + style.ROW_GAP)
    panelFishButton = CreateFishingButton(C.PANEL_FISH_BUTTON_NAME, panel, true)
    Hud.StyleActionButton(panelFishButton)
    panelFishButton:SetPoint("TOPLEFT", style.PADDING, rowTop)
    panelFishButton:RegisterForDrag(C.DRAG_BUTTON)
    panelFishButton:SetScript("OnDragStart", PickUpFishingMacro)
    panelFishButton:SetScript("OnEnter", function(self)
        ShowTooltip(self, L.FISH_LABEL,
            { L.FISH_TOOLTIP, L.FISH_TOOLTIP_DRAG, L.FISH_TOOLTIP_COMBAT, GetStatusText() })
    end)
    panelFishButton:SetScript("OnLeave", HideTooltip)
    panelFishButton:SetScript("PostClick", RefreshPanel)

    panelWeaponButton = CreateWeaponButton(C.PANEL_WEAPON_BUTTON_NAME, panel)
    Hud.StyleActionButton(panelWeaponButton)
    panelWeaponButton:SetPoint("LEFT", panelFishButton, "RIGHT", style.BUTTON_GAP, 0)
    panelWeaponButton:RegisterForDrag(C.DRAG_BUTTON)
    panelWeaponButton:SetScript("OnDragStart", PickUpWeaponMacro)
    panelWeaponButton:SetScript("OnEnter", function(self)
        ShowTooltip(self, L.WEAPON_LABEL,
            { L.WEAPON_TOOLTIP, L.WEAPON_TOOLTIP_DRAG, GetWeaponNames() or L.WEAPON_NONE })
    end)
    panelWeaponButton:SetScript("OnLeave", HideTooltip)
    panelWeaponButton:SetScript("PostClick", RefreshPanel)

    -- The state, two lines centred on the buttons: title above the middle, hint below.
    Hud.statusTitle = panel:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_STATUS)
    Hud.statusTitle:SetPoint("BOTTOMLEFT", panelWeaponButton, "RIGHT", style.STATUS_GAP, style.TEXT_GAP)
    Hud.statusTitle:SetJustifyH("LEFT")
    Hud.statusTitle:SetWordWrap(false)
    Hud.statusSub = panel:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_SUB)
    Hud.statusSub:SetPoint("TOPLEFT", panelWeaponButton, "RIGHT", style.STATUS_GAP, -style.TEXT_GAP)
    Hud.statusSub:SetPoint("RIGHT", panel, "RIGHT", -style.PADDING, 0)
    Hud.statusSub:SetJustifyH("LEFT")

    -- The bobber: a red dot with ripples right after the title while the line is out.
    local ripple = CreateFrame("Frame", nil, panel)
    ripple:SetSize(style.RIPPLE_SIZE, style.RIPPLE_SIZE)
    ripple:SetPoint("LEFT", Hud.statusTitle, "RIGHT", style.TEXT_GAP * 2, 0)
    local dot = ripple:CreateTexture(nil, "OVERLAY")
    dot:SetTexture(style.DOT_TEXTURE)
    dot:SetAllPoints()
    local wave = ripple:CreateTexture(nil, "ARTWORK")
    wave:SetTexture(style.RIPPLE_TEXTURE)
    wave:SetAllPoints()
    local waves = wave:CreateAnimationGroup()
    waves:SetLooping("REPEAT")
    local grow = waves:CreateAnimation("Scale")
    if grow.SetScaleFrom then
        grow:SetScaleFrom(1, 1)
        grow:SetScaleTo(style.RIPPLE_SCALE, style.RIPPLE_SCALE)
    elseif grow.SetScale then
        grow:SetScale(style.RIPPLE_SCALE, style.RIPPLE_SCALE)
    end
    grow:SetDuration(style.RIPPLE_SECONDS)
    local fadeOut = waves:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(style.RIPPLE_SECONDS)
    ripple:SetScript("OnShow", function() waves:Play() end)
    ripple:SetScript("OnHide", function() waves:Stop() end)
    ripple:Hide()
    Hud.ripple = ripple

    -- The lure bar.
    local barHolder, bar = Hud.CreateLureBar(panel)
    barHolder:SetPoint("TOPLEFT", panelFishButton, "BOTTOMLEFT", 0, -style.ROW_GAP)
    barHolder:SetPoint("RIGHT", panel, "RIGHT", -style.PADDING, 0)
    Hud.lureBar = bar

    -- Footer: Fishing skill, and how this water treats you.
    Hud.skillText = panel:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_FOOTER)
    Hud.skillText:SetPoint("TOPLEFT", barHolder, "BOTTOMLEFT", 0, -style.ROW_GAP)
    Hud.zoneText = panel:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_FOOTER)
    Hud.zoneText:SetPoint("TOPRIGHT", barHolder, "BOTTOMRIGHT", 0, -style.ROW_GAP)

    -- What you just caught rises and fades.
    local float = CreateFrame("Frame", nil, panel)
    float:SetSize(width, style.CATCH_ICON_SIZE)
    float:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", style.PADDING, style.TEXT_GAP)
    float.icon = float:CreateTexture(nil, "ARTWORK")
    float.icon:SetSize(style.CATCH_ICON_SIZE, style.CATCH_ICON_SIZE)
    float.icon:SetPoint("LEFT")
    float.text = float:CreateFontString(nil, "OVERLAY", C.FONTS.HUD_CATCH)
    float.text:SetPoint("LEFT", float.icon, "RIGHT", style.TEXT_GAP * 2, 0)
    float.anim = float:CreateAnimationGroup()
    local rise = float.anim:CreateAnimation("Translation")
    rise:SetOffset(0, style.CATCH_RISE)
    rise:SetDuration(style.CATCH_SECONDS)
    local vanish = float.anim:CreateAnimation("Alpha")
    vanish:SetFromAlpha(1)
    vanish:SetToAlpha(0)
    vanish:SetStartDelay(style.CATCH_SECONDS / 2)
    vanish:SetDuration(style.CATCH_SECONDS / 2)
    float.anim:SetScript("OnFinished", function() float:Hide() end)
    float:Hide()
    Hud.catchFloat = float

    -- It slides in and fades in whenever it appears.
    local appear = panel:CreateAnimationGroup()
    local drop = appear:CreateAnimation("Translation")
    drop:SetOffset(0, -style.APPEAR_OFFSET)
    drop:SetDuration(0)
    drop:SetOrder(1)
    local slide = appear:CreateAnimation("Translation")
    slide:SetOffset(0, style.APPEAR_OFFSET)
    slide:SetDuration(style.APPEAR_SECONDS)
    slide:SetOrder(2)
    local fadeIn = appear:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(style.APPEAR_SECONDS)
    fadeIn:SetOrder(2)
    Hud.appear = appear

    panel:SetScript("OnShow", function()
        Hud.appear:Play()
        Hud.RefreshHotkeys()
        RefreshPanel()
        if not statusTicker then
            statusTicker = C_Timer.NewTicker(style.REFRESH_SECONDS, RefreshPanel)
        end
    end)
    panel:SetScript("OnHide", function()
        if statusTicker then
            statusTicker:Cancel()
            statusTicker = nil
        end
    end)
    -- Created hidden so showing it fires OnShow and starts the refresh.
    panel:Hide()
end

-- Minimap button ---------------------------------------------------------------------

local function PlaceMinimapButton()
    local radius = Minimap:GetWidth() / 2 + C.MINIMAP.RADIUS_OFFSET
    local angle = math.rad(db.minimapAngle or C.MINIMAP.DEFAULT_ANGLE)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function FollowCursorAroundMinimap()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    db.minimapAngle = math.deg(Atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    PlaceMinimapButton()
end

local function CreateMinimapButton()
    if not Minimap then
        return
    end
    local style = C.MINIMAP
    minimapButton = CreateFrame("Button", C.MINIMAP_BUTTON_NAME, Minimap)
    minimapButton:SetSize(style.SIZE, style.SIZE)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(style.FRAME_LEVEL)
    minimapButton:SetHighlightTexture(style.HIGHLIGHT_TEXTURE)
    minimapButton:RegisterForClicks(C.CLICK_REGISTRATION)
    minimapButton:RegisterForDrag(C.DRAG_BUTTON)

    local background = minimapButton:CreateTexture(nil, "BACKGROUND")
    background:SetTexture(style.BACKGROUND_TEXTURE)
    background:SetSize(style.BACKGROUND_SIZE, style.BACKGROUND_SIZE)
    background:SetPoint("TOPLEFT", style.ICON_OFFSET_X, style.BACKGROUND_OFFSET_Y)

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(C.MINIMAP_ICON)
    icon:SetSize(style.ICON_SIZE, style.ICON_SIZE)
    icon:SetPoint("TOPLEFT", style.ICON_OFFSET_X, style.ICON_OFFSET_Y)

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture(style.BORDER_TEXTURE)
    border:SetSize(style.BORDER_SIZE, style.BORDER_SIZE)
    border:SetPoint("TOPLEFT")

    minimapButton:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == C.RIGHT_BUTTON then
            OpenOptions()
        else
            TogglePanel()
        end
    end)
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", FollowCursorAroundMinimap)
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    minimapButton:SetScript("OnEnter", function(self)
        ShowTooltip(self, L.TITLE,
            { L.MINIMAP_TOOLTIP_CLICK, L.MINIMAP_TOOLTIP_RIGHT, L.MINIMAP_TOOLTIP_DRAG, GetStatusText() })
    end)
    minimapButton:SetScript("OnLeave", HideTooltip)

    PlaceMinimapButton()
    minimapButton:SetShown(GetOption("showMinimapButton"))
end

-- For the AddOns menu next to the minimap, when the client has one (see .toc).
function FishfulThinking_OnAddonCompartmentClick(_, mouseButton)
    if mouseButton == C.RIGHT_BUTTON then
        OpenOptions()
    else
        TogglePanel()
    end
end

-- Combat alert -------------------------------------------------------------------------
-- When combat starts with the pole on, a card with your weapon appears (with a sound).
-- Addons can't show or hide secure buttons in combat, but the game's own state driver
-- can: it shows the alert only while you are in combat holding a pole, so it
-- disappears the moment your weapon is back.

local function SaveAlertPosition()
    local point, _, relativePoint, x, y = alertButton:GetPoint()
    db.alertPosition = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function RestoreAlertPosition()
    local saved = db.alertPosition
    local style = C.ALERT
    alertButton:ClearAllPoints()
    if saved and saved.point then
        alertButton:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
    else
        alertButton:SetPoint(style.DEFAULT_POINT, UIParent, style.DEFAULT_POINT, style.DEFAULT_X, style.DEFAULT_Y)
    end
end

local function PlayAlertSound()
    if not GetOption("combatAlertSound") or not PlaySound then
        return
    end
    local soundKit = SOUNDKIT and SOUNDKIT[C.ALERT.SOUND_KIT]
    pcall(PlaySound, soundKit or C.ALERT.SOUND_FALLBACK_ID)
end

-- The game's name for fishing poles, as [equipped:...] uses it. Nil when it can't be
-- read safely, the client has no state drivers, or the check below failed.
local function GetPoleTypeName()
    if alertDriverUnsupported or not (GetItemSubClassInfo and RegisterStateDriver and UnregisterStateDriver) then
        return nil
    end
    local ok, poleTypeName = pcall(GetItemSubClassInfo, C.WEAPON_ITEM_CLASS, C.FISHING_POLE_SUBCLASS)
    if not ok or type(poleTypeName) ~= "string" or IsSecret(poleTypeName) or poleTypeName == ""
        or poleTypeName:find(C.ALERT.CONDITION_UNSAFE_PATTERN) then
        return nil
    end
    return poleTypeName
end

-- "[combat,equipped:Fishing Poles] show; hide", with the name in the game's language.
-- Nil means no driver: then the alert dims instead of hiding.
local function GetAlertCondition()
    local poleTypeName = GetPoleTypeName()
    return poleTypeName and C.ALERT.VISIBILITY_CONDITION:format(poleTypeName)
end

-- With the pole in your hands: does the game's own check see it under that name?
local function PoleConditionMatches()
    local poleTypeName = GetPoleTypeName()
    if not (poleTypeName and SecureCmdOptionParse) then
        return poleTypeName ~= nil
    end
    local ok, result = pcall(SecureCmdOptionParse, C.ALERT.EQUIPPED_CHECK:format(poleTypeName))
    return ok and result == C.ALERT.EQUIPPED_CHECK_YES
end

-- The HUD shows while you hold the pole, through the same secure driver as the alert,
-- so it also appears and hides in combat. Without the option, or asked for by hand
-- without the pole, it simply shows.
-- verify: equipment has settled, so the game's own check on the pole can be trusted
-- (right after loading it may not see your gear yet).
function Hud.ApplyVisibility(verify)
    if not panel then
        return
    end
    if InCombatLockdown() then
        Hud.visibilityPending = true
        return
    end
    Hud.visibilityPending = false
    local poleTypeName = GetPoleTypeName()
    if verify and poleTypeName and IsPoleEquipped() and not PoleConditionMatches() then
        -- The game's check doesn't see the pole under that name: no driver.
        alertDriverUnsupported = true
        poleTypeName = nil
    end
    if GetOption("showPanel") and GetOption("hudWithPole") and not Hud.peek and poleTypeName then
        local condition = C.HUD.VISIBILITY_CONDITION:format(poleTypeName)
        if not (Hud.driverActive and Hud.driverCondition == condition) then
            RegisterStateDriver(panel, C.HUD.VISIBILITY_STATE, condition)
            Hud.driverActive, Hud.driverCondition = true, condition
        end
        return
    end
    if Hud.driverActive then
        UnregisterStateDriver(panel, C.HUD.VISIBILITY_STATE)
        Hud.driverActive, Hud.driverCondition = false, nil
    end
    panel:SetShown(GetOption("showPanel") and true or false)
end

-- Grows a region by this much over the animation, on top of what the steps before
-- did (so steps chain: 0.6, then x1.8 = 1.08, then back to 1).
function Fx.Scale(anim, ratio)
    if anim.SetScale then
        anim:SetScale(ratio, ratio)
    elseif anim.SetScaleFrom then
        anim:SetScaleFrom(1, 1)
        anim:SetScaleTo(ratio, ratio)
    end
end

-- The alert's entrance: the icon pops in with a little bounce while the texts fade
-- in. Only the card's textures and texts move, never the secure button itself.
function Fx.CreateAlertEffects(style)
    local pop = alertButton.icon:CreateAnimationGroup()
    local shrink = pop:CreateAnimation("Scale")
    Fx.Scale(shrink, style.POP_FROM_SCALE)
    shrink:SetDuration(0)
    shrink:SetOrder(1)
    local grow = pop:CreateAnimation("Scale")
    Fx.Scale(grow, style.POP_OVERSHOOT_SCALE / style.POP_FROM_SCALE)
    grow:SetDuration(style.POP_GROW_SECONDS)
    grow:SetOrder(2)
    local appear = pop:CreateAnimation("Alpha")
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    appear:SetDuration(style.POP_GROW_SECONDS)
    appear:SetOrder(2)
    local settle = pop:CreateAnimation("Scale")
    Fx.Scale(settle, 1 / style.POP_OVERSHOOT_SCALE)
    settle:SetDuration(style.POP_SETTLE_SECONDS)
    settle:SetOrder(3)
    alertButton.pop = pop

    alertButton.fades = {}
    for _, text in ipairs({ alertTitle, alertHint }) do
        local fadeIn = text:CreateAnimationGroup()
        local alpha = fadeIn:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0)
        alpha:SetToAlpha(1)
        alpha:SetDuration(style.POP_GROW_SECONDS + style.POP_SETTLE_SECONDS)
        table.insert(alertButton.fades, fadeIn)
    end
end

-- Whenever the alert becomes visible: entrance and the red pulse around the icon.
function Fx.PlayAlertEntrance()
    alertButton.pop:Stop()
    alertButton.pop:Play()
    for _, fadeIn in ipairs(alertButton.fades) do
        fadeIn:Stop()
        fadeIn:Play()
    end
    alertPulse:Play()
end

function Fx.StopAlertEffects()
    alertButton.pop:Stop()
    for _, fadeIn in ipairs(alertButton.fades) do
        fadeIn:Stop()
    end
    alertPulse:Stop()
end

-- Gives any frame the HUD's frame, whether or not it was created with the template.
function Fx.ApplyBackdrop(frame, borderColor)
    if not frame.SetBackdrop and BackdropTemplateMixin and Mixin then
        Mixin(frame, BackdropTemplateMixin)
        -- What the template would do: keep the border right if the size changes.
        if frame.HookScript and frame.OnBackdropSizeChanged then
            frame:HookScript("OnSizeChanged", frame.OnBackdropSizeChanged)
        end
    end
    if frame.SetBackdrop then
        frame:SetBackdrop(C.BACKDROP)
        frame:SetBackdropColor(unpack(C.COLORS.HUD_BACKGROUND))
        frame:SetBackdropBorderColor(unpack(borderColor))
    end
end

-- The notice: weapon icon, text and a tick, where the alert would have been.
function Fx.CreateToast()
    local style = C.TOAST
    local toast = CreateFrame("Frame", C.TOAST_FRAME_NAME, UIParent, BackdropTemplateMixin and C.BACKDROP_TEMPLATE or nil)
    toast:SetSize(style.WIDTH, style.HEIGHT)
    toast:SetFrameStrata(style.STRATA)
    toast:EnableMouse(false)
    Fx.ApplyBackdrop(toast, C.COLORS.TOAST_BORDER)
    toast.icon = toast:CreateTexture(nil, "ARTWORK")
    toast.icon:SetSize(style.ICON_SIZE, style.ICON_SIZE)
    toast.icon:SetPoint("LEFT", style.PADDING, 0)
    toast.icon:SetTexCoord(unpack(C.HUD.ICON_TEXCOORD))
    toast.check = toast:CreateTexture(nil, "OVERLAY")
    toast.check:SetSize(style.CHECK_SIZE, style.CHECK_SIZE)
    toast.check:SetPoint("RIGHT", -style.PADDING, 0)
    toast.check:SetTexture(style.CHECK_TEXTURE)
    toast.text = toast:CreateFontString(nil, "OVERLAY", C.FONTS.TOAST)
    toast.text:SetPoint("LEFT", toast.icon, "RIGHT", style.TEXT_GAP, 0)
    toast.text:SetPoint("RIGHT", toast.check, "LEFT", -style.TEXT_GAP, 0)
    toast.text:SetJustifyH("LEFT")
    toast.text:SetWordWrap(false)

    -- Slides down and fades in, stays a moment, fades out.
    local anim = toast:CreateAnimationGroup()
    local lift = anim:CreateAnimation("Translation")
    lift:SetOffset(0, style.SLIDE_OFFSET)
    lift:SetDuration(0)
    lift:SetOrder(1)
    local slide = anim:CreateAnimation("Translation")
    slide:SetOffset(0, -style.SLIDE_OFFSET)
    slide:SetDuration(style.SLIDE_SECONDS)
    slide:SetOrder(2)
    local fadeIn = anim:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(style.SLIDE_SECONDS)
    fadeIn:SetOrder(2)
    local fadeOut = anim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetStartDelay(style.HOLD_SECONDS)
    fadeOut:SetDuration(style.FADE_SECONDS)
    fadeOut:SetOrder(3)
    anim:SetScript("OnFinished", function() toast:Hide() end)
    toast.anim = anim

    -- The tick appears a moment later with a small pop.
    local tick = toast.check:CreateAnimationGroup()
    local wait = tick:CreateAnimation("Alpha")
    wait:SetFromAlpha(0)
    wait:SetToAlpha(0)
    wait:SetDuration(style.CHECK_DELAY)
    wait:SetOrder(1)
    local show = tick:CreateAnimation("Alpha")
    show:SetFromAlpha(0)
    show:SetToAlpha(1)
    show:SetDuration(style.CHECK_SECONDS)
    show:SetOrder(2)
    local popTick = tick:CreateAnimation("Scale")
    Fx.Scale(popTick, C.ALERT.POP_OVERSHOOT_SCALE)
    popTick:SetDuration(style.CHECK_SECONDS)
    popTick:SetOrder(2)
    toast.tick = tick

    toast:Hide()
    Fx.toast = toast
end

-- Weapon back on by itself: say so, without covering the fight.
function Fx.ShowToast()
    if not (db and GetOption("combatToast")) then
        return
    end
    if not Fx.toast then
        Fx.CreateToast()
    end
    local toast, style = Fx.toast, C.TOAST
    local saved, alertStyle = db.alertPosition, C.ALERT
    toast:ClearAllPoints()
    if saved and saved.point then
        toast:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
    else
        toast:SetPoint(alertStyle.DEFAULT_POINT, UIParent, alertStyle.DEFAULT_POINT, alertStyle.DEFAULT_X, alertStyle.DEFAULT_Y)
    end
    toast.icon:SetTexture(GetWeaponIcon())
    toast.text:SetText(L.TOAST_WEAPON_ON)
    toast:Show()
    toast.anim:Stop()
    toast.anim:Play()
    toast.tick:Stop()
    toast.tick:Play()
    -- In case the animation can't run, it still goes away.
    Fx.toastToken = Fx.toastToken + 1
    local token = Fx.toastToken
    C_Timer.After(style.SLIDE_SECONDS + style.HOLD_SECONDS + style.FADE_SECONDS + style.HIDE_MARGIN, function()
        if token == Fx.toastToken then
            toast.anim:Stop()
            toast:Hide()
        end
    end)
end

local function CreateAlertButton()
    local style = C.ALERT
    -- A weapon button: it always carries the macro that re-equips your saved weapon.
    alertButton = CreateWeaponButton(C.ALERT_BUTTON_NAME, UIParent)
    alertButton:SetSize(style.WIDTH, style.HEIGHT)
    alertButton:SetFrameStrata(style.STRATA)
    alertButton:SetClampedToScreen(true)
    alertButton:SetMovable(true)
    alertButton:RegisterForDrag(C.DRAG_BUTTON)
    alertButton:SetScript("OnDragStart", function(self)
        if not InCombatLockdown() then
            self:StartMoving()
        end
    end)
    alertButton:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveAlertPosition()
    end)

    -- The card: the HUD's frame with a red border; the whole card is the button.
    Fx.ApplyBackdrop(alertButton, C.COLORS.ALERT)

    local icon = alertButton:CreateTexture(nil, "ARTWORK")
    icon:SetSize(style.ICON_SIZE, style.ICON_SIZE)
    icon:SetPoint("LEFT", style.PADDING, 0)
    icon:SetTexCoord(unpack(C.HUD.ICON_TEXCOORD))
    alertButton.icon = icon
    local slot = alertButton:CreateTexture(nil, "OVERLAY")
    slot:SetTexture(style.SLOT_TEXTURE)
    slot:SetSize(style.ICON_SIZE * style.SLOT_SCALE, style.ICON_SIZE * style.SLOT_SCALE)
    slot:SetPoint("CENTER", icon, "CENTER")
    -- Hovering lights the icon, not the whole card.
    alertButton:SetHighlightTexture(C.TEXTURES.HIGHLIGHT, C.BLEND_ADD)
    local highlight = alertButton.GetHighlightTexture and alertButton:GetHighlightTexture()
    if highlight then
        highlight:ClearAllPoints()
        highlight:SetAllPoints(icon)
    end

    -- A red glow that beats around the icon.
    local glow = alertButton:CreateTexture(nil, "OVERLAY", nil, 1)
    glow:SetTexture(style.GLOW_TEXTURE)
    glow:SetBlendMode(C.BLEND_ADD)
    glow:SetVertexColor(unpack(C.COLORS.ALERT))
    glow:SetSize(style.ICON_SIZE * style.GLOW_SCALE, style.ICON_SIZE * style.GLOW_SCALE)
    glow:SetPoint("CENTER", icon, "CENTER")
    alertPulse = glow:CreateAnimationGroup()
    alertPulse:SetLooping("BOUNCE")
    local fade = alertPulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(style.PULSE_MIN_ALPHA)
    fade:SetDuration(style.PULSE_SECONDS)

    -- Title just above the middle, what to do just below, beside the icon.
    alertTitle = alertButton:CreateFontString(nil, "OVERLAY", C.FONTS.ALERT_TITLE)
    alertTitle:SetPoint("BOTTOMLEFT", icon, "RIGHT", style.TEXT_GAP, style.LINE_GAP)
    alertTitle:SetPoint("RIGHT", alertButton, "RIGHT", -style.PADDING, 0)
    alertTitle:SetJustifyH("LEFT")
    alertTitle:SetWordWrap(false)
    alertTitle:SetTextColor(unpack(C.COLORS.ALERT_TITLE))
    alertHint = alertButton:CreateFontString(nil, "OVERLAY", C.FONTS.ALERT_HINT)
    alertHint:SetPoint("TOPLEFT", icon, "RIGHT", style.TEXT_GAP, -style.LINE_GAP)
    alertHint:SetPoint("RIGHT", alertButton, "RIGHT", -style.PADDING, 0)
    alertHint:SetJustifyH("LEFT")
    Fx.CreateAlertEffects(style)

    -- The driver may show it in combat: the effects follow whatever shows it.
    alertButton:SetScript("OnShow", Fx.PlayAlertEntrance)
    alertButton:SetScript("OnHide", Fx.StopAlertEffects)

    RestoreAlertPosition()
    alertButton:Hide()
end

-- Icon and texts, set beforehand so the alert is ready whenever it appears.
local function PrepareAlertLook()
    alertButton.icon:SetTexture(GetWeaponIcon())
    alertTitle:SetText(L.ALERT_TITLE)
    local weaponKeys = {}
    AddBindingKeys(weaponKeys, C.WEAPON_BINDING_COMMAND)
    local key = Hud.FirstKey(weaponKeys)
    alertHint:SetText(key ~= "" and L.ALERT_HINT_KEY:format(key) or L.ALERT_HINT)
    alertButton:SetAlpha(1)
end

local function StopAlertDriver()
    if alertDriverActive then
        UnregisterStateDriver(alertButton, C.ALERT.VISIBILITY_STATE)
    end
    alertDriverActive = false
    alertDriverCondition = nil
end

-- Out of combat only. Hands the alert to the driver when it is enabled and there is
-- a weapon to give back; otherwise keeps it hidden.
UpdateAlertDriver = function()
    if not alertButton or alertTesting then
        return
    end
    if InCombatLockdown() then
        alertDriverPending = true
        return
    end
    alertDriverPending = false
    PrepareAlertLook()
    local condition = GetAlertCondition()
    if GetOption("combatAlert") and BuildWeaponMacroText(db and db.weapons) and condition then
        if not (alertDriverActive and alertDriverCondition == condition) then
            RegisterStateDriver(alertButton, C.ALERT.VISIBILITY_STATE, condition)
            alertDriverActive = true
            alertDriverCondition = condition
        end
    else
        StopAlertDriver()
        alertButton:Hide()
    end
end

local function HideCombatAlert()
    if not alertButton or InCombatLockdown() then
        return
    end
    alertButton:Hide()
end

-- Weapon back in your hands but the alert can't hide (no driver): it dims until
-- combat ends.
local function MarkCombatAlertDone()
    if not (alertButton and alertButton:IsShown()) then
        return
    end
    Fx.StopAlertEffects()
    alertButton:SetAlpha(C.ALERT.DONE_ALPHA)
    alertTitle:SetText(L.ALERT_DONE)
    alertHint:SetText("")
end

local function EndAlertTest()
    if not alertTesting or InCombatLockdown() then
        return
    end
    alertTesting = false
    alertButton:Hide()
    UpdateAlertDriver()
end

-- Options > "Test alert": shows it for a few seconds, out of combat.
local function TestCombatAlert()
    if not alertButton or not BuildWeaponMacroText(db and db.weapons) then
        PrintMessage(L.WEAPON_NONE)
        return
    end
    -- The driver would hide it right away out of combat.
    StopAlertDriver()
    alertTesting = true
    PrepareAlertLook()
    alertButton:Show()
    PlayAlertSound()
    alertTestToken = alertTestToken + 1
    local token = alertTestToken
    C_Timer.After(C.ALERT.TEST_SECONDS, function()
        if token == alertTestToken then
            EndAlertTest()
            -- And what you'd see when the weapon goes on by itself.
            if GetOption("combatAutoEquip") then
                Fx.ShowToast()
            end
        end
    end)
end

-- Runs at PLAYER_REGEN_DISABLED, the last moment secure frames can change.
-- weaponOnItsWay: the weapon is being put on by itself; the alert stays invisible
-- and silent unless it hasn't arrived a moment later.
local function StartCombatAlert(weaponOnItsWay)
    if not alertButton then
        return
    end
    -- A test still on screen: back to normal before combat locks everything.
    alertTestToken = alertTestToken + 1
    alertTesting = false
    UpdateAlertDriver()
    if not (GetOption("combatAlert") and IsPoleEquipped() and BuildWeaponMacroText(db and db.weapons)) then
        return
    end
    if alertDriverActive and not PoleConditionMatches() then
        -- The driver would never see the pole on this client: use the older way.
        alertDriverUnsupported = true
        StopAlertDriver()
    end
    if not alertDriverActive then
        -- No driver on this client: show it now; it dims once the weapon is back.
        PrepareAlertLook()
        alertButton:Show()
    end
    if weaponOnItsWay then
        alertButton:SetAlpha(0)
        C_Timer.After(C.AUTO_EQUIP_CHECK_SECONDS, function()
            if IsPoleEquipped() and alertButton:IsShown() then
                alertButton:SetAlpha(1)
                Fx.PlayAlertEntrance()
                PlayAlertSound()
            end
        end)
        return
    end
    PlayAlertSound()
end

local function OnAlertEquipmentChanged()
    if alertTesting or not (alertButton and alertButton:IsShown()) or IsPoleEquipped() then
        return
    end
    if not InCombatLockdown() then
        alertButton:Hide()
    elseif not alertDriverActive then
        MarkCombatAlertDone()
    else
        -- The driver hides it within moments; if it somehow didn't, dim it.
        C_Timer.After(C.ALERT.DRIVER_CHECK_SECONDS, function()
            if alertButton:IsShown() and not IsPoleEquipped() then
                MarkCombatAlertDone()
            end
        end)
    end
end

-- Fishing hints ---------------------------------------------------------------------------
-- Why a fish got away, a lure that ran out.

function Hints.GetFishMessageKind(messageType, message)
    if messageType and GetGameMessageInfo and not IsSecret(messageType) then
        local ok, id = pcall(GetGameMessageInfo, messageType)
        if ok and type(id) == "string" and C.FISH_MESSAGE_IDS[id] then
            return C.FISH_MESSAGE_IDS[id]
        end
    end
    if type(message) ~= "string" or IsSecret(message) then
        return nil
    end
    for kind, globalName in pairs(C.FISH_MESSAGE_GLOBALS) do
        local text = _G[globalName]
        if type(text) == "string" and text == message then
            return kind
        end
    end
end

Hints.byKind = {}

-- Fish get away when your skill is too low for the water: said once per zone.
function Hints.byKind.ESCAPED()
    local zone = GetRealZoneText and GetRealZoneText()
    if type(zone) ~= "string" or zone == "" or IsSecret(zone) then
        zone = L.ZONE_FALLBACK
    end
    if Hints.escapeZones[zone] then
        return
    end
    Hints.escapeZones[zone] = true
    PrintMessage(L.FISH_ESCAPED_HINT:format(zone))
end

function Hints.byKind.NOT_HOOKED()
    if Hints.notHookedShown then
        return
    end
    Hints.notHookedShown = true
    PrintMessage(L.FISH_NOT_HOOKED_HINT)
end

function Hints.OnGameMessage(messageType, message)
    if not (db and GetOption("escapeHints")) then
        return
    end
    local kind = Hints.GetFishMessageKind(messageType, message)
    if kind then
        Hints.byKind[kind]()
    end
end

function Hints.PlayLureAlertSound()
    if not PlaySound then
        return
    end
    local soundKit = SOUNDKIT and SOUNDKIT[C.LURE_ALERT.SOUND_KIT]
    pcall(PlaySound, soundKit or C.LURE_ALERT.SOUND_FALLBACK_ID)
end

-- While the pole is on, every few seconds: a lure that was on and is gone has run out.
function Hints.CheckLureExpired()
    if not db or not IsPoleEquipped() then
        Hints.lureWasOn = nil
        return
    end
    local ok, hasLure = pcall(GetLureState)
    if not ok then
        return
    end
    hasLure = hasLure and true or false
    if Hints.lureWasOn and not hasLure and not pendingLure and GetOption("lureExpiredAlert") then
        Hints.PlayLureAlertSound()
        PrintMessage(FindBestLure() and L.LURE_EXPIRED or L.LURE_EXPIRED_NONE_LEFT)
        RefreshPanel()
    end
    Hints.lureWasOn = hasLure
end

function Hints.WatchLure()
    if Hints.lureWatching or not IsPoleEquipped() then
        return
    end
    Hints.lureWatching = true
    local function Tick()
        Hints.CheckLureExpired()
        if IsPoleEquipped() then
            C_Timer.After(C.LURE_CHECK_SECONDS, Tick)
        else
            Hints.lureWatching = false
            Hints.lureWasOn = nil
        end
    end
    Tick()
end

-- Catch value ---------------------------------------------------------------------------
-- What to do with what you caught: sell it to a vendor, sell it at the auction house, or
-- turn it into something worth more with any of your professions. Auction prices come from
-- Auctionator (required for this part). Cooking recipes are Forever's own (Data\CookingData.lua);
-- recipes from your other professions are learned when you open their windows.

Value.byReagent = {}
Value.fishItems = {}
for recipeID, recipe in pairs(ns.COOKING_RECIPES or {}) do
    local reagents = recipe.reagents
    for index = 1, #reagents, 2 do
        local itemID = reagents[index]
        Value.byReagent[itemID] = Value.byReagent[itemID] or {}
        table.insert(Value.byReagent[itemID], recipeID)
    end
    if recipe.fish then
        Value.fishItems[reagents[1]] = true
    end
end
for _, recipeIDs in pairs(Value.byReagent) do
    table.sort(recipeIDs)
end

function Value.RebuildCraftIndex()
    Value.craftByReagent = {}
    for recipeID, recipe in pairs(db and db.craftRecipes or {}) do
        for index = 1, #recipe.reagents, 2 do
            local itemID = recipe.reagents[index]
            Value.craftByReagent[itemID] = Value.craftByReagent[itemID] or {}
            table.insert(Value.craftByReagent[itemID], recipeID)
        end
    end
    for _, recipeIDs in pairs(Value.craftByReagent) do
        table.sort(recipeIDs)
    end
end
Value.craftByReagent = {}

function Value.API()
    return Auctionator and Auctionator.API and Auctionator.API.v1 or nil
end

local function ReadNumber(ok, value)
    if ok and type(value) == "number" and not IsSecret(value) then
        return value
    end
end

function Value.AuctionPrice(itemID)
    local api = Value.API()
    if not (api and api.GetAuctionPriceByItemID) then
        return nil
    end
    local price = ReadNumber(pcall(api.GetAuctionPriceByItemID, ADDON_NAME, itemID))
    return price and price > 0 and price or nil
end

-- Days since Auctionator last saw it at the auction house.
function Value.AuctionAge(itemID)
    local api = Value.API()
    if api and api.GetAuctionAgeByItemID then
        return ReadNumber(pcall(api.GetAuctionAgeByItemID, ADDON_NAME, itemID))
    end
end

function Value.VendorPrice(itemID)
    if not GetItemInfoFull then
        return 0
    end
    local ok, sellPrice = pcall(function()
        return select(C.VALUE.SELL_PRICE_INDEX, GetItemInfoFull(itemID))
    end)
    sellPrice = ReadNumber(ok, sellPrice)
    if not sellPrice and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
    return sellPrice or 0
end

-- What another ingredient costs: a vendor's price as Auctionator saw it, else the
-- auction price. Nil when nobody knows.
function Value.IngredientCost(itemID)
    local api = Value.API()
    if api and api.GetVendorPriceByItemID then
        local price = ReadNumber(pcall(api.GetVendorPriceByItemID, ADDON_NAME, itemID))
        if price and price > 0 then
            return price
        end
    end
    return Value.AuctionPrice(itemID)
end

-- The most one fetches when sold: at the auction house (after its cut) or from a vendor.
function Value.SaleValue(itemID)
    local vendor = Value.VendorPrice(itemID)
    local auction = Value.AuctionPrice(itemID)
    local net = auction and math.floor(auction * (1 - C.VALUE.AUCTION_CUT))
    if net and net > vendor then
        return net, C.VALUE_KIND.AUCTION
    end
    return vendor, C.VALUE_KIND.VENDOR
end

function Value.KnowsRecipe(recipeID)
    if db and db.knownRecipes and db.knownRecipes[recipeID] then
        return true
    end
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, recipeID)
        return ok and not IsSecret(known) and known == true
    end
    return false
end

-- Making something with it: what it makes is worth, minus the other ingredients, per
-- piece of this item.
function Value.RecipeOption(itemID, recipeID, recipe, kind, known)
    local dishValue = Value.SaleValue(recipe.creates) * (recipe.makes or 1)
    local needed, otherCost, costUnknown = 1, 0, false
    local reagents = recipe.reagents
    for index = 1, #reagents, 2 do
        local reagentID, count = reagents[index], reagents[index + 1]
        if reagentID == itemID then
            needed = count
        else
            local cost = Value.IngredientCost(reagentID)
            if cost then
                otherCost = otherCost + cost * count
            else
                costUnknown = true
            end
        end
    end
    return {
        kind = kind,
        value = math.floor((dishValue - otherCost) / needed),
        recipeID = recipeID,
        recipe = recipe,
        creates = recipe.creates,
        known = known,
        costUnknown = costUnknown,
        recipeItem = recipe.items and recipe.items[1],
    }
end

-- Every way to turn one of this item into money.
function Value.GetOptions(itemID)
    local options = {}
    local vendor = Value.VendorPrice(itemID)
    if vendor > 0 then
        table.insert(options, { kind = C.VALUE_KIND.VENDOR, value = vendor })
    end
    local auction = Value.AuctionPrice(itemID)
    if auction then
        table.insert(options, { kind = C.VALUE_KIND.AUCTION, value = math.floor(auction * (1 - C.VALUE.AUCTION_CUT)) })
    end
    -- Copies of a recipe make the same thing: keep the one you know, else the best.
    local byDish = {}
    local function Keep(option)
        local kept = byDish[option.creates]
        if not kept or (option.known and not kept.known) or (option.known == kept.known and option.value > kept.value) then
            byDish[option.creates] = option
        end
    end
    for _, recipeID in ipairs(Value.byReagent[itemID] or {}) do
        Keep(Value.RecipeOption(itemID, recipeID, ns.COOKING_RECIPES[recipeID], C.VALUE_KIND.COOK,
            Value.KnowsRecipe(recipeID)))
    end
    -- Anything your other professions make with it.
    for _, recipeID in ipairs(Value.craftByReagent[itemID] or {}) do
        local recipe = db.craftRecipes[recipeID]
        Keep(Value.RecipeOption(itemID, recipeID, recipe, C.VALUE_KIND.CRAFT, recipe.known ~= false))
    end
    local dishes = {}
    for _, option in pairs(byDish) do
        table.insert(dishes, option)
    end
    table.sort(dishes, function(a, b) return a.recipeID < b.recipeID end)
    for _, option in ipairs(dishes) do
        table.insert(options, option)
    end
    return options
end

-- The best you can do now, and a recipe you don't know yet that would pay more.
-- On a tie the simpler choice (selling) wins.
function Value.GetBest(itemID)
    local best, learn
    for _, option in ipairs(Value.GetOptions(itemID)) do
        local isRecipe = option.kind == C.VALUE_KIND.COOK or option.kind == C.VALUE_KIND.CRAFT
        if not isRecipe or option.known then
            if not best or option.value > best.value then
                best = option
            end
        elseif option.value > 0 and (not learn or option.value > learn.value) then
            learn = option
        end
    end
    if learn and best and learn.value <= best.value then
        learn = nil
    end
    local openable = Value.GetOpenable(itemID)
    if openable == C.VALUE_KIND.OPEN then
        best = { kind = C.VALUE_KIND.OPEN, value = 0 }
    elseif openable == C.VALUE_KIND.LOCKED and (not best or best.kind == C.VALUE_KIND.VENDOR) then
        best = { kind = C.VALUE_KIND.LOCKED, value = best and best.value or 0 }
    end
    return best, learn
end

function Value.ItemName(itemID, fallback)
    return GetItemName(itemID) or fallback or (C.ITEM_LINK_PREFIX .. itemID)
end

function Value.Describe(option)
    if option.kind == C.VALUE_KIND.VENDOR then
        return L.VALUE_SELL_VENDOR
    elseif option.kind == C.VALUE_KIND.AUCTION then
        return L.VALUE_SELL_AUCTION
    elseif option.kind == C.VALUE_KIND.OPEN then
        return L.VALUE_OPEN
    elseif option.kind == C.VALUE_KIND.LOCKED then
        return L.VALUE_LOCKED
    end
    local format = option.kind == C.VALUE_KIND.CRAFT and L.VALUE_CRAFT or L.VALUE_COOK
    local text = format:format(Value.ItemName(option.creates, option.recipe.name))
    if option.costUnknown then
        text = text .. " " .. L.VALUE_PLUS_OTHER
    end
    return text
end

-- "Learn Recipe: Smoked Sagefish to earn 12s each".
function Value.DescribeLearn(option)
    local teacher = option.recipeItem and GetItemName(option.recipeItem) or Value.ItemName(option.creates, option.recipe.name)
    return L.VALUE_LEARN:format(teacher, Value.Money(option.value))
end

function Value.Money(copper)
    copper = math.max(0, math.floor(copper or 0))
    if GetCoinTextureString then
        local ok, text = pcall(GetCoinTextureString, copper)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
    end
    local style = C.VALUE
    local parts = {}
    local gold = math.floor(copper / style.COPPER_PER_GOLD)
    local silver = math.floor(copper / style.COPPER_PER_SILVER) % style.COPPER_PER_SILVER
    local rest = copper % style.COPPER_PER_SILVER
    if gold > 0 then
        table.insert(parts, style.MONEY_GOLD:format(gold))
    end
    if silver > 0 then
        table.insert(parts, style.MONEY_SILVER:format(silver))
    end
    if rest > 0 or #parts == 0 then
        table.insert(parts, style.MONEY_COPPER:format(rest))
    end
    return table.concat(parts, style.MONEY_SEPARATOR)
end

-- Something from fishing: anything Forever lets you fish up (Data\FishingCatches.lua), the
-- main ingredient of a fish recipe, or anything you looted while fishing or from a
-- container you fished up.
function Value.IsCatch(itemID)
    return (ns.FISHING_CATCHES and ns.FISHING_CATCHES[itemID] ~= nil) or Value.fishItems[itemID]
        or (accountDB and accountDB.caught and accountDB.caught[itemID]) or false
end

-- Containers fished up: "<Right Click to Open>" or "Locked" on the tooltip, in the game's
-- language. Remembered once the tooltip has loaded.
function Value.GetOpenable(itemID)
    if Value.openable[itemID] ~= nil then
        return Value.openable[itemID]
    end
    if not (C_TooltipInfo and C_TooltipInfo.GetItemByID) then
        return false
    end
    local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" or #data.lines == 0 then
        return false
    end
    local kind = false
    local openText, lockedText = _G[C.VALUE.OPENABLE_GLOBAL], _G[C.VALUE.LOCKED_GLOBAL]
    for _, line in ipairs(data.lines) do
        local text = line.leftText
        if type(text) == "string" and not IsSecret(text) then
            if lockedText and text == lockedText then
                kind = C.VALUE_KIND.LOCKED
            elseif openText and text == openText and not kind then
                kind = C.VALUE_KIND.OPEN
            end
        end
    end
    Value.openable[itemID] = kind
    return kind
end

-- Other professions' recipes that use it (from the fishing list), when they aren't among
-- the choices already: "Fire Oil (Alchemy)".
function Value.GetOtherUses(itemID, options)
    local entry = ns.FISHING_CATCHES and ns.FISHING_CATCHES[itemID]
    local list = {}
    if not (entry and entry.uses) then
        return list
    end
    local shown = {}
    for _, option in ipairs(options or {}) do
        if option.recipeID then
            shown[option.recipeID] = true
        end
    end
    for _, use in ipairs(entry.uses) do
        local recipeID, profession, englishName = use[1], use[2], use[3]
        if not shown[recipeID] and not ns.COOKING_RECIPES[recipeID] then
            local recipeName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(recipeID)
            local professionSpell = C.PROFESSION_SPELLS[profession]
            local professionName = professionSpell and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(professionSpell)
            recipeName = type(recipeName) == "string" and not IsSecret(recipeName) and recipeName or englishName
            professionName = type(professionName) == "string" and not IsSecret(professionName) and professionName or profession
            table.insert(list, C.VALUE.USE_FORMAT:format(recipeName, professionName))
        end
    end
    return list
end

-- Said once per item each session, when the advice isn't just "sell it to a vendor".
function Value.HintBest(itemID)
    if Value.hinted[itemID] then
        return
    end
    Value.hinted[itemID] = true
    if not (GetOption("catchValueHints") and Value.API()) then
        return
    end
    local best, learn = Value.GetBest(itemID)
    local isMoney = best and best.kind ~= C.VALUE_KIND.OPEN and best.kind ~= C.VALUE_KIND.LOCKED
    if isMoney and (best.kind ~= C.VALUE_KIND.VENDOR or learn) then
        PrintMessage(L.VALUE_HINT:format(Value.ItemName(itemID), Value.Describe(best), Value.Money(best.value)))
    end
    if learn then
        PrintMessage(Value.DescribeLearn(learn))
    end
end

-- Opening a fished-up container locks it for a moment: its loot is a catch too.
function Value.OnItemLocked(bag, bagSlot)
    if not bagSlot then
        return
    end
    local itemID = GetContainerItemID(bag, bagSlot)
    if itemID and not IsSecret(itemID) and Value.IsCatch(itemID) and Value.GetOpenable(itemID) then
        Value.openingUntil = GetTime() + C.VALUE.OPEN_LOOT_SECONDS
    end
end

function Value.RecordLoot()
    if not (accountDB and GetNumLootItems and GetLootSlotLink) then
        return
    end
    local fromContainer = Value.openingUntil and GetTime() <= Value.openingUntil
    Value.openingUntil = nil
    if not (fromContainer or (IsFishingLoot and IsFishingLoot())) then
        return
    end
    accountDB.caught = accountDB.caught or {}
    local zone = not fromContainer and GetRealZoneText and GetRealZoneText()
    if type(zone) == "string" and zone ~= "" then
        Hints.zoneCatches[zone] = (Hints.zoneCatches[zone] or 0) + 1
    end
    for slot = 1, GetNumLootItems() or 0 do
        local link = GetLootSlotLink(slot)
        local itemID = type(link) == "string" and not IsSecret(link) and tonumber(link:match(C.ITEM_ID_PATTERN))
        if itemID then
            accountDB.caught[itemID] = true
            Value.HintBest(itemID)
            if not fromContainer then
                local okCount, _, _, quantity = pcall(GetLootSlotInfo, slot)
                Hud.ShowCatch(itemID, okCount and tonumber(quantity) or 1)
            end
        end
    end
end

-- What a recipe needs and makes, from the game: required reagents only (not optional ones).
function Value.ReadSchematic(recipeID)
    if not C_TradeSkillUI.GetRecipeSchematic then
        return nil
    end
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
        return nil
    end
    local creates = tonumber(schematic.outputItemID)
    if not creates and C_TradeSkillUI.GetRecipeOutputItemData then
        local okOutput, output = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        creates = okOutput and type(output) == "table" and tonumber(output.itemID) or nil
    end
    if not creates then
        return nil
    end
    local reagents = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local first = slot.required ~= false and type(slot.reagents) == "table" and slot.reagents[1]
        local itemID = first and tonumber(first.itemID)
        if itemID then
            table.insert(reagents, itemID)
            table.insert(reagents, tonumber(slot.quantityRequired) or 1)
        end
    end
    if #reagents == 0 then
        return nil
    end
    local low, high = tonumber(schematic.quantityMin) or 1, tonumber(schematic.quantityMax) or 1
    return { reagents = reagents, creates = creates, makes = (low + high) / 2 }
end

-- Recipes from your own profession windows: Cooking ones mark what you know; the others
-- (Alchemy oils from fish, and so on) are kept so their uses count too.
function Value.LearnRecipesFromWindow()
    if not (db and C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeInfo) then
        return
    end
    -- Someone else's linked list isn't yours.
    if C_TradeSkillUI.IsTradeSkillLinked then
        local ok, linked = pcall(C_TradeSkillUI.IsTradeSkillLinked)
        if not ok or linked then
            return
        end
    end
    local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(recipeIDs) ~= "table" then
        return
    end
    db.knownRecipes = db.knownRecipes or {}
    db.craftRecipes = db.craftRecipes or {}
    for _, recipeID in ipairs(recipeIDs) do
        local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
        if okInfo and type(info) == "table" then
            local learned = info.learned == true
            if ns.COOKING_RECIPES[recipeID] then
                db.knownRecipes[recipeID] = learned or nil
            else
                local recipe = Value.ReadSchematic(recipeID)
                if recipe then
                    recipe.name = type(info.name) == "string" and not IsSecret(info.name) and info.name or nil
                    recipe.known = learned
                    db.craftRecipes[recipeID] = recipe
                end
            end
        end
    end
    Value.RebuildCraftIndex()
    Value.RefreshIfShown()
end

function Value.ScheduleRecipeScan()
    if Value.recipeScanPending then
        return
    end
    Value.recipeScanPending = true
    C_Timer.After(C.VALUE.RECIPE_SCAN_DELAY, function()
        Value.recipeScanPending = false
        Value.LearnRecipesFromWindow()
    end)
end

-- Tooltips ---------------------------------------------------------------------------------

function Value.AddTooltipLines(tooltip, itemID)
    if not (db and GetOption("catchValueTooltip") and Value.IsCatch(itemID) and Value.API()) then
        return
    end
    local best, learn = Value.GetBest(itemID)
    if best then
        tooltip:AddLine(L.VALUE_TOOLTIP_BEST:format(Value.Describe(best), Value.Money(best.value)), unpack(C.COLORS.VALUE))
    end
    if learn then
        tooltip:AddLine(Value.DescribeLearn(learn), unpack(C.COLORS.VALUE_LEARN))
    end
    local uses = Value.GetOtherUses(itemID, Value.GetOptions(itemID))
    if #uses > 0 then
        tooltip:AddLine(L.VALUE_ALSO_USED:format(table.concat(uses, C.LIST_SEPARATOR)), unpack(C.COLORS.VALUE_NOTE))
    end
end

function Value.HookTooltips()
    local function OnItem(tooltip, itemID)
        if type(itemID) == "number" and not IsSecret(itemID) then
            pcall(Value.AddTooltipLines, tooltip, itemID)
        end
    end
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
        and Enum.TooltipDataType.Item then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            if tooltip == GameTooltip or tooltip == ItemRefTooltip then
                OnItem(tooltip, data and data.id)
            end
        end)
    elseif GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
            local _, link = tooltip:GetItem()
            OnItem(tooltip, type(link) == "string" and tonumber(link:match(C.ITEM_ID_PATTERN)) or nil)
        end)
    end
end

-- Window -----------------------------------------------------------------------------------

-- What you fished that is in your bags now, with its best use, most valuable first.
function Value.CollectCatches()
    local list, seen = {}, {}
    for bag = C.FIRST_BAG, C.LAST_ITEM_BAG do
        for bagSlot = 1, GetContainerNumSlots(bag) or 0 do
            local itemID = GetContainerItemID(bag, bagSlot)
            if itemID and not IsSecret(itemID) and not seen[itemID] and Value.IsCatch(itemID) then
                seen[itemID] = true
                local count = GetItemCount(itemID) or 0
                local best, learn = Value.GetBest(itemID)
                table.insert(list, {
                    itemID = itemID,
                    count = count,
                    best = best,
                    learn = learn,
                    total = best and best.value * count or 0,
                    vendorTotal = Value.VendorPrice(itemID) * count,
                    noAuctionPrice = Value.AuctionPrice(itemID) == nil,
                    age = Value.AuctionAge(itemID),
                })
            end
        end
    end
    table.sort(list, function(a, b)
        if a.total ~= b.total then
            return a.total > b.total
        end
        return a.itemID < b.itemID
    end)
    return list
end

-- Main window -------------------------------------------------------------------------------
-- One window in the HUD's frame with three tabs: what your catch is worth, your fishing
-- gear, and the recipes that use what you fish. Every page has the same parts: three
-- summary tiles, filter chips, a scrolling list and a footer.

function Window.ContentWidth()
    return C.WINDOW.WIDTH - C.WINDOW.PADDING * 2
end

function Window.RowWidth()
    return Window.ContentWidth() - C.WINDOW.SCROLL_WIDTH - C.WINDOW.SCROLL_GAP
end

-- Where each part starts, from the top of the window.
function Window.Layout()
    local style = C.WINDOW
    local tabs = style.PADDING + style.HEADER_HEIGHT + style.TAB_TOP_GAP
    local divider = tabs + style.TAB_HEIGHT
    local tiles = divider + style.DIVIDER_HEIGHT + style.SECTION_GAP
    local chips = tiles + style.TILE_HEIGHT + style.SECTION_GAP
    local columns = chips + style.CHIP_HEIGHT + style.SECTION_GAP
    local list = columns + style.COLUMN_HEADER_HEIGHT + style.LIST_TOP_GAP
    local footer = list + style.ROWS * style.ROW_HEIGHT + style.SECTION_GAP
    return {
        tabs = tabs, divider = divider, tiles = tiles, chips = chips, list = list,
        height = footer + style.FOOTER_HEIGHT + style.PADDING,
    }
end

-- A text's width, or a fair guess while the game hasn't measured it.
function Window.TextWidth(fontString, text)
    local width = fontString.GetStringWidth and fontString:GetStringWidth()
    if type(width) ~= "number" or width <= 0 then
        width = #(text or "") * C.WINDOW.CHAR_WIDTH
    end
    return width
end

function Window.SetColor(fontString, color)
    if color then
        fontString:SetTextColor(unpack(color))
    end
end

-- Rows ----------------------------------------------------------------------------------------

function Window.CreateRow(list, index)
    local style = C.WINDOW
    local rowWidth = Window.RowWidth()
    local useX = style.COLUMN_ITEM + style.COLUMN_GAP
    local secondLine = -(style.ROW_HEIGHT / 2 + style.LINE_GAP)
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(style.ROW_HEIGHT)
    if index % 2 == 0 then
        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        local r, g, b = unpack(C.COLORS.ROW_STRIPE)
        stripe:SetColorTexture(r, g, b, style.ROW_STRIPE_ALPHA)
    end
    row:SetHighlightTexture(style.ROW_HIGHLIGHT, C.BLEND_ADD)
    local highlight = row.GetHighlightTexture and row:GetHighlightTexture()
    if highlight and highlight.SetAlpha then
        highlight:SetAlpha(style.ROW_HIGHLIGHT_ALPHA)
    end

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(style.ICON_SIZE, style.ICON_SIZE)
    row.icon:SetPoint("LEFT", 0, 0)
    row.icon:SetTexCoord(unpack(C.HUD.ICON_TEXCOORD))
    local textX = style.ICON_SIZE + style.TEXT_GAP
    local titleWidth = style.COLUMN_ITEM - textX
    row.title = row:CreateFontString(nil, "OVERLAY", C.FONTS.ROW_TITLE)
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", textX, -style.TAG_TOP)
    row.title:SetWidth(titleWidth)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    row.sub = row:CreateFontString(nil, "OVERLAY", C.FONTS.ROW_SUB)
    row.sub:SetPoint("TOPLEFT", row, "TOPLEFT", textX, secondLine)
    row.sub:SetWidth(titleWidth)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)

    row.total = row:CreateFontString(nil, "OVERLAY", C.FONTS.ROW_MONEY)
    row.total:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.total:SetWidth(style.COLUMN_TOTAL)
    row.total:SetJustifyH("RIGHT")
    row.each = row:CreateFontString(nil, "OVERLAY", C.FONTS.ROW_NOTE)
    row.each:SetPoint("RIGHT", row, "RIGHT", -(style.COLUMN_TOTAL + style.COLUMN_GAP), 0)
    row.each:SetWidth(style.COLUMN_EACH)
    row.each:SetJustifyH("RIGHT")

    -- The use: a coloured badge, then what it means; a second line underneath.
    row.tagBack = row:CreateTexture(nil, "BORDER")
    row.tagText = row:CreateFontString(nil, "OVERLAY", C.FONTS.ROW_TAG)
    row.tagText:SetPoint("TOPLEFT", row, "TOPLEFT", useX + style.TAG_PADDING, -style.TAG_TOP)
    row.tagBack:SetPoint("TOPLEFT", row.tagText, "TOPLEFT", -style.TAG_PADDING, style.TAG_INSET_Y)
    row.tagBack:SetPoint("BOTTOMRIGHT", row.tagText, "BOTTOMRIGHT", style.TAG_PADDING, -style.TAG_INSET_Y)
    row.note = row:CreateFontString(nil, "OVERLAY", C.FONTS.ROW_NOTE)
    row.note:SetJustifyH("LEFT")
    row.note:SetWordWrap(false)
    row.detail = row:CreateFontString(nil, "OVERLAY", C.FONTS.ROW_SUB)
    row.detail:SetPoint("TOPLEFT", row, "TOPLEFT", useX, secondLine)
    row.detail:SetPoint("RIGHT", row.each, "LEFT", -style.COLUMN_GAP, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)
    row.useX = useX

    -- A section title in place of an item ("Lures").
    row.section = row:CreateFontString(nil, "OVERLAY", C.FONTS.ROW_SECTION)
    row.section:SetPoint("LEFT", row, "LEFT", 0, 0)

    row:SetScript("OnEnter", function(self)
        if self.itemID then
            GameTooltip:SetOwner(self, C.TOOLTIP_ANCHOR)
            -- The item's tooltip already carries the best use and the recipe to learn
            -- (unless those tooltip lines are turned off): add it only then.
            GameTooltip:SetItemByID(self.itemID)
            if self.learnText and not GetOption("catchValueTooltip") then
                GameTooltip:AddLine(self.learnText, unpack(C.COLORS.VALUE_LEARN))
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", HideTooltip)
    row:SetWidth(rowWidth)
    row:Hide()
    return row
end

-- entry: { itemID, icon, title, sub, tag, tagColor, note, noteColor, detail, detailColor,
-- each, total, learnText } or { section = "Lures" }.
function Window.FillRow(row, entry)
    local style = C.WINDOW
    local isSection = entry.section ~= nil
    row.itemID = not isSection and entry.itemID or nil
    row.learnText = entry.learnText
    row.section:SetText(entry.section or "")
    for _, part in ipairs({ row.icon, row.title, row.sub, row.note, row.detail, row.each, row.total }) do
        part:SetShown(not isSection)
    end
    local hasTag = not isSection and entry.tag ~= nil
    row.tagText:SetShown(hasTag)
    row.tagBack:SetShown(hasTag)
    if isSection then
        row:Show()
        return
    end
    row.icon:SetTexture(entry.icon)
    row.title:SetText(entry.title or "")
    row.title:SetTextColor(unpack(C.COLORS.TOOLTIP_TEXT))
    row.sub:SetText(entry.sub or "")
    row.note:ClearAllPoints()
    if hasTag then
        local r, g, b = unpack(entry.tagColor)
        row.tagText:SetText(entry.tag)
        row.tagText:SetTextColor(r, g, b)
        row.tagBack:SetColorTexture(r, g, b, C.COLORS.TAG_BACK_ALPHA)
        row.note:SetPoint("LEFT", row.tagText, "RIGHT", style.TAG_PADDING * 2, 0)
    else
        row.note:SetPoint("TOPLEFT", row, "TOPLEFT", row.useX, -style.TAG_TOP)
    end
    row.note:SetPoint("RIGHT", row.each, "LEFT", -style.COLUMN_GAP, 0)
    row.note:SetText(entry.note or "")
    row.note:SetTextColor(unpack(entry.noteColor or C.COLORS.TOOLTIP_TEXT))
    row.detail:SetText(entry.detail or "")
    row.detail:SetTextColor(unpack(entry.detailColor or C.COLORS.MUTED))
    row.each:SetText(entry.each or "")
    row.total:SetText(entry.total or "")
    row:Show()
end

-- Scrolling list ----------------------------------------------------------------------------

function Window.CreateList(page, top)
    local style = C.WINDOW
    local list = CreateFrame("Frame", nil, page)
    list:SetPoint("TOPLEFT", page, "TOPLEFT", style.PADDING, -top)
    list:SetSize(Window.ContentWidth(), style.ROWS * style.ROW_HEIGHT)
    list.rows, list.data, list.offset = {}, {}, 0
    for index = 1, style.ROWS do
        local row = Window.CreateRow(list, index)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(index - 1) * style.ROW_HEIGHT)
        list.rows[index] = row
    end

    -- A slim bar on the right; the wheel scrolls too.
    local bar = CreateFrame("Slider", nil, list)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(style.SCROLL_WIDTH)
    bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(unpack(C.COLORS.SCROLL_TRACK))
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(unpack(C.COLORS.SCROLL_THUMB))
    thumb:SetSize(style.SCROLL_WIDTH, style.SCROLL_THUMB_HEIGHT)
    bar:SetThumbTexture(thumb)
    bar:SetValueStep(1)
    if bar.SetObeyStepOnDrag then
        bar:SetObeyStepOnDrag(true)
    end
    bar:SetScript("OnValueChanged", function(_, value)
        local offset = math.floor((value or 0) + 0.5)
        if offset ~= list.offset then
            list.offset = offset
            Window.RenderList(list)
        end
    end)
    list.bar = bar
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        Window.ScrollList(list, -delta)
    end)
    return list
end

function Window.MaxOffset(list)
    return math.max(0, #list.data - #list.rows)
end

function Window.ScrollList(list, step)
    local offset = math.min(Window.MaxOffset(list), math.max(0, list.offset + step))
    if offset ~= list.offset then
        list.offset = offset
        list.bar:SetValue(offset)
        Window.RenderList(list)
    end
end

function Window.SetListData(list, data)
    list.data = data
    local maxOffset = Window.MaxOffset(list)
    list.offset = math.min(list.offset, maxOffset)
    list.bar:SetMinMaxValues(0, maxOffset)
    list.bar:SetValue(list.offset)
    list.bar:SetShown(maxOffset > 0)
    Window.RenderList(list)
end

function Window.RenderList(list)
    for index, row in ipairs(list.rows) do
        local entry = list.data[list.offset + index]
        if entry then
            Window.FillRow(row, entry)
        else
            row.itemID, row.learnText = nil, nil
            row:Hide()
        end
    end
end

-- Tiles and chips ----------------------------------------------------------------------------

function Window.CreateTile(page, index, top)
    local style = C.WINDOW
    local width = (Window.ContentWidth() - style.TILE_GAP * 2) / 3
    local tile = CreateFrame("Frame", nil, page, BackdropTemplateMixin and C.BACKDROP_TEMPLATE or nil)
    tile:SetSize(width, style.TILE_HEIGHT)
    tile:SetPoint("TOPLEFT", page, "TOPLEFT", style.PADDING + (index - 1) * (width + style.TILE_GAP), -top)
    if tile.SetBackdrop then
        tile:SetBackdrop(style.TILE_BACKDROP)
        tile:SetBackdropColor(unpack(C.COLORS.HUD_BAR_BACK))
        tile:SetBackdropBorderColor(unpack(C.COLORS.HUD_DIVIDER))
    end
    tile.label = tile:CreateFontString(nil, "OVERLAY", C.FONTS.TILE_LABEL)
    tile.label:SetPoint("TOPLEFT", tile, "TOPLEFT", style.TILE_INSET, -style.TILE_INSET_Y)
    tile.label:SetPoint("RIGHT", tile, "RIGHT", -style.TILE_INSET, 0)
    tile.label:SetJustifyH("LEFT")
    tile.label:SetWordWrap(false)
    tile.value = tile:CreateFontString(nil, "OVERLAY", C.FONTS.TILE_VALUE)
    tile.value:SetPoint("BOTTOMLEFT", tile, "BOTTOMLEFT", style.TILE_INSET, style.TILE_INSET_Y)
    tile.value:SetPoint("RIGHT", tile, "RIGHT", -style.TILE_INSET, 0)
    tile.value:SetJustifyH("LEFT")
    tile.value:SetWordWrap(false)
    return tile
end

function Window.SetTile(tile, value, color)
    tile.value:SetText(value or C.WINDOW.NO_VALUE)
    tile.value:SetTextColor(unpack(color or C.COLORS.TOOLTIP_TEXT))
end

function Window.CreateChip(page)
    local style = C.WINDOW
    local chip = CreateFrame("Button", nil, page, BackdropTemplateMixin and C.BACKDROP_TEMPLATE or nil)
    chip:SetHeight(style.CHIP_HEIGHT)
    if chip.SetBackdrop then
        chip:SetBackdrop(style.TILE_BACKDROP)
        chip:SetBackdropColor(unpack(C.COLORS.HUD_BAR_BACK))
    end
    chip.text = chip:CreateFontString(nil, "OVERLAY", C.FONTS.CHIP)
    chip.text:SetPoint("CENTER")
    chip:SetHighlightTexture(style.ROW_HIGHLIGHT, C.BLEND_ADD)
    chip:SetScript("OnClick", function(self)
        page.filter = self.key
        page.list.offset = 0
        Window.RefreshPage(page)
    end)
    return chip
end

-- chips: { { key =, label =, count = }, ... }; the selected one is gold.
function Window.SetChips(page, chips)
    local style = C.WINDOW
    local previous
    for index, info in ipairs(chips) do
        local chip = page.chips[index] or Window.CreateChip(page)
        page.chips[index] = chip
        local label = style.CHIP_FORMAT:format(info.label, info.count)
        chip.key, chip.label = info.key, label
        chip.text:SetText(label)
        chip:SetWidth(Window.TextWidth(chip.text, label) + style.CHIP_PADDING * 2)
        chip:ClearAllPoints()
        if previous then
            chip:SetPoint("LEFT", previous, "RIGHT", style.CHIP_GAP, 0)
        else
            chip:SetPoint("TOPLEFT", page, "TOPLEFT", style.PADDING, -page.chipsTop)
        end
        local selected = info.key == page.filter
        chip.text:SetTextColor(unpack(selected and C.COLORS.TAB_ACTIVE or C.COLORS.CHIP_IDLE))
        if chip.SetBackdropBorderColor then
            chip:SetBackdropBorderColor(unpack(selected and C.COLORS.HUD_BORDER or C.COLORS.HUD_DIVIDER))
        end
        chip:Show()
        previous = chip
    end
    for index = #chips + 1, #page.chips do
        page.chips[index]:Hide()
    end
end

-- "All · 6" first, then one chip per kind that has something.
function Window.BuildChips(page, counts, order, labelFor, total)
    local chips = { { key = C.FILTER_ALL, label = L.FILTER_ALL, count = total } }
    local stillThere = page.filter == C.FILTER_ALL
    for _, key in ipairs(order) do
        if (counts[key] or 0) > 0 then
            table.insert(chips, { key = key, label = labelFor(key), count = counts[key] })
            stillThere = stillThere or page.filter == key
        end
    end
    -- The kind you picked is gone (sold, eaten...): back to everything.
    if not stillThere then
        page.filter = C.FILTER_ALL
    end
    Window.SetChips(page, chips)
end

-- Pages ---------------------------------------------------------------------------------------

-- spec: { tiles = { 3 locale keys }, columns = { 4 locale keys or false }, button = {...} }
function Window.CreatePage(frame, key, spec)
    local style = C.WINDOW
    local layout = Window.Layout()
    local page = CreateFrame("Frame", nil, frame)
    page:SetAllPoints()
    page:Hide()
    page.key, page.filter, page.chips, page.chipsTop = key, C.FILTER_ALL, {}, layout.chips
    page.tiles = {}
    for index, labelKey in ipairs(spec.tiles) do
        local tile = Window.CreateTile(page, index, layout.tiles)
        tile.label:SetText(L[labelKey])
        page.tiles[index] = tile
    end
    page.list = Window.CreateList(page, layout.list)

    -- Column titles over the list, lined up with the rows.
    local rowWidth = Window.RowWidth()
    local columns = {
        { point = "BOTTOMLEFT", x = 0, justify = "LEFT" },
        { point = "BOTTOMLEFT", x = style.COLUMN_ITEM + style.COLUMN_GAP, justify = "LEFT" },
        { point = "BOTTOMRIGHT", x = rowWidth - style.COLUMN_TOTAL - style.COLUMN_GAP, justify = "RIGHT" },
        { point = "BOTTOMRIGHT", x = rowWidth, justify = "RIGHT" },
    }
    for index, column in ipairs(columns) do
        local labelKey = spec.columns[index]
        if labelKey then
            local text = page:CreateFontString(nil, "OVERLAY", C.FONTS.COLUMN)
            text:SetPoint(column.point, page.list, "TOPLEFT", column.x, style.LIST_TOP_GAP)
            text:SetJustifyH(column.justify)
            text:SetText(L[labelKey])
        end
    end

    local buttonSpace = 0
    if spec.button then
        local button = CreateFrame("Button", nil, page, C.PANEL_BUTTON_TEMPLATE)
        button:SetSize(style.BUTTON_WIDTH, style.BUTTON_HEIGHT)
        button:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -style.PADDING, style.PADDING)
        button:SetText(L[spec.button.label])
        button:SetScript("OnClick", spec.button.onClick)
        button:SetScript("OnEnter", function(self)
            ShowTooltip(self, L[spec.button.label], { L[spec.button.tip] })
        end)
        button:SetScript("OnLeave", HideTooltip)
        page.button = button
        buttonSpace = style.BUTTON_WIDTH + style.COLUMN_GAP
    end
    page.footer = page:CreateFontString(nil, "OVERLAY", C.FONTS.WINDOW_FOOTER)
    page.footer:SetPoint("LEFT", page, "BOTTOMLEFT", style.PADDING, style.PADDING + style.FOOTER_HEIGHT / 2)
    page.footer:SetPoint("RIGHT", page, "BOTTOMRIGHT", -(style.PADDING + buttonSpace), style.PADDING + style.FOOTER_HEIGHT / 2)
    page.footer:SetJustifyH("LEFT")

    -- Switching tabs: the page fades in.
    page.fade = page:CreateAnimationGroup()
    local fadeIn = page.fade:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(style.PAGE_FADE_SECONDS)
    page.refresh = spec.refresh
    return page
end

function Window.RefreshPage(page)
    Value.Safely(page.refresh, page)
end

-- Catch value ---------------------------------------------------------------------------------

function Window.ValueEntry(entry)
    local best, learn = entry.best, entry.learn
    local row = {
        itemID = entry.itemID,
        icon = GetItemIcon(entry.itemID),
        title = Value.ItemName(entry.itemID),
        sub = C.WINDOW.COUNT_FORMAT:format(entry.count),
        each = C.WINDOW.NO_VALUE,
        total = C.WINDOW.NO_VALUE,
        learnText = learn and Value.DescribeLearn(learn) or nil,
    }
    if best then
        row.tag = L["TAG_" .. best.kind]
        row.tagColor = C.COLORS.TAG[best.kind]
        if best.kind == C.VALUE_KIND.COOK or best.kind == C.VALUE_KIND.CRAFT then
            row.note = Value.ItemName(best.creates, best.recipe.name)
            if best.costUnknown then
                row.note = row.note .. " " .. L.VALUE_PLUS_OTHER
            end
        elseif best.kind == C.VALUE_KIND.AUCTION then
            row.note, row.noteColor = L.VALUE_NOTE_AUCTION, C.COLORS.MUTED
        elseif best.kind == C.VALUE_KIND.OPEN then
            row.note, row.noteColor = L.VALUE_NOTE_OPEN, C.COLORS.MUTED
        elseif best.kind == C.VALUE_KIND.LOCKED then
            row.note, row.noteColor = L.VALUE_NOTE_LOCKED, C.COLORS.MUTED
        end
        if best.kind ~= C.VALUE_KIND.OPEN then
            row.each = Value.Money(best.value)
            row.total = Value.Money(entry.total)
        end
    else
        row.note, row.noteColor = L.VALUE_NO_VALUE, C.COLORS.MUTED
    end
    if learn then
        row.detail, row.detailColor = row.learnText, C.COLORS.VALUE_LEARN
    else
        local uses = Value.GetOtherUses(entry.itemID, Value.GetOptions(entry.itemID))
        if #uses > 0 then
            row.detail = L.VALUE_ALSO_USED:format(table.concat(uses, C.LIST_SEPARATOR))
        end
    end
    return row
end

function Window.RefreshValue(page)
    local tiles = page.tiles
    if not Value.API() then
        for _, tile in ipairs(tiles) do
            Window.SetTile(tile, nil)
        end
        Window.BuildChips(page, {}, {}, nil, 0)
        Window.SetListData(page.list, {})
        page.footer:SetText(L.VALUE_NEEDS_AUCTIONATOR)
        return
    end
    local catches = Value.CollectCatches()
    local bestTotal, vendorTotal, missing, oldest = 0, 0, false, 0
    local counts = {}
    for _, entry in ipairs(catches) do
        bestTotal = bestTotal + entry.total
        vendorTotal = vendorTotal + entry.vendorTotal
        missing = missing or entry.noAuctionPrice
        oldest = math.max(oldest, entry.age or 0)
        local kind = entry.best and entry.best.kind
        if kind then
            counts[kind] = (counts[kind] or 0) + 1
        end
    end
    Window.SetTile(tiles[1], Value.Money(bestTotal), C.COLORS.VALUE)
    Window.SetTile(tiles[2], Value.Money(vendorTotal))
    Window.SetTile(tiles[3], C.WINDOW.GAIN_FORMAT:format(Value.Money(math.max(0, bestTotal - vendorTotal))), C.COLORS.HUD_GOOD)
    Window.BuildChips(page, counts, C.VALUE_KIND_ORDER, function(kind) return L["TAG_" .. kind] end, #catches)

    local rows = {}
    for _, entry in ipairs(catches) do
        local kind = entry.best and entry.best.kind
        if page.filter == C.FILTER_ALL or kind == page.filter then
            table.insert(rows, Window.ValueEntry(entry))
        end
    end
    Window.SetListData(page.list, rows)

    local notes = {}
    if #catches == 0 then
        table.insert(notes, L.VALUE_EMPTY)
    elseif missing then
        table.insert(notes, L.VALUE_MISSING_PRICES)
    elseif oldest > C.VALUE.PRICE_OLD_DAYS then
        table.insert(notes, L.VALUE_OLD_PRICES:format(oldest))
    end
    -- No profession window opened yet: their uses can't count.
    if #catches > 0 and not next(db.craftRecipes or {}) and not next(db.knownRecipes or {}) then
        table.insert(notes, L.VALUE_PROFESSIONS_HINT)
    end
    page.footer:SetText(#notes > 0 and table.concat(notes, " ") or L.VALUE_FOOTER_PRICES)
end

-- Fishing gear --------------------------------------------------------------------------------

function Window.GearEntry(itemID, state, bonus, sub)
    return {
        itemID = itemID,
        icon = GetItemIcon(itemID),
        title = Value.ItemName(itemID),
        sub = sub,
        tag = L["TAG_" .. state],
        tagColor = C.COLORS.TAG[state],
        each = bonus and bonus > 0 and C.WINDOW.BONUS_FORMAT:format(bonus) or "",
    }
end

function Window.SlotName(slot)
    local name = _G[C.SLOT_NAME_GLOBALS[slot] or ""]
    return type(name) == "string" and name or ""
end

-- Poles, lures and pieces with a Fishing bonus, worn or in your bags.
function Window.CollectGear()
    local groups = { POLES = {}, LURES = {}, PIECES = {} }
    local seen = {}
    local worn = GetEquippedItemID(C.MAIN_HAND_SLOT)
    local usedPole = IsFishingPole(worn) and worn or FindFishingPoleInBags()
    if IsFishingPole(worn) then
        seen[worn] = true
        table.insert(groups.POLES, Window.GearEntry(worn, C.GEAR_STATE.WORN, Gear.GetBonus(worn), Window.SlotName(C.MAIN_HAND_SLOT)))
    end
    local planned = {}
    for _, pick in ipairs(Gear.GetPlan()) do
        planned[pick.itemID] = true
    end
    for _, slot in pairs(C.GEAR_SLOTS) do
        local itemID = GetEquippedItemID(slot)
        local bonus = itemID and Gear.GetBonus(itemID) or 0
        if bonus > 0 and not seen[itemID] then
            seen[itemID] = true
            table.insert(groups.PIECES, Window.GearEntry(itemID, C.GEAR_STATE.WORN, bonus, Window.SlotName(slot)))
        end
    end
    for bag = C.FIRST_BAG, C.LAST_ITEM_BAG do
        for bagSlot = 1, GetContainerNumSlots(bag) or 0 do
            local itemID = GetContainerItemID(bag, bagSlot)
            if itemID and not IsSecret(itemID) and not seen[itemID] then
                if IsFishingPole(itemID) then
                    seen[itemID] = true
                    local state = itemID == usedPole and C.GEAR_STATE.BEST or C.GEAR_STATE.SPARE
                    table.insert(groups.POLES, Window.GearEntry(itemID, state, Gear.GetBonus(itemID), Window.SlotName(C.MAIN_HAND_SLOT)))
                else
                    local slot = Gear.GetSlot(itemID)
                    local bonus = slot and Gear.GetBonus(itemID) or 0
                    if bonus > 0 then
                        seen[itemID] = true
                        local state = planned[itemID] and C.GEAR_STATE.GOES_ON or C.GEAR_STATE.SPARE
                        table.insert(groups.PIECES, Window.GearEntry(itemID, state, bonus, Window.SlotName(slot)))
                    end
                end
            end
        end
    end
    local bestLure = FindBestLure()
    for _, lure in ipairs(C.LURES) do
        local count = GetItemCount(lure.itemID) or 0
        if count > 0 then
            local state = lure.itemID == bestLure and C.GEAR_STATE.BEST or C.GEAR_STATE.SPARE
            table.insert(groups.LURES, Window.GearEntry(lure.itemID, state, lure.bonus, C.WINDOW.COUNT_FORMAT:format(count)))
        end
    end
    return groups, usedPole, bestLure
end

function Window.RefreshGear(page)
    local groups, pole, lure = Window.CollectGear()
    local rank, bonus = Hud.GetFishingSkill()
    local skill = rank and (bonus > 0 and C.WINDOW.SKILL_FORMAT:format(rank, bonus) or tostring(rank)) or nil
    Window.SetTile(page.tiles[1], skill, C.COLORS.VALUE)
    Window.SetTile(page.tiles[2], pole and Value.ItemName(pole) or L.GEAR_NONE_SHORT)
    Window.SetTile(page.tiles[3], lure and Value.ItemName(lure) or L.GEAR_NONE_SHORT)

    local counts, total = {}, 0
    for _, key in ipairs(C.GEAR_FILTER_ORDER) do
        counts[key] = #groups[key]
        total = total + counts[key]
    end
    Window.BuildChips(page, counts, C.GEAR_FILTER_ORDER, function(key) return L["GEAR_SECTION_" .. key] end, total)

    local rows = {}
    for _, key in ipairs(C.GEAR_FILTER_ORDER) do
        if #groups[key] > 0 and (page.filter == C.FILTER_ALL or page.filter == key) then
            -- With everything shown, each group gets its title.
            if page.filter == C.FILTER_ALL then
                table.insert(rows, { section = L["GEAR_SECTION_" .. key] })
            end
            for _, entry in ipairs(groups[key]) do
                table.insert(rows, entry)
            end
        end
    end
    Window.SetListData(page.list, rows)
    page.footer:SetText(total == 0 and L.GEAR_EMPTY or L.GEAR_FOOTER)
end

-- Recipes -------------------------------------------------------------------------------------

-- What you fished: everything you looted while fishing, and anything in your bags now.
function Window.CaughtItems()
    local caught = {}
    for itemID in pairs(accountDB and accountDB.caught or {}) do
        caught[itemID] = true
    end
    for bag = C.FIRST_BAG, C.LAST_ITEM_BAG do
        for bagSlot = 1, GetContainerNumSlots(bag) or 0 do
            local itemID = GetContainerItemID(bag, bagSlot)
            if itemID and not IsSecret(itemID) and Value.IsCatch(itemID) then
                caught[itemID] = true
            end
        end
    end
    return caught
end

function Window.RecipeNeeds(recipe, itemID)
    for index = 1, #recipe.reagents, 2 do
        if recipe.reagents[index] == itemID then
            return recipe.reagents[index + 1]
        end
    end
    return 1
end

-- Every recipe that uses something you fished, with what it earns per fish.
function Window.CollectRecipes()
    local list, seen = {}, {}
    local priced = Value.API() ~= nil
    local function Add(itemID, recipeID, recipe, kind, known)
        if seen[recipeID] or not recipe then
            return
        end
        seen[recipeID] = true
        local option = Value.RecipeOption(itemID, recipeID, recipe, kind, known)
        local status = known and C.RECIPE_FILTER.KNOWN or C.RECIPE_FILTER.LEARN
        local teacher = not known and recipe.items and recipe.items[1] and GetItemName(recipe.items[1])
        local uses = Value.ItemName(itemID) .. " " .. C.WINDOW.COUNT_FORMAT:format(Window.RecipeNeeds(recipe, itemID))
        table.insert(list, {
            status = status,
            value = priced and option.value or nil,
            itemID = recipe.creates,
            icon = GetItemIcon(recipe.creates),
            title = Value.ItemName(recipe.creates, recipe.name),
            sub = L.RECIPES_USES:format(uses),
            tag = L["TAG_" .. status],
            tagColor = C.COLORS.TAG[status],
            note = L["TAG_" .. kind],
            noteColor = C.COLORS.MUTED,
            detail = teacher and L.RECIPES_FROM:format(teacher) or nil,
            detailColor = C.COLORS.VALUE_LEARN,
            each = priced and option.value > 0 and Value.Money(option.value) or C.WINDOW.NO_VALUE,
        })
    end
    for itemID in pairs(Window.CaughtItems()) do
        for _, recipeID in ipairs(Value.byReagent[itemID] or {}) do
            Add(itemID, recipeID, ns.COOKING_RECIPES[recipeID], C.VALUE_KIND.COOK, Value.KnowsRecipe(recipeID))
        end
        for _, recipeID in ipairs(Value.craftByReagent[itemID] or {}) do
            local recipe = db.craftRecipes[recipeID]
            Add(itemID, recipeID, recipe, C.VALUE_KIND.CRAFT, recipe and recipe.known ~= false)
        end
    end
    table.sort(list, function(a, b)
        if (a.value or 0) ~= (b.value or 0) then
            return (a.value or 0) > (b.value or 0)
        end
        return a.title < b.title
    end)
    return list
end

function Window.RefreshRecipes(page)
    local all = Window.CollectRecipes()
    local counts, bestLearn = {}, nil
    for _, entry in ipairs(all) do
        counts[entry.status] = (counts[entry.status] or 0) + 1
        if entry.status == C.RECIPE_FILTER.LEARN and entry.value and entry.value > 0
            and (not bestLearn or entry.value > bestLearn.value) then
            bestLearn = entry
        end
    end
    Window.SetTile(page.tiles[1], tostring(counts.KNOWN or 0))
    Window.SetTile(page.tiles[2], tostring(counts.LEARN or 0), C.COLORS.VALUE_LEARN)
    Window.SetTile(page.tiles[3], bestLearn and bestLearn.title or nil, C.COLORS.VALUE)
    Window.BuildChips(page, counts, C.RECIPE_FILTER_ORDER, function(key) return L["TAG_" .. key] end, #all)
    local rows = {}
    for _, entry in ipairs(all) do
        if page.filter == C.FILTER_ALL or entry.status == page.filter then
            table.insert(rows, entry)
        end
    end
    Window.SetListData(page.list, rows)
    local footer = #all == 0 and L.RECIPES_EMPTY or L.RECIPES_FOOTER
    if #all > 0 and not Value.API() then
        footer = L.RECIPES_NO_PRICES
    end
    page.footer:SetText(footer)
end

-- The window ----------------------------------------------------------------------------------

Window.PAGE_SPECS = {
    VALUE = {
        tiles = { "VALUE_TILE_ADVICE", "VALUE_TILE_VENDOR", "VALUE_TILE_GAIN" },
        columns = { "COL_ITEM", "COL_USE", "COL_EACH", "COL_TOTAL" },
        refresh = Window.RefreshValue,
        button = { label = "VALUE_SCAN", tip = "VALUE_SCAN_TIP", onClick = function() Value.Safely(Value.Scan) end },
    },
    GEAR = {
        tiles = { "GEAR_TILE_SKILL", "GEAR_TILE_POLE", "GEAR_TILE_LURE" },
        columns = { "COL_PIECE", "COL_STATUS", "COL_BONUS", false },
        refresh = Window.RefreshGear,
    },
    RECIPES = {
        tiles = { "RECIPES_TILE_KNOWN", "RECIPES_TILE_LEARN", "RECIPES_TILE_BEST" },
        columns = { "COL_RECIPE", "COL_STATUS", "COL_PER_FISH", false },
        refresh = Window.RefreshRecipes,
    },
}

function Window.CreateTab(frame, key, previous, top)
    local style = C.WINDOW
    local tab = CreateFrame("Button", nil, frame)
    tab.key = key
    tab.label = L["TAB_" .. key]
    tab.text = tab:CreateFontString(nil, "OVERLAY", C.FONTS.TAB)
    tab.text:SetPoint("CENTER")
    tab.text:SetText(tab.label)
    tab:SetSize(Window.TextWidth(tab.text, tab.label), style.TAB_HEIGHT)
    if previous then
        tab:SetPoint("LEFT", previous, "RIGHT", style.TAB_GAP, 0)
    else
        tab:SetPoint("TOPLEFT", frame, "TOPLEFT", style.PADDING, -top)
    end
    tab.underline = tab:CreateTexture(nil, "ARTWORK")
    tab.underline:SetColorTexture(unpack(C.COLORS.TAB_ACTIVE))
    tab.underline:SetHeight(style.TAB_UNDERLINE)
    tab.underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
    tab.underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
    tab:SetScript("OnClick", function()
        Window.Select(key)
    end)
    tab:SetScript("OnEnter", function(self)
        self.text:SetTextColor(unpack(C.COLORS.TAB_ACTIVE))
    end)
    tab:SetScript("OnLeave", function(self)
        Window.StyleTab(self)
    end)
    return tab
end

function Window.StyleTab(tab)
    local selected = tab.key == Window.current
    tab.text:SetTextColor(unpack(selected and C.COLORS.TAB_ACTIVE or C.COLORS.TAB_IDLE))
    tab.underline:SetShown(selected)
end

function Window.Create()
    local style = C.WINDOW
    local layout = Window.Layout()
    local frame = CreateFrame("Frame", C.WINDOW_FRAME_NAME, UIParent, BackdropTemplateMixin and C.BACKDROP_TEMPLATE or nil)
    frame:SetSize(style.WIDTH, layout.height)
    frame:SetPoint(C.LAYOUT.DEFAULT_POINT)
    frame:SetFrameStrata(style.STRATA)
    Fx.ApplyBackdrop(frame, C.COLORS.HUD_BORDER)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag(C.DRAG_BUTTON)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    -- Header, like the HUD's: icon, name, close.
    local headerY = -(style.PADDING + style.HEADER_HEIGHT / 2)
    local logo = frame:CreateTexture(nil, "ARTWORK")
    logo:SetSize(style.LOGO_SIZE, style.LOGO_SIZE)
    logo:SetPoint("LEFT", frame, "TOPLEFT", style.PADDING, headerY)
    logo:SetTexture(C.MINIMAP_ICON)
    logo:SetTexCoord(unpack(C.HUD.ICON_TEXCOORD))
    local title = frame:CreateFontString(nil, "OVERLAY", C.FONTS.WINDOW_TITLE)
    title:SetPoint("LEFT", logo, "RIGHT", style.TEXT_GAP, 0)
    title:SetText(L.TITLE)
    local hasClose, close = pcall(CreateFrame, "Button", nil, frame, C.CLOSE_BUTTON_TEMPLATE)
    if hasClose and close then
        close:SetSize(style.ICON_BUTTON_SIZE, style.ICON_BUTTON_SIZE)
        close:SetPoint("RIGHT", frame, "TOPRIGHT", -style.PADDING, headerY)
        close:SetScript("OnClick", function()
            frame:Hide()
        end)
    end

    -- Tabs, with a line under them.
    Window.tabs = {}
    local previous
    for _, key in ipairs(C.WINDOW_TAB_ORDER) do
        previous = Window.CreateTab(frame, key, previous, layout.tabs)
        Window.tabs[key] = previous
    end
    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(C.COLORS.HUD_DIVIDER))
    divider:SetHeight(style.DIVIDER_HEIGHT)
    divider:SetPoint("TOPLEFT", frame, "TOPLEFT", style.PADDING, -layout.divider)
    divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -style.PADDING, -layout.divider)

    Window.pages = {}
    for _, key in ipairs(C.WINDOW_TAB_ORDER) do
        Window.pages[key] = Window.CreatePage(frame, key, Window.PAGE_SPECS[key])
    end

    -- It slides up a little and fades in when it opens.
    local appear = frame:CreateAnimationGroup()
    local drop = appear:CreateAnimation("Translation")
    drop:SetOffset(0, -style.APPEAR_OFFSET)
    drop:SetDuration(0)
    drop:SetOrder(1)
    local rise = appear:CreateAnimation("Translation")
    rise:SetOffset(0, style.APPEAR_OFFSET)
    rise:SetDuration(style.APPEAR_SECONDS)
    rise:SetOrder(2)
    local fadeIn = appear:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(style.APPEAR_SECONDS)
    fadeIn:SetOrder(2)
    Window.appear = appear

    frame:SetScript("OnShow", function()
        Window.appear:Play()
        Window.Refresh()
    end)
    -- Esc closes it, like the game's own windows.
    if UISpecialFrames then
        table.insert(UISpecialFrames, C.WINDOW_FRAME_NAME)
    end
    frame:Hide()
    Window.frame = frame
    Window.current = C.WINDOW_TAB.VALUE
end

function Window.Select(key)
    local changed = Window.current ~= key
    Window.current = key
    for tabKey, page in pairs(Window.pages) do
        page:SetShown(tabKey == key)
        Window.StyleTab(Window.tabs[tabKey])
    end
    local page = Window.pages[key]
    if changed then
        page.fade:Stop()
        page.fade:Play()
    end
    if Window.frame:IsShown() then
        Window.RefreshPage(page)
    end
end

function Window.Refresh()
    if Window.frame and Window.frame:IsShown() then
        Window.Select(Window.current)
    end
end

-- Opens it on that tab; asked again for the tab already showing, it closes.
function Window.Toggle(key)
    Value.Safely(function()
        if not Window.frame then
            Window.Create()
        end
        if Window.frame:IsShown() and Window.current == key then
            Window.frame:Hide()
            return
        end
        Window.Select(key)
        Window.frame:Show()
    end)
end

function Value.Toggle()
    Window.Toggle(C.WINDOW_TAB.VALUE)
end

function Value.RefreshIfShown()
    if Window.frame and Window.frame:IsShown() then
        Value.Safely(Window.Refresh)
    end
end

-- For events that can come in bursts (item data, Auctionator's database): one refresh.
function Value.ScheduleRefresh()
    if Value.refreshPending or not (Window.frame and Window.frame:IsShown()) then
        return
    end
    Value.refreshPending = true
    C_Timer.After(C.VALUE.REFRESH_DELAY, function()
        Value.refreshPending = false
        Value.RefreshIfShown()
    end)
end

-- Any error here is said in the chat instead of failing in silence.
function Value.Safely(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        PrintMessage(L.DEBUG_ERROR:format(tostring(err)))
    end
    return ok
end

-- The auction house is open: by its event, or by its window (Auctionator checks the same).
function Value.IsAuctionOpen()
    return Value.auctionOpen or (AuctionHouseFrame and AuctionHouseFrame:IsShown())
        or (AuctionFrame and AuctionFrame:IsShown()) or false
end

-- With the auction house open, Auctionator searches what you caught, the dishes you
-- could cook with it and their other ingredients, and keeps the prices.
function Value.Scan()
    local api = Value.API()
    local search = api and (api.MultiSearchExact or api.MultiSearch)
    if not search then
        PrintMessage(L.VALUE_NEEDS_AUCTIONATOR)
        return
    end
    if not Value.IsAuctionOpen() then
        PrintMessage(L.VALUE_SCAN_NEEDS_AH)
        return
    end
    local names, seen = {}, {}
    local function Add(itemID)
        local name = GetItemName(itemID)
        if name and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    for _, entry in ipairs(Value.CollectCatches()) do
        Add(entry.itemID)
        local function AddRecipe(recipe)
            Add(recipe.creates)
            for index = 1, #recipe.reagents, 2 do
                Add(recipe.reagents[index])
            end
        end
        for _, recipeID in ipairs(Value.byReagent[entry.itemID] or {}) do
            AddRecipe(ns.COOKING_RECIPES[recipeID])
        end
        for _, recipeID in ipairs(Value.craftByReagent[entry.itemID] or {}) do
            AddRecipe(db.craftRecipes[recipeID])
        end
    end
    if #names == 0 then
        PrintMessage(L.VALUE_EMPTY)
        return
    end
    local ok, err = pcall(search, ADDON_NAME, names)
    if ok then
        PrintMessage(L.VALUE_SCAN_STARTED:format(#names))
    else
        PrintMessage(L.DEBUG_ERROR:format(tostring(err)))
    end
end

-- Auctionator says when its prices change.
function Value.RegisterPriceUpdates()
    local api = Value.API()
    if Value.registered or not (api and api.RegisterForDBUpdate) then
        return
    end
    Value.registered = pcall(api.RegisterForDBUpdate, ADDON_NAME, Value.ScheduleRefresh)
end

-- Options page ---------------------------------------------------------------------------
-- Options > AddOns > Fishful Thinking. Everything that can be configured lives here.

local SESSION_OPTIONS = { sessionTweaks = true, soundMode = true, markBobber = true }

local function ApplyOptions()
    if InCombatLockdown() then
        optionsApplyPending = true
        return
    end
    optionsApplyPending = false
    Hud.ApplyVisibility()
    if minimapButton then
        minimapButton:SetShown(GetOption("showMinimapButton"))
    end
    UpdateAlertDriver()
    if reelKeysActive and not GetOption("reelWithFishKey") then
        SetReelKeys(false)
    end
    SyncMacros()
end

local function SetOption(key, value)
    db.options[key] = value
    -- Turning it back on tries again, in case the game allows it now.
    if key == "combatAutoEquip" and value then
        db.directEquipBlocked = nil
    end
    -- Tweaks and sound mode change which game settings a session touches: restore
    -- yours now; the next cast applies the new choice.
    if SESSION_OPTIONS[key] then
        EndFishingSession()
    end
    if InCombatLockdown() then
        optionsApplyPending = true
        PrintMessage(L.OPTIONS_AFTER_COMBAT)
    else
        ApplyOptions()
    end
    RefreshOptions()
end

local function GetLanguageChoiceName(shortCode)
    if shortCode == C.LANGUAGE_AUTO then
        return L.LANGUAGE_AUTO_NAME
    end
    return C.LANGUAGE_NAMES[C.LANGUAGE_CODES[shortCode]]
end

local function IsLanguageChoice(shortCode)
    local saved = accountDB and accountDB.language
    if shortCode == C.LANGUAGE_AUTO then
        return saved == C.LANGUAGE_AUTO
    end
    return (saved or C.DEFAULT_LANGUAGE) == C.LANGUAGE_CODES[shortCode]
end

local function SetLanguage(shortCode)
    local code = C.LANGUAGE_CODES[shortCode]
    if not code then
        return false
    end
    accountDB.language = (code ~= C.DEFAULT_LANGUAGE) and code or nil
    ApplyLanguage()
    PrintMessage(L.LANGUAGE_SET:format(DescribeLanguageSetting()))
    RefreshOptions()
    return true
end

local OPTION_ACTIONS = {}

function OPTION_ACTIONS.RESET_PANEL()
    ResetPanelPosition()
end

function OPTION_ACTIONS.OPEN_WINDOW()
    Value.Toggle()
end

function OPTION_ACTIONS.TEST_ALERT()
    if InCombatLockdown() then
        PrintMessage(L.IN_COMBAT)
        return
    end
    TestCombatAlert()
end

RefreshOptions = function()
    for _, control in ipairs(optionControls) do
        control.Refresh()
    end
end

OpenOptions = function()
    if optionsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(optionsCategory:GetID())
    elseif optionsCanvas and InterfaceOptionsFrame_OpenToCategory then
        -- The first call only opens the frame on some clients.
        InterfaceOptionsFrame_OpenToCategory(optionsCanvas)
        InterfaceOptionsFrame_OpenToCategory(optionsCanvas)
    end
end

local function AttachTooltip(region, title, tip)
    region:SetScript("OnEnter", function(self)
        ShowTooltip(self, title, { tip })
    end)
    region:SetScript("OnLeave", HideTooltip)
end

-- How tall a text came out, or a fair guess while the game hasn't measured it.
function Options.TextHeight(fontString)
    local height = fontString.GetStringHeight and fontString:GetStringHeight()
    if type(height) ~= "number" or height <= 0 then
        return C.OPTIONS_LAYOUT.FALLBACK_TEXT_HEIGHT
    end
    return height
end

-- A text that wraps within the page, placed at y; returns it and the y below it.
function Options.AddText(content, font, text, x, y, width)
    local layout = C.OPTIONS_LAYOUT
    local fontString = content:CreateFontString(nil, "ARTWORK", font)
    fontString:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    fontString:SetWidth(width or layout.WIDTH)
    fontString:SetJustifyH("LEFT")
    fontString:SetText(text)
    return fontString, y - Options.TextHeight(fontString)
end

-- Switches -------------------------------------------------------------------------------------
-- A track with a knob: grey on the left when off, gold on the right when on. The knob
-- slides when you click it.

function Options.PlaceKnob(switch, on)
    local layout = C.OPTIONS_LAYOUT
    switch.knob:ClearAllPoints()
    if on then
        switch.knob:SetPoint("RIGHT", switch, "RIGHT", -layout.KNOB_INSET, 0)
    else
        switch.knob:SetPoint("LEFT", switch, "LEFT", layout.KNOB_INSET, 0)
    end
end

function Options.CreateSwitch(parent)
    local layout = C.OPTIONS_LAYOUT
    local switch = CreateFrame("CheckButton", nil, parent, BackdropTemplateMixin and C.BACKDROP_TEMPLATE or nil)
    switch:SetSize(layout.SWITCH_WIDTH, layout.SWITCH_HEIGHT)
    if switch.SetBackdrop then
        switch:SetBackdrop(C.WINDOW.TILE_BACKDROP)
    end
    switch.knob = switch:CreateTexture(nil, "OVERLAY")
    switch.knob:SetSize(layout.KNOB_SIZE, layout.KNOB_SIZE)
    switch.slide = switch.knob:CreateAnimationGroup()
    switch.move = switch.slide:CreateAnimation("Translation")
    switch.move:SetDuration(layout.SWITCH_SECONDS)
    if switch.move.SetSmoothing then
        switch.move:SetSmoothing("OUT")
    end
    switch.slide:SetScript("OnFinished", function()
        Options.PlaceKnob(switch, switch.target)
    end)
    return switch
end

-- animate: the knob slides from the other side (a click); otherwise it just goes there.
function Options.ShowSwitch(switch, on, animate)
    if switch.target == on then
        return
    end
    local colors = C.COLORS
    local layout = C.OPTIONS_LAYOUT
    local first = switch.target == nil
    switch.target = on
    switch.knob:SetColorTexture(unpack(on and colors.SWITCH_ON_KNOB or colors.SWITCH_OFF_KNOB))
    if switch.SetBackdropColor then
        switch:SetBackdropColor(unpack(on and colors.SWITCH_ON_TRACK or colors.HUD_BAR_BACK))
        switch:SetBackdropBorderColor(unpack(on and colors.HUD_BORDER or colors.HUD_DIVIDER))
    end
    switch.slide:Stop()
    if animate and not first then
        local travel = layout.SWITCH_WIDTH - layout.KNOB_SIZE - layout.KNOB_INSET * 2
        Options.PlaceKnob(switch, not on)
        switch.move:SetOffset(on and travel or -travel, 0)
        switch.slide:Play()
    else
        Options.PlaceKnob(switch, on)
    end
end

-- Builders: each places one entry at y and returns the y below it --------------------------

local OPTION_BUILDERS = {}

function OPTION_BUILDERS.header(content, entry, y)
    local layout = C.OPTIONS_LAYOUT
    local _, below = Options.AddText(content, C.FONTS.OPTIONS_HEADER, L[entry.text], layout.LEFT, y - layout.HEADER_GAP)
    return below - layout.HEADER_BOTTOM
end

function OPTION_BUILDERS.note(content, entry, y)
    local layout = C.OPTIONS_LAYOUT
    local _, below = Options.AddText(content, C.FONTS.OPTIONS_HINT, L[entry.text], layout.LEFT, y)
    return below - layout.ROW_GAP
end

function OPTION_BUILDERS.switch(content, entry, y)
    local layout = C.OPTIONS_LAYOUT
    local x = layout.LEFT + (entry.requires and layout.INDENT or 0)
    local textX = x + layout.SWITCH_WIDTH + layout.SWITCH_GAP
    local textWidth = layout.LEFT + layout.WIDTH - textX
    local switch = Options.CreateSwitch(content)
    switch.option = entry.option
    switch:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    local label, belowLabel = Options.AddText(content, C.FONTS.OPTIONS_LABEL, L[entry.label], textX, y - layout.LABEL_TOP, textWidth)
    local hint, below = Options.AddText(content, C.FONTS.OPTIONS_HINT, L[entry.tip], textX, belowLabel - layout.LABEL_HINT_GAP, textWidth)
    switch:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        Options.ShowSwitch(self, on, true)
        SetOption(entry.option, on)
    end)

    -- Clicking the name or the explanation flips it too.
    local hitArea = CreateFrame("Button", nil, content)
    hitArea:SetPoint("TOPLEFT", label, "TOPLEFT")
    hitArea:SetPoint("BOTTOMRIGHT", hint, "BOTTOMRIGHT")
    hitArea:SetScript("OnClick", function()
        if switch:IsEnabled() then
            switch:Click()
        end
    end)

    table.insert(optionControls, {
        Refresh = function()
            local on = GetOption(entry.option) and true or false
            switch:SetChecked(on)
            Options.ShowSwitch(switch, on, false)
            local enabled = not entry.requires or GetOption(entry.requires)
            switch:SetEnabled(enabled)
            local alpha = enabled and 1 or layout.DISABLED_ALPHA
            for _, part in ipairs({ switch, label, hint }) do
                part:SetAlpha(alpha)
            end
        end,
    })
    return math.min(y - layout.SWITCH_HEIGHT, below) - layout.ROW_GAP
end

function OPTION_BUILDERS.buttons(content, entry, y)
    local layout = C.OPTIONS_LAYOUT
    for index, info in ipairs(entry.buttons) do
        local button = CreateFrame("Button", nil, content, C.PANEL_BUTTON_TEMPLATE)
        button:SetSize(layout.BUTTON_WIDTH, layout.BUTTON_HEIGHT)
        button:SetPoint("TOPLEFT", content, "TOPLEFT", layout.LEFT + (index - 1) * (layout.BUTTON_WIDTH + layout.BUTTON_GAP), y)
        button:SetText(L[info.label])
        button:SetScript("OnClick", OPTION_ACTIONS[info.action])
        AttachTooltip(button, L[info.label], L[info.tip])
    end
    return y - layout.BUTTON_HEIGHT - layout.ROW_GAP
end

function OPTION_BUILDERS.language(content, entry, y)
    local layout = C.OPTIONS_LAYOUT
    local label, belowLabel = Options.AddText(content, C.FONTS.OPTIONS_LABEL, L[entry.label], layout.LEFT, y)
    local _, belowHint = Options.AddText(content, C.FONTS.OPTIONS_HINT, L[entry.tip], layout.LEFT, belowLabel - layout.LABEL_HINT_GAP)
    local controlY = belowHint - layout.CHIPS_TOP_GAP

    local ok, dropdown = pcall(CreateFrame, C.DROPDOWN_FRAME_TYPE, nil, content, C.DROPDOWN_TEMPLATE)
    if ok and dropdown and dropdown.SetupMenu then
        dropdown:SetWidth(layout.DROPDOWN_WIDTH)
        dropdown:SetPoint("TOPLEFT", content, "TOPLEFT", layout.LEFT, controlY)
        dropdown:SetupMenu(function(_, root)
            for _, shortCode in ipairs(C.LANGUAGE_CODE_ORDER) do
                root:CreateRadio(GetLanguageChoiceName(shortCode),
                    function() return IsLanguageChoice(shortCode) end,
                    function() SetLanguage(shortCode) end)
            end
        end)
        table.insert(optionControls, {
            Refresh = function()
                if dropdown.GenerateMenu then
                    dropdown:GenerateMenu()
                end
            end,
        })
        return controlY - layout.BUTTON_HEIGHT - layout.ROW_GAP
    end

    -- Without the dropdown template: a button that goes through the languages.
    local button = CreateFrame("Button", nil, content, C.PANEL_BUTTON_TEMPLATE)
    button:SetSize(layout.DROPDOWN_WIDTH, layout.BUTTON_HEIGHT)
    button:SetPoint("TOPLEFT", content, "TOPLEFT", layout.LEFT, controlY)
    button:SetScript("OnClick", function()
        local order = C.LANGUAGE_CODE_ORDER
        for index, shortCode in ipairs(order) do
            if IsLanguageChoice(shortCode) then
                SetLanguage(order[index % #order + 1])
                return
            end
        end
        SetLanguage(order[1])
    end)
    table.insert(optionControls, {
        Refresh = function()
            for _, shortCode in ipairs(C.LANGUAGE_CODE_ORDER) do
                if IsLanguageChoice(shortCode) then
                    button:SetText(GetLanguageChoiceName(shortCode))
                end
            end
        end,
    })
    return controlY - layout.BUTTON_HEIGHT - layout.ROW_GAP
end

-- Keys -----------------------------------------------------------------------------------------
-- One chip per key bound to the action, then "+ Add". "+ Add" listens for the next key
-- (keyboard, mouse button, wheel or controller); clicking a key chip listens for its
-- replacement; right-clicking a key chip removes it. Esc cancels.

function Keys.GetActionName(command)
    local name = _G[C.BINDING_NAME_PREFIX .. command]
    return type(name) == "string" and name or command
end

function Keys.GetKeys(command)
    local keys = {}
    for _, key in ipairs({ GetBindingKey(command) }) do
        if key and not IsSecret(key) then
            table.insert(keys, key)
        end
    end
    return keys
end

function Keys.WithModifiers(key)
    local prefix = ""
    for _, modifier in ipairs(C.KEY_MODIFIERS) do
        local isDown = _G[modifier.isDown]
        if isDown and isDown() then
            prefix = prefix .. modifier.prefix
        end
    end
    return prefix .. key
end

function Keys.SaveKeyBindings()
    if SaveBindings and GetCurrentBindingsSet then
        SaveBindings(GetCurrentBindingsSet())
    end
end

function Keys.StopCapture()
    local button = Keys.capture.button
    if not button then
        return
    end
    Keys.capture.button, Keys.capture.row, Keys.capture.replace = nil, nil, nil
    button:EnableKeyboard(false)
    button:EnableMouseWheel(false)
    if button.EnableGamePadButton then
        button:EnableGamePadButton(false)
    end
    RefreshOptions()
end

-- replace: the key being changed, or nil to add one.
function Keys.StartCapture(button, row, replace)
    if InCombatLockdown() then
        PrintMessage(L.IN_COMBAT)
        return
    end
    Keys.StopCapture()
    Keys.capture.button, Keys.capture.row, Keys.capture.replace = button, row, replace
    button:EnableKeyboard(true)
    -- The key goes to this row, not to the game.
    if button.SetPropagateKeyboardInput then
        pcall(button.SetPropagateKeyboardInput, button, false)
    end
    button:EnableMouseWheel(true)
    if button.EnableGamePadButton then
        button:EnableGamePadButton(true)
    end
    RefreshOptions()
end

function Keys.AssignKey(key)
    local row, replace = Keys.capture.row, Keys.capture.replace
    Keys.StopCapture()
    if not row or InCombatLockdown() then
        return
    end
    local command = row.command
    local previous = GetBindingAction and GetBindingAction(key)
    -- Changing a key frees the old one; adding keeps the others.
    if replace and replace ~= key then
        SetBinding(replace)
    end
    if not SetBinding(key, command) then
        return
    end
    Keys.SaveKeyBindings()
    local keyLabel, actionLabel = GetKeyLabel(key), L[row.name]
    if type(previous) == "string" and previous ~= "" and previous ~= command and not IsSecret(previous) then
        PrintMessage(L.KEY_REPLACED:format(keyLabel, actionLabel, Keys.GetActionName(previous)))
    else
        PrintMessage(L.KEY_SET:format(keyLabel, actionLabel))
    end
    RefreshOptions()
end

function Keys.RemoveKey(row, key)
    if InCombatLockdown() then
        PrintMessage(L.IN_COMBAT)
        return
    end
    Keys.StopCapture()
    SetBinding(key)
    Keys.SaveKeyBindings()
    PrintMessage(L.KEY_REMOVED:format(GetKeyLabel(key), L[row.name]))
    RefreshOptions()
end

function Keys.CreateChip(content, keyRow)
    local layout = C.OPTIONS_LAYOUT
    local chip = CreateFrame("Button", nil, content, BackdropTemplateMixin and C.BACKDROP_TEMPLATE or nil)
    chip:SetHeight(layout.CHIP_HEIGHT)
    if chip.SetBackdrop then
        chip:SetBackdrop(C.WINDOW.TILE_BACKDROP)
        chip:SetBackdropColor(unpack(C.COLORS.HUD_BAR_BACK))
    end
    chip.caption = chip:CreateFontString(nil, "OVERLAY", C.FONTS.OPTIONS_CHIP)
    chip.caption:SetPoint("CENTER")
    chip:SetFontString(chip.caption)
    chip:SetHighlightTexture(C.WINDOW.ROW_HIGHLIGHT, C.BLEND_ADD)
    chip:RegisterForClicks(unpack(C.KEY_ROW_CLICKS))
    chip:SetScript("OnClick", function(self, mouseButton)
        if Keys.capture.button == keyRow.add then
            Keys.StopCapture()
        elseif mouseButton == C.RIGHT_BUTTON then
            if self.key then
                Keys.RemoveKey(keyRow.row, self.key)
            end
        else
            Keys.StartCapture(keyRow.add, keyRow.row, self.key)
        end
    end)
    return chip
end

-- "+ Add": also the one that listens while a key is being chosen.
function Keys.CreateAddChip(content, keyRow)
    local layout = C.OPTIONS_LAYOUT
    local add = Keys.CreateChip(content, keyRow)
    local function Take(self, key)
        if Keys.capture.button == self and key then
            Keys.AssignKey(Keys.WithModifiers(key))
        end
    end
    add:SetScript("OnKeyDown", function(self, key)
        if Keys.capture.button ~= self or C.MODIFIER_KEYS[key] then
            return
        end
        if key == C.CANCEL_KEY then
            Keys.StopCapture()
        else
            Keys.AssignKey(Keys.WithModifiers(key))
        end
    end)
    add:SetScript("OnMouseDown", function(self, mouseButton)
        Take(self, C.MOUSE_BUTTON_KEYS[mouseButton])
    end)
    add:SetScript("OnMouseWheel", function(self, delta)
        Take(self, delta > 0 and C.MOUSE_WHEEL_KEYS.UP or C.MOUSE_WHEEL_KEYS.DOWN)
    end)
    add:SetScript("OnGamePadButtonDown", Take)
    add:EnableKeyboard(false)
    add:EnableMouseWheel(false)
    -- While listening, the prompt breathes.
    add.pulse = add.caption:CreateAnimationGroup()
    add.pulse:SetLooping("BOUNCE")
    local fade = add.pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(layout.CAPTURE_PULSE_ALPHA)
    fade:SetDuration(layout.CAPTURE_PULSE_SECONDS)
    return add
end

function Keys.SizeChip(chip, text)
    local layout = C.OPTIONS_LAYOUT
    chip:SetText(text)
    chip:SetWidth(Window.TextWidth(chip.caption, text) + layout.CHIP_PADDING * 2)
end

-- Lays out the chips for the keys bound now, then "+ Add".
function Keys.LayoutChips(keyRow)
    local layout = C.OPTIONS_LAYOUT
    local listening = Keys.capture.button == keyRow.add
    local previous
    local keys = Keys.GetKeys(keyRow.row.command)
    for index, key in ipairs(keys) do
        local chip = keyRow.chips[index] or Keys.CreateChip(keyRow.content, keyRow)
        keyRow.chips[index] = chip
        chip.key = key
        Keys.SizeChip(chip, GetKeyLabel(key))
        local changing = listening and Keys.capture.replace == key
        if chip.SetBackdropBorderColor then
            chip:SetBackdropBorderColor(unpack(changing and C.COLORS.TAB_ACTIVE or C.COLORS.HUD_BORDER))
        end
        chip:ClearAllPoints()
        if previous then
            chip:SetPoint("LEFT", previous, "RIGHT", layout.CHIP_GAP, 0)
        else
            chip:SetPoint("TOPLEFT", keyRow.content, "TOPLEFT", layout.LEFT, keyRow.y)
        end
        chip:Show()
        previous = chip
    end
    for index = #keys + 1, #keyRow.chips do
        keyRow.chips[index]:Hide()
        keyRow.chips[index].key = nil
    end
    local add = keyRow.add
    Keys.SizeChip(add, listening and L.KEY_PRESS_PROMPT or L.KEY_ADD)
    add.caption:SetTextColor(unpack(listening and C.COLORS.TAB_ACTIVE or C.COLORS.CHIP_IDLE))
    if add.SetBackdropBorderColor then
        add:SetBackdropBorderColor(unpack(listening and C.COLORS.TAB_ACTIVE or C.COLORS.HUD_DIVIDER))
    end
    if listening then
        add.pulse:Play()
    else
        add.pulse:Stop()
    end
    add:ClearAllPoints()
    if previous then
        add:SetPoint("LEFT", previous, "RIGHT", layout.CHIP_GAP, 0)
    else
        add:SetPoint("TOPLEFT", keyRow.content, "TOPLEFT", layout.LEFT, keyRow.y)
    end
end

function OPTION_BUILDERS.binding(content, entry, y)
    local layout = C.OPTIONS_LAYOUT
    local _, belowLabel = Options.AddText(content, C.FONTS.OPTIONS_LABEL, L[entry.label], layout.LEFT, y)
    local _, belowHint = Options.AddText(content, C.FONTS.OPTIONS_HINT, L[entry.tip], layout.LEFT, belowLabel - layout.LABEL_HINT_GAP)
    local keyRow = { row = C.BINDING_COMMANDS[entry.command], chips = {}, content = content, y = belowHint - layout.CHIPS_TOP_GAP }
    keyRow.add = Keys.CreateAddChip(content, keyRow)
    table.insert(optionControls, {
        Refresh = function()
            Keys.LayoutChips(keyRow)
        end,
    })
    return keyRow.y - layout.CHIP_HEIGHT - layout.ROW_GAP
end

-- Pages -----------------------------------------------------------------------------------------

-- A page for the game's Options: it scrolls when it doesn't fit. Returns the frame to
-- register and the frame to fill.
function Options.CreateCanvas(name)
    local layout = C.OPTIONS_LAYOUT
    local canvas = CreateFrame("Frame")
    canvas.name = name
    local content = canvas
    local hasScroll, scroll = pcall(CreateFrame, "ScrollFrame", nil, canvas, layout.SCROLL_TEMPLATE)
    if hasScroll and scroll and scroll.SetScrollChild then
        scroll:SetPoint("TOPLEFT")
        scroll:SetPoint("BOTTOMRIGHT", -layout.SCROLL_BAR_WIDTH, 0)
        content = CreateFrame("Frame", nil, scroll)
        content:SetWidth(layout.LEFT * 2 + layout.WIDTH)
        scroll:SetScrollChild(content)
    end
    canvas:SetScript("OnShow", RefreshOptions)
    canvas:SetScript("OnHide", Keys.StopCapture)
    return canvas, content
end

-- Title, explanation and a line; as a header when several sections share one page.
function Options.AddSection(content, section, y, asPage)
    local layout = C.OPTIONS_LAYOUT
    local titleFont = asPage and C.FONTS.OPTIONS_TITLE or C.FONTS.OPTIONS_HEADER
    local _, below = Options.AddText(content, titleFont, L[section.title], layout.LEFT, y)
    _, below = Options.AddText(content, C.FONTS.OPTIONS_DESCRIPTION, L[section.description], layout.LEFT, below - layout.TITLE_GAP)
    below = below - layout.DIVIDER_GAP
    local divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(C.COLORS.HUD_DIVIDER))
    divider:SetSize(layout.WIDTH, layout.DIVIDER_HEIGHT)
    divider:SetPoint("TOPLEFT", content, "TOPLEFT", layout.LEFT, below)
    below = below - layout.DIVIDER_HEIGHT - layout.DIVIDER_GAP
    for _, entry in ipairs(section.items) do
        below = OPTION_BUILDERS[entry.kind](content, entry, below)
    end
    return below
end

function Options.FinishContent(content, canvas, y)
    if content ~= canvas then
        content:SetHeight(-y + C.OPTIONS_LAYOUT.BOTTOM_PADDING)
    end
end

-- Fishful Thinking (General) in Options > AddOns, each other section under it. A client
-- without sub-pages gets every section on the one page.
local function CreateOptionsPanel()
    local layout = C.OPTIONS_LAYOUT
    local sections = C.OPTIONS_SECTIONS
    local canRegisterSettings = Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory
    local withSubpages = (canRegisterSettings and Settings.RegisterCanvasLayoutSubcategory)
        or (not canRegisterSettings and InterfaceOptions_AddCategory)

    local canvas, content = Options.CreateCanvas(L.TITLE)
    optionsCanvas, optionsPanel = canvas, content
    local y = Options.AddSection(content, sections[1], -layout.TOP, true)
    if not withSubpages then
        for index = 2, #sections do
            y = Options.AddSection(content, sections[index], y - layout.HEADER_GAP, false)
        end
    end
    Options.FinishContent(content, canvas, y)

    if canRegisterSettings then
        optionsCategory = Settings.RegisterCanvasLayoutCategory(canvas, L.TITLE)
        Settings.RegisterAddOnCategory(optionsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(canvas)
    end
    if not withSubpages then
        return
    end
    for index = 2, #sections do
        local section = sections[index]
        local subCanvas, subContent = Options.CreateCanvas(L[section.title])
        Options.FinishContent(subContent, subCanvas, Options.AddSection(subContent, section, -layout.TOP, true))
        if canRegisterSettings then
            Settings.RegisterCanvasLayoutSubcategory(optionsCategory, subCanvas, L[section.title])
        else
            subCanvas.parent = L.TITLE
            InterfaceOptions_AddCategory(subCanvas)
        end
    end
end

local function SetUpInterface()
    panelSetupPending = false
    CreatePanel()
    RestorePanelPosition()
    CreateMinimapButton()
    CreateAlertButton()
    CreateOptionsPanel()
    UpdateWeaponActions()
    Hud.ApplyVisibility()
end

-- Diagnostics --------------------------------------------------------------------------

local function FormatValue(value)
    if type(value) == "boolean" then
        return value and L.YES or L.NO
    end
    if value == nil then
        return L.NONE
    end
    return value
end

-- Takes a pcall result and makes it readable.
local function DescribeResult(ok, value, formatter)
    if not ok then
        return L.DEBUG_ERROR:format(tostring(value))
    end
    return (formatter or FormatValue)(value)
end

local function PrintDiagnostics()
    PrintMessage(L.DEBUG_HEADER)
    local function Line(label, value)
        print(L.DEBUG_LINE:format(label, tostring(value)))
    end
    local function KeysFormatter(keys)
        return DescribeKeys(keys) or L.NONE
    end

    Line(L.DEBUG_MAIN_HAND, FormatValue(GetEquippedItemID(C.MAIN_HAND_SLOT)))
    Line(L.DEBUG_POLE_EQUIPPED, FormatValue(IsPoleEquipped()))
    local okState, hasLure, _, source = pcall(GetLureState)
    Line(L.DEBUG_LURE_STATE, DescribeResult(okState, hasLure, function(value)
        return value and (L.YES .. " (" .. tostring(L["SOURCE_" .. tostring(source)]) .. ")") or L.NO
    end))
    local okTooltip, tooltipSeconds = pcall(ReadLureTooltip)
    Line(L.DEBUG_LURE_TOOLTIP, DescribeResult(okTooltip, tooltipSeconds))
    Line(L.DEBUG_LURE_API, DescribeResult(pcall(HasLureFromApi)))
    Line(L.DEBUG_LURE_TRACKED, FormatValue(GetTrackedLureSeconds(GetEquippedItemID(C.MAIN_HAND_SLOT))))
    Line(L.DEBUG_BEST_LURE, FormatValue(FindBestLure()))
    Line(L.DEBUG_WEAPONS, FormatValue(GetWeaponNames()))
    Line(L.DEBUG_FREE_SLOTS, FormatValue(GetFreeBagSlots()))
    Line(L.DEBUG_FISHING, FormatValue(IsFishingChannelActive()))
    local okFishKeys, fishKeys = pcall(CollectFishingKeys)
    Line(L.DEBUG_REEL_KEYS, DescribeResult(okFishKeys, fishKeys, KeysFormatter))
    local okInteractKeys, interactKeys = pcall(CollectInteractKeys)
    Line(L.DEBUG_INTERACT_KEYS, DescribeResult(okInteractKeys, interactKeys, KeysFormatter))
    Line(L.DEBUG_GAMEPAD, FormatValue(IsGamepadUI()))
    local gearNames = {}
    for _, pick in ipairs(Gear.GetPlan()) do
        table.insert(gearNames, (GetItemName(pick.itemID) or (C.ITEM_LINK_PREFIX .. pick.itemID)) .. " +" .. pick.bonus)
    end
    Line(L.DEBUG_GEAR, #gearNames > 0 and table.concat(gearNames, C.LIST_SEPARATOR) or L.NONE)
    Line(L.DEBUG_DIRECT_EQUIP, FormatValue(AutoEquip.CanEquip() and true or false))
    Line(L.DEBUG_AUCTIONATOR, FormatValue(Value.API() ~= nil))
    local learned = 0
    for _ in pairs(db.craftRecipes or {}) do
        learned = learned + 1
    end
    Line(L.DEBUG_CRAFT_RECIPES, learned)
    Line(L.DEBUG_SESSION, FormatValue(db.cvarBackup ~= nil))
    Line(L.DEBUG_LANGUAGE, DescribeLanguageSetting())
end

-- /fishful command -----------------------------------------------------------------------

-- Every subcommand works in English and in each translated language.
local SUBCOMMAND_ALIASES = {}
for key, english in pairs(C.SUBCOMMANDS) do
    SUBCOMMAND_ALIASES[english] = key
    for _, texts in pairs(ns.LOCALES) do
        local localized = texts["CMD_" .. key]
        if localized then
            SUBCOMMAND_ALIASES[localized:lower()] = key
        end
    end
end

local function PrintHelp()
    PrintMessage(L.HELP_HEADER)
    print(L.HELP_LINE:format(C.SLASH_COMMAND, "", L.HELP_TOGGLE))
    for _, key in ipairs(C.SUBCOMMAND_ORDER) do
        print(L.HELP_LINE:format(C.SLASH_COMMAND, L["CMD_" .. key], L["HELP_" .. key]))
    end
end

local SUBCOMMAND_HANDLERS = {}

local function DescribeLanguageOptions()
    return table.concat(C.LANGUAGE_CODE_ORDER, C.LIST_SEPARATOR)
end

function SUBCOMMAND_HANDLERS.LANGUAGE(argument)
    if not SetLanguage(argument) then
        PrintMessage(L.LANGUAGE_CURRENT:format(DescribeLanguageSetting(), DescribeLanguageOptions()))
    end
end

function SUBCOMMAND_HANDLERS.OPTIONS()
    OpenOptions()
end

function SUBCOMMAND_HANDLERS.VALUE()
    Window.Toggle(C.WINDOW_TAB.VALUE)
end

function SUBCOMMAND_HANDLERS.GEAR()
    Window.Toggle(C.WINDOW_TAB.GEAR)
end

function SUBCOMMAND_HANDLERS.RECIPES()
    Window.Toggle(C.WINDOW_TAB.RECIPES)
end

function SUBCOMMAND_HANDLERS.DEBUG()
    PrintDiagnostics()
end

function SUBCOMMAND_HANDLERS.HELP()
    PrintHelp()
end

function SUBCOMMAND_HANDLERS.MINIMAP()
    local shown = not GetOption("showMinimapButton")
    SetOption("showMinimapButton", shown)
    if not shown then
        PrintMessage(L.MINIMAP_HIDDEN:format(C.SLASH_COMMAND, L.CMD_MINIMAP))
    end
end

function SUBCOMMAND_HANDLERS.TWEAKS()
    local enabled = not GetOption("sessionTweaks")
    SetOption("sessionTweaks", enabled)
    PrintMessage(enabled and L.TWEAKS_ON or L.TWEAKS_OFF)
end

function SUBCOMMAND_HANDLERS.SOUND()
    local enabled = not GetOption("soundMode")
    SetOption("soundMode", enabled)
    PrintMessage(enabled and L.SOUND_ON or L.SOUND_OFF)
end

function SUBCOMMAND_HANDLERS.RESET()
    ResetPanelPosition()
end

_G["SLASH_" .. C.SLASH_KEY .. "1"] = C.SLASH_COMMAND
_G["SLASH_" .. C.SLASH_KEY .. "2"] = C.SLASH_COMMAND_LONG
SlashCmdList[C.SLASH_KEY] = function(message)
    local command, argument = strtrim(message or ""):lower():match("^(%S*)%s*(.-)$")
    local key = SUBCOMMAND_ALIASES[command]
    if key then
        SUBCOMMAND_HANDLERS[key](argument)
    elseif command == "" then
        TogglePanel()
    else
        PrintHelp()
    end
end

-- Events ---------------------------------------------------------------------------------

local function OnEquipmentChanged()
    -- Wait until the swap (main and off hand) settles before remembering.
    equipmentToken = equipmentToken + 1
    local token = equipmentToken
    C_Timer.After(C.EQUIPMENT_SETTLE_SECONDS, function()
        if token ~= equipmentToken then
            return
        end
        local mainHand = GetEquippedItemID(C.MAIN_HAND_SLOT)
        if IsFishingPole(mainHand) then
            db.lastPoleID = mainHand
        else
            -- Pole off: the fishing session is over.
            EndFishingSession()
        end
        RememberCurrentWeapons()
        Gear.RememberUsual()
        -- Also rebuilds the macros: fishing gear lines follow the pole.
        UpdateWeaponActions()
        if Hud.peek and IsPoleEquipped() then
            Hud.peek = false
        end
        Hud.ApplyVisibility(true)
        Hints.WatchLure()
        RefreshPanel()
    end)
end

local handlers = {}
local PLAYER_UNIT_EVENTS = {
    UNIT_INVENTORY_CHANGED = true,
    UNIT_SPELLCAST_CHANNEL_START = true,
    UNIT_SPELLCAST_CHANNEL_STOP = true,
}

function handlers.ADDON_LOADED(name)
    if name == C.VALUE.AUCTIONATOR_ADDON then
        Value.RegisterPriceUpdates()
    end
    if name ~= ADDON_NAME then
        return
    end
    local isNew = FishfulThinkingCharDB == nil
    FishfulThinkingCharDB = FishfulThinkingCharDB or {}
    db = FishfulThinkingCharDB
    FishfulThinkingDB = FishfulThinkingDB or {}
    accountDB = FishfulThinkingDB
    MigrateLegacyOptions()
    ApplyLanguage()
    Value.RebuildCraftIndex()
    Value.HookTooltips()
    -- After a /reload in combat the panel can't be built yet: wait for combat to end.
    if InCombatLockdown() then
        panelSetupPending = true
    else
        SetUpInterface()
    end
    if isNew then
        PrintMessage(L.WELCOME:format(C.SLASH_COMMAND))
    end
end

function handlers.PLAYER_LOGIN()
    Value.RegisterPriceUpdates()
    -- Values left over from a session cut short (crash, disconnect).
    EndFishingSession()
    RememberCurrentWeapons()
    Gear.RememberUsual()
    UpdateWeaponActions()
    Hints.WatchLure()
    RefreshPanel()
end

function handlers.PLAYER_ENTERING_WORLD()
    SetReelKeys(false)
    fishingActive = false
end

function handlers.PLAYER_LOGOUT()
    EndFishingSession()
end

function handlers.UPDATE_MACROS()
    SyncMacros()
    Hud.RefreshHotkeys()
end

function handlers.PLAYER_EQUIPMENT_CHANGED()
    OnAlertEquipmentChanged()
    AutoEquip.Continue()
    OnEquipmentChanged()
end

function handlers.BAG_UPDATE_DELAYED()
    CheckPendingLure()
    -- Fishing pieces and usual pieces in your bags decide the macros' gear lines.
    UpdateWeaponActions()
    RefreshPanel()
    Value.RefreshIfShown()
end

function handlers.LOOT_READY()
    Value.RecordLoot()
end

function handlers.ITEM_LOCK_CHANGED(bag, bagSlot)
    Value.OnItemLocked(bag, bagSlot)
end

function handlers.AUCTION_HOUSE_SHOW()
    Value.auctionOpen = true
    Value.RegisterPriceUpdates()
    Value.RefreshIfShown()
end

function handlers.AUCTION_HOUSE_CLOSED()
    Value.auctionOpen = false
    Value.RefreshIfShown()
end

function handlers.TRADE_SKILL_SHOW()
    Value.ScheduleRecipeScan()
end

function handlers.TRADE_SKILL_LIST_UPDATE()
    Value.ScheduleRecipeScan()
end

-- Item names and prices arrive a moment after they're first asked for.
function handlers.GET_ITEM_INFO_RECEIVED()
    Value.ScheduleRefresh()
end

function handlers.UPDATE_BINDINGS()
    RefreshOptions()
    Hud.RefreshHotkeys()
end

function handlers.ACTIONBAR_SLOT_CHANGED()
    Hud.RefreshHotkeys()
end

function handlers.ADDON_ACTION_BLOCKED(addonName)
    AutoEquip.OnActionBlocked(addonName)
end

function handlers.ADDON_ACTION_FORBIDDEN(addonName)
    AutoEquip.OnActionBlocked(addonName)
end

function handlers.UI_ERROR_MESSAGE(messageType, message)
    Hints.OnGameMessage(messageType, message)
end

function handlers.UI_INFO_MESSAGE(messageType, message)
    Hints.OnGameMessage(messageType, message)
end

function handlers.SYSMSG(message)
    Hints.OnGameMessage(nil, message)
end

function handlers.UNIT_INVENTORY_CHANGED()
    RefreshPanel()
end

function handlers.UNIT_SPELLCAST_CHANNEL_START(_, _, spellID)
    if IsFishingSpell(spellID) then
        fishingActive = true
        StartFishingSession()
        SetReelKeys(true)
        RefreshPanel()
    end
end

function handlers.UNIT_SPELLCAST_CHANNEL_STOP()
    if fishingActive or reelKeysActive then
        fishingActive = false
        SetReelKeys(false)
        ScheduleSessionEnd()
        RefreshPanel()
    end
end

-- Last moment buttons and keys can change before combat.
function handlers.PLAYER_REGEN_DISABLED()
    SetReelKeys(false)
    -- Attacked with the pole on: the weapon goes on by itself if the game allows it,
    -- and the "Equip weapon" alert is ready in case it doesn't.
    local weaponOnItsWay = AutoEquip.StartForCombat()
    for _, button in ipairs(fishingButtons) do
        PrepareCombatFishing(button)
    end
    StartCombatAlert(weaponOnItsWay)
end

function handlers.PLAYER_REGEN_ENABLED()
    if panelSetupPending then
        SetUpInterface()
    end
    HideCombatAlert()
    if alertDriverPending then
        UpdateAlertDriver()
    end
    if optionsApplyPending then
        ApplyOptions()
    end
    if weaponUpdatePending then
        UpdateWeaponActions()
    end
    if reelClearPending then
        SetReelKeys(false)
    end
    AutoEquip.Finish()
    if Hud.visibilityPending then
        Hud.ApplyVisibility()
    end
    -- Restore any value that could not be restored during combat.
    if db and db.cvarBackup and not fishingActive and not IsPoleEquipped() then
        EndFishingSession()
    end
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do
    if PLAYER_UNIT_EVENTS[event] then
        events:RegisterUnitEvent(event, C.PLAYER_UNIT)
    else
        events:RegisterEvent(event)
    end
end
events:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)
