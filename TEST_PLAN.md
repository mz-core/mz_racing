# mz_racing - Plano e evidência de testes (Wave 5C)

Ambiente: Windows, Lua 5.5, Node 22 e Chromium headless com Playwright 1.64.
Sem servidor FiveM, CEF real, OneSync real ou MariaDB.

## 1. Suítes do resource

| Suite | Casos | Resultado |
|---|---:|---|
| `tests/domain.lua` (regressão 5A) | 68 | PASS |
| `tests/adapters.lua` (navigation/identity/posição/autorização) | 15 | PASS |
| `tests/bridge.lua` (22 antigos + contratos 5B) | 27 | PASS |
| `tests/wave5b.lua` (catálogo/privacidade/concorrência/status) | 22 | PASS |
| `tests/organizer.lua` (escopo/revisão/DTO/estado/rotas inválidas) | 18 | PASS |
| `tests/organizer_bridge.lua` (auth/revogação/forja/idempotência/concorrência) | 24 | PASS |
| `tests/client.lua` (foco/callback/HUD/organizador) | 19 | PASS |
| `tests/frontend_contract.test.js` | 8 | PASS |
| `tests/browser/*.spec.js` (Google Chrome headless) | 8 | PASS |

Total `mz_racing`: **193 Lua + 8 Node + 8 Chromium = 209 PASS, 0 FAIL**.
Os 101 checks da Wave 5A estão preservados nas três primeiras suítes.
Sintaxe: **16 arquivos Lua**, `strings.js` e `app.js` validados.

## 2. Cobertura

| Cenário | Evidência |
|---|---|
| catálogo paginado, filtros, `created` oculto e DTO redigido | wave5b/bridge/browser |
| detalhe revalida visibilidade e erro neutro | wave5b |
| duas entradas no último slot, full e roles | wave5b/domain |
| source reuse, identidade fechada, restart | domain/wave5b/client |
| checkpoint sequencial e posição server-side | domain/adapters/bridge |
| somente próximo checkpoint chega ao participante | wave5b/client |
| observer sem marker/resultado | wave5b |
| classificação/tempo somente server-side e aliases | domain/wave5b/browser |
| requestId, seq obsoleta, clique duplicado e timeout | bridge/frontend/browser |
| callbacks NUI sempre finalizam | client/frontend |
| foco alheio preservado; HUD sem foco | client/frontend/browser |
| lobby vazio/erro, join/leave, countdown, finish/DNF | browser |
| 1920x1080, 2560x1440, 3440x1440 e 390x720 | browser + screenshots |
| sem waypoint/pagamento/identidade interna | frontend |
| feature OFF/navigation ausente/rate limit | domain/bridge |
| capability, negação, revogação e Core indisponível | adapters/organizer_bridge/client |
| rota pública atual, revisão obsoleta e payload forjado | organizer/organizer_bridge/browser |
| sessões isoladas por writer e monitor sem IDs | organizer/organizer_bridge |
| criar, abrir inscrições, iniciar e cancelar | organizer/organizer_bridge/browser |

## 3. Regressão cruzada versionada

| Resource | Lua | Node | Resultado |
|---|---:|---:|---|
| `mz_navigation` | 151 | 13 | PASS |
| `mz_phone` (inclui Maps/Move contracts) | 95 | 253 | PASS |
| `mz_transport` | 150 | 9 | PASS |

Total reexecutado: **671 PASS, 0 FAIL**. Os 115 casos Chromium históricos de
Navigation/Phone (72 + 43) não foram reexecutados: os cinco probes citados nos
relatórios antigos eram externos ao repositório e não estão disponíveis. Foram
marcados **NOT RUN**, sem substituir por resultado histórico.

Total auditável desta rodada: **880 PASS, 0 FAIL** (209 Racing + 671 regressão).

## 4. Comandos

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
playwright test --workers=1

cd ../mz_navigation
lua tests/geo.lua
lua tests/registry.lua
lua tests/routes.lua
lua tests/service.lua
lua tests/quota_concurrency.lua
node --test tests/projection.test.js

cd ../mz_phone
node --test tests/*.test.js
# todos os tests/*.lua também executados individualmente

cd ../mz_transport
node --test tests/*.test.js
# todos os tests/*.lua também executados individualmente
```

## 5. Runtime obrigatório antes de homologar

- [ ] dois jogadores entram e largam na mesma sessão;
- [ ] dois joins disputam a última vaga em FXServer real;
- [ ] countdown, tempo, raio, sequência e finish com OneSync;
- [ ] veículo, troca de veículo, morte e sair do banco do motorista;
- [ ] observer nunca recebe marker/resultado privado;
- [ ] troca de personagem/source reuse e reconnect;
- [ ] restart limpa lobby/HUD/resultados sem estado zumbi;
- [ ] lobby concorrendo com Phone, Inventory e Navigation no CEF;
- [ ] MZ Move ativo preserva GPS/waypoint durante a corrida;
- [ ] `z` ausente em ponte, túnel e interior;
- [ ] OFF, `mz_navigation` ausente e resource stop/start.
- [ ] capability concedida/revogada durante painel aberto em FXServer real;
- [ ] duas contas autorizadas operando a mesma sessão no mesmo tick;

## 6. Veredito

**PASS offline/browser; runtime FiveM/OneSync/CEF/MariaDB NOT RUN; NÃO HOMOLOGADO.**

