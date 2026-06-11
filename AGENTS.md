# AGENTS.md — RyukGram-Fork (regras de trabalho p/ Opus 4.8)

Contexto: tweak iOS (Theos/Logos) que liga features internas/dogfood do Instagram via hooks de gating. Pesquisa em sandbox, autorizada. Este arquivo existe para **não repetir os erros que causaram o crash e os toggles mortos** na branch `experiments2`.

Leia também: `REVISAO_CODIGO_RyukGram.md`, `ERROS_E_CORRECOES.md`, `CRASH_ANALISE_433.0.283.md`.

---

## 0. Antes de tocar em qualquer hook — reancore no binário certo

1. **Confirme a versão pelo UUID, não pelo cabeçalho de docs.** Docs antigos diziam “429.0.0”; os binários reais eram **433.0.283**. Cheque o `LC_UUID` do Mach-O contra o crash report / o IPA em mãos. Offsets de ivar, nomes mangled de Swift e listas de método **mudam entre versões**.
2. Trate comentários `// confirmado via disassembly` como **hipótese**, não verdade. Vários apontavam para nomes errados.

---

## 1. Validar seletor/classe — a regra que mais quebrou aqui

- **Seletor existir como string no binário ≠ método existir naquela classe.** `isLiquidGlassEnabled` está em `__objc_methname` mas **não** é método de `IGDSLauncherConfig`. Validar contra `strings`/xref TSV é errado.
- **Fonte de verdade = a lista de métodos da própria classe** (class-dump da classe, ex.: `IGDSLauncherConfig_FULL_header.c`).
- **Classe Swift:** o nome mangled tem que estar presente em `__objc_classlist`/class-dump. Diferente de seletor, **se o nome da classe não está no binário, a classe não existe** — `NSClassFromString` devolve `nil` e o hook vira no-op silencioso.
- Sempre que o helper `hook()`/`SCIHook*` não acha classe/seletor, ele **retorna em silêncio** (sem crash, sem log). Logo, *toggle morto* quase sempre = nome errado. Cheque o nome antes de culpar a lógica.

Nomes confirmados no 433 (use estes):
- Direct Notes exposure helper: `_TtC37IGDirectNotesExperimentExposureHelper37IGDirectNotesExperimentExposureHelper`
- Experimentos efetivos: `LIDExperimentGenerator -isExperimentEnabled:` ✅. `MetaLocalExperiment`, `_TtC18IGNavConfiguration18IGNavConfiguration`, `FamilyLocalExperiment` → **ausentes** (inertes).
- `IGDSLauncherConfig`: **não tem getter “master”** de LiquidGlass nem de Prism. Force os getters específicos do class-dump. `isPrismAvatarRingEnabled` existe (sem underscore); a única variante com underscore real é `_isPrismSecondaryNonUserIconsEnabled`.

---

## 2. Instalação de hook — proibido escada de timer

- **NUNCA** instale/reinstale hook nem aplique config por escada de `dispatch_after {1,2,5,6,8}s`. Foi isso que causou o `EXC_BAD_ACCESS` (bloco adiado → `objc_msgSend` em ponteiro inválido; PAC fail). Ver `CRASH_ANALISE_433.0.283.md`.
- **Use** `Dogfooding/SCIInstallOnce.h` → `SCIInstallOnceOnActive(^{ ... })`: install único em `UIApplicationDidBecomeActive`, com ran-guard e auto-remoção do observer.
- **Classe Swift de realização tardia** (pode não existir nem em `DidBecomeActive`): instale **no ponto de uso** (quando o usuário abre a superfície) ou reaja a `_dyld_register_func_for_add_image`. Nunca “espere N segundos e mande mensagem”.
- `dispatch_after` só é aceitável quando o bloco **(a)** só toca `NSUserDefaults`, **(b)** re-resolve sessão/objetos a cada chamada com null-guard, ou **(c)** é disparado por ação do usuário pós-launch. Nunca quando captura um ponteiro de objeto que pode virar lixo.

---

## 3. Qual mecanismo de persistência usar (do melhor ao pior)

| Caso | Use | Por quê |
|---|---|---|
| Gate C / MobileConfig / EasyGating (símbolo exportado pelo FBShared, importado via GOT) | **fishhook / `rebind_symbols`** + cache C estático + KVO | global e relido a cada launch. Ferramenta certa p/ C. |
| Feature lastreada por LauncherConfig / dogfood | **`SCILauncherOverride`** (cliente nativo `IGDogfoodingAssistantLauncherClient` + `replayPersistedOverrides`) | usa o store de persistência da própria Meta. **Melhor persistência.** |
| Getter BOOL ObjC (classe realizada cedo, ex. `IGDSLauncherConfig`) | **`SCIGatingCatalog`** (`MSHookMessageEx` + override-dict + fallback ao IMP original) | toggleable + fallback seguro. Reinstale em `DidBecomeActive`. |
| Getter BOOL Swift tardio | install **no ponto de uso** | evita realização tardia e evita o timer cego. |

**Não use** `class_replaceMethod` com bloco constante (`SCIRuntimeBoolForce.m`): descarta o IMP original (não desliga) e exige classe realizada. É o pior mecanismo; migre p/ `SCIGatingCatalog` e considere deletar.

> Nota de UX dos gates C: o rebind é **one-shot** gated em “pref já ON no `%ctor`”. Ligar em runtime só vale no próximo launch. Se quiser efeito imediato, instale o rebind incondicionalmente no `%ctor` (barato e seguro na GOT) e deixe o cache refletir a pref.

---

## 4. Regras de segurança de hooking (sideload-safe)

- Só **`MSHookMessageEx`** em `__DATA` (métodos ObjC). **Nunca** `MSHookFunction` em páginas `__TEXT`.
- **fishhook/`rebind_symbols`** para GOT/PLT (símbolos C importados).
- **`dlsym`** para símbolos C/C++ exportados (ex.: `_XPluginsGetListLookupDataPair` é exported dynamic symbol — não hardcode endereço).
- `XPluginsGetListLookupDataPair` é **definido dentro do Instagram** (launch path) — deixe **desligado**; fishhook nele no launch crasha.
- `.x` é ObjC/C puro: sem `extern "C"`, sem sintaxe C++, sem `#import <mach/mach_vm.h>`.
- Sem `performSelector:` sob ARC+`-Werror`. Replacement de hook C **não chama ObjC** no hot path — leia só cache C estático (atualizado via KVO).
- `%ctor` faz só leitura barata de pref e **early-return se OFF**.

---

## 5. Higiene de build / repo

- **Não** confie em `-Wno-incompatible-pointer-types` (mascara bugs de tipo/ABI → PAC fail). Remova e trate os avisos. (Hoje **não** há `-Werror` no Makefile — a antiga preocupação com `-Wunused-function`+`-Werror` não se aplica à config atual.)
- Evite “disable-by-rename” (`.txt`/`.xm_`/`.m_`): um `git mv` acidental religa código morto. Prefira gate por pref no `%ctor` ou lista explícita de `FILES` no Makefile.
- Não deixe dois mecanismos fazendo a mesma coisa (C e D coexistiam). Unifique.

---

## 6. Honestidade de entrega (não invente certeza)

- Se não compilou/testou em device, **diga isso**. Faça no mínimo checagem de balanceamento `{}`/`()`/`[]` e de `#import` nos arquivos tocados.
- Não simbolize por offset sem ter a dylib com símbolos; descreva a **classe do bug** em vez de cravar o arquivo.
- Ao remover escadas de timer, registre o trade-off: classes Swift realizadas **depois** de `DidBecomeActive` podem ser perdidas pelo install único. O conserto certo é install no ponto de uso — **não** reintroduzir a escada cega. Um único retry guardado por null-check é paliativo aceitável; escada não.
