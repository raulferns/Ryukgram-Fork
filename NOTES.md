[release] RyukGram v1.3.1

### ✨ Features
- Tab bar icon order is now fully customizable — drag to reorder any tab and toggle tabs off (including profile), replacing the old fixed presets; the hide-tab switches moved into the new Icon order screen
- Reordering rows in settings (action menus, home shortcut) is more reliable — native drag handles, no more failed drops
- Custom sticker colors — the color-wheel long-press now works on every sticker editor (slider, fundraiser, prompt and more), not just music
- Hide suggested users on profiles — removes the suggested-accounts strip shown under a profile
- Hide story highlights — removes the resurfaced highlights row from the feed stories tray
- Profile Analyzer scans keep running after you leave the view — a progress pill lets you track or cancel from anywhere
- Profile Analyzer can remove people who follow you but you don't follow back, straight from the list — per-row or in batch
- Hide the DM and story seen buttons while keeping receipt blocking on, with an optional confirmation before any mark-as-seen action
- Disappearing media can advance to the next stacked message when you mark it as viewed
- Deleted-messages log now groups by chat — group-chat unsends appear under the group, each tagged with who unsent it
- Deleted-messages log can optionally record removed reactions — the emoji, who removed it, and which message it was on
- Deleted-messages log now captures disappearing (view-once) media — saved when you open it, when it's unsent, or when you reopen the chat, and states clearly when it couldn't be recovered
- Filter the deleted-messages log to disappearing media only
- Exclude chats from the deleted-messages log — long-press one to stop logging it, with an ignored list to manage and undo
- Optional background keep-alive for the deleted-messages log — catches unsends while you're away, off by default (may use more battery)
- File logging (Settings → Debug) — records RyukGram's own activity across the app and its extensions to one shareable log file for troubleshooting, off by default
- Messages-only mode keeps the search tab, with a toggle to hide it, and trims its explore grid and trending searches
- Disable all tweak options (Advanced → Instagram) — turns every feature off so Instagram behaves stock; your settings are kept and restored when you turn it back off
- Force progressive blur (iOS 26) — keeps the scroll-edge blur visible instead of letting it fade out
- Custom chat backgrounds can auto-color message bubbles (text, replies and voice notes) — the other person's, yours, or both, solid or gradient (vertical, horizontal, or diagonal), with custom or auto-contrast text; works with animated themes and shows through the composer; editable from the in-chat picker with live updates
- Instants can auto-advance to the next one after you like or react
- Read receipts — get notified, and optionally keep a log, when someone reads a message you sent; grouped by chat with profile photos, an unread count per chat that clears when you open it, username/date search and sort, a per-person/chat ignore list, group-chat support, and a notifications-only mode (off by default); tapping the notification opens the log; backs up via Backup & Restore (opt-in, under Feature data)
- Importing a backup can now merge into your existing data instead of replacing it — pick Replace or Merge on the import page; duplicates are combined, including merging galleries together
- Save photo posts with their music — new feed action menu entries combine the photo with the exact track snippet the post plays and save it as a video to Photos or the Gallery
- Save straight to Photos from the profile action button and the expanded media viewer, alongside the existing Gallery and share options
- Force liquid glass off — disables liquid glass for accounts that have it enabled by default
- Favorite GIFs — long-press a GIF in the picker (comments and DMs) to pin it to the top with a star badge or download it; GIF comments can be favorited from their long-press menu
- Mirror toasts to iOS notifications — toasts that fire while Instagram is in the background are delivered to the notification centre instead so they aren't missed; per-action overrides and auto-clear when the app opens
- Custom date formats — build your own with placeholders like `{DD}/{MM}/{YYYY} {HH}:{mm}`, live preview and tap-to-insert tokens; save as many as you like and switch between them, plus a new `dd/MM/yyyy` 24-hour preset
- Auto-save instants — pick Photos or the RyukGram gallery and every instant you view (including while swiping) saves automatically, each one only once

### 🛠 Fixes
- Story overlay buttons no longer crash, freeze, disappear, or jump to the corner when swiping between stories — across action-button / mentions / seen combos (including mentions-only on iPad landscape)
- Notification pills no longer re-open their view when tapped while you're already inside it
- Home shortcut updates without a restart and now shows on accounts that don't have the create button
- Instants download button stays put when Instagram hides its toolbar anchors
- Instants gallery button matches the native camera controls and glides with the capture animation
- Instants saved to gallery group under the username instead of the timestamp
- Sending Instants from your photo album handles HDR / wide-gamut photos on every device
- Video in photo sticker picker works again on Instagram 431+
- Do not save recent searches works again on Instagram 431 — search bars and the DM recipient picker stop saving
- Confirm note like also catches double-tapping a note in the inbox tray or on a profile
- Keep deleted messages survives huge unsend bursts and cache evictions, and no longer blocks Instagram's own unsend in chat
- Unsent-message toast names who unsent again instead of the generic message, even for messages received before the last app restart
- Voice notes and audio shares in the deleted-messages log save as Audio with the right file extension instead of generic Share/Link
- Deleted-messages log unread count badge now sits beside the time instead of misaligned under it
- Doom-scrolling Reels limit starts from the reel you tapped instead of the top of the feed
- OLED mode now blacks out more dark surfaces in comments, DMs, profiles and the deleted-messages log, while keeping buttons, search fields and Notes readable
- Reels force-audio finds the right audio cell when Instagram nests it differently
- Reels no longer black-screen on play in pause/play mode; silent reels are detected without flashing the "no sound" toast
- Settings search now reaches options inside nested pages like Security & Privacy and the passcode screen
- Skip sensitive content covers now reveal in any app language and work on feed posts, not just reels
- Launch tab and messages-only reliably open the chosen tab instead of sometimes landing on feed or reels
- Gallery save mode now applies to HD videos and bulk carousel saves, not just single photos
- HD downloads no longer freeze when you leave the app mid-encode — encoding continues in the background with your quality settings, switching to a software encoder when needed
- Notification action names in Settings, the read receipts footer, quality-picker sizes and several other strings now translate properly instead of always showing in English
- Hold-for-settings shortcut on the profile button works again on Instagram 432
- Profile action button works again on Instagram 432 and no longer disappears when you open its menu
- Auto mark seen on send no longer fires a read receipt when you forward or share a post into a chat, including to multiple people
- Auto mark seen on send now also covers reel quick-reactions, voice notes and media, and still marks if you leave the chat before media finishes uploading
- Confirm calls and hide call buttons now work on the new single call button that opens an audio/video menu (some accounts)
- Confirm calls no longer asks twice on accounts with the old call-button layout
- Confirm note reactions works again on Instagram 431
- Hide "Made with Edits" and "Use template" work again on Instagram 431
- Reels swipe-to-profile opens the right reel on newer Instagram versions and no longer hijacks carousel swipes
- Note theming and custom note buttons work as independent toggles again
- Instagram-native style notifications appear above tweak popups instead of behind them
- Hide UI on Capture now also redacts the home shortcut, follow indicator, follow-list filter button, notes editor buttons, revealed sticker results, story mentions counter, Instants gallery / chat background / password-locked-reels buttons, profile-card view/like/date overlays, and the Unsent tag on kept deleted messages — previously these stayed visible in screenshots
- Long-press download works again on carousel posts on Instagram 432 — saves the right photo or video from feed and Reels carousels
- Hide Meta AI works again on Instagram 432 — search, the DM inbox AI button, the summarize pill, and AI fonts
- Hide suggested users (search and profiles) and hide suggested chats work again on Instagram 432
- Copy note text on long-press, OLED chat backgrounds, DM screenshot blocking, carousel photo zoom, and the detailed color picker work again on Instagram 432
- Hiding the stories tray now also removes the mid-feed and expiring-soon stories carousels
- Detailed color picker, hiding the explore search bar, and slider sticker reveal work again on Instagram 433
- Quiz sticker reveal no longer highlights the first option when Instagram sends no answer data
- Confirm switching Instants and auto-advance after a reaction work again on Instagram 433
- Profile card likes and dates load again on the reels and reposts tabs on Instagram 433
- Custom GIF in comments works again on Instagram 432+
- Download quality sheet no longer randomly skips to standard quality on some reels and reposts
- Gallery filters now work inside grouped folders — only folders with matches show, counts and previews reflect the filter, and it carries into the folder you open
- The tweak's story menu options (exclude story seen, mute audio, view mentions) now also appear in Instagram's redesigned story menu — the new bottom sheet some accounts get — matching its native grouped style, with the same items as the classic 3-dot menu
- Profile Analyzer “You unfollowed” list now shows your real follow state — people you re-followed get an Unfollow button instead of always showing Follow

### 🔄 Changes
- RyukGram's own menus now keep the stock iOS appearance — the theme only applies to Instagram
- Profile settings toggles that lacked a description now have one
- Deleted-messages log chat list restyled to match the read receipts log, with the search bar kept at the top on iOS 26
- Follow indicator redesigned — cleaner pill look and faster cached follow statuses
- Removed the Disable instants creation toggle — Instagram has its own option to hide Instants
- Removed the Auto-scroll reels toggle — Instagram now has this natively
- Locked, hidden, and excluded chat lists now show real profile pictures, including group chat photos

## v32 ABI runtime browser correction

- Restored actual runtime hook actions in the C function browser.
- Added typed force support for validated int64/int32, double, and string/pointer C readers.
- Added observe-only action hooks for registration/update actions.
- Browser rows now show forced typed values and expose typed force from tap/context menu.
- DATA/param descriptors remain separated from function hooks; they must be routed through the consuming reader.

## v33
- Unified runtime browser: one Liquid Glass browser for Instagram executable + FBSharedFramework.
- Tabs for image scope: All / Exec / FBShared.
- Tabs for symbol kind: ObjC / C / DATA / Swift.
- DATA MobileConfig params can now be forced through IGMobileConfigBooleanValueForInternalUse descriptor matching, not by treating DATA as a function.
- ObjC BOOL getter overrides are surfaced in the same unified browser.
