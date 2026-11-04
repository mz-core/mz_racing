-- mz_racing - relogio monotonicamente injetavel.
--
-- Em runtime o main troca Now por GetGameTimer. Testes usam Clock.SetNow.
MZRacing = MZRacing or {}
MZRacing.Clock = MZRacing.Clock or {}

local Clock = MZRacing.Clock

Clock.nowProvider = function()
    return 0
end

function Clock.SetNowProvider(provider)
    assert(type(provider) == 'function', 'clock provider must be a function')
    Clock.nowProvider = provider
end

function Clock.Now()
    local ok, value = pcall(Clock.nowProvider)
    if not ok or type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
        return 0
    end
    return math.floor(value)
end
