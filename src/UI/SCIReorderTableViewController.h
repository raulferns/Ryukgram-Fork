// Reorder base for settings tables: lives in editing mode so UIKit draws the
// reorder handle and owns the move interaction. Subclasses mark reorderable
// sections and splice their model in -didMoveRowFromIndexPath:toIndexPath:.
// Gotcha: plain accessoryView/Type hide while editing — mirror them onto the
// editing* variants; manual contentView subviews are unaffected.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCIReorderTableViewController : UITableViewController

// Sections whose rows can be reordered. Default NO.
- (BOOL)isReorderableSection:(NSInteger)section;

// First movable row in a reorderable section. Default 0.
- (NSInteger)firstReorderableRowInSection:(NSInteger)section;

// Splice + persist; indexes are final table positions.
- (void)didMoveRowFromIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst;

@end

NS_ASSUME_NONNULL_END
