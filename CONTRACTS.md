# mz_racing - Contratos da Wave 5C

Versão de contrato: **0.3.0** (organizador autorizado, sem persistência).

`mz_navigation` continua owner de rotas/checkpoints. `mz_racing` é owner das
sessões, participantes, validação de passagem e resultados efêmeros. `mz_core`
continua owner de identidade/sessão; `mz_transport` continua owner de viagem,
preço, pagamento e GPS.

## 1. Administração server-only

`CreateRaceSession`, `OpenRaceRegistration`, `StartRaceSession`,
`CancelRaceSession`, `FinishRaceSession`, `GetRaceSession`,
`ListRaceSessions` e `GetRaceStatusForSource` continuam exports server-only.
Todos validam `GetInvokingResource()` contra `Config.Racing.CreatorResources`;
lista vazia nega tudo. Nenhum deles possui wrapper `RegisterNetEvent` ou NUI.

Criação copia a rota retornada por
`exports.mz_navigation:GetPublishedRoute(publicId)`. Só aceita rota pública,
publicada, com revisão e pontos válidos. O snapshot não muda depois da criação.

## 2. Eventos client/server

| Evento | Direção | Dados aceitos | Autorização |
|---|---|---|---|
| `mz_racing:server:catalog` | client -> server | `{ requestId, page?, limit?, state? }` | identidade ativa + rate limit |
| `mz_racing:server:detail` | client -> server | `{ requestId, sessionId }` | visibilidade revalidada |
| `mz_racing:server:join` | client -> server | `{ requestId, sessionId, role? }` | identidade/fase/vaga/role |
| `mz_racing:server:leave` | client -> server | `{ requestId, sessionId }` | próprio participante ativo |
| `mz_racing:server:checkpoint` | client -> server | `{ requestId, sessionId, checkpointIndex }` | participante/running + validação 5A |
| `mz_racing:server:status` | client -> server | `{ requestId, sessionId }` | próprio participante/observador |
| `mz_racing:server:organizer` | client -> server | `{ requestId, action, payload }` | identidade ativa + capability global + rate limit |
| `mz_racing:client:response` | server -> client | DTO redigido com `action`, `seq` + `requestId` | destinatário |
| `mz_racing:client:response` (`action='state'`) | server -> client | push autorizado da própria sessão | destinatário |
| `mz_racing:server:suspicion` | server local | auditoria | nunca ban automático |

Todos os eventos client -> server derivam `source`, `characterId` e
`coreSessionId` no servidor. `requestId` é texto limitado; `seq` descarta
resposta atrasada no client/NUI.

### 2.1 Organizador

O painel exige simultaneamente `Racing.Enabled`, `Organizer.Enabled`, identidade
ativa e `mz_core:HasGlobalPermission(source, 'mz.racing.organize')`. A permissão
é revalidada em cada request; revogação fecha o painel na próxima operação.
`mz_racing` não consulta ACE diretamente e não altera o catálogo de permissões
do Core.

Ações aceitas: `bootstrap`, `list`, `routes`, `detail`, `create`,
`openRegistration`, `start` e `cancel`. Criação aceita apenas `routePublicId` e
`routeRevision`; capacidade, autor, identidade, estado e tempos enviados pelo
cliente são ignorados. A revisão é comparada com o snapshot público atual de
`mz_navigation`. Mutação duplicada com o mesmo `requestId` e sessão de Core é
idempotente; uso do ID para outra ação falha com `request_id_conflict`.

O painel enxerga somente sessões cujo writer canônico é o próprio bridge
`mz_racing`. Sessões criadas por outro `CreatorResources` continuam isoladas.
O monitor usa aliases `Competidor NN` e omite source, IDs canônicos, pontos da
rota e dados de veículo. Não existe ação NUI de finish, resultado forçado,
pagamento, waypoint ou persistência.

## 3. DTO público de sessão

```lua
{
  sessionId, title, state, revision,
  route = {
    publicId, title, description?, routeType,
    checkpointCount, totalDistance
  },
  participantCount, observerCount,
  minParticipants, maxParticipants,
  canJoin, canObserve, canLeave,
  joinReason?, observeReason?, role?, participantStatus?,
  countdownRemainingMs?, elapsedMs?
}
```

O DTO não contém `characterId`, `citizenid`, license, source, core session,
vehicle/netId, lista de participantes nem `route.points`. Sessões `created`
não aparecem. Detalhe repete a checagem de visibilidade e devolve
`session_not_found` de forma neutra.

Paginação: `page >= 1`, `limit` limitado por `Lobby.MaxPageSize`; filtros
aceitos são `all`, `registration`, `running` e `finished`.
Catálogo/detalhe têm rate limits próprios.

## 4. Status, checkpoint e HUD

Status do participante contém o DTO público, somente seu registro redigido e,
em `countdown|running`, apenas o próximo checkpoint autorizado:

```lua
nextCheckpoint = { index, total, point = { x, y, z? } }
```

Observador nunca recebe coordenada de checkpoint nem resultados compartilhados.
O marker é local, sem entidade/blip/waypoint. `z` ausente permanece ausente no
contrato; o client tenta solo apenas para desenhar e não envia essa coordenada.
`SubmitCheckpoint` envia somente o índice e continua não confiável.

O HUD interpola countdown/tempo entre snapshots, mas rebaseia a cada push. Não
exibe posição durante a corrida porque o domínio não possui ranking intermediário
confiável.

## 5. Resultado

Após `finished`, apenas participante daquela sessão recebe:

```lua
{
  expiresInMs,
  entries = {
    { label = "Competidor 01", status, position?, finishTimeMs?, own }
  }
}
```

A ordem e `finishTimeMs` vêm do servidor. DNF não recebe posição/tempo. Empate
segue a ordem de processamento server-side herdada da Wave 5A. IDs canônicos
nunca são enviados. O resultado expira por `SessionRetainMs`; observer/visitante
tardio não recebe tabela. Restart limpa tudo.

## 6. Foco e ciclo de vida

- `/corridas` e `OpenRaceLobby` solicitam catálogo antes de adquirir foco;
- se `IsNuiFocused()` já estiver ativo, retornam `focus_unavailable`;
- ESC/close, join, troca de identidade e stop fecham o lobby;
- o resource libera foco apenas quando `UI.ownsFocus=true`;
- HUD, resultado e checkpoint visual nunca chamam `SetNuiFocus(true, ...)`;
- polling é restrito e configurável: catálogo enquanto lobby aberto, status
  somente durante participação e lista/detalhe enquanto organizador aberto;
- perda de permissão, identidade, flag ou Core fecha o organizador e libera
  somente o foco adquirido por ele.

## 7. Estados e falhas

```text
created -> registration -> countdown -> running -> finished
                                      |            |
                                      +-> cancelled+-> failed
```

Erros tipados das Waves anteriores permanecem. A Wave 5C acrescenta
`organizer_disabled`, `permission_denied`, `authorization_unavailable`,
`route_revision_conflict`, `request_id_conflict` e `organizer_internal_error`.
A Wave 5B já havia acrescentado
`focus_unavailable`, `request_timeout` (NUI local) e respostas neutras de
sessão expirada. Feature OFF devolve `racing_disabled`; `mz_navigation`
indisponível degrada o catálogo com `navigation_unavailable` e não afeta
Phone/Move.

## 8. Concorrência e privacidade

Mutação de join é síncrona no servidor; dois joins no último slot resultam em
um sucesso e um `session_full`. Join/leave/checkpoint/status revalidam identidade
atual. `identitySessionClosed`/`playerDropped` removem o vínculo transitório.
Eventos duplicados, fora de fase, com payload inválido/grande ou índice obsoleto
falham sem avançar estado.

