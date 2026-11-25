-- lune run roundtrip.luau <Types.luau>: encodes values with the module's Write and decodes with its Read,
-- then compares key by key, so a placeholder left behind (false instead of nil) is a mismatch.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Types = luau.load(fs.readFile(process.args[1]))()

local function deepEqual(a, b, path)
	if type(a) ~= "table" or type(b) ~= "table" then
		if a ~= b then
			return false, `{path}: {tostring(a)} ~= {tostring(b)}`
		end
		return true
	end
	for k, v in a do
		local ok, why = deepEqual(v, b[k], `{path}.{k}`)
		if not ok then
			return false, why
		end
	end
	for k, v in b do
		if a[k] == nil then
			return false, `{path}.{k}: decoded has extra key = {tostring(v)}`
		end
	end
	return true
end

local function inner(i, withC)
	return { a = i, b = "in" .. i, c = withC and (1000 + i) or nil }
end

local full = {
	id = 513,
	name = "full",
	opt = 7,
	optStr = "s",
	optInner = inner(1, true),
	inner = inner(2, true),
	list = { inner(3, true), inner(4, false) },
	optList = { 1, 2, 3 },
	mood = "Sad",
	flags = { A = true, B = false, C = true },
	scores = { x = 1, y = 255 },
	flag = true,
	f = 3.25,
	shape = { kind = "Circle", r = 1.5, label = "lbl" },
	nested = { deep = { x = 9, y = 10 }, z = "zz" },
}
local sparse = {
	id = 0,
	name = "",
	inner = inner(5, false),
	list = {},
	mood = "Happy",
	flags = { A = false, B = false, C = false },
	scores = {},
	flag = false,
	f = -0.5,
	shape = { kind = "Square", side = 4 },
	nested = { deep = { x = 0 } },
}
local circleNoLabel = table.clone(sparse)
circleNoLabel.shape = { kind = "Circle", r = 2 }
circleNoLabel.optInner = inner(6, false)

local cases = { full = full, sparse = sparse, circleNoLabel = circleNoLabel }
local fails = 0
for name, value in cases do
	local decoded = Types.Outer.Read(Types.Outer.Write(value))
	local ok, why = deepEqual(value, decoded, name)
	print((ok and "PASS " or "FAIL ") .. name .. (why and (": " .. why) or ""))
	fails += ok and 0 or 1
end

local keywordCases = {
	present = {
		["end"] = 1,
		["function"] = "f",
		flags = { ["and"] = true, ["or"] = false },
		choice = { ["then"] = "Yes", ["do"] = 3 },
	},
	absent = { ["end"] = 2, flags = { ["and"] = false, ["or"] = true }, choice = { ["then"] = "No" } },
}
for name, value in keywordCases do
	local ok, why = deepEqual(value, Types.Keywords.Read(Types.Keywords.Write(value)), "keywords." .. name)
	print((ok and "PASS " or "FAIL ") .. "keywords." .. name .. (why and (": " .. why) or ""))
	fails += ok and 0 or 1
end

local many = { items = { full, sparse, circleNoLabel, sparse, full } }
local ok, why = deepEqual(many, Types.Many.Read(Types.Many.Write(many)), "many")
print((ok and "PASS " or "FAIL ") .. "many" .. (why and (": " .. why) or ""))
fails += ok and 0 or 1
process.exit(fails)
