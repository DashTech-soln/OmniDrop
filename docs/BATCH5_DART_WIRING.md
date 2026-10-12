# BATCH 5 - WIRE THE NATIVE STORAGE TOOLS INTO THE APP (Dart only)

Branch: wip-pairing-fixes. The Kotlin class StorageTools.kt is already built and hooked into MainActivity (it compiles in CI). This batch is DART ONLY: connect it to the UI. Do NOT edit Kotlin, Rust, generated files (frb_generated.*, lib/rust, *.g.dart), the pairing controller/cards, the dock or the progress page. Do NOT restyle anything (a separate design pass comes later): reuse the current look and the shared surface widget.

## RULES
0. Run `git pull` first. BEFORE changing anything PRINT: android_channel.dart (all of it), the storage statistics provider and card, the selection toolbar (X | SEND(N) |), the Apps loader and cells, how each category's items expose their file path (photo_manager assets, MediaStore rows, SAF DocumentFile uris, device_apps), the code that reloads categories, and browser_strings.dart. Cite file:line for every claim.
1. All new text goes in app/lib/pages/browser/browser_strings.dart. Use only real data. Never show raw PlatformException text to the user: map error codes to friendly messages and log the technical text to the Pairing log screen's log.
2. Work in TWO PARTS. After each part: `cd app && ../support/submodules/flutter/bin/dart analyze lib` (zero errors), `../support/submodules/flutter/bin/flutter test` for the files you touched, `git diff --check`, check the last 15 lines of app/lib/main.dart, then a LOCAL commit. Do NOT push (pushing always fails here; the user pushes by hand). After Part 2 STOP and report each numbered item as DONE / NOT DONE / PARTIAL with file:line evidence.
3. If StorageTools lacks something you need, do NOT edit Kotlin: list exactly what is missing in your report.

## THE NATIVE CHANNEL CONTRACT (already implemented; same MethodChannel as the existing methods)
```
getStorageStats          -> Map {total, free, photos, videos, audio, docs}   (bytes, ints)
deleteFiles  {paths:[String]} -> {deleted:[..], failed:[..], cancelled:bool}
uninstallApp {package:String} -> {launched:true}
                  errors: SELF, SYSTEM_APP, NOT_INSTALLED, BAD_ARGS
findApkFiles             -> [ {path, name, size, modified} ]
getApkInfo   {path}      -> {package, label, versionName, versionCode, state, icon:bytes?}
                  state: "not_installed" | "update" | "installed"
installApk   {path}      -> {launched:true}
                  errors: INSTALL_NOT_ALLOWED, NO_FILE, FILE_NOT_SHAREABLE, BAD_ARGS
canInstallPackages       -> bool
openInstallSettings      -> true
```
Paths for deleteFiles are absolute file paths (or content:// uris for SAF items). On Android 8-10 delete is direct; on Android 11+ the system shows its own confirmation, and the call returns only after the user answers (cancelled=true if refused).

## PART 1 - CHANNEL WRAPPERS, STORAGE CARD, DELETE, UNINSTALL

1. TYPED WRAPPERS in android_channel.dart for every method above, returning plain Dart classes (StorageStats, DeleteResult, ApkFile, ApkInfo). Convert PlatformException codes into one small enum/class with a friendly message. Add unit tests with a mocked MethodChannel (TestDefaultBinaryMessenger) for: stats parsing, delete result parsing (including cancelled), error mapping, apk info with and without an icon.
2. STORAGE CARD (Files tab): feed it from getStorageStats. Others = (total - free) - photos - videos - audio - docs, never negative. Skeleton while loading, then the real numbers; on error "Storage details unavailable" with a small Retry. Refresh the stats after every successful delete, uninstall or install.
3. DELETE (trash button). Add the trash icon to the selection toolbar: `X | SEND (N) | trash`. Flow:
```
 [trash tapped]
    |-- selection contains apps?  -> apps go to the UNINSTALL flow below; files continue here
    |-- files: confirm dialog "Delete N files (X MB)? This cannot be undone." [Cancel] [Delete]
    |       (on Android 11+ add one line: Android will ask you to confirm)
    |-- storage permission missing (Android 10 and older)? -> friendly dialog with an "Open settings" button, no delete
    |-- deleteFiles(paths)
    |       |-- cancelled=true -> nothing changes, no error message
    |       |-- deleted        -> remove them from selectedSendingFilesProvider (dock count updates),
    |       |                     reload the affected categories (this is a real file change), refresh the storage card
    |       |-- failed (non-empty) -> ONE summary line "N items could not be deleted"
```
   Take paths from each category the right way (photo_manager assets -> real file path via originFile, MediaStore rows -> their path, SAF items -> their content uri). Never pass a path you cannot prove is a real file. Do not let the user delete a file that is part of a running transfer: show a short message instead.
4. UNINSTALL (apps in the selection):
```
 for each selected app, in order:
     skip system apps and OmniDrop itself (the trash action must be disabled or filtered for them, with a one-line explanation)
     uninstallApp(package) -> the system uninstall screen opens
     wait until the app resumes (WidgetsBindingObserver) -> check whether the package is gone -> next app
 after the last one: reload the Apps list (removed apps disappear) and refresh the storage card
```
   Confirm once before starting: "Uninstall N apps?" The system screens are the real confirmation.
5. Selection after actions: items deleted or uninstalled leave the selection; everything else stays selected.

VERIFY part 1, then LOCAL commit "feat: wire storage stats, delete and uninstall".

## PART 2 - APK FILES IN THE APPS TAB (find, show, install)

6. Apps tab gets a THIRD section after System: "APK files - N". It lists real APK files from findApkFiles (newest first, max 500). Each APK cell keeps the current app-cell layout:
```
   +--------+
   |  icon  |   real icon from getApkInfo (generic APK icon until it loads)
   |  Name  |   label from getApkInfo (file name until it loads)
   | [pill] |   Install | Update   (tappable pill)    or   "Installed" (plain dim text, not tappable)
   +--------+
```
   - getApkInfo loads lazily as cells scroll into view: max 2 calls at a time, cache by path + modified time, never block scrolling, never read the whole list at once.
   - Tapping the CELL selects it (for sending, uses the file path). Only the pill starts an install.
   - If getApkInfo says NOT_APK, show the file name with a generic icon and no pill.
7. INSTALL flow:
```
 [Install/Update pill]
    -> installApk(path)
         |-- INSTALL_NOT_ALLOWED -> dialog "Allow OmniDrop to install apps" [Not now] [Open settings]
         |       [Open settings] -> openInstallSettings
         |       on resume: canInstallPackages? yes -> run installApk once more; no -> do nothing
         |-- launched -> the system installer opens
                 on resume: re-run getApkInfo for that path so the pill becomes "Installed"; refresh the Local apps list
         |-- other error -> friendly message (FILE_NOT_SHAREABLE: "This file location cannot be shared with the installer")
```
8. Deleting APK files works through the normal trash flow (they are files).
9. Add unit/widget tests that can run (pill state mapping, selection of an APK cell, install flow error handling with a fake channel). If the Flutter test compiler crashes, say so; do not claim tests passed.

VERIFY part 2, then LOCAL commit "feat: APK files section with install".

## FINAL REPORT
List items 1-9 as DONE / NOT DONE / PARTIAL with file:line evidence, anything you could not verify, and anything StorageTools would still need (do not edit Kotlin).
