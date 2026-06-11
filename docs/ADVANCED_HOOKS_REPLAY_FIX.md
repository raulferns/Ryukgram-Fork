# Advanced hooks replay fix

## Motivo da regressão

Os toggles em Advanced continuavam persistindo em `NSUserDefaults`, mas vários hooks tinham sido removidos do `%ctor` para evitar watchdog em `scene-create`.

Isso deixou um buraco lógico:

- toggle já estava ON antes do app abrir;
- `%ctor` não instalava mais hook;
- abrir Advanced mostrava o toggle ON;
- nenhum `UIControlEventValueChanged` acontecia;
- logo nenhum instalador era chamado.

Resultado: Feature Gating/MobileConfig/EasyGating/Sessioned/Internal apareciam ON, mas não estavam ativos na sessão.

## Correção

Adiciona `SCIAdvancedHooks`:

- `%ctor` registra apenas `UIApplicationDidBecomeActiveNotification`;
- não instala hooks durante dyld/static init;
- não usa `dispatch_after`;
- depois do app estar ativo, reaplica uma vez todos os grupos Advanced cujas prefs já estão ON;
- quando o usuário liga um toggle, `switchChanged:` chama o instalador correspondente imediatamente.

## Ajustes adicionais

- `sci_force_ig_internal_employee` agora é master real para os getters ObjC internos.
- `SCIIGEmployeeForceHook.x`, `SCIIGInternalBuildHook.x` e `SCIInternalSettingsMenuHook.x` não usam mais retry com `dispatch_after` em `%ctor`.
- `SCIInternalSettingsMenuHook.x` expõe `SCIInstallInternalSettingsMenuHookIfNeeded()` para uso pelo dispatcher.
- Rows Advanced que agora aplicam live não pedem restart.
