# Changelog

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
