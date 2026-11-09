;;; org-timegrid.el --- SVG week calendar with mouse and keyboard editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad

;; Author: Umar Ahmad <Gleek@users.noreply.github.com>
;; Assisted-by: Codex:gpt-5.6-sol
;; Maintainer: Umar Ahmad <Gleek@users.noreply.github.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: calendar, outlines, convenience
;; URL: https://github.com/Gleek/org-timegrid

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Draw timed events as an interactive SVG week calendar and edit them by
;; dragging or from the keyboard.  This file has no Org dependency: it renders
;; whatever a backend supplies, through the protocol in `org-timegrid-model'.
;; `org-timegrid-org' is the Org implementation of that protocol.
;; Drawing data lives in `org-timegrid-scene', SVG interpretation in
;; `org-timegrid-svg', and cache/resource ownership in `org-timegrid-display'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org-timegrid-model)
(require 'org-timegrid-scene)
(require 'org-timegrid-display)

(defcustom org-timegrid-range-alignment 'week
  "How to position the range when opening or jumping to a date.
With `week', start on `calendar-week-start-day', or end on the target
date if that week start would leave the target outside the range.
With `center', place the target date in the middle.  For an even
number of days, use the column just right of the middle.
The target date defaults to today."
  :group 'org-timegrid
  :type '(choice (const :tag "Align to week start" week)
                 (const :tag "Center target date" center)))

(defun org-timegrid--range-start (&optional absolute-date)
  "Return the first visible day for a range containing ABSOLUTE-DATE.
Position the range according to `org-timegrid-range-alignment'.
ABSOLUTE-DATE defaults to today."
  (let ((absolute (or absolute-date
                      (calendar-absolute-from-gregorian
                       (calendar-current-date)))))
    (if (eq org-timegrid-range-alignment 'center)
        (- absolute (/ org-timegrid-days 2))
      (max (org-timegrid-week-start absolute)
           (- absolute (org-timegrid--last-day-index))))))

(defvar org-timegrid-preview-prefetch t
  "Prepare nearby timed drag and resize positions between input events.
This uses extra CPU and memory to make upcoming snapped positions faster.
Set to nil to disable preparation and its image cache.")

(defcustom org-timegrid-default-duration-minutes 30
  "Duration assumed wherever no end time is given.
Keyboard creation offers it, and a backend event that has a start but no
end is shown this long."
  :group 'org-timegrid
  :type 'integer)

(defvar org-timegrid-data-refresh-seconds 300
  "Seconds between visible backend data refreshes.")

(defvar org-timegrid-keyboard-commit-delay 0.65
  "Idle seconds before a keyboard block movement is written to its backend.")

(defvar org-timegrid-copy-date-format "%a %d %b %Y"
  "Date format used for day headings in copied calendar text.")

(defvar org-timegrid-copy-item-template "%{start}–%{end}  %{title}"
  "Template for one item in copied calendar text.
The tokens `%{title}', `%{start}', and `%{end}' are replaced.")

(defvar org-timegrid--header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line down-mouse-1] #'org-timegrid-header-press)
    (define-key map [header-line double-down-mouse-1]
                #'org-timegrid-ignore-double-press)
    (define-key map [header-line mouse-1] #'org-timegrid-header-click)
    (define-key map [header-line double-mouse-1] #'org-timegrid-header-visit)
    (define-key map [down-mouse-1] #'org-timegrid-header-press)
    (define-key map [double-down-mouse-1] #'org-timegrid-ignore-double-press)
    (define-key map [mouse-1] #'org-timegrid-header-click)
    (define-key map [double-mouse-1] #'org-timegrid-header-visit)
    (dolist (area '(calendar-rail-block calendar-rail-resize))
      (define-key map (vector area 'down-mouse-1) #'org-timegrid-header-press)
      (define-key map (vector area 'double-down-mouse-1) #'org-timegrid-ignore-double-press)
      (define-key map (vector area 'mouse-1) #'org-timegrid-header-click)
      (define-key map (vector area 'double-mouse-1) #'org-timegrid-header-visit))
    map)
  "Mouse map installed directly on the sticky calendar header image.")

(defvar-local org-timegrid--pointer-overlay nil)

(defvar-local org-timegrid--keyboard-edit-timer nil)
(defvar-local org-timegrid--keyboard-edit nil)
(defvar org-timegrid--defer-refresh nil)

(defconst org-timegrid--scroll-rebound-seconds 0.35
  "Seconds to suppress a reversed wheel event after hitting an edge.")
(defvar-local org-timegrid--scroll-boundary nil
  "Most recently hit scroll boundary as (SIDE . TIME).")

(defvar-local org-timegrid--fringe-remap-cookie nil)

(defvar-local org-timegrid--backend nil)

(defun org-timegrid--make-block
    (id day start end title &optional color done time-kind)
  "Construct a renderer block from ID, DAY, START, END, TITLE and COLOR.
DONE and TIME-KIND describe the block's completion and timestamp kind."
  (org-timegrid-block-create
   :id id :day day :start start :end end :title title
   :time-kind (or time-kind 'timed) :color color :done done))

(defun org-timegrid--load-state (week-start)
  "Load renderer state for WEEK-START from the current backend."
  (let* ((start (* week-start 1440))
         (end (* (+ week-start org-timegrid-days) 1440))
         (anchor (or org-timegrid--cache-anchor start))
         (events (org-timegrid-backend-list
                  org-timegrid--backend start end
                  (list :force org-timegrid--force-data-refresh
                        :cache-range (cons (- anchor (* 14 1440))
                                           (+ (max end (+ anchor (- end start))) (* 7 1440))))))
         (blocks (org-timegrid-events-to-blocks events week-start)))
    ;; The cursor has a remembered position and a separate visibility, so
    ;; hiding it with C-g keeps the place, and block selection can record a
    ;; position without drawing anything.
    (org-timegrid--calendar-state-create
     :week-start week-start :events events :blocks blocks)))

(defun org-timegrid--blocks-at-slot (day minute)
  "Return committed timed blocks overlapping DAY's slot at MINUTE.
Shortest first, so a nested child is offered before its parent.  Lanes
make every overlapping block reachable, including off-grid starts."
  (when (and (numberp day) (numberp minute))
    (let ((slot-start (+ (* day 1440) minute)))
      (sort (seq-filter
             (lambda (block)
               (let ((start (org-timegrid--block-absolute-start block)))
                 (and (not (org-timegrid-block-preview block))
                      (< start (+ slot-start org-timegrid-slot-minutes))
                      (> (+ start (- (org-timegrid-block-end block)
                                     (org-timegrid-block-start block)))
                         slot-start))))
             (org-timegrid--timed-blocks))
            (lambda (left right)
              (< (- (org-timegrid-block-end left) (org-timegrid-block-start left))
                 (- (org-timegrid-block-end right) (org-timegrid-block-start right))))))))

(defun org-timegrid--reveal-cursor ()
  "Show the cursor, returning non-nil when it was hidden until now.
The first movement key reveals the cursor where it was left rather than
also moving it, so its position is visible before it is used."
  (unless (org-timegrid--cursor-visible-p)
    (org-timegrid--ensure-cursor)
    (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
    t))

(defun org-timegrid--region-message ()
  "Return the active calendar region as a readable time range."
  (when-let* ((range (org-timegrid--region-range)))
    (let ((start (car range))
          (end (cdr range)))
      (if (= (floor start 1440) (floor end 1440))
          (format "%s–%s" (org-timegrid--format-minute start)
                  (org-timegrid--format-minute end))
        (format "%s %s–%s %s"
                (org-timegrid--format-copy-date start)
                (org-timegrid--format-minute start)
                (org-timegrid--format-copy-date end)
                (org-timegrid--format-minute end))))))

(defun org-timegrid-set-mark-command ()
  "Set or deactivate the calendar mark at the cursor."
  (interactive)
  (org-timegrid--with-update nil
    (org-timegrid--reveal-cursor)
    (if (org-timegrid-region-active-p)
        (setf (org-timegrid--calendar-state-region-active org-timegrid--state) nil)
      (setf (org-timegrid--calendar-state-mark org-timegrid--state)
            (org-timegrid--cursor-calendar-minute)
            (org-timegrid--calendar-state-region-active org-timegrid--state) t))
    (if (org-timegrid-region-active-p)
        (message "%s" (org-timegrid--region-message))
      (message nil))))

(defun org-timegrid-exchange-point-and-mark ()
  "Exchange the calendar cursor and its remembered mark."
  (interactive)
  (org-timegrid--with-update 'reset
    (unless (integerp (org-timegrid--calendar-state-mark org-timegrid--state))
      (user-error "No calendar mark set"))
    (let* ((point (org-timegrid--cursor-calendar-minute))
           (mark (org-timegrid--calendar-state-mark org-timegrid--state))
           (day (floor mark 1440)))
      (org-timegrid--reload-state (org-timegrid--range-start day))
      (org-timegrid--set-cursor
       (- day (org-timegrid--calendar-state-week-start org-timegrid--state))
       (% mark 1440))
      (setf (org-timegrid--calendar-state-mark org-timegrid--state) point
            (org-timegrid--calendar-state-region-active org-timegrid--state) t
            (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
      (message "%s" (org-timegrid--region-message)))))

(defun org-timegrid--set-cursor (day minute &optional lane)
  "Move the cursor to DAY and MINUTE, clamped to the visible week.
LANE picks between blocks overlapping that slot, and defaults to zero."
  (let* ((day (max 0 (min (org-timegrid--last-day-index) day)))
         (minute (org-timegrid--visible-minute minute))
         (lane (or lane 0))
         (candidates (org-timegrid--blocks-at-slot day minute))
         (selected (and candidates
                        (org-timegrid-block-id
                         (nth (min lane (1- (length candidates))) candidates)))))
    (setf (org-timegrid--calendar-state-cursor org-timegrid--state)
          (org-timegrid--cursor-state-create
           :surface 'grid :day day :minute minute :lane lane)
          (org-timegrid--calendar-state-selected-id org-timegrid--state)
          selected))
  (org-timegrid--cursor))

(defun org-timegrid--reload-state (week-start &optional state)
  "Reload WEEK-START from the backend, keeping cursor and selection.
Navigation and refresh drop preview and history, but they must not throw
the cursor back to today, and they must not clear the selection: every
edit refreshes, so a cleared selection would make repeated keyboard
nudges of one block impossible.  A selection that no longer resolves
after the reload is dropped.  Use STATE when already fetched."
  (let ((cursor (org-timegrid--calendar-state-cursor org-timegrid--state))
        (visible (org-timegrid--calendar-state-cursor-visible
                  org-timegrid--state))
        (selected (org-timegrid--calendar-state-selected-id
                   org-timegrid--state))
        (mark (org-timegrid--calendar-state-mark org-timegrid--state))
        (region-active
         (org-timegrid--calendar-state-region-active org-timegrid--state)))
    (setq-local org-timegrid--state (or state (org-timegrid--load-state week-start)))
    (when cursor
      (setf (org-timegrid--calendar-state-cursor org-timegrid--state) cursor
            (org-timegrid--calendar-state-cursor-visible org-timegrid--state)
            visible
            (org-timegrid--calendar-state-selected-id org-timegrid--state)
            (and (org-timegrid--block selected) selected)
            (org-timegrid--calendar-state-mark org-timegrid--state) mark
            (org-timegrid--calendar-state-region-active org-timegrid--state)
            region-active)
      ;; Heading edits can change position-based IDs.  Select at the cursor.
      (when (and selected (not (org-timegrid--selected-id)))
        (let ((day (org-timegrid--cursor-state-day cursor))
              (lane (org-timegrid--cursor-state-lane cursor)))
          (if (eq (org-timegrid--cursor-state-surface cursor) 'rail)
              (org-timegrid--set-all-day-cursor day lane)
            (org-timegrid--set-cursor
             day (org-timegrid--cursor-state-minute cursor) lane)))))))

(defun org-timegrid--proposal (origin target copy-kind)
  "Return a drag proposal from ORIGIN to TARGET.
COPY-KIND is nil for a move, `duplicate-entry' for an independent copy,
or `add-occurrence' for another time on the source entry."
  (let* ((id (plist-get origin :block-id))
         (copying (memq copy-kind '(duplicate-entry add-occurrence)))
         (origin-surface (or (plist-get origin :surface) 'grid))
         (target-surface (or (plist-get target :surface) 'grid))
         (origin-day (plist-get origin :day))
         (target-day (plist-get target :day))
         (origin-minute (plist-get origin :minute))
         (target-minute (plist-get target :minute))
         (edge (plist-get origin :edge)))
    (cond
     ((or (null origin-day) (null origin-minute)
          (null target-day) (null target-minute))
      (org-timegrid--operation-create
       :error "Release inside a calendar cell"))
     ((and (null id) (not (eq origin-surface target-surface)))
      (org-timegrid--operation-create
       :error "Create a range on one calendar surface"))
     ((null id)
      (if (/= origin-day target-day)
          (org-timegrid--operation-create
           :error "New ranges currently stay within one day")
        (let ((block (org-timegrid--make-block
                      'preview origin-day
                      (min origin-minute target-minute)
                      (+ (max origin-minute target-minute)
                         org-timegrid-slot-minutes)
                      "New block")))
          (setf (org-timegrid-block-preview block) t)
          (org-timegrid--operation-create :kind 'create :block block))))
     ((not (eq origin-surface target-surface))
      (let ((source (org-timegrid--block id)))
        (cond
         ((null source)
          (org-timegrid--operation-create
           :error "Drag an existing block between the all-day rail and time grid"))
         ((and (eq origin-surface 'rail)
               (/= (- (org-timegrid-block-end source)
                       (org-timegrid-block-start source))
                   1440))
          (org-timegrid--operation-create
           :error "Multi-day blocks cannot move into the time grid"))
         (t
          (let* ((block (copy-org-timegrid-block source))
                 (start (+ (* target-day 1440)
                           (if (eq target-surface 'rail) 0 target-minute)))
                 (duration (if (eq target-surface 'rail)
                               1440
                             org-timegrid-default-duration-minutes)))
            (org-timegrid--set-absolute-range block start (+ start duration))
            (setf (org-timegrid-block-time-kind block)
                  (if (eq target-surface 'rail) 'all-day 'timed)
                  (org-timegrid-block-preview block) t)
            (org-timegrid--operation-create
             :kind (if copying copy-kind 'move) :block block
             :replace-id (and (not copying) id)))))))
     (t
      (let ((source (org-timegrid--block id)))
        (if (null source)
            (org-timegrid--operation-create
             :error "That calendar block changed; refresh and try again")
          (let* ((absolute-start (org-timegrid--block-absolute-start source))
                 (absolute-end (+ absolute-start
                                  (- (org-timegrid-block-end source)
                                     (org-timegrid-block-start source))))
                 (absolute-origin (+ (* origin-day 1440) origin-minute))
                 (absolute-target (+ (* target-day 1440) target-minute))
                 (edge (and (not copying) edge))
                 (delta (pcase edge
                          ('top (- absolute-target absolute-start))
                          ('bottom (- (+ absolute-target
                                         (if (org-timegrid-block-all-day-p source)
                                             1440 org-timegrid-slot-minutes))
                                      absolute-end))
                          (_ (- absolute-target absolute-origin)))))
            (org-timegrid--operation-create
             :kind (if copying copy-kind (if edge 'resize 'move)) :edge edge
             :block (org-timegrid--transform-block-range source delta edge)
             :replace-id (and (not copying) id)))))))))

(defun org-timegrid-day-blocks (backend absolute-day)
  "Return BACKEND blocks on ABSOLUTE-DAY, clipped to that day.
Coordinates are minutes within that day, so a range running past midnight
arrives clipped at 1440 rather than spilling into a day that is not being
drawn.  Layout belongs to the shared renderer used by both calendar views.
Date-only events are omitted: day images have no all-day rail, and
rendering them as midnight-to-midnight timed blocks would be misleading."
  (let* ((start (* absolute-day 1440))
         (events
          (seq-remove
           #'org-timegrid-event-all-day
           (org-timegrid-backend-list backend start (+ start 1440))))
         (blocks
          (mapcar
           (lambda (event)
             (org-timegrid-block-create
              :id (org-timegrid-event-id event)
              :day 0
              :start (max 0 (- (org-timegrid-event-start event) start))
              :end (min 1440 (- (org-timegrid-event-end event) start))
              :time-kind 'timed
              :title (org-timegrid-event-title event)
              :color (org-timegrid-event-color event)
              :done (eq (org-timegrid-event-state event) 'done)
              :event event))
           events)))
    blocks))

(defun org-timegrid--ensure-state ()
  "Ensure the current calendar buffer has a usable calendar state.
Keep existing blocks when possible, but reconstruct missing date metadata."
  (unless (and (org-timegrid--calendar-state-p org-timegrid--state)
               (numberp (org-timegrid--calendar-state-week-start
                         org-timegrid--state)))
    (setq-local org-timegrid--state
                (org-timegrid--load-state (org-timegrid--range-start))))
  org-timegrid--state)

(defun org-timegrid--rail-edge-at (geometry x)
  "Return resize endpoint for rail GEOMETRY at horizontal pixel X.
The operation model calls the start and end endpoints `top' and `bottom';
the rail presents those same endpoints as its left and right edges."
  (let* ((left (plist-get geometry :x))
         (right (+ left (plist-get geometry :width)))
         (edge (min org-timegrid--resize-pixels
                    (max 1 (/ (plist-get geometry :width) 2.0)))))
    (cond ((and (plist-get geometry :allow-left)
                (<= left x (+ left edge)))
           'top)
          ((and (plist-get geometry :allow-right)
                (<= (- right edge) x right))
           'bottom))))

(defun org-timegrid--position-image-xy (position)
  "Return stable full-calendar pixel coordinates for mouse POSITION.
Use window-relative X so crossing image map hotspots and day columns cannot
reset the horizontal origin.  Add the tile offset to glyph-relative Y."
  (let* ((window-xy (posn-x-y position))
         (object-xy (posn-object-x-y position))
         (point (posn-point position))
         (tile (and (integer-or-marker-p point)
                    (or (get-text-property point 'org-timegrid-tile)
                        (and (> point (point-min))
                             (get-text-property (1- point)
                                                'org-timegrid-tile))))))
    (when (or window-xy object-xy)
      (cons (or (car-safe window-xy)
              (and object-xy (+ (car object-xy)
                                (if tile (car (org-timegrid--tile-x-bounds tile)) 0))))
            (+ (if (and tile org-timegrid--tile-count)
                   (car (org-timegrid--tile-bounds tile))
                 0)
               (or (cdr-safe object-xy) (cdr-safe window-xy)))))))

(defun org-timegrid--target (position)
  "Return calendar metadata at mouse POSITION in the SVG image."
  (org-timegrid--with-render-context (org-timegrid--display-context)
  (let* ((xy (org-timegrid--position-image-xy position))
         (x (and xy (car xy)))
         (y (and xy (cdr xy)))
         (width (org-timegrid--canvas-width))
         (column-width (org-timegrid--column-width))
         (start-minute (* 60 org-timegrid-start-hour)))
    (when (and (numberp x) (numberp y)
               (>= x (org-timegrid--label-width))
               (< x width) (>= y 0)
               (< y org-timegrid--image-height))
      (let* ((column (/ (- x (org-timegrid--label-width)) column-width))
             (day (max 0 (min (org-timegrid--last-day-index)
                              (if (plist-get (org-timegrid--calendar-state-gesture org-timegrid--state) :clock)
                                  (1- (round column))
                                (floor column)))))
             (minute (+ start-minute
                        (* org-timegrid-slot-minutes
                           (floor (/ (max 0 (- y (org-timegrid--grid-top-inset)))
                                     (* (org-timegrid--pixels-per-minute)
                                        org-timegrid-slot-minutes))))))
             (geometry
              (cl-find-if (lambda (item)
                            (let ((slop
                                   org-timegrid--resize-slop))
                              (and (not (plist-get item :preview))
                                   (<= (plist-get item :x) x
                                       (+ (plist-get item :x)
                                          (plist-get item :width)))
                                   (<= (- (plist-get item :y) slop) y
                                       (+ (plist-get item :y)
                                          (plist-get item :height) slop)))))
                          org-timegrid--geometry))
             (edge (and geometry
                        (org-timegrid--edge-at geometry y))))
        (list :surface 'grid :block-id (plist-get geometry :id)
              :day (if (and geometry (not (plist-get (org-timegrid--calendar-state-gesture org-timegrid--state) :clock)))
                       (plist-get geometry :day) day)
              :minute minute :edge edge))))))

(defun org-timegrid--set-preview (proposal)
  "Update the preview without committing it to the backend."
  (org-timegrid--with-update nil
    (setf (org-timegrid--calendar-state-preview org-timegrid--state)
          (and proposal (not (org-timegrid--operation-error proposal)) proposal))))

(defun org-timegrid--clear-preview ()
  "Discard the pending preview."
  (org-timegrid--set-preview nil))

(defun org-timegrid--backend-undo (redo)
  "Ask the backend to undo, or REDO, its most recent edit.
The calendar cannot undo for itself: the change lives in a source buffer
it does not own.  Repeating the key continues one run rather than
undoing the undo, which is what `undo' does at a keyboard."
  (let ((undoer (org-timegrid-backend-undo-function org-timegrid--backend)))
    (unless (functionp undoer)
      (user-error "This backend cannot undo; undo in the source buffer"))
    (funcall undoer
             (and (memq last-command '(org-timegrid-undo org-timegrid-redo)) t)
             redo)
    (org-timegrid--refresh-data)))

(defun org-timegrid-undo ()
  "Undo the calendar's most recent edit, in the file it touched."
  (interactive)
  (org-timegrid--backend-undo nil))

(defun org-timegrid-redo ()
  "Redo the calendar's most recently undone edit."
  (interactive)
  (org-timegrid--backend-undo t))

(defun org-timegrid-remove-selected (&optional keep-entry)
  "Remove timestamps in the region or the block at point.
KEEP-ENTRY never offers to remove timestamp-free entries."
  (interactive)
  (let* ((selection (org-timegrid--logical-selection))
         (events (plist-get selection :events))
         (deleter (org-timegrid-backend-delete-function org-timegrid--backend))
         (entry-deleter
          (org-timegrid-backend-delete-entry-function org-timegrid--backend))
         (empty-p (org-timegrid-backend-entry-empty-function org-timegrid--backend))
         (entry-key (org-timegrid-backend-entry-key-function org-timegrid--backend)))
    (unless events (user-error "The calendar region contains no blocks"))
    (unless (functionp deleter)
      (user-error "This backend cannot remove calendar entries"))
    (org-timegrid--transaction
     (lambda ()
       (dolist (event events) (funcall deleter event))
       (unless keep-entry
         (let (eligible)
           (dolist (event events)
             (when (and (functionp empty-p) (funcall empty-p event))
               (unless (cl-find (and (functionp entry-key)
                                     (funcall entry-key event))
                                eligible :key (lambda (candidate)
                                                (and (functionp entry-key)
                                                     (funcall entry-key candidate)))
                                :test #'equal)
                 (push event eligible))))
           (when (and eligible (functionp entry-deleter)
                      (y-or-n-p
                       (format "Delete %d timestamp-free entr%s too? "
                               (length eligible)
                               (if (= (length eligible) 1) "y" "ies"))))
             (dolist (event eligible) (funcall entry-deleter event)))))
       (org-timegrid--deactivate-region)
       (org-timegrid--deselect-block)))
    (message "Removed %d timestamp%s" (length events)
             (if (= (length events) 1) "" "s"))))

(defun org-timegrid-edit-selected-title ()
  "Edit the selected calendar block's source heading title."
  (interactive)
  (let* ((id (org-timegrid--selected-id))
         (source (and id (org-timegrid--block id))))
    (if (null source)
        (message "No block selected")
      (let ((title (org-timegrid--read-title
                    (org-timegrid-block-title source))))
        (unless (string-empty-p title)
          (let ((event (org-timegrid-block-event source))
                (updater (org-timegrid-backend-update-function
                          org-timegrid--backend)))
            (unless (and event (functionp updater))
              (user-error "This backend cannot rename calendar entries"))
            (org-timegrid--call-update
             updater event
             (org-timegrid-event-start event)
             (org-timegrid-event-end event) title
             (org-timegrid-event-time-kind event))
            (org-timegrid--refresh-data)))))))

(defun org-timegrid--read-title (&optional initial)
  "Read a block title in the echo area, prefilled with INITIAL."
  (read-string "Title: " initial))

(defun org-timegrid--block-absolute-range (block)
  "Return BLOCK's absolute (START . END) minute range."
  (let ((day-minute
         (* (+ (org-timegrid--calendar-state-week-start org-timegrid--state)
               (org-timegrid-block-day block))
            1440)))
    (cons (+ day-minute (org-timegrid-block-start block))
          (+ day-minute (org-timegrid-block-end block)))))

(defun org-timegrid--accepts-arguments-p (function count)
  "Return non-nil when FUNCTION accepts COUNT arguments."
  (pcase-let ((`(,minimum . ,maximum) (func-arity function)))
    (and (<= minimum count)
         (or (eq maximum 'many) (>= maximum count)))))

(defun org-timegrid--call-update (updater event start end title time-kind)
  "Call UPDATER for EVENT, START, END and TITLE.
Pass an explicit TIME-KIND when UPDATER's contract supports it."
  (cond
   ((org-timegrid--accepts-arguments-p updater 5)
    (funcall updater event start end title time-kind))
   ((or title (org-timegrid--accepts-arguments-p updater 4))
    (funcall updater event start end title))
   (t (funcall updater event start end))))

(defun org-timegrid--backend-create (title block &optional source-event target)
  "Ask the active backend to create TITLE using BLOCK's range.
SOURCE-EVENT identifies an entry to reuse, and TARGET selects its destination."
  (let ((creator (org-timegrid-backend-create-function
                  org-timegrid--backend))
        (range (org-timegrid--block-absolute-range block)))
    (unless (functionp creator)
      (user-error "This backend cannot create calendar entries"))
    (if (org-timegrid--accepts-arguments-p creator 6)
        (funcall creator title (car range) (cdr range) source-event target
                 (org-timegrid-block-time-kind block))
      (if target
          (funcall creator title (car range) (cdr range) source-event target)
        (funcall creator title (car range) (cdr range) source-event)))
    (unless org-timegrid--defer-refresh (org-timegrid--refresh-data))))

(defun org-timegrid--read-entry ()
  "Read a title and optional existing record for a new block."
  (let ((reader (and org-timegrid--backend
                     (org-timegrid-backend-read-entry-function
                      org-timegrid--backend))))
    (if (functionp reader)
        (funcall reader)
      (cons (org-timegrid--read-title) nil))))

(defvar-local org-timegrid--edit-context nil
  "Backend edit scope retained during consecutive block adjustments.")

(defun org-timegrid--prepare-block-edit (block)
  "Let BLOCK's backend choose an edit scope before displaying a preview."
  (when-let* ((event (org-timegrid-block-event block))
              (prepare (plist-get (org-timegrid-event-metadata event)
                                  :prepare-edit)))
    (funcall prepare event)))

(defun org-timegrid--backend-update (block)
  "Ask the active backend to apply BLOCK's new range."
  (org-timegrid--with-update nil
    (let* ((updater (org-timegrid-backend-update-function
                     org-timegrid--backend))
           (event (org-timegrid-event-snapshot (org-timegrid-block-event block)))
           (range (org-timegrid--block-absolute-range block)))
      (unless (and event (functionp updater))
        (user-error "This backend cannot move or resize calendar entries"))
      (org-timegrid--prepare-block-edit block)
      (condition-case error-data
          (progn
            (org-timegrid--call-update
             updater event (car range) (cdr range) nil
             (org-timegrid-block-time-kind block))
            (setf (org-timegrid-event-start event) (car range)
                  (org-timegrid-event-end event) (cdr range)
                  (org-timegrid-event-all-day event)
                  (eq (org-timegrid-block-time-kind block) 'all-day))
            (setf (org-timegrid--calendar-state-events org-timegrid--state)
                  (mapcar (lambda (old)
                            (if (equal (org-timegrid-event-id old) (org-timegrid-event-id event))
                                event old))
                          (org-timegrid--calendar-state-events org-timegrid--state)))
            (if (plist-get (org-timegrid-event-metadata event) :reload-after-edit)
                (progn
                  (org-timegrid--refresh-data)
                  (when-let* ((updated (org-timegrid--block (org-timegrid-event-id event))))
                    (org-timegrid--goto-block updated)))
              (setf (org-timegrid--calendar-state-blocks org-timegrid--state)
                    (org-timegrid-events-to-blocks
                     (org-timegrid--calendar-state-events org-timegrid--state)
                     (org-timegrid--calendar-state-week-start org-timegrid--state)))))
        (error
         (org-timegrid--refresh-data)
         (signal (car error-data) (cdr error-data)))))))

(defun org-timegrid--apply (proposal)
  "Commit SVG drag PROPOSAL."
  (let ((error-message (org-timegrid--operation-error proposal))
        (kind (org-timegrid--operation-kind proposal))
        (block (and (org-timegrid--operation-block proposal)
                    (copy-org-timegrid-block
                     (org-timegrid--operation-block proposal)))))
    (cond
     (error-message
      (org-timegrid--clear-preview)
      (message "%s" error-message))
     ((eq kind 'create)
      (let (entry)
        (unwind-protect
            (progn
              (org-timegrid--set-preview proposal)
              (setq entry (org-timegrid--read-entry)))
          (org-timegrid--clear-preview))
        (unless (string-empty-p (car entry))
          (org-timegrid--backend-create
           (car entry) block nil (cdr entry)))))
     ((memq kind '(duplicate-entry add-occurrence))
      (org-timegrid--with-update nil
        (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil)
        (let ((source (org-timegrid--block (org-timegrid-block-id block))))
          (org-timegrid--backend-create
           (org-timegrid-block-title source) block
           (org-timegrid-block-event source)
           (and (eq kind 'add-occurrence)
                (org-timegrid-event-source (org-timegrid-block-event source)))))))
     ((memq kind '(move resize))
      (org-timegrid--with-update nil
        (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil
              (org-timegrid-block-preview block) nil)
        (org-timegrid--backend-update block)))
     (t (org-timegrid--clear-preview)))))

(defun org-timegrid-click (event)
  "Put the cursor where SVG mouse EVENT landed.
Clicking a block moves the cursor to that block's own first slot, which is
what selects it; clicking empty space moves the cursor to that slot and so
selects nothing.  The mouse and the keyboard drive one shared cursor."
  (interactive "@e")
  (org-timegrid--with-update nil
    (let* ((extend (memq 'shift (event-modifiers event)))
           (old-point (and extend (org-timegrid--cursor-calendar-minute)))
           (target (org-timegrid--target (event-start event)))
           (block (org-timegrid--block (plist-get target :block-id))))
      (if extend
          (unless (org-timegrid-region-active-p)
            (setf (org-timegrid--calendar-state-mark org-timegrid--state) old-point
                  (org-timegrid--calendar-state-region-active org-timegrid--state) t))
        (org-timegrid--deactivate-region))
      (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
      (if block
          (org-timegrid--goto-block block (plist-get target :day))
        (when (and (plist-get target :day) (plist-get target :minute))
          (org-timegrid--set-cursor (plist-get target :day)
                                    (plist-get target :minute))
          (org-timegrid--cursor-moved))))))

(defun org-timegrid--header-target (position)
  "Return all-day rail metadata at header-line mouse POSITION."
  (org-timegrid--with-render-context (org-timegrid--display-context)
  (let* ((xy (or (posn-object-x-y position) (posn-x-y position)))
         (x (car-safe xy))
         (y (cdr-safe xy))
         (window (posn-window position))
         (left-offset (org-timegrid--header-left-offset window))
         (canvas-width (org-timegrid--canvas-width))
         (column-width (org-timegrid--column-width)))
    (when (and (numberp x) (numberp y)
               (>= y (org-timegrid--rail-top))
               (>= x (+ left-offset (org-timegrid--label-width)))
               (< x (+ left-offset canvas-width)))
      (let ((geometry
             (cl-find-if
              (lambda (item)
                (and (<= (plist-get item :x) x
                         (+ (plist-get item :x) (plist-get item :width)))
                     (<= (plist-get item :y) y
                         (+ (plist-get item :y) (plist-get item :height)))))
              org-timegrid--header-geometry)))
        (list :surface 'rail
              :id (plist-get geometry :id)
              :block-id (plist-get geometry :id)
              :edge (and geometry (org-timegrid--rail-edge-at geometry x))
              :day (min (org-timegrid--last-day-index) (max 0 (floor
                                  (/ (- x left-offset
                                        (org-timegrid--label-width))
                                     column-width))))
              :minute 0
              :lane (max 0 (floor (/ (- y (org-timegrid--rail-top))
                                     (org-timegrid--all-day-lane-height))))))))))

(defun org-timegrid--header-navigation-action (position &optional coordinates window)
  "Return the navigation command assigned to header POSITION, if any.
COORDINATES and WINDOW allow callers to supply already decoded position data."
  (let* ((xy (or coordinates
                 (posn-object-x-y position)
                 (posn-x-y position)))
         (x (car-safe xy))
         (y (cdr-safe xy))
         (window (or window (posn-window position)))
         (left-offset (org-timegrid--header-left-offset window)))
    (when (and (numberp x) (numberp y))
      (cond
       ((< y (org-timegrid--header-title-height))
        #'org-timegrid-goto-date)
       ((and (= org-timegrid-days 1)
             (< x (+ left-offset (org-timegrid--label-width))))
        #'org-timegrid-goto-today)
       ((and (> org-timegrid-days 1)
             (< y (org-timegrid--rail-top))
             (>= x (+ left-offset (org-timegrid--label-width))))
        (let* ((column-width (org-timegrid--column-width))
               (day (floor (/ (- x left-offset
                                  (org-timegrid--label-width))
                               column-width)))
               (absolute (+ (org-timegrid--calendar-state-week-start
                             org-timegrid--state)
                            day)))
          (and (<= 0 day (org-timegrid--last-day-index))
               (= absolute
                  (calendar-absolute-from-gregorian (org-timegrid--today)))
               #'org-timegrid-goto-today)))))))

(defun org-timegrid--mouse-position-xy (position)
  "Return comparable POSITION coordinates across the rail and time grid."
  (let ((xy (or (posn-x-y position) (posn-object-x-y position))))
    (and xy (list (org-timegrid--mouse-surface position)
                  (car xy) (cdr xy)))))

(defun org-timegrid--rail-area-p (area)
  "Return non-nil when mouse AREA belongs to the all-day rail.
Image-map hotspots replace `header-line' in `posn-area', so all of the
rail's area names must be treated as one stable surface during a drag."
  (memq area '(header-line calendar-rail-block calendar-rail-resize)))

(defun org-timegrid--mouse-surface (position)
  "Return the stable calendar surface containing mouse POSITION."
  (if (org-timegrid--rail-area-p (posn-area position)) 'rail 'grid))

(defun org-timegrid--mouse-target (position)
  "Return calendar metadata for POSITION on either mouse surface."
  (let ((window (posn-window position)))
    (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
      (if (eq (org-timegrid--mouse-surface position) 'rail)
          (org-timegrid--header-target position)
        (org-timegrid--target position)))))

(defun org-timegrid-header-click (event)
  "Move the shared calendar cursor to all-day rail mouse EVENT."
  (interactive "@e")
  (org-timegrid--with-update nil
    (let* ((extend (memq 'shift (event-modifiers event)))
           (old-point (and extend (org-timegrid--cursor-calendar-minute)))
           (position (event-start event))
           (navigation (org-timegrid--header-navigation-action position))
           (target (org-timegrid--header-target position)))
      (cond
       (navigation
        (call-interactively navigation))
       ((null target)
        (message "Click inside an all-day cell"))
       (t
        (if extend
            (unless (org-timegrid-region-active-p)
              (setf (org-timegrid--calendar-state-mark org-timegrid--state)
                    old-point
                    (org-timegrid--calendar-state-region-active
                     org-timegrid--state) t))
          (org-timegrid--deactivate-region))
        (let ((day (plist-get target :day))
              (lane (plist-get target :lane))
              (id (plist-get target :id)))
          (org-timegrid--set-all-day-cursor day lane)
          (when id
            (setf (org-timegrid--calendar-state-selected-id org-timegrid--state)
                  id))
          (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state)
                t)
          (org-timegrid--cursor-moved)))))))

(defun org-timegrid--all-day-create-proposal (origin target)
  "Return a date-only creation proposal spanning ORIGIN through TARGET.
Both endpoints are rail targets.  The mouse-selected final day is inclusive;
the block and backend range use an exclusive midnight endpoint."
  (let ((origin-day (plist-get origin :day))
        (target-day (plist-get target :day)))
    (if (or (null origin-day) (null target-day))
        (org-timegrid--operation-create
         :error "Release inside an all-day cell")
      (let* ((first (min origin-day target-day))
             (last (max origin-day target-day))
             (block (org-timegrid--make-block
                     'preview first 0 (* (1+ (- last first)) 1440)
                     "New all-day block" nil nil 'all-day)))
        (setf (org-timegrid-block-preview block) t)
        (org-timegrid--operation-create :kind 'create :block block)))))

(defun org-timegrid--header-position-xy (position)
  "Return the SVG-local coordinates of header-line POSITION."
  (or (posn-object-x-y position) (posn-x-y position)))

(defmacro org-timegrid--with-gesture (origin &rest body)
  "Run BODY while ORIGIN's frozen geometry is represented in calendar state."
  (declare (indent 1) (debug t))
  `(progn
     (org-timegrid--with-update nil
       (setf (org-timegrid--calendar-state-gesture org-timegrid--state)
             (list :rail-rows (org-timegrid--rail-row-count (org-timegrid--all-day-layout))
                   :clock (when-let* ((block (org-timegrid--block (plist-get ,origin :block-id))))
                            (org-timegrid--clock-block-p block)))))
     (unwind-protect (progn ,@body)
       (org-timegrid--with-update nil
         (setf (org-timegrid--calendar-state-gesture org-timegrid--state) nil)))))

(defun org-timegrid--track-drag-gesture
    (event position-function target-function proposal-function click-function)
  "Track one mouse EVENT independently of its calendar surface.
POSITION-FUNCTION returns comparable pixel coordinates, TARGET-FUNCTION
returns model coordinates, PROPOSAL-FUNCTION builds a preview, and
CLICK-FUNCTION handles a press that never becomes a drag."
  (let* ((origin-position (event-start event))
         (origin (funcall target-function origin-position))
         (origin-xy (funcall position-function origin-position))
         (end-target origin)
         dragged finished next basic)
    (unwind-protect
        (progn
          ;; Freeze the rail while tracking so a preview cannot move the
          ;; grid beneath the pointer. Release that geometry before commit.
          (org-timegrid--with-gesture origin
            (track-mouse
              (while (not finished)
                (setq next (read-event)
                      basic (event-basic-type next))
                (cond
                 ((mouse-movement-p next)
                  (setq next (org-timegrid--latest-motion-event next))
                  (let* ((position (event-end next))
                         (xy (funcall position-function position))
                         (target (funcall target-function position)))
                    (when (and origin-xy xy (not (equal origin-xy xy)))
                      (setq dragged t end-target target)
                      (if target
                          (org-timegrid--set-preview
                           (funcall proposal-function origin end-target))
                        (org-timegrid--clear-preview)))))
                 ((memq basic '(mouse-1 drag-mouse-1))
                  ;; Commit only the target under the actual release.
                  (setq end-target (funcall target-function (event-end next))
                        finished t))
                 ((eq basic 'switch-frame))
                 (t
                  (push next unread-command-events)
                  (setq finished 'cancelled))))))
          (unless (eq finished 'cancelled)
            (if dragged
                (org-timegrid--apply (funcall proposal-function origin end-target))
              (funcall click-function origin-position))))
      (org-timegrid--clear-preview))))

(defun org-timegrid-header-press (event)
  "Track an all-day range creation gesture beginning with mouse EVENT.
Dragging an empty rail cell across date columns creates an inclusive range.
Pressing an existing block retains ordinary click-to-select behavior."
  (interactive "@e")
  (when mark-active (deactivate-mark))
  (let* ((origin-position (event-start event))
         (origin (org-timegrid--header-target origin-position))
         (modifiers (event-modifiers event))
         (copy-kind (cond ((memq 'super modifiers) 'duplicate-entry)
                          ((memq 'shift modifiers) 'add-occurrence)))
         (creator (and org-timegrid--backend
                       (org-timegrid-backend-create-function
                        org-timegrid--backend))))
    (cond
     ((null origin)
      (unless (org-timegrid--header-navigation-action origin-position)
        (message "Press inside an all-day cell")))
     ((plist-get origin :id)
      (let ((callback
             (and org-timegrid--backend
                  (if copy-kind
                      (org-timegrid-backend-create-function
                       org-timegrid--backend)
                    (org-timegrid-backend-update-function
                     org-timegrid--backend)))))
        (if (not (functionp callback))
            (progn
              (org-timegrid-header-click (list 'mouse-1 origin-position))
              (message "Unsupported drag"))
          (org-timegrid--track-drag-gesture
           event
           #'org-timegrid--mouse-position-xy
           #'org-timegrid--mouse-target
           (lambda (from to) (org-timegrid--proposal from to copy-kind))
           (lambda (position)
             (org-timegrid-header-click (list 'mouse-1 position)))))))
     ((not (functionp creator))
      (org-timegrid-header-click (list 'mouse-1 origin-position))
      (message "This backend cannot create calendar entries"))
     (t
      (org-timegrid--track-drag-gesture
       event
       #'org-timegrid--header-position-xy
       (lambda (position)
         (when (eq (org-timegrid--mouse-surface position) 'rail)
           (org-timegrid--mouse-target position)))
       #'org-timegrid--all-day-create-proposal
       (lambda (position)
         (org-timegrid-header-click (list 'mouse-1 position))))))))

(defun org-timegrid-header-visit (event)
  "Visit the all-day event under header-line mouse EVENT."
  (interactive "@e")
  (when-let* ((target (org-timegrid--header-target (event-start event)))
              (block (org-timegrid--block (plist-get target :id)))
              (calendar-event (org-timegrid-block-event block))
              (visitor (org-timegrid-backend-visit-function
                        org-timegrid--backend)))
    (funcall visitor calendar-event)))

(defun org-timegrid-ignore-double-press (_event)
  "Ignore the second button press so its double-click release can visit.
The first press still follows the ordinary click-or-drag path."
  (interactive "e"))

(defun org-timegrid-visit (event)
  "Visit the source event under double-click mouse EVENT."
  (interactive "@e")
  (let* ((target (org-timegrid--target (event-start event)))
         (block (org-timegrid--block
                 (plist-get target :block-id)))
         (calendar-event (and block (org-timegrid-block-event block)))
         (visitor (and org-timegrid--backend
                       (org-timegrid-backend-visit-function
                        org-timegrid--backend))))
    (if (and calendar-event (functionp visitor))
        (funcall visitor calendar-event)
      (message "No source to visit"))))

(defun org-timegrid--latest-motion-event (event)
  "Return the newest consecutive mouse-motion EVENT waiting in the queue.
Leave the first non-motion event for the gesture loop to process."
  (let ((latest event))
    (catch 'done
      (while (input-pending-p)
        (let ((pending (read-event nil nil 0)))
          (cond
           ((null pending) (throw 'done nil))
           ((mouse-movement-p pending) (setq latest pending))
           (t
            (push pending unread-command-events)
            (throw 'done nil))))))
    latest))

(defun org-timegrid-press (event)
  "Track a complete create, move, duplicate, occurrence, or resize EVENT."
  (interactive "@e")
  (when mark-active (deactivate-mark))
  (let* ((origin-position (event-start event))
         (origin (org-timegrid--target origin-position))
         (modifiers (event-modifiers event))
         ;; Super, which is the Option key under the usual macOS mapping,
         ;; makes an independent entry.  Shift retains the source entry.
         (copy-kind (cond ((memq 'super modifiers) 'duplicate-entry)
                          ((memq 'shift modifiers) 'add-occurrence)))
         (required-callback
          (and org-timegrid--backend
               (if (or copy-kind (null (plist-get origin :block-id)))
                   (org-timegrid-backend-create-function
                    org-timegrid--backend)
                 (org-timegrid-backend-update-function
                  org-timegrid--backend)))))
    (if (and org-timegrid--backend
             (not (functionp required-callback)))
        (progn
          (org-timegrid-click (list 'mouse-1 origin-position))
          (message "Unsupported drag"))
      (org-timegrid--track-drag-gesture
       event
       #'org-timegrid--mouse-position-xy
       #'org-timegrid--mouse-target
       (lambda (from to)
         (org-timegrid--proposal from to copy-kind))
       (lambda (position)
         (org-timegrid-click (list 'mouse-1 position)))))))

(defun org-timegrid-pointer-feedback (event)
  "Set a resize or move pointer under SVG mouse EVENT."
  (interactive "e")
  (let* ((position (event-end event))
         (window (posn-window position)))
    (when (windowp window)
      (with-current-buffer (window-buffer window)
        (let* ((target (org-timegrid--target position))
               (shape (cond ((plist-get target :edge) 'nhdrag)
                            ((plist-get target :block-id) 'hand)))
               (point (posn-point position)))
          (when (integer-or-marker-p point)
            (unless (overlayp org-timegrid--pointer-overlay)
              (setq-local org-timegrid--pointer-overlay
                          (make-overlay point (1+ point))))
            ;; Each hour tile is a separate display glyph.  Keeping this
            ;; overlay on the first tile visited makes its pointer property
            ;; appear to work only after unrelated selection redraws.
            (move-overlay org-timegrid--pointer-overlay point (1+ point))
            (overlay-put org-timegrid--pointer-overlay
                         'pointer shape)
            (force-window-update window)))))))

(defun org-timegrid-scroll (pixels &optional window)
  "Scroll the tall SVG image by PIXELS in calendar WINDOW."
  (interactive "p")
  (let ((window (or window (get-buffer-window (current-buffer) t))))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (when (and (derived-mode-p 'org-timegrid-mode)
                   (numberp org-timegrid--image-height))
          (let* ((now (float-time))
                 (current (org-timegrid--window-scroll-pixels window))
                 (maximum
                  (max 0 (- org-timegrid--image-height
                            (window-body-height window t))))
                 (rebound
                  (and org-timegrid--scroll-boundary
                       (< (- now (cdr org-timegrid--scroll-boundary))
                          org-timegrid--scroll-rebound-seconds)
                       (or (and (eq (car org-timegrid--scroll-boundary) 'top)
                                (> pixels 0))
                           (and (eq (car org-timegrid--scroll-boundary) 'bottom)
                                (< pixels 0)))))
                 (next
                  (max 0 (min maximum
                              (+ current pixels)))))
            (cond
             ((and (zerop current) (< pixels 0))
              (setq-local org-timegrid--scroll-boundary (cons 'top now)))
             ((and (= current maximum) (> pixels 0))
              (setq-local org-timegrid--scroll-boundary (cons 'bottom now)))
             ((not rebound)
              (setq-local org-timegrid--scroll-boundary nil)
              (org-timegrid--set-vscroll window next)))))))))

(defun org-timegrid--event-window (event)
  "Return the live calendar window associated with mouse EVENT."
  (let ((window (posn-window (event-start event))))
    (and (window-live-p window)
         (with-current-buffer (window-buffer window)
           (derived-mode-p 'org-timegrid-mode))
         window)))

(defun org-timegrid--cursor-moved ()
  "Describe the current cursor or selection in the echo area."
  (if (org-timegrid-region-active-p)
      (message "%s" (org-timegrid--region-message))
    (if-let* ((block (org-timegrid--block-at-cursor)))
        (message "%s" (org-timegrid--block-details block))
      (message nil))))

(defvar-local org-timegrid--recenter-position nil
  "Last cursor alignment used by `org-timegrid-recenter'.")

(defun org-timegrid-recenter ()
  "Cycle the cursor's slot through middle, top, and bottom of the window.
Ordinary motion scrolls only as far as it must, which keeps the cursor at
an edge after a long run; this is the view half of that on its own, so
the cursor never moves to satisfy the scroll."
  (interactive)
  (let ((position (if (eq last-command 'org-timegrid-recenter)
                      (pcase org-timegrid--recenter-position
                        ('middle 'top)
                        ('top 'bottom)
                        (_ 'middle))
                    'middle))
        (cursor (org-timegrid--ensure-cursor))
        (window (get-buffer-window (current-buffer) t)))
    (setq org-timegrid--recenter-position position)
    (when (window-live-p window)
      (let* ((scale (org-timegrid--pixels-per-minute))
             (top (+ (org-timegrid--grid-top-inset)
                     (* (- (org-timegrid--cursor-state-minute cursor)
                           (* 60 org-timegrid-start-hour))
                        scale)))
             (body (window-body-height window t))
             (maximum (max 0 (- (or org-timegrid--image-height 0) body))))
        (org-timegrid--set-vscroll
         window
         (max 0 (min maximum
                     (round (- top
                               (pcase position
                                 ('top 0)
                                 ('bottom (- body (* org-timegrid-slot-minutes
                                                     scale)))
                                 (_ (/ (- body (* org-timegrid-slot-minutes
                                                  scale)) 2))))))))))))

(defun org-timegrid--move-cursor (minutes days)
  "Move the cursor by MINUTES and DAYS, revealing it first when hidden."
  (org-timegrid--with-update nil
    (if (org-timegrid--reveal-cursor)
        (org-timegrid--cursor-moved)
      (let ((cursor (org-timegrid--cursor)))
        (org-timegrid--set-cursor (+ (org-timegrid--cursor-state-day cursor) days)
                                  (+ (org-timegrid--cursor-state-minute cursor) minutes)))
      (org-timegrid--cursor-moved))))

(defun org-timegrid--lane-count (day minute)
  "Return how many blocks overlap the slot at DAY and MINUTE."
  (length (org-timegrid--blocks-at-slot day minute)))

(defun org-timegrid--all-day-visible-rows ()
  "Return the number of occupied event rows currently shown in the rail."
  (let ((blocks (org-timegrid--all-day-layout)))
    (if blocks
        (min org-timegrid-all-day-max-lanes
             (1+ (apply #'max (mapcar (lambda (block)
                                        (org-timegrid-block-rail-lane block))
                                      blocks))))
      0)))

(defun org-timegrid--all-day-at (day lane)
  "Return the all-day block occupying DAY and LANE, if any."
  (cl-find-if
   (lambda (block)
     (and (= lane (org-timegrid-block-rail-lane block))
          (< (* day 1440) (org-timegrid-block-rail-end block))
          (< (org-timegrid-block-rail-start block) (* (1+ day) 1440))))
   (org-timegrid--all-day-layout)))

(defun org-timegrid--set-all-day-cursor (day lane)
  "Place the cursor in all-day rail cell DAY, LANE."
  (let ((block (org-timegrid--all-day-at day lane)))
    (setf (org-timegrid--calendar-state-cursor org-timegrid--state)
          (org-timegrid--cursor-state-create
           :surface 'rail :day day :minute 0 :lane lane)
          (org-timegrid--calendar-state-selected-id org-timegrid--state)
          (and block (org-timegrid-block-id block)))))

(defun org-timegrid--grid-stops (day)
  "Return (MINUTE . BLOCK-ID) stops for DAY in navigation order.
An empty step boundary has a nil id.  Blocks replace empty boundaries at
their start time, and blocks sharing a start each get a stop."
  (let* ((start (* 60 org-timegrid-start-hour))
         (end (* 60 org-timegrid-end-hour))
         (blocks (seq-filter
                  (lambda (block)
                    (and (not (org-timegrid-block-all-day-p block))
                         (= (org-timegrid-block-day block) day)
                         (<= start (org-timegrid-block-start block))
                         (< (org-timegrid-block-start block) end)))
                  (org-timegrid--ordered-blocks)))
         (stops (mapcar (lambda (block)
                          (cons (org-timegrid-block-start block)
                                (org-timegrid-block-id block)))
                        blocks)))
    (cl-loop for minute from start below end by org-timegrid-slot-minutes
             unless (assoc minute stops) do (push (cons minute nil) stops))
    (cl-stable-sort stops #'< :key #'car)))

(defun org-timegrid--set-grid-stop (day stop)
  "Place the grid cursor on DAY at (MINUTE . BLOCK-ID) STOP."
  (setf (org-timegrid--calendar-state-selected-id org-timegrid--state) (cdr stop)
        (org-timegrid--calendar-state-cursor org-timegrid--state)
        (org-timegrid--cursor-state-create
         :surface 'grid :day day :minute (car stop)
         :lane (or (cl-position (cdr stop)
                                (org-timegrid--blocks-at-slot day (car stop))
                                :key #'org-timegrid-block-id :test #'equal)
                   0))))

(defun org-timegrid--move-grid-stop (direction)
  "Move to the next grid boundary or block start in DIRECTION."
  (let* ((cursor (org-timegrid--cursor))
         (day (org-timegrid--cursor-state-day cursor))
         (minute (org-timegrid--cursor-state-minute cursor))
         (selected (org-timegrid--selected-id))
         (stops (org-timegrid--grid-stops day))
         (index (and selected
                     (cl-position selected stops :key #'cdr :test #'equal)))
         (next (if index
                   (let ((target (+ index direction)))
                     (and (<= 0 target) (nth target stops)))
                 (seq-find (lambda (stop)
                             (if (> direction 0)
                                 (> (car stop) minute)
                               (< (car stop) minute)))
                           (if (> direction 0) stops (reverse stops))))))
    (when next
      (org-timegrid--set-grid-stop day next))))

(defun org-timegrid-cursor-forward (&optional count)
  "Move COUNT stops later, visiting step boundaries and every block start."
  (interactive "p")
  (org-timegrid--with-update nil
    (let ((count (or count 1)))
      (if (< count 0)
          (org-timegrid-cursor-backward (- count))
        (if (org-timegrid--reveal-cursor)
            (org-timegrid--cursor-moved)
          (dotimes (_ count)
            (let ((cursor (org-timegrid--cursor)))
              (if (eq (org-timegrid--cursor-state-surface cursor) 'rail)
                  (let ((next (1+ (org-timegrid--cursor-state-lane cursor)))
                        (rows (org-timegrid--all-day-visible-rows)))
                    (if (> next rows)
                        (org-timegrid--set-grid-stop
                         (org-timegrid--cursor-state-day cursor)
                         (car (org-timegrid--grid-stops
                               (org-timegrid--cursor-state-day cursor))))
                      (org-timegrid--set-all-day-cursor
                       (org-timegrid--cursor-state-day cursor) next)))
                (org-timegrid--move-grid-stop 1))))
          (org-timegrid--cursor-moved))))))

(defun org-timegrid-cursor-backward (&optional count)
  "Move the cursor COUNT stops earlier."
  (interactive "p")
  (org-timegrid--with-update nil
    (let ((count (or count 1)))
      (if (< count 0)
          (org-timegrid-cursor-forward (- count))
        (if (org-timegrid--reveal-cursor)
            (org-timegrid--cursor-moved)
          (dotimes (_ count)
            (let ((cursor (org-timegrid--cursor)))
              (cond
               ((eq (org-timegrid--cursor-state-surface cursor) 'rail)
                (org-timegrid--set-all-day-cursor
                 (org-timegrid--cursor-state-day cursor)
                 (max 0 (1- (org-timegrid--cursor-state-lane cursor)))))
               ((and (not (org-timegrid--move-grid-stop -1))
                     (= (org-timegrid--cursor-state-minute cursor)
                        (* 60 org-timegrid-start-hour)))
                (org-timegrid--set-all-day-cursor
                 (org-timegrid--cursor-state-day cursor)
                 (org-timegrid--all-day-visible-rows))))))
          (org-timegrid--cursor-moved))))))

(defun org-timegrid-cursor-forward-slot (&optional count)
  "Move the cursor COUNT calendar slots later."
  (interactive "p")
  (org-timegrid--move-cursor
   (* (or count 1) org-timegrid-slot-minutes) 0))

(defun org-timegrid-cursor-backward-slot (&optional count)
  "Move the cursor COUNT calendar slots earlier."
  (interactive "p")
  (org-timegrid-cursor-forward-slot (- (or count 1))))

(defun org-timegrid-cursor-forward-day (&optional count)
  "Move the cursor one lane to the right, or COUNT day columns.
Where several blocks overlap the cursor's slot this walks their lanes
first, so two events at the same time are both reachable; once past the
last lane, or where there is only one, it moves by a day."
  (interactive "p")
  (org-timegrid--with-update nil
    (if (org-timegrid--reveal-cursor)
        (org-timegrid--cursor-moved)
      (let* ((count (or count 1))
             (cursor (org-timegrid--cursor))
             (rail (eq (org-timegrid--cursor-state-surface cursor) 'rail))
             (lane (or (org-timegrid--cursor-state-lane cursor) 0))
             (lanes (org-timegrid--lane-count (org-timegrid--cursor-state-day cursor)
                                              (org-timegrid--cursor-state-minute cursor))))
        (cond
         ((and (not rail) (> count 0) (< (1+ lane) lanes))
          (org-timegrid--set-cursor (org-timegrid--cursor-state-day cursor)
                                    (org-timegrid--cursor-state-minute cursor) (1+ lane)))
         ((and (not rail) (< count 0) (> lane 0))
          (org-timegrid--set-cursor (org-timegrid--cursor-state-day cursor)
                                    (org-timegrid--cursor-state-minute cursor) (1- lane)))
         (t
          (let* ((target (+ (org-timegrid--cursor-state-day cursor) count))
                 (week-offset (* org-timegrid-days
                                 (floor target org-timegrid-days)))
                 (day (mod target org-timegrid-days))
                 (minute (org-timegrid--cursor-state-minute cursor)))
            (when (/= week-offset 0)
              (org-timegrid--reload-state
               (+ (org-timegrid--calendar-state-week-start org-timegrid--state) week-offset)))
            (if rail
                (org-timegrid--set-all-day-cursor day lane)
              (org-timegrid--set-cursor day minute 0)))))
        (org-timegrid--cursor-moved)))))

(defun org-timegrid-cursor-backward-day (&optional count)
  "Move the cursor one lane to the left, or COUNT day columns."
  (interactive "p")
  (org-timegrid-cursor-forward-day (- (or count 1))))

(defun org-timegrid-cursor-day-start ()
  "Move the cursor to the first visible slot in its own day."
  (interactive)
  (org-timegrid--with-update nil
    (unless (org-timegrid--reveal-cursor)
      (org-timegrid--set-cursor
       (org-timegrid--cursor-state-day (org-timegrid--cursor))
       (* 60 org-timegrid-start-hour)))
    (org-timegrid--cursor-moved)))

(defun org-timegrid-cursor-day-end ()
  "Move the cursor to the last slot of its own day."
  (interactive)
  (org-timegrid--with-update nil
    (unless (org-timegrid--reveal-cursor)
      (org-timegrid--set-cursor
       (org-timegrid--cursor-state-day (org-timegrid--cursor))
       (- (* 60 org-timegrid-end-hour)
          org-timegrid-slot-minutes)))
    (org-timegrid--cursor-moved)))

(defun org-timegrid--page-minutes (&optional window)
  "Return one screenful expressed in minutes for WINDOW."
  (let ((window (or window (get-buffer-window (current-buffer) t))))
    (max org-timegrid-slot-minutes
         (org-timegrid--snap-minute
          (/ (- (if window (window-body-height window t) 400) 40)
             (org-timegrid--pixels-per-minute))))))

(defun org-timegrid-cursor-page-down (&optional count)
  "Move the cursor COUNT screenfuls later."
  (interactive "p")
  (org-timegrid--move-cursor
   (* (or count 1) (org-timegrid--page-minutes)) 0))

(defun org-timegrid-cursor-page-up (&optional count)
  "Move the cursor COUNT screenfuls earlier."
  (interactive "p")
  (org-timegrid--move-cursor
   (* (- (or count 1)) (org-timegrid--page-minutes)) 0))

(defun org-timegrid--block-visible-start (block)
  "Return BLOCK's first week minute, clipping carry-in events to midnight."
  (max 0 (org-timegrid--block-absolute-start block)))

(defun org-timegrid--ordered-blocks ()
  "Return committed blocks in visible keyboard-navigation order.
For each date, all-day blocks anchored there follow their displayed lanes
from top to bottom, followed by that day's timed blocks.  A multi-day block
occurs once, at its first visible date.  Timed blocks sharing a start are
visited from left to right."
  (let* ((all-day (org-timegrid--all-day-layout))
         (timed (seq-filter
                 (lambda (block) (not (org-timegrid-block-preview block)))
                 (org-timegrid--timed-blocks)))
         result)
    (dotimes (day-index org-timegrid-days)
      (let ((positions (make-hash-table :test #'equal))
            day-all-day day-timed)
        (dolist (block all-day)
          (when (and (= day-index
                        (floor (org-timegrid-block-rail-start block) 1440))
                     (< (org-timegrid-block-rail-lane block)
                        org-timegrid-all-day-max-lanes))
            (push block day-all-day)))
        (dolist (block timed)
          (when (= day-index (max 0 (org-timegrid-block-day block)))
            (push block day-timed)))
        (dolist (block (org-timegrid--layout-day timed day-index))
          (puthash (org-timegrid-block-id block)
                   (car (org-timegrid--layout-frame
                         block 0 (org-timegrid--column-width)))
                   positions))
        (setq result
              (append
               result
               (sort day-all-day
                     (lambda (left right)
                       (< (org-timegrid-block-rail-lane left)
                          (org-timegrid-block-rail-lane right))))
               (sort day-timed
                     (lambda (left right)
                       (let ((ls (org-timegrid--block-visible-start left))
                             (rs (org-timegrid--block-visible-start right)))
                         (if (= ls rs)
                             (< (gethash (org-timegrid-block-id left) positions 0)
                                (gethash (org-timegrid-block-id right) positions 0))
                           (< ls rs)))))))))
    result))

(defun org-timegrid--goto-block (block &optional day)
  "Select BLOCK at its first visible slot, or its segment on DAY."
  (org-timegrid--with-update nil
    (let* ((day (or day (max 0 (min (org-timegrid--last-day-index)
                                    (org-timegrid-block-day block)))))
           (start (if (> day (org-timegrid-block-day block)) 0
                    (org-timegrid-block-start block))))
      (if (org-timegrid-block-all-day-p block)
          (let ((laid-out
                 (cl-find (org-timegrid-block-id block) (org-timegrid--all-day-layout)
                          :key (lambda (candidate) (org-timegrid-block-id candidate))
                          :test #'equal)))
            (org-timegrid--set-all-day-cursor
             (floor (or (and laid-out
                             (org-timegrid-block-rail-start laid-out))
                        0)
                    1440)
             (or (and laid-out (org-timegrid-block-rail-lane laid-out)) 0)))
        (org-timegrid--set-cursor day start))
      (setf (org-timegrid--calendar-state-selected-id org-timegrid--state)
            (org-timegrid-block-id block))
      (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
      (org-timegrid--cursor-moved))))

(defun org-timegrid--move-selection (direction)
  "Select the next block in DIRECTION across the visible week.
DIRECTION is 1 for later or -1 for earlier.  Without a selection the
search starts from the cursor."
  (let* ((blocks (org-timegrid--ordered-blocks))
         (selected (org-timegrid--selected-id))
         (index (and selected
                     (cl-position selected blocks
                                  :key (lambda (block) (org-timegrid-block-id block))
                                  :test #'equal)))
         (from (org-timegrid--cursor-absolute)))
    (cond
     ;; Walking the ordered list by index, rather than comparing start
     ;; times, is what keeps two blocks sharing a start reachable.
     (index
     (let ((next (+ index direction)))
        (if (and (>= next 0) (< next (length blocks)))
            (org-timegrid--goto-block (nth next blocks))
          (org-timegrid--move-selection-across-week direction))))
     ;; With nothing selected, land on the nearest block in that direction,
     ;; including one that starts exactly at the cursor.
     (t
      (let ((candidates
             (if (> direction 0)
                 (seq-filter
                  (lambda (block)
                    (>= (org-timegrid--block-visible-start block) from))
                  blocks)
               (nreverse
                (seq-filter
                 (lambda (block)
                   (<= (org-timegrid--block-visible-start block) from))
                 blocks)))))
        (if candidates
            (org-timegrid--goto-block (car candidates))
          (org-timegrid--move-selection-across-week direction)))))))

(defun org-timegrid--move-selection-across-week (direction)
  "Move one week in DIRECTION and select its first or last block."
  (org-timegrid--with-update nil
    (let* ((week-start (+ (org-timegrid--calendar-state-week-start org-timegrid--state)
                          (* direction org-timegrid-days)))
           (state (org-timegrid--load-state week-start))
           (blocks (let ((org-timegrid--state state))
                     (org-timegrid--ordered-blocks))))
      ;; Loading the prospective week separately keeps failed navigation a
      ;; no-op: do not replace the current week or manufacture an edge cursor
      ;; when there is no block to select.
      (if blocks
          (progn
            (setq-local org-timegrid--state state)
            (setq-local org-timegrid--static-inner nil)
            (org-timegrid--goto-block
             (if (> direction 0) (car blocks) (car (last blocks)))))
        (message "No further block")))))

(defun org-timegrid-next-block ()
  "Select the next block by start time, anywhere in the visible week."
  (interactive)
  (org-timegrid--move-selection 1))

(defun org-timegrid-previous-block ()
  "Select the previous block by start time, anywhere in the visible week."
  (interactive)
  (org-timegrid--move-selection -1))

(defun org-timegrid--block-at-cursor ()
  "Return the explicitly selected block, or nil at an empty cursor stop."
  (org-timegrid--block (org-timegrid--selected-id)))

;;; Keyboard editing
;;
;; Every command below builds the same proposal a drag would and commits it
;; through `org-timegrid--apply', so snapping, the minimum slot duration,
;; week clamping, stale-marker detection, read-only refusal, and repeating
;; series handling are inherited rather than reimplemented.

(defun org-timegrid--selected-block ()
  "Return the selected block, or signal a user error."
  (let ((block (org-timegrid--block (org-timegrid--selected-id))))
    (unless block
      (user-error "No block selected; press n, or move the cursor onto a block"))
    block))

(defun org-timegrid--follow-block (id day minute &optional all-day)
  "Put the cursor back on block ID, or on DAY and MINUTE if it is gone.
ALL-DAY selects the date rail when the block cannot be found.
Following by id preserves explicit selection and picks up the block's new
lane after an edit changes its layout."
  (org-timegrid--with-update nil
    (if-let* ((block (org-timegrid--block id)))
        (org-timegrid--goto-block block)
      (if all-day
          (org-timegrid--set-all-day-cursor
           (max 0 (min (org-timegrid--last-day-index) day)) 0)
        (org-timegrid--set-cursor day minute 0))
      (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
      (org-timegrid--cursor-moved))))

(defun org-timegrid--all-day-to-timed-proposal (block)
  "Return a proposal converting one-day date-only BLOCK at midnight."
  (let* ((copy (copy-org-timegrid-block block))
         (start (org-timegrid--block-absolute-start block))
         (duration (- (org-timegrid-block-end block)
                      (org-timegrid-block-start block))))
    (unless (= duration 1440)
      (user-error "Multi-day blocks cannot move into the time grid"))
    (org-timegrid--set-absolute-range
     copy start (+ start org-timegrid-default-duration-minutes))
    (setf (org-timegrid-block-time-kind copy) 'timed
          (org-timegrid-block-preview copy) t)
    (org-timegrid--operation-create
     :kind 'move :block copy :replace-id (org-timegrid-block-id block))))

(defun org-timegrid--commit-keyboard-edit (&optional buffer)
  "Commit BUFFER's pending keyboard block edit."
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (timerp org-timegrid--keyboard-edit-timer)
          (cancel-timer org-timegrid--keyboard-edit-timer))
        (setq-local org-timegrid--keyboard-edit-timer nil)
        (when-let* ((proposal org-timegrid--keyboard-edit))
          (setq-local org-timegrid--keyboard-edit nil)
          (let* ((block (org-timegrid--operation-block proposal))
                 (day (org-timegrid-block-day block))
                 (minute (org-timegrid-block-start block)))
            (org-timegrid--with-update nil
              (org-timegrid--apply proposal)
              (org-timegrid--follow-block
               (org-timegrid-event-id (org-timegrid-block-event block))
               day minute (org-timegrid-block-all-day-p block)))))))))

(defun org-timegrid--schedule-keyboard-commit ()
  "Restart the idle timer that commits keyboard block movement."
  (when (timerp org-timegrid--keyboard-edit-timer)
    (cancel-timer org-timegrid--keyboard-edit-timer))
  (setq-local
   org-timegrid--keyboard-edit-timer
   (run-with-idle-timer
    (max 0 org-timegrid-keyboard-commit-delay) nil
    #'org-timegrid--commit-keyboard-edit (current-buffer))))

(defun org-timegrid--commit-before-unrelated-command ()
  "Commit a keyboard edit before running a command outside its edit family."
  (when (not (memq this-command
                        '(org-timegrid-move-later
                          org-timegrid-move-earlier
                          org-timegrid-move-next-day
                          org-timegrid-move-previous-day
                          org-timegrid-grow-end
                          org-timegrid-shrink-end
                          org-timegrid-grow-start
                          org-timegrid-shrink-start
                          org-timegrid-grow-all-day-end
                          org-timegrid-shrink-all-day-end
                          org-timegrid-grow-all-day-start
                          org-timegrid-shrink-all-day-start)))
    (org-timegrid--commit-keyboard-edit)
    (setq org-timegrid--edit-context nil)))

(defun org-timegrid--edit-selected (minutes days edge)
  "Shift the selected block by MINUTES and DAYS, resizing EDGE when provided."
  (org-timegrid--with-update nil
    (let* ((block (or (and org-timegrid--keyboard-edit
                           (org-timegrid--operation-block org-timegrid--keyboard-edit))
                      (org-timegrid--selected-block)))
           (updater (org-timegrid-backend-update-function org-timegrid--backend)))
      (unless (and (org-timegrid-block-event block) (functionp updater))
        (user-error "This backend cannot move or resize calendar entries"))
      (org-timegrid--prepare-block-edit block)
      (let* ((proposal (if (and (org-timegrid-block-all-day-p block) (/= minutes 0))
                           (org-timegrid--all-day-to-timed-proposal block)
                         (org-timegrid--edit-proposal block minutes days edge)))
             (moved (org-timegrid--operation-block proposal)))
        (setq org-timegrid--keyboard-edit proposal)
        (setf (org-timegrid--calendar-state-preview org-timegrid--state) proposal
              (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
        (if (org-timegrid-block-all-day-p moved)
            (let ((laid-out (cl-find (org-timegrid-block-id moved)
                                     (org-timegrid--all-day-layout)
                                     :key #'org-timegrid-block-id :test #'equal)))
              (org-timegrid--set-all-day-cursor
               (max 0 (min (org-timegrid--last-day-index)
                           (floor (or (and laid-out (org-timegrid-block-rail-start laid-out)) 0) 1440)))
               (or (and laid-out (org-timegrid-block-rail-lane laid-out)) 0)))
          (org-timegrid--set-cursor (org-timegrid-block-day moved)
                                    (org-timegrid-block-start moved) 0))
        (org-timegrid--schedule-keyboard-commit)))))

(defun org-timegrid-copy-to-next-day (&optional count)
  "Copy the selected block COUNT days later, at the same time.
The cursor follows the copy, so holding the key spreads one entry across
consecutive days instead of stacking every copy on the same one."
  (interactive "p")
  (org-timegrid--with-update nil
    (let* ((block (org-timegrid--selected-block))
           (start (org-timegrid-block-start block))
           (day (+ (org-timegrid-block-day block) (or count 1)))
           (title (org-timegrid-block-title block)))
      (unless (<= 0 day (org-timegrid--last-day-index))
        (user-error "That day is outside the visible week"))
      (let ((copy (copy-org-timegrid-block block)))
        (setf (org-timegrid-block-day copy) day)
        (org-timegrid--backend-create
         title copy (org-timegrid-block-event block)
         (org-timegrid-event-source (org-timegrid-block-event block))))
      ;; The new timestamp belongs to the same heading, but its event identity
      ;; is not known until the backend data is reloaded, so follow its slot.
      (let* ((candidates (org-timegrid--blocks-at-slot day start))
             (lane (or (cl-position title candidates
                                    :key (lambda (candidate)
                                           (org-timegrid-block-title candidate))
                                    :test #'equal)
                       0)))
        (org-timegrid--set-cursor day start lane)
        (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)))))

(defun org-timegrid-copy-to-previous-day (&optional count)
  "Copy the selected block COUNT days earlier, at the same time."
  (interactive "p")
  (org-timegrid-copy-to-next-day (- (or count 1))))

(defun org-timegrid-move-later (&optional count)
  "Move the selected block COUNT calendar slots later."
  (interactive "p")
  (org-timegrid--edit-selected
   (* (or count 1) org-timegrid-slot-minutes) 0 nil))

(defun org-timegrid-move-earlier (&optional count)
  "Move the selected block COUNT calendar slots earlier."
  (interactive "p")
  (org-timegrid-move-later (- (or count 1))))

(defun org-timegrid-move-next-day (&optional count)
  "Move the selected block COUNT days later."
  (interactive "p")
  (org-timegrid--edit-selected 0 (or count 1) nil))

(defun org-timegrid-move-previous-day (&optional count)
  "Move the selected block COUNT days earlier."
  (interactive "p")
  (org-timegrid-move-next-day (- (or count 1))))

(defun org-timegrid-grow-end (&optional count)
  "Move the selected block's end COUNT slots later.
This only ever resizes.  Fine cursor motion has its own keys, because
sharing one key made nudging the cursor resize whatever it had selected."
  (interactive "p")
  (org-timegrid--edit-selected
   (* (or count 1) org-timegrid-slot-minutes) 0 'bottom))

(defun org-timegrid-shrink-end (&optional count)
  "Move the selected block's end COUNT slots earlier."
  (interactive "p")
  (org-timegrid-grow-end (- (or count 1))))

(defun org-timegrid-grow-start (&optional count)
  "Move the selected block's start COUNT slots earlier, keeping its end."
  (interactive "p")
  (org-timegrid--edit-selected
   (* (- (or count 1)) org-timegrid-slot-minutes) 0 'top))

(defun org-timegrid-shrink-start (&optional count)
  "Move the selected block's start COUNT slots later, keeping its end."
  (interactive "p")
  (org-timegrid-grow-start (- (or count 1))))

(defun org-timegrid--require-all-day-selection ()
  "Return the selected date-only block, or signal a user error."
  (let ((block (org-timegrid--selected-block)))
    (unless (org-timegrid-block-all-day-p block)
      (user-error "This key resizes date-only blocks in the all-day rail"))
    block))

(defun org-timegrid-grow-all-day-end (&optional count)
  "Move the selected date-only block's end COUNT days later."
  (interactive "p")
  (org-timegrid--require-all-day-selection)
  (org-timegrid--edit-selected 0 (or count 1) 'bottom))

(defun org-timegrid-shrink-all-day-end (&optional count)
  "Move the selected date-only block's end COUNT days earlier."
  (interactive "p")
  (org-timegrid-grow-all-day-end (- (or count 1))))

(defun org-timegrid-grow-all-day-start (&optional count)
  "Move the selected date-only block's start COUNT days earlier."
  (interactive "p")
  (org-timegrid--require-all-day-selection)
  (org-timegrid--edit-selected 0 (- (or count 1)) 'top))

(defun org-timegrid-shrink-all-day-start (&optional count)
  "Move the selected date-only block's start COUNT days later."
  (interactive "p")
  (org-timegrid-grow-all-day-start (- (or count 1))))

(defun org-timegrid-create-at-cursor ()
  "Create a block at the cursor.
Rail cells create a one-day date-only entry without a duration prompt;
time-grid cells prompt for the timed duration as usual."
  (interactive)
  (org-timegrid--with-update nil
    (org-timegrid--reveal-cursor)
    (let* ((cursor (org-timegrid--ensure-cursor))
           (range (org-timegrid--region-range))
           (all-day (eq (org-timegrid--cursor-state-surface cursor) 'rail))
           (_ (when (and range (= (car range) (cdr range)))
                (user-error "Move point to give the calendar region a duration")))
           (entry (org-timegrid--read-entry))
           (title (car entry)))
      (if (string-empty-p title)
          (message "Nothing created")
        (let* ((minutes (if range
                            (- (cdr range) (car range))
                          (if all-day
                              1440
                            (org-timegrid--read-minutes
                             org-timegrid-default-duration-minutes))))
               (absolute-start (and range (car range)))
               (day (if range
                        (- (floor absolute-start 1440)
                           (org-timegrid--calendar-state-week-start
                            org-timegrid--state))
                      (org-timegrid--cursor-state-day cursor)))
               (start (if range (% absolute-start 1440)
                        (if all-day 0 (org-timegrid--cursor-state-minute cursor))))
               (block (org-timegrid--make-block
                       'new day start (+ start minutes)
                       title nil nil (if all-day 'all-day 'timed))))
          (org-timegrid--backend-create title block nil (cdr entry))
          (org-timegrid--deactivate-region))))))

(defun org-timegrid-open-at-cursor ()
  "Visit the block under the cursor, or create one when the slot is empty."
  (interactive)
  (org-timegrid--with-update nil
    (org-timegrid--reveal-cursor)
    (let ((block (org-timegrid--block-at-cursor)))
      (if (or (org-timegrid-region-active-p) (null block))
          (org-timegrid-create-at-cursor)
        (let ((event (org-timegrid-block-event block))
              (visitor (and org-timegrid--backend
                            (org-timegrid-backend-visit-function
                             org-timegrid--backend))))
          (if (and event (functionp visitor))
              (funcall visitor event)
            (message "No source to visit")))))))

;;; Keyboard copy, cut, and yank

(defconst org-timegrid--clipboard-version 1)
(defvar-local org-timegrid--last-yank-origin nil)
(defvar-local org-timegrid--last-yank-add-occurrence nil)

(defun org-timegrid--logical-selection ()
  "Return the active region or the block at point as backend events."
  (if-let* ((range (org-timegrid--region-range)))
      (list :start (car range) :end (cdr range)
            :events (if (< (car range) (cdr range))
                        (sort (org-timegrid-backend-list
                               org-timegrid--backend (car range) (cdr range))
                              (lambda (left right)
                                (< (org-timegrid-event-start left)
                                   (org-timegrid-event-start right))))))
    (let* ((block (org-timegrid--block-at-cursor))
           (event (and block (org-timegrid-block-event block))))
      (unless event
        (user-error "No calendar region or block at point"))
      (list :start (org-timegrid-event-start event)
            :end (org-timegrid-event-end event) :events (list event)))))

(defun org-timegrid--format-copy-date (minute)
  "Format the date containing absolute Gregorian MINUTE."
  (let* ((date (calendar-gregorian-from-absolute (floor minute 1440)))
         (value (encode-time 0 0 12 (nth 1 date) (nth 0 date) (nth 2 date))))
    (format-time-string org-timegrid-copy-date-format value)))

(defun org-timegrid--format-copy-item (title start end)
  "Format TITLE spanning absolute minutes START through END."
  (let ((end-text
         (cond
          ((= (floor start 1440) (floor end 1440))
           (org-timegrid--format-minute end))
          ((and (= (% end 1440) 0)
                (= (floor end 1440) (1+ (floor start 1440))))
           (if (eq org-timegrid-time-format '24h) "24:00"
             (org-timegrid--format-minute end)))
          (t (format "%s %s" (org-timegrid--format-copy-date end)
                     (org-timegrid--format-minute end))))))
    (let ((values `(("%{title}" . ,title)
                    ("%{start}" . ,(org-timegrid--format-minute start))
                    ("%{end}" . ,end-text))))
      (replace-regexp-in-string
       (regexp-opt (mapcar #'car values))
       (lambda (token) (cdr (assoc token values)))
       org-timegrid-copy-item-template t t))))

(defun org-timegrid--format-copy-day (day items)
  "Format copied ITEMS whose start lies on absolute DAY."
  (concat (org-timegrid--format-copy-date (* day 1440)) "\n"
          (mapconcat
           (lambda (item)
             (org-timegrid--format-copy-item
              (car item) (cadr item) (caddr item)))
           items "\n")))

(defun org-timegrid--selection-free-ranges (selection)
  "Return unoccupied ranges inside SELECTION, split at midnight."
  (let* ((start (plist-get selection :start))
         (end (plist-get selection :end))
         (occupied
          (sort
           (delq nil
                 (mapcar
                  (lambda (event)
                    (let ((from (max start (org-timegrid-event-start event)))
                          (to (min end (org-timegrid-event-end event))))
                      (and (< from to) (cons from to))))
                  (plist-get selection :events)))
           (lambda (left right) (< (car left) (car right)))))
         merged cursor free)
    (dolist (range occupied)
      (if (and merged (<= (car range) (cdar merged)))
          (setcdr (car merged) (max (cdar merged) (cdr range)))
        (push (cons (car range) (cdr range)) merged)))
    (setq cursor start)
    (dolist (range (nreverse merged))
      (when (< cursor (car range)) (push (cons cursor (car range)) free))
      (setq cursor (max cursor (cdr range))))
    (when (< cursor end) (push (cons cursor end) free))
    (let (split)
      (dolist (range (nreverse free))
        (let ((from (car range)) (to (cdr range)))
          (while (< from to)
            (let ((part-end (min to (* (1+ (floor from 1440)) 1440))))
              (push (cons from part-end) split)
              (setq from part-end)))))
      (nreverse split))))

(defun org-timegrid--selection-text (selection)
  "Return readable clipboard text for SELECTION."
  (let* ((events (plist-get selection :events))
         (items
          (sort
           (append
            (mapcar (lambda (event)
                      (list (org-timegrid-event-title event)
                            (org-timegrid-event-start event)
                            (org-timegrid-event-end event)))
                    events)
            (mapcar (lambda (range) (list "Free" (car range) (cdr range)))
                    (org-timegrid--selection-free-ranges selection)))
           (lambda (left right) (< (cadr left) (cadr right)))))
         days)
    (dolist (item items)
      (let* ((day (floor (cadr item) 1440))
             (group (assq day days)))
        (if group
            (setcdr group (append (cdr group) (list item)))
          (setq days (append days (list (list day item)))))))
    (mapconcat (lambda (group)
                 (org-timegrid--format-copy-day (car group) (cdr group)))
               days "\n\n")))

(defun org-timegrid--clipboard-string (selection cut)
  "Return a readable clipboard string for SELECTION, marked as CUT."
  (let* ((events (plist-get selection :events))
         (origin (plist-get selection :start))
         (text (org-timegrid--selection-text selection)))
    (if (null events)
        text
      (propertize
       text 'org-timegrid-payload
       (list :version org-timegrid--clipboard-version :cut cut
             :items
             (mapcar
              (lambda (event)
                (list :title (org-timegrid-event-title event)
                      :offset (- (org-timegrid-event-start event) origin)
                      :duration (- (org-timegrid-event-end event)
                                   (org-timegrid-event-start event))
                      :time-kind (org-timegrid-event-time-kind event)
                      :event event :target (org-timegrid-event-source event)))
              events))))))

(defun org-timegrid--deactivate-region ()
  "Deactivate the calendar region without forgetting its mark."
  (setf (org-timegrid--calendar-state-region-active org-timegrid--state) nil))

(defun org-timegrid--deselect-block ()
  "Clear the block selection, keeping the cursor at the nearest regular stop."
  (setf (org-timegrid--calendar-state-selected-id org-timegrid--state) nil)
  (let ((cursor (org-timegrid--cursor)))
    (when (eq (org-timegrid--cursor-state-surface cursor) 'grid)
      (org-timegrid--set-grid-stop
       (org-timegrid--cursor-state-day cursor)
       (cons (max (* 60 org-timegrid-start-hour)
                  (min (- (* 60 org-timegrid-end-hour) org-timegrid-slot-minutes)
                       (* org-timegrid-slot-minutes
                          (round (org-timegrid--cursor-state-minute cursor)
                                 org-timegrid-slot-minutes))))
             nil)))))

(defun org-timegrid--transaction (function)
  "Run FUNCTION as one backend transaction and refresh once."
  (org-timegrid--with-update nil
    (let ((transaction
           (and (org-timegrid-backend-p org-timegrid--backend)
                (org-timegrid-backend-transaction-function
                 org-timegrid--backend)))
          (org-timegrid--defer-refresh t))
      (unwind-protect
          (if (functionp transaction)
              (funcall transaction function)
            (funcall function))
        (org-timegrid--refresh-data)))))

(defun org-timegrid-copy-selected ()
  "Copy the calendar region or block at point to the normal kill ring."
  (interactive)
  (org-timegrid--with-update nil
    (let* ((selection (org-timegrid--logical-selection))
           (count (length (plist-get selection :events))))
      (kill-new (org-timegrid--clipboard-string selection nil))
      (org-timegrid--deactivate-region)
      (if (= count 0)
          (message "Copied free time")
        (message "Copied %d block%s" count (if (= count 1) "" "s"))))))

(defun org-timegrid-cut-selected ()
  "Copy selected blocks to the kill ring, then remove their timestamps."
  (interactive)
  (org-timegrid--with-update nil
    (let* ((selection (org-timegrid--logical-selection))
           (events (plist-get selection :events))
           (text (org-timegrid--clipboard-string selection t))
           (deleter (org-timegrid-backend-delete-function org-timegrid--backend)))
      (when events
        (unless (functionp deleter) (user-error "This backend cannot cut events"))
        (org-timegrid--transaction
         (lambda ()
           (dolist (event events) (funcall deleter event))
           (org-timegrid--deselect-block))))
      (kill-new text)
      (org-timegrid--deactivate-region)
      (if events
          (message "Cut %d block%s" (length events)
                   (if (= (length events) 1) "" "s"))
        (message "Copied free time")))))

(defun org-timegrid--yank-payload (string origin)
  "Validate calendar STRING for pasting at ORIGIN and return its payload."
  (let ((payload (and (> (length string) 0)
                      (get-text-property 0 'org-timegrid-payload string))))
    (unless payload (user-error "The current kill-ring entry is text only"))
    (unless (and (equal (plist-get payload :version) org-timegrid--clipboard-version)
                 (consp (plist-get payload :items)))
      (user-error "Unsupported calendar clipboard data"))
    (dolist (item (plist-get payload :items))
      (unless (and (stringp (plist-get item :title))
                   (integerp (plist-get item :offset))
                   (integerp (plist-get item :duration))
                   (> (plist-get item :duration) 0)
                   (memq (plist-get item :time-kind) '(timed all-day)))
        (user-error "Invalid calendar clipboard item"))
      (when (and (eq (plist-get item :time-kind) 'all-day)
                 (or (/= (% (+ origin (plist-get item :offset)) 1440) 0)
                     (/= (% (plist-get item :duration) 1440) 0)))
        (user-error "Paste all-day blocks at midnight in the all-day rail")))
    payload))

(defun org-timegrid-yank (&optional add-occurrence)
  "Yank calendar data from the normal kill ring at point.
With ADD-OCCURRENCE, add timestamps to their original entries."
  (interactive "P")
  (org-timegrid--with-update nil
    (let* ((origin (org-timegrid--cursor-calendar-minute))
           (payload (org-timegrid--yank-payload (current-kill 0 t) origin)))
      (org-timegrid--reveal-cursor)
      (let ((week (org-timegrid--calendar-state-week-start org-timegrid--state))
            (items (plist-get payload :items)))
        (org-timegrid--transaction
         (lambda ()
           (dolist (item items)
             (let* ((start (+ origin (plist-get item :offset)))
                    (duration (plist-get item :duration))
                    (day (- (floor start 1440) week))
                    (minute (% start 1440))
                    (block (org-timegrid--make-block
                            'yank day minute (+ minute duration)
                            (plist-get item :title) nil nil
                            (plist-get item :time-kind))))
               (org-timegrid--backend-create
                (plist-get item :title) block (plist-get item :event)
                (and (or add-occurrence (plist-get payload :cut))
                     (plist-get item :target)))))))
        (org-timegrid--deactivate-region)
        (setq-local org-timegrid--last-yank-origin origin
                    org-timegrid--last-yank-add-occurrence add-occurrence)
        (message "Pasted %d block%s" (length items)
                 (if (= (length items) 1) "" "s"))))))

(defun org-timegrid-yank-pop (&optional count)
  "Replace the preceding calendar yank with another `kill-ring' entry.
COUNT selects how many entries to advance."
  (interactive "p")
  (org-timegrid--with-update nil
    (unless (and org-timegrid--last-yank-origin
                 (memq last-command '(org-timegrid-yank org-timegrid-yank-pop)))
      (user-error "Previous command was not a calendar yank"))
    (let* ((origin org-timegrid--last-yank-origin)
           (add org-timegrid--last-yank-add-occurrence)
           (day (floor origin 1440)))
      (org-timegrid--yank-payload (current-kill (or count 1) t) origin)
      (org-timegrid--backend-undo nil)
      (current-kill (or count 1))
      (org-timegrid--reload-state (org-timegrid--range-start day))
      (org-timegrid--set-cursor
       (- day (org-timegrid--calendar-state-week-start org-timegrid--state))
       (% origin 1440))
      (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
      (org-timegrid-yank add))))

;;; Keyboard re-timing

(defun org-timegrid--read-timestamp (absolute-start duration)
  "Read a start minute and duration, prefilled from ABSOLUTE-START.
A backend may supply its own reader, which is how Org's date prompt gets
used without the renderer knowing about Org.  DURATION is passed through
for that reader to prefill.  Returns a cons of start and duration, where
a nil duration means the caller should ask."
  (funcall (or (org-timegrid-backend-read-timestamp-function
                org-timegrid--backend)
               #'org-timegrid-read-timestamp-default)
           absolute-start duration))

(defun org-timegrid-read-timestamp-default (absolute-start duration)
  "Read a start time textually, prefilled from ABSOLUTE-START.
DURATION is unused; this reader leaves the duration prompt to the caller."
  (ignore duration)
  (let* ((day (floor absolute-start 1440))
         (minute (% absolute-start 1440))
         (date (calendar-gregorian-from-absolute day))
         (prefill (format "%04d-%02d-%02d %02d:%02d"
                          (nth 2 date) (nth 0 date) (nth 1 date)
                          (/ minute 60) (% minute 60)))
         (answer (string-trim (read-string "Start (YYYY-MM-DD HH:MM): " prefill))))
    (unless (string-match
             "\\`\\([0-9]\\{4\\}\\)-\\([0-9]+\\)-\\([0-9]+\\)[ \t]+\\([0-9]+\\):\\([0-9]+\\)\\'"
             answer)
      (user-error "Enter a date and time as YYYY-MM-DD HH:MM"))
    (let* ((parts (mapcar (lambda (index) (string-to-number (match-string index answer)))
                          '(1 2 3 4 5)))
           (date (list (nth 1 parts) (nth 2 parts) (nth 0 parts)))
           (hour (nth 3 parts)) (minute (nth 4 parts)))
      (unless (and (> (nth 0 parts) 0) (calendar-date-is-valid-p date)
                   (<= 0 hour 23) (<= 0 minute 59))
        (user-error "Invalid calendar date or time"))
      (cons (+ (* 1440 (calendar-absolute-from-gregorian date)) (* 60 hour) minute) nil))))

(defun org-timegrid--read-minutes (default)
  "Read a duration in minutes, offering DEFAULT."
  (let* ((answer (read-string
                  (format "Duration in minutes (default %d): " default)
                  nil nil (number-to-string default)))
         (minutes (string-to-number answer)))
    (if (>= minutes org-timegrid-slot-minutes)
        minutes
      org-timegrid-slot-minutes)))

(defun org-timegrid-retime-selected ()
  "Re-time the selected block by reading a new start and duration.
The reader is prefilled with the block's current value.  When it reports
a duration, as a typed time range does, that is used directly; otherwise
the duration is asked for separately, prefilled with the current one."
  (interactive)
  (let* ((block (org-timegrid--selected-block))
         (week-start (org-timegrid--calendar-state-week-start org-timegrid--state))
         (absolute-start (+ (* (+ week-start (org-timegrid-block-day block)) 1440)
                            (org-timegrid-block-start block)))
         (minutes (- (org-timegrid-block-end block) (org-timegrid-block-start block)))
         (answer (org-timegrid--read-timestamp absolute-start minutes))
         (start (car answer))
         (duration (max org-timegrid-slot-minutes
                        (or (cdr answer)
                            (org-timegrid--read-minutes minutes))))
         (updater (org-timegrid-backend-update-function
                   org-timegrid--backend)))
    (unless (and (org-timegrid-block-event block) (functionp updater))
      (user-error "This backend cannot re-time calendar entries"))
    (org-timegrid--call-update
     updater (org-timegrid-block-event block) start (+ start duration) nil
     (if (and (org-timegrid-block-all-day-p block)
              (zerop (% start 1440)) (zerop (% duration 1440)))
         'all-day 'timed))
    (org-timegrid--refresh-data)))

;;; Pointer context menu

(defun org-timegrid--context-menu ()
  "Return the context menu appropriate for the calendar cursor."
  (let ((block (org-timegrid--block-at-cursor)))
    (easy-menu-create-menu
     "Org Time Grid"
     (if block
         (list
          ["Open" org-timegrid-open-at-cursor t]
          ["Rename…" org-timegrid-edit-selected-title t]
          ["Change time…" org-timegrid-retime-selected t]
          "--"
          ["Copy" org-timegrid-copy-selected t]
          ["Cut" org-timegrid-cut-selected t]
          ["Delete" org-timegrid-remove-selected t])
       (list
        ["Create block…" org-timegrid-create-at-cursor t]
        ["Paste" org-timegrid-yank
         (and kill-ring
              (get-text-property 0 'org-timegrid-payload (car kill-ring)))])))))

(defun org-timegrid-context-menu (event)
  "Select the calendar location at EVENT and show its action menu."
  (interactive "@e")
  (funcall (if (eq (org-timegrid--mouse-surface (event-start event)) 'rail)
               #'org-timegrid-header-click #'org-timegrid-click)
           (list 'mouse-1 (event-start event)))
  (popup-menu (org-timegrid--context-menu) event))

;;; Dates

(defun org-timegrid-goto-date ()
  "Show the week containing a date read from the user."
  (interactive)
  (org-timegrid--with-update 'reset
    (let* ((cursor-absolute (org-timegrid--cursor-calendar-minute))
           (answer (org-timegrid--read-timestamp
                    cursor-absolute org-timegrid-slot-minutes))
           (absolute (floor (car answer) 1440)))
      (org-timegrid--reload-state (org-timegrid--range-start absolute))
      (org-timegrid--set-cursor
       (- absolute (org-timegrid--calendar-state-week-start org-timegrid--state))
       (% (car answer) 1440)))))

(defun org-timegrid-goto-today (&optional force-reload)
  "Show the week containing today.
A visible cursor moves to the current slot; a hidden one stays hidden,
since jumping dates should not conjure a cursor nobody asked for.
Position the current time at the top of the viewport.
With FORCE-RELOAD, reload the backend even if today is already displayed."
  (interactive)
  (org-timegrid--with-update nil
    (let* ((today (calendar-absolute-from-gregorian (org-timegrid--today)))
           (range (org-timegrid--range-start today))
           (visible (and (org-timegrid--cursor) t))
           (reload (or force-reload org-timegrid--stale
                       (/= range (org-timegrid--calendar-state-week-start
                                  org-timegrid--state)))))
      (when reload
        (org-timegrid--reload-state range)
        (setq-local org-timegrid--stale nil))
      (let ((cursor (and visible (org-timegrid--default-cursor range))))
        (unless (equal cursor (org-timegrid--cursor))
          (setf (org-timegrid--calendar-state-cursor org-timegrid--state)
                cursor)))
      (if reload
          (org-timegrid--with-update (cons (org-timegrid--now-minute) 'top))
        (when-let* ((window (get-buffer-window (current-buffer) t)))
          (org-timegrid--align-now window))))))

(defun org-timegrid-remove-or-page-up (&optional count)
  "Remove the selected block, or page the cursor up when none is selected.
COUNT controls the number of pages to move.
Backspace sends DEL, so this key has to serve both the delete people
expect on a selected block and the paging DEL means in a view buffer."
  (interactive "p")
  (if (or (org-timegrid-region-active-p) (org-timegrid--selected-id))
      (org-timegrid-remove-selected)
    (org-timegrid-cursor-page-up count)))

(defun org-timegrid-dismiss ()
  "Hide the cursor and clear the selection and any preview.
The cursor's position is remembered, so a later movement key resumes from
where it was left.  Only an explicit refresh forgets it."
  (interactive)
  (org-timegrid--with-update nil
    (if (org-timegrid-region-active-p)
        (setf (org-timegrid--calendar-state-region-active org-timegrid--state) nil)
      (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil
            (org-timegrid--calendar-state-cursor-visible org-timegrid--state) nil))
    (message nil)))

(defun org-timegrid-wheel-up (event)
  "Scroll the SVG upward in response to EVENT."
  (interactive "e")
  (when-let* ((window (org-timegrid--event-window event)))
    (org-timegrid-scroll -90 window)))

(defun org-timegrid-wheel-down (event)
  "Scroll the SVG downward in response to EVENT."
  (interactive "e")
  (when-let* ((window (org-timegrid--event-window event)))
    (org-timegrid-scroll 90 window)))

(defun org-timegrid-precision-scroll (event)
  "Scroll the tiled SVG using the pixel delta carried by EVENT.
This bypasses generic precision scrollers whose text-position assumptions do
not hold for a buffer made of tall image glyphs."
  (interactive "e")
  (when-let* ((window (org-timegrid--event-window event))
              (delta (cdr-safe (nth 4 event)))
              ((numberp delta)))
    ;; Precision-wheel deltas describe content motion, while this renderer's
    ;; absolute scroll coordinate increases down the calendar.
    (org-timegrid-scroll (- delta) window)))

(defvar org-timegrid--precision-scroll-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "<remap> <pixel-scroll-precision>"
                #'org-timegrid-precision-scroll)
    map)
  "Buffer-local override map for generic precision scrolling modes.")

(defun org-timegrid--install-precision-scroll-override ()
  "Prefer the calendar's image-aware scroller in the current buffer."
  (setq-local minor-mode-overriding-map-alist
              (assq-delete-all 'pixel-scroll-precision-mode
                               minor-mode-overriding-map-alist))
  (push `(pixel-scroll-precision-mode . ,org-timegrid--precision-scroll-map)
        minor-mode-overriding-map-alist))

(defun org-timegrid-shift-week (days)
  "Move the SVG week by DAYS, preserving vertical scroll position."
  (org-timegrid--with-update 'preserve
    (org-timegrid--reload-state
     (+ (org-timegrid--calendar-state-week-start org-timegrid--state) days))))

(defun org-timegrid-previous-week ()
  "Show the previous week."
  (interactive)
  (org-timegrid-shift-week (- org-timegrid-days)))

(defun org-timegrid-next-week ()
  "Show the next week."
  (interactive)
  (org-timegrid-shift-week org-timegrid-days))

(defun org-timegrid-backward-day ()
  "Move the seven-day calendar backward by one day."
  (interactive)
  (org-timegrid-shift-week -1))

(defun org-timegrid-forward-day ()
  "Move the seven-day calendar forward by one day."
  (interactive)
  (org-timegrid-shift-week 1))

(defun org-timegrid-refresh ()
  "Reload the displayed range from the backend, preserving the view."
  (interactive)
  (let ((org-timegrid--force-data-refresh t))
    (org-timegrid--refresh-data)))

;; Org commands are loaded only when one of their bindings is used.
(autoload 'org-timegrid-org-set-tags "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-todo "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-open-at-point "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-priority "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-clock-in "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-clock-out "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-add-note "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-set-effort "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-refile "org-timegrid-org" nil t)
(autoload 'org-timegrid-org-archive "org-timegrid-org" nil t)

(defvar org-timegrid-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map [down-mouse-1]
                #'org-timegrid-press)
    (define-key map [double-down-mouse-1]
                #'org-timegrid-ignore-double-press)
    (define-key map [s-down-mouse-1]
                #'org-timegrid-press)
    (define-key map [S-down-mouse-1]
                #'org-timegrid-press)
    (define-key map [mouse-1] #'org-timegrid-click)
    (define-key map [double-mouse-1] #'org-timegrid-visit)
    (define-key map [down-mouse-3] #'org-timegrid-context-menu)
    (define-key map [mouse-movement] #'org-timegrid-pointer-feedback)
    (define-key map [header-line mouse-1] #'org-timegrid-header-click)
    (define-key map [header-line down-mouse-1] #'org-timegrid-header-press)
    (define-key map [header-line double-down-mouse-1]
                #'org-timegrid-ignore-double-press)
    (define-key map [header-line s-down-mouse-1] #'org-timegrid-header-press)
    (define-key map [header-line S-down-mouse-1] #'org-timegrid-header-press)
    (define-key map [header-line double-mouse-1] #'org-timegrid-header-visit)
    (dolist (area '(calendar-block calendar-resize))
      (define-key map (vector area 'down-mouse-1)
                  #'org-timegrid-press)
      (define-key map (vector area 'double-down-mouse-1)
                  #'org-timegrid-ignore-double-press)
      (define-key map (vector area 's-down-mouse-1)
                  #'org-timegrid-press)
      (define-key map (vector area 'S-down-mouse-1)
                  #'org-timegrid-press)
      (define-key map (vector area 'mouse-1)
                  #'org-timegrid-click)
      (define-key map (vector area 'double-mouse-1)
                  #'org-timegrid-visit)
      (define-key map (vector area 'down-mouse-3)
                  #'org-timegrid-context-menu)
      (define-key map (vector area 'mouse-movement)
                  #'org-timegrid-pointer-feedback)
      (dolist (wheel '(wheel-up double-wheel-up triple-wheel-up))
        (define-key map (vector area wheel)
                    #'org-timegrid-wheel-up))
      (dolist (wheel '(wheel-down double-wheel-down triple-wheel-down))
        (define-key map (vector area wheel)
                    #'org-timegrid-wheel-down)))
    (dolist (wheel '(wheel-up double-wheel-up triple-wheel-up))
      (define-key map (vector wheel)
                  #'org-timegrid-wheel-up))
    (dolist (wheel '(wheel-down double-wheel-down triple-wheel-down))
      (define-key map (vector wheel)
                  #'org-timegrid-wheel-down))
    (keymap-set map "b" #'org-timegrid-backward-day)
    (keymap-set map "f" #'org-timegrid-forward-day)
    (keymap-set map "M-b" #'org-timegrid-previous-week)
    (keymap-set map "M-f" #'org-timegrid-next-week)
    (keymap-set map "g" #'org-timegrid-refresh)
    (keymap-set map "C-s" #'org-timegrid-isearch-forward)
    (keymap-set map "C-r" #'org-timegrid-isearch-backward)
    ;; In vanilla Emacs the fully modified `C-x C-+' invokes text scaling,
    ;; while `C-x +' balances windows.  The latter is a convenient calendar-
    ;; local alias and matches how this command is commonly described.
    (keymap-set map "C-x +" #'text-scale-adjust)
    ;; Remapping catches whatever key the user has put undo on, and the
    ;; explicit bindings are the floor for a command we cannot know about.
    (keymap-set map "<remap> <undo>" #'org-timegrid-undo)
    (keymap-set map "<remap> <undo-only>" #'org-timegrid-undo)
    (keymap-set map "<remap> <undo-redo>" #'org-timegrid-redo)
    (keymap-set map "<remap> <undo-fu-only-undo>" #'org-timegrid-undo)
    (keymap-set map "<remap> <undo-fu-only-redo>" #'org-timegrid-redo)
    (keymap-set map "<remap> <undo-tree-undo>" #'org-timegrid-undo)
    (keymap-set map "<remap> <undo-tree-redo>" #'org-timegrid-redo)
    (keymap-set map "C-/" #'org-timegrid-undo)
    (keymap-set map "C-_" #'org-timegrid-undo)
    (keymap-set map "C-x u" #'org-timegrid-undo)
    (keymap-set map "M-_" #'org-timegrid-redo)
    (keymap-set map "<remap> <set-mark-command>"
                #'org-timegrid-set-mark-command)
    (keymap-set map "<remap> <exchange-point-and-mark>"
                #'org-timegrid-exchange-point-and-mark)
    (keymap-set map "<remap> <kill-ring-save>" #'org-timegrid-copy-selected)
    (keymap-set map "<remap> <kill-region>" #'org-timegrid-cut-selected)
    (keymap-set map "<remap> <yank>" #'org-timegrid-yank)
    (keymap-set map "<remap> <yank-pop>" #'org-timegrid-yank-pop)
    (keymap-set map "C-SPC" #'org-timegrid-set-mark-command)
    (keymap-set map "C-x C-x" #'org-timegrid-exchange-point-and-mark)
    (keymap-set map "d" #'org-timegrid-remove-selected)
    (keymap-set map "e"
                #'org-timegrid-edit-selected-title)
    (keymap-set map "<delete>"
                #'org-timegrid-remove-selected)
    ;; Cursor motion, which scrolls the view to follow it.
    (keymap-set map "C-n" #'org-timegrid-cursor-forward)
    (keymap-set map "C-p" #'org-timegrid-cursor-backward)
    (keymap-set map "<down>" #'org-timegrid-cursor-forward)
    (keymap-set map "<up>" #'org-timegrid-cursor-backward)
    (keymap-set map "C-f" #'org-timegrid-cursor-forward-day)
    (keymap-set map "C-b" #'org-timegrid-cursor-backward-day)
    (keymap-set map "<right>" #'org-timegrid-cursor-forward-day)
    (keymap-set map "<left>" #'org-timegrid-cursor-backward-day)
    (keymap-set map "C-v" #'org-timegrid-cursor-page-down)
    (keymap-set map "M-v" #'org-timegrid-cursor-page-up)
    (keymap-set map "SPC" #'org-timegrid-cursor-page-down)
    (keymap-set map "DEL" #'org-timegrid-remove-or-page-up)
    (keymap-set map "<backspace>" #'org-timegrid-remove-or-page-up)
    (keymap-set map "C-l" #'org-timegrid-recenter)
    (keymap-set map "C-a" #'org-timegrid-cursor-day-start)
    (keymap-set map "C-e" #'org-timegrid-cursor-day-end)
    ;; Block selection.
    (keymap-set map "n" #'org-timegrid-next-block)
    (keymap-set map "p" #'org-timegrid-previous-block)
    (keymap-set map "RET" #'org-timegrid-open-at-cursor)
    (keymap-set map "C-g" #'org-timegrid-dismiss)
    ;; Keyboard editing.
    (keymap-set map "M-<down>" #'org-timegrid-move-later)
    (keymap-set map "M-<up>" #'org-timegrid-move-earlier)
    (keymap-set map "M-<right>" #'org-timegrid-move-next-day)
    (keymap-set map "M-<left>" #'org-timegrid-move-previous-day)
    (keymap-set map "S-<down>" #'org-timegrid-grow-end)
    (keymap-set map "S-<up>" #'org-timegrid-shrink-end)
    (keymap-set map "C-S-<up>" #'org-timegrid-grow-start)
    (keymap-set map "C-S-<down>" #'org-timegrid-shrink-start)
    (keymap-set map "S-<right>" #'org-timegrid-grow-all-day-end)
    (keymap-set map "S-<left>" #'org-timegrid-shrink-all-day-end)
    (keymap-set map "C-S-<left>" #'org-timegrid-grow-all-day-start)
    (keymap-set map "C-S-<right>" #'org-timegrid-shrink-all-day-start)
    (keymap-set map "t" #'org-timegrid-retime-selected)
    (keymap-set map "M-w" #'org-timegrid-copy-selected)
    (keymap-set map "C-w" #'org-timegrid-cut-selected)
    (keymap-set map "C-y" #'org-timegrid-yank)
    (keymap-set map "M-y" #'org-timegrid-yank-pop)
    ;; Dates and files.
    (keymap-set map "j" #'org-timegrid-goto-date)
    (keymap-set map "." #'org-timegrid-goto-today)
    (keymap-set map "q" #'quit-window)
    (keymap-set map ":" #'org-timegrid-org-set-tags)
    (keymap-set map "C-c C-q" #'org-timegrid-org-set-tags)
    (keymap-set map "C-c C-t" #'org-timegrid-org-todo)
    (keymap-set map "C-c C-o" #'org-timegrid-org-open-at-point)
    (keymap-set map "," #'org-timegrid-org-priority)
    (keymap-set map "C-c ," #'org-timegrid-org-priority)
    (keymap-set map "i" #'org-timegrid-org-clock-in)
    (keymap-set map "O" #'org-timegrid-org-clock-out)
    (keymap-set map "z" #'org-timegrid-org-add-note)
    (keymap-set map "C-c C-z" #'org-timegrid-org-add-note)
    (keymap-set map "C-c C-x e" #'org-timegrid-org-set-effort)
    (keymap-set map "C-c C-w" #'org-timegrid-org-refile)
    (keymap-set map "$" #'org-timegrid-org-archive)
    map))

(define-derived-mode org-timegrid-mode special-mode
  "Org Time Grid"
  "Major mode for an SVG week calendar.

The calendar owns one explicit cursor and one selected event.  The cursor
can occupy either a timed slot or an all-day rail cell; both mouse and
keyboard changes pass through the same damage-based renderer.

\\{org-timegrid-mode-map}"
  ;; Redraws replace images; calendar undo belongs to the backend.
  (buffer-disable-undo)
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  ;; Image rows otherwise gain one baseline pixel and visible hour seams.
  (setq-local line-spacing -1)
  (setq-local track-mouse t)
  (setq-local mouse-fine-grained-tracking t)
  (setq-local auto-window-vscroll t)
  (org-timegrid--install-text-scale-hook)
  (org-timegrid--install-global-hooks)
  (org-timegrid--install-precision-scroll-override)
  (add-hook 'window-size-change-functions
            #'org-timegrid--window-resized nil t)
  (add-hook 'pre-command-hook
            #'org-timegrid--commit-before-unrelated-command nil t)
  (add-hook 'kill-buffer-hook #'org-timegrid--clear-view-cache nil t)
  (add-hook 'kill-buffer-hook
            #'org-timegrid--cancel-timers nil t))

(defun org-timegrid--now-minute ()
  "Return the current minute of the day."
  (let ((now (decode-time)))
    (+ (* 60 (decoded-time-hour now)) (decoded-time-minute now))))

(defun org-timegrid--align-now (window)
  "Position the current time at the top of WINDOW."
  (org-timegrid--align-minute window (org-timegrid--now-minute)
                              'top))

;;;###autoload
(defun org-timegrid-open (backend &optional absolute-date)
  "Open BACKEND on the week containing ABSOLUTE-DATE.
Show the current time at the top on first display; later visits retain the view."
  (unless (org-timegrid-backend-p backend)
    (user-error "A calendar backend is required"))
  (let* ((existing (get-buffer "*Org Time Grid*"))
         (buffer (or existing (get-buffer-create "*Org Time Grid*")))
         (requested (and absolute-date (org-timegrid--range-start absolute-date)))
         candidate reload)
    (condition-case error-data
        (with-current-buffer buffer
          (unless existing
            (org-timegrid-mode)
            (org-timegrid--start-timers))
          (let ((week (and org-timegrid--state
                           (org-timegrid--calendar-state-week-start org-timegrid--state))))
            (setq reload (or (not existing) org-timegrid--stale
                             (not (eq backend org-timegrid--backend))
                             (and requested (not (equal requested week)))))
            (when reload
              (let ((org-timegrid--backend backend))
                (setq candidate (org-timegrid--load-state
                                 (or requested week (org-timegrid--range-start absolute-date))))))))
      ((error quit)
       (unless existing (kill-buffer buffer))
       (signal (car error-data) (cdr error-data))))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (org-timegrid--with-update
          (cond ((not existing) (cons (org-timegrid--now-minute) 'top))
                ((or reload (/= (org-timegrid--window-width) (or org-timegrid--last-width -1))) 'preserve))
        (when reload
          (setq org-timegrid--backend backend org-timegrid--state candidate
                org-timegrid--stale nil)))
      (when-let* ((window (get-buffer-window buffer t)))
        (org-timegrid--schedule-scroll-restore window)))
    buffer))

(defun org-timegrid--install-global-hooks ()
  "Install hooks needed while a calendar is active."
  (add-hook 'enable-theme-functions #'org-timegrid--theme-changed)
  (add-hook 'disable-theme-functions #'org-timegrid--theme-changed)
  (add-hook 'window-buffer-change-functions
            #'org-timegrid--restore-frame-calendars))

(provide 'org-timegrid)
(require 'org-timegrid-isearch)
(when (eq system-type 'android)
  (require 'org-timegrid-android))
;;; org-timegrid.el ends here
