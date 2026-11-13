# Changelog

## Unreleased

- Prevent calendar flicker while typing in incremental search.
- Push tasks with meta-drag or `M-S-up` / `M-S-down` to make space.
  - Absorb gaps and move newly encountered overlap groups together.
  - Push across visible days, leaving initial overlaps and repeaters alone.
  - Stop at the displayed date boundaries.
  - Preview the whole push and undo it in one step.
- Respect Org tag inheritance for calendar colours and tag exclusions.
- Use the last mapped tag for colours, checking file tags, ancestor tags,
  then local tags. Previously, the first mapped local tag won.
- Show active timestamps in heading titles as calendar blocks, with labels
  updated after retiming.
- Display calendar titles using Org's visible text for links, emphasis,
  entities, and subscripts while preserving markup for editing and copying.

## v0.1.0 — 2026-11-09

- Faster calendar interaction
  - Cached views and prepared drag previews.
  - Fewer redraws and Org file reads.
- Simpler configuration
  - Fewer options; see [Defcustom cleanup](#defcustom-cleanup).
  - One slot size for keyboard steps and edits.
  - Time labels default to `12h`; use `24h` for 24-hour labels.
- Android compatibility
  - Improved touch editing and resize feedback.
  - Long-press vibration.
- Org clock strips
  - Finished, running, overnight, and overlapping clocks.
  - Editing for finished clocks.

### Bug fixes

- `org-timegrid-org-save` saves only the grid's source buffers, including the capture file.
- Scrolling and search
  - Navigation and refresh preserve the viewport.
  - Search keeps matched blocks visible.
- Selection and navigation
  - Selection survives heading edits; removal keeps the cursor in place.
  - Navigation visits off-grid starts and tied starts from left to right.
- Display
  - Fixed stale images across frames.
  - Short blocks occupy at least one calendar slot.

### Defcustom cleanup

#### Moved to defvar

These remain available as plain variables. Use `setq` instead of Custom:

`org-timegrid-agenda-heading-format`, `org-timegrid-android-header-title-style`,
`org-timegrid-android-scroll-scale`,
`org-timegrid-android-single-day-label-style`,
`org-timegrid-calendar-event-predicate`,
`org-timegrid-calendar-highlight-dates`, `org-timegrid-colors`,
`org-timegrid-copy-date-format`, `org-timegrid-copy-item-template`,
`org-timegrid-data-refresh-seconds`, `org-timegrid-header-title-style`,
`org-timegrid-highlight-current-day`, `org-timegrid-isearch-week-limit`,
`org-timegrid-keyboard-commit-delay`, `org-timegrid-org-after-create-hook`,
`org-timegrid-org-color-function`, `org-timegrid-org-entry-filter-function`,
`org-timegrid-org-filter-function`, `org-timegrid-org-repeater-history`,
`org-timegrid-org-show-repeaters`, `org-timegrid-single-day-label-style`.

#### Removed with alternatives

- `org-timegrid-cursor-step-minutes`: use `org-timegrid-slot-minutes`.
  The old name remains an obsolete alias.
- `org-timegrid-pixels-per-minute`: use `org-timegrid-default-zoom` or
  text-scale commands.
- `org-timegrid-org-exclude-todo-states`,
  `org-timegrid-org-exclude-properties`: use
  `org-timegrid-org-filter-function`.
- `org-timegrid-edge-pixels`: use internal `org-timegrid--resize-pixels`.
- `org-timegrid-edge-slop`: use internal `org-timegrid--resize-slop`.

#### Removed without alternatives

Remove these from your configuration:

`org-timegrid-now-alignment`, `org-timegrid-buffer-name`,
`org-timegrid-copy-day-separator`, `org-timegrid-android-scroll-max-step`,
`org-timegrid-block-gap`, `org-timegrid-midnight-grip-pixels`,
`org-timegrid-nesting-indent`, `org-timegrid-title-clearance`,
`org-timegrid-cursor-opacity`, `org-timegrid-region-opacity`,
`org-timegrid-all-day-lane-height`, `org-timegrid-compact-shadow-pixels`,
`org-timegrid-corner-radius`.

## v0.0.5 — 2026-10-23

- Added `org-timegrid-time-format` to choose `12-hour` or `24-hour` time labels (default: `24-hour`).
- Refined time labels with smaller AM/PM suffixes, compact block ranges, and stronger grid-label contrast.
- Made task suggestion durations and file locations easier to read.
- Fixed agenda strips showing “TODAY” when displaying another date.
- Fixed calendar scaling to use the font’s actual pixel size.

## v0.0.4 — 2026-10-18

### Features

- Task suggestions now show the last block’s duration, tags, and file location in aligned columns.
- Calendar blocks now have translucent backgrounds and cleaner spacing, making the grid easier to see.
- Smoother calendar navigation and faster loading of long-running repeating events.

### Bug fixes

- Calendar undo now protects changes made directly in your Org files. Failed edits involving several blocks no longer leave partial changes behind.
- Deleting several repeating blocks now applies your chosen scope consistently.
- Cancelled drags no longer leave previews behind or move blocks to an outdated position.
- Long-press editing now works in the all-day row on Android.
- Fixed selecting blocks in narrow windows and blocks that continue from another day.
- Selecting all-day events no longer scrolls the hourly grid. Adding a clock time correctly turns an all-day event into a timed block.
- Fixed searching across weeks when showing fewer than seven days.
- Turning off the Org Agenda integration now removes its calendar strip.
- Fixed missing block durations with older Org versions.
- Improved date validation and handling of overnight time ranges.
- Failed cuts now preserve your clipboard. Cycling through pasted items checks the next item before removing the previous paste.
- Titles containing template placeholders are now preserved as typed.

## v0.0.3 — 2026-10-13
- Repeating events now preserve history when editing or deleting just one occurrence, future occurrences, or the whole series. Added configurable history cutoffs and undo support.
- Plain headings with active date-only timestamps now appear in completion when adding another calendar range.
- Aligned hour labels with their grid lines.
- Reloading the calendar now preserves custom isearch bindings.
- Updated installation instructions for MELPA and fixed melpazoid tooling installation in CI.

## v0.0.2 — 2026-09-30
- Fixed block selection when nearby start times share a cursor slot; navigation now selects blocks directly by ID.
- Keyboard time moves now snap timed blocks to the configured slot interval while preserving duration. Day moves and resizing retain their existing precision.
- Fixed cutting and pasting multiple blocks assigning their timestamps to the wrong Org heading.
- Cleaned up package metadata, autoloads, hooks, and deprecated forms for MELPA; added melpazoid checks in CI.

## v0.0.1 — 2026-09-27
- Added `org-timegrid-range-alignment`: set it to `center` to center today or a chosen date, with even day counts placing it just right of center. The default remains `week`.
- Opening the calendar now centers the current time vertically on first display; later visits retain the viewport. Going to today also centers the current time, and manual refresh reloads events and returns to today.
- The calendar cursor now stays within the configured visible hours.
- Repeating events now display a repeat icon in both timed blocks and the all-day rail.
- `C-c C-o` now runs Org's open-at-point command on the selected calendar entry's heading.
- The active region's time range now appears in the echo area while setting the mark, moving, or exchanging point and mark.
- Fixed isearch matching across adjacent event titles.
- Static calendar tiles now share one image map calculation to reduce rendering work.

## 2026-09-20
- Calendar regions now treat point and mark as boundaries, matching normal Emacs regions in both movement directions.
- Moving and resizing events now redraw immediately from the updated in-memory state instead of reloading the Org backend after every edit.
- Android keyboard commands now appear in the echo area without a delay.

## 2026-09-17
- The agenda strip's one-day calendar now follows whatever day the Org Agenda buffer is showing, instead of always displaying today.

## 2026-09-15
- Title search (`C-s`/`C-r`) now uses real Emacs isearch instead of a lookalike: highlighting, `RET`, `C-g`, and search history all work as they do in any buffer, and it searches across up to 52 adjacent weeks.
- Added a region: `C-SPC` sets a mark and moving the cursor extends a highlighted time span; copy, cut, delete, and paste act on the whole region.
- Copy/cut go through the real kill ring (`M-w`/`C-w`/`C-y`, `M-y` to cycle), and multi-block edits undo as one step.

## 2026-09-10
- Moving the cursor over a block, or hovering it with the mouse, now shows its full `[start-end] title` in the echo area or tooltip.

## 2026-09-07
- Added Android support: touch scrolling, long-press editing, gestures that avoid popping up the on-screen keyboard, and a one-day layout on phones. Since Android's bundled SVG renderer can't draw text, calendar labels are drawn from a bundled font outline set instead (regenerable from any font via `builds/generate-android-font.py`).

## 2026-09-05
- Added filtering options for which Org headings appear on the calendar: hide done items, exclude by tag, TODO state, or property, or supply your own filter function (`org-timegrid-org-filter-function`).

## 2026-09-04
- The colored tint on today's column is now off by default (`org-timegrid-highlight-current-day` turns it back on).

## 2026-09-02
- Added zoom for the calendar: `C-x +` / `C-x C--` / `C-x C-0` zoom in, out, and reset, built on Emacs's standard text-scale commands, with `org-timegrid-default-zoom` for the starting level.
- `org-timegrid-days` now controls how many consecutive days the view shows, so you can set up a 3-day or workweek view instead of always seeing 7 days.

## 2026-08-31
- Dates with events now show in bold, colored text in Emacs's standard date picker (e.g. the `j` jump-to-date prompt), toggleable and filterable.
- Fixed dragging a block between the all-day rail and the timed grid, which used to jump or misplace the block mid-drag.

## 2026-08-26
- Added a sticky all-day row above the week grid: all-day events show as bars there, and you can click, drag to move, drag an edge to resize, or double-click to open them, same as timed blocks, with up to 5 stacked lanes before overflow.
- Org headings with only a date (no clock time), or a date range, now render as all-day events in that rail.

## 2026-08-25
- `org-timegrid-org-capture-template` lets you define where and how new Org entries created from the calendar are written, with placeholders for title, time range, start, end, and duration.
- Dragging or copying a block onto a new time now adds a second timestamp to the same Org entry instead of duplicating the whole heading. Added keybindings that run Org commands on the selected calendar entry: tags, TODO state, priority, clock in/out, notes, effort, refile, and archive.

## 2026-08-24
- Creating a block on an empty slot now offers completion against your existing unfinished TODO headings; picking one adds the new time to that heading instead of always creating a new one. Typing non-matching text still creates a new heading.
- Switched to tiled rendering for faster calendar interaction; held movement/resize keys now update the display immediately and only write to Org after you pause.

## 2026-08-23
- Initial release.
