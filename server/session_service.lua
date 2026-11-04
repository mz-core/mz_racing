-- mz_racing - dominio de sessoes de corrida (Wave 5B).
--
-- Sem persistencia, sem premio e sem SQL. O estado e efemero por
-- processo e e perdido em restart; isso e deliberado nesta fundacao.
--
-- O servico e puro: navegacao, identidade, posicao e auditoria entram por
-- adapters injetados. Testes nao precisam de FiveM/nativos.

MZRacing = MZRacing or {}
MZRacing.SessionService = MZRacing.SessionService or {}

local Service = MZRacing.SessionService
local Schema = MZRacing.Schema

local FINAL_STATES = { finished = true, cancelled = true, failed = true }
local ACTIVE_STATES = { registration = true, countdown = true, running = true }

Service.Sessions = {}
Service.CharacterSessions = {}
Service.RateBuckets = {}
Service.Adapters = {}

local idCounter = 0
math.randomseed(os.time())

local function nowMs()
    local clock = Service.Adapters.clock
    if clock and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now)
        if ok and type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge then
            return math.floor(value)
        end
    end
    return 0
end

local function enabled()
    return Config.Racing and Config.Racing.Enabled == true
end

local function audit(kind, payload)
    local adapter = Service.Adapters.audit
    if not adapter or type(adapter.record) ~= 'function' then return end
    pcall(adapter.record, kind, Schema.DeepCopy(payload or {}))
end

local function newSessionId()
    idCounter = idCounter + 1
    return ('race_%08x%04x%04x'):format(
        os.time() % 0xffffffff,
        math.random(0, 0xffff),
        idCounter % 0xffff
    )
end

local function validIdentity(identity)
    if type(identity) ~= 'table' then return nil, 'identity_unavailable' end
    local source = tonumber(identity.source)
    local characterId = tonumber(identity.characterId)
    if not source or source <= 0 or source % 1 ~= 0 then return nil, 'identity_unavailable' end
    if not characterId or characterId <= 0 or characterId % 1 ~= 0 then return nil, 'identity_unavailable' end
    if type(identity.citizenid) ~= 'string' or identity.citizenid == '' then return nil, 'identity_unavailable' end
    if type(identity.coreSessionId) ~= 'string' or identity.coreSessionId == '' then
        return nil, 'identity_unavailable'
    end
    if identity.active == false then return nil, 'identity_unavailable' end
    return {
        source = source,
        characterId = characterId,
        citizenid = identity.citizenid,
        coreSessionId = identity.coreSessionId
    }
end

local function identityCharacterKey(identity)
    return tostring(identity.characterId)
end

local function isFinal(session)
    return session ~= nil and FINAL_STATES[session.state] == true
end

local function stateError(code)
    return nil, code
end

local function participantKey(participant)
    return tostring(participant.characterId)
end

local function activeParticipantCount(session)
    local count = 0
    for _, participant in pairs(session.participants) do
        if participant.role == 'participant' and participant.status == 'active' then count = count + 1 end
    end
    return count
end

local function participantCount(session)
    local count = 0
    for _ in pairs(session.participants) do count = count + 1 end
    return count
end

local function activeObserverCount(session)
    local count = 0
    for _, participant in pairs(session.participants) do
        if participant.role == 'observer' and participant.status == 'active' then count = count + 1 end
    end
    return count
end

local function clearCharacterSession(session, participant)
    local key = participantKey(participant)
    if Service.CharacterSessions[key] == session.sessionId then
        Service.CharacterSessions[key] = nil
    end
end

local function clearSessionCharacters(session)
    for _, participant in pairs(session.participants) do
        clearCharacterSession(session, participant)
    end
end

local function setState(session, state, now)
    session.state = state
    session.updatedAt = now
    session.revision = (tonumber(session.revision) or 0) + 1
end

local function touch(session, now)
    session.updatedAt = now or nowMs()
    session.revision = (tonumber(session.revision) or 0) + 1
end

local function participantDTO(participant)
    if not participant then return nil end
    return {
        role = participant.role,
        status = participant.status,
        nextCheckpoint = participant.nextCheckpoint,
        finishedAt = participant.finishedAt,
        finishTimeMs = participant.finishTimeMs,
        finishPosition = participant.finishPosition
    }
end

local function sessionSummary(session)
    return {
        sessionId = session.sessionId,
        state = session.state,
        routePublicId = session.route.publicId,
        routeTitle = session.route.title,
        routeRevision = session.route.revision,
        checkpointCount = session.route.pointCount,
        participantCount = participantCount(session),
        activeParticipantCount = activeParticipantCount(session),
        minParticipants = session.minParticipants,
        maxParticipants = session.maxParticipants,
        joinable = session.state == 'registration',
        countdownEndsAt = session.countdownEndsAt,
        startedAt = session.startedAt,
        finishedAt = session.finishedAt,
        revision = session.revision
    }
end

local function sessionAdminDTO(session)
    local participants = {}
    for _, participant in pairs(session.participants) do
        participants[#participants + 1] = {
            characterId = participant.characterId,
            role = participant.role,
            status = participant.status,
            nextCheckpoint = participant.nextCheckpoint,
            finishPosition = participant.finishPosition,
            finishTimeMs = participant.finishTimeMs
        }
    end
    table.sort(participants, function(a, b) return a.characterId < b.characterId end)
    return {
        summary = sessionSummary(session),
        creatorResource = session.creatorResource,
        createdAt = session.createdAt,
        updatedAt = session.updatedAt,
        route = Schema.DeepCopy(session.route),
        participants = participants,
        results = Schema.DeepCopy(session.results)
    }
end

local function organizerSessionDTO(session, includeParticipants)
    local dto = {
        sessionId = session.sessionId,
        state = session.state,
        revision = session.revision,
        route = {
            publicId = session.route.publicId,
            title = session.route.title,
            description = includeParticipants and session.route.description or nil,
            routeType = session.route.routeType,
            revision = session.route.revision,
            checkpointCount = session.route.pointCount,
            totalDistance = session.route.totalDistance
        },
        participantCount = activeParticipantCount(session),
        observerCount = activeObserverCount(session),
        minParticipants = session.minParticipants,
        maxParticipants = session.maxParticipants,
        createdAt = session.createdAt,
        updatedAt = session.updatedAt,
        countdownEndsAt = session.countdownEndsAt,
        startedAt = session.startedAt,
        finishedAt = session.finishedAt,
        finishReason = session.finishReason,
        canOpenRegistration = session.state == 'created',
        canStart = session.state == 'registration'
            and activeParticipantCount(session) >= session.minParticipants,
        canCancel = not isFinal(session)
    }
    if not includeParticipants then return dto end

    local order = {}
    for index, key in ipairs(session.participantOrder) do order[key] = index end
    dto.participants = {}
    for key, participant in pairs(session.participants) do
        dto.participants[#dto.participants + 1] = {
            label = ('Competidor %02d'):format(order[key] or (#dto.participants + 1)),
            role = participant.role,
            status = participant.status,
            nextCheckpoint = participant.nextCheckpoint,
            finishPosition = participant.finishPosition,
            finishTimeMs = participant.finishTimeMs
        }
    end
    table.sort(dto.participants, function(a, b) return a.label < b.label end)
    return dto
end

local function visibleSession(session)
    return session and session.state ~= 'created'
end

local function findParticipantByCharacter(session, identity)
    if not session or not identity then return nil end
    return session.participants[tostring(identity.characterId)]
end

local function canEnter(session, identity, role)
    if session.state ~= 'registration' then return false, 'session_not_joinable' end
    if role == 'observer' and Config.Racing.AllowObservers == false then
        return false, 'role_not_allowed'
    end

    local existing = findParticipantByCharacter(session, identity)
    if existing and existing.status == 'active' then return false, 'already_joined' end
    if existing and existing.status == 'abandoned' then return true end

    local currentId = Service.CharacterSessions[tostring(identity.characterId)]
    if currentId and currentId ~= session.sessionId then
        local current = Service.Sessions[currentId]
        if current and not isFinal(current) then return false, 'character_in_other_session' end
    end
    if participantCount(session) >= session.maxParticipants then return false, 'session_full' end
    return true
end

local function publicSessionDTO(session, identity, includeDescription)
    local member = findParticipantByCharacter(session, identity)
    local canJoin, joinReason = canEnter(session, identity, 'participant')
    local canObserve, observeReason = canEnter(session, identity, 'observer')
    local now = nowMs()
    local dto = {
        sessionId = session.sessionId,
        title = session.route.title ~= '' and session.route.title or session.route.publicId,
        state = session.state,
        route = {
            publicId = session.route.publicId,
            title = session.route.title,
            routeType = session.route.routeType,
            checkpointCount = session.route.pointCount,
            totalDistance = session.route.totalDistance
        },
        participantCount = activeParticipantCount(session),
        observerCount = activeObserverCount(session),
        maxParticipants = session.maxParticipants,
        minParticipants = session.minParticipants,
        canJoin = canJoin == true,
        joinReason = canJoin and nil or joinReason,
        canObserve = canObserve == true,
        observeReason = canObserve and nil or observeReason,
        canLeave = member ~= nil and member.status == 'active',
        role = member and member.role or nil,
        memberStatus = member and member.status or nil,
        revision = session.revision,
        countdownRemainingMs = session.state == 'countdown' and session.countdownEndsAt
            and math.max(0, session.countdownEndsAt - now) or nil,
        elapsedMs = session.startedAt and math.max(0, math.min(now, session.finishedAt or now) - session.startedAt) or nil
    }
    if includeDescription then dto.route.description = session.route.description end
    return dto
end

local function publicResultsDTO(session, viewer)
    if not isFinal(session) or not viewer or viewer.role ~= 'participant' then return nil end
    local entries = {}
    local order = {}
    for index, key in ipairs(session.participantOrder) do order[key] = index end
    for key, participant in pairs(session.participants) do
        if participant.role == 'participant' then
            entries[#entries + 1] = {
                label = ('Competidor %02d'):format(order[key] or (#entries + 1)),
                status = participant.status,
                position = participant.finishPosition,
                finishTimeMs = participant.finishTimeMs,
                own = participant.characterId == viewer.characterId
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.position and b.position then return a.position < b.position end
        if a.position then return true end
        if b.position then return false end
        return a.label < b.label
    end)
    return {
        state = session.state,
        reason = session.finishReason,
        entries = entries,
        expiresInMs = session.finishedAt
            and math.max(0, (tonumber(Config.Racing.SessionRetainMs) or 600000) - (nowMs() - session.finishedAt)) or nil
    }
end

local function statusDTO(session, identity)
    local participant = findParticipantByCharacter(session, identity)
    if not participant then return nil, 'not_participant' end
    if participant.source ~= identity.source or participant.coreSessionId ~= identity.coreSessionId then
        return nil, 'identity_changed'
    end

    local nextCheckpoint = nil
    if participant.role == 'participant' and participant.status == 'active'
        and (session.state == 'countdown' or session.state == 'running') then
        local point = session.route.points[participant.nextCheckpoint]
        if point then
            nextCheckpoint = {
                index = participant.nextCheckpoint,
                total = session.route.pointCount,
                point = { x = point.x, y = point.y, z = point.z }
            }
        end
    end

    return {
        session = publicSessionDTO(session, identity, true),
        participant = participantDTO(participant),
        nextCheckpoint = nextCheckpoint,
        results = publicResultsDTO(session, participant)
    }
end

local function findParticipant(session, identity)
    return session and session.participants[identityCharacterKey(identity)] or nil
end

local function validateActor(session, actorResource)
    if type(actorResource) ~= 'string' or actorResource == '' then return false, 'not_authorized' end
    if session.creatorResource ~= actorResource then return false, 'not_authorized' end
    return true
end

function Service.SetAdapters(adapters)
    Service.Adapters = type(adapters) == 'table' and adapters or {}
end

function Service.SetIdGenerator(generator)
    if type(generator) == 'function' then
        newSessionId = generator
    end
end

function Service.IsEnabled()
    return enabled()
end

function Service.GetSession(sessionId)
    return Service.Sessions[sessionId]
end

function Service.CheckRate(source, action, now)
    local limits = Config.Racing and Config.Racing.RateLimits or {}
    local policy = limits[action]
    if not policy then return true end
    source = tonumber(source)
    if not source or source <= 0 then return false end
    now = tonumber(now) or nowMs()
    local key = ('%d:%s'):format(source, action)
    local bucket = Service.RateBuckets[key]
    if not bucket or now - bucket.startedAt >= policy.window then
        bucket = { startedAt = now, count = 0 }
        Service.RateBuckets[key] = bucket
    end
    bucket.count = bucket.count + 1
    return bucket.count <= policy.max
end

function Service.ResetSource(source)
    source = tonumber(source)
    if not source then return end
    local prefix = tostring(source) .. ':'
    for key in pairs(Service.RateBuckets) do
        if key:sub(1, #prefix) == prefix then Service.RateBuckets[key] = nil end
    end
end

function Service.Create(routePublicId, actorResource, options)
    if not enabled() then return stateError('racing_disabled') end
    if type(routePublicId) ~= 'string' or #routePublicId < 1 or #routePublicId > 96 then
        return stateError('route_public_id_invalid')
    end
    if type(actorResource) ~= 'string' or actorResource == '' then
        return stateError('not_authorized')
    end
    local sessionCount = 0
    for _ in pairs(Service.Sessions) do sessionCount = sessionCount + 1 end
    if sessionCount >= (tonumber(Config.Racing.MaxSessions) or 64) then
        return stateError('session_limit_reached')
    end

    local navigation = Service.Adapters.navigation
    if not navigation or type(navigation.getPublishedRoute) ~= 'function' then
        return stateError('navigation_unavailable')
    end
    local ok, route, routeErr = pcall(navigation.getPublishedRoute, routePublicId)
    if not ok then return stateError('navigation_unavailable') end
    if not route then return stateError(routeErr or 'route_not_found') end

    local normalized, normalizeErr = Schema.NormalizeRoute(route, Config.Racing)
    if not normalized then return stateError(normalizeErr) end
    options = type(options) == 'table' and options or {}
    if options.expectedRevision ~= nil then
        local expectedRevision = tonumber(options.expectedRevision)
        if not expectedRevision or expectedRevision < 1 or expectedRevision % 1 ~= 0 then
            return stateError('route_revision_invalid')
        end
        if normalized.revision ~= expectedRevision then return stateError('route_revision_conflict') end
    end

    local now = nowMs()
    local id
    for _ = 1, 5 do
        id = newSessionId()
        if type(id) == 'string' and #id <= 64 and not Service.Sessions[id] then break end
        id = nil
    end
    if not id then return stateError('session_id_generation_failed') end

    local session = {
        sessionId = id,
        state = 'created',
        createdAt = now,
        updatedAt = now,
        revision = 1,
        creatorResource = actorResource,
        minParticipants = math.max(1, tonumber(Config.Racing.MinParticipantsToStart) or 2),
        maxParticipants = math.max(1, tonumber(Config.Racing.MaxParticipants) or 32),
        route = {
            publicId = normalized.publicId,
            revision = normalized.revision,
            schemaVersion = normalized.schemaVersion,
            title = normalized.title,
            description = normalized.description,
            routeType = normalized.routeType,
            points = normalized.points,
            pointCount = normalized.pointCount,
            totalDistance = normalized.totalDistance,
            capturedAt = now,
            snapshotVersion = 1
        },
        participants = {},
        participantOrder = {},
        countdownEndsAt = nil,
        startedAt = nil,
        finishedAt = nil,
        finishCounter = 0,
        finishSequence = 0,
        results = {}
    }
    Service.Sessions[id] = session
    audit('session.create', { sessionId = id, routePublicId = normalized.publicId, routeRevision = normalized.revision })
    return sessionSummary(session)
end

function Service.OpenRegistration(sessionId, actorResource)
    if not enabled() then return stateError('racing_disabled') end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    local allowed, actorErr = validateActor(session, actorResource)
    if not allowed then return stateError(actorErr) end
    if isFinal(session) then return stateError('invalid_state') end
    if session.state == 'registration' then
        local dto = sessionSummary(session); dto.idempotent = true; return dto
    end
    if session.state ~= 'created' then return stateError('invalid_state') end
    setState(session, 'registration', nowMs())
    audit('session.registration', { sessionId = session.sessionId })
    return sessionSummary(session)
end

function Service.Join(sessionId, rawIdentity, role)
    if not enabled() then return stateError('racing_disabled') end
    local identity, identityErr = validIdentity(rawIdentity)
    if not identity then return stateError(identityErr) end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    if session.state ~= 'registration' then return stateError('session_not_joinable') end

    role = role == nil and 'participant' or role
    local validRole, roleErr = Schema.ValidateRole(role)
    if not validRole then return stateError(roleErr) end
    if validRole == 'observer' and Config.Racing.AllowObservers == false then
        return stateError('role_not_allowed')
    end

    local key = identityCharacterKey(identity)
    local currentSessionId = Service.CharacterSessions[key]
    if currentSessionId and currentSessionId ~= sessionId then
        local current = Service.Sessions[currentSessionId]
        if current and not isFinal(current) then return stateError('character_in_other_session') end
        Service.CharacterSessions[key] = nil
    end

    local participant = session.participants[key]
    if participant then
        if participant.status == 'active' then return stateError('already_joined') end
        if participant.status ~= 'abandoned' then return stateError('already_joined') end
        if session.state ~= 'registration' then return stateError('rejoin_not_allowed') end
        participant.source = identity.source
        participant.coreSessionId = identity.coreSessionId
        participant.status = 'active'
        participant.role = validRole
        participant.joinedAt = nowMs()
        Service.CharacterSessions[key] = sessionId
        touch(session, participant.joinedAt)
        audit('session.rejoin', { sessionId = sessionId, characterId = identity.characterId })
        local dto = sessionSummary(session); dto.participant = participantDTO(participant); dto.idempotent = false
        return dto
    end

    if participantCount(session) >= session.maxParticipants then return stateError('session_full') end
    participant = {
        characterId = identity.characterId,
        citizenid = identity.citizenid,
        source = identity.source,
        coreSessionId = identity.coreSessionId,
        role = validRole,
        status = 'active',
        joinedAt = nowMs(),
        nextCheckpoint = 1,
        lastCheckpointAt = nil,
        checkpointTimes = {},
        finishedAt = nil,
        finishTimeMs = nil,
        finishPosition = nil
    }
    session.participants[key] = participant
    session.participantOrder[#session.participantOrder + 1] = key
    Service.CharacterSessions[key] = sessionId
    touch(session, participant.joinedAt)
    audit('session.join', { sessionId = sessionId, characterId = identity.characterId, role = validRole })
    local dto = sessionSummary(session); dto.participant = participantDTO(participant)
    return dto
end

function Service.Start(sessionId, actorResource)
    if not enabled() then return stateError('racing_disabled') end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    local allowed, actorErr = validateActor(session, actorResource)
    if not allowed then return stateError(actorErr) end
    if session.state == 'countdown' or session.state == 'running' then
        local dto = sessionSummary(session); dto.idempotent = true; return dto
    end
    if session.state ~= 'registration' then return stateError('invalid_state') end
    if activeParticipantCount(session) < session.minParticipants then
        return stateError('not_enough_participants')
    end
    local now = nowMs()
    session.countdownEndsAt = now + math.max(0, tonumber(Config.Racing.CountdownMs) or 0)
    setState(session, 'countdown', now)
    audit('session.start', { sessionId = sessionId, countdownEndsAt = session.countdownEndsAt })
    return sessionSummary(session)
end

local function markParticipantFinished(session, participant, now)
    if participant.status ~= 'active' then return end
    participant.status = 'finished'
    participant.finishedAt = now
    participant.finishTimeMs = math.max(0, now - (session.startedAt or now))
    session.finishCounter = session.finishCounter + 1
    participant.finishPosition = session.finishCounter
    session.results[#session.results + 1] = {
        characterId = participant.characterId,
        finishPosition = participant.finishPosition,
        finishTimeMs = participant.finishTimeMs,
        finishedAt = now
    }
    clearCharacterSession(session, participant)
    audit('session.finish_participant', {
        sessionId = session.sessionId,
        characterId = participant.characterId,
        position = participant.finishPosition,
        finishTimeMs = participant.finishTimeMs
    })
end

local function markActiveDnf(session, now)
    for _, participant in pairs(session.participants) do
        if participant.status == 'active' then
            participant.status = 'dnf'
            participant.finishedAt = now
            participant.finishTimeMs = nil
            clearCharacterSession(session, participant)
        end
    end
end

local function finishSession(session, now, state, reason)
    if isFinal(session) then return end
    if state == 'finished' then
        markActiveDnf(session, now)
    else
        markActiveDnf(session, now)
    end
    session.finishedAt = now
    session.finishReason = reason
    setState(session, state, now)
    clearSessionCharacters(session)
    if state == 'finished' then
        table.sort(session.results, function(a, b)
            if a.finishPosition == b.finishPosition then return a.characterId < b.characterId end
            return a.finishPosition < b.finishPosition
        end)
        audit('session.finished', { sessionId = session.sessionId, reason = reason, results = session.results })
    elseif state == 'cancelled' then
        audit('session.cancelled', { sessionId = session.sessionId, reason = reason })
    else
        audit('session.failed', { sessionId = session.sessionId, reason = reason })
    end
end

local function maybeFinish(session, now)
    if session.state ~= 'running' then return end
    local active = 0
    for _, participant in pairs(session.participants) do
        if participant.role == 'participant' and participant.status == 'active' then active = active + 1 end
    end
    if active == 0 then
        local anyFinished = false
        for _, participant in pairs(session.participants) do
            if participant.status == 'finished' then anyFinished = true break end
        end
        if anyFinished then finishSession(session, now, 'finished', 'all_finished')
        else finishSession(session, now, 'failed', 'all_participants_lost') end
    end
end

function Service.Leave(sessionId, rawIdentity)
    if not enabled() then return stateError('racing_disabled') end
    local identity, identityErr = validIdentity(rawIdentity)
    if not identity then return stateError(identityErr) end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    local participant = findParticipant(session, identity)
    if not participant then return stateError('not_participant') end
    if participant.source ~= identity.source or participant.coreSessionId ~= identity.coreSessionId then
        return stateError('identity_changed')
    end
    if isFinal(session) then return stateError('invalid_state') end
    if participant.status ~= 'active' then return stateError('participant_inactive') end
    if session.state == 'registration' then
        session.participants[participantKey(participant)] = nil
        clearCharacterSession(session, participant)
        touch(session)
        audit('session.leave', { sessionId = sessionId, characterId = identity.characterId })
        if activeParticipantCount(session) == 0 then
            finishSession(session, nowMs(), 'cancelled', 'empty_registration')
        end
        return sessionSummary(session)
    end
    if session.state == 'countdown' or session.state == 'running' then
        participant.status = 'abandoned'
        participant.finishedAt = nowMs()
        participant.finishTimeMs = nil
        clearCharacterSession(session, participant)
        touch(session, participant.finishedAt)
        audit('session.leave', { sessionId = sessionId, characterId = identity.characterId })
        maybeFinish(session, nowMs())
        return sessionSummary(session)
    end
    return stateError('invalid_state')
end

function Service.Checkpoint(sessionId, rawIdentity, rawCheckpointIndex)
    if not enabled() then return stateError('racing_disabled') end
    local identity, identityErr = validIdentity(rawIdentity)
    if not identity then return stateError(identityErr) end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    if session.state ~= 'running' then return stateError('session_not_running') end
    local participant = findParticipant(session, identity)
    if not participant then return stateError('not_participant') end
    if participant.role ~= 'participant' then return stateError('observer_not_racer') end
    if participant.status ~= 'active' then return stateError('participant_inactive') end
    if participant.source ~= identity.source or participant.coreSessionId ~= identity.coreSessionId then
        return stateError('identity_changed')
    end

    local checkpointIndex, indexErr = Schema.ValidateCheckpointIndex(rawCheckpointIndex, session.route.pointCount)
    if not checkpointIndex then return stateError(indexErr) end
    if checkpointIndex < participant.nextCheckpoint then return stateError('checkpoint_duplicate') end
    if checkpointIndex > participant.nextCheckpoint then return stateError('checkpoint_out_of_order') end

    local checkpoint = session.route.points[checkpointIndex]
    local positionAdapter = Service.Adapters.position
    if not positionAdapter or type(positionAdapter.get) ~= 'function' then
        return stateError('position_unavailable')
    end
    local posOk, position, posErr = pcall(positionAdapter.get, identity.source)
    if not posOk or type(position) ~= 'table' or position.ok ~= true then
        return stateError(posErr or 'position_unavailable')
    end
    if position.dead == true then return stateError('player_dead') end
    if Config.Racing.RequireVehicle == true and not position.vehicle then
        return stateError('vehicle_required')
    end
    if Config.Racing.RequireDriver == true and position.vehicle and position.isDriver ~= true then
        return stateError('not_driver')
    end
    if not Schema.Finite(position.x) or not Schema.Finite(position.y) then
        return stateError('position_unavailable')
    end

    local distance
    if checkpoint.z ~= nil then
        if not Schema.Finite(position.z) then return stateError('position_unverifiable') end
        local dz = position.z - checkpoint.z
        local dx, dy = position.x - checkpoint.x, position.y - checkpoint.y
        distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if math.abs(dz) > (tonumber(Config.Racing.CheckpointZRadius) or 8.0) then
            return stateError('checkpoint_out_of_range')
        end
    else
        local dx, dy = position.x - checkpoint.x, position.y - checkpoint.y
        distance = math.sqrt(dx * dx + dy * dy)
    end
    if distance > (tonumber(Config.Racing.CheckpointRadius) or 15.0) then
        audit('checkpoint.out_of_range', {
            sessionId = sessionId, characterId = identity.characterId,
            checkpointIndex = checkpointIndex, distance = distance
        })
        return stateError('checkpoint_out_of_range')
    end

    local now = nowMs()
    if participant.lastCheckpointAt and checkpointIndex > 1 then
        local delta = now - participant.lastCheckpointAt
        if delta <= 0 then return stateError('checkpoint_too_fast') end
        if delta < (tonumber(Config.Racing.MinCheckpointIntervalMs) or 0) then
            audit('checkpoint.too_fast', {
                sessionId = sessionId, characterId = identity.characterId,
                checkpointIndex = checkpointIndex, deltaMs = delta
            })
            return stateError('checkpoint_too_fast')
        end
        local previous = session.route.points[checkpointIndex - 1]
        local segment = Schema.Distance3D(previous, checkpoint)
        if segment / (delta / 1000.0) > (tonumber(Config.Racing.MaxPlausibleSpeed) or 200.0) then
            audit('checkpoint.implausible', {
                sessionId = sessionId, characterId = identity.characterId,
                checkpointIndex = checkpointIndex, deltaMs = delta, distance = segment
            })
            return stateError('checkpoint_implausible')
        end
    end

    participant.lastCheckpointAt = now
    participant.nextCheckpoint = checkpointIndex + 1
    participant.checkpointTimes[checkpointIndex] = now
    touch(session, now)
    if Config.Racing.AuditAcceptedCheckpoints == true then
        audit('checkpoint.accepted', {
            sessionId = sessionId, characterId = identity.characterId,
            checkpointIndex = checkpointIndex, distance = distance
        })
    end

    if checkpointIndex == session.route.pointCount then
        markParticipantFinished(session, participant, now)
        maybeFinish(session, now)
    end

    return {
        session = sessionSummary(session),
        participant = participantDTO(participant)
    }
end

function Service.Cancel(sessionId, actorResource, reason)
    if not enabled() then return stateError('racing_disabled') end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    local allowed, actorErr = validateActor(session, actorResource)
    if not allowed then return stateError(actorErr) end
    if session.state == 'cancelled' then
        local dto = sessionSummary(session); dto.idempotent = true; return dto
    end
    if isFinal(session) then return stateError('invalid_state') end
    finishSession(session, nowMs(), 'cancelled', reason or 'operator_cancelled')
    return sessionSummary(session)
end

function Service.Finish(sessionId, actorResource)
    if not enabled() then return stateError('racing_disabled') end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    local allowed, actorErr = validateActor(session, actorResource)
    if not allowed then return stateError(actorErr) end
    if session.state == 'finished' then
        local dto = sessionSummary(session); dto.idempotent = true; return dto
    end
    if isFinal(session) then return stateError('invalid_state') end
    if session.state ~= 'running' then return stateError('invalid_state') end
    finishSession(session, nowMs(), 'finished', 'operator_finish')
    return sessionSummary(session)
end

function Service.Tick()
    if not enabled() then return {} end
    local now = nowMs()
    local changed = {}
    for _, session in pairs(Service.Sessions) do
        local revision = session.revision
        if session.state == 'countdown' and session.countdownEndsAt and now >= session.countdownEndsAt then
            session.startedAt = now
            for _, participant in pairs(session.participants) do
                if participant.status == 'active' then participant.lastCheckpointAt = nil end
            end
            setState(session, 'running', now)
            audit('session.running', { sessionId = session.sessionId, startedAt = now })
            maybeFinish(session, now)
        elseif session.state == 'running' and session.startedAt
            and now - session.startedAt > (tonumber(Config.Racing.MaxRaceDurationMs) or 900000) then
            finishSession(session, now, 'failed', 'race_timeout')
        elseif session.state == 'running' then
            maybeFinish(session, now)
        end
        if session.revision ~= revision then changed[#changed + 1] = session.sessionId end
    end
    Service.Prune(now)
    return changed
end

function Service.Prune(now)
    now = tonumber(now) or nowMs()
    local retain = tonumber(Config.Racing.SessionRetainMs) or 600000
    for sessionId, session in pairs(Service.Sessions) do
        if isFinal(session) and session.finishedAt and now - session.finishedAt >= retain then
            clearSessionCharacters(session)
            Service.Sessions[sessionId] = nil
        end
    end
end

function Service.Status(sessionId, rawIdentity)
    if not enabled() then return stateError('racing_disabled') end
    local identity, identityErr = validIdentity(rawIdentity)
    if not identity then return stateError(identityErr) end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    return statusDTO(session, identity)
end

function Service.Catalog(rawIdentity, payload)
    if not enabled() then return stateError('racing_disabled') end
    local identity, identityErr = validIdentity(rawIdentity)
    if not identity then return stateError(identityErr) end
    payload = type(payload) == 'table' and payload or {}

    local lobby = Config.Racing.Lobby or {}
    local page = tonumber(payload.page) or 1
    if page < 1 or page % 1 ~= 0 then page = 1 end
    local limit = tonumber(payload.limit) or tonumber(lobby.DefaultPageSize) or 12
    if limit < 1 or limit % 1 ~= 0 then limit = tonumber(lobby.DefaultPageSize) or 12 end
    limit = math.min(limit, tonumber(lobby.MaxPageSize) or 24)

    local stateFilter = tostring(payload.state or 'all')
    local allowedFilters = { all = true, registration = true, running = true, finished = true }
    if not allowedFilters[stateFilter] then stateFilter = 'all' end

    local rows = {}
    for _, session in pairs(Service.Sessions) do
        local matches = visibleSession(session)
        if stateFilter == 'registration' then matches = matches and session.state == 'registration'
        elseif stateFilter == 'running' then matches = matches and (session.state == 'countdown' or session.state == 'running')
        elseif stateFilter == 'finished' then matches = matches and isFinal(session) end
        if matches then rows[#rows + 1] = session end
    end
    table.sort(rows, function(a, b)
        if a.createdAt == b.createdAt then return a.sessionId < b.sessionId end
        return a.createdAt > b.createdAt
    end)

    local startIndex = (page - 1) * limit + 1
    local sessions = {}
    for index = startIndex, math.min(#rows, startIndex + limit - 1) do
        sessions[#sessions + 1] = publicSessionDTO(rows[index], identity, false)
    end
    return {
        sessions = sessions,
        page = page,
        limit = limit,
        hasNext = startIndex + limit - 1 < #rows,
        total = #rows
    }
end

function Service.Detail(sessionId, rawIdentity)
    if not enabled() then return stateError('racing_disabled') end
    local identity, identityErr = validIdentity(rawIdentity)
    if not identity then return stateError(identityErr) end
    local session = Service.Sessions[sessionId]
    if not visibleSession(session) then return stateError('session_not_found') end
    return publicSessionDTO(session, identity, true)
end

function Service.OrganizerList(actorResource, payload)
    if not enabled() then return stateError('racing_disabled') end
    if type(actorResource) ~= 'string' or actorResource == '' then return stateError('not_authorized') end
    payload = type(payload) == 'table' and payload or {}
    local organizer = Config.Racing.Organizer or {}
    local page = tonumber(payload.page) or 1
    if page < 1 or page % 1 ~= 0 then page = 1 end
    local limit = tonumber(payload.limit) or tonumber(organizer.DefaultPageSize) or 12
    if limit < 1 or limit % 1 ~= 0 then limit = tonumber(organizer.DefaultPageSize) or 12 end
    limit = math.min(limit, tonumber(organizer.MaxPageSize) or 24)
    local search = Schema.Trim(payload.search, 48):lower()

    local rows = {}
    for _, session in pairs(Service.Sessions) do
        local title = tostring(session.route.title or ''):lower()
        if session.creatorResource == actorResource and (search == '' or title:find(search, 1, true)) then
            rows[#rows + 1] = session
        end
    end
    table.sort(rows, function(a, b)
        if a.updatedAt == b.updatedAt then return a.sessionId < b.sessionId end
        return a.updatedAt > b.updatedAt
    end)

    local startIndex = (page - 1) * limit + 1
    local sessions = {}
    for index = startIndex, math.min(#rows, startIndex + limit - 1) do
        sessions[#sessions + 1] = organizerSessionDTO(rows[index], false)
    end
    return {
        sessions = sessions,
        page = page,
        limit = limit,
        hasNext = startIndex + limit - 1 < #rows,
        total = #rows
    }
end

function Service.OrganizerDetail(sessionId, actorResource)
    if not enabled() then return stateError('racing_disabled') end
    local session = Service.Sessions[sessionId]
    if not session or session.creatorResource ~= actorResource then
        return stateError('session_not_found')
    end
    return organizerSessionDTO(session, true)
end

function Service.GetAdmin(sessionId)
    if not enabled() then return stateError('racing_disabled') end
    local session = Service.Sessions[sessionId]
    if not session then return stateError('session_not_found') end
    return sessionAdminDTO(session)
end

function Service.List()
    if not enabled() then return stateError('racing_disabled') end
    local summaries = {}
    for _, session in pairs(Service.Sessions) do
        summaries[#summaries + 1] = sessionSummary(session)
    end
    table.sort(summaries, function(a, b) return a.sessionId < b.sessionId end)
    return summaries
end

function Service.HandleIdentityClosed(source, coreSessionId, reason)
    source = tonumber(source)
    if not source then return {} end
    Service.ResetSource(source)
    local now = nowMs()
    local changed = {}
    for _, session in pairs(Service.Sessions) do
        local revision = session.revision
        for _, participant in pairs(session.participants) do
            if participant.source == source
                and (coreSessionId == nil or participant.coreSessionId == coreSessionId)
                and participant.status == 'active' then
                participant.status = 'abandoned'
                participant.finishedAt = now
                clearCharacterSession(session, participant)
                touch(session, now)
                audit('session.identity_closed', {
                    sessionId = session.sessionId, characterId = participant.characterId,
                    reason = reason or 'identity_closed'
                })
            end
        end
        if session.state == 'registration' and activeParticipantCount(session) == 0 then
            finishSession(session, now, 'cancelled', 'identity_closed_empty')
        elseif session.state == 'running' then
            maybeFinish(session, now)
        end
        if session.revision ~= revision then changed[#changed + 1] = session.sessionId end
    end
    return changed
end

function Service.HandlePlayerDropped(source)
    return Service.HandleIdentityClosed(source, nil, 'player_dropped')
end

function Service.Reset()
    Service.Sessions = {}
    Service.CharacterSessions = {}
    Service.RateBuckets = {}
end
