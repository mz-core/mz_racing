# mz_racing

Domínio efêmero de corridas de veículos do MZ Framework. O resource é
independente, mantém a autoridade no servidor e consome somente snapshots de
rotas públicas/publicadas de `mz_navigation`.

## Escopo entregue (Wave 5C)

- sessões server-authoritative em memória e snapshot imutável da rota;
- catálogo paginado e detalhe público redigido, com correlação de requests;
- lobby NUI pt-BR/en-US para entrar, sair e observar conforme o domínio;
- HUD não focável de countdown/corrida e resultado oficial efêmero;
- marcador local somente para o próximo checkpoint autorizado;
- validação server-side de identidade, fase, sequência, tempo, posição,
  veículo/motorista, lotação e rate limit;
- comando configurável `/corridas` e export client `OpenRaceLobby`;
- painel NUI de organizador com lista, busca, paginação, criação por rota
  pública, abertura de inscrições, largada, cancelamento e monitor redigido;
- autorização por operação via `mz_core:HasGlobalPermission` e capability
  dedicada `mz.racing.organize`;
- comando configurável `/organizarcorridas` e export client
  `OpenRaceOrganizer`, ambos OFF por padrão;
- feature flag OFF e allowlist de criação vazia por padrão.

Fora de escopo: dinheiro, apostas, premiação, ranking histórico, SQL, telefone,
social, editor de rotas, routing bucket, teleporte, spawn de
veículos, grid/quali e alterações em MZ Move/GPS.

## Ativação segura em homologação

1. Inicie `mz_core`, `mz_navigation` e `mz_racing` nesta ordem.
2. Aplique manualmente as migrations 001/002/003 de `mz_navigation` conforme o
   baseline daquele resource. `mz_racing` não possui migration.
3. Em `config.lua`, ative `Config.Racing.Enabled=true`.
4. Para o painel, ative `Config.Racing.Organizer.Enabled=true` e conceda a
   capability pelo mecanismo global do Core/ACE, por exemplo:

   ```cfg
   add_ace group.mz_racing_organizer mz.racing.organize allow
   add_principal identifier.license:SEU_IDENTIFICADOR group.mz_racing_organizer
   ```

5. Para integrações server-only antigas, mantenha somente resources confiáveis
   em `Config.Racing.CreatorResources`.
6. Abra `/organizarcorridas`; o foco só é adquirido após autorização válida.

Sem capability, o painel não abre nem opera. Sem `CreatorResources`, os exports
server-only continuam negados. O painel nunca finaliza resultado nem aceita
identidade, capacidade, tempo ou estado enviados pelo browser.

## Contratos principais

Exports server-only (protegidos por `GetInvokingResource()`):

```lua
exports.mz_racing:CreateRaceSession(routePublicId)
exports.mz_racing:OpenRaceRegistration(sessionId)
exports.mz_racing:StartRaceSession(sessionId)
exports.mz_racing:CancelRaceSession(sessionId, reason?)
exports.mz_racing:FinishRaceSession(sessionId)
exports.mz_racing:GetRaceSession(sessionId)
exports.mz_racing:ListRaceSessions()
exports.mz_racing:GetRaceStatusForSource(source, sessionId)
```

Exports client:

```lua
exports.mz_racing:OpenRaceLobby()
exports.mz_racing:OpenRaceOrganizer()
exports.mz_racing:JoinRace(sessionId, role?) -- participant | observer
exports.mz_racing:LeaveRace(sessionId)
exports.mz_racing:SubmitCheckpoint(sessionId, checkpointIndex)
exports.mz_racing:RequestRaceStatus(sessionId)
```

O cliente sinaliza intenção. Não envia identidade, coordenadas, tempo,
colocação ou checkpoint validado. O marcador e a interpolação do relógio são
somente visuais; o servidor decide passagem, tempo e ordem.

## Foco e integração

Lobby e organizador só chamam `SetNuiFocus(true, true)` depois de receber um
bootstrap válido e
se `IsNuiFocused()` estiver livre. Ele libera apenas o foco que adquiriu. HUD,
resultado e marker nunca recebem foco. Nenhum waypoint/blip é criado, portanto
o GPS pessoal e o waypoint gerenciado por `mz_transport` permanecem intactos.

## Estado efêmero

Sessões e resultados ficam em memória. Resultados autorizados usam aliases
`Competidor NN`, ficam disponíveis durante `Config.Racing.SessionRetainMs` e somem
em restart/expiração. Não há persistência, histórico, prêmio ou ledger.

## Testes

```powershell
cd mz_racing
lua tests/domain.lua
lua tests/adapters.lua
lua tests/bridge.lua
lua tests/wave5b.lua
lua tests/organizer.lua
lua tests/organizer_bridge.lua
lua tests/client.lua
node --test tests/frontend_contract.test.js
# Playwright: tests/browser/*.spec.js
```

Resultado desta entrega: **193 Lua + 8 Node + 8 Chromium = 209 PASS, 0 FAIL**.
Regressão versionada dos recursos vizinhos: **671 PASS, 0 FAIL**. Os 115 casos
Chromium históricos de Navigation/Phone não foram reexecutados porque seus
probes eram externos e não estão no repositório. FiveM, OneSync real, CEF real e
MariaDB: **NOT RUN**.

## Limitações

- racing e organizador continuam OFF por padrão;
- restart perde sessões e resultados;
- `z` ausente usa projeção visual no solo/jogador, nunca `0`; pontes, túneis e
  interiores precisam de validação in-game;
- `GetEntityCoords` via OneSync é autoridade de jogo, não prova criptográfica;
- sem árbitro global de foco: a guarda conservadora evita abrir sobre outra NUI,
  mas o fluxo simultâneo precisa ser homologado no CEF/FiveM.

