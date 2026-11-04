-- mz_racing - adapter read-only de mz_navigation.
--
-- Nao consulta tabelas de rotas. Sem mz_navigation iniciado, falha fechado.

MZRacing = MZRacing or {}
MZRacing.Adapters = MZRacing.Adapters or {}
MZRacing.Adapters.Navigation = MZRacing.Adapters.Navigation or {}

local Navigation = MZRacing.Adapters.Navigation

local function available()
    return GetResourceState('mz_navigation') == 'started'
end

function Navigation.listPublishedRoutes(payload)
    if not available() then return nil, 'navigation_unavailable' end
    local ok, result, err = pcall(function()
        return exports.mz_navigation:ListPublishedRoutes(type(payload) == 'table' and payload or {})
    end)
    if not ok then return nil, 'navigation_unavailable' end
    if type(result) ~= 'table' then return nil, err or 'routes_unavailable' end
    return result
end

function Navigation.getPublishedRoute(publicId)
    if not available() then
        return nil, 'navigation_unavailable'
    end
    if type(publicId) ~= 'string' or publicId == '' then
        return nil, 'route_public_id_invalid'
    end

    local ok, route, err = pcall(function()
        return exports.mz_navigation:GetPublishedRoute(publicId)
    end)
    if not ok then return nil, 'navigation_unavailable' end
    if type(route) ~= 'table' then return nil, err or 'route_not_found' end
    return route
end
