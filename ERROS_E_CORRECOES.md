# Erros e correções — RyukGram-Fork (branch experiments2)

**Data:** 2026-06-11 · **Alvo verificado:** Instagram **433.0.283** + FBSharedFramework
**Natureza:** análise estática + verificação contra os binários reais enviados (UUID conferido com o crash report).

> Legenda de severidade: **🔴 crash/estabilidade** · **🟠 funcional (toggle morto/não persiste)** · **🟡 dívida/limpeza** · **🔵 documentação**.
> Legenda de status: **✅ corrigido** · **📝 anotado/recomendado (não alterei o código)** · **⏳ precisa de verificação em device**.

---

## 1. Tabela item a item

| # | Sev | Arquivo | O que estava errado | Correção aplicada | Status |
|---|---|---|---|---|---|
| 1 | 🔴 | `src/Features/Dogfooding/SCIExperimentalNavHook.x` | `dispatch_after +5s` que **aplicava** LiquidGlass mandando mensagem a um helper Swift (`IGLiquidGlassNavigationExperimentHelper`) que pode não estar realizado/estar morto aos 5 s — casa exatamente com o backtrace do crash (bloco adiado → `objc_msgSend` em ponteiro inválido). | Substituído por install único determinístico em `UIApplicationDidBecomeActive` (`SCIInstallOnceOnActive`). | ✅ ⏳ |
| 2 | 🔴 | `SCIIGConsumerSubsHook.x` | `install()` no static-init + escada de retry **1s/3s/6s** (timer-source sobrevivendo a estado capturado). | `SCIInstallOnceOnActive` — 1 install. `#import "SCIInstallOnce.h"`. | ✅ ⏳ |
| 3 | 🔴 | `SCIIGPlusEligibilityHook.x` | static-init + escada **2s/5s**. | `SCIInstallOnceOnActive` — 1 install. | ✅ ⏳ |
| 4 | 🔴 | `SCIIGUserSessionHook.x` | DidBecomeActive **+ 0.5/2/5s** de retry. | Observer único em `DidBecomeActive`, sem ladder. | ✅ ⏳ |
| 5 | 🔴 | `SCIDogfoodObjectRuntimeHooks.x` | DidBecomeActive **+ 2s/8s** de retry. | Observer único em `DidBecomeActive`, sem ladder. | ✅ ⏳ |
| 6 | 🔴 | `SCIDogfoodingSettingsPersistenceHooks.x` | `dispatch_async` **+ 2s** de retry. | `dispatch_async` único, sem o `+2s`. | ✅ ⏳ |
| 7 | 🔴 | `SCILauncherClientHook.x` | `%ctor` **+ 1s** de fallback. | `SCIInstallOnceOnActive`. | ✅ ⏳ |
| 8 | 🟠 | `src/Features/Experimental/DirectNotesCompat.xm` | Mirava a classe `IGDirectNotesExperimentHelper` — **ausente** no 433 → hook morto silencioso (`class_getInstanceMethod` retorna `nil`, helper bail sem log). | Retarget para a classe presente `_TtC37IGDirectNotesExperimentExposureHelper37IGDirectNotesExperimentExposureHelper`; fallback legado mantido nil-guarded. | ✅ ⏳ |
| 9 | 🟠 | `src/Features/Gating/SCIBulkGatingPresets.m` | `applyLiquidGlass:` chamava 3 seletores em `IGDSLauncherConfig` marcados “confirmado” que **não estão na classe**: `isLiquidGlassEnabled`, `isLiquidGlassToggleEnabled`, `isOptimizeLiquidGlassGlyphRenderingEnabled`. No-op enganoso. | Removidos os 3; comentário `SCI-FIX` explicando que LiquidGlass não tem getter “master” na `IGDSLauncherConfig` — o lever real são os getters específicos (já cobertos em `SCIIGDSLauncherConfigHook.x`) e as classes Swift de LiquidGlass. | ✅ |
| 10 | 🟠 | `src/Features/Experimental/HomecomingCompat.xm` | Mirava `MetaLocalExperiment`, `_TtC18IGNavConfiguration18IGNavConfiguration` — **ausentes** no 433. Só `LIDExperimentGenerator -isExperimentEnabled:` é efetivo. | Anotação `SCI-FIX` deixando claro que no 433 só `LIDExperimentGenerator` funciona; os demais alvos ficam inertes/nil-guarded (mantidos p/ compat com builds antigas). | ✅ |
| 10b | 🟠 | `src/Features/Experimental/ExperimentalRolloutCompat.xm` | Mesmo alvo morto `MetaLocalExperiment` (`FamilyLocalExperiment` também ausente). | **Não editei** este arquivo — mesmo diagnóstico do #10; documentado aqui. Os hooks são no-op inofensivo no 433. Limpeza opcional. | 📝 |
| 11 | 🔵 | `DIAGNOSTICO_E_CORRECAO_avancado.md` | Cabeçalho diz **429.0.0 / build 966827582**, mas binário+crash são **433.0.283** (UUID confere). Rótulo arrastado do RE antigo. | Documentado em `REVISAO_CODIGO_RyukGram.md §0`; toda a verdade-terreno reancorada no 433. | 📝 |
| 12 | 🟡 | `src/Features/Gating/SCIRuntimeBoolForce.m` | Mecanismo D (`class_replaceMethod` com bloco constante): descarta o IMP original (não desliga sem relançar) e exige classe realizada. Estritamente pior que o Mecanismo C (`SCIGatingCatalog`). | **Recomendo deletar** (ou marcar deprecated) e migrar chamadas p/ Mecanismo C. Não removi p/ não quebrar referências sem build. | 📝 |
| 13 | 🟡 | Vários (`.txt`/`.xm_`/`.m_`/`.x_`) | “Disable-by-rename” (`SCIIGDSLauncherConfigHook.txt`, `SCIXPluginsLookupHook.txt`, `ExpFlagsHooks.xm_`, `QuickSnapCompat.xm_`, `EnableHomecomingUI.x_`, `ProfileCopyButton.x_`, `SCIDebugConsole.m_`, …). Funciona porque o Makefile faz glob só de `.x/.xm/.m`, mas um `git mv` acidental religa código morto. | Recomendo gate por pref no `%ctor` (early-return) **ou** lista explícita de `FILES` no Makefile. Não alterei. | 📝 |
| 14 | 🟡 | `Makefile` | `-Wno-incompatible-pointer-types` **global** mascara bugs reais de tipo/ABI — justamente a família de erro que produz PAC-fail em runtime. `-Wno-unused-function` global também. | Recomendo remover `-Wno-incompatible-pointer-types` e tratar os avisos. Não há `-Werror` em lugar nenhum (logo a antiga preocupação do guardrail com `-Wunused-function`+`-Werror` **não corresponde** à config atual). Não mexi no Makefile p/ não introduzir ruído sem build limpo. | 📝 |
| 15 | 🟡 | `src/Features/Dogfooding/SCIIGEmployeeForceHook.x` | Alt name `_TtC16IGLaunchHorizon30LaunchHorizonViewControllerV2` **não existe**; a classe real é `LaunchHorizonViewControllerV2` (superclasse). `shouldShowDebugInfo` está na subclasse (já hookada), então a linha é redundante/no-op inofensivo. | Recomendo remover o alt p/ limpeza. Sem dano funcional. Não alterei. | 📝 |

---

## 2. Mecanismo de install novo (`SCIInstallOnce.h`)

Adicionado `src/Features/Dogfooding/SCIInstallOnce.h` com `SCIInstallOnceOnActive(^block)`:

- Registra observer de `UIApplicationDidBecomeActiveNotification`.
- Dispara **uma vez**, com guard de “já rodou”, e **se auto-remove**.
- Sem dispatch-source/timer que sobreviva a um ponteiro capturado.

Usado por: `SCIIGConsumerSubsHook.x`, `SCIIGPlusEligibilityHook.x`, `SCIExperimentalNavHook.x`, `SCILauncherClientHook.x`.
Os arquivos #4/#5/#6 fazem o mesmo efeito inline (observer único / `dispatch_async` único) sem importar o helper — equivalente e igualmente seguro.

---

## 3. `dispatch_after` que **permaneceram** (revisados e mantidos de propósito)

Estes **não** são escadas de install de hook e **não** são o padrão do crash. Foram revisados um a um; mantê-los é a decisão correta, mas ficam registrados:

| Arquivo:linha | Uso | Por que é seguro | Hardening opcional |
|---|---|---|---|
| `SCIInternalGatePrefs.m:92` | timer **15s** que desarma o “crash-guard” se o launch ficou estável. | Só escreve em `NSUserDefaults` (`setPref`). Nenhuma mensagem a objeto do app. É **mecanismo de segurança**, não de hook. | nenhum — manter. |
| `SCIDogfooding.m:81` | **0.35s** após o usuário abrir Notes dogfooding, chama `replayPersistedOverrides`. | Disparado por ação do usuário, muito depois do launch; replay passa pelo store nativo. | poderia ser síncrono pós-present; baixo valor. |
| `SCIInternalSettingsApplier.m:106` | escada **4s/8s/16s** que chama `applyNow` quando há `activeUserSession`. | `applyNow` **re-resolve** sessão+objetos a cada chamada e tem null-guard (`if activeUserSession`) — não captura ponteiro que possa virar lixo. O propósito legítimo é esperar a sessão aparecer pós-login. | trocar por re-apply único guiado pelo surgimento da sessão; mantive a escada por ser session-gated e por eu não poder testar a substituição em device. |

> Critério usado: **escada que instala hook ou que manda mensagem a ponteiro capturado = remover** (itens 1–7). **Bloco adiado que só toca defaults, ou que re-resolve tudo com null-guard, ou disparado por ação do usuário = seguro, manter.**

---

## 4. Ressalva importante sobre o Mecanismo A (gates C / EasyGating)

`SCIEasyGatingHook.x` / `SCIInternalUseGateHook.x` / `SCIMobileConfigRuntimeHooks.x` estão **corretos** (fishhook na GOT + cache C estático + KVO) e **persistem entre launches**. Mas há uma lacuna de UX:

- O install do rebind é **one-shot**, gated em “pref já estar ON no `%ctor`”. O observer KVO que recarrega o cache é instalado **depois** do install.
- Consequência: **ligar o gate em runtime não faz efeito até o próximo launch** (o rebind nunca aconteceu naquela sessão). Quem já estava ON no boot funciona e persiste normalmente.
- Não é bug de persistência — é “precisa relançar uma vez após ativar”. Se quiser ativação imediata, instale o rebind incondicionalmente no `%ctor` (ele é barato e seguro na GOT) e deixe o cache começar refletindo a pref.

Não alterei isso (é comportamento, não crash); fica como decisão sua.

---

## 5. Verificação pendente (⏳ — honestidade de engenharia)

Tudo abaixo **não** foi validado em device porque não há Theos/iPhone neste ambiente:

1. **Build limpo.** Não compilei. Fiz apenas checagem estática de balanceamento `{}`/`()`/`[]` e de `#import` em todos os arquivos tocados. Rode `make clean && make` e trate qualquer aviso novo.
2. **Boot real.** A hipótese do crash (bloco adiado → ponteiro inválido) é fortíssima pelo backtrace, mas **não simbolizei `RyukGram.dylib+0x9cc20`** (não tenho a dylib compilada). Confirme que o boot passa dos ~12 s e que a tela onde antes crashava agora abre.
3. **Cobertura de realização tardia (o trade-off da remoção das escadas).** Ao trocar ladder por install único em `DidBecomeActive`, uma classe Swift que só seja **realizada depois** do `DidBecomeActive` pode ser **perdida** pelo install único. Isso é o preço da segurança contra o crash.
   - Se algum toggle Swift voltar a “não pegar” após esta revisão, o conserto **certo** não é reintroduzir a escada cega: é instalar **no ponto de uso** (quando o usuário navega até a superfície) ou reagir a `add_image`.
   - Se preferir um paliativo rápido enquanto isso, dá pra reintroduzir **um único** retry (não escada) ~2s, guardado por null-check de classe — posso fazer sob pedido.
4. **Seletores Prism ampliados** em `SCIIGDSLauncherConfigHook.x` (do diagnóstico antigo): confirmei que os nomes batem com o class-dump do 433, mas o efeito visual de cada um só se vê rodando.
