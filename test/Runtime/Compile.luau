--> Fork: schemas the compiler must accept or refuse, and the diagnostic it gives.
--> lune run test/Runtime/Compile.luau
local fs = require("@lune/fs")
local process = require("@lune/process")

local Directory = "test/Runtime/out/Compile"
fs.writeDir(Directory)

local HEADER = 'option ServerOutput = "./Server.luau"\noption ClientOutput = "./Client.luau"\n'
local PING = "event Ping { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }\n"

--> { label, schema body, expected: "ok" or a substring of the diagnostic }
local CASES = {
	{
		"instance class with digits (#75)",
		"event Pick { From: Client, Type: Reliable, Call: SingleSync, Data: Instance(Vector3Value) }",
		"ok",
	},
	{
		"plain instance class",
		"event Pick { From: Client, Type: Reliable, Call: SingleSync, Data: Instance(Sound) }",
		"ok",
	},
	{
		"keyword event name",
		"event repeat { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }",
		"is a Luau keyword",
	},
	{ "keyword struct name", "struct end { a: u8 }", "is a Luau keyword" },
	{ "keyword field name is allowed", "export struct S { ['end']: u8, function: u8 }", "ok" },
	{
		"reserved API name",
		"event SetDropHandler { From: Client, Type: Reliable, Call: SingleSync, Data: u8 }",
		"Reserved identifier",
	},
	{
		"numeric limits",
		"option MaxPacketSize = 8192\noption InboundBurst = 16384\noption MaxQueuedEvents = 32\noption InvocationTimeout = 0\n"
			.. PING,
		"ok",
	},
	{ "limit of zero", "option MaxPacketSize = 0\n" .. PING, "Expected a whole number of at least 1" },
	{
		"burst below packet size",
		"option MaxPacketSize = 8192\noption InboundBurst = 4096\n" .. PING,
		"Expected at least MaxPacketSize",
	},
	{ "budget off", "option InboundBytesPerSecond = 0\n" .. PING, "ok" },
}

local Failures = 0
for Index, Case in CASES do
	local Schema = `{Directory}/case{Index}.blink`
	local Body = string.gsub(Case[2], "'", '"')
	--> Options must come before declarations, so a case's own options go right after the output options.
	fs.writeFile(Schema, HEADER .. Body .. "\n")
	local Result = process.exec("lune", { "run", "src/CLI/init.luau", Schema, "-y" })
	local Output = string.gsub(Result.stdout .. Result.stderr, "\27%[[%d;]*m", "")
	local Compiled = string.find(Output, "Network files generated", 1, true) ~= nil
	local Ok
	if Case[3] == "ok" then
		Ok = Compiled
	else
		Ok = not Compiled and string.find(Output, Case[3], 1, true) ~= nil
	end
	print(`{Ok and "PASS" or "FAIL"} {Case[1]}{Ok and "" or ("  -> " .. string.sub(Output, -300))}`)
	Failures += Ok and 0 or 1
end

process.exit(Failures)
