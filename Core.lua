local addonName, ns = ...

-- The plan is a level 60 character: one point per level from 10 through 60.
local MAX_LEVEL = 60
local FIRST_TALENT_LEVEL = 10
local PLAN_BUDGET = MAX_LEVEL - FIRST_TALENT_LEVEL + 1
-- Talents whose posY differs by no more than this sit on the same row.
local ROW_TOLERANCE = 0.5

local TALENT_UI = "Blizzard_PlayerSpells"
local REQUIRED_EDGE
local SUFFICIENT_EDGE
local EXCLUSIVE_EDGE

local function ReadEnums()
	REQUIRED_EDGE = Enum.TraitEdgeType.RequiredForAvailability
	SUFFICIENT_EDGE = Enum.TraitEdgeType.SufficientForAvailability
	EXCLUSIVE_EDGE = Enum.TraitEdgeType.MutuallyExclusive
end

ns.ranks = {}
ns.structure = {}
ns.incoming = {}
ns.loadedSlot = nil
ns.slot = nil
ns.planBySlot = {}
ns.budget = PLAN_BUDGET

-- Primary and Secondary use this same frame. Calculator behavior runs only
-- while its own tab is the one selected.
local function ShowingCalculator(frame)
	return frame and frame.calculatorMode and frame.calculatorTabID and frame.GetTab and frame:GetTab() == frame.calculatorTabID
end

local function EnsureSaved()
	if type(TalentCalculatorDB) ~= "table" then
		TalentCalculatorDB = {}
	end
	if type(TalentCalculatorDB.characters) ~= "table" then
		TalentCalculatorDB.characters = {}
	end
end

local function CharacterKey()
	if type(UnitName) ~= "function" then
		return nil
	end
	local name = UnitName("player")
	if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then
		return nil
	end
	local realm
	if type(GetRealmName) == "function" then
		realm = GetRealmName()
	end
	if type(realm) ~= "string" or realm == "" then
		return name
	end
	return name .. "-" .. realm
end

local function ActiveSpecGroup()
	if C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup then
		local group = C_SpecializationInfo.GetActiveSpecGroup()
		if group == 1 or group == 2 then
			return group
		end
	end
	return 1
end

-- Each character has two saved plans, Primary (1) and Secondary (2). They are
-- the calculator's own slots, not the character's spec slots.
local function SaveSlot(group, create)
	EnsureSaved()
	local key = CharacterKey()
	if not key then
		return nil
	end
	local record = TalentCalculatorDB.characters[key]
	if type(record) ~= "table" then
		if not create then
			return nil
		end
		record = {}
		TalentCalculatorDB.characters[key] = record
	end
	local field = group == 2 and "secondary" or "build"
	if create and type(record[field]) ~= "table" then
		record[field] = {}
	end
	if type(record[field]) ~= "table" then
		return nil
	end
	return record[field]
end

-- The saved plan's ranks by node, or nil when that slot has never been saved.
local function SavedRanks(group)
	local saved = SaveSlot(group, false)
	if not saved or type(saved.nodes) ~= "table" then
		return nil
	end
	local ranks = {}
	for _, node in ipairs(saved.nodes) do
		if type(node) == "table" and type(node.nodeID) == "number" and type(node.ranks) == "number" and node.ranks > 0 then
			ranks[node.nodeID] = {
				ranks = node.ranks,
				entryID = type(node.entryID) == "number" and node.entryID or 0,
			}
		end
	end
	return ranks
end

local function ClearRankTable()
	for nodeID in pairs(ns.ranks) do
		ns.ranks[nodeID] = nil
	end
end

local function LoadSavedRanks(group)
	ClearRankTable()
	for nodeID, stored in pairs(SavedRanks(group) or {}) do
		ns.ranks[nodeID] = stored
	end
end

local enteringCalculator = false

local function CopyList(source)
	local copy = {}
	if source then
		for index, value in ipairs(source) do
			copy[index] = value
		end
	end
	return copy
end

local function SharesGroup(left, right)
	if not left or not right or not left[1] or not right[1] then
		return false
	end
	for _, groupID in ipairs(left) do
		for _, otherID in ipairs(right) do
			if groupID == otherID then
				return true
			end
		end
	end
	return false
end

local function TotalSpent()
	local spent = 0
	for _, stored in pairs(ns.ranks) do
		spent = spent + (stored.ranks or 0)
	end
	return spent
end

local function Unspent()
	return ns.budget - TotalSpent()
end

local function HeaderGroupIDs(frame)
	local headers = {}
	local seen = {}
	local function add(groupID)
		if groupID and not seen[groupID] then
			seen[groupID] = true
			headers[#headers + 1] = groupID
		end
	end
	if frame and C_Traits.GetGroupDisplayInfoByTreeID and frame.GetTalentTreeID then
		local treeID = frame:GetTalentTreeID()
		if treeID then
			local ok, infos = pcall(C_Traits.GetGroupDisplayInfoByTreeID, treeID)
			if ok and type(infos) == "table" then
				for _, info in ipairs(infos) do
					add(info.groupID)
				end
			end
		end
	end
	if frame and frame.treeHeaders then
		for _, header in ipairs(frame.treeHeaders) do
			local info = header.displayInfo
			add(info and info.groupID)
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
		for _, groupID in ipairs(structure.groupIDs or {}) do
			if not seenGroup[groupID] then
				seenGroup[groupID] = true
				groupIDs[#groupIDs + 1] = groupID
			end
		end
	end
	if configID and C_Traits.GetGroupCurrencyInfo and #groupIDs > 0 then
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
	if configID and C_Traits.GetNodeCost then
		for nodeID in pairs(ns.structure) do
			local ok, costs = pcall(C_Traits.GetNodeCost, configID, nodeID)
			local groups = {}
			if ok and type(costs) == "table" then
				for _, cost in ipairs(costs) do
					local currencyID = cost.ID or cost.traitCurrencyID
					local groupID = currencyID and ns.currencyGroup[currencyID]
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
		for _, groupID in ipairs(structure.groupIDs or {}) do
			if headerSet[groupID] then
				headerCount = headerCount + 1
				headerID = groupID
			end
		end
		if headerCount == 1 then
			ns.treeOf[nodeID] = headerID
		else
			local hints = {}
			for _, groupID in ipairs(structure.groupIDs or {}) do
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
			for _, groupID in ipairs(structure.groupIDs or {}) do
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
		if not key or key == false then
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
			for _, groupID in ipairs(structure.groupIDs or {}) do
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
		if otherID ~= nodeID and SameTree(nodeID, otherID) then
			local structure = ns.structure[otherID]
			if IsAbove(structure, target) then
				spent = spent + (stored.ranks or 0)
			end
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
	local button = frame and frame.GetTalentButtonByNodeID and frame:GetTalentButtonByNodeID(nodeID)
	if not button then
		return nil
	end
	if button.GetNodeInfo then
		return button:GetNodeInfo()
	end
	return button.nodeInfo
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
			}
		end
	end
end

-- Primary and Secondary are the calculator's own slots. Both read the tree on
-- screen. Before the frame has a config, the active spec's config has the same tree.
local function PlanConfigID(frame)
	local configID = frame and frame:GetConfigID()
	if configID then
		return configID
	end
	return C_SpecializationInfo.GetCombatConfigIDForSpecGroup(ActiveSpecGroup())
end

local function PlanTreeID(frame, configID)
	if configID and C_Traits and C_Traits.GetConfigInfo then
		local info = C_Traits.GetConfigInfo(configID)
		if info and info.treeIDs and info.treeIDs[1] then
			return info.treeIDs[1]
		end
	end
	if frame and frame.GetTalentTreeID then
		return frame:GetTalentTreeID()
	end
	return nil
end

-- The tree's gate list is fixed layout data. The frame's own gate widgets are not
-- read: the game shows those only while the character has not met them.
local function TreeGates(frame, configID)
	local treeID = PlanTreeID(frame, configID)
	if configID and treeID and C_Traits.GetTreeInfo then
		local info = C_Traits.GetTreeInfo(configID, treeID)
		if info and info.gates and info.gates[1] then
			return info.gates
		end
	end
	if frame and frame.GetConfigID and frame:GetConfigID() == configID and frame.GetTreeInfo then
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
local POINTS_PER_ROW = 5

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

	-- The gate tooltip uses the wording of the nearest tree gate on or above that row.
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

local function RememberFrame(frame)
	local configID = PlanConfigID(frame)
	local treeID = PlanTreeID(frame, configID)
	local nodeIDs = treeID and C_Traits.GetTreeNodes and C_Traits.GetTreeNodes(treeID)
	if configID and nodeIDs and C_Traits.GetNodeInfo then
		local saved = ns.structure
		ns.structure = {}
		for _, nodeID in ipairs(nodeIDs) do
			local ok, info = pcall(C_Traits.GetNodeInfo, configID, nodeID)
			if not ok then
				info = nil
			end
			-- The button is the same talent the player is looking at, for either spec.
			info = CombineNode(info, ButtonNode(frame, nodeID))
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
	if not frame.EnumerateAllTalentButtons then
		return
	end
	for button in frame:EnumerateAllTalentButtons() do
		RememberNode(button.GetNodeInfo and button:GetNodeInfo() or button.nodeInfo)
	end
	RebuildIncoming()
	ApplyRowRequirements(frame)
end

local function SourceRank(nodeID)
	local stored = ns.ranks[nodeID]
	return stored and stored.ranks or 0
end

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

local function GateOpen(nodeID)
	local structure = ns.structure[nodeID]
	if not structure then
		return true
	end
	local required = structure.requiredSpent or 0
	if required > 0 and SpentAbove(nodeID) < required then
		return false
	end
	return true
end

local function CanAddRank(nodeID)
	local structure = ns.structure[nodeID]
	if not structure or structure.maxRanks <= 0 then
		return false
	end
	if SourceRank(nodeID) >= structure.maxRanks then
		return false
	end
	if Unspent() < 1 then
		return false
	end
	if not GateOpen(nodeID) then
		return false
	end
	if not EdgesAllow(nodeID) then
		return false
	end
	return true
end

local function RankHolds(nodeID)
	local stored = ns.ranks[nodeID]
	if not stored or (stored.ranks or 0) <= 0 or not ns.structure[nodeID] then
		return false
	end
	return EdgesAllow(nodeID) and GateOpen(nodeID)
end

-- The loaded selection only. Every talent that would still have points, in all
-- three trees, has to stay legal. The other selection is a different rank table.
local function SelectionStaysLegal(nodeID, ranks)
	local stored = ns.ranks[nodeID]
	local previousRanks = stored and stored.ranks or 0
	local entryID = stored and stored.entryID or 0
	if ranks > 0 then
		ns.ranks[nodeID] = { ranks = ranks, entryID = entryID }
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
	if previousRanks > 0 then
		ns.ranks[nodeID] = stored
	else
		ns.ranks[nodeID] = nil
	end
	return allowed
end

local function MarkOutgoing(affected, nodeID)
	if not nodeID then
		return
	end
	affected[nodeID] = true
	local structure = ns.structure[nodeID]
	if not structure or not structure.edges then
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

-- The first point comes at level 10, then one point each level up to 60.
-- Zero points spent does not require level 10.
local function LevelForSpent(spent)
	if spent < 1 then
		return 1
	end
	return math.min(MAX_LEVEL, FIRST_TALENT_LEVEL - 1 + spent)
end

local function LevelLabel(frame)
	local display = frame.ClassCurrencyDisplay
	local unspent = display and display.UnspentLabel
	if not display or not unspent then
		return nil
	end
	if not display.calculatorLevelText then
		local text = display:CreateFontString(nil, "ARTWORK", "SystemFont_Shadow_Med1")
		text:SetJustifyH("RIGHT")
		text:SetPoint("RIGHT", unspent, "LEFT", -20, 0)
		text:Hide()
		display.calculatorLevelText = text
	end
	return display.calculatorLevelText
end

local function PlanMatchesSaved()
	local savedRanks = SavedRanks(ns.slot or 1) or {}
	for nodeID, stored in pairs(ns.ranks) do
		local ranks = stored.ranks or 0
		if ranks > 0 then
			local saved = savedRanks[nodeID]
			if not saved or saved.ranks ~= ranks or saved.entryID ~= (stored.entryID or 0) then
				return false
			end
			savedRanks[nodeID] = nil
		end
	end
	return next(savedRanks) == nil
end

local function HasSavedBuild()
	return SavedRanks(ns.slot or 1) ~= nil
end

local function UpdateSaveButton(frame)
	if not frame then
		return
	end
	local matches = PlanMatchesSaved()
	local save = frame.calculatorSaveButton
	if save then
		if matches then
			save:Disable()
		else
			save:Enable()
		end
	end
	local load = frame.calculatorLoadButton
	if load then
		if HasSavedBuild() and not matches then
			load:Enable()
		else
			load:Disable()
		end
	end
	local clear = frame.calculatorClearButton
	if clear then
		local hasPoints = false
		for _, stored in pairs(ns.ranks) do
			if (stored.ranks or 0) > 0 then
				hasPoints = true
				break
			end
		end
		if hasPoints then
			clear:Enable()
		else
			clear:Disable()
		end
	end
end

local function PlanAmountText(frame)
	local display = frame.ClassCurrencyDisplay
	local container = display and display.CurrentAmountContainer
	local amount = container and container.CurrencyAmount
	if not display or not container or not amount then
		return nil, nil
	end
	if not display.calculatorAmountText then
		local text = container:CreateFontString(nil, "OVERLAY", "Game32Font_Shadow2")
		text:SetPoint("CENTER", container, "CENTER", 0, 0)
		text:SetJustifyH("CENTER")
		text:SetJustifyV("MIDDLE")
		text:Hide()
		display.calculatorAmountText = text
	end
	return display.calculatorAmountText, amount
end

local function HeaderSpentText(header)
	if not header.Text then
		return nil
	end
	if not header.calculatorSpentText then
		local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetPoint("CENTER", header.Text, "CENTER", 0, 0)
		text:SetJustifyH("CENTER")
		text:SetJustifyV("MIDDLE")
		text:Hide()
		header.calculatorSpentText = text
	end
	return header.calculatorSpentText
end

local function ShowCharacterTalentNumbers(frame)
	local display = frame.ClassCurrencyDisplay
	if display and display.calculatorAmountText then
		display.calculatorAmountText:Hide()
	end
	local amount = display and display.CurrentAmountContainer and display.CurrentAmountContainer.CurrencyAmount
	if amount then
		amount:Show()
	end
	for _, header in ipairs(frame.treeHeaders or {}) do
		if header.calculatorSpentText then
			header.calculatorSpentText:Hide()
		end
		if header.Text then
			header.Text:Show()
		end
	end
end

local function PaintSpent(frame)
	local planAmount, realAmount = PlanAmountText(frame)
	if planAmount and realAmount then
		local unspent = math.max(0, Unspent())
		planAmount:SetText(unspent)
		if unspent > 0 and GREEN_FONT_COLOR then
			planAmount:SetTextColor(GREEN_FONT_COLOR:GetRGBA())
		elseif GRAY_FONT_COLOR then
			planAmount:SetTextColor(GRAY_FONT_COLOR:GetRGBA())
		end
		planAmount:Show()
		realAmount:Hide()
	end
	local levelText = LevelLabel(frame)
	if levelText then
		levelText:SetText("Level required: " .. LevelForSpent(TotalSpent()))
		levelText:Show()
	end
	UpdateSaveButton(frame)
	if not frame.treeHeaders then
		return
	end
	for _, header in ipairs(frame.treeHeaders) do
		local groupID = header.displayInfo and header.displayInfo.groupID
		if groupID and header.Text then
			local spent = 0
			for nodeID, stored in pairs(ns.ranks) do
				local structure = ns.structure[nodeID]
				local knownTree = ns.treeOf and ns.treeOf[nodeID]
				if knownTree then
					-- The same tree the row gates count this talent in.
					if knownTree == groupID then
						spent = spent + (stored.ranks or 0)
					end
				elseif structure then
					local counts = false
					for _, headerGroup in ipairs(structure.groupIDs or {}) do
						local mapped = ns.groupTree and ns.groupTree[headerGroup]
						if headerGroup == groupID or mapped == groupID then
							counts = true
							break
						end
					end
					if not counts and ns.currencyGroupsOf then
						for _, headerGroup in ipairs(ns.currencyGroupsOf[nodeID] or {}) do
							if headerGroup == groupID then
								counts = true
								break
							end
						end
					end
					if counts then
						spent = spent + (stored.ranks or 0)
					end
				end
			end
			local planText = HeaderSpentText(header)
			if planText then
				planText:SetText(spent)
				planText:Show()
				header.Text:Hide()
			end
		end
	end
end

local function EntryCap(frame, entryID)
	if not frame or not frame.GetAndCacheEntryInfo or not entryID then
		return 1
	end
	local info = frame:GetAndCacheEntryInfo(entryID)
	local cap = info and info.maxRanks or 1
	if cap < 1 then
		return 1
	end
	return cap
end

local function ResolvePlanEntries(frame, nodeID, nodeInfo)
	local ranks = SourceRank(nodeID)
	local structure = ns.structure[nodeID]
	local maxRanks = structure and structure.maxRanks or nodeInfo.maxRanks or 0
	if maxRanks > 0 and ranks > maxRanks then
		ranks = maxRanks
	end
	local stored = ns.ranks[nodeID]
	local entryIDs = structure and structure.entryIDs
	if not entryIDs or not entryIDs[1] then
		entryIDs = nodeInfo.entryIDs
	end
	local nodeType = structure and structure.nodeType or nodeInfo.type
	local tiered = Enum.TraitNodeType and nodeType == Enum.TraitNodeType.Tiered
	local currentID, currentRank, nextID, nextRank

	if tiered and entryIDs and entryIDs[1] then
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
		if not currentID and entryIDs[1] then
			currentID, currentRank = entryIDs[1], 0
		end
	else
		if stored and stored.entryID and stored.entryID > 0 then
			currentID = stored.entryID
		elseif nodeInfo.activeEntry and nodeInfo.activeEntry.entryID then
			currentID = nodeInfo.activeEntry.entryID
		elseif nodeInfo.nextEntry and nodeInfo.nextEntry.entryID then
			currentID = nodeInfo.nextEntry.entryID
		elseif entryIDs then
			currentID = entryIDs[1]
		end
		currentRank = ranks
		if currentID and maxRanks > ranks then
			nextID, nextRank = currentID, ranks + 1
		end
	end

	return ranks, currentID, currentRank, nextID, nextRank
end

local function TreeName(frame, structure)
	if not frame or not structure or not structure.groupIDs then
		return nil
	end
	for _, header in ipairs(frame.treeHeaders or {}) do
		local info = header.displayInfo
		local name = info and info.displayName
		if info and name and name ~= "" then
			for _, groupID in ipairs(structure.groupIDs) do
				if groupID == info.groupID then
					return name
				end
			end
		end
	end
	return nil
end

local function PointsLeft(nodeID)
	local structure = nodeID and ns.structure[nodeID]
	local total = structure and structure.requiredSpent
	if not total or total <= 0 then
		return nil
	end
	local left = total - SpentAbove(nodeID)
	if left < 0 then
		left = 0
	end
	return left
end

-- ClassTalentsFrameMixin:GetTraitTreeName supplies the "Fire Talents" name the client formats in.
local function TraitTreeName(frame, nodeID)
	local structure = nodeID and ns.structure[nodeID]
	local groupIDs = structure and structure.groupIDs
	if frame and frame.GetTraitTreeName and frame.GetTalentTreeID then
		local name = frame:GetTraitTreeName(frame:GetTalentTreeID(), groupIDs)
		if name and name ~= "" then
			return name
		end
	end
	return TreeName(frame, structure) or ""
end

-- Same sentence as C_Traits.GetConditionInfo: tooltipFormat filled with the
-- points still missing in this plan, then the client's red color.
local function ClientGateText(frame, nodeID, condInfo)
	local left = PointsLeft(nodeID)
	if not left or left <= 0 then
		return nil
	end
	local treeName = TraitTreeName(frame, nodeID)
	local formatString = condInfo and condInfo.tooltipFormat
	local line
	if type(formatString) == "string" and string.find(formatString, "%%") then
		local ok, formatted = pcall(string.format, formatString, left, treeName)
		if not ok then
			ok, formatted = pcall(string.format, formatString, left)
		end
		if ok then
			line = formatted
		end
	end
	if not line and TALENT_FRAME_GATE_TOOLTIP_FORMAT then
		local ok, formatted = pcall(string.format, TALENT_FRAME_GATE_TOOLTIP_FORMAT, left)
		if ok then
			line = formatted
		end
	end
	if line and C_StringUtil and C_StringUtil.StripHyperlinks then
		line = C_StringUtil.StripHyperlinks(line)
	end
	return line
end

local function ColorGateLine(line)
	if line and RED_FONT_COLOR and RED_FONT_COLOR.WrapTextInColorCode then
		return RED_FONT_COLOR:WrapTextInColorCode(line)
	end
	return line
end

local ChangeRank
local ChooseEntry
local RefundNode

local function AddGateLine(tooltip, line)
	if not line or line == "" then
		return
	end
	if GameTooltip_AddErrorLine then
		GameTooltip_AddErrorLine(tooltip, line)
	elseif tooltip and tooltip.AddLine then
		tooltip:AddLine(ColorGateLine(line))
	end
end

local function GateCondInfo(frame, nodeID)
	local structure = ns.structure[nodeID]
	if not structure or not frame or not frame.GetAndCacheCondInfo then
		return nil
	end
	local ids = {}
	if structure.gateConditionID then
		ids[#ids + 1] = structure.gateConditionID
	end
	for _, condID in ipairs(structure.conditionIDs or {}) do
		ids[#ids + 1] = condID
	end
	for _, condID in ipairs(ids) do
		local info = frame:GetAndCacheCondInfo(condID)
		if info and type(info.tooltipFormat) == "string" and string.find(info.tooltipFormat, "%", 1, true) then
			return info
		end
	end
	return nil
end

-- Same order as TalentUtil.GetTalentName: the definition's override, then the spell name.
local function TalentDisplayName(definition, subTree)
	local spellID = definition and definition.spellID
	local name
	if definition and TalentUtil and TalentUtil.GetTalentName then
		name = TalentUtil.GetTalentName(definition.overrideName, spellID)
	end
	if (type(name) ~= "string" or name == "") and definition then
		if type(definition.overrideName) == "string" and definition.overrideName ~= "" then
			name = definition.overrideName
		elseif spellID and C_Spell and C_Spell.GetSpellName then
			name = C_Spell.GetSpellName(spellID)
		end
	end
	if (type(name) ~= "string" or name == "") and subTree and type(subTree.name) == "string" and subTree.name ~= "" then
		name = subTree.name
	end
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return name
end

local function EntryVisual(frame, entryID)
	local configID = frame and frame.GetConfigID and frame:GetConfigID()
	if not configID or not entryID or not C_Traits.GetEntryInfo then
		return { entryID = entryID }
	end
	local entry = C_Traits.GetEntryInfo(configID, entryID)
	if not entry then
		return { entryID = entryID }
	end
	-- GetDefinitionInfo takes the definition id only. The config id is not an argument.
	local definition
	if entry.definitionID and C_Traits.GetDefinitionInfo then
		definition = C_Traits.GetDefinitionInfo(entry.definitionID)
	end
	local subTree
	if entry.subTreeID and C_Traits.GetSubTreeInfo then
		subTree = C_Traits.GetSubTreeInfo(configID, entry.subTreeID)
	end
	local spellID = definition and definition.spellID
	return {
		entryID = entryID,
		name = TalentDisplayName(definition, subTree),
		spellID = spellID,
		definition = definition,
		subTree = subTree,
	}
end

local function ApplyIcon(texture, visual)
	if not texture or not visual then
		return
	end
	local icon, isAtlas
	if TalentButtonUtil and TalentButtonUtil.CalculateIconTextureFromInfo then
		icon, isAtlas = TalentButtonUtil.CalculateIconTextureFromInfo(visual.definition, visual.subTree)
	elseif visual.definition and visual.definition.overrideIcon then
		icon = visual.definition.overrideIcon
	elseif visual.spellID and C_Spell and C_Spell.GetSpellTexture then
		icon = select(2, C_Spell.GetSpellTexture(visual.spellID))
	end
	if isAtlas and icon and texture.SetAtlas then
		texture:SetAtlas(icon)
	elseif icon and texture.SetTexture then
		texture:SetTexture(icon)
	end
	if icon or not visual.spellID or not Spell or not Spell.CreateFromSpellID then
		return
	end
	local spell = Spell:CreateFromSpellID(visual.spellID)
	if not spell or spell:IsSpellDataCached() or not spell.ContinueWithCancelOnSpellLoad then
		return
	end
	spell:ContinueWithCancelOnSpellLoad(function()
		ApplyIcon(texture, visual)
	end)
end

local function PlanSpendText(frame, nodeID)
	local ranks = SourceRank(nodeID)
	local structure = ns.structure[nodeID]
	local maxRanks = structure and structure.maxRanks or 0
	if ranks < 1 and not CanAddRank(nodeID) then
		return ""
	end
	if ranks <= 1 and maxRanks == 1 and frame.ShouldHideSingleRankNumbers and frame:ShouldHideSingleRankNumbers() then
		return ""
	end
	if ranks > 0 or CanAddRank(nodeID) then
		return tostring(ranks)
	end
	return ""
end

local function PlanRefundInvalid(nodeID)
	if SourceRank(nodeID) <= 0 then
		return false, nil
	end
	if not EdgesAllow(nodeID) then
		return true, TALENT_BUTTON_TOOLTIP_REFUND_INVALID_LINKS_ERROR
	end
	return false, nil
end

local function ShowNodeTooltip(button)
	local nodeButton = button.planNode or button
	local frame = nodeButton.calculatorFrame
	local nodeID = nodeButton.calculatorNodeID
	local structure = nodeID and ns.structure[nodeID]
	if not frame or not structure or not GameTooltip then
		return
	end
	local ranks, currentID, currentRank, nextID, nextRank = ResolvePlanEntries(frame, nodeID, {
		maxRanks = structure.maxRanks,
		type = structure.nodeType,
		entryIDs = structure.entryIDs,
	})
	if button.entryID and button.entryID > 0 then
		currentID = button.entryID
		currentRank = (ns.ranks[nodeID] and ns.ranks[nodeID].entryID == button.entryID) and ranks or 0
	end
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	local visual = button.entryVisual
	local definition = visual and visual.definition
	local spellID = visual and visual.spellID
	local name = TalentDisplayName(definition, visual and visual.subTree) or ""
	if name ~= "" and GameTooltip_SetTitle then
		GameTooltip_SetTitle(GameTooltip, name)
	elseif name ~= "" and GameTooltip.SetText then
		GameTooltip:SetText(name)
	end
	if TALENT_BUTTON_TOOLTIP_RANK_FORMAT then
		local rankShown = ranks
		if HIGHLIGHT_FONT_COLOR and HIGHLIGHT_FONT_COLOR.WrapTextInColorCode then
			rankShown = HIGHLIGHT_FONT_COLOR:WrapTextInColorCode(ranks)
		end
		local rankLine = TALENT_BUTTON_TOOLTIP_RANK_FORMAT:format(rankShown, structure.maxRanks or 0)
		if GameTooltip_AddHighlightLine then
			GameTooltip_AddHighlightLine(GameTooltip, rankLine)
		elseif GameTooltip.AddLine then
			GameTooltip:AddLine(rankLine)
		end
	end
	local subtext
	if definition and TalentUtil and TalentUtil.GetTalentSubtext then
		subtext = TalentUtil.GetTalentSubtext(definition.overrideSubtext, spellID)
	end
	if subtext and subtext ~= "" and GameTooltip_AddColoredLine and DISABLED_FONT_COLOR then
		if GameTooltip_AddBlankLineToTooltip then
			GameTooltip_AddBlankLineToTooltip(GameTooltip)
		end
		GameTooltip_AddColoredLine(GameTooltip, subtext, DISABLED_FONT_COLOR)
	end
	-- AppendInfo is how the talent frame fills the spell text once that data has loaded.
	if currentID and GameTooltip.AppendInfo then
		if GameTooltip_AddBlankLineToTooltip then
			GameTooltip_AddBlankLineToTooltip(GameTooltip)
		end
		GameTooltip:AppendInfo("GetTraitEntry", currentID, currentRank or 0)
	elseif definition and TalentUtil and TalentUtil.GetTalentDescription and GameTooltip.AddLine then
		local description = TalentUtil.GetTalentDescription(definition.overrideDescription, spellID)
		if description and description ~= "" then
			GameTooltip:AddLine(description, nil, nil, nil, true)
		end
	end
	if nextID and ranks > 0 and GameTooltip.AppendInfo then
		if GameTooltip_AddBlankLineToTooltip then
			GameTooltip_AddBlankLineToTooltip(GameTooltip)
		end
		if TALENT_BUTTON_TOOLTIP_NEXT_RANK and GameTooltip_AddHighlightLine then
			GameTooltip_AddHighlightLine(GameTooltip, TALENT_BUTTON_TOOLTIP_NEXT_RANK)
		end
		GameTooltip:AppendInfo("GetTraitEntry", nextID, nextRank or 0)
	end
	local left = PointsLeft(nodeID)
	if left and left > 0 then
		AddGateLine(GameTooltip, ClientGateText(frame, nodeID, GateCondInfo(frame, nodeID)))
	end
	local invalid, reason = PlanRefundInvalid(nodeID)
	if invalid and reason then
		AddGateLine(GameTooltip, reason)
	end
	if GameTooltip.Show then
		GameTooltip:Show()
	end
end

local function ShowGateTooltip(gate)
	local frame = gate.calculatorFrame
	local nodeID = gate.calculatorNodeID
	local left = PointsLeft(nodeID)
	if not frame or not left or left <= 0 or not GameTooltip then
		return
	end
	GameTooltip:SetOwner(gate, "ANCHOR_LEFT", 4, -4)
	AddGateLine(GameTooltip, ClientGateText(frame, nodeID, GateCondInfo(frame, nodeID)))
	if GameTooltip.Show then
		GameTooltip:Show()
	end
end

local function NodePoint(frame, posX, posY)
	local panX, panY = 0, 0
	if frame.GetPanOffset then
		local x, y = frame:GetPanOffset()
		panX, panY = x or 0, y or 0
	end
	if TalentButtonUtil and TalentButtonUtil.TranslateNodePositionsToAnchorPositions then
		return TalentButtonUtil.TranslateNodePositionsToAnchorPositions(posX or 0, posY or 0, panX, panY)
	end
	return 0, 0
end

local function HideWidget(frame, widget)
	if not widget or not widget.Hide or not widget.IsShown then
		return
	end
	frame.calculatorHiddenWidgets = frame.calculatorHiddenWidgets or {}
	if frame.calculatorHiddenWidgets[widget] == nil then
		frame.calculatorHiddenWidgets[widget] = widget:IsShown() and true or false
	end
	if widget.HookScript and not widget.calculatorKeepHidden then
		widget.calculatorKeepHidden = true
		widget:HookScript("OnShow", function(self)
			local owner = self.GetTalentFrame and self:GetTalentFrame() or frame
			if ShowingCalculator(owner) then
				self:Hide()
			end
		end)
	end
	widget:Hide()
	if widget.EnableMouse then
		widget:EnableMouse(false)
	end
end

local function HideClientTree(frame)
	frame.calculatorTreeHidden = true
	if frame.EnumerateAllTalentButtons then
		for button in frame:EnumerateAllTalentButtons() do
			HideWidget(frame, button)
		end
	end
	if frame.edgePool and frame.edgePool.EnumerateActive then
		for edge in frame.edgePool:EnumerateActive() do
			HideWidget(frame, edge)
		end
	end
	if frame.gatePool and frame.gatePool.EnumerateActive then
		for gate in frame.gatePool:EnumerateActive() do
			HideWidget(frame, gate)
		end
	end
	local displays = frame.talentDisplayFramePool or frame.talentDislayFramePool
	if displays and displays.EnumerateActive then
		for display in displays:EnumerateActive() do
			HideWidget(frame, display)
		end
	end
end

local function ShowClientTree(frame)
	frame.calculatorTreeHidden = false
	local hidden = frame.calculatorHiddenWidgets
	frame.calculatorHiddenWidgets = nil
	if not hidden then
		return
	end
	for widget, wasShown in pairs(hidden) do
		if widget.SetShown then
			widget:SetShown(wasShown and true or false)
		end
		if wasShown and widget.EnableMouse then
			widget:EnableMouse(true)
		end
	end
end

local function AttachPlanMethods(button, frame, nodeID)
	button.calculatorFrame = frame
	button.calculatorNodeID = nodeID
	function button:GetNodeID()
		return nodeID
	end
	function button:GetTalentFrame()
		return frame
	end
	function button:CanPurchaseRank()
		return CanAddRank(nodeID)
	end
	function button:CanAfford()
		return Unspent() >= 1
	end
	function button:HasProgress()
		return SourceRank(nodeID) > 0
	end
	function button:IsMaxed()
		return SourceMaxed(nodeID)
	end
	function button:IsGated()
		return ns.structure[nodeID] and not GateOpen(nodeID) or false
	end
	function button:IsLocked()
		return ns.structure[nodeID] and not EdgesAllow(nodeID) or false
	end
	function button:IsDisplayError()
		if SourceRank(nodeID) <= 0 then
			return false
		end
		return not (EdgesAllow(nodeID) and GateOpen(nodeID))
	end
	function button:GetSpendText()
		return PlanSpendText(frame, nodeID)
	end
	function button:IsRefundInvalid()
		return PlanRefundInvalid(nodeID)
	end
	function button:Choose(entryID)
		ChooseEntry(frame, nodeID, entryID)
	end
	function button:RefundAll()
		RefundNode(frame, nodeID)
	end
end

local function NodeClick(frame, nodeID, mouseButton, entryID)
	if mouseButton == "RightButton" then
		ChangeRank(frame, nodeID, -1)
		return
	end
	if IsModifiedClick and IsModifiedClick("CHATLINK") then
		return
	end
	local structure = ns.structure[nodeID]
	local selection = Enum.TraitNodeType and structure and structure.nodeType == Enum.TraitNodeType.Selection
	if selection or entryID then
		local chosen = entryID
		if not chosen or chosen <= 0 then
			local stored = ns.ranks[nodeID]
			chosen = stored and stored.entryID or 0
			if chosen <= 0 and structure and structure.entryIDs then
				chosen = structure.entryIDs[1]
			end
		end
		ChooseEntry(frame, nodeID, chosen)
		return
	end
	ChangeRank(frame, nodeID, 1)
end

local function ArtSet(frame, nodeID)
	local live = frame and frame.GetTalentButtonByNodeID and frame:GetTalentButtonByNodeID(nodeID)
	if live and live.artSet then
		return live.artSet
	end
	local sets = TalentButtonArtMixin and TalentButtonArtMixin.ArtSet
	if not sets then
		return nil
	end
	local entryType = live and live.entryInfo and live.entryInfo.type
	if not entryType and live and live.GetEntryInfo then
		local info = live:GetEntryInfo()
		entryType = info and info.type
	end
	local types = Enum and Enum.TraitNodeEntryType
	if types and entryType == types.SpendCircle then
		return sets.Circle
	end
	if types and entryType == types.SpendCapstoneCircle then
		return sets.CapstoneCircle or sets.Circle
	end
	if types and entryType == types.SpendCapstoneSquare then
		return sets.CapstoneSquare or sets.Square
	end
	if types and entryType == types.SpendSmallCircle then
		return sets.LegionSmallCircle or sets.Circle
	end
	local structure = ns.structure[nodeID]
	local selection = Enum.TraitNodeType and structure and structure.nodeType == Enum.TraitNodeType.Selection
	if selection and sets.Choice then
		return sets.Choice
	end
	return sets.Square
end

local function NodeLook(nodeID, entryID)
	local ranks = SourceRank(nodeID)
	local stored = ns.ranks[nodeID]
	local selected = stored and stored.entryID or 0
	if PlanRefundInvalid(nodeID) then
		return "refund"
	end
	if entryID and ranks > 0 and entryID ~= selected then
		return "disabled"
	end
	if not GateOpen(nodeID) then
		return "gated"
	end
	if not EdgesAllow(nodeID) then
		return "locked"
	end
	if SourceMaxed(nodeID) then
		return "maxed"
	end
	if CanAddRank(nodeID) and ranks < 1 then
		return "selectable"
	end
	if ranks > 0 then
		return "normal"
	end
	return "disabled"
end

local function BorderAtlas(frame, nodeID, entryID)
	local art = ArtSet(frame, nodeID)
	if not art then
		return nil
	end
	local look = NodeLook(nodeID, entryID)
	if look == "refund" then
		return art.refundInvalid
	end
	if look == "gated" then
		return art.locked or art.disabled
	end
	if look == "selectable" then
		return art.selectable
	end
	if look == "maxed" then
		return art.maxed
	end
	if look == "normal" then
		return art.normal
	end
	return art.disabled
end

local function ApplyBorder(texture, atlas)
	if not texture or not atlas or not texture.SetAtlas then
		return
	end
	texture:ClearAllPoints()
	texture:SetPoint("CENTER")
	texture:SetAtlas(atlas, true)
end

-- TalentButtonArtMixin:OnLoad centers this drop shadow and sizes it from the atlas.
local function ApplyShadow(texture, atlas)
	if not texture then
		return
	end
	if not atlas or atlas == "" or not texture.SetAtlas then
		texture:Hide()
		return
	end
	texture:ClearAllPoints()
	texture:SetPoint("CENTER")
	local useAtlasSize = true
	if TextureKitConstants and TextureKitConstants.UseAtlasSize ~= nil then
		useAtlasSize = TextureKitConstants.UseAtlasSize
	end
	texture:SetAtlas(atlas, useAtlasSize)
	texture:Show()
end

local function BindEdgeOffset(button, frame, nodeID)
	button.GetEdgeDiameterOffset = nil
	local live = frame and frame.GetTalentButtonByNodeID and frame:GetTalentButtonByNodeID(nodeID)
	if live and live.GetEdgeDiameterOffset then
		button.GetEdgeDiameterOffset = function(_, angle)
			return live:GetEdgeDiameterOffset(angle)
		end
		return
	end
	local mixin = TalentButtonArtMixin
	local art = ArtSet(frame, nodeID)
	local sets = mixin and mixin.ArtSet
	if not mixin or not art or not sets then
		return
	end
	if art == sets.Square or art == sets.CapstoneSquare or art == sets.LegacySquare or art == sets.LegionSquare or art == sets.LargeSquare then
		button.GetEdgeDiameterOffset = mixin.GetSquareEdgeDiameterOffset
	elseif art == sets.Choice or art == sets.LegionChoice then
		button.GetEdgeDiameterOffset = mixin.GetChoiceEdgeDiameterOffset
	else
		button.GetEdgeDiameterOffset = mixin.GetCircleEdgeDiameterOffset
	end
end

local function ApplyShade(icon, shade, look)
	local dimmed = look == "gated" or look == "locked" or look == "disabled"
	local refund = look == "refund"
	if icon and icon.SetDesaturated then
		icon:SetDesaturated(dimmed)
	end
	if icon and icon.SetVertexColor then
		if refund and DIM_RED_FONT_COLOR then
			icon:SetVertexColor(DIM_RED_FONT_COLOR:GetRGBA())
		elseif WHITE_FONT_COLOR then
			icon:SetVertexColor(WHITE_FONT_COLOR:GetRGBA())
		else
			icon:SetVertexColor(1, 1, 1, 1)
		end
	end
	if not shade then
		return
	end
	shade:SetShown(dimmed or refund)
	if dimmed or refund then
		shade:SetAlpha(look == "gated" and 0.7 or (refund and 0.3 or 0.25))
	end
end

local function ButtonSize(frame)
	if frame.GetButtonSize then
		local size = frame:GetButtonSize()
		if type(size) == "number" and size > 0 then
			return size
		end
	end
	if type(frame.buttonSize) == "number" and frame.buttonSize > 0 then
		return frame.buttonSize
	end
	local info = frame.GetTreeInfo and frame:GetTreeInfo()
	if info and type(info.buttonSize) == "number" and info.buttonSize > 0 then
		return info.buttonSize
	end
	return nil
end

local function LiveButton(frame, nodeID)
	if frame and frame.GetTalentButtonByNodeID then
		return frame:GetTalentButtonByNodeID(nodeID)
	end
	return nil
end

local function MatchIcon(icon, shade, live)
	local source = live and live.Icon
	if not icon or not source or not source.GetSize then
		return
	end
	local width, height = source:GetSize()
	if not width or width <= 0 or not height or height <= 0 then
		return
	end
	icon:ClearAllPoints()
	icon:SetSize(width, height)
	icon:SetPoint("CENTER")
	if shade then
		shade:ClearAllPoints()
		shade:SetSize(width, height)
		shade:SetPoint("CENTER")
	end
end

local function MatchSpendText(text, live)
	local source = live and live.SpendText
	if not text or not source or not source.GetFont or not text.SetFont then
		return
	end
	local font, size, flags = source:GetFont()
	if font and size and size > 0 then
		text:SetFont(font, size, flags)
	end
	if source.GetPoint and text.ClearAllPoints then
		local point, _, relativePoint, x, y = source:GetPoint(1)
		if point then
			text:ClearAllPoints()
			text:SetPoint(point, text:GetParent(), relativePoint or point, x or 0, y or 0)
		end
	end
	if source.GetJustifyH and text.SetJustifyH then
		local justify = source:GetJustifyH()
		if justify then
			text:SetJustifyH(justify)
		end
	end
end

-- NameMatch atlas from TalentButtonUtil.GetStyleForSearchMatchType, same mark the talent button shows.
local function SearchMatchAtlas()
	local matchType = SpellSearchUtil and SpellSearchUtil.MatchType and SpellSearchUtil.MatchType.NameMatch
	if matchType and TalentButtonUtil and TalentButtonUtil.GetStyleForSearchMatchType then
		local style = TalentButtonUtil.GetStyleForSearchMatchType(matchType)
		if type(style) == "table" and type(style.icon) == "string" and style.icon ~= "" then
			return style.icon
		end
	end
	return "talents-search-match"
end

-- The layers every plan button draws, sized like the talent button it stands for.
local function CreatePlanButton(frame, board, nodeID)
	local button = CreateFrame("Button", nil, board)
	local size = ButtonSize(frame)
	if size then
		button:SetSize(size, size)
	end
	button:RegisterForClicks("LeftButtonDown", "RightButtonDown")
	if GameTooltip_Hide then
		button:SetScript("OnLeave", GameTooltip_Hide)
	end
	local shadow = button:CreateTexture(nil, "BACKGROUND")
	shadow:SetPoint("CENTER")
	shadow:Hide()
	button.Shadow = shadow
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints(button)
	button.icon = icon
	local shade = button:CreateTexture(nil, "ARTWORK", nil, 1)
	shade:SetAllPoints(icon)
	if shade.SetColorTexture then
		shade:SetColorTexture(0, 0, 0, 1)
	end
	shade:Hide()
	button.shade = shade
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetAllPoints(button)
	button.border = border
	MatchIcon(icon, shade, LiveButton(frame, nodeID))
	return button
end

local function CreateNodeButton(frame, board, nodeID)
	local button = CreatePlanButton(frame, board, nodeID)
	AttachPlanMethods(button, frame, nodeID)
	button:SetScript("OnClick", function(_, mouseButton)
		NodeClick(frame, nodeID, mouseButton)
	end)
	button:SetScript("OnEnter", ShowNodeTooltip)
	-- Same corner as the talent button's SearchIcon: centered on the icon's top right.
	local searchIcon = button:CreateTexture(nil, "OVERLAY")
	searchIcon:SetPoint("CENTER", button.icon, "TOPRIGHT", 0, 0)
	searchIcon:SetSize(63, 63)
	if searchIcon.SetAtlas then
		searchIcon:SetAtlas(SearchMatchAtlas(), true)
	end
	searchIcon:Hide()
	button.SearchIcon = searchIcon
	local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
	text:SetJustifyH("RIGHT")
	button.rankText = text
	MatchSpendText(text, LiveButton(frame, nodeID))
	button.choices = {}
	return button
end

local function EnsureChoices(frame, board, button, structure)
	local selection = Enum.TraitNodeType and structure.nodeType == Enum.TraitNodeType.Selection
	local entries = structure.entryIDs or {}
	if not selection or #entries < 2 then
		for _, choice in ipairs(button.choices) do
			choice:Hide()
		end
		return
	end
	local nodeID = button.calculatorNodeID
	for index, entryID in ipairs(entries) do
		local choice = button.choices[index]
		if not choice then
			choice = CreatePlanButton(frame, board, nodeID)
			choice.planNode = button
			choice:SetScript("OnClick", function(self, mouseButton)
				NodeClick(frame, nodeID, mouseButton, self.entryID)
			end)
			choice:SetScript("OnEnter", ShowNodeTooltip)
			button.choices[index] = choice
		end
		choice.entryID = entryID
		choice.entryVisual = EntryVisual(frame, entryID)
		ApplyIcon(choice.icon, choice.entryVisual)
		ApplyBorder(choice.border, BorderAtlas(frame, nodeID, entryID))
		choice:Show()
	end
	for index = #entries + 1, #button.choices do
		button.choices[index]:Hide()
	end
end

local function EnsureBoard(frame)
	if frame.calculatorBoard then
		return frame.calculatorBoard
	end
	local parent = frame.ButtonsParent or frame
	local board = CreateFrame("Frame", nil, parent)
	board:SetAllPoints(parent)
	board:SetFrameLevel((parent.GetFrameLevel and parent:GetFrameLevel() or 0) + 20)
	frame.calculatorBoard = board
	frame.calculatorNodes = {}
	frame.calculatorEdges = {}
	return board
end

local function PlaceNode(frame, board, button, structure, shift)
	local x, y = NodePoint(frame, structure.posX, structure.posY)
	button:ClearAllPoints()
	button:SetPoint("CENTER", board, "TOPLEFT", x + (shift or 0), y)
end

local function MakeEdgeWidgets(parent)
	local line
	if parent.CreateLine then
		line = parent:CreateLine(nil, "ARTWORK")
	end
	if not line then
		line = parent:CreateTexture(nil, "ARTWORK")
	end
	local arrow = parent:CreateTexture(nil, "OVERLAY")
	arrow:Hide()
	return line, arrow
end

local function ShowsArrow(style)
	local styles = Enum and Enum.TraitEdgeVisualStyle
	if not styles or style == nil or style == styles.Straight then
		return true
	end
	return false
end

local function ArrowNames(edge)
	local startLook = NodeLook(edge.fromID)
	local endLook = NodeLook(edge.targetID)
	local name = "gray"
	if startLook == "refund" or (endLook == "refund" and SourceMaxed(edge.fromID)) then
		name = "red"
	elseif endLook == "gated" then
		name = "locked"
	elseif edge.active then
		name = "yellow"
	end
	return "talents-arrow-line-" .. name, "talents-arrow-head-" .. name
end

local function NodeSpan(button, frame, nodeID)
	local function span(widget)
		if not widget or not widget.GetWidth then
			return nil
		end
		local width = widget:GetWidth()
		if type(width) ~= "number" or width <= 0 then
			return nil
		end
		local height = widget.GetHeight and widget:GetHeight() or width
		if type(height) ~= "number" or height <= 0 then
			height = width
		end
		return width, height
	end
	local width, height = span(button)
	if not width then
		width, height = span(LiveButton(frame, nodeID))
	end
	if not width then
		width, height = 40, 40
	end
	return width, height
end

local function DiameterOffset(button, angle)
	if button.GetEdgeDiameterOffset and type(Lerp) == "function" and TalentButtonUtil then
		return button:GetEdgeDiameterOffset(angle)
	end
	if TalentButtonUtil and type(TalentButtonUtil.CircleEdgeDiameterOffset) == "number" then
		return TalentButtonUtil.CircleEdgeDiameterOffset
	end
	return 1.2
end

-- TalentEdgeArrowMixin:UpdatePosition stops the line on the arrow head, just outside the target.
local function PlaceArrow(frame, edge)
	local line = edge.line
	local fromButton = edge.fromButton
	local toButton = edge.toButton
	if not line or not fromButton or not toButton then
		return
	end
	local fromStructure = ns.structure[edge.fromID]
	local toStructure = ns.structure[edge.targetID]
	local angle = 0
	if fromStructure and toStructure then
		local x1, y1 = NodePoint(frame, fromStructure.posX, fromStructure.posY)
		local x2, y2 = NodePoint(frame, toStructure.posX, toStructure.posY)
		angle = math.atan2(y1 - y2, x1 - x2)
	end
	local offset = DiameterOffset(toButton, angle)
	local width, height = NodeSpan(toButton, frame, edge.targetID)
	local xOffset = (width / 2) * math.cos(angle) * offset
	local yOffset = (height / 2) * math.sin(angle) * offset
	if line.SetStartPoint then
		line:SetStartPoint("CENTER", fromButton)
	end
	if line.SetEndPoint then
		line:SetEndPoint("CENTER", toButton, xOffset, yOffset)
	end
	local arrow = edge.arrow
	if not arrow then
		return
	end
	arrow:ClearAllPoints()
	arrow:SetPoint("CENTER", toButton, xOffset, yOffset)
	if arrow.SetRotation then
		arrow:SetRotation(angle - (math.pi / 2))
	end
end

local function PaintEdge(frame, edge)
	local ranksLink = edge.edgeType == REQUIRED_EDGE or edge.edgeType == SUFFICIENT_EDGE
	if ranksLink then
		edge.active = SourceMaxed(edge.fromID) and true or false
	else
		edge.active = nil
	end
	local show = ShowsArrow(edge.visualStyle)
	local line = edge.line
	local arrow = edge.arrow
	if line and line.SetShown then
		line:SetShown(show)
	end
	if arrow and arrow.SetShown then
		arrow:SetShown(show)
	end
	if not show or not line then
		return
	end
	local lineAtlas, headAtlas = ArrowNames(edge)
	local ignoreSize = false
	if TextureKitConstants and TextureKitConstants.IgnoreAtlasSize ~= nil then
		ignoreSize = TextureKitConstants.IgnoreAtlasSize
	end
	if line.SetThickness then
		line:SetThickness(6)
	end
	if line.SetHorizTile then
		line:SetHorizTile(true)
	end
	if line.SetVertexColor then
		line:SetVertexColor(1, 1, 1, 1)
	end
	if line.SetAtlas then
		line:SetAtlas(lineAtlas, ignoreSize)
	end
	if arrow and arrow.SetAtlas then
		local useAtlasSize = true
		if TextureKitConstants and TextureKitConstants.UseAtlasSize ~= nil then
			useAtlasSize = TextureKitConstants.UseAtlasSize
		end
		if arrow.SetVertexColor then
			arrow:SetVertexColor(1, 1, 1, 1)
		end
		arrow:SetAtlas(headAtlas, useAtlasSize)
	end
	PlaceArrow(frame, edge)
end

local function BuildEdges(frame, board)
	local wanted = {}
	for nodeID, structure in pairs(ns.structure) do
		local from = frame.calculatorNodes[nodeID]
		for _, edge in ipairs(structure.edges or {}) do
			local to = edge.target and frame.calculatorNodes[edge.target]
			if from and to then
				wanted[#wanted + 1] = {
					fromID = nodeID,
					targetID = edge.target,
					edgeType = edge.edgeType,
					visualStyle = edge.visualStyle,
					fromButton = from,
					toButton = to,
				}
			end
		end
	end
	local lines = frame.calculatorEdges
	for index, info in ipairs(wanted) do
		local record = lines[index]
		if not record then
			local line, arrow = MakeEdgeWidgets(board)
			record = { line = line, arrow = arrow }
			lines[index] = record
		elseif not record.arrow then
			record.arrow = board:CreateTexture(nil, "OVERLAY")
		end
		record.fromID = info.fromID
		record.targetID = info.targetID
		record.edgeType = info.edgeType
		record.visualStyle = info.visualStyle
		record.fromButton = info.fromButton
		record.toButton = info.toButton
		if record.line and record.line.Show then
			record.line:Show()
		end
		PaintEdge(frame, record)
	end
	for index = #wanted + 1, #lines do
		local record = lines[index]
		if record and record.line and record.line.Hide then
			record.line:Hide()
		end
		if record and record.arrow and record.arrow.Hide then
			record.arrow:Hide()
		end
		lines[index] = nil
	end
end

local function BuildBoard(frame)
	local board = EnsureBoard(frame)
	local seen = {}
	for nodeID, structure in pairs(ns.structure) do
		if structure.maxRanks and structure.maxRanks > 0 then
			seen[nodeID] = true
			local button = frame.calculatorNodes[nodeID]
			if not button then
				button = CreateNodeButton(frame, board, nodeID)
				frame.calculatorNodes[nodeID] = button
			end
			local stored = ns.ranks[nodeID]
			local selected = stored and stored.entryID or 0
			local shownEntry = selected > 0 and selected or (structure.entryIDs and structure.entryIDs[1])
			button.entryVisual = EntryVisual(frame, shownEntry)
			ApplyIcon(button.icon, button.entryVisual)
			ApplyBorder(button.border, BorderAtlas(frame, nodeID))
			PlaceNode(frame, board, button, structure, 0)
			BindEdgeOffset(button, frame, nodeID)
			EnsureChoices(frame, board, button, structure)
			local size = ButtonSize(frame) or 36
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
		if not seen[nodeID] then
			button:Hide()
		end
	end
	BuildEdges(frame, board)
	board:Show()
end

local function PaintNode(frame, nodeID)
	local button = frame.calculatorNodes and frame.calculatorNodes[nodeID]
	if not button then
		return
	end
	local art = ArtSet(frame, nodeID)
	BindEdgeOffset(button, frame, nodeID)
	ApplyShadow(button.Shadow, art and art.shadow)
	local structure = ns.structure[nodeID]
	local storedRank = ns.ranks[nodeID]
	local selectedEntry = storedRank and storedRank.entryID or 0
	if selectedEntry <= 0 and structure and structure.entryIDs then
		selectedEntry = structure.entryIDs[1] or 0
	end
	if selectedEntry > 0 then
		button.entryVisual = EntryVisual(frame, selectedEntry)
		ApplyIcon(button.icon, button.entryVisual)
	end
	if button.rankText then
		MatchSpendText(button.rankText, LiveButton(frame, nodeID))
		MatchIcon(button.icon, button.shade, LiveButton(frame, nodeID))
		if button.rankText.GetFont and not button.rankText:GetFont() and button.rankText.SetFontObject and GameFontHighlight then
			button.rankText:SetFontObject(GameFontHighlight)
		end
		button.rankText:SetText(PlanSpendText(frame, nodeID))
		local look = NodeLook(nodeID)
		local states = TalentButtonUtil and TalentButtonUtil.BaseVisualState
		local color
		if states and TalentButtonUtil.GetColorForBaseVisualState then
			local visual = look == "refund" and states.RefundInvalid
				or look == "gated" and states.Gated
				or look == "locked" and states.Locked
				or look == "selectable" and states.Selectable
				or look == "maxed" and states.Maxed
				or look == "normal" and states.Normal
				or states.Disabled
			color = TalentButtonUtil.GetColorForBaseVisualState(visual)
		elseif look == "gated" or look == "locked" or look == "disabled" then
			color = DISABLED_FONT_COLOR
		elseif look == "selectable" then
			color = GREEN_FONT_COLOR
		elseif look == "refund" then
			color = RED_FONT_COLOR
		else
			color = YELLOW_FONT_COLOR
		end
		if color and button.rankText.SetTextColor then
			if color.GetRGB then
				button.rankText:SetTextColor(color:GetRGB())
			elseif color.GetRGBA then
				button.rankText:SetTextColor(color:GetRGBA())
			end
		end
	end
	local look = NodeLook(nodeID)
	ApplyBorder(button.border, BorderAtlas(frame, nodeID))
	ApplyShade(button.icon, button.shade, look)
	for _, choice in ipairs(button.choices or {}) do
		local choiceLook = NodeLook(nodeID, choice.entryID)
		ApplyBorder(choice.border, BorderAtlas(frame, nodeID, choice.entryID))
		ApplyShadow(choice.Shadow, art and art.shadow)
		ApplyShade(choice.icon, choice.shade, choiceLook)
	end
end

local function RefreshOpenTooltip()
	if not GameTooltip or not GameTooltip.IsShown or not GameTooltip:IsShown() then
		return
	end
	local owner = GameTooltip.GetOwner and GameTooltip:GetOwner()
	if owner and owner.calculatorNodeID and owner.GetScript then
		local script = owner:GetScript("OnEnter")
		if script then
			script(owner)
		end
	end
end

local function RefreshChangedEdges(frame, nodeIDs)
	for _, edge in ipairs(frame.calculatorEdges or {}) do
		if nodeIDs[edge.fromID] or nodeIDs[edge.targetID] then
			PaintEdge(frame, edge)
		end
	end
end

local BuildGates

local RememberCurrentPlan

local function ApplyLocalChange(frame, originID, poolChanged)
	local affected = {}
	local origin = ns.structure[originID]
	MarkOutgoing(affected, originID)
	if origin then
		for nodeID, other in pairs(ns.structure) do
			if other.requiredSpent and other.requiredSpent > 0 and SameTree(originID, nodeID) then
				affected[nodeID] = true
			end
		end
	end
	-- The last point, or the first point freed, changes what every tree can buy.
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
	if RememberCurrentPlan then
		RememberCurrentPlan()
	end
end

local function HideLockedOverlay(frame)
	local original = frame.talentCalculatorOverlayShown
	if original then
		original(frame, false)
	elseif frame.DisabledOverlay then
		frame.DisabledOverlay:Hide()
	end
end

-- The number on a gate stays while any talent that gate locks still needs those points.
local function GateStillLocks(anchorID, amount)
	local anchor = anchorID and ns.structure[anchorID]
	if not anchor or not amount or amount <= 0 then
		return false
	end
	for nodeID, structure in pairs(ns.structure) do
		local required = structure.requiredSpent or 0
		if required >= amount and SameTree(anchorID, nodeID) and not IsAbove(structure, anchor) and SpentAbove(nodeID) < amount then
			return true
		end
	end
	return false
end

function BuildGates(frame)
	local nodes = frame.calculatorNodes
	if not nodes then
		return
	end
	frame.calculatorGates = frame.calculatorGates or {}
	local gates = TreeGates(frame, PlanConfigID(frame)) or {}
	local used = {}
	for index, gateInfo in ipairs(gates) do
		local button = nodes[gateInfo.topLeftNodeID]
		if button then
			used[index] = true
			local gate = frame.calculatorGates[index]
			if not gate then
				gate = CreateFrame("Frame", nil, button)
				gate:EnableMouse(true)
				gate:SetScript("OnEnter", ShowGateTooltip)
				if GameTooltip_Hide then
					gate:SetScript("OnLeave", GameTooltip_Hide)
				end
				local text = gate:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				text:SetPoint("RIGHT", gate, "RIGHT", 0, 0)
				gate.GateText = text
				frame.calculatorGates[index] = gate
			end
			-- A reused marker follows its new node, so it is not hidden along with the old one.
			if gate:GetParent() ~= button then
				gate:SetParent(button)
			end
			gate.calculatorFrame = frame
			gate.calculatorNodeID = gateInfo.topLeftNodeID
			gate:ClearAllPoints()
			if frame.AnchorGate then
				frame:AnchorGate(gate, button)
			else
				gate:SetPoint("RIGHT", button, "LEFT")
			end
			local anchor = ns.structure[gateInfo.topLeftNodeID]
			local fullAmount = anchor and anchor.requiredSpent
			if gate.GateText and fullAmount and fullAmount > 0 then
				if gate.GateText.GetFont and not gate.GateText:GetFont() and gate.GateText.SetFontObject and GameFontHighlight then
					gate.GateText:SetFontObject(GameFontHighlight)
				end
				gate.GateText:SetText(fullAmount)
				gate.GateText:Show()
			end
			gate:SetShown(GateStillLocks(gateInfo.topLeftNodeID, fullAmount))
			button.gate = gate
		end
	end
	for index, gate in pairs(frame.calculatorGates) do
		if not used[index] then
			gate:Hide()
		end
	end
end

local function ShowPlan(frame)
	if not next(ns.structure) then
		RememberFrame(frame)
	end
	Prune()
	HideClientTree(frame)
	BuildBoard(frame)
	HideLockedOverlay(frame)
	for nodeID in pairs(ns.structure) do
		PaintNode(frame, nodeID)
	end
	PaintSpent(frame)
	BuildGates(frame)
	HideLockedOverlay(frame)
	RefreshOpenTooltip()
end

function ChangeRank(frame, nodeID, delta)
	if not ShowingCalculator(frame) or not nodeID or delta == 0 then
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
	local current = stored and stored.ranks or 0
	if delta > 0 then
		if not CanAddRank(nodeID) or not SelectionStaysLegal(nodeID, current + delta) then
			return
		end
	elseif current <= 0 or not SelectionStaysLegal(nodeID, current + delta) then
		return
	end

	local unspentBefore = Unspent()
	local nextRank = current + delta
	if nextRank <= 0 then
		ns.ranks[nodeID] = nil
	else
		local entryID = stored and stored.entryID or 0
		if entryID <= 0 and structure.entryIDs then
			entryID = structure.entryIDs[1] or 0
		end
		ns.ranks[nodeID] = {
			ranks = nextRank,
			entryID = entryID,
		}
	end
	ApplyLocalChange(frame, nodeID, (unspentBefore == 0) ~= (Unspent() == 0))
end

function ChooseEntry(frame, nodeID, entryID)
	if not ShowingCalculator(frame) or not nodeID then
		return
	end
	if not ns.structure[nodeID] then
		RememberFrame(frame)
	end
	-- A first pick spends a point, so it passes the same checks as a normal click.
	if not ns.ranks[nodeID] and (not CanAddRank(nodeID) or not SelectionStaysLegal(nodeID, 1)) then
		return
	end
	local unspentBefore = Unspent()
	local stored = ns.ranks[nodeID]
	local structure = ns.structure[nodeID]
	local chosen = entryID or (stored and stored.entryID) or 0
	if chosen <= 0 and structure and structure.entryIDs then
		chosen = structure.entryIDs[1] or 0
	end
	local nextRanks = stored and stored.ranks or 1
	if nextRanks < 1 then
		nextRanks = 1
	end
	ns.ranks[nodeID] = {
		ranks = nextRanks,
		entryID = chosen,
	}
	ApplyLocalChange(frame, nodeID, (unspentBefore == 0) ~= (Unspent() == 0))
end

function RefundNode(frame, nodeID)
	if not ShowingCalculator(frame) or not nodeID then
		return
	end
	if not SelectionStaysLegal(nodeID, 0) then
		return
	end
	local unspentBefore = Unspent()
	ns.ranks[nodeID] = nil
	ApplyLocalChange(frame, nodeID, (unspentBefore == 0) ~= (Unspent() == 0))
end

local HideRealActions
local EnsureWorkingCopy

local function ClientText(globalName, fallback)
	local value = _G[globalName]
	if type(value) == "string" and value ~= "" then
		return value
	end
	return fallback
end

local function SlotText(group)
	if group == 2 then
		return "Secondary"
	end
	return "Primary"
end

local function UpdateSlotDropdown(frame)
	local dropdown = frame and frame.calculatorSlotDropdown
	if not dropdown then
		return
	end
	local text = SlotText(ns.slot or 1)
	dropdown.calculatorLabel = text
	if dropdown.GenerateMenu and dropdown.menuGenerator then
		pcall(dropdown.GenerateMenu, dropdown)
	end
	if not dropdown.SetupMenu and dropdown.SetText then
		dropdown:SetText(text)
	end
end

local function SelectSlot(frame, group)
	if group ~= 1 and group ~= 2 then
		return
	end
	if ns.slot == group and ns.loadedSlot == group then
		UpdateSlotDropdown(frame)
		return
	end
	ns.slot = group
	EnsureWorkingCopy()
	if ShowingCalculator(frame) then
		ShowPlan(frame)
		HideRealActions(frame)
	else
		UpdateSlotDropdown(frame)
	end
end

function HideRealActions(frame)
	frame.ApplyButton:Hide()
	frame.ApplyButton:Disable()
	frame.UndoButton:Hide()
	frame.ResetButton:Hide()
	if frame.ActiveSpec then
		frame.ActiveSpec:Hide()
	end
	HideLockedOverlay(frame)
	if frame.calculatorSaveButton then
		frame.calculatorSaveButton:SetText(ClientText("SAVE", "Save"))
		frame.calculatorClearButton:SetText(ClientText("CLEAR", "Clear"))
		frame.calculatorSaveButton:Show()
		if frame.calculatorLoadButton then
			frame.calculatorLoadButton:Show()
		end
		UpdateSaveButton(frame)
		frame.calculatorClearButton:Show()
	end
	if frame.calculatorSlotDropdown then
		if frame:IsShown() then
			if frame.calculatorSlotDropdown.PlaceOnTalentFrame then
				frame.calculatorSlotDropdown:PlaceOnTalentFrame()
			end
			frame.calculatorSlotDropdown:Show()
			UpdateSlotDropdown(frame)
		else
			frame.calculatorSlotDropdown:Hide()
		end
	end
end

local function ShowRealActions(frame)
	local display = frame.ClassCurrencyDisplay
	if display and display.calculatorLevelText then
		display.calculatorLevelText:Hide()
	end
	if frame.calculatorSaveButton then
		frame.calculatorSaveButton:Hide()
		if frame.calculatorLoadButton then
			frame.calculatorLoadButton:Hide()
		end
		frame.calculatorClearButton:Hide()
	end
	if frame.calculatorSlotDropdown then
		if frame.calculatorSlotDropdown.CloseMenu then
			frame.calculatorSlotDropdown:CloseMenu()
		end
		frame.calculatorSlotDropdown:Hide()
	end
	ShowCharacterTalentNumbers(frame)
	frame.ApplyButton:Show()
	if frame.UpdateConfigButtonsState then
		frame:UpdateConfigButtonsState()
	end
	if frame.InitializeActiveSpec then
		frame:InitializeActiveSpec()
	end
end

local function SnapshotRanks()
	local copy = {}
	for nodeID, stored in pairs(ns.ranks) do
		if stored and (stored.ranks or 0) > 0 then
			copy[nodeID] = {
				ranks = stored.ranks,
				entryID = stored.entryID or 0,
			}
		end
	end
	return copy
end

function RememberCurrentPlan()
	if ns.loadedSlot then
		ns.planBySlot[ns.loadedSlot] = SnapshotRanks()
	end
end

local function ApplySnapshot(copy)
	ClearRankTable()
	if not copy then
		return
	end
	for nodeID, stored in pairs(copy) do
		ns.ranks[nodeID] = {
			ranks = stored.ranks,
			entryID = stored.entryID or 0,
		}
	end
end

-- Puts the selected slot's plan on the calculator: the unsaved edits from this
-- session if that slot has any, otherwise its saved plan. Primary is the first slot shown.
function EnsureWorkingCopy()
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
	local group = ns.slot or 1
	ns.slot = group
	if ns.loadedSlot == group then
		return
	end
	RememberCurrentPlan()
	local kept = ns.planBySlot[group]
	if kept then
		ApplySnapshot(kept)
	else
		LoadSavedRanks(group)
	end
	ns.loadedSlot = group
end

local function EnterCalculator(frame)
	if enteringCalculator then
		return true
	end
	if frame:IsInspecting() then
		return false
	end
	EnsureWorkingCopy()
	enteringCalculator = true
	-- An error is reported with its full stack. Returning false sends SetTab back to
	-- the character's own talents instead of leaving the frame half switched.
	local opened = xpcall(function()
		frame.calculatorMode = true
		HideRealActions(frame)
		-- Read the live tree once. Rebuilding it on every point is counted as this addon's memory.
		RememberFrame(frame)
		ShowPlan(frame)
		HideRealActions(frame)
	end, CallErrorHandler)
	enteringCalculator = false
	return opened
end

local restoringTree = false

-- The character's icons were only hidden. Put them back without reloading the spec.
local function RestoreSharedTree(frame)
	if restoringTree then
		return
	end
	restoringTree = true
	frame.calculatorMode = false
	ShowClientTree(frame)
	if frame.calculatorBoard then
		frame.calculatorBoard:Hide()
	end
	ShowRealActions(frame)
	restoringTree = false
end

local function SaveBuild()
	local build = SaveSlot(ns.slot or 1, true)
	if not build then
		return
	end
	for key in pairs(build) do
		build[key] = nil
	end
	local nodes = {}
	for nodeID, stored in pairs(ns.ranks) do
		if stored.ranks and stored.ranks > 0 then
			nodes[#nodes + 1] = {
				nodeID = nodeID,
				ranks = stored.ranks,
				entryID = stored.entryID or 0,
			}
		end
	end
	build.nodes = nodes
	RememberCurrentPlan()
	local savedWord = "build saved."
	if type(SAVE) == "string" and SAVE ~= "" then
		savedWord = SAVE
	end
	print(addonName .. " " .. savedWord)
end

local function ClearBuild(frame)
	ClearRankTable()
	ns.loadedSlot = ns.slot or 1
	if ShowingCalculator(frame) then
		ShowPlan(frame)
		HideRealActions(frame)
	end
	RememberCurrentPlan()
	print(addonName .. " plan cleared.")
end

local function LoadSavedPlan(frame)
	local group = ns.slot or 1
	if not HasSavedBuild() then
		return
	end
	LoadSavedRanks(group)
	ns.loadedSlot = group
	if ShowingCalculator(frame) then
		ShowPlan(frame)
		HideRealActions(frame)
	end
	RememberCurrentPlan()
	print(addonName .. " saved build loaded.")
end

local function CreateButtons(frame)
	local load = CreateFrame("Button", nil, frame, "UIPanelButtonNoTooltipTemplate")
	load:SetSize(120, 22)
	load:SetPoint("CENTER", frame.ApplyButton, "CENTER", 0, 0)
	load:SetText("Load Saved")
	load:SetFrameLevel(frame.ApplyButton:GetFrameLevel() + 5)
	load:SetScript("OnClick", function()
		LoadSavedPlan(frame)
	end)
	load:Disable()
	load:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Load Saved")
		GameTooltip:AddLine("Puts the saved plan back on the calculator. It does not change your talents.", 1, 0.82, 0, true)
		GameTooltip:Show()
	end)
	load:SetScript("OnLeave", GameTooltip_Hide)
	load:Hide()

	local save = CreateFrame("Button", nil, frame, "UIPanelButtonNoTooltipTemplate")
	save:SetSize(120, 22)
	save:SetPoint("RIGHT", load, "LEFT", -6, 0)
	save:SetText("Save")
	save:SetFrameLevel(frame.ApplyButton:GetFrameLevel() + 5)
	save:SetScript("OnClick", function(self)
		SaveBuild()
		UpdateSaveButton(self:GetParent())
	end)
	save:Disable()
	save:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Save build")
		GameTooltip:AddLine("Stores this plan for this character. It does not change your talents.", 1, 0.82, 0, true)
		GameTooltip:Show()
	end)
	save:SetScript("OnLeave", GameTooltip_Hide)
	save:Hide()

	local clear = CreateFrame("Button", nil, frame, "UIPanelButtonNoTooltipTemplate")
	clear:SetSize(120, 22)
	clear:SetPoint("LEFT", load, "RIGHT", 6, 0)
	clear:SetText("Clear")
	clear:SetFrameLevel(save:GetFrameLevel())
	clear:Disable()
	clear:SetScript("OnClick", function()
		ClearBuild(frame)
	end)
	clear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Clear build")
		GameTooltip:AddLine("Removes every point from the plan on screen. Press Save to store that.", 1, 0.82, 0, true)
		GameTooltip:Show()
	end)
	clear:SetScript("OnLeave", GameTooltip_Hide)
	clear:Hide()

	frame.calculatorSaveButton = save
	frame.calculatorLoadButton = load
	frame.calculatorClearButton = clear

	-- UIParent + DIALOG so the talent tree cannot take the click. This is the game's dropdown.
	local dropdown = CreateFrame("DropdownButton", nil, UIParent, "WowStyle1DropdownTemplate")
	if not dropdown.SetupMenu then
		dropdown:Hide()
		dropdown = CreateFrame("Button", nil, UIParent, "UIPanelButtonNoTooltipTemplate")
		dropdown:SetSize(160, 22)
	end
	dropdown:SetFrameStrata("DIALOG")
	dropdown:SetFrameLevel(100)
	dropdown:SetWidth(160)
	local function PlaceDropdown()
		dropdown:ClearAllPoints()
		-- ApplyButton is hidden while the calculator is open. Anchoring to it leaves this control on screen after the window moves or closes.
		local anchor = frame.Background or frame
		dropdown:SetPoint("BOTTOM", anchor, "BOTTOM", 0, 36)
	end
	PlaceDropdown()
	dropdown.PlaceOnTalentFrame = PlaceDropdown
	if not dropdown.SetupMenu then
		function dropdown:GetText()
			return self.calculatorLabel or SlotText(ns.slot or 1)
		end
	end
	if dropdown.SetupMenu then
		dropdown:SetupMenu(function(_, rootDescription)
			local function isSelected(group)
				return (ns.slot or 1) == group
			end
			local function setSelected(group)
				SelectSlot(frame, group)
			end
			rootDescription:CreateRadio(SlotText(1), isSelected, setSelected, 1)
			rootDescription:CreateRadio(SlotText(2), isSelected, setSelected, 2)
		end)
	end
	dropdown:Hide()

	local function HideDropdown()
		if dropdown.CloseMenu then
			dropdown:CloseMenu()
		end
		dropdown:Hide()
	end
	if not frame.calculatorSlotHooked then
		frame.calculatorSlotHooked = true
		frame:HookScript("OnHide", HideDropdown)
		local owner = PlayerSpellsFrame
		if owner and owner ~= frame then
			owner:HookScript("OnHide", HideDropdown)
		end
	end

	frame.calculatorSlotDropdown = dropdown
	UpdateSlotDropdown(frame)
end

local function BlockOriginal(frame, methodName)
	local original = frame[methodName]
	if type(original) ~= "function" then
		return
	end
	frame[methodName] = function(self, ...)
		if ShowingCalculator(self) then
			return
		end
		return original(self, ...)
	end
end

local function Install(frame)
	if frame.calculatorTabID then
		return
	end

	frame.calculatorTabID = frame:AddNamedTab("Talent Calculator")
	local tabSystem = frame.TabSystem or frame.tabSystem
	local calculatorTab = tabSystem and tabSystem.GetTabButton and tabSystem:GetTabButton(frame.calculatorTabID)
	if calculatorTab then
		-- A selected spec tab is disabled, and that disabled state draws the lock. This tab is not a spec.
		calculatorTab.GetTabText = function(self)
			return TabSystemButtonMixin.GetTabText(self)
		end
	end
	local originalUpdateTabs = frame.UpdateTabs
	if originalUpdateTabs then
		frame.UpdateTabs = function(self)
			originalUpdateTabs(self)
			local tabs = self.TabSystem or self.tabSystem
			if tabs and tabs.SetTabEnabled then
				tabs:SetTabEnabled(self.calculatorTabID, true)
			end
			UpdateSlotDropdown(self)
		end
	end
	CreateButtons(frame)

	local originalInstantiate = frame.InstantiateTalentButton
	if originalInstantiate then
		frame.InstantiateTalentButton = function(self, ...)
			local button = originalInstantiate(self, ...)
			if ShowingCalculator(self) then
				HideWidget(self, button)
			end
			return button
		end
	end

	local originalSetTab = frame.SetTab
	frame.SetTab = function(self, tabID, forcedOpen)
		if tabID == self.calculatorTabID then
			if self:IsInspecting() then
				print(addonName .. " is not available while inspecting.")
				return true
			end
			-- Set this before the tab changes so the spec lock overlay stays down.
			self.calculatorMode = true
			TabSystemOwnerMixin.SetTab(self, tabID)
			if not EnterCalculator(self) then
				self.calculatorMode = false
				local activeTab = self.GetActiveTab and self:GetActiveTab()
				if activeTab then
					originalSetTab(self, activeTab, forcedOpen)
				end
				RestoreSharedTree(self)
			elseif self.UpdateTabs then
				self:UpdateTabs()
			end
			-- True tells the tab button this click already selected its tab.
			return true
		end
		if self.calculatorMode then
			self.calculatorMode = false
			originalSetTab(self, tabID, forcedOpen)
			RestoreSharedTree(self)
			return true
		end
		originalSetTab(self, tabID, forcedOpen)
		return true
	end

	-- Tab clicks call the SetTab closure captured when this frame was created.
	-- Register this replacement or the calculator tab stays on the locked-spec overlay.
	local tabSystem = frame.tabSystem or frame.TabSystem
	if tabSystem and tabSystem.SetTabSelectedCallback then
		local setTab = frame.SetTab
		tabSystem:SetTabSelectedCallback(function(tabID, isUserAction)
			return setTab(frame, tabID, isUserAction)
		end)
	end

	local originalOverlay = frame.SetDisabledOverlayShown
	if originalOverlay then
		frame.talentCalculatorOverlayShown = originalOverlay
		frame.SetDisabledOverlayShown = function(self, shown)
			if ShowingCalculator(self) then
				return originalOverlay(self, false)
			end
			return originalOverlay(self, shown)
		end
	end

	BlockOriginal(frame, "PurchaseRank")
	BlockOriginal(frame, "RefundRank")
	BlockOriginal(frame, "RefundAllRanks")
	BlockOriginal(frame, "SetSelection")

	local originalRefresh = frame.RefreshConfigID
	frame.RefreshConfigID = function(self)
		if enteringCalculator then
			return
		end
		if ShowingCalculator(self) then
			HideClientTree(self)
			return
		end
		return originalRefresh(self)
	end

	local originalCurrency = frame.RefreshClassCurrencyDisplay
	if originalCurrency then
		frame.RefreshClassCurrencyDisplay = function(self)
			originalCurrency(self)
			if ShowingCalculator(self) then
				PaintSpent(self)
				HideClientTree(self)
			end
		end
	end

	local originalHeaders = frame.RefreshTreeHeaders
	if originalHeaders then
		frame.RefreshTreeHeaders = function(self)
			originalHeaders(self)
			if ShowingCalculator(self) then
				PaintSpent(self)
				HideClientTree(self)
			end
		end
	end

	local originalGates = frame.RefreshGates
	if originalGates then
		frame.RefreshGates = function(self)
			originalGates(self)
			if ShowingCalculator(self) then
				HideClientTree(self)
			end
		end
	end

	-- The clear button and Enter call SetFullResultSearch before the box text changes.
	-- A nil or short search is inactive even while the box still holds the old query.
	local committedQuery = nil
	local function CommitFullSearch(searchText)
		local minChars = type(MIN_CHARACTER_SEARCH) == "number" and MIN_CHARACTER_SEARCH or 3
		local length = 0
		if type(searchText) == "string" then
			if strlen then
				length = strlen(searchText)
			else
				length = #searchText
			end
		end
		if type(searchText) == "string" and length >= minChars then
			committedQuery = searchText
		else
			committedQuery = nil
		end
	end

	if frame.SetFullResultSearch then
		local originalFullSearch = frame.SetFullResultSearch
		frame.SetFullResultSearch = function(self, searchText, ...)
			CommitFullSearch(searchText)
			return originalFullSearch(self, searchText, ...)
		end
	end

	local function NameMatches(name, query)
		return type(name) == "string" and name ~= "" and string.find(string.lower(name), query, 1, true) ~= nil
	end

	local function ApplyPlanSearch(self)
		local query = committedQuery and string.lower(committedQuery) or ""
		for _, button in pairs(self.calculatorNodes or {}) do
			local matched = false
			if query ~= "" then
				local shown = button.entryVisual and button.entryVisual.name
				matched = NameMatches(shown, query)
				local nodeID = button.calculatorNodeID
				local structure = nodeID and ns.structure[nodeID]
				-- A choice node matches any of its entries, including one that is not selected.
				if not matched and structure and structure.entryIDs then
					for _, entryID in ipairs(structure.entryIDs) do
						local visual = EntryVisual(self, entryID)
						if NameMatches(visual and visual.name, query) then
							matched = true
							break
						end
					end
				end
			end
			local searchIcon = button.SearchIcon
			if searchIcon then
				if matched then
					if searchIcon.SetAtlas then
						searchIcon:SetAtlas(SearchMatchAtlas(), true)
					end
					searchIcon:Show()
				else
					searchIcon:Hide()
				end
			end
		end
	end

	if frame.DisplayFullSearchResults then
		local originalSearch = frame.DisplayFullSearchResults
		frame.DisplayFullSearchResults = function(self)
			originalSearch(self)
			if ShowingCalculator(self) then
				ApplyPlanSearch(self)
				HideClientTree(self)
			end
		end
	end

	local function ResumeCalculator(self)
		if not ShowingCalculator(self) or not self:IsShown() then
			return
		end
		ShowPlan(self)
		HideRealActions(self)
	end
	frame:HookScript("OnShow", ResumeCalculator)

	local originalButtons = frame.UpdateConfigButtonsState
	frame.UpdateConfigButtonsState = function(self)
		if ShowingCalculator(self) then
			HideRealActions(self)
			return
		end
		return originalButtons(self)
	end

	local originalCheck = frame.CheckSetSelectedConfigID
	frame.CheckSetSelectedConfigID = function(self)
		if ShowingCalculator(self) then
			return
		end
		return originalCheck(self)
	end

	local originalTalentUpdate = frame.HandlePlayerTalentUpdate
	frame.HandlePlayerTalentUpdate = function(self)
		if ShowingCalculator(self) then
			if self.UpdateTabs then
				self:UpdateTabs()
			end
			HideRealActions(self)
			HideClientTree(self)
			return
		end
		return originalTalentUpdate(self)
	end

	local originalInspect = frame.UpdateInspecting
	if originalInspect then
		frame.UpdateInspecting = function(self)
			originalInspect(self)
			if ShowingCalculator(self) then
				HideRealActions(self)
			end
		end
	end

	local function IgnoreWhileCalculating(button)
		local originalClick = button:GetScript("OnClick")
		if originalClick then
			button:SetScript("OnClick", function(self, ...)
				if ShowingCalculator(frame) then
					return
				end
				return originalClick(self, ...)
			end)
		end

		-- UIButtonMixin stores the real action here. That closure calls Apply, Undo, or Reset directly.
		if type(button.onClickHandler) == "function" then
			local originalHandler = button.onClickHandler
			button.onClickHandler = function(self, ...)
				if ShowingCalculator(frame) then
					return
				end
				return originalHandler(self, ...)
			end
		end
	end
	IgnoreWhileCalculating(frame.ApplyButton)
	IgnoreWhileCalculating(frame.UndoButton)
	IgnoreWhileCalculating(frame.ResetButton)

	BlockOriginal(frame, "ApplyConfig")
	BlockOriginal(frame, "CommitConfig")
	BlockOriginal(frame, "CommitConfigInternal")
	BlockOriginal(frame, "RollbackConfig")
	BlockOriginal(frame, "ResetTree")
	BlockOriginal(frame, "ResetClassTalents")
	BlockOriginal(frame, "ResetSpecTalents")
	BlockOriginal(frame, "LoadConfigInternal")
	BlockOriginal(frame, "SetSelectedSavedConfigID")
	BlockOriginal(frame, "OnConfigChanged")

	if frame.UpdateTabs then
		frame:UpdateTabs()
	end
end

local function TryInstall()
	if not C_AddOns.IsAddOnLoaded(TALENT_UI) then
		return
	end
	if PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame then
		Install(PlayerSpellsFrame.TalentsFrame)
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, _, name)
	if name == addonName then
		ReadEnums()
		EnsureSaved()
		TryInstall()
	elseif name == TALENT_UI then
		TryInstall()
	end
end)
