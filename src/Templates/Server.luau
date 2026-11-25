return [[local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsServer() then
    error("Server network module can only be required from the server.")
end

local Reliable: RemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
if not Reliable then
    local RemoteEvent = Instance.new("RemoteEvent")
    RemoteEvent.Name = BASE_EVENT_NAME .. "_RELIABLE_REMOTE"
    RemoteEvent.Parent = ReplicatedStorage
    Reliable = RemoteEvent
end

local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent
if not Unreliable then
    local UnreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
    UnreliableRemoteEvent.Name = BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE"
    UnreliableRemoteEvent.Parent = ReplicatedStorage
    Unreliable = UnreliableRemoteEvent
end

local PlayersMap: {[Player]: BufferSave} = {}

--> Inbound hardening (Thaiban City fork). Everything a client sends passes AcceptPacket before a byte
--> of it is decoded, and is decoded under DecodePacket, so a hostile or broken packet costs at most
--> its own events and never throws into the remote's connection.
export type BLINK_DROP_REASON = "Malformed" | "Oversized" | "Instances" | "Events" | "Budget" | "Queue"
type DropHandler = (Player: Player, Reason: BLINK_DROP_REASON, Count: number, Detail: number) -> ()
type DecodeErrorHandler = (Player: Player, Channel: string, Message: string, Count: number) -> ()

local DropHandler: DropHandler? = nil
local DecodeErrorHandler: DecodeErrorHandler? = nil

local Budgets: {[Player]: {number}} = {}
local Reports: {[Player]: {[string]: {number}}} = {}

local Decoding = false
local DecodeRemaining = 0

--> How many entries each polled event's queue holds, so a client cannot grow one without bound.
local PolledSizes: {[any]: number} = {}
--> Events whose "no listener" hint has been printed once already.
local QueueWarned: {[string]: boolean} = {}

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
    Budgets[Player] = nil
    Reports[Player] = nil
end)

--> Counts a refusal and says whether it should be reported now: at most once a second per player and
--> kind, carrying how many refusals the report stands for, so a client cannot flood the output.
local function TakeReport(Player: Player, Kind: string): number?
    local PerPlayer = Reports[Player]
    if not PerPlayer then
        if Player.Parent == nil then
            return nil
        end

        PerPlayer = {}
        Reports[Player] = PerPlayer
    end

    local Entry = PerPlayer[Kind]
    if not Entry then
        Entry = {-math.huge, 0}
        PerPlayer[Kind] = Entry
    end

    Entry[2] += 1
    local Now = os.clock()
    if Now - Entry[1] < 1 then
        return nil
    end

    local Count = Entry[2]
    Entry[1] = Now
    Entry[2] = 0
    return Count
end

local function ReportDrop(Player: Player, Reason: BLINK_DROP_REASON, Detail: number)
    local Count = TakeReport(Player, Reason)
    if not Count then
        return
    end

    local Handler = DropHandler
    if Handler then
        --> Spawned: a handler that throws or yields must not reach back into the connection.
        task.spawn(Handler, Player, Reason, Count, Detail)
    else
        local Unit = if Reason == "Queue" then "event(s)" else "packet(s)"
        warn(`[Blink]: Refused {Count} {Unit} from {Player.Name} in the last second: {Reason} ({Detail}).`)
    end
end

--> An event or call arrived for a listener that is not connected yet, and its queue is full. The hint is
--> printed once per event for the developer; the refusals themselves are reported like any other drop.
local function ReportQueueFull(Player: Player, Event: string, Index: number)
    if not QueueWarned[Event] then
        QueueWarned[Event] = true
        warn(`[Blink]: The queue of "{Event}" is full ({MAX_QUEUED_EVENTS}), so further events are dropped until a listener is connected. Did you forget to implement one?`)
    end

    ReportDrop(Player, "Queue", Index)
end

--> Answers a call with a failure, the way an erroring listener is answered, so the client stops waiting.
local function AnswerFailure(Player: Player, Index: number, InvocationIdentifier: number)
    Load(PlayersMap[Player])
    local Position = Allocate(3)
    buffer.writeu8(SendBuffer, Position, Index)
    buffer.writeu8(SendBuffer, Position + 1, InvocationIdentifier)
    buffer.writeu8(SendBuffer, Position + 2, 0)
    PlayersMap[Player] = Save()
end

local function ReportDecodeError(Player: Player, Channel: string, Failure: any)
    local Count = TakeReport(Player, "Decode")
    if not Count then
        return
    end

    local Message = tostring(Failure)
    local Handler = DecodeErrorHandler
    if Handler then
        task.spawn(Handler, Player, Channel, Message, Count)
    else
        warn(`[Blink]: Failed to decode {Count} {Channel} packet(s) from {Player.Name} in the last second: {Message}`)
    end
end

local function InboundAccept(Player: Player, Size: number): boolean
    if INBOUND_BYTES_PER_SECOND <= 0 then
        return true
    end

    local Now = os.clock()
    local Budget = Budgets[Player]
    if not Budget then
        if Player.Parent == nil then
            return false
        end

        Budget = {INBOUND_BURST, Now}
        Budgets[Player] = Budget
    end

    local Tokens = math.min(INBOUND_BURST, Budget[1] + (Now - Budget[2]) * INBOUND_BYTES_PER_SECOND)
    local Cost = math.max(Size, INBOUND_PACKET_FLOOR)
    Budget[2] = Now

    if Tokens < Cost then
        Budget[1] = Tokens
        ReportDrop(Player, "Budget", Size)
        return false
    end

    Budget[1] = Tokens - Cost
    return true
end

local function AcceptPacket(Player: Player, Buffer: buffer, Instances: {Instance}): boolean
    if typeof(Buffer) ~= "buffer" or type(Instances) ~= "table" then
        ReportDrop(Player, "Malformed", 0)
        return false
    end

    local Size = buffer.len(Buffer)
    if Size > MAX_PACKET_SIZE then
        ReportDrop(Player, "Oversized", Size)
        return false
    end

    local InstanceCount = #Instances
    if InstanceCount > MAX_INSTANCES_PER_PACKET then
        ReportDrop(Player, "Instances", InstanceCount)
        return false
    end

    return InboundAccept(Player, Size)
end

--> Runs a channel's decode loop under pcall. A failure while decoding drops the rest of that packet and
--> is reported; a failure inside a Sync listener is the game's error, so it is raised on its own
--> thread and decoding carries on with the next event, which the cursor already points at.
local function DecodePacket(Decode: (Player: Player, Size: number) -> (), Player: Player, Size: number, Channel: string)
    DecodeRemaining = MAX_EVENTS_PER_PACKET
    while true do
        Decoding = true
        local Success, Failure = pcall(Decode, Player, Size)
        if Success then
            break
        end

        if Decoding then
            ReportDecodeError(Player, Channel, Failure)
            break
        end

        task.spawn(error, Failure, 0)
        if Player.Parent == nil then
            break
        end
    end

    Decoding = false
end

local function SetDropHandler(Handler: DropHandler?)
    DropHandler = Handler
end

local function SetDecodeErrorHandler(Handler: DecodeErrorHandler?)
    DecodeErrorHandler = Handler
end

local function StepReplication()
    for Player, Send in PlayersMap do
        if Send.Cursor <= 0 then
            continue
        end

        local Buffer = buffer.create(Send.Cursor)
        buffer.copy(Buffer, 0, Send.Buffer, 0, Send.Cursor)
        Reliable:FireClient(Player, Buffer, Send.Instances)

        Send.Size = 64
        Send.Cursor = 0
        Send.Buffer = buffer.create(64)
        table.clear(Send.Instances)
    end
end
]]
