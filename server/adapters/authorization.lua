-- mz_racing - autorizacao global do organizador via owner canonico mz_core.

MZRacing = MZRacing or {}
MZRacing.Adapters = MZRacing.Adapters or {}
MZRacing.Adapters.Authorization = MZRacing.Adapters.Authorization or {}

local Authorization = MZRacing.Adapters.Authorization

function Authorization.hasOrganizerPermission(source)
    source = tonumber(source)
    local organizer = Config.Racing and Config.Racing.Organizer or {}
    local permission = type(organizer.Permission) == 'string' and organizer.Permission or ''
    if not source or source <= 0 or permission == '' then return false, 'permission_denied' end
    if GetResourceState('mz_core') ~= 'started' then return false, 'authorization_unavailable' end

    local ok, allowed = pcall(function()
        return exports.mz_core:HasGlobalPermission(source, permission)
    end)
    if not ok then return false, 'authorization_unavailable' end
    if allowed ~= true then return false, 'permission_denied' end
    return true
end
