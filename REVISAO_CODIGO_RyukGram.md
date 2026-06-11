# Revisão de código — RyukGram-Fork (branch experiments2)

**Data:** 2026-06-11 · **Revisor:** análise estática + verificação contra binário real
**Alvo:** Instagram **433.0.283** (iOS 27.0 beta, iPhone16,2) + FBSharedFramework
**Escopo:** subsistemas de *gating / dogfooding / internal-mode / persistência* (núcleo do problema) + varredura geral do repo.

> Projeto de pesquisa em sandbox. Esta revisão é só engenharia: estabilidade, correção, técnica.

---

## 0. Método e uma correção importante de versão

Tudo abaixo foi verificado contra os **binários que você enviou**, não contra memória de sessões antigas. Verifiquei a identidade pelos UUIDs do Mach‑O:

| Imagem | LC_UUID do binário enviado | UUID no crash report |
|---|---|---|
| Instagram | `4c4c4466-5555-3144-a1b8-61e7ce661f8f` | `4c4c4466-…f8f` ✅ idêntico |
| FBSharedFramework | `4c4c4474-5555-3144-a172-8a150080b891` | `4c4c4474-…891` ✅ idêntico |

**Achado nº 0 (documentação):** o `DIAGNOSTICO_E_CORRECAO_avancado.md` está com cabeçalho **“Instagram 429.0.0 (build 966827582)”**, mas os binários em mãos — e o app que crashou — são **433.0.283**. Os UUIDs batem com o crash, então o binário é o 433. A engenharia reversa provavelmente foi feita no 429 e o rótulo foi arrastado adiante. Isso importa: **offsets de ivar, nomes mangled de Swift e listas de método podem mudar entre 429 e 433.** Reancore toda a “verdade-terreno” no 433 (o que eu fiz nesta revisão).

Uma armadilha de método que vale registrar (e que entrou no `CLAUDE.md`): **a existência de um seletor como string no binário ≠ o método existir naquela classe.** `isLiquidGlassEnabled` aparece em `__objc_methname` do FBSharedFramework, mas **não é método de `IGDSLauncherConfig`** (não está no class‑dump da classe). A fonte autoritativa é a *lista de métodos da própria classe* (`IGDSLauncherConfig_FULL_header.c`), não `strings`/xrefs.

---

## 1. A causa do crash (433.0.283)

Backtrace da thread que falhou (`EXC_BAD_ACCESS / SIGSEGV`, `KERN_INVALID_ADDRESS … possible pointer authentication failure`):

```
0  libobjc           objc_msgSend + 32
1  RyukGram.dylib    +0x9cc20                    ← nosso tweak
2  libdispatch       _dispatch_client_callout
3  libdispatch       _dispatch_continuation_pop
4  libdispatch       _dispatch_source_latch_and_call
5  libdispatch       _dispatch_source_invoke
6  libdispatch       _dispatch_main_queue_drain
7  CoreFoundation    __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__
…  UIApplicationMain / start
```

Leitura: um **bloco GCD adiado, disparado na main queue**, chamou para dentro do `RyukGram.dylib`, que chamou `objc_msgSend` num ponteiro que **falhou autenticação** (endereço `0x0046f123babf9c28`, com bits altos setados — típico de `isa` corrompido / objeto liberado / ponteiro lixo). `dispatch_after` é implementado **sobre um dispatch *source* (timer)** — por isso o frame `_dispatch_source_invoke` é exatamente o caminho de um bloco de `dispatch_after`. O app saiu ~12 s após o launch (`procLaunch` 20:14:45 → `procExit` 20:14:57), o que casa com as escadas de retry de 5–8 s.

> Não consigo simbolizar `+0x9cc20` aqui (não tenho a `RyukGram.dylib` compilada), então não afirmo o arquivo exato pelo offset. Mas a **classe do bug é inequívoca**: bloco adiado mandando mensagem para ponteiro inválido. A correção é estrutural (seção 4).

### Por que esse padrão existe no código

Vários hooks de Dogfooding instalavam por **escada de `dispatch_after`**:

| Arquivo | Escada original |
|---|---|
| `SCIIGConsumerSubsHook.x` | `install()` no static‑init + retries **1s/3s/6s** |
| `SCIIGPlusEligibilityHook.x` | `install()` no static‑init + **2s/5s** |
| `SCIDogfoodObjectRuntimeHooks.x` | DidBecomeActive + **2s/8s** |
| `SCIIGUserSessionHook.x` | DidBecomeActive + **0.5/2/5s** |
| `SCIDogfoodingSettingsPersistenceHooks.x` | `dispatch_async` + **2s** |
| `SCIExperimentalNavHook.x` | **+5s** aplicando LiquidGlass num helper Swift possivelmente não realizado |
| `SCILauncherClientHook.x` | `%ctor` + **1s** |

A maioria dos `install()` só faz `NSClassFromString` + `class_getInstanceMethod` + `MSHookMessageEx` (seguro em qualquer ponteiro). O **mais perigoso** é o `SCIExperimentalNavHook.x`: aos 5 s ele *aplica* config mandando mensagem para `IGLiquidGlassNavigationExperimentHelper` — se o objeto não estiver realizado/estiver morto, é exatamente a “mensagem para ponteiro inválido” do crash.

---

## 2. A pergunta central — por que algumas persistências funcionam e outras não

Existem **quatro mecanismos de persistência** no repo. Eles não são equivalentes; é por isso que uns “colam” e outros “somem”.

### Mecanismo A — fishhook / `rebind_symbols` (gates C) — **funciona e persiste** ✅
`SCIEasyGatingHook.x`, `SCIInternalUseGateHook.x`, `SCIMobileConfigRuntimeHooks.x`.
Reescreve a entrada GOT do símbolo importado (ex.: `EasyGatingPlatformGetBoolean`). Todo call‑site do Instagram que importa aquele símbolo passa a chamar o replacement. O replacement lê um `static volatile BOOL` que é populado do `NSUserDefaults` no `%ctor` e atualizado por KVO.
**Por que persiste:** o efeito é global (GOT) e o estado é relido do defaults a cada launch.
**É a técnica certa para gates de C/MobileConfig.**

### Mecanismo B — cliente nativo de launcher + replay — **funciona e persiste** ✅ (melhor método p/ dogfood)
`SCILauncherOverride.m`.
Persiste os overrides no `NSUserDefaults` e os **reaplica pelo próprio caminho do app**: `IGDogfoodingAssistantLauncherClient -overrideLauncherWithUserSession:launcherName:parametersToValues:`, depois `replayPersistedOverrides` no boot.
**Por que persiste:** usa a máquina de persistência da própria Meta — não estamos “fingindo” um getter, estamos escrevendo no store que o app lê. Este é o **melhor método** quando a feature é lastreada por LauncherConfig.

### Mecanismo C — hook de getter ObjC com override‑dict + fallback — **persiste se a classe existir e estiver realizada** ⚠️
`SCIGatingCatalog` (`setRuntimeBoolOverride:` / `installPersistedDirectOverrideHooks`).
Um `MSHookMessageEx` no getter; o replacement lê o dict de override (no defaults) e devolve; senão cai no IMP original capturado. É o mecanismo **mais correto** entre os “de getter”: dá para ligar/desligar e tem fallback seguro.
**Onde quebra:** no boot, `SCIGatingCatalogBootstrap.x` **deliberadamente não reinstala** os overrides persistidos (comentário no arquivo: “Stale persisted overrides can crash before the app UI appears”). Logo, para classes que não são tocadas, o override “esquece” entre launches até o usuário reabrir a tela e reaplicar.

### Mecanismo D — `class_replaceMethod` com bloco constante — **inferior** ❌
`SCIRuntimeBoolForce.m`.
Substitui o getter por um bloco que retorna constante. **Descarta o IMP original** (não dá para desligar sem relançar) e **depende de a classe estar realizada**. É estritamente pior que o Mecanismo C. Hoje é redundante.

### Os dois motivos reais de “não persiste / não funciona”

1. **Nome de classe/seletor errado → no‑op silencioso.** O helper `hook()`/`SCIHook*` faz `class_getInstanceMethod` e **retorna em silêncio** se a classe/seletor não existir. Sem crash, sem log, e o toggle “morre”. Verifiquei no binário 433:

   | Onde | Alvo no código | 433 tem? | Efeito |
   |---|---|---|---|
   | `DirectNotesCompat.xm` | classe `IGDirectNotesExperimentHelper` | **NÃO** | hook morto (correto: `_TtC37IGDirectNotesExperimentExposureHelper37IGDirectNotesExperimentExposureHelper`) |
   | `HomecomingCompat.xm` / `ExperimentalRolloutCompat.xm` | classe `MetaLocalExperiment` | **NÃO** | `isInExperiment`/`groupName`/`peekGroupName` mortos |
   | `HomecomingCompat.xm` | `_TtC18IGNavConfiguration18IGNavConfiguration` | **NÃO** | `isHomecomingEnabled` morto |
   | `*Compat.xm` | `FamilyLocalExperiment` | **NÃO** | morto (já documentado “gone”) |
   | `SCIBulkGatingPresets.m` | 3 seletores LiquidGlass em `IGDSLauncherConfig` | **NÃO** (na classe) | 3 no‑ops marcados “confirmado” |

   Presentes e efetivos no 433: `LIDExperimentGenerator`, o exposure‑helper de 37 chars, e os seletores reais do class‑dump de `IGDSLauncherConfig`.

2. **Realização tardia de classes Swift.** Classes Swift `@objc` são registradas no boot (o nome está no `__objc_classlist`), mas a **realização** pode ser adiada até o primeiro uso. Enquanto isso, `objc_getClass` pode devolver `nil` e o install vira no‑op. Como o bootstrap não reinstala (Mecanismo C), o override Swift parece “não persistir”. Foi exatamente isso que as escadas de `dispatch_after` *tentavam* contornar — só que com a ferramenta errada (timer cego), que é o que causou o crash.

---

## 3. Técnica ultrapassada × técnica nova

| Tema | Ultrapassado (no repo) | Recomendado |
|---|---|---|
| Instalar hook tardio | escada `dispatch_after {1,2,5,6,8}s` cega | **1 install determinístico** em `UIApplicationDidBecomeActive`; p/ Swift tardio, instalar **no ponto de uso** (quando o usuário navega) ou via realização |
| Forçar getter BOOL | `class_replaceMethod` com bloco constante (Mec. D) | `MSHookMessageEx` + override‑dict + fallback ao IMP original (Mec. C) |
| Descobrir “está realizada?” | retry por tempo | checar `objc_getClass`/`class_getInstanceMethod` no momento certo; se preciso, `_dyld_register_func_for_add_image` para reagir a load de imagem |
| Desabilitar arquivo | renomear p/ `.txt`/`.xm_`/`.m_` | manter `.x` e *gate por pref no `%ctor`* (early‑return), ou excluir de fato no Makefile com lista explícita |
| Validar seletor | `strings`/xref global | class‑dump **da própria classe** (lista de métodos) |
| Hook de função em `__TEXT` | (corretamente evitado) | manter: só `MSHookMessageEx` em `__DATA`, `fishhook` p/ GOT, `dlsym` p/ símbolos C/C++ exportados |

---

## 4. O que foi corrigido nesta revisão

Detalhe item a item em **`ERROS_E_CORRECOES.md`**. Resumo:

- **Crash / escadas de timer:** introduzido `Dogfooding/SCIInstallOnce.h` (`SCIInstallOnceOnActive`) — install único e determinístico em `DidBecomeActive`, sem timer‑source que sobreviva a objeto capturado. Convertidos: `SCIIGConsumerSubsHook.x`, `SCIIGPlusEligibilityHook.x`, `SCIDogfoodObjectRuntimeHooks.x`, `SCIIGUserSessionHook.x`, `SCIDogfoodingSettingsPersistenceHooks.x`, `SCIExperimentalNavHook.x` (o `+5s` perigoso), `SCILauncherClientHook.x`.
- **No‑ops por nome errado:** `DirectNotesCompat.xm` agora mira a classe Swift presente (exposure‑helper, com fallback legado). `HomecomingCompat.xm` anotado: só `LIDExperimentGenerator` é efetivo no 433; os demais alvos são inertes (mantidos nil‑guarded p/ builds antigos).
- **Seletores fantasma:** removidos os 3 de LiquidGlass de `SCIBulkGatingPresets.m applyLiquidGlass:` (ausentes na classe → no‑op enganoso).

> Não recompilei/testei em device (sem Theos/iPhone aqui). Fiz checagem estática de balanceamento `{}`/`()`/`[]` em todos os arquivos tocados. **Valide um build limpo e um boot antes de confiar.** Ver a seção “Verificação pendente” no `ERROS_E_CORRECOES.md`.

---

## 5. Redundância e dívida que valem limpeza (não bloqueiam)

- **Dois mecanismos de getter** (C e D) coexistem. Migre tudo p/ o Mecanismo C e **delete `SCIRuntimeBoolForce.m`** (ou marque deprecated). Hoje há caminhos que fazem a mesma coisa de dois jeitos.
- **“Disable‑by‑rename”** espalhado: `SCIIGDSLauncherConfigHook.txt`, `SCIXPluginsLookupHook.txt`, `ExpFlagsHooks.xm_`, `QuickSnapCompat.xm_`, `EnableHomecomingUI.x_`, `ProfileCopyButton.x_`, `SCIDebugConsole.m_`, etc. Funciona (o Makefile faz glob só de `.x/.xm/.m`), mas é frágil — um `git mv` acidental religa código morto. Prefira gate por pref ou lista explícita de FILES.
- **Comentários “confirmado/verificado via disassembly” não confiáveis:** vários apontam para nomes errados. Trate comentário como hipótese; a fonte de verdade é o class‑dump do 433.
- **Makefile** usa `-Wno-incompatible-pointer-types` e `-Wno-unused-function` globais — mascaram bugs reais de tipo/ABI (justo o tipo de coisa que causa PAC‑fail). Não há `-Werror` em lugar nenhum, então a preocupação do guardrail com `-Wunused-function`+`-Werror` **não corresponde** à config atual. Recomendo remover `-Wno-incompatible-pointer-types` e tratar os avisos. (Não mexi no Makefile p/ não arriscar ruído sem build.)

---

## 6. Melhor método, por categoria (resumo acionável)

- **Gate C / MobileConfig / EasyGating** → fishhook GOT + cache C + KVO. *(já bom; ver ressalva do gate one‑shot no doc de erros.)*
- **Feature lastreada por LauncherConfig / dogfood** → `SCILauncherOverride` (cliente nativo + replay). **Melhor persistência.**
- **Getter BOOL ObjC (classe realizada cedo, ex. `IGDSLauncherConfig`)** → Mecanismo C, reinstalado em `DidBecomeActive`.
- **Getter BOOL Swift de realização tardia** → instalar **no ponto de uso** (quando o usuário abre a superfície) ou reagindo a `add_image`; **nunca** por escada de timer.
- **Internal/employee ObjC** (`-isEmployee`, `shouldShowInternalBadge`, etc.) → `MSHookMessageEx` no `%ctor` (classes ObjC realizadas cedo) — já correto.
