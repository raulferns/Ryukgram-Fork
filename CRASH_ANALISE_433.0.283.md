# Análise do crash — Instagram 433.0.283 + RyukGram.dylib

**Crash report:** `Instagram-2026-06-10-201458.ips`
**Dispositivo/OS:** iPhone16,2 · iPhone OS **27.0**
**Verificação de identidade:** os binários enviados batem com o crash report por LC_UUID — então a análise é sobre **433.0.283**, não 429.

| Imagem | UUID no crash |
|---|---|
| Instagram | `4c4c4466-5555-3144-a1b8-61e7ce661f8f` |
| FBSharedFramework | `4c4c4474-5555-3144-a172-8a150080b891` |
| RyukGram.dylib | `05d738bd-507f-3635-ac57-a9cfe803e4ee` (base `0x11461c000`) |

---

## 1. Resumo em uma frase

Um **bloco GCD adiado** (`dispatch_after`, que roda sobre um *dispatch source/timer*) disparou na main queue, entrou no `RyukGram.dylib` e chamou `objc_msgSend` num ponteiro que **falhou autenticação de ponteiro (PAC)** — `isa` corrompido / objeto liberado / ponteiro lixo. O app morreu ~12 s após o launch.

---

## 2. Sinais brutos

```
exception : EXC_BAD_ACCESS (SIGSEGV)
subtype   : KERN_INVALID_ADDRESS at 0x0046f123babf9c28
            -> 0x00000123babf9c28 (possible pointer authentication failure)
faultingThread : 0  (main thread)
procLaunch : 2026-06-10 20:14:45.680 -0300
captureTime: 2026-06-10 20:14:57.377 -0300   →  ~11.7 s de vida
```

O endereço `0x0046f123babf9c28` tem **bits altos setados** (`0x0046…`), assinatura clássica de ponteiro com bits de autenticação PAC que não validaram — o objeto destino não era um objeto válido naquele momento.

---

## 3. Backtrace da thread 0 (a que falhou)

```
0  libobjc.A.dylib    objc_msgSend + 32
1  RyukGram.dylib     +0x9cc20                         ← nosso tweak (base 0x11461c000 → 0x1146b8c20)
2  libdispatch        _dispatch_client_callout
3  libdispatch        _dispatch_continuation_pop
4  libdispatch        _dispatch_source_latch_and_call   ← caminho de um dispatch SOURCE (timer)
5  libdispatch        _dispatch_source_invoke
6  libdispatch        _dispatch_main_queue_drain
7  CoreFoundation     __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__
…  UIKit / UIApplicationMain / start
```

**Por que isso aponta para `dispatch_after`:** `dispatch_after` é implementado **sobre um dispatch source com timer**. Os frames `_dispatch_source_latch_and_call` → `_dispatch_source_invoke` são exatamente o caminho de execução de um bloco agendado por `dispatch_after` quando o timer vence. Não é um `dispatch_async` simples (esse não passa por `_dispatch_source_*`).

Ou seja: **um timer do nosso tweak venceu, o bloco rodou, e mandou mensagem para um ponteiro inválido.**

---

## 4. Por que ~12 s e não no instante 0

O launch foi 20:14:45.680; o crash 20:14:57.377 → **~11.7 s**. Isso bate com as **escadas de retry** que existiam no código de Dogfooding (5–8 s e além), e descarta a hipótese de “crash no `%ctor`/scene-create” (que seria sub-segundo). O objeto-alvo existia (ou parecia existir) no install, mas **no momento em que o timer tardio venceu** ele já não era válido — ou nunca chegou a ser realizado e o que estava ali era lixo.

---

## 5. Mapeamento provável para o código

Não dá para simbolizar `+0x9cc20` aqui (não tenho a `RyukGram.dylib` compilada com símbolos), então **não afirmo o arquivo exato pelo offset**. Mas o conjunto de candidatos era pequeno — os blocos adiados que **mandavam mensagem a objeto** (não só instalavam hook):

| Candidato | Padrão | Risco |
|---|---|---|
| `SCIExperimentalNavHook.x` (+5s) | **aplicava** LiquidGlass mandando mensagem a `IGLiquidGlassNavigationExperimentHelper` (Swift, realização tardia) | **ALTÍSSIMO** — é literalmente “bloco adiado → msg a objeto possivelmente morto/não-realizado”. Principal suspeito. |
| `SCIIGConsumerSubsHook.x` (1/3/6s), `SCIIGPlusEligibilityHook.x` (2/5s), `SCIIGUserSessionHook.x` (0.5/2/5s), `SCIDogfoodObjectRuntimeHooks.x` (2/8s) | escadas de **install** (`NSClassFromString`+`MSHookMessageEx`) | menor (install é seguro em qualquer ponteiro), mas ainda timer-source tardio. |

A correção (em `ERROS_E_CORRECOES.md`, itens 1–7) elimina **todos** esses timers tardios, com ênfase no `SCIExperimentalNavHook.x`.

---

## 6. A correção estrutural

Trocar “escada de `dispatch_after` cega” por **install/apply único e determinístico**:

- Novo `Dogfooding/SCIInstallOnce.h` → `SCIInstallOnceOnActive(^block)`: observer único de `UIApplicationDidBecomeActive`, com ran-guard e auto-remoção. **Sem timer-source que sobreviva a um ponteiro capturado.**
- Para classes Swift de **realização tardia** (que podem não existir nem em `DidBecomeActive`): instalar **no ponto de uso** (quando o usuário abre a superfície) ou reagir a `_dyld_register_func_for_add_image`. **Nunca** “esperar N segundos e mandar mensagem”.

---

## 7. Como confirmar que sumiu

1. `make clean && make`, instala, e cronometra: o boot tem que **passar dos ~12 s** sem `EXC_BAD_ACCESS`.
2. Navegar até a tela de LiquidGlass/Nav experimental (onde o `+5s` antes aplicava) e confirmar que abre.
3. Se quiser prova forte de causa-raiz: rodar a build **anterior** com um único `dispatch_after +5s` mandando mensagem a um helper Swift não-realizado deve reproduzir o mesmo backtrace (`_dispatch_source_invoke` → `objc_msgSend` → PAC fail). Com a build nova, não reproduz.

> Limite honesto: sem simbolizar `+0x9cc20`, isto é uma causa-raiz **fortemente fundamentada pelo backtrace e pelo timing**, não uma prova por offset. A classe do bug, porém, é inequívoca.
