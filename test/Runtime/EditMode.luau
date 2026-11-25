--> Fork (#81): outside a running game (stories, plugins, tests) the generated API keeps its shape.
--> lune run test/Runtime/EditMode.luau
local Mock = require("./Mock")
local process = require("@lune/process")

Mock.Compile(process.cwd, "test/Runtime/EditMode.blink")

local Failures = 0
local function Try(Label: string, Callback: () -> ())
	local Ok, Error = pcall(Callback)
	print(`{Ok and "PASS" or "FAIL"} {Label}{Ok and "" or ("  -> " .. tostring(Error))}`)
	Failures += Ok and 0 or 1
end

local Client = Mock.Load("test/Runtime/out/EditMode/Client.luau", "Client", { Running = false }).Module
Try("client On returns a disconnect function", function()
	local Disconnect = Client.Chat.On(function() end)
	assert(type(Disconnect) == "function", `On returned {typeof(Disconnect)}`)
	Disconnect()
end)
Try("client Iter loops zero times", function()
	for _ in Client.Feed.Iter() do
		error("Iter produced a value")
	end
end)
Try("client deprecated Next loops zero times", function()
	for _ in Client.Feed.Next() do
		error("Next produced a value")
	end
end)
Try("client Fire does nothing", function()
	Client.Ping.Fire(1)
	Client.Move.Fire(1)
end)
Try("client Invoke returns", function()
	Client.Ask.Invoke(1)
end)
Try("client StepReplication exists", function()
	Client.StepReplication()
end)

local Server = Mock.Load("test/Runtime/out/EditMode/Server.luau", "Server", { Running = false }).Module
Try("server On returns a disconnect function", function()
	local Disconnect = Server.Ping.On(function() end)
	assert(type(Disconnect) == "function", `On returned {typeof(Disconnect)}`)
	Disconnect()
	Server.Move.On(function() end)()
end)
Try("server function On does not error", function()
	Server.Ask.On(function()
		return 1
	end)
end)
Try("server Iter loops zero times", function()
	for _ in Server.Tick.Iter() do
		error("Iter produced a value")
	end
end)
Try("server Fire variants do nothing", function()
	local Player = {}
	Server.Chat.Fire(Player, "x")
	Server.Chat.FireAll("x")
	Server.Chat.FireList({ Player }, "x")
	Server.Chat.FireExcept(Player, "x")
end)
Try("server StepReplication and handler setters exist", function()
	Server.StepReplication()
	Server.SetDropHandler(function() end)
	Server.SetDecodeErrorHandler(function() end)
end)

process.exit(Failures)
