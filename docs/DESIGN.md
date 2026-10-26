# Keystrand design contract (macOS 26, Liquid Glass)

This contract defines Keystrand's windows, navigation, controls, colors, fonts,
menus, and UI text. It takes precedence over `docs/ARCHITECTURE.md` for visual
and structural decisions. The code and tests define feature behavior, including
the Redis commands that each feature sends.

The app implements this contract with the following exceptions:

- Table column widths do not persist. The Browser opens with an even split.
- Pub/Sub has no jump-to-latest button.
- `TableColumn` descriptions appear as cell tooltips rather than header tooltips.
- Save Query failures appear in an alert instead of inline.
- The bottom panel uses a SwiftUI stack with a `DragGesture` divider. An AppKit
  `VSplitView` extends under the floating sidebar.
- Live Cluster, Sentinel, SSH, and Redis Software screenshots are unavailable.
  Redis cluster, SSH, and Redis Software also have no live tests. Read
  `ARCHITECTURE.md` section 10 for the recorded limits.

Check each rule through a screenshot or source search. Requirements use **must**
and **must not**. Source checks use `grep -rn '<pattern>' <path>` with an
expected result.

Section headings identify each screen's area. The following table maps areas to targets:

| Area | Targets |
| --- | --- |
| AppShell | `Sources/AppShell`, `Keystrand/` (app bundle, icon) |
| RedisUI | `Sources/RedisUI` |
| Connections | `Sources/Features/ConnectionsFeature` |
| Browser | `Sources/Features/BrowserFeature`, `Sources/Features/KeyTypesBasicFeature` |
| Advanced key types | `Sources/Features/KeyTypesAdvancedFeature` |
| Workbench | `Sources/Features/WorkbenchFeature`, `Sources/Features/CLIFeature` |
| Analytics | `Sources/Features/AnalyticsFeature`, `Sources/Features/MonitoringFeature` |
| Vector Search and Settings | `Sources/Features/VectorSearchFeature`, `Sources/Features/SettingsFeature` |

Navigation, status and confirmation state come from RedisCore (`DatabaseNavigator`, `ToastCenter`,
`ConfirmationCenter`, `DatabaseSection`, `AnalyticsTab`, `BottomPanelTool`, `InsightsTab`). State that only one screen
needs lives in that screen's target.

---

## 1. Principles and non-goals

Apply these principles in priority order:

1. Use system containers before you build custom containers. Choose
   `NavigationSplitView`, window toolbars, `.inspector`, `HSplitView`,
   `VSplitView`, `Table`, `List`, grouped `Form`, sheets, alerts, menus,
   popovers, or `ContentUnavailableView` as appropriate.
2. Use semantic system colors, the user's accent color, and system materials.
   Feature code must not define hex colors.
3. Keep content areas plain. Do not add cards, borders, custom backgrounds,
   or custom hover effects. Use the system's Liquid Glass for sidebars,
   toolbars, sheets, popovers, menus, and controls.
4. Where applicable, expose each action through a visible control, a menu bar
   item, and a context menu or keyboard shortcut.
5. Display data in monospaced text styles. Display window controls in the system
   font. Use text styles rather than fixed point sizes.
6. Use macOS status and error controls. If a successful action has a visible
   result, show no message. Otherwise, show its result inline where the action
   started. Show failures from user actions as alerts. Use inline
   `ContentUnavailableView` for empty or failed content. Do not show transient
   status messages.
7. Use the component kit consistently. The same interaction must use the same
   control throughout the app.

This contract excludes the following work:

- Web app layouts, brand colors, illustrated icons, and onboarding flows.
- Custom themes. Use system appearance with the Settings choices System,
  Light, and Dark.
- iPad or iOS layouts, App Store distribution work such as sandboxing and
  notarization, and localization beyond English.
- User toolbar customization. Do not use `.toolbar(id:)`. Use the fixed toolbar
  defined in this contract.
- Feature behavior. This contract covers presentation and interaction.

---

## 2. Windows and navigation

### 2.1 Scenes

`RootScene` (AppShell) declares exactly these scenes:

| Scene | Declaration | Size | Restoration |
| --- | --- | --- | --- |
| Home library | `Window("Redis Databases", id: AppWindowID.home)` (single instance) | default 1000×640, min 760×460 | restored |
| Database window | `WindowGroup("Database", for: DatabaseID.self)` | default 1320×860, min 900×600 | restored with its `DatabaseID`; reconnects on restore |
| Settings | `Settings { SettingsView() }` | fixed width 520, height fits the page | system |
| Keyboard Shortcuts | `Window("Keyboard Shortcuts", id: AppWindowID.shortcuts)` | fixed 640×600, `.windowResizability(.contentSize)` | `.restorationBehavior(.disabled)` |
| Acknowledgements | `Window("Acknowledgements", id: AppWindowID.acknowledgements)` | default 640×640, min 520×400, resizable | `.restorationBehavior(.disabled)` |

Apply these rules:

- All windows use the default `.windowToolbarStyle(.unified)` (do not set `.unifiedCompact`, do not hide the title).
- Home uses `.defaultLaunchBehavior(.suppressed)` when the process was launched with `--open`, `--open-id` or any
  `--section`/`--tool`/`--inspector`/`--key` flag, and `.presented` otherwise.
- Opening a database that already has a window focuses that window (current `WindowGroup(for:)` behavior). A database
  never has two windows.
- Database windows may be merged into tabs by the user (system Window menu). Nothing in the app depends on a window
  being untabbed.
- Use `@SceneStorage` to keep per-window state across relaunch. Store sidebar
  selection under `"sidebar"`, inspector visibility under `"inspector"`, the
  inspector pane under `"inspectorPane"`, and bottom panel visibility under
  `"bottomPanel"`. Keep Browser list or tree mode globally in `settings.browser`.
- When any QA flag from section 9 is present, AppShell sets `UserDefaults.standard` `ApplePersistenceIgnoreState = true`
  in `applicationWillFinishLaunching` so screenshot runs never restore old windows.

### 2.2 Home library window

Use the patterns from **Finder** (sidebar of filters, list table, status in toolbar) and **Mail** (library sidebar with counts).

```text
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│ ◧  Redis Databases          [ Database added ✓ ]        [＋▾] │ [⇪] [🗑] │ [🔍 Search      ] │
│    12 databases                                                                            │
├────────────────────┬──────────────────────────────────────────────────────────────────────┤
│ Library            │ Name ▲            Host:Port        Type        Environment  Modules … │
│  ▣ All Databases 12│ ◉ cache-prod  ⛨   10.0.0.4:6379    Standalone  Production   Search, J…│
│  🕘 Recents       5 │   local         127.0.0.1:6390   Standalone  —            Search, J…│
│ Environments       │   sessions      redis.lan:6379   OSS Cluster Development  —         │
│  ⛨ Production    2 │                                                                       │
│  🔨 Development   3 │                                                                       │
│ Tags               │                                                                       │
│  🏷 team: core    4 │                                                                       │
│  🏷 app: web      2 │                                                                       │
└────────────────────┴──────────────────────────────────────────────────────────────────────┘
```

- Root: `NavigationSplitView { HomeSidebar } detail: { DatabaseTable }`. Sidebar
  `.navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)`.
- Sidebar: `List(selection: $filters)` with `filters: Set<HomeFilter>`, `.listStyle(.sidebar)`.
  - Section "Library": "All Databases" (`cylinder.split.1x2`), "Recents" (`clock`, the 10 most recently connected).
  - Section "Environments" (shown only when at least one database has that environment): "Production"
    (`exclamationmark.shield`), "Development" (`hammer`).
  - Section "Tags" (shown only when tags exist): one row per distinct `key: value`, symbol `tag`, sorted by key then value.
  - Every row has `.badge(count)` with the number of databases it matches.
  - Selection semantics: a Library or Environment row is exclusive (selecting it clears other rows). Tag rows may be
    multi-selected with ⌘-click; a database matches when it has ANY selected tag. Empty selection means
    "All Databases".
- Detail: the database `Table` (section 3.1).
- Title `Redis Databases`; `.navigationSubtitle`: `"12 databases"`, `"3 of 12 databases"` when filtered or searched,
  `"2 selected"` when the selection has more than one row.
- Toolbar, left to right:
  1. `.primaryAction`: Add menu: `Menu { … } label: { Label("Add Database", systemImage: "plus") } primaryAction:
     { add database sheet }` with items "Add Database…" (⌘N), "Discover Sentinel Databases…",
     "Discover Redis Software Databases…", divider, "Import Connections…" (⇧⌘I).
  2. `ToolbarSpacer(.fixed)`.
  3. `.primaryAction` group: "Export…" (`square.and.arrow.up`, enabled with a selection), "Remove…" (`trash`,
     enabled with a selection).
  4. Search: `.searchable(text:placement: .toolbar, prompt: "Search")` on the `NavigationSplitView` (trailing end).
- Use native `Table` column customization. Filter tags through the sidebar.
  Do not add a header button, floating bulk-action bar, Columns popover, tag
  filter popover, or pagination controls.

### 2.3 Database window

Use the patterns from **Xcode** (navigator sidebar, activity view in the toolbar center, debug area at the bottom, inspector on
the right) and **Mail** (list and content side by side under one toolbar).

```text
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ◧ [⛁]  local [db2]           ⛨ Production · Redis 8.10.2 · CPU 0.4% · 132 ops/s · 5 MB · 73 keys · 1 client │
│        Browser · 127.0.0.1:6390        [≡|⌸] [⏷] [＋] [🗑] [⟳▾] │ [db2 ▾] │ [▭] [◨] │ [🔍 Key name or pattern] │
├───────────────────┬──────────────────────────────────────────────────────────────┬───────────────────────┤
│ Data              │  section content (detail column)                              │ Inspector (optional)  │
│  🔑 Browser        │                                                              │ [Commands|Tips|Tutor.] │
│  </> Workbench     │                                                              │                       │
│  ✨ Vector Search  │                                                              │                       │
│ Analytics         │                                                              │                       │
│  ◔ Database Analysis                                                             │                       │
│  🐢 Slow Log       │══════════════════════════════════════════════════════════════│                       │
│  ▤ Cluster Details│ [CLI] [Profiler]                                         [×] │                       │
│ Messaging         │ CLI pane                         │ Profiler pane             │                       │
│  ((•)) Pub/Sub    │                                  │                           │                       │
└───────────────────┴──────────────────────────────────────────────────────────────┴───────────────────────┘
```

Build AppShell's `DatabaseWindowView` with this structure:

```swift
NavigationSplitView(columnVisibility: $columns) {
    DatabaseSidebar(selection: $sidebarItem, session: session)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
} detail: {
    VSplitView {
        SectionContent(...)               // minHeight 240
        if isBottomPanelShown { BottomPanelView(session:) }  // minHeight 140, idealHeight persisted
    }
    .inspector(isPresented: $isInspectorShown) {
        InspectorView(session:)
            .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
    }
}
.navigationTitle(windowTitle)
.navigationSubtitle(windowSubtitle)
```

- Switch sections through the sidebar. Give each analytics page its own row.

#### 2.3.1 Sidebar

`List(selection: $sidebarItem) { … }.listStyle(.sidebar)`. `sidebarItem` is an AppShell enum
`DatabaseSidebarItem` mapped onto RedisCore navigation:

| Section header | Row title | SF Symbol | Maps to | Shortcut | Visible when |
| --- | --- | --- | --- | --- | --- |
| Data | Browser | `key` | `.browser` | ⌘1 | always |
| Data | Workbench | `chevron.left.forwardslash.chevron.right` | `.workbench` | ⌘2 | always |
| Data | Vector Search | `sparkle.magnifyingglass` | `.vectorSearch` | ⌘3 | always |
| Analytics | Database Analysis | `chart.pie` | `.analytics` + `.databaseAnalysis` | ⌘4 | always |
| Analytics | Slow Log | `tortoise` | `.analytics` + `.slowLog` | ⌘5 | always |
| Analytics | Cluster Details | `server.rack` | `.analytics` + `.clusterDetails` | ⌘6 | `session.isCluster` |
| Messaging | Pub/Sub | `dot.radiowaves.left.and.right` | `.pubSub` | ⌘7 | always |

- Rows are `Label(title, systemImage:)`; no custom row backgrounds, no custom selection color, no hover effects.
- Pub/Sub row: while subscribed, its symbol uses `.symbolEffect(.variableColor.iterative, isActive: isSubscribed)`
  (disabled when Reduce Motion is on).
- Database Analysis row: `.badge(n)` where `n` is the unread live tips count (`LiveTipsModel`), hidden when 0.
- Selecting a row sets `session.navigator.section` (and `analyticsTab`); navigator changes from features update the
  selection. Cluster Details on a non-cluster database redirects to Database Analysis.
- The sidebar has no footer, no Settings button (Settings is ⌘, in the app menu) and no "Databases" link (⌘0).

#### 2.3.2 Title, subtitle and toolbar

- `navigationTitle`: the database name truncated to 33 characters plus `[db<N>]` when the logical database N > 0.
  Example: `local [db2]`. This is also the window's title in the Window menu.
- `navigationSubtitle`: `"<Section title> · <host>:<port>"`, for example `Browser · 127.0.0.1:6390`. Section titles:
  Browser, Workbench, Vector Search, Database Analysis, Slow Log, Cluster Details, Pub/Sub.
- Window toolbar style: default unified. The toolbar is not customizable.

Place toolbar items in this exact order from left to right:

| # | Placement | Item | Owner | Notes |
| --- | --- | --- | --- | --- |
| 1 | system | Sidebar toggle | system | Provided by `NavigationSplitView`; do not add another. |
| 2 | `.navigation` | Database switcher: `Button { showPicker } label: { Label("Switch Database", systemImage: "cylinder.split.1x2") }` with `.popover { DatabasePickerPopover(...) }` | AppShell | Icon only in the toolbar; `.help("Switch Database (⌘O)")`. |
| 3 | system | Title and subtitle | system | From `navigationTitle` / `navigationSubtitle`. |
| 4 | `.principal` | `DatabaseActivityView` (section 2.3.3) | AppShell (+ SettingsFeature `OverviewBarView`) | Center of the toolbar. |
| 5 | `.primaryAction` | Section items (section 3, per screen), at most 6 controls, with the section's refresh control last | section view | Declared by the section view with `.toolbar { }`. |
| 6 | `.primaryAction` | `ToolbarSpacer(.fixed)` | AppShell | |
| 7 | `.primaryAction` | Logical database picker (only when `session.databaseCount > 1`) | AppShell | `Picker("Logical Database", selection:) { ForEach(0..<min(count, 64)) { Text("db\($0)").tag($0) } }.pickerStyle(.menu)`; disabled while a Workbench run is in progress; `.help("Logical database")`. When `databaseCount > 64` the menu shows db0…db63 and "Other…" which opens an alert with a numeric `TextField`. |
| 8 | `.primaryAction` | `ToolbarSpacer(.fixed)` | AppShell | |
| 9 | `.primaryAction` | `ToolbarItemGroup`: Bottom panel toggle `Label("Bottom Panel", systemImage: "rectangle.bottomthird.inset.filled")`, inspector toggle `Label("Inspector", systemImage: "sidebar.trailing")` | AppShell | Both are `Toggle`s with `.toggleStyle(.button)`; help "Show Bottom Panel (⇧⌘Y)" / "Show Inspector (⌥⌘I)". |
| 10 | system | Search field | section view | Only sections that call `.searchable` (Browser, Vector Search index list). |

Apply these rules:

- Sections never add `.navigation` or `.principal` items. Sections add only `.primaryAction` (or `.automatic`) items.
- Use `.buttonStyle(.glassProminent)` for at most one toolbar button per window.
  Eligible actions are Workbench "Run", Vector Search query "Run", and Vector
  Search "Create Index". Use the default style for other toolbar items.
- Every toolbar item has a `Label` with a title (shown in the overflow menu and to VoiceOver) and a `.help` tooltip.
- Check the toolbar order in a screenshot, as described in section 9.
- AppShell declares items 6 to 9 on the detail column's outermost view, after
  the section content, which keeps the required order. While the inspector is
  shown, the inspector toggle moves out of group 9 and is declared on the
  inspector content after a flexible `ToolbarSpacer`, so it sits at the
  trailing edge over the inspector column, and the detail items end at the
  column divider instead of straddling it.

#### 2.3.3 Activity view (toolbar center)

Use the patterns from **Xcode** activity viewer. The capsule in the toolbar center shows content in this priority order:

1. Connection state when not connected: `ProgressView().controlSize(.small)` + "Connecting…"; `bolt.horizontal.circle`
   - "Disconnected"; `exclamationmark.triangle.fill` (`.orange`) + "Connection Failed"; `exclamationmark.triangle.fill`
   - "Connection Lost" + borderless button "Reconnect".
2. Otherwise the overview metrics rendered by SettingsFeature's `OverviewBarView(session:)`:
   `Redis 8.10.2 · CPU 0.4% · 132 ops/s · 5.1 MB · 73 keys · 1 client` in `.callout` with `.monospacedDigit()`,
   `.foregroundStyle(.secondary)`, separators " · ". Missing metrics are omitted. `ViewThatFits` drops, in this order,
   clients, keys, ops/s, CPU when space is short. When the last overview refresh failed, a trailing
   `exclamationmark.circle.fill` (`.orange`) with the error as `.help` is added.

- When the database environment is production, the capsule always starts with
  `Label("Production", systemImage: "exclamationmark.shield.fill")` tinted `.red` (title visible), followed by " · ".
  Development shows nothing. No other part of the window is tinted for production.
- Clicking the capsule (it is a `Button` with `.buttonStyle(.plain)` inside the toolbar item) opens
  `DatabaseInfoPopover(session:)` (section 3.30).
- Width: `.frame(minWidth: 200, idealWidth: 420, maxWidth: 560)`.
- Metric value changes animate with `.contentTransition(.numericText())` unless Reduce Motion is on.

#### 2.3.4 Inspector

Use the patterns from **Xcode** inspectors and **Pages** inspector (segmented pane switcher at the top).

- `.inspector(isPresented:)` on the `NavigationSplitView`, not on the detail column. Only that placement gives the
  inspector its own toolbar section on macOS. Toggle: toolbar item 9, View > Show Inspector (⌥⌘I).
- Content: `InspectorView` (AppShell) = `Picker` with `.pickerStyle(.segmented)`, `.labelsHidden()`, full width, padded
  12 pt, then the pane:

| Pane | Picker label | Symbol | View | Owner |
| --- | --- | --- | --- | --- |
| Command Helper | "Commands" | `book` | `CommandHelperView(session:)` | Workbench (CLIFeature) |
| Tips | "Tips" (or "Tips (3)" with unread count) | `lightbulb` | `TipsPanelView(session:)` | Analytics |
| Tutorials | "Tutorials" | `graduationcap` | `TutorialsPanelView(session:)` | Workbench |

- The selected pane lives in AppShell (`InspectorPane` enum in a `session.scopedObject`) and is kept in sync with
  RedisCore: `navigator.isInsightsOpen`/`insightsTab` map to Tips and Tutorials; a navigation request
  `.bottomPanel(.commandHelper)` or `navigator.openBottomTools` containing `.commandHelper` opens the inspector on
  Command Helper and removes `.commandHelper` from `openBottomTools`.
- The inspector has no header, full-screen mode or close button of its own. Esc does nothing special.
- Unread tips are marked read when the Tips pane is hidden.

#### 2.3.5 Bottom panel (CLI and Profiler)

Use the patterns from **Xcode** debug area (`VSplitView`, toggled with ⇧⌘Y, side-by-side consoles).

- A `VStack` inside the detail column: section content (min height 240), a hairline `DrawerDivider` with a 9 pt
  `DragGesture` target, then `BottomPanelView` (min height 140, height from `settings.ui.bottomPanelSizes`, written back
  when the drag ends). A `VSplitView` is not used because an AppKit split view lays out under the floating sidebar.
- `BottomPanelView` = a 28 pt header row, `Divider()`, then the open tools. Header row, `.controlSize(.small)`:
  - Leading: `Toggle(isOn:) { Label("CLI", systemImage: "terminal") }` and
    `Toggle(isOn:) { Label("Profiler", systemImage: "waveform.path.ecg") }`, both `.toggleStyle(.button)`.
  - Trailing: `Button { hide } label: { Label("Hide Bottom Panel", systemImage: "xmark") }.labelStyle(.iconOnly)`.
- Tools: CLI alone, Profiler alone, or both side by side in an `HSplitView` (each min width 230). The Command Helper is
  not in the bottom panel (it is in the inspector).
- Showing the bottom panel with no tool open opens the CLI. Hiding the last tool hides the panel. Hiding the panel does
  not stop the CLI client or the Profiler; closing a tool with its toggle does.
- Keep the header row as the panel's only control area. Do not add a tab bar or a minimize button for each tool.

#### 2.3.6 Connection states in the detail column

| State | Detail column content |
| --- | --- |
| Session loading | `ProgressView()` centered |
| Connecting (first connect) | `ProgressView("Connecting to <name>…")` centered |
| Failed | `ContentUnavailableView { Label(error.title, systemImage: "bolt.horizontal.circle") } description: { Text(error.message) } actions: { Button("Try Again") { reconnect } ; Button("Edit Database…") { edit } }` |
| Disconnected (user chose Disconnect) | `ContentUnavailableView("Disconnected", systemImage: "bolt.horizontal.circle", description: Text("<name> is disconnected."))` with action `Button("Connect")` |
| Connected | the section view |
| Connection lost while connected | section view stays; activity view shows "Connection Lost" + "Reconnect" (2.3.3) |

The bottom panel and section toolbar items are disabled in every state except Connected.

#### 2.3.7 Production prompt

AppShell shows the production prompt in the database window. SettingsFeature
requests the prompt for a database with many keys that uses a remote endpoint,
TLS, a cluster, Sentinel, or authentication.

The alert uses these controls:

- The title is "Treat This Database as Production?".
- The message explains that production status adds confirmations only within Keystrand.
- The default button, "Mark as Production…", opens Edit Database at Environment.
- The cancel button is "Not Now".

Either button sets the app-wide "prompt actioned" flag. The prompt then stays
hidden for every database. Dismissing the alert without a button hides it only
for that window.

### 2.4 Browser (three-column layout)

Use the patterns from **Mail** (sidebar, message list, message view under one toolbar) and **Finder** (list/outline view switch,
View Options ⌘J, status bar).

The Browser uses an `HSplitView` in the database window's detail column.
The complete window contains the database sidebar, key list, and key details.
Do not use a three-column `NavigationSplitView`. Changing its column count
between sections rebuilds the window and loses toolbar and sidebar state.

```text
 sidebar │ key list (min 300, ideal 420)          │ key details (min 380)
         │ ▾ 📁 rgtest                      4    │ [H] user:1001                          (⋯)
         │   ▾ 📁 wbsearch                  4    │     Size 1.2 KB  Length 42  TTL No limit
         │     ▸ 📁 54e35fb9                2    │ Format [Unicode ▾]            [＋ Add Fields…]
         │     ▸ 📁 98b899e6                2    │ ──────────────────────────────────────────
         │                                      │ Field        │ Value
         │ ─────────────────────────────────── │ name         │ Ada
         │ 4 keys · scanned 4 of 4   Scan More  │ …
```

Rules are in sections 3.8 to 3.15.

### 2.5 Settings scene

Use the patterns from **System Settings** grouped forms, in a classic tabbed Settings window like **Safari** / **Mail**.

Use `Settings { SettingsView() }` with a `TabView` containing these tabs:

- General uses `gearshape`.
- Workbench uses `terminal`.
- Advanced uses `gearshape.2`.

Each tab uses `Form { … }.formStyle(.grouped)`, `.frame(width: 520)`, and
`.fixedSize(horizontal: false, vertical: true)`. Do not add a `ScrollView`,
custom header, or `.redisTheme`. Section 3.29 defines the pages.

Open About through **Keystrand > About Keystrand**. Keep **Copy System Info**
in the **Help** menu. Do not add Privacy or About tabs.

### 2.6 Keyboard Shortcuts window

Use the patterns from **Xcode** Settings > Key Bindings (read-only table). Specified in section 3.37.

#### 2.6.1 Acknowledgements window

Use the patterns from the standard macOS acknowledgements and credits window (plain scrolling text, one disclosure per license).
Specified in section 3.38.

### 2.7 Sheets, alerts and confirmations

Use these sheet sizes for forms that collect input:

| Size class | Use | Declaration |
| --- | --- | --- |
| Small | one to four fields: Manage Tags, Save Query, Rename Key, Remove Elements, Add Entry (JSON), Edit Field (Vector Search), New Group (stream), Export Connections | `.sheetSize(.small)` = width 460, `.presentationSizing(.fitted)` |
| Form | Add/Edit/Clone Database, Import, New Key, Add Fields/Members/Elements/Entries, Edit Value | `.sheetSize(.form)` = width 580, min height 420, `.presentationSizing(.form)` |
| Large | Sentinel and Redis Software discovery, Import results, Bulk Actions, Pick Sample Data, Value Preview, Workbench result "Expand" | `.sheetSize(.large)` = `.presentationSizing(.page)`, min 820×560 |

- Every sheet is built with RedisUI `SheetForm` (section 4): title row (`.title3.weight(.semibold)`), content (usually a
  grouped `Form`), and a footer row.
- Footer button order (left to right): optional secondary actions on the leading side (for example "Test Connection",
  "Back"), flexible space, "Cancel", primary. The primary button has `.keyboardShortcut(.defaultAction)`; Cancel has
  `.keyboardShortcut(.cancelAction)`. No `.borderedProminent` in sheets (the default button is already accented).
  Destructive primary buttons use `role: .destructive` and are not the default action; then Cancel is default.
- While a sheet works (saving, testing), its primary button shows a trailing `ProgressView().controlSize(.small)` and
  its fields are disabled. Errors inside a sheet are shown as `InlineMessage(kind: .error)` above the footer, not as
  alerts behind the sheet.
- Sheets never contain a close "×" button.

Apply these rules to alerts and confirmation dialogs:

- Destructive confirmations use `.destructiveConfirmation(...)` (RedisUI, built on `.confirmationDialog` with
  `titleVisibility: .visible`). Title is a question in title case with the object in curly quotes:
  `Delete “user:1001”?`. Message is one or two sentences, sentence case. Buttons: destructive action (verb, for example
  "Delete", "Remove", "Clear") and "Cancel" (the system makes Cancel the default for destructive dialogs).
- Production write confirmations (`ConfirmationRequest.requiresTyping == false`) use `.confirmationDialog` with the
  request's title, message and button, plus `.dialogSuppressionToggle("Don't ask again this session",
  isSuppressed:)` when `actionID != nil`.
- Type-to-confirm (`requiresTyping == true`) is an `.alert` with a `TextField` (section 4.4): message, then
  "Type “\<db\>” to confirm.", then "Tip: Restrict dangerous commands per user with Redis ACLs." The destructive button
  is `.disabled(typed != expected)` and also re-checks the text when tapped (a mismatch resolves as cancel).
  `.dialogSeverity(.critical)` is set so the alert shows the caution badge.
- A window's dialogs do not show while a sheet is up, so every sheet whose content may ask for a production
  confirmation or report an error applies RedisUI `.sheetAlerts(session)` to its root view (section 4.4). The
  innermost sheet presents; the window root waits until no sheet is up.
- Error alerts come only from `ToastCenter` through AppShell's `.shellStatusAlerts(_:)` (section 4.3): title = error
  title (default "Error"), message = toast message (first 400 characters with "…"; longer messages add a
  "Save Full Log…" button that writes `error-log.txt` through `NSSavePanel`), button "OK".
- Small value editors that are not sheets: Set TTL (popover), Set Field TTL (popover), score editing (in-cell
  `TextField`).
- Popovers (`.popover`) are allowed only for: the database switcher, the database info popover, Set TTL, Set Field
  TTL, Slow Log configuration, View Options (⌘J), the stream Last Delivered ID editor, the stream Claim form, the Vector
  Set filter syntax help, and the Workbench time series Chart Options. Confirmations are never popovers.
  `grep -rn '\.popover(' Sources/Features` must only match those.

### 2.8 Window restoration and multiple database windows

- One database = at most one window. `openWindow(value: id)` focuses an existing window for that id; the database
  switcher, File > Open Recent, Home double-click and deep links all go through it.
- The session (`SessionRegistry`) lives exactly as long as its window (ARCHITECTURE decision 4); minimizing, hiding,
  tab-merging and switching Spaces never disconnect.
- On relaunch, SwiftUI restores Home (if it was open) and every database window with its `DatabaseID`; each restored
  window reconnects with the normal connect flow (2.3.6) and restores its `@SceneStorage` state (sidebar item, inspector,
  inspector pane, bottom panel). A restored window whose database was deleted shows
  `ContentUnavailableView("Database Not Found", systemImage: "cylinder.split.1x2", description: Text("This database
  was removed from Keystrand."))` with the action "Show All Databases".
- Clicking the Dock icon with no visible windows shows Home (`applicationShouldHandleReopen` → `openWindow(id: home)`).
- Quit after the last window closes (`LastWindowCloseGuard`, AppShell). When Settings > General "Quit when the last
  window closes" is on (the default), closing the last window quits the app
  (`applicationShouldTerminateAfterLastWindowClosed`). Another window keeps the app open when it can become main and
  is visible or minimized. If a database is connected, the red close button and ⌘W on that last window do not close it
  at once. They show an alert sheet on the window: "Quit Keystrand?", message "Closing the last window disconnects from
  “\<name\>” and quits Keystrand." (or "from N databases"), buttons "Quit" (default) and "Cancel". When the setting
  is off, closing the last window leaves the app running without windows.
- Quitting closes every session (`AppShellDelegate.applicationShouldTerminate`).
- Hold to quit (`QuitHoldController`, AppShell). When Settings > General "Hold ⌘Q to quit" is on (the default), a ⌘Q
  key press does not quit at once. It shows a "Hold ⌘Q to Quit" reminder centered on the active screen. Holding ⌘Q
  for 1 second quits. Releasing earlier keeps the app open, and the reminder fades 1.5 seconds later. Auto-repeat of the
  held key is swallowed. Quit from the app menu, the Dock, or an Apple Event (logout, `osascript`) quits at once.
- The Window menu lists Home as "Redis Databases" and each database window by its title (`name [dbN]`).

---

## 3. Per-screen mapping

Each screen specification defines its reference pattern, layout, containers,
toolbar, context menu, keyboard controls, selection, and states. It also lists
excluded controls. Keep the specified UI labels and technical declarations.

"Section items" refers to toolbar group 5 in section 2.3.2, ordered from left
to right. Quoted strings identify UI text. If their capitalization conflicts
with section 10, change only the capitalization.

### 3.1 Home database table (Connections)

- **Pattern.** Use Finder list view and Mail account list.
- **Layout.** Fill the Home window's detail column from edge to edge.
- **Containers and styles.** Use `Table(of: DatabaseConfig.self, selection: $selection, sortOrder: $sortOrder,
  columnCustomization: $columns)` with `.tableStyle(.inset(alternatesRowBackgrounds: true))`. Column customization is
  persisted in `settings.ui` via `TableColumnCustomization` (encode to `Data`).
  Columns (all `.customizationID` set, all hideable through the header context menu except Name):
  - Name (sortable): `HStack` = connecting `ProgressView().controlSize(.small)` or "new" dot (`Circle().fill(.blue)`
    6 pt, `.help("New")`) + name + `[dbN]` suffix in `.secondary`; production databases add
    `Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)` with `.help("Production")`.
  - Host:Port (sortable), monospaced digits.
  - Type (sortable): "Standalone", "OSS Cluster", "Sentinel", "Not Connected".
  - Environment (sortable): "Production", "Development", or "—" in `.tertiary`.
  - Modules: plain text via `ModuleSummaryText` ("Search, JSON, Time Series +2"), `.help` lists
    "\<Name\> v. \<version\>".
  - Last Connection (sortable): relative text, "Never".
  - Tags (sortable): plain text "team: core, app: web" truncated; `.help` lists all.
  - Put row actions in the context menu. Do not add a Controls column.
- **Toolbar.** Use the toolbar in section 2.2.
- **Context menu** (`.contextMenu(forSelectionType: DatabaseID.self, menu:primaryAction:)`): "Open" (bold, primary
  action = double-click/Return), divider, "Edit Database…", "Manage Tags…", "Clone Database…", divider,
  "Copy Host and Port", divider, "Export…", "Remove…". With a multi-selection: "Open N Databases", "Export N
  Databases…", "Remove N Databases…".
- **Keyboard.** Support these controls:
  - Return or a double-click opens the selection.
  - ⌫ through `.onDeleteCommand` asks to remove the selection.
  - ⌘F focuses search.
  - ⌘N opens Add Database.
  - ⌥⌘E edits the single selected database.
- **Selection.** Support multiple selected rows. A single click selects a row without opening it.
- **States.** While loading, show `ProgressView()` centered over the empty table. If the library is empty, show
  `ContentUnavailableView { Label("No Databases", systemImage: "cylinder.split.1x2") } description: { Text("Add a Redis
  database with a connection URL, discover Sentinel primary groups, or import connections from a file.") } actions: {
  Button("Add Database…") }`. If the filter returns no rows, show `ContentUnavailableView.search(text:)` (or, for a sidebar filter
  without search text, `ContentUnavailableView("No Matching Databases", systemImage: "line.3.horizontal.decrease.circle")`).
  If connection fails, show an error alert through `services.toasts.error`.
- **Remove.** Show confirmation `Remove “<name>”?` / message "The connection will be removed from Keystrand. Your data on the
  server is not affected." / "Remove". Multi: `Remove 3 Databases?` with up to 10 names in the message.
- **Export.** "Export…" opens a Small sheet containing database names in a
  plain `List` and an "Include passwords" toggle, enabled by default. Show
  "Cancel" and "Export…" in the footer. Export opens `NSSavePanel` with filename
  `Keystrand_connections_<ms>.json`.
- **Excluded controls.** Do not use striped custom rows, tag chips, module badges, a row "…" popover, a copy button in the Host cell (copying
  is in the context menu), a Columns popover, a tag funnel popover, a bulk action bar, a dashed drop-zone overlay
  (dropping a file still works; the window shows the system drop highlight only).

### 3.2 Add Database sheet (start page) (Connections)

- **Pattern.** Use Mail > Add Account and Xcode > Add Account.
- **Layout.** Use a Form-size `SheetForm(title: "Add Database")`. Add one grouped `Form` with these sections:
  - Section "Connection URL": `TextField("Connection URL", text:, prompt: Text("redis://default@127.0.0.1:6379"),
    axis: .vertical).lineLimit(2...4)` with `.fontDesign(.monospaced)`; section footer (`.secondary`, `.footnote`):
    "Supported formats: redis://[user[:password]@]host:port, rediss://…, host:port". Invalid URL: footer shows
    `InlineMessage("The connection URL format is not supported. Use Connection Settings instead.", kind: .error)`.
  - Section "Other Ways to Add": three rows, each a `Button` with `.buttonStyle(.plain)` whose label is
    `LabeledContent { Image(systemName: "chevron.right").foregroundStyle(.tertiary) } label: { Label(…) }`:
    "Redis Sentinel" (`shield.lefthalf.filled`), "Redis Software" (`building.2`), "Import from File" (`doc`).
- **Footer.** Put "Test Connection" at the leading edge. Put "Cancel",
  "Connection Settings…", and the default "Add Database" action at the trailing edge.
- **Keyboard.** If the URL is valid, Return adds the database. Esc cancels.
- **States.** While testing, show progress in the Test Connection button. The result shows in the sheet directly above the footer
  (the `SheetForm` message slot): success is `InlineMessage("Connection is successful.", kind: .success)`, and failure
  is `InlineMessage(kind: .error)`. Editing the URL clears a success. Adding a database closes the sheet; the new row
  in the table is the confirmation.
- **Excluded controls.** Do not use tile grid, "Or" rule, info tooltip icon.

### 3.3 Connection settings form to add, edit, or clone (Connections)

- **Pattern.** Use System Settings > Network > Details sheet (segmented pages over grouped forms).

```text
┌ Edit Database ─────────────────────────────────────────────┐
│        [ General | Security | Decompression & Formatters ]  │
│ ┌ Connection ─────────────────────────────────────────────┐ │
│ │ Connection Type                               Standalone│ │
│ │ Modules                                Search, JSON +2  │ │
│ └─────────────────────────────────────────────────────────┘ │
│ ┌ Database ───────────────────────────────────────────────┐ │
│ │ Alias                        [local                    ]│ │
│ │ Host                         [127.0.0.1                ]│ │
│ │ Port                         [6390 ]                    │ │
│ │ …                                                       │ │
│ └─────────────────────────────────────────────────────────┘ │
│ [Test Connection] [Clone Database…]        [Cancel] [Save]  │
└─────────────────────────────────────────────────────────────┘
```

- **Layout.** Use a Form-size `SheetForm`. Set the title to "Connection Settings" (add), "Edit Database" (edit), "Clone Database"
  (clone). Under the title, centered `Picker("", selection: $page) { "General", "Security", "Decompression &
  Formatters" }.pickerStyle(.segmented).labelsHidden()`. Below it one grouped `Form` per page.
- **General page.** Include these sections:
  - Edit only, first section "Connection" with read-only `LabeledContent` rows (hidden when empty): Connection Type,
    Database Name from Provider, Host (with `.help` listing cluster nodes), Port, Database Index, Modules.
  - "Database": TextField "Alias", TextField "Host" (prompt "Hostname, IP address, or connection URL"),
    TextField "Port" (`.monospacedDigit()`), Picker "IP Protocol" (`.menu`: Automatic (IPv4 and IPv6), IPv4, IPv6),
    TextField "Username", SecureField "Password", TextField "Timeout" with trailing unit text "seconds".
  - "Options": Toggle "Select logical database" + indented TextField "Database Index" when on; Toggle "Force standalone
    connection" with a section footer explaining that it overrides the default connection logic and connects to the
    given endpoint as a standalone database; Picker "Environment" (`.menu`: Unspecified,
    Production, Development) with footer text explaining the three values.
  - Pasting a URL into Host autofills.
- **Security page.** Include sections "TLS" (Toggle "Use TLS"; when on: Toggle "Use SNI" + TextField "Server Name"; Toggle
  "Verify TLS certificate"; Picker "CA Certificate" (`.menu`, items: None, saved certificates, divider, "Add New…");
  when Add New: TextField "Name", `TextEditor` "Certificate" (monospaced, 5 lines); Toggle "Requires TLS client
  authentication" → Picker "Client Certificate" + Name/Certificate/Private Key editors), "SSH Tunnel" (Toggle "Use SSH
  tunnel"; Host, Port, Username; `Picker("Authentication", …).pickerStyle(.segmented)` Password | Private Key; SecureField
  or `TextEditor` + Passphrase), "Pre-Connection Script" (`TextEditor`, monospaced, footer: runs in the login shell before each connection, which starts only after the
  script exits with code 0),
  "Post-Disconnect Script" (`TextEditor`, monospaced, footer: runs in the login shell after Keystrand closes its
  connections to the database, even when the connection failed).
  Deleting a saved certificate: a "Delete Certificate…" button next to the picker (enabled for saved certs) with
  `.destructiveConfirmation("Delete “<name>”?", …)`.
- **Decompression & Formatters page.** Add Toggle "Enable automatic data decompression" + Picker "Decompression Format";
  Picker "Key Name Format" (Unicode, HEX).
- **Footer.** Put "Test Connection" at the leading edge. In edit mode, put
  "Clone Database…" after it. In clone mode, show "Back" to return to edit.
  Put "Cancel" and the primary action at the trailing edge. Use "Add Database",
  "Save", or "Clone Database" for the primary action, based on the mode.
  If required fields are missing, disable the primary action and Test Connection.
  Show `InlineMessage("Fill in the required
  fields: Host, Port.", kind: .warning)` with at most five field names.

- **Secrets.** Stored secrets show as an empty `SecureField` with prompt "Saved" (`.secondary`); typing replaces it,
  unchanged fields are not re-sent.
- **Sentinel edit and clone.** Use the same frame. The General page contains sections "Database" (alias, db index, master username/password) and
  "Sentinel" (host/port/username/password).
- **Keyboard.** If the form is valid, Return submits it. Do not assign ⌘[ or ⌘].
- **Excluded controls.** Do not use custom tab strip, required-field tooltip icons, half-width web grid, info "(i)" tooltips (explanations
  are section footers or `.help`).

### 3.4 Sentinel and Redis Software discovery (Connections)

- **Pattern.** Use Xcode > Add Accounts and Disk Utility list sheets.
- **Flow.** Keep discovery in the Add Database sheet:
  1. Selecting "Redis Sentinel" replaces the content with a Form-size Sentinel form.
     Put "Back" at the footer's leading edge.
  2. Selecting "Discover" expands the sheet to Large and opens the discovery page.
  3. Adding groups opens the result page in the same sheet.
  4. Selecting "Done" closes the sheet.

- **Sentinel form.** Use a grouped `Form`: section "Sentinel" (Host default 127.0.0.1, Port default 26379, IP Protocol,
  Username, Password), section "TLS" (same as 3.3), explanatory section footer and a `Link("Learn
  More", destination:)`. Footer: Back, Cancel, "Discover" (default).
- **Discovery page.** Use `SheetForm(title: "Sentinel Primary Groups")`, subtitle text asking which primary groups to add. `Table` with
  `.tableStyle(.inset(alternatesRowBackgrounds: true))`, a checkbox column (`Toggle` `.toggleStyle(.checkbox)`), Primary
  Group, Alias (inline `TextField`), Address, Replicas, Username (TextField), Password (SecureField), Database Index
  (TextField, `.monospacedDigit()`). A search field (RedisUI `SearchField`, prompt "Filter") sits in the title row,
  trailing. Footer: Back, Cancel, "Add Primary Groups" (default; disabled with an `InlineMessage(kind: .warning)`
  "Choose at least one primary group." or "Enter an alias for every selected group.").
- **Result page.** Use the title "Primary Groups Added", summary line ("Added 3 primary groups. 1 failed.") as
  `InlineMessage(kind: .info/.warning)`, `Table` with a Result column: `Label("Added", systemImage:
  "checkmark.circle.fill")` (`.green`) or `Label("Error", systemImage: "xmark.octagon.fill")` (`.red`) with the message
  as `.help`, and a per-row "Retry" button for retryable rows. Footer: "Done" (default).
- **Redis Software.** Use the same frames. Add form fields Cluster Host, Cluster Port (default 9443), Admin Username, Admin
  Password; discovery table columns Database, Status, Endpoint, Modules (text), Options (symbols with `.help`:
  `arrow.triangle.2.circlepath` Active-Active, `externaldrive` Backup, `square.grid.3x3` Clustering, `internaldrive`
  Persistence, `bolt` Flash, `doc.on.doc` Replication, `arrow.down.doc` Replica Destination, `arrow.up.doc` Replica
  Source); result page "Databases Added".
- **Cancel with changes.** Use `.destructiveConfirmation("Discard Discovered Databases?", message: "Your changes have not
  been saved.", confirmTitle: "Discard")`.
- **States.** During discovery, the "Discover" button shows its working spinner (`SheetForm(isWorking:)`). If empty, show `ContentUnavailableView("No Primary Groups",
  systemImage: "shield.lefthalf.filled", description: Text("This Sentinel isn't monitoring any primary groups."))`. If search returns no rows, show `ContentUnavailableView.search(text:)`.
- **Excluded controls.** Do not use full-page web layout, pagination, colored summary bar, a "View Databases" button ("Done" closes the
  sheet).

### 3.5 Import connections (Connections)

- **Pattern.** Use Contacts > Import and Passwords > Import.
- **Layout.** Open "Import from File" from Add Database in a Form-size sheet. Use a grouped `Form` with a "File" section containing RedisUI
  `FilePickerRow` ("Choose File…" button + chosen filename + size, accepts drops), footer "Use a JSON file exported
  from Keystrand or RedisInsight. Use files only from trusted sources." Max 10 MB → `InlineMessage("File should not exceed
  10 MB.", kind: .error)`. Footer: Back, Cancel, "Import" (default, disabled until a file is chosen).
- **Importing.** Hide fields. Center `ProgressView("Importing…")` in the sheet.
- **Failure.** Show `ContentUnavailableView { Label("Import Failed", systemImage: "xmark.octagon") } description: {
  Text(error) }`; footer "Try Again" (leading), "Done".
- **Results.** Expand the sheet to Large. Use a `List` with `Section`s "Imported (N)", "Partially Imported (N)", "Failed (N)"
  (only non-empty), each row `LabeledContent("#\(index) host:port") { result text }`, failures in `.red`. Footer "Done".
- **Excluded controls.** Do not use collapsible custom accordions, illustrations, dashed drop zone.

### 3.6 Manage Tags sheet (Connections)

- **Pattern.** Use Finder > Tags editor and Mail > Rules condition rows.
- **Layout.** Use `SheetForm(title: "Manage Tags for “<name>”")`, size Small. Description text ("Label databases with key-value tags to group and filter them.") under the title.
  `Grid` of rows: `TextField("Key")` · `Text(":")` · `TextField("Value")` · remove button
  (`Image(systemName: "minus.circle")`, borderless, `.help("Remove Tag")`). Below: `Button("Add Tag",
  systemImage: "plus.circle")` borderless. Inline validation messages under the row as `.footnote` `.red` text.
  Suggestions: `TextField` with `.textInputSuggestions { }` (macOS 15+) listing presets and existing tags, filtered.
- **Footer.** Show "Cancel" and default action "Save". Enable Save only if
  the form contains valid changes.
- **Excluded controls.** Do not use custom suggestion popup, trash icons, warning banner (for Redis Software databases the description's
  second paragraph reads "Tags edited here are saved on this Mac only. Redis Software keeps its own tags.").

### 3.7 Database switcher popover (Connections)

- **Pattern.** Use Safari's tab overview search and Xcode scheme chooser popover.
- **Layout.** `DatabasePickerPopover` keeps its public signature. Content: RedisUI `SearchField` (prompt "Search
  Databases") at top, then `List(selection:)` `.listStyle(.plain)` of rows `name [dbN]` with a trailing checkmark for
  the current database, a `ProgressView().controlSize(.small)` while connecting, then `Divider()` and a
  borderless button "Show All Databases" (⌘0). Size 320×380.
- **Keyboard.** Typing filters the list. ↑ and ↓ move the selection. Return opens the database. Esc closes the popover.
- **States.** If no databases exist, show `ContentUnavailableView("No Databases", systemImage: "cylinder.split.1x2")`. If no matches exist, show
  `.search(text:)`.
- **Excluded controls.** Do not use a "Databases (n)" tab header, custom highlight.

### 3.8 Browser key list and tree (Browser)

- **Pattern.** Use Finder list view with View > as List / as Outline and Mail message list status.
- **Layout.** Use the leading pane of the Browser `HSplitView`, `.frame(minWidth: 300, idealWidth: 420)`. Content: the key list,
  then `Divider()`, then a `StatusBar` (RedisUI, 22 pt).
- **List mode.** Use `List(selection: $selectedKey) { ForEach(rows) { KeyRow } }` with
  `.listStyle(.inset(alternatesRowBackgrounds: true))`. Row = `HStack`: `KeyTypeIcon(type, size: .small)`, key name
  (`.body.monospaced()`, `.lineLimit(1)`, `.truncationMode(.middle)`, `.help(full name)`), Spacer, TTL (`.callout`,
  `.secondary`, `.monospacedDigit()`, width 70, trailing) when shown, Size (same style, width 70) when shown. Metadata
  not yet loaded renders as empty text (no placeholder bars).
- **Tree mode.** Use `List(selection:) { OutlineGroup }` (or `DisclosureGroup` rows) in the same list style. Folder row:
  `Label(name, systemImage: "folder")` (`folder.fill` when expanded is not used; keep `folder`), Spacer, percentage
  (`.secondary`), count `.badge(count)`. Leaf row as in list mode with the short name. Expansion state per session.
  Space toggles the focused folder.
- **Status bar.** Use `.footnote` and `.secondary`. Show "1,234 keys" (no filter), "Found 12 · scanned 500 of 1,234"
  (filtered/tree; "~" prefix when approximate), "Scanning…" with `ProgressView().controlSize(.mini)` on first load.
  Trailing borderless button "Scan More" (shown when a pattern filter is active, in tree view, or when the total is unknown, and the
  cursor is not 0) with `.help("Each extra scan adds load on the server and
  keeps more keys in memory.")`.
- **Section items (Browser):** 1. `Picker("View", selection: $viewMode) { Label("List", systemImage: "list.bullet");
  Label("Tree", systemImage: "list.bullet.indent") }.pickerStyle(.segmented)` (Tree disabled in HEX key-name format with
  `.help`); 2. Key type filter menu (3.9); 3. "New Key…" (`plus`); 4. "Delete Key…" (`trash`, enabled with a selected
  key); 5. `AutoRefreshMenu(postfix: "keys")`.
- **View Options (⌘J).** **View > Show View Options** opens a popover anchored
  to the view picker. Use a grouped `Form`
  (`.formStyle(.grouped)`, width 300) with sections "Columns" (Toggle "TTL", Toggle "Size" with footer "Turn off Size if
  large keys make the list slow to load."), "Sort By" (List mode: Picker `.inline` None, Key, TTL, Size + Picker
  Ascending/Descending), "Tree" (TextField "Delimiters" with `TokenField`-like comma-separated text, Stepper "Ignore
  separators in first N characters" 0–512, Picker "Sort Folders" A to Z / Z to A). Changes apply on close (Return or
  clicking away); "Cancel" button discards.
- **Context menu (key rows).** Include "Copy Key Name" (⌥⌘C), "Rename…", "Set TTL…", divider, "Find Keys with This Prefix",
  divider, "Delete Key…". Folder rows: "Expand All", "Collapse All", "Copy Pattern", divider, "Delete Keys in Folder…"
  (opens Bulk Actions Delete with `<folder><delim>*`; disabled when the folder name has more than one delimiter or contains U+FFFD).
- **Keyboard.** Support these controls:
  - ↑ and ↓ select a key and open its details.
  - Return opens Rename.
  - ⌫ opens Delete Key through `.onDeleteCommand`.
  - ⌥⌘C copies the key name.
  - ⌘F focuses search.
  - Space expands or collapses folders in tree mode.
- **Selection.** Support one selected key. Open it in the details pane. Keep the selection during refresh.
- **Infinite loading.** `.onAppear` on the row 50 from the end triggers the next SCAN when `nextCursor != 0` and no
  filter is active. With a filter, loading more is explicit ("Scan More").
- **States.** On first load, show `ProgressView()` centered. If the database is empty, show
  `ContentUnavailableView { Label("No Keys", systemImage: "key") } description: { Text("This database is empty.") }
  actions: { Button("New Key…"); Button("Load Sample Data…") }`. If the pattern scan is incomplete, show `ContentUnavailableView(
  "No Results Yet", systemImage: "magnifyingglass", description: Text("Scan more keys or search for an exact key name."))`
  with action "Scan More". After a complete scan, show `ContentUnavailableView.search(text: pattern)`. If RediSearch has no index selected, show
  `ContentUnavailableView("Choose an Index", systemImage: "sparkle.magnifyingglass", description: Text("Pick an index,
  then type a query to match against key values."))`. For list errors, show `ErrorStateView(message:, retry:)`.
- **Narrow windows.** If the detail column is narrower than 720 pt, the Browser shows only one pane: the list, or the
  details with a "Back" button (`Label("Back", systemImage: "chevron.left")`, ⌘[) added as the first Browser section
  item (`.primaryAction`; sections never use `.navigation`). While the details are shown in single-pane mode, the view
  picker and the type filter are hidden so the Browser never exceeds six section items.
- **Excluded controls.** Do not use hover delete buttons, skeleton rows, rounded row backgrounds, a keys header row with gear/columns/view
  toggles, a "Last refresh" label, custom row heights (rows use the list's default height), a Columns popover, a tree
  settings popover.

### 3.9 Browser search, filters and history (Browser)

- **Pattern.** Use Finder search with scope bar and tokens and Mail search suggestions.
- **Search field.** Use `.searchable(text: $query, tokens: $typeTokens, suggestedTokens: $suggestedTypeTokens, placement:
  .toolbar, prompt: mode == .pattern ? "Key name or pattern" : "Search values") { token in Label(token.title,
  systemImage: token.type.symbolName) }` on the Browser view. `typeTokens` holds at most one `KeyTypeToken`; adding a
  second replaces the first. Submitting (Return) applies the pattern (empty = `*`); clearing the field and tokens is
  "Reset Filters".
- **Scopes.** Use `.searchScopes($mode, activation: .onSearchPresentation) { Text("Key Name").tag(.pattern); Text("Values
  (Redis Search)").tag(.redisearch) }`. The Values scope is disabled (tag present, selection reverted with an alert)
  when the search module is missing or older than 2.0, explained in an alert.
- **Type filter menu (section item 2).** Use `Menu { Picker("Key Type", selection:) { Text("All Types"); ForEach(types)
  { Label(title, systemImage:) } }.pickerStyle(.inline) } label: { Label("Filter", systemImage:
  typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }`. It and the
  token stay in sync. Disabled below Redis 6.0 with `.help("The key type filter needs Redis 6 or newer.")`.
- **Index picker.** In RediSearch scope, insert a picker before the type filter. Use a `Menu` labeled with the index name or
  "Choose Index", items = indexes ("(empty name)" for empty), divider, "Refresh Indexes", "Create Index…".
- **History.** If the field has focus and is empty, `.searchSuggestions` shows a "Recent Searches" section with up to 10
  entries (`Label(pattern, systemImage: "clock")`, `.searchCompletion(pattern)`; entries with a type filter show the
  type icon) and "Clear Recent Searches". Removing a single entry: context menu "Remove from Recents".
- **Excluded controls.** Do not use custom mode segmented control, custom type dropdown with colored dots, history dropdown, reset/history/
  search buttons inside the field.

### 3.10 Bulk Actions (Browser)

- **Pattern.** Use Finder > Batch Rename sheet and Disk Utility progress sheet.
- **Entry.** Open Bulk Actions through "Delete Keys Matching Filter…" or "Upload Commands from File…" in the Database menu. Also offer it in folder context menus. Do not add a toolbar button.
- **Layout.** Use `SheetForm(title: "Bulk Actions")`, size Large, `Picker` segmented "Delete Keys" | "Upload Data" under the
  title.
  - Delete: grouped `Form`: section "Filter" with `LabeledContent("Key Type")` (KeyTypeLabel or "All Types"),
    `LabeledContent("Pattern")` (monospaced); section "Estimate" with `LabeledContent("Expected Keys", "~N")` and
    `LabeledContent("Scanned", "P% (scanned of total), found N")`; section footer: InlineMessage(kind: .warning)
    "Deleting many keys at once can slow the server and spike its memory use. Avoid it on production databases." Toggle
    "Save report to a file". When neither pattern nor type is set: `ContentUnavailableView("No Filter Set",
    systemImage: "line.3.horizontal.decrease.circle", description: Text("Set a pattern or key type in the Browser
    first."))`.
  - Running: section "Progress" with `ProgressView(value:)` (linear) and `LabeledContent` Processed / Success / Errors /
    Time. Final status as `Label` with `checkmark.circle.fill` (.green) "Completed", `stop.circle` "Stopped at P%",
    `xmark.octagon.fill` (.red) "Failed".
  - Upload: section "File": `FilePickerRow` (.txt, max 3,000 MB), footer "Upload a text file with one Redis command per
    line, for example SET key value. Only run files you trust."; results as LabeledContent rows.
- **Footer.** Change the controls for each task state:
  - Delete shows "Cancel" and "Delete Keys…" with `role: .destructive`.
    Use `.destructiveConfirmation("Delete Matching Keys?",
  message: "All keys matching the type and pattern will be deleted.", confirmTitle: "Delete")`.
    On production, require typed confirmation through `session.confirm`.
  - While running, show "Stop".
  - After completion, show "Start New" at the leading edge and default action "Done".
  - Upload shows "Cancel" and "Upload…". Use
    `.destructiveConfirmation("Run Commands from “file.txt”?", message: "Each command in the file
  will run against this database, in order.", confirmTitle: "Run")`.
- **Excluded controls.** Do not use right-pane panel, full-screen toggle, info card, colored banners, popover confirmations.

### 3.11 New Key sheet (Browser; Vector Set form from Advanced key types)

- **Pattern.** Use Xcode > New File options sheet and Contacts new card.
- **Layout.** Use a Form-size `SheetForm(title: "New Key")` with a grouped `Form`. Include these sections:
  - Section "Key": `Picker("Type", selection:)` (`.menu`, items `Label(type.displayName, systemImage:
    type.symbolName)`; Vector Set disabled below Redis 8.0 with "Requires Redis 8.0+" in the item title), TextField
    "Name" (monospaced, required), TextField "TTL" (prompt "No limit", digits only, trailing unit "seconds").
  - Section "\<Type\> Value": type-specific rows using RedisUI `MultiRowFormList` (Hash field/value[/TTL], List
    elements + Picker "Insert At" Tail/Head, Set members, Sorted Set member/score, Stream entry ID + field/value, String
    value as `TextEditor` (monospaced, min 8 lines), JSON as `CodeEditorView(language: .json)` + "Choose File…" button,
    Vector Set as the injected `VectorSetAddKeyForm(context:)` content rendered inside the same Form).
  - JSON without module: section footer `InlineMessage("This database does not support JSON.", kind: .warning)`.
- **Footer.** Show "Cancel" and default action "Add Key". Enable Add Key only
  if the form is valid. Show a spinner while saving. If the name exists, show
  `InlineMessage("This key name is already in use.", kind: .error)` above the footer.
- **After success.** Close the sheet. Select the new key.
- **Load sample data.** For the empty database action, use `.destructiveConfirmation("Load Sample Data?", message: "This runs the
  bundled sample commands against this database. Avoid it on production databases.", confirmTitle: "Load")`;
  disabled for production databases.
- **Excluded controls.** Do not use a right-pane "New Key" panel with a close button.

### 3.12 Key details header and metadata (Browser, KeyTypesBasicFeature)

- **Pattern.** Use Mail message header (sender line + LabeledContent-like rows) and Finder Get Info header.
- **Layout.** Use the trailing pane of the Browser `HSplitView` (min 380). Top to bottom: header (padding 12 vertical, 16
  horizontal), `KeySubheaderBar` (3.13), `Divider()`, type view body, no footer except String "Load All" row.
- **Header.** Build these rows:
  - Row 1: `KeyTypeIcon(type, size: .large)` (28 pt), key name `Text` in `.title3` `.fontDesign(.monospaced)`
    `.textSelection(.enabled)` `.lineLimit(1)` `.truncationMode(.middle)` with `.help(full name)`; trailing actions menu
    `Menu { … } label: { Label("Key Actions", systemImage: "ellipsis.circle") }.menuStyle(.button)
    .buttonStyle(.borderless).menuIndicator(.hidden)` with items "Copy Key Name", "Rename…", "Set TTL…", divider,
    "View Index" (submenu when several) / "Make Searchable…", divider, "Refresh Key" (⌘R refreshes the list and the
    key together), "Auto Refresh" submenu (Toggle + "Every" picker, persisted per key type postfix; disabled
    while a value is being edited), divider, "Hide Key List" / "Show Key List" (full-screen details), divider,
    "Delete Key…".
  - Row 2: `KeyMetadataRow` (RedisUI) = `HStack(spacing: 20)` of `LabeledContent` items (label `.secondary`, value
    `.monospacedDigit()`): "Type" (display name), "Size" (bytes; `-1` shows "Too large" with a `.help` explaining that `MEMORY USAGE` was skipped for performance),
    "Length" (per-type label: Entries, Top-Level Values, Samples, Nodes, Count), Vector Set adds "Quantization" and
    "Dimensions", Array adds "Count", and "TTL" ("No limit" or duration; `.help` with seconds). In narrow panes
    (< 560 pt) the row wraps into a two-column `Grid`.
- **Rename.** "Rename…" (Return in the key list, double-click on the name) opens a Small sheet "Rename Key" with
  TextField "Name" prefilled; non-printable names disable the item with `.help("Use Workbench or CLI to rename keys with
  non-printable characters.")`; overwrite asks `Replace “<name>”?`.
- **Set TTL.** Use a popover anchored to the TTL value (or the actions menu): `TextField("TTL", prompt: "No limit")` with
  trailing "seconds", buttons "Cancel" and "Set" (default). Empty = persist, 0 deletes the key after
  `.destructiveConfirmation("Delete “key”?", message: "A TTL of 0 deletes the key.")`.
- **Delete.** Use `.destructiveConfirmation("Delete “<key>”?", message: "This key will be deleted. You can't undo this
  action.", confirmTitle: "Delete")`; Development environment skips it.
- **No key selected.** Show `ContentUnavailableView("No Key Selected", systemImage: "key", description: Text("Select a key
  to see its details."))`.
- **Key deleted elsewhere.** Close details. Remove the row. Show the "Key Not Found" error alert.
- **Loading.** Show `ProgressView().controlSize(.small)` in place of the metadata row; body shows `ProgressView()` centered.
- **Excluded controls.** Do not use a close "×" button (closing = deselecting; Esc in the key list deselects), a full-screen icon button, an
  inline rename field with ✓/✗, an inline TTL editor with a pencil, hover pencil and copy buttons, a "Last refresh"
  label, a refresh control in the header (the Browser toolbar's refresh refreshes the key too), skeleton lines.

### 3.13 Key subheader and value format picker (RedisUI, used by all key types)

- **Pattern.** Use Xcode jump bar and Preview's format menu.
- **Layout.** Use `KeySubheaderBar { leading } trailing: { … }`: `HStack` with `.controlSize(.small)`, padding 6 vertical,
  16 horizontal, no background. Trailing order: `ValueFormatPicker` ("Format" menu `Picker`, `.pickerStyle(.menu)`,
  `.fixedSize()`; compact (< 560 pt) shows `Label(format.title, systemImage: "textformat").labelStyle(.iconOnly)`),
  then type actions as `AddItemsButton` ("Add Fields…", `plus`) and others (borderless buttons with title and symbol).
- The format picker is disabled with `.help` when not applicable (for example until the full value is loaded); JSON keys have no format picker.
- **Excluded controls.** Do not use vertical dividers between items, icon-only action buttons at wide widths.

### 3.14 String (Browser)

- **Layout.** Fill the body with a read-only `CodeEditorView(language: .plain, isEditable: false, wrapsLines: true)` filling the
  pane. Partial values (first 5,000 bytes) show a bottom `StatusBar`: "Showing the first 5,000 bytes" + buttons "Load
  All" and "Save to File…".
- **Editing.** Add subheader action "Edit" (`pencil`, ⌘E is not used; Return in the editor area does not edit). Edit mode
  makes the editor editable and shows a bottom bar (`StatusBar` style) with "Cancel" and "Save" (default, ⌘S while the
  editor has focus). Disabled with a `.help` reason when the value is partly loaded, decompressed, or shown in a
  format that cannot be edited. Invalid format on save:
  `.destructiveConfirmation("Save as Unicode?", message: "The value is not valid in the selected format.",
  confirmTitle: "Save")`.
- **Copy.** Support subheader "Copy" (`doc.on.doc`) and ⌘C in the editor.
- **Empty.** The editor shows the placeholder "Empty" in `.tertiary` italic.
- **Excluded controls.** Do not use footer link buttons, a text area with a custom border.

### 3.15 Hash, List, Set (Browser)

- **Pattern.** Use Xcode Property List editor (Key / Type / Value table).
- **Containers.** Use `Table(rows, selection: $selection)` `.tableStyle(.inset(alternatesRowBackgrounds: true))`; data
  cells use `MonospacedCell` / `FormattedValueCell` (`.body.monospaced()`), one line when unselected; the selected row's
  value cell shows up to 8 lines.
  - Hash: columns Field (resizable, width persisted in `settings.browser`), Value, TTL (Redis ≥ 7.3; toggled by the
    subheader Toggle "Show TTL" `.toggleStyle(.checkbox)`).
  - List: Index (`.monospacedDigit()`), Element.
  - Set: Member.
- **Subheader.** Place leading `SearchField` (prompt "Filter Fields" / "Go to Index" / "Filter Members"), trailing format
  picker, "Add Fields…" / "Add Elements…" + "Remove Elements…" / "Add Members…".
- **Editing.** A double-click on a value cell or Return with a selected row opens the Edit Value sheet (Form size):
  `CodeEditorView` with the value serialized in the current format, footer Cancel / Save; same editing rules as String. Field TTL edits via
  the context menu "Set Field TTL…" popover.
- **Value preview.** Space or "Show Value" in the context menu opens a Large sheet "Value Preview" with the full formatted
  value (JSON formats as `JSONTreeView`), buttons "Copy" and "Done".
- **Add sheets.** Use Form-size `SheetForm` ("Add Fields to “key”", "Add Elements to “key”", "Add Members to “key”") with
  `MultiRowFormList`; List adds Picker "Insert At" Tail/Head. Remove Elements: Small sheet with Picker "Remove From"
  Tail/Head and TextField "Count" (disabled below 6.2 with footer note), confirm via `.destructiveConfirmation`.
- **Context menu (rows).** Include "Copy Field" / "Copy Value", "Show Value", "Edit Value…", divider, "Remove Field…" /
  "Remove Member…" (List has no per-row remove).
- **Keyboard.** Space opens the value preview. Return edits the value.
  ⌫ asks to remove the item. For the last item, the message reads
  "Removing the last item deletes the key.".
- **Infinite loading.** `.onAppear` near the last rows loads the next 500 through HSCAN, LRANGE, or SSCAN. While loading, a trailing
  `LoadMoreRow` shows a small spinner.
- **States.** For an empty table or filter result, show `ContentUnavailableView.search(text:)` or `ContentUnavailableView("No Fields",
  systemImage: "number")`. Show errors as alerts.
- **Excluded controls.** Do not use row click expand/collapse, hover pencil and trash, a bottom add panel, a search icon in the column header,
  a tall custom header row.

### 3.16 Sorted Set (Advanced key types)

- Same frame as 3.15. Table columns Member, Score (`.monospacedDigit()`, sortable ascending/descending with the column
  header; changing the sort reloads from the first page). Score editing: double-click on Score → inline `TextField` in the cell (Return
  saves, Esc cancels); non-numeric scores disable editing with `.help`. Member edit: Edit Value is not offered.
  Subheader: `SearchField` "Filter Members", format picker, "Add Members…" (sheet with Member/Score rows).
- Context menu: "Copy Member", "Copy Score", "Show Value", "Edit Score", divider, "Remove Member…".

### 3.17 Stream (Advanced key types)

- **Pattern.** Use Console (time-stamped entries) and Mail threads (drill-down with a path control).
- **Layout.** Start the subheader with `Picker` segmented "Entries" | "Consumer Groups"; when drilled into a group/consumer,
  a path is shown after it: `Button(groupName)` › `Text(consumerName)` (borderless, `.callout`), acting as breadcrumb
  back navigation (this is a path control, not a page header). Trailing: format picker, "New Entry…" / "New Group…".
  - Entries: `RangeSliderView` row (date labels `.caption` `.monospacedDigit()`, "Reset" borderless button) above a
    `Table` whose first column "Entry ID" shows two lines (formatted date `.secondary`, id monospaced) and one column per
    field. Sort by Entry ID via column header. Horizontal scrolling is the Table's own.
  - Consumer Groups: Table Group, Consumers, Pending (`.help` range), Last Delivered ID (double-click or context menu
    "Set Last Delivered ID…" → popover editor). Row double-click drills into Consumers.
  - Consumers: Table Name, Pending, Idle Time (ms, trailing). Double-click drills into Pending Messages.
  - Pending Messages: Table Entry ID, Last Delivered, Delivery Count, and a trailing column with two borderless buttons
    "Acknowledge…" and "Claim…" (Claim popover form: consumer, min idle time, and optional idle time, retry count and force, laid out as a grouped `Form` 420 wide with a
    DisclosureGroup "Optional Parameters").
- Confirmations: delete entry/group/consumer, acknowledge → `.destructiveConfirmation`.
- Empty: `ContentUnavailableView("No Entries", systemImage: "water.waves")`, "No Consumer Groups", "No Consumers",
  "No Pending Messages"; range empty: `ContentUnavailableView.search`.
- **Excluded controls.** Do not use a custom tab strip with breadcrumb tabs, a custom virtual grid, bottom add panels (adding uses sheets).

### 3.18 JSON (Advanced key types)

- **Pattern.** Use Xcode Property List editor outline and Console JSON view.
- **Layout.** Omit the format picker. On the trailing side of the subheader, place `Picker` segmented "Tree" | "Text" (Text mode = the full document in a JSON editor),
  "Copy" (`doc.on.doc`) or "Save to File…" for partially loaded documents.
- **Tree.** Use RedisUI `JSONTreeView` (section 4): rows in an outline with system disclosure chevrons, monospaced text,
  syntax colors from `EditorAppearance.JSON`, selection highlight from the system. Row actions via context menu: "Edit
  Value…" (scalars: inline field; containers: Edit Value sheet with `CodeEditorView(language: .json)`), "Add Entry…"
  (containers; Small sheet with Key and Value fields), "Copy Path", "Copy Value", divider, "Delete…". Keyboard: Return
  edits, ⌫ deletes, ←/→ collapse/expand, Space preview.
- **Text mode.** Use `CodeEditorView(language: .json)` editable; bottom bar "Revert" and "Save".
- **Excluded controls.** Do not use hover pencil/trash, inline "+" rows under containers, a floating copy button.

### 3.19 Vector Set (Advanced key types)

- **Pattern.** Use Photos "Show Similar" and Spotlight search form above results.
- **Layout.** Use a top `Form` (`.formStyle(.grouped)`, `.scrollDisabled(true)`, compact) with section "Find Similar":
  `Picker` segmented "Vector" | "Element", query `TextField` (monospaced), `Stepper("Results: \(count)", value:
  in: 1...1000)`, `TextField("Filter")` with `.textInputSuggestions` for `.attr` completion and a trailing
  `Button { } label: { Label("Filter Syntax", systemImage: "questionmark.circle") }` popover; row of
  `CommandPreviewBar` (its "Show command" checkbox reveals the command), "Reset", "Find Similar" (default when the field has
  focus). Below: `Table` of elements (Element, Actions) or results (Rank, Element, attribute columns hidden by default
  via column customization, Similarity `xx.xx %` with `.green` text ≥ 85%).
- **Paging.** Load pages of 50 elements as the user scrolls (`VRANGE … 50`); the status bar shows "Showing N of T". `VRANDMEMBER` fallback shows "Previewing N of T".
- **Element details.** A double-click or "Show Details" in the context menu opens a Large sheet "Element “name”" with sections "Vector" (read-only monospaced `TextEditor`, Copy / Save to File…)
  and "Attributes" (`CodeEditorView(language: .json)`, editable with Save).
- **Context menu.** Include "Show Details", "Find Similar Elements", "Copy Element Name", divider, "Remove Element…".
- **Add Elements.** Use a Form-size sheet with rows (Name, Vector with live validation text under the field), DisclosureGroup
  "Attributes (Optional)".
- **Excluded controls.** Do not use a right drawer, a pager, a link-style "View", custom rank badges (rank is plain `#1` text).

### 3.20 Time Series (Advanced key types)

- **Layout.** Use Swift Charts `LineMark` chart (height 220, system default axes, `.foregroundStyle(.tint)`) above a
  `Table` of samples with formatted Timestamp and monospaced Value columns.
  Add a subheader `Picker` for range and aggregation. Omit the format picker.
- **States.** If no samples exist, show `ContentUnavailableView("No Samples", systemImage: "chart.xyaxis.line")`.
- **Excluded controls.** Do not use custom chart colors, a bordered chart panel.

### 3.21 Array (Advanced key types)

- **Layout.** Start the subheader with a segmented "View" | "Search" | "Aggregate". Each tab: a compact grouped `Form` (query
  inputs: start and end index for View and Aggregate, match predicates and options for Search, `CommandPreviewBar` ("Show command" checkbox), "Reset", "Run" default) above a `Table`
  (Index `.monospacedDigit()`, Value) or a result `LabeledContent("Result")` with Copy.
- Multi-selection in the Table; ⌫ / context "Remove Elements…" removes selected; subheader "Delete Range…" and
  "Add Element…" (Small sheet). Edit value: double-click opens the Edit Value sheet.
- Empty: `ContentUnavailableView("No Elements in Range", systemImage: "rectangle.split.3x1")`.

### 3.22 Unsupported and module types (Advanced key types)

- `ContentUnavailableView { Label("Unsupported Key Type", systemImage: "questionmark.square.dashed") } description: {
  Text("This key type is not currently supported.") }`; Graph/Time Series module notices: title "RedisGraph Key" /
  "RedisTimeSeries Key", description "Use Redis commands in Workbench to view the value.", action
  `Button("Open Workbench")`. No close button.

### 3.23 Workbench editor and run (Workbench)

- **Pattern.** Use Xcode source editor over the debug console and Script Editor (run button in the toolbar).
- **Layout.** Build the detail column with `VSplitView { editor (minHeight 80, idealHeight 20%) ; results (minHeight 120) }`.
  Editor = `CodeEditorView(language: .redis, showsLineNumbers: true, showsCommandMarkers: true, wrapsLines: true)` edge to
  edge, background `EditorAppearance.background`.

```text
toolbar: … [Raw Mode] [Group Results] [🗑] [▶ Run]  │ [db0 ▾] │ [▭] [◨]
┌──────────────────────────────────────────────────────────────────────────────┐
│  1 ▸ SET foo bar                                       (CodeEditorView)       │
│  2 ▸ GET foo                                                                  │
╞══════════════════════════════ VSplitView divider ════════════════════════════╡
│ ▾ GET foo                         Text ▾   0.2 ms   14:02:11   ⟳  ⋯   (pinned) │
│   "bar"                                                                       │
│ ───────────────────────────────────────────────────────────────────────────── │
│ ▸ SET foo bar                                0.3 ms   14:02:11   ⟳  ⋯         │
│ ───────────────────────────────────────────────────────────────────────────── │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Section items:** 1. `Toggle(isOn: $rawMode) { Label("Raw Mode", systemImage: "text.alignleft") }` (button style,
  `.help("Show raw output")`), 2. `Toggle { Label("Group Results", systemImage: "square.stack") }`, 3. "Clear Results…"
  (`trash`, enabled when results exist), 4. "Run" (`Label("Run", systemImage: "play.fill")`,
  `.buttonStyle(.glassProminent)`, ⌘↩, disabled while running; while running its label is replaced by
  `ProgressView().controlSize(.small)` and help "Running commands…").
- **Tutorial chips** go in the empty state actions and to the Tutorials inspector.
- **Keyboard.** Support these controls:
  - ⌘↩ runs commands.
  - ⌃Space opens completions.
  - ⇧⌘Space opens the signature hint.
  - ↑ at line 1, column 1 opens history.
  - Esc dismisses completions.
- **States.** While command specifications load, keep the editor visible and read-only. Show `ProgressView` in the Run button.
- **Excluded controls.** Do not use a footer row with chips, toggles and Run; an editor skeleton; a custom split.

### 3.24 Workbench results (Workbench)

- **Pattern.** Use Xcode console with collapsible output sections and Terminal marks.
- **Layout.** Use `ScrollView { LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) { ForEach(results) { Section {
  body } header: { ResultHeader } ; Divider() } } }` with `.scrollEdgeEffectStyle(.hard, for: .top)`. No card
  backgrounds or borders.
- **ResultHeader** (height 30, padding 16 horizontal, `.background(.bar)` so pinned headers stay legible): disclosure
  chevron button, command text (`.callout.monospaced()`, `[dbN]` prefix, one line, `.help` numbered lines), Spacer,
  view `Picker` (`.menu`, `.fixedSize()`, only when expanded and > 1 option), duration (`.secondary`,
  `.monospacedDigit()`, `.help("Processing Time: 1,234.567 msec")`), timestamp (`.secondary`), "Run Again" (`arrow.clockwise`,
  icon only, borderless), and a `Menu` (`ellipsis.circle`, borderless) with "Copy Command", "Copy Result", "Profile
  Command" / "Explain Command" (FT.SEARCH/AGGREGATE), "Expand…", divider, "Clear Result". Raw/Group/Silent modes show a
  `.secondary` caption "Raw · Grouped" after the command.
- **Body.** Display text results in `VirtualizedTextLinesView` (monospaced, selectable, max height 210 when not expanded), errors
  in `EditorAppearance.error`. Visualizations (3.25) fill the body. Group and silent modes render as their own card variants.
- **Expand.** Open the result in a Large sheet titled with the command, with the same view picker, "Copy" and "Done".
- **States.** While history loads, show `ProgressView()` centered in the results pane. If no results exist, show
  `ContentUnavailableView { Label("No Results", systemImage: "text.and.command.macwindow") } description: { Text("Run
  commands to see their results here. New to Redis? Try a tutorial.") } actions: { Button("Data Structures");
  Button("Search and Query"); Button("Vector Search") }` (each opens the Tutorials inspector at that page:
  `ds-strings`, `sq-intro`, `vss-intro`);
  For oversized results, show `InlineMessage(kind: .warning)` in the body.
- **Context menu (header).** Use the same items as the ⋯ menu.
- **Excluded controls.** Do not use bordered cards, a hover copy icon, per-card skeletons (running cards show a small `ProgressView` in the
  header), plugin message chips, a card full-screen mode.

### 3.25 Workbench visualizations (Workbench)

- Search table, FT.INFO table, Clients table, Profile table: `Table` with `.tableStyle(.inset(alternatesRowBackgrounds:
  true))`, `MonospacedCell` cells, a header line (`Text("Matched: 42")` `.callout` `.secondary`). Clients table scrolls
  (no pagination). Boolean flags as `Image(systemName: "checkmark")` (`.tint`) / `"xmark"` (`.secondary`).
- JSON view: `JSONTreeView` read-only.
- Time series: Swift Charts with system styling; series colors come from the default chart palette
  (`.foregroundStyle(by: .value("Key", key))`); options (Line/Points, Staircase, Fill, units, axes) in a `Form`
  popover behind a "Chart Options" button; hint text `.footnote` `.secondary`.
- Explain/Profile tree: `List` with `OutlineGroup`, `.listStyle(.plain)`, node type in `.headline`, snippet in
  monospaced `.secondary`, profile timing trailing `.monospacedDigit()`.
- Geo: `Map` (MapKit) with system markers tinted `.tint`; details `Table`.
- **Excluded controls.** Do not use hex chart palettes, colored badges, pagination, bordered containers.

### 3.26 Tutorials (inspector pane) (Workbench)

- **Pattern.** Use Xcode documentation / Help Viewer in a narrow column.
- **Layout.** The pane switches between the root and a page in place (no `NavigationStack`). Root: RedisUI
  `SearchField` (prompt "Search Tutorials") over a `List` `.listStyle(.sidebar)` with `DisclosureGroup`s per manifest
  group (`Label(label, systemImage: "folder")`) and leaf rows `Label(label, systemImage: "doc.text")`; search results
  show the page label, its group path ("Data structures › …", `.caption` `.secondary`) and an excerpt. Page: a top row
  with a borderless back button `Label(<group label>, systemImage: "chevron.left")` (`.help("Back to All Tutorials")`),
  `Divider()`, then a `ScrollView` with the manifest label in `.title2.weight(.semibold)` (not uppercase) and
  `MarkdownView` (system text styles). Bottom bar: "Previous" / `Menu("\(i) of \(n)")` / "Next"
  (`.controlSize(.small)`).
- **Content.** Pages are bundled Markdown files listed in `Resources/Tutorials/manifest.json`. Pages link to each other
  with relative `.md` paths (`hashes.md`, `../sq/indexing.md`), which open in the pane; `https` links open in the
  browser. Each file starts with `# <manifest label>`; the page view drops that heading at render time because it shows
  the manifest label as the title. Module requirements come from the commands in each code block
  (`session.capabilities.missingModule(for:)`), not from the manifest.
- **Code blocks.** Use `MarkdownCodeView` with a label (`.caption.weight(.semibold)`), trailing "Copy" and "Run" borderless
  buttons (Run → `.help` that explains where results appear, disabled on production), code in monospaced text on
  `.background(.quaternary, in: .rect(cornerRadius: 6))`. Run confirmation for tutorials that change data =
  `.confirmationDialog("Run Commands?", …)` with buttons "Run", "Change Database", Cancel and
  `.dialogSuppressionToggle("Don't ask again for this database", …)`.
- **States.** While loading, show `ProgressView()`. For page errors, show `ContentUnavailableView("Tutorial Unavailable", systemImage:
  "doc.questionmark")` with the action "Show All Tutorials".
- **Excluded controls.** Do not use uppercase titles, a bordered root group, slide-in transitions, skeletons.

### 3.27 CLI (Workbench, CLIFeature)

- **Pattern.** Use Terminal and Xcode debug console.
- **Layout.** Use a bottom panel pane. Pane header (28 pt, `.controlSize(.small)`): `Text("CLI").font(.headline)`,
  Spacer, "Clear" (`clear`, ⌘K while the CLI has focus). Below: output (`CLIOutputTextView`, NSTextView, monospaced
  `EditorAppearance.font()`, background `EditorAppearance.background`, selectable), then the input row (prompt `>` or
  `[dbN] >` in `.secondary`, `CommandLineField`, dim argument hint in `.tertiary`).
- **Colors.** Display command echoes in `.labelColor` bold, replies `EditorAppearance.text`, errors
  `EditorAppearance.error`, "Workbench" link uses `.linkColor`.
- **Keyboard.** Support these controls:
  - ↑ and ↓ navigate the last 20 distinct inputs.
  - Tab and ⇧Tab cycle command name completions.
  - ⌘K, ⌃L, and the command `clear` clear output.
  - Clicking output focuses the input.
  - Esc moves focus out of the input.
- **Excluded controls.** Do not use hex CLI colors, a custom header with minimize/close.

### 3.28 Command Helper (inspector pane) (Workbench, CLIFeature)

- **Pattern.** Use Xcode Quick Help inspector.
- **Layout.** Build the top row with `SearchField` (prompt "Search Commands") + group filter `Menu` (`line.3.horizontal.decrease.circle`,
  items = groups with checkmark, "All Groups"). Searching: `List(results)` `.listStyle(.plain)`, row = command name
  (`.body.monospaced().weight(.semibold)`) over syntax/summary (`.callout`, `.secondary`, one line).
  Details (selected or typed in CLI): `ScrollView` with syntax (`.body.monospaced()`, `.textSelection(.enabled)`),
  summary, `LabeledContent` rows "Group", "Complexity", "Since", section "Arguments" (each argument line with
  "Required"/"Optional"/"Multiple" as `.caption` `.secondary` text), `Link("Read More", destination:)`. A borderless
  "Back" (`chevron.left`) returns to results.
- **States.** By default, show `ContentUnavailableView("Command Helper", systemImage: "book", description: Text("Type a
  command in the CLI or search to see its documentation."))`. If search returns no results, show `.search(text:)`.
- **Excluded controls.** Do not use colored group badges, underlined link rows, a complexity badge.

### 3.29 Settings pages (SettingsFeature)

The General tab contains these sections:

- **Appearance** uses `Picker("Appearance", selection:) { Text("System"); Text("Light"); Text("Dark") }.pickerStyle(.radioGroup)`.
  Changes apply immediately.
- **Date and Time** contains a Format menu with four presets and "Custom".
  If Custom is selected, show a monospaced Custom Format field. Submit applies
  the format. Errors appear inline. Add a Time Zone picker with System and UTC.
  Show the formatted current time in `LabeledContent("Preview") { Text(now formatted) }`.
- An untitled section contains the default-on "Hold ⌘Q to quit" toggle
  from section 2.8. Its footer reads "A short press of ⌘Q shows a reminder
  instead of quitting. Quit in the menu bar or the Dock still quits at once."
- Another untitled section contains the default-on "Quit when the last window
  closes" toggle from section 2.8. Its footer reads "Closing the last window
  quits Keystrand instead of leaving it running in the background. If a
  database is still connected, Keystrand asks first."
- The final untitled section uses `LabeledContent("Version", value: "<version> (<build>)")`.
  Its `.footnote`, `.secondary` footer reads "MIT License · Help > Acknowledgements for
  third-party notices".

The Workbench tab contains these sections:

- **Editor** contains the "Empty the editor once commands run" toggle.
- **Pipeline** uses `LabeledContent("Commands per pipeline") { TextField(value:format:.number).frame(width: 80) }`.
  Its footer reads "Sets the batch size for pipelined commands. 0 or 1 sends
  each command separately." Add `Link("Learn About Pipelining")`.

The Advanced tab starts with an untitled section containing only
`InlineMessage("Change these settings only if you understand their impact.", kind: .warning)`.
Its Browser section uses `LabeledContent("Keys to scan") { TextField(value:, format: .number) }`.
The footer reads "Keys scanned per iteration. Values below 500 are raised to 500."

Numeric settings use plain `TextField`s. Commit on Return or focus loss.
Revert invalid input. Do not add pencil or ✓/✕ controls. Do not add Privacy
or About tabs, custom themes, or custom section headers.

### 3.30 Overview metrics and database info popover (SettingsFeature)

- **OverviewBarView(session:)** renders only the compact metric text described in 2.3.3 (no icons per metric, no
  separators views, no refresh control). Tooltips: each metric run has `.help` with details (Commands/s with network in
  and out; Total Keys per database).
- **DatabaseInfoPopover(session:)** (width 340): grouped `Form` with sections: header (database name `.headline`,
  `host:port` `.secondary`), "Connection" (`LabeledContent` Type, Redis Version, User ("Default"), Logical Databases),
  "Modules" (one `LabeledContent(name) { Text("v. x.y.z") }` each), "Metrics" (`LabeledContent` CPU, Commands/s,
  Network Input, Network Output, Memory, Keys, Clients), "Refresh" (Toggle "Auto refresh" + Picker "Every" 1, 2, 5,
  10, 30, 60 seconds, from `AutoRefreshMenu` state with postfix `overview`), and a bottom row with "Edit Database…".
- **Excluded controls.** Do not use a metrics bar with dividers and per-item popovers, an overview auto-refresh chevron, a red info icon.

### 3.31 Database Analysis and Tips (Analytics)

- **Pattern.** Use System Settings > General > Storage (summary charts + lists) and Activity Monitor bottom summary.
- **Section items:** 1. `Picker` segmented "Summary" | "Tips (3)", 2. report history `Picker` (`.menu`,
  label = selected report date "Oct 3, 2026 at 14:02", items `[db1] <date>`; hidden when no reports), 3. "New Report"
  (`Label("New Report", systemImage: "play.fill")`, disabled while analyzing, `.help` explaining that the analysis covers up to 10,000 keys, per shard on clusters).
- **Summary layout.** Use `ScrollView` → `VStack(alignment: .leading, spacing: 24)`, padding 20, max width 1100 centered.
  First a progress line: "Scanned 100% (8,213 of 8,213 keys)" `.callout` (`.orange` when partial) with
  `ProgressView(value:)` while analyzing. Then sections, each = header `HStack { Text(title).font(.title3.weight(
  .semibold)); Spacer(); controls }` + content, sections separated by `Divider()`:
  - "Summary by Data Type": two `DonutChartView`s (Memory, Keys) side by side (`ViewThatFits` stacks them), slices tinted
    `KeyType.tint`; Toggle "Extrapolate results" (`.toggleStyle(.switch)`, `.controlSize(.small)`).
  - "Memory by Time to Expire": `BarChartView` (Swift Charts, height 240), toggles "Extrapolate" and "Show No Expiry".
  - "Top Namespaces": segmented `Picker` "By Memory" | "By Keys", Extrapolate toggle; `Table` (fixed height for up to
    15 rows) with disclosure for multi-type namespaces via `OutlineGroup`-backed `Table(children:)`; columns Key Pattern,
    Data Type (`KeyTypeIcon`s), Total Memory, Total Keys. Double-click a pattern opens it in Browser.
  - "Top Keys": segmented "By Memory" | "By Length"; `Table` columns Type (`KeyTypeIcon`), Key Name, TTL, Size,
    Length; large values in `.orange` semibold with `.help("Large key; splitting it into smaller keys may help")`.
- **Tips layout.** Use `List` `.listStyle(.inset)` of `DisclosureGroup` rows (expanded by default): title `.headline`,
  trailing category symbols (`chevron.left.forwardslash.chevron.right` Code Changes, `gearshape` Configuration Changes,
  `arrow.up.circle` Upgrade) with `.help`; body = rich text (MarkdownView-like rendering of recommendations JSON), key
  example in monospaced text with a `CopyButton`. A legend is not shown (the `.help` tooltips replace it).
- **States.** If no reports exist, show `ContentUnavailableView { Label("No Reports", systemImage: "chart.pie") } description: {
  Text("Sample up to 10,000 keys for a memory breakdown and tips on saving space.") } actions: {
  Button("New Report") }`. If no keys exist, show `ContentUnavailableView("No Keys to Analyze", systemImage: "key")` with action
  "Open Workbench". For an unreadable report, show `ContentUnavailableView("Report Unavailable", systemImage:
  "exclamationmark.triangle", description: Text("Re-run the analysis to create a new report."))`. If no tips exist, show
  `ContentUnavailableView("No Tips", systemImage: "checkmark.seal", description: Text("Keep up the good work."))`.
  While loading, center `ProgressView()`.
- **Tips inspector pane** (`TipsPanelView`): `List` of `DisclosureGroup`s (expanded when unread) with context menu
  "Hide Tip" / "Show Tip", "Snooze" (delete); bottom row Toggle "Show hidden tips" (`.checkbox`, only when hidden tips
  exist); footer button "Analyze Database" → confirmation "Run Database Analysis?" then navigates. Welcome state =
  `ContentUnavailableView("No Tips Yet", systemImage: "lightbulb", …)` with action "Analyze Database".
- **Excluded controls.** Do not use rounded section panels, all-caps section titles, a "Report generated on:" label, skeletons,
  illustrations, vote buttons, a badge legend row, a dashed key box.

### 3.32 Slow Log (Analytics)

- **Pattern.** Use Console log table and Activity Monitor table.
- **Layout.** Use `Table` (columns Timestamp, Duration (ms or µs per unit, header "Duration (ms)"), Command
  (`MonospacedCell`)) sortable, `.tableStyle(.inset(alternatesRowBackgrounds: true))`, filling the detail column, then
  `Divider()` and a `StatusBar`: "12 entries since 13:40:01 · Logging commands slower than 10 ms · Max length 128".
- **Section items:** 1. `Picker("Show", selection:)` `.menu` "10", "25", "50", "100", "Max" (label "Show 50" /
  per-node wording for clusters in `.help`), 2. "Configure…" (`gearshape`, with a popover containing a grouped `Form` 380 wide and
  TextField "Log commands slower than" + Picker unit µs/ms + converted helper text, TextField "Max length", footer
  "This changes the server configuration.", buttons "Defaults", "Cancel", "Save"; clusters show text explaining that each node is configured separately with `CONFIG SET` and
  "OK"), 3. "Clear Slow Log…" (`trash`) → `.destructiveConfirmation("Clear Slow Log?", message: "The Slow Log will be
  cleared for <db>. This changes the server state.", confirmTitle: "Clear")`, 4. `AutoRefreshMenu(postfix: "slowlog",
  persistsEnabledState: false)`.
- **Context menu.** Include "Copy Command", "Open in Workbench".
- **States.** For an empty log, show `ContentUnavailableView { Label("No Slow Log Entries", systemImage: "tortoise") } description: {
  Text("No commands took longer than 10 ms, or the Slow Log is disabled.") }`. Keep rows visible during loading. Show a spinner in the
  refresh control. Show errors as alerts.
- **Excluded controls.** Do not use a large "Slow Log" page title, a header info line, an eraser icon, a modal sheet confirmation, an info
  tooltip icon.

### 3.33 Cluster Details (Analytics)

- **Pattern.** Use Activity Monitor (summary row + process table).
- **Layout.** Use `VStack(spacing: 0)`: header `Grid` of `LabeledContent` (Type, Version, User, Uptime) padding 16; two
  `DonutChartView`s (Memory, Keys by node; default chart palette; legend shows `A: host:port`); `Table` of primary nodes
  (Node (colored `Circle` 8 pt from the chart palette + letter + host:port), Commands/s, Network In, Network Out, Memory,
  Keys, Clients; unique column maximum in `.semibold`).
- **States.** On first load, show `ProgressView()` centered. If node details are unavailable, show `ContentUnavailableView("No Node Details",
  systemImage: "server.rack", description: Text("This cluster didn't report any primary
  nodes."))`.
- **Excluded controls.** Do not use a custom node color scheme, a value-above-label metric layout, skeletons.

### 3.34 Pub/Sub (Analytics, MonitoringFeature)

- **Pattern.** Use Console streaming log + Messages compose bar.

```text
toolbar: … [ *            ] [((•)) Subscribe] [🗑]  │ [db0 ▾] │ [▭] [◨]
┌──────────────────────────────────────────────────────────────────────────────┐
│ Time ▼          Channel        Message                                        │
│ 14:02:11.120    orders         {"id":42,"total":19.99}                        │
│ 14:02:10.004    orders         {"id":41,"total":5.00}                         │
├──────────────────────────────────────────────────────────────────────────────┤
│ Subscribed to all channels · 42 messages                                      │
├──────────────────────────────────────────────────────────────────────────────┤
│ [Channel          ] [Message                                      ] [Publish] │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Layout.** Use `VStack(spacing: 0)`: messages `Table` (Time, Channel, Message (`MonospacedCell`, `.help` full text))
  sortable, newest first, at most 5,000 rows, no pagination; `Divider()`; `StatusBar` ("Subscribed to all channels ·
  42 messages" / "Not subscribed"); `Divider()`; compose bar (padding 12, `.controlSize(.regular)`): `TextField(
  "Channel")` width 200, `TextField("Message")` flexible, `Button("Publish")` (default action when either field has
  focus). After publishing, the compose bar shows the publish result ("Published to 2 clients").
- **Section items:** 1. `TextField("Patterns", text:)` width 180 with prompt "*" (disabled while subscribed), 2.
  Subscribe toggle `Button { } label: { Label(isSubscribed ? "Unsubscribe" : "Subscribe", systemImage: isSubscribed ?
  "stop.circle" : "dot.radiowaves.left.and.right") }`, 3. "Clear Messages" (`trash`, enabled with messages).
- **Context menu (rows).** Include "Copy Message", "Copy Channel".
- **States.** If unsubscribed with no messages, show `ContentUnavailableView { Label("Not Subscribed", systemImage:
  "dot.radiowaves.left.and.right") } description: { Text("Subscribe to see messages published to this database.
  Subscribing on production may reduce performance.") } actions: { Button("Subscribe") }` (cluster ≥ 7.0 appends
  "Messages published with SPUBLISH do not appear here."). If subscribed with no messages, show
  `ContentUnavailableView("No Messages Yet", systemImage: "tray")`. If the connection drops, show status and an alert reading "No connection to
  the Redis database."
- **Excluded controls.** Do not use a paginated table, a status badge, a patterns info icon, a warning callout, a footer with top border
  styling, a green check button.

### 3.35 Profiler (Analytics, MonitoringFeature)

- **Pattern.** Use Console streaming and Instruments recording controls.
- **Layout.** Use a bottom panel pane. Pane header (28 pt): `Text("Profiler").font(.headline)`, then
  `Button { } label: { Label(state.title, systemImage:) }` toggling Start (`record.circle`) / Pause (`pause.circle`) /
  Resume (`play.circle`) (Resume disabled with `.help` after connection loss), "Clear" (`trash`), Spacer, Toggle "Save
  Log" (`.checkbox`, only before starting), "Save Log…" (`square.and.arrow.down`, when paused with Save Log on),
  "Reset" (`arrow.counterclockwise`, when paused). Output: monospaced `VirtualizedTextLinesView` (auto-scroll),
  command token in `.labelColor` semibold, the rest `.secondary`. Paused summary in a `StatusBar`: "14:01:02 – 14:03:10
  · 2 min 8 s running time". A `JumpToLatestButton` floats bottom-trailing when the user scrolled up (glass, see 7).
- **States.** Before profiling starts, show `ContentUnavailableView { Label("Profiler", systemImage: "waveform.path.ecg") }
  description: { Text("Analyze every command sent to Redis in real time. Profiling decreases throughput; avoid running
  it on production.") } actions: { Button("Start Profiler") }`. After profiling starts, if no lines exist, show `ProgressView("Waiting for
  commands…")`. If permission is missing, show `ContentUnavailableView("Profiler Unavailable", systemImage: "nosign", description:
  Text("This user has no permission to run MONITOR."))`. Before profiling a production database, show confirmation "Start Profiler on a
  Production Database?" / "Run".
- **Excluded controls.** Do not use a two-column illustration layout, a warning banner, a red error panel, a custom header with
  minimize/close.

### 3.36 Vector Search (Vector Search)

- **Pattern.** Use Xcode Organizer (a list that opens detail pages with a back button) and Finder Get Info (⌘I).
- **Navigation.** `VectorSearchStack` switches among the index list or welcome
  state, query page, and Create Index page in the detail column. Switch pages
  in place. Do not use `NavigationStack`, which hides AppShell's toolbar items.
  Do not add a breadcrumb. The Create Index page's first section item is a back button `Label("Indexes", systemImage:
  "chevron.left")` with `.help("Back to Indexes")`; the query page's index menu ends with "Show All Indexes".
- **Gates.** Show `ProgressView()` while modules load. If Search is missing, show `ContentUnavailableView { Label("Redis Search Not
  Available", systemImage: "sparkle.magnifyingglass") } description: { Text("Redis Search adds querying, secondary
  indexes, full-text and vector search.") }`. If the version is below 2.0, show `ContentUnavailableView { Label("Redis Search Version Too Old", systemImage:
  "sparkle.magnifyingglass") } description: { Text("Vector Search uses Redis Search commands introduced in version 2.0.
  Redis 6 and later include a compatible version.") }`.
- **Welcome.** If no indexes exist, show `ContentUnavailableView { Label("Search Your Data", systemImage: "sparkle.magnifyingglass") }
  description: { Text("Full-text, vector and hybrid search at in-memory speed.") } actions: { Button("Try Sample
  Data…"); Button("Create Index…") }`. Do not add feature tiles.
- **Index list.** Use a `Table` (Name, Prefix, Types (plain text "TEXT, VECTOR"), Docs, Records, Terms, Fields; numeric
  columns `.monospacedDigit()` trailing; column header `.help` texts), sortable, double-click → Query.
  `.searchable(prompt: "Search Indexes")`. Section items: 1. Create menu `Menu { "Use Sample Data…"; "Use Existing
  Data…" } label: { Label("Create Index", systemImage: "plus") }`, 2. "Get Info" (`info.circle`, ⌘I, selected row),
  3. `Button` refresh (`arrow.clockwise`). Context menu: "Query", "Get Info", "Browse Dataset", divider, "Delete
  Index…" (`.destructiveConfirmation("Delete “idx”?", message: "The index will be removed. Your data is not
  deleted.", confirmTitle: "Delete Index")`). Redis < 7.2 notice: `InlineMessage(kind: .info)` above the table.
- **Index info (Get Info).** Open a Large sheet titled "Index “name”". Show `Text` summary lines (indexed type and prefixes, options, document, record and term counts) and an attributes `Table`
  (flags as checkmark / xmark symbols), footer "Done".
- **Query page.** Use `HSplitView { VSplitView { editor ; results } ; IndexInfoPane (toggle, min 260) }`. Section items: 1.
  index `Picker` (`.menu`, switches index), 2. `Picker` segmented "Editor" | "Library", 3. "Index Info" `Toggle` with
  `Label("Index Info", systemImage: "list.bullet.rectangle")` and `.toggleStyle(.button)`, 4. `Menu { "Save Query…";
  divider; "Explain"; "Profile" } label: { Label("More", systemImage: "ellipsis.circle") }` (disabled reasons as
  `.help` on the items), 5. "Run" (`.glassProminent`, ⌘↩). Results reuse the Workbench result list rules (3.24).
- **Query library.** Use `List` `.listStyle(.inset)` rows: name (`.headline`) + description (`.secondary`) + kind
  (`Text("Sample")`/`Text("Saved")` `.caption` `.secondary`), `DisclosureGroup` body with the read-only query
  (`CodeEditorView`, isEditable false). Row actions: borderless "Load" and "Run"; context menu adds "Copy Name",
  "Delete Query…". `SearchField` at top when items exist. Empty: `ContentUnavailableView("No Saved Queries", systemImage:
  "books.vertical", description: Text("Save a query from the editor to add it here."))`.
- **Save query.** Use a Small sheet "Save Query" with TextField "Name", footer Cancel / "Save".
- **Pick sample data.** Use a Large sheet "Choose Sample Data": `List` with two selectable rows (title `.headline`, description
  `.secondary`, `Image(systemName: dataset.symbolName)`): "Trail Finder" ("Find hikes that match a mood or a scene, not
  just keywords.", `figure.hiking`) and "Recipe Recommendations" ("Discover dishes by flavor, diet, or occasion.",
  `fork.knife`); footer leading "See Index Definition", trailing Cancel / "Start Querying" (default).
- **Create index page.** Use `HSplitView { keys browser (List .sidebar style, segmented HASH | JSON, StatusBar with Scan
  More), schema }`. Schema: title row `TextField` for the index name (`.title3`, plain style, commit on Return) and
  `TextField("Prefix")`; `Picker` segmented "Table" | "Command" as section item 1; section items 2 "Add Field…" (`plus`),
  3 "Create Index" (`.glassProminent`, disabled with `.help` reason). Table: checkbox column, Field, Sample Value,
  Type (plain text), edit via double-click → Small sheet "Edit Field" (grouped Form; VECTOR / TEXT option sections).
  Command view: read-only `CodeEditorView` + Copy. Unsaved-changes switch: `.confirmationDialog("Discard Field
  Changes?", …)` with "Discard and Load" / "Keep Editing". Before any key is chosen:
  `ContentUnavailableView("Select a Key", systemImage: "key", description: Text("Choose a key on the left to suggest
  an indexing schema."))`.
- **Excluded controls.** Do not use a bordered card around the schema, onboarding tours and popovers, a breadcrumb, colored type badges,
  feature tiles, illustration fallbacks, a right panel with percentage widths.

### 3.37 Keyboard Shortcuts window (SettingsFeature)

- **Pattern.** Use Xcode Settings > Key Bindings.
- **Layout.** Build `KeyboardShortcutsView()` with a `List` `.listStyle(.inset(alternatesRowBackgrounds: true))` with `Section`s
  "Application", "Database Window", "Browser", "Vector Search", "Workbench", "CLI"; rows `LabeledContent(description) {
  Text(shortcut).font(.body.monospaced()) }`; `.searchable(prompt: "Search Shortcuts")`. Content is the shortcut table in
  section 8.9 (single source of truth; add a unit test that the view's data matches `AppCommands` shortcuts for the
  menu items).
- **Excluded controls.** Do not use a two-column custom table, hex colors.

### 3.38 Acknowledgements window (SettingsFeature)

- **Pattern.** Use the standard macOS acknowledgements window with plain,
  scrolling, selectable text.
- **Entry.** **Help > Acknowledgements** opens `Window("Acknowledgements", id:
  AppWindowID.acknowledgements)` without a shortcut (section 2.1). The About panel's credits end with "Choose Help > Acknowledgements for
  the full notices." and the Settings General page footer points here too.
- **Layout.** `AcknowledgementsView()` loads `THIRD_PARTY_NOTICES.md`, `LICENSE` and `LICENSES/*.txt` from
  `Bundle.main`'s Resources. One `ScrollView`, padded: the notices rendered by RedisUI `MarkdownView`, a `Divider()`, a
  "License Texts" heading (`.title3.weight(.semibold)`), then one `DisclosureGroup` per file, collapsed by default,
  titled "LICENSE" and then `LICENSES/<file>.txt` sorted by name. Each shows the file's plain text in
  `.body.monospaced()` with `.textSelection(.enabled)`.
- **States.** If the notices file is missing, show `ContentUnavailableView("Notices Unavailable", systemImage: "doc.questionmark",
  description: Text("THIRD_PARTY_NOTICES.md isn't in the app bundle."))` in place of the notices. If license files are missing,
  the "License Texts" part is omitted. A missing file never crashes the window.
- **Excluded controls.** Do not use custom fonts, colors, backgrounds or cards; web views.

---

## 4. Component kit (Sources/RedisUI)

### 4.1 Read the tables

Section 4.2 lists the public RedisUI types and their styles. The alternatives
table identifies needs that the kit handles with existing controls.
Source checks in sections 4 and 5 must return no matches unless the check
lists an explicit exception.

### 4.2 Inventory

The following types manage theme and environment in `Sources/RedisUI/Theme`. Section 5 defines colors.

| File | Type | Notes |
| --- | --- | --- |
| Theme.swift | `NSAppearance.isDarkMode` | used by AppKit-backed views to pick appearance-specific drawing; colors stay system colors |
| Theme.swift | `AppTheme.colorScheme`, `AppTheme.appearance` | `nil` follows the system |
| ThemeEnvironment.swift | `ThemeMode` (= `AppTheme`), `ThemeApplier`, `View.appAppearance(_ mode: ThemeMode)` | sets `NSApp.appearance` only; no tint, no palette |
| EditorAppearance.swift | `EditorAppearance` | 4.7 |

Use these components from `Sources/RedisUI/Components`:

| File | Public type | Styling |
| --- | --- | --- |
| AutoRefreshControl.swift | `AutoRefreshMenu`, `AutoRefreshMenu.relative(from:now:)` | 4.10 |
| Badges.swift | `KeyType.tint`, `KeyType.symbolName`, `KeyTypeIcon`, `KeyTypeLabel`, `EnvironmentLabel`, `TagText`, `ModuleSummaryText` | 4.6, 5.4 |
| Badges.swift | `CommandGroupBadge(group:)`, `.displayName(for:)` | renders `Text(displayName)` `.caption` `.secondary`, no fill |
| Basics.swift | `CopyButton(text:/data:/text closure, help:title:)` | borderless, `doc.on.doc` → `checkmark` with `.contentTransition(.symbolEffect(.replace))` for 1 s, accessibility label = help |
| Basics.swift | `TTLText`, `ByteCountText` | `.monospacedDigit()` |
| Basics.swift | `SearchField(text:placeholder:onSubmit:debounce:onDebouncedChange:)` | `NSSearchField` wrapper (`NSViewRepresentable`) |
| Basics.swift | `View.dataTableStyle()` | `.tableStyle(.inset(alternatesRowBackgrounds: true))` only (no font) |
| Basics.swift | `MonospacedCell(_:)` | `.body.monospaced()` |
| Charts.swift | `DonutSlice`, `DonutChartView`, `BarDatum`, `BarChartView` | Swift Charts; `color` optional (nil = chart palette); no hex |
| Confirmations.swift | `View.destructiveConfirmation`, `View.productionConfirmations(_:)`, `View.sheetAlerts` | 4.4 |
| Confirmations.swift | `View.nonUnicodeEditGuard(isPresented:formatName:onEditAnyway:onChangeToUnicode:)` | `.alert("Edit a Non-Unicode Value?")` with "Change to Unicode" (default), "Edit Anyway", "Cancel" |
| JSONTreeView.swift | `JSONTreeActions`, `JSONTreeView` | 4.8 |
| KeyDetailsBlocks.swift | `KeySubheaderBar` | 3.13 |
| KeyDetailsBlocks.swift | `AddItemsButton(_:help:action:)` | callers pass the title without an ellipsis ("Add Fields"); renders `Button(title + "…", systemImage: "plus")`, borderless; title visible ≥ 560 pt, icon only below with `.help(title)` |
| KeyDetailsBlocks.swift | `FormattedValueCell` | monospaced, `.help` "Failed to convert to \<format\>" |
| KeyDetailsBlocks.swift | `EditableTextCell` | edit on double-click / Return; no hover pencil, no ✓/✗ buttons (Return saves, Esc cancels) |
| KeyDetailsBlocks.swift | `CommandPreviewBar(command:isExpanded:)` | monospaced selectable text + `CopyButton`, no background |
| KeyDetailsBlocks.swift | `MultiRowFormList` | rows in a `Grid`; trailing `minus.circle` / `plus.circle` borderless buttons (Mail rules editor) |
| KeyDetailsBlocks.swift | `RangeSliderView` | track `.quaternary`, range `.tint`, system thumb look (`Circle` with `.shadow(radius: 1)` and `.background` fill `Color(nsColor: .controlColor)`) |
| KeyDetailsBlocks.swift | `VirtualizedTextLinesView` | monospaced via `EditorAppearance.font()` |
| AppSupport.swift | `QALaunchOptions`, `EditorRunAction`, `FocusedValues.editorRunAction`, `ChartPalette` | 4.12, 4.13 |
| ErrorAlerts.swift | `ErrorAlerts`, `View.errorAlerts(_:)` | 4.3, 4.4 |
| KeyEditors.swift | `RenameKeyForm`, `TTLField`, `SetTTLPopover` | 3.12 |
| Sheets.swift | `SheetForm`, `SheetSize`, `View.sheetSize(_:)`, `FilePickerRow`, `JumpToLatestButton` | 4.11 |
| States.swift | `ErrorStateView`, `InlineMessage`, `StatusBar`, `LoadMoreRow` | 4.9 |
| ValueFormatPicker.swift | `ValueFormatPicker(selection:compact:)` | `.pickerStyle(.menu)`, title "Format" |

Use these existing controls for needs without a dedicated kit type:

| Need | Use |
| --- | --- |
| A color | system semantic colors (section 5); `EditorAppearance` in editors, the CLI and the Profiler |
| A key type, environment, tag or module badge | `KeyTypeIcon` / `KeyTypeLabel`, `EnvironmentLabel`, `TagText`, `ModuleSummaryText` |
| An empty, failed or not-yet-available state | `ContentUnavailableView` directly, or `ErrorStateView` |
| An icon-only button | `Button(title, systemImage:)` + `.labelStyle(.iconOnly)` + `.help`; `.buttonStyle(.borderless)` outside toolbars |
| An error banner | `InlineMessage(_:kind: .error)` or `ErrorStateView` |
| Inline editable text | `TextField` committing on submit, or `EditableTextCell` in tables |
| A sheet frame | `SheetForm` + `.sheetSize(_:)` |
| A destructive confirmation | `.destructiveConfirmation` (never a popover) |
| Typing to confirm a production write | the alert in `productionConfirmations` (4.4) |
| A file drop zone | `FilePickerRow` |
| A progress overlay, loading bar or skeleton | `ProgressView` in place (centered, `.linear`, or `.controlSize(.small)`), or `AutoRefreshMenu(isLoading:)` |
| Pagination | infinite loading + `LoadMoreRow` (4.9) |
| A resizable split | `HSplitView` / `VSplitView` (4.5) |
| A toast | nothing for success; errors as alerts through AppShell's `View.shellStatusAlerts(_:)` (4.3) |
| A panel or card background | nothing (no panels) |

Use these types from `Sources/RedisUI/Editor`, `JSON`, and `Markdown`:

| Type | Notes |
| --- | --- |
| `CodeEditorView` (all parameters), `CodeEditorController`, `CodeLanguage`, `CodeCompletion`, `CodeSignatureHint`, `CodeEditorText`, `CodeSnippet` | appearance from `EditorAppearance` (4.7) |
| `CommandLineField` | `EditorAppearance` font and colors |
| `RedisSyntaxHighlighter`, `SyntaxToken`, `SyntaxTokenKind` | colors from `EditorAppearance.Syntax` |
| `JSONTreeModel`, `JSONTreeNode`, `JSONTreeRow`, `JSONTreeFlattener`, `JSONLiteral`, `JSONTreeMember`, `JSONContainerKind`, `JSONPath`, `JSONPathComponent`, `JSONPathParseError` | — |
| `MarkdownView`, `MarkdownCodeView`, `MarkdownParser`, `MarkdownBlock`, `MarkdownCodeBlock`, `MarkdownListItem`, `MarkdownTableAlignment`, `SyntaxAttributedString` | system text styles; code blocks per 3.26; also renders the Acknowledgements window (3.38) |
| `Exports.swift` (`@_exported import RedisCore`) | — |

### 4.3 Status presentation

Do not show transient status messages. Present action results according to these rules:

- **Success with a visible result reports nothing.** Examples are a deleted row that disappears, a key that is added
  and selected, a closed save panel, a library list that updates, or a new database row that is selected and marked
  New. Copy commands also report nothing.
- **A result that is not visible shows inline where the user acted.** It stays in the sheet, popover or bar that
  started the action:
  - Test Connection: `SheetForm(successMessage:)` shows `InlineMessage(kind: .success)` in the slot above the footer.
    `errorMessage` uses the same slot and wins over `successMessage`.
  - Stream Claim and Auto Claim: when nothing was idle long enough, the popover stays open and its section footer shows
    `InlineMessage("None of the pending messages has been idle long enough.")`. Otherwise the popover closes.
  - Pub/Sub Publish: the publish bar shows "Published to 2 clients" beside the Publish button for 3 seconds.
  - Bulk Actions: the sheet shows the summary (processed, succeeded, failed, time).
- **A rejected action beeps.** For example, Run while the Workbench is already running calls `NSSound.beep()`.
- **Failures the user caused are alerts.** `ToastCenter` (RedisCore) is an error queue: `toasts.error(_:title:)` adds
  one, and AppShell's `.shellStatusAlerts(_:)` on the Home and database windows presents them one at a time (title,
  message, "OK", and "Save Full Log…" for messages longer than 400 characters). Sheets present them with
  `.sheetAlerts(session)`. Nothing closes an error alert but the user, and dismissing an alert dismisses that error.
  App-wide errors (`services.toasts`) bring the Home window forward, which presents them. Background work (polling, auto-refresh, overview, cluster details polling, live tips) shows failures inline
  (activity view warning symbol, `InlineMessage`, `ErrorStateView`) and does not call `toasts.error`.

### 4.4 Confirmations

```swift
public extension View {
    /// `.confirmationDialog` with a visible title, a destructive button and Cancel.
    func destructiveConfirmation(_ title: String, isPresented: Binding<Bool>, message: String? = nil,
                                 confirmTitle: String = "Delete", isSuppressed: Binding<Bool>? = nil,
                                 onConfirm: @escaping @MainActor () -> Void) -> some View

    /// Item-driven variant: presents while `item` is non-nil.
    func destructiveConfirmation<Item: Identifiable>(item: Binding<Item?>, title: @escaping (Item) -> String,
                                                     message: @escaping (Item) -> String? = { _ in nil },
                                                     confirmTitle: String = "Delete",
                                                     onConfirm: @escaping @MainActor (Item) -> Void) -> some View

    /// Production confirmations of a session.
    /// requiresTyping == false → confirmationDialog (+ dialogSuppressionToggle when actionID != nil).
    /// requiresTyping == true  → alert with TextField, disabled destructive button, dialogSeverity(.critical).
    func productionConfirmations(_ center: ConfirmationCenter) -> some View

    /// Production confirmations and error alerts of a session, presented inside a sheet. Apply to the root view of
    /// every sheet whose content may call `session.confirm`, `confirmProduction` or `session.toasts.error`.
    func sheetAlerts(_ session: DatabaseSession) -> some View
    func sheetAlerts(confirmations: ConfirmationCenter, errors: ToastCenter) -> some View

    /// Error alerts of a window root (AppShell's `.shellStatusAlerts`).
    func errorAlerts(_ center: ToastCenter) -> some View
}
```

Attach dialogs to invisible background views. A new or resolved request then
leaves the content structure unchanged.

Use the following content for an alert that requires a typed confirmation:

```text
Title:   request.title                         (e.g. "Production Database: Check Before Running")
Message: request.message (inline Markdown)
         Type “<confirmationText>” to confirm.
         Tip: Restrict dangerous commands per user with Redis ACLs.
Fields:  TextField(confirmationText, text: $typed)
Buttons: request.confirmButtonTitle (role: .destructive, disabled until exact match), Cancel (role: .cancel)
Toggle:  .dialogSuppressionToggle("Don't ask again this session", isSuppressed: $skip) when actionID != nil
```

`ConfirmationCenter` and its callers manage the Development bypass and session skips.

### 4.5 Native split views

- `HSplitView` / `VSplitView` only. Minimum sizes via `.frame(minWidth:)` / `.frame(minHeight:)` on the children,
  ideal sizes via `idealWidth` / `idealHeight`.
- Size persistence is optional; when a size is persisted (bottom panel, Browser list width, hash field column), it is
  read once into `idealWidth`/`idealHeight` and written with `onGeometryChange` debounced 0.5 s.
`grep -rn 'DragGesture' Sources/AppShell` must match only `DrawerDivider`
for the bottom panel in section 2.3.5.

### 4.6 Badges, labels and key details blocks

```swift
public extension KeyType {
    var tint: Color { get }          // section 5.4
    var symbolName: String { get }   // section 5.4
}

/// System Settings–style tile: rounded rect (radius 4 small, 5 regular, 7 large) filled with `type.tint.gradient`,
/// white symbol `type.symbolName` at 60% of the tile size, `.accessibilityLabel(type.displayName)`.
public struct KeyTypeIcon: View {
    public enum Size: Sendable { case small /*16*/, regular /*20*/, large /*28*/ }
    public init(type: KeyType, size: Size = .small)
}

/// `Label { Text(type.displayName) } icon: { KeyTypeIcon(type: type) }`.
public struct KeyTypeLabel: View { public init(type: KeyType, size: KeyTypeIcon.Size = .small) }

/// Production: `Label("Production", systemImage: "exclamationmark.shield.fill")` tinted `.red`;
/// Development: `Label("Development", systemImage: "hammer.fill")` tinted `.secondary`; unspecified: EmptyView.
public struct EnvironmentLabel: View {
    public init(environment: DatabaseEnvironment, style: Style = .titleAndIcon)
    public enum Style: Sendable { case titleAndIcon, iconOnly }
}

/// "team: core, app: web" (plain text, middle truncation, `.help` lists all tags one per line).
public struct TagText: View { public init(tags: [DatabaseTag]) ; public init(tag: DatabaseTag) }

/// "Search, JSON, Time Series +2" with `.help` "<Name> v. <version>" per line.
public struct ModuleSummaryText: View { public init(modules: [RedisModuleInfo], maxVisible: Int = 3) }

/// One row of LabeledContent pairs for the key details header; wraps to a 2-column Grid below 560 pt.
public struct KeyMetadataItem: Identifiable, Sendable {
    public init(label: String, value: String, help: String? = nil)
}
public struct KeyMetadataRow: View { public init(items: [KeyMetadataItem]) }
```

- Generic chips and colored capsules are not part of the kit. Category text (field types, command groups, argument
  kinds, query kinds) is plain `Text` in `.caption`/`.callout` with `.secondary` or a semantic tint as foreground only.
`grep -rn 'Capsule()' Sources/Features` must return no matches.

### 4.7 Editor appearance

```swift
public enum EditorAppearance {
    /// Allowed explicit background for code editors, CLI output and Profiler output.
    public static var background: Color { get }           // Color(nsColor: .textBackgroundColor)
    public static var nsBackground: NSColor { get }        // .textBackgroundColor
    public static var text: Color { get }                  // Color(nsColor: .textColor)
    public static var secondaryText: Color { get }         // .secondaryLabelColor
    public static var error: Color { get }                 // Color(nsColor: .systemRed)
    public static var success: Color { get }               // Color(nsColor: .labelColor)
    public static var gutterText: NSColor { get }          // .tertiaryLabelColor
    public static var gutterActiveText: NSColor { get }    // .secondaryLabelColor
    public static var commandMarker: NSColor { get }       // .systemGreen
    /// Editor font. Size defaults to `NSFont.systemFontSize` (13).
    public static func font(size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular) -> NSFont
    public enum Syntax {      // NSColor, resolved by AppKit per appearance
        public static var text: NSColor { get }        // .textColor
        public static var keyword: NSColor { get }     // .systemPink
        public static var function: NSColor { get }    // .systemPurple
        public static var string: NSColor { get }      // .systemRed
        public static var number: NSColor { get }      // .systemBlue
        public static var comment: NSColor { get }     // .secondaryLabelColor
        public static var bracket: NSColor { get }     // .labelColor
        public static var params: NSColor { get }      // .systemOrange
        public static var operatorToken: NSColor { get } // .systemTeal
    }
    public enum JSON {        // SwiftUI Color
        public static var key: Color { get }           // .primary
        public static var arrayKey: Color { get }      // .secondary
        public static var string: Color { get }        // Color(nsColor: .systemRed)
        public static var number: Color { get }        // Color(nsColor: .systemBlue)
        public static var boolean: Color { get }       // Color(nsColor: .systemPink)
        public static var null: Color { get }          // Color(nsColor: .systemPink)
        public static var punctuation: Color { get }   // .secondary
    }
}
```

- The editor uses `NSColor.selectedTextBackgroundColor` for selection and the default insertion point color; it does
  not set them.
- The line-number ruler draws no background of its own other than `EditorAppearance.nsBackground` and a 1 px
  `NSColor.separatorColor` line.

### 4.8 JSON tree

Keep the `JSONTreeView` API. Apply these rules to its contents:

- Rows are built in a `List` (`.listStyle(.plain)`) or a `LazyVStack` inside a `ScrollView`; disclosure uses
  `Image(systemName: "chevron.right")` rotated 90° when expanded (animation suppressed with Reduce Motion), 12 pt per
  indentation level, max 8 levels.
- Text: `.body.monospaced()`, colors from `EditorAppearance.JSON`. Selected row uses the system selection (List
  selection) or `Color(nsColor: .selectedContentBackgroundColor)` with `.white` text when emphasized (LazyVStack case).
- Actions come only from the context menu and keyboard (Return edit, ⌫ delete, ←/→ collapse/expand, ⌘C copy value).
  Do not add hover action buttons or inline "+" rows. `showsToolbar` controls
  `KeySubheaderBar` items. `showsPathBar` controls a monospaced `.footnote` path line.

### 4.9 Empty, error, loading and list continuation

```swift
/// ContentUnavailableView with an exclamation triangle, the message, and an optional "Try Again" action.
public struct ErrorStateView: View {
    public init(title: String = "Unable to Load", message: String, retryTitle: String = "Try Again",
                retry: (@MainActor () -> Void)? = nil)
}

/// Inline, background-free message: Label with a tinted symbol and `.callout` text.
/// info = `info.circle.fill` .blue, warning = `exclamationmark.triangle.fill` .orange, error = `xmark.octagon.fill` .red.
public struct InlineMessage: View {
    public enum Kind: Sendable { case info, warning, error }
    public init(_ text: String, kind: Kind = .info)
}

/// Finder-style status bar: 22 pt, `.footnote`, `.secondary`, padding 12 horizontal; content leading, accessory trailing.
public struct StatusBar<Content: View, Accessory: View>: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory)
}

/// Last row of a cursor-paged list: a small spinner while loading, otherwise a borderless "Load More" button.
/// Also calls `action` from `.onAppear` when `loadsAutomatically` is true.
public struct LoadMoreRow: View {
    public init(title: String = "Load More", isLoading: Bool, loadsAutomatically: Bool = true,
                action: @escaping @MainActor () -> Void)
}
```

- Empty states use `ContentUnavailableView` directly (title in Title Case, one SF Symbol, one-sentence description,
  at most two actions). `ContentUnavailableView.search(text:)` for empty search results.
- Use cursor continuation for `SCAN`, `HSCAN`, `SSCAN`, `ZSCAN`, `XRANGE`,
  `VRANGE`, and `LRANGE` lists. Keep the cursor in the view model. Append each
  page and end the list with `LoadMoreRow`. Unfiltered lists load near the end
  automatically. For wildcard `SCAN` filters, set `loadsAutomatically: false`
  so the user requests each scan. Client-side Pub/Sub, Workbench Clients, and
  Sentinel discovery lists scroll without pagination controls.

### 4.10 Auto-refresh control

```swift
/// Toolbar split button: primary click refreshes; the menu holds "Auto Refresh" (Toggle) and
/// "Refresh Every" (Picker: 1, 2, 5, 10, 30, 60 seconds, "Custom…"). Rate persisted per `postfix` in
/// `settings.ui.autoRefreshRates` (1.0…999.9). Help text: "Refresh (⌘R) · Last refreshed <relative>".
/// Symbol: `arrow.clockwise`; with auto refresh on: `timer`. While `isLoading`, the label is a small ProgressView.
public struct AutoRefreshMenu: View {
    public init(postfix: String, lastRefresh: Date? = nil, isLoading: Bool = false, isDisabled: Bool = false,
                enabledByDefault: Bool = false, minimumRate: Double = 1.0, persistsEnabledState: Bool = true,
                isPaused: Bool = false, onRefresh: @escaping () -> Void)
    public static func relative(from date: Date, now: Date) -> String
}
```

"Custom…" opens an alert with a numeric `TextField` (one decimal, 1.0–999.9).

### 4.11 Sheets, files, and floating controls

```swift
public enum SheetSize: Sendable { case small, form, large }
public extension View { func sheetSize(_ size: SheetSize) -> some View }   // widths and presentationSizing from 2.7

/// Title row, content, inline error or success message, footer (leading actions, Cancel, trailing actions,
/// primary). Primary = default action; isDestructive makes it `role: .destructive` and moves the default action to
/// Cancel. A nil `cancelTitle` leaves out Cancel. Overloads drop `trailingActions`, or both action builders.
public struct SheetForm<Content: View, Leading: View, Trailing: View>: View {
    public init(title: String, primaryTitle: String, isPrimaryDisabled: Bool = false, isWorking: Bool = false,
                isDestructive: Bool = false, cancelTitle: String? = "Cancel", errorMessage: String? = nil,
                successMessage: String? = nil, onCancel: @escaping @MainActor () -> Void,
                onPrimary: @escaping @MainActor () -> Void, @ViewBuilder content: () -> Content,
                @ViewBuilder leadingActions: () -> Leading, @ViewBuilder trailingActions: () -> Trailing)
}

/// "Choose File…" button, chosen file name and size, `.dropDestination(for: URL.self)`; validates type and size.
public struct FilePickerRow: View {
    public init(fileURL: Binding<URL?>, allowedTypes: [UTType] = [.item], prompt: String = "Choose File…",
                maxFileSize: Int? = nil)
}

/// Floating glass button that scrolls a live log to its end (Profiler, CLI, Pub/Sub).
public struct JumpToLatestButton: View { public init(action: @escaping @MainActor () -> Void) }
```

### 4.12 Shared focused value and chart palette

```swift
/// Published with `.focusedSceneValue(\.editorRunAction, …)` by the Workbench and the Vector Search query page;
/// read by AppShell's Database > Run Commands (⌘↩).
public struct EditorRunAction {
    public var canRun: Bool
    public var run: @MainActor () -> Void
    public init(canRun: Bool, run: @escaping @MainActor () -> Void)
}
public extension FocusedValues { var editorRunAction: EditorRunAction? { get set } }

/// Ordered categorical palette matching Swift Charts' default series colors, for non-chart marks that must match a
/// chart series (Cluster Details node dots, legends).
public enum ChartPalette {
    public static let colors: [Color]   // [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .indigo, .mint, .cyan, .brown, .red]
    public static func color(at index: Int) -> Color   // cycles
}
```

Charts that need to match `ChartPalette` set `.chartForegroundStyleScale(domain:range: ChartPalette.colors)` explicitly
so the chart and the table dots agree.

### 4.13 QA launch options

```swift
/// Parses the QA flags of DESIGN.md §9 from ProcessInfo once. Used by AppShell and by features that must open a sheet.
public struct QALaunchOptions: Sendable, Equatable {
    public static let current: QALaunchOptions
    public var home: Bool
    public var addDatabase: Bool
    public var section: String?        // browser|workbench|analysis|slowlog|cluster|pubsub|vectorsearch
    public var tools: [String]         // cli|helper|profiler (flag may repeat)
    public var inspector: String?      // helper|tips|tutorials
    public var key: String?
    public var settingsPage: String?   // general|workbench|advanced ("" = current page, also for unknown names)
    public var shortcuts: Bool
    public var appearance: ThemeMode?  // light|dark
    public var sheet: String?          // new-key|bulk-actions|edit-database|tags|sample-data
    public var windowSize: CGSize?     // WxH, each side at least 200
    public var open: String?           // --open host:port[/db], as given
    public var openID: String?         // --open-id
    public var isActive: Bool          // any QA flag present
    public init(arguments: [String])
}
```

---

## 5. Tokens

### 5.1 Rules

Use system appearance and these styling rules:

- Do not define a theme token type.
  `grep -rn 'Theme\.' Sources/Features Sources/AppShell` must return no matches.
- Do not define hex colors.
  `grep -rn 'Color(hex\|#[0-9A-Fa-f]\{6\}' Sources/Features Sources/AppShell`
  must return no matches.
- Do not hard-code appearance in features.
  `grep -rn 'colorScheme == .dark\|isDarkMode\|preferredColorScheme' Sources/Features`
  must return no matches.
- Use system appearance by default. `ThemeApplier` applies `settings.app.theme`
  app-wide by setting `NSApp.appearance`. Each scene root calls
  `View.appAppearance(_:)`. This provides the AppKit equivalent of
  `preferredColorScheme`. Do not use `preferredColorScheme(nil)` because it
  does not reliably restore System appearance on macOS. Other views must not
  read or force appearance. `--appearance light|dark` applies the same override
  for one run without saving it.
- Do not set `.tint` in app code. The asset catalog defines indigo `AccentColor`
  as `#4A55C7` for light appearance and `#7480F0` for dark appearance.
  macOS uses this accent only if the user selects Multicolor.
- Restrict explicit backgrounds to the locations listed after these rules.
  Search for `\.background(` in features to check them.
- Do not add bordered cards.
  `grep -rn '\.stroke(\|\.border(' Sources/Features` and
  `grep -rn 'RoundedRectangle' Sources/Features` must return no matches.
  Keep custom drawing, such as `RangeSliderView`, in RedisUI.
- Do not add custom hover effects.
  `grep -rn 'onHover' Sources/Features Sources/AppShell` must return no matches.
  Internal AppKit cursor handling in RedisUI's `CodeEditorView` is the exception.
- Omit stack spacing to use the system default. If explicit spacing is needed,
  use 2, 4, 6, 8, 12, 16, 20, or 24. Use `.padding()` or one of the same values
  for padding. Do not define spacing tokens.
- Do not add corner radii in features. RedisUI uses 4, 5, or 7 for
  `KeyTypeIcon` and 6 for code blocks.
- Use text styles.
  `grep -rn '\.system(size:' Sources/Features Sources/AppShell` must return no
  matches. For monospaced data, use `.fontDesign(.monospaced)`,
  `Font.body.monospaced()`, or the `.callout` and `.caption` variants.
  Use `.monospacedDigit()` for changing numbers.

Explicit backgrounds are permitted only in these locations:

- Code editors, CLI output, and Profiler output use `EditorAppearance.background`.
- Markdown and tutorial code blocks use `.background(.quaternary, in: .rect(cornerRadius: 6))`.
- Pinned Workbench result headers use `.background(.bar)`.
- `KeyTypeIcon` tiles draw their background inside RedisUI.
- Invisible helpers, such as geometry readers and keyboard shortcut buttons,
  may use `.background { }` without a color.

### 5.2 Color roles

| Role | Use |
| --- | --- |
| Accent | `Color.accentColor` / `.tint` from the system (never set) |
| Window, panel, popover, sidebar and input backgrounds | none; the system draws them (glass for popovers, menus and the sidebar) |
| Hover | none; the system handles hover |
| Selection | `List` / `Table` selection; `Color(nsColor: .selectedContentBackgroundColor)` where a view draws its own rows |
| Alternating rows | `.inset(alternatesRowBackgrounds: true)` |
| Borders and separators | none; `Divider()` for separation |
| Production marker | the 2.3.3 production label only; no tint elsewhere |
| Loading placeholders | none; `ProgressView` |
| Primary, secondary, tertiary text | `.primary`, `.secondary`, `.tertiary` (`Color(nsColor: .tertiaryLabelColor)` where a `Color` is required) |
| Placeholder text | system-drawn prompts; `Color(nsColor: .placeholderTextColor)` where drawn by hand |
| Links | `Link` / `.link` (`Color(nsColor: .linkColor)`) |
| Success, warning, danger, notice | `.green`, `.orange`, `.red`, `.purple` |
| Command group and category text | `.secondary` |
| Editor, CLI and Profiler background, text, success and error | `EditorAppearance.background`, `.text`, `.success`, `.error` |
| Syntax colors | `EditorAppearance.Syntax.*` (AppKit), `EditorAppearance.JSON.*` (SwiftUI) |
| Editor gutter and command marker | `EditorAppearance.gutterText`, `.gutterActiveText`, `.commandMarker`; system selection and caret |
| Chart series and matching table dots | Swift Charts default palette (`.foregroundStyle(by:)`); `ChartPalette.color(at:)` = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .indigo, .mint, .cyan, .brown, .red], cycling |

### 5.3 Spacing, radii and fonts

| Role | Use |
| --- | --- |
| Spacing | default stack spacing, or a literal from {2, 4, 6, 8, 12, 16, 20, 24}: 20 for sheet padding, 24 between content sections |
| Padding | `.padding()` or a literal from the same set |
| Corner radii | none in features (no custom shapes) |
| Monospaced data | `.body.monospaced()`, `.callout.monospaced()`, `.caption.monospaced()` |
| Body and caption text | `.body` (default; omit), `.caption` |
| In-content section titles | `.title3.weight(.semibold)`; `.title2` for page titles (rare) |
| Headers in content | `.headline`; system section headers in `List` / `Form` |
| AppKit editor font | `EditorAppearance.font(size:weight:)` |
| AppKit UI font | `NSFont.systemFont(ofSize: NSFont.systemFontSize)` |

### 5.4 Key type tint and symbol

| KeyType | `tint` | `symbolName` |
| --- | --- | --- |
| string | `.purple` | `textformat` |
| hash | `.blue` | `number` |
| list | `.green` | `list.bullet` |
| set | `.orange` | `circle.grid.2x2` |
| zset | `.pink` | `list.number` |
| stream | `.mint` | `water.waves` |
| json | `.indigo` | `curlybraces` |
| timeSeries | `.gray` | `chart.xyaxis.line` |
| vectorSet | `.cyan` | `move.3d` |
| array | `.teal` | `rectangle.split.3x1` |
| graph | `.brown` | `point.3.filled.connected.trianglepath.dotted` |
| unknown | `.gray` | `questionmark` |

RedisUITests must include a test that `NSImage(systemSymbolName:accessibilityDescription:)` is non-nil for every
`symbolName` above and every symbol used in sections 2 and 3.

---

## 6. Idiom replacement table

Use the macOS controls in the second column for each interaction in the first column.

| Web idiom | macOS equivalent | API |
| --- | --- | --- |
| Toasts (bottom-right stack) | No message for success (the result is visible); inline result in the sheet or popover that started the action; alerts for failures | `SheetForm(successMessage:)`, `InlineMessage`, `.shellStatusAlerts(_:)` |
| Skeleton loaders | Spinner in place; content appears when ready; empty metadata cells stay blank | `ProgressView()`, `ProgressView().controlSize(.small)` |
| Pagination controls | Scrolling lists with cursor continuation | `LoadMoreRow`, `.onAppear` on trailing rows |
| Hand-rolled hover states (hover delete, hover pencil, hover copy) | Selection + context menu + keyboard + double-click | `.contextMenu`, `.contextMenu(forSelectionType:menu:primaryAction:)`, `.onDeleteCommand`, `.onCopyCommand` |
| Type-to-confirm popover / sheet | Alert with text field and suppression toggle | `.alert` + `TextField`, `.dialogSuppressionToggle`, `.dialogSeverity(.critical)` |
| Delete confirmation popovers | Confirmation dialog | `.destructiveConfirmation` (`.confirmationDialog`) |
| Breadcrumb instance header ("Databases / name / db ✎ ⓘ") | Window title + subtitle, database switcher toolbar button, logical DB picker, activity view | `navigationTitle`, `navigationSubtitle`, `ToolbarItem(.navigation)`, `Picker(.menu)` |
| Icon rail | Sidebar with sections | `NavigationSplitView`, `List(selection:).listStyle(.sidebar)` |
| Bottom tab bar (CLI / Command Helper / Profiler) | Debug-area style bottom panel toggled from the toolbar and View menu; Command Helper in the inspector | bottom panel (2.3.5), `Toggle(.button)`, `.inspector` |
| Custom split pane with drag handle | Native split views | `HSplitView`, `VSplitView` |
| Insights side panel with header and full-screen | Inspector | `.inspector(isPresented:)`, `.inspectorColumnWidth` |
| Web-style tabs (custom tab strips) | Segmented picker; sidebar rows for top-level pages; `TabView` only in Settings | `Picker(...).pickerStyle(.segmented)` |
| Chips and badges (key type, env, tags, modules, groups) | Colored symbol tiles for key types; plain text elsewhere; `.badge(n)` for counts in lists | `KeyTypeIcon`, `EnvironmentLabel`, `TagText`, `ModuleSummaryText`, `List` `.badge` |
| Cards (bordered rounded panels) | Plain sections separated by dividers; grouped forms; tables | `Divider()`, `Form { Section }.formStyle(.grouped)`, `Table` |
| Inline banners (colored callouts) | Section footers, `InlineMessage` (symbol + text, no fill), `ContentUnavailableView` description | `InlineMessage`, `Section { } footer: { }` |
| Columns popover | Native column customization through the table header context menu | `Table(columnCustomization:)`, `TableColumn.customizationID` |
| Tree settings / columns popovers in list header | View Options | View > Show View Options ⌘J popover |
| Search bar with mode switch, type dropdown, history dropdown | Toolbar search with scopes, tokens and suggestions | `.searchable(text:tokens:suggestedTokens:placement:prompt:token:)`, `.searchScopes`, `.searchSuggestions` |
| "Last refresh" label + refresh + chevron popover | Split-button menu with help tooltip | `AutoRefreshMenu` (`Menu(primaryAction:)`) |
| Inline ✓/✗ editors with pencils | Sheets, popovers, or in-cell text fields committed by Return | `TextField.onSubmit`, `.popover`, `SheetForm` |
| Right-pane panels (New Key, Bulk Actions, drawers) | Sheets | `.sheet` + `SheetForm` + `.sheetSize` |
| Floating bulk-action bar | Toolbar items and context menu acting on the table selection | `Table(selection:)`, `.contextMenu(forSelectionType:)` |
| Full-screen panel toggles | Hide the list pane (View menu) / expand into a sheet | `HSplitView` child visibility, `.sheetSize(.large)` |
| Illustrations and marketing copy in empty states | `ContentUnavailableView` with one SF Symbol | `ContentUnavailableView` |
| Production header tint | Red production label in the activity view and in the Home table | `EnvironmentLabel` |
| Drop zone with dashed border | File button + system drop highlight | `FilePickerRow`, `.dropDestination` |
| Info "(i)" icons with tooltips | `.help` on the control, section footers | `.help(_:)` |
| Custom search field | Native search field | `.searchable`, `SearchField` (NSSearchField) |

---

## 7. Liquid Glass rules

The design check used Apple's SwiftUI documentation through Context7 at
`/websites/developer_apple_swiftui`. It covered these pages:

- "Applying Liquid Glass to custom views" and "glassEffect(_:in:)".
- "GlassEffectContainer", "glassProminent", and "buttonStyle(.glass)" through
  "Landmarks: Displaying custom activity badges".
- "backgroundExtensionEffect(isEnabled:)" and "scrollEdgeEffectStyle(_:for:)".
- "ToolbarSpacer init(_:placement:)" and "SpacerSizing".
- "Landmarks: Refining the system-provided glass effect in toolbars" and
  "sharedBackgroundVisibility(_:)".
- "presentationSizing(_:)" and "PresentationSizing automatic".
- "inspectorColumnWidth(min:ideal:max:)".
- "dialogSuppressionToggle(isSuppressed:)" and "dialogSeverity(_:)".
- "searchScopes(_:activation:_:)" and "ContentUnavailableView search(text:)".
- "ToolbarItemPlacement principal".

The check covered the declarations in this example.

```swift
func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
GlassEffectContainer(spacing:) { … }          // plus .glassEffectID(_:in:)
static var glassProminent: GlassProminentButtonStyle   // .buttonStyle(.glassProminent); .buttonStyle(.glass)
func backgroundExtensionEffect(isEnabled: Bool) -> some View
func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View
ToolbarSpacer(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic)
func sharedBackgroundVisibility(_ visibility: Visibility) -> some CustomizableToolbarContent
Glass.regular.tint(_:).interactive()
```

The system applies glass to the following controls. Do not add custom glass to them.

- Sidebar of `NavigationSplitView` (floating glass sidebar), window toolbar and its item groups (glass capsules grouped by
  `ToolbarSpacer`), the inspector column chrome, sheets, alerts, confirmation dialogs, popovers, menus, the search field,
  segmented pickers, toggles, sliders and buttons.
- Toolbar item grouping: items between spacers share one glass capsule. Use `ToolbarSpacer(.fixed)` exactly where
  section 2.3.2 says. `sharedBackgroundVisibility(.hidden)` is not used (the activity view keeps the shared glass).

Use custom glass only in these locations:

| Use | API | Owner |
| --- | --- | --- |
| Primary toolbar action (one per window): Workbench Run, Vector Search Run, Create Index | `.buttonStyle(.glassProminent)` | Workbench, Vector Search |
| `JumpToLatestButton` floating over live logs (Profiler, CLI, Pub/Sub) | `.buttonStyle(.glass)` inside a `GlassEffectContainer` placed with `.overlay(alignment: .bottomTrailing)` and padding 12 | RedisUI (used by Analytics, Workbench) |
| "Hold ⌘Q to Quit" reminder (section 2.8) in a borderless, non-activating, click-through panel | `.glassEffect(.regular, in: .capsule)` | AppShell |

Apply these restrictions to content and scroll effects:

- Content areas: tables, lists, forms, the key details pane, charts, the editor, CLI and Profiler output, result
  sections, empty states. `grep -rn 'glassEffect\|\.glass\b\|glassProminent' Sources/Features` must only match the
  three toolbar Run/Create buttons; `glassEffect` itself appears only in RedisUI (`JumpToLatestButton`) and in
  AppShell's quit reminder.
- Custom materials in content (`.ultraThinMaterial`, `.regularMaterial`): not allowed. `.bar` is allowed only for pinned
  Workbench result headers (5.1).
- `backgroundExtensionEffect`: not used. The app has no edge-to-edge imagery that should extend under the sidebar or
  inspector; applying it to tables or text produces mirrored smears.
- `scrollEdgeEffectStyle`: leave the system default (soft) everywhere except `.scrollEdgeEffectStyle(.hard, for:
  .top)` on the Workbench and Vector Search results scroll views (pinned headers). AppKit-hosted scroll views
  (`CodeEditorView`, CLI and Profiler output) keep AppKit's default.

---

## 8. Menu bar

AppShell owns `AppCommands`. Sections and items below are exhaustive; system items not listed keep their default.
"Enabled when" uses these focused values:

| Focused value | Type | Published by | With |
| --- | --- | --- | --- |
| `\.databaseSession` | `DatabaseSession` | AppShell database window | `.focusedSceneValue` |
| `\.homeCommands` | `HomeCommands` (ConnectionsFeature, public struct of closures + selection count) | `HomeView` | `.focusedSceneValue` |
| `\.browserCommands` | `BrowserCommands` (BrowserFeature, public) | `BrowserView` | `.focusedSceneValue` |
| `\.workbenchCommands` | `WorkbenchCommands` (WorkbenchFeature, public: `clearResults`, `hasResults`) | `WorkbenchView` | `.focusedSceneValue` |
| `\.editorRunAction` | `EditorRunAction` (RedisUI, public: `run`, `canRun`) | `WorkbenchView`, Vector Search query page | `.focusedSceneValue` |
| `\.analyticsCommands` | `AnalyticsCommands` (AnalyticsFeature, public: `newReport`, `canCreateReport`, `clearSlowLog`, `canClearSlowLog`) | `DatabaseAnalysisView`, `SlowLogView` | `.focusedSceneValue` |
| `\.profilerCommands` | `ProfilerCommands` (MonitoringFeature, public: `title` ("Start Profiler" / "Pause Profiler" / "Resume Profiler"), `isEnabled`, `toggle`) | `ProfilerView` | `.focusedSceneValue` |

Each feature declares a public `FocusedValues` key in its own target.
AppShell imports every feature and can read those keys. `editorRunAction`
lives in RedisUI because two features publish it. Values contain `@MainActor`
closures and `Bool` flags. The view recreates them when state changes.

### 8.1 App menu (Keystrand)

| Item | Shortcut | Enabled when |
| --- | --- | --- |
| About Keystrand | — | always; the standard About panel (`orderFrontStandardAboutPanel`) with the version, build, `NSHumanReadableCopyright` and `Keystrand/Resources/Credits.rtf`: the copyright and MIT License line, the Redis trademark line, and an acknowledgements paragraph that ends "Choose Help > Acknowledgements for the full notices." |
| Settings… | ⌘, | always (system `Settings` scene) |
| Services, Hide Keystrand ⌘H, Hide Others ⌥⌘H, Show All, Quit Keystrand ⌘Q | system | system |

⌘Q is held for 1 second to quit while "Hold ⌘Q to quit" is on (section 2.8). Choosing the menu item quits at once.

### 8.2 File

| Item | Shortcut | Enabled when / action |
| --- | --- | --- |
| Add Database… | ⌘N | always; brings Home forward and opens the Add Database sheet (`HomeCommandCenter`) |
| Open Recent ▸ | — | submenu of the 10 most recently connected databases ("name [dbN]"), then divider, "Clear Menu"; opens the database window |
| — | | |
| Import Connections… | ⇧⌘I | always; Home Import sheet |
| Export Connections… | ⇧⌘E | `homeCommands.selectionCount > 0` |
| — | | |
| Close | ⌘W | system |

Open Home through **Window > Redis Databases** (⌘0). Assign ⇧⌘N to **Database > New Key…**. Do not add New Window.

### 8.3 Edit

| Item | Shortcut | Enabled when / action |
| --- | --- | --- |
| Undo, Redo, Cut, Copy, Paste, Delete, Select All | system | system (text fields, editors, `.onDeleteCommand`, `.onCopyCommand`) |
| Copy Key Name | ⌥⌘C | `browserCommands.hasSelectedKey` |
| — | | |
| Find ▸ Find… | ⌘F | focuses the window's search field (`.searchable` focus binding: Home, Browser, Vector Search list; Command Helper and Keyboard Shortcuts search when visible) |

### 8.4 View

| Item | Shortcut | Enabled when / action |
| --- | --- | --- |
| Show Sidebar / Hide Sidebar | ⌃⌘S | system `SidebarCommands()` |
| — | | |
| Browser | ⌘1 | database window |
| Workbench | ⌘2 | database window |
| Vector Search | ⌘3 | database window |
| Database Analysis | ⌘4 | database window |
| Slow Log | ⌘5 | database window |
| Cluster Details | ⌘6 | database window and `session.isCluster` |
| Pub/Sub | ⌘7 | database window |
| — | | |
| as List | ⌃⌘1 | Browser visible; checkmark when active |
| as Tree | ⌃⌘2 | Browser visible and key-name format not HEX; checkmark |
| Show View Options | ⌘J | Browser visible |
| — | | |
| Show Bottom Panel / Hide Bottom Panel | ⇧⌘Y | database window connected |
| Show CLI / Hide CLI | ⌃` | database window connected |
| Show Profiler / Hide Profiler | ⇧⌘P | database window connected |
| — | | |
| Show Inspector / Hide Inspector | ⌥⌘I | database window |
| Command Helper | ⇧⌘H | database window; opens the inspector on Command Helper |
| Tips | — | database window; inspector on Tips |
| Tutorials | — | database window; inspector on Tutorials |
| — | | |
| Refresh | ⌘R | database window connected (`navigator.requestRefresh()`) or Home (reload list) |
| — | | |
| Show Toolbar / Hide Toolbar, Enter Full Screen ⌃⌘F | system | system `ToolbarCommands()` |

Toggle items change their title ("Show …"/"Hide …") with state; section items show a checkmark for the current section.

### 8.5 Database

| Item | Shortcut | Enabled when / action |
| --- | --- | --- |
| Connect | — | database window, state disconnected or failed |
| Disconnect | — | database window, connected |
| Reconnect | ⇧⌘R | database window, connected or connection lost |
| — | | |
| Switch Database… | ⌘O | database window; opens the switcher popover |
| Logical Database ▸ | — | `databaseCount > 1`; db0…db15 (checkmark on current), "Other…" when more; disabled while Workbench runs |
| Edit Database… | ⌥⌘E | database window, or Home with exactly one selected database |
| — | | |
| New Key… | ⇧⌘N | Browser visible and connected |
| Rename Key… | — | `browserCommands.hasSelectedKey` |
| Set TTL… | — | `browserCommands.hasSelectedKey` |
| Delete Key… | — | `browserCommands.hasSelectedKey` |
| Delete Keys Matching Filter… | — | Browser visible |
| Upload Commands from File… | — | Browser visible |
| — | | |
| Run Commands | ⌘↩ | `editorRunAction.canRun` (Workbench or Vector Search query page). The editor's own ⌘↩ handler and this item call the same closure; the closure ignores calls while a run is in progress, so a double delivery never runs twice |
| Clear Results… | — | `workbenchCommands.hasResults` |
| — | | |
| New Analysis Report | — | `analyticsCommands.canCreateReport` |
| Clear Slow Log… | — | `analyticsCommands.canClearSlowLog` |
| Start Profiler / Pause Profiler / Resume Profiler | — | `profilerCommands.isEnabled` (the Profiler pane is open); title from `profilerCommands.title` |

### 8.6 Window

| Item | Shortcut | Enabled when / action |
| --- | --- | --- |
| Minimize ⌘M, Zoom, tab items, Bring All to Front, window list | system | system |
| Redis Databases | ⌘0 | always; `openWindow(id: AppWindowID.home)` (focuses the single Home window) |

### 8.7 Help

| Item | Shortcut | Action |
| --- | --- | --- |
| Keyboard Shortcuts | ⌘/ | `openWindow(id: AppWindowID.shortcuts)` |
| Redis Command Reference | — | opens <https://redis.io/docs/latest/commands/> |
| Acknowledgements | — | `openWindow(id: AppWindowID.acknowledgements)` (section 3.38) |
| — | | |
| Copy System Info | — | copies the app version, build, macOS version and architecture as a fenced "Keystrand diagnostics" block |
| Reset Onboarding | — | `settings.ui.resetOnboarding()` |

Keep the system Help search field. Do not add a Release Notes link.

### 8.8 Routing rules

- Menu items never hold state; they read focused values and call navigator methods or feature closures.
- Section shortcuts and toggles also work when focus is inside a text field of the database window (they use
  `.focusedSceneValue`, not `.focusedValue`).
- In-view keyboard shortcuts (`.keyboardShortcut` on hidden buttons) are not used when a menu item covers the same
  action: `grep -rn 'keyboardShortcut' Sources/Features` may only match: sheet default/cancel actions, ⌘↩ inside the
  Workbench and Vector Search editors (shared closure), ⌘K/⌃L in the CLI, ⌘[ Back in the narrow Browser, ⌘S Save in
  the String and JSON text editors while editing, ⌘I Get Info in the Vector Search index list.

### 8.9 Shortcut table (source for the Keyboard Shortcuts window)

| Group | Description | Shortcut |
| --- | --- | --- |
| Application | Add database | ⌘N |
| Application | Import connections | ⇧⌘I |
| Application | Show Redis databases | ⌘0 |
| Application | Settings | ⌘, |
| Application | Keyboard shortcuts | ⌘/ |
| Database Window | Browser … Pub/Sub | ⌘1 … ⌘7 |
| Database Window | Show or hide the sidebar | ⌃⌘S |
| Database Window | Show or hide the inspector | ⌥⌘I |
| Database Window | Command Helper | ⇧⌘H |
| Database Window | Show or hide the bottom panel | ⇧⌘Y |
| Database Window | Show or hide the CLI | ⌃` |
| Database Window | Show or hide the Profiler | ⇧⌘P |
| Database Window | Refresh | ⌘R |
| Database Window | Switch database | ⌘O |
| Database Window | Edit database | ⌥⌘E |
| Database Window | Reconnect | ⇧⌘R |
| Browser | New key | ⇧⌘N |
| Browser | Show as list / as tree | ⌃⌘1 / ⌃⌘2 |
| Browser | View options | ⌘J |
| Browser | Copy key name | ⌥⌘C |
| Browser | Rename key | Return |
| Browser | Delete key | ⌫ |
| Browser | Preview value | Space |
| Browser | Find keys | ⌘F |
| Vector Search | Get index info | ⌘I |
| Workbench | Run commands | ⌘↩ |
| Workbench | Show completions | ⌃Space |
| Workbench | Show command hints | ⇧⌘Space |
| Workbench | Previous command from history | ↑ (at the start of the editor) |
| CLI | Complete command / previous completion | Tab / ⇧Tab |
| CLI | Clear the screen | ⌘K or ⌃L |
| CLI | Previous / next command | ↑ / ↓ |

---

## 9. Launch flags and screenshot QA

### 9.1 Flags AppShell must support

RedisUI `QALaunchOptions` parses all flags from section 4.13. AppShell applies
them after the first window appears. Any flag sets `ApplePersistenceIgnoreState`,
as specified in section 2.1. `scripts/snapshot.sh` also sets
`KEYSTRAND_DISABLE_AUTODISCOVERY=1`.

Use the following flags to select the initial window state:

| Flag | Effect |
| --- | --- |
| `--home` | Shows the Home window (default when no `--open`). |
| `--home --add-database` | Home window with the Add Database sheet open (start page). |
| `--open host:port[/db]` | Existing behavior (upsert "host:port", open its window); Home is not presented. |
| `--open-id <id>` | Existing behavior. |
| `--section browser\|workbench\|analysis\|slowlog\|cluster\|pubsub\|vectorsearch` | With `--open`: selects that sidebar item once connected (`cluster` falls back to analysis on non-cluster). |
| `--tool cli\|helper\|profiler` | With `--open`: opens the bottom panel with CLI or Profiler, or the inspector on Command Helper (`helper`). May be repeated. |
| `--inspector helper\|tips\|tutorials` | With `--open`: shows the inspector on that pane. |
| `--key <name>` | With `--open`: Browser selects that key (`navigate(.browser(BrowserNavigationRequest(selectedKey:)))`). Implies `--section browser`. |
| `--sheet new-key\|bulk-actions\|edit-database\|tags\|sample-data` | Opens that sheet after the window is ready (`edit-database` and `tags` work with `--open` and with `--home` + selected first row). Features read `QALaunchOptions.current.sheet` once. |
| `--settings [general\|workbench\|advanced]` | After Home appears, opens Settings on that tab (writes `SettingsTab.selectionDefaultsKey` first); Settings is frontmost. |
| `--shortcuts` | After Home appears, opens the Keyboard Shortcuts window (frontmost). |
| `--appearance light\|dark` | Forces the appearance for this run (not saved). |
| `--window-size WxH` | Sets the frontmost window's content size (default shots: 1280x800). |

`scripts/snapshot.sh` captures the process's frontmost window. macOS treats a
sheet as a separate window, so sheet screenshots contain only the sheet.
For screenshots that need a connection and data, set `WAIT=8`.

### 9.2 Shared procedure

Seed only the assigned test database. Do not send `FLUSHDB` or `FLUSHALL`.
Delete only your own keys. Use these commands to capture a screenshot:

```bash
export APP=.build/dd/Build/Products/Debug/Keystrand.app   # or dist/Keystrand.app
mkdir -p .build/shots/<label>
# seed the area's DB index (never FLUSHDB/FLUSHALL; delete only your own keys)
docker exec keystrand-test redis-cli -n <db> HSET qa:user:1 name Ada role admin
WAIT=8 scripts/snapshot.sh .build/shots/<label>/browser-hash-light.png --open 127.0.0.1:6390/<db> --key qa:user:1 \
  --appearance light --window-size 1280x800
```

Capture every listed screen in light and dark appearance. Use `-light.png`
and `-dark.png` filename suffixes. Inspect every PNG.

Use these test database indexes:

| Area | Database index |
| --- | --- |
| Connections | 12 |
| Browser | 4 |
| Basic key types | 5 |
| Advanced key types | 6 |
| Workbench | 7 |
| CLI | 8 |
| Analytics | 9 |
| Monitoring | 10 |
| Vector Search | 0, with prefix `qa-vs:` |
| Settings | 13 |

After Vector Search checks, delete the `qa-vs:` keys and the test index.

Check every screenshot against these requirements:

1. The sidebar and toolbar use system glass. Window controls use no hex
   colors, navy rail, or red selection fill.
2. Toolbar order matches section 2.3.2. The title and subtitle remain visible.
   The activity view stays centered.
3. Content contains no bordered cards, skeleton bars, transient status messages,
   pagination controls, or custom tab strips.
4. Text remains legible in both appearances. Selection uses the user's accent color.
5. Empty and failed areas use `ContentUnavailableView` with a large symbol,
   title, and one-line description.

### 9.3 Shots per feature group

| Area | Shot (file name) | Flags | Reviewer checks |
| --- | --- | --- | --- |
| AppShell | `window-browser` | `--open 127.0.0.1:6390/4` | Sidebar sections Data/Analytics/Messaging with symbols; toolbar order; subtitle "Browser · 127.0.0.1:6390"; activity metrics. |
| AppShell | `window-production` | `--open …` on a database edited to Production (`--sheet edit-database` first, save) | Red "Production" label leads the activity view; no tinted header. |
| AppShell | `window-inspector-tips`, `window-drawer-both` | `--inspector tips`; `--tool cli --tool profiler` | Inspector segmented picker; bottom panel header with two toggles; native split dividers. |
| AppShell | `window-failed` | `--open 127.0.0.1:6399` (nothing listening) | `ContentUnavailableView` with "Try Again" and "Edit Database…". |
| AppShell | `menu-*` (manual: open each menu, `screencapture -i`) | — | Menu items, ellipses and shortcuts match section 8. |
| Connections | `home-empty` | `--home` (fresh data dir) | `ContentUnavailableView` "No Databases" with "Add Database…". |
| Connections | `home-list` | run `--open 127.0.0.1:6390/12` once with `KEYSTRAND_DATA_DIR=<dir>`, add 2 more DBs with tags, then `--home` with the same dir | Sidebar Library/Environments/Tags with counts; Table inset alternating; no chips; subtitle count. |
| Connections | `add-database` | `--home --add-database` | Grouped form, URL field monospaced, "Other Ways to Add" rows, footer order Test Connection … Cancel, Connection Settings…, Add Database. |
| Connections | `edit-database` | `--open …/12 --sheet edit-database` | Segmented General/Security/Decompression; read-only LabeledContent section; footer order. |
| Connections | `manage-tags` | `--open …/12 --sheet tags` | Grid rows with minus/plus circle buttons. |
| Browser | `browser-tree`, `browser-list` | `--open …/4` with 50 seeded keys of mixed types | Key type tiles, tree folders with `.badge` counts, status bar with "Scan More" logic, no hover buttons. |
| Browser | `browser-search` | as above, then type a pattern (manual) | Search field in toolbar with scopes and a type token. |
| Browser | `browser-empty` | `--open …/4` with the DB emptied | "No Keys" with New Key… and Load Sample Data…. |
| Browser | `key-string`, `key-hash`, `key-list`, `key-set` | `--key qa:string` etc. on DB 5 | Header tile + monospaced name, LabeledContent metadata row, subheader with Format menu, Table inset alternating. |
| Browser | `new-key`, `bulk-actions` | `--sheet new-key`, `--sheet bulk-actions` | Form sheet size, Type menu with tiles, footer buttons; Large sheet with segmented tabs. |
| Advanced key types | `key-zset`, `key-stream-entries`, `key-stream-groups`, `key-json-tree`, `key-json-text`, `key-vectorset`, `key-timeseries`, `key-array`, `key-unsupported` | `--key …` on DB 6 (seed with `ZADD`, `XADD`, `XGROUP CREATE`, `JSON.SET`, `VADD`, `TS.ADD`, `ARSET` when available, `BF.ADD`) | Segmented subheaders, JSON outline with system chevrons and syntax colors, no right drawer, chart system-styled, unsupported `ContentUnavailableView`. |
| Workbench | `workbench-empty`, `workbench-results` | `--section workbench` on DB 7 (run `SET a 1`, `GET a`, `FT._LIST`, `CLIENT LIST` manually or via a seeded history) | Toolbar Toggles + glass prominent Run; result sections with pinned headers, no cards; empty state with tutorial buttons. |
| Workbench | `workbench-tutorials`, `command-helper`, `cli` | `--inspector tutorials`, `--tool helper`, `--tool cli` | Tutorial list in inspector; Quick Help layout; CLI output on text background with system colors. |
| Analytics | `analysis-empty`, `analysis-report`, `analysis-tips` | `--section analysis` on DB 9 (seed 2,000 keys; click New Report manually for the report shot) | Charts with key type tints; sections separated by dividers; Tables; no rounded panels. |
| Analytics | `slowlog`, `slowlog-empty` | `--section slowlog` (`CONFIG SET slowlog-log-slower-than 0` on the test server only for the shot, then restore 10000) | Table + status bar; toolbar Show menu, Configure…, Clear…, refresh split button. |
| Analytics | `pubsub-empty`, `pubsub-messages`, `profiler-idle`, `profiler-running` | `--section pubsub`; `--tool profiler` on DB 10 (publish with `docker exec keystrand-test redis-cli PUBLISH qa hello`) | ContentUnavailableView states; compose bar; Profiler pane header controls; JumpToLatest glass button only when scrolled up. |
| Vector Search | `vs-welcome`, `vs-list`, `vs-query`, `vs-create-index`, `vs-sample-data` | `--section vectorsearch` (welcome needs no indexes in DB 0: only if no other indexes exist; otherwise skip and note), `--sheet sample-data` | NavigationStack back button, Table, glass prominent Run/Create, no cards or breadcrumbs. |
| Vector Search (Settings) | `settings-general`, `settings-workbench`, `settings-advanced`, `shortcuts` | `--settings general` etc., `--shortcuts` | Fixed 520 width grouped forms, radio Appearance picker, no Privacy/About tabs; shortcuts list with sections and search. |
| Vector Search (Settings) | `info-popover` | `--open …` then click the activity view (manual) | Grouped LabeledContent rows, modules, metrics, refresh controls. |

---

## 10. Accessibility and polish checklist

Check each requirement before you approve a UI change:

1. Give every icon-only button a text label. Use `Label(title, systemImage:)`
   with `.labelStyle(.iconOnly)` or `.accessibilityLabel`. Every match from
   `grep -rn 'Image(systemName' Sources/Features | grep 'Button'` must have
   one of these labels on the same control.
2. Add `.help(_:)` to every icon-only control. Include its action name and
   shortcut, if available, such as "Refresh (⌘R)".
3. Use title case for window titles, sidebar rows, section titles, menu items,
   button titles, toolbar labels, column headers, alert titles, and
   `ContentUnavailableView` titles. Use sentence case for descriptions,
   messages, footers, help tooltips, form labels, and toggle labels, such as
   "Empty the editor once commands run".
4. End titles with "…" (U+2026) if the item opens a sheet, popover, dialog,
   or file panel. Do not use "...". The check
   `grep -rn '\.\.\."' Sources/Features Sources/AppShell` must return no
   matches in UI strings.
5. Give every sheet a default button with `.keyboardShortcut(.defaultAction)`
   and a cancel button with `.keyboardShortcut(.cancelAction)`. Focus its first
   text field on appearance with `@FocusState` and `.defaultFocus`.
6. Set `role: .destructive` on destructive buttons. A destructive dialog must
   not make its destructive button the default.
7. Use text styles from section 5.1 rather than fixed point sizes. Display data
   in monospaced styles. Use `.monospacedDigit()` for changing numbers.
   Check layouts at the largest supported macOS text size. Use
   **System Settings > Accessibility > Display > Text size** where applicable.
   Also check a larger `.dynamicTypeSize` in previews.
8. If `@Environment(\.accessibilityReduceMotion)` is true, skip animations that
   move content. This includes insertion with `withAnimation`, symbol effects,
   disclosure rotation, and `numericText` transitions.
9. Use the system accent for selection and prominent buttons. App code must
   not set `.tint` or hard-code selection colors.
10. Use only the listed symbol effects. State changes use
    `.contentTransition(.symbolEffect(.replace))`, including copy to checkmark,
    play to pause, and Subscribe to Unsubscribe in either direction.
    Refresh completion may use `.symbolEffect(.bounce, value:)`.
    The subscribed Pub/Sub sidebar symbol may use `.variableColor.iterative`.
11. Use `contentTransition(.numericText())` for activity metrics, status bar
    list counts, and progress percentages.
12. Combine list row children for VoiceOver with
    `.accessibilityElement(children: .combine)`. Use a label such as
    "Hash user:1001, TTL no limit, 1.2 kilobytes".
    `KeyTypeIcon` must use `accessibilityLabel(type.displayName)`.
13. Support keyboard operation in every list and table with arrows, Return,
    Space, ⌫, and ⌘C. Keep system focus rings. Features must not use
    `.focusEffectDisabled()`.
14. Use tooltips instead of "(i)" icons. The check
    `grep -rn '"info.circle"' Sources/Features` may match only Vector Search
    **Get Info** and `InlineMessage(.info)`.
15. Name the app "Keystrand" in UI text. Use another client's name only to
    identify an import format. The check
    `grep -rn 'Redis Insight\|RedisInsight' Sources/Features Sources/AppShell`
    may match only import-format code, its comments, and the import file picker footer.

---

## 11. App icon

### 11.1 Direction

macOS 26 icons combine background and foreground layers, depth, and a glass
highlight inside the system's rounded-square shape. Use these layers for Keystrand:

- **Background.** Fill a rounded square with a diagonal gradient from deep
  indigo `#252951` at the top left to petrol teal `#073E4B` at the bottom
  right. Add an indigo radial glow (`#9097FA`, 40%) in the upper left and a
  teal radial glow (`#20DDB4`, 60%) in the lower right.
- **Foreground.** Center one key at a 45-degree downward angle, with its ring
  in the upper left and its bit in the lower right. Join three rounded teeth
  to the shaft, with the last tooth slightly longer. Fill the entire key
  with a continuous gradient from white `#FFFFFF` through `#DEF9F3` to mint
  `#69DCC3`.
- **Depth.** Place a teal underside (`#4B9D9B`) 10 icon units below the key.
  Add a navy shadow (`#020E20`, 60%) with a blur of 26 units and a downward
  offset of 22 units. Shade the lower edges and ring opening with a soft
  inner shadow, and add a fine white bevel along the foreground outline.
  All geometry uses the 1024 px canvas described below.
- **Glass highlight.** Draw a 1 px inner white stroke at 18% opacity along the
  shape's top half.

Do not add text or the Redis logo. The icon must remain clear at 16 px.

### 11.2 Production path (no Icon Composer GUI)

Generate the icon with a Swift script that draws into the asset catalog's PNG
sizes. Do not create an Icon Composer `.icon` bundle by hand. Its JSON schema
lacks enough documentation for reliable manual creation.

Run `swift scripts/make-app-icon.swift Keystrand/Resources/Assets.xcassets/AppIcon.appiconset`
to generate the assets.

The script draws a 1024×1024 master with `CGContext`, sRGB, 8 bits per component,
and premultiplied alpha. It renders each size directly from vector geometry.
It does not downscale the master. Output sizes are 16, 32, 64, 128, 256, 512,
and 1024 px. `CGImageDestination` writes `public.png` files using the existing
names, from `icon_16x16.png` and `icon_16x16@2x.png` through `icon_512x512@2x.png`.

Keep `Contents.json` unchanged. Use a 1024 px canvas with a 100 px inset on
each side, leaving an 824×824 shape. Draw continuous corners with radius
185.4 px. A superellipse-like path is preferred.
`CGPath(roundedRect:cornerWidth:cornerHeight:)` is acceptable at that radius.
Keep all pixels outside the shape transparent.

For sizes ≤ 32 px, draw a heavier ring and shaft with two wider teeth. Keep
the continuous white-to-mint fill. Omit the underside, shadows, bevel, and
edge stroke.

To check the icon:

1. Build the app.
2. Run `qlmanage -t -s 512 -o .build/shots/icon <app>`.
3. Inspect the PNG and a screenshot of the Dock icon.
4. If macOS adds a gray rounded container, set the inset and radius to the
   exact values specified in this section. Check the icon again.
