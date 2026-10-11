# BATCH 4B - FILE BROWSER FIXES, LAYOUT AND BOTTOM BAR (Dart only)

Branch: wip-pairing-fixes. This batch fixes everything found when Phase 1 was tested on a real phone (Honor 7X, Android 8.0, 360dp wide). Phase 2 (real delete, app uninstall, real storage statistics - Kotlin) is NOT part of this batch: do NOT start it.

## ORCHESTRATION RULES (read first)
0. Run `git pull` first. Before changing anything, PRINT the current code you are about to change (home_page.dart, send_tab.dart, in_app_file_browser.dart, browser_surface.dart, browser_strings.dart, the bottom navigation, the Send/Receive pill code, the old extra FAB, the photo/album loaders, the apps loader, the document/download row widget, the Text tab card, the Settings page). No guessing: cite file:line for each root cause.
1. Dart only. Do NOT edit Rust, Kotlin, generated files (frb_generated.*, lib/rust, *.g.dart), the pairing controller, the pairing cards, the floating transfer dock or the transfer progress page. Do not add packages unless a bug cannot be fixed without one (say so first).
2. All new user-facing text goes in app/lib/pages/browser/browser_strings.dart. No slang codegen, no build_runner.
3. Use the shared surface widget from browser_surface.dart for every new card, bar, chip, pill and sheet. No hard-coded glass/blur in individual widgets.
4. Real data only. If data is not available yet, show an honest loading or "unavailable" state. Never invent numbers, files or apps.
5. Work in THREE PARTS. After each part: run `cd app && ../support/submodules/flutter/bin/dart analyze lib` (zero errors), run `flutter test` for the files you touched, `git diff --check`, check the last 15 lines of app/lib/main.dart, then commit and `git push origin wip-pairing-fixes`. If a push fails with an authentication error, STOP and say so (the user pushes by hand). After Part 3, STOP and report; do not continue.
6. Every item below must be applied EXACTLY as written. At the end, report each numbered item as DONE / NOT DONE / PARTIAL with file:line evidence.

## SCREEN ANATOMY (the target, portrait phone)

```
+--------------------------------------------------+
| system status bar                                |
+--------------------------------------------------+
| HEADER (normal state)                            |
|  [:]  (logo) OmniDrop           [search] [=] [*] |  <- search icon sits immediately LEFT
|                                                  |     of the right-hand option buttons
+--------------------------------------------------+
| CATEGORY TAB BAR  (height = 2/3 of today's)      |
|  [dl] [APPS: icon+label] [img] [vid] [aud] [doc] |  <- only the SELECTED tab shows its
|        selected = icon + name, others = icon only|     name; icon size/name size unchanged
+--------------------------------------------------+
| +----------------------------------------------+ |
| | FILE BROWSER CARD                            | |  <- as wide and as tall as possible:
| | (list or grid; scrolls inside the card)      | |     8dp side margins, its top edge
| |                                              | |     touches the tab bar, its bottom
| |        +-----------------+                   | |     edge reaches the TOP of the
| |        | SEND  |  RECEIVE|  <- floating pills| |     bottom bar and passes right
| |        +-----------------+   (overlay, no    | |     below the center FAB
| |                                 layout space)| |
| +----------------------------------------------+ |
|            (FILES TAB ONLY: see storage card)    |
|   ______                    ______               |
|  /      \      (  FAB  )    /      \             |
| | WebDrop | OS Pairs | FAB | Cloud |  Me |       |  <- bottom bar = 50% of today's height,
|  \______/                                        |     FAB protrudes above the bar
+--------------------------------------------------+
```

FILES TAB ONLY (storage card sits on its own, fixed, directly above the bottom bar; the browser card shortens to make room):

```
| FILE BROWSER CARD (shorter)                      |
+--------------------------------------------------+  <- 8dp gap
| STORAGE CARD (fixed, ~104dp)                     |
| [=] Storage: 51.47 GB        [=] Available: 634 MB|
| [====teal====|===blue===|====lavender===|o|y|   ] |  <- segmented bar
| (teal)Photos  2.94 GB     (orange)Music   1.58 GB |
| (blue)Videos 18.11 GB     (yellow)Docs    83.73 MB|
| (lav) Others 28.14 GB                             |
+--------------------------------------------------+
| BOTTOM BAR                                        |
```

## PART 1 - BUGS (do these first)

1. PHOTOS AND ALBUMS DO NOT LOAD. Root cause is visible in the on-screen error: the SQL is `... ORDER BY LIMIT 100 OFFSET 0` (empty ORDER BY) -> "near LIMIT: syntax error" (SQLite on Android 8). The photo_manager query is built without any order option. Fix: every `getAssetListPaged` / `getAssetListRange` / path query must use a FilterOptionGroup that contains an explicit order, newest first: `OrderOption(type: OrderOptionType.createDate, asc: false)`. Apply it to Photos, Albums (album contents), Videos and any other photo_manager query, so they cannot break the same way. Photos stay a 3-column date-grouped grid; opening an album shows its photos date-grouped below it (only one album open at a time). Never show raw exception text to the user: show a friendly message with a Retry button, and put the technical text in the Pairing log screen's log.
2. APPS HAVE NO SECTIONS AND NO SYSTEM APPS. Show two sections with sticky headers: "Local - N" (installed non-system apps) and "System - N" (system apps; include system apps in the query). Both use the same 4-column grid. APK files found on storage are NOT part of this batch (note it as a later item).
3. DOCUMENTS AND DOWNLOAD ROWS SHOW NO FILE NAME (only size and date). Find the cause and fix it with this fallback chain: display name -> title -> file name from the path -> last URI segment -> "Unnamed file". The name is the first line of the row (2 lines max, ellipsis). Check Videos, Audio and Files rows for the same bug.
4. TEXT TAB "SAY HELLO" CARD DOES NOT WORK. Print what exists in the app for sending a text message (the existing "send message / text" flow: compose dialog and how the message becomes a sendable item). Build the card as a chat bubble:

```
   +--------------------------------------------+
   | (chat icon)  Say hello                 [>] |   <- rounded bubble, small tail at left,
   +--------------------------------------------+      paper-plane icon at the right
```
   Tapping the card opens the EXISTING compose flow; after composing, the message is added to the selected items and sent like a file (to the connected peer(s) if a pairing connection exists, otherwise through the normal device picker). If the app has no such flow, say so and STOP this item (do not fake it). Below the card, list text files as bubble-style rows.

## PART 2 - LAYOUT (follow the anatomy diagram exactly)

5. CATEGORY TAB BAR. Height = exactly 2/3 of the current height (print the current value and compute). Icon size and label font size do NOT change. Unselected tabs show the icon only; the selected tab shows icon + label side by side (animated width). Result: the whole bar is mostly visible without scrolling; keep it scrollable and swipeable, and auto-scroll the selected tab into view.
6. HEADER AND SEARCH. Remove the separate search/sort row from the body completely.

```
   NORMAL:   [:]  (logo) OmniDrop                [search] [=] [*]
   SEARCH:   [<-] [ search icon  Search in <category>...  [sort] [x] ]
```
   - The search icon is in the header, immediately to the left of the right-hand option buttons.
   - Tapping it makes the search field occupy the whole header; all normal header items fade/slide away (200ms). Closing search (x or the system back button) brings them back the same way, exactly like the selection mode swaps the bottom bar.
   - The sort control lives INSIDE the expanded search bar (left of the x): name, date, size, ascending/descending. Searching and sorting keep working per category as now.
   - The file browser card grows into the space the old row used.
7. FILE BROWSER CARD SIZE. It fills all available space: top edge directly under the tab bar, 8dp side margins, bottom edge reaches the top of the bottom bar and passes right below the center FAB (the FAB is drawn on top of the card's bottom edge, like the storage card in the reference).
8. APP CELLS (Apps tab). Make every cell (almost) square: width = height (childAspectRatio about 1.0, never below 0.95). Keep the icon size and icon area exactly as they are.

```
   NOW (tall):             TARGET (square):
   +--------+              +--------+
   |  icon  |              |  icon  |   icon unchanged
   |        |              | Name   |   app name: BOLD, 1 line, ellipsis
   |  Name  |              | 77 MB  |   size: directly under the name, gap <= 2dp,
   |        |              +--------+   font = name font minus 1-2sp
   |  size  |
   +--------+
```
   Handle large system font sizes without overflow (FittedBox or ellipsis).
9. SEND/RECEIVE PILLS = OVERLAY, NOT LAYOUT. They must not take space of their own. Put them in a Stack ABOVE the browser card (Positioned, foreground), so files scroll behind them, like the dock. Remove the NEW extra FAB shown above the bottom bar (the square FAB in the screenshots) completely.

```
   pill state machine (kept in its own small notifier, NOT in the page state):

        +-----------+   5 s after it appeared        +----------+
        |  VISIBLE  | ------------------------------>|  HIDDEN  |
        |           |<------------------------------ |          |
        +-----------+   tap the center FAB           +----------+
              |  tap the center FAB (when visible) -> HIDDEN
              |  tap ANYWHERE ELSE, scroll, select  -> NO change
```
   - The ORIGINAL center FAB of the bottom bar owns this: on the Transfer tab it toggles the pills; on other tabs it first returns to the Transfer tab. The pills appear on entering the Transfer tab, then hide after 5 seconds.
   - NO REFRESH: appearing or disappearing pills must never rebuild or reload the file browser. Isolate the pill widgets (own provider/ValueNotifier, RepaintBoundary, const browser subtree, AutomaticKeepAliveClientMixin on tab pages). The browser reloads ONLY on: pull-to-refresh, a real file change (delete / uninstall / media change callback), or first load. Tab switches, pill toggles and app resume do not reload. Add a debug counter or a log line to prove it.
10. BOTTOM BAR. Height = exactly 50% of today's height (print and compute). Five slots: WebDrop, OS Pairs, CENTER FAB, Cloud, Me. The FAB is a circle with a thin glowing ring, protruding above the bar (the bar outline curves around it), keeping the OmniDrop logo inside. Put back the Cloud tab: a simple page with an icon and the text "Cloud sync between devices is coming soon". The reference look: dark rounded bar with a raised circular center button.
11. PERMISSION DENIED SCREEN: verify (revoke the permission, reopen) that the friendly screen with a working "Open settings" button shows. Report what you found; fix if broken.

## PART 3 - STORAGE CARD (FILES TAB ONLY) AND SURFACE STYLE

12. STORAGE CARD. Remove the placeholder "Storage statistics will be available in a later phase" row from inside the browser card. Build the fixed storage card shown in the diagram, visible ONLY on the Files tab, sitting on its own right above the bottom bar (8dp gap); the browser card shortens to make room on that tab only. Content: header row "Storage: <total>" left and "Available: <free>" right (with small icons); one rounded segmented bar (used space by category: Photos teal, Videos blue, Others lavender, Music orange, Docs yellow; the remainder is the empty track); legend in two columns (Photos, Videos, Others / Music, Docs) with size values (GB or MB as needed). Colors defined once as tokens.
   Data comes from ONE provider `storageStatsProvider` returning a plain class (total, free, photos, videos, audio, docs, others = used minus the sum of the others). It reads a platform-channel method `getStorageStats` that will be implemented natively in Phase 2. Until it exists (MissingPluginException), show the card with a skeleton and the honest text "Calculating..." then "Storage details unavailable". NO fake numbers.
13. SURFACE STYLE SETTING. Settings -> Appearance: add "Surface style" with two choices, Clean (default) and Glass. Persist it with the app's existing settings storage. The shared surface widget reads it, so the browser card, tab bar, search bar, pills, storage card and bottom bar switch instantly. Glass = the current translucent look; Clean = solid surfaces, thin border, no blur. Both must work in light and dark themes.

## FINAL REPORT (after Part 3, then STOP)
List items 1-13 as DONE / NOT DONE / PARTIAL with file:line evidence, the root causes of items 1, 3 and 9, anything you could not verify, and what Phase 2 will need from the Dart side (channel method names you expect: `getStorageStats`, `deleteFiles`, `uninstallApp`).
