local addonName, ns = ...

-- Keep equal to ## Version in the .toc. The game reads the .toc only at client start,
-- so the in-game label uses this, which /reload picks up.
local VERSION = "1.1.1"
-- The addon's name as the player sees it: the tab, the title on the points row and chat.
local ADDON_TITLE = "Just the Trees"

-- The plan is a level 60 character: one point per level from 10 through 60.
local MAX_LEVEL = 60
local FIRST_TALENT_LEVEL = 10
local PLAN_BUDGET = MAX_LEVEL - FIRST_TALENT_LEVEL + 1
-- Row 1 of a tree is open. Every row after it needs this many more points spent in the
-- rows above it, in that same tree. A fixed rule, not read from the client.
local POINTS_PER_ROW = 5
-- Talents whose posY differs by no more than this sit on the same row. The game's rows are 600
-- apart (BaseRowHeight in Blizzard_ClassTalentsFrame.lua), and its data puts some talents a few
-- units off their row.
local ROW_TOLERANCE = 150

local TALENT_UI = "Blizzard_PlayerSpells"
-- Checked at load with the game's other pieces (see Loading).
local EDGE_TYPES = Enum.TraitEdgeType or {}
local REQUIRED_EDGE = EDGE_TYPES.RequiredForAvailability
local SUFFICIENT_EDGE = EDGE_TYPES.SufficientForAvailability
local EXCLUSIVE_EDGE = EDGE_TYPES.MutuallyExclusive

-- The addon's own frame for game events (see Loading), and the color blind mode
-- update, set once the talent window is installed.
local events = CreateFrame("Frame")
local OnColorBlindMode

--------------------------------------------------------------------------------
-- Saved plans
--------------------------------------------------------------------------------

-- The saved layout's version. Raise it only when a change stores plans differently,
-- and convert the older layout in NormalizeSaved. Saves without a format already
-- use format 1's layout.
local SAVE_FORMAT = 1

local function WholeNumber(value, low, high)
	return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

-- One saved talent: node, ranks and chosen entry, or nil when the entry is damaged.
-- Ranks are whole points from 1 to the budget. The tree's own max ranks are not
-- known until it is on screen; FitPlanToTree applies them.
local function CleanNode(node)
	if type(node) ~= "table" or not WholeNumber(node.nodeID, 1, math.huge) or not WholeNumber(node.ranks, 1, PLAN_BUDGET) then
		return nil
	end
	return {
		nodeID = node.nodeID,
		ranks = node.ranks,
		entryID = WholeNumber(node.entryID, 1, math.huge) and node.entryID or 0,
	}
end

-- A saved plan keeps only its talents, each node once.
local function CleanPlan(plan)
	if type(plan) ~= "table" or type(plan.nodes) ~= "table" then
		return nil
	end
	local nodes = {}
	local seen = {}
	for _, node in ipairs(plan.nodes) do
		local clean = CleanNode(node)
		if clean and not seen[clean.nodeID] then
			seen[clean.nodeID] = true
			nodes[#nodes + 1] = clean
		end
	end
	return { nodes = nodes }
end

-- Runs on every load. Rebuilds JustTheTreesDB from the fields the addon uses:
-- the save format, and per character the Primary (build) and Secondary plans.
-- Anything else, left by older versions or damaged, is dropped.
-- A new saved field has to be added here too, or it is dropped on the next load.
local function NormalizeSaved()
	local old = JustTheTreesDB
	local clean = {
		format = SAVE_FORMAT,
		characters = {},
	}
	if type(old) == "table" and type(old.characters) == "table" then
		for key, record in pairs(old.characters) do
			if type(key) == "string" and key ~= "" and type(record) == "table" then
				local build = CleanPlan(record.build)
				local secondary = CleanPlan(record.secondary)
				if build or secondary then
					clean.characters[key] = {
						build = build,
						secondary = secondary,
					}
				end
			end
		end
	end
	JustTheTreesDB = clean
end

local function CharacterKey()
	local name = UnitName("player")
	if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then
		return nil
	end
	local realm = GetRealmName()
	if type(realm) ~= "string" or realm == "" then
		return name
	end
	return name .. "-" .. realm
end

local function SlotText(slot)
	if slot == 2 then
		return "Secondary"
	end
	return "Primary"
end

-- Each character has two saved plans, Primary (1) and Secondary (2). They are
-- the calculator's own slots, not the character's spec slots.
local function SaveSlot(slot, create)
	local key = CharacterKey()
	if not key then
		return nil
	end
	local record = JustTheTreesDB.characters[key]
	if type(record) ~= "table" then
		if not create then
			return nil
		end
		record = {}
		JustTheTreesDB.characters[key] = record
	end
	local field = slot == 2 and "secondary" or "build"
	if create and type(record[field]) ~= "table" then
		record[field] = {}
	end
	if type(record[field]) ~= "table" then
		return nil
	end
	return record[field]
end

-- The saved plan's ranks by node, or nil when that slot has never been saved.
local function SavedRanks(slot)
	local saved = SaveSlot(slot, false)
	if not saved or type(saved.nodes) ~= "table" then
		return nil
	end
	local ranks = {}
	for _, node in ipairs(saved.nodes) do
		local clean = CleanNode(node)
		if clean and not ranks[clean.nodeID] then
			ranks[clean.nodeID] = {
				ranks = clean.ranks,
				entryID = clean.entryID,
			}
		end
	end
	return ranks
end

--------------------------------------------------------------------------------
-- Chat
--------------------------------------------------------------------------------

-- Every chat line starts with the addon's name in gold. The addon writes to chat only
-- after a button press or when something changed that the player did not ask for.
local function Say(message)
	print(NORMAL_FONT_COLOR:WrapTextInColorCode(ADDON_TITLE) .. ": " .. message)
end

-- Something the player asked for did not happen, or something stopped. The line is red
-- after the name, then says what the player can do, if anything.
local function SayFailed(message, advice)
	Say(RED_FONT_COLOR:WrapTextInColorCode(message) .. (advice and " " .. advice or ""))
end

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

-- The plan runs inside the game's own code: its talent window, menu button, menus and
-- events. An error there must not break the code that called it, nor repeat on every
-- redraw. The first error goes to the game's error handler and is said once in chat;
-- the addon then puts back what it changed (PutBack: its tab hidden, the character's
-- own talents on screen) and stays off until /reload.
local stopped = false
local PutBack -- defined with the tab, below

-- Turning off runs in the game's code too, so nothing in it may throw.
local function TurnOff(problem, advice)
	if stopped then
		return
	end
	stopped = true
	xpcall(SayFailed, CallErrorHandler, problem, advice)
	xpcall(PutBack, CallErrorHandler)
end

local function Passed(ok, ...)
	if ok then
		return ...
	end
	TurnOff("The talent plan stopped working and is off.", "Type /reload to turn it back on.")
end

-- Runs func and returns what it returns, while the addon is on.
local function Guarded(func, ...)
	if not stopped then
		return Passed(xpcall(func, CallErrorHandler, ...))
	end
end

-- func as a hook, script or callback the game calls: each call runs through Guarded.
local function Guard(func)
	return function(...)
		return Guarded(func, ...)
	end
end

--------------------------------------------------------------------------------
-- The plan
--------------------------------------------------------------------------------

-- The plan on screen: ranks (1 or more) and chosen entry (0 for none) by node, for the
-- slot in ns.loadedSlot. ns.slot is the slot picked in the menu, and ns.planBySlot
-- keeps each slot's unsaved edits for the session.
ns.ranks = {}
ns.slot = nil
ns.loadedSlot = nil
ns.planBySlot = {}
-- The tree's fixed layout by node (RememberFrame), and the arrows into each node.
ns.structure = {}
ns.incoming = {}

local function TotalSpent()
	local spent = 0
	for _, stored in pairs(ns.ranks) do
		spent = spent + stored.ranks
	end
	return spent
end

local function Unspent()
	return PLAN_BUDGET - TotalSpent()
end

local function ClearRankTable()
	for nodeID in pairs(ns.ranks) do
		ns.ranks[nodeID] = nil
	end
end

local function LoadSavedRanks(slot)
	ClearRankTable()
	for nodeID, stored in pairs(SavedRanks(slot) or {}) do
		ns.ranks[nodeID] = stored
	end
end

local function SnapshotRanks()
	local copy = {}
	for nodeID, stored in pairs(ns.ranks) do
		copy[nodeID] = {
			ranks = stored.ranks,
			entryID = stored.entryID,
		}
	end
	return copy
end

local function ApplySnapshot(copy)
	ClearRankTable()
	for nodeID, stored in pairs(copy) do
		ns.ranks[nodeID] = {
			ranks = stored.ranks,
			entryID = stored.entryID,
		}
	end
end

local function RememberCurrentPlan()
	if ns.loadedSlot then
		ns.planBySlot[ns.loadedSlot] = SnapshotRanks()
	end
end

-- Puts the selected slot's plan on the calculator: the unsaved edits from this
-- session if that slot has any, otherwise its saved plan. Primary is the first slot
-- shown. The character's name can be missing right after login; once it is known,
-- the plans start over for it.
local function EnsureWorkingCopy()
	local key = CharacterKey()
	if key and ns.characterKey ~= key then
		ns.characterKey = key
		ns.loadedSlot = nil
		ns.slot = nil
		ns.planBySlot = {}
		ClearRankTable()
		ns.structure = {}
		ns.incoming = {}
	end
	local slot = ns.slot or 1
	ns.slot = slot
	if ns.loadedSlot == slot then
		return
	end
	RememberCurrentPlan()
	local kept = ns.planBySlot[slot]
	if kept then
		ApplySnapshot(kept)
	else
		LoadSavedRanks(slot)
	end
	ns.loadedSlot = slot
end

local function PlanMatchesSaved()
	local savedRanks = SavedRanks(ns.slot or 1) or {}
	for nodeID, stored in pairs(ns.ranks) do
		local saved = savedRanks[nodeID]
		if not saved or saved.ranks ~= stored.ranks or saved.entryID ~= stored.entryID then
			return false
		end
		savedRanks[nodeID] = nil
	end
	return next(savedRanks) == nil
end

local function HasSavedPlan()
	return SavedRanks(ns.slot or 1) ~= nil
end

--------------------------------------------------------------------------------
-- The tree's layout
--------------------------------------------------------------------------------

local function CopyList(source)
	local copy = {}
	if source then
		for index, value in ipairs(source) do
			copy[index] = value
		end
	end
	return copy
end

-- Only straight edges are drawn, as arrows.
local function ShowsArrow(visualStyle)
	return visualStyle == nil or visualStyle == Enum.TraitEdgeVisualStyle.Straight
end

-- The tree headers' groups, one per tree.
local function HeaderGroupIDs(frame)
	local headers = {}
	local treeID = frame:GetTalentTreeID()
	if treeID then
		for _, info in ipairs(C_Traits.GetGroupDisplayInfoByTreeID(treeID)) do
			headers[#headers + 1] = info.groupID
		end
	end
	return headers
end

-- One header is one tree. A currency owned by exactly one header marks that tree,
-- and every other group that lists the same currency belongs to it. A currency
-- or a group that shows up on two headers is shared, and it does not join those trees.
-- Primary and Secondary are two rank tables. Points in one are not in the other.
local function BuildComponents(frame, configID)
	local parent = {}
	local function find(id)
		local root = parent[id]
		if not root then
			parent[id] = id
			return id
		end
		if root ~= id then
			root = find(root)
			parent[id] = root
		end
		return parent[id]
	end
	local function unite(left, right)
		if not left or not right or not ns.structure[left] or not ns.structure[right] then
			return
		end
		local leftRoot = find(left)
		local rightRoot = find(right)
		if leftRoot ~= rightRoot then
			parent[rightRoot] = leftRoot
		end
	end
	ns.currencyGroup = {}
	ns.groupTree = {}
	ns.treeOf = {}
	local currencyOwners = {}
	local headerList = HeaderGroupIDs(frame)
	local headerSet = {}
	for _, groupID in ipairs(headerList) do
		headerSet[groupID] = true
	end
	local groupIDs = {}
	local seenGroup = {}
	for _, groupID in ipairs(headerList) do
		seenGroup[groupID] = true
		groupIDs[#groupIDs + 1] = groupID
	end
	for _, structure in pairs(ns.structure) do
		for _, groupID in ipairs(structure.groupIDs) do
			if not seenGroup[groupID] then
				seenGroup[groupID] = true
				groupIDs[#groupIDs + 1] = groupID
			end
		end
	end
	-- The talents' own groups are not only the headers the talent window asks about,
	-- so a group the client does not take only leaves its currency unread.
	if configID and #groupIDs > 0 then
		local ok, infos = pcall(C_Traits.GetGroupCurrencyInfo, configID, groupIDs)
		if ok and type(infos) == "table" then
			for _, info in ipairs(infos) do
				local ownerID = info.traitNodeGroupID
				for _, currency in ipairs(info.currencyInfos or {}) do
					local currencyID = currency.traitCurrencyID
					if currencyID and ownerID then
						local owners = currencyOwners[currencyID]
						if not owners then
							owners = {}
							currencyOwners[currencyID] = owners
						end
						owners[ownerID] = true
					end
				end
			end
		end
	end
	local function TreeOfCurrency(owners)
		local headerID = nil
		local headerCount = 0
		local onlyID = nil
		local ownerCount = 0
		for groupID in pairs(owners) do
			ownerCount = ownerCount + 1
			onlyID = groupID
			if headerSet[groupID] then
				headerCount = headerCount + 1
				headerID = groupID
			end
		end
		if headerCount == 1 then
			return headerID
		end
		if headerCount == 0 and ownerCount == 1 then
			return onlyID
		end
		return nil
	end
	for currencyID, owners in pairs(currencyOwners) do
		local treeID = TreeOfCurrency(owners)
		if treeID then
			ns.currencyGroup[currencyID] = treeID
			for groupID in pairs(owners) do
				local mapped = ns.groupTree[groupID]
				if mapped == nil then
					ns.groupTree[groupID] = treeID
				elseif mapped ~= treeID then
					ns.groupTree[groupID] = false
				end
			end
		end
	end
	ns.currencyGroupsOf = {}
	if configID then
		for nodeID in pairs(ns.structure) do
			local ok, costs = pcall(C_Traits.GetNodeCost, configID, nodeID)
			local groups = {}
			if ok and type(costs) == "table" then
				for _, cost in ipairs(costs) do
					local groupID = ns.currencyGroup[cost.ID]
					if groupID then
						groups[#groups + 1] = groupID
					end
				end
			end
			ns.currencyGroupsOf[nodeID] = groups
		end
	end
	local function AddHint(hints, treeID)
		if treeID and treeID ~= false then
			hints[treeID] = true
		end
	end
	for nodeID, structure in pairs(ns.structure) do
		-- The talent frame's own rule: a talent is in a header when its group list contains that header.
		local headerID = nil
		local headerCount = 0
		for _, groupID in ipairs(structure.groupIDs) do
			if headerSet[groupID] then
				headerCount = headerCount + 1
				headerID = groupID
			end
		end
		if headerCount == 1 then
			ns.treeOf[nodeID] = headerID
		else
			local hints = {}
			for _, groupID in ipairs(structure.groupIDs) do
				AddHint(hints, ns.groupTree[groupID])
			end
			for _, groupID in ipairs(ns.currencyGroupsOf[nodeID] or {}) do
				AddHint(hints, groupID)
			end
			local chosen = nil
			local count = 0
			for treeID in pairs(hints) do
				count = count + 1
				chosen = treeID
			end
			if count == 1 then
				ns.treeOf[nodeID] = chosen
			end
		end
	end
	local groupHints = {}
	local subHints = {}
	local function Note(map, key, treeID)
		local hints = map[key]
		if not hints then
			hints = {}
			map[key] = hints
		end
		hints[treeID] = true
	end
	for nodeID, structure in pairs(ns.structure) do
		local treeID = ns.treeOf[nodeID]
		if treeID then
			for _, groupID in ipairs(structure.groupIDs) do
				Note(groupHints, groupID, treeID)
			end
			if structure.subTreeID then
				Note(subHints, structure.subTreeID, treeID)
			end
		end
	end
	local function Spans(map, key)
		local hints = map[key]
		if not hints then
			return false
		end
		local count = 0
		for _ in pairs(hints) do
			count = count + 1
			if count > 1 then
				return true
			end
		end
		return false
	end
	local firstInGroup = {}
	local function claim(key, nodeID)
		if not key then
			return
		end
		local first = firstInGroup[key]
		if first then
			unite(first, nodeID)
		else
			firstInGroup[key] = nodeID
		end
	end
	for nodeID, structure in pairs(ns.structure) do
		find(nodeID)
		local treeID = ns.treeOf[nodeID]
		if treeID then
			claim(treeID, nodeID)
		else
			for _, groupID in ipairs(structure.groupIDs) do
				if not Spans(groupHints, groupID) then
					local mapped = ns.groupTree[groupID]
					if mapped then
						claim(mapped, nodeID)
					else
						claim(groupID, nodeID)
					end
				end
			end
			if structure.subTreeID and not Spans(subHints, structure.subTreeID) then
				claim("sub:" .. structure.subTreeID, nodeID)
			end
			for _, groupID in ipairs(ns.currencyGroupsOf[nodeID] or {}) do
				if not Spans(groupHints, groupID) then
					claim(groupID, nodeID)
				end
			end
		end
	end
	ns.component = {}
	for nodeID in pairs(ns.structure) do
		ns.component[nodeID] = find(nodeID)
	end
end

local function SameComponent(leftID, rightID)
	local component = ns.component
	return component and leftID and rightID and component[leftID] ~= nil and component[leftID] == component[rightID]
end

-- A header is one tree. Points match only when both talents resolve to that same header.
-- A shared group cannot pull in a talent from another header. Primary and Secondary only choose the plan.
local function SameTree(leftID, rightID)
	local trees = ns.treeOf
	local leftTree = trees and trees[leftID]
	local rightTree = trees and trees[rightID]
	if leftTree or rightTree then
		return leftTree ~= nil and leftTree == rightTree
	end
	return SameComponent(leftID, rightID)
end

-- posY grows downward on screen (TalentButtonUtil.TranslateNodePositionsToAnchorPositions).
local function IsAbove(upper, lower)
	if not upper or not lower or upper.posY == nil or lower.posY == nil then
		return false
	end
	return upper.posY < lower.posY - ROW_TOLERANCE
end

-- A row opens from points on earlier rows of the same tree only. Points on that
-- row, and points deeper in the tree, stay behind the gate and cannot hold it open.
local function SpentAbove(nodeID)
	local target = ns.structure[nodeID]
	if not target or target.posY == nil then
		return 0
	end
	local spent = 0
	for otherID, stored in pairs(ns.ranks) do
		if otherID ~= nodeID and SameTree(nodeID, otherID) and IsAbove(ns.structure[otherID], target) then
			spent = spent + stored.ranks
		end
	end
	return spent
end

local function RememberNode(info)
	if not info or not info.ID or info.ID == 0 then
		return
	end
	local previous = ns.structure[info.ID]
	local edges = {}
	for _, edge in ipairs(info.visibleEdges or {}) do
		edges[#edges + 1] = {
			target = edge.targetNode,
			edgeType = edge.type,
			visualStyle = edge.visualStyle,
		}
	end
	local maxRanks = info.maxRanks or 0
	local groupIDs = CopyList(info.groupIDs)
	local conditionIDs = CopyList(info.conditionIDs)
	local entryIDs = CopyList(info.entryIDs)
	local stub = maxRanks <= 0 and not entryIDs[1]
	local posX = info.posX or 0
	local posY = info.posY or 0
	-- A preview config can report an empty node. Keep the ranks and arrows already read off the live tree.
	if previous then
		if maxRanks <= 0 then
			maxRanks = previous.maxRanks
		end
		if not groupIDs[1] then
			groupIDs = previous.groupIDs
		end
		if not conditionIDs[1] then
			conditionIDs = previous.conditionIDs
		end
		if not entryIDs[1] then
			entryIDs = previous.entryIDs
		end
		if not edges[1] then
			edges = previous.edges
		end
		if stub then
			posX = previous.posX or posX
			posY = previous.posY or posY
		end
	end
	ns.structure[info.ID] = {
		maxRanks = maxRanks,
		groupIDs = groupIDs,
		conditionIDs = conditionIDs,
		entryIDs = entryIDs,
		nodeType = info.type or (previous and previous.nodeType),
		subTreeID = info.subTreeID or (previous and previous.subTreeID),
		edges = edges,
		posX = posX,
		posY = posY,
	}
end

local function PreferList(first, second)
	if type(first) == "table" and first[1] ~= nil then
		return first
	end
	if type(second) == "table" and second[1] ~= nil then
		return second
	end
	return first or second
end

-- The config query and the talent button are the same node. Keep whichever one actually has the links and the row total.
local function CombineNode(info, extra)
	if not extra then
		return info
	end
	if not info then
		return extra
	end
	local combined = {}
	for key, value in pairs(extra) do
		combined[key] = value
	end
	for key, value in pairs(info) do
		combined[key] = value
	end
	combined.ID = info.ID or extra.ID
	combined.visibleEdges = PreferList(info.visibleEdges, extra.visibleEdges)
	combined.groupIDs = PreferList(info.groupIDs, extra.groupIDs)
	combined.conditionIDs = PreferList(info.conditionIDs, extra.conditionIDs)
	combined.entryIDs = PreferList(info.entryIDs, extra.entryIDs)
	if not info.subTreeID then
		combined.subTreeID = extra.subTreeID
	end
	if (not info.maxRanks or info.maxRanks <= 0) and extra.maxRanks and extra.maxRanks > 0 then
		combined.maxRanks = extra.maxRanks
	end
	if info.posX == nil then
		combined.posX = extra.posX
	end
	if info.posY == nil then
		combined.posY = extra.posY
	end
	if not info.type then
		combined.type = extra.type
	end
	return combined
end

local function ButtonNode(frame, nodeID)
	local button = frame:GetTalentButtonByNodeID(nodeID)
	return button and button:GetNodeInfo()
end

local function RebuildIncoming()
	ns.incoming = {}
	for sourceID, structure in pairs(ns.structure) do
		for _, edge in ipairs(structure.edges) do
			local list = ns.incoming[edge.target]
			if not list then
				list = {}
				ns.incoming[edge.target] = list
			end
			list[#list + 1] = {
				source = sourceID,
				edgeType = edge.edgeType,
				visualStyle = edge.visualStyle,
			}
		end
	end
end

-- Primary and Secondary are the calculator's own slots. Both read the tree on
-- screen. Before the frame has a config, the active spec's config has the same tree.
local function PlanConfigID(frame)
	return frame:GetConfigID() or C_SpecializationInfo.GetCombatConfigIDForSpecGroup(C_SpecializationInfo.GetActiveSpecGroup() or 1)
end

local function PlanTreeID(frame, configID)
	if configID then
		local info = C_Traits.GetConfigInfo(configID)
		if info and info.treeIDs and info.treeIDs[1] then
			return info.treeIDs[1]
		end
	end
	return frame:GetTalentTreeID()
end

-- The tree's gate list is fixed layout data: where each gate goes and its condition.
-- The frame's own gate widgets are not read: the game shows those only while the
-- character has not met them.
local function TreeGates(frame, configID)
	local treeID = PlanTreeID(frame, configID)
	if configID and treeID then
		local info = C_Traits.GetTreeInfo(configID, treeID)
		if info and info.gates and info.gates[1] then
			return info.gates
		end
	end
	if frame:GetConfigID() == configID then
		local cached = frame:GetTreeInfo()
		if cached and cached.gates and cached.gates[1] then
			return cached.gates
		end
	end
	return nil
end

-- Row 1 of a tree is open. Every row after it needs POINTS_PER_ROW more points
-- spent in the rows above it, in that same tree. Only the tree's layout is read,
-- never the character's talents.
local function ApplyRowRequirements(frame)
	local configID = PlanConfigID(frame)
	BuildComponents(frame, configID)

	-- One node stands for each tree. Each tree lists its row positions from the top.
	local reps = {}
	local function RepOf(nodeID)
		for _, rep in ipairs(reps) do
			if SameTree(rep, nodeID) then
				return rep
			end
		end
		reps[#reps + 1] = nodeID
		return nodeID
	end
	local rowsOf = {}
	for nodeID, structure in pairs(ns.structure) do
		structure.requiredSpent = nil
		structure.gateConditionID = nil
		if structure.maxRanks > 0 then
			local rep = RepOf(nodeID)
			local rows = rowsOf[rep]
			if not rows then
				rows = {}
				rowsOf[rep] = rows
			end
			local known = false
			for _, rowY in ipairs(rows) do
				if math.abs(rowY - structure.posY) <= ROW_TOLERANCE then
					known = true
					break
				end
			end
			if not known then
				rows[#rows + 1] = structure.posY
			end
		end
	end
	for _, rows in pairs(rowsOf) do
		table.sort(rows)
	end
	for nodeID, structure in pairs(ns.structure) do
		if structure.maxRanks > 0 then
			for index, rowY in ipairs(rowsOf[RepOf(nodeID)]) do
				if math.abs(rowY - structure.posY) <= ROW_TOLERANCE then
					if index > 1 then
						structure.requiredSpent = (index - 1) * POINTS_PER_ROW
					end
					break
				end
			end
		end
	end

	-- The tooltip words the row requirement like the nearest tree gate on or above that row.
	local gates = TreeGates(frame, configID)
	for nodeID, structure in pairs(ns.structure) do
		if structure.requiredSpent then
			local nearestY
			for _, gate in ipairs(gates or {}) do
				local anchor = ns.structure[gate.topLeftNodeID]
				if anchor and SameTree(gate.topLeftNodeID, nodeID) and not IsAbove(structure, anchor) then
					if not nearestY or anchor.posY > nearestY then
						nearestY = anchor.posY
						structure.gateConditionID = gate.conditionID
					end
				end
			end
		end
	end
end

-- Reads the tree on screen: every node's layout, ranks, arrows and groups. Only fixed
-- data is kept, never the character's points.
local function RememberFrame(frame)
	local configID = PlanConfigID(frame)
	local treeID = PlanTreeID(frame, configID)
	local nodeIDs = treeID and C_Traits.GetTreeNodes(treeID)
	if configID and nodeIDs then
		local saved = ns.structure
		ns.structure = {}
		for _, nodeID in ipairs(nodeIDs) do
			-- The button is the same talent the player is looking at, for either spec.
			local info = CombineNode(C_Traits.GetNodeInfo(configID, nodeID), ButtonNode(frame, nodeID))
			if type(info) == "table" and info.ID and info.ID ~= 0 and info.isVisible ~= false then
				RememberNode(info)
			end
		end
		if next(ns.structure) then
			RebuildIncoming()
			ApplyRowRequirements(frame)
			return
		end
		ns.structure = saved
	end
	for button in frame:EnumerateAllTalentButtons() do
		RememberNode(button:GetNodeInfo())
	end
	RebuildIncoming()
	ApplyRowRequirements(frame)
end

--------------------------------------------------------------------------------
-- The rules
--------------------------------------------------------------------------------

local function SourceRank(nodeID)
	local stored = ns.ranks[nodeID]
	return stored and stored.ranks or 0
end

-- A talent opens its arrows once maxed. A one-rank talent needs its point.
local function SourceMaxed(nodeID)
	local structure = ns.structure[nodeID]
	local ranks = SourceRank(nodeID)
	if not structure or structure.maxRanks <= 1 then
		return ranks > 0
	end
	return ranks >= structure.maxRanks
end

local function EdgesAllow(nodeID)
	local incoming = ns.incoming[nodeID]
	if not incoming then
		return true
	end
	local requiredMet = true
	local sawSufficient = false
	local sufficientMet = false
	for _, edge in ipairs(incoming) do
		if edge.edgeType == EXCLUSIVE_EDGE then
			if SourceRank(edge.source) > 0 then
				return false
			end
		elseif edge.edgeType == REQUIRED_EDGE then
			if not SourceMaxed(edge.source) then
				requiredMet = false
			end
		elseif edge.edgeType == SUFFICIENT_EDGE then
			sawSufficient = true
			if SourceMaxed(edge.source) then
				sufficientMet = true
			end
		end
	end
	if not requiredMet then
		return false
	end
	if sawSufficient and not sufficientMet then
		return false
	end
	return true
end

-- Forever's rule for the talent tooltip (ShouldAddEdgeRequirementsToTooltip): a talent
-- with an arrow from a talent that is not maxed yet needs all preceding talents.
local function MissingPrecedingTalent(nodeID)
	for _, edge in ipairs(ns.incoming[nodeID] or {}) do
		local rankLink = edge.edgeType == REQUIRED_EDGE or edge.edgeType == SUFFICIENT_EDGE
		if rankLink and ShowsArrow(edge.visualStyle) and not SourceMaxed(edge.source) then
			return true
		end
	end
	return false
end

local function GateOpen(nodeID)
	local structure = ns.structure[nodeID]
	local required = structure and structure.requiredSpent or 0
	return required <= 0 or SpentAbove(nodeID) >= required
end

-- The points the plan still needs above a talent's row before that row opens, or nil
-- on a tree's first row.
local function PointsLeft(nodeID)
	local structure = ns.structure[nodeID]
	local required = structure and structure.requiredSpent
	if not required or required <= 0 then
		return nil
	end
	return math.max(0, required - SpentAbove(nodeID))
end

local function CanAddRank(nodeID)
	local structure = ns.structure[nodeID]
	if not structure or structure.maxRanks <= 0 or SourceRank(nodeID) >= structure.maxRanks or Unspent() < 1 then
		return false
	end
	if not GateOpen(nodeID) or not EdgesAllow(nodeID) then
		return false
	end
	-- An exclusive arrow from this talent shuts out a talent that already has points.
	for _, edge in ipairs(structure.edges) do
		if edge.edgeType == EXCLUSIVE_EDGE and SourceRank(edge.target) > 0 then
			return false
		end
	end
	return true
end

local function RankHolds(nodeID)
	return ns.ranks[nodeID] ~= nil and ns.structure[nodeID] ~= nil and EdgesAllow(nodeID) and GateOpen(nodeID)
end

-- The loaded slot only. Every talent that would still have points, in all
-- three trees, has to stay legal. The other slot is a different rank table.
local function SelectionStaysLegal(nodeID, ranks)
	local stored = ns.ranks[nodeID]
	if ranks > 0 then
		ns.ranks[nodeID] = { ranks = ranks, entryID = stored and stored.entryID or 0 }
	else
		ns.ranks[nodeID] = nil
	end
	local allowed = true
	for otherID in pairs(ns.ranks) do
		if otherID ~= nodeID and not RankHolds(otherID) then
			allowed = false
			break
		end
	end
	ns.ranks[nodeID] = stored
	return allowed
end

-- A click adds a point when the talent can take one and every other talent stays legal.
local function CanAddPoint(nodeID)
	return CanAddRank(nodeID) and SelectionStaysLegal(nodeID, SourceRank(nodeID) + 1)
end

-- A right click takes a point off unless that leaves a deeper talent short of its
-- row's points or breaks an arrow.
local function CanRemovePoint(nodeID)
	local ranks = SourceRank(nodeID)
	return ranks > 0 and SelectionStaysLegal(nodeID, ranks - 1)
end

local function MarkOutgoing(affected, nodeID)
	affected[nodeID] = true
	local structure = ns.structure[nodeID]
	if not structure then
		return
	end
	for _, edge in ipairs(structure.edges) do
		if edge.target then
			affected[edge.target] = true
		end
	end
end

-- Removes every rank that no longer holds. A removal can break the talents that
-- depend on it, so this repeats until nothing changes. Removed talents and the
-- talents their arrows point to are marked in affected, when given.
local function Prune(affected)
	repeat
		local removed = false
		for nodeID in pairs(ns.ranks) do
			if not RankHolds(nodeID) then
				ns.ranks[nodeID] = nil
				if affected then
					MarkOutgoing(affected, nodeID)
				end
				removed = true
			end
		end
	until not removed
end

local function ListHas(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

-- The talent on the lowest row, the highest node ID breaking a tie.
local function DeepestPlannedNode()
	local deepestID, deepestY
	for nodeID in pairs(ns.ranks) do
		local posY = ns.structure[nodeID].posY
		if not deepestID or posY > deepestY or (posY == deepestY and nodeID > deepestID) then
			deepestID, deepestY = nodeID, posY
		end
	end
	return deepestID
end

-- A plan can come from an older tree: a later patch can lower a talent's max rank
-- or remove a choice. The plan is fitted to the tree on screen: each talent is
-- capped at its max rank, a choice the node no longer has becomes its first one,
-- and points over the budget come off the deepest rows. Prune drops what no longer holds.
-- Returns what changed, one entry per talent, for ReportPlanFit, with every reason
-- the talent lost points, in order: "tree", "max", "budget", and "requirements"
-- when Prune took more than those steps did.
local function FitPlanToTree()
	local before = {}
	local reasons = {}
	local expected = {}
	local newEntries = {}
	local function Note(nodeID, reason)
		local list = reasons[nodeID] or {}
		reasons[nodeID] = list
		if list[#list] ~= reason then
			list[#list + 1] = reason
		end
	end
	for nodeID, stored in pairs(ns.ranks) do
		before[nodeID] = { ranks = stored.ranks, entryID = stored.entryID }
		expected[nodeID] = stored.ranks
		local structure = ns.structure[nodeID]
		if not structure or structure.maxRanks <= 0 then
			Note(nodeID, "tree")
			expected[nodeID] = 0
			ns.ranks[nodeID] = nil
		else
			if stored.ranks > structure.maxRanks then
				stored.ranks = structure.maxRanks
				expected[nodeID] = structure.maxRanks
				Note(nodeID, "max")
			end
			local entryIDs = structure.entryIDs
			if stored.entryID > 0 and entryIDs[1] and not ListHas(entryIDs, stored.entryID) then
				stored.entryID = entryIDs[1]
				newEntries[nodeID] = entryIDs[1]
			end
		end
	end
	Prune()
	while TotalSpent() > PLAN_BUDGET do
		local nodeID = DeepestPlannedNode()
		local stored = ns.ranks[nodeID]
		Note(nodeID, "budget")
		expected[nodeID] = expected[nodeID] - 1
		if stored.ranks > 1 then
			stored.ranks = stored.ranks - 1
		else
			ns.ranks[nodeID] = nil
		end
		Prune()
	end

	local changes = {}
	for nodeID, old in pairs(before) do
		local now = ns.ranks[nodeID]
		local ranks = now and now.ranks or 0
		if ranks < expected[nodeID] then
			Note(nodeID, "requirements")
		end
		if ranks ~= old.ranks or newEntries[nodeID] then
			changes[#changes + 1] = {
				nodeID = nodeID,
				entryID = old.entryID,
				from = old.ranks,
				to = ranks,
				reasons = reasons[nodeID] or {},
				newEntryID = newEntries[nodeID],
			}
		end
	end
	table.sort(changes, function(left, right)
		return left.nodeID < right.nodeID
	end)
	return changes
end

-- The first point is spent at level 10, then one point each level up to 60.
-- Until the first point is spent the label shows "-".
local function LevelRequiredText(spent)
	if spent < 1 then
		return "-"
	end
	return tostring(math.min(MAX_LEVEL, FIRST_TALENT_LEVEL - 1 + spent))
end

--------------------------------------------------------------------------------
-- Talent details
--------------------------------------------------------------------------------

-- TalentUtil.GetTalentName: the definition's override, then the spell name.
-- A talent with neither shows its sub tree's name.
local function TalentDisplayName(definition, subTree)
	local name = definition and TalentUtil.GetTalentName(definition.overrideName, definition.spellID)
	if (type(name) ~= "string" or name == "") and subTree then
		name = subTree.name
	end
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return name
end

-- The talent behind an entry: its name, spell, and what its icon is drawn from.
local function EntryVisual(frame, entryID)
	local configID = frame:GetConfigID()
	local entry = configID and entryID and C_Traits.GetEntryInfo(configID, entryID)
	if not entry then
		return { entryID = entryID }
	end
	-- GetDefinitionInfo takes the definition id only. The config id is not an argument.
	local definition = entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
	local subTree = entry.subTreeID and C_Traits.GetSubTreeInfo(configID, entry.subTreeID)
	return {
		entryID = entryID,
		name = TalentDisplayName(definition, subTree),
		spellID = definition and definition.spellID,
		definition = definition,
		subTree = subTree,
	}
end

local function ApplyIcon(texture, visual)
	local icon, isAtlas = TalentButtonUtil.CalculateIconTextureFromInfo(visual.definition, visual.subTree)
	if isAtlas and icon then
		texture:SetAtlas(icon)
	elseif icon then
		texture:SetTexture(icon)
	end
	-- The icon can be missing until the spell's data has loaded. Try again then.
	if icon or not visual.spellID then
		return
	end
	local spell = Spell:CreateFromSpellID(visual.spellID)
	if spell:IsSpellDataCached() then
		return
	end
	spell:ContinueWithCancelOnSpellLoad(function()
		Guarded(ApplyIcon, texture, visual)
	end)
end

-- A talent named in chat: its spell link, which can be hovered, else its name.
local function TalentText(frame, nodeID, entryID, missing)
	local structure = ns.structure[nodeID]
	local shownID = entryID and entryID > 0 and entryID or (structure and structure.entryIDs[1])
	if not shownID then
		return missing
	end
	local visual = EntryVisual(frame, shownID)
	return visual.spellID and C_Spell.GetSpellLink(visual.spellID) or visual.name or missing
end

-- How many ranks one entry of a tiered talent holds.
local function EntryCap(frame, entryID)
	local configID = frame:GetConfigID()
	local info = configID and C_Traits.GetEntryInfo(configID, entryID)
	return math.max(1, info and info.maxRanks or 1)
end

-- The entries the tooltip describes, picked like the game's tooltip picks them: the
-- current rank's entry and the next rank's. A tiered talent moves through its entries.
local function ResolvePlanEntries(frame, nodeID)
	local structure = ns.structure[nodeID]
	local ranks = math.min(SourceRank(nodeID), structure.maxRanks)
	local entryIDs = structure.entryIDs
	local currentID, currentRank, nextID, nextRank

	if structure.nodeType == Enum.TraitNodeType.Tiered and entryIDs[1] then
		local remaining = ranks
		for _, entryID in ipairs(entryIDs) do
			local cap = EntryCap(frame, entryID)
			if remaining <= 0 then
				if not currentID then
					currentID, currentRank = entryID, 0
				elseif not nextID then
					nextID, nextRank = entryID, 1
				end
				break
			end
			local take = math.min(remaining, cap)
			currentID, currentRank = entryID, take
			remaining = remaining - take
			if remaining == 0 and take < cap then
				nextID, nextRank = entryID, take + 1
				break
			end
		end
	else
		local stored = ns.ranks[nodeID]
		currentID = stored and stored.entryID > 0 and stored.entryID or entryIDs[1]
		currentRank = ranks
		if currentID and structure.maxRanks > ranks then
			nextID, nextRank = currentID, ranks + 1
		end
	end

	return ranks, currentID, currentRank, nextID, nextRank
end

-- The condition behind a talent's row requirement: the nearest tree gate on or above
-- its row, then the talent's own conditions. Read from C_Traits directly, so the
-- talent window's own cache is left to the game.
local function GateCondInfo(frame, nodeID)
	local configID = frame:GetConfigID()
	local structure = ns.structure[nodeID]
	if not configID or not structure then
		return nil
	end
	local ids = { structure.gateConditionID }
	for _, condID in ipairs(structure.conditionIDs) do
		ids[#ids + 1] = condID
	end
	for _, condID in ipairs(ids) do
		local info = C_Traits.GetConditionInfo(configID, condID)
		if info and type(info.tooltipFormat) == "string" and string.find(info.tooltipFormat, "%", 1, true) then
			return info
		end
	end
	return nil
end

-- The row requirement as the game words it for this talent: the condition's sentence
-- with the points the plan still needs and the tree's name (C_Traits.GetConditionInfo
-- fills it the same way), or the game's gate sentence.
local function GateText(frame, nodeID)
	local left = PointsLeft(nodeID)
	if not left or left <= 0 then
		return nil
	end
	local condInfo = GateCondInfo(frame, nodeID)
	if condInfo then
		-- The sentence is client data, so one that does not take these values falls back.
		local treeName = frame:GetTraitTreeName(frame:GetTalentTreeID(), ns.structure[nodeID].groupIDs) or ""
		local ok, text = pcall(string.format, condInfo.tooltipFormat, left, treeName)
		if ok then
			return C_StringUtil.StripHyperlinks(text)
		end
	end
	return TALENT_FRAME_GATE_TOOLTIP_FORMAT:format(left)
end

--------------------------------------------------------------------------------
-- Tooltips
--------------------------------------------------------------------------------

-- The talent's tooltip, built like the game's (TalentDisplayMixin:SetTooltipInternal with
-- TalentButtonSpendMixin): the talent tooltip's backdrop, name, rank, the rank's text,
-- the next rank, what a click does, then what still holds the talent back.
local function ShowNodeTooltip(button)
	local nodeButton = button.planNode or button
	local frame = nodeButton.calculatorFrame
	local nodeID = nodeButton.calculatorNodeID
	local structure = ns.structure[nodeID]
	if not structure then
		return
	end
	local ranks, currentID, currentRank, nextID, nextRank = ResolvePlanEntries(frame, nodeID)
	-- A choice of a choice talent describes its own entry.
	local stored = ns.ranks[nodeID]
	local entryID = button.entryID
	local chosen = entryID ~= nil and stored ~= nil and stored.entryID == entryID
	if entryID then
		currentID = entryID
		currentRank = chosen and ranks or 0
	end

	local tooltip = GameTooltip
	tooltip:SetOwner(button, "ANCHOR_RIGHT", 0, 0)
	SharedTooltip_SetBackdropStyle(tooltip, GAME_TOOLTIP_BACKDROP_STYLE_CLASS_TALENT)
	local visual = button.entryVisual
	if visual and visual.name then
		GameTooltip_SetTitle(tooltip, visual.name)
	end
	local rankShown = HIGHLIGHT_FONT_COLOR:WrapTextInColorCode(tostring(ranks))
	GameTooltip_AddHighlightLine(tooltip, TALENT_BUTTON_TOOLTIP_RANK_FORMAT:format(rankShown, structure.maxRanks))
	-- AppendInfo is how the talent window fills in a rank's text once that data has loaded.
	if currentID then
		GameTooltip_AddBlankLineToTooltip(tooltip)
		tooltip:AppendInfo("GetTraitEntry", currentID, currentRank)
	end
	if nextID and ranks > 0 then
		GameTooltip_AddBlankLineToTooltip(tooltip)
		GameTooltip_AddHighlightLine(tooltip, TALENT_BUTTON_TOOLTIP_NEXT_RANK)
		tooltip:AppendInfo("GetTraitEntry", nextID, nextRank)
	end

	local canAdd, canRemove
	if entryID and stored then
		-- On a choice talent with its point, the taken choice can give the point back
		-- and any other choice can take it over.
		canAdd = not chosen
		canRemove = chosen and CanRemovePoint(nodeID)
	else
		canAdd = CanAddRank(nodeID)
		canRemove = CanRemovePoint(nodeID)
	end
	if canAdd or canRemove then
		GameTooltip_AddBlankLineToTooltip(tooltip)
	end
	if canAdd then
		GameTooltip_AddInstructionLine(tooltip, TALENT_BUTTON_TOOLTIP_PURCHASE_INSTRUCTIONS)
	elseif canRemove then
		GameTooltip_AddDisabledLine(tooltip, TALENT_BUTTON_TOOLTIP_REFUND_INSTRUCTIONS)
	end

	local gateText = GateText(frame, nodeID)
	if gateText then
		GameTooltip_AddBlankLineToTooltip(tooltip)
		GameTooltip_AddErrorLine(tooltip, gateText)
	end
	if MissingPrecedingTalent(nodeID) then
		GameTooltip_AddBlankLineToTooltip(tooltip)
		GameTooltip_AddErrorLine(tooltip, GENERIC_TRAIT_FRAME_EDGE_REQUIREMENTS_BUTTON_TOOLTIP)
	end
	tooltip:Show()
end

-- TalentFrameGateMixin:OnEnter, with the points this plan still needs.
local function ShowGateTooltip(gate)
	GameTooltip:SetOwner(gate, "ANCHOR_LEFT", 4, -4)
	GameTooltip_AddErrorLine(GameTooltip, TALENT_FRAME_GATE_TOOLTIP_FORMAT:format(gate.pointsNeeded))
	GameTooltip:Show()
end

-- After a click, the hovered talent's tooltip is built again for the new plan.
local function RefreshOpenTooltip()
	if not GameTooltip:IsShown() then
		return
	end
	local owner = GameTooltip:GetOwner()
	if owner and (owner.calculatorNodeID or owner.planNode) then
		ShowNodeTooltip(owner)
	end
end

--------------------------------------------------------------------------------
-- The character's tree under the plan
--------------------------------------------------------------------------------

-- Primary and Secondary use this same frame. Calculator behavior runs only while the
-- plan is on screen.
local function ShowingCalculator(frame)
	return frame.calculatorMode == true
end

-- The game's tree and controls stay as the game drew them, only out of sight under the
-- plan: see-through, with the plan's board and shields taking the mouse. Alpha and mouse
-- changes run none of the game's code, so its tree and controls carry on untainted.
-- Each control gets a shield just above it and its own buttons; the plan's controls sit
-- above the shields (PlanButton). The locked-spec overlay spans the whole window, so it gets
-- no shield: it only stops taking the mouse.
local GAME_CONTROLS = { "ApplyButton", "UndoButton", "ResetButton", "ActiveSpec" }
local SHIELD_LEVEL = 3

local function Shield(frame, region)
	local shield = CreateFrame("Frame", nil, frame)
	shield:SetAllPoints(region)
	shield:SetFrameLevel(region:GetFrameLevel() + SHIELD_LEVEL)
	shield:EnableMouse(true)
	shield:Hide()
	return shield
end

-- The game's tree frame spans the whole window but its bottom row, tabs and search box
-- included. Only its talents' area, from just below the tabs (which reach 4 into the
-- border) down, is shielded, just under the plan's board, so the game's see-through
-- talents can't be hovered or clicked. The game lays its talents out by row, the top row
-- highest: up to 502 above the tree's frame (ClassTalentsFrameMixin:GetFrameLevelForButton,
-- TotalFrameLevelSpread 500, plus TalentButtonBaseMixin's frameLevelOffset 2). Its pop-ups sit
-- at 2000.
local TREE_LEVEL = 600

local function TreeShield(frame)
	local shield = CreateFrame("Frame", nil, frame)
	shield:SetPoint("TOPLEFT", frame.BackgroundBorder, "TOPLEFT", 0, -4)
	shield:SetPoint("BOTTOMRIGHT", frame.ButtonsParent, "BOTTOMRIGHT")
	shield:SetFrameLevel(frame.ButtonsParent:GetFrameLevel() + TREE_LEVEL - 10)
	shield:EnableMouse(true)
	shield:Hide()
	return shield
end

local function CoverClientTree(frame, covered)
	frame.ButtonsParent:SetAlpha(covered and 0 or 1)
	frame.calculatorTreeShield = frame.calculatorTreeShield or TreeShield(frame)
	frame.calculatorTreeShield:SetShown(covered)
	frame.calculatorShields = frame.calculatorShields or {}
	for _, key in ipairs(GAME_CONTROLS) do
		local control = frame[key]
		frame.calculatorShields[key] = frame.calculatorShields[key] or Shield(frame, control)
		frame.calculatorShields[key]:SetShown(covered)
		control:SetAlpha(covered and 0 or 1)
	end
	-- The locked-spec overlay takes the mouse above everything (DisabledOverlay, enableMouse).
	frame.DisabledOverlay:SetAlpha(covered and 0 or 1)
	frame.DisabledOverlay:EnableMouse(not covered)
end

--------------------------------------------------------------------------------
-- The plan's buttons
--------------------------------------------------------------------------------

local NodeClick

-- The art set of the talent button a plan button stands for. Without a live button,
-- a choice talent gets the choice art and any other talent the square art.
local function ArtSet(frame, nodeID)
	local live = frame:GetTalentButtonByNodeID(nodeID)
	if live and live.artSet then
		return live.artSet
	end
	local sets = TalentButtonArtMixin.ArtSet
	return ns.structure[nodeID].nodeType == Enum.TraitNodeType.Selection and sets.Choice or sets.Square
end

-- The talent button's own shape for arrows (GetEdgeDiameterOffset), so they stop
-- just outside its border.
local function EdgeShape(art, live)
	if live and live.GetEdgeDiameterOffset then
		return live.GetEdgeDiameterOffset
	end
	local mixin = TalentButtonArtMixin
	local sets = mixin.ArtSet
	if art == sets.Square or art == sets.CapstoneSquare or art == sets.LegacySquare or art == sets.LegionSquare or art == sets.LargeSquare then
		return mixin.GetSquareEdgeDiameterOffset
	elseif art == sets.Choice or art == sets.LegionChoice then
		return mixin.GetChoiceEdgeDiameterOffset
	end
	return mixin.GetCircleEdgeDiameterOffset
end

-- Gives a plan button the talent button's art: the art set the game's state drawing
-- reads, the shadow, rank font and glow it sets up from it (TalentButtonArtMixin:OnLoad,
-- ClassTalentButtonBaseMixin:OnLoad), and the live button's icon size and number spot.
local function SetButtonArt(button, art, live)
	button.artSet = art
	if art.shadow then
		button.Shadow:SetAtlas(art.shadow, TextureKitConstants.UseAtlasSize)
		button.Shadow:Show()
	else
		button.Shadow:Hide()
	end
	button.GetEdgeDiameterOffset = EdgeShape(art, live)
	local icon = live and live.Icon
	local width, height = 36, 36
	if icon and icon:GetWidth() > 0 and icon:GetHeight() > 0 then
		width, height = icon:GetSize()
	end
	button.Icon:SetSize(width, height)
	button.DisabledOverlay:SetSize(width, height)

	local text = button.SpendText
	if text then
		text:SetFontObject(art.spendFont)
		-- Where TalentButtonArtTemplate puts it, unless the live button moved it.
		local point, relativePoint, x, y = "BOTTOM", "BOTTOM", 11, 4
		local source = live and live.SpendText
		if source then
			local livePoint, _, liveRelativePoint, liveX, liveY = source:GetPoint(1)
			if livePoint then
				point, relativePoint, x, y = livePoint, liveRelativePoint, liveX, liveY
			end
		end
		text:ClearAllPoints()
		text:SetPoint(point, button, relativePoint, x, y)
	end

	local glow = button.SelectableGlow
	if glow then
		glow:SetAtlas(art.glow, TextureKitConstants.IgnoreAtlasSize)
		-- Capstones pulse brighter (SelectableGlowMaxAlpha in ClassTalentButtonTemplates.xml).
		local sets = TalentButtonArtMixin.ArtSet
		local alpha = (art == sets.CapstoneCircle or art == sets.CapstoneSquare) and 0.7 or 0.15
		glow.FadeIn:SetToAlpha(alpha)
		glow.FadeOut:SetFromAlpha(alpha)
	end
end

-- A plan button has the layers of TalentButtonArtTemplate under the same names, so
-- the game's own TalentButtonArtMixin:ApplyVisualState draws its state.
local function CreatePlanButton(frame, board)
	local button = CreateFrame("Button", nil, board)
	button:SetSize(frame:GetButtonSize(), frame:GetButtonSize())
	button:RegisterForClicks("LeftButtonDown", "RightButtonDown")
	button:SetScript("OnClick", Guard(NodeClick))
	button:SetScript("OnEnter", Guard(ShowNodeTooltip))
	button:SetScript("OnLeave", GameTooltip_Hide)
	button.Shadow = button:CreateTexture(nil, "BACKGROUND")
	button.Shadow:SetPoint("CENTER")
	button.Icon = button:CreateTexture(nil, "BORDER")
	button.Icon:SetPoint("CENTER")
	button.DisabledOverlay = button:CreateTexture(nil, "BORDER", nil, 1)
	button.DisabledOverlay:SetPoint("CENTER")
	button.DisabledOverlay:SetColorTexture(0, 0, 0, 1)
	button.DisabledOverlay:Hide()
	button.StateBorder = button:CreateTexture(nil, "ARTWORK")
	button.StateBorder:SetPoint("CENTER")
	-- ApplyVisualState calls these on the button. In Forever, UpdateStateBorder is the
	-- client's own version, which draws a talent with points green until it is maxed.
	button.UpdateStateBorder = TalentButtonArtMixin.UpdateStateBorder
	button.SetBorderAtlas = TalentButtonArtMixin.SetBorderAtlas
	-- The color blind mark on a talent that can take a point.
	button.SelectableIcon = button:CreateTexture(nil, "OVERLAY", nil, 2)
	button.SelectableIcon:SetAtlas("talents-icon-learnableplus", TextureKitConstants.UseAtlasSize)
	button.SelectableIcon:SetPoint("BOTTOMLEFT", -3, -3)
	button.SelectableIcon:Hide()
	-- The talent button's own search mark (TalentButtonArt.xml): the game's template,
	-- 63 across, centered on the icon's top right, with an 18 wide hover spot for its
	-- tooltip, which uses the talent tooltip's backdrop. The template pulses the mark
	-- while it is shown.
	local searchIcon = CreateFrame("Frame", nil, button, "TalentButtonSearchIconTemplate")
	searchIcon:SetSize(63, 63)
	searchIcon:SetPoint("CENTER", button.Icon, "TOPRIGHT")
	searchIcon.Mouseover:SetSize(18, 18)
	searchIcon.tooltipBackdropStyle = GAME_TOOLTIP_BACKDROP_STYLE_CLASS_TALENT
	searchIcon:Hide()
	button.SearchIcon = searchIcon
	return button
end

local function CreateNodeButton(frame, board, nodeID)
	local button = CreatePlanButton(frame, board)
	-- The tooltip reads these, and RefreshOpenTooltip finds plan buttons by them.
	button.calculatorFrame = frame
	button.calculatorNodeID = nodeID
	button.SpendText = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	-- Sublevel 2 of OVERLAY, as the game's own SpendText. Forever's API docs list no fourth
	-- value for CreateFontString, so the sublevel is set on its own.
	button.SpendText:SetDrawLayer("OVERLAY", 2)
	button.SpendText:SetJustifyH("CENTER")
	-- The game's pulse on a talent that can take a point (SelectableGlow in
	-- ClassTalentBaseButtonTemplate): the art set's glow, fading in and out, shown
	-- only while it plays. Its alpha comes from the animation, so it starts at 0.
	-- The game's template for this (VisibleWhilePlayingAnimGroupTemplate) is not used:
	-- made in Lua, an animation group gets the template's scripts but not its mixin,
	-- so PaintNode shows and hides the glow itself.
	local glow = button:CreateTexture(nil, "OVERLAY")
	glow:SetSize(61, 61)
	glow:SetPoint("CENTER")
	glow:SetBlendMode("ADD")
	glow:SetAlpha(0)
	local pulse = glow:CreateAnimationGroup()
	pulse:SetLooping("REPEAT")
	pulse:SetToFinalAlpha(true)
	glow.FadeIn = pulse:CreateAnimation("Alpha")
	glow.FadeIn:SetFromAlpha(0)
	glow.FadeIn:SetDuration(1)
	glow.FadeIn:SetOrder(1)
	glow.FadeIn:SetSmoothing("OUT")
	glow.FadeOut = pulse:CreateAnimation("Alpha")
	glow.FadeOut:SetToAlpha(0)
	glow.FadeOut:SetDuration(1)
	glow.FadeOut:SetOrder(2)
	glow.FadeOut:SetSmoothing("IN")
	glow.Anim = pulse
	glow:Hide()
	button.SelectableGlow = glow
	button.choices = {}
	return button
end

-- The entry a talent shows: the chosen one, or its first.
local function ShownEntryID(nodeID)
	local stored = ns.ranks[nodeID]
	if stored and stored.entryID > 0 then
		return stored.entryID
	end
	return ns.structure[nodeID].entryIDs[1]
end

-- Shows an entry's icon on a plan button. The entry is read again only when it changes.
local function SetButtonEntry(frame, button, entryID)
	if button.entryVisual and button.entryVisual.entryID == entryID then
		return
	end
	button.entryVisual = EntryVisual(frame, entryID)
	ApplyIcon(button.Icon, button.entryVisual)
end

local function EnsureChoices(frame, board, button, structure, art, live)
	local entries = structure.entryIDs
	if structure.nodeType ~= Enum.TraitNodeType.Selection or #entries < 2 then
		for _, choice in ipairs(button.choices) do
			choice:Hide()
		end
		return
	end
	for index, entryID in ipairs(entries) do
		local choice = button.choices[index]
		if not choice then
			choice = CreatePlanButton(frame, board)
			choice.planNode = button
			button.choices[index] = choice
		end
		choice.entryID = entryID
		SetButtonArt(choice, art, live)
		choice.entryVisual = nil
		SetButtonEntry(frame, choice, entryID)
		choice:Show()
	end
	for index = #entries + 1, #button.choices do
		button.choices[index]:Hide()
	end
end

-- The talent button's visual state for a plan talent, in the game's order
-- (TalentButtonBaseMixin:CalculateVisualState). With an entry, the state of that
-- choice of a choice talent: a choice not taken on a talent with its point is disabled.
local function PlanVisualState(nodeID, entryID)
	local states = TalentButtonUtil.BaseVisualState
	local ranks = SourceRank(nodeID)
	if entryID and ranks > 0 and entryID ~= ns.ranks[nodeID].entryID then
		return states.Disabled
	end
	if SourceMaxed(nodeID) then
		return states.Maxed
	end
	if CanAddRank(nodeID) then
		return states.Selectable
	end
	if ranks > 0 then
		return states.Normal
	end
	if not GateOpen(nodeID) then
		return states.Gated
	end
	if not EdgesAllow(nodeID) then
		return states.Locked
	end
	return states.Disabled
end

-- TalentButtonBaseMixin:GetSpendText for the plan: the ranks once the talent has a
-- point or can take one, and no number on a one-rank talent when the tree hides those.
local function PlanSpendText(frame, nodeID)
	local ranks = SourceRank(nodeID)
	if ranks < 1 and not CanAddRank(nodeID) then
		return ""
	end
	if ranks <= 1 and ns.structure[nodeID].maxRanks == 1 and frame:ShouldHideSingleRankNumbers() then
		return ""
	end
	return tostring(ranks)
end

local function PaintNode(frame, nodeID)
	local button = frame.calculatorNodes[nodeID]
	if not button then
		return
	end
	local state = PlanVisualState(nodeID)
	SetButtonEntry(frame, button, ShownEntryID(nodeID))
	TalentButtonUtil.SetSpendText(button, PlanSpendText(frame, nodeID))
	TalentButtonArtMixin.ApplyVisualState(button, state)
	-- ClassTalentButtonBaseMixin:UpdateSelectableGlow. A pulse already running goes on.
	local glow = button.SelectableGlow
	local selectable = state == TalentButtonUtil.BaseVisualState.Selectable
	if glow.Anim:IsPlaying() ~= selectable then
		glow:SetShown(selectable)
		glow.Anim:SetPlaying(selectable)
	end
	for _, choice in ipairs(button.choices) do
		if choice:IsShown() then
			TalentButtonArtMixin.ApplyVisualState(choice, PlanVisualState(nodeID, choice.entryID))
		end
	end
end

-- The talent window's own search result for a talent: exact name, name, description
-- or related match, the same answer its buttons get. With no entry it is the best
-- match across a choice node's entries, as on the node's button; with an entry it is
-- that choice's own match, as on the game's choice buttons. Action bar matches ("not
-- on your action bar") are about the character's own bars, so a planned talent does
-- not show them. A type with no mark in TalentButtonUtil counts as no match.
local function PlanSearchMatchType(frame, nodeID, entryID)
	local matchType = frame:GetSearchMatchTypeForEntry(nodeID, entryID)
	if not matchType or SpellSearchUtil.IsActionBarMatchType(matchType) or not TalentButtonUtil.GetStyleForSearchMatchType(matchType) then
		return nil
	end
	return matchType
end

-- TalentButtonArtMixin:UpdateSearchIcon: the mark takes the match type, and a shown
-- mark sits 50 levels above its button.
local function SetSearchMark(button, matchType)
	button.SearchIcon:SetMatchType(matchType)
	if matchType then
		button.SearchIcon:SetFrameLevel(button:GetFrameLevel() + 50)
	end
end

local function ApplyPlanSearch(frame)
	for nodeID, button in pairs(frame.calculatorNodes or {}) do
		SetSearchMark(button, PlanSearchMatchType(frame, nodeID, nil))
		for _, choice in ipairs(button.choices) do
			SetSearchMark(choice, choice:IsShown() and PlanSearchMatchType(frame, nodeID, choice.entryID) or nil)
		end
	end
end

--------------------------------------------------------------------------------
-- Arrows
--------------------------------------------------------------------------------

local function NodePoint(frame, posX, posY)
	local panX, panY = frame:GetPanOffset()
	return TalentButtonUtil.TranslateNodePositionsToAnchorPositions(posX, posY, panX, panY)
end

-- TalentEdgeArrowTemplate: a 6 thick line whose art repeats along it, under an arrow head.
local function CreateEdge(board)
	local line = board:CreateLine(nil, "ARTWORK")
	line:SetThickness(6)
	line:SetHorizTile(true)
	local arrow = board:CreateTexture(nil, "OVERLAY")
	arrow:Hide()
	return { line = line, arrow = arrow }
end

-- TalentEdgeArrowMixin:UpdateState's colors: locked into a gated talent, yellow once
-- the arrow's talent is maxed, gray before.
local function ArrowNames(edge)
	local name = "gray"
	if PlanVisualState(edge.targetID) == TalentButtonUtil.BaseVisualState.Gated then
		name = "locked"
	elseif edge.active then
		name = "yellow"
	end
	return "talents-arrow-line-" .. name, "talents-arrow-head-" .. name
end

-- TalentEdgeArrowMixin:UpdatePosition stops the line on the arrow head, just outside the target.
local function PlaceArrow(frame, edge)
	local fromButton = edge.fromButton
	local toButton = edge.toButton
	local fromStructure = ns.structure[edge.fromID]
	local toStructure = ns.structure[edge.targetID]
	local x1, y1 = NodePoint(frame, fromStructure.posX, fromStructure.posY)
	local x2, y2 = NodePoint(frame, toStructure.posX, toStructure.posY)
	local angle = math.atan2(y1 - y2, x1 - x2)
	local offset = toButton:GetEdgeDiameterOffset(angle)
	local xOffset = (toButton:GetWidth() / 2) * math.cos(angle) * offset
	local yOffset = (toButton:GetHeight() / 2) * math.sin(angle) * offset
	edge.line:SetStartPoint("CENTER", fromButton)
	edge.line:SetEndPoint("CENTER", toButton, xOffset, yOffset)
	edge.arrow:ClearAllPoints()
	edge.arrow:SetPoint("CENTER", toButton, xOffset, yOffset)
	edge.arrow:SetRotation(angle - (math.pi / 2))
end

local function PaintEdge(frame, edge)
	local rankLink = edge.edgeType == REQUIRED_EDGE or edge.edgeType == SUFFICIENT_EDGE
	edge.active = rankLink and SourceMaxed(edge.fromID)
	local show = ShowsArrow(edge.visualStyle)
	edge.line:SetShown(show)
	edge.arrow:SetShown(show)
	if not show then
		return
	end
	local lineAtlas, headAtlas = ArrowNames(edge)
	edge.line:SetAtlas(lineAtlas, TextureKitConstants.IgnoreAtlasSize)
	edge.arrow:SetAtlas(headAtlas, TextureKitConstants.UseAtlasSize)
	PlaceArrow(frame, edge)
end

local function BuildEdges(frame, board)
	local edges = frame.calculatorEdges
	local count = 0
	for nodeID, structure in pairs(ns.structure) do
		local from = frame.calculatorNodes[nodeID]
		for _, info in ipairs(structure.edges) do
			local to = info.target and frame.calculatorNodes[info.target]
			if from and to and from:IsShown() and to:IsShown() then
				count = count + 1
				local edge = edges[count]
				if not edge then
					edge = CreateEdge(board)
					edges[count] = edge
				end
				edge.fromID = nodeID
				edge.targetID = info.target
				edge.edgeType = info.edgeType
				edge.visualStyle = info.visualStyle
				edge.fromButton = from
				edge.toButton = to
				PaintEdge(frame, edge)
			end
		end
	end
	for index = count + 1, #edges do
		edges[index].line:Hide()
		edges[index].arrow:Hide()
	end
	frame.calculatorEdgeCount = count
end

local function RefreshChangedEdges(frame, nodeIDs)
	for index = 1, frame.calculatorEdgeCount do
		local edge = frame.calculatorEdges[index]
		if nodeIDs[edge.fromID] or nodeIDs[edge.targetID] then
			PaintEdge(frame, edge)
		end
	end
end

--------------------------------------------------------------------------------
-- Gates
--------------------------------------------------------------------------------

-- The game's gates (TalentFrameGateTemplate, anchored by the talent window's own
-- AnchorGate): a lock with the points the plan still needs, on the first locked row
-- of each tree, as the game shows one gate per tree. The tree's gate list says
-- where gates go. Gates sit below the talents, as the game draws them.
local function BuildGates(frame)
	local nodes = frame.calculatorNodes
	local board = frame.calculatorBoard
	frame.calculatorGates = frame.calculatorGates or {}
	-- The first locked gate of each tree, keyed by its anchor talent.
	local firstLocked = {}
	for _, gateInfo in ipairs(TreeGates(frame, PlanConfigID(frame)) or {}) do
		local anchorID = gateInfo.topLeftNodeID
		local left = PointsLeft(anchorID)
		local button = nodes[anchorID]
		if left and left > 0 and button and button:IsShown() then
			local treeAnchor
			for otherID in pairs(firstLocked) do
				if SameTree(otherID, anchorID) then
					treeAnchor = otherID
					break
				end
			end
			if not treeAnchor then
				firstLocked[anchorID] = left
			elseif ns.structure[anchorID].posY < ns.structure[treeAnchor].posY then
				firstLocked[treeAnchor] = nil
				firstLocked[anchorID] = left
			end
		end
	end
	local count = 0
	for anchorID, left in pairs(firstLocked) do
		count = count + 1
		local gate = frame.calculatorGates[count]
		if not gate then
			gate = CreateFrame("Frame", nil, board, "TalentFrameGateTemplate")
			gate:SetFrameLevel(board:GetFrameLevel())
			gate:EnableMouseMotion(true)
			gate:SetScript("OnEnter", Guard(ShowGateTooltip))
			gate:SetScript("OnLeave", GameTooltip_Hide)
			frame.calculatorGates[count] = gate
		end
		gate.pointsNeeded = left
		gate.GateText:SetText(left)
		gate.GateText:Show()
		gate:ClearAllPoints()
		frame:AnchorGate(gate, nodes[anchorID])
		gate:Show()
	end
	for index = count + 1, #frame.calculatorGates do
		frame.calculatorGates[index]:Hide()
	end
end

--------------------------------------------------------------------------------
-- The board
--------------------------------------------------------------------------------

local function EnsureBoard(frame)
	if frame.calculatorBoard then
		return frame.calculatorBoard
	end
	-- Over the game's tree, as big as it and clipped like it, above its talents (TREE_LEVEL).
	local parent = frame.ButtonsParent
	local board = CreateFrame("Frame", nil, frame)
	board:SetAllPoints(parent)
	board:SetFrameLevel(parent:GetFrameLevel() + TREE_LEVEL)
	board:SetClipsChildren(true)
	frame.calculatorBoard = board
	frame.calculatorNodes = {}
	frame.calculatorEdges = {}
	frame.calculatorEdgeCount = 0
	return board
end

local function BuildBoard(frame)
	local board = EnsureBoard(frame)
	local size = frame:GetButtonSize()
	local shown = {}
	for nodeID, structure in pairs(ns.structure) do
		if structure.maxRanks > 0 then
			shown[nodeID] = true
			local button = frame.calculatorNodes[nodeID]
			if not button then
				button = CreateNodeButton(frame, board, nodeID)
				frame.calculatorNodes[nodeID] = button
			end
			local live = frame:GetTalentButtonByNodeID(nodeID)
			local art = ArtSet(frame, nodeID)
			SetButtonArt(button, art, live)
			local x, y = NodePoint(frame, structure.posX, structure.posY)
			button:ClearAllPoints()
			button:SetPoint("CENTER", board, "TOPLEFT", x, y)
			-- Spell data may have loaded since the last time, so the icon is read again.
			button.entryVisual = nil
			SetButtonEntry(frame, button, ShownEntryID(nodeID))
			EnsureChoices(frame, board, button, structure, art, live)
			for index, choice in ipairs(button.choices) do
				if choice:IsShown() then
					choice:ClearAllPoints()
					choice:SetPoint("RIGHT", button, "LEFT", -((index - 1) * (size + 4)), 0)
				end
			end
			button:Show()
		end
	end
	for nodeID, button in pairs(frame.calculatorNodes) do
		if not shown[nodeID] then
			button:Hide()
		end
	end
	BuildEdges(frame, board)
	board:Show()
end

--------------------------------------------------------------------------------
-- The points row and tree headers
--------------------------------------------------------------------------------

local function LevelLabel(frame)
	local display = frame.ClassCurrencyDisplay
	if not display.calculatorLevelText then
		local text = display:CreateFontString(nil, "ARTWORK", "SystemFont_Shadow_Med1")
		text:SetJustifyH("RIGHT")
		text:SetPoint("RIGHT", display.UnspentLabel, "LEFT", -20, 0)
		display.calculatorLevelText = text
	end
	return display.calculatorLevelText
end

-- The addon's version on the left end of the points row, mirroring the row's
-- inset from the right. The row sits 6 below the tree area's top, centered on its tallest part.
local function VersionLabel(frame)
	local display = frame.ClassCurrencyDisplay
	if not display.calculatorVersionText then
		local text = display:CreateFontString(nil, "ARTWORK", "SystemFont_Shadow_Med1")
		text:SetJustifyH("LEFT")
		text:SetText("v" .. VERSION)
		local rowHeight = math.max(display.Border:GetHeight(), display.CurrentAmountContainer:GetHeight())
		text:SetPoint("LEFT", frame.BackgroundBorder, "TOPLEFT", 20, -6 - rowHeight / 2)
		display.calculatorVersionText = text
	end
	return display.calculatorVersionText
end

-- The addon's name in the game's gold title font, centered on the same points row.
local function TitleLabel(frame)
	local display = frame.ClassCurrencyDisplay
	if not display.calculatorTitleText then
		local text = display:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
		text:SetJustifyH("CENTER")
		text:SetText(ADDON_TITLE)
		local rowHeight = math.max(display.Border:GetHeight(), display.CurrentAmountContainer:GetHeight())
		text:SetPoint("CENTER", frame.BackgroundBorder, "TOP", 0, -6 - rowHeight / 2)
		display.calculatorTitleText = text
	end
	return display.calculatorTitleText
end

-- The plan's unspent points, over the game's own number in the same font.
local function PlanAmountText(frame)
	local display = frame.ClassCurrencyDisplay
	if not display.calculatorAmountText then
		local container = display.CurrentAmountContainer
		local text = container:CreateFontString(nil, "OVERLAY", "Game32Font_Shadow2")
		text:SetPoint("CENTER", container, "CENTER", 0, 0)
		text:SetJustifyH("CENTER")
		text:SetJustifyV("MIDDLE")
		display.calculatorAmountText = text
	end
	return display.calculatorAmountText
end

-- A tree's planned points, over the header's own number in the same font.
local function HeaderSpentText(header)
	if not header.calculatorSpentText then
		local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetPoint("CENTER", header.Text, "CENTER", 0, 0)
		text:SetJustifyH("CENTER")
		text:SetJustifyV("MIDDLE")
		header.calculatorSpentText = text
	end
	return header.calculatorSpentText
end

-- Puts the character's own numbers back on the points row and the tree headers.
local function ShowCharacterTalentNumbers(frame)
	local display = frame.ClassCurrencyDisplay
	if display.calculatorAmountText then
		display.calculatorAmountText:Hide()
	end
	display.CurrentAmountContainer.CurrencyAmount:Show()
	for _, header in ipairs(frame.treeHeaders or {}) do
		if header.calculatorSpentText then
			header.calculatorSpentText:Hide()
		end
		header.Text:Show()
	end
end

-- Save is on while the plan differs from the saved one, Load Saved while a saved
-- plan differs from the one on screen, and Clear while the plan has points.
-- As the game's UpdateConfigButtonsState: Apply Changes is on and glows while the plan differs
-- from the saved one; the undo arrow shows then, and the reset arrow otherwise, on while the
-- plan has points (IconButtonMixin:SetEnabledState).
local function UpdatePlanButtons(frame)
	local matches = PlanMatchesSaved()
	local apply = frame.calculatorSaveButton
	apply:SetEnabled(not matches)
	apply.YellowGlow:SetShown(not matches)
	frame.calculatorLoadButton:SetShown(not matches)
	local reset = frame.calculatorClearButton
	reset:SetShown(matches)
	reset:SetEnabled(next(ns.ranks) ~= nil)
	reset.Icon:SetDesaturated(next(ns.ranks) == nil)
end

-- A tree header's planned points: the same tree the row gates count each talent in.
local function HeaderSpent(groupID)
	local spent = 0
	for nodeID, stored in pairs(ns.ranks) do
		local structure = ns.structure[nodeID]
		local knownTree = ns.treeOf and ns.treeOf[nodeID]
		local counts = false
		if knownTree then
			counts = knownTree == groupID
		elseif structure then
			for _, headerGroup in ipairs(structure.groupIDs) do
				local mapped = ns.groupTree and ns.groupTree[headerGroup]
				if headerGroup == groupID or mapped == groupID then
					counts = true
					break
				end
			end
			if not counts and ns.currencyGroupsOf then
				counts = ListHas(ns.currencyGroupsOf[nodeID] or {}, groupID)
			end
		end
		if counts then
			spent = spent + stored.ranks
		end
	end
	return spent
end

local function PaintSpent(frame)
	local display = frame.ClassCurrencyDisplay
	local unspent = math.max(0, Unspent())
	local amount = PlanAmountText(frame)
	amount:SetText(unspent)
	-- ClassTalentCurrencyDisplayMixin:SetAmount's colors.
	amount:SetTextColor((unspent > 0 and GREEN_FONT_COLOR or GRAY_FONT_COLOR):GetRGBA())
	amount:Show()
	display.CurrentAmountContainer.CurrencyAmount:Hide()
	local levelText = LevelLabel(frame)
	levelText:SetText("Level required: " .. LevelRequiredText(TotalSpent()))
	levelText:Show()
	VersionLabel(frame):Show()
	TitleLabel(frame):Show()
	UpdatePlanButtons(frame)
	for _, header in ipairs(frame.treeHeaders or {}) do
		local groupID = header.displayInfo and header.displayInfo.groupID
		if groupID then
			local text = HeaderSpentText(header)
			text:SetText(HeaderSpent(groupID))
			text:Show()
			header.Text:Hide()
		end
	end
end

--------------------------------------------------------------------------------
-- Chat about plans
--------------------------------------------------------------------------------

local FIT_REASONS = {
	tree = "no longer in the tree",
	max = "max rank lowered",
	budget = "over " .. PLAN_BUDGET .. " points",
	requirements = "row or arrow requirement no longer met",
}
local MAX_LISTED_CHANGES = 3

local function Reasons(texts)
	return GRAY_FONT_COLOR:WrapTextInColorCode("(" .. table.concat(texts, ", ") .. ")")
end

local function DescribeChange(frame, change)
	local reasonTexts = {}
	for index, reason in ipairs(change.reasons) do
		reasonTexts[index] = FIT_REASONS[reason]
	end
	local newName = change.newEntryID and TalentText(frame, change.nodeID, change.newEntryID, "a talent")
	if change.newEntryID and change.to == change.from then
		local oldName = TalentText(frame, change.nodeID, change.entryID, "a removed choice")
		return newName .. " replaces " .. oldName .. " " .. Reasons({ "choice no longer exists" })
	end
	-- A replaced choice that also lost points is named by its new choice.
	local name = newName or TalentText(frame, change.nodeID, change.entryID, "a talent")
	if change.to == 0 then
		return name .. " removed " .. Reasons(reasonTexts)
	end
	return string.format("%s from %d to %d ranks %s", name, change.from, change.to, Reasons(reasonTexts))
end

-- One chat line when fitting changed the plan on screen, naming the first few talents
-- as links.
local function ReportPlanFit(frame, changes)
	if not changes[1] then
		return
	end
	local listed = {}
	for index = 1, math.min(#changes, MAX_LISTED_CHANGES) do
		listed[index] = DescribeChange(frame, changes[index])
	end
	local text = table.concat(listed, ", ")
	if #changes > MAX_LISTED_CHANGES then
		text = text .. " and " .. (#changes - MAX_LISTED_CHANGES) .. " more"
	end
	Say(SlotText(ns.slot or 1) .. " plan changed to fit the current talents: " .. text .. ". Press " .. TALENT_FRAME_APPLY_BUTTON_TEXT .. " to keep it.")
end

--------------------------------------------------------------------------------
-- Showing and changing the plan
--------------------------------------------------------------------------------

local function ShowPlan(frame)
	if not next(ns.structure) then
		RememberFrame(frame)
	end
	-- Without the tree nothing can be checked, so the plan is kept as it is.
	if next(ns.structure) then
		ReportPlanFit(frame, FitPlanToTree())
	else
		SayFailed("Couldn't read the talent tree. Close and reopen the talent window.")
	end
	CoverClientTree(frame, true)
	BuildBoard(frame)
	ApplyPlanSearch(frame)
	for nodeID in pairs(ns.structure) do
		PaintNode(frame, nodeID)
	end
	PaintSpent(frame)
	BuildGates(frame)
	RefreshOpenTooltip()
end

-- Repaints what a change to one talent can affect: its arrows' talents, the rows of
-- its tree, and when the last point was spent or the first one freed, every talent
-- that could take one.
local function ApplyLocalChange(frame, originID, poolChanged)
	local affected = {}
	MarkOutgoing(affected, originID)
	for nodeID, other in pairs(ns.structure) do
		if other.requiredSpent and other.requiredSpent > 0 and SameTree(originID, nodeID) then
			affected[nodeID] = true
		end
	end
	if poolChanged then
		for nodeID in pairs(ns.structure) do
			if not SourceMaxed(nodeID) and EdgesAllow(nodeID) and GateOpen(nodeID) then
				affected[nodeID] = true
			end
		end
	end
	Prune(affected)
	for nodeID in pairs(affected) do
		PaintNode(frame, nodeID)
	end
	RefreshChangedEdges(frame, affected)
	PaintSpent(frame)
	BuildGates(frame)
	RefreshOpenTooltip()
	RememberCurrentPlan()
end

-- The sounds the game's class talent buttons play (ClassTalentButtonSpendMixin and
-- ClassTalentButtonSelectMixin): a spend by the talent's entry type, and the refund sound.
local function PlaySpendSound(frame, entryID)
	local configID = frame:GetConfigID()
	local entry = configID and entryID and entryID > 0 and C_Traits.GetEntryInfo(configID, entryID)
	PlaySound(ClassTalentUtil.GetSpendSoundKitID(entry and entry.type))
end

local function ChangeRank(frame, nodeID, delta)
	if not ShowingCalculator(frame) then
		return
	end
	if not ns.structure[nodeID] then
		RememberFrame(frame)
	end
	local structure = ns.structure[nodeID]
	if not structure then
		return
	end
	if delta > 0 and not CanAddPoint(nodeID) or delta < 0 and not CanRemovePoint(nodeID) then
		return
	end
	local stored = ns.ranks[nodeID]
	local unspentBefore = Unspent()
	local nextRank = SourceRank(nodeID) + delta
	if nextRank <= 0 then
		ns.ranks[nodeID] = nil
	else
		local entryID = stored and stored.entryID or 0
		if entryID <= 0 then
			entryID = structure.entryIDs[1] or 0
		end
		ns.ranks[nodeID] = {
			ranks = nextRank,
			entryID = entryID,
		}
	end
	if delta > 0 then
		PlaySpendSound(frame, ns.ranks[nodeID].entryID)
	else
		PlaySound(SOUNDKIT.UI_CLASS_TALENT_NODE_REFUND)
	end
	ApplyLocalChange(frame, nodeID, (unspentBefore == 0) ~= (Unspent() == 0))
end

-- Picks one choice of a choice talent. A first pick spends a point, so it passes the
-- same checks as a click; switching choices keeps the point.
local function ChooseEntry(frame, nodeID, entryID)
	if not ShowingCalculator(frame) then
		return
	end
	if not ns.structure[nodeID] then
		RememberFrame(frame)
	end
	local structure = ns.structure[nodeID]
	if not structure then
		return
	end
	local stored = ns.ranks[nodeID]
	if not stored and not CanAddPoint(nodeID) then
		return
	end
	local unspentBefore = Unspent()
	local chosen = entryID or (stored and stored.entryID) or 0
	if chosen <= 0 then
		chosen = structure.entryIDs[1] or 0
	end
	ns.ranks[nodeID] = {
		ranks = stored and stored.ranks or 1,
		entryID = chosen,
	}
	PlaySpendSound(frame, chosen)
	ApplyLocalChange(frame, nodeID, (unspentBefore == 0) ~= (Unspent() == 0))
end

-- A plan button's click, as on the game's talent buttons: a right click takes a point
-- off, a shift-click puts the talent's link in chat, and a click adds a point or picks
-- a choice.
function NodeClick(button, mouseButton)
	local nodeButton = button.planNode or button
	local frame = nodeButton.calculatorFrame
	local nodeID = nodeButton.calculatorNodeID
	if mouseButton == "RightButton" then
		ChangeRank(frame, nodeID, -1)
		return
	end
	if IsModifiedClick("CHATLINK") then
		local spellID = button.entryVisual and button.entryVisual.spellID
		local link = spellID and C_Spell.GetSpellLink(spellID)
		if link then
			ChatFrameUtil.InsertLink(link)
		end
		return
	end
	local structure = ns.structure[nodeID]
	if button.entryID or (structure and structure.nodeType == Enum.TraitNodeType.Selection) then
		ChooseEntry(frame, nodeID, button.entryID)
		return
	end
	ChangeRank(frame, nodeID, 1)
end

--------------------------------------------------------------------------------
-- The apply effect
--------------------------------------------------------------------------------

-- What the game shows as it applies talent changes (ClassTalentsFrameMixin and
-- TalentFrameBaseMixin:SetCommitCompleteVisualsActive): its class flash over the tree
-- (commitFlashAnims), the background flash (BackgroundFlashAnim) and, a moment later, a spark on
-- each newly learned talent (PlayPurchaseCompleteEffect) with the completion sound. Rebuilt on the
-- addon's own textures and model scene from Camelot's Blizzard_ClassTalentsFrame.xml and
-- Blizzard_SharedTalentFrame.xml: the game's own run the game's code when played.
local PURCHASE_FX_DELAY = 1.2 -- PurchaseFXDelay
local NODE_PURCHASE_COMPLETE_FX = 150 -- NODE_PURCHASE_COMPLETE_FX_1
local DEFAULT_CLASS_FX = "talents-animations-class-druid" -- the XML's atlas, kept when a class has none
local MASK_WRAP = "CLAMPTOBLACKADDITIVE"

local function AddAlpha(group, target, duration, fromAlpha, toAlpha, smoothing)
	local anim = group:CreateAnimation("Alpha")
	anim:SetTarget(target)
	anim:SetDuration(duration)
	anim:SetFromAlpha(fromAlpha)
	anim:SetToAlpha(toAlpha)
	if smoothing then
		anim:SetSmoothing(smoothing)
	end
end

local function AddScale(group, target, duration, fromScale, toScale, smoothing)
	local anim = group:CreateAnimation("Scale")
	anim:SetTarget(target)
	anim:SetDuration(duration)
	anim:SetScaleFrom(fromScale, fromScale)
	anim:SetScaleTo(toScale, toScale)
	if smoothing then
		anim:SetSmoothing(smoothing)
	end
end

local function CreateApplyEffect(frame)
	-- Over the game's see-through tree and its shield, under the plan's board, as the game draws
	-- these in its background layer under its talents.
	local holder = CreateFrame("Frame", nil, frame)
	holder:SetAllPoints(frame)
	holder:SetFrameLevel(frame.ButtonsParent:GetFrameLevel() + TREE_LEVEL - 5)
	local background = frame.ClassBackground
	local function FxTexture(atlas, useAtlasSize)
		local texture = holder:CreateTexture(nil, "BACKGROUND", nil, 3)
		texture:SetAtlas(atlas, useAtlasSize)
		texture:SetBlendMode("ADD")
		texture:SetAlpha(0)
		return texture
	end
	local function Mask(atlas)
		local mask = holder:CreateMaskTexture()
		mask:SetAtlas(atlas, false, nil, nil, MASK_WRAP, MASK_WRAP)
		return mask
	end

	local visuals = ClassTalentUtil.GetVisualsForClassID(select(3, UnitClass("player")))
	local classFx = visuals and visuals.activationFX
	if not (classFx and C_Texture.GetAtlasInfo(classFx)) then
		classFx = DEFAULT_CLASS_FX
	end
	local expand = FxTexture("talents-animations-gridburst", false)
	expand:SetSize(320, 320)
	expand:SetPoint("CENTER", background, "CENTER")
	local filigree = Mask("talents-animations-mask-filigree-activate")
	filigree:SetPoint("TOPLEFT", background, "TOPLEFT")
	expand:AddMaskTexture(filigree)
	local class1 = FxTexture(classFx, true)
	class1:SetPoint("CENTER", background, "CENTER")
	local class2, class3, class4 = FxTexture(classFx, true), FxTexture(classFx, true), FxTexture(classFx, true)
	for _, texture in ipairs({ class2, class3, class4 }) do
		texture:SetPoint("CENTER", class1, "CENTER")
	end
	local titans = FxTexture("talents-animations-titans", true)
	titans:SetPoint("CENTER", background, "CENTER", 100, -18)
	local full = Mask("talents-animations-mask-full")
	full:SetPoint("TOPLEFT", background, "TOPLEFT")
	full:SetPoint("BOTTOMRIGHT", background, "BOTTOMRIGHT")
	for _, texture in ipairs({ titans, expand, class3, class4 }) do
		texture:AddMaskTexture(full)
	end
	local flash = FxTexture("spec-background", false)
	flash:SetPoint("TOPLEFT", frame.ButtonsParent, "TOPLEFT")
	flash:SetPoint("BOTTOMRIGHT", frame.ButtonsParent, "BOTTOMRIGHT")

	local commit = holder:CreateAnimationGroup()
	commit:SetToFinalAlpha(true)
	AddScale(commit, expand, 1.4, 1, 20, "IN")
	AddAlpha(commit, expand, 1.4, 0.65, 0, "IN")
	AddAlpha(commit, class1, 1.2, 1, 0, "OUT")
	AddAlpha(commit, class2, 1.2, 1, 0, "OUT")
	AddAlpha(commit, class3, 0.3, 0.3, 0, "OUT")
	AddAlpha(commit, class4, 0.5, 0.2, 0, "OUT")
	AddScale(commit, class3, 0.3, 1, 1.5)
	AddScale(commit, class4, 0.5, 1, 1.5)
	AddAlpha(commit, titans, 1, 0.7, 0, "IN")
	AddScale(commit, titans, 2, 1.3, 1.2)
	local backgroundFlash = holder:CreateAnimationGroup()
	backgroundFlash:SetToFinalAlpha(true)
	AddAlpha(backgroundFlash, flash, 1.2, 1, 0, "IN")

	-- The talents' sparks, in a model scene like the game's FxModelScene.
	local scene = CreateFrame("ModelScene", nil, frame, "ScriptAnimatedModelSceneTemplate")
	scene:SetFrameStrata("HIGH")
	scene:SetFrameLevel(4000)
	scene:SetPoint("TOPLEFT", frame.ButtonsParent, "TOPLEFT")
	scene:SetPoint("BOTTOMRIGHT", frame.ButtonsParent, "BOTTOMRIGHT")

	frame.calculatorApplyEffect = { commit = commit, backgroundFlash = backgroundFlash, scene = scene }
end

-- Plays the effect for a plan just saved; nodeIDs are the talents it learned since the last save.
local function PlayApplyEffect(frame, nodeIDs)
	if not frame:IsVisible() then
		return
	end
	if not frame.calculatorApplyEffect then
		CreateApplyEffect(frame)
	end
	local effect = frame.calculatorApplyEffect
	effect.commit:Restart()
	effect.backgroundFlash:Restart()
	if #nodeIDs == 0 then
		return
	end
	C_Timer.After(PURCHASE_FX_DELAY, Guard(function()
		if not ShowingCalculator(frame) or not frame:IsVisible() then
			return
		end
		for _, nodeID in ipairs(nodeIDs) do
			local button = frame.calculatorNodes and frame.calculatorNodes[nodeID]
			if button and button:IsVisible() then
				-- TalentButtonArtMixin:InternalPlayAnimEffects's scale.
				effect.scene:AddEffect(NODE_PURCHASE_COMPLETE_FX, button, button, nil, nil, button:GetEffectiveScale() / effect.scene:GetEffectiveScale())
			end
		end
		PlaySound(SOUNDKIT.UI_CLASS_TALENT_APPLY_COMPLETE)
	end))
end

--------------------------------------------------------------------------------
-- Save, Load Saved, Clear and the slot menu
--------------------------------------------------------------------------------

local function SaveBuild(frame)
	local build = SaveSlot(ns.slot or 1, true)
	-- Plans are saved per character, and the name can be missing right after login.
	if not build then
		SayFailed("Couldn't save: your character isn't fully loaded yet. Try again in a moment.")
		return
	end
	-- The talents learned since the last save: new, more ranks, or another choice.
	local saved = SavedRanks(ns.slot or 1) or {}
	local learned = {}
	for nodeID, stored in pairs(ns.ranks) do
		local before = saved[nodeID]
		if not before or stored.ranks > before.ranks or stored.entryID ~= before.entryID then
			learned[#learned + 1] = nodeID
		end
	end
	for key in pairs(build) do
		build[key] = nil
	end
	local nodes = {}
	for nodeID, stored in pairs(ns.ranks) do
		nodes[#nodes + 1] = {
			nodeID = nodeID,
			ranks = stored.ranks,
			entryID = stored.entryID,
		}
	end
	build.nodes = nodes
	RememberCurrentPlan()
	UpdatePlanButtons(frame)
	-- The sound the game plays as it applies talent changes (commitSound).
	PlaySound(SOUNDKIT.UI_CLASS_TALENT_APPLY_CHANGES)
	PlayApplyEffect(frame, learned)
	Say(string.format("%s plan saved (%d/%d points).", SlotText(ns.slot or 1), TotalSpent(), PLAN_BUDGET))
end

local function ClearBuild(frame)
	ClearRankTable()
	ns.loadedSlot = ns.slot or 1
	if ShowingCalculator(frame) then
		ShowPlan(frame)
	end
	RememberCurrentPlan()
	Say(SlotText(ns.slot or 1) .. " plan cleared. Your saved plan is unchanged until you press " .. TALENT_FRAME_APPLY_BUTTON_TEXT .. ".")
end

local function LoadSavedPlan(frame)
	local slot = ns.slot or 1
	if not HasSavedPlan() then
		return
	end
	local hadChanges = not PlanMatchesSaved()
	LoadSavedRanks(slot)
	ns.loadedSlot = slot
	-- Said before ShowPlan, so a line about fitting the plan to the tree comes after it.
	local message = string.format("Saved %s plan loaded (%d/%d points).", SlotText(slot), TotalSpent(), PLAN_BUDGET)
	if hadChanges then
		message = message .. " Unsaved changes were discarded."
	end
	Say(message)
	if ShowingCalculator(frame) then
		ShowPlan(frame)
	end
	RememberCurrentPlan()
end

local function SelectSlot(frame, slot)
	if ns.slot == slot and ns.loadedSlot == slot then
		return
	end
	ns.slot = slot
	EnsureWorkingCopy()
	if ShowingCalculator(frame) then
		ShowPlan(frame)
	end
end

-- Undo Pending Changes: back to the saved plan, or to none if the slot was never saved.
local function UndoPlan(frame)
	if HasSavedPlan() then
		LoadSavedPlan(frame)
	else
		ClearBuild(frame)
	end
end

-- The plan's own buttons in the game's controls' places, made like them: Apply Changes like
-- ApplyButton (with its YellowGlow), the undo and reset arrows like UndoButton and ResetButton
-- (IconButtonTemplate). They sit just above the shields over the game's controls.
local function PlanControlLevel(frame)
	return math.max(frame.ApplyButton:GetFrameLevel(), frame.ResetButton:GetFrameLevel(), frame.UndoButton:GetFrameLevel()) + SHIELD_LEVEL + 2
end

local function OnPlanButtonClick(frame, onClick)
	return function()
		-- UIButtonMixin:OnClick's sound.
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		Guarded(onClick, frame)
	end
end

local function PlanButtonTooltip(title, text)
	return Guard(function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if title then
			GameTooltip_SetTitle(GameTooltip, title)
			GameTooltip_AddNormalLine(GameTooltip, text)
		else
			GameTooltip_AddHighlightLine(GameTooltip, text)
		end
		GameTooltip:Show()
	end)
end

local GLOW_PARTS = {
	{ key = "Left", atlas = "newplayertutorial-yellowGlow-redbutton-left" },
	{ key = "Right", atlas = "newplayertutorial-yellowGlow-redbutton-right" },
	{ key = "Middle", atlas = "newplayertutorial-yellowGlow-redbutton-middle" },
}

local function CreateApplyButton(frame)
	local button = CreateFrame("Button", nil, frame, "UIPanelButtonNoTooltipTemplate")
	button:SetSize(frame.ApplyButton:GetSize())
	button:SetPoint("CENTER", frame.ApplyButton, "CENTER")
	button:SetFrameLevel(PlanControlLevel(frame))
	button:SetText(TALENT_FRAME_APPLY_BUTTON_TEXT)
	button:SetScript("OnClick", OnPlanButtonClick(frame, SaveBuild))
	button:SetScript("OnEnter", PlanButtonTooltip(TALENT_FRAME_APPLY_BUTTON_TEXT, "Stores the plan on screen for this character. It does not change your talents."))
	button:SetScript("OnLeave", GameTooltip_Hide)
	-- The ApplyButton's YellowGlow (Camelot's Blizzard_ClassTalentsFrame.xml).
	local glow = CreateFrame("Frame", nil, button)
	glow:SetHeight(1)
	glow:SetPoint("LEFT", -12, 0)
	glow:SetPoint("RIGHT", 12, 0)
	local parts = {}
	for _, part in ipairs(GLOW_PARTS) do
		local texture = glow:CreateTexture(nil, "ARTWORK")
		texture:SetAtlas(part.atlas, part.key ~= "Middle")
		texture:SetBlendMode("ADD")
		parts[part.key] = texture
	end
	local left, right, middle = parts.Left, parts.Right, parts.Middle
	left:SetPoint("LEFT")
	right:SetPoint("RIGHT")
	middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
	middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
	glow:Hide()
	button.YellowGlow = glow
	button:Hide()
	return button
end

-- An arrow button in ResetButton's place (LEFT of ApplyButton's RIGHT, 14 over), as
-- IconButtonMixin:OnLoad sets one up from its atlas.
local function CreateArrowButton(frame, apply, atlas, onClick, tooltip)
	local button = CreateFrame("Button", nil, frame, "IconButtonTemplate")
	button:SetSize(25, 25)
	button:SetPoint("LEFT", apply, "RIGHT", 14, 0)
	button:SetFrameLevel(PlanControlLevel(frame))
	button.Icon:SetAtlas(atlas, true)
	button:SetHighlightAtlas(atlas, "ADD")
	local highlight = button:GetHighlightTexture()
	highlight:SetPoint("TOPLEFT", button.Icon, "TOPLEFT")
	highlight:SetPoint("BOTTOMRIGHT", button.Icon, "BOTTOMRIGHT")
	button:SetScript("OnClick", OnPlanButtonClick(frame, onClick))
	button:SetScript("OnEnter", tooltip)
	button:SetScript("OnLeave", GameTooltip_Hide)
	button:Hide()
	return button
end

-- Apply Changes, the undo arrow and the reset arrow take the game's controls' places, and the
-- Primary/Secondary menu sits above them.
local function CreatePlanControls(frame)
	local apply = CreateApplyButton(frame)
	frame.calculatorSaveButton = apply
	frame.calculatorLoadButton = CreateArrowButton(frame, apply, "talents-button-undo", UndoPlan,
		PlanButtonTooltip(nil, TALENT_FRAME_DISCARD_CHANGES_BUTTON_TOOLTIP))
	frame.calculatorClearButton = CreateArrowButton(frame, apply, "talents-button-reset", ClearBuild,
		PlanButtonTooltip("Clear", "Removes every point from the plan on screen. Press " .. TALENT_FRAME_APPLY_BUTTON_TEXT .. " to store that."))

	-- The game's dropdown, part of the talent window, so it hides and moves with it and its
	-- menu closes with it. The talent buttons sit at level 1000 and up; 2000 keeps the dropdown
	-- above them, where the window's own search list sits.
	local dropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
	dropdown:SetFrameLevel(2000)
	dropdown:SetWidth(160)
	dropdown:SetPoint("BOTTOM", frame.Background, "BOTTOM", 0, 36)
	dropdown:SetupMenu(Guard(function(_, rootDescription)
		local isSelected = Guard(function(slot)
			return (ns.slot or 1) == slot
		end)
		local setSelected = Guard(function(slot)
			SelectSlot(frame, slot)
		end)
		rootDescription:CreateRadio(SlotText(1), isSelected, setSelected, 1)
		rootDescription:CreateRadio(SlotText(2), isSelected, setSelected, 2)
	end))
	dropdown:Hide()
	frame.calculatorSlotDropdown = dropdown
end

local function ShowPlanControls(frame)
	frame.calculatorSaveButton:Show()
	frame.calculatorSlotDropdown:Show()
	-- The menu's button shows the slot on screen.
	frame.calculatorSlotDropdown:GenerateMenu()
	UpdatePlanButtons(frame)
end

local function HidePlanControls(frame)
	local display = frame.ClassCurrencyDisplay
	for _, label in ipairs({ display.calculatorLevelText, display.calculatorVersionText, display.calculatorTitleText }) do
		label:Hide()
	end
	frame.calculatorSaveButton:Hide()
	frame.calculatorLoadButton:Hide()
	frame.calculatorClearButton:Hide()
	frame.calculatorSlotDropdown:CloseMenu()
	frame.calculatorSlotDropdown:Hide()
	ShowCharacterTalentNumbers(frame)
end

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

-- The plan has its own tab after the game's Primary and Secondary tabs, made from the game's
-- tab template. It is not one of the game's tabs: adding a tab to the game's tab bar writes
-- the game's own tab data from the addon's code, and every open of the window then ran the
-- talent window's code tainted. So the game's tab bar never hears of the plan. While the
-- plan shows, the game's selected tab is drawn unselected and clickable, and a click on any
-- game tab returns to the game's tree as any tab change does.

-- The talent frame, once the plan's tab is on it.
local installedFrame
local enteringCalculator = false

-- A game tab drawn selected or not, as TabSystemButtonArtMixin:SetTabSelected draws it, with
-- widget calls only: the tab's own selected state stays the game's.
local function DrawGameTab(tab, selected)
	tab.Left:SetShown(not selected)
	tab.Middle:SetShown(not selected)
	tab.Right:SetShown(not selected)
	tab.LeftActive:SetShown(selected)
	tab.MiddleActive:SetShown(selected)
	tab.RightActive:SetShown(selected)
	tab:SetNormalFontObject(selected and tab.selectedFontObject or tab.unselectedFontObject)
	tab:SetEnabled(not selected and not tab:IsForceDisabled())
end

-- While the plan shows, every game tab is drawn unselected; after, each as the game has it.
local function DrawGameTabs(frame)
	for _, tabID in ipairs(frame:GetTabSet()) do
		local tab = frame.TabSystem:GetTabButton(tabID)
		DrawGameTab(tab, tab.isSelected and not frame.calculatorMode)
	end
end

-- The plan's tab, selected while the plan shows. Turned off while inspecting.
local function DrawPlanTab(frame)
	local tab = frame.calculatorTab
	local inspecting = frame:IsInspecting()
	tab.forceDisabled = inspecting
	tab.errorReason = inspecting and "Not available while inspecting." or nil
	tab:SetTabSelected(frame.calculatorMode == true)
	tab.Text:SetText(inspecting and DISABLED_FONT_COLOR:WrapTextInColorCode(ADDON_TITLE) or ADDON_TITLE)
end

-- The tab's size, as TabSystemButtonMixin:UpdateTabWidth sizes the game's tabs.
local function SizePlanTab(frame, tab)
	local minWidth, maxWidth = frame.TabSystem:GetTabWidthConstraints()
	local width = tab.Left:GetWidth() + tab.Right:GetWidth() + 20
	local textWidth = tab.Text:GetWidth() + (tab.textPadding or 0)
	if width < textWidth then
		width = textWidth + 10
	end
	if maxWidth and width > maxWidth then
		width = maxWidth
		textWidth = width - 10
	end
	if minWidth and width < minWidth then
		width = minWidth
		textWidth = width - 10
	end
	tab.Text:SetWidth(textWidth)
	tab:SetTabWidth(width)
	tab:SetTabHeight(tab:GetHeight())
end

-- The plan's tab, as TabSystemButtonMixin:OnEnter shows a turned-off tab's reason.
local function ShowPlanTabTooltip(tab)
	if tab.errorReason then
		GameTooltip:SetOwner(tab, tab.tooltipAnchor, tab.tooltipAnchorX, tab.tooltipAnchorY)
		GameTooltip_AddErrorLine(GameTooltip, tab.errorReason)
		GameTooltip:Show()
	end
end

local function EnterCalculator(frame)
	if enteringCalculator or frame.calculatorMode or frame:IsInspecting() then
		return
	end
	EnsureWorkingCopy()
	enteringCalculator = true
	frame.calculatorMode = true
	frame.TabSystem:PlayTabSelectSound()
	DrawPlanTab(frame)
	DrawGameTabs(frame)
	-- The tree is read each time the tab opens. Edits reuse what was read.
	RememberFrame(frame)
	ShowPlan(frame)
	ShowPlanControls(frame)
	enteringCalculator = false
end

-- The game's tree back on screen, as the game left it.
local function LeaveCalculator(frame)
	frame.calculatorMode = false
	CoverClientTree(frame, false)
	if frame.calculatorBoard then
		frame.calculatorBoard:Hide()
	end
	HidePlanControls(frame)
	DrawPlanTab(frame)
	DrawGameTabs(frame)
end

local function CreatePlanTab(frame)
	local tab = CreateFrame("Button", nil, frame, "ClassTalentsFrameTabTemplate")
	tab:SetFrameLevel(frame.TabSystem:GetFrameLevel())
	tab:SetPoint("BOTTOMLEFT", frame.TabSystem, "BOTTOMRIGHT", frame.TabSystem.spacing or 0, 0)
	tab:HandleRotation()
	tab:SetText(ADDON_TITLE)
	SizePlanTab(frame, tab)
	tab:SetScript("OnClick", Guard(function()
		EnterCalculator(frame)
	end))
	tab:SetScript("OnEnter", Guard(ShowPlanTabTooltip))
	tab:SetScript("OnLeave", GameTooltip_Hide)
	frame.calculatorTab = tab
	DrawPlanTab(frame)
end

-- Every hook here runs after Blizzard's own function and leaves that function in place,
-- and only reads the game's state or draws the plan. hooksecurefunc keeps the addon's code
-- out of the talent frame's own work, so applying talents and switching specs run untainted.
local function Install(frame)
	if frame.calculatorTab then
		return
	end
	installedFrame = frame
	CreatePlanTab(frame)
	CreatePlanControls(frame)

	-- Any of the game's tab changes on this frame (a click on a game tab, the game switching
	-- specs) runs TabSystemOwnerMixin.SetTab, so this hook sees them all.
	hooksecurefunc(TabSystemOwnerMixin, "SetTab", Guard(function(owner)
		if owner == frame and frame.calculatorMode then
			LeaveCalculator(frame)
		end
	end))
	-- The game draws its selected tab again as it updates the tabs (UpdateTabs, also from
	-- HandlePlayerTalentUpdate).
	hooksecurefunc(frame, "UpdateTabs", Guard(function(self)
		if self.calculatorMode then
			DrawGameTabs(self)
		end
	end))
	-- Inspecting fills this window with another player's talents. The plan steps aside.
	hooksecurefunc(frame, "UpdateInspecting", Guard(function(self)
		if self:IsInspecting() and self.calculatorMode then
			LeaveCalculator(self)
		end
		DrawPlanTab(self)
	end))

	-- These put the character's point totals back on the currency display and tree headers.
	local KeepPlanNumbers = Guard(function(self)
		if ShowingCalculator(self) then
			PaintSpent(self)
		end
	end)
	hooksecurefunc(frame, "RefreshClassCurrencyDisplay", KeepPlanNumbers)
	hooksecurefunc(frame, "RefreshTreeHeaders", KeepPlanNumbers)

	-- The window's search results are up to date whenever it displays them. It does so
	-- at the end of its own updates, after any new arrows were drawn.
	hooksecurefunc(frame, "DisplayFullSearchResults", Guard(function(self)
		if ShowingCalculator(self) then
			ApplyPlanSearch(self)
		end
	end))

	frame:HookScript("OnShow", Guard(function(self)
		if ShowingCalculator(self) then
			ShowPlan(self)
		end
	end))

	-- Color blind mode marks the talents that can take a point, as in the talent
	-- window's own UpdateColorBlindModeUI. Watched with CVAR_UPDATE on the addon's own
	-- frame, not CVarCallbackRegistry: registering there writes the addon's callback into
	-- Blizzard's shared registry, which taints it.
	OnColorBlindMode = function()
		if ShowingCalculator(frame) then
			for nodeID in pairs(ns.structure) do
				PaintNode(frame, nodeID)
			end
		end
	end
	events:RegisterEvent("CVAR_UPDATE")
end

--------------------------------------------------------------------------------
-- Turning off
--------------------------------------------------------------------------------

-- The talent window as the game draws it: the plan's tab gone and the game's tree back.
PutBack = function()
	if installedFrame then
		if installedFrame.calculatorMode then
			LeaveCalculator(installedFrame)
		end
		installedFrame.calculatorTab:Hide()
	end
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- The game's pieces the addon can't do without, checked before it adds anything. If one is
-- missing, the addon says so once and adds nothing.
local function HasFunctions(owner, names)
	if type(owner) ~= "table" then
		return false
	end
	for _, name in ipairs(names) do
		if type(owner[name]) ~= "function" then
			return false
		end
	end
	return true
end

local function HasTables(owner, names)
	if type(owner) ~= "table" then
		return false
	end
	for _, name in ipairs(names) do
		if type(owner[name]) ~= "table" then
			return false
		end
	end
	return true
end

-- At login: what the plan reads the tree with.
local function HasLoginPieces()
	return type(REQUIRED_EDGE) == "number" and type(SUFFICIENT_EDGE) == "number" and type(EXCLUSIVE_EDGE) == "number"
		and HasTables(Enum, { "TraitNodeType", "TraitEdgeVisualStyle" })
		and HasFunctions(C_AddOns, { "IsAddOnLoaded" })
		and HasFunctions(C_SpecializationInfo, { "GetCombatConfigIDForSpecGroup", "GetActiveSpecGroup" })
		and HasFunctions(C_Traits, { "GetGroupDisplayInfoByTreeID", "GetConfigInfo", "GetTreeInfo", "GetTreeNodes", "GetNodeInfo", "GetEntryInfo", "GetDefinitionInfo", "GetSubTreeInfo", "GetConditionInfo" })
		and HasFunctions(C_XMLUtil, { "GetTemplateInfo" })
end

-- The talent frame's functions the plan hooks or calls, and the parts it hides, covers or
-- draws on.
local TALENT_FRAME_FUNCTIONS = {
	"GetTabSet", "IsInspecting", "UpdateTabs", "UpdateInspecting", "RefreshClassCurrencyDisplay",
	"RefreshTreeHeaders", "DisplayFullSearchResults", "EnumerateAllTalentButtons", "GetTalentButtonByNodeID",
	"GetButtonSize", "AnchorGate", "GetConfigID", "GetTalentTreeID", "GetTreeInfo", "GetPanOffset",
	"GetSearchMatchTypeForEntry", "ShouldHideSingleRankNumbers", "GetTraitTreeName", "HookScript",
}
local TALENT_FRAME_PARTS = {
	"TabSystem", "ApplyButton", "UndoButton", "ResetButton", "ActiveSpec", "DisabledOverlay",
	"ClassCurrencyDisplay", "BackgroundBorder", "Background", "ClassBackground", "ButtonsParent",
}
-- The game's templates the plan's pieces are made from.
local TEMPLATES = { "ClassTalentsFrameTabTemplate", "IconButtonTemplate", "ScriptAnimatedModelSceneTemplate", "TalentFrameGateTemplate", "TalentButtonSearchIconTemplate", "UIPanelButtonNoTooltipTemplate", "WowStyle1DropdownTemplate" }

local function HasTalentFramePieces(frame)
	return HasFunctions(frame, TALENT_FRAME_FUNCTIONS) and HasTables(frame, TALENT_FRAME_PARTS)
		and HasFunctions(frame.TabSystem, { "GetTabButton", "GetTabWidthConstraints", "PlayTabSelectSound" })
		and HasTables(frame.ClassCurrencyDisplay, { "UnspentLabel", "Border", "CurrentAmountContainer" })
		and HasTables(frame.ClassCurrencyDisplay.CurrentAmountContainer, { "CurrencyAmount" })
end

-- Once the talent window has loaded: its talent frame, and the game's talent
-- button code the plan's buttons are drawn with.
local function HasTalentWindowPieces()
	local window = PlayerSpellsFrame
	if not (type(window) == "table" and HasTalentFramePieces(window.TalentsFrame)
		and HasFunctions(TabSystemOwnerMixin, { "SetTab" })
		and HasFunctions(TalentButtonArtMixin, { "ApplyVisualState", "UpdateStateBorder", "SetBorderAtlas", "GetSquareEdgeDiameterOffset", "GetChoiceEdgeDiameterOffset", "GetCircleEdgeDiameterOffset" })
		and HasTables(TalentButtonArtMixin, { "ArtSet" })
		and HasFunctions(TalentButtonUtil, { "CalculateIconTextureFromInfo", "SetSpendText", "TranslateNodePositionsToAnchorPositions", "GetStyleForSearchMatchType" })
		and HasTables(TalentButtonUtil, { "BaseVisualState" })
		and HasFunctions(TalentUtil, { "GetTalentName" }) and HasFunctions(ClassTalentUtil, { "GetSpendSoundKitID" })
		and type(TALENT_FRAME_APPLY_BUTTON_TEXT) == "string" and type(TALENT_FRAME_DISCARD_CHANGES_BUTTON_TOOLTIP) == "string"
		and HasTables(_G, { "SOUNDKIT" }) and SOUNDKIT.UI_CLASS_TALENT_NODE_REFUND and SOUNDKIT.UI_CLASS_TALENT_APPLY_CHANGES
		and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON and SOUNDKIT.UI_CLASS_TALENT_APPLY_COMPLETE
		and HasFunctions(ClassTalentUtil, { "GetVisualsForClassID" }) and HasFunctions(C_Texture, { "GetAtlasInfo" })
		and HasFunctions(SpellSearchUtil, { "IsActionBarMatchType" }))
	then
		return false
	end
	for _, template in ipairs(TEMPLATES) do
		if not C_XMLUtil.GetTemplateInfo(template) then
			return false
		end
	end
	return true
end

local function SayGameChanged(what)
	TurnOff("The talent plan is off: " .. what .. " has changed since version " .. VERSION .. ".", "Look for an update.")
end

local function InstallTalentWindow()
	if HasTalentWindowPieces() then
		Install(PlayerSpellsFrame.TalentsFrame)
	else
		SayGameChanged("the talent window")
	end
end

-- The saved plans load with the addon. The talent window loads when the player first
-- opens it, or before the addon when something opened it earlier. Watched here, not with
-- EventUtil.ContinueOnAddOnLoaded: that writes the addon's callback into Blizzard's shared
-- event registry, which taints it.
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", Guard(function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == addonName then
			if not HasLoginPieces() then
				SayGameChanged("the game")
				return
			end
			NormalizeSaved()
			if select(2, C_AddOns.IsAddOnLoaded(TALENT_UI)) then
				InstallTalentWindow()
			end
		elseif ... == TALENT_UI then
			InstallTalentWindow()
		end
	elseif event == "CVAR_UPDATE" then
		if ... == "colorblindMode" then
			OnColorBlindMode()
		end
	end
end))
