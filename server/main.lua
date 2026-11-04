-- mz_racing - entrada server-side (Wave 5C).
--
-- Nao existe comando publico de criacao/start. Criacao/administracao sao
-- exports server-only e exigem CreatorResources configurado pelo dono do
-- servidor. Lobby/join/leave/checkpoint/status sao eventos de cliente e sempre
-- derivam source -> identidade no servidor.

local Service = MZRacing.SessionService
local Schema = MZRacing.Schema
local Clock = MZRacing.Clock
local Navigation = MZRacing.Adapters.Navigation
local Identity = MZRacing.Adapters.Identity
local Authorization = MZRacing.Adapters.Authorization
local Position = MZRacing.Adapters.Position
local Audit = MZRacing.Adapters.Audit

local RESOURCE = GetCurrentResourceName()
local responseSeq = {}
local organizerMutations = {}
local publishSession

Service.SetAdapters({
    clock = { now = function() return GetGameTimer() end },
    navigation = Navigation,
    identity = Identity,
    position = Position,
    audit = Audit
})

local function creatorAllowed(actor)
    if type(actor) ~= 'string' or actor == '' then return false end
    for _, allowed in ipairs(Config.Racing.CreatorResources or {}) do
        if allowed == actor then return true end
    end
    return false
end

local function exportActor()
    return GetInvokingResource()
end

local function sessionActorAllowed(sessionId, actor)
    if not creatorAllowed(actor) then return false end
    local session = Service.GetSession(sessionId)
    if not session then return false end
    return session.creatorResource == actor
end

local function nextSeq(source)
    local src = tonumber(source) or 0
    responseSeq[src] = (responseSeq[src] or 0) + 1
    return responseSeq[src]
end

local function clientResponse(source, action, result, err, requestId)
    local payload = {
        action = action,
        ok = result ~= nil,
        error = result == nil and (err or 'racing_error') or nil,
        requestId = requestId,
        seq = nextSeq(source)
    }
    if result and type(result) == 'table' then
        if action == 'catalog' or action == 'detail' or action:find('^organizer:') then
            payload.data = result
        else
            payload.session = result.session or (result.sessionId and result or nil)
            payload.participant = result.participant
            payload.nextCheckpoint = result.nextCheckpoint
            payload.results = result.results
            payload.idempotent = result.idempotent
        end
    end
    TriggerClientEvent('mz_racing:client:response', source, payload)
end

local ORGANIZER_ACTIONS = {
    bootstrap = 'organizer_bootstrap',
    list = 'organizer_list',
    routes = 'organizer_routes',
    detail = 'organizer_detail',
    create = 'organizer_create',
    openRegistration = 'organizer_action',
    start = 'organizer_action',
    cancel = 'organizer_action'
}

local ORGANIZER_MUTATIONS = {
    create = true, openRegistration = true, start = true, cancel = true
}

local function auditOrganizer(source, identity, action, outcome, reason, extra)
    if not Audit or type(Audit.operation) ~= 'function' then return end
    extra = type(extra) == 'table' and extra or {}
    Audit.operation('organizer.' .. tostring(action or 'unknown'), {
        action = action,
        outcome = outcome,
        reason = reason,
        source = source,
        characterId = identity and identity.characterId or nil,
        sessionId = extra.sessionId,
        routePublicId = extra.routePublicId,
        at = Clock.Now()
    })
end

local function cleanRequestId(value)
    if value == nil then return nil end
    if type(value) ~= 'string' or #value < 1 or #value > 64 then return nil end
    if not value:match('^[%w_:%-]+$') then return nil end
    return value
end

local function readPayload(payload)
    if type(payload) ~= 'table' then return nil, 'payload_invalid' end
    local sessionId = payload.sessionId
    if type(sessionId) ~= 'string' or #sessionId > 64 then return nil, 'session_id_invalid' end
    local valid, validErr = Schema.ValidateSessionId(sessionId)
    if not valid then return nil, validErr end
    return {
        sessionId = sessionId,
        role = payload.role,
        checkpointIndex = payload.checkpointIndex,
        requestId = cleanRequestId(payload.requestId)
    }
end

local function readCatalogPayload(payload)
    if type(payload) ~= 'table' then return nil, 'payload_invalid' end
    local requestId = cleanRequestId(payload.requestId)
    if not requestId then return nil, 'request_id_invalid' end
    return {
        page = payload.page,
        limit = payload.limit,
        state = payload.state,
        requestId = requestId
    }
end

local function readOrganizerPayload(payload)
    if type(payload) ~= 'table' then return nil, 'payload_invalid' end
    local action = type(payload.action) == 'string' and payload.action or ''
    if not ORGANIZER_ACTIONS[action] then return nil, 'action_invalid' end
    local requestId = cleanRequestId(payload.requestId)
    if not requestId then return nil, 'request_id_invalid' end
    return {
        action = action,
        requestId = requestId,
        data = type(payload.payload) == 'table' and payload.payload or {}
    }
end

local function clientIdentity(source)
    local identity, err = Identity.resolve(source)
    if not identity then return nil, err or 'identity_unavailable' end
    return identity
end

local function organizerAuthorized(source, action)
    local organizer = Config.Racing.Organizer or {}
    if Config.Racing.Enabled ~= true then return nil, 'racing_disabled' end
    if organizer.Enabled ~= true then return nil, 'organizer_disabled' end
    if not Service.CheckRate(source, ORGANIZER_ACTIONS[action], Clock.Now()) then
        return nil, 'rate_limited'
    end
    local identity, identityErr = clientIdentity(source)
    if not identity then
        auditOrganizer(source, nil, action, 'denied', identityErr)
        return nil, identityErr
    end
    if not Authorization or type(Authorization.hasOrganizerPermission) ~= 'function' then
        auditOrganizer(source, identity, action, 'denied', 'authorization_unavailable')
        return nil, 'authorization_unavailable'
    end
    local allowed, permissionErr = Authorization.hasOrganizerPermission(source)
    if allowed ~= true then
        auditOrganizer(source, identity, action, 'denied', permissionErr or 'permission_denied')
        return nil, permissionErr or 'permission_denied'
    end
    return identity
end

local function organizerRoutes(payload)
    payload = type(payload) == 'table' and payload or {}
    local organizer = Config.Racing.Organizer or {}
    local page = tonumber(payload.page) or 1
    if page < 1 or page % 1 ~= 0 then page = 1 end
    local limit = tonumber(payload.limit) or tonumber(organizer.DefaultPageSize) or 12
    if limit < 1 or limit % 1 ~= 0 then limit = tonumber(organizer.DefaultPageSize) or 12 end
    limit = math.min(limit, tonumber(organizer.MaxPageSize) or 24)
    local search = Schema.Trim(payload.search, 48)
    local result, err = Navigation.listPublishedRoutes({ page = page, limit = limit, search = search })
    if not result then return nil, err end

    local routes = {}
    for _, route in ipairs(type(result.routes) == 'table' and result.routes or {}) do
        if type(route) == 'table' and route.visibility == 'public' and route.isPublished == true then
            routes[#routes + 1] = {
                publicId = type(route.publicId) == 'string' and route.publicId:sub(1, 96) or '',
                title = Schema.Trim(route.title, 80),
                description = Schema.Trim(route.description, 300),
                routeType = Schema.Trim(route.routeType or 'generic', 24),
                revision = tonumber(route.revision),
                checkpointCount = tonumber(route.pointCount) or 0,
                totalDistance = tonumber(route.totalDistance) or 0,
                updatedAt = route.updatedAt,
                publishedAt = route.publishedAt
            }
        end
    end
    return {
        routes = routes,
        page = tonumber(result.page) or page,
        limit = tonumber(result.limit) or limit,
        hasNext = result.hasNext == true
    }
end

local function organizerSessionId(payload)
    local sessionId = type(payload) == 'table' and payload.sessionId or nil
    return Schema.ValidateSessionId(sessionId)
end

local function executeOrganizer(action, payload)
    local organizer = Config.Racing.Organizer or {}
    if action == 'list' then
        return Service.OrganizerList(RESOURCE, payload)
    elseif action == 'routes' then
        return organizerRoutes(payload)
    elseif action == 'bootstrap' then
        local sessions, sessionsErr = Service.OrganizerList(RESOURCE, {
            page = 1, limit = organizer.DefaultPageSize
        })
        if not sessions then return nil, sessionsErr end
        local routes, routesErr = organizerRoutes({ page = 1, limit = organizer.DefaultPageSize })
        return {
            sessions = sessions,
            routes = routes or { routes = {}, page = 1, limit = organizer.DefaultPageSize, hasNext = false },
            routesError = routes and nil or (routesErr or 'navigation_unavailable')
        }
    elseif action == 'detail' then
        local sessionId, sessionErr = organizerSessionId(payload)
        if not sessionId then return nil, sessionErr end
        return Service.OrganizerDetail(sessionId, RESOURCE)
    elseif action == 'create' then
        local publicId = type(payload.routePublicId) == 'string' and payload.routePublicId or nil
        if not publicId or #publicId < 1 or #publicId > 96 then return nil, 'route_public_id_invalid' end
        local revision = tonumber(payload.routeRevision)
        if not revision or revision < 1 or revision % 1 ~= 0 then return nil, 'route_revision_invalid' end
        local created, createErr = Service.Create(publicId, RESOURCE, { expectedRevision = revision })
        if not created then return nil, createErr end
        return Service.OrganizerDetail(created.sessionId, RESOURCE)
    end

    local sessionId, sessionErr = organizerSessionId(payload)
    if not sessionId then return nil, sessionErr end
    local result, err
    if action == 'openRegistration' then
        result, err = Service.OpenRegistration(sessionId, RESOURCE)
    elseif action == 'start' then
        result, err = Service.Start(sessionId, RESOURCE)
    elseif action == 'cancel' then
        result, err = Service.Cancel(sessionId, RESOURCE, 'organizer_cancelled')
    end
    if not result then return nil, err end
    publishSession(sessionId)
    return Service.OrganizerDetail(sessionId, RESOURCE)
end

publishSession = function(sessionId)
    local session = Service.GetSession(sessionId)
    if not session then return end
    for _, participant in pairs(session.participants or {}) do
        if tonumber(participant.source) then
            local identity = Identity.resolve(participant.source)
            if identity and identity.characterId == participant.characterId
                and identity.coreSessionId == participant.coreSessionId then
                local status = Service.Status(sessionId, identity)
                if status then clientResponse(participant.source, 'state', status) end
            end
        end
    end
end

--[[
    Exports server-only. O actor e GetInvokingResource(), nunca source de
    jogador. Lista vazia de CreatorResources = nenhuma criacao autorizada.
]]
exports('CreateRaceSession', function(routePublicId)
    local actor = exportActor()
    if not creatorAllowed(actor) then return nil, 'not_authorized' end
    return Service.Create(routePublicId, actor)
end)

exports('OpenRaceRegistration', function(sessionId)
    local actor = exportActor()
    if not sessionActorAllowed(sessionId, actor) then return nil, 'not_authorized' end
    local result, err = Service.OpenRegistration(sessionId, actor)
    if result then publishSession(sessionId) end
    return result, err
end)

exports('StartRaceSession', function(sessionId)
    local actor = exportActor()
    if not sessionActorAllowed(sessionId, actor) then return nil, 'not_authorized' end
    local result, err = Service.Start(sessionId, actor)
    if result then publishSession(sessionId) end
    return result, err
end)

exports('CancelRaceSession', function(sessionId, reason)
    local actor = exportActor()
    if not sessionActorAllowed(sessionId, actor) then return nil, 'not_authorized' end
    if type(reason) ~= 'string' then reason = 'operator_cancelled' end
    local result, err = Service.Cancel(sessionId, actor, reason:sub(1, 64))
    if result then publishSession(sessionId) end
    return result, err
end)

exports('FinishRaceSession', function(sessionId)
    local actor = exportActor()
    if not sessionActorAllowed(sessionId, actor) then return nil, 'not_authorized' end
    local result, err = Service.Finish(sessionId, actor)
    if result then publishSession(sessionId) end
    return result, err
end)

exports('GetRaceSession', function(sessionId)
    local actor = exportActor()
    if not sessionActorAllowed(sessionId, actor) then return nil, 'not_authorized' end
    return Service.GetAdmin(sessionId)
end)

exports('ListRaceSessions', function()
    local actor = exportActor()
    if not creatorAllowed(actor) then return nil, 'not_authorized' end
    return Service.List()
end)

exports('GetRaceStatusForSource', function(source, sessionId)
    local actor = exportActor()
    if not creatorAllowed(actor) then return nil, 'not_authorized' end
    local identity, err = clientIdentity(source)
    if not identity then return nil, err end
    return Service.Status(sessionId, identity)
end)

for _, eventName in ipairs({ 'join', 'leave', 'checkpoint', 'status', 'catalog', 'detail', 'organizer' }) do
    RegisterNetEvent('mz_racing:server:' .. eventName)
end

AddEventHandler('mz_racing:server:join', function(payload)
    local src = source
    if Config.Racing.Enabled ~= true then
        return clientResponse(src, 'join', nil, 'racing_disabled', type(payload) == 'table' and cleanRequestId(payload.requestId))
    end
    local clean, payloadErr = readPayload(payload)
    if not clean then return clientResponse(src, 'join', nil, payloadErr, type(payload) == 'table' and cleanRequestId(payload.requestId)) end
    if not Service.CheckRate(src, 'join', Clock.Now()) then
        return clientResponse(src, 'join', nil, 'rate_limited', clean.requestId)
    end
    local identity, identityErr = clientIdentity(src)
    if not identity then return clientResponse(src, 'join', nil, identityErr, clean.requestId) end
    local result, err = Service.Join(clean.sessionId, identity, clean.role)
    clientResponse(src, 'join', result, err, clean.requestId)
    if result then publishSession(clean.sessionId) end
end)

AddEventHandler('mz_racing:server:organizer', function(payload)
    local src = source
    local clean, payloadErr = readOrganizerPayload(payload)
    if not clean then
        return clientResponse(src, 'organizer:invalid', nil, payloadErr,
            type(payload) == 'table' and cleanRequestId(payload.requestId))
    end

    local identity, authorizationErr = organizerAuthorized(src, clean.action)
    if not identity then
        return clientResponse(src, 'organizer:' .. clean.action, nil, authorizationErr, clean.requestId)
    end

    local cacheKey = identity.coreSessionId .. ':' .. clean.requestId
    local sourceCache = organizerMutations[src]
    if ORGANIZER_MUTATIONS[clean.action] and sourceCache and sourceCache[cacheKey] then
        local cached = sourceCache[cacheKey]
        if cached.action ~= clean.action then
            return clientResponse(src, 'organizer:' .. clean.action, nil, 'request_id_conflict', clean.requestId)
        end
        return clientResponse(src, 'organizer:' .. clean.action, cached.result, cached.err, clean.requestId)
    end

    local ok, result, err = pcall(executeOrganizer, clean.action, clean.data)
    if not ok then result, err = nil, 'organizer_internal_error' end
    if ORGANIZER_MUTATIONS[clean.action] then
        sourceCache = sourceCache or {}
        organizerMutations[src] = sourceCache
        if not sourceCache[cacheKey] then
            local count = 0
            for _ in pairs(sourceCache) do count = count + 1 end
            if count >= 32 then sourceCache = {}; organizerMutations[src] = sourceCache end
            sourceCache[cacheKey] = { action = clean.action, result = result, err = err }
        end
        auditOrganizer(src, identity, clean.action, result and 'allowed' or 'rejected', err, {
            sessionId = result and result.sessionId or clean.data.sessionId,
            routePublicId = result and result.route and result.route.publicId or clean.data.routePublicId
        })
    end
    clientResponse(src, 'organizer:' .. clean.action, result, err, clean.requestId)
end)

AddEventHandler('mz_racing:server:leave', function(payload)
    local src = source
    if Config.Racing.Enabled ~= true then
        return clientResponse(src, 'leave', nil, 'racing_disabled', type(payload) == 'table' and cleanRequestId(payload.requestId))
    end
    local clean, payloadErr = readPayload(payload)
    if not clean then return clientResponse(src, 'leave', nil, payloadErr, type(payload) == 'table' and cleanRequestId(payload.requestId)) end
    if not Service.CheckRate(src, 'leave', Clock.Now()) then
        return clientResponse(src, 'leave', nil, 'rate_limited', clean.requestId)
    end
    local identity, identityErr = clientIdentity(src)
    if not identity then return clientResponse(src, 'leave', nil, identityErr, clean.requestId) end
    local result, err = Service.Leave(clean.sessionId, identity)
    clientResponse(src, 'leave', result, err, clean.requestId)
    if result then publishSession(clean.sessionId) end
end)

AddEventHandler('mz_racing:server:checkpoint', function(payload)
    local src = source
    if Config.Racing.Enabled ~= true then
        return clientResponse(src, 'checkpoint', nil, 'racing_disabled', type(payload) == 'table' and cleanRequestId(payload.requestId))
    end
    local clean, payloadErr = readPayload(payload)
    if not clean then return clientResponse(src, 'checkpoint', nil, payloadErr, type(payload) == 'table' and cleanRequestId(payload.requestId)) end
    if not Service.CheckRate(src, 'checkpoint', Clock.Now()) then
        return clientResponse(src, 'checkpoint', nil, 'rate_limited', clean.requestId)
    end
    local identity, identityErr = clientIdentity(src)
    if not identity then return clientResponse(src, 'checkpoint', nil, identityErr, clean.requestId) end
    local result, err = Service.Checkpoint(clean.sessionId, identity, clean.checkpointIndex)
    clientResponse(src, 'checkpoint', result, err, clean.requestId)
    if result then publishSession(clean.sessionId) end
end)

AddEventHandler('mz_racing:server:status', function(payload)
    local src = source
    if Config.Racing.Enabled ~= true then
        return clientResponse(src, 'status', nil, 'racing_disabled', type(payload) == 'table' and cleanRequestId(payload.requestId))
    end
    local clean, payloadErr = readPayload(payload)
    if not clean then return clientResponse(src, 'status', nil, payloadErr, type(payload) == 'table' and cleanRequestId(payload.requestId)) end
    if not Service.CheckRate(src, 'status', Clock.Now()) then
        return clientResponse(src, 'status', nil, 'rate_limited', clean.requestId)
    end
    local identity, identityErr = clientIdentity(src)
    if not identity then return clientResponse(src, 'status', nil, identityErr, clean.requestId) end
    local result, err = Service.Status(clean.sessionId, identity)
    clientResponse(src, 'status', result, err, clean.requestId)
end)

AddEventHandler('mz_racing:server:catalog', function(payload)
    local src = source
    local clean, payloadErr = readCatalogPayload(payload)
    if not clean then return clientResponse(src, 'catalog', nil, payloadErr) end
    if Config.Racing.Enabled ~= true then
        return clientResponse(src, 'catalog', nil, 'racing_disabled', clean.requestId)
    end
    if not Service.CheckRate(src, 'catalog', Clock.Now()) then
        return clientResponse(src, 'catalog', nil, 'rate_limited', clean.requestId)
    end
    local identity, identityErr = clientIdentity(src)
    if not identity then return clientResponse(src, 'catalog', nil, identityErr, clean.requestId) end
    local result, err = Service.Catalog(identity, clean)
    if result then
        result.navigationAvailable = type(GetResourceState) == 'function'
            and GetResourceState('mz_navigation') == 'started'
        if not result.navigationAvailable then result.warning = 'navigation_unavailable' end
    end
    clientResponse(src, 'catalog', result, err, clean.requestId)
end)

AddEventHandler('mz_racing:server:detail', function(payload)
    local src = source
    local clean, payloadErr = readPayload(payload)
    if not clean or not clean.requestId then
        return clientResponse(src, 'detail', nil, payloadErr or 'request_id_invalid')
    end
    if Config.Racing.Enabled ~= true then
        return clientResponse(src, 'detail', nil, 'racing_disabled', clean.requestId)
    end
    if not Service.CheckRate(src, 'detail', Clock.Now()) then
        return clientResponse(src, 'detail', nil, 'rate_limited', clean.requestId)
    end
    local identity, identityErr = clientIdentity(src)
    if not identity then return clientResponse(src, 'detail', nil, identityErr, clean.requestId) end
    local result, err = Service.Detail(clean.sessionId, identity)
    clientResponse(src, 'detail', result, err, clean.requestId)
end)

AddEventHandler('mz_core:server:identitySessionClosed', function(src, coreSessionId, reason)
    organizerMutations[tonumber(src) or 0] = nil
    for _, sessionId in ipairs(Service.HandleIdentityClosed(src, coreSessionId, reason) or {}) do
        publishSession(sessionId)
    end
end)

AddEventHandler('playerDropped', function()
    for _, sessionId in ipairs(Service.HandlePlayerDropped(source) or {}) do
        publishSession(sessionId)
    end
    responseSeq[tonumber(source) or 0] = nil
    organizerMutations[tonumber(source) or 0] = nil
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    Service.Reset()
end)

CreateThread(function()
    while true do
        Wait(tonumber(Config.Racing.TickIntervalMs) or 500)
        local ok, changed = pcall(Service.Tick)
        if not ok then
            print(('[mz_racing] tick error: %s'):format(tostring(changed)))
        else
            for _, sessionId in ipairs(changed or {}) do publishSession(sessionId) end
        end
    end
end)

print(('[mz_racing] ready enabled=%s creatorResources=%d'):format(
    tostring(Config.Racing.Enabled == true),
    #(Config.Racing.CreatorResources or {})
))
