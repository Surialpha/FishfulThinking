local _, ns = ...

local C = {}
ns.C = C

-- Frame names. Secure buttons need a name to be used with /click and key bindings.
-- If you rename them, update Bindings.xml too.
C.MACRO_BUTTON_NAME = "FishfulThinkingFishButton"
C.HIDDEN_WEAPON_BUTTON_NAME = "FishfulThinkingWeaponButton"
C.PANEL_NAME = "FishfulThinkingPanel"
C.PANEL_FISH_BUTTON_NAME = "FishfulThinkingPanelFish"
C.PANEL_WEAPON_BUTTON_NAME = "FishfulThinkingPanelWeapon"
C.MINIMAP_BUTTON_NAME = "FishfulThinkingMinimapButton"
C.ALERT_BUTTON_NAME = "FishfulThinkingAlertButton"
C.WINDOW_FRAME_NAME = "FishfulThinkingWindow"
C.TOAST_FRAME_NAME = "FishfulThinkingToast"
C.SECURE_TEMPLATE = "SecureActionButtonTemplate"
C.PANEL_BUTTON_TEMPLATE = "UIPanelButtonTemplate"
C.DROPDOWN_TEMPLATE = "WowStyle1DropdownTemplate"
C.DROPDOWN_FRAME_TYPE = "DropdownButton"
C.BACKDROP_TEMPLATE = "BackdropTemplate"
C.CLOSE_BUTTON_TEMPLATE = "UIPanelCloseButton"

-- Names from when this addon was called PescaTodo, kept so old macros keep working.
C.LEGACY_FISH_BUTTON_NAMES = { "PescaTodoFishButton", "PescaTodoBoton" }
C.LEGACY_FISH_MACRO_NAMES = { "PescaTodo" }
C.LEGACY_WEAPON_MACRO_NAMES = { "PescaTodoWeapon", "PescaTodoArma" }

-- Chat command
C.SLASH_KEY = "FISHFULTHINKING"
C.SLASH_COMMAND = "/fishful"
C.SLASH_COMMAND_LONG = "/fishfulthinking"
-- English subcommands always work, as well as every translated one (L.CMD_*).
C.SUBCOMMANDS = {
    RESET = "reset",
    DEBUG = "debug",
    HELP = "help",
    MINIMAP = "minimap",
    TWEAKS = "tweaks",
    SOUND = "sound",
    LANGUAGE = "language",
    OPTIONS = "options",
    VALUE = "value",
    GEAR = "gear",
    RECIPES = "recipes",
}
C.SUBCOMMAND_ORDER = { "OPTIONS", "VALUE", "GEAR", "RECIPES", "RESET", "MINIMAP", "TWEAKS", "SOUND", "LANGUAGE", "DEBUG", "HELP" }
C.RIGHT_BUTTON = "RightButton"

-- Options (per character) and their defaults. Everything here is on the options page.
C.OPTION_DEFAULTS = {
    showPanel = true,
    hudWithPole = true,
    showMinimapButton = true,
    chatHints = true,
    useLures = true,
    reelWithFishKey = true,
    clearTarget = true,
    sessionTweaks = true,
    soundMode = false,
    combatWeaponSwap = true,
    combatAlert = true,
    combatAlertSound = true,
    combatAutoEquip = true,
    combatToast = true,
    fishingGear = true,
    markBobber = true,
    escapeHints = true,
    lureExpiredAlert = true,
    catchValueTooltip = true,
    catchValueHints = true,
}
-- Older versions kept some of these as flags; they are moved into the options once.
C.LEGACY_OPTION_FLAGS = {
    { flag = "panelHidden", option = "showPanel", value = false },
    { flag = "minimapHidden", option = "showMinimapButton", value = false },
    { flag = "tweaksDisabled", option = "sessionTweaks", value = false },
    { flag = "soundMode", option = "soundMode", value = true },
}

-- Options: in the game's Options > AddOns, Fishful Thinking (General) and one page per
-- section under it. Each option shows its explanation under its name. Texts are keys
-- of the locale tables.
C.OPTIONS_SECTIONS = {
    { key = "GENERAL", title = "TITLE", description = "OPTIONS_DESC_GENERAL", items = {
        { kind = "buttons", buttons = {
            { action = "OPEN_WINDOW", label = "OPT_OPEN_WINDOW", tip = "OPT_OPEN_WINDOW_TIP" },
            { action = "RESET_PANEL", label = "OPT_RESET_PANEL", tip = "OPT_RESET_PANEL_TIP" },
        } },
        { kind = "header", text = "OPTIONS_SECTION_INTERFACE" },
        { kind = "switch", option = "showPanel", label = "OPT_SHOW_PANEL", tip = "OPT_SHOW_PANEL_TIP" },
        { kind = "switch", option = "hudWithPole", label = "OPT_HUD_WITH_POLE", tip = "OPT_HUD_WITH_POLE_TIP",
          requires = "showPanel" },
        { kind = "switch", option = "showMinimapButton", label = "OPT_SHOW_MINIMAP", tip = "OPT_SHOW_MINIMAP_TIP" },
        { kind = "language", label = "OPT_LANGUAGE", tip = "OPT_LANGUAGE_TIP" },
    } },
    { key = "KEYS", title = "OPTIONS_SECTION_KEYS", description = "OPTIONS_DESC_KEYS", items = {
        { kind = "binding", command = "FISH", label = "OPT_KEY_FISH", tip = "OPT_KEY_FISH_DESC" },
        { kind = "binding", command = "WEAPON", label = "OPT_KEY_WEAPON", tip = "OPT_KEY_WEAPON_DESC" },
        { kind = "note", text = "OPT_KEY_HINT" },
    } },
    { key = "FISHING", title = "OPTIONS_SECTION_FISHING", description = "OPTIONS_DESC_FISHING", items = {
        { kind = "switch", option = "useLures", label = "OPT_USE_LURES", tip = "OPT_USE_LURES_TIP" },
        { kind = "switch", option = "fishingGear", label = "OPT_FISHING_GEAR", tip = "OPT_FISHING_GEAR_TIP" },
        { kind = "switch", option = "reelWithFishKey", label = "OPT_REEL_KEY", tip = "OPT_REEL_KEY_TIP" },
        { kind = "switch", option = "clearTarget", label = "OPT_CLEAR_TARGET", tip = "OPT_CLEAR_TARGET_TIP" },
        { kind = "switch", option = "markBobber", label = "OPT_MARK_BOBBER", tip = "OPT_MARK_BOBBER_TIP" },
        { kind = "switch", option = "sessionTweaks", label = "OPT_TWEAKS", tip = "OPT_TWEAKS_TIP" },
        { kind = "switch", option = "soundMode", label = "OPT_SOUND", tip = "OPT_SOUND_TIP" },
    } },
    { key = "COMBAT", title = "OPTIONS_SECTION_COMBAT", description = "OPTIONS_DESC_COMBAT", items = {
        { kind = "switch", option = "combatAutoEquip", label = "OPT_AUTO_EQUIP", tip = "OPT_AUTO_EQUIP_TIP" },
        { kind = "switch", option = "combatToast", label = "OPT_COMBAT_TOAST", tip = "OPT_COMBAT_TOAST_TIP",
          requires = "combatAutoEquip" },
        { kind = "switch", option = "combatWeaponSwap", label = "OPT_COMBAT_SWAP", tip = "OPT_COMBAT_SWAP_TIP" },
        { kind = "switch", option = "combatAlert", label = "OPT_COMBAT_ALERT", tip = "OPT_COMBAT_ALERT_TIP" },
        { kind = "switch", option = "combatAlertSound", label = "OPT_COMBAT_SOUND", tip = "OPT_COMBAT_SOUND_TIP",
          requires = "combatAlert" },
        { kind = "buttons", buttons = {
            { action = "TEST_ALERT", label = "OPT_TEST_ALERT", tip = "OPT_TEST_ALERT_TIP" },
        } },
    } },
    { key = "VALUE", title = "OPTIONS_SECTION_VALUE", description = "OPTIONS_DESC_VALUE", items = {
        { kind = "switch", option = "catchValueTooltip", label = "OPT_VALUE_TOOLTIP", tip = "OPT_VALUE_TOOLTIP_TIP" },
        { kind = "switch", option = "catchValueHints", label = "OPT_VALUE_HINTS", tip = "OPT_VALUE_HINTS_TIP" },
        { kind = "buttons", buttons = {
            { action = "OPEN_WINDOW", label = "OPT_VALUE_OPEN", tip = "OPT_VALUE_OPEN_TIP" },
        } },
    } },
    { key = "MESSAGES", title = "OPTIONS_SECTION_MESSAGES", description = "OPTIONS_DESC_MESSAGES", items = {
        { kind = "switch", option = "chatHints", label = "OPT_CHAT_HINTS", tip = "OPT_CHAT_HINTS_TIP" },
        { kind = "switch", option = "escapeHints", label = "OPT_ESCAPE_HINTS", tip = "OPT_ESCAPE_HINTS_TIP" },
        { kind = "switch", option = "lureExpiredAlert", label = "OPT_LURE_EXPIRED", tip = "OPT_LURE_EXPIRED_TIP" },
    } },
}
C.OPTIONS_LAYOUT = {
    LEFT = 16,
    TOP = 16,
    WIDTH = 600,
    TITLE_GAP = 6,
    DIVIDER_GAP = 12,
    DIVIDER_HEIGHT = 1,
    HEADER_GAP = 10,
    HEADER_BOTTOM = 10,
    ROW_GAP = 14,
    -- Switches: a track with a knob that slides.
    SWITCH_WIDTH = 34,
    SWITCH_HEIGHT = 18,
    KNOB_SIZE = 12,
    KNOB_INSET = 3,
    SWITCH_SECONDS = 0.12,
    SWITCH_GAP = 12,
    LABEL_TOP = 2,
    LABEL_HINT_GAP = 3,
    -- An option that depends on the one above sits a little to the right.
    INDENT = 22,
    DISABLED_ALPHA = 0.45,
    BUTTON_WIDTH = 190,
    BUTTON_HEIGHT = 24,
    BUTTON_GAP = 10,
    DROPDOWN_WIDTH = 200,
    -- Keys: one chip per key, then "+ Add".
    CHIP_HEIGHT = 22,
    CHIP_GAP = 6,
    CHIP_PADDING = 10,
    CHIPS_TOP_GAP = 8,
    CAPTURE_PULSE_SECONDS = 0.5,
    CAPTURE_PULSE_ALPHA = 0.35,
    -- The page scrolls when it doesn't fit.
    SCROLL_TEMPLATE = "UIPanelScrollFrameTemplate",
    SCROLL_BAR_WIDTH = 26,
    BOTTOM_PADDING = 16,
    -- When the game can't measure a text yet.
    FALLBACK_TEXT_HEIGHT = 14,
}

-- Languages. English is the default, whatever the game client's language is.
C.DEFAULT_LANGUAGE = "enUS"
C.LANGUAGE_AUTO = "auto"
C.LANGUAGE_CODES = {
    en = "enUS",
    es = "esES",
    de = "deDE",
    fr = "frFR",
    pt = "ptBR",
    auto = "auto",
}
C.LANGUAGE_CODE_ORDER = { "en", "es", "de", "fr", "pt", "auto" }
-- Each language is shown by its own name.
C.LANGUAGE_NAMES = {
    enUS = "English",
    esES = "Español",
    esMX = "Español",
    deDE = "Deutsch",
    frFR = "Français",
    ptBR = "Português",
}
C.LIST_SEPARATOR = ", "

-- Slots and bags
C.PLAYER_UNIT = "player"
C.DRAG_BUTTON = "LeftButton"
C.MAIN_HAND_SLOT = INVSLOT_MAINHAND or 16
C.OFF_HAND_SLOT = INVSLOT_OFFHAND or 17
C.FIRST_BAG = BACKPACK_CONTAINER or 0
C.LAST_BAG = NUM_BAG_SLOTS or 4
-- Looking for items also covers the reagent bag (fish and other materials often live there).
-- Free space is still counted in the normal bags only: most catches can't go in it.
C.LAST_ITEM_BAG = C.LAST_BAG + (NUM_REAGENTBAG_SLOTS or 1)
C.GENERIC_BAG_TYPE = 0

-- Item types
C.WEAPON_ITEM_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
C.FISHING_POLE_SUBCLASS = (Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole) or 20
C.ENCHANT_TYPE_TEMPORARY = (Enum and Enum.ItemEnchantType and Enum.ItemEnchantType.Temporary) or 2
C.WEAPON_SLOT_MAIN_HAND = (Enum and Enum.WeaponSlot and Enum.WeaponSlot.MainHand) or 0

-- Fishing. Every rank shares the name; it is read from the client for any language.
C.FISHING_SPELL_IDS = { [7620] = true, [7731] = true, [7732] = true, [18248] = true }
C.FISHING_SPELL_ID = 7620
C.FISHING_SPELL_FALLBACK_NAME = "Fishing"
C.FISHING_ICON_FALLBACK = 136245
C.WEAPON_ICON_FALLBACK = "Interface\\Icons\\INV_Sword_04"
C.MINIMAP_ICON = "Interface\\Icons\\Trade_Fishing"

-- Lures, best first. Minutes are Classic's and only used as a fallback when the
-- game doesn't show the time left.
C.LURES = {
    { itemID = 6533, minutes = 5, bonus = 100 },  -- Aquadynamic Fish Attractor
    { itemID = 6532, minutes = 10, bonus = 75 },  -- Bright Baubles
    { itemID = 7307, minutes = 10, bonus = 75 },  -- Flesh Eating Worm
    { itemID = 6530, minutes = 10, bonus = 50 },  -- Nightcrawlers
    { itemID = 6811, minutes = 10, bonus = 50 },  -- Aquadynamic Fish Lens
    { itemID = 6529, minutes = 10, bonus = 25 },  -- Shiny Bauble
}
C.DEFAULT_LURE_MINUTES = 10
C.LURE_MAX_FAILURES = 2

-- Enchant time format when the client doesn't provide its own.
C.ENCHANT_TIME_FALLBACK = {
    SECONDS = "%s (%d sec)",
    MINUTES = "%s (%d min)",
    HOURS = "%s (%d hour)",
}

-- Secure actions
C.ATTR_TYPE = "type"
C.ATTR_ITEM = "item"
C.ATTR_SPELL = "spell"
C.ATTR_MACROTEXT = "macrotext"
C.ATTR_TARGET_SLOT = "target-slot"
C.ATTR_USE_ON_KEY_DOWN = "useOnKeyDown"
C.ACTION_ITEM = "item"
C.ACTION_SPELL = "spell"
C.ACTION_MACRO = "macro"
C.CLICK_REGISTRATION = "AnyUp"
C.ITEM_LINK_PREFIX = "item:"
C.ITEM_ID_PATTERN = "item:(%d+)"
C.EQUIP_SLOT_LINE = "/equipslot %d item:%d"
C.MACRO_LINE_SEPARATOR = "\n"

-- Macros you drag to the action bar
C.MACRO_FISH_NAME = "FishfulThinking"
C.MACRO_WEAPON_NAME = "FishfulWeapon"
C.ACTION_INFO_MACRO = "macro"
C.DEFAULT_MAX_ACCOUNT_MACROS = 120
C.DEFAULT_MAX_CHARACTER_MACROS = 18
C.MACRO_LINES = {
    -- In combat, the Fish macro gives your weapon back and stops there.
    COMBAT_EQUIP = "/equipslot [combat] %d item:%d",
    STOP_IN_COMBAT = "/stopmacro [combat]",
    -- Interact prefers your target over the bobber: clear it before casting.
    CLEAR_TARGET = "/cleartarget",
    -- Fishing gear goes on in the same press as the pole.
    GEAR_EQUIP = "/equipslot %d item:%d",
    -- Your usual pieces come back with the weapon, only out of combat (the game
    -- only lets you change weapons in combat).
    NOCOMBAT_EQUIP = "/equipslot [nocombat] %d item:%d",
    -- The macro "clicks" with its own mouse button name, so the Fish button knows the
    -- press came from a macro: a macro can't run another button's macro text.
    CLICK = "/click %s %s",
}
C.BAR_CLICK_BUTTON = "Bar"
-- The game's limit for a macro's text.
C.MACRO_MAX_CHARS = 255

-- Keys. While the bobber is out, the Fish keys become "Interact".
C.INTERACT_BINDING_COMMAND = "INTERACTTARGET"
-- Names the game itself translates, so they match your menus.
C.INTERACT_BINDING_LABEL_GLOBAL = "BINDING_NAME_INTERACTTARGET"
C.KEY_BINDINGS_LABEL_GLOBAL = "KEY_BINDINGS"
C.CLICK_BINDING_FORMAT = "CLICK %s:LeftButton"
C.CLICK_BINDING_FRAME_PATTERN = "^CLICK ([^:]+):"
C.FISH_BINDING_COMMAND = C.CLICK_BINDING_FORMAT:format(C.MACRO_BUTTON_NAME)
C.WEAPON_BINDING_COMMAND = C.CLICK_BINDING_FORMAT:format(C.HIDDEN_WEAPON_BUTTON_NAME)
C.BINDING_NAME_FORMAT = "%s: %s"
C.BINDING_NAME_PREFIX = "BINDING_NAME_"
-- Key rows on the options page.
C.BINDING_COMMANDS = {
    FISH = { command = C.FISH_BINDING_COMMAND, name = "BINDING_FISH" },
    WEAPON = { command = C.WEAPON_BINDING_COMMAND, name = "BINDING_WEAPON" },
}
-- Pressed alone they only wait for the real key.
C.MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, LMETA = true, RMETA = true,
}
-- In the order the game writes them ("ALT-CTRL-SHIFT-F").
C.KEY_MODIFIERS = {
    { prefix = "ALT-", isDown = "IsAltKeyDown" },
    { prefix = "CTRL-", isDown = "IsControlKeyDown" },
    { prefix = "SHIFT-", isDown = "IsShiftKeyDown" },
    { prefix = "META-", isDown = "IsMetaKeyDown" },
}
C.CANCEL_KEY = "ESCAPE"
-- Mouse buttons that can be keys (left and right click the row itself).
C.MOUSE_BUTTON_KEYS = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }
C.MOUSE_WHEEL_KEYS = { UP = "MOUSEWHEELUP", DOWN = "MOUSEWHEELDOWN" }
C.KEY_ROW_CLICKS = { "LeftButtonUp", "RightButtonUp" }
C.LEFT_BUTTON = "LeftButton"
C.BUTTONS_PER_BAR = NUM_ACTIONBAR_BUTTONS or 12
C.ACTION_BAR_BUTTONS = {
    { frame = "ActionButton%d", command = "ACTIONBUTTON%d" },
    { frame = "MultiBarBottomLeftButton%d", command = "MULTIACTIONBAR1BUTTON%d" },
    { frame = "MultiBarBottomRightButton%d", command = "MULTIACTIONBAR2BUTTON%d" },
    { frame = "MultiBarRightButton%d", command = "MULTIACTIONBAR3BUTTON%d" },
    { frame = "MultiBarLeftButton%d", command = "MULTIACTIONBAR4BUTTON%d" },
    { frame = "MultiBar5Button%d", command = "MULTIACTIONBAR5BUTTON%d" },
    { frame = "MultiBar6Button%d", command = "MULTIACTIONBAR6BUTTON%d" },
    { frame = "MultiBar7Button%d", command = "MULTIACTIONBAR7BUTTON%d" },
}
C.KEY_SEPARATOR = ", "
C.GAMEPAD_UI_CVAR = "InputDeviceInterfaceStyle"
C.GAMEPAD_UI_VALUE = "1"

-- Temporary settings while you fish; restored when the session ends (a while
-- without casting, taking the pole off or logging out).
C.SESSION_CVARS = {
    { name = "SoftTargetInteract", value = "3" },       -- Interact with keyboard too
    { name = "SoftTargetInteractArc", value = "2" },    -- bobber in any direction
    { name = "SoftTargetInteractRange", value = "30" }, -- the bobber lands far (default 10)
    { name = "autoLootDefault", value = "1" },          -- auto loot
}
-- Mark the bobber (optional): the game's interact icon over your bobber.
C.BOBBER_MARK_CVARS = {
    { name = "SoftTargetIconGameObject", value = "1" },
    { name = "SoftTargetIconInteract", value = "1" },
}
-- Sound mode (optional): hear the splash better.
C.SOUND_CVARS = {
    { name = "Sound_SFXVolume", value = "1" },
    { name = "Sound_EnableMusic", value = "0" },
    { name = "Sound_EnableAmbience", value = "0" },
}

-- Why the Fish button does nothing on this press
C.BLOCK_REASON = {
    NO_POLE = "NO_POLE",
    BAGS_FULL = "BAGS_FULL",
    BAGS_FULL_FOR_POLE = "BAGS_FULL_FOR_POLE",
}

-- Where the lure detection came from (for diagnostics)
C.LURE_SOURCE = {
    TOOLTIP = "TOOLTIP",
    API = "API",
    TRACKED = "TRACKED",
}

-- Times (seconds)
C.SECONDS_PER_MINUTE = 60
C.SECONDS_PER_HOUR = 3600
C.EQUIPMENT_SETTLE_SECONDS = 1
C.LURE_PENDING_SECONDS = 15
C.LURE_TOOLTIP_GRACE_SECONDS = 10
C.STATUS_REFRESH_SECONDS = 2
C.SESSION_IDLE_SECONDS = 90
C.LURE_CHECK_SECONDS = 5

-- Fishing gear: pieces with a Fishing bonus go on with the pole. Slots by the
-- item's equip location (rings and trinkets are left alone).
C.GEAR_SLOTS = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_BODY = 4,
    INVTYPE_CHEST = 5, INVTYPE_ROBE = 5, INVTYPE_WAIST = 6, INVTYPE_LEGS = 7,
    INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10, INVTYPE_CLOAK = 15,
}
-- A tooltip line naming Fishing with "+N" ("Equip: Increased Fishing +5"). The "+"
-- keeps out "Requires Fishing (225)".
C.FISHING_BONUS_PATTERN = "%+%s*(%d+)"
C.FISHING_WORD_FALLBACK = "fishing"

-- Putting the weapon on by itself when combat starts: pick it up from the bag and
-- drop it on the hand, as you would by hand.
C.CURSOR_ITEM = "item"
-- An "action blocked" report this soon after trying means the game refused it.
C.DIRECT_EQUIP_BLOCK_WINDOW = 2
-- How long the alert waits for the weapon before it sounds.
C.AUTO_EQUIP_CHECK_SECONDS = 0.6
-- The weapon put on at combat start must arrive within this; the off hand follows it.
C.AUTO_EQUIP_WINDOW_SECONDS = 5

-- Messages the game shows when a fish gets away or nothing was hooked, by the
-- game's own ID (any language) or, failing that, its text.
C.FISH_MESSAGE_IDS = { ERR_FISH_ESCAPED = "ESCAPED", ERR_FISH_NOT_HOOKED = "NOT_HOOKED" }
C.FISH_MESSAGE_GLOBALS = { ESCAPED = "ERR_FISH_ESCAPED", NOT_HOOKED = "ERR_FISH_NOT_HOOKED" }

-- Lure ran out
C.LURE_ALERT = { SOUND_KIT = "READY_CHECK", SOUND_FALLBACK_ID = 8960 }

-- Catch value: sell to a vendor, sell at the auction house or cook, whichever pays more.
-- Auction prices come from Auctionator's public API.
C.VALUE_KIND = { VENDOR = "VENDOR", AUCTION = "AUCTION", COOK = "COOK", CRAFT = "CRAFT", OPEN = "OPEN", LOCKED = "LOCKED" }
-- Profession names come from the game (any language) through these spells.
C.PROFESSION_SPELLS = { Alchemy = 2259, Cooking = 2550, Fishing = 7620 }
C.VALUE = {
    -- The auction house keeps 5% of the sale.
    AUCTION_CUT = 0.05,
    -- Older prices are flagged, with a reminder to scan again.
    PRICE_OLD_DAYS = 3,
    -- GetItemInfo's sell price position.
    SELL_PRICE_INDEX = 11,
    AUCTIONATOR_ADDON = "Auctionator",
    -- Tooltip lines the game itself writes on containers.
    OPENABLE_GLOBAL = "ITEM_OPENABLE",
    LOCKED_GLOBAL = "LOCKED",
    -- Loot this soon after opening a fished-up container comes from it.
    OPEN_LOOT_SECONDS = 3,
    -- "Fire Oil (Alchemy)"
    USE_FORMAT = "%s (%s)",
    -- Learning the window's cooking recipes waits for the list to settle.
    RECIPE_SCAN_DELAY = 0.5,
    -- Bursts of item data or price updates refresh the window once.
    REFRESH_DELAY = 0.3,
    ICON = "Interface\\Icons\\INV_Misc_Coin_02",
    -- Without the game's coin icons: "1g 2s 3c".
    MONEY_GOLD = "%dg",
    MONEY_SILVER = "%ds",
    MONEY_COPPER = "%dc",
    MONEY_SEPARATOR = " ",
    COPPER_PER_SILVER = 100,
    COPPER_PER_GOLD = 10000,
}

-- The main window: the HUD's frame with three tabs (catch value, fishing gear, recipes).
-- Each page: three summary tiles, filter chips where they help, a scrolling list and a
-- footer.
C.WINDOW = {
    WIDTH = 640,
    PADDING = 12,
    HEADER_HEIGHT = 20,
    LOGO_SIZE = 18,
    ICON_BUTTON_SIZE = 16,
    TAB_TOP_GAP = 6,
    TAB_HEIGHT = 24,
    TAB_GAP = 20,
    TAB_UNDERLINE = 2,
    DIVIDER_HEIGHT = 1,
    SECTION_GAP = 10,
    TILE_HEIGHT = 44,
    TILE_GAP = 8,
    TILE_INSET = 9,
    TILE_INSET_Y = 6,
    CHIP_HEIGHT = 20,
    CHIP_GAP = 6,
    CHIP_PADDING = 10,
    -- When the game can't measure a text yet: about this wide per letter.
    CHAR_WIDTH = 6,
    COLUMN_HEADER_HEIGHT = 16,
    LIST_TOP_GAP = 4,
    ROWS = 8,
    ROW_HEIGHT = 34,
    ICON_SIZE = 26,
    TEXT_GAP = 8,
    LINE_GAP = 1,
    COLUMN_ITEM = 190,
    COLUMN_EACH = 86,
    COLUMN_TOTAL = 96,
    COLUMN_GAP = 8,
    TAG_PADDING = 5,
    TAG_INSET_Y = 1,
    TAG_TOP = 4,
    SCROLL_WIDTH = 6,
    SCROLL_GAP = 6,
    SCROLL_THUMB_HEIGHT = 28,
    FOOTER_HEIGHT = 24,
    BUTTON_WIDTH = 120,
    BUTTON_HEIGHT = 22,
    STRATA = "DIALOG",
    APPEAR_SECONDS = 0.25,
    APPEAR_OFFSET = 12,
    PAGE_FADE_SECONDS = 0.15,
    ROW_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    ROW_HIGHLIGHT_ALPHA = 0.45,
    ROW_STRIPE_ALPHA = 0.04,
    TILE_BACKDROP = {
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    },
    -- Symbols, the same in every language.
    CHIP_FORMAT = "%s · %d",
    COUNT_FORMAT = "×%d",
    BONUS_FORMAT = "+%d",
    GAIN_FORMAT = "+%s",
    SKILL_FORMAT = "%d + %d",
    NO_VALUE = "—",
}
C.WINDOW_TAB = { VALUE = "VALUE", GEAR = "GEAR", RECIPES = "RECIPES" }
C.WINDOW_TAB_ORDER = { "VALUE", "GEAR", "RECIPES" }
-- Filter chips: everything, or one kind.
C.FILTER_ALL = "ALL"
C.RECIPE_FILTER = { KNOWN = "KNOWN", LEARN = "LEARN" }
C.RECIPE_FILTER_ORDER = { "KNOWN", "LEARN" }
C.GEAR_FILTER_ORDER = { "POLES", "LURES", "PIECES" }
C.VALUE_KIND_ORDER = { "COOK", "CRAFT", "AUCTION", "VENDOR", "OPEN", "LOCKED" }
-- Gear rows: worn, goes on with the pole, or kept in the bags (something better is worn).
C.GEAR_STATE = { WORN = "WORN", GOES_ON = "GOES_ON", SPARE = "SPARE", BEST = "BEST" }
-- The game's own names for equipment slots (already in every language).
C.SLOT_NAME_GLOBALS = {
    [1] = "HEADSLOT", [2] = "NECKSLOT", [3] = "SHOULDERSLOT", [4] = "SHIRTSLOT", [5] = "CHESTSLOT",
    [6] = "WAISTSLOT", [7] = "LEGSSLOT", [8] = "FEETSLOT", [9] = "WRISTSLOT", [10] = "HANDSSLOT",
    [15] = "BACKSLOT", [16] = "MAINHANDSLOT",
}

-- Minimap button
C.MINIMAP = {
    SIZE = 31,
    ICON_SIZE = 17,
    ICON_OFFSET_X = 7,
    ICON_OFFSET_Y = -6,
    BACKGROUND_SIZE = 20,
    BACKGROUND_OFFSET_Y = -5,
    BORDER_SIZE = 53,
    RADIUS_OFFSET = 10,
    DEFAULT_ANGLE = 225,
    FRAME_LEVEL = 8,
    BORDER_TEXTURE = "Interface\\Minimap\\MiniMap-TrackingBorder",
    BACKGROUND_TEXTURE = "Interface\\Minimap\\UI-Minimap-Background",
    HIGHLIGHT_TEXTURE = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight",
}

-- Combat alert: one card in the HUD's style (red border) with your weapon on the left
-- and what to do beside it. The whole card is the button.
C.ALERT = {
    WIDTH = 300,
    HEIGHT = 60,
    PADDING = 10,
    ICON_SIZE = 40,
    -- From the icon to the texts, and between the two lines.
    TEXT_GAP = 10,
    LINE_GAP = 2,
    SLOT_SCALE = 1.72,
    GLOW_SCALE = 1.85,
    STRATA = "HIGH",
    DEFAULT_POINT = "TOP",
    DEFAULT_X = 0,
    DEFAULT_Y = -160,
    PULSE_MIN_ALPHA = 0.25,
    PULSE_SECONDS = 0.45,
    DONE_ALPHA = 0.4,
    TEST_SECONDS = 6,
    GLOW_TEXTURE = "Interface\\Buttons\\UI-ActionButton-Border",
    SLOT_TEXTURE = "Interface\\Buttons\\UI-Quickslot2",
    SOUND_KIT = "RAID_WARNING",
    SOUND_FALLBACK_ID = 8959,
    -- The game's own secure state driver shows and hides the alert, even in combat:
    -- only while you are in combat holding a fishing pole. %s = the game's localized
    -- name for fishing poles, as used by [equipped:...] in macros.
    VISIBILITY_STATE = "visibility",
    VISIBILITY_CONDITION = "[combat,equipped:%s] show; hide",
    -- Characters that would break that condition; with them, the older dimming is used.
    CONDITION_UNSAFE_PATTERN = "[%[%],;]",
    -- Asked right before combat: does the game see the pole you hold with that name?
    EQUIPPED_CHECK = "[equipped:%s] yes; no",
    EQUIPPED_CHECK_YES = "yes",
    -- If the alert is still up this long after the weapon is back, it is dimmed instead.
    DRIVER_CHECK_SECONDS = 0.5,
    -- Its entrance: the icon pops in with a little bounce while the texts fade in.
    POP_FROM_SCALE = 0.6,
    POP_OVERSHOOT_SCALE = 1.08,
    POP_GROW_SECONDS = 0.27,
    POP_SETTLE_SECONDS = 0.18,
}

-- When combat starts and the weapon goes on by itself: a small notice slides down,
-- shows a tick and leaves on its own. Ordinary frame, so it works in combat.
C.TOAST = {
    WIDTH = 230,
    HEIGHT = 36,
    PADDING = 8,
    ICON_SIZE = 22,
    CHECK_SIZE = 16,
    TEXT_GAP = 8,
    STRATA = "HIGH",
    SLIDE_OFFSET = 24,
    SLIDE_SECONDS = 0.35,
    HOLD_SECONDS = 2.4,
    FADE_SECONDS = 0.45,
    -- After the fade, in case the animation never ran.
    HIDE_MARGIN = 0.2,
    CHECK_DELAY = 0.25,
    CHECK_SECONDS = 0.3,
    CHECK_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-Ready",
}

-- Fishing HUD (the panel): the game's own look, action-button style buttons, a lure
-- bar and the bobber's state. Shown while you hold the pole (secure state driver,
-- so it also works in combat).
C.HUD = {
    WIDTH = 280,
    PADDING = 10,
    HEADER_HEIGHT = 18,
    LOGO_SIZE = 16,
    BUTTON_SIZE = 40,
    BUTTON_GAP = 8,
    SLOT_SCALE = 1.72,
    GLOW_SCALE = 1.85,
    -- Coin, gear and close: one size, centred on the title line.
    ICON_BUTTON_SIZE = 16,
    ICON_BUTTON_GAP = 4,
    -- Icons trimmed of their own border, like the action bars do.
    ICON_TEXCOORD = { 0.08, 0.92, 0.08, 0.92 },
    HOTKEY_OFFSET_X = -2,
    HOTKEY_OFFSET_Y = -3,
    -- From the Weapon button to the status text.
    STATUS_GAP = 12,
    DIVIDER_HEIGHT = 1,
    BAR_HEIGHT = 16,
    BAR_INSET = 2,
    BAR_TEXT_INSET = 6,
    ROW_GAP = 8,
    FOOTER_HEIGHT = 14,
    RIPPLE_SIZE = 10,
    TEXT_GAP = 3,
    -- The game's own art, present in every client.
    SLOT_TEXTURE = "Interface\\Buttons\\UI-Quickslot2",
    GLOW_TEXTURE = "Interface\\Buttons\\UI-ActionButton-Border",
    BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar",
    DOT_TEXTURE = "Interface\\COMMON\\Indicator-Red",
    RIPPLE_TEXTURE = "Interface\\COMMON\\Indicator-Gray",
    OPTIONS_ICON = "Interface\\Icons\\INV_Misc_Gear_01",
    BAR_BORDER = { edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 8, insets = { left = 2, right = 2, top = 2, bottom = 2 } },
    -- Effects (seconds, alpha, pixels)
    APPEAR_SECONDS = 0.3,
    APPEAR_OFFSET = 10,
    PULSE_SECONDS = 0.65,
    PULSE_MIN_ALPHA = 0.35,
    RIPPLE_SECONDS = 1.6,
    RIPPLE_SCALE = 2.2,
    SHIMMER_SECONDS = 2.4,
    SHIMMER_WIDTH = 0.3,
    SHIMMER_ALPHA = 0.25,
    CATCH_SECONDS = 1.8,
    CATCH_RISE = 26,
    CATCH_ICON_SIZE = 14,
    CAUGHT_SECONDS = 2.5,
    REFRESH_SECONDS = 1,
    -- Without the time a lure lasts, the bar is measured against this.
    DEFAULT_LURE_SECONDS = 600,
    VISIBILITY_STATE = "visibility",
    VISIBILITY_CONDITION = "[equipped:%s] show; hide",
}
C.HUD_CLOCK_FORMAT = "%d:%02d"
-- Short key names on the buttons, like the action bars ("s-F", "M3").
C.HOTKEY_ABBREVIATIONS = {
    { "SHIFT%-", "s-" }, { "CTRL%-", "c-" }, { "ALT%-", "a-" }, { "META%-", "m-" },
    { "MOUSEWHEELUP", "MwU" }, { "MOUSEWHEELDOWN", "MwD" }, { "BUTTON", "M" }, { "NUMPAD", "N" },
}

-- Panel
C.LAYOUT = {
    BUTTON_SIZE = 40,
    BUTTON_GAP = 14,
    PADDING = 10,
    LABEL_GAP = 2,
    DEFAULT_POINT = "CENTER",
    DEFAULT_X = 0,
    DEFAULT_Y = -200,
}
C.COLORS = {
    BACKGROUND = { 0, 0, 0, 0.85 },
    TOOLTIP_TEXT = { 1, 1, 1 },
    ALERT = { 1, 0.15, 0.1 },
    ALERT_TITLE = { 1, 0.35, 0.25 },
    VALUE = { 1, 0.82, 0 },
    HUD_BAR = { 0.12, 0.43, 0.66 },
    HUD_BAR_BACK = { 0.04, 0.035, 0.03, 0.9 },
    HUD_BORDER = { 0.6, 0.46, 0.24 },
    HUD_BACKGROUND = { 0.07, 0.055, 0.04, 0.9 },
    HUD_DIVIDER = { 0.6, 0.46, 0.24, 0.45 },
    HUD_GLOW = { 1, 0.82, 0 },
    HUD_GOOD = { 0.56, 0.82, 0.42 },
    TOAST_BORDER = { 0.56, 0.82, 0.42 },
    TAB_IDLE = { 0.72, 0.72, 0.72 },
    TAB_ACTIVE = { 1, 0.82, 0 },
    CHIP_IDLE = { 0.85, 0.85, 0.85 },
    MUTED = { 0.6, 0.6, 0.6 },
    ROW_STRIPE = { 1, 1, 1 },
    SCROLL_TRACK = { 0, 0, 0, 0.35 },
    SCROLL_THUMB = { 0.6, 0.46, 0.24, 0.9 },
    -- Badges by kind of use; a soft background of the same colour goes behind the text.
    TAG = {
        COOK = { 1, 0.66, 0.26 }, CRAFT = { 0.78, 0.58, 1 }, AUCTION = { 0.4, 0.76, 1 },
        VENDOR = { 0.75, 0.75, 0.75 }, OPEN = { 0.56, 0.82, 0.42 }, LOCKED = { 1, 0.45, 0.35 },
        KNOWN = { 0.56, 0.82, 0.42 }, LEARN = { 0.6, 0.8, 1 },
        WORN = { 0.56, 0.82, 0.42 }, GOES_ON = { 1, 0.82, 0 }, SPARE = { 0.75, 0.75, 0.75 },
        BEST = { 1, 0.82, 0 },
    },
    TAG_BACK_ALPHA = 0.2,
    SWITCH_ON_TRACK = { 0.32, 0.24, 0.05, 0.95 },
    SWITCH_ON_KNOB = { 1, 0.82, 0 },
    SWITCH_OFF_KNOB = { 0.5, 0.5, 0.5 },
    HUD_BAD = { 1, 0.35, 0.24 },
    VALUE_LEARN = { 0.6, 0.8, 1 },
    VALUE_NOTE = { 0.7, 0.7, 0.7 },
}
C.TEXTURES = {
    BACKGROUND = "Interface\\Tooltips\\UI-Tooltip-Background",
    BORDER = "Interface\\Tooltips\\UI-Tooltip-Border",
    HIGHLIGHT = "Interface\\Buttons\\ButtonHilight-Square",
    PUSHED = "Interface\\Buttons\\UI-Quickslot-Depress",
}
C.BACKDROP = {
    bgFile = C.TEXTURES.BACKGROUND,
    edgeFile = C.TEXTURES.BORDER,
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
C.FONTS = {
    TITLE = "GameFontNormal",
    OPTIONS_TITLE = "GameFontNormalLarge",
    OPTIONS_DESCRIPTION = "GameFontHighlightSmall",
    OPTIONS_HEADER = "GameFontNormal",
    OPTIONS_LABEL = "GameFontHighlight",
    OPTIONS_HINT = "GameFontDisableSmall",
    OPTIONS_CHIP = "GameFontHighlightSmall",
    ALERT_TITLE = "GameFontNormalLarge",
    ALERT_HINT = "GameFontHighlightSmall",
    TOAST = "GameFontHighlight",
    WINDOW_TITLE = "GameFontNormal",
    TAB = "GameFontNormal",
    TILE_LABEL = "GameFontDisableSmall",
    TILE_VALUE = "GameFontHighlightLarge",
    CHIP = "GameFontHighlightSmall",
    COLUMN = "GameFontDisableSmall",
    ROW_TITLE = "GameFontHighlight",
    ROW_SUB = "GameFontDisableSmall",
    ROW_TAG = "GameFontNormalSmall",
    ROW_NOTE = "GameFontHighlightSmall",
    ROW_MONEY = "GameFontHighlight",
    ROW_SECTION = "GameFontNormal",
    WINDOW_FOOTER = "GameFontDisableSmall",
    HUD_TITLE = "GameFontNormal",
    HUD_STATUS = "GameFontHighlight",
    HUD_SUB = "GameFontDisableSmall",
    HUD_HOTKEY = "NumberFontNormalSmallGray",
    HUD_BAR = "GameFontHighlightSmall",
    HUD_FOOTER = "GameFontDisableSmall",
    HUD_CATCH = "GameFontHighlight",
}
C.BLEND_ADD = "ADD"
C.TOOLTIP_ANCHOR = "ANCHOR_RIGHT"
