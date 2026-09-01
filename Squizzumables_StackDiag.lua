--[[ Squizzumables StackDiag.lua - "is this error ours?" instrumentation ]]
--
-- TEMPORARY DIAGNOSTIC (2026-09-01). Added to answer one question: a BugSack
-- entry reading "8x C stack overflow" with no stack and an empty Locals block.
--
-- Why the usual routes do not work here:
--   * There is no trace to read, and that is not a BugSack shortcoming. Its
--     grabError stores the error object first and only then calls
--     GetErrorStack, with the comment "in case something goes wrong whilst
--     calling them" -- and on a C stack overflow it does go wrong, because
--     debugstack() needs stack space that no longer exists. So the message is
--     kept and the stack and locals are not. Blank is the expected shape of
--     this error, and it carries no attribution.
--   * Bisecting by disabling addons means playing without them in the content
--     where the error actually happens.
--
-- So instead of asking "who errored", this asks "was OUR code on the stack
-- when it happened". Every reachable repeating entry point is wrapped, and if
-- the overflow lands inside one of ours we catch it AT OUR OWN BOUNDARY, where
-- the label is still known -- the xpcall handler runs before the stack unwinds
-- past us. Decisive in both directions:
--
--   * we catch one    -> it is ours, and we know which entry point;
--   * BugSack's count climbs while we never catch one
--                     -> it is not ours, and the search moves on.
--
-- Ported from the same diagnostic written for SquizzFrames (2026-08-29), which
-- cleared that addon. One thing added here: `report` lists what is actually
-- wrapped. Without that, "caught nothing" is ambiguous -- it could equally mean
-- nothing was being watched, and a diagnostic whose null result cannot be
-- interpreted is worse than none.
--
-- Everything is inert until switched on with /sqstackdiag. When off the cost is
-- one boolean test per wrapped call.
--
-- REMOVE THIS FILE, its .toc line and the cdmModule.eventFrame export in
-- Squizzumables_CDM.lua once the question is settled. It earns its place only
-- while that count is unexplained.

local BH = BH
if not BH then return end

local Diag = {}
BH.StackDiag = Diag

-- Live toggle rather than a load-time read: telling someone to /reload before
-- they can start collecting is how a diagnostic never gets run.
local enabled = false

-- Which of our entry points is currently executing. Restored rather than
-- cleared on the way out, so a wrapped path that drives another wrapped path
-- still reports the OUTERMOST one, which is the useful frame.
local crumb

local hits     = {}   -- [label] = count
local firstErr = {}   -- [label] = first raw error message, for the report
local total    = 0
local wrapped  = {}   -- [label] = true, for coverage reporting

-- Runs ON the erroring stack, which for a C stack overflow has essentially no
-- headroom left. Deliberately trivial: no string.format, no debugstack, no
-- table churn beyond one integer bump. Anything heavier risks a second
-- overflow inside the handler and loses the very data point we came for.
local function OnError(err)
    local key = crumb or "?"
    hits[key] = (hits[key] or 0) + 1
    if firstErr[key] == nil then firstErr[key] = err end
    total = total + 1
    return err
end

-- Wrap one function. Returns the replacement.
--
-- Return values are forwarded up to three deep; every site this is used on is
-- a void event/timer/update handler, so that is headroom rather than a limit.
function Diag.Wrap(label, fn)
    if type(fn) ~= "function" then return fn end
    return function(...)
        if not enabled then return fn(...) end
        local prev = crumb
        crumb = label
        local ok, r1, r2, r3 = xpcall(fn, OnError, ...)
        crumb = prev
        if ok then return r1, r2, r3 end
        -- Swallowed deliberately: re-raising would put the error back into
        -- BugSack indistinguishable from the ones we are trying to attribute,
        -- and this is a short-lived diagnostic, not a supported mode.
    end
end

-- Swap a frame's script handler for a wrapped copy. Tagged so re-running the
-- install (frames here are built lazily, so one pass at login misses some)
-- cannot wrap a wrapper and double-count.
local function WrapScript(frame, script, label)
    if not frame or not frame.GetScript then return end
    frame._sqDiagWrapped = frame._sqDiagWrapped or {}
    if frame._sqDiagWrapped[script] then return end
    local fn = frame:GetScript(script)
    if type(fn) ~= "function" then return end
    frame:SetScript(script, Diag.Wrap(label, fn))
    frame._sqDiagWrapped[script] = true
    wrapped[label] = true
end

-- C_Timer tickers keep their callback on the returned object. Undocumented, so
-- this is best-effort and simply does not claim coverage if the field is not a
-- function -- which is exactly why `report` lists what was wrapped.
local function WrapTicker(ticker, label)
    if type(ticker) ~= "table" then return end
    if ticker._sqDiagWrapped then return end
    if type(ticker._callback) ~= "function" then return end
    ticker._callback = Diag.Wrap(label, ticker._callback)
    ticker._sqDiagWrapped = true
    wrapped[label] = true
end

-- Re-runnable on purpose: several of these frames are created lazily (the Kel
-- alert frame on the first alert, the CDM tickers when the module starts), so
-- a single pass at login would silently miss them.
function Diag.Install()
    WrapScript(BH.frame,                "OnEvent",  "core events")
    WrapScript(BH.blindReminderTicker,  "OnLoop",   "blind reminder poll")
    WrapScript(BH.deathTallyTicker,     "OnLoop",   "death tally poll")
    WrapScript(BH.bresUpdater,          "OnLoop",   "bres counter poll")
    WrapScript(BH.kelAlertFrame,        "OnUpdate", "kel alert animation")

    local cdm = BH.cdm
    if cdm then
        WrapScript(cdm.eventFrame,      "OnEvent",  "cdm events")
        WrapTicker(cdm.soundPollTicker,             "cdm sound poll")
        WrapTicker(cdm.alertHookTicker,             "cdm hook sweep")
    end
end

local function CountWrapped()
    local n = 0
    for _ in pairs(wrapped) do n = n + 1 end
    return n
end

local function Report()
    Diag.Install()  -- pick up anything built since the last pass

    print("|cFF00FF00Squizzumables StackDiag|r")
    print(("  state: %s"):format(enabled and "|cff33ff33ON|r" or "|cffff5555OFF|r"))

    local n = CountWrapped()
    if n == 0 then
        print("|cFFFF5555  nothing wrapped -- run /sqstackdiag on first.|r")
        return
    end
    print(("  watching %d entry point(s):"):format(n))
    for label in pairs(wrapped) do
        print("    " .. label)
    end

    if total == 0 then
        print("  caught: |cff33ff33nothing|r")
        if enabled then
            print("  If BugSack's C stack overflow count is still climbing while this")
            print("  stays at nothing, the errors are |cff33ff33not from Squizzumables|r.")
        end
        return
    end

    print(("|cFFFF5555  caught %d error(s) inside Squizzumables:|r"):format(total))
    for label, n2 in pairs(hits) do
        print(("    |cffffd100%s|r  x%d  -- %s"):format(label, n2, tostring(firstErr[label])))
    end
end

function Diag.SetEnabled(on)
    enabled = on and true or false
    if enabled then
        Diag.Install()
        print(("|cFF00FF00Squizzumables StackDiag ON|r -- watching %d entry point(s)."):format(CountWrapped()))
        print("  Play normally, then /sqstackdiag report.")
        print("  Nothing caught while BugSack keeps counting = the errors are not ours.")
    else
        print("|cFFFF5555Squizzumables StackDiag OFF|r")
    end
end

function Diag.Clear()
    wipe(hits); wipe(firstErr); total = 0
    print("Squizzumables StackDiag: counters cleared.")
end

function Diag.IsEnabled() return enabled end

SLASH_SQSTACKDIAG1 = "/sqstackdiag"
SlashCmdList["SQSTACKDIAG"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(%S*)")
    if msg == "on" then Diag.SetEnabled(true)
    elseif msg == "off" then Diag.SetEnabled(false)
    elseif msg == "clear" then Diag.Clear()
    elseif msg == "report" then Report()
    else
        print("|cFF00FF00Squizzumables StackDiag|r -- attributes errors to this addon when there is no usable stack trace.")
        print("  /sqstackdiag on | off | report | clear")
    end
end
