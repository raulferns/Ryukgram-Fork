#import "SCISettingsSections.h"

@implementation SCITweakSettings (Section_General)

+ (SCISetting *)generalNavCell {
	return [SCISetting navigationCellWithTitle:SCILocalized(@"General")
										   subtitle:@""
											   icon:[SCISymbol symbolWithIGName:@"settings" fallback:@"gear"]
										navSections:@[@{
											@"header": @"",
											@"rows": @[
												[SCISetting navigationCellWithTitle:SCILocalized(@"Hide ads")
												subtitle:SCILocalized(@"Choose which surfaces hide ads")
													icon:nil
											 navSections:@[@{
												@"header": @"",
												@"footer": SCILocalized(@"Master switch. When off, all per-surface toggles below are ignored."),
												@"rows": @[
													[SCISetting switchCellWithTitle:SCILocalized(@"Hide ads") subtitle:SCILocalized(@"Removes ads across enabled surfaces") defaultsKey:@"hide_ads"],
												]
											},
											@{
												@"header": SCILocalized(@"Surfaces"),
												@"rows": @[
													[SCISetting switchCellWithTitle:SCILocalized(@"Feed") subtitle:SCILocalized(@"Sponsored posts in main, contextual, video, and chaining feeds") defaultsKey:@"hide_ads_feed"],
													[SCISetting switchCellWithTitle:SCILocalized(@"Stories") subtitle:SCILocalized(@"Story ads and sponsored entries in the story tray") defaultsKey:@"hide_ads_stories"],
													[SCISetting switchCellWithTitle:SCILocalized(@"Reels") subtitle:SCILocalized(@"Sponsored reels in the sundial feed") defaultsKey:@"hide_ads_reels"],
													[SCISetting switchCellWithTitle:SCILocalized(@"Explore & search") subtitle:SCILocalized(@"Sponsored posts on the explore grid") defaultsKey:@"hide_ads_explore"],
													[SCISetting switchCellWithTitle:SCILocalized(@"Shopping") subtitle:SCILocalized(@"Commerce carousels in comments and shoppable CTAs on reels") defaultsKey:@"hide_ads_shopping"],
												]
											}]],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide Meta AI") subtitle:SCILocalized(@"Hides the meta ai buttons/functionality within the app") defaultsKey:@"hide_meta_ai" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide metrics") subtitle:SCILocalized(@"Hides like/comment/share counts on posts and reels") defaultsKey:@"hide_metrics"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Do not save recent searches") subtitle:SCILocalized(@"Search bars will no longer save your recent searches") defaultsKey:@"no_recent_searches"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Open link from clipboard") subtitle:SCILocalized(@"Long-press the search tab to open a copied Instagram link") defaultsKey:@"paste_link_from_search"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Copy description") subtitle:SCILocalized(@"Copy description text fields by long-pressing on them") defaultsKey:@"copy_description"],
											]
										},
										@{
											@"header": SCILocalized(@"Date format"),
											@"footer": SCILocalized(@"Replace IG's relative timestamps (\"3d ago\") with a custom format. Toggle which surfaces it applies to inside the picker."),
											@"rows": @[
												[self dateFormatNavCell],
											]
										},
										@{
											@"header": SCILocalized(@"Browser"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Open links in external browser") subtitle:SCILocalized(@"Opens links in Safari instead of Instagram's in-app browser") defaultsKey:@"open_links_external"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Strip tracking from links") subtitle:SCILocalized(@"Removes Instagram tracking wrappers (l.instagram.com) and UTM/fbclid params from URLs") defaultsKey:@"strip_browser_tracking"],
											]
										},
										@{
											@"header": SCILocalized(@"Sharing"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Replace domain in shared links") subtitle:SCILocalized(@"Rewrites copied/shared links to use an embed-friendly domain for previews in Discord, Telegram, etc.") defaultsKey:@"embed_links"],
												({
													SCISetting *s = [SCISetting buttonCellWithTitle:SCILocalized(@"Embed domain")
																	   subtitle:@""
																		   icon:nil
																		 action:^(void) {
														UIWindow *win = nil;
														for (UIWindow *w in [UIApplication sharedApplication].windows)
															if (w.isKeyWindow) { win = w; break; }
														UIViewController *top = win.rootViewController;
														while (top.presentedViewController) top = top.presentedViewController;
														if ([top isKindOfClass:[UINavigationController class]])
															[(UINavigationController *)top pushViewController:[SCIEmbedDomainViewController new] animated:YES];
														else if (top.navigationController)
															[top.navigationController pushViewController:[SCIEmbedDomainViewController new] animated:YES];
													}];
													s.dynamicTitle = ^{ return [NSString stringWithFormat:SCILocalized(@"Embed domain: %@"), [SCIUtils getStringPref:@"embed_link_domain"] ?: @"kkinstagram.com"]; };
													s;
												}),
												[SCISetting switchCellWithTitle:SCILocalized(@"Strip tracking params") subtitle:SCILocalized(@"Removes igsh, utm_source, and other tracking parameters from shared links") defaultsKey:@"strip_tracking_params"],
											]
										},
										@{
											@"header": SCILocalized(@"Audio page"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Download audio") subtitle:SCILocalized(@"Adds a download button next to share/save on the reels audio page") defaultsKey:@"audio_page_download"],
											]
										},
										@{
											@"header": SCILocalized(@"Comments"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Copy comment text") subtitle:SCILocalized(@"Adds a copy option to the comment long-press menu") defaultsKey:@"copy_comment"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Download GIF & image comments") subtitle:SCILocalized(@"Adds download, copy and expand options to GIF and image comments") defaultsKey:@"download_gif_comment"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Custom GIF in comments") subtitle:SCILocalized(@"Long-press the GIF button to paste any Giphy URL") defaultsKey:@"custom_gif_comment"],
											]
										},
										@{
											@"header": SCILocalized(@"Focus/distractions"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"No suggested users") subtitle:SCILocalized(@"Hides all suggested users for you to follow, outside your feed") defaultsKey:@"no_suggested_users" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"No suggested chats") subtitle:SCILocalized(@"Hides the suggested broadcast channels in direct messages") defaultsKey:@"no_suggested_chats"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide explore posts grid") subtitle:SCILocalized(@"Hides the grid of suggested posts on the explore/search tab") defaultsKey:@"hide_explore_grid" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Favorite GIFs") subtitle:SCILocalized(@"Long-press a GIF in the picker to pin it — favorites show first") defaultsKey:@"gif_favorites_enabled"],
				[SCISetting switchCellWithTitle:SCILocalized(@"Hide trending searches") subtitle:SCILocalized(@"Hides the trending searches under the explore search bar") defaultsKey:@"hide_trending_searches" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Skip sensitive content covers") subtitle:SCILocalized(@"Auto-reveals sensitive media") defaultsKey:@"skip_sensitive_content"],
											]
										},
										@{
											@"header": SCILocalized(@"Live"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Anonymous live viewing") subtitle:SCILocalized(@"Blocks the viewer-count heartbeat so the broadcaster doesn't see you — you also won't see the viewer count") defaultsKey:@"live_anonymous_view"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Toggle live comments") subtitle:SCILocalized(@"Long-press the heart button in a live to hide or show the comments") defaultsKey:@"live_hide_comments"],
											]
										},
										]
				];
}

@end
