ORCHESTRATION NOTES (read first, these override anything below that conflicts)

0. Run `git pull` first. PRINT the real current code of everything listed under "first inspect" before changing anything. No guessing, no fake data, no fake success.
1. Do NOT edit Rust, generated files (frb_generated.*, lib/rust, *.g.dart), the pairing controller logic, the pairing cards, the floating transfer dock or the transfer progress page. When a pairing connection is active, the Send/Receive pills are replaced by a Disconnect button that the pairing batch provides: read the connected state from the pairing controller and do not build your own.
2. selectedSendingFilesProvider is the single source of truth for selection. The dock count, the selection toolbar SEND(N) and the highlights in the browser must stay in sync both ways. Highlights disappear when items are deselected.
3. All new user-facing text goes in app/lib/pages/browser/browser_strings.dart as const English strings. No slang/translation codegen, no build_runner, no dart_mappable models.
4. Kotlin is allowed ONLY for: real file delete (MediaStore.createDeleteRequest on Android 11+, RecoverableSecurityException handling on Android 10, plain delete or DocumentFile on older versions), app uninstall via the system package-uninstaller intent (one system prompt per app is expected, never silent), and real storage statistics (StatFs / StorageStatsManager). Expose them through the existing platform channel. Keep them minimal and defensive. Build and test Dart first, add the Kotlin delete/uninstall/storage last.
5. App startup must stay fast and must never block on scanning. Never scan storage in build() or before the first frame (a previous build showed a white screen at launch). Load categories lazily, page the results, and cache thumbnails sized to the cell.
6. Use the OmniDrop theme tokens already in the app (dark and light). Do not hard-code colors in components.
7. VERIFY: whole-app `cd app && fvm dart analyze lib` with zero errors (fall back to the repo-pinned Dart SDK if fvm is missing); `git diff --check`; check the last 15 lines of app/lib/main.dart for stray characters. If the Flutter test compiler crashes, say so and do not claim tests passed. Add tests only where they can run.
8. FINISH: commit "feat: final file browser (categories, swipe, search, selection, delete, storage)", `git push origin main`. If the push fails with an authentication error, STOP and say so (the user pushes manually). Show `git log -1 --stat` and the commit hash, and list every file you removed as obsolete.
9. SURFACE STYLE FOUNDATION: do not hard-code glass/blur/translucent decorations in individual widgets. Create ONE shared surface widget (and tokens) used by every new card, tile, sheet, pill and bar in the browser, with a style parameter that has two values: clean (flat, solid surfaces, subtle border, no blur) and glass (the existing translucent glass look). The default is clean for NEW browser surfaces; the existing glass look must stay available as the glass value. Do not add the user-facing setting yet and do not restyle the pairing cards, the dock or the progress page; a later batch will switch the whole app between the two styles from Settings.

============================================================
TASK DOCUMENT
============================================================
You are working on the OmniDrop Android application.
Your task is to redesign/refactor the ENTIRE FILE BROWSER / FILE
TRANSFER UI using the existing OmniDrop signature design as the
visual foundation while implementing the new file-browser architecture
defined below.
This is an IMPLEMENTATION task, not a visual mockup task.
First inspect the existing project and identify:
- current browser/files screen
- current top bar/header
- current horizontal category navigation
- current Apps grid
- current Images/media implementation
- current file discovery system
- current search capabilities
- current selection system
- current Send/Receive controls
- current transfer FAB
- current bottom navigation
- current storage statistics
- current WebDrop implementation
- current OS Pairs implementation
- current QR/Wi-Fi transfer flow
- current Android permission handling
- current delete/uninstall behavior
Reuse existing working architecture wherever possible.
DO NOT unnecessarily rewrite the transfer/network engine.
The objective is to build a polished OmniDrop file browser on top of
the existing working functionality.
============================================================
1. OMNIDROP DESIGN IDENTITY
============================================================
Use the existing OmniDrop signature design as the foundation.
The reference design language is:
- futuristic
- clean
- premium
- dark navy/black
- cyan/teal accent
- rounded panels
- rounded category buttons
- subtle cyan borders
- restrained glow
- modern typography
- floating transfer controls
- central transfer FAB
- rounded bottom navigation
OmniDrop must remain visually recognizable.
Do NOT copy another application's branding, logos, wording,
or proprietary visual identity.
============================================================
2. SUPPORT BOTH LIGHT MODE AND DARK MODE
============================================================
The file browser MUST support two complete visual themes:
DARK MODE
and
LIGHT MODE.
The layout, interaction behavior, spacing and architecture must remain
the SAME between the two themes.
Only visual properties change:
- background
- surfaces
- borders
- text
- icon treatment
- shadows/glows
- active states
Do NOT build two separate UI architectures.
Use one shared component architecture with theme-aware colors.
============================================================
3. DARK MODE
============================================================
Dark mode should retain the current OmniDrop signature appearance.
Background:
very dark navy / near black.
Suggested direction:
#050A10
#07131B
#081A23
Primary OmniDrop cyan:
approximately:
#00CFE8
Secondary teal:
approximately:
#00AFC4
Text:
white / light gray.
Inactive surfaces:
dark navy / translucent dark surfaces.
Borders:
subtle cyan/teal.
Active elements:
cyan/teal with restrained glow.
Avoid excessive neon effects.
The interface should feel premium, not like a gaming interface.
============================================================
4. LIGHT MODE
============================================================
Add a complete light-theme version of the same interface.
Light mode must preserve the exact same layout architecture.
Use:
background:
#F5F7F8 or similarly soft neutral
surface:
#FFFFFF
primary text:
dark navy / charcoal
secondary text:
muted gray
primary OmniDrop accent:
cyan/teal
suggested:
#00BFD6
or existing OmniDrop cyan token.
Borders:
very light cyan-gray.
Active tabs:
light/cyan filled surface with stronger cyan border.
Selected elements:
soft cyan-tinted background.
Shadows:
very subtle cool-gray shadows.
DO NOT turn the interface into a generic white Material Design screen.
The OmniDrop cyan identity must remain obvious.
============================================================
5. THEME REQUIREMENT
============================================================
Every UI component must use theme tokens.
DO NOT hard-code colors directly inside individual components.
Create/use centralized theme values for:
background
surface
surfaceElevated
primary
secondary
border
textPrimary
textSecondary
icon
selection
destructive
divider
This allows dark/light mode to remain consistent.
============================================================
6. OVERALL FILE BROWSER ARCHITECTURE
============================================================
The browser contains:
A. Collapsing OmniDrop header
B. Horizontal category navigation
C. Search control
D. Category-specific content
E. Floating Transfer controls
F. Storage panel ONLY on the Files category
G. Bottom navigation
H. Selection mode toolbar
============================================================
7. FILE CATEGORIES
============================================================
The horizontal categories MUST be:
DOWNLOAD
APPS
IMAGES
VIDEOS
AUDIO
DOCUMENTS
TEXT
FILES
Order:
DOWNLOAD
APPS
IMAGES
VIDEOS
AUDIO
DOCUMENTS
TEXT
FILES
The category bar is horizontally scrollable.
============================================================
8. CATEGORY NAVIGATION — TAP
============================================================
Each category tab must be fully clickable.
Tapping:
DOWNLOAD
→ opens Downloads browser.
APPS
→ opens Apps browser.
IMAGES
→ opens Images browser.
VIDEOS
→ opens Videos browser.
AUDIO
→ opens Audio browser.
DOCUMENTS
→ opens Documents browser.
TEXT
→ opens Text browser.
FILES
→ opens the Generic Files browser.
The active category must immediately update.
The content presentation mode changes according to category.
============================================================
9. CATEGORY NAVIGATION — SWIPE
============================================================
IMPORTANT:
Support horizontal SWIPING LEFT/RIGHT between file categories.
The user must be able to:
swipe left
→ move to the next category.
swipe right
→ move to the previous category.
Example:
DOWNLOAD
→ swipe left
→ APPS
APPS
→ swipe left
→ IMAGES
IMAGES
→ swipe left
→ VIDEOS
VIDEOS
→ swipe left
→ AUDIO
and so on.
Reverse direction:
FILES
→ swipe right
→ TEXT
TEXT
→ swipe right
→ DOCUMENTS
etc.
The category navigation bar must automatically scroll to keep the
active category visible.
============================================================
10. SWIPE + VERTICAL SCROLL MUST NOT CONFLICT
============================================================
This is important.
Vertical gestures inside the file browser must remain vertical scrolling.
Horizontal gestures should change categories.
Use proper gesture direction detection.
Do not accidentally switch categories during normal vertical scrolling.
The threshold should require a clearly horizontal swipe.
For grids and lists:
vertical movement:
→ scroll content.
horizontal dominant movement:
→ switch category.
============================================================
11. TOP OMNIDROP HEADER
============================================================
Use the existing OmniDrop signature header.
Header contains:
OmniDrop logo
OmniDrop title
menu button
settings/action button(s) already present in the project
The visual design should match the existing signature screenshot.
Dark mode:
dark navy/black header.
Light mode:
light/white header with dark text and cyan accents.
============================================================
12. TOP BAR DISAPPEAR BEHAVIOR
============================================================
IMPORTANT:
The large OmniDrop top bar MUST disappear when the user scrolls UP.
However, it must NOT automatically reappear merely because the user
slows down or because a timer expires.
The header reappears ONLY under these conditions:
CONDITION A:
The user manually drags DOWN / performs a downward scroll gesture.
OR
CONDITION B:
The user scrolls all the way back to the first items/top of the
current content.
Therefore:
Scroll UP:
→ hide header.
Continue scrolling:
→ header remains hidden.
Stop scrolling:
→ header remains hidden.
Wait 10 seconds:
→ header remains hidden.
Scroll downward manually:
→ header reappears.
Return to the beginning/top of the content:
→ header reappears.
This behavior is REQUIRED.
============================================================
13. HEADER COLLAPSE ANIMATION
============================================================
When user scrolls upward:
header collapses smoothly.
Recommended:
200–300ms.
When user manually drags downward:
header expands smoothly.
Do not make it jump.
============================================================
14. HEADER COLLAPSED STATE
============================================================
When collapsed, the browser should gain maximum vertical space.
The file/category browser remains fully usable.
The horizontal category navigation should remain accessible in an
appropriate compact/sticky position.
Do not remove access to category navigation when the large header
collapses.
============================================================
15. SEARCH — NEW FEATURE
============================================================
The existing application DOES NOT currently support search.
ADD SEARCH TO THE FILE BROWSER.
Search must work across the content currently being browsed.
The search control should be visible near the top browser controls
and accessible in both expanded and collapsed header states.
============================================================
16. SEARCH UX
============================================================
Normal state:
show a search icon.
When tapped:
expand/open a search field.
Example:
┌─────────────────────────────────────┐
│ 🔍 Search files...              ×   │
└─────────────────────────────────────┘
The search input should support:
- filename
- application name
- file type/extension where possible
Examples:
Search:
"report"
results:
report.pdf
project-report.docx
report-final.txt
============================================================
17. SEARCH BEHAVIOR
============================================================
Search must be category-aware.
Apps:
search installed applications.
Images:
search image filenames/albums where applicable.
Videos:
search video filenames.
Audio:
search audio filenames.
Documents:
search document names.
Text:
search text/code filenames.
Files:
search generic files.
Downloads:
search downloaded files.
The current category remains the active context.
============================================================
18. SEARCH RESULTS LAYOUT
============================================================
Search results MUST preserve the presentation style of the current
category.
Examples:
Apps search:
→ 4-column grid.
Images search:
→ image grid.
Videos search:
→ vertical thumbnail list.
Audio search:
→ vertical list.
Documents search:
→ vertical list.
Files search:
→ vertical list.
Do NOT create a separate generic search-results UI.
============================================================
19. SEARCH EMPTY STATE
============================================================
If nothing matches:
show a clean empty state.
Example:
No files found
Search:
"assignment"
Do not show a blank screen.
============================================================
20. SEARCH CLEAR
============================================================
Provide a clear X button.
Tapping X:
clears query
restores full category contents.
============================================================
21. APPS CATEGORY
============================================================
APPS MUST use a fixed 4-column grid on phone portrait.
Each item:
icon
application name
size
The grid must be geometrically rigid.
Every cell:
same width
same height
same internal spacing.
============================================================
22. APP GRID ALIGNMENT
============================================================
Do NOT use content-driven vertical positioning.
Each cell contains fixed regions:
ICON REGION
NAME REGION
SIZE REGION
Recommended conceptual structure:
┌─────────────┐
│             │
│    ICON     │
│             │
│ App Name    │
│ 22.08 MB    │
│             │
└─────────────┘
Different icon dimensions must NOT move the text.
Different name lengths must NOT change cell height.
Different file sizes must NOT change cell geometry.
============================================================
23. APP NAME
============================================================
Application names MUST be a single line.
Use:
singleLine = true
maxLines = 1
ellipsize = END
gravity = CENTER
Examples:
Control Cen...
Family Savio...
GoChop Driv...
PartnerNet...
Never allow:
Family
Savior
unless explicitly required by a future design revision.
============================================================
24. APP SELECTION
============================================================
Selected app:
show OmniDrop selection indicator/check.
Use cyan/teal in light/dark themes.
Selection must NOT:
move icon
move text
change cell size
change row spacing.
============================================================
25. IMAGES CATEGORY
============================================================
IMAGES is also a grid-based category.
IMAGES contains two subcategories:
PHOTOS
ALBUMS
============================================================
26. PHOTOS / ALBUMS SELECTOR
============================================================
Use a segmented selector.
Example:
┌──────────────────────┬──────────────────────┐
│ 🖼 Photos (66)       │ ▣ Albums (25)       │
└──────────────────────┴──────────────────────┘
Active:
OmniDrop cyan.
Inactive:
theme surface with cyan outline.
Counts are dynamic.
Never hard-code the counts.
============================================================
27. PHOTOS
============================================================
Photos use:
3-column grid on phone portrait.
Use:
equal cells
consistent spacing
efficient thumbnails
centerCrop
Support chronological grouping.
Example:
October 5, 2026
[IMG][IMG][IMG]
[IMG][IMG][IMG]
[IMG][IMG][IMG]
October 4, 2026
[IMG][IMG][IMG]
============================================================
28. ALBUMS
============================================================
Albums are grouped collections.
Do not display albums as ordinary individual photo files.
Each album should show:
cover image
album name
photo count
Example:
[cover]   Graduation
          48 photos
Use a clean album-oriented layout.
============================================================
29. OTHER FILE CATEGORIES
============================================================
These categories MUST be vertical lists:
DOWNLOAD
VIDEOS
AUDIO
DOCUMENTS
TEXT
FILES
============================================================
30. FILE ROW
============================================================
Each file is represented by a fixed-height horizontal row.
Example:
┌──────────────────────────────────────────┐
│ [THUMB]   Project Report.pdf        ›   │
│            4.82 MB • Oct 8             │
└──────────────────────────────────────────┘
Recommended:
row height:
72–84dp
horizontal padding:
16dp
thumbnail:
52–60dp
corner radius:
6–8dp
text gap:
12dp
============================================================
31. FILE THUMBNAILS
============================================================
Use actual thumbnails whenever possible.
Images:
actual image thumbnail.
Videos:
video frame + play indicator.
Audio:
album artwork.
Documents:
preview thumbnail where practical.
Generic files:
MIME-type vector icon.
Do not load unnecessarily large images.
============================================================
32. FILE NAME
============================================================
Filename:
16–18sp
dark/light theme appropriate
single line where possible
ellipsize END
Filename must not destroy row geometry.
============================================================
33. FILE SECONDARY INFORMATION
============================================================
Use:
13–15sp.
Possible information:
size
date
duration
extension
file type
Examples:
4.82 MB • PDF • Oct 8
182 MB • 04:32
8.2 MB • 04:12
============================================================
34. FILES CATEGORY — IMPORTANT
============================================================
The FILES category is the GENERIC FILE BROWSER.
When the user taps:
FILES
it must open the full vertically stacked generic file browser.
Display files from appropriate user-accessible storage locations.
Each row contains:
thumbnail/icon
filename
extension/type
size
modified date
The FILES category must NOT open a blank placeholder page.
The Files category tap MUST perform the actual navigation described
in the architecture above.
============================================================
35. DOWNLOADS
============================================================
Downloads:
vertical list.
Default sort:
newest first.
Show:
thumbnail/icon
filename
size
date
============================================================
36. VIDEOS
============================================================
Videos:
vertical list.
Show:
thumbnail
play badge
filename
duration
size
============================================================
37. AUDIO
============================================================
Audio:
vertical list.
Show:
album artwork or audio icon
title/name
duration
size
============================================================
38. DOCUMENTS
============================================================
Documents:
vertical list.
Support:
PDF
DOC
DOCX
XLS
XLSX
PPT
PPTX
etc.
Use MIME-specific icons.
============================================================
39. TEXT
============================================================
Text:
vertical list.
Include:
TXT
JSON
XML
CSV
LOG
source code
configuration files
etc.
============================================================
40. FILES
============================================================
Generic vertical file browser.
Use:
actual thumbnail where available
MIME icon otherwise.
Show:
filename
extension
size
modified date
============================================================
41. NORMAL SEND / RECEIVE CONTROLS
============================================================
During NORMAL browsing show:
SEND
RECEIVE
as two floating pill-shaped controls.
Use OmniDrop signature cyan/teal.
Dark mode:
cyan/teal glowing treatment.
Light mode:
cyan filled/pale cyan treatment with darker text where appropriate.
Recommended:
height:
56–64dp
pill radius:
28–32dp
These controls must be accessible and easy to tap.
============================================================
42. AUTO-HIDE SEND / RECEIVE
============================================================
After approximately 3 seconds of inactivity:
SEND and RECEIVE disappear.
This applies across EVERY category.
They do NOT disappear permanently.
============================================================
43. TRANSFER FAB
============================================================
A central Transfer FAB remains accessible.
When SEND/RECEIVE are hidden:
only the Transfer FAB remains.
When the user taps the Transfer FAB:
SEND and RECEIVE reappear.
Reset the 3-second timer.
This behavior MUST be consistent in:
Downloads
Apps
Images
Videos
Audio
Documents
Text
Files
============================================================
44. FAB VISIBILITY TIMER
============================================================
Use one lifecycle-safe controller/state.
When SEND/RECEIVE become visible:
start/reset timer.
After ~3 seconds:
hide them.
When Transfer FAB is tapped:
show them again.
When screen leaves foreground:
cancel timer.
Do not create multiple unmanaged timers.
============================================================
45. SELECTION MODE
============================================================
Selection mode overrides normal browsing controls.
When one or more items are selected:
HIDE:
normal bottom navigation
normal floating SEND
normal floating RECEIVE
SHOW:
selection toolbar.
============================================================
46. SELECTION TOOLBAR
============================================================
Selection toolbar:
X
SEND(N)
TRASH
Example:
┌──────────────────────────────────────┐
│ X       SEND(6)                🗑   │
└──────────────────────────────────────┘
Recommended:
72–80dp height.
Use OmniDrop theme.
Dark mode:
dark elevated surface.
Light mode:
white/light elevated surface.
Primary Send button:
OmniDrop cyan.
============================================================
47. SEND COUNT
============================================================
SEND(N)
must dynamically reflect actual selected item count.
Examples:
SEND(1)
SEND(6)
SEND(15)
Update immediately whenever selection changes.
============================================================
48. CANCEL SELECTION
============================================================
X:
clear selection.
It must NOT delete anything.
After clearing:
selection toolbar disappears.
Normal bottom navigation returns.
Normal Send/Receive behavior returns.
============================================================
49. TRASH
============================================================
Trash is a REAL destructive action.
It must NOT simply remove selection.
Trash behavior depends on selected item type.
============================================================
50. FILE DELETE
============================================================
For files:
Trash
→ show confirmation dialog.
Never delete immediately.
Example:
Delete permanently?
6 selected files will be permanently removed from this device.
This action cannot be undone.
[CANCEL]        [DELETE]
============================================================
51. ACTUAL PERMANENT FILE DELETION
============================================================
After user confirms:
perform real deletion using the correct Android APIs.
Then:
remove successfully deleted items from the data source
clear their selection
refresh current category
update counts
update storage statistics.
If deletion fails:
keep the file in the UI
show a clear error.
============================================================
52. APP UNINSTALL
============================================================
For installed apps:
Trash means UNINSTALL.
Show confirmation.
Example:
Uninstall selected applications?
The selected applications will be removed from this device.
[CANCEL]        [UNINSTALL]
Use Android-supported package uninstall/system flows.
Do NOT use unsupported/private APIs.
Do NOT attempt silent uninstall.
After successful uninstall:
refresh Apps category
update count
clear selection.
============================================================
53. DESTRUCTIVE DIALOG THEMING
============================================================
Dark mode:
dark panel
light text
cyan secondary action
clear destructive action.
Light mode:
white panel
dark text
soft shadow
clear destructive action.
Do not make destructive actions ambiguous.
============================================================
54. STORAGE PANEL — SPECIAL RULE
============================================================
IMPORTANT:
The Storage panel appears ONLY on the:
FILES
category page.
It must NOT appear on:
Downloads
Apps
Images
Videos
Audio
Documents
Text
When the user is inside FILES:
the Storage panel is permanently part of the Files page.
It remains available as part of the Files screen architecture.
============================================================
55. STORAGE PANEL POSITION
============================================================
On FILES category:
show the generic file list plus the Storage panel according to the
Files page layout.
The Storage panel must not randomly appear/disappear based on
temporary scrolling.
It belongs specifically to the FILES category.
When the user leaves FILES:
hide the Storage panel.
============================================================
56. STORAGE INFORMATION
============================================================
Display REAL storage values.
Example:
Storage: 51.47 GB
Available: 634.15 MB
Do not hard-code example numbers.
============================================================
57. STORAGE BAR
============================================================
Use a segmented horizontal storage bar.
Segments:
Photos
Videos
Music
Documents
Other
Segment widths must be proportional to real usage.
Use OmniDrop theme-aware colors.
Dark mode:
brighter, glowing segments.
Light mode:
cleaner, softer segments.
============================================================
58. STORAGE LEGEND
============================================================
Display:
Photos
Videos
Music
Documents
Other
with:
color marker
storage value
Use clean two-column layout where appropriate.
============================================================
59. STORAGE UPDATE
============================================================
After deleting files:
storage statistics must update.
After receiving/transferring files when local storage changes:
storage statistics should update appropriately.
The UI should not display stale storage information.
============================================================
60. BOTTOM NAVIGATION
============================================================
Preserve the OmniDrop signature bottom navigation.
Conceptually:
WebDrop
OS Pairs
Transfer
Me
The central Transfer item should remain visually dominant.
Use the same OmniDrop signature treatment in:
dark mode
light mode.
============================================================
61. SELECTION OVERRIDES BOTTOM NAVIGATION
============================================================
NORMAL MODE:
bottom navigation visible.
SELECTION MODE:
bottom navigation hidden.
Selection toolbar shown instead.
When selection is cleared:
restore bottom navigation.
============================================================
62. SCROLLING ARCHITECTURE
============================================================
The browser must support BOTH:
VERTICAL SCROLLING
and
HORIZONTAL CATEGORY SWIPING.
Vertical:
browse files/items.
Horizontal swipe:
change categories.
Use a unified gesture architecture.
Do not create nested-scroll conflicts.
============================================================
63. SCROLL POSITION
============================================================
Where practical preserve the scroll position for each category.
Example:
User scrolls far down in Apps.
Switches to Images.
Returns to Apps.
Apps should return approximately where the user left it.
Do not unnecessarily reset every category to top.
============================================================
64. HEADER REAPPEARANCE + CATEGORY SWIPE
============================================================
Horizontal category swiping must NOT accidentally cause the header
to reappear.
Only a downward vertical gesture or returning to the top should
restore the header.
============================================================
65. PERFORMANCE
============================================================
The browser may contain:
thousands of photos
hundreds of apps
hundreds of videos
thousands of documents/files.
Use:
lazy loading
RecyclerView/Lazy grids
thumbnail caching
background scanning/indexing
efficient URI handling
paging where appropriate.
Never load all full-resolution files/images into memory.
Prevent:
OutOfMemoryError
ANR
UI freezes
major frame drops.
============================================================
66. FILE DATA MODEL
============================================================
Use one unified file-item abstraction where practical.
Possible properties:
id
uri
name
mimeType
extension
size
modifiedDate
category
thumbnail
duration
isSelected
isDirectory
isInstalledApp
packageName
albumId
Avoid creating separate unrelated models for every category unless
there is a strong architectural reason.
============================================================
67. CATEGORY MAPPING
============================================================
DOWNLOAD:
downloaded files.
APPS:
installed applications.
IMAGES:
image media.
VIDEOS:
video media.
AUDIO:
audio media.
DOCUMENTS:
document MIME types.
TEXT:
text/code/configuration files.
FILES:
generic/other accessible files.
============================================================
68. SEARCH DATA SOURCE
============================================================
Search should use the same unified data source as the browser.
Do not create an independent duplicate filesystem scan for search.
Search should filter the already indexed/available dataset where
possible.
============================================================
69. SEARCH PERFORMANCE
============================================================
Search must be responsive.
For large datasets:
use debouncing or equivalent.
Do not trigger a full expensive filesystem scan on every keystroke.
============================================================
70. PERMISSIONS
============================================================
Maintain Android 8+ compatibility where practical.
Use version-specific Android storage/media APIs.
Request only permissions actually needed by the browser.
If access is missing:
show a useful permission state.
Do not silently show zero files when the real problem is permission.
============================================================
71. CATEGORY EMPTY STATES
============================================================
Each category requires an empty state.
Examples:
No downloads yet.
No videos found.
No documents found.
No received files.
No applications found.
For permission issues:
show a different permission-specific state.
============================================================
72. LOADING STATES
============================================================
Show lightweight loading/skeleton state while scanning.
Do not freeze the entire screen during file discovery.
============================================================
73. THEME CONSISTENCY
============================================================
Every component must work correctly in:
DARK MODE
LIGHT MODE.
This includes:
header
category tabs
search
grid
lists
selection state
floating buttons
dialogs
storage panel
bottom navigation
empty states
loading states.
Do not create components that only look correct in one theme.
============================================================
74. DARK MODE COMPONENT BEHAVIOR
============================================================
Dark mode:
background = dark navy
surface = dark translucent navy
border = subtle cyan
active = cyan
primary text = white
secondary text = light gray
selection = cyan-tinted
destructive = clearly distinguishable
============================================================
75. LIGHT MODE COMPONENT BEHAVIOR
============================================================
Light mode:
background = very light cool gray
surface = white
border = light cyan-gray
active = cyan
primary text = dark navy
secondary text = gray
selection = pale cyan
destructive = clearly distinguishable
Maintain the same geometry and hierarchy.
============================================================
76. SEARCH + COLLAPSING HEADER
============================================================
Search MUST remain accessible after the large header collapses.
The search control may become:
compact search icon/button
in the collapsed state.
If tapped:
open the search field.
Do NOT make search unavailable simply because the user has scrolled.
============================================================
77. FILES PAGE SPECIAL LAYOUT
============================================================
The FILES category is the special storage-management browser.
It contains:
generic file list
+
permanent Storage panel
Example:
FILES
Search
[File]
[File]
[File]
[File]
[File]
...
Storage panel
────────────────────────
Storage: XX GB
Available: XX GB
[ segmented storage bar ]
Photos ...
Videos ...
Music ...
Documents ...
Other ...
The Storage panel belongs to FILES only.
============================================================
78. GENERAL CONTENT LAYOUT
============================================================
APPS:
4-column grid.
IMAGES:
Photos / Albums
Photos = 3-column image grid.
Albums = album-oriented layout.
EVERYTHING ELSE:
vertical list.
Do not violate this rule.
============================================================
79. VISUAL ALIGNMENT
============================================================
All list rows:
same thumbnail X position
same text X position
same secondary text X position
same action X position
same row height.
All app grid cells:
same width
same height
same icon position
same name baseline
same size baseline.
All image cells:
same width
same height
same spacing.
============================================================
80. CONTENT-SAFE LAYOUT
============================================================
Long file names, long app names, unusual MIME types, huge file sizes
and missing thumbnails must never break the layout.
Use:
ellipsis
fixed regions
reserved space
controlled wrapping
placeholder icons.
============================================================
81. SELECTION CONSISTENCY
============================================================
Selection behavior must look and work the same across:
Apps
Photos
Videos
Audio
Documents
Text
Files
Downloads.
Do not create different selection logic for every screen.
============================================================
82. TRANSFER CONSISTENCY
============================================================
The Send action from:
floating Send button
selection SEND(N)
must connect to the SAME existing OmniDrop transfer pipeline.
Do not create two transfer implementations.
============================================================
83. RECEIVE CONSISTENCY
============================================================
The Receive button must connect to the existing OmniDrop receiving
flow.
Do not duplicate QR/Wi-Fi connection logic.
============================================================
84. PRESERVE EXISTING FEATURES
============================================================
Do not break:
WebDrop
OS Pairs
QR scanner
Wi-Fi transfer
device pairing
send flow
receive flow
transfer progress
encryption
cloud sync
existing network communication.
The redesign must be integrated with existing functionality.
============================================================
85. FINAL INTERACTION MODEL
============================================================
NORMAL STATE:
Open OmniDrop
↓
Large OmniDrop header visible
↓
Category navigation visible
↓
Browse current category
↓
SEND/RECEIVE visible temporarily
↓
after ~3 seconds
↓
SEND/RECEIVE hide
↓
Transfer FAB remains
============================================================
86. HEADER INTERACTION
============================================================
User scrolls upward:
large header disappears.
User stops:
header stays hidden.
User waits:
header stays hidden.
User manually drags downward:
header reappears.
OR
user returns to the first items/top:
header reappears.
No automatic timer should restore the header.
============================================================
87. CATEGORY INTERACTION
============================================================
User taps Images:
Images opens.
User swipes left:
Videos opens.
User swipes right:
Apps opens.
Category navigation scrolls automatically to keep active category
visible.
============================================================
88. SEARCH INTERACTION
============================================================
Tap search:
search field opens.
Type:
"report"
Results filter.
Tap X:
search clears.
Current category remains active.
============================================================
89. SELECTION INTERACTION
============================================================
User selects files:
normal bottom navigation disappears.
normal SEND/RECEIVE buttons disappear.
Selection toolbar appears.
Example:
X   SEND(6)   TRASH
============================================================
90. DELETE INTERACTION
============================================================
User taps Trash:
confirmation dialog.
User cancels:
nothing happens.
User confirms:
perform actual deletion/uninstallation.
Then:
refresh data
refresh screen
update counts
update storage
clear selection.
============================================================
91. APP UNINSTALL
============================================================
Selected installed app:
Trash
↓
Uninstall warning
↓
Android supported uninstall flow
↓
refresh Apps.
Never attempt unsupported silent uninstall.
============================================================
92. LIGHT/DARK MODE TEST
============================================================
Test the entire interface in:
Dark mode
Light mode
No text should disappear.
No borders should become invisible.
No active state should become unclear.
No button should lose contrast.
No dialog should become unreadable.
============================================================
93. FINAL ACCEPTANCE TEST
============================================================
Test every item below.
HEADER:
[ ] large header visible initially
[ ] header disappears when scrolling UP
[ ] header stays hidden when scrolling stops
[ ] header does NOT reappear automatically
[ ] header returns when user manually drags DOWN
[ ] header returns when reaching top
CATEGORY NAVIGATION:
[ ] all 8 categories present
[ ] horizontal scrolling works
[ ] tapping category works
[ ] left/right swipe changes category
[ ] active category stays synchronized with content
[ ] vertical scrolling does not accidentally change category
SEARCH:
[ ] search icon exists
[ ] search field opens
[ ] filename search works
[ ] app-name search works
[ ] clear search works
[ ] empty state works
[ ] search remains accessible after header collapse
APPS:
[ ] 4-column grid
[ ] fixed cell geometry
[ ] aligned icons
[ ] one-line names
[ ] file/app size
[ ] selection works
IMAGES:
[ ] Photos/Albums selector
[ ] dynamic counts
[ ] Photos = 3-column grid
[ ] Albums = album view
[ ] date grouping
[ ] selection works
VIDEOS:
[ ] vertical list
[ ] thumbnails
[ ] play indicator
[ ] duration
[ ] size
AUDIO:
[ ] vertical list
[ ] artwork/icon
[ ] duration
[ ] size
DOCUMENTS:
[ ] vertical list
[ ] MIME icons
[ ] file metadata
TEXT:
[ ] vertical list
[ ] text/code icons
[ ] file metadata
FILES:
[ ] tapping Files actually opens generic browser
[ ] vertical file list
[ ] thumbnails/icons
[ ] filename
[ ] size
[ ] modified date
[ ] Storage panel exists
STORAGE:
[ ] only appears on Files page
[ ] permanently belongs to Files page
[ ] disappears when leaving Files
[ ] real values
[ ] segmented bar
[ ] legend
[ ] updates after deletion
TRANSFER:
[ ] Send works
[ ] Receive works
[ ] Send/Receive auto-hide after ~3 seconds
[ ] Transfer FAB remains
[ ] tapping Transfer FAB restores Send/Receive
[ ] works in every category
SELECTION:
[ ] bottom navigation hides
[ ] selection toolbar appears
[ ] SEND(N) updates
[ ] X clears selection
[ ] Trash opens warning
DELETION:
[ ] files really delete
[ ] warning shown first
[ ] failed deletion handled
[ ] app uninstall uses supported Android flow
[ ] counts update
[ ] storage updates
THEMES:
[ ] Dark mode works
[ ] Light mode works
[ ] same architecture in both
[ ] no broken contrast
[ ] no broken icons
[ ] no unreadable dialogs
PERFORMANCE:
[ ] large photo collections remain smooth
[ ] large file collections remain smooth
[ ] thumbnails are cached/lazy-loaded
[ ] no OOM
[ ] no ANR
[ ] no major UI jank
============================================================
FINAL IMPLEMENTATION PRINCIPLE
============================================================
Do not build this as a collection of unrelated screens.
Build ONE COHERENT OMNIDROP FILE BROWSER SYSTEM.
Shared:
category state
search state
selection state
theme
gesture navigation
transfer controls
header behavior
data source
file model
Category-specific presentation:
Apps → 4-column grid
Images → Photos/Albums + photo grid
Everything else → vertical file list
Files → vertical file list + permanent Storage panel
The finished result should feel like ONE unified OmniDrop application,
not several different interfaces stitched together.
The final product should preserve OmniDrop's signature visual
identity while delivering a fast, professional, scalable file browser
with light/dark themes, search, swipe navigation, collapsing header,
persistent Files storage panel, intelligent file thumbnails, proper
selection behavior and safe real deletion/uninstallation.
**Since you make an alarming observation about conflict in color and design, use this document for the batch 4 instead and ignore the privious one. **
**Note: when writing the prompt make sure to use these words exactly to achieve the maximum desired result possible. You can even include diagrams where necessary. **
