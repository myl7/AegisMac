## Aegis — Visual Design & Main-Screen UX Spec (for SwiftUI/macOS port)

This spec describes the visual system and main-screen behavior of the Aegis Authenticator Android app so it can be recreated natively on macOS. All values are taken directly from the Android resources/source. Android uses `dp` (density-independent pixels) and `sp` (scaled pixels for text). For a 1:1 macOS port, treat **1 dp = 1 pt and 1 sp = 1 pt** (macOS points), then scale to taste. All colors are given as `#RRGGBB` hex (fully opaque unless noted).

---

## 1. Themes & Color Palette

Aegis is a Material 3 (Material You) app. It ships **three base themes** — Light, Dark, and AMOLED (pure-black dark) — plus optional Android-12 "dynamic color" variants (system-derived; ignore for macOS, just support the three static themes). The user picks Light / Dark / AMOLED / Follow-System.

### 1.1 Material color roles

Aegis defines a full Material 3 color scheme. The roles actually used on the main screen are called out in §1.3; the complete palette is below so gradients/containers match.

**LIGHT theme (`md_theme_light_*`)**
- primary `#2b5bb5`, onPrimary `#ffffff`, primaryContainer `#d9e2ff`, onPrimaryContainer `#001945`
- inversePrimary `#b0c6ff`, surfaceTint `#2b5bb5`
- secondary `#365ca8`, secondaryContainer `#d9e2ff`, onSecondaryContainer `#001944`
- tertiary `#006491`, tertiaryContainer `#c9e6ff`, onTertiaryContainer `#001e2f`
- error `#ba1a1a`, onError `#ffffff`, errorContainer `#ffdad6`, onErrorContainer `#410002`
- background `#fefbff`, onBackground `#1b1b1f`
- surface `#fbf8fd`, onSurface `#1b1b1f`
- surfaceVariant `#e1e2ec`, onSurfaceVariant `#44464f`
- outline `#757780`, outlineVariant `#c5c6d0`
- surfaceContainerLowest `#ffffff`, surfaceContainerLow `#f5f3f7`, surfaceContainer `#efedf1`, surfaceContainerHigh `#e9e7ec`, surfaceContainerHighest `#e4e2e6`
- surfaceDim `#dbd9dd`, surfaceBright `#fbf8fd`
- inverseSurface `#303034`, inverseOnSurface `#f2f0f4`
- scrim `#000000`, shadow `#000000`

**DARK theme (`md_theme_dark_*`)**
- primary `#b0c6ff`, onPrimary `#002d6f`, primaryContainer `#00429c`, onPrimaryContainer `#d9e2ff`
- inversePrimary `#2b5bb5`, surfaceTint `#b0c6ff`
- secondary `#b0c6ff`, secondaryContainer `#18438f`, onSecondaryContainer `#d9e2ff`
- tertiary `#8aceff`, tertiaryContainer `#004c6e`, onTertiaryContainer `#c9e6ff`
- error `#ffb4ab`, onError `#690005`, errorContainer `#93000a`, onErrorContainer `#ffdad6`
- background `#1b1b1f`, onBackground `#e4e2e6`
- surface `#131316`, onSurface `#c7c6ca`
- surfaceVariant `#44464f`, onSurfaceVariant `#c5c6d0`
- outline `#8f9099`, outlineVariant `#44464f`
- surfaceContainerLowest `#0d0e11`, surfaceContainerLow `#1b1b1f`, surfaceContainer `#1f1f23`, surfaceContainerHigh `#292a2d`, surfaceContainerHighest `#343438`
- surfaceDim `#131316`, surfaceBright `#39393c`
- inverseSurface `#e4e2e6`, inverseOnSurface `#1b1b1f`

**AMOLED theme** = Dark theme, except every surface role and the window background are forced to pure black:
- `background = #000000`; `surface`, `surfaceVariant`, `surfaceContainer`, `surfaceContainerLow`, `surfaceContainerLowest`, `surfaceContainerHigh`, `surfaceContainerHighest`, `surfaceDim`, `surfaceBright` all = `#000000`.
- All other roles inherit from Dark.

### 1.2 Custom (Aegis-specific) color attributes

These are the semantic colors the OTP UI keys off of. Recreate them as named colors:

| Attr | Light | Dark | AMOLED |
|---|---|---|---|
| `colorFavorite` | `#F9A825` | `#F9A825` | `#F9A825` |
| `colorSuccess` | `#518242` | `#d9e7cb` | (inherits dark) |
| `colorOnSurfaceDim` (dim gray for "next code") | `#9D9EA2` | `#616371` | (inherits dark) |
| `colorCode` (the OTP digits) | = primary `#2b5bb5` | = primary `#b0c6ff` | `#ffffff` (white) |
| `colorCodeHidden` (dots when hidden) | = outlineVariant `#c5c6d0` | = outlineVariant `#44464f` | `#2F2F2F` |
| `colorProgressbar` | `#2b5bb5` | `#2b5bb5` | `#ffffff` (white) |
| `colorPrimaryAlternative` | = primary `#2b5bb5` | = inversePrimary `#2b5bb5` | (inherits) |

Note: `colorProgressbar` = `colorPrimaryAlternative`, which is `primary` in Light and `inversePrimary` in Dark — both resolve to **`#2b5bb5`**. AMOLED overrides it to white. The favorite gold `#F9A825` is the one true "accent" that never changes.

### 1.3 Which surface each element uses (important for the "flat card on tinted background" look)
- **Window background:** `background` (light `#fefbff` / dark `#1b1b1f` / amoled `#000000`).
- **Entry card (Normal / Small / Tile view modes):** an *elevated* Material card **with elevation forced to 0** — so it is effectively a **filled** card. Its fill is `colorSurfaceContainer` (light `#efedf1` / dark `#1f1f23` / amoled `#000000`). No drop shadow.
- **Entry card (Compact view mode):** same, but fill is `colorSurface` (light `#fbf8fd` / dark `#131316` / amoled `#000000`) — i.e. compact cards blend almost invisibly into the background; the list reads as a dense flat list rather than discrete cards.
- **Error card:** filled card using `colorErrorContainer` as its background, `colorOnErrorContainer` for icon+text.

macOS equivalent: cards are flat rounded rectangles filled with a subtle surface tint, **no shadow, no border**. On AMOLED everything is black-on-black separated only by spacing and the colored code text.

### 1.4 Status/system bars
Transparent status & navigation bars (edge-to-edge). Light theme uses dark status-bar icons; Dark/AMOLED use light icons. On macOS this maps to a standard window with a toolbar; no direct analog needed.

---

## 2. Overall Main-Screen Layout

Top-to-bottom structure:

1. **App bar (toolbar)** — Material toolbar, height = `actionBarSize` (56 dp standard). Title text **"Aegis"**. On the right: Search, Lock, Sort (always visible as icons); overflow menu holds Settings, About. "Lift on scroll" — the app bar gains a slight tonal elevation when the list is scrolled (subtle background shift; can be approximated on macOS with a hairline separator that appears on scroll).
2. **Group filter chip row** — a single horizontally-scrolling row of filter chips directly under the toolbar, with `12 dp` start/end padding. Hidden entirely when there are no groups.
3. **Optional global progress bar** — a thin horizontal TOTP countdown bar spanning the full width, shown *only* when all entries share one uniform period (see §4). Height `4 dp`. Hidden otherwise (`visibility=gone`).
4. **Entry list** — vertically scrolling `RecyclerView` with `8 dp` horizontal padding, `clipToPadding=false` (content can scroll under padding). Bottom padding grows to clear the system nav bar inset.
5. **Empty state** — shown in place of the list when there are zero entries (see §8).
6. **Floating Action Button (FAB)** — bottom-trailing corner, `16 dp` margin, floats over the list (see §7).

The list ends with a **footer row** (always present): centered text "Showing N entries" (`14 sp`), where N is bold. Plural: "Showing 1 entry" / "Showing N entries".

---

## 3. Entry Card Anatomy

Every entry (OTP account) is one card. There are **4 view modes** — NORMAL, COMPACT, SMALL, TILES — selectable in settings. NORMAL is the default. Layout is a horizontal row: **[favorite indicator] [icon] [text block: issuer/name + code] [spacer] [refresh button / drag handle]**, with a **per-card progress bar pinned to the very bottom edge** of the card.

### 3.1 Shared elements (all modes)

**Favorite indicator** — a thin vertical bar on the extreme leading edge of the card. Width `15 dp`, full card height, pulled `11 dp` off the leading edge (`marginStart = -11 dp`) so only a sliver (~4 dp) peeks out inside the card's rounded corner. Shape: rectangle, `4 dp` corner radius, `1 dp` stroke, tinted `colorFavorite` `#F9A825`. Visible only when the entry is favorited; otherwise `INVISIBLE` (occupies space but not drawn).

**Icon** — a `ShapeableImageView` clipped to a **circle** (`cornerSize = 50%`). Shows the entry's custom icon or a generated letter-avatar. Sizes per mode below. There is a note in styles for an 8 dp rounded-corner variant (`ShapeAppearanceOverlay.Aegis.ImageView.Rounded`, `cornerSize=8dp`) but the entry list uses the **circle** overlay. Icon can be globally hidden via a setting (then the text block shifts left).

**Selection overlay** — when an entry is selected (multi-select mode), a same-size circle appears over the icon filled with `colorPrimaryAlternative` and a white checkmark glyph (vector `item_selected`: a checkmark, tint `#F7F7F7`, drawn at 50% scale centered). The card itself is also marked "checked" (Material card checked state = a subtle tonal overlay). Selecting animates the checkmark in with a scale 0→100% over `150 ms`; deselecting scales 100%→0 over `150 ms`.

**Issuer + account-name** (the "description"):
- `profile_issuer`: **bold**, ellipsize end, single line.
- `profile_account_name`: regular weight, ellipsize end, single line.
- Three placement modes (`AccountNamePosition`, default **END**):
  - **END** (default): name appears on the same line, to the right of the issuer. If both issuer and name are present, name is prefixed with a `24`-unit start margin and wrapped as `(name)` — i.e. displayed like **`Issuer (account)`**. (In TILES mode, END is coerced to BELOW.)
  - **BELOW**: name on its own line beneath the issuer, no parenthesization.
  - **HIDDEN**: name not shown at all.
- There's a setting "only show account name when necessary": if on, the account name is only shown when 2+ entries share the same issuer (otherwise treated as HIDDEN for that entry).

**OTP code** (`profile_code`): font family **`sans-serif-light`** with **bold** style, color `colorCode`. This is the big glanceable number. `layoutDirection=ltr` (codes are always LTR even in RTL locales). Sizes per mode below. Text is grouped with spaces (see §5.1).

**Next code** (`next_profile_code`): a smaller, dimmed preview of the *next* rotation's code, color `colorOnSurfaceDim`, bold. Shown only if the "show next code" setting is on AND the entry is TOTP. Slightly negative letter spacing (`-0.01`) in compact/small/tile.

**"Copied" label** (`profile_copied`): the localized word **"Copied"**, normally `INVISIBLE`, animated in when the code is copied (see §5.2). Same text size as the issuer line.

**Refresh button** (`buttonRefresh`): a `refresh` outline icon, tinted `colorOnSurface`, `8 dp` padding, ripple background. Shown **only for HOTP** (counter-based) entries; `GONE` for TOTP. Tapping increments the HOTP counter and regenerates the code.

**Drag handle** (`drag_handle`): a `menu`/hamburger icon `24×24 dp`, normally `INVISIBLE`, shown when an entry is in draggable state (custom sort + single selection + non-favorite). Reordering is drag-and-drop.

**Per-card progress bar** — a `TotpProgressBar` (horizontal determinate) pinned along the **bottom edge** of each card, full card width. `max = 5000`. Progress drawable: solid fill `colorProgressbar`, with only the **top-right and bottom-right corners rounded `2 dp`** (left edge square) — so it looks like a bar that drains toward the right. Height `4 dp` (Normal) / `3 dp` (Compact/Small/Tile). **This per-card bar is shown only for entries whose period differs from the list's dominant period** (non-uniform entries); when all visible TOTP entries share the same period, the per-card bars are hidden and the single global top bar (§2.3) is used instead. Always hidden for HOTP.

### 3.2 View-mode dimensions

| Property | NORMAL | COMPACT | SMALL | TILES |
|---|---|---|---|---|
| Layout | `card_entry` | `card_entry_compact` | `card_entry_small` | `card_entry_tile` |
| Columns (grid span) | 1 | 1 | 1 | **2** |
| Inter-item spacing (dp) | 8 | 1 | 8 | 4 (all four sides) |
| Card fill | surfaceContainer | **surface** | surfaceContainer | surfaceContainer |
| Row vertical padding (dp) | top 8 / bottom 8 | top 3 / bottom 3 | top 5 / bottom 5 | 0 |
| Icon size (dp) | **60** | 45 | 45 | **24** |
| Icon container start pad (dp) | 14 | 12 | 14 | (inline, `6 dp` end margin) |
| Text block padding | top 18 / bottom 16 / sides 16 | top 12 / bottom 8 / sides 8 | top 8 / bottom 8 / sides 8 | top 12 / bottom 8 / start 8 |
| Issuer & name size (sp) | 16 | 13 | 13 | 11 |
| **Code size (sp)** | **34** | 26 | 26 | 26 |
| Next-code size (sp) | 20 | 16 | 16 | 16 |
| "Copied" size (sp) | 16 | 13 | 13 | 9 |
| Progress bar height (dp) | 4 | 3 | 3 | 3 |

**TILES specifics:** two columns; icon is small (`24 dp`) and sits **inline to the left of the issuer** on the top line (issuer/name row is a fixed `24 dp` tall header), the code sits below with a `10 dp` top margin. In TILES, END account-name position is forced to BELOW. When account name is HIDDEN in TILES, the issuer line is vertically centered and its text size bumped to `14 sp` (and the "Copied" label likewise centered at `14 sp`). Tile spacing is uniform `4 dp` on all four edges (first row / footer / error card get double top).

**Copy-confirm animation differs by mode** (see §5.2): non-TILES modes slide the "Copied" text down over the description; TILES cross-fades issuer↔"Copied" in place.

### 3.3 Card corner radius & favorite grouping
Cards use Material 3's medium shape (default **12 dp** rounded corners). Special behavior: **consecutive favorite entries at the top of the list are visually merged into one rounded block** — the top favorite keeps its top corners rounded but has square bottom corners, middle favorites are fully square, and the last favorite keeps only its bottom corners rounded. Non-favorite entries all have normal 12 dp corners. Favorites always sort to the top. macOS equivalent: when rendering a run of favorites, only round the outer corners of the group.

### 3.4 Spacing rules (item decoration)
- Non-tile modes: vertical gap = the mode's offset (8/1/8 dp). First entry gets a top margin (unless the error card is above it). The last entry gets no bottom margin. Favorites get bottom margins so the merged block reads as one unit but is separated from non-favorites.
- Error card: top margin = offset (×4 in Compact), bottom margin = offset. Footer: top margin = 2×offset, bottom = offset.
- Tiles: every tile gets offset margins on all four sides; first row / error card / footer get double top margin.

---

## 4. Countdown / Refresh Behavior

TOTP codes rotate on a fixed **period** (default 30 s; per-entry configurable). Aegis shows the time remaining as a draining horizontal bar and auto-regenerates codes.

- **Uniform vs non-uniform periods:** the adapter computes the *most frequent period* among all shown TOTP entries. If a single period dominates (`>1` entry shares it), the list is "uniform" and uses **one global progress bar** at the top of the list (full width, `4 dp`), plus hides all per-card bars. If entries have mixed periods, each entry shows its **own** per-card bar for the non-dominant ones. HOTP entries never show a bar.
- **Progress bar mechanics (`TotpProgressBar`):** `max = 5000`. On start, it computes current progress = `max × (millisTillNextRotation / (period×1000))`, i.e. the bar starts partially drained and animates **linearly down toward empty**, restarting each ~1 s tick and fully resetting at each rotation boundary. Interpolator: linear. Direction: value decreases → the filled portion shrinks toward the right (left corners square, right corners rounded).
- **Code auto-refresh:** a UI refresher fires at each rotation boundary (`millisTillNextRotation`) and regenerates every visible code. On refresh the app can emit a subtle haptic (Android vibration pattern) — omit on macOS or use `NSHapticFeedback` sparingly.
- **Expiration warning animation** (setting "show expiration state", per TOTP entry): as a code nears expiry the big code text animates from `colorCode` to the Material **error** color and then **blinks**. Exact timeline (from `startExpirationAnimation`):
  - `totalStateDuration = 7000 ms` (the warning window before rotation).
  - If period ≤ 7 s, the code is just shown permanently in error color.
  - Otherwise: hold normal color until `period×1000 − 7000 − 300 ms` elapses, then **fade color to error over `colorShiftDuration = 300 ms`**, hold `7000 − 3000 = 4000 ms`, then **blink**: alpha oscillates 1.0↔0.5, each half-cycle `500 ms`, repeated for `blinkDuration = 3000 ms` (6 half-cycles). The animation is seeked to the correct current position on bind. When animations are disabled, it just switches to error color at the 7 s mark. On stop/reset the code returns to `colorCode`, alpha 1.
- **HOTP:** no timer; user taps the refresh button to advance the counter and get a new code.

---

## 5. Code Formatting, Tap-to-Copy, Tap-to-Reveal

### 5.1 Code grouping
The raw OTP digits are grouped with single spaces for readability. Setting `CodeGrouping` (default **GROUPING_THREES**):
- `NO_GROUPING` → one block, no spaces.
- `HALVES` → split into two groups (`ceil(len/2)` per group).
- `GROUPING_TWOS` / `THREES` / `FOURS` → groups of 2 / 3 / 4.
Grouping inserts a `" "` before every position that is a positive multiple of the group size. Example (6-digit, threes): `012345` → `012 345`. **Steam and Yandex codes are never grouped** (shown raw). Codes that fail to generate (legacy empty-secret entries) display the literal string **`ERROR`**.

### 5.2 Tap-to-copy (`CopyBehavior`)
Tapping an entry copies its current code to the clipboard and plays a "Copied" confirmation.
- **SINGLETAP** (a common setting): one tap copies.
- **DOUBLETAP:** first tap arms, a second tap within the system double-tap timeout copies; otherwise it disarms.
- **Copy confirmation animation** (`animateCopyText`, 3 s visible):
  - **Non-tiles:** the "Copied" label slides down + fades in from above (`translate fromY -200%→-100%` over 300 ms, alpha 0→1 over 500 ms) while the description/name slides down + fades out; after **3000 ms** the "Copied" fades out and the description fades back in.
  - **Tiles:** cross-fade — "Copied" fades in (300 ms) as the issuer/name fades out; reversed after 3000 ms.
- Copying also increments a per-entry usage count and updates a "last used" timestamp (used by the Sort options).

### 5.3 Tap-to-reveal (setting `pref_tap_to_reveal`, default **off**)
When on, codes are hidden by default and shown only for the tapped entry, for a configurable number of seconds (`tapToRevealTime`, then auto-re-hide).
- **Hidden rendering:** each visible glyph of the (grouped) code is replaced with the bullet char **`●` (U+25CF)**; spaces are preserved. The dots are colored `colorCodeHidden`. To keep the hidden width close to the real code width, Aegis measures both and, if the dots are much narrower (scale factor < 0.8), it applies a per-character relative size span so the dot row visually matches the code's footprint (and vertically centers the dots). A zero-width space (`​`) is prepended to stabilize line height (needed for space-less Steam tokens). For macOS you can approximate: render the same number of `●` with spacing preserved, in the hidden color; exact width-matching is a nicety, not load-bearing.
- **Reveal interaction:** tapping a hidden entry reveals its code (and re-hides the previously focused one), starts the expiration animation, and — if copy-on-single-tap is also on — the reveal tap does **not** also copy (the first tap reveals, subsequent taps copy).

### 5.4 Highlight/dim (setting "highlight tapped entry", default off)
When on, tapping an entry dims all *other* entries to alpha **0.2** (`itemView.alpha` animated over 200 ms) and keeps the tapped one at alpha 1.0, for the focus duration, then restores. A freshly-added entry is temporarily highlighted this way for 3 s (others dimmed) after scrolling it into view.

---

## 6. Search & Group Filter

### 6.1 Search
- A Material **SearchView** lives in the toolbar (search icon, "always" shown). Iconified (collapsed to icon) by default; hint text **"Search"**. Max width unconstrained (fills the bar when expanded).
- Typing filters the list live (`onQueryTextChange`). On submit, the toolbar **title changes to "Search"** and the query is shown as the toolbar **subtitle**.
- **Match logic:** the query is lowercased and split on whitespace into tokens; an entry matches only if **every** token is found (substring, case-insensitive) in at least one of the enabled search fields. Search-field mask (settings) can include: **issuer**, **account name**, **note**, and **group names**. Default includes issuer + name at minimum.
- While searching, drag-reorder is disabled and the group filter is bypassed.
- Empty state during an active search: the list simply shows nothing (the "no entries" illustration is **not** shown while a search filter is active — it's only shown for a genuinely empty vault).

### 6.2 Group filter chips
- A horizontal, non-scrollbar-visible scroll row of **Material 3 Filter chips** under the toolbar. Hidden when the vault has no groups.
- Chip contents, left to right: one chip per user group (chip text = group name), plus two **placeholder chips**: **"All"** (selecting it clears the filter → show everything) and **"No group"** (show only ungrouped entries; represented internally as a `null` in the filter set). Selecting a specific group filters to entries in that group.
- **Selection model:** single-select by default (`selectionRequired=true`, so one is always selected — "All" is the default). A setting enables **multi-select** across groups.
- When a filter selection changes, a transient **"Save" chip** appears (transparent background, no stroke) that lets the user persist the current filter as the default; it disappears after saving. Un-checking the last selected group resets to "All".
- Filter logic: with a group filter active, an entry is hidden unless it belongs to one of the selected groups (or is ungrouped when "No group" is selected). Search overrides the group filter.

macOS mapping: a horizontal row of toggle "pill" chips (or a segmented/token control). Filter chips use the Material filter-chip look — rounded-full pill, tonal selected state with a leading checkmark when selected.

---

## 7. FAB & Add-Entry Menu

- **FAB:** circular Material FloatingActionButton, bottom-**trailing** corner, `16 dp` margin (`fab_margin`), icon = **`+`** (`ic_outline_add_24`), tinted with the theme's primary container colors (standard M3 FAB coloring). It floats above the list and hides/reveals on scroll (scroll down hides it, scroll up shows it).
- **Tapping the FAB opens a speed-dial menu:** a translucent scrim fades in over the whole screen to **alpha 0.5** (300 ms), and three pill-shaped action cards stagger-animate upward from above the FAB. The `+` icon **rotates 0°→45°** (becomes an ✕) over 100 ms. Each action card: rounded-full (`cardCornerRadius=100dp`), elevation 6 dp, `48 dp` tall, a `24 dp` leading icon + `12 dp` gap + label. Items animate in bottom-up with an overshoot interpolator (staggered `50 ms` apart, each 300 ms); tapping the scrim or an item closes the menu (reverse animation).
- **The three menu items (top to bottom in the open menu):**
  1. **"Scan QR code"** — icon `ic_qrcode_scan` (opens camera scanner). *On macOS, likely repurpose to "Scan from screen"/camera or omit if no camera.*
  2. **"Scan image"** — icon `ic_outline_add_photo_alternate_24` (pick an image file containing a QR).
  3. **"Enter manually"** — icon `ic_outline_edit_24` (opens the manual add/edit form).
- There is also an alternate **bottom-sheet** presentation of the same three choices (`dialog_add_entry`): a drag handle, centered title **"Add new entry"** (`20 sp`), then three `65 dp`-tall rows (`Scan QR code` / `Scan image` / `Enter manually`), each with a `25 dp` leading icon tinted `colorOnSurfaceVariant`, `20 dp` gap, `17 sp` label. Use this as the natural macOS equivalent: a `+` toolbar button opening a small popover/menu with those three commands.

---

## 8. Empty & Error States

### 8.1 Empty vault
When there are no entries **and no active search**, the list is replaced by a centered empty state (bottom-weighted, `150 dp` bottom padding to sit above center):
- A `50×50 dp` QR-scan icon (`ic_qrcode_scan`).
- Title (`17 dp` top pad, `18 sp`): **"No entries found"**.
- Body (`7 dp` top pad, `300 dp` wide, centered, `5 dp` extra line spacing): **"There are no codes to be shown. Start adding entries by tapping the plus sign in the bottom right corner"**.

### 8.2 Error card
Shown as the first item in the list (above all entries) when there's a warning/error to surface (e.g. backup failures). It's a filled card with `10 dp` outer + `16 dp` inner padding, background `colorErrorContainer`, containing a leading `error` icon and a **bold** message, both `colorOnErrorContainer`. Tappable (opens details). In tiles mode it spans both columns.

---

## 9. Toolbar Menu / Action Items (main screen)

Top app-bar actions (icons unless noted):
- **Search** (always).
- **Lock** (`ic_outline_lock_24`) — locks the vault (if encryption enabled).
- **Sort** (`ic_outline_sort_24`) — opens a single-choice submenu: **Custom** (default, drag-orderable), A→Z by name, Z→A by name, A→Z by issuer, Z→A by issuer, Most used, Last used. Favorites always float above regardless of sort.
- Overflow: **Settings**, **About**.

**Multi-select action mode** (entered by long-press / selecting entries) replaces the app bar with a contextual bar offering: Favorite/Unfavorite (star), Copy, Edit, Select all, Assign icons, Assign to group, Transfer (share via QR, star icon `qr_code_2`), Delete. These are relevant if you build selection; the primary read-only main screen doesn't need them initially.

---

## 10. Interaction Summary (state machine per entry)

- **Single tap** (no selection active): depending on settings — reveal (if tap-to-reveal), copy (single/double-tap behavior), highlight-focus. Copy shows the "Copied" animation and bumps usage stats.
- **Long press:** enters multi-select (focus + checkmark), and if the entry is drag-eligible, starts a drag.
- **Refresh button** (HOTP only): increments counter, focuses the entry, regenerates and persists.
- **Drag** (custom-sort, single non-favorite selection): reorders; disabled while filtering/searching.

---

## 11. macOS / SwiftUI Mapping Notes

- **Cards:** `RoundedRectangle(cornerRadius: 12)` filled with the surface color, **no shadow, no stroke**. Merge favorite runs by rounding only the group's outer corners (use a custom shape or `clipShape` per position). AMOLED = pure black fills; rely on spacing + the colored code for separation.
- **Code text:** use a **light-weight, slightly condensed** system font at large size (Android uses `sans-serif-light` bold at 34 sp in Normal). SF Pro Display Light/Regular is the closest; the digits should feel airy and prominent, colored `colorCode`. Consider a monospaced-digit variant (`.monospacedDigit()`) so grouped codes don't jitter as they refresh.
- **Progress bar:** a `GeometryReader`/`Capsule`-with-square-left-corners `Rectangle` whose width animates linearly from current fraction to 0 each period, resetting at the rotation boundary; color `colorProgressbar`. Per-card bar pinned to the card's bottom edge; global bar pinned under the toolbar. Only round the trailing (right) corners `2 pt`.
- **Filter chips:** a horizontally scrolling `HStack` of toggle pills matching Material filter-chip states (tonal selected fill + leading checkmark).
- **FAB → toolbar `+`:** most mac-native is a `+` button in the window toolbar (or bottom-trailing floating button if you want to preserve the Aegis feel) opening a menu/popover with Scan / Scan image / Enter manually. The rotating-plus + scrim speed-dial is a nice-to-have flourish, not essential.
- **Search:** a `.searchable` field in the toolbar; live token-AND filtering across issuer/name/note/group per the mask; show the query as a subtitle if you keep a title area.
- **Lift-on-scroll:** approximate with a toolbar hairline that appears once the list scrolls.
- **Theme:** implement Light / Dark / AMOLED as three explicit palettes plus "follow system". Don't rely on system semantic colors — Aegis's palette is a specific indigo-blue Material scheme; port the hex values above verbatim so the brand feel is preserved. The single accent that must stay constant is favorite gold `#F9A825`.
- **Animations:** copy-confirm ~3 s visible; selection checkmark scale 150 ms; expiration color-shift 300 ms + 3 s blink at 500 ms half-cycles; dim to 0.2 over 200 ms. These durations are load-bearing for matching the feel.

## CRITICAL FACTS (must preserve exactly)

- Progress bar: TotpProgressBar with android:max=5000; drains LINEARLY toward empty; per-card bar height 4dp (Normal) / 3dp (Compact/Small/Tile); global top bar 4dp. Progress drawable is solid colorProgressbar with ONLY top-right & bottom-right corners rounded 2dp (left square).
- Progress placement is HYBRID: one global full-width bar at top of list when all shown TOTP entries share a dominant period (uniform); otherwise per-card bars only on entries whose period differs from the dominant one. HOTP never shows a bar.
- colorCode (OTP digit color): Light = #2b5bb5, Dark = #b0c6ff, AMOLED = #ffffff. colorCodeHidden (dots): Light #c5c6d0, Dark #44464f, AMOLED #2F2F2F. colorProgressbar: Light/Dark #2b5bb5, AMOLED #ffffff. Favorite accent colorFavorite = #F9A825 in ALL themes. colorOnSurfaceDim (next-code): Light #9D9EA2, Dark #616371.
- Window background: Light #fefbff, Dark #1b1b1f, AMOLED #000000. Card fill: Normal/Small/Tile = surfaceContainer (Light #efedf1 / Dark #1f1f23 / AMOLED #000000); Compact = surface (Light #fbf8fd / Dark #131316 / AMOLED #000000). AMOLED forces ALL surfaces to #000000. Cards are FILLED with elevation forced to 0 — no shadow, no border.
- Code font: fontFamily sans-serif-light + bold, textColor colorCode, layoutDirection=ltr. Sizes: Normal 34sp, Compact/Small/Tile 26sp. Next-code: Normal 20sp, others 16sp. Issuer(bold)+name: Normal 16sp, Compact/Small 13sp, Tile 11sp.
- Icon: ShapeableImageView clipped to CIRCLE (cornerSize 50%). Sizes: Normal 60dp, Compact 45dp, Small 45dp, Tile 24dp.
- Four view modes enum order: NORMAL(card_entry), COMPACT(card_entry_compact), SMALL(card_entry_small), TILES(card_entry_tile). Default view mode = NORMAL (ordinal 0). TILES = 2 columns; all others = 1 column. Inter-item offsets: NORMAL 8dp, COMPACT 1dp, SMALL 8dp, TILES 4dp (all sides).
- Card corners: Material3 medium = 12dp. Consecutive favorites at top merge into one block: only the group's outer corners stay rounded (top favorite keeps top corners, last keeps bottom, middle fully square). Favorites always sort to top.
- Code grouping default = GROUPING_THREES. Modes: NO_GROUPING(-2 no spaces), HALVES(-1, ceil(len/2) per group), GROUPING_TWOS(2), THREES(3), FOURS(4). Space inserted before each index that is a positive multiple of group size. Steam & Yandex codes NEVER grouped. Generation failure shows literal 'ERROR'.
- Tap-to-reveal default OFF. Hidden char = '●' U+25CF, colored colorCodeHidden, spaces preserved; if dots width scale factor < 0.8 apply per-char RelativeSizeSpan to match real code width; prepend zero-width space U+200B for line-height stability.
- AccountNamePosition default = END. END: 'Issuer (account)' on one line, name gets 24-unit start margin and is wrapped in parentheses via getFormattedAccountName. BELOW: name on its own line, no parens. HIDDEN: name not shown. In TILES, END is coerced to BELOW; when HIDDEN in TILES the issuer is centered at 14sp.
- Favorite indicator: 15dp wide vertical bar, full height, marginStart=-11dp, rectangle shape 4dp corner radius + 1dp stroke, backgroundTint colorFavorite #F9A825, visible only when favorited else INVISIBLE.
- Copy confirmation: 'Copied' label visible for exactly 3000ms. Non-tiles: slide-down+fade (translate -200%→-100% 300ms, alpha 0→1 500ms) over description. Tiles: cross-fade issuer↔Copied (fade 300ms). Copy increments usage count + last-used timestamp.
- Expiration warning animation: totalStateDuration=7000ms, colorShiftDuration=300ms, blinkDuration=3000ms. Color fades from colorCode to Material error over 300ms starting at period*1000-7000-300ms, then blink alpha 1.0↔0.5 each half-cycle 500ms for 3000ms. If period<=7s just show error color. Dim other entries to alpha 0.2 over 200ms; default alpha 1.0.
- Selection checkmark overlay: circle over icon filled colorPrimaryAlternative + white check (item_selected vector, tint #F7F7F7). Scale-in/out 150ms. HOTP entries show refresh button (ic_outline_refresh_24, tint colorOnSurface); TOTP hide it.
- FAB: bottom-trailing, margin 16dp (fab_margin), icon ic_outline_add_24, hides on scroll-down. Tap opens speed-dial: scrim fades to alpha 0.5 (300ms), plus icon rotates 0°→45° (100ms), three pill cards (cornerRadius 100dp, elevation 6dp, 48dp tall, 24dp icon+12dp gap+label) stagger up 50ms apart with overshoot. Items: Scan QR code (ic_qrcode_scan), Scan image (ic_outline_add_photo_alternate_24), Enter manually (ic_outline_edit_24).
- Search: Material SearchView in toolbar, iconified by default, hint 'Search'. Query lowercased, split on whitespace, ALL tokens must substring-match at least one enabled field (issuer/name/note/group-names). On submit, toolbar title='Search', subtitle=query. Search bypasses group filter and disables drag reorder.
- Group filter chips: horizontal scroll row under toolbar, 12dp start/end padding, Material3 Filter chips, hidden when no groups. Includes per-group chips plus placeholder 'All' (clears filter) and 'No group' (ungrouped = null in filter set), plus a transient transparent 'Save' chip. Single-select by default (selectionRequired=true, 'All' default); multi-select is a setting.
- Empty state (only when zero entries AND no active search): QR icon 50x50dp, title 'No entries found' 18sp, body 'There are no codes to be shown. Start adding entries by tapping the plus sign in the bottom right corner' at 300dp wide centered. During active search the empty illustration is NOT shown.
- Error card: first list item, filled card colorErrorContainer bg, 10dp outer + 16dp inner padding, leading error icon + BOLD message both colorOnErrorContainer, spans both columns in tiles. Footer row always present: centered 'Showing N entries' (plural 'Showing 1 entry'), 14sp, N bold.
- Toolbar title 'Aegis', height actionBarSize (~56dp), lift-on-scroll. Actions: Search, Lock (ic_outline_lock_24), Sort (ic_outline_sort_24 -> Custom/A-Z name/Z-A name/A-Z issuer/Z-A issuer/Most used/Last used, single choice, Custom default), overflow Settings/About. RecyclerView has 8dp horizontal padding, clipToPadding=false.
- CopyBehavior: SINGLETAP (one tap copies) or DOUBLETAP (second tap within system double-tap timeout copies). When tap-to-reveal + single-tap copy both on, the first tap reveals and does NOT copy.
