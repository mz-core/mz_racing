-- mz_racing - schema puro (sem natives/FiveM).
--
-- Este modulo nao acessa banco, NUI, mz_navigation ou natives. Ele valida o
-- snapshot recebido pelo adapter read-only e devolve um DTO copiado.

MZRacing = MZRacing or {}
MZRacing.Schema = MZRacing.Schema or {}

local Schema = MZRacing.Schema

local MAX_SESSION_ID = 64
local MAX_TITLE = 80
local MAX_DESCRIPTION = 300
local MAX_PUBLIC_ID = 96

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function trim(value, maximum)
    if type(value) ~= 'string' then return '' end
    local text = value:gsub('[%z\1-\31\127]', ' ')
    text = text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #text > maximum then
        text = text:sub(1, maximum):gsub('%s+$', '')
    end
    return text
end

function Schema.Finite(value)
    return finite(value)
end

function Schema.Trim(value, maximum)
    return trim(value, maximum)
end

function Schema.ValidateSessionId(value)
    if type(value) ~= 'string' or #value < 6 or #value > MAX_SESSION_ID then
        return nil, 'session_id_invalid'
    end
    if not value:match('^[a-z][a-z0-9_%-:]+$') then
        return nil, 'session_id_invalid'
    end
    return value
end

function Schema.ValidateCheckpointIndex(value, maximum)
    local index = tonumber(value)
    if not index or index % 1 ~= 0 or index < 1 or index > (tonumber(maximum) or 0) then
        return nil, 'checkpoint_index_invalid'
    end
    return index
end

function Schema.ValidateRole(value)
    if value == nil or value == '' then return 'participant' end
    if value == 'participant' or value == 'observer' then return value end
    return nil, 'role_invalid'
end

function Schema.NormalizePoint(raw, config)
    config = config or Config.Racing
    if type(raw) ~= 'table' then return nil, 'route_point_invalid' end
    local x, y, z = tonumber(raw.x), tonumber(raw.y), tonumber(raw.z)
    if not finite(x) or not finite(y) then return nil, 'route_point_invalid' end
    if math.abs(x) > config.MaxWorldCoord or math.abs(y) > config.MaxWorldCoord then
        return nil, 'route_point_out_of_bounds'
    end
    if raw.z ~= nil then
        if not finite(z) or z < config.MinZ or z > config.MaxZ then
            return nil, 'route_z_out_of_bounds'
        end
    else
        z = nil
    end
    return { x = x, y = y, z = z }
end

local function distance2d(a, b)
    if not a or not b then return 0.0 end
    local dx, dy = b.x - a.x, b.y - a.y
    return math.sqrt(dx * dx + dy * dy)
end

function Schema.Distance2D(a, b)
    return distance2d(a, b)
end

function Schema.Distance3D(a, b)
    if not a or not b then return 0.0 end
    local dx, dy = b.x - a.x, b.y - a.y
    local dz = (a.z ~= nil and b.z ~= nil) and (b.z - a.z) or 0.0
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--[[
    Valida o DTO de mz_navigation.GetPublishedRoute e copia apenas os campos
    necessarios. Nao aceita lista (sem points), rota privada, rascunho, revisao
    ausente ou geometria invalida.
]]
function Schema.NormalizeRoute(route, config)
    config = config or Config.Racing
    if type(route) ~= 'table' then return nil, 'route_invalid' end

    local publicId = route.publicId
    if type(publicId) ~= 'string' or publicId == '' or #publicId > MAX_PUBLIC_ID then
        return nil, 'route_contract_incomplete'
    end
    if route.visibility ~= 'public' or route.isPublished ~= true then
        return nil, 'route_not_public'
    end
    local revision = tonumber(route.revision)
    if not revision or revision < 1 or revision % 1 ~= 0 then
        return nil, 'route_contract_incomplete'
    end
    if type(route.points) ~= 'table' or #route.points < 2 then
        return nil, 'route_contract_incomplete'
    end
    if #route.points > config.MaxCheckpoints then
        return nil, 'route_checkpoints_too_many'
    end

    local points, previous = {}, nil
    for index = 1, #route.points do
        local point, err = Schema.NormalizePoint(route.points[index], config)
        if not point then return nil, err end
        if previous and distance2d(previous, point) < config.MinCheckpointDistance then
            return nil, 'route_point_duplicate'
        end
        points[index] = point
        previous = point
    end

    local totalDistance = tonumber(route.totalDistance)
    if totalDistance ~= nil and (not finite(totalDistance) or totalDistance < 0) then
        totalDistance = nil
    end

    return {
        publicId = publicId,
        revision = revision,
        schemaVersion = tonumber(route.schemaVersion) or 1,
        title = trim(route.title, MAX_TITLE),
        description = trim(route.description, MAX_DESCRIPTION),
        routeType = trim(route.routeType or 'generic', 24),
        points = points,
        pointCount = #points,
        totalDistance = totalDistance or 0.0
    }
end

function Schema.DeepCopy(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for key, entry in pairs(value) do
        copy[key] = Schema.DeepCopy(entry)
    end
    return copy
end
