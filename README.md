# org-timegrid

A mouse- and keyboard-driven SVG week calendar for Emacs, backed by your Org
files. Drag to create, drag to move, drag an edge to resize — every gesture
writes a real timestamp into a real heading. A compact read-only strip of the
current day can also be dropped into an existing Org Agenda.

![Week view](screenshots/week-dark.png)

The renderer knows nothing about Org. It draws whatever a backend hands it, and
the Org backend is one implementation of a small protocol.

## Contents

- [Screenshots](#screenshots)
- [Install](#install)
- [What it reads from Org](#what-it-reads-from-org)
- [The Week view](#the-week-view)
- [Inside Org Agenda](#inside-org-agenda)
- [Colours](#colours)
- [Configuration](#configuration)
- [Extending it](#extending-it)
- [Design notes](#design-notes)
- [Status](#status)

## Screenshots

Nothing here ships its own colours: the palette comes from the faces of whatever
theme is loaded, and is redrawn when the theme changes. Same week, same data,
two themes:

| | |
|---|---|
| ![Week, light](screenshots/week-light.png) | ![Week, dark](screenshots/week-dark.png) |

The agenda strip, with the day's untimed items listed underneath it:

| | |
|---|---|
| ![Agenda, light](screenshots/agenda-light.png) | ![Agenda, dark](screenshots/agenda-dark.png) |

## Install

Emacs 29.1 or later, built with SVG support — `(image-type-available-p 'svg)`
must be non-nil. Org 9.6 or later. No other dependencies.

With [Elpaca](https://github.com/progfolio/elpaca):

```elisp
(use-package org-timegrid-org
  :ensure (org-timegrid :host github :repo "gleek/org-timegrid")
  :commands (org-timegrid-week)
  :bind ("C-c c" . org-timegrid-week)
  :config
  ;; Where the calendar writes entries you create by dragging.  Nil resolves
  ;; to the first agenda file; naming it means reordering `org-agenda-files'
  ;; cannot silently move the target.
  (setq org-timegrid-org-capture-file "~/org/inbox.org"))
```

With `straight.el`:

```elisp
(straight-use-package
 '(org-timegrid :host github :repo "Gleek/org-timegrid"))
(require 'org-timegrid-org)
```

Manually: put the `.el` files on your `load-path`, then `(require
'org-timegrid-org)` and `M-x org-timegrid-week`.

The package is four files. Requiring `org-timegrid-org` pulls in the two it
needs; `org-timegrid-agenda` is separate and optional.

```text
org-timegrid-model.el     records, the backend protocol, date arithmetic
          ↑
org-timegrid.el           SVG, layout, cursor, commands, hit testing
          ↑
org-timegrid-org.el       Org extraction and source edits
          ↑
org-timegrid-agenda.el    the read-only day strip for Org Agenda
```

## What it reads from Org

Active timestamps that carry a clock time, whether plain or after `SCHEDULED:`
or `DEADLINE:`:

```org
* TODO Design review            :work:
<2026-08-24 Mon 14:00-15:30>

* TODO Standup
SCHEDULED: <2026-08-24 Mon 09:00-09:15>

* TODO Vendor call
<2026-08-24 Mon 15:00>          ← no end: drawn 30 minutes long
```

A timestamp with no end is drawn `org-timegrid-default-duration-minutes` long
rather than hidden — an entry timed 09:00 is a real plan. Date-only values and
inactive timestamps do not appear: the former have no position on a time grid,
the latter are records rather than plans.

Repeaters are expanded into concrete occurrences at the backend boundary, so the
renderer only ever sees ordinary dated events. Moving or resizing an occurrence
edits the series anchor and preserves the repeater and warning modifiers, so the
series moves with it.

Edits leave source buffers modified but unsaved, exactly as Org Agenda commands
do. `u` inside the calendar undoes in the file the edit landed in.

## The Week view

### Mouse

| Gesture | Action |
|---|---|
| Drag empty space | Create an entry over that range, asking for a title |
| Drag a block | Move it, preserving duration and the grab offset |
| Drag a top or bottom edge | Resize it, keeping the other edge |
| **Option**-drag a block | Duplicate it at the drop point |
| Click | Move the cursor there, selecting a block if one starts there |
| Double-click | Visit the Org heading |
| Wheel | Scroll the day |

Everything snaps to fifteen minutes and enforces a fifteen-minute minimum.
Drags commit on release, and `C-g` during one cancels it.

### Keyboard

There is **one cursor and no separate selection**. A block is selected exactly
when the cursor sits on that block's own first slot, so the highlight and the
cursor can never disagree, and the mouse and keyboard drive the same state.

The cursor occupies one fifteen-minute slot, drawn in the `cursor` face colour
with a translucent fill. While it selects a block it is not drawn at all: that
block's outline is the feedback, and two borders around one slot read as a bug.
It stays hidden until a movement key asks for it, and the first press reveals it
where it was left rather than also moving it.

| Key | Action |
|---|---|
| `C-n` / `C-p`, `<down>` / `<up>` | Next / previous stop: a half-hour boundary, a block edge, or a lane |
| `C-f` / `C-b`, `<right>` / `<left>` | Next / previous lane, else ±1 day |
| `M-<down>` / `M-<up>` | Cursor ±15 minutes |
| `C-v` / `M-v`, `SPC` | Cursor ±1 screenful |
| `C-a` / `C-e` | Midnight / last slot of the cursor's day |
| `C-l` | Centre the view on the cursor, leaving it where it is |
| `n` / `p` | Select the next / previous block by start time |
| `RET` | Open the block under the cursor in its own file, or create one there |
| `C-g` | Hide the cursor, keeping its place |
| `M-S-<down>` / `M-S-<up>` | Move the selection ±15 minutes |
| `M-S-<right>` / `M-S-<left>` | Move the selection ±1 day |
| `M-S-s-<right>` / `M-S-s-<left>` | Copy the selection to the next / previous day, same time |
| `S-<down>` / `S-<up>` | Move the end edge |
| `C-S-<up>` / `C-S-<down>` | Move the start edge |
| `t` | Re-time from a prefilled prompt |
| `e` | Edit the title |
| `d`, `<delete>` | Remove the time, then offer to delete the entry |
| `DEL` | Remove the selected block, or page up when none is selected |
| `M-w` / `C-w` / `C-y` | Copy / cut / yank a block |
| `u`, `C-/`, `C-x u` | Undo the last calendar edit, in the file it touched |
| `b` / `f`, `M-b` / `M-f` | Shift the visible range by a day / a week |
| `j` / `.` | Jump to a date / to today |
| `g` | Reload from the backend |
| `q` | Quit |

Undo is also reached by remapping, so whatever key you have bound to `undo`,
`undo-only` or `undo-redo` reaches it here too.

Some deliberate details:

**Editing carries the cursor with the block.** Selection is derived from the
cursor, so an edit that left the cursor behind would deselect the very block it
changed, and the key could only be pressed once. Holding `M-S-<up>` walks a
block up the day. Copying follows the *copy*, so holding that key spreads one
entry across consecutive days instead of stacking every copy on one.

**Ordinary motion is half an hour**, unless a block edge falls in between. Both
starts and ends are stops, so `C-n` alone reaches every block in a column and
the gap after each one. Where blocks share a start, each lane is a stop too, so
vertical motion reaches both of two events beginning at the same minute rather
than only the shortest.

**Fine motion, moving and resizing have separate keys** on purpose. Sharing one
key meant that nudging the cursor by fifteen minutes resized whatever it had
selected.

**Off-grid timestamps work.** A real entry may run 13:50 to 14:10. A block is
selected when its start falls *within* the cursor's slot rather than exactly on
it, a start is a stop at the slot containing it, and an end is a stop at the
first free slot after it. Snapping by direction of travel instead would make
forward and backward motion disagree, and could leave a block unreachable.

## Inside Org Agenda

`M-x org-timegrid-agenda-mode` inserts a read-only strip of the current day into
Org Agenda buffers, showing the hours around now:

```text
existing Org Agenda
        │
        ├── existing blocks above
        ├── inserted day strip
        └── existing blocks below
```

It does not rewrite or replace the agenda. Org builds its buffer as it always
does, and the strip is added by `org-agenda-finalize-hook`, so `g` regenerates
it along with everything else and there is nothing to keep in sync. Insertion
replaces any strip already present, because not every agenda command rebuilds
the buffer before finalizing.

`org-timegrid-agenda-insert-after` names the block to sit below, matched as a
regexp; nil, or a header this agenda does not have, puts the strip at the top.
The strip goes below that block's separator, so it opens the section that
follows. `org-timegrid-agenda-separator` nil then makes the next block read as
part of the strip's own section, which is what you want when that block is the
same day's untimed items:

```elisp
(setq org-timegrid-agenda-insert-after "To Refile"
      org-timegrid-agenda-separator nil)
```

The strip is read-only by design, and `RET` on it opens the Week view. Editing
an image inside a buffer that rebuilds itself on `g` would mean two things
competing for the same keys.

An edge is shaded only when the day holds something past it, so a shadow means
"more this way" rather than merely marking where the window stops.

Two library functions do the work and neither needs a calendar buffer, so a mode
line or a dashboard can use them too: `org-timegrid-day-blocks` returns one
day's blocks from a backend, clipped to that day and given side-by-side lanes,
and `org-timegrid-day-image` renders a minute window of them as an image.

## Colours

`org-timegrid-colors` names thirteen colours after the macOS system palette —
`blue` `cyan` `teal` `indigo` `purple` `pink` `red` `orange` `yellow` `lime`
`green` `brown` `graphite` — so a calendar coloured to match one there needs no
translation. A block is a translucent wash of its colour with a saturated bar
down its left edge, which is why the values are saturated rather than pastel.

Map Org tags to them. A colour need not be a name; any string Emacs understands
works, so nothing has to be registered in advance:

```elisp
(setq org-timegrid-org-tag-color-alist
      '(("work"     . indigo)
        ("business" . lime)
        ("reading"  . green)
        ("errand"   . cyan)
        ("urgent"   . "#b4d74a")))
```

Tags are checked in the order they appear on the heading, so the first mapped
tag wins and a heading may carry others freely. An unmapped heading uses
`org-timegrid-default-color`: colour means something on a calendar, so a colour
invented per tag name would be noise rather than information.

To colour by anything else — TODO state, priority, a property, the file — set
`org-timegrid-org-color-function`, which receives the `org-element` headline.

Everything else on the grid comes from the current theme's faces, including
buffer-local face remapping, so the drawing matches the buffer it sits in rather
than the frame's idea of `default`. That is what keeps it flush under
`solaire-mode` and anything else that dims one buffer.

## Configuration

### Appearance

| Variable | Default | |
|---|---|---|
| `org-timegrid-start-hour` / `-end-hour` | 0 / 24 | Hours the canvas covers |
| `org-timegrid-pixels-per-minute` | 0.9 | Vertical scale of the Week view |
| `org-timegrid-block-gap` | 3 | Pixels between consecutive blocks |
| `org-timegrid-corner-radius` | 0 | Block corner radius |
| `org-timegrid-nesting-indent` | 8 | Indent per level of containment |
| `org-timegrid-title-clearance` | 18 | Pixels needed before one block nests inside another |
| `org-timegrid-cursor-opacity` | 0.22 | Fill opacity of the keyboard cursor |
| `org-timegrid-colors` | see above | Named colours |
| `org-timegrid-default-color` | `blue` | Colour for an event given none |

### Behaviour

| Variable | Default | |
|---|---|---|
| `org-timegrid-slot-minutes` | 15 | Snapping granularity, and the cursor's size |
| `org-timegrid-cursor-step-minutes` | 30 | Ordinary cursor step |
| `org-timegrid-default-duration-minutes` | 30 | Assumed wherever no end time is given |
| `org-timegrid-data-refresh-seconds` | 300 | Backend re-query interval |
| `org-timegrid-buffer-name` | `*Org Time Grid*` | |
| `org-timegrid-edge-pixels` / `-edge-slop` | 8 / 3 | Size of the resize zones |

### The agenda strip

| Variable | Default | |
|---|---|---|
| `org-timegrid-agenda-minutes-before` / `-after` | 180 / 180 | The visible window |
| `org-timegrid-agenda-insert-after` | `"To Refile"` | Block to sit below |
| `org-timegrid-agenda-separator` | t | Close the strip with a separator |
| `org-timegrid-compact-pixels-per-minute` | 0.95 | Vertical scale of the strip |
| `org-timegrid-compact-font-size` | 11 | Text size; line height follows it |
| `org-timegrid-compact-shadow-pixels` | 10 | Depth of the edge shadow |

### Org

| Variable | Default | |
|---|---|---|
| `org-timegrid-org-files` | `agenda` | Files to query; a list is used literally |
| `org-timegrid-org-extra-files` | nil | Always queried as well |
| `org-timegrid-org-capture-file` | nil | Where new entries go; nil is the first agenda file |
| `org-timegrid-org-capture-todo-keyword` | `"TODO"` | |
| `org-timegrid-org-tag-color-alist` | nil | Tag to colour |
| `org-timegrid-org-color-function` | tag lookup | Headline to colour |

## Extending it

`org-timegrid-org-after-create-hook` runs on a heading the calendar has just
created, with point on it, inside the change group that inserted it — so a
property set there belongs to the entry's single undo step. This is how calendar
entries come out looking like captured ones:

```elisp
(add-hook 'org-timegrid-org-after-create-hook
          (lambda ()
            (org-set-property "CAPTURED"
                              (format-time-string "[%F %a %R]"))))
```

`org-timegrid-mode-hook` is available as usual.

### Writing a backend

The renderer takes events in absolute minutes — Emacs absolute Gregorian days
times 1440, plus the minute within the day — and calls back to mutate them. A
backend with only `list-function` is read-only, and the commands that need the
others say so rather than failing oddly.

```elisp
(org-timegrid-open
 (org-timegrid-backend-create
  :name "Example"
  :list-function (lambda (start end) ...)   ; → org-timegrid-event records
  :create-function (lambda (title start end &optional source) ...)
  :update-function (lambda (event start end &optional title) ...)
  :delete-function (lambda (event) ...)
  :delete-entry-function (lambda (event) ...)
  :undo-function (lambda (continue redo) ...)
  :visit-function (lambda (event) ...)
  :read-timestamp-function (lambda (start duration) ...)))
```

Undo is a backend callback for the same reason as the rest: the change lives in
a buffer the renderer does not own, so only the backend knows where to undo it.
It receives whether this call continues an unbroken run, which is what stops a
repeated key from undoing its own undo.

## Design notes

**Why one cursor.** An earlier version had a cursor and a separate selection.
They could disagree, and since every edit refreshes the view, every edit dropped
the selection. Deriving selection from cursor position removed a state variable
and a class of bug with it.

**Why the renderer has no Org dependency.** It is enforced by a test that greps
the source for `(require 'org...)` and for Org functions. The one place Org
knowledge had leaked in — reading a date from the user — became a backend
callback.

**Redraw cost.** 4.3 ms to lay out and build the SVG DOM, 6.3 ms to serialize
it, 15.5 ms for a full refresh including redisplay, on a thirty-block week. A
synthetic 140-block week costs 55–85 ms, which is why held keys coalesce: a
burst updates state and paints once when input stops.

**What batch tests cannot check.** With no display, `default`'s background is
`unspecified-bg`, so any assertion about a colour passes vacuously. Anything to
do with the palette, the theme, or face remapping has to be checked in a real
frame.

## Status

In daily use, and the interfaces above are settled enough to build on.

Not yet done: all-day events, which want a rail above the grid as macOS Calendar
has, and day or three-day spans. Only the Week view edits; the agenda strip is
read-only by design.
