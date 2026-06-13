#import "../../Utils.h"
#import "../../InstagramHeaders.h"

// Drop IGProfileChainingModel at the data source — filtering it in the section
// controller is too late and the row flashes before collapsing.

static BOOL sciHideProfileSuggestions(void) {
	return [SCIUtils getBoolPref:@"no_profile_suggested_users"];
}

%hook IGProfileViewController

- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *list = %orig;
	if (!sciHideProfileSuggestions() || ![list isKindOfClass:NSArray.class] || !list.count) return list;

	Class chaining = %c(IGProfileChainingModel);
	if (!chaining) return list;

	NSMutableArray *filtered = nil;
	for (id obj in list) {
		if ([obj isKindOfClass:chaining]) {
			if (!filtered) filtered = [list mutableCopy];
			[filtered removeObjectIdenticalTo:obj];
		}
	}

	return filtered ?: list;
}

%end

// Fallback for builds that route the strip through a class the source filter misses.
%hook IGProfileChainingSectionController

- (NSArray *)objectsForListAdapter:(id)arg1 {
	return sciHideProfileSuggestions() ? @[] : %orig;
}

- (NSInteger)numberOfItems {
	return sciHideProfileSuggestions() ? 0 : %orig;
}

- (CGSize)sizeForItemAtIndex:(NSInteger)arg1 {
	return sciHideProfileSuggestions() ? CGSizeZero : %orig(arg1);
}

%end
