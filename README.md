# org-timegrid

`org-timegrid` is a beautiful SVG week calendar for Org mode. It reads timed active
timestamps from your Org files and writes edits back to their source headings.

Create, move, resize, copy, rename, and remove calendar blocks with the mouse
or keyboard. The same renderer can add a compact, read-only day view to an
existing Org Agenda.



https://github.com/user-attachments/assets/fa93bdc9-91cb-4582-8d44-47a8461c2007



## Screenshots

The palette comes from the theme, and is redrawn when the theme changes.

| | |
|---|---|
| ![Week, light](screenshots/week-light.png) | ![Week, dark](screenshots/week-dark.png) |

Agenda view:

| | |
|---|---|
| ![Agenda, light](screenshots/agenda-light.png) | ![Agenda, dark](screenshots/agenda-dark.png) |


## Requirements and installation

You need Emacs 29.1 or later with SVG support and Org 9.6 or later. Check SVG
support with `(image-type-available-p 'svg)`. There are no other dependencies.

With [Elpaca](https://github.com/progfolio/elpaca):

```elisp
(use-package org-timegrid
  :ensure (:host github :repo "Gleek/org-timegrid")
  :commands (org-timegrid-week)
  :bind ("C-c c" . org-timegrid-week))
```

For a manual install, put the `.el` files on `load-path`, evaluate `(require
'org-timegrid-org)`, then run `M-x org-timegrid-week`.

## What appears on the calendar

The Org backend reads active timestamps with a start time. They may be plain
timestamps or values attached to `SCHEDULED` and `DEADLINE`.

```org
* TODO Design review :work:
<2026-08-24 Mon 14:00-15:30>

* TODO Standup
SCHEDULED: <2026-08-24 Mon 09:00-09:15>

* Call the vendor
<2026-08-24 Mon 15:00>
```

The last heading appears even though it has no TODO keyword. A timed active
timestamp is enough to put a heading on the calendar. A timestamp without an
end uses `org-timegrid-default-duration-minutes`, which defaults to 30 minutes.

Date-only and inactive timestamps do not appear on the time grid. A separate
date-only rail is planned.

Repeaters are expanded into dated occurrences for display. Moving or resizing
one occurrence edits the series anchor and preserves its repeater and warning
modifiers. Edits leave source buffers modified but unsaved, like Org Agenda
commands. Press `u` in the calendar to undo the edit in the Org buffer it
changed.

Set `org-timegrid-org-show-repeaters` to nil to omit repeating timestamps and
all of their occurrences.

## Week view

Run `M-x org-timegrid-week` to open the week containing today.

### Mouse

| Gesture                           | Action                                |
|-----------------------------------|---------------------------------------|
| Drag empty space                  | Create an entry for that range        |
| Drag a block                      | Move it                               |
| Drag a block's top or bottom edge | Resize it                             |
| super-drag a block                | Duplicate it as an independent entry  |
| shift-drag a block                | Add another time to its source entry  |
| Click                             | Put the cursor there                  |
| Double-click a block              | Visit its Org heading                 |
| Wheel                             | Scroll the day                        |

Mouse edits snap to 15 minutes and use a 15-minute minimum. Release commits a
drag. Press `C-g` before releasing to cancel it.

### Keyboard

The calendar has one cursor. A block is selected when the cursor sits on the
slot where that block begins. This keeps keyboard and mouse selection in sync
after redraws.

| Key                       | Action                                                                               |
|---------------------------|--------------------------------------------------------------------------------------|
| `C-n` / `C-p`, up/down    | Move the cursor by 15 minutes                                                        |
| `C-f` / `C-b`, left/right | Move through overlapping lanes, then days                                            |
| `C-v` / `M-v`, `SPC`      | Move by one screen                                                                   |
| `C-a` / `C-e`             | Go to the first or last slot of the day                                              |
| `C-l`                     | Center the view on the cursor                                                        |
| `n` / `p`                 | Select the next or previous block                                                    |
| `RET`                     | Visit the selected block, or create one at the cursor                                |
| `C-g`                     | Hide the cursor                                                                      |
| `M-down` / `M-up`         | Move the selected block by 15 minutes                                                |
| `M-right` / `M-left`      | Move the block by one day                                                            |
| `S-down` / `S-up`         | Move the end time                                                                    |
| `C-S-up` / `C-S-down`     | Move the start time                                                                  |
| `t`                       | Enter a new time or range                                                            |
| `e`                       | Rename the heading                                                                   |
| `d`, Delete               | Remove its time, then optionally delete the heading                                  |
| `M-w`, then `C-y`          | Duplicate the block as an independent entry                  |
| `C-w`, then `C-y`          | Move the block by cutting and restoring its timestamp        |
| `C-u C-y`                  | Paste by adding another time to the copied entry              |
| `u`, `C-/`, `C-x u`       | Undo the last calendar edit                                                          |
| `:`, `C-c C-q`            | Change the selected entry's tags                                                      |
| `C-c C-t`                 | Change the selected entry's TODO state                                                |
| `,`, `C-c ,`              | Set the selected entry's priority                                                     |
| `i`                       | Clock in to the selected entry                                                        |
| `O`                       | Clock out                                                                             |
| `z`, `C-c C-z`            | Add a note to the selected entry                                                      |
| `C-c C-x e`               | Set the selected entry's effort                                                       |
| `C-c C-w`                 | Refile the selected entry                                                             |
| `$`                       | Archive the selected entry                                                            |
| `b` / `f`, `M-b` / `M-f`  | Shift by a day or week                                                               |
| `j` / `.`                 | Jump to a date or today                                                              |
| `g`                       | Reload the week from the backend                                                     |
| `q`                       | Quit                                                                                 |
| `C-s`, `C-r`              | Isearch like forward or backward search. `RET` keeps the current match, `C-g` resets |

The Org backend can wrap other interactive commands for use in the calendar.
`org-timegrid-org-command` runs a command at the selected source heading.
`org-timegrid-org-agenda-command` finds the corresponding line in a live Org
Agenda buffer and runs the command there. Both wrappers return to the calendar
and reload it without resetting the cursor or scroll position.

```elisp
(keymap-set org-timegrid-mode-map "i"
            (org-timegrid-org-command #'org-clock-in))
(keymap-set org-timegrid-mode-map ","
            (org-timegrid-org-agenda-command #'org-agenda-priority))
```

The Agenda wrapper signals a user error when no live Agenda buffer contains
the selected entry. Prefer the Org wrapper when the underlying Org command is
available, since it does not depend on an Agenda view being open.


## Org Agenda strip

Enable the optional integration after loading `org-timegrid-agenda`:

```elisp
(require 'org-timegrid-agenda)
(org-timegrid-agenda-mode 1)
```

Org continues to build the agenda buffer. A finalize hook inserts a read-only
SVG view of the hours around the current time. Press `RET` on the image to open
the editable week view.

```elisp
(setq org-timegrid-agenda-insert-after "To Refile"
      org-timegrid-agenda-separator nil)
```

The first option matches the agenda block above the strip. A nil separator lets
the following block read as the untimed part of the same day section. The strip
shades an edge only when an event continues beyond the visible window.

`org-timegrid-day-blocks` gets and lays out one day's blocks.
`org-timegrid-day-image` draws a chosen minute range as an SVG image. Neither
function needs a calendar buffer.

## Colours

The grid, text, cursor, and backgrounds use the current Emacs theme. Images
redraw after a theme change and respect buffer-local face remapping.

Map Org tags to the built-in macOS-style palette or any colour string Emacs
accepts:

```elisp
(setq org-timegrid-org-tag-color-alist
      '(("work" . indigo)
        ("business" . lime)
        ("reading" . green)
        ("errand" . cyan)
        ("urgent" . "#b4d74a")))
```

The named colours are `blue`, `cyan`, `teal`, `indigo`, `purple`, `pink`,
`red`, `orange`, `yellow`, `lime`, `green`, `brown`, and `graphite`. The first
mapped tag wins. Set `org-timegrid-org-color-function` to colour by TODO state,
priority, property, or file.

## Configuration

| Variable                                            |    Default | Meaning                                  |
|-----------------------------------------------------|-----------:|------------------------------------------|
| `org-timegrid-start-hour` / `org-timegrid-end-hour` | `0` / `24` | Hours drawn                              |
| `org-timegrid-pixels-per-minute`                    |      `0.9` | Week-view scale                          |
| `org-timegrid-slot-minutes`                         |       `15` | Cursor and edit granularity              |
| `org-timegrid-cursor-step-minutes`                  |       `15` | Normal keyboard step                     |
| `org-timegrid-keyboard-commit-delay`                |     `0.25` | Idle delay before a moved block is saved |
| `org-timegrid-default-duration-minutes`             |       `30` | Length used when no end is present       |
| `org-timegrid-block-gap`                            |        `1` | Gap between blocks, in pixels            |
| `org-timegrid-corner-radius`                        |        `0` | Block corner radius                      |
| `org-timegrid-nesting-indent`                       |        `8` | Indent for contained events              |
| `org-timegrid-title-clearance`                      |       `18` | Space a parent keeps for its title       |
| `org-timegrid-data-refresh-seconds`                 |      `300` | Backend reload interval                  |

| Agenda variable                                 |       Default | Meaning                   |
|-------------------------------------------------|--------------:|---------------------------|
| `org-timegrid-agenda-minutes-before` / `-after` | `180` / `180` | Visible window around now |
| `org-timegrid-agenda-insert-after`              | `"To Refile"` | Block above the strip     |
| `org-timegrid-agenda-separator`                 |           `t` | Separator after the strip |
| `org-timegrid-compact-pixels-per-minute`        |        `0.95` | Strip scale               |
| `org-timegrid-compact-font-size`                |          `11` | Strip text size           |

| Org variable                        |                                  Default | Meaning                                              |
|-------------------------------------|-----------------------------------------:|------------------------------------------------------|
| `org-timegrid-org-files`            |                                 `agenda` | Files to query; a list is literal                    |
| `org-timegrid-org-capture-file`     | `calendar.org` in `user-emacs-directory` | Target for new entries; always queried               |
| `org-timegrid-org-capture-template` |           top-level title and time range | Structure and location inside the capture file       |
| `org-timegrid-org-auto-save`        |                                    `nil` | Save the affected Org file after every calendar edit |
| `org-timegrid-org-show-repeaters`   |                                      `t` | Show timestamps with repeaters                       |
| `org-timegrid-org-tag-color-alist`  |                                    `nil` | Tag-to-colour mapping                                |

On an empty slot, `RET` and mouse-drag creation complete against unfinished
TODO headings in the configured Org files. Choosing one adds the new time
range to that heading. Entering text that does not match a candidate creates a
heading in `org-timegrid-org-capture-file`, as before. This uses Org's parser
and works with any `completion-styles`.

The default template is `(:target file :template "* %{title}\n%{time-range}\n%?")`.
Its target may also be `datetree`, `(headline "Name")`, or
`(olp "Parent" "Child")`. Template headings are relative to that target. The
available substitutions are `%{title}`, `%{time-range}`, `%{start}`, `%{end}`,
`%{duration}`, `%<FORMAT>` (using the selected start time), and `%?` for the
final point.

To keep calendar entries in a dedicated file organized by their start date:

```elisp
(setq org-timegrid-org-capture-file "~/org/timegrid.org"
      org-timegrid-org-capture-template
      '(:target datetree
        :template "* %{title}\n%{time-range}\n%?"))
```

Creating “Project review” on August 25, 2026 produces a child of that date:

```org
* 2026
** 2026-08 August
*** 2026-08-25 Tuesday
**** Project review
<2026-08-25 Tue 10:00-11:00>
```

The datetree date comes from the block's selected start time, including when
creating an entry in a past or future week. The capture file is also searched
and displayed automatically; it need not be added to `org-agenda-files`.

## Hooks and custom backends

`org-timegrid-org-after-create-hook` runs with point on a newly created Org
heading. Hook edits join the same undo step.

```elisp
(add-hook 'org-timegrid-org-after-create-hook
          (lambda ()
            (org-set-property
             "CREATED_AT" (format-time-string "[%F %a %R]"))))
```

The renderer itself does not require Org. `org-timegrid-open` accepts an
`org-timegrid-backend` with a listing function and optional callbacks for
create, update, delete, undo, visit, entry completion, and date input. A
backend with only a listing function is read-only. See
`org-timegrid-backend-create` for the full contract.

Create and update callbacks can accept a final `time-kind` argument whose
value is `timed` or `all-day`. This distinguishes date-only entries from timed
entries that happen to span whole days; callbacks using the older arity remain
supported.

## Credits and status

The visual design and interaction borrow from macOS Calendar. [`org-timeblock`](https://github.com/ichernyshovvv/org-timeblock)
and [`timeblock`](https://github.com/ichernyshovvv/timeblock.el) supplied the idea of drawing an Emacs calendar with SVG, and
[`calfw`](https://github.com/kiwanami/emacs-calfw) and [`calfw-blocks`](https://github.com/ml729/calfw-blocks) were the original
inspiration toward a calendar view for Org.

## AI usage
Even though I directed the UI, interaction design, package structure, public
commands, and customization options. Opus 5 and GPT-5.6-Codex wrote all code
in the current implementation. The SVG renderer was agent-written and then
reworked through hands-on usability testing.
