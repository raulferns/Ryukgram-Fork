#import "SCIReorderTableViewController.h"

@implementation SCIReorderTableViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.allowsSelectionDuringEditing = YES;
	[self setEditing:YES animated:NO];
}

#pragma mark - Subclass hooks

- (BOOL)isReorderableSection:(NSInteger)section { return NO; }
- (NSInteger)firstReorderableRowInSection:(NSInteger)section { return 0; }
- (void)didMoveRowFromIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {}

#pragma mark - Editing chrome

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip {
	return [self isReorderableSection:ip.section] && ip.row >= [self firstReorderableRowInSection:ip.section];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
	return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip {
	return NO;
}

#pragma mark - Move clamping

- (NSIndexPath *)tableView:(UITableView *)tv targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)src toProposedIndexPath:(NSIndexPath *)dst {
	if ([self isReorderableSection:dst.section]) {
		NSInteger first = [self firstReorderableRowInSection:dst.section];
		return dst.row >= first ? dst : [NSIndexPath indexPathForRow:first inSection:dst.section];
	}

	if (dst.section < src.section) {
		// Overshot above — snap to the first slot of the nearest reorderable section below.
		for (NSInteger s = dst.section + 1; s <= src.section; s++) {
			if ([self isReorderableSection:s])
				return [NSIndexPath indexPathForRow:[self firstReorderableRowInSection:s] inSection:s];
		}
	} else {
		// Overshot below — snap to the last slot of the nearest reorderable section above.
		for (NSInteger s = dst.section - 1; s >= src.section; s--) {
			if (![self isReorderableSection:s]) continue;
			NSInteger rows = [tv numberOfRowsInSection:s];
			// Same section: max final index is rows-1. Foreign section: rows = append slot.
			NSInteger last = (s == src.section) ? rows - 1 : rows;
			return [NSIndexPath indexPathForRow:MAX(last, [self firstReorderableRowInSection:s]) inSection:s];
		}
	}

	return src;
}

#pragma mark - Move commit

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {
	if (![self isReorderableSection:src.section] || ![self isReorderableSection:dst.section]) return;
	if ([src isEqual:dst]) return;
	[self didMoveRowFromIndexPath:src toIndexPath:dst];
}

@end
