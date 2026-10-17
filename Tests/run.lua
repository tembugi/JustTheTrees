-- Tests for Core.lua: `luajit Tests/run.lua` in the addon folder. Exits non-zero when a test fails.
--
-- Every function in the addon is local to its file, so each test loads the unchanged file and
-- watches what it does, in Tests/standin.lua: a stand-in for Forever's talent window with a small
-- made-up class tree. The saved-plan tests load the addon there with saved plans; the plan tests
-- use the plan through its own buttons, as a player does.

-- This file runs under luajit, outside the game, and uses standard Lua's loadfile and io, which
-- the game doesn't have.
---@diagnostic disable: undefined-global, lowercase-global

local SOURCE = assert(io.open("Core.lua")):read("*a")
local VERSION = SOURCE:match('\nlocal VERSION = "([^"]+)"')
local PLAN_BUDGET = 51

local NewGame = dofile("Tests/standin.lua")

-- Loads the addon with these saved plans, as the game does: the saved variables are set before
-- the addon's ADDON_LOADED. Returns the saved plans after the addon has cleaned them.
local function Load(saved)
	local game = NewGame({ saved = saved })
	assert(#game.errors == 0 and #game.chat == 0, "the addon loaded with an error or a chat line")
	return JustTheTreesDB
end

-- A table as text with sorted keys, to compare whole saves.
local function Dump(value)
	if type(value) ~= "table" then
		return type(value) == "string" and string.format("%q", value) or tostring(value)
	end
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = Dump(key) .. "=" .. Dump(value[key])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local failures = 0

local function Test(name, func)
	local ok, problem = pcall(func)
	if ok then
		io.write("ok    " .. name .. "\n")
	else
		failures = failures + 1
		io.write("FAIL  " .. name .. ": " .. tostring(problem) .. "\n")
	end
end

local function Equal(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
	end
end

local function Same(actual, expected, what)
	Equal(Dump(actual), Dump(expected), what)
end

local function Plan(...)
	return { nodes = { ... } }
end

local function Node(nodeID, ranks, entryID)
	return { nodeID = nodeID, ranks = ranks, entryID = entryID }
end

Test("the version matches the .toc", function()
	local toc = assert(io.open("JustTheTrees.toc")):read("*a")
	Equal(VERSION, toc:match("## Version: (%S+)"), "VERSION")
end)

Test("the budget is one point per level from 10 to 60", function()
	Equal(SOURCE:match("\nlocal MAX_LEVEL = (%d+)") - SOURCE:match("\nlocal FIRST_TALENT_LEVEL = (%d+)") + 1, PLAN_BUDGET, "budget")
end)

Test("a first load starts empty", function()
	Same(Load(nil), { format = 1, characters = {} }, "no saves")
	Same(Load("damaged"), { format = 1, characters = {} }, "not a table")
	Same(Load({ characters = "damaged" }), { format = 1, characters = {} }, "characters not a table")
end)

Test("valid plans are kept as they are", function()
	local saved = {
		format = 1,
		characters = {
			["Ana-Realm"] = { build = Plan(Node(101, 5, 2001), Node(102, 1, 0)), secondary = Plan(Node(201, 3, 0)) },
			["Bo-Realm"] = { build = Plan(Node(101, PLAN_BUDGET, 0)) },
		},
	}
	Same(Load(saved), saved, "save")
end)

Test("a save from before the format number keeps its plans", function()
	Same(Load({ characters = { ["Ana-Realm"] = { build = Plan(Node(101, 2, 0)) } } }), { format = 1, characters = { ["Ana-Realm"] = { build = Plan(Node(101, 2, 0)) } } }, "save")
end)

Test("an empty saved plan stays saved", function()
	Same(Load({ format = 1, characters = { ["Ana-Realm"] = { secondary = Plan() } } }), { format = 1, characters = { ["Ana-Realm"] = { secondary = Plan() } } }, "save")
end)

Test("fields the addon doesn't use are dropped", function()
	local saved = {
		format = 1,
		version = "0.4.0",
		plans = { 1, 2 },
		characters = {
			["Ana-Realm"] = {
				build = { nodes = { { nodeID = 101, ranks = 2, entryID = 0, spent = 2 } }, specID = 71 },
				secondary = Plan(Node(201, 1, 0)),
				spec = 1,
				notes = "old",
			},
		},
	}
	Same(Load(saved), { format = 1, characters = { ["Ana-Realm"] = { build = Plan(Node(101, 2, 0)), secondary = Plan(Node(201, 1, 0)) } } }, "save")
end)

Test("damaged talents are dropped, the rest of the plan is kept", function()
	local saved = {
		format = 1,
		characters = {
			["Ana-Realm"] = {
				build = Plan(
					Node(101, 2, 0),
					"damaged",
					Node(0, 1, 0),
					Node(-5, 1, 0),
					Node(1.5, 1, 0),
					Node("102", 1, 0),
					Node(103, 0, 0),
					Node(104, PLAN_BUDGET + 1, 0),
					Node(105, 1.5, 0),
					Node(106, "2", 0),
					Node(107, 1, nil),
					Node(108, 1, -1),
					Node(109, 1, 2.5),
					Node(101, 4, 0)
				),
			},
		},
	}
	Same(Load(saved), { format = 1, characters = { ["Ana-Realm"] = { build = Plan(Node(101, 2, 0), Node(107, 1, 0), Node(108, 1, 0), Node(109, 1, 0)) } } }, "save")
end)

Test("damaged characters and plans are dropped", function()
	local saved = {
		format = 1,
		characters = {
			[""] = { build = Plan(Node(101, 1, 0)) },
			[7] = { build = Plan(Node(101, 1, 0)) },
			["Ana-Realm"] = "damaged",
			["Bo-Realm"] = { build = "damaged", secondary = { nodes = "damaged" } },
			["Cy-Realm"] = { build = { talents = {} }, secondary = Plan(Node(201, 1, 0)) },
		},
	}
	Same(Load(saved), { format = 1, characters = { ["Cy-Realm"] = { secondary = Plan(Node(201, 1, 0)) } } }, "save")
end)

Test("cleaning a clean save changes nothing", function()
	local once = Load({ version = 2, characters = { ["Ana-Realm"] = { build = Plan(Node(101, 2, 9), Node(101, 3, 0), Node(102, 60, 0)), x = 1 } } })
	Same(Load(once), once, "save cleaned twice")
end)

--------------------------------------------------------------------------------
-- The plan, played in the stand-in's talent window
--------------------------------------------------------------------------------

-- The made-up tree (Tests/standin.lua). Tree A: A1-A2 on row 1, A3-A4 row 2, A5-A6 row 3, A7 row
-- 4, the choice A8 row 5, the capstone A9 row 7. A5 needs A3 maxed. Tree B: B1-B2 row 1, the
-- tiered B3 and B4 row 2, B5-B6 row 3 (each shuts the other out), B7 row 4 (needs B5 or B6).
-- Tree C: C1-C3 row 1, C4-C5 row 2, C6-C7 row 3, C8 row 4, C9 row 5; all five ranks.
local A1, A2, A3, A4, A5, A6, A7, A8, A9 = 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009
local B1, B2, B3, B4, B5, B6, B7 = 2001, 2002, 2003, 2004, 2005, 2006, 2007
local C1, C2, C3, C4, C5, C6, C7, C8, C9 = 3001, 3002, 3003, 3004, 3005, 3006, 3007, 3008, 3009

-- Clicks talents in order: { nodeID, times, ... }.
local function Spend(game, list)
	for index = 1, #list, 2 do
		game:ClickTimes(list[index], list[index + 1])
	end
end

-- A plan with 51 points: tree C full to row 5 (45), then A1 5 and A2 1.
local FULL_PLAN = { C1, 5, C2, 5, C3, 5, C4, 5, C5, 5, C6, 5, C7, 5, C8, 5, C9, 5, A1, 5, A2, 1 }

local function Has(lines, expected, what)
	for _, line in ipairs(lines) do
		if line == expected then
			return
		end
	end
	error(string.format("%s: no line %q in\n  %s", what, expected, table.concat(lines, "\n  ")), 2)
end

local function HasNo(lines, unexpected, what)
	for _, line in ipairs(lines) do
		if line:find(unexpected, 1, true) then
			error(string.format("%s: unexpected line %q", what, line), 2)
		end
	end
end

local function LastChat(game)
	return game.chat[#game.chat] or ""
end

Test("the plan starts empty and never reads or changes the character's talents", function()
	local game = NewGame()
	game:OpenPlan()
	Equal(#game.errors, 0, "errors")
	Equal(game:Spent(), 0, "planned points (the character has 12)")
	Equal(game:Unspent(), "51", "unspent")
	Equal(game:LevelRequired(), "Level required: -", "level")
	Equal(game:State(A1), "Selectable", "A1")
	Equal(game:State(A3), "Gated", "A3, which the character has maxed")
	local text, planShown, gameShown = game:HeaderSpent(1)
	Equal(text .. tostring(planShown) .. tostring(gameShown), "0truefalse", "tree A header (the character has 8 there)")
	Spend(game, FULL_PLAN)
	game:Click(C9, "RightButton")
	game:PressPlanButton("Save")
	game:PickSlot(2)
	game:PressPlanButton("Clear")
	Equal(#game.writes, 0, "calls that change the character's talents")
	Equal(#game.errors, 0, "errors after")
end)

Test("the game's own tree and controls step aside for the plan, and come back after", function()
	local game = NewGame()
	game:OpenTalentWindow()
	local pieces = game:GamePiecesShown()
	Equal(pieces > 0, true, "the game's pieces before")
	local primary = game:Tab(game.frame.primarySpecTabID)
	Equal(primary:IsEnabled(), false, "the selected game tab before")
	game:ClickPlanTab()
	Equal(game:GamePiecesShown(), 0, "the game's pieces under the plan")
	for _, name in ipairs({ "ApplyButton", "UndoButton", "ResetButton", "ActiveSpec" }) do
		local shield = game.frame.calculatorShields[name]
		Equal(game.frame[name]:GetAlpha(), 0, name .. " under the plan")
		Equal(shield:IsShown() and shield:IsMouseEnabled(), true, name .. " shielded")
		Equal(shield:GetFrameLevel() < game.frame.calculatorSaveButton:GetFrameLevel(), true, name .. "'s shield under the plan's buttons")
	end
	-- The locked-spec overlay spans the whole window: it only stops taking the mouse.
	Equal(game.frame.DisabledOverlay:GetAlpha(), 0, "the locked-spec overlay under the plan")
	Equal(game.frame.DisabledOverlay:IsMouseEnabled(), false, "the locked-spec overlay's mouse")
	Equal(game.frame.calculatorShields.DisabledOverlay, nil, "no shield over the whole window")
	local treeShield = game.frame.calculatorTreeShield
	Equal(treeShield:IsShown() and treeShield:IsMouseEnabled(), true, "the game's talents shielded")
	Equal(treeShield:GetFrameLevel() < game.frame.calculatorBoard:GetFrameLevel(), true, "the talents' shield under the plan")
	-- The game's top talent row sits 502 above its tree's frame (ClassTalentsFrameMixin:GetFrameLevelForButton).
	Equal(treeShield:GetFrameLevel() > game.frame.ButtonsParent:GetFrameLevel() + 502, true, "the talents' shield over the game's top row")
	Equal(game.frame.calculatorBoard:IsMouseEnabled(), false, "the plan's board leaves the mouse to what is around it")
	Equal(game.frame.calculatorSaveButton:IsShown(), true, "Save shown")
	Equal(game:PlanTab().isSelected, true, "the plan's tab selected")
	Equal(primary.LeftActive:IsShown(), false, "the game's tab drawn unselected")
	Equal(primary:IsEnabled(), true, "the game's tab clickable")
	Equal(game.sounds[#game.sounds], SOUNDKIT.IG_CHARACTER_INFO_TAB, "the tab sound")
	-- The game updating its tree, buttons and tabs while the plan is open doesn't bring them back.
	game.frame:RefreshConfigID()
	game.frame:UpdateConfigButtonsState()
	game.frame:HandlePlayerTalentUpdate()
	Equal(game:GamePiecesShown(), 0, "the game's pieces after the game redraws")
	Equal(game.frame.ApplyButton:GetAlpha(), 0, "Apply after the game updates it")
	Equal(primary:IsEnabled(), true, "the game's tab after the game updates its tabs")
	game:ClickTab(game.frame.primarySpecTabID)
	Equal(game:GamePiecesShown(), pieces, "the game's pieces back")
	Equal(game.frame.ApplyButton:GetAlpha(), 1, "Apply back")
	Equal(game.frame.calculatorShields.ApplyButton:IsShown(), false, "Apply's shield gone")
	Equal(game.frame.calculatorTreeShield:IsShown(), false, "the talents' shield gone")
	Equal(game.frame.DisabledOverlay:IsMouseEnabled(), true, "the locked-spec overlay's mouse back")
	Equal(game.frame.calculatorBoard:IsShown(), false, "plan hidden")
	Equal(game.frame.calculatorSaveButton:IsShown(), false, "Save hidden")
	Equal(game.frame.ClassCurrencyDisplay.CurrentAmountContainer.CurrencyAmount:IsShown(), true, "the character's points back")
	Equal(game:PlanTab().isSelected, false, "the plan's tab unselected")
	Equal(primary.LeftActive:IsShown(), true, "the game's tab drawn selected")
	Equal(primary:IsEnabled(), false, "the game's selected tab as the game has it")
	Equal(#game.errors, 0, "errors")
end)

-- The plan never runs the game's own tab, tree or window code, and never shows or hides the
-- game's widgets that have scripts: in the game, that code would run tainted.
Test("the plan never runs the game's own tab, tree or window code", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { A1, 5, A3, 2 })
	game:Click(A3, "RightButton")
	game:Tooltip(A1)
	game:PressPlanButton("Save")
	game:PickSlot(2)
	game:PickSlot(1)
	game.search[A1 .. ":nil"] = SpellSearchUtil.MatchType.ExactMatch
	game.frame:DisplayFullSearchResults()
	game:SetCVar("colorblindMode", true)
	game.frame:HandlePlayerTalentUpdate()
	game:CloseTalentWindow()
	game:OpenTalentWindow()
	game:ClickTab(game.frame.primarySpecTabID)
	game:ClickPlanTab()
	game.inspecting = true
	game.frame:UpdateInspecting()
	game.inspecting = false
	game.frame:UpdateInspecting()
	game:ClickPlanTab()
	game:RunTimers()
	Equal(table.concat(game.taints, ", "), "", "the game's code run from the addon")
	Equal(#game.errors, 0, "errors")
end)

Test("row 1 is open, and each row after it needs 5 more points in the rows above", function()
	local game = NewGame()
	game:OpenPlan()
	game:ClickTimes(A1, 4)
	Equal(game:State(A3), "Gated", "row 2 after 4 points")
	game:Click(A3)
	Equal(game:Ranks(A3), 0, "a click on a gated talent")
	game:Click(A2)
	Equal(game:State(A3), "Selectable", "row 2 after 5 points")
	Equal(game:State(A6), "Gated", "row 3 after 5 points")
	game:ClickTimes(A2, 3)
	game:Click(A1)
	Equal(game:State(A6), "Gated", "row 3 after 9 points")
	game:Click(A2)
	Equal(game:State(A6), "Selectable", "row 3 after 10 points")
	Equal(game:State(A7), "Gated", "row 4 after 10 points")
end)

Test("points in other trees and in the same row don't open a row", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { B1, 5, C1, 5, C2, 5 })
	Equal(game:State(A3), "Gated", "A3 with points in trees B and C")
	Spend(game, { A1, 5, A3, 3, A4, 1 })
	-- Row 3 needs 10 above it: A1 5, A3 3 and A4 1 are 9.
	Equal(game:State(A6), "Gated", "row 3 after 9 points above it")
	game:Click(A4)
	Equal(game:State(A6), "Selectable", "row 3 after 10 points above it")
end)

Test("points in a row can't hold that same row open", function()
	local game = NewGame()
	game:OpenPlan()
	-- Row 3 needs 10 above it: A1 5, A3 3 and A4 2. A5 and A6 are on row 3.
	Spend(game, { A1, 5, A3, 3, A4, 2, A5, 1, A6, 5 })
	game:Click(A4, "RightButton")
	Equal(game:Ranks(A4), 2, "A4 after a right click (row 3 would have 9 above it)")
end)

Test("an empty row doesn't count: the capstone on row 7 is the tree's sixth row", function()
	local game = NewGame()
	game:OpenPlan()
	Has(game:Tooltip(A9), "error: Requires 25 more points in Tree A talents", "capstone tooltip")
	game:ClickTimes(A1, 5)
	Has(game:Tooltip(A9), "error: Requires 20 more points in Tree A talents", "capstone tooltip after 5")
end)

Test("a point can't come off when a deeper talent would be left short", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { A1, 5, A2, 1, A3, 1 })
	game:Click(A2, "RightButton")
	Equal(game:Ranks(A2), 0, "A2 after a right click (row 1 keeps 5)")
	game:Click(A1, "RightButton")
	Equal(game:Ranks(A1), 5, "A1 after a right click (A3 would be short)")
	game:Click(A3, "RightButton")
	game:Click(A1, "RightButton")
	Equal(game:Ranks(A1), 4, "A1 once A3 is empty")
end)

Test("a talent behind an arrow needs the talent before it maxed", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { A1, 5, A2, 5, A3, 2 })
	Equal(game:State(A5), "Locked", "A5 with A3 at 2 of 3")
	Has(game:Tooltip(A5), "error: Requires all preceding talents", "A5 tooltip")
	game:Click(A5)
	Equal(game:Ranks(A5), 0, "a click on A5")
	game:Click(A3)
	Equal(game:State(A5), "Selectable", "A5 with A3 maxed")
	HasNo(game:Tooltip(A5), "preceding", "A5 tooltip with A3 maxed")
	game:Click(A5)
	Equal(game:State(A5), "Maxed", "A5 after its point")
	game:Click(A3, "RightButton")
	Equal(game:Ranks(A3), 3, "A3 after a right click (A5 needs it maxed)")
end)

Test("two talents that shut each other out", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { B1, 5, B2, 5, B5, 1 })
	Equal(game:Ranks(B5), 1, "B5")
	Equal(game:State(B6), "Locked", "B6 while B5 has its point")
	game:Click(B6)
	Equal(game:Ranks(B6), 0, "a click on B6")
	game:Click(B5, "RightButton")
	Equal(game:State(B6), "Selectable", "B6 after B5 gave its point back")
end)

Test("a talent with two arrows into it needs either one maxed", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { B1, 5, B2, 5, B4, 5 })
	Equal(game:State(B7), "Locked", "B7 with neither")
	game:Click(B6)
	Equal(game:State(B7), "Selectable", "B7 with B6")
	game:Click(B7)
	game:Click(B6, "RightButton")
	Equal(game:Ranks(B6), 1, "B6 after a right click (B7 needs it)")
end)

Test("a choice talent: a click picks a choice, another choice takes the point over", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { A1, 5, A2, 5, A3, 3, A4, 2, A6, 5 })
	Equal(game:State(A8, 1), "Selectable", "first choice")
	game:Click(A8, "LeftButton", 1)
	Equal(game:Ranks(A8), 1, "A8 after the first choice")
	Equal(game.ns.ranks[A8].entryID, 10081, "chosen entry")
	Equal(game:State(A8, 2), "Disabled", "second choice while the first is taken")
	local spent = game:Spent()
	game:Click(A8, "LeftButton", 2)
	Equal(game.ns.ranks[A8].entryID, 10082, "entry after switching")
	Equal(game:Spent(), spent, "points after switching")
	game:Click(A8, "RightButton", 2)
	Equal(game:Ranks(A8), 0, "A8 after a right click")
end)

Test("a tiered talent moves through its entries", function()
	local game = NewGame()
	game:OpenPlan()
	game:ClickTimes(B1, 5)
	local function Entries()
		local lines = {}
		for _, line in ipairs(game:Tooltip(B3)) do
			if line:find("^info") then
				lines[#lines + 1] = line:match("GetTraitEntry (.*)")
			end
		end
		return table.concat(lines, ", ")
	end
	Equal(Entries(), "20031 rank 0", "no points")
	game:Click(B3)
	Equal(Entries(), "20031 rank 1, 20032 rank 1", "1 point")
	game:Click(B3)
	Equal(Entries(), "20032 rank 1, 20032 rank 2", "2 points")
	game:Click(B3)
	Equal(Entries(), "20032 rank 2", "3 points")
	Equal(game:State(B3), "Maxed", "3 of 3")
end)

Test("the plan has 51 points, one per level from 10 to 60", function()
	local game = NewGame()
	game:OpenPlan()
	game:Click(C1)
	Equal(game:LevelRequired(), "Level required: 10", "level after 1 point")
	game:ClickTimes(C1, 4)
	game:ClickTimes(C2, 5)
	Equal(game:LevelRequired(), "Level required: 19", "level after 10 points")
	Spend(game, { C3, 5, C4, 5, C5, 5, C6, 5, C7, 5, C8, 5, C9, 5, A1, 5, A2, 1 })
	Equal(game:Spent(), 51, "points")
	Equal(game:Unspent(), "0", "unspent")
	Equal(game:LevelRequired(), "Level required: 60", "level")
	Equal(game:State(A4), "Disabled", "an open talent with no points left")
	game:Click(A2)
	Equal(game:Ranks(A2), 1, "A2 after a click with no points left")
	game:Click(C9, "RightButton")
	Equal(game:State(A4), "Selectable", "an open talent once a point is free")
end)

Test("each tree's header counts that tree's planned points", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { A1, 3, B1, 5, B3, 2 })
	Equal(game:HeaderSpent(1), "3", "tree A")
	Equal(game:HeaderSpent(2), "7", "tree B")
	Equal(game:HeaderSpent(3), "0", "tree C")
end)

Test("each tree shows a gate on its first locked row, with the points still needed", function()
	local game = NewGame()
	game:OpenPlan()
	local function Gates()
		local list = {}
		for nodeID, needed in pairs(game:Gates()) do
			list[#list + 1] = nodeID .. "=" .. needed
		end
		table.sort(list)
		return table.concat(list, " ")
	end
	Equal(Gates(), "1003=5 2003=5 3004=5", "gates at first")
	game:ClickTimes(A1, 3)
	Equal(Gates(), "1003=2 2003=5 3004=5", "after 3 points in tree A")
	game:ClickTimes(A1, 2)
	Equal(Gates(), "1005=5 2003=5 3004=5", "after 5 points in tree A")
end)

Test("the tooltip says what a click does", function()
	local game = NewGame()
	game:OpenPlan()
	local lines = game:Tooltip(A1)
	Has(lines, "title: Talent 10010", "title")
	Has(lines, "highlight: Rank " .. HIGHLIGHT_FONT_COLOR:WrapTextInColorCode("0") .. "/5", "rank")
	Has(lines, "instruction: Click to learn", "instruction")
	game:ClickTimes(A1, 2)
	lines = game:Tooltip(A1)
	Has(lines, "highlight: Next Rank:", "next rank")
	Has(lines, "instruction: Click to learn", "instruction with points")
	game:ClickTimes(A1, 3)
	lines = game:Tooltip(A1)
	Has(lines, "disabled: Right click to unlearn", "maxed")
	HasNo(lines, "Click to learn", "maxed")
	HasNo(lines, "Next Rank", "maxed")
end)

-- The plan's controls are the game's: Apply Changes (calculatorSaveButton) glows while the plan
-- differs from the saved one, the undo arrow (calculatorLoadButton) shows then, and the reset
-- arrow (calculatorClearButton) shows otherwise.
Test("Apply Changes keeps the plan, the undo arrow puts it back, the reset arrow empties the screen", function()
	local game = NewGame()
	game:OpenPlan()
	local apply, undo, reset = game.frame.calculatorSaveButton, game.frame.calculatorLoadButton, game.frame.calculatorClearButton
	Equal(apply:GetText(), "Apply Changes", "the game's text")
	Equal(game:PressPlanButton("Save"), false, "Apply Changes with an empty plan never saved")
	Equal(apply.YellowGlow:IsShown(), false, "no glow with nothing to apply")
	Equal(tostring(undo:IsShown()) .. " " .. tostring(reset:IsShown()), "false true", "the reset arrow, not the undo arrow")
	Equal(reset:IsEnabled(), false, "the reset arrow with no points")
	game:ClickTimes(A1, 3)
	Equal(apply.YellowGlow:IsShown(), true, "the glow with changes to apply")
	Equal(tostring(undo:IsShown()) .. " " .. tostring(reset:IsShown()), "true false", "the undo arrow, not the reset arrow")
	Equal(game:PressPlanButton("Save"), true, "Apply Changes")
	Equal(game.sounds[#game.sounds], SOUNDKIT.UI_CLASS_TALENT_APPLY_CHANGES, "the game's apply sound")
	Equal(LastChat(game):find("Primary plan saved (3/51 points).", 1, true) ~= nil, true, "chat after Apply Changes")
	Equal(Dump(JustTheTreesDB.characters["Ana-Realm"].build), Dump({ nodes = { { nodeID = A1, ranks = 3, entryID = 10010 } } }), "saved plan")
	Equal(apply:IsEnabled(), false, "Apply Changes when nothing changed")
	Equal(apply.YellowGlow:IsShown(), false, "no glow when nothing changed")
	Equal(undo:IsShown(), false, "no undo arrow when nothing changed")
	game:ClickTimes(A1, 2)
	game:PressPlanButton("Load")
	Equal(game:Ranks(A1), 3, "A1 after the undo arrow")
	Equal(LastChat(game):find("Unsaved changes were discarded.", 1, true) ~= nil, true, "chat after the undo arrow")
	game:PressPlanButton("Clear")
	Equal(game:Spent(), 0, "points after the reset arrow")
	Equal(JustTheTreesDB.characters["Ana-Realm"].build.nodes[1].ranks, 3, "saved plan after the reset arrow")
	game:PressPlanButton("Load")
	Equal(game:Ranks(A1), 3, "the undo arrow after the reset arrow")
end)

Test("the undo arrow on a slot never saved empties the plan", function()
	local game = NewGame()
	game:OpenPlan()
	game:ClickTimes(A1, 2)
	game:PressPlanButton("Load")
	Equal(game:Spent(), 0, "points")
end)

Test("talent clicks play the game's spend and refund sounds", function()
	local game = NewGame()
	game:OpenPlan()
	game:Click(A1)
	Equal(game.sounds[#game.sounds], SOUNDKIT.UI_CLASS_TALENT_NODE_SPEND, "a point")
	game:Click(A1, "RightButton")
	Equal(game.sounds[#game.sounds], SOUNDKIT.UI_CLASS_TALENT_NODE_REFUND, "a point off")
	local count = #game.sounds
	game:Click(A3)
	Equal(#game.sounds, count, "no sound when nothing changes")
end)

Test("Primary and Secondary are separate plans, and each keeps its unsaved edits", function()
	local game = NewGame()
	game:OpenPlan()
	game:ClickTimes(A1, 2)
	game:PickSlot(2)
	Equal(game.frame.calculatorSlotDropdown.selectedText, "Secondary", "menu")
	Equal(game:Spent(), 0, "Secondary at first")
	game:ClickTimes(C1, 4)
	game:PressPlanButton("Save")
	game:PickSlot(1)
	Equal(game:Ranks(A1) .. " " .. game:Ranks(C1), "2 0", "Primary's unsaved edits")
	game:PickSlot(2)
	Equal(game:Ranks(A1) .. " " .. game:Ranks(C1), "0 4", "Secondary")
	Equal(JustTheTreesDB.characters["Ana-Realm"].build, nil, "Primary never saved")
end)

Test("a saved plan comes back after /reload", function()
	local game = NewGame()
	game:OpenPlan()
	Spend(game, { A1, 5, A3, 2 })
	game:PressPlanButton("Save")
	game = NewGame({ saved = JustTheTreesDB })
	game:OpenPlan()
	Equal(game:Ranks(A1) .. " " .. game:Ranks(A3), "5 2", "plan after /reload")
	Equal(game.frame.calculatorSaveButton:IsEnabled(), false, "Save after /reload")
end)

Test("a saved plan that no longer fits the tree is fitted, and chat says how", function()
	local saved = { format = 1, characters = { ["Ana-Realm"] = { build = { nodes = {
		{ nodeID = A1, ranks = 7, entryID = 10010 }, -- over A1's 5 ranks
		{ nodeID = A2, ranks = 5, entryID = 10020 },
		{ nodeID = A8, ranks = 1, entryID = 99999 }, -- a choice the talent no longer has, on a locked row
		{ nodeID = 9999, ranks = 2, entryID = 0 }, -- a talent no longer in the tree
		{ nodeID = C1, ranks = 5, entryID = 0 }, { nodeID = C2, ranks = 5, entryID = 0 }, { nodeID = C3, ranks = 5, entryID = 0 },
		{ nodeID = C4, ranks = 5, entryID = 0 }, { nodeID = C5, ranks = 5, entryID = 0 }, { nodeID = C6, ranks = 5, entryID = 0 },
		{ nodeID = C7, ranks = 5, entryID = 0 }, { nodeID = C8, ranks = 5, entryID = 0 }, { nodeID = C9, ranks = 5, entryID = 0 },
	} } } } }
	local game = NewGame({ saved = saved })
	game:OpenPlan()
	-- 55 points after the caps; the 4 over the budget come off the deepest row.
	Equal(game:Ranks(A1) .. " " .. game:Ranks(A8) .. " " .. game:Ranks(9999) .. " " .. game:Ranks(C9), "5 0 0 1", "fitted plan")
	Equal(game:Spent(), 51, "points")
	local line = LastChat(game)
	for _, part in ipairs({ "Primary plan changed to fit the current talents:", "from 7 to 5 ranks", "max rank lowered", "row or arrow requirement no longer met", "over 51 points", "and 1 more", "Press Apply Changes to keep it." }) do
		Equal(line:find(part, 1, true) ~= nil, true, "chat has " .. part)
	end
	Equal(game.frame.calculatorSaveButton:IsEnabled(), true, "Save after fitting")
end)

Test("inspecting turns the tab off and hands the window over", function()
	local game = NewGame()
	game:OpenPlan()
	game:ClickTimes(A1, 2)
	game.inspecting = true
	game.frame:UpdateInspecting()
	Equal(game.frame.calculatorMode, false, "plan mode")
	Equal(game.frame.calculatorBoard:IsShown(), false, "plan")
	local tab = game:PlanTab()
	Equal(tab:IsForceDisabled(), true, "plan tab turned off")
	Equal(tab.Text:GetText(), DISABLED_FONT_COLOR:WrapTextInColorCode("Just the Trees"), "plan tab label")
	game:ClickPlanTab()
	Equal(game.frame.calculatorMode, false, "plan mode after clicking the turned-off tab")
	game.inspecting = false
	game.frame:UpdateInspecting()
	Equal(tab.Text:GetText(), "Just the Trees", "plan tab label after")
	game:ClickPlanTab()
	Equal(game:Ranks(A1), 2, "plan after inspecting")
end)

local TURNED_OFF = RED_FONT_COLOR:WrapTextInColorCode("The talent plan stopped working and is off.") .. " Type /reload to turn it back on."

local function GameChanged(what)
	return RED_FONT_COLOR:WrapTextInColorCode("The talent plan is off: " .. what .. " has changed since version " .. VERSION .. ".") .. " Look for an update."
end

-- The talent window as the game draws it: its own tab and talents, controls and points.
local function GameWindowBack(game, pieces)
	Equal(game.frame:GetTab(), game.frame.primarySpecTabID, "tab")
	Equal(game.frame.calculatorMode, false, "plan mode")
	Equal(game.frame.calculatorBoard == nil or not game.frame.calculatorBoard:IsShown(), true, "plan hidden")
	Equal(game:GamePiecesShown(), pieces, "the game's pieces")
	Equal(game.frame.ApplyButton:GetAlpha(), 1, "Apply")
	Equal(game.frame.DisabledOverlay:IsShown(), false, "the locked-spec overlay")
	Equal(game.frame.ClassCurrencyDisplay.CurrentAmountContainer.CurrencyAmount:IsShown(), true, "the character's points")
	Equal(game:PlanTab():IsShown(), false, "the plan's tab")
end

Test("an error while opening the plan turns it off until /reload: its tab hides, the character's talents come back", function()
	local game = NewGame()
	game:OpenTalentWindow()
	local pieces = game:GamePiecesShown()
	local entryInfo = C_Traits.GetEntryInfo
	C_Traits.GetEntryInfo = function()
		error("entry info failed")
	end
	game:ClickPlanTab()
	Equal(#game.errors, 1, "errors reported")
	Same(game.chat, { NORMAL_FONT_COLOR:WrapTextInColorCode("Just the Trees") .. ": " .. TURNED_OFF }, "chat")
	game:RunTimers()
	GameWindowBack(game, pieces)
	-- The game goes on without the addon: nothing more is reported or said.
	C_Traits.GetEntryInfo = entryInfo
	game.frame:UpdateTabs()
	game.inspecting = true
	game.frame:UpdateInspecting()
	game.inspecting = false
	game.frame:UpdateInspecting()
	game.frame:RefreshConfigID()
	game:CloseTalentWindow()
	game:OpenTalentWindow()
	game:SetCVar("colorblindMode", true)
	game:RunTimers()
	GameWindowBack(game, pieces)
	Equal(#game.errors .. " " .. #game.chat, "1 1", "errors and chat lines after")
	-- After /reload the plan opens again.
	game = NewGame()
	game:OpenPlan()
	Equal(game.frame.calculatorMode, true, "plan after /reload")
	Equal(#game.errors, 0, "errors after /reload")
end)

Test("an error in a click on the plan turns it off and shows the character's talents", function()
	local game = NewGame()
	game:OpenTalentWindow()
	local pieces = game:GamePiecesShown()
	game:ClickPlanTab()
	game:ClickTimes(A1, 2)
	function IsModifiedClick()
		error("modified click failed")
	end
	game:Click(A1)
	Equal(#game.errors, 1, "errors reported")
	Equal(LastChat(game):find(TURNED_OFF, 1, true) ~= nil, true, "chat")
	game:RunTimers()
	GameWindowBack(game, pieces)
	Equal(#game.chat, 1, "chat lines")
end)

Test("if the talent window lacks a piece the plan needs, chat says so once and the plan adds nothing", function()
	local game = NewGame({ changeGame = function()
		local GetTemplateInfo = C_XMLUtil.GetTemplateInfo
		function C_XMLUtil.GetTemplateInfo(name)
			if name ~= "TalentFrameGateTemplate" then
				return GetTemplateInfo(name)
			end
		end
	end })
	game:OpenTalentWindow()
	game:RunTimers()
	Equal(game.frame.calculatorTab, nil, "the plan's tab")
	game:CloseTalentWindow()
	game:OpenTalentWindow()
	Same(game.chat, { NORMAL_FONT_COLOR:WrapTextInColorCode("Just the Trees") .. ": " .. GameChanged("the talent window") }, "chat")
	Equal(#game.errors, 0, "errors")
end)

Test("if the game lacks a piece the addon needs, chat says so once and the addon adds nothing", function()
	local saved = { format = 1, characters = { ["Ana-Realm"] = { build = Plan(Node(A1, 2, 0)) } }, old = true }
	local game = NewGame({ saved = saved, changeGame = function()
		C_XMLUtil = nil
	end })
	Equal(JustTheTreesDB, saved, "saved plans")
	Equal(JustTheTreesDB.old, true, "saved plans left as they were")
	game:OpenTalentWindow()
	Equal(game.frame.calculatorTab, nil, "the plan's tab")
	Same(game.chat, { NORMAL_FONT_COLOR:WrapTextInColorCode("Just the Trees") .. ": " .. GameChanged("the game") }, "chat")
	Equal(#game.errors, 0, "errors")
end)

Test("the tab is there when the talent window loaded before the addon", function()
	local game = NewGame({ talentWindowFirst = true })
	game:OpenPlan()
	Equal(game.frame.calculatorTab ~= nil, true, "the plan's tab")
	Spend(game, { A1, 1 })
	Equal(game:Ranks(A1), 1, "a point in the plan")
end)

Test("closing and opening the window keeps the plan on screen", function()
	local game = NewGame()
	game:OpenPlan()
	game:ClickTimes(A1, 3)
	game:CloseTalentWindow()
	game:OpenTalentWindow()
	Equal(game.frame.calculatorMode, true, "plan")
	Equal(game:Ranks(A1), 3, "A1")
	Equal(game:GamePiecesShown(), 0, "the game's pieces")
end)

-- Below the talent level the game greys out the talent button and keeps its talents tab shut.
-- Opening it from the addon taints the window and the action bars, so the addon leaves it.
Test("below the talent level the talent button and window stay as the game has them", function()
	local game = NewGame({ belowTalentLevel = true })
	Equal(TalentMicroButton:IsEnabled(), false, "button greyed out")
	TalentMicroButton:Enable()
	game:PressTalentButton()
	game:PressTalentKey()
	game:RunTimers()
	Equal(game:WindowShown(), false, "window after a click and the talent key")
	Equal(#game.errors .. " " .. #game.chat, "0 0", "errors and chat lines")
end)

Test("shift-click puts the talent's link in chat", function()
	local game = NewGame()
	game:OpenPlan()
	game.modified.CHATLINK = true
	game:Click(A1)
	Equal(game.insertedLink, C_Spell.GetSpellLink(910010), "link")
	Equal(game:Ranks(A1), 0, "A1")
end)

Test("numbers on talents follow the game's rules", function()
	for _, hide in ipairs({ false, true }) do
		local game = NewGame({ hideSingleRankNumbers = hide })
		game:OpenPlan()
		Equal(game:Button(A3).SpendText:GetText(), "", "a gated talent")
		Equal(game:Button(A1).SpendText:GetText(), "0", "a talent that can take a point")
		Spend(game, { A1, 5, A2, 5, A3, 3 })
		local single = hide and "" or "0"
		Equal(game:Button(A5).SpendText:GetText(), single, "a one-rank talent that can take a point, hidden " .. tostring(hide))
		game:Click(A5)
		Equal(game:Button(A5).SpendText:GetText(), hide and "" or "1", "a one-rank talent with its point, hidden " .. tostring(hide))
		Equal(game:Button(A1).SpendText:GetText(), "5", "a maxed talent")
		Equal(table.concat(game:Button(A1).SpendText.textColor, ","), table.concat({ YELLOW_FONT_COLOR:GetRGB() }, ","), "a maxed talent's number color")
	end
end)

Test("color blind mode marks the talents that can take a point", function()
	local game = NewGame()
	game:OpenPlan()
	Equal(game:Button(A1).SelectableIcon:IsShown(), false, "mark without color blind mode")
	game:SetCVar("colorblindMode", true)
	Equal(game:Button(A1).SelectableIcon:IsShown(), true, "mark on A1")
	Equal(game:Button(A3).SelectableIcon:IsShown(), false, "mark on gated A3")
end)

Test("search marks come from the window's search, without action bar marks", function()
	local game = NewGame()
	game:OpenPlan()
	game.search[A1 .. ":nil"] = SpellSearchUtil.MatchType.ExactMatch
	game.search[A2 .. ":nil"] = SpellSearchUtil.MatchType.NotOnActionBar
	game.search[A8 .. ":10082"] = SpellSearchUtil.MatchType.NameMatch
	game.frame:DisplayFullSearchResults()
	Equal(game:Button(A1).SearchIcon:IsShown(), true, "A1 mark")
	Equal(game:Button(A1).SearchIcon.Icon:GetAtlas(), "talents-search-exactmatch", "A1 mark art")
	Equal(game:Button(A2).SearchIcon:IsShown(), false, "A2 mark (not on your action bar)")
	Equal(game:Button(A8, 2).SearchIcon:IsShown(), true, "the second choice of A8")
	Equal(game:Button(A8, 1).SearchIcon:IsShown(), false, "the first choice of A8")
end)

Test("hidden and empty talents aren't in the plan", function()
	local game = NewGame()
	game:OpenPlan()
	Equal(game.frame.calculatorNodes[game.HIDDEN_NODE], nil, "hidden talent")
	Equal(game.frame.calculatorNodes[game.EMPTY_NODE] == nil or not game.frame.calculatorNodes[game.EMPTY_NODE]:IsShown(), true, "empty talent")
	Equal(#game.errors, 0, "errors")
end)

if failures > 0 then
	io.write(failures .. " failed\n")
	os.exit(1)
end
io.write("all passed\n")
