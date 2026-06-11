# Arquivos alterados nesta revisão

Diff unificado completo dos fontes: **`PATCH_src_changes.diff`** (17K).
Tudo verificado contra o binário **433.0.283**; balanceamento `{}`/`()`/`[]` conferido em todos os arquivos tocados. **Não compilado/testado em device** — ver “Verificação pendente” em `ERROS_E_CORRECOES.md`.

## Novos arquivos
- `src/Features/Dogfooding/SCIInstallOnce.h` — helper `SCIInstallOnceOnActive` (install único em `DidBecomeActive`).
- `REVISAO_CODIGO_RyukGram.md` — revisão detalhada (método, crash, persistência, técnica, melhor método).
- `ERROS_E_CORRECOES.md` — tabela item a item de erro/severidade/correção/status + verificação pendente.
- `CRASH_ANALISE_433.0.283.md` — análise standalone do crash.
- `AGENTS.md` — regras p/ agentes não repetirem os erros nesta branch.
- `CLAUDE.md` — regras p/ o Opus 4.8 não repetir os erros.

## Fontes modificados (10)
**Crash / remoção de escadas de `dispatch_after`:**
- `src/Features/Dogfooding/SCIExperimentalNavHook.x` *(principal suspeito do crash — `+5s` que aplicava LiquidGlass)*
- `src/Features/Dogfooding/SCIIGConsumerSubsHook.x`
- `src/Features/Dogfooding/SCIIGPlusEligibilityHook.x`
- `src/Features/Dogfooding/SCIIGUserSessionHook.x`
- `src/Features/Dogfooding/SCIDogfoodObjectRuntimeHooks.x`
- `src/Features/Dogfooding/SCIDogfoodingSettingsPersistenceHooks.x`
- `src/Features/Dogfooding/SCILauncherClientHook.x`

**No-ops por nome de classe/seletor errado:**
- `src/Features/Experimental/DirectNotesCompat.xm` *(retarget p/ exposure-helper de 37 chars)*
- `src/Features/Experimental/HomecomingCompat.xm` *(anotação: só `LIDExperimentGenerator` efetivo no 433)*
- `src/Features/Gating/SCIBulkGatingPresets.m` *(3 seletores LiquidGlass fantasma removidos)*

## Recomendado mas NÃO alterado (precisa decisão sua)
- Deletar/deprecar `src/Features/Gating/SCIRuntimeBoolForce.m` (Mecanismo D inferior).
- `Makefile`: remover `-Wno-incompatible-pointer-types`.
- Limpar “disable-by-rename” (`.txt`/`.xm_`/`.m_`/`.x_`).
- `ExperimentalRolloutCompat.xm`: mesmo alvo morto do Homecoming (no-op).
- `SCIIGEmployeeForceHook.x`: remover alt name inexistente `_TtC16IGLaunchHorizon30LaunchHorizonViewControllerV2`.
