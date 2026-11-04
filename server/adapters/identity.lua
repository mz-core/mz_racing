-- mz_racing - adapter de identidade canonica (mz_core).
--
-- O source e apenas um handle transitorio. A chave de participante e o
-- characterId resolvido no servidor; coreSessionId detecta source reutilizado.

MZRacing = MZRacing or {}
MZRacing.Adapters = MZRacing.Adapters or {}
MZRacing.Adapters.Identity = MZRacing.Adapters.Identity or {}

local Identity = MZRacing.Adapters.Identity

function Identity.resolve(source)
    source = tonumber(source)
    if not source then return nil, 'identity_unavailable' end
    if GetResourceState('mz_core') ~= 'started' then return nil, 'identity_unavailable' end

    local ok, result = pcall(function()
        return exports.mz_core:ResolvePlayerIdentity(source)
    end)
    if not ok or type(result) ~= 'table' or result.ok ~= true then
        return nil, (type(result) == 'table' and result.error) or 'identity_unavailable'
    end
    if tonumber(result.source) ~= source then return nil, 'identity_changed' end
    if result.active == false then return nil, 'identity_inactive' end

    return {
        source = source,
        characterId = tonumber(result.characterId),
        citizenid = tostring(result.citizenid or ''),
        coreSessionId = tostring(result.sessionId or ''),
        active = result.active
    }
end
