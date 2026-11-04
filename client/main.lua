-- mz_racing - bridge, lobby focavel e HUD/checkpoints locais (Wave 5B).
-- O cliente apresenta estado autorizado; servidor continua dono de progresso e resultado.

local RESOURCE = GetCurrentResourceName()
local lobbyConfig = Config.Racing.Lobby or {}
local markerConfig = Config.Racing.Marker or {}

local organizerConfig = Config.Racing.Organizer or {}
local UI = {
    open = false, mode = nil, ownsFocus = false, pendingOpen = nil,
    pendingMode = nil, lastSeq = 0, requestGeneration = 0
}
local Runtime = {
    sessionId = nil, session = nil, participant = nil, nextCheckpoint = nil,
    results = nil, lastSubmitted = nil, lastSubmitAt = 0, finalHideAt = nil
}

local function isFinalState(state)
    return state == 'finished' or state == 'cancelled' or state == 'failed'
end

local function nuiMessage(action, data)
    SendNUIMessage({ action = action, data = type(data) == 'table' and data or {} })
end

local function notify(message, kind)
    local ok = pcall(function()
        exports['mz_notify']:Notify({
            type = kind or 'info', title = 'Corridas', message = message, duration = 3500
        })
    end)
    if not ok then print(('[mz_racing] %s'):format(tostring(message))) end
end

local function localized(pt, en)
    return Config.Locale == 'en-US' and en or pt
end

local function focusedByAnotherNui()
    if UI.open then return false end
    local ok, focused = pcall(IsNuiFocused)
    return ok and focused == true
end

local function requestId(prefix)
    UI.requestGeneration = UI.requestGeneration + 1
    return ('%s:%d:%d'):format(prefix, GetGameTimer(), UI.requestGeneration)
end

local function send(action, payload)
    TriggerServerEvent('mz_racing:server:' .. action, type(payload) == 'table' and payload or {})
end

local function request(action, payload, id)
    payload = type(payload) == 'table' and payload or {}
    payload.requestId = id or payload.requestId or requestId(action)
    send(action, payload)
    return payload.requestId
end

local function organizerRequest(action, payload, id)
    id = id or requestId('organizer:' .. action)
    send('organizer', { action = action, payload = type(payload) == 'table' and payload or {}, requestId = id })
    return id
end

local function resetRuntime(reason)
    Runtime.sessionId, Runtime.session, Runtime.participant = nil, nil, nil
    Runtime.nextCheckpoint, Runtime.results = nil, nil
    Runtime.lastSubmitted, Runtime.lastSubmitAt, Runtime.finalHideAt = nil, 0, nil
    nuiMessage('racing:runtimeReset', { reason = reason or 'reset' })
end

local function closeLobby(reason)
    UI.pendingOpen, UI.pendingMode = nil, nil
    if not UI.open then return end
    UI.open, UI.mode = false, nil
    nuiMessage('racing:close', { reason = reason or 'closed' })
    if UI.ownsFocus then
        UI.ownsFocus = false
        SetNuiFocus(false, false)
    end
end

local function openLobby(catalog)
    if focusedByAnotherNui() then
        UI.pendingOpen = nil
        notify(localized('Outra interface esta em uso.', 'Another interface is in use.'), 'error')
        return false, 'focus_unavailable'
    end
    UI.open, UI.mode, UI.ownsFocus, UI.pendingOpen, UI.pendingMode = true, 'lobby', true, nil, nil
    nuiMessage('racing:open', {
        locale = Config.Locale or 'pt-BR', catalog = catalog,
        requestTimeoutMs = tonumber(lobbyConfig.RequestTimeoutMs) or 6000
    })
    SetNuiFocus(true, true)
    return true
end

local function openOrganizer(data)
    if focusedByAnotherNui() then
        UI.pendingOpen, UI.pendingMode = nil, nil
        notify(localized('Outra interface esta em uso.', 'Another interface is in use.'), 'error')
        return false, 'focus_unavailable'
    end
    UI.open, UI.mode, UI.ownsFocus, UI.pendingOpen, UI.pendingMode = true, 'organizer', true, nil, nil
    nuiMessage('racing:organizerOpen', {
        locale = Config.Locale or 'pt-BR', bootstrap = data,
        refreshMs = tonumber(organizerConfig.RefreshMs) or 3000,
        requestTimeoutMs = tonumber(organizerConfig.RequestTimeoutMs) or 6000
    })
    SetNuiFocus(true, true)
    return true
end

local function openRaceLobby()
    if Config.Racing.Enabled ~= true then
        notify(localized('Corridas estao desativadas no servidor.', 'Racing is disabled on this server.'), 'error')
        return false, 'racing_disabled'
    end
    if UI.open then return true end
    if focusedByAnotherNui() then return false, 'focus_unavailable' end
    local id = requestId('catalog')
    UI.pendingOpen, UI.pendingMode = id, 'lobby'
    request('catalog', { page = 1, limit = lobbyConfig.DefaultPageSize, state = 'all' }, id)
    return true
end


local function openRaceOrganizer()
    if Config.Racing.Enabled ~= true then
        notify(localized('Corridas estao desativadas no servidor.', 'Racing is disabled on this server.'), 'error')
        return false, 'racing_disabled'
    end
    if organizerConfig.Enabled ~= true then
        notify(localized('Organizador de corridas esta desativado.', 'The race organizer is disabled.'), 'error')
        return false, 'organizer_disabled'
    end
    if UI.open then
        if UI.mode == 'organizer' then return true end
        return false, 'focus_unavailable'
    end
    if focusedByAnotherNui() then return false, 'focus_unavailable' end
    local id = requestId('organizer:bootstrap')
    UI.pendingOpen, UI.pendingMode = id, 'organizer'
    organizerRequest('bootstrap', {}, id)
    return true
end

local function applyRuntime(payload)
    if type(payload.session) ~= 'table' or type(payload.participant) ~= 'table' then return end
    local sessionId = payload.session.sessionId
    if type(sessionId) ~= 'string' then return end
    local incomingRevision = tonumber(payload.session.revision) or 0
    if Runtime.session and incomingRevision < (tonumber(Runtime.session.revision) or 0) then return end

    local finalHideAt = Runtime.sessionId == sessionId and Runtime.finalHideAt or nil
    Runtime.sessionId, Runtime.session, Runtime.participant = sessionId, payload.session, payload.participant
    Runtime.nextCheckpoint = type(payload.nextCheckpoint) == 'table' and payload.nextCheckpoint or nil
    Runtime.results = type(payload.results) == 'table' and payload.results or nil
    Runtime.finalHideAt = isFinalState(payload.session.state)
        and (finalHideAt or (GetGameTimer() + (tonumber(lobbyConfig.FinalHudMs) or 12000))) or nil
    if Runtime.nextCheckpoint and Runtime.lastSubmitted ~= Runtime.nextCheckpoint.index then
        Runtime.lastSubmitted = nil
    end
    nuiMessage('racing:state', {
        session = Runtime.session, participant = Runtime.participant,
        nextCheckpoint = Runtime.nextCheckpoint, results = Runtime.results,
        receivedAt = GetGameTimer()
    })
end

exports('JoinRace', function(sessionId, role)
    return request('join', { sessionId = sessionId, role = role })
end)
exports('LeaveRace', function(sessionId)
    return request('leave', { sessionId = sessionId })
end)
exports('SubmitCheckpoint', function(sessionId, checkpointIndex)
    return request('checkpoint', { sessionId = sessionId, checkpointIndex = checkpointIndex })
end)
exports('RequestRaceStatus', function(sessionId)
    return request('status', { sessionId = sessionId })
end)
exports('OpenRaceLobby', openRaceLobby)
exports('OpenRaceOrganizer', openRaceOrganizer)

RegisterNetEvent('mz_racing:client:response', function(payload)
    if type(payload) ~= 'table' then return end
    local seq = tonumber(payload.seq) or 0
    if seq <= UI.lastSeq then return end
    UI.lastSeq = seq

    if type(payload.action) == 'string' and payload.action:find('^organizer:') then
        local organizerAction = payload.action:sub(11)
        if organizerAction == 'bootstrap' and payload.requestId == UI.pendingOpen and UI.pendingMode == 'organizer' then
            if payload.ok == true then
                openOrganizer(payload.data)
            else
                UI.pendingOpen, UI.pendingMode = nil, nil
                notify(localized('Organizador de corridas indisponivel.', 'The race organizer is unavailable.'), 'error')
            end
        end
        if payload.ok ~= true and UI.open and UI.mode == 'organizer'
            and (payload.error == 'permission_denied' or payload.error == 'authorization_unavailable'
                or payload.error == 'identity_changed' or payload.error == 'identity_unavailable'
                or payload.error == 'organizer_disabled'
                or payload.error == 'racing_disabled') then
            closeLobby(payload.error)
        end
        nuiMessage('racing:organizerResponse', payload)
        TriggerEvent('mz_racing:client:event', payload)
        return
    end

    if payload.action == 'catalog' and payload.requestId == UI.pendingOpen then
        if payload.ok == true then
            openLobby(payload.data)
        else
            UI.pendingOpen = nil
            notify(payload.error == 'racing_disabled'
                and localized('Corridas estao desativadas.', 'Racing is disabled.')
                or localized('Lobby de corridas indisponivel.', 'The racing lobby is unavailable.'), 'error')
        end
    end
    if payload.action == 'join' and payload.ok == true and payload.session then
        Runtime.sessionId = payload.session.sessionId
        closeLobby('joined')
        request('status', { sessionId = Runtime.sessionId })
    elseif payload.action == 'leave' and payload.ok == true then
        resetRuntime('left')
    elseif payload.action == 'status' or payload.action == 'state' or payload.action == 'checkpoint' then
        if payload.ok == true then applyRuntime(payload) end
    end
    if payload.ok ~= true and (payload.action == 'status' or payload.action == 'state')
        and (payload.error == 'session_not_found' or payload.error == 'not_participant'
            or payload.error == 'identity_changed' or payload.error == 'racing_disabled') then
        resetRuntime(payload.error)
    end
    if payload.action == 'checkpoint' and payload.ok ~= true then Runtime.lastSubmitted = nil end
    nuiMessage('racing:response', payload)
    TriggerEvent('mz_racing:client:event', payload)
end)

RegisterNUICallback('racingReady', function(_, cb)
    cb({ ok = true, locale = Config.Locale or 'pt-BR', enabled = Config.Racing.Enabled == true,
        requestTimeoutMs = tonumber(lobbyConfig.RequestTimeoutMs) or 6000 })
end)

RegisterNUICallback('racingRequest', function(data, cb)
    data = type(data) == 'table' and data or {}
    local action = tostring(data.action or '')
    local allowed = { catalog = true, detail = true, join = true, leave = true, status = true }
    if not allowed[action] then cb({ ok = false, error = 'action_invalid' }); return end
    local payload = type(data.payload) == 'table' and data.payload or {}
    local id = request(action, payload, type(data.requestId) == 'string' and data.requestId or nil)
    cb({ ok = true, pending = true, requestId = id })
end)

RegisterNUICallback('racingOrganizerRequest', function(data, cb)
    data = type(data) == 'table' and data or {}
    local action = tostring(data.action or '')
    local allowed = {
        bootstrap = true, list = true, routes = true, detail = true, create = true,
        openRegistration = true, start = true, cancel = true
    }
    if not allowed[action] then cb({ ok = false, error = 'action_invalid' }); return end
    local id = organizerRequest(action, type(data.payload) == 'table' and data.payload or {},
        type(data.requestId) == 'string' and data.requestId or nil)
    cb({ ok = true, pending = true, requestId = id })
end)

RegisterNUICallback('racingClose', function(_, cb)
    closeLobby('closed')
    cb({ ok = true })
end)

local command = tostring(lobbyConfig.Command or '')
if command ~= '' then RegisterCommand(command, openRaceLobby, false) end
local organizerCommand = tostring(organizerConfig.Command or '')
if organizerCommand ~= '' then RegisterCommand(organizerCommand, openRaceOrganizer, false) end

RegisterNetEvent('mz_core:client:characterSelectionRequired', function()
    closeLobby('identity_changed')
    resetRuntime('identity_changed')
end)
RegisterNetEvent('mz_core:client:playerLoaded', function()
    closeLobby('identity_changed')
    resetRuntime('identity_changed')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    closeLobby('resource_stop')
    resetRuntime('resource_stop')
end)

CreateThread(function()
    while true do
        local waitMs = 1000
        if Runtime.sessionId then
            if Runtime.finalHideAt and GetGameTimer() >= Runtime.finalHideAt then
                resetRuntime('final_timeout')
            else
                waitMs = math.max(500, tonumber(lobbyConfig.StatusPollMs) or 1500)
                request('status', { sessionId = Runtime.sessionId })
            end
        elseif UI.open and UI.mode == 'lobby' then
            waitMs = math.max(1000, tonumber(lobbyConfig.RefreshMs) or 5000)
            request('catalog', { page = 1, limit = lobbyConfig.DefaultPageSize, state = 'all' })
        end
        Wait(waitMs)
    end
end)

local function checkpointZ(point, playerZ)
    if tonumber(point.z) then return tonumber(point.z) end
    local ok, found, groundZ = pcall(GetGroundZFor_3dCoord, point.x, point.y, playerZ + 150.0, false)
    if ok and found == true and tonumber(groundZ) then return tonumber(groundZ) end
    return playerZ
end

CreateThread(function()
    while true do
        local checkpoint, session, participant = Runtime.nextCheckpoint, Runtime.session, Runtime.participant
        if not checkpoint or type(checkpoint.point) ~= 'table' or not session or not participant or participant.role ~= 'participant'
            or participant.status ~= 'active' or session.state ~= 'running' then
            Wait(250)
        else
            local point = checkpoint.point
            local coords = GetEntityCoords(PlayerPedId())
            local dx, dy = coords.x - point.x, coords.y - point.y
            local distance2d = math.sqrt(dx * dx + dy * dy)
            if distance2d <= (tonumber(markerConfig.DrawDistance) or 350.0) then
                local z = checkpointZ(point, coords.z)
                local color, scale = markerConfig.Color or {}, tonumber(markerConfig.Scale) or 7.0
                DrawMarker(tonumber(markerConfig.Type) or 1, point.x, point.y, z - 1.0,
                    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, scale, scale, 1.25,
                    tonumber(color.r) or 242, tonumber(color.g) or 184,
                    tonumber(color.b) or 32, tonumber(color.a) or 150,
                    false, true, 2, false, nil, nil, false)
            end

            local dz = point.z and math.abs(coords.z - point.z) or 0.0
            local inRange = distance2d <= (tonumber(markerConfig.SubmitRadius) or 10.0)
                and (point.z == nil or dz <= (tonumber(Config.Racing.CheckpointZRadius) or 8.0))
            local now = GetGameTimer()
            if inRange and (Runtime.lastSubmitted ~= checkpoint.index or now - Runtime.lastSubmitAt >= 1200) then
                Runtime.lastSubmitted, Runtime.lastSubmitAt = checkpoint.index, now
                request('checkpoint', { sessionId = Runtime.sessionId, checkpointIndex = checkpoint.index })
            end
            Wait(0)
        end
    end
end)
