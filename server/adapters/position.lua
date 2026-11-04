-- mz_racing - adapter de posicao server-side (OneSync).
--
-- O cliente NAO fornece coordenadas. A posicao vem do ped/veiculo do source
-- resolvido no servidor. Handles/network IDs sao transitorios; nao sao
-- identidade. Qualquer falha de leitura falha fechado.

MZRacing = MZRacing or {}
MZRacing.Adapters = MZRacing.Adapters or {}
MZRacing.Adapters.Position = MZRacing.Adapters.Position or {}

local Position = MZRacing.Adapters.Position

local function safeCall(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

function Position.get(source)
    local src = tonumber(source)
    if not src then return nil, 'position_unavailable' end

    local ped = safeCall(GetPlayerPed, src)
    if type(ped) ~= 'number' or ped == 0 then return nil, 'ped_not_found' end
    if safeCall(DoesEntityExist, ped) ~= true then return nil, 'position_unavailable' end

    local health = safeCall(GetEntityHealth, ped)
    if type(health) == 'number' and health <= 0 then return nil, 'player_dead' end

    local vehicle = safeCall(GetVehiclePedIsIn, ped, false)
    local vehicleValid = type(vehicle) == 'number' and vehicle ~= 0
        and safeCall(DoesEntityExist, vehicle) == true
    local coords = safeCall(GetEntityCoords, vehicleValid and vehicle or ped)
    if type(coords) ~= 'vector3' and type(coords) ~= 'table' then return nil, 'position_unavailable' end

    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z
        or x ~= x or y ~= y or z ~= z
        or x == math.huge or y == math.huge or z == math.huge
        or x == -math.huge or y == -math.huge or z == -math.huge then
        return nil, 'position_unavailable'
    end

    local isDriver = false
    if vehicleValid then
        local driver = safeCall(GetPedInVehicleSeat, vehicle, -1)
        isDriver = type(driver) == 'number' and driver == ped
    end

    return {
        ok = true,
        x = x, y = y, z = z,
        vehicle = vehicleValid,
        isDriver = isDriver,
        bucket = tonumber(safeCall(GetPlayerRoutingBucket, src)) or 0
    }
end
