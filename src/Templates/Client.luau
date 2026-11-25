return [[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsClient() then
    error("Client network module can only be required from the client.")
end

local Reliable: RemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent

--> Invocation timeouts (fork). A call that gets no reply within INVOCATION_TIMEOUT seconds is resumed with
--> INVOCATION_TIMED_OUT and fails. Its slot stays taken (holding INVOCATION_TIMED_OUT) until the late reply
--> arrives or another timeout period passes, so a late reply cannot reach the next call that is given the
--> same identifier.
local INVOCATION_TIMED_OUT = newproxy()

local function ExpireInvocation(InvocationIdentifier: number, Thread: thread)
    if Calls[InvocationIdentifier] ~= Thread then
        return
    end

    Calls[InvocationIdentifier] = INVOCATION_TIMED_OUT
    task.delay(INVOCATION_TIMEOUT, function()
        if Calls[InvocationIdentifier] == INVOCATION_TIMED_OUT then
            Calls[InvocationIdentifier] = nil
        end
    end)

    task.spawn(Thread, INVOCATION_TIMED_OUT)
end

local function StepReplication()
    if SendCursor <= 0 then
        return
    end

    local Buffer = buffer.create(SendCursor)
    buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
    Reliable:FireServer(Buffer, SendInstances)

    SendSize = 64
    SendCursor = 0
    SendOffset = 0
    SendBuffer = buffer.create(64)
    table.clear(SendInstances)
end
]]
