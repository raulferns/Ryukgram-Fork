// Popup de menu Liquid Glass 100% custom.
//
// O Instagram seta UIDesignRequiresCompatibility=YES no Info.plist, então o
// processo inteiro renderiza UIKit legado: o chrome do UIMenu nativo e do
// popover do sistema NUNCA viram Liquid Glass aqui, e empilhar um popover do
// sistema com um container próprio gera o efeito "menu dentro de menu".
//
// Este componente desenha UM único painel (SCIUIKit26GlassPanelView, que
// instancia UIGlassEffect explicitamente) direto na window, com as opções
// dentro dele. Sem UIMenu, sem UIModalPresentationPopover, sem UITableView
// inset-grouped. É a única forma de ter glass de verdade no processo do IG.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCIGlassMenuPopup : NSObject

/// Apresenta as opções de `menu` ancoradas em `sourceView`. `currentValue` marca
/// a opção ativa (checkmark + highlight). `wordmark` usa linhas altas com a
/// imagem grande em vez de título. `onPick` recebe o UICommand escolhido (o
/// chamador roteia para menuChanged:).
+ (void)presentMenu:(UIMenu *)menu
       currentValue:(nullable NSString *)currentValue
           wordmark:(BOOL)wordmark
         sourceView:(UIView *)sourceView
             onPick:(void (^)(UICommand *command))onPick;

+ (void)dismiss;

@end

NS_ASSUME_NONNULL_END
