-- mz_racing - auditoria de suspeitas sem banimento.
--
-- O consumidor externo (mz_banguard, admin, log) pode escutar o evento. Nao ha
-- integracao inventada, nao ha ban automatico e nao ha escrita em banco.

MZRacing = MZRacing or {}
MZRacing.Adapters = MZRacing.Adapters or {}
MZRacing.Adapters.Audit = MZRacing.Adapters.Audit or {}

local Audit = MZRacing.Adapters.Audit

local function safePayload(payload)
    payload = type(payload) == 'table' and payload or {}
    return {
        action = tostring(payload.action or ''):sub(1, 48),
        outcome = tostring(payload.outcome or ''):sub(1, 24),
        reason = tostring(payload.reason or ''):sub(1, 64),
        source = tonumber(payload.source),
        characterId = tonumber(payload.characterId),
        sessionId = type(payload.sessionId) == 'string' and payload.sessionId:sub(1, 64) or nil,
        routePublicId = type(payload.routePublicId) == 'string' and payload.routePublicId:sub(1, 96) or nil,
        at = tonumber(payload.at)
    }
end

function Audit.record(kind, payload)
    local safeKind = tostring(kind or 'unknown'):sub(1, 48)
    local safePayload = type(payload) == 'table' and payload or {}
    print(('[mz_racing][audit] %s session=%s character=%s'):format(
        safeKind,
        tostring(safePayload.sessionId or ''),
        tostring(safePayload.characterId or '')
    ))
    if Config.Racing.EmitSuspicionEvent == true and type(TriggerEvent) == 'function' then
        TriggerEvent('mz_racing:server:suspicion', {
            kind = safeKind,
            sessionId = safePayload.sessionId,
            characterId = safePayload.characterId,
            checkpointIndex = safePayload.checkpointIndex,
            reason = safePayload.reason,
            at = safePayload.at
        })
    end
end

function Audit.operation(kind, payload)
    local safeKind = tostring(kind or 'organizer.unknown'):sub(1, 48)
    local safe = safePayload(payload)
    print(('[mz_racing][audit] %s outcome=%s reason=%s character=%s session=%s'):format(
        safeKind, safe.outcome, safe.reason, tostring(safe.characterId or ''), tostring(safe.sessionId or '')
    ))
    if type(TriggerEvent) == 'function' then
        TriggerEvent('mz_racing:server:audit', {
            kind = safeKind,
            action = safe.action,
            outcome = safe.outcome,
            reason = safe.reason,
            source = safe.source,
            characterId = safe.characterId,
            sessionId = safe.sessionId,
            routePublicId = safe.routePublicId,
            at = safe.at
        })
    end
end
