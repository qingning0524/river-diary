# River Diary Design System

Status: Approved visual baseline v2, based on the provided evidence-report reference
Scope: macOS Personal Evidence OS, `codex/ui-redesign`

River Diary is a private evidence instrument, not a mood tracker, SaaS dashboard, or generic AI chat surface. The UI should help a user see what happened, inspect why the system believes it, correct uncertainty, and return to long-term change without feeling judged.

## Reference direction: Evidence Desk

The current visual baseline follows the provided “daily evidence report” reference, rebuilt as an implemented panel system rather than a set of per-screen cards:

- **Left:** date context and text-first navigation.
- **Center:** a daily evidence report with a strong date header, one primary action, compact facts, and the river timeline.
- **Right:** a short queue of evidence that needs the user's attention; selecting a row opens the source and correction controls in the inspector.
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
4. Evidence: sources, missing data, limits, replay.
5. Detail: raw records, derived facts, report versions.

Today uses: Day Brief → 2–3 core interactive cards → compact fact list → river timeline → evidence console. Day Brief shows at most three linkable day insights, each marked as an observation, user note, or material item needing explanation; it does not fill unused slots with synthetic conclusions.

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

Every colour is defined once, in `Palettes.swift`, as a light/dark pair **per palette**. Views reference the semantic token through `AppTheme`, never a hex value and never a system colour like `.orange` or `Color.accentColor` — a system accent leak would break the single-accent rule the moment a user changes their accent colour.

Eight palettes (海雾蓝 / 青瓷 / 暖阳 / 堇紫 / 莓红 / 墨青 / 可可棕 / 樱花粉) × two appearances, sixteen tokens each:

```text
canvas  sidebar  surface  strongSurface  editor  chip
border  separator  strongSeparator
ink  ink2  ink3
accent  accentSoft  gradientStart  gradientEnd
```

The tokens are not hand-picked hexes. Each set is generated from one recipe so that **the same lightness ladder holds in all sixteen combinations**; the recipe is documented in full at the top of `Palettes.swift`, and `PaletteDepthTests` enforces the bands below for every palette.

```text
token              target                       guarded band
canvas             white → 1.17                 canvas darker than surface, 1.08–1.30
chip               white → 1.15                 ≥ 1.10 vs surface
editor             white → 1.22                 darker than surface; ≥ 6 channel steps from chip
border             canvas → 1.26                1.18–1.60 vs canvas (white 10% in dark)
separator          white → 1.20                 ≥ 1.14 vs surface (white 8% in dark)
strongSeparator    canvas → 1.40                 ≥ 1.32 vs canvas
sidebar            canvas → 1.07                 rail must stay distinguishable from the canvas
ink2                white → 4.5+                 body text stays readable
ink3               white → 3.25                 ≥ 3.0, and always lighter than ink2
timelineSpine      accent 72% / 60% over surface  ≥ 2.2 vs surface, and lighter than accent
```

Why a ratio table instead of a list of hexes: the first palette set was a set of "柔和水洗色" whose neighbours differed by 1.04–1.16. The light panel outline on the canvas measured **1.040:1**, the dark row divider **1.009:1**, and the timeline spine (`accent` at 30%) **1.48:1**. That is why the app read as flat and unfinished — not a matter of taste, a matter of contrast. Every step now sits in a band that can be seen without becoming a hard line.

Three numbers live outside the ladder:

- `darkBorderAlpha` (0.10) / `darkSeparatorAlpha` (0.08) — white hairlines over a dark panel. They must differ: a panel outline is a stronger statement than a row divider.
- `settingsRailBlendAmount` (0.13) — how far `ink` is pressed into `sidebar`. After the light canvas was deepened, the previous 0.07 left the rail within 1–2 channel steps of the canvas and the two columns smeared together. `SettingsRailContrastTests` guards all sixteen combinations.
- `timelineSpineAlphaLight` (0.72) / `timelineSpineAlphaDark` (0.60) — the connector's opacity over the current panel fill.

Rules that follow from this table:

- One accent, used for selection, evidence, links and the primary action. `AppTheme.accent`.
- Status colour is always paired with a word. `StatusBadge("待确认", tone: .neutral)` carries meaning in the text; the tint is a second channel, never the only one.
- The four surface levels are distinct in both appearances: canvas < panel < floating, and a **raised** chip must never be the same colour as a **recessed** well. Light mode `chip` and `editor` had collapsed to the same grey (channel delta 0–2) before this ladder existed: a raised button and a sunken input field were literally one colour.
- `--tertiary-ink` is for hints and unrecorded values. Essential state never uses it.
- Change a colour, change this table, and let `PaletteDepthTests` move with it. A hex edited in `Palettes.swift` without the table is drift.

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

The summary reads from `TimelineAnalysisSnapshot`. Each of at most three insight rows shows its time, short claim, epistemic type and source detail, and opens the matching timeline item. A material unexplained item may occupy one row; ordinary missing time stays unknown without becoming a task. Data coverage describes what was recorded; it is not confidence in an interpretation.

### Core cards

Cards exist only when they are interactive entry points. Phase 1 shows at most 2–3 prominent cards, prioritizing Work & Learn and Footprints. Other domains use compact rows or expandable details.

Every card has: title, observed value, coverage and source state, primary action, evidence action, and correction action when applicable. A confidence score appears only when calibrated for that claim.

### Timeline

The timeline answers "what happened, and when". Its default `AI 整理` mode presents the day as an automatically prepared reading of nearby activity; `原始记录` remains the complete evidence table. Neither mode is a decorative river chart: no gradient spine, glowing app bubbles or animated water. App logos appear only as small local app identifiers beside an AI activity segment.

The 时间线 page leads with the day, then the ordered rows:

```text
TimelineWorkspaceView          the 时间线 destination
  pinned header                PageHeader + RiverDayRibbon (the whole day, always visible)
  day overview panel           four compact stats, a RiverRule, a coverage footnote
  journal panel                the day's writing, collapsed to a summary until edited
  timeline panel               AI 整理 / 原始记录 switch; digest or RiverTimelineView
```

`RiverDayRibbon` is the one-glance component: a 00:00–24:00 band, 6-hour guides, one segment per recorded item, and a "现在" tick on today. Ordinary days use an even 24-hour scale; local clock-change days map the actual 23/25-hour interval and identify the offset on the time cursor. It is pinned in the header rather than repeated in the body, because it answers a question about the whole day and the row list scrolls away. It exists because a row list can say what happened but only a laid-out day shows *where* the recorded evidence sits and how much of the day holds none. It is deliberately not a chart — no per-category rainbow, no axis drama.

The ribbon is also the page's **scrubber**. Hovering draws a crosshair with the time under the pointer and says "未记录" over empty time; pressing and dragging scrolls to evidence only when a row covers that moment. A folded 碎片带 expands and selects the member at that moment. A capture marker has a small hit area matching its visible tick. Clicking empty time never jumps to a nearby row. The translation from a moment to a row lives in `TimelineDisplayList.scrubTarget(for:rows:)`, the same code the list renders from, so the two cannot drift.

`TimelineAIDigestView` is the default. It shows one short overview, then activity segments grouped by time of day; each segment links back to its contributing `ActivityTimelineItem`s. Overview evidence can open an activity, capture, or the matching journal entry. User captures stay separate and optional. Unknown intervals keep their real start and end, and app-only input is rendered as app usage with unknown detail. A changed source marks the saved digest as old while the debounced refresh runs. If a candidate was not returned by the model, it still appears as a local factual row.

`AIAssistantStore.organizeTimeline` sends candidates only when the existing **自动采集与 AI 分析** preference is enabled and the model connection has been verified. Window titles remain behind their independent preference. The model returns candidate IDs, title and summary; local code validates IDs, grouping gaps and text lengths, then derives timestamps, durations and source sessions from local records. The normalized digest and source fingerprint are stored in `ai_results`; the related `AnalysisRun` is stored as `timelineDigest`. A repeated source fingerprint skips the request. The daily capture schedule and opening a date in Timeline both use this same path; live session updates debounce for 90 seconds.

The model is not allowed to promote app names into task completion, mood, location or intent. Segments without a window title or user annotation use local app/time wording, even if the model returned a more specific sentence. Unsupported JSON or IDs leave the local list readable and report the issue in the AI status line.

App logos are loaded from local application bundles using the recorded bundle ID, grouped by foreground duration and limited to two visible icons plus `+N`. Missing or uninstalled apps use a neutral placeholder. Capture cards do not use app logos.

The `原始记录` mode remains `RiverTimelineView`, an evidence table with five fixed columns:

```text
time column      54pt   start over end, monospaced digits, trailing-aligned
spine column     26pt   the node, and the connector drawn behind it
content                 title line, then one evidence line; badges ride the title line
duration column  78pt   duration, right-aligned
control column   22pt   the row's own affordance: run disclosure, or detail chevron
```

**Two lines per row, not three.** A row says *when* and *what happened*; the second line is the evidence — note → capture tag → 碎片带 (composition + span) → gap → window title → span vs foreground cover → app composition — plus where the row came from, with any part the title already stated removed. There used to be a third line for the source, and a trailing "· N 个原始片段" counter: two lines said the same thing, and the counter is an instrument's internal number, not something that happened. Both now live in the inspector and the context menu.

Six rules keep the rows honest, aligned and quiet:

- **The connector is continuous.** Rows carry no vertical padding of their own — the padding lives inside each column, and the content column supplies the row's height — so a background connector meets the next row's. It is trimmed at the first and last row so the series has two clear ends, and **the trim is computed after expansion**: expanding a 碎片带 inserts child rows, so the run itself is no longer last and its lower half must keep drawing.
- **The connector is visible.** `Color.timelineSpine` (`accent` blended into the current surface) reads at ≥ 2.2:1 in every palette, and stays lighter than a solid node so a node still reads as a node. A gap's connector uses the neutral `strongSeparator`, and a 碎片带 draws its connector dashed — the same line, saying "this stretch is made of many small pieces".
- **Alignment is structural, not arithmetic.** The connector repeats the row's own column grid inside its background and is centred in the same spine column that centres the node. Never position it with a computed `offset(x:)`: that drifts from the rendered layout the moment a column width or an inner padding changes.
- **Meaning never rests on colour alone.** An activity is a 19pt rimmed node with a solid centre; a gap is a hollow neutral ring; a written note is a warm square stamp; a 碎片带 is a rim with two small dots; a fragment inside an expanded run is a smaller dot, indented. Selection adds a larger soft halo. An empty list explains itself: "没有符合条件的节点" is not the same message as "这一天还没有记录".
- **Hover is not selection.** Hover is a neutral wash (`ink` at 5%) with the detail chevron fading in; selection is `accentSoft` with a 2.5pt accent capsule as its leading rule and `AppRadius.row`. The two must be one glance apart, because a hover state you mistake for a selection makes the list feel broken. (The raised `chip` fill cannot serve as the hover wash: in light mode `accentSoft` and `chip` are within 1.001:1 of each other.)
- **Affordances earn their ink.** The trailing detail chevron appears only on the hovered or selected row — a permanent column of chevrons is noise on a list where every row is already clickable. The exception is a 碎片带, whose disclosure is always drawn: it is a container, and its collapsed state has to be visible without hovering.

A category chip is drawn only for the two categories a reader cannot infer from the node and the app names (`系统`, `快记`). Rows for 工作 / 浏览 / 娱乐 used to carry one each, restating what the node colour and the statistics already said.

**碎片带 (fragment runs).** Measured on a real machine, 72% of a day's nodes are shorter than three minutes — one-minute app switches that no one needs to confirm. They are folded at the display layer: `ActivityTimeline.items` always holds every node (export, search, the evidence console and the daily review all read that), while the list reads `foldedItems`. Folding never changes a statistic and never drops a source record. The fold is visible and reversible: the day overview's 短切换 metric counts the folded nodes, an expanded run lists its members inline, and the panel footnote says where they went. `TimelineDisplayList` is the single owner of the folded row list, `ActivityTimelineEngine.foldFragments` of the folding itself.

**Switching is neutral.** App switching does not imply a loss of focus — most of it is multi-tool composition, which *is* work. So a run's name is decided by its **structure**, not by its switch count, and every phrase is a pattern description: "组合工作", "短切换", "分散在 N 个应用之间" — never "分心". `FragmentRunShape` classifies each run from app structure alone:

```text
intraApp       every member is the same app        "Chrome 里的 8 段短切换"（换窗口/换页面）
composedWork   dominant app ≥ 60% of foreground    "组合工作 · N 段"，第二行 "在 Xcode 与 终端 之间来回 3 次"
               AND the run returns to it ≥ 2 times
wandering      ≥ 3 apps, none above 40%            "N 段碎片"，第二行 "分散在 N 个应用之间"
mixed          everything else                     "N 段碎片"，第二行退回应用构成
```

The thresholds come from a measured distribution (2026-09-26, 17 days / 2,378 sessions / 133 runs on the author's machine): dominant-app share p50 = 0.74, so composition is the *typical* shape; the composed rule captures 40% of runs; wandering runs measured **zero** — that tier stays as a deliberate silence. Retune thresholds by re-running the distribution, never by eye. Two consequences worth keeping:

- **Structure beats category.** The composed runs' dominant categories on real data were 浏览/其他/沟通 — work-category runs measured zero, so any "is it work?" category condition would never fire. The ribbon draws composed runs' members at ordinary weight for structural reasons only.
- **The 专注 metric reads ≈ 0 on this data** because the keyword classifier maps the user's actual apps to 浏览/其他. That is a classifier-vocabulary gap, not a folding bug — and it will partly self-heal now that window titles are sampled every 25 s (the classifier reads the title too). Do not "fix" it by redefining 专注.

The review page may add **one sentence** under 时间分布, only when the range's busiest day reached 100 短切换 (p90 of the measured daily distribution is 121): "近 7 天里，9 月 25 日 的短切换最多（248 段），多为多工具之间的组合工作。" Default state is silence.

A 碎片带 is not an annotatable evidence item: it is a view-level aggregate, so it has no annotation key and the inspector offers an explanation instead of an 编辑 button that would save nothing (see `ActivityTimelineItem.isAnnotatable`).

A selected row uses `AppTheme.accentSoft` with a 2.5pt accent capsule as its leading rule and `AppRadius.row`. A reviewed row uses a text label such as `已确认`, never colour.

`ActivityClassifier.color(for:)` and `AppTheme.categoryTint(_:)` return one accent for every category, with only system noise and unrecorded time stepping down to the neutral tone. There is intentionally no per-category colour palette: that would turn the evidence report into a productivity chart. Both must track the `--accent` and `--tertiary-ink` tokens.

**Where the evidence comes from.** The row's second line is only as good as the data behind it, so the collector is part of this component:

- Window titles are sampled **every 25 seconds while a session is open**, not once at the moment of the app switch. Sampling at the switch alone loses almost everything: the target app frequently has no window yet at that instant (2,297 recorded fragments on the author's machine contained exactly one title), and a missing title is one of the inputs to "needs review". `WindowTitleSampling` decides what a reading means — a failed read never erases a title, a session with no title adopts the first one it gets, and a title that changes for two consecutive samples (50s) splits the session at the first sighting, with unread badges like "(3)" ignored so a notification does not cut a block in half.
- The sampling timer only exists while titles are enabled **and** accessibility is granted. When the permission is missing the timeline says so above the rows, with an action, once — dismissible, and permanently visible in Settings › 记录. Silently showing a day of "没有记录的时间" while the real cause is a missing permission is the failure mode this notice exists to prevent.
- **The keyword classifier cannot know every app.** On the measured machine it mapped the user's main tools to 浏览/其他, which left the 专注 metric effectively empty (4 minutes across 17 days) — a vocabulary gap, not a folding bug. Settings › 记录 › 应用类别 lets the user assign a category per app, and the mapping is applied at **read time**: history recomputes instantly, the raw day files and the V2 evidence layer are never rewritten, and removing a mapping falls back to re-deriving from app name + title. Interpretation is a layer over evidence, never baked into it — the same rule the annotation system follows.
- **Window titles stay inside three boundaries**: the encrypted local files and backups, the on-screen inspector, and AI requests behind their own explicit toggle. The review range's Markdown export carries aggregates only; the timeline Markdown builder is the only title-bearing export, declares it in its header, and currently has no UI entry.

The 今日 page must not repeat the timeline. It shows the report header, the day brief, entry cards, compact facts and the review queue (`evidenceInbox`), and reaches the timeline through an action — a second copy of the timeline on 今日 was removed for exactly this reason. The current live-capture state appears as a small status pill beside today's date, within the main page header; it is not a second card in the right rail or sidebar footer.

### Evidence console

The console and inspector share one right-hand column:

- **Review queue (`EvidenceConsoleView`)** — only the day's material unexplained evidence, capped at four prioritized cards. The queue is empty when nothing needs the user's attention; it never fills the rail with collection status or trust information. Starting capture is available from the Today's header when paused.
- **What earns a confirmation** — the review queue is a triage list, not a to-do list. A node enters it only when it is an **activity** (never a gap — sleep and being away are life, and the daily review already speaks for them, never a 碎片带 whose members are all under three minutes), **at least 20 minutes** (`reviewMaterialityThreshold` — the same unit the console's own copy uses: "系统无法解释的二十分钟"), **and has nothing that explains it**: no window title, no annotation. The first criterion used to be "≥ 3 minutes and missing a window title", which silently degraded into "≥ 3 minutes" once titles were not being captured — the queue was never empty, which is the opposite of what it was built for ("日常状态是空的"). A long block with a title explains itself and does not need confirming. Items are ordered by unexplained duration, longest first, capped at four. Each row offers 写一句 (inline one-line annotation, saved as the node's title and marked reviewed — the timeline renames itself immediately) and 不用管 (mark reviewed silently); tapping the row opens the full evidence detail.
- **The instrument does not record itself** — `ActivityClassifier.isRecordable` excludes River Diary (by bundle id and name). Time spent looking at the gauge is not observed life; it is excluded from new sessions and from aggregates.
- **Detail (`InspectorPanel`)** — the selected fact, user note, or inference; its time range, original sources, why it is shown, evidence detail, and correction controls. “依据细度” describes whether an app, window title, or user note is present; it does not score semantic truth. The panel distinguishes facts from explanations without relying on color alone.

Trust and storage information live under Settings › 隐私与备份, alongside encryption, recent collection, evidence coverage, backups and app lock. The compact review rows keep a tinted kind chip, source metadata in monospaced digits and a short “why this needs review” explanation. Below `AppLayout.sideInspectorBreakpoint` the column collapses and the selected detail opens as the floating Inspector instead.

### Buttons

Four button treatments, and no ad-hoc `background` + `foregroundStyle` pairs:

```text
.primaryCTA()                 filled accent; one per page, the page's main action
.secondaryCTA()               outlined
.smallAction(dark:)           compact inline action inside a panel or a row
.iconAction(prominent:)       a single SF Symbol, square hit area
```

### Scroll indicator

Scrolling surfaces never show the system NSScroller — it is chunky, stays resident under the "always show scrollbars" preference, and ignores `.scrollIndicators(.hidden)` on some containers. `riverScrollIndicators()` replaces it with two layers: an AppKit-level suppressor that closes the native scroller, and (macOS 15+) a 3pt hairline thumb in 22% ink that appears while scrolling and fades out shortly after. Wheel, trackpad and swipe scrolling are unaffected. Every `ScrollView` in the app goes through this primitive — a bare `ScrollView` is drift.

### Segmented picker

`RiverSegmentedPicker` is the only exclusive-mode switcher (复盘范围、记忆范围、对照周期、外观/密度). It is a chip-filled container with the selected segment raised on a `Color.surface` pill and a 1px border. The native `.pickerStyle(.segmented)` is banned: its filled-blue bezel belongs to System Settings, not to this instrument.

### Empty and partial states

Every empty state explains what is missing, why it matters, and the next action. An empty state inside a panel is chrome-less (`EmptyStateView(showsChrome: false)`) so it does not nest an outline inside an outline; `RiverInsetPanel` is the tinted note block used for guidance and boundary statements.


## Interaction and accessibility

- Keyboard: previous/next date, Today, range menu, workspace shortcuts, focus evidence, confirm/correct/undo.
- VoiceOver: announce workspace, selected date/range, insight type, time range, source state, and whether a row opens evidence or needs explanation.
- Focus order: date block → workspace navigation → Day Brief → core actions → cards → timeline → evidence console.
- Do not rely on hover. Use visible affordances and native button/list behavior. Hover is an enhancement, selection is state: hover may add a neutral wash or fade in an affordance, but the selected state is always the stronger one and every hover-only affordance has a keyboard path.
- Respect reduced motion. State changes must remain understandable without animation.
- Contrast must meet macOS accessibility expectations; color is never the only encoding.

## Mac window layouts

- **Wide (≥`AppLayout.sideInspectorBreakpoint`):** sidebar + main workspace + the right column shows only the prioritized review queue. When a timeline node is selected, the same column is taken over by `InspectorPanel` — queue and detail share one slot, so the rail never competes with the inspector.
- **Standard:** sidebar + main workspace; evidence detail opens as a drawer/Inspector; the console is hidden.
- **Narrow:** sidebar remains navigable; prominent cards become compact rows; evidence and replay open as a sheet or Inspector; never require horizontal scrolling for core actions.
- The minimum window size preserves date navigation, primary action, Day Brief, and the current evidence state.

## State language

```text
loading       preserve structure; show quiet progress
empty         explain absence; offer permission or manual action
partial       show available facts; name missing sources
success       show observed value, source coverage, and action
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
8. **GeometryReader is greedy in both directions** — a `GeometryReader` with only a `minHeight` has no upper bound. Inside a ScrollView the proposal is the ideal height and the greed stays invisible; move the same view into a fixed header (or any unscrollable container) and it swallows the window's real height and pushes the page out from under it — this is how 260pt of blank canvas appeared under the day ribbon, and `TimelineRibbonTests` exists because of it. Cap every `GeometryReader` with a fixed `.frame(height:)`; the only exception is the root layout reader in `RiverShell`.
9. **Does it render?** — a view-hierarchy check cannot see a broken connector, an off-centre node, or a filled ribbon. `Tests/RiverDiaryMacTests/TimelineRenderingTests.swift` renders components offscreen with `ImageRenderer` and asserts on the pixels; extend it when a change alters geometry, and never re-derive the numbers the view uses — measure the node out of the bitmap. `TimelineRowAnatomyTests.swift` is the same instrument for the row's *appearance*: it measures the spine's contrast at the node axis, the selected row's fill, and counts the dark pixels in the trailing control column to prove the chevron only appears when it should.
10. **Is the colour ladder intact?** — a hex edited in `Palettes.swift` is a claim about contrast. `PaletteDepthTests` recomputes WCAG contrast for every token in all eight palettes × both appearances; if a token was lightened or darkened, update the table in *Color tokens* and the test's band together, and say why in the comment.
11. **Does the change shuffle evidence or copy?** — the timeline reads `foldedItems`, everything else reads `items`. A change that moves a statistic onto the folded list, or makes the fold drop a node, is a data change wearing a display change's clothes.

Run the whole suite before packaging:

```bash
cd macos/RiverDiaryMac
source ../../scripts/select_xcode.sh && "$RIVER_SWIFT_EXECUTABLE" test --disable-sandbox
```

Then rebuild the shipping app so `dist/` is never stale:

```bash
make mac        # or ./macos/RiverDiaryMac/make_app.sh
```
