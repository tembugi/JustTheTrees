-- Tests for Core.lua: `luajit Tests/run.lua` in the addon folder. Exits non-zero when a test fails.
--
-- Every function in the addon is local to its file, so each test loads the unchanged file and
-- watches what it does. Loading needs only two pieces of the game, copied from wow-ui-source
-- (forever, 1.60.1): Enum.TraitEdgeType (TraitConstantsDocumentation.lua) and
-- EventUtil.ContinueOnAddOnLoaded (EventUtil.lua). The talent window itself is not stood in:
-- these tests cover the saved plans, which the addon cleans as it loads.

-- This file runs under luajit, outside the game, and uses standard Lua's loadfile and io, which
-- the game doesn't have.
---@diagnostic disable: undefined-global, lowercase-global

local ADDON_NAME = "JustTheTrees"
local SOURCE = assert(io.open("Core.lua")):read("*a")
local PLAN_BUDGET = 51

-- Loads the addon with these saved plans, as the game does: the saved variables are set before
-- the addon's ADDON_LOADED. Returns the saved plans after the addon has cleaned them.
local function Load(saved)
	Enum = { TraitEdgeType = { VisualOnly = 0, DeprecatedRankConnection = 1, SufficientForAvailability = 2, RequiredForAvailability = 3, MutuallyExclusive = 4, DeprecatedSelectionOption = 5 } }
	-- An addon that isn't loaded yet runs the callback on its ADDON_LOADED; the talent window
	-- isn't loaded in these tests.
	local waiting = {}
	EventUtil = {}
	function EventUtil.ContinueOnAddOnLoaded(addOnName, callback)
		waiting[addOnName] = callback
	end
	JustTheTreesDB = saved
	assert(loadfile("Core.lua"))(ADDON_NAME, {})
	waiting[ADDON_NAME]()
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
	Equal(SOURCE:match('\nlocal VERSION = "([^"]+)"'), toc:match("## Version: (%S+)"), "VERSION")
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

if failures > 0 then
	io.write(failures .. " failed\n")
	os.exit(1)
end
io.write("all passed\n")
