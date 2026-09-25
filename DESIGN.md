# River Diary Design System

Status: Approved visual baseline v2, based on the provided evidence-report reference
Scope: macOS Personal Evidence OS, `codex/ui-redesign`

River Diary is a private evidence instrument, not a mood tracker, SaaS dashboard, or generic AI chat surface. The UI should help a user see what happened, inspect why the system believes it, correct uncertainty, and return to long-term change without feeling judged.

## Reference direction: Evidence Desk

The current visual baseline follows the provided “daily evidence report” reference, rebuilt as an implemented panel system rather than a set of per-screen cards:

- **Left:** date context and text-first navigation.
- **Center:** a daily evidence report with a strong date header, one primary action, compact facts, and the river timeline.
- **Right:** an evidence console that explains the judgment, lists the records used, and offers quick questions.
- **Material:** warm paper canvas, opaque off-white panels, 1px hairlines, small radii, and generous whitespace.
- **Accent:** one restrained steel blue for selection, primary actions, evidence bars, links, and timeline nodes.
- **Language:** every conclusion carries an epistemic label such as `事实`, `推断`, `部分`, or `可纠正`.

“Modern panel” here means modern craft, not modern ornament: one radius scale, layered surfaces with a real elevation order, consistent header and row anatomy, and aligned gutters — held inside the restrained character above. Floating and rounded is reserved for things that genuinely float (sheets, drawers, the lock gate); a page is still a stack of quiet, outlined panels, and there are no gradient fills, decorative blobs, or oversized hero cards.

This is a style reference, not a pixel copy. The product keeps native macOS behavior, keyboard access, dark mode, and the existing evidence model.

## Product thesis

- The left sidebar owns the selected date and day/week/month range.
- Today is a restrained dashboard, not the whole product.
- The river timeline shows how a day flowed.
- The evidence console explains why a fact or inference exists.
- Facts, inferences, unknowns, and user feelings are visibly distinct.
- Unknown data is never displayed as zero.
- The interface should feel calm, exact, native, and useful at 3am.

## Information hierarchy

1. Orientation: selected date, current workspace, source coverage.
2. Day Brief: what happened in one scan.
3. Core actions: open timeline, ask, review, correct.
4. Evidence: sources, confidence, missing data, replay.
5. Detail: raw records, derived facts, report versions.

Today uses: Day Brief → 2–3 core interactive cards → compact fact list → river timeline → evidence console.

## Navigation

The sidebar contains a compact date block at the top: previous day, current date, next day, Today, and a popover for day/week/month range. It does not expand into a full calendar by default.

```text
[date block]
RIVER: Today / Timeline / Daily Review
UNDERSTAND: Health / Footprints / Work & Learn
MEMORY: Ask / Progress
SYSTEM: Database / Sources / Settings
```

The selected date is owned by a Shell-level `DateContext`. Workspace changes preserve it. Keyboard navigation and VoiceOver must announce the selected date and range.

## Color tokens

Every colour is defined once, in `Theme.swift`, as a dynamic light/dark pair. Views reference the semantic token, never a hex value and never a system colour like `.orange` or `Color.accentColor` — a system accent leak would break the single-accent rule the moment a user changes their accent colour.

```text
                                light      dark        role
--workspace                     #F1F0EB    #111210     page canvas behind panels
--sidebar-surface               #EDECE6    #171816     navigation rail / inspector drawer
--surface                       #FCFBF8    #1B1C1A     the fill of every panel
--strong-surface                #FFFFFF    #232421     floating surfaces: sheets, drawers, banner
--editor                        #F0EFE9    #131412     recessed wells: text editors, inputs
--chip                          #EFEEE9    #262724     small chips and raised rows
--border                        #DAD8D1    white 14%  the 1px panel outline
--separator                     #E4E2DC    white 9%   the 1px divider between rows
--strong-separator              #D3D1C9    #3A3B37    page-level section rule

--ink                           #232427    #F2F0EA    primary text
--secondary-ink                 #63656A    #B4B4AF    bodies, values, metadata
--tertiary-ink                  #8E9096    #8A8B87    hints and unrecorded values only

--accent                        #3F678F    #8AB4DD    selection, evidence, primary action
--accent-soft                   #E6EDF6    #23364C    selected row / chip background
--cta-background                #3F678F    #6F9AC7    filled primary button
--ok / --warning / --error      green      amber       red, each with a `-soft` tint pair
```

Rules that follow from this table:

- One accent, used for selection, evidence, links and the primary action. `AppTheme.accent`.
- Status colour is always paired with a word. `StatusBadge("待确认", tone: .neutral)` carries meaning in the text; the tint is a second channel, never the only one.
- The three surface levels are distinct in both appearances: canvas < panel < floating. A panel must never be the same colour as the surface it sits on.
- `--tertiary-ink` is for hints and unrecorded values. Essential state never uses it.

## Typography

One scale in `AppTypography`, so no view writes a raw `.system(size:)`. Sizes step by 1–2pt to keep dense evidence tables readable.

```text
pageTitle     22 semibold    one per page
sheetTitle    17 semibold    sheets, modals, inspector section heads
sectionTitle  15 semibold    panel and section titles
rowTitle      13 medium      row titles: above body text, below section titles
primary       14             primary reading text
secondary     13             list bodies, descriptions, panel prose
label         12 medium      form labels, compact list text
metadata      11             captions, sources, timestamps
micro         10             the smallest text allowed: dense counters, inline hints
numeric       12 semibold    monospaced digits: clocks, durations, counts
metricSmall   18 semibold    an inline metric inside a panel
metric        26 semibold    the headline metric of a page
mono          11             source labels, run IDs, evidence metadata
kicker        10 semibold    monospaced, uppercase-style group labels
reportTitle   28             the daily report date only
```

- Native system typography everywhere. `Font.editorial` and `Font.ui` both resolve to the system face; they exist only for call-site compatibility, and new code uses `AppTypography`.
- A raw `.system(size:)` in a view is reserved for icon glyphs (`Image(systemName:)`), never for text.
- Monospaced digits are required for anything that sits in a column: times, durations, counts, deltas.

## Surfaces and components

### The panel system

There is exactly one panel primitive. `RiverPanel` is built from a header and a body, and every card, group and section in the app is an instance of it.

```text
RiverPanel(title:systemImage:detail:accent:trailingText:level:padding:)   a titled panel
RiverPanel(level:padding:)                                                a bare panel
RiverPanelRow(title:detail:systemImage:showsDivider:)                     a row in a panel
RiverValueRow(title:value:detail:valueTint:showsDivider:)                 a label / value / source row
RiverPanelTitle / RiverIconWell / RiverSectionHeading / RiverGroupLabel    header anatomy
RiverRule / RiverRowDivider                                               the only two 1px rules
RiverStat / RiverStatStrip / RiverStatDivider                             a metric row inside a panel
```

Anatomy of a panel:

1. A header band at least 44pt tall: optional icon well or 3pt accent bar, then the title, then an optional detail line, then optional trailing text.
2. The body, padded by `AppSpacing.panelPadding`.
3. A 1px `--border` outline around the whole panel, radius `AppRadius.panel`.

There is deliberately **no** rule between the header and the body, the way macOS System Settings groups a header above its box. When a panel needs to separate two regions inside its body — a filter bar above a list, say — it introduces an explicit `RiverRule()` at that boundary rather than relying on the header.

Rows inside a panel use `RiverPanelRow` or `RiverValueRow` and are separated by `RiverRowDivider`, which is inset so it lines up with the row's text rather than the panel edge. Because a row cannot know its own position, the last row in a panel passes `showsDivider: false` (or the loop guards on its index).

Three elevation levels, and only three:

```text
.inline     outline only, no shadow     panels inside a scrolling page
.raised     outline + 5pt soft shadow   panels on a rail, a drawer, or a header band
.floating   outline + 20pt shadow       sheets, the lock gate, the recovery gate, the feedback banner
```

`.inline` is the default and carries no shadow, deliberately: dozens of shadowed panels in one scroll view is both slow and visually noisy. Depth on a page comes from the canvas/panel colour step, not from shadow.

### Page scaffold

Every destination is one of two shapes, and both put their content on the same line.

```text
RiverPage              header scrolls with the content (most destinations)
RiverHeaderBand        header stays put, body scrolls (记忆, 设置)
  └── RiverPageBody    the shared scrolling column, optionally lazy
```

Both use `AppSpacing.headerTop` (20) below the toolbar, `AppSpacing.page` (24) as the side gutter, `AppSpacing.headerBottom` (16) above the first panel, and `AppLayout.contentMaxWidth` (920) as the reading width. **One content width for every destination** — dashboards and timelines used to run wider (1000/1040) and Ask/数据库 narrower (760/820), which made the版心 jump when switching pages; that inconsistency is gone. A page never hand-rolls `ScrollView` + padding + background.

### Page header

One anatomy for every destination: a 22pt title, one line of context, and actions on the right. There is no page-level kicker — the title already says where you are, and mixed "SYSTEM" / "TIMELINE" / "设置" labels were an inconsistency, not a hierarchy.

### Sidebar date block

Compact, always visible, keyboard accessible. Shows date and range, not a full calendar. The active workspace and selected date must be visually distinct.

### Day Brief

One concise summary plus observed activity duration, evidence coverage, and status. It must never present an unsupported single life score.

### Core cards

Cards exist only when they are interactive entry points. Phase 1 shows at most 2–3 prominent cards, prioritizing Work & Learn and Footprints. Other domains use compact rows or expandable details.

Every card has: title, observed value, coverage/confidence, state, primary action, evidence action, and correction action when applicable.

### Timeline

The timeline answers "what happened, and when". It is an evidence table, never a decorative river chart: no gradient spine, glowing app bubbles, animated water or app-icon collage.

The 时间线 page leads with the day, then the ordered rows:

```text
TimelineWorkspaceView          the 时间线 destination
  TimelineDayOverview          panel: four stats, a RiverRule, the day ribbon, a coverage footnote
  journal panel                the day's writing, collapsed to a summary until edited
  timeline panel               filter bar, RiverRule, RiverTimelineView
```

`RiverDayRibbon` is the one-glance component: a fixed 00:00–24:00 band, 6-hour guides, one segment per recorded item, and a "now" tick on today. It exists because a row list can say what happened but only a laid-out day shows *where* the recorded evidence sits and how much of the day holds none. It is deliberately not a chart — no per-category rainbow, no axis drama.

Row anatomy (`RiverTimelineView`), all four columns fixed so the eye can scan one column at a time:

```text
time column     54pt   start over end, monospaced digits, trailing-aligned
spine column    26pt   the node, and the connector drawn behind it
content                title, category chip, favourite and 待确认 badges, summary, source
duration column 78pt   duration, right-aligned, then a disclosure chevron
```

Three rules keep the rows honest and aligned:

- **The connector is continuous.** Rows carry no vertical padding of their own — the padding lives inside each column, and the content column supplies the row's height — so a background connector meets the next row's. It is trimmed at the first and last row so the series has two clear ends.
- **Alignment is structural, not arithmetic.** The connector repeats the row's own column grid inside its background and is centred in the same spine column that centres the node. Never position it with a computed `offset(x:)`: that drifts from the rendered layout the moment a column width or an inner padding changes.
- **Meaning never rests on colour alone.** A recorded activity is a solid round accent node, a gap is a hollow neutral ring, and a written note is a square. An empty list explains itself: "没有符合条件的节点" is not the same message as "这一天还没有记录".

A selected row uses `AppTheme.accentSoft` with a 2.5pt accent capsule as its leading rule and `AppRadius.row`. A reviewed row uses a text label such as `已确认`, never colour.

`ActivityClassifier.color(for:)` and `AppTheme.categoryTint(_:)` return one accent for every category, with only system noise and unrecorded time stepping down to the neutral tone. There is intentionally no per-category colour palette: that would turn the evidence report into a productivity chart. Both must track the `--accent` and `--tertiary-ink` tokens.

The 今日 page must not repeat the timeline. It shows the report header, the day brief, entry cards, compact facts and the review queue (`evidenceInbox`), and reaches the timeline through an action — a second copy of the timeline on 今日 was removed for exactly this reason.

### Evidence console

The secondary context surface shows the selected fact or inference, source records, time range, coverage, confidence, correction controls, and replay entry. It must distinguish facts from explanations without relying on color alone.

Each evidence item is a `RiverPanel` at `.inline`, with a tinted `kind` chip, the source metadata in monospaced digits, and a short “why this judgment” explanation. When the console is closed, the same content opens as the native Inspector without changing the main report layout.

### Buttons

Four button treatments, and no ad-hoc `background` + `foregroundStyle` pairs:

```text
.primaryCTA()                 filled accent; one per page, the page's main action
.secondaryCTA()               outlined
.smallAction(dark:)           compact inline action inside a panel or a row
.iconAction(prominent:)       a single SF Symbol, square hit area
```

### Segmented picker

`RiverSegmentedPicker` is the only exclusive-mode switcher (复盘范围、记忆范围、对照周期、外观/密度). It is a chip-filled container with the selected segment raised on a `Color.surface` pill and a 1px border. The native `.pickerStyle(.segmented)` is banned: its filled-blue bezel belongs to System Settings, not to this instrument.

### Empty and partial states

Every empty state explains what is missing, why it matters, and the next action. An empty state inside a panel is chrome-less (`EmptyStateView(showsChrome: false)`) so it does not nest an outline inside an outline; `RiverInsetPanel` is the tinted note block used for guidance and boundary statements.


## Interaction and accessibility

- Keyboard: previous/next date, Today, range menu, workspace shortcuts, focus evidence, confirm/correct/undo.
- VoiceOver: announce workspace, selected date/range, card title, observed value, coverage, confidence, and state.
- Focus order: date block → workspace navigation → Day Brief → core actions → cards → timeline → evidence console.
- Do not rely on hover. Use visible affordances and native button/list behavior.
- Respect reduced motion. State changes must remain understandable without animation.
- Contrast must meet macOS accessibility expectations; color is never the only encoding.

## Mac window layouts

- **Wide:** sidebar + main Today workspace + persistent evidence console.
- **Standard:** sidebar + main workspace; evidence console opens as a drawer/Inspector.
- **Narrow:** sidebar remains navigable; prominent cards become compact rows; evidence and replay open as a sheet or Inspector; never require horizontal scrolling for core actions.
- The minimum window size preserves date navigation, primary action, Day Brief, and the current evidence state.

## State language

```text
loading       preserve structure; show quiet progress
empty         explain absence; offer permission or manual action
partial       show available facts; name missing sources
success       show observed value, coverage, confidence, action
ai-failed     preserve facts; explain unavailable interpretation; retry
needs-review  show inference and evidence; confirm, edit, or ignore
stale         show last valid report and why it is outdated
```

## Voice and copy

Use factual, non-moralizing language: “31 minutes of video unrelated to the selected project” rather than “you wasted 31 minutes.” Use “unknown” when evidence is insufficient. Every AI interpretation must offer “why this judgment” and “correct it.”

## Phase 1 visual acceptance

- Left date context is always available and never duplicated in the main content.
- Today can be understood in ten seconds without opening a detail page.
- No generic card mosaic, oversized hero, gradient background, or ornamental icon grid.
- Timeline and evidence console remain visibly connected.
- Loading, empty, partial, failed, stale, and needs-review states are specified before implementation.

## How to check a change against this document

1. **Surface** — is the new thing a `RiverPanel` (or a `RiverPageBody` inside a `RiverPanel`)? If it draws its own `background` + `overlay` + `cornerRadius`, it is a new surface primitive and should not exist.
2. **Shape** — does every radius and spacing come from `AppRadius` / `AppSpacing`, multiplied through `@Environment(\.riverDensity)`? A raw `cornerRadius: 8` or `padding(14)` is drift.
3. **Type** — does every text font come from `AppTypography`? A raw `.system(size:)` is only valid on an `Image(systemName:)`.
4. **Colour** — does every colour come from `Color.*` or `AppTheme.*`? `.orange`, `.red`, `Color.accentColor`, `#2C8158` are drift, and the last one silently ignores dark mode.
5. **Position** — is this the last row in its panel? Then it must pass `showsDivider: false`.
6. **Elevation** — is `.raised` or `.floating` justified? Inside a scrolling page, `.inline` is correct.
7. **Cross-element alignment** — does anything line up across rows or across panels (a connector, a column, a rule)? Then it must share the same column grid rather than a computed offset. Reach for `TimelineRowMetrics`-style shared constants, and put the element inside a `background`/`overlay` that repeats the grid.
8. **Does it render?** — a view-hierarchy check cannot see a broken connector, an off-centre node, or a filled ribbon. `Tests/RiverDiaryMacTests/TimelineRenderingTests.swift` renders components offscreen with `ImageRenderer` and asserts on the pixels; extend it when a change alters geometry, and never re-derive the numbers the view uses — measure the node out of the bitmap.

Run the whole suite before packaging:

```bash
cd macos/RiverDiaryMac
source ../../scripts/select_xcode.sh && "$RIVER_SWIFT_EXECUTABLE" test --disable-sandbox
```

Then rebuild the shipping app so `dist/` is never stale:

```bash
make mac        # or ./macos/RiverDiaryMac/make_app.sh
```

