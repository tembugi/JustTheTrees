-- A stand-in for the game around Core.lua: Forever's talent window with a small made-up class
-- tree, so Tests/run.lua can use the plan through its own buttons, as a player does.
-- `local NewGame = dofile("Tests/standin.lua")`, then `local game = NewGame()` for each test.
--
-- Blizzard's code below copies wow-ui-source (forever, 1.60.1), cut to what the addon touches:
--   Blizzard_SharedTalentUI: Blizzard_SharedTalentUtil.lua, Blizzard_TalentButtonArt.lua,
--     Blizzard_SharedTalentButtonTemplates (the search mark), Blizzard_SharedTalentFrame.lua,
--     Blizzard_SharedTalentFrameTemplates.xml (the gate) and Camelot/Blizzard_SharedTalentOverrides.lua
--   Blizzard_PlayerSpells: Camelot/ClassTalents/Blizzard_ClassTalentsFrame.lua
--   Blizzard_SharedXML: TabSystemOwner.lua, TabSystemTemplates.lua, EventUtil.lua, MathUtil.lua
--   Blizzard_SpellSearch: Blizzard_SpellSearchUtil.lua
-- Strings are from BlizzardInterfaceResources (enUS), and the widgets have only the methods
-- Forever's widgets have (Tests/WidgetAPI.lua). The tree's data is made up: Forever's trees come
-- from the server. What the stand-in assumes beyond the game's code is marked ASSUMED: a
-- stand-in that behaves better than the game hides bugs.

-- This file runs under luajit, outside the game, and uses standard Lua's dofile and loadfile.
-- It plays the game, so it sets the game's globals.
---@diagnostic disable: undefined-global, lowercase-global, create-global

local WIDGET_METHODS = {}
for widgetType, names in pairs(dofile("Tests/WidgetAPI.lua")) do
	local set = {}
	for _, name in ipairs(names) do
		set[name] = true
	end
	WIDGET_METHODS[widgetType] = set
end

local game -- the game the current test plays

local function Mixin(object, ...)
	for index = 1, select("#", ...) do
		for key, value in pairs((select(index, ...))) do
			object[key] = value
		end
	end
	return object
end

local function Copy(list)
	local copy = {}
	for index, value in ipairs(list or {}) do
		copy[index] = value
	end
	return copy
end

--------------------------------------------------------------------------------
-- Widgets. A widget has only the methods its type has in Forever. The ones below do what the
-- game does with what the tests look at; any other method only records its last arguments in
-- widget.calls.
--------------------------------------------------------------------------------

local Widget = {}
local recorders = {}

local function Recorder(name)
	local recorder = recorders[name]
	if not recorder then
		recorder = function(self, ...)
			self.calls[name] = { ... }
		end
		recorders[name] = recorder
	end
	return recorder
end

local WidgetMeta = {
	__index = function(widget, key)
		if WIDGET_METHODS[rawget(widget, "widgetType")][key] then
			return Widget[key] or Recorder(key)
		end
		return nil
	end,
}

local function NewWidget(widgetType, parent)
	assert(WIDGET_METHODS[widgetType], "no such widget type: " .. tostring(widgetType))
	local widget = setmetatable({
		widgetType = widgetType,
		parent = parent,
		children = {},
		shown = true,
		enabled = true,
		alpha = 1,
		width = 0,
		height = 0,
		frameLevel = parent and rawget(parent, "frameLevel") or 0,
		scripts = {},
		calls = {},
		points = {},
	}, WidgetMeta)
	if parent then
		parent.children[#parent.children + 1] = widget
	end
	return widget
end

function Widget:GetObjectType()
	return self.widgetType
end
function Widget:GetParent()
	return self.parent
end
function Widget:IsShown()
	return self.shown
end
function Widget:IsVisible()
	return self.shown and (self.parent == nil or self.parent:IsVisible())
end

-- OnShow and OnHide run for a widget and its shown children when it becomes visible or stops
-- being visible.
local function RunVisibilityScripts(widget, name)
	local script = widget.scripts[name]
	if script then
		script(widget)
	end
	for _, child in ipairs(widget.children) do
		if child.shown then
			RunVisibilityScripts(child, name)
		end
	end
end

function Widget:SetShown(shown)
	shown = not not shown
	if shown == self.shown then
		return
	end
	local parentVisible = self.parent == nil or self.parent:IsVisible()
	self.shown = shown
	if parentVisible then
		RunVisibilityScripts(self, shown and "OnShow" or "OnHide")
	end
end
function Widget:Show()
	self:SetShown(true)
end
function Widget:Hide()
	self:SetShown(false)
end
function Widget:SetScript(name, func)
	self.scripts[name] = func
end
function Widget:GetScript(name)
	return self.scripts[name]
end
function Widget:HookScript(name, func)
	local old = self.scripts[name]
	self.scripts[name] = old and function(...)
		old(...)
		func(...)
	end or func
end

-- SetPoint(point), (point, x, y), (point, relativeTo, x, y) and (point, relativeTo,
-- relativePoint, x, y). Setting a point the widget has replaces it.
function Widget:SetPoint(point, a, b, c, d)
	local relativeTo, relativePoint, x, y
	if type(a) == "number" then
		x, y = a, b
	elseif type(b) == "number" then
		relativeTo, x, y = a, b, c
	else
		relativeTo, relativePoint, x, y = a, b, c, d
	end
	local anchor = { point, relativeTo or self.parent, relativePoint or point, x or 0, y or 0 }
	for index, existing in ipairs(self.points) do
		if existing[1] == point then
			self.points[index] = anchor
			return
		end
	end
	self.points[#self.points + 1] = anchor
end
function Widget:ClearAllPoints()
	self.points = {}
end
function Widget:GetNumPoints()
	return #self.points
end
function Widget:GetPoint(index)
	local anchor = self.points[index or 1]
	if anchor then
		return unpack(anchor)
	end
end
function Widget:SetSize(width, height)
	self.width, self.height = width, height
end
function Widget:SetWidth(width)
	self.width = width
end
function Widget:SetHeight(height)
	self.height = height
end
function Widget:GetSize()
	return self.width, self.height
end
function Widget:GetWidth()
	return self.width
end
function Widget:GetHeight()
	return self.height
end
function Widget:SetFrameLevel(level)
	self.frameLevel = level
end
function Widget:GetFrameLevel()
	return self.frameLevel
end
function Widget:SetText(text)
	self.text = text ~= nil and tostring(text) or nil
end
function Widget:GetText()
	return self.text
end
function Widget:SetTextColor(r, g, b)
	self.textColor = { r, g, b }
end
function Widget:SetEnabled(enabled)
	self.enabled = not not enabled
end
function Widget:Enable()
	self.enabled = true
end
function Widget:Disable()
	self.enabled = false
end
function Widget:IsEnabled()
	return self.enabled
end
function Widget:SetAtlas(atlas)
	self.atlas = atlas
end
function Widget:GetAtlas()
	return self.atlas
end
function Widget:SetTexture(texture)
	self.texture = texture
end
function Widget:SetAlpha(alpha)
	self.alpha = alpha
end
function Widget:GetAlpha()
	return self.alpha
end
function Widget:SetDesaturated(desaturated)
	self.desaturated = desaturated
end
function Widget:SetFontObject(font)
	self.fontObject = font
end
function Widget:CreateTexture()
	return NewWidget("Texture", self)
end
function Widget:CreateFontString(_, _, template)
	local text = NewWidget("FontString", self)
	text.fontObject = template
	return text
end
function Widget:CreateLine()
	return NewWidget("Line", self)
end
-- A template on an animation group made in Lua gets its scripts but not its mixin in Forever,
-- so the stand-in takes none (see the addon's comment on SelectableGlow).
function Widget:CreateAnimationGroup(_, template)
	assert(template == nil, "animation group templates are not in the stand-in")
	return NewWidget("AnimationGroup", self)
end
function Widget:CreateAnimation(animationType)
	assert(animationType == "Alpha", "only Alpha animations are in the stand-in")
	return NewWidget("Alpha", self)
end
function Widget:Play()
	self.playing = true
end
function Widget:Stop()
	self.playing = false
end
function Widget:SetPlaying(playing)
	self.playing = not not playing
end
function Widget:IsPlaying()
	return not not self.playing
end

-- A pool of widgets in use (ObjectPool's EnumerateActive gives each active widget).
local function NewPool(make)
	local pool = { active = {}, free = {} }
	function pool:Acquire()
		local widget = table.remove(self.free) or make()
		self.active[widget] = true
		return widget
	end
	function pool:ReleaseAll()
		for widget in pairs(self.active) do
			widget:Hide()
			widget:ClearAllPoints()
			self.free[#self.free + 1] = widget
		end
		self.active = {}
	end
	function pool:EnumerateActive()
		return pairs(self.active)
	end
	return pool
end

--------------------------------------------------------------------------------
-- The made-up class tree (ASSUMED data): three trees side by side in one talent tree, each its
-- own header group with its own currency, as Camelot's RefreshTreeHeaders reads them. Rows are
-- 600 apart in posY; a gate sits on the first talent of each row after the first.
--------------------------------------------------------------------------------

local TREE_ID = 1
local CONFIGS = { 10, 11 } -- the Primary and Secondary spec groups' configs
local SHARED_GROUP = 500 -- a group every talent of the class lists, on no header
local HEADERS = {
	{ groupID = 501, currencyID = 901, displayName = "Tree A" },
	{ groupID = 502, currencyID = 902, displayName = "Tree B" },
	{ groupID = 503, currencyID = 903, displayName = "Tree C" },
}
local NodeType = { Single = 0, Tiered = 1, Selection = 2, SubTreeSelection = 3 }
local EdgeType = { VisualOnly = 0, DeprecatedRankConnection = 1, SufficientForAvailability = 2, RequiredForAvailability = 3, MutuallyExclusive = 4, DeprecatedSelectionOption = 5 }
local EdgeStyle = { None = 0, Straight = 1 }

-- nodeID = { tree, column, row, max ranks, type, entries (entryID = max ranks) }
local NODES = {
	-- Tree A: an arrow from A3 to A5, a choice on row 5, and a capstone on row 7 with no
	-- talent on row 6, so it is the tree's sixth row.
	[1001] = { 1, 1, 1, 5 },
	[1002] = { 1, 2, 1, 5 },
	[1003] = { 1, 1, 2, 3 },
	[1004] = { 1, 2, 2, 2 },
	[1005] = { 1, 1, 3, 1 },
	[1006] = { 1, 2, 3, 5 },
	[1007] = { 1, 1, 4, 3 },
	[1008] = { 1, 2, 5, 1, NodeType.Selection, { { 10081, 1 }, { 10082, 1 } } },
	[1009] = { 1, 1, 7, 1 },
	-- Tree B: a tiered talent (one rank, then two), two talents that shut each other out, and
	-- one that needs either of them.
	[2001] = { 2, 1, 1, 5 },
	[2002] = { 2, 2, 1, 5 },
	[2003] = { 2, 1, 2, 3, NodeType.Tiered, { { 20031, 1 }, { 20032, 2 } } },
	[2004] = { 2, 2, 2, 5 },
	[2005] = { 2, 1, 3, 1 },
	[2006] = { 2, 2, 3, 1 },
	[2007] = { 2, 1, 4, 2 },
	-- Tree C: room for many points.
	[3001] = { 3, 1, 1, 5 },
	[3002] = { 3, 2, 1, 5 },
	[3003] = { 3, 3, 1, 5 },
	[3004] = { 3, 1, 2, 5 },
	[3005] = { 3, 2, 2, 5 },
	[3006] = { 3, 1, 3, 5 },
	[3007] = { 3, 2, 3, 5 },
	[3008] = { 3, 1, 4, 5 },
	[3009] = { 3, 1, 5, 5 },
}
local HIDDEN_NODE = 4001 -- isVisible false
local EMPTY_NODE = 4002 -- no ranks and no entries
local EDGES = {
	{ 1003, 1005, EdgeType.RequiredForAvailability, EdgeStyle.Straight },
	{ 2005, 2006, EdgeType.MutuallyExclusive, EdgeStyle.None },
	{ 2006, 2005, EdgeType.MutuallyExclusive, EdgeStyle.None },
	{ 2005, 2007, EdgeType.SufficientForAvailability, EdgeStyle.Straight },
	{ 2006, 2007, EdgeType.SufficientForAvailability, EdgeStyle.Straight },
}
-- ASSUMED: the wording of a gate's condition; the addon fills in the points and the tree's name.
local GATE_FORMAT = "Requires %d more points in %s talents"

local function PosX(node)
	return (node[1] - 1) * 6000 + node[2] * 600
end
local function PosY(node)
	return 1000 + (node[3] - 1) * 600
end

local function NodeIDs()
	local ids = {}
	for nodeID in pairs(NODES) do
		ids[#ids + 1] = nodeID
	end
	table.sort(ids)
	ids[#ids + 1] = HIDDEN_NODE
	ids[#ids + 1] = EMPTY_NODE
	return ids
end

local function EntriesOf(nodeID)
	local node = NODES[nodeID]
	if node[6] then
		return node[6]
	end
	return { { nodeID * 10, node[4] } }
end

local function EntryNode(entryID)
	for nodeID in pairs(NODES) do
		for _, entry in ipairs(EntriesOf(nodeID)) do
			if entry[1] == entryID then
				return nodeID, entry[2]
			end
		end
	end
end

-- The tree's gates, sorted: one on the first talent of every row after the first.
local function Gates()
	local gates = {}
	for _, nodeID in ipairs(NodeIDs()) do
		local node = NODES[nodeID]
		if node and node[3] > 1 and node[2] == 1 then
			gates[#gates + 1] = { topLeftNodeID = nodeID, conditionID = 7000 + nodeID }
		end
	end
	return gates
end

--------------------------------------------------------------------------------
-- A new game
--------------------------------------------------------------------------------

return function(options)
	options = options or {}
	game = {
		chat = {},
		errors = {},
		writes = {},
		timers = {},
		cvars = {},
		addOnCallbacks = {},
		loadedAddOns = {},
		search = {},
		modified = {},
		activeSpecGroup = options.activeSpecGroup or 1,
		inspecting = false,
		hideSingleRankNumbers = options.hideSingleRankNumbers or false,
		-- ASSUMED: the character's own points, which the plan must never read.
		character = { [10] = { [1001] = 5, [1003] = 3, [2001] = 4 }, [11] = { [3001] = 2 } },
	}

	print = function(...)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[index] = tostring((select(index, ...)))
		end
		game.chat[#game.chat + 1] = table.concat(parts, " ")
	end
	function CallErrorHandler(message)
		game.errors[#game.errors + 1] = tostring(message)
	end
	-- hooksecurefunc runs the hook after the original, with the same arguments.
	function hooksecurefunc(owner, name, hook)
		local original = owner[name]
		assert(type(original) == "function", "hooking a missing function: " .. tostring(name))
		owner[name] = function(...)
			local results = { original(...) }
			hook(...)
			return unpack(results)
		end
	end
	function IsModifiedClick(action)
		return game.modified[action] == true
	end
	ChatFrameUtil = {}
	function ChatFrameUtil.InsertLink(link)
		game.insertedLink = link
	end
	function UnitName()
		return options.playerName or "Ana"
	end
	function GetRealmName()
		return "Realm"
	end
	function GetNumSpecGroups()
		return 2
	end

	-- Strings (enUS).
	UNKNOWNOBJECT = "Unknown"
	DUAL_SPEC_PRIMARY = "Primary"
	DUAL_SPEC_SECONDARY = "Secondary"
	TALENT_SPEC_LOCKED = "Locked"
	TALENT_BUTTON_TOOLTIP_RANK_FORMAT = "Rank %s/%s"
	TALENT_BUTTON_TOOLTIP_NEXT_RANK = "Next Rank:"
	TALENT_BUTTON_TOOLTIP_PURCHASE_INSTRUCTIONS = "Click to learn"
	TALENT_BUTTON_TOOLTIP_REFUND_INSTRUCTIONS = "Right click to unlearn"
	GENERIC_TRAIT_FRAME_EDGE_REQUIREMENTS_BUTTON_TOOLTIP = "Requires all preceding talents"
	TALENT_FRAME_GATE_TOOLTIP_FORMAT = "Spend %d more |4point:points; to unlock this row"

	-- Colors. ASSUMED values: the addon only passes them on, and the tests tell them apart.
	local function CreateColor(r, g, b, a)
		local color = { r = r, g = g, b = b, a = a or 1 }
		function color:GetRGB()
			return self.r, self.g, self.b
		end
		function color:GetRGBA()
			return self.r, self.g, self.b, self.a
		end
		function color:WrapTextInColorCode(text)
			return string.format("|cff%02x%02x%02x%s|r", math.floor(self.r * 255), math.floor(self.g * 255), math.floor(self.b * 255), text)
		end
		return color
	end
	NORMAL_FONT_COLOR = CreateColor(1, 0.82, 0)
	HIGHLIGHT_FONT_COLOR = CreateColor(1, 1, 1)
	WHITE_FONT_COLOR = CreateColor(1, 1, 1)
	RED_FONT_COLOR = CreateColor(1, 0.125, 0.125)
	DIM_RED_FONT_COLOR = CreateColor(0.8, 0.1, 0.1)
	GREEN_FONT_COLOR = CreateColor(0.1, 1, 0.1)
	YELLOW_FONT_COLOR = CreateColor(1, 1, 0)
	GRAY_FONT_COLOR = CreateColor(0.5, 0.5, 0.5)
	DISABLED_FONT_COLOR = CreateColor(0.498, 0.498, 0.498)

	Enum = {
		TraitEdgeType = EdgeType,
		TraitEdgeVisualStyle = EdgeStyle,
		TraitNodeType = NodeType,
	}
	TextureKitConstants = { UseAtlasSize = true, IgnoreAtlasSize = false }

	-- MathUtil.lua and Blizzard's table helpers.
	function Lerp(startValue, endValue, amount)
		return (1 - amount) * startValue + amount * endValue
	end
	function GetKeysArray(tbl)
		local keys = {}
		for key in pairs(tbl) do
			keys[#keys + 1] = key
		end
		table.sort(keys)
		return keys
	end
	function GetOrCreateTableEntry(tbl, key)
		local value = tbl[key]
		if value == nil then
			value = {}
			tbl[key] = value
		end
		return value
	end
	function GenerateClosure(func, ...)
		local bound = { ... }
		return function(...)
			local args = { unpack(bound) }
			for index = 1, select("#", ...) do
				args[#args + 1] = select(index, ...)
			end
			return func(unpack(args))
		end
	end
	MixinUtil = {}
	function MixinUtil.CallMethodSafe(object, methodName, ...)
		if object and object[methodName] then
			return object[methodName](object, ...)
		end
	end

	-- EventUtil.ContinueOnAddOnLoaded: now if the addon is loaded, else on its ADDON_LOADED.
	C_AddOns = {}
	function C_AddOns.IsAddOnLoaded(name)
		return game.loadedAddOns[name] == true, game.loadedAddOns[name] == true
	end
	EventUtil = {}
	function EventUtil.ContinueOnAddOnLoaded(name, callback)
		if select(2, C_AddOns.IsAddOnLoaded(name)) then
			callback()
			return
		end
		local list = game.addOnCallbacks[name] or {}
		game.addOnCallbacks[name] = list
		list[#list + 1] = callback
	end
	local function AddOnLoaded(name)
		game.loadedAddOns[name] = true
		local list = game.addOnCallbacks[name] or {}
		game.addOnCallbacks[name] = nil
		for _, callback in ipairs(list) do
			callback()
		end
	end

	C_Timer = {}
	function C_Timer.After(_, callback)
		game.timers[#game.timers + 1] = callback
	end

	CVarCallbackRegistry = {}
	function CVarCallbackRegistry:RegisterCallback(cvar, func)
		game.cvarCallback = { cvar = cvar, func = func }
	end
	function CVarCallbackRegistry:GetCVarValueBool(cvar)
		return game.cvars[cvar] == true
	end

	-- Spells. ASSUMED: every spell's data is loaded, named after its talent's entry.
	local function SpellName(spellID)
		return "Talent " .. (spellID - 900000)
	end
	C_Spell = {}
	function C_Spell.GetSpellName(spellID)
		return SpellName(spellID)
	end
	function C_Spell.GetSpellLink(spellID)
		return "|cff71d5ff|Hspell:" .. spellID .. ":0|h[" .. SpellName(spellID) .. "]|h|r"
	end
	function C_Spell.GetSpellTexture(spellID)
		return spellID, spellID
	end
	Spell = {}
	function Spell:CreateFromSpellID()
		return {
			IsSpellDataCached = function()
				return true
			end,
		}
	end
	TalentUtil = {}
	function TalentUtil.GetTalentName(overrideName, spellID)
		if overrideName and overrideName ~= "" then
			return overrideName
		end
		if spellID then
			local spellName = C_Spell.GetSpellName(spellID)
			if spellName then
				return spellName
			end
		end
		return nil
	end
	C_StringUtil = {}
	function C_StringUtil.StripHyperlinks(text)
		return (text:gsub("|H.-|h(.-)|h", "%1"))
	end

	-- Search (Blizzard_SpellSearchUtil.lua).
	SpellSearchUtil = { MatchType = { DescriptionMatch = 1, NameMatch = 2, RelatedMatch = 3, ExactMatch = 4, NotOnActionBar = 5, OnInactiveBonusBar = 6, OnDisabledActionBar = 7, AssistedCombat = 8 } }
	function SpellSearchUtil.IsActionBarMatchType(matchType)
		local types = SpellSearchUtil.MatchType
		return matchType == types.NotOnActionBar or matchType == types.OnInactiveBonusBar or matchType == types.OnDisabledActionBar
	end

	-- Tooltips: the lines a tooltip shows, each with its kind.
	GAME_TOOLTIP_BACKDROP_STYLE_CLASS_TALENT = {}
	GameTooltip = { lines = {}, shown = false }
	function GameTooltip:SetOwner(owner)
		self.owner = owner
		self.lines = {}
	end
	function GameTooltip:GetOwner()
		return self.owner
	end
	function GameTooltip:ClearLines()
		self.lines = {}
	end
	function GameTooltip:AddLine(text, kind)
		self.lines[#self.lines + 1] = { text = text, kind = kind or "normal" }
	end
	-- The talent window's tooltip fills in a talent's text from its entry.
	function GameTooltip:AppendInfo(getter, entryID, rank)
		self:AddLine(string.format("%s %d rank %d", getter, entryID, rank), "info")
	end
	function GameTooltip:Show()
		self.shown = true
	end
	function GameTooltip:Hide()
		self.shown = false
		self.owner = nil
	end
	function GameTooltip:IsShown()
		return self.shown
	end
	function SharedTooltip_SetBackdropStyle() end
	function GameTooltip_SetTitle(tooltip, text)
		tooltip:ClearLines()
		tooltip:AddLine(text, "title")
	end
	function GameTooltip_AddBlankLineToTooltip(tooltip)
		tooltip:AddLine(" ", "blank")
	end
	function GameTooltip_AddHighlightLine(tooltip, text)
		tooltip:AddLine(text, "highlight")
	end
	function GameTooltip_AddNormalLine(tooltip, text)
		tooltip:AddLine(text, "normal")
	end
	function GameTooltip_AddInstructionLine(tooltip, text)
		tooltip:AddLine(text, "instruction")
	end
	function GameTooltip_AddDisabledLine(tooltip, text)
		tooltip:AddLine(text, "disabled")
	end
	function GameTooltip_AddErrorLine(tooltip, text)
		tooltip:AddLine(text, "error")
	end
	function GameTooltip_Hide()
		GameTooltip:Hide()
	end

	----------------------------------------------------------------------------
	-- C_Traits and C_SpecializationInfo over the made-up tree
	----------------------------------------------------------------------------

	C_SpecializationInfo = {}
	function C_SpecializationInfo.GetActiveSpecGroup()
		return game.activeSpecGroup
	end
	function C_SpecializationInfo.GetCombatConfigIDForSpecGroup(specGroup)
		return CONFIGS[specGroup]
	end

	local function KnownConfig(configID)
		return configID == CONFIGS[1] or configID == CONFIGS[2]
	end

	local Traits = {}
	function Traits.GetConfigInfo(configID)
		if KnownConfig(configID) then
			return { ID = configID, type = 1, name = "", treeIDs = { TREE_ID }, usesSharedActionBars = false }
		end
	end
	function Traits.GetTreeNodes(treeID)
		if game.failTreeNodes then
			error("tree nodes failed")
		end
		return treeID == TREE_ID and NodeIDs() or {}
	end
	-- What the game tells about a node, with the character's own points in it (ASSUMED shape of
	-- those fields: the plan must not read them anyway).
	function Traits.GetNodeInfo(configID, nodeID)
		local node = NODES[nodeID]
		local ranks = game.character[configID] and game.character[configID][nodeID] or 0
		if nodeID == HIDDEN_NODE then
			return { ID = nodeID, posX = 100, posY = 1000, maxRanks = 1, type = NodeType.Single, entryIDs = { 40010 }, visibleEdges = {}, groupIDs = { SHARED_GROUP }, conditionIDs = {}, isVisible = false }
		elseif nodeID == EMPTY_NODE then
			return { ID = nodeID, posX = 200, posY = 9000, maxRanks = 0, type = NodeType.Single, entryIDs = {}, visibleEdges = {}, groupIDs = { SHARED_GROUP }, conditionIDs = {}, isVisible = true }
		elseif not node then
			return { ID = 0 }
		end
		local edges = {}
		for _, edge in ipairs(EDGES) do
			if edge[1] == nodeID then
				edges[#edges + 1] = { targetNode = edge[2], type = edge[3], visualStyle = edge[4], isActive = false }
			end
		end
		local entryIDs = {}
		for index, entry in ipairs(EntriesOf(nodeID)) do
			entryIDs[index] = entry[1]
		end
		return {
			ID = nodeID,
			posX = PosX(node),
			posY = PosY(node),
			flags = 0,
			maxRanks = node[4],
			type = node[5] or NodeType.Single,
			entryIDs = entryIDs,
			visibleEdges = edges,
			groupIDs = { SHARED_GROUP, HEADERS[node[1]].groupID },
			conditionIDs = {},
			isVisible = true,
			ranksPurchased = ranks,
			activeRank = ranks,
			currentRank = ranks,
			canPurchaseRank = ranks < node[4],
			canRefundRank = ranks > 0,
			activeEntry = ranks > 0 and { entryID = entryIDs[1], rank = ranks } or nil,
		}
	end
	function Traits.GetEntryInfo(configID, entryID)
		local nodeID, maxRanks = EntryNode(entryID)
		if KnownConfig(configID) and nodeID then
			return { definitionID = entryID, type = 1, maxRanks = maxRanks, isAvailable = true, conditionIDs = {} }
		end
	end
	function Traits.GetDefinitionInfo(definitionID)
		return { spellID = 900000 + definitionID }
	end
	function Traits.GetSubTreeInfo()
		return nil
	end
	function Traits.GetTreeInfo(configID, treeID)
		if KnownConfig(configID) and treeID == TREE_ID then
			-- Camelot's override fills in the zoom and button size.
			return { ID = treeID, gates = Gates(), hideSingleRankNumbers = game.hideSingleRankNumbers, minZoom = 1, maxZoom = 1, buttonSize = 40 }
		end
	end
	function Traits.GetConditionInfo(_, conditionID)
		local nodeID = conditionID - 7000
		local node = NODES[nodeID]
		if node then
			return { condID = conditionID, isGate = true, isMet = false, spentAmountRequired = (node[3] - 1) * 5, tooltipFormat = GATE_FORMAT }
		end
	end
	function Traits.GetGroupDisplayInfoByTreeID(treeID)
		local infos = {}
		if treeID == TREE_ID then
			for index, header in ipairs(HEADERS) do
				infos[index] = { groupID = header.groupID, treeID = treeID, orderIndex = index, displayName = header.displayName, icon = 1000 + index }
			end
		end
		return infos
	end
	-- The character's spent points per tree. ASSUMED: groups without a currency aren't listed.
	function Traits.GetGroupCurrencyInfo(configID, groupIDs)
		local infos = {}
		for _, groupID in ipairs(groupIDs) do
			for index, header in ipairs(HEADERS) do
				if header.groupID == groupID then
					local spent = 0
					for nodeID, ranks in pairs(game.character[configID] or {}) do
						if NODES[nodeID][1] == index then
							spent = spent + ranks
						end
					end
					infos[#infos + 1] = { traitNodeGroupID = groupID, currencyInfos = { { traitCurrencyID = header.currencyID, quantity = 51, spent = spent } } }
				end
			end
		end
		return infos
	end
	function Traits.GetNodeCost(_, nodeID)
		local node = NODES[nodeID]
		if node then
			return { { ID = HEADERS[node[1]].currencyID, amount = 1 } }
		end
		return {}
	end
	-- The calls that change the character's talents. The plan must never make them.
	for _, name in ipairs({ "PurchaseRank", "RefundRank", "SetSelection", "CommitConfig", "ResetTree", "ResetTreeByCurrency", "CascadeRepurchaseRanks", "ClearCascadeRepurchaseHistory", "RollbackConfig", "StageConfig", "TryPurchaseAllRanks", "TryPurchaseToNode", "TryRefundToNode", "LoadConfig", "RenameConfig", "DeleteConfig", "CreateConfig" }) do
		Traits[name] = function()
			game.writes[#game.writes + 1] = name
		end
	end
	C_Traits = setmetatable(Traits, {
		__index = function(_, name)
			error("C_Traits." .. tostring(name) .. " is not in the stand-in", 2)
		end,
	})

	----------------------------------------------------------------------------
	-- Talent buttons (Blizzard_SharedTalentUtil.lua, Blizzard_TalentButtonArt.lua, and Camelot's
	-- overrides)
	----------------------------------------------------------------------------

	TalentButtonUtil = {
		CircleEdgeDiameterOffset = 1.2,
		SquareEdgeMinDiameterOffset = 1.2,
		SquareEdgeMaxDiameterOffset = 1.5,
		ChoiceEdgeMinDiameterOffset = 1.2,
		ChoiceEdgeMaxDiameterOffset = 1.5,
		BaseVisualState = { Normal = 1, Gated = 2, Disabled = 3, Locked = 4, Selectable = 5, Maxed = 6, Invisible = 7, RefundInvalid = 8, DisplayError = 9 },
	}
	local States = TalentButtonUtil.BaseVisualState
	function TalentButtonUtil.TranslateNodePositionsToAnchorPositions(posX, posY, offsetX, offsetY)
		return (posX / 10) - offsetX, (-posY / 10) + offsetY
	end
	-- Camelot's colors: green until maxed.
	function TalentButtonUtil.GetColorForBaseVisualState(visualState)
		if visualState == States.Gated or visualState == States.Disabled or visualState == States.Locked then
			return DISABLED_FONT_COLOR
		elseif visualState == States.Selectable then
			return GREEN_FONT_COLOR
		elseif visualState == States.RefundInvalid or visualState == States.DisplayError then
			return RED_FONT_COLOR
		elseif visualState ~= States.Maxed then
			return GREEN_FONT_COLOR
		end
		return YELLOW_FONT_COLOR
	end
	function TalentButtonUtil.CalculateIconTextureFromInfo(definitionInfo, subTreeInfo)
		if subTreeInfo and subTreeInfo.iconElementID and subTreeInfo.iconElementID ~= "" then
			return subTreeInfo.iconElementID, true
		end
		local spellID = definitionInfo and definitionInfo.spellID or nil
		return TalentButtonUtil.CalculateIconTexture(definitionInfo, spellID), false
	end
	function TalentButtonUtil.CalculateIconTexture(definitionInfo, overrideSpellID)
		if definitionInfo then
			if definitionInfo.overrideIcon then
				return definitionInfo.overrideIcon
			end
			local spellID = overrideSpellID or definitionInfo.spellID
			if spellID then
				return select(2, C_Spell.GetSpellTexture(spellID))
			end
		end
		return [[Interface\Icons\spell_magic_polymorphrabbit]]
	end
	function TalentButtonUtil.SetSpendText(button, spendText)
		MixinUtil.CallMethodSafe(button.SpendText, "SetText", spendText)
	end
	local SearchMatchStyles = {
		[SpellSearchUtil.MatchType.ExactMatch] = { icon = "talents-search-exactmatch" },
		[SpellSearchUtil.MatchType.NameMatch] = { icon = "talents-search-match" },
		[SpellSearchUtil.MatchType.DescriptionMatch] = { icon = "talents-search-match" },
		[SpellSearchUtil.MatchType.RelatedMatch] = { icon = "talents-search-match" },
		[SpellSearchUtil.MatchType.NotOnActionBar] = { icon = "talents-search-notonactionbar" },
		[SpellSearchUtil.MatchType.OnInactiveBonusBar] = { icon = "talents-search-notonactionbarhidden" },
		[SpellSearchUtil.MatchType.OnDisabledActionBar] = { icon = "talents-search-notonactionbarhidden" },
	}
	function TalentButtonUtil.GetStyleForSearchMatchType(matchType)
		return SearchMatchStyles[matchType]
	end
	local HoverAlphaByVisualState = { [States.Normal] = 1, [States.Gated] = 0.4, [States.Disabled] = 0.4, [States.Locked] = 0.4, [States.Selectable] = 1, [States.Maxed] = 1, [States.Invisible] = 0, [States.RefundInvalid] = 0.4, [States.DisplayError] = 1 }
	function TalentButtonUtil.GetHoverAlphaForVisualStyle(visualStyle)
		return HoverAlphaByVisualState[visualStyle]
	end

	local function ArtSet(prefix)
		return {
			shadow = "talents-node-" .. prefix .. "-shadow",
			normal = "talents-node-" .. prefix .. "-yellow",
			disabled = "talents-node-" .. prefix .. "-gray",
			selectable = "talents-node-" .. prefix .. "-green",
			maxed = "talents-node-" .. prefix .. "-yellow",
			locked = "talents-node-" .. prefix .. "-locked",
			refundInvalid = "talents-node-" .. prefix .. "-red",
			displayError = "talents-node-" .. prefix .. "-red",
			glow = "talents-node-" .. prefix .. "-greenglow",
			spendFont = "SystemFont16_Shadow_ThickOutline",
		}
	end
	TalentButtonArtMixin = {
		ArtSet = {
			Square = ArtSet("square"),
			Circle = ArtSet("circle"),
			Choice = ArtSet("choice"),
			LargeSquare = ArtSet("square-large"),
			LegionSquare = ArtSet("square-legion"),
			LegionChoice = ArtSet("choice-legion"),
			CapstoneCircle = ArtSet("circle-capstone"),
			CapstoneSquare = ArtSet("square-capstone"),
			LegacySquare = ArtSet("square-legacy"),
		},
	}
	function TalentButtonArtMixin:ApplyVisualState(visualState)
		-- Stand-in bookkeeping: the tests read the state a button was drawn with.
		self.standinVisualState = visualState
		local color = TalentButtonUtil.GetColorForBaseVisualState(visualState)
		local r, g, b = color:GetRGB()
		MixinUtil.CallMethodSafe(self.SpendText, "SetTextColor", r, g, b)
		local isRefundInvalid = visualState == States.RefundInvalid
		local isDisplayError = visualState == States.DisplayError
		local iconVertexColor = (isRefundInvalid or isDisplayError) and DIM_RED_FONT_COLOR or WHITE_FONT_COLOR
		self.Icon:SetVertexColor(iconVertexColor:GetRGBA())
		local isGated = visualState == States.Gated
		MixinUtil.CallMethodSafe(self.DisabledOverlay, "SetAlpha", (isGated and 0.7) or (isRefundInvalid and 0.4) or 0.25)
		local isLocked = visualState == States.Locked
		local isDisabled = visualState == States.Disabled
		local isDimmed = isGated or isLocked or isDisabled
		self.Icon:SetDesaturated(not isRefundInvalid and isDimmed)
		MixinUtil.CallMethodSafe(self.DisabledOverlay, "SetShown", isRefundInvalid or isDimmed)
		if self.SelectableIcon then
			local isSelectable = visualState == States.Selectable
			self.SelectableIcon:SetShown(isSelectable and CVarCallbackRegistry:GetCVarValueBool("colorblindMode"))
		end
		self:UpdateStateBorder(visualState)
	end
	function TalentButtonArtMixin:SetBorderAtlas(atlas, visualState)
		self.StateBorder:SetAtlas(atlas, TextureKitConstants.UseAtlasSize)
		if self.StateBorderHover then
			self.StateBorderHover:SetAtlas(atlas, TextureKitConstants.UseAtlasSize)
			self.StateBorderHover:SetAlpha(TalentButtonUtil.GetHoverAlphaForVisualStyle(visualState))
		end
	end
	-- Camelot's border: green until maxed.
	function TalentButtonArtMixin:UpdateStateBorder(visualState)
		local isDisabled = visualState == States.Gated or visualState == States.Locked or visualState == States.Disabled
		if visualState == States.RefundInvalid then
			self:SetBorderAtlas(self.artSet.refundInvalid, visualState)
		elseif visualState == States.DisplayError then
			self:SetBorderAtlas(self.artSet.displayError, visualState)
		elseif visualState == States.Gated then
			self:SetBorderAtlas(self.artSet.locked, visualState)
		elseif visualState == States.Selectable then
			self:SetBorderAtlas(self.artSet.selectable, visualState)
		elseif visualState == States.Maxed then
			self:SetBorderAtlas(self.artSet.maxed, visualState)
		elseif visualState ~= States.Maxed and not isDisabled then
			self:SetBorderAtlas(self.artSet.selectable, visualState)
		else
			self:SetBorderAtlas(self.artSet.disabled, visualState)
		end
	end
	function TalentButtonArtMixin:GetCircleEdgeDiameterOffset()
		return TalentButtonUtil.CircleEdgeDiameterOffset
	end
	function TalentButtonArtMixin:GetSquareEdgeDiameterOffset(angle)
		local quarterRotation = math.pi / 2
		local eighthRotation = quarterRotation / 2
		local progress = math.abs(((eighthRotation + angle) % quarterRotation) - eighthRotation)
		return Lerp(TalentButtonUtil.SquareEdgeMinDiameterOffset, TalentButtonUtil.SquareEdgeMaxDiameterOffset, progress)
	end
	function TalentButtonArtMixin:GetChoiceEdgeDiameterOffset(angle)
		local eighthRotation = math.pi / 4
		local sixteenthRotation = eighthRotation / 2
		local progress = math.abs(((sixteenthRotation + angle) % eighthRotation) - sixteenthRotation)
		return Lerp(TalentButtonUtil.ChoiceEdgeMinDiameterOffset, TalentButtonUtil.ChoiceEdgeMaxDiameterOffset, progress)
	end

	----------------------------------------------------------------------------
	-- Frames made from templates
	----------------------------------------------------------------------------

	local TalentButtonSearchIconMixin = {}
	function TalentButtonSearchIconMixin:SetMatchType(matchType)
		self.matchType = matchType
		if not self.matchType then
			self.tooltipText = nil
			self:Hide()
		else
			self:Show()
			local matchStyle = TalentButtonUtil.GetStyleForSearchMatchType(self.matchType)
			self.Icon:SetAtlas(matchStyle.icon)
			self.OverlayIcon:SetAtlas(matchStyle.icon)
		end
	end

	-- The dropdown's menu: the radios its generator makes, picked as the menu does.
	local DropdownButtonMixin = {}
	function DropdownButtonMixin:SetupMenu(generator)
		self.menuGenerator = generator
	end
	function DropdownButtonMixin:GenerateMenu()
		local root = { radios = {} }
		function root:CreateRadio(text, isSelected, setSelected, data)
			self.radios[#self.radios + 1] = { text = text, isSelected = isSelected, setSelected = setSelected, data = data }
		end
		self.menuGenerator(self, root)
		self.menu = root
		for _, radio in ipairs(root.radios) do
			if radio.isSelected(radio.data) then
				self.selectedText = radio.text
			end
		end
	end
	function DropdownButtonMixin:CloseMenu()
		self.menuOpen = false
	end

	local TEMPLATES = {
		TalentButtonSearchIconTemplate = function(frame)
			frame.mouseoverSize = 10
			frame.Icon = frame:CreateTexture()
			frame.OverlayIcon = frame:CreateTexture()
			frame.Mouseover = frame:CreateTexture()
			frame.Mouseover:SetSize(18, 18)
			frame.GlowAnim = frame:CreateAnimationGroup()
			Mixin(frame, TalentButtonSearchIconMixin)
		end,
		TalentFrameGateTemplate = function(frame)
			frame:SetSize(124, 40)
			frame.LockIcon = frame:CreateTexture()
			frame.LockIcon:SetAtlas("talents-gate")
			frame.GateText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge2")
			frame.GateText:Hide()
		end,
		UIPanelButtonNoTooltipTemplate = function() end,
		WowStyle1DropdownTemplate = function() end,
	}

	function CreateFrame(frameType, _, parent, template)
		local widgetType = frameType == "DropdownButton" and "Button" or frameType
		local frame = NewWidget(widgetType, parent)
		if frameType == "DropdownButton" then
			Mixin(frame, DropdownButtonMixin)
		end
		if template then
			local apply = TEMPLATES[template]
			assert(apply, "template not in the stand-in: " .. template)
			apply(frame)
		end
		return frame
	end

	UIParent = NewWidget("Frame", nil)

	----------------------------------------------------------------------------
	-- Tabs (TabSystemOwner.lua and TabSystemTemplates.lua) and the talent window's tabs
	----------------------------------------------------------------------------

	local TabSystemTrackerMixin = {}
	function TabSystemTrackerMixin:Init()
		self.tabbedElements = {}
		self.tabIDToElementSet = {}
		self.tabIDToTabCallback = {}
		self.tabIDToTabDeselectCallback = {}
	end
	function TabSystemTrackerMixin:AddTab(tabID)
		self.tabIDToElementSet[tabID] = {}
	end
	function TabSystemTrackerMixin:SetTab(tabID, isUserAction)
		if self.tabID and tabID ~= self.tabID then
			local deselectCallback = self.tabIDToTabDeselectCallback[self.tabID]
			if deselectCallback then
				deselectCallback(isUserAction)
			end
		end
		self.tabID = tabID
		local tabCallback = self.tabIDToTabCallback[tabID]
		if tabCallback then
			tabCallback(isUserAction)
		end
	end
	function TabSystemTrackerMixin:GetTab()
		return self.tabID
	end
	function TabSystemTrackerMixin:GetTabSet()
		return GetKeysArray(self.tabIDToElementSet)
	end

	TabSystemOwnerMixin = {}
	function TabSystemOwnerMixin:OnLoad()
		self.internalTabTracker = Mixin({}, TabSystemTrackerMixin)
		self.internalTabTracker:Init()
	end
	function TabSystemOwnerMixin:SetTabSystem(tabSystem)
		self.tabSystem = tabSystem
		tabSystem:SetTabSelectedCallback(GenerateClosure(self.SetTab, self))
	end
	function TabSystemOwnerMixin:AddNamedTab(tabName)
		local tabID = self.tabSystem:AddTab(tabName)
		self.internalTabTracker:AddTab(tabID)
		return tabID
	end
	function TabSystemOwnerMixin:SetTab(tabID, isUserAction)
		self.internalTabTracker:SetTab(tabID, isUserAction)
		self.tabSystem:SetTabVisuallySelected(tabID)
	end
	function TabSystemOwnerMixin:GetTab()
		return self.internalTabTracker:GetTab()
	end
	function TabSystemOwnerMixin:GetTabSet()
		return self.internalTabTracker:GetTabSet()
	end
	function TabSystemOwnerMixin:GetTabButton(tabID)
		return self.tabSystem:GetTabButton(tabID)
	end

	TabSystemButtonMixin = {}
	-- A tab's Button:SetText writes its Text (ASSUMED: Text is the button's font string).
	function TabSystemButtonMixin:Init(tabID, tabText)
		self.tabID = tabID
		self.tabText = tabText
		if tabText then
			self.Text:SetText(tabText)
		end
		self:SetTabSelected(false)
	end
	function TabSystemButtonMixin:GetTabText()
		return self.tabText
	end
	function TabSystemButtonMixin:UpdateTabText()
		local tabText = self:GetTabText()
		local text = not self:IsForceDisabled() and tabText or DISABLED_FONT_COLOR:WrapTextInColorCode(tabText)
		self.Text:SetText(text)
	end
	function TabSystemButtonMixin:SetTabEnabled(enabled, errorReason)
		self.forceDisabled = not enabled
		self:SetEnabled(not self:IsForceDisabled() and not self.isSelected)
		self:UpdateTabText()
		self.errorReason = errorReason
	end
	function TabSystemButtonMixin:IsForceDisabled()
		return self.forceDisabled, self.errorReason
	end
	function TabSystemButtonMixin:GetTabID()
		return self.tabID
	end
	-- TabSystemButtonArtMixin:SetTabSelected, without the art.
	function TabSystemButtonMixin:SetTabSelected(isSelected)
		self.isSelected = isSelected
		self:SetEnabled(not self:IsForceDisabled() and not isSelected)
	end
	function TabSystemButtonMixin:OnClick()
		self:GetParent():SetTab(self:GetTabID(), true)
	end

	-- Camelot's talent tabs mark the active spec's tab and lock a disabled one.
	local function CreateAtlasMarkup(atlasName, width, height, offsetX, offsetY)
		return ("|A:%s:%d:%d:%d:%d|a"):format(atlasName, height or 0, width or 0, offsetX or 0, offsetY or 0)
	end
	local TAB_CHECKMARK_MARKUP = CreateAtlasMarkup("Talents-Checkmark-c60", 20, 15)
	local TAB_LOCK_MARKUP = CreateAtlasMarkup("Talents-lock-c60", 10, 14)
	local ClassTalentsFrameTabMixin = {}
	function ClassTalentsFrameTabMixin:SetIsActive(isActive)
		self.isActive = isActive
		self:UpdateTabText()
	end
	function ClassTalentsFrameTabMixin:IsActive()
		return self.isActive
	end
	function ClassTalentsFrameTabMixin:GetTabText()
		local primaryText = TabSystemButtonMixin.GetTabText(self)
		if self:IsActive() then
			return primaryText .. " " .. TAB_CHECKMARK_MARKUP
		elseif not self:IsEnabled() then
			return primaryText .. " " .. TAB_LOCK_MARKUP
		end
		return primaryText
	end

	local TabSystemMixin = {}
	function TabSystemMixin:AddTab(tabText)
		local tabID = #self.tabs + 1
		local tab = NewWidget("Button", self)
		tab.Text = tab:CreateFontString()
		Mixin(tab, TabSystemButtonMixin, ClassTalentsFrameTabMixin)
		tab:SetScript("OnClick", tab.OnClick)
		self.tabs[tabID] = tab
		tab:Init(tabID, tabText)
		return tabID
	end
	function TabSystemMixin:SetTabSelectedCallback(callback)
		self.tabSelectedCallback = callback
	end
	function TabSystemMixin:SetTab(tabID, isUserAction)
		if not self.tabSelectedCallback(tabID, isUserAction) then
			self:SetTabVisuallySelected(tabID)
		end
	end
	function TabSystemMixin:SetTabVisuallySelected(tabID)
		self.selectedTabID = tabID
		for _, tab in ipairs(self.tabs) do
			tab:SetTabSelected(tab:GetTabID() == tabID)
		end
	end
	function TabSystemMixin:SetTabEnabled(tabID, enabled, errorReason)
		self.tabs[tabID]:SetTabEnabled(enabled, errorReason)
	end
	function TabSystemMixin:GetTabButton(tabID)
		return self.tabs[tabID]
	end

	----------------------------------------------------------------------------
	-- The talent window (TalentFrameBaseMixin and Camelot's ClassTalentsFrameMixin)
	----------------------------------------------------------------------------

	local TalentFrameMixin = {}
	function TalentFrameMixin:GetConfigID()
		return self.configurationInfo and self.configurationInfo.ID or nil
	end
	function TalentFrameMixin:GetTalentTreeID()
		return self.talentTreeID
	end
	function TalentFrameMixin:GetTreeInfo()
		return self.talentTreeInfo
	end
	function TalentFrameMixin:GetButtonSize()
		return self.buttonSize
	end
	function TalentFrameMixin:ShouldHideSingleRankNumbers()
		return self:GetTreeInfo().hideSingleRankNumbers
	end
	function TalentFrameMixin:AnchorGate(gate, button)
		gate:SetPoint("RIGHT", button, "LEFT", -12, 0)
	end
	function TalentFrameMixin:GetPanOffset()
		return self.basePanOffsetX + self.panOffsetX, self.basePanOffsetY + self.panOffsetY
	end
	function TalentFrameMixin:GetTalentButtonByNodeID(nodeID)
		return self.nodeIDToButton[nodeID]
	end
	function TalentFrameMixin:EnumerateAllTalentButtons()
		return self.talentButtonCollection:EnumerateActive()
	end
	function TalentFrameMixin:IsInspecting()
		return game.inspecting
	end
	-- ASSUMED: the talent window's search answer, set by the tests.
	function TalentFrameMixin:GetSearchMatchTypeForEntry(nodeID, entryID)
		return game.search[nodeID .. ":" .. tostring(entryID)] or game.search[nodeID .. ":nil"]
	end
	function TalentFrameMixin:DisplayFullSearchResults() end
	-- The game's own talent buttons for the character's tree. ASSUMED: their icon size and
	-- where their number sits.
	function TalentFrameMixin:InstantiateTalentButton(nodeID)
		local frame = self
		local info = C_Traits.GetNodeInfo(self:GetConfigID(), nodeID)
		local button = NewWidget("Button", self.ButtonsParent)
		button.nodeID = nodeID
		button.artSet = info.type == NodeType.Selection and TalentButtonArtMixin.ArtSet.Choice or TalentButtonArtMixin.ArtSet.Square
		button.GetEdgeDiameterOffset = TalentButtonArtMixin.GetSquareEdgeDiameterOffset
		button.Icon = button:CreateTexture()
		button.Icon:SetSize(36, 36)
		button.SpendText = button:CreateFontString()
		button.SpendText:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 4, -4)
		function button:GetNodeInfo()
			return C_Traits.GetNodeInfo(frame:GetConfigID(), self.nodeID)
		end
		self.nodeIDToButton[nodeID] = button
		self.talentButtonCollection.active[button] = true
		return button
	end
	-- Loads the config's tree, the way the talent window does when its config changes
	-- (ASSUMED order of the steps; the game spreads them over frames).
	function TalentFrameMixin:RefreshConfigID()
		self.talentButtonCollection:ReleaseAll()
		self.nodeIDToButton = {}
		self.edgePool:ReleaseAll()
		for _, nodeID in ipairs(C_Traits.GetTreeNodes(self:GetTalentTreeID())) do
			local info = C_Traits.GetNodeInfo(self:GetConfigID(), nodeID)
			if info.ID ~= 0 and info.isVisible and info.maxRanks > 0 then
				self:InstantiateTalentButton(nodeID)
				for _ in ipairs(info.visibleEdges) do
					self.edgePool:Acquire():Show()
				end
			end
		end
		self.talentTreeInfo = C_Traits.GetTreeInfo(self:GetConfigID(), self:GetTalentTreeID())
		self:RefreshGates()
		self:RefreshTreeHeaders()
		self:RefreshClassCurrencyDisplay()
		self:UpdateConfigButtonsState()
		self:DisplayFullSearchResults()
	end
	function TalentFrameMixin:SetConfigID(configID)
		self.configurationInfo = C_Traits.GetConfigInfo(configID)
		self.talentTreeID = self.configurationInfo.treeIDs[1]
		self:RefreshConfigID()
	end
	-- ASSUMED: the game draws a gate on every gate the character hasn't met; the stand-in
	-- draws one per gate.
	function TalentFrameMixin:RefreshGates()
		self.gatePool:ReleaseAll()
		if not self.talentTreeInfo or not self.talentTreeInfo.gates then
			return
		end
		for _ in ipairs(self.talentTreeInfo.gates) do
			self.gatePool:Acquire():Show()
		end
	end
	function TalentFrameMixin:RefreshTreeHeaders()
		self.treeHeaderPool:ReleaseAll()
		self.treeHeaders = {}
		local groupIDs = {}
		local displayInfos = C_Traits.GetGroupDisplayInfoByTreeID(self:GetTalentTreeID())
		for _, displayInfo in ipairs(displayInfos) do
			table.insert(groupIDs, displayInfo.groupID)
		end
		local groupInfos = C_Traits.GetGroupCurrencyInfo(self:GetConfigID(), groupIDs)
		for _, displayInfo in ipairs(displayInfos) do
			local groupInfo
			for _, info in ipairs(groupInfos) do
				if info.traitNodeGroupID == displayInfo.groupID then
					groupInfo = info
				end
			end
			local header = self.treeHeaderPool:Acquire()
			header.displayInfo = displayInfo
			header.Name:SetText(displayInfo.displayName)
			header.Text:SetText(groupInfo and groupInfo.currencyInfos[1].spent or "0")
			header:Show()
			table.insert(self.treeHeaders, header)
		end
	end
	-- ASSUMED: the character's unspent points on the points row.
	function TalentFrameMixin:RefreshClassCurrencyDisplay()
		local spent = 0
		for _, ranks in pairs(game.character[self:GetConfigID()] or {}) do
			spent = spent + ranks
		end
		local amount = self.ClassCurrencyDisplay.CurrentAmountContainer.CurrencyAmount
		amount:SetText(51 - spent)
		amount:Show()
	end
	-- ASSUMED: the game shows its Apply, Undo and Reset buttons as it updates them.
	function TalentFrameMixin:UpdateConfigButtonsState()
		self.ApplyButton:Show()
		self.UndoButton:Show()
		self.ResetButton:Show()
	end
	function TalentFrameMixin:InitializeActiveSpec()
		self.ActiveSpec:Show()
	end
	function TalentFrameMixin:SetDisabledOverlayShown(shown)
		self.DisabledOverlay:SetShown(shown)
	end
	-- ASSUMED: inspecting is set by the tests before this runs.
	function TalentFrameMixin:UpdateInspecting() end
	function TalentFrameMixin:HandlePlayerTalentUpdate()
		self:UpdateTabs()
		self:InitializeActiveSpec()
	end
	function TalentFrameMixin:GetActiveTab()
		if C_SpecializationInfo.GetActiveSpecGroup() == 1 then
			return self.primarySpecTabID
		end
		return self.secondarySpecTabID
	end
	function TalentFrameMixin:InitializeTabSystem()
		TabSystemOwnerMixin.OnLoad(self)
		self:SetTabSystem(self.TabSystem)
		self.primarySpecTabID = self:AddNamedTab(DUAL_SPEC_PRIMARY)
		self.secondarySpecTabID = self:AddNamedTab(DUAL_SPEC_SECONDARY)
		self:SetTab(self:GetActiveTab())
		self:UpdateTabs()
	end
	function TalentFrameMixin:GetTraitTreeName(traitTreeID, groupIDs)
		if groupIDs then
			for _, displayInfo in pairs(C_Traits.GetGroupDisplayInfoByTreeID(traitTreeID)) do
				for _, groupID in ipairs(groupIDs) do
					if displayInfo.groupID == groupID then
						return displayInfo.displayName
					end
				end
			end
		end
		return ""
	end
	function TalentFrameMixin:UpdateTabs()
		self.TabSystem:SetTabEnabled(self.secondarySpecTabID, GetNumSpecGroups() > 1, TALENT_SPEC_LOCKED)
		local activeTab = self:GetActiveTab()
		for _, tabID in ipairs(self:GetTabSet()) do
			self.TabSystem:GetTabButton(tabID):SetIsActive(activeTab == tabID)
		end
	end
	function TalentFrameMixin:SetTab(tabID)
		TabSystemOwnerMixin.SetTab(self, tabID)
		local configID = C_SpecializationInfo.GetCombatConfigIDForSpecGroup(tabID)
		if configID then
			self:SetConfigID(configID)
		else
			self:SetDisabledOverlayShown(true)
		end
	end

	local function NewTalentsFrame()
		PlayerSpellsFrame = NewWidget("Frame", UIParent)
		local frame = NewWidget("Frame", PlayerSpellsFrame)
		PlayerSpellsFrame.TalentsFrame = frame
		Mixin(frame, TabSystemOwnerMixin, TalentFrameMixin)
		frame.buttonSize = 40
		frame.basePanOffsetX, frame.basePanOffsetY, frame.panOffsetX, frame.panOffsetY = 0, 0, 0, 0
		frame.nodeIDToButton = {}
		frame.ButtonsParent = NewWidget("Frame", frame)
		frame.talentButtonCollection = NewPool(function()
			return NewWidget("Button", frame.ButtonsParent)
		end)
		frame.edgePool = NewPool(function()
			return NewWidget("Frame", frame.ButtonsParent)
		end)
		frame.gatePool = NewPool(function()
			return NewWidget("Frame", frame.ButtonsParent)
		end)
		frame.talentDisplayFramePool = NewPool(function()
			return NewWidget("Frame", frame.ButtonsParent)
		end)
		frame.treeHeaderPool = NewPool(function()
			local header = NewWidget("Frame", frame)
			header.Name = header:CreateFontString()
			header.Text = header:CreateFontString()
			return header
		end)
		local display = NewWidget("Frame", frame)
		display.UnspentLabel = display:CreateFontString()
		display.Border = display:CreateTexture()
		display.Border:SetSize(200, 26)
		display.CurrentAmountContainer = NewWidget("Frame", display)
		display.CurrentAmountContainer:SetSize(40, 40)
		display.CurrentAmountContainer.CurrencyAmount = display.CurrentAmountContainer:CreateFontString()
		frame.ClassCurrencyDisplay = display
		frame.BackgroundBorder = NewWidget("Frame", frame)
		frame.Background = frame:CreateTexture()
		frame.ApplyButton = NewWidget("Button", frame)
		frame.UndoButton = NewWidget("Button", frame)
		frame.ResetButton = NewWidget("Button", frame)
		frame.ActiveSpec = NewWidget("Frame", frame)
		frame.DisabledOverlay = NewWidget("Frame", frame)
		frame.DisabledOverlay:Hide()
		frame.TabSystem = Mixin(NewWidget("Frame", frame), TabSystemMixin)
		frame.TabSystem.tabs = {}
		frame:InitializeTabSystem()
		return frame
	end

	----------------------------------------------------------------------------
	-- Playing
	----------------------------------------------------------------------------

	-- The addon loads with its saved plans, as at login.
	JustTheTreesDB = options.saved
	game.ns = {}
	assert(loadfile("Core.lua"))("JustTheTrees", game.ns)
	AddOnLoaded("JustTheTrees")

	-- The talent window loads when the player first opens it.
	function game:OpenTalentWindow()
		if not self.frame then
			self.frame = NewTalentsFrame()
			AddOnLoaded("Blizzard_PlayerSpells")
		end
		PlayerSpellsFrame:Show()
		return self.frame
	end
	function game:CloseTalentWindow()
		PlayerSpellsFrame:Hide()
	end
	function game:Tab(tabID)
		return self.frame.TabSystem:GetTabButton(tabID)
	end
	-- Clicking a tab does nothing while it is turned off or already selected.
	function game:ClickTab(tabID)
		local tab = self:Tab(tabID)
		if tab:IsEnabled() then
			tab.scripts.OnClick(tab, "LeftButton")
		end
	end
	function game:OpenPlan()
		self:OpenTalentWindow()
		self:ClickTab(self.frame.calculatorTabID)
	end
	function game:RunTimers()
		local timers = self.timers
		self.timers = {}
		for _, callback in ipairs(timers) do
			callback()
		end
	end
	-- A plan button, or one choice of a choice talent.
	function game:Button(nodeID, choice)
		local button = self.frame.calculatorNodes[nodeID]
		if choice then
			return button.choices[choice]
		end
		return button
	end
	function game:Click(nodeID, mouseButton, choice)
		local button = self:Button(nodeID, choice)
		assert(button:IsVisible(), "clicking a hidden button")
		button.scripts.OnClick(button, mouseButton or "LeftButton", true)
	end
	function game:ClickTimes(nodeID, times)
		for _ = 1, times do
			self:Click(nodeID)
		end
	end
	function game:Ranks(nodeID)
		local stored = self.ns.ranks[nodeID]
		return stored and stored.ranks or 0
	end
	function game:Spent()
		local spent = 0
		for _, stored in pairs(self.ns.ranks) do
			spent = spent + stored.ranks
		end
		return spent
	end
	local STATE_NAMES = {}
	for name, value in pairs(States) do
		STATE_NAMES[value] = name
	end
	function game:State(nodeID, choice)
		return STATE_NAMES[self:Button(nodeID, choice).standinVisualState]
	end
	-- The talent's tooltip, one line per entry: "kind: text".
	function game:Tooltip(nodeID, choice)
		local button = self:Button(nodeID, choice)
		button.scripts.OnEnter(button)
		local lines = {}
		for _, line in ipairs(GameTooltip.lines) do
			if line.kind ~= "blank" then
				lines[#lines + 1] = line.kind .. ": " .. line.text
			end
		end
		return lines
	end
	function game:PressPlanButton(name)
		local button = self.frame["calculator" .. name .. "Button"]
		assert(button:IsVisible(), name .. " is hidden")
		if button:IsEnabled() then
			button.scripts.OnClick(button, "LeftButton")
			return true
		end
		return false
	end
	function game:PickSlot(slot)
		local dropdown = self.frame.calculatorSlotDropdown
		dropdown:GenerateMenu()
		local radio = dropdown.menu.radios[slot]
		radio.setSelected(radio.data)
		dropdown:GenerateMenu()
	end
	-- The gates the plan shows, by their anchor talent: the points each still needs.
	function game:Gates()
		local gates = {}
		for _, gate in ipairs(self.frame.calculatorGates or {}) do
			if gate:IsShown() then
				local _, anchor = gate:GetPoint(1)
				gates[anchor.calculatorNodeID] = gate.pointsNeeded
			end
		end
		return gates
	end
	function game:HeaderSpent(treeIndex)
		for _, header in ipairs(self.frame.treeHeaders) do
			if header.displayInfo.groupID == HEADERS[treeIndex].groupID then
				return header.calculatorSpentText:GetText(), header.calculatorSpentText:IsShown(), header.Text:IsShown()
			end
		end
	end
	function game:Unspent()
		return self.frame.ClassCurrencyDisplay.calculatorAmountText:GetText()
	end
	function game:LevelRequired()
		return self.frame.ClassCurrencyDisplay.calculatorLevelText:GetText()
	end
	-- What the game's own pieces show: its talent buttons, arrows and gates, and its controls.
	function game:GamePiecesShown()
		local shown = 0
		for _, pool in ipairs({ self.frame.talentButtonCollection, self.frame.edgePool, self.frame.gatePool }) do
			for widget in pool:EnumerateActive() do
				if widget:IsShown() then
					shown = shown + 1
				end
			end
		end
		return shown
	end

	game.NODES = NODES
	game.HIDDEN_NODE = HIDDEN_NODE
	game.EMPTY_NODE = EMPTY_NODE
	game.GATE_FORMAT = GATE_FORMAT
	return game
end
