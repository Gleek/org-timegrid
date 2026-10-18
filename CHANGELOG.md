# Changelog

## v0.0.4 — 2026-10-18
- Preserved explicit timestamp range durations with older Org versions bundled in Emacs 29.
- Task completion now shows aligned annotations for the latest explicitly recorded block duration, inherited tags, and file/outline context, using Emacs's built-in completion API without a Marginalia dependency.
- Simplified calendar rendering, cached timed and all-day layouts, and fixed duplicate painting of selected blocks and hit testing in narrow windows.
- Made bulk Org edits atomic, including nested transactions and rollback after errors. Calendar undo/redo now checks all source buffers and refuses to overwrite intervening source edits.
- Fixed bulk deletion of repeating occurrences to reuse the chosen scope and resolve remaining occurrences after the series changes. Old fixed-interval repeaters now skip directly to the queried dates.
- Fixed cancelled mouse/touch gestures leaving previews behind, releases outside the calendar using stale targets, and Android long-press handling in the all-day rail.
- Made events continuing into the visible range reachable by keyboard and kept clicks on continuation segments on the clicked day. All-day navigation no longer scrolls the timed grid.
- Fixed cross-week search horizons for non-seven-day views and cached empty search results. Disabling the agenda integration now removes its calendar strips and cancels pending theme refreshes.
- Preserved literal capture/clipboard template values, validated pasted calendar data before undoing a previous paste, and kept the kill ring intact when cutting fails. Improved date/time validation and overnight range input.
- Added regression coverage and a shared ERT runner, expanded CI checks, and updated MELPA lint support and development documentation.

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
