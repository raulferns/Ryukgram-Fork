#import "SCISettingsSections.h"

@implementation SCITweakSettings (Section_Messages)

+ (SCISetting *)messagesNavCell {
	return [SCISetting navigationCellWithTitle:SCILocalized(@"Messages")
										   subtitle:@""
											   icon:[SCISymbol symbolWithIGName:@"messages" fallback:@"bubble.left.and.bubble.right"]
										navSections:@[@{
											@"header": SCILocalized(@"Threads"),
											@"rows": @[
												[SCISetting navigationCellWithTitle:SCILocalized(@"Read receipts")
																		   subtitle:SCILocalized(@"Control when messages are marked as seen")
																			   icon:nil
																		navSections:@[@{
																			@"header": @"",
																			@"rows": @[
																				[SCISetting switchCellWithTitle:SCILocalized(@"Manually mark messages as seen") subtitle:SCILocalized(@"Adds a button to DM threads to mark messages as seen") defaultsKey:@"remove_lastseen"],
																				[SCISetting menuCellWithTitle:SCILocalized(@"Read receipt mode") subtitle:SCILocalized(@"How the seen button behaves") menu:[self menus][@"seen_mode"]],
																				[SCISetting switchCellWithTitle:SCILocalized(@"Auto mark seen on interact") subtitle:SCILocalized(@"Marks messages as seen when you send any message") defaultsKey:@"seen_auto_on_interact"],
																				[SCISetting switchCellWithTitle:SCILocalized(@"Auto mark seen on typing") subtitle:SCILocalized(@"Marks messages as seen when you start typing") defaultsKey:@"seen_auto_on_typing"],
																			]
																		}]
												],
												[SCISetting navigationCellWithTitle:SCILocalized(@"Keep deleted messages")
																		   subtitle:SCILocalized(@"Preserves messages that others unsend")
																			   icon:nil
																		navSections:@[@{
																			@"header": @"",
																			@"footer": SCILocalized(@"⚠️ Pull-to-refresh in the DMs tab clears all preserved messages. Enable the warning below to get a confirmation dialog."),
																			@"rows": @[
																				[SCISetting switchCellWithTitle:SCILocalized(@"Keep deleted messages") subtitle:SCILocalized(@"Preserves messages that others unsend") defaultsKey:@"keep_deleted_message"],
																				[SCISetting switchCellWithTitle:SCILocalized(@"Indicate unsent messages") subtitle:SCILocalized(@"Shows an \"Unsent\" label on preserved messages") defaultsKey:@"indicate_unsent_messages"],
																				[SCISetting switchCellWithTitle:SCILocalized(@"Unsent message notification") subtitle:SCILocalized(@"Shows a notification pill when a message is unsent") defaultsKey:@"unsent_message_toast"],
																				[SCISetting switchCellWithTitle:SCILocalized(@"Warn before clearing on refresh") subtitle:SCILocalized(@"Confirmation dialog before clearing preserved messages") defaultsKey:@"warn_refresh_clears_preserved"],
																			]
																		}]
												],
												[SCISetting navigationCellWithTitle:SCILocalized(@"Deleted messages log")
																		   subtitle:SCILocalized(@"Records every message someone unsends, grouped by sender")
																			   icon:nil
																		navSections:@[@{
																			@"header": @"",
																			@"footer": SCILocalized(@"When enabled, deleted messages and their media are saved on this device. Toggle off and clear the log to wipe history."),
																			@"rows": @[
																				[SCISetting switchCellWithTitle:SCILocalized(@"Enable deleted messages log") subtitle:SCILocalized(@"Captures unsent messages with their text or media") defaultsKey:@"deleted_messages_log_enabled"],
																				[SCISetting buttonCellWithTitle:SCILocalized(@"Open log")
																									   subtitle:SCILocalized(@"Browse, filter and search recorded messages")
																										   icon:[SCISymbol symbolWithName:@"tray.full"]
																										 action:^(void) {
																					[SCIDeletedMessagesViewController presentFromViewController:nil];
																				}],
																			]
																		}]
												],
												[SCISetting switchCellWithTitle:SCILocalized(@"Disable typing status") subtitle:SCILocalized(@"Hides typing indicator from others") defaultsKey:@"disable_typing_status"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Disable vanish mode swipe") subtitle:SCILocalized(@"Prevents accidental swipe-up activation of vanish mode") defaultsKey:@"disable_disappearing_mode_swipe"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide voice call button") subtitle:SCILocalized(@"Removes the audio call button from DM thread header") defaultsKey:@"hide_voice_call_button" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide video call button") subtitle:SCILocalized(@"Removes the video call button from DM thread header") defaultsKey:@"hide_video_call_button" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Silence incoming calls") subtitle:SCILocalized(@"Incoming calls stay silent — no ring, no screen, no notification") defaultsKey:@"sci_silence_calls" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide reels blend button") subtitle:SCILocalized(@"Hides the blend button in DMs") defaultsKey:@"hide_reels_blend"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide send to group chat") subtitle:SCILocalized(@"Removes the create/send to group chat row when sharing to multiple recipients") defaultsKey:@"hide_send_to_group"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Bypass DM character limit") subtitle:SCILocalized(@"Allows typing and sending DMs longer than Instagram's limit") defaultsKey:@"bypass_dm_char_limit"],
											]
										},
										@{
											@"header": SCILocalized(@"Share sheet"),
											@"footer": SCILocalized(@"Long-press a recipient to pin or unpin. Pinned recipients render at the top."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Pin recipients on long-press") subtitle:SCILocalized(@"Long-press in the share sheet to pin a chat/user to the top") defaultsKey:@"share_sheet_pin_threads"],
											]
										},
										@{
											@"header": SCILocalized(@"Chat list"),
											@"footer": SCILocalized(@"Block all: all chats blocked — listed chats are exceptions.\nBlock selected: only listed chats are blocked — everything else is normal.\nBoth lists are saved independently. Long-press a chat in the inbox to add or remove."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Enable chat list") subtitle:SCILocalized(@"Master toggle. When off, the list is ignored") defaultsKey:@"enable_chat_exclusions"],
												[SCISetting menuCellWithTitle:SCILocalized(@"Blocking mode") subtitle:SCILocalized(@"Which chats get read-receipt blocking") menu:[self menus][@"chat_blocking_mode"]],
												({
	SCISetting *s = [SCISetting switchCellWithTitle:@"" subtitle:@"" defaultsKey:@"exclusions_default_keep_deleted"];
	s.dynamicTitle = ^{
		BOOL bs = [[SCIUtils getStringPref:@"chat_blocking_mode"] isEqualToString:@"block_selected"];
		return bs ? SCILocalized(@"Block keep-deleted for unlisted chats")
				  : SCILocalized(@"Block keep-deleted for excluded chats");
	};
	s.subtitle = SCILocalized(@"Each chat can override this in the list");
	s;
}),
												[SCISetting switchCellWithTitle:SCILocalized(@"Quick list button in chats") subtitle:SCILocalized(@"Shows a button in DM threads to add/remove chats from the list. Long-press for more options") defaultsKey:@"chat_quick_list_button"],
												({
													SCISetting *s = [SCISetting buttonCellWithTitle:SCILocalized(@"Manage list")
																	   subtitle:SCILocalized(@"Search, sort, swipe to remove or toggle keep-deleted")
																		   icon:[SCISymbol symbolWithIGName:@"ig_icon_edit_list_outline_24" fallback:@"list.bullet.rectangle"]
																		 action:^(void) {
														UIWindow *win = nil;
														for (UIWindow *w in [UIApplication sharedApplication].windows) {
															if (w.isKeyWindow) { win = w; break; }
														}
														UIViewController *top = win.rootViewController;
														while (top.presentedViewController) top = top.presentedViewController;
														if ([top isKindOfClass:[UINavigationController class]]) {
															[(UINavigationController *)top pushViewController:[SCIExcludedChatsViewController new] animated:YES];
														} else if (top.navigationController) {
															[top.navigationController pushViewController:[SCIExcludedChatsViewController new] animated:YES];
														}
													}];
													s.dynamicTitle = ^{ return [NSString stringWithFormat:SCILocalized(@"Manage list (%lu)"), (unsigned long)[SCIExcludedThreads count]]; };
													s;
												}),
											]
										},
										@{
											@"header": SCILocalized(@"Activity"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Full last active date") subtitle:SCILocalized(@"Show full date instead of \"Active 2h ago\"") defaultsKey:@"dm_full_last_active"],
											]
										},
										@{
											@"header": SCILocalized(@"Files"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Send files (experimental)") subtitle:SCILocalized(@"Adds a 'Send File' option to the plus menu in DMs. Supported file types may be limited by Instagram") defaultsKey:@"send_file"],
											]
										},
										@{
											@"header": SCILocalized(@"Voice messages"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Send audio as file") subtitle:SCILocalized(@"Adds an 'Audio File' option to the plus menu in DMs to send audio files as voice messages") defaultsKey:@"send_audio_as_file" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Download voice messages") subtitle:SCILocalized(@"Adds a 'Download' option to the long-press menu on voice messages to save them as M4A audio") defaultsKey:@"download_audio_message"],
											]
										},
										@{
											@"rows": @[
												({ SCISetting *s = [SCISetting navigationCellWithTitle:SCILocalized(@"Custom chat background")
																		   subtitle:SCILocalized(@"Use your own images as chat backgrounds")
																			   icon:nil
																	 viewController:[SCIChatBgSettingsVC new]];
												   s.whatsNewID = @"chat_bg_enabled"; s; }),
											]
										},
										@{
											@"header": SCILocalized(@"Notes"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide notes tray") subtitle:SCILocalized(@"Hides the notes tray in the DM inbox") defaultsKey:@"hide_notes_tray"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide friends map") subtitle:SCILocalized(@"Hides the friends map icon in the notes tray") defaultsKey:@"hide_friends_map" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Note actions") subtitle:SCILocalized(@"Adds copy text, download GIF/audio to the note long-press menu") defaultsKey:@"note_actions"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Copy text on hold") subtitle:SCILocalized(@"Copies note text directly on long press without opening the menu") defaultsKey:@"note_copy_on_hold"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Enable note theming") subtitle:SCILocalized(@"Enables the notes theme picker") defaultsKey:@"enable_notes_customization"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Custom note themes") subtitle:SCILocalized(@"Adds a paintbrush button and long-press shortcut to pick custom background and text colors") defaultsKey:@"custom_note_themes"],
											]
										},
										@{
											@"header": SCILocalized(@"Disappearing media"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Show action button") subtitle:SCILocalized(@"Inserts a button on disappearing media overlays") defaultsKey:@"dm_visual_action_button" requiresRestart:YES],
												({ SCISetting *s = [SCISetting navigationCellWithTitle:SCILocalized(@"Configure menu")
																			subtitle:SCILocalized(@"Reorder, enable/disable, set default tap")
																				icon:nil
																	  viewController:[[SCIActionMenuConfigViewController alloc] initForSource:SCIActionSourceDM]];
												   s.whatsNewID = @"ui_cfg_actionmenu"; s; }),
												[SCISetting switchCellWithTitle:SCILocalized(@"Show mark-as-viewed button") subtitle:SCILocalized(@"Inserts an eye button to mark the current disappearing media as viewed") defaultsKey:@"dm_visual_seen_button" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Show audio toggle") subtitle:SCILocalized(@"Inserts a speaker button to mute/unmute disappearing media") defaultsKey:@"dm_visual_audio_toggle" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Unlimited replay of visual messages") subtitle:SCILocalized(@"Replay visual messages without expiring. Toggle in the eye button menu, or as a standalone button when the eye button is disabled") defaultsKey:@"unlimited_replay"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Disable view-once limitations") subtitle:SCILocalized(@"Makes view-once messages behave like normal visual messages (loopable/pauseable)") defaultsKey:@"disable_view_once_limitations"],
											]
										},
										@{
											@"header": SCILocalized(@"Instants"),
											@"footer": SCILocalized(@"Tweaks for the QuickSnap / Instants camera surface."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Keep running in background")
																										subtitle:SCILocalized(@"Catch view-once media unsent while you're away. ⚠️ May drain battery")
																										value:^BOOL{ return [SCIUtils getBoolPref:@"deleted_messages_keepalive"]; }
																										action:^(BOOL on) {
																										if (!on) {
																											[NSUserDefaults.standardUserDefaults setBool:NO forKey:@"deleted_messages_keepalive"];
																											sciDMUpdateKeepAlive();
																											return;
																										}
																										UIAlertController *a = [UIAlertController alertControllerWithTitle:SCILocalized(@"Keep Instagram active in background")
																											message:SCILocalized(@"Forces Instagram to keep running in the background so it can capture disappearing media that someone unsends while you're not in the app.\n\nMainly useful for view-once media — normal photos/videos are usually still recoverable without it. ⚠️ May significantly drain your battery, and can't capture anything if you force-quit Instagram from the app switcher.\n\nEnable it?")
																											preferredStyle:UIAlertControllerStyleAlert];
																										[a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *_) {
																											[NSUserDefaults.standardUserDefaults setBool:NO forKey:@"deleted_messages_keepalive"];
																											[NSNotificationCenter.defaultCenter postNotificationName:@"SCISettingsShouldReload" object:nil];
																										}]];
																										[a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Enable") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
																											[NSUserDefaults.standardUserDefaults setBool:YES forKey:@"deleted_messages_keepalive"];
																											sciDMUpdateKeepAlive();
																										}]];
																										[sciTopVC() presentViewController:a animated:YES completion:nil];
																				}],
				[SCISetting switchCellWithTitle:SCILocalized(@"Disable instants creation") subtitle:SCILocalized(@"Hides the functionality to create/send instants") defaultsKey:@"disable_instants_creation" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Send from gallery") subtitle:SCILocalized(@"Adds a gallery button to the instants camera so you can send a photo from your album") defaultsKey:@"instants_send_from_gallery" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Instants action button") subtitle:SCILocalized(@"Adds a RyukGram action button to the instants viewer header with expand, save, share, and bulk-save entries") defaultsKey:@"instants_download_btn"],
												({ SCISetting *s = [SCISetting navigationCellWithTitle:SCILocalized(@"Configure menu")
																			subtitle:SCILocalized(@"Reorder, enable/disable, set default tap, show date")
																				icon:nil
																	  viewController:[[SCIActionMenuConfigViewController alloc] initForSource:SCIActionSourceInstants]];
												   s.whatsNewID = @"ui_cfg_actionmenu"; s; }),
											]
										}]
				];
}

@end
