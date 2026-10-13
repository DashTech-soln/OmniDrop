# BATCH 5B - FIXES FROM THE DELETE / UNINSTALL TEST (Dart only)

Branch: wip-pairing-fixes. Dart only. Do NOT edit Kotlin (StorageTools.kt and MainActivity.kt are built and stay untouched), Rust, generated files (frb_generated.*, lib/rust, *.g.dart), the pairing code, the dock or the progress page. Do NOT restyle anything (a separate design pass comes later).

## RULES
0. Run `git pull` first. Before changing anything PRINT the relevant code and cite file:line for every root cause. Evidence only; where code cannot prove a cause, add logging (Pairing log screen's log) and say what to look for.
1. Text goes in app/lib/pages/browser/browser_strings.dart. Never show raw exception text to the user.
2. Two parts. After each part: `cd app && ../support/submodules/flutter/bin/dart analyze lib` (zero errors), `../support/submodules/flutter/bin/flutter test` for touched files, `git diff --check`, last 15 lines of app/lib/main.dart, then a LOCAL commit. Do NOT push (the user pushes by hand). After Part 2 STOP and report items as DONE / NOT DONE / PARTIAL with file:line evidence.

## PART 1 - FUNCTION BUGS

1. DELETE FAILS IN DOCUMENTS, AUDIO, VIDEOS AND DOWNLOADS. The snackbar says: "Some selected files could not be safely identified for deletion." It works in the Files tab. Print the path-verification code and exactly what each of these tabs' items exposes (real path? content uri? media id?). The native deleteFiles accepts absolute file paths AND content:// uris. Fix the Dart side so every MediaStore-backed row passes either its real file path or its own content uri (for example content://media/external/file/<id>, /video/media/<id>, /audio/media/<id>), and make the verifier accept a content uri it can prove belongs to MediaStore. Log the reason for every item that is still rejected. Never pass a path you cannot prove is a real file or a MediaStore uri.
2. IMAGES TAB SHOWS GHOSTS AFTER DELETE. Deleted photos are gone from the Gallery but stay in the browser as blank tiles that cannot be tapped or selected. Fix: (a) remove the deleted items from the in-memory list the moment deleteFiles reports them as deleted; (b) then reload with the photo_manager cache cleared (clearFileCache) so nothing stale is shown; (c) any tile whose asset no longer exists must disappear silently instead of staying blank; (d) register a photo_manager change callback (startChangeNotify / addChangeCallback) so a delete done outside the app also refreshes the list. This is a real file change, so reloading is allowed.
3. FOLDERS CANNOT BE SELECTED (Files tab). The folder rows show a circle-plus but it does nothing for folders. Required: tapping the row opens the folder; the circle (touch area 48dp) selects or deselects the folder. A selected folder can be sent or deleted. The delete confirmation for a folder reads: Are you sure you want to delete the folder "<name>" and everything inside it? This cannot be undone. Deleting a folder uses the same deleteFiles call (the native side removes folders recursively and refuses the storage root and the Android folder).
4. STORAGE PERMISSION IS REQUESTED EVERYWHERE. From reopening the app to every tab switch the system permission dialog appears; if denied, no files are shown. Required behaviour, one shared state for all tabs:
```
 first need  -> ask ONCE per app session
 denied      -> every tab shows the SAME inline screen: icon, one sentence, [Allow access] button
                no system dialogs on tab switches, no loops
 [Allow access] -> asks again; if the system says "never ask again" the button becomes [Open settings]
 on resume   -> silently re-check; if granted, load the tab with no prompt
```
5. DIALOG WORDING. Delete: "Are you sure you want to delete N files (X MB)? This cannot be undone." (folder wording as in item 3). Uninstall: "Are you sure you want to uninstall N apps?" Keep Cancel / Delete (Uninstall) buttons.
6. UNINSTALL SHOWS NO SYSTEM SCREEN. In the test the app was uninstalled right after OmniDrop's own confirmation, with no Android uninstall screen, and a "cancel" test was impossible. Android does not allow silent uninstalls, so find out what really happens. PRINT the complete call chain from the trash tap to the platform call and prove whether it goes through StorageTools.uninstallApp or through another plugin function (for example a device_apps uninstall helper). If another path is used, route it through StorageTools.uninstallApp. Add Pairing-log lines: uninstall_launch <package>, then on resume uninstall_return <package> stillInstalled=<true/false>. Do NOT edit Kotlin; if you conclude the native intent needs a change, say exactly what and why in the report.
7. A file that belongs to an active transfer must not be deletable: add a test for the check (fake the transfer state).

VERIFY part 1, then LOCAL commit "fix: delete in media tabs, ghosts, folder select, permission flow, dialogs".

## PART 2 - SPEED (measure first, then fix)

8. APPS TAB LOADS SLOWLY. First add timing logs (shown in the Pairing log): time from tab open to first cell, to first icon, to all icons. Then fix with evidence:
```
 tab opened -> show the CACHED list instantly (package, label, size, version; icons as small PNG files in the cache dir)
            -> refresh in the background, diff, update only what changed
 icons      -> only for visible cells, decoded at 96px, memory LRU + disk cache, never all at once
 sizes      -> cheap source file length, never per-app slow queries
 heavy work -> compute/isolate, nothing heavy in build()
 revisit    -> keep the list alive; invalidate only when the package list changed (check on resume)
```
9. SCROLLING FEELS HECTIC AND RIGID (all tabs). Audit and fix with file:line evidence for each finding:
   - BackdropFilter / blur inside scrolled content (very expensive on a low-end phone such as the Honor 7X)
   - shrinkWrap lists, NeverScrollable physics, nested scrollables
   - setState in scroll listeners (header collapse, pill notifier) rebuilding the whole page
   - thumbnails decoded at full size: request thumbnails at the exact cell pixel size (photo_manager ThumbnailSize and cacheWidth/cacheHeight on Image.memory), gaplessPlayback true
   - do not load thumbnails while the list is flinging (Scrollable.recommendDeferredLoadingForContext or ScrollAwareImageProvider)
   - fixed row height (itemExtent or prototypeItem) for the list tabs, RepaintBoundary per cell, addAutomaticKeepAlives false, cacheExtent about 500
   - header collapse with hysteresis: hide after 24dp of continuous downward scroll, reveal after 16dp upward, 200ms animation, no flicker
   - physics: use BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()) for a smoother, elastic feel on every browser list and grid
   Report what you found and changed, and anything you could not prove.

VERIFY part 2, then LOCAL commit "perf: apps cache and smoother scrolling".

## FINAL REPORT
Items 1-9 as DONE / NOT DONE / PARTIAL with file:line evidence; the proven cause for item 6; anything native you believe is still needed (do not edit Kotlin).
