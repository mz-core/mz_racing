-- mz_racing - configuracao de sessoes e experiencia visual (Wave 5C).
--
-- Tudo desabilitado por padrao. Nao existe comando publico de criacao.
-- A criacao ocorre apenas por export server-side autorizado por resource.

Config = Config or {}
Config.Locale = Config.Locale or 'pt-BR'

Config.Racing = {
    Enabled = false,

    -- Caller server-side autorizado a criar/iniciar/cancelar sessoes.
    -- Lista vazia = nenhum export de administracao autorizado (fail closed).
    -- Exemplo futuro, somente depois de existir um resource organizador real:
    -- CreatorResources = { 'mz_racing_organizer' }
    CreatorResources = {},

    MaxParticipants = 32,
    MinParticipantsToStart = 2,
    MaxSessions = 64,

    CountdownMs = 3000,
    MaxRaceDurationMs = 900000,
    TickIntervalMs = 500,
    SessionRetainMs = 600000,

    Lobby = {
        Command = 'corridas',
        DefaultPageSize = 12,
        MaxPageSize = 24,
        StatusPollMs = 1500,
        RefreshMs = 5000,
        RequestTimeoutMs = 6000,
        FinalHudMs = 12000
    },

    -- Painel operacional. Exige tambem Racing.Enabled=true e a capability
    -- server-side abaixo; nenhuma permissao e concedida automaticamente.
    Organizer = {
        Enabled = false,
        Command = 'organizarcorridas',
        Permission = 'mz.racing.organize',
        DefaultPageSize = 12,
        MaxPageSize = 24,
        RefreshMs = 3000,
        RequestTimeoutMs = 6000
    },

    Marker = {
        Type = 1,
        DrawDistance = 350.0,
        SubmitRadius = 10.0,
        Scale = 7.0,
        Color = { r = 242, g = 184, b = 32, a = 150 }
    },

    -- Geometria e checkpoints.
    MaxCheckpoints = 64,
    MaxWorldCoord = 20000.0,
    MinZ = -2000.0,
    MaxZ = 3000.0,
    CheckpointRadius = 15.0,
    CheckpointZRadius = 8.0,
    MinCheckpointDistance = 0.01,
    MinCheckpointIntervalMs = 150,
    MaxPlausibleSpeed = 200.0,

    RequireVehicle = true,
    RequireDriver = true,
    AllowObservers = true,

    -- Rate limit por source/acao. Checkpoint e join sao os mais sensiveis.
    RateLimits = {
        join = { window = 10000, max = 5 },
        leave = { window = 10000, max = 5 },
        status = { window = 10000, max = 20 },
        catalog = { window = 10000, max = 10 },
        detail = { window = 10000, max = 20 },
        checkpoint = { window = 5000, max = 12 },
        organizer_bootstrap = { window = 10000, max = 5 },
        organizer_list = { window = 10000, max = 10 },
        organizer_routes = { window = 10000, max = 10 },
        organizer_detail = { window = 10000, max = 20 },
        organizer_create = { window = 10000, max = 2 },
        organizer_action = { window = 10000, max = 8 }
    },

    -- Auditoria de suspeita e evento observavel. Nunca aplica ban.
    EmitSuspicionEvent = true,
    AuditAcceptedCheckpoints = false,
}
