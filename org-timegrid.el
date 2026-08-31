;;; org-timegrid.el --- SVG week calendar with mouse and keyboard editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad

;; Author: Umar Ahmad
;; Maintainer: Umar Ahmad
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
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

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'face-remap)
(require 'svg)
(require 'subr-x)
(require 'org-timegrid-model)

(defgroup org-timegrid nil
  "An SVG week calendar for Emacs, edited by mouse and keyboard."
  :group 'calendar
  :prefix "org-timegrid-")

(defcustom org-timegrid-start-hour 0
  "First hour drawn in the week canvas."
  :type 'integer)

(defcustom org-timegrid-end-hour 24
  "Hour at the bottom edge of the week canvas."
  :type 'integer)

(defcustom org-timegrid-pixels-per-minute 0.9
  "Vertical SVG scale in pixels per minute."
  :type 'number)

(defcustom org-timegrid-block-gap 1
  "Vertical gap in pixels between consecutive blocks."
  :type 'integer)

(defcustom org-timegrid-corner-radius 0
  "Radius in pixels for event blocks and their accent bars.
Set this to zero for square event corners."
  :type 'number)

(defcustom org-timegrid-edge-pixels 8
  "Height of the top and bottom resize zones in pixels."
  :type 'integer)

(defcustom org-timegrid-edge-slop 3
  "Extra pixels outside a block that count as a resize edge."
  :type 'integer)

(defcustom org-timegrid-midnight-grip-pixels 6
  "Height of a resize grip shown across an exact midnight boundary."
  :type 'integer)

(defcustom org-timegrid-nesting-indent 8
  "Horizontal indent in pixels for each contained calendar block."
  :type 'integer)

(defcustom org-timegrid-title-clearance 18
  "Required vertical pixels before one block may nest inside another.
This keeps at least one line of the containing block's title visible."
  :type 'integer)

(defcustom org-timegrid-colors
  '((blue     . "#4da3ff")
    (cyan     . "#32ade6")
    (teal     . "#30b0c7")
    (indigo   . "#5856d6")
    (purple   . "#af52de")
    (pink     . "#ff2d55")
    (red      . "#ff3b30")
    (orange   . "#ff9500")
    (yellow   . "#ffcc00")
    (lime     . "#a2c73a")
    (green    . "#34c759")
    (brown    . "#a2845e")
    (graphite . "#8e8e93"))
  "Named colors a backend may use for an event.
The names and values follow the macOS system palette, so a calendar
coloured to match one there needs no translation.  Blocks are drawn as a
translucent wash of the colour with a saturated bar down the left edge,
which is why the values here are saturated rather than pastel.

An event's colour need not be a name: any string Emacs understands, such
as \"#b4d74a\" or \"DarkSeaGreen\", is used as given.  Names exist so a
backend can speak in terms a user recognises."
  :type '(alist :key-type symbol :value-type color))

(defcustom org-timegrid-default-color 'blue
  "Colour for an event whose backend gives it none.
A name in `org-timegrid-colors', or any colour string."
  :type '(choice symbol color))

(defcustom org-timegrid-cursor-opacity 0.22
  "Fill opacity of the keyboard cursor.
The cursor is drawn over the blocks, so its fill stays translucent and
lets a block underneath remain readable."
  :type 'number)

(defcustom org-timegrid-default-duration-minutes 30
  "Duration assumed wherever no end time is given.
Keyboard creation offers it, and a backend event that has a start but no
end is shown this long."
  :type 'integer)

(defcustom org-timegrid-all-day-max-lanes 5
  "Maximum number of all-day event lanes shown in the sticky date rail.
Overflow is summarized per day.  The prototype reserves another row for
future keyboard creation and navigation."
  :type 'integer)

(defcustom org-timegrid-all-day-lane-height 22
  "Height in pixels of one event row in the sticky date rail."
  :type 'integer)

(defcustom org-timegrid-cursor-step-minutes 15
  "Minutes the keyboard cursor moves per ordinary step.
The default matches `org-timegrid-slot-minutes'."
  :type 'integer)

(defcustom org-timegrid-compact-font-size 11
  "Point size of text in a compact one-day strip.
Everything else in the strip is derived from it: the line height, how many
characters fit across a block, and therefore how many lines of title a
block of a given length can hold."
  :type 'integer)

(defcustom org-timegrid-compact-shadow-pixels 10
  "Height of the shadow at the edges of a compact viewport.
An edge is shaded only when the day holds something past it, so a shadow
means \"more this way\" rather than merely marking where the window stops."
  :type 'integer)

(defcustom org-timegrid-compact-pixels-per-minute 0.95
  "Vertical scale of a compact one-day strip, in pixels per minute.
This trades detail for reach: a lower value fits more hours into the same
height, at the cost of how much title a short block can show.  The
default puts six hours in about eighteen text lines and still leaves a
half-hour block room for two lines of title."
  :type 'number)

(defcustom org-timegrid-compact-label-width 40
  "Width in pixels of the time-label gutter in a compact one-day strip."
  :type 'integer)

(defcustom org-timegrid-data-refresh-seconds 300
  "Seconds between visible backend data refreshes."
  :type 'number)

(defcustom org-timegrid-keyboard-commit-delay 0.65
  "Idle seconds before a keyboard block movement is written to its backend."
  :type 'number)

(defcustom org-timegrid-buffer-name "*Org Time Grid*"
  "Name of the calendar buffer."
  :type 'string)

(defconst org-timegrid--label-width 48)
(defconst org-timegrid--lane-gap 3)
(defconst org-timegrid--grid-top-inset 6
  "Pixels between the sticky date rail and the midnight grid line.")
(defconst org-timegrid--header-title-height 44)
(defconst org-timegrid--header-date-height 30)
(defconst org-timegrid--rail-top
  (+ org-timegrid--header-title-height org-timegrid--header-date-height))
(defvar-local org-timegrid--geometry nil)
(defvar-local org-timegrid--header-geometry nil)
(defvar-local org-timegrid--rendered-ui nil)
(defvar org-timegrid--header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line down-mouse-1] #'org-timegrid-header-press)
    (define-key map [header-line mouse-1] #'org-timegrid-header-click)
    (define-key map [header-line double-mouse-1] #'org-timegrid-header-visit)
    map)
  "Mouse map installed directly on the sticky calendar header image.")
;; Refresh an existing map when this source is evaluated in a live Emacs.
;; Header-line events arrive prefixed through the mode map but unprefixed
;; through the image string's `keymap' property, so support both forms.
(define-key org-timegrid--header-map [down-mouse-1]
            #'org-timegrid-header-press)
(define-key org-timegrid--header-map [mouse-1]
            #'org-timegrid-header-click)
(define-key org-timegrid--header-map [double-mouse-1]
            #'org-timegrid-header-visit)
(define-key org-timegrid--header-map [header-line down-mouse-1]
            #'org-timegrid-header-press)
(define-key org-timegrid--header-map [header-line mouse-1]
            #'org-timegrid-header-click)
(define-key org-timegrid--header-map [header-line double-mouse-1]
            #'org-timegrid-header-visit)
(dolist (area '(calendar-rail-block calendar-rail-resize))
  (define-key org-timegrid--header-map (vector area 'down-mouse-1)
              #'org-timegrid-header-press)
  (define-key org-timegrid--header-map (vector area 'mouse-1)
              #'org-timegrid-header-click)
  (define-key org-timegrid--header-map (vector area 'double-mouse-1)
              #'org-timegrid-header-visit))
(defvar-local org-timegrid--image-height nil)
(defvar-local org-timegrid--last-width nil)
(defvar-local org-timegrid--pointer-overlay nil)
(defvar-local org-timegrid--resize-timer nil)
(defvar-local org-timegrid--clock-timer nil)
(defvar-local org-timegrid--data-timer nil)
(defvar-local org-timegrid--scroll-restore-timer nil)
(defvar-local org-timegrid--keyboard-edit-timer nil)
(defvar-local org-timegrid--keyboard-edit nil)
(defvar-local org-timegrid--stale nil)
(defvar-local org-timegrid--saved-vscroll 0
  "Pixel scroll position restored when this calendar is shown again.")
(defvar-local org-timegrid--tile-height nil)
(defvar-local org-timegrid--tile-count nil)
(defvar-local org-timegrid--tile-width nil)
(defvar-local org-timegrid--tile-markers nil)
(defvar-local org-timegrid--static-inner nil)
(defvar-local org-timegrid--static-images nil)
(defvar-local org-timegrid--dynamic-tiles nil)
(defvar-local org-timegrid--clock-fragment nil)
(defvar-local org-timegrid--clock-tiles nil)
(defvar-local org-timegrid--base-excluded-id nil)
(defvar-local org-timegrid--fringe-remap-cookie nil)
(defvar org-timegrid--static-render nil)
(defvar org-timegrid--render-excluded-id nil)
(defvar org-timegrid--theme-timer nil)
(defvar-local org-timegrid--backend nil)
(defvar-local org-timegrid--state nil)

(cl-defstruct (org-timegrid--cursor-state
               (:constructor org-timegrid--cursor-state-create))
  "A position on either the timed grid or the all-day rail."
  surface day minute lane)

(cl-defstruct (org-timegrid--operation
               (:constructor org-timegrid--operation-create))
  "A proposed calendar mutation and its preview BLOCK."
  kind block replace-id error)

(cl-defstruct (org-timegrid--calendar-state
               (:constructor org-timegrid--calendar-state-create))
  "Backend data and interactive state for one displayed week."
  week-start events blocks preview cursor selected-id cursor-visible)

(defun org-timegrid--make-block
    (id day start end title &optional color done time-kind)
  "Construct a renderer block from ID, DAY, START, END, TITLE and COLOR."
  (org-timegrid-block-create
   :id id :day day :start start :end end :title title
   :time-kind (or time-kind 'timed) :color color :done done))

(defun org-timegrid--timed-blocks ()
  "Return the current state's timed blocks."
  (seq-remove #'org-timegrid-block-all-day-p
              (org-timegrid--calendar-state-blocks org-timegrid--state)))

(defun org-timegrid--all-day-blocks ()
  "Return the current state's all-day blocks."
  (seq-filter #'org-timegrid-block-all-day-p
              (org-timegrid--calendar-state-blocks org-timegrid--state)))

(defun org-timegrid--load-state (week-start)
  "Load renderer state for WEEK-START from the current backend."
  (let* ((events (org-timegrid-backend-list
                  org-timegrid--backend
                  (* week-start 1440) (* (+ week-start 7) 1440)))
         (blocks (org-timegrid-events-to-blocks events week-start)))
    ;; The cursor has a remembered position and a separate visibility, so
    ;; hiding it with C-g keeps the place, and block selection can record a
    ;; position without drawing anything.
    (org-timegrid--calendar-state-create
     :week-start week-start :events events :blocks blocks)))

(defun org-timegrid--default-cursor (week-start)
  "Return the initial keyboard cursor for the week at WEEK-START.
It sits on the current fifteen-minute slot when today is visible, and on
the first visible day at the configured start hour otherwise."
  (let* ((today (calendar-absolute-from-gregorian (calendar-current-date)))
         (offset (- today week-start)))
    (if (<= 0 offset 6)
        (let ((now (decode-time)))
          (org-timegrid--cursor-state-create
           :surface 'grid :day offset
           :minute (org-timegrid--snap-minute
                    (+ (* 60 (decoded-time-hour now))
                       (decoded-time-minute now)))
           :lane 0))
      (org-timegrid--cursor-state-create
       :surface 'grid :day 0
       :minute (* 60 org-timegrid-start-hour) :lane 0))))

(defun org-timegrid--snap-minute (minute)
  "Return MINUTE rounded down to a fifteen-minute slot inside one day."
  (let ((slots (/ (- (* 60 24) org-timegrid-slot-minutes)
                  org-timegrid-slot-minutes)))
    (* org-timegrid-slot-minutes
       (max 0 (min slots (floor minute org-timegrid-slot-minutes))))))

(defun org-timegrid--cursor ()
  "Return the remembered cursor position, which may be hidden."
  (org-timegrid--calendar-state-cursor org-timegrid--state))

(defun org-timegrid--cursor-visible-p ()
  "Return non-nil when the cursor is currently drawn."
  (org-timegrid--calendar-state-cursor-visible org-timegrid--state))

(defun org-timegrid--blocks-starting-at (day minute)
  "Return committed blocks starting inside DAY's slot at MINUTE.
A real Org range can start at 13:10, which is no slot at all, so the test
is whether the start falls within this slot rather than equalling it;
otherwise such a block could never be selected.  Shortest first, so a
nested child is offered before its parent.  Several blocks can share a
slot, which is what the cursor's :lane disambiguates."
  (when (and (numberp day) (numberp minute))
    (sort (seq-filter (lambda (block)
                        (and (not (org-timegrid-block-preview block))
                             (= (org-timegrid-block-day block) day)
                             (>= (org-timegrid-block-start block) minute)
                             (< (org-timegrid-block-start block)
                                (+ minute org-timegrid-slot-minutes))))
                      (org-timegrid--timed-blocks))
          (lambda (left right)
            (< (- (org-timegrid-block-end left) (org-timegrid-block-start left))
               (- (org-timegrid-block-end right) (org-timegrid-block-start right)))))))

(defun org-timegrid--selected-id ()
  "Return the explicitly selected block id, or nil while hidden."
  (and (org-timegrid--cursor-visible-p)
       (org-timegrid--calendar-state-selected-id org-timegrid--state)))

(defun org-timegrid--cursor-rectangle (&optional geometry-list)
  "Return the cursor slot's pixel rectangle, or nil while it is hidden.
The rectangle narrows to the selected block's lane, which is how one lane
among several is visible at all.  GEOMETRY-LIST defaults to the committed
geometry; `org-timegrid--svg' passes the list it is still building, so the
cursor it draws and this agree."
  (when-let* (((org-timegrid--cursor-visible-p))
              (cursor (org-timegrid--cursor)))
    (let* ((canvas (max 560 (org-timegrid--window-width)))
           (column (/ (- canvas org-timegrid--label-width) 7.0))
           (selected (org-timegrid--selected-id))
           (lane (and selected
                      (cl-find-if
                       (lambda (item)
                         (and (equal (plist-get item :id) selected)
                              (= (plist-get item :day)
                                 (org-timegrid--cursor-state-day cursor))
                              (not (plist-get item :boundary-edge))))
                       (or geometry-list org-timegrid--geometry)))))
      (list :x (if lane
                   (plist-get lane :x)
                 (+ 1 org-timegrid--label-width
                    (* (org-timegrid--cursor-state-day cursor) column)))
            :y (+ org-timegrid--grid-top-inset
                  (* (- (org-timegrid--cursor-state-minute cursor)
                        (* 60 org-timegrid-start-hour))
                     org-timegrid-pixels-per-minute))
            :width (if lane (plist-get lane :width) (- column 2))
            :height (* org-timegrid-slot-minutes
                       org-timegrid-pixels-per-minute)))))

(defun org-timegrid--ensure-cursor ()
  "Return the cursor position, defaulting it when nothing is remembered."
  (or (org-timegrid--cursor)
      (let ((cursor (org-timegrid--default-cursor
                     (org-timegrid--calendar-state-week-start
                      org-timegrid--state))))
        (setf (org-timegrid--calendar-state-cursor org-timegrid--state) cursor)
        cursor)))

(defun org-timegrid--reveal-cursor ()
  "Show the cursor, returning non-nil when it was hidden until now.
The first movement key reveals the cursor where it was left rather than
also moving it, so its position is visible before it is used."
  (unless (org-timegrid--cursor-visible-p)
    (org-timegrid--ensure-cursor)
    (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
    t))

(defun org-timegrid--cursor-absolute ()
  "Return the cursor's absolute week minute."
  (let ((cursor (org-timegrid--ensure-cursor)))
    (+ (* (org-timegrid--cursor-state-day cursor) 1440)
       (org-timegrid--cursor-state-minute cursor))))

(defun org-timegrid--set-cursor (day minute &optional lane)
  "Move the cursor to DAY and MINUTE, clamped to the visible week.
LANE picks between blocks sharing that start, and defaults to zero."
  (let* ((day (max 0 (min 6 day)))
         (minute (org-timegrid--snap-minute minute))
         (lane (or lane 0))
         (candidates (org-timegrid--blocks-starting-at day minute))
         (selected (and candidates
                        (org-timegrid-block-id
                         (nth (min lane (1- (length candidates))) candidates)))))
    (setf (org-timegrid--calendar-state-cursor org-timegrid--state)
          (org-timegrid--cursor-state-create
           :surface 'grid :day day :minute minute :lane lane)
          (org-timegrid--calendar-state-selected-id org-timegrid--state)
          selected))
  (org-timegrid--cursor))

(defun org-timegrid--reload-state (week-start)
  "Reload WEEK-START from the backend, keeping cursor and selection.
Navigation and refresh drop preview and history, but they must not throw
the cursor back to today, and they must not clear the selection: every
edit refreshes, so a cleared selection would make repeated keyboard
nudges of one block impossible.  A selection that no longer resolves
after the reload is dropped."
  (let ((cursor (org-timegrid--calendar-state-cursor org-timegrid--state))
        (visible (org-timegrid--calendar-state-cursor-visible
                  org-timegrid--state))
        (selected (org-timegrid--calendar-state-selected-id
                   org-timegrid--state)))
    (setq-local org-timegrid--state (org-timegrid--load-state week-start))
    (when cursor
      (setf (org-timegrid--calendar-state-cursor org-timegrid--state) cursor
            (org-timegrid--calendar-state-cursor-visible org-timegrid--state)
            visible
            (org-timegrid--calendar-state-selected-id org-timegrid--state)
            selected))
    (setq-local org-timegrid--static-inner nil)))

(defun org-timegrid--block (id)
  "Return the current renderer block identified by ID."
  (cl-find id (org-timegrid--calendar-state-blocks org-timegrid--state)
           :key #'org-timegrid-block-id :test #'equal))

(defun org-timegrid--set-absolute-range
    (block absolute-start absolute-end)
  "Set BLOCK to ABSOLUTE-START and ABSOLUTE-END week-minute values."
  (let* ((day (floor absolute-start 1440))
         (day-start (* day 1440)))
    (setf (org-timegrid-block-day block) day
          (org-timegrid-block-start block) (- absolute-start day-start)
          (org-timegrid-block-end block) (- absolute-end day-start))
    block))

(defun org-timegrid--transform-block-range (block delta edge)
  "Return a copy of BLOCK shifted by DELTA minutes at optional EDGE.
All-day ranges use whole-day granularity and may continue beyond the
visible week.  Timed ranges remain clamped to the visible week."
  (let* ((copy (copy-org-timegrid-block block))
         (all-day (org-timegrid-block-all-day-p block))
         (minimum (if all-day 1440 org-timegrid-slot-minutes))
         (start (+ (* (org-timegrid-block-day block) 1440)
                   (org-timegrid-block-start block)))
         (end (+ (* (org-timegrid-block-day block) 1440)
                 (org-timegrid-block-end block)))
         (duration (- end start))
         (week-end (* 7 1440)))
    (pcase edge
      ('top
       (setq start (min (+ start delta) (- end minimum)))
       (unless all-day (setq start (max 0 start))))
      ('bottom
       (setq end (max (+ end delta) (+ start minimum)))
       (unless all-day (setq end (min week-end end))))
      (_
       (setq start
             (if all-day
                 (max (- 1440 duration)
                      (min (+ start delta) (- week-end 1440)))
               (max 0 (min (+ start delta) (- week-end duration))))
             end (+ start duration))))
    (org-timegrid--set-absolute-range copy start end)
    (setf (org-timegrid-block-preview copy) t)
    copy))

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
     ((null id)
      (if (/= origin-day target-day)
          (org-timegrid--operation-create
           :error "New ranges currently stay within one day")
        (let ((block (org-timegrid--make-block
                      'preview origin-day
                      (min origin-minute target-minute)
                      (+ (max origin-minute target-minute)
                         org-timegrid-slot-minutes)
                      "New block" 'blue)))
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
          (let* ((block (copy-org-timegrid-block source))
                 (absolute-start (+ (* (org-timegrid-block-day block) 1440)
                                    (org-timegrid-block-start block)))
                 (absolute-end (+ (* (org-timegrid-block-day block) 1440)
                                  (org-timegrid-block-end block)))
                 (duration (- absolute-end absolute-start))
                 (absolute-origin (+ (* origin-day 1440) origin-minute))
                 (absolute-target (+ (* target-day 1440) target-minute))
                 kind)
            (let ((unit (if (eq origin-surface 'rail)
                            1440
                          org-timegrid-slot-minutes)))
              (cond
             ((and (eq edge 'top) (not copying))
              (setq kind 'resize)
              (org-timegrid--set-absolute-range
               block (max 0 (min absolute-target
                                 (- absolute-end unit)))
               absolute-end))
             ((and (eq edge 'bottom) (not copying))
              (setq kind 'resize)
              (org-timegrid--set-absolute-range
               block absolute-start
               (min (* 7 1440)
                    (max (+ absolute-target unit)
                         (+ absolute-start unit)))))
             (t
              (setq kind (if copying copy-kind 'move))
              (let* ((grab-offset (- absolute-origin absolute-start))
                     (new-start (max 0 (min (- absolute-target grab-offset)
                                            (- (* 7 1440) duration)))))
                (org-timegrid--set-absolute-range
                 block new-start (+ new-start duration))))))
            (setf (org-timegrid-block-preview block) t)
            (org-timegrid--operation-create
             :kind kind :block block
             :replace-id (and (not copying) id)))))))))

(defun org-timegrid--remapped-color (face attribute)
  "Return ATTRIBUTE of FACE as remapped in this buffer, or nil.
`face-remapping-alist' is how a buffer gets a background of its own --
solaire-mode dims every buffer that is not visiting a file, and per-buffer
theming works the same way -- and `face-attribute' does not consult it.
Reading the global face instead draws a calendar that does not match the
buffer it sits in.  An entry is a face, or a list of faces with the first
taking priority, or an inline attribute list."
  (let ((remap (cdr (assq face face-remapping-alist))))
    (seq-some
     (lambda (entry)
       (cond ((and (symbolp entry) (facep entry))
              (let ((value (face-attribute entry attribute nil t)))
                (and (stringp value) value)))
             ((and (consp entry) (keywordp (car entry)))
              (plist-get entry attribute))))
     (if (proper-list-p remap) remap (list remap)))))

(defun org-timegrid--face-color
    (face attribute fallback)
  "Return FACE ATTRIBUTE as a color string, or FALLBACK.
Buffer-local face remapping wins, so the drawing matches the buffer it is
drawn into rather than the frame's idea of the face."
  (let ((value (or (org-timegrid--remapped-color face attribute)
                   (face-attribute face attribute nil t))))
    (if (and (stringp value) (color-name-to-rgb value)) value fallback)))

(defun org-timegrid--blend (foreground background amount)
  "Blend FOREGROUND into BACKGROUND by AMOUNT."
  (let ((foreground-rgb (org-timegrid--rgb foreground))
        (background-rgb (org-timegrid--rgb background)))
    (if (and foreground-rgb background-rgb)
        (apply #'color-rgb-to-hex
               (append
                (cl-mapcar (lambda (foreground-part background-part)
                             (+ (* amount foreground-part)
                                (* (- 1 amount) background-part)))
                           foreground-rgb background-rgb)
                '(2)))
      background)))

(defun org-timegrid--rgb (color)
  "Return normalized RGB components for COLOR.
Parse hexadecimal values directly because some macOS builds interpret a
six-digit value as three one-digit components in `color-values'."
  (if (and (stringp color)
           (string-match "\\`#\\([[:xdigit:]]+\\)\\'" color)
           (= (% (length (match-string 1 color)) 3) 0))
      (let* ((hex (match-string 1 color))
             (digits (/ (length hex) 3))
             (maximum (float (1- (expt 16 digits)))))
        (cl-loop for offset from 0 below (length hex) by digits
                 collect (/ (string-to-number
                              (substring hex offset (+ offset digits)) 16)
                            maximum)))
    (color-name-to-rgb color)))

(defun org-timegrid--palette ()
  "Return SVG colors derived from the current Emacs faces."
  (let* ((background (org-timegrid--face-color
                      'default :background "#ffffff"))
         (foreground (org-timegrid--face-color
                      'default :foreground "#30343a"))
         (muted (org-timegrid--face-color
                 'shadow :foreground foreground))
         ;; Chrome only: the selection outline and the current-time line.
         ;; Event colours come from `org-timegrid-colors'.
         (blue (org-timegrid--face-color
                'link :foreground "#3979d6"))
         (red (org-timegrid--face-color
               'error :foreground "#d94b4b"))
         (highlight (org-timegrid--face-color
                     'highlight :background blue)))
    (list :background background :foreground foreground :muted muted
          :grid (org-timegrid--blend foreground background 0.16)
          :half-grid (org-timegrid--blend foreground background 0.08)
          :time-background
          (org-timegrid--blend foreground background 0.035)
          :time-label
          (org-timegrid--blend foreground background 0.64)
          :secondary-text
          (org-timegrid--blend foreground background 0.72)
          :weekend (org-timegrid--blend foreground background 0.025)
          :today (org-timegrid--blend highlight background 0.10)
          :blue blue :red red
          :cursor (org-timegrid--face-color 'cursor :background blue)
          :preview-fill (org-timegrid--blend muted background 0.18)
          :done-fill (org-timegrid--blend muted background 0.11))))

(defun org-timegrid--sync-fringe-background ()
  "Match this buffer's fringes to its time-label gutter."
  (when org-timegrid--fringe-remap-cookie
    (face-remap-remove-relative org-timegrid--fringe-remap-cookie))
  (setq-local
   org-timegrid--fringe-remap-cookie
   (face-remap-add-relative
    'fringe
    (list :background
          (plist-get (org-timegrid--palette) :time-background)))))

(defun org-timegrid--layout-day (blocks day)
  "Lay out BLOCKS on DAY as nested, independently split sibling groups."
  (let* ((sorted (sort (cl-remove-if-not
                        (lambda (block) (= day (org-timegrid-block-day block)))
                        (copy-sequence blocks))
                       (lambda (left right)
                         (if (= (org-timegrid-block-start left)
                                (org-timegrid-block-start right))
                             (> (org-timegrid-block-end left)
                                (org-timegrid-block-end right))
                           (< (org-timegrid-block-start left)
                              (org-timegrid-block-start right))))))
         annotated)
    (dolist (block sorted)
      (let* ((containers
              (cl-remove-if-not
               (lambda (candidate)
                 (and (<= (org-timegrid-block-start candidate)
                           (org-timegrid-block-start block))
                      (>= (org-timegrid-block-end candidate)
                           (org-timegrid-block-end block))
                      (or (< (org-timegrid-block-start candidate)
                             (org-timegrid-block-start block))
                          (> (org-timegrid-block-end candidate)
                             (org-timegrid-block-end block)))
                      (>= (* (- (org-timegrid-block-start block)
                                (org-timegrid-block-start candidate))
                             org-timegrid-pixels-per-minute)
                          org-timegrid-title-clearance)))
               annotated))
             (parent
              (car (sort containers
                         (lambda (left right)
                           (> (org-timegrid-block-nest-depth left)
                              (org-timegrid-block-nest-depth right))))))
             (copy (copy-org-timegrid-block block)))
        (setf (org-timegrid-block-nest-depth copy)
              (if parent
                  (1+ (org-timegrid-block-nest-depth parent))
                0)
              (org-timegrid-block-root-id copy)
              (if parent
                  (org-timegrid-block-root-id parent)
                (org-timegrid-block-id copy))
              (org-timegrid-block-parent-id copy)
              (and parent (org-timegrid-block-id parent)))
        (push copy annotated)))
    (setq annotated (nreverse annotated))
    (let ((siblings (make-hash-table :test #'equal))
          (local-layout (make-hash-table :test #'equal))
          (output (make-hash-table :test #'equal))
          (family-size (make-hash-table :test #'equal)))
      (dolist (block annotated)
        (let ((parent-id (org-timegrid-block-parent-id block))
              (root-id (org-timegrid-block-root-id block)))
          (puthash parent-id
                   (cons block (gethash parent-id siblings))
                   siblings)
          (puthash root-id (1+ (gethash root-id family-size 0)) family-size)))
      ;; Every parent's children get their own overlap lanes.  This prevents
      ;; deep siblings from painting over each other's title line while both
      ;; remain geometrically contained by the same ancestor.
      (maphash
       (lambda (_parent-id children)
         (dolist (child
                  (org-timegrid-basic-layout-day
                   (nreverse children) day))
           (puthash (org-timegrid-block-id child) child local-layout)))
       siblings)
      ;; Parents precede their children in ANNOTATED, so their completed path
      ;; is available when constructing each descendant's path.
      (mapcar
       (lambda (block)
         (let* ((copy (copy-org-timegrid-block block))
                (id (org-timegrid-block-id copy))
                (parent-id (org-timegrid-block-parent-id copy))
                (parent (and parent-id (gethash parent-id output)))
                (local (gethash id local-layout))
                (step (cons (or (org-timegrid-block-lane local) 0)
                            (max 1 (or (org-timegrid-block-lanes local) 1))))
                (path (append (and parent (org-timegrid-block-layout-path parent))
                              (list step))))
           (setf (org-timegrid-block-layout-path copy) path
                 (org-timegrid-block-nested-family copy)
                 (> (gethash (org-timegrid-block-root-id copy)
                             family-size 0)
                    1))
           (puthash id copy output)
           copy))
       annotated))))

(defun org-timegrid--layout-frame
    (block day-x column-width)
  "Return BLOCK's horizontal (X . WIDTH) inside a day column.
DAY-X and COLUMN-WIDTH describe the full column."
  (let ((x day-x)
        (width column-width)
        (depth 0))
    (dolist (step (org-timegrid-block-layout-path block))
      (when (> depth 0)
        (setq x (+ x org-timegrid-nesting-indent)
              width (max 4 (- width
                              org-timegrid-nesting-indent))))
      (let* ((lane (car step))
             (lanes (max 1 (cdr step)))
             (available (- width
                           (* (1- lanes)
                              org-timegrid--lane-gap)))
             (lane-width (/ available lanes)))
        (setq x (+ x (* lane (+ lane-width
                                org-timegrid--lane-gap)))
              width lane-width))
      (setq depth (1+ depth)))
    (cons x width)))

(defun org-timegrid--wrap-title
    (title width max-lines)
  "Wrap TITLE to WIDTH characters and at most MAX-LINES lines."
  (let ((remaining (string-trim (or title "")))
        lines)
    (dotimes (line max-lines)
      (when (not (string-empty-p remaining))
        (if (= line (1- max-lines))
            (progn
              (push (truncate-string-to-width remaining width nil nil "…") lines)
              (setq remaining ""))
          (if (<= (string-width remaining) width)
              (progn (push remaining lines) (setq remaining ""))
            (let ((cut (min width (length remaining))))
              (while (and (> cut 1)
                          (> (string-width (substring remaining 0 cut)) width))
                (setq cut (1- cut)))
              (let* ((space (cl-position ?\s remaining :from-end t :end cut))
                     (end (if (and space (> space 0)) space cut)))
                (push (string-trim-right (substring remaining 0 end)) lines)
                (setq remaining
                      (string-trim-left
                       (substring remaining
                                  (if (and space (= end space)) (1+ end) end))))))))))
    (nreverse lines)))

(defun org-timegrid--format-minute (minute)
  "Format MINUTE as a clock time normalized to the 24-hour day."
  (let ((normalized (% minute 1440)))
    (format "%02d:%02d" (/ normalized 60) (% normalized 60))))

(defun org-timegrid--format-range (start end)
  "Format logical START and END minutes, including the end-day offset."
  (let ((day-offset (floor end 1440)))
    (format "%s–%s%s"
            (org-timegrid--format-minute start)
            (org-timegrid--format-minute end)
            (if (> day-offset 0) (format " (+%d)" day-offset) ""))))

(defun org-timegrid--resolve-color (color palette)
  "Return COLOR as a colour string, resolving a name through the palette.
COLOR is a name in `org-timegrid-colors', any colour string, or nil for
`org-timegrid-default-color'.  An unknown name falls back to the theme's
own accent rather than drawing nothing."
  (let ((color (or color org-timegrid-default-color)))
    (or (and (symbolp color) (cdr (assq color org-timegrid-colors)))
        (and (stringp color) (color-defined-p color) color)
        (cdr (assq org-timegrid-default-color org-timegrid-colors))
        (plist-get palette :blue))))

(defun org-timegrid--accent (block palette)
  "Return the accent color for BLOCK from PALETTE."
  (if (or (org-timegrid-block-preview block) (org-timegrid-block-done block))
      (plist-get palette :muted)
    (org-timegrid--resolve-color (org-timegrid-block-color block) palette)))

(defun org-timegrid--color (block palette)
  "Return the fill color for BLOCK from PALETTE.
A block is a wash of its accent over the buffer background, so any colour
works without the palette having to know it in advance."
  (cond
   ((org-timegrid-block-preview block) (plist-get palette :preview-fill))
   ((org-timegrid-block-done block) (plist-get palette :done-fill))
   (t (org-timegrid--blend (org-timegrid--accent block palette)
                           (plist-get palette :background) 0.17))))

(defun org-timegrid--display-segments (block)
  "Return visible per-day segments and exact-midnight grips for BLOCK."
  (let* ((source-day (org-timegrid-block-day block))
         (source-start (org-timegrid-block-start block))
         (source-end (org-timegrid-block-end block))
         (absolute-start (+ (* source-day 1440) source-start))
         (absolute-end (+ (* source-day 1440) source-end))
         segments)
    (dotimes (day 7)
      (let* ((day-start (* day 1440))
             (day-end (+ day-start 1440))
             (segment-start (max absolute-start day-start))
             (segment-end (min absolute-end day-end)))
        (when (< segment-start segment-end)
          (let ((segment (copy-org-timegrid-block block)))
            (setf (org-timegrid-block-source-day segment) source-day
                  (org-timegrid-block-source-start segment) source-start
                  (org-timegrid-block-source-end segment) source-end
                  (org-timegrid-block-day segment) day
                  (org-timegrid-block-start segment) (- segment-start day-start)
                  (org-timegrid-block-end segment) (- segment-end day-start)
                  (org-timegrid-block-allow-top segment)
                  (= segment-start absolute-start)
                  (org-timegrid-block-allow-bottom segment)
                  (= segment-end absolute-end))
            (push segment segments)))))
    ;; A range ending exactly at midnight needs a small bottom-edge target at
    ;; the top of the next day so it can be extended forward.
    (when (and (= (% absolute-end 1440) 0)
               (< 0 absolute-end (* 7 1440)))
      (let* ((day (/ absolute-end 1440))
             (grip (copy-org-timegrid-block block)))
        (setf (org-timegrid-block-source-day grip) source-day
              (org-timegrid-block-source-start grip) source-start
              (org-timegrid-block-source-end grip) source-end
              (org-timegrid-block-day grip) day
              (org-timegrid-block-start grip) 0
              (org-timegrid-block-end grip) 1
              (org-timegrid-block-title grip) ""
              (org-timegrid-block-boundary-edge grip) 'bottom
              (org-timegrid-block-allow-top grip) nil
              (org-timegrid-block-allow-bottom grip) t)
        (push grip segments)))
    ;; A range starting exactly at midnight gets its top-edge target at the
    ;; bottom of the preceding day so it can be extended backward.
    (when (and (= (% absolute-start 1440) 0)
               (< 0 absolute-start (* 7 1440)))
      (let* ((day (1- (/ absolute-start 1440)))
             (grip (copy-org-timegrid-block block)))
        (setf (org-timegrid-block-source-day grip) source-day
              (org-timegrid-block-source-start grip) source-start
              (org-timegrid-block-source-end grip) source-end
              (org-timegrid-block-day grip) day
              (org-timegrid-block-start grip) 1439
              (org-timegrid-block-end grip) 1440
              (org-timegrid-block-title grip) ""
              (org-timegrid-block-boundary-edge grip) 'top
              (org-timegrid-block-allow-top grip) t
              (org-timegrid-block-allow-bottom grip) nil)
        (push grip segments)))
    (nreverse segments)))

(defun org-timegrid-day-blocks (backend absolute-day)
  "Return BACKEND blocks on ABSOLUTE-DAY, clipped to it and given lanes.
Coordinates are minutes within that day, so a range running past midnight
arrives clipped at 1440 rather than spilling into a day that is not being
drawn.  Overlaps get plain side-by-side lanes: the Week view nests a child
inside its parent, which needs more height than one compact row has.
Date-only events are omitted: compact day images have no all-day rail, and
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
    (org-timegrid-basic-layout-day blocks 0)))

(defun org-timegrid--draw-edge-shadow (svg x y width direction palette)
  "Shade WIDTH pixels of SVG inward from X and Y, going DIRECTION.
DIRECTION is 1 for an edge at the top and -1 for one at the bottom.
A shadow always darkens, whatever the theme.  The usual advice is to lift
rather than darken on a dark background, but a pale band across the foot
of a dark calendar reads as a highlight, not as depth.  Stacked bands
rather than an SVG gradient: five rectangles are indistinguishable at this
size and need no gradient definition."
  (let* ((bands 5)
         (band (/ (float org-timegrid-compact-shadow-pixels) bands))
         (color (org-timegrid--blend "#000000"
                                    (plist-get palette :background) 0.5)))
    (dotimes (index bands)
      (svg-rectangle svg x
                     (if (> direction 0)
                         (+ y (* index band))
                       (- y (* (1+ index) band)))
                     width band
                     :fill color
                     ;; Densest at the cut, fading inward, so content
                     ;; dissolves into the edge instead of stopping at it.
                     :fill-opacity (max 0.04 (- 0.5 (* index 0.11)))))))

(defun org-timegrid-day-image (blocks start-minute end-minute width
                                      &optional now)
  "Return an SVG image of BLOCKS between START-MINUTE and END-MINUTE.
WIDTH is in pixels.  NOW, a minute of the day, draws a current-time line.
This is a read-only strip: one day, no cursor, and no hit-test geometry,
which is what makes it safe to drop into a buffer the calendar does not
own."
  (let* ((scale org-timegrid-compact-pixels-per-minute)
         (font-size org-timegrid-compact-font-size)
         (line-height (+ font-size 2))
         ;; Roughly the advance width of a digit at this size, which is what
         ;; decides how much of a title fits before it has to wrap.
         (character-width (* font-size 0.6))
         (span (max 60 (- end-minute start-minute)))
         (height (ceiling (* span scale)))
         (label-width org-timegrid-compact-label-width)
         (column (max 40 (- width label-width 2)))
         (palette (org-timegrid--palette))
         (font-family (let ((family (face-attribute 'default :family nil t)))
                        (if (stringp family) family "monospace")))
         (svg (svg-create width height :stroke-width 0)))
    (svg-rectangle svg 0 0 width height
                   :fill (plist-get palette :background))
    ;; Hour rules, with the half hours a shade lighter, as in the Week view.
    (cl-loop for minute from (* 60 (ceiling start-minute 60))
             to end-minute by 30 do
             (let ((y (* (- minute start-minute) scale))
                   (hourp (zerop (% minute 60))))
               (svg-line svg label-width y width y
                         :stroke (plist-get palette
                                            (if hourp :grid :half-grid))
                         :stroke-width 1)
               (when hourp
                 (svg-text svg (org-timegrid--format-minute minute)
                           :x 2 :y (min (- height 2) (+ y (- line-height 2)))
                           :font-size font-size :font-family font-family
                           :fill (plist-get palette :time-label)))))
    (dolist (block blocks)
      (let* ((lanes (max 1 (or (org-timegrid-block-lanes block) 1)))
             (lane (or (org-timegrid-block-lane block) 0))
             (lane-width (/ (- column (* (1- lanes) org-timegrid--lane-gap))
                            (float lanes)))
             (x (+ label-width 1 (* lane (+ lane-width
                                            org-timegrid--lane-gap))))
             ;; Clipped to the viewport, so a block that began before it
             ;; still shows the part that has not happened yet.
             (top (max start-minute (org-timegrid-block-start block)))
             (bottom (min end-minute (org-timegrid-block-end block)))
             (y (* (- top start-minute) scale))
             (block-height (max 3 (- (* (- bottom top) scale)
                                     org-timegrid-block-gap)))
             (characters (max 1 (floor (/ (- lane-width 8) character-width))))
             (lines (unless (< (org-timegrid-block-start block) start-minute)
                      (org-timegrid--wrap-title
                       (org-timegrid-block-title block) characters
                       (max 1 (floor (/ block-height line-height)))))))
        (when (> bottom top)
          (svg-rectangle svg x y lane-width block-height
                         :rx org-timegrid-corner-radius
                         :ry org-timegrid-corner-radius
                         :fill (org-timegrid--color block palette))
          (svg-rectangle svg (+ x 1) (+ y 1) 2 (max 1 (- block-height 2))
                         :fill (org-timegrid--accent block palette))
          (cl-loop for line in lines
                   for index from 0 do
                   (svg-text svg line
                             :x (+ x 6)
                             :y (+ y (- line-height 2) (* index line-height))
                             :font-size font-size :font-family font-family
                             :fill (if (org-timegrid-block-done block)
                                       (plist-get palette :muted)
                                     (plist-get palette :foreground)))))))
    ;; Shade an edge only when the day has something past it.  A shadow over
    ;; an empty evening claims there is more to see, and there is not.
    (when (and (> start-minute 0)
               (seq-some (lambda (block)
                           (< (org-timegrid-block-start block) start-minute))
                         blocks))
      (org-timegrid--draw-edge-shadow svg 0 0 width 1 palette))
    (when (and (< end-minute 1440)
               (seq-some (lambda (block)
                           (> (org-timegrid-block-end block) end-minute))
                         blocks))
      (org-timegrid--draw-edge-shadow svg 0 height width -1 palette))
    ;; Last, so the shadows never dim the one line that says where now is.
    (when (and now (<= start-minute now end-minute))
      (let ((y (* (- now start-minute) scale)))
        (svg-line svg label-width y width y
                  :stroke (plist-get palette :red) :stroke-width 2)
        (svg-circle svg label-width y 3 :fill (plist-get palette :red))))
    (svg-image svg :scale 1 :ascent 'center)))

(defun org-timegrid--effective-blocks ()
  "Return per-day display segments with the current preview applied."
  (let* ((preview (org-timegrid--calendar-state-preview org-timegrid--state))
         (preview-block (and preview
                             (org-timegrid--operation-block preview)))
         (timed-preview (and preview-block
                             (not (org-timegrid-block-all-day-p
                                   preview-block))))
         (replace-id (and preview
                          timed-preview
                          (org-timegrid--operation-replace-id preview)))
         (blocks (org-timegrid--timed-blocks)))
    (mapcan
     #'org-timegrid--display-segments
     (let ((display-blocks
            (if (null timed-preview)
                blocks
              (append (if replace-id
                          (cl-remove replace-id blocks
                                     :key (lambda (block)
                                            (org-timegrid-block-id block))
                                     :test #'equal)
                        blocks)
                      (list preview-block)))))
       (if org-timegrid--render-excluded-id
           (cl-remove org-timegrid--render-excluded-id display-blocks
                      :key (lambda (block) (org-timegrid-block-id block))
                      :test #'equal)
         display-blocks)))))

(defun org-timegrid--window-width ()
  "Return the prototype window's body width in pixels."
  (if-let ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window t)
    900))

(defun org-timegrid--ensure-state ()
  "Ensure the current prototype buffer has a usable calendar state.
Keep existing blocks when possible, but reconstruct missing date metadata."
  (unless (and (org-timegrid--calendar-state-p org-timegrid--state)
               (numberp (org-timegrid--calendar-state-week-start
                         org-timegrid--state)))
    (setq-local org-timegrid--state
                (org-timegrid--load-state (org-timegrid-week-start))))
  org-timegrid--state)

(defun org-timegrid--draw-block
    (svg block canvas-height start-minute scale column-width palette font-family)
  "Draw BLOCK on SVG and return its hit-test geometry."
  (let* ((day (org-timegrid-block-day block))
         (day-x (+ org-timegrid--label-width (* day column-width)))
         (horizontal (org-timegrid--layout-frame block day-x column-width))
         (x (car horizontal))
         (boundary-edge (org-timegrid-block-boundary-edge block))
         (raw-y (cond ((eq boundary-edge 'top)
                       (- canvas-height org-timegrid-midnight-grip-pixels))
                      ((eq boundary-edge 'bottom)
                       org-timegrid--grid-top-inset)
                      (t (+ org-timegrid--grid-top-inset
                            (* (- (org-timegrid-block-start block) start-minute)
                               scale)))))
         (raw-height
          (if boundary-edge
              (+ org-timegrid-midnight-grip-pixels org-timegrid-block-gap)
            (* (- (org-timegrid-block-end block) (org-timegrid-block-start block)) scale)))
         (gap org-timegrid-block-gap)
         (y (+ raw-y (/ gap 2.0)))
         (block-height (max 4 (- raw-height gap)))
         (block-width (max 4 (- (cdr horizontal) 1)))
         (selected (and (not org-timegrid--static-render)
                        (not (org-timegrid-block-preview block))
                        (equal (org-timegrid-block-id block)
                               (org-timegrid--selected-id))))
         (fill (org-timegrid--color block palette))
         (accent (org-timegrid--accent block palette))
         (font-size (if (< block-height 13) 8 10))
         (line-height (if (= font-size 8) 10 13))
         (characters (max 1 (floor (/ (- block-width 12)
                                      (* font-size 0.62)))))
         (max-lines (max 1 (floor (/ (max 1 (- block-height 3))
                                     line-height))))
         (title-lines (org-timegrid--wrap-title
                       (org-timegrid-block-title block) characters max-lines))
         (clip-id (format "occs-block-%s-%x" day
                          (sxhash (org-timegrid-block-id block))))
         (clip (svg-clip-path svg :id clip-id))
         (radius (max 0 org-timegrid-corner-radius))
         (accent-radius (min 1.5 (/ radius 2.0))))
    (svg-rectangle clip x y block-width block-height :rx radius :ry radius)
    (svg-rectangle svg x y block-width block-height
                   :rx radius :ry radius :fill fill
                   :fill-opacity (if (org-timegrid-block-preview block) 0.72 1)
                   :stroke (if selected
                               (plist-get palette :blue)
                             (plist-get palette :background))
                   :stroke-width (if selected 2 1))
    (svg-rectangle svg (+ x 2) (+ y 2) 3 (max 1 (- block-height 4))
                   :rx accent-radius :ry accent-radius :fill accent)
    (cl-loop for line in (unless boundary-edge title-lines)
             for index from 0 do
             (svg-text svg line :x (+ x 9)
                       :y (+ y (min (- block-height 1)
                                    (+ (if (= font-size 8) 8 10)
                                       (* index line-height))))
                       :font-size font-size :font-weight "600"
                       :font-family font-family
                       :clip-path (format "url(#%s)" clip-id)
                       :fill (if (org-timegrid-block-done block)
                                 (plist-get palette :muted)
                               (plist-get palette :foreground))))
    (when (and (not boundary-edge) (< (length title-lines) max-lines))
      (svg-text svg
                (org-timegrid--format-range
                 (or (org-timegrid-block-source-start block) (org-timegrid-block-start block))
                 (or (org-timegrid-block-source-end block) (org-timegrid-block-end block)))
                :x (+ x 9)
                :y (+ y 10 (* (length title-lines) line-height))
                :font-size 9 :font-family font-family
                :clip-path (format "url(#%s)" clip-id)
                :fill (plist-get palette :secondary-text)))
    (list :id (org-timegrid-block-id block) :day day
          :start (org-timegrid-block-start block) :end (org-timegrid-block-end block)
          :x x :y y :width block-width :height block-height
          :preview (org-timegrid-block-preview block)
          :allow-top (org-timegrid-block-allow-top block)
          :allow-bottom (org-timegrid-block-allow-bottom block)
          :boundary-edge boundary-edge)))

(defun org-timegrid--draw-current-time
    (svg width height column-width palette font-family start-minute scale)
  "Draw the current-time marker on SVG and return its Y coordinate."
  (let* ((now (decode-time))
         (today (calendar-absolute-from-gregorian (calendar-current-date)))
         (today-day (- today (org-timegrid--calendar-state-week-start org-timegrid--state)))
         (now-minute (+ (* 60 (decoded-time-hour now))
                        (decoded-time-minute now))))
    (when (and (<= 0 today-day 6)
               (<= start-minute now-minute
                   (* 60 org-timegrid-end-hour)))
      (let* ((y (+ org-timegrid--grid-top-inset
                   (* (- now-minute start-minute) scale)))
             (today-x (+ org-timegrid--label-width
                         (* today-day column-width)))
             (label (format "%02d:%02d"
                            (decoded-time-hour now)
                            (decoded-time-minute now)))
             (bubble-width 36)
             (bubble-height 14)
             (bubble-x (/ (- org-timegrid--label-width bubble-width) 2.0))
             (bubble-right (+ bubble-x bubble-width))
             (today-line-x (if (= today-day 0) bubble-right today-x))
             (bubble-y (max 1 (min (- height bubble-height 1)
                                   (- y (/ bubble-height 2.0))))))
        (svg-line svg bubble-right y width y
                  :stroke (plist-get palette :red) :stroke-width 2
                  :stroke-opacity 0.16)
        (svg-line svg today-line-x y (+ today-x column-width) y
                  :stroke (plist-get palette :red) :stroke-width 2)
        (when (> today-day 0)
          (svg-circle svg today-x y 4 :fill (plist-get palette :red)))
        (svg-rectangle svg bubble-x bubble-y bubble-width bubble-height
                       :rx 7 :ry 7 :fill (plist-get palette :red))
        (svg-text svg label :x (/ org-timegrid--label-width 2.0)
                  :y (+ bubble-y 10) :font-size 8 :font-weight "600"
                  :font-family font-family :text-anchor "middle"
                  :fill "#ffffff")
        y))))

(defun org-timegrid--svg ()
  "Build the calendar SVG and update hit-test geometry."
  (org-timegrid--ensure-state)
  (let* ((width (max 560 (org-timegrid--window-width)))
         (start-minute (* 60 org-timegrid-start-hour))
         (end-minute (* 60 org-timegrid-end-hour))
         (scale org-timegrid-pixels-per-minute)
         (height (+ org-timegrid--grid-top-inset
                    (ceiling (* (- end-minute start-minute) scale))))
         (column-width (/ (- width org-timegrid--label-width)
                          7.0))
         (svg (svg-create width height :stroke-width 0))
         (palette (org-timegrid--palette))
         (font-family (let ((family (face-attribute 'default :family nil t)))
                        (if (stringp family) family "monospace")))
         (week-start (org-timegrid--calendar-state-week-start org-timegrid--state))
         (today-column
          (- (calendar-absolute-from-gregorian (calendar-current-date))
             week-start))
         (blocks (org-timegrid--effective-blocks))
         (day-blocks (make-vector 7 nil))
         geometry)
    (setq-local org-timegrid--image-height height)
    (svg-rectangle svg 0 0 width height :fill (plist-get palette :background))
    (svg-rectangle svg 0 0 org-timegrid--label-width height
                   :fill (plist-get palette :time-background))
    (dotimes (day 7)
      (let* ((x (+ org-timegrid--label-width
                   (* day column-width)))
             (weekday
              (calendar-day-of-week
               (calendar-gregorian-from-absolute (+ week-start day)))))
        (svg-rectangle svg x 0 column-width height
                       :fill (cond ((= day today-column) (plist-get palette :today))
                                   ((memq weekday '(0 6))
                                    (plist-get palette :weekend))
                                   (t (plist-get palette :background))))
        (svg-line svg x 0 x height
                  :stroke (plist-get palette :grid) :stroke-width 1)
        (aset day-blocks day
              (org-timegrid--layout-day blocks day))))
    (svg-line svg width 0 width height
              :stroke (plist-get palette :grid) :stroke-width 1)
    (cl-loop for minute from start-minute to end-minute by 30 do
             (let* ((y (+ org-timegrid--grid-top-inset
                          (* (- minute start-minute) scale)))
                    (hourp (= (% minute 60) 0)))
               (svg-line svg org-timegrid--label-width y
                         width y
                         :stroke (if hourp
                                     (plist-get palette :grid)
                                   (plist-get palette :half-grid))
                         :stroke-width 1)
               (when (and hourp (< minute end-minute))
                 (svg-text svg (format "%02d:00" (/ minute 60))
                           :x 5 :y (+ y 11) :font-size 10
                           :font-family font-family
                           :fill (plist-get palette :time-label)))))
    (dotimes (day 7)
      (dolist (block (aref day-blocks day))
        (push (org-timegrid--draw-block
               svg block height start-minute scale column-width
               palette font-family)
              geometry)))
    ;; The keyboard cursor is one fifteen-minute slot drawn over the blocks.
    ;; Its fill is translucent so a block underneath stays readable, and it
    ;; is drawn only while visible.
    (when-let* (((not org-timegrid--static-render))
                ((org-timegrid--cursor-visible-p))
                ((eq (org-timegrid--cursor-state-surface
                      (org-timegrid--cursor))
                     'grid))
                ;; A selected block already draws its own outline, and two
                ;; borders around one slot read as a bug.
                ((null (org-timegrid--selected-id)))
                (cursor (org-timegrid--cursor))
                (cursor-minute (org-timegrid--cursor-state-minute cursor)))
      (when (<= start-minute cursor-minute (- end-minute
                                              org-timegrid-slot-minutes))
        ;; A cursor that selects a block narrows to that block's lane, which
        ;; is what makes one lane among several visible.  Otherwise it spans
        ;; the whole day column.
        (let* ((rectangle (org-timegrid--cursor-rectangle geometry))
               (x (plist-get rectangle :x))
               (width (plist-get rectangle :width))
               (y (+ org-timegrid--grid-top-inset
                     (* (- cursor-minute start-minute) scale))))
          (svg-rectangle svg x y width
                         (* org-timegrid-slot-minutes scale)
                         :fill (plist-get palette :cursor)
                         :fill-opacity org-timegrid-cursor-opacity
                         :stroke (plist-get palette :cursor)
                         :stroke-width 1
                         :rx org-timegrid-corner-radius))))
    (unless org-timegrid--static-render
      (org-timegrid--draw-current-time
       svg width height column-width palette font-family start-minute scale))
    (setq-local org-timegrid--geometry geometry)
    svg))

(defun org-timegrid--svg-inner-xml (svg)
  "Return SVG's serialized child elements."
  (with-temp-buffer
    (svg-print svg)
    (let* ((xml (buffer-string))
           (start (1+ (string-match ">" xml)))
           (end (string-match "</svg>\\'" xml)))
      (substring xml start end))))

(defun org-timegrid--update-clock-fragment ()
  "Rebuild the current-time fragment and remember its overlapping tiles."
  (let* ((svg (svg-create org-timegrid--tile-width org-timegrid--image-height
                          :stroke-width 0))
         (palette (org-timegrid--palette))
         (font-family (let ((family (face-attribute 'default :family nil t)))
                        (if (stringp family) family "monospace")))
         (start-minute (* 60 org-timegrid-start-hour))
         (column-width (/ (- org-timegrid--tile-width
                             org-timegrid--label-width)
                          7.0))
         (y (org-timegrid--draw-current-time
             svg org-timegrid--tile-width org-timegrid--image-height
             column-width palette font-family start-minute
             org-timegrid-pixels-per-minute)))
    (setq-local org-timegrid--clock-fragment
                (and y (org-timegrid--svg-inner-xml svg))
                org-timegrid--clock-tiles
                (and y
                     (let ((first
                            (max 0 (floor (- y 7)
                                          org-timegrid--tile-height)))
                           (last
                            (min (1- org-timegrid--tile-count)
                                 (floor (min (1- org-timegrid--image-height)
                                             (+ y 7))
                                        org-timegrid--tile-height))))
                       (number-sequence first last))))))

(defun org-timegrid--tile-xml (tile &optional fragment)
  "Return the complete SVG document for TILE and dynamic FRAGMENT."
  (let* ((y (* tile org-timegrid--tile-height))
         (height (min org-timegrid--tile-height
                      (- org-timegrid--image-height y))))
    (format
     (concat "<svg width=\"%s\" height=\"%s\" viewBox=\"0 %s %s %s\" "
             "version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" "
             "xmlns:xlink=\"http://www.w3.org/1999/xlink\">%s%s</svg>")
     org-timegrid--tile-width height y org-timegrid--tile-width height
     org-timegrid--static-inner (or fragment ""))))

(defun org-timegrid--tile-image-map (tile)
  "Return the production image map clipped and translated for TILE."
  (let* ((top (* tile org-timegrid--tile-height))
         (bottom (min org-timegrid--image-height
                      (+ top org-timegrid--tile-height)))
         translated)
    (dolist (entry (org-timegrid--image-map))
      (pcase-let* ((`(,shape ,id ,properties) entry)
                   (`(rect . ((,left . ,y) . (,right . ,end))) shape))
        (when (and (< y bottom) (> end top))
          (push (list `(rect . ((,left . ,(max 0 (- y top)))
                                . (,right . ,(- (min end bottom) top))))
                      id properties)
                translated))))
    (nreverse translated)))

(defun org-timegrid--make-tile-image (tile &optional fragment)
  "Create TILE's image, adding optional dynamic SVG FRAGMENT."
  (let ((map (org-timegrid--tile-image-map tile))
        ;; The current-time marker is calendar chrome, so paint it after
        ;; selection and preview fragments instead of letting those cover it.
        (fragment (concat fragment
                          (and (memq tile org-timegrid--clock-tiles)
                               org-timegrid--clock-fragment))))
    (if map
        (create-image (org-timegrid--tile-xml tile fragment) 'svg t
                      :ascent 90 :map map :original-map map)
      (create-image (org-timegrid--tile-xml tile fragment) 'svg t
                    :ascent 90))))

(defun org-timegrid--cache-static-tiles (&optional excluded-id)
  "Cache hour tiles, omitting EXCLUDED-ID from their static layer."
  (let ((org-timegrid--static-render t)
        (org-timegrid--render-excluded-id excluded-id)
        (org-timegrid--state
         (copy-org-timegrid--calendar-state org-timegrid--state)))
    (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil
          (org-timegrid--calendar-state-cursor-visible org-timegrid--state) nil)
    (let ((svg (org-timegrid--svg)))
      (setq-local org-timegrid--static-inner (org-timegrid--svg-inner-xml svg)
                  org-timegrid--tile-width (dom-attr svg 'width)
                  org-timegrid--tile-height
                  (ceiling (* 60 org-timegrid-pixels-per-minute))
                  org-timegrid--tile-count
                  (ceiling (/ (float org-timegrid--image-height)
                              (ceiling (* 60 org-timegrid-pixels-per-minute))))
                  org-timegrid--base-excluded-id excluded-id)))
  (org-timegrid--update-clock-fragment)
  (setq-local org-timegrid--static-images
              (make-vector org-timegrid--tile-count nil))
  (dotimes (tile org-timegrid--tile-count)
    (aset org-timegrid--static-images tile
          (org-timegrid--make-tile-image tile))))

(defun org-timegrid--dynamic-blocks ()
  "Return laid-out blocks belonging to the current dynamic layer."
  (let* ((preview (org-timegrid--calendar-state-preview org-timegrid--state))
         (selected (and (null preview) (org-timegrid--selected-id)))
         (blocks (org-timegrid--effective-blocks)))
    (when (or preview selected)
      (cl-loop for day from 0 below 7
               append
               (cl-remove-if-not
                (lambda (block)
                  (and (not (org-timegrid-block-boundary-edge block))
                       (if preview
                           (org-timegrid-block-preview block)
                         (equal (org-timegrid-block-id block) selected))))
                (org-timegrid--layout-day blocks day))))))

(defun org-timegrid--geometry-tiles (geometry &optional margin)
  "Return tiles intersected by GEOMETRY and its visual MARGIN."
  (let* ((margin (or margin 0))
         (top (max 0 (- (plist-get geometry :y) margin)))
         (bottom (min org-timegrid--image-height
                      (+ (plist-get geometry :y)
                         (plist-get geometry :height) margin)))
         (first (max 0 (floor top org-timegrid--tile-height)))
         (last (min (1- org-timegrid--tile-count)
                    (floor (- bottom 0.001)
                           org-timegrid--tile-height))))
    (number-sequence first last)))

(defun org-timegrid--dynamic-fragment ()
  "Return dynamic SVG XML followed by the tiles it intersects."
  (let* ((svg (svg-create org-timegrid--tile-width org-timegrid--image-height
                          :stroke-width 0))
         (palette (org-timegrid--palette))
         (font-family (let ((family (face-attribute 'default :family nil t)))
                        (if (stringp family) family "monospace")))
         (start-minute (* 60 org-timegrid-start-hour))
         (column-width (/ (- org-timegrid--tile-width
                             org-timegrid--label-width)
                          7.0))
         (preview (org-timegrid--calendar-state-preview org-timegrid--state))
         (selected (and (null preview) (org-timegrid--selected-id)))
         geometry tiles)
    (dolist (block (org-timegrid--dynamic-blocks))
      (let ((item (org-timegrid--draw-block
                   svg block org-timegrid--image-height start-minute
                   org-timegrid-pixels-per-minute column-width
                   palette font-family)))
        (push item geometry)
        ;; Selected blocks have a two-pixel outline.  Include its full visual
        ;; bounds when it crosses an SVG tile edge.
        (dolist (tile (org-timegrid--geometry-tiles item 1))
          (cl-pushnew tile tiles))))
    (when (and (null preview) (org-timegrid--cursor-visible-p)
               (eq (org-timegrid--cursor-state-surface
                    (org-timegrid--cursor))
                   'grid)
               (null selected))
      (when-let ((rectangle (org-timegrid--cursor-rectangle
                             org-timegrid--geometry)))
        (svg-rectangle svg
                       (plist-get rectangle :x) (plist-get rectangle :y)
                       (plist-get rectangle :width) (plist-get rectangle :height)
                       :fill (plist-get palette :cursor)
                       :fill-opacity org-timegrid-cursor-opacity
                       :stroke (plist-get palette :cursor) :stroke-width 1
                       :rx org-timegrid-corner-radius)
        ;; SVG strokes are centered on their path, so the cursor extends half
        ;; a pixel beyond its geometric rectangle on every side.
        (dolist (tile (org-timegrid--geometry-tiles rectangle 0.5))
          (cl-pushnew tile tiles))))
    (cons (org-timegrid--svg-inner-xml svg) (sort tiles #'<))))

(defun org-timegrid--set-tile-image (tile image)
  "Display IMAGE at TILE's buffer marker."
  (let ((marker (aref org-timegrid--tile-markers tile))
        (inhibit-read-only t))
    (put-text-property marker (1+ marker) 'display image)))

(defun org-timegrid--render-dynamic (&optional redisplay-now)
  "Redraw only tiles touched by cursor selection or a drag preview."
  (let* ((preview (org-timegrid--calendar-state-preview org-timegrid--state))
         (excluded (and preview (org-timegrid--operation-replace-id preview))))
    (when (and (vectorp org-timegrid--tile-markers)
               (not (equal excluded org-timegrid--base-excluded-id)))
      (let* ((window (get-buffer-window (current-buffer) t))
             (scroll (and window
                          (org-timegrid--window-scroll-pixels window))))
        (org-timegrid--cache-static-tiles excluded)
        (org-timegrid--insert-tiles)
        (when window (org-timegrid--set-vscroll window scroll)))))
  (pcase-let* ((`(,fragment . ,new-tiles) (org-timegrid--dynamic-fragment))
               (changed (delete-dups
                         (append new-tiles org-timegrid--dynamic-tiles))))
    (dolist (tile changed)
      (org-timegrid--set-tile-image
       tile
       (if (memq tile new-tiles)
           (org-timegrid--make-tile-image tile fragment)
         (aref org-timegrid--static-images tile))))
    (setq-local org-timegrid--dynamic-tiles new-tiles)
    (set-buffer-modified-p nil)
    (when redisplay-now (redisplay t))))

(defun org-timegrid--insert-tiles ()
  "Replace the buffer with the cached hour tiles."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq-local org-timegrid--tile-markers
                (make-vector org-timegrid--tile-count nil))
    (dotimes (tile org-timegrid--tile-count)
      (let ((start (point)))
        (aset org-timegrid--tile-markers tile start)
        (insert (propertize " "
                            'org-timegrid-tile tile
                            'occs-svg-image t
                            'help-echo
                            "Drag empty time to create; drag blocks to move or resize"
                            'display (aref org-timegrid--static-images tile)))
        (insert "\n")))
    (setq-local org-timegrid--dynamic-tiles nil)
    (set-buffer-modified-p nil)))

(defun org-timegrid--all-day-less-p (left right)
  "Return non-nil when all-day block LEFT sorts before RIGHT."
  (let* ((ls (+ (* (org-timegrid-block-day left) 1440) (org-timegrid-block-start left)))
         (rs (+ (* (org-timegrid-block-day right) 1440) (org-timegrid-block-start right)))
         (le (+ (* (org-timegrid-block-day left) 1440) (org-timegrid-block-end left)))
         (re (+ (* (org-timegrid-block-day right) 1440) (org-timegrid-block-end right)))
         (lt (or (org-timegrid-block-title left) ""))
         (rt (or (org-timegrid-block-title right) "")))
    (cond ((/= ls rs) (< ls rs))
          ((/= (- le ls) (- re rs)) (> (- le ls) (- re rs)))
          ((not (equal lt rt)) (string-lessp lt rt))
          (t (string-lessp (prin1-to-string (org-timegrid-block-id left))
                           (prin1-to-string (org-timegrid-block-id right)))))))

(defun org-timegrid--all-day-layout ()
  "Return visible all-day blocks annotated with stable rail lanes.
The ordering favours earlier and longer spans, then title and identity."
  (let* ((week-end (* 7 1440))
         (preview (org-timegrid--calendar-state-preview org-timegrid--state))
         (preview-block (and preview (org-timegrid--operation-block preview)))
         (replace-id (and preview
                          (org-timegrid--operation-replace-id preview)))
         (source
          (append
           (if replace-id
               (cl-remove replace-id (org-timegrid--all-day-blocks)
                          :key #'org-timegrid-block-id
                          :test #'equal)
             (org-timegrid--all-day-blocks))
           (and preview-block
                (org-timegrid-block-all-day-p preview-block)
                (list preview-block))))
         (blocks (sort (mapcar #'copy-org-timegrid-block source)
                       #'org-timegrid--all-day-less-p))
         lane-ends result)
    (dolist (block blocks (nreverse result))
      (let* ((real-start (+ (* (org-timegrid-block-day block) 1440)
                            (org-timegrid-block-start block)))
             (real-end (+ (* (org-timegrid-block-day block) 1440)
                          (org-timegrid-block-end block)))
             (start (max 0 real-start))
             (end (min week-end real-end))
             (lane 0))
        (while (and (< lane (length lane-ends))
                    (> (nth lane lane-ends) start))
          (setq lane (1+ lane)))
        (if (= lane (length lane-ends))
            (setq lane-ends (append lane-ends (list end)))
          (setf (nth lane lane-ends) end))
        (setf (org-timegrid-block-rail-start block) start
              (org-timegrid-block-rail-end block) end
              (org-timegrid-block-continues-left block) (< real-start 0)
              (org-timegrid-block-continues-right block) (> real-end week-end)
              (org-timegrid-block-rail-lane block) lane)
        (push block result)))))

(defun org-timegrid--draw-all-day-block
    (svg block left-offset column-width top palette font-family)
  "Draw one laid-out all-day BLOCK into SVG rail at TOP."
  (let* ((start-day (/ (org-timegrid-block-rail-start block) 1440.0))
         (end-day (/ (org-timegrid-block-rail-end block) 1440.0))
         (x (+ left-offset org-timegrid--label-width (* start-day column-width) 2))
         (right (+ left-offset org-timegrid--label-width (* end-day column-width) -2))
         (y (+ top 2))
         (height (- org-timegrid-all-day-lane-height 4))
         (arrow (min 9 (/ (- right x) 3.0)))
         (leftp (org-timegrid-block-continues-left block))
         (rightp (org-timegrid-block-continues-right block))
         (fill (org-timegrid--color block palette))
         (selected (equal (org-timegrid-block-id block) (org-timegrid--selected-id)))
         (radius (min (max 0 org-timegrid-corner-radius)
                      (/ height 2.0)))
         (mid (+ y (/ height 2.0)))
         ;; A single silhouette keeps the selection stroke on the outside of
         ;; continuation arrowheads.  Drawing the body and arrows separately
         ;; both exposed antialiasing seams and made the selected rectangle
         ;; cross through the arrow.
         (path
          (concat
           (if leftp
               (format "M %g %g L %g %g" x mid (+ x arrow) y)
             (format "M %g %g" (+ x radius) y))
           (if rightp
               (format " L %g %g L %g %g L %g %g"
                       (- right arrow) y right mid
                       (- right arrow) (+ y height))
             (format " L %g %g Q %g %g %g %g L %g %g Q %g %g %g %g"
                     (- right radius) y
                     right y right (+ y radius)
                     right (- (+ y height) radius)
                     right (+ y height) (- right radius) (+ y height)))
           (if leftp
               (format " L %g %g L %g %g Z" (+ x arrow) (+ y height) x mid)
             (format " L %g %g Q %g %g %g %g L %g %g Q %g %g %g %g Z"
                     (+ x radius) (+ y height)
                     x (+ y height) x (- (+ y height) radius)
                     x (+ y radius)
                     x y (+ x radius) y)))))
    (svg-node svg 'path :d path :fill fill
              :stroke (if selected
                          (plist-get palette :blue)
                        (plist-get palette :background))
              :stroke-width (if selected 2 1)
              :stroke-linejoin "round")
    (let* ((text-x (+ x (if leftp arrow 0) 9))
           (available (max 1 (- right text-x 5)))
           (characters (max 1 (floor (/ available 6.2))))
           (title (truncate-string-to-width
                   (org-timegrid-block-title block) characters nil nil "…")))
      (svg-text svg title :x text-x :y (+ y 13)
                :font-size 10 :font-weight "600" :font-family font-family
                :fill (plist-get palette :foreground)))
    (list :id (org-timegrid-block-id block) :lane (org-timegrid-block-rail-lane block)
          :x x :y y :width (- right x) :height height
          :allow-left (not leftp) :allow-right (not rightp))))

(defun org-timegrid--rail-edge-at (geometry x)
  "Return resize endpoint for rail GEOMETRY at horizontal pixel X.
The operation model calls the start and end endpoints `top' and `bottom';
the rail presents those same endpoints as its left and right edges."
  (let* ((left (plist-get geometry :x))
         (right (+ left (plist-get geometry :width)))
         (edge (min org-timegrid-edge-pixels
                    (max 1 (/ (plist-get geometry :width) 2.0)))))
    (cond ((and (plist-get geometry :allow-left)
                (<= left x (+ left edge)))
           'top)
          ((and (plist-get geometry :allow-right)
                (<= (- right edge) x right))
           'bottom))))

(defun org-timegrid--header-image-map ()
  "Return move and horizontal-resize hotspots for all-day blocks."
  (let (edges bodies)
    (dolist (geometry org-timegrid--header-geometry)
      (let* ((x (round (plist-get geometry :x)))
             (y (round (plist-get geometry :y)))
             (right (round (+ (plist-get geometry :x)
                              (plist-get geometry :width))))
             (bottom (round (+ (plist-get geometry :y)
                               (plist-get geometry :height))))
             (edge (min org-timegrid-edge-pixels
                        (max 1 (floor (/ (- right x) 2.0))))))
        (when (plist-get geometry :allow-left)
          (push (list `(rect . ((,x . ,y) . (,(+ x edge) . ,bottom)))
                      'calendar-rail-resize
                      '(pointer hdrag help-echo "Drag to change the first day"))
                edges))
        (when (plist-get geometry :allow-right)
          (push (list `(rect . ((,(- right edge) . ,y) . (,right . ,bottom)))
                      'calendar-rail-resize
                      '(pointer hdrag help-echo "Drag to change the last day"))
                edges))
        (push (list `(rect . ((,x . ,y) . (,right . ,bottom)))
                    'calendar-rail-block
                    '(pointer hand help-echo "Drag to move; double-click to open"))
              bodies)))
    (append edges bodies)))

(defun org-timegrid--header-month-parts (week-start)
  "Return the visible month title for WEEK-START as (PRIMARY SECONDARY).
SECONDARY is the final year and is drawn with lighter weight.  PRIMARY
includes both month names when the visible week crosses a boundary."
  (let* ((first (calendar-gregorian-from-absolute week-start))
         (last (calendar-gregorian-from-absolute (+ week-start 6)))
         (first-month (calendar-month-name (nth 0 first)))
         (last-month (calendar-month-name (nth 0 last)))
         (first-year (nth 2 first))
         (last-year (nth 2 last)))
    (cond
     ((and (= (nth 0 first) (nth 0 last)) (= first-year last-year))
      (list first-month (number-to-string first-year)))
     ((= first-year last-year)
      (list (format "%s–%s" first-month last-month)
            (number-to-string first-year)))
     (t
      (list (format "%s %d–%s" first-month first-year last-month)
            (number-to-string last-year))))))

(defun org-timegrid--iso-week-format (absolute-date format)
  "Format ABSOLUTE-DATE as an ISO week using time FORMAT."
  (pcase-let ((`(,month ,day ,year)
               (calendar-gregorian-from-absolute absolute-date)))
    (format-time-string format (encode-time 0 0 12 day month year))))

(defun org-timegrid--week-label (absolute-date)
  "Return the ISO week label that best represents the visible week.
ABSOLUTE-DATE is the first displayed day.  Use its midpoint because a
Sunday-starting calendar begins one day before the corresponding ISO week."
  (org-timegrid--iso-week-format (+ absolute-date 3) "W%V"))

(defun org-timegrid--week-current-p (week-start today)
  "Return non-nil when WEEK-START's displayed ISO week contains TODAY."
  (equal (org-timegrid--iso-week-format (+ week-start 3) "%G-%V")
         (org-timegrid--iso-week-format today "%G-%V")))

(defun org-timegrid--header ()
  "Return a pixel-aligned SVG header for the calendar."
  (org-timegrid--ensure-state)
  (let* ((window (get-buffer-window (current-buffer) t))
         (left-offset (if window (or (car (window-fringes window)) 0) 0))
         (canvas-width
          (max 560 (org-timegrid--window-width)))
         (width (+ left-offset canvas-width))
         (all-day (org-timegrid--all-day-layout))
         (highest-lane (if all-day
                           (apply #'max (mapcar (lambda (block)
                                                 (org-timegrid-block-rail-lane block))
                                               all-day))
                         -1))
         (event-rows (min org-timegrid-all-day-max-lanes
                          (1+ highest-lane)))
         ;; One final row is intentionally empty: it is the future keyboard
         ;; cursor/creation lane and keeps the rail visually discoverable.
         (rail-rows (1+ event-rows))
         (height (+ org-timegrid--rail-top
                    (* rail-rows org-timegrid-all-day-lane-height)))
         (column-width (/ (- canvas-width
                             org-timegrid--label-width)
                          7.0))
         (palette (org-timegrid--palette))
         (font-family (let ((family (face-attribute 'default :family nil t)))
                        (if (stringp family) family "monospace")))
         (week-start (org-timegrid--calendar-state-week-start org-timegrid--state))
         (today (calendar-absolute-from-gregorian (calendar-current-date)))
         (month-parts (org-timegrid--header-month-parts week-start))
         (month-title (car month-parts))
         (year-title (cadr month-parts))
         (title-x (+ left-offset 8))
         (svg (svg-create width height :stroke-width 0))
         geometry)
    (svg-rectangle svg 0 0 width height
                   :fill (plist-get palette :time-background))
    (svg-text svg month-title :x title-x :y 34
              :font-size 22 :font-weight "700"
              :font-family font-family :fill (plist-get palette :foreground))
    (svg-text svg year-title
              :x (+ title-x (* 13.4 (string-width month-title)) 8) :y 34
              :font-size 22 :font-weight "300"
              :font-family font-family
              :fill (plist-get palette :secondary-text))
    (svg-text svg (org-timegrid--week-label week-start)
              :x (+ left-offset 7)
              :y (+ org-timegrid--header-title-height 20)
              :font-size 10 :font-family font-family
              :fill (plist-get palette
                               (if (org-timegrid--week-current-p week-start today)
                                   :red
                                 :secondary-text)))
    (dotimes (day 7)
      (let* ((absolute (+ week-start day))
             (date (calendar-gregorian-from-absolute absolute))
             (day-name (calendar-day-name date t))
             (day-number (number-to-string (nth 1 date)))
             (x (+ left-offset
                   org-timegrid--label-width
                   (* day column-width)))
             (center (+ x (/ column-width 2.0)))
             (baseline (+ org-timegrid--header-title-height 20)))
        (if (= absolute today)
            (let* ((name-width (* 6.2 (string-width day-name)))
                   (circle-radius 10)
                   (gap 5)
                   (group-width (+ name-width gap (* 2 circle-radius)))
                   (name-x (- center (/ group-width 2.0)))
                   (number-x (+ name-x name-width gap circle-radius)))
              (svg-text svg day-name :x name-x :y baseline
                        :font-size 11 :font-weight "500"
                        :font-family font-family
                        :fill (plist-get palette :foreground))
              (svg-circle svg number-x (- baseline 4) circle-radius
                          :fill (plist-get palette :red))
              (svg-text svg day-number :x number-x :y baseline
                        :font-size 11 :font-weight "700"
                        :font-family font-family :text-anchor "middle"
                        :fill "#ffffff"))
          (svg-text svg (format "%s %s" day-name day-number)
                    :x center :y baseline :font-size 11 :font-weight "500"
                    :font-family font-family :text-anchor "middle"
                    :fill (plist-get palette :foreground)))))
    (svg-line svg 0 (1- org-timegrid--rail-top)
              width (1- org-timegrid--rail-top)
              :stroke (plist-get palette :grid) :stroke-width 1)
    (svg-text svg "all-day" :x (+ left-offset 5)
              :y (+ org-timegrid--rail-top 15)
              :font-size 9 :font-family font-family
              :fill (plist-get palette :secondary-text))
    (dotimes (day 7)
      (let ((x (+ left-offset org-timegrid--label-width (* day column-width))))
        (svg-line svg x org-timegrid--rail-top x height
                  :stroke (plist-get palette :grid) :stroke-width 1)))
    (dolist (block all-day)
      (when (< (org-timegrid-block-rail-lane block) org-timegrid-all-day-max-lanes)
        (push (org-timegrid--draw-all-day-block
               svg block left-offset column-width
               (+ org-timegrid--rail-top
                  (* (org-timegrid-block-rail-lane block)
                     org-timegrid-all-day-lane-height))
               palette font-family)
              geometry)))
    (when-let* (((org-timegrid--cursor-visible-p))
                (cursor (org-timegrid--cursor))
                ((eq (org-timegrid--cursor-state-surface cursor) 'rail))
                ((null (org-timegrid--selected-id))))
      (let* ((cursor-height (* org-timegrid-slot-minutes
                               org-timegrid-pixels-per-minute))
             (x (+ left-offset org-timegrid--label-width
                   (* (org-timegrid--cursor-state-day cursor) column-width) 1))
             (y (+ org-timegrid--rail-top
                   (* (org-timegrid--cursor-state-lane cursor)
                      org-timegrid-all-day-lane-height)
                   (/ (- org-timegrid-all-day-lane-height cursor-height) 2.0))))
        (svg-rectangle svg x y (- column-width 2)
                       cursor-height
                       :fill (plist-get palette :cursor)
                       :fill-opacity org-timegrid-cursor-opacity
                       :stroke (plist-get palette :cursor)
                       :stroke-width 1
                       :rx org-timegrid-corner-radius)))
    (dotimes (day 7)
      (let ((hidden
             (seq-count
              (lambda (block)
                (and (>= (org-timegrid-block-rail-lane block)
                         org-timegrid-all-day-max-lanes)
                     (< (* day 1440) (org-timegrid-block-rail-end block))
                     (< (org-timegrid-block-rail-start block) (* (1+ day) 1440))))
              all-day)))
        (when (> hidden 0)
          (svg-text svg (format "+%d more" hidden)
                    :x (+ left-offset org-timegrid--label-width
                          (* day column-width) 7)
                    :y (+ org-timegrid--rail-top
                          (* event-rows org-timegrid-all-day-lane-height) 15)
                    :font-size 9 :font-family font-family
                    :fill (plist-get palette :secondary-text)))))
    (svg-line svg 0 (1- height) width (1- height)
              :stroke (plist-get palette :grid) :stroke-width 1)
    (setq-local org-timegrid--header-geometry geometry)
    (let ((map (org-timegrid--header-image-map)))
      (propertize " "
                ;; Header lines still use text baseline metrics for images.
                ;; With zero ascent Emacs reserves a full text ascent above
                ;; the SVG, which appears as an unexplained blank strip.
                'display (svg-image svg :ascent 100 :scale 1
                                    :map map :original-map map)
                'keymap org-timegrid--header-map
                'help-echo "Click to select an all-day cell or event"))))

(defun org-timegrid--edge-height (geometry)
  "Return the pixel resize-zone height for GEOMETRY."
  (min org-timegrid-edge-pixels
       (max 1 (/ (- (plist-get geometry :height) 2) 2.0))))

(defun org-timegrid--edge-at (geometry y)
  "Return `top', `bottom', or nil for the resize zone at pixel Y in GEOMETRY.
A zone reaches `org-timegrid--edge-height' pixels into the block and
`org-timegrid-edge-slop' pixels outside it, which is exactly the
hotspot geometry built by `org-timegrid--image-map'.  Slop must not
extend inwards: on a fifteen-minute block the two zones would meet and
leave no central move target."
  (or (plist-get geometry :boundary-edge)
      (let* ((edge-height (org-timegrid--edge-height geometry))
             (slop org-timegrid-edge-slop)
             (top (plist-get geometry :y))
             (bottom (+ top (plist-get geometry :height)))
             (in-top (and (>= y (- top slop)) (<= y (+ top edge-height))))
             (in-bottom (and (<= y (+ bottom slop))
                             (>= y (- bottom edge-height)))))
        (cond
         ((and (plist-get geometry :allow-top) in-top
               (or (not (plist-get geometry :allow-bottom))
                   (not in-bottom)
                   (<= (abs (- y top)) (abs (- y bottom)))))
          'top)
         ((and (plist-get geometry :allow-bottom) in-bottom)
          'bottom)))))

(defun org-timegrid--image-map ()
  "Return pixel hotspots for block movement and edge resizing."
  (let (edges bodies)
    (dolist (geometry org-timegrid--geometry)
      (unless (plist-get geometry :preview)
        (let* ((x (round (plist-get geometry :x)))
               (y (round (plist-get geometry :y)))
               (right (round (+ (plist-get geometry :x)
                                (plist-get geometry :width))))
               (bottom (round (+ (plist-get geometry :y)
                                 (plist-get geometry :height))))
               (edge (max 1 (round
                             (org-timegrid--edge-height
                              geometry))))
               (slop org-timegrid-edge-slop)
               (boundary-edge (plist-get geometry :boundary-edge)))
          (cond
           (boundary-edge
            (push (list `(rect . ((,x . ,y) . (,right . ,bottom)))
                        'calendar-resize
                        `(pointer nhdrag
                                  help-echo ,(if (eq boundary-edge 'top)
                                                 "Drag into this day to change the start time"
                                               "Drag into this day to change the end time")))
                  edges))
           (t
            (when (plist-get geometry :allow-top)
              (push (list `(rect . ((,x . ,(max 0 (- y slop)))
                                    . (,right . ,(+ y edge))))
                          'calendar-resize
                          '(pointer nhdrag help-echo "Drag to change the start time"))
                    edges))
            (when (plist-get geometry :allow-bottom)
              (push (list `(rect . ((,x . ,(- bottom edge))
                                    . (,right . ,(+ bottom slop))))
                          'calendar-resize
                          '(pointer nhdrag help-echo "Drag to change the end time"))
                    edges))
            (push (list `(rect . ((,x . ,y) . (,right . ,bottom)))
                        'calendar-block
                        '(pointer hand help-echo "Drag to move; double-click to open"))
                  bodies))))))
    (append edges bodies)))

(defun org-timegrid--refresh (&optional preserve-scroll)
  "Rebuild cached tiles, preserving pixel scroll when requested."
  (org-timegrid--ensure-state)
  (org-timegrid--sync-fringe-background)
  (let* ((window (get-buffer-window (current-buffer) t))
         (vscroll (and preserve-scroll window
                       (let ((current (org-timegrid--window-scroll-pixels
                                       window)))
                         (if (and (zerop current)
                                (> org-timegrid--saved-vscroll 0))
                             org-timegrid--saved-vscroll
                           current))))
         (previewp (org-timegrid--calendar-state-preview org-timegrid--state)))
    (when (overlayp org-timegrid--pointer-overlay)
      (delete-overlay org-timegrid--pointer-overlay)
      (setq-local org-timegrid--pointer-overlay nil))
    (org-timegrid--cache-static-tiles
     (and previewp (org-timegrid--operation-replace-id previewp)))
    (org-timegrid--insert-tiles)
    (org-timegrid--render-dynamic)
    (unless (and previewp header-line-format)
      (setq-local header-line-format
                  (org-timegrid--header)))
    (setq-local org-timegrid--rendered-ui (org-timegrid--ui-snapshot))
    (setq-local org-timegrid--last-width
                (org-timegrid--window-width))
    (set-buffer-modified-p nil)
    (when window
      ;; Restore the viewport before redisplay.  Painting after the tile
      ;; insertion but before this restoration flashes the top of the
      ;; calendar whenever an edit reloads its backend data.
      (if vscroll
          (org-timegrid--set-vscroll window vscroll)
        (set-window-start window (point-min) t)
        (set-window-point window (point-min))
        (set-window-vscroll window 0 t))
      (redisplay t))))

(defun org-timegrid--window-scroll-pixels (window)
  "Return WINDOW's absolute pixel offset in the tiled calendar."
  (let* ((start (window-start window))
         (tile (or (get-text-property start 'org-timegrid-tile) 0)))
    (+ (* tile (or org-timegrid--tile-height 0))
       (window-vscroll window t))))

(defun org-timegrid--set-vscroll (window pixels)
  "Set WINDOW's pixel scroll to PIXELS and remember it."
  (let* ((pixels (max 0 (round pixels)))
         (height (max 1 (or org-timegrid--tile-height 1)))
         (tile (min (max 0 (1- (or org-timegrid--tile-count 1)))
                    (floor pixels height)))
         (within (% pixels height)))
    (when (and (vectorp org-timegrid--tile-markers)
               (< tile (length org-timegrid--tile-markers)))
      (let ((marker (aref org-timegrid--tile-markers tile)))
        (set-window-start window marker t)
        (set-window-point
         window
         (aref org-timegrid--tile-markers
               (min (1- (length org-timegrid--tile-markers))
                    (1+ tile))))))
    (set-window-vscroll window within t))
  (setq-local org-timegrid--saved-vscroll pixels))

(defun org-timegrid--restore-scroll (window)
  "Restore this calendar's saved pixel position in WINDOW."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (set-window-point window (point-min))
    (org-timegrid--set-vscroll window org-timegrid--saved-vscroll)))

(defun org-timegrid--schedule-scroll-restore (window)
  "Restore WINDOW after the buffer switch has finished redisplaying."
  (when (timerp org-timegrid--scroll-restore-timer)
    (cancel-timer org-timegrid--scroll-restore-timer))
  (let ((buffer (current-buffer)))
    (setq-local
     org-timegrid--scroll-restore-timer
     (run-at-time
      0.01 nil
      (lambda ()
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq-local org-timegrid--scroll-restore-timer nil)
            (org-timegrid--restore-scroll window))))))))

(defun org-timegrid--restore-frame-calendars (frame)
  "Restore calendars newly displayed in a window on FRAME."
  (dolist (window (window-list frame 'no-minibuffer))
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'org-timegrid-mode)
                 (> org-timegrid--saved-vscroll 0))
        (org-timegrid--schedule-scroll-restore window)))))

(defun org-timegrid--theme-changed (&rest _ignored)
  "Redraw live SVG calendars after Emacs changes theme faces."
  (when (timerp org-timegrid--theme-timer)
    (cancel-timer org-timegrid--theme-timer))
  (setq org-timegrid--theme-timer
        (run-at-time
         0 nil
         (lambda ()
           (setq org-timegrid--theme-timer nil)
           (dolist (buffer (buffer-list))
             (with-current-buffer buffer
               (when (derived-mode-p 'org-timegrid-mode)
                 (org-timegrid--refresh t))))))))

(defun org-timegrid--window-resized (window)
  "Schedule a redraw when prototype WINDOW changes pixel width."
  (let ((buffer (window-buffer window))
        (width (window-body-width window t)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (derived-mode-p 'org-timegrid-mode)
                   (or org-timegrid--stale
                       (/= width (or org-timegrid--last-width -1))))
          (setq-local org-timegrid--stale nil)
          (when (timerp org-timegrid--resize-timer)
            (cancel-timer org-timegrid--resize-timer))
          (setq-local
           org-timegrid--resize-timer
           (run-at-time
            0 nil
            (lambda ()
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (setq-local org-timegrid--resize-timer nil)
                  (org-timegrid--refresh t)))))))))))

(defun org-timegrid--cancel-timers ()
  "Cancel timers owned by the SVG prototype buffer."
  (dolist (timer (list org-timegrid--resize-timer
                       org-timegrid--clock-timer
                       org-timegrid--data-timer
                       org-timegrid--keyboard-edit-timer
                       org-timegrid--scroll-restore-timer))
    (when (timerp timer) (cancel-timer timer))))

(defun org-timegrid--clock-tick (buffer)
  "Redraw the current-time indicator in visible calendar BUFFER."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'org-timegrid-mode)
                 (null (org-timegrid--calendar-state-preview org-timegrid--state)))
        (let ((old-tiles org-timegrid--clock-tiles))
          (org-timegrid--update-clock-fragment)
          (dolist (tile (delete-dups
                         (append old-tiles org-timegrid--clock-tiles)))
            (aset org-timegrid--static-images tile
                  (org-timegrid--make-tile-image tile))
            (unless (memq tile org-timegrid--dynamic-tiles)
              (org-timegrid--set-tile-image
               tile (aref org-timegrid--static-images tile))))
          (when org-timegrid--dynamic-tiles
            (org-timegrid--render-dynamic))
          (redisplay t))))))

(defun org-timegrid--data-tick (buffer)
  "Reload visible calendar BUFFER, or mark it stale while hidden."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'org-timegrid-mode)
        (if (get-buffer-window buffer t)
            (org-timegrid--refresh-data)
          (setq-local org-timegrid--stale t))))))

(defun org-timegrid--position-image-xy (position)
  "Return stable full-calendar pixel coordinates for mouse POSITION.
Use window-relative X so crossing image-map hotspots and day columns cannot
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
      (cons (or (car-safe window-xy) (car-safe object-xy))
            (+ (* (or tile 0) (or org-timegrid--tile-height 0))
               (or (cdr-safe object-xy) (cdr-safe window-xy)))))))

(defun org-timegrid--target (position)
  "Return calendar metadata at mouse POSITION in the SVG image."
  (let* ((xy (org-timegrid--position-image-xy position))
         (x (and xy (car xy)))
         (y (and xy (cdr xy)))
         (width (org-timegrid--window-width))
         (column-width (/ (- width org-timegrid--label-width)
                          7.0))
         (start-minute (* 60 org-timegrid-start-hour)))
    (when (and (numberp x) (numberp y)
               (>= x org-timegrid--label-width)
               (< x width) (>= y 0)
               (< y org-timegrid--image-height))
      (let* ((day (min 6 (floor (/ (- x org-timegrid--label-width)
                                    column-width))))
             (minute (+ start-minute
                        (* org-timegrid-slot-minutes
                           (floor (/ (max 0 (- y org-timegrid--grid-top-inset))
                                     (* org-timegrid-pixels-per-minute
                                        org-timegrid-slot-minutes))))))
             (geometry
              (cl-find-if (lambda (item)
                            (let ((slop
                                   org-timegrid-edge-slop))
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
              :day day :minute minute :edge edge)))))

(defun org-timegrid--set-preview (proposal)
  "Display PROPOSAL without committing it."
  (let* ((old (org-timegrid--calendar-state-preview org-timegrid--state))
         (preview (and proposal (not (org-timegrid--operation-error proposal)) proposal))
         (old-all-day (and old (org-timegrid-block-all-day-p
                                (org-timegrid--operation-block old))))
         (new-all-day (and preview (org-timegrid-block-all-day-p
                                    (org-timegrid--operation-block preview)))))
    (unless (equal preview (org-timegrid--calendar-state-preview org-timegrid--state))
      (setf (org-timegrid--calendar-state-preview org-timegrid--state) preview)
      (if (eq old-all-day new-all-day)
          (if new-all-day
              (org-timegrid--render-header-dynamic)
            (org-timegrid--render-dynamic t))
        ;; A cross-surface preview removes the source from one canvas and
        ;; paints it on the other, so both dynamic layers must be refreshed.
        (org-timegrid--render-header-dynamic)
        (org-timegrid--render-dynamic t)))))

(defun org-timegrid--clear-preview ()
  "Remove a pending SVG preview."
  (when (org-timegrid--calendar-state-preview org-timegrid--state)
    (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil)
    (org-timegrid--refresh t)))

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

(defun org-timegrid--offer-entry-deletion (event)
  "Offer to delete EVENT's whole entry now that its time is gone.
Removing a block usually means the plan is over, not that the entry
should linger untimed, so the question is asked once here rather than
requiring a trip to the file.  Declining keeps the timestamp removed."
  (when-let* ((deleter (org-timegrid-backend-delete-entry-function
                        org-timegrid--backend))
              ((functionp deleter))
              ((y-or-n-p (format "Delete entry \"%s\" too? "
                                 (org-timegrid-event-title event)))))
    (funcall deleter event)
    (org-timegrid--refresh-data)))

(defun org-timegrid-remove-selected (&optional keep-entry)
  "Remove the selected block from its calendar source.
KEEP-ENTRY skips the offer to delete the entry itself, which is what a
cut wants: the entry has to survive for the yank to copy it."
  (interactive)
  (let ((id (org-timegrid--selected-id)))
    (if (null id)
        (message "No block selected")
      (let* ((block (org-timegrid--block id))
             (event (and block (org-timegrid-block-event block)))
             (deleter (org-timegrid-backend-delete-function
                       org-timegrid--backend)))
        (unless (and event (functionp deleter))
          (user-error "This backend cannot remove calendar entries"))
        (funcall deleter event)
        (org-timegrid--refresh-data)
        (unless keep-entry
          (org-timegrid--offer-entry-deletion event))))))

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
  "Call UPDATER with an explicit TIME-KIND when its contract supports it."
  (cond
   ((org-timegrid--accepts-arguments-p updater 5)
    (funcall updater event start end title time-kind))
   ((or title (org-timegrid--accepts-arguments-p updater 4))
    (funcall updater event start end title))
   (t (funcall updater event start end))))

(defun org-timegrid--backend-create (title block &optional source-event target)
  "Ask the active backend to create TITLE using BLOCK's range."
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
    (org-timegrid--refresh-data)))

(defun org-timegrid--read-entry ()
  "Read a title and optional existing record for a new block."
  (let ((reader (and (fboundp 'org-timegrid-backend-read-entry-function)
                     org-timegrid--backend
                     (org-timegrid-backend-read-entry-function
                      org-timegrid--backend))))
    (if (functionp reader)
        (funcall reader)
      (cons (org-timegrid--read-title) nil))))

(defun org-timegrid--backend-update (block)
  "Ask the active backend to apply BLOCK's new range."
  (let* ((updater (org-timegrid-backend-update-function
                   org-timegrid--backend))
         (event (org-timegrid-block-event block))
         (range (org-timegrid--block-absolute-range block)))
    (unless (and event (functionp updater))
      (user-error "This backend cannot move or resize calendar entries"))
    (condition-case error-data
        (progn
          (org-timegrid--call-update
           updater event (car range) (cdr range) nil
           (org-timegrid-block-time-kind block))
          (org-timegrid--refresh-data))
      (error
       (org-timegrid--refresh-data)
       (signal (car error-data) (cdr error-data))))))

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
          (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil)
          (org-timegrid--refresh t))
        (unless (string-empty-p (car entry))
          (org-timegrid--backend-create
           (car entry) block nil (cdr entry)))))
     ((memq kind '(duplicate-entry add-occurrence))
      (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil)
      (let ((source (org-timegrid--block (org-timegrid-block-id block))))
        (org-timegrid--backend-create
         (org-timegrid-block-title source) block
         (org-timegrid-block-event source)
         (and (eq kind 'add-occurrence)
              (org-timegrid-event-source
               (org-timegrid-block-event source))))))
     ((memq kind '(move resize))
      (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil
            (org-timegrid-block-preview block) nil)
      (org-timegrid--backend-update block))
     (t (org-timegrid--clear-preview)))))

(defun org-timegrid-click (event)
  "Put the cursor where SVG mouse EVENT landed.
Clicking a block moves the cursor to that block's own first slot, which is
what selects it; clicking empty space moves the cursor to that slot and so
selects nothing.  The mouse and the keyboard drive one shared cursor."
  (interactive "@e")
  (let* ((target (org-timegrid--target (event-start event)))
         (block (org-timegrid--block (plist-get target :block-id))))
    (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
    (if block
        (org-timegrid--goto-block block)
      (when (and (plist-get target :day) (plist-get target :minute))
        (org-timegrid--set-cursor (plist-get target :day)
                                  (plist-get target :minute))
        (org-timegrid--cursor-moved)))))

(defun org-timegrid--header-target (position)
  "Return all-day rail metadata at header-line mouse POSITION."
  (let* ((xy (or (posn-object-x-y position) (posn-x-y position)))
         (x (car-safe xy))
         (y (cdr-safe xy))
         (window (posn-window position))
         (left-offset (if (window-live-p window)
                          (or (car (window-fringes window)) 0)
                        0))
         (canvas-width (org-timegrid--window-width))
         (column-width (/ (- canvas-width org-timegrid--label-width) 7.0)))
    (when (and (numberp x) (numberp y) (>= y org-timegrid--rail-top)
               (>= x (+ left-offset org-timegrid--label-width))
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
              :day (min 6 (max 0 (floor
                                  (/ (- x left-offset
                                        org-timegrid--label-width)
                                     column-width))))
              :minute 0
              :lane (max 0 (floor (/ (- y org-timegrid--rail-top)
                                     org-timegrid-all-day-lane-height))))))))

(defun org-timegrid--mouse-position-xy (position)
  "Return comparable POSITION coordinates across the rail and time grid."
  (let ((xy (or (posn-x-y position) (posn-object-x-y position))))
    (and xy (list (posn-area position) (car xy) (cdr xy)))))

(defun org-timegrid--mouse-target (position)
  "Return calendar metadata for POSITION on either mouse surface."
  (if (eq (posn-area position) 'header-line)
      (org-timegrid--header-target position)
    (org-timegrid--target position)))

(defun org-timegrid-header-click (event)
  "Move the shared calendar cursor to all-day rail mouse EVENT."
  (interactive "@e")
  (let* ((position (event-start event))
         (target (org-timegrid--header-target position)))
    (if (null target)
        (message "Click inside an all-day cell")
      (let ((day (plist-get target :day))
            (lane (plist-get target :lane))
            (id (plist-get target :id)))
        (org-timegrid--set-all-day-cursor day lane)
        (when id
          (setf (org-timegrid--calendar-state-selected-id org-timegrid--state)
                id))
        (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state)
              t)
        (org-timegrid--cursor-moved)))))

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
                     "New all-day block" 'blue nil 'all-day)))
        (setf (org-timegrid-block-preview block) t)
        (org-timegrid--operation-create :kind 'create :block block)))))

(defun org-timegrid--header-position-xy (position)
  "Return the SVG-local coordinates of header-line POSITION."
  (or (posn-object-x-y position) (posn-x-y position)))

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
              (setq dragged t
                    end-target target)
              (if target
                  (org-timegrid--set-preview
                   (funcall proposal-function origin end-target))
                (org-timegrid--clear-preview)))))
         ((memq basic '(mouse-1 drag-mouse-1))
          ;; Commit only the cell under the actual release.  In particular,
          ;; do not retain a destructive cross-surface hover after the mouse
          ;; has left the calendar.
          (setq end-target (funcall target-function (event-end next))
                finished t))
         ((eq basic 'switch-frame))
         (t
          (push next unread-command-events)
          (setq finished 'cancelled)))))
    (cond
     ((eq finished 'cancelled)
      (org-timegrid--clear-preview))
     (dragged
      (org-timegrid--apply (funcall proposal-function origin end-target)))
     (t
      (funcall click-function origin-position)))))

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
      (message "Press inside an all-day cell"))
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
       #'org-timegrid--header-target
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

(defun org-timegrid-visit (event)
  "Visit the source event under double-click mouse EVENT."
  (interactive "@e")
  (let* ((target (org-timegrid--target (event-start event)))
         (block (org-timegrid--block
                 (plist-get target :block-id)))
         (calendar-event (org-timegrid-block-event block))
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
  "Track a complete create, move, duplicate, occurrence, or resize gesture."
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
          (let* ((maximum
                  (max 0 (- org-timegrid--image-height
                            (window-body-height window t))))
                 (next
                  (max 0 (min maximum
                              (+ (org-timegrid--window-scroll-pixels window)
                                 pixels)))))
            (org-timegrid--set-vscroll window next)))))))

(defun org-timegrid--event-window (event)
  "Return the live calendar window associated with mouse EVENT."
  (let ((window (posn-window (event-start event))))
    (and (window-live-p window)
         (with-current-buffer (window-buffer window)
           (derived-mode-p 'org-timegrid-mode))
         window)))

;;; Keyboard cursor

(defun org-timegrid--ui-snapshot ()
  "Return the small model fragment that controls dynamic painting."
  (list :surface (and (org-timegrid--cursor)
                      (org-timegrid--cursor-state-surface
                       (org-timegrid--cursor)))
        :cursor (and (org-timegrid--cursor)
                     (copy-org-timegrid--cursor-state
                      (org-timegrid--cursor)))
        :selected-id (org-timegrid--selected-id)
        :visible (and (org-timegrid--cursor-visible-p) t)))

(defun org-timegrid--render-header-dynamic ()
  "Repaint the small sticky surface without touching time-grid tiles."
  (setq-local header-line-format (org-timegrid--header))
  (when (get-buffer-window (current-buffer) t)
    (force-mode-line-update t)
    (redisplay t)))

(defun org-timegrid--render-ui-change ()
  "Paint the minimal damage between the rendered and current UI state."
  (let* ((old org-timegrid--rendered-ui)
         (new (org-timegrid--ui-snapshot))
         (old-surface (plist-get old :surface))
         (new-surface (plist-get new :surface)))
    (cond
     ((not org-timegrid--static-inner)
      (org-timegrid--refresh t))
     ((eq new-surface 'rail)
      ;; Same-surface rail motion changes only the header.  Crossing from the
      ;; grid must additionally restore any body tiles that held its cursor.
      (unless (eq old-surface 'rail)
        (org-timegrid--render-dynamic))
      (org-timegrid--render-header-dynamic))
     ((eq old-surface 'rail)
      ;; Clear the old rail cursor, then draw the new grid dynamic layer.
      (org-timegrid--render-header-dynamic)
      (org-timegrid--render-dynamic t))
     (t
      (org-timegrid--render-dynamic t)))
    (setq-local org-timegrid--rendered-ui new)))

(defun org-timegrid--cursor-moved ()
  "Render a cursor/selection model change and keep it visible."
  (org-timegrid--render-ui-change)
  (org-timegrid--scroll-cursor-into-view))

(defun org-timegrid--scroll-cursor-into-view ()
  "Scroll the minimum amount that makes the whole cursor slot visible."
  (when-let* ((cursor (org-timegrid--cursor))
              (window (get-buffer-window (current-buffer) t)))
    (let* ((scale org-timegrid-pixels-per-minute)
           (start-minute (* 60 org-timegrid-start-hour))
           (top (+ org-timegrid--grid-top-inset
                   (* (- (org-timegrid--cursor-state-minute cursor) start-minute) scale)))
           (bottom (+ top (* org-timegrid-slot-minutes scale)))
           (body (window-body-height window t))
           (vscroll (org-timegrid--window-scroll-pixels window))
           (maximum (max 0 (- (or org-timegrid--image-height 0) body))))
      (cond
       ((< top vscroll)
        (org-timegrid--set-vscroll window (max 0 (min maximum top))))
       ((> bottom (+ vscroll body))
        (org-timegrid--set-vscroll
         window (max 0 (min maximum (- bottom body)))))))))

(defun org-timegrid-recenter ()
  "Scroll the cursor's slot to the middle of the window, leaving it put.
Ordinary motion scrolls only as far as it must, which keeps the cursor at
an edge after a long run; this is the view half of that on its own, so
the cursor never moves to satisfy the scroll."
  (interactive)
  (let ((cursor (org-timegrid--ensure-cursor))
        (window (get-buffer-window (current-buffer) t)))
    (when (window-live-p window)
      (let* ((scale org-timegrid-pixels-per-minute)
             (top (+ org-timegrid--grid-top-inset
                     (* (- (org-timegrid--cursor-state-minute cursor)
                           (* 60 org-timegrid-start-hour))
                        scale)))
             (body (window-body-height window t))
             (maximum (max 0 (- (or org-timegrid--image-height 0) body))))
        (org-timegrid--set-vscroll
         window
         (max 0 (min maximum
                     (round (- top (/ (- body (* org-timegrid-slot-minutes
                                                scale))
                                      2))))))))))

(defun org-timegrid--move-cursor (minutes days)
  "Move the cursor by MINUTES and DAYS, revealing it first when hidden."
  (if (org-timegrid--reveal-cursor)
      (org-timegrid--cursor-moved)
    (let ((cursor (org-timegrid--cursor)))
      (org-timegrid--set-cursor (+ (org-timegrid--cursor-state-day cursor) days)
                                (+ (org-timegrid--cursor-state-minute cursor) minutes)))
    (org-timegrid--cursor-moved)))

(defun org-timegrid--lane-count (day minute)
  "Return how many blocks start in the slot at DAY and MINUTE."
  (length (org-timegrid--blocks-starting-at day minute)))

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

(defun org-timegrid-cursor-forward (&optional count)
  "Move the cursor COUNT fifteen-minute slots later."
  (interactive "p")
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
                      (org-timegrid--set-cursor (org-timegrid--cursor-state-day cursor) 0)
                    (org-timegrid--set-all-day-cursor
                     (org-timegrid--cursor-state-day cursor) next)))
              (org-timegrid--set-cursor
               (org-timegrid--cursor-state-day cursor)
               (+ (org-timegrid--cursor-state-minute cursor)
                  org-timegrid-cursor-step-minutes)))))
        (org-timegrid--cursor-moved)))))

(defun org-timegrid-cursor-backward (&optional count)
  "Move the cursor COUNT stops earlier."
  (interactive "p")
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
             ((= (org-timegrid--cursor-state-minute cursor) 0)
              (org-timegrid--set-all-day-cursor
               (org-timegrid--cursor-state-day cursor)
               (org-timegrid--all-day-visible-rows)))
             (t
              (org-timegrid--set-cursor
               (org-timegrid--cursor-state-day cursor)
               (- (org-timegrid--cursor-state-minute cursor)
                  org-timegrid-cursor-step-minutes))))))
        (org-timegrid--cursor-moved)))))

(defun org-timegrid-cursor-forward-slot (&optional count)
  "Move the cursor COUNT fifteen-minute slots later."
  (interactive "p")
  (org-timegrid--move-cursor
   (* (or count 1) org-timegrid-slot-minutes) 0))

(defun org-timegrid-cursor-backward-slot (&optional count)
  "Move the cursor COUNT fifteen-minute slots earlier."
  (interactive "p")
  (org-timegrid-cursor-forward-slot (- (or count 1))))

(defun org-timegrid-cursor-forward-day (&optional count)
  "Move the cursor one lane to the right, or COUNT day columns.
Where several blocks start in the cursor's slot this walks their lanes
first, so two events at the same time are both reachable; once past the
last lane, or where there is only one, it moves by a day."
  (interactive "p")
  (if (org-timegrid--reveal-cursor)
      (org-timegrid--cursor-moved)
    (let* ((count (or count 1))
           (cursor (org-timegrid--cursor))
           (lane (or (org-timegrid--cursor-state-lane cursor) 0))
           (lanes (org-timegrid--lane-count (org-timegrid--cursor-state-day cursor)
                                            (org-timegrid--cursor-state-minute cursor))))
      (cond
       ((eq (org-timegrid--cursor-state-surface cursor) 'rail)
        (let* ((target (+ (org-timegrid--cursor-state-day cursor) count))
               (week-offset (* 7 (floor target 7)))
               (day (mod target 7)))
          (when (/= week-offset 0)
            (org-timegrid--reload-state
             (+ (org-timegrid--calendar-state-week-start org-timegrid--state) week-offset)))
          (org-timegrid--set-all-day-cursor day lane)))
       ((and (> count 0) (< (1+ lane) lanes))
        (org-timegrid--set-cursor (org-timegrid--cursor-state-day cursor)
                                  (org-timegrid--cursor-state-minute cursor) (1+ lane)))
       ((and (< count 0) (> lane 0))
        (org-timegrid--set-cursor (org-timegrid--cursor-state-day cursor)
                                  (org-timegrid--cursor-state-minute cursor) (1- lane)))
       (t
        (let* ((target (+ (org-timegrid--cursor-state-day cursor) count))
               (week-offset (* 7 (floor target 7)))
               (day (mod target 7))
               (minute (org-timegrid--cursor-state-minute cursor)))
          (when (/= week-offset 0)
            (org-timegrid--reload-state
             (+ (org-timegrid--calendar-state-week-start org-timegrid--state) week-offset)))
          (org-timegrid--set-cursor day minute 0))))
      (org-timegrid--cursor-moved))))

(defun org-timegrid-cursor-backward-day (&optional count)
  "Move the cursor one lane to the left, or COUNT day columns."
  (interactive "p")
  (org-timegrid-cursor-forward-day (- (or count 1))))

(defun org-timegrid-cursor-day-start ()
  "Move the cursor to midnight in its own day."
  (interactive)
  (unless (org-timegrid--reveal-cursor)
    (org-timegrid--set-cursor
     (org-timegrid--cursor-state-day (org-timegrid--cursor)) 0))
  (org-timegrid--cursor-moved))

(defun org-timegrid-cursor-day-end ()
  "Move the cursor to the last slot of its own day."
  (interactive)
  (unless (org-timegrid--reveal-cursor)
    (org-timegrid--set-cursor
     (org-timegrid--cursor-state-day (org-timegrid--cursor))
                              (- (* 60 24) org-timegrid-slot-minutes)))
  (org-timegrid--cursor-moved))

(defun org-timegrid--page-minutes (&optional window)
  "Return one screenful expressed in minutes for WINDOW."
  (let ((window (or window (get-buffer-window (current-buffer) t))))
    (max org-timegrid-slot-minutes
         (org-timegrid--snap-minute
          (/ (- (if window (window-body-height window t) 400) 40)
             org-timegrid-pixels-per-minute)))))

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

;;; Keyboard block selection

(defun org-timegrid--block-absolute-start (block)
  "Return BLOCK's absolute week start minute."
  (+ (* (org-timegrid-block-day block) 1440) (org-timegrid-block-start block)))

(defun org-timegrid--ordered-blocks ()
  "Return committed blocks in visible keyboard-navigation order.
For each date, all-day blocks anchored there follow their displayed lanes
from top to bottom, followed by that day's timed blocks.  A multi-day block
occurs once, at its first visible date."
  (let* ((all-day (org-timegrid--all-day-layout))
         (timed (seq-filter
                 (lambda (block) (not (org-timegrid-block-preview block)))
                 (org-timegrid--timed-blocks)))
         result)
    (dotimes (day-index 7)
      (let (day-all-day day-timed)
        (dolist (block all-day)
          (when (and (= day-index
                        (floor (org-timegrid-block-rail-start block) 1440))
                     (< (org-timegrid-block-rail-lane block)
                        org-timegrid-all-day-max-lanes))
            (push block day-all-day)))
        (dolist (block timed)
          (when (= day-index (org-timegrid-block-day block))
            (push block day-timed)))
        (setq result
              (append
               result
               (sort day-all-day
                     (lambda (left right)
                       (< (org-timegrid-block-rail-lane left)
                          (org-timegrid-block-rail-lane right))))
               (sort day-timed
                     (lambda (left right)
                       (let ((ls (org-timegrid-block-start left))
                             (rs (org-timegrid-block-start right)))
                         (if (= ls rs)
                             (string< (format "%S" (org-timegrid-block-id left))
                                      (format "%S" (org-timegrid-block-id right)))
                           (< ls rs)))))))))
    result))

(defun org-timegrid--goto-block (block)
  "Move the cursor to BLOCK's own first slot, which selects it.
The lane records which of several blocks sharing that start is meant, so
co-starting entries stay individually reachable."
  (let* ((day (max 0 (min 6 (org-timegrid-block-day block))))
         (start (org-timegrid-block-start block)))
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
           (or (and laid-out (org-timegrid-block-rail-lane laid-out)) 0))
          ;; Keep selection explicit when the event is hidden by the lane cap.
          (setf (org-timegrid--calendar-state-selected-id org-timegrid--state)
                (org-timegrid-block-id block)))
      (let ((lane (or (cl-position
                       (org-timegrid-block-id block)
                       (org-timegrid--blocks-starting-at day start)
                       :key (lambda (candidate) (org-timegrid-block-id candidate))
                       :test #'equal)
                      0)))
        (org-timegrid--set-cursor day start lane)))
    (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
    (org-timegrid--cursor-moved)
    (org-timegrid--scroll-cursor-into-view)))

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
                    (>= (org-timegrid--block-absolute-start block) from))
                  blocks)
               (nreverse
                (seq-filter
                 (lambda (block)
                   (<= (org-timegrid--block-absolute-start block) from))
                 blocks)))))
        (if candidates
            (org-timegrid--goto-block (car candidates))
          (org-timegrid--move-selection-across-week direction)))))))

(defun org-timegrid--move-selection-across-week (direction)
  "Move one week in DIRECTION and select its first or last block."
  (let* ((week-start (+ (org-timegrid--calendar-state-week-start org-timegrid--state)
                        (* direction 7)))
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
      (message "No further block"))))

(defun org-timegrid-next-block ()
  "Select the next block by start time, anywhere in the visible week."
  (interactive)
  (org-timegrid--move-selection 1))

(defun org-timegrid-previous-block ()
  "Select the previous block by start time, anywhere in the visible week."
  (interactive)
  (org-timegrid--move-selection -1))

(defun org-timegrid--block-at-cursor ()
  "Return the committed block the cursor points at, innermost first.
The block the cursor selects wins; failing that, any block overlapping the
cursor's slot counts, innermost first, so a nested child stays reachable
inside its parent.  Overlap rather than containment matters because an Org
range may start at 13:50, which lies inside the 13:45 slot but after it,
and such a block was unreachable while this asked for containment."
  (or (org-timegrid--block (org-timegrid--selected-id))
      (let ((cursor (org-timegrid--cursor)))
        (if (eq (org-timegrid--cursor-state-surface cursor) 'rail)
            (org-timegrid--all-day-at (org-timegrid--cursor-state-day cursor)
                                      (org-timegrid--cursor-state-lane cursor))
          (let* ((slot-start (org-timegrid--cursor-absolute))
                 (slot-end (+ slot-start org-timegrid-slot-minutes)))
            (car (sort (seq-filter
                        (lambda (block)
                          (let* ((start
                                  (org-timegrid--block-absolute-start block))
                                 (end (+ start
                                         (- (org-timegrid-block-end block)
                                            (org-timegrid-block-start block)))))
                            (and (not (org-timegrid-block-preview block))
                                 (< start slot-end)
                                 (> end slot-start))))
                        (org-timegrid--timed-blocks))
                       (lambda (left right)
                         (< (- (org-timegrid-block-end left)
                               (org-timegrid-block-start left))
                            (- (org-timegrid-block-end right)
                               (org-timegrid-block-start right)))))))))))

;;; Keyboard editing
;;
;; Every command below builds the same proposal a drag would and commits it
;; through `org-timegrid--apply', so snapping, the fifteen-minute minimum,
;; week clamping, stale-marker detection, read-only refusal, and repeating
;; series handling are inherited rather than reimplemented.

(defun org-timegrid--selected-block ()
  "Return the selected block, or signal a user error."
  (let ((block (org-timegrid--block (org-timegrid--selected-id))))
    (unless block
      (user-error "No block selected; press n, or put the cursor on a block's first slot"))
    block))

(defun org-timegrid--follow-block (id day minute &optional all-day)
  "Put the cursor back on block ID, or on DAY and MINUTE if it is gone.
Following by id preserves explicit selection and picks up the block's new
lane after an edit changes its layout."
  (if-let ((block (org-timegrid--block id)))
      (org-timegrid--goto-block block)
    (if all-day
        (org-timegrid--set-all-day-cursor (max 0 (min 6 day)) 0)
      (org-timegrid--set-cursor day minute 0))
    (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
    (org-timegrid--cursor-moved)))

(defun org-timegrid--keyboard-proposal (block minutes days edge)
  "Return one timed or all-day edit preview for BLOCK.
MINUTES and DAYS form the interval delta; EDGE selects a resize endpoint."
  (org-timegrid--operation-create
   :kind (if edge 'resize 'move)
   :block (org-timegrid--transform-block-range
           block (+ minutes (* days 1440)) edge)
   :replace-id (org-timegrid-block-id block)))

(defun org-timegrid--all-day-to-timed-proposal (block)
  "Return a proposal converting one-day date-only BLOCK at midnight."
  (let* ((copy (copy-org-timegrid-block block))
         (start (+ (* (org-timegrid-block-day block) 1440)
                   (org-timegrid-block-start block)))
         (duration (- (+ (* (org-timegrid-block-day block) 1440)
                         (org-timegrid-block-end block))
                      start)))
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
        (when-let ((proposal org-timegrid--keyboard-edit))
          (setq-local org-timegrid--keyboard-edit nil)
          (let* ((block (org-timegrid--operation-block proposal))
                 (id (org-timegrid-block-id block))
                 (day (org-timegrid-block-day block))
                 (minute (org-timegrid-block-start block)))
            (org-timegrid--apply proposal)
            (org-timegrid--follow-block
             id day minute (org-timegrid-block-all-day-p block))))))))

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
  (when (and org-timegrid--keyboard-edit
             (not (memq this-command
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
                          org-timegrid-shrink-all-day-start))))
    (org-timegrid--commit-keyboard-edit)))

(defun org-timegrid--edit-selected (minutes days edge)
  "Shift the selected block by MINUTES and DAYS.
EDGE nil moves the whole block, `top' changes its start, and `bottom'
changes its end.  The cursor follows, so the key can be held down."
  (let* ((block (or (and org-timegrid--keyboard-edit
                          (org-timegrid--operation-block
                           org-timegrid--keyboard-edit))
                    (org-timegrid--selected-block)))
         (updater (org-timegrid-backend-update-function org-timegrid--backend)))
    (unless (and (org-timegrid-block-event block) (functionp updater))
      (user-error "This backend cannot move or resize calendar entries"))
    (let* ((all-day (org-timegrid-block-all-day-p block))
           (to-timed (and all-day (/= minutes 0)))
           (proposal (if to-timed
                         (org-timegrid--all-day-to-timed-proposal block)
                       (org-timegrid--keyboard-proposal
                        block minutes days edge)))
           (moved (org-timegrid--operation-block proposal)))
      (setq-local org-timegrid--keyboard-edit proposal)
      (if (and all-day (not to-timed))
          (progn
            (setf (org-timegrid--calendar-state-preview org-timegrid--state)
                  proposal)
            (let* ((laid-out
                    (cl-find (org-timegrid-block-id moved)
                             (org-timegrid--all-day-layout)
                             :key (lambda (candidate)
                                    (org-timegrid-block-id candidate))
                             :test #'equal))
                   (day (max 0 (min 6 (floor
                                      (or (and laid-out
                                               (org-timegrid-block-rail-start
                                                laid-out))
                                          0)
                                      1440)))))
              (org-timegrid--set-all-day-cursor
               day (or (and laid-out
                            (org-timegrid-block-rail-lane laid-out))
                       0))))
        (progn
          (when all-day
            (setf (org-timegrid--calendar-state-preview org-timegrid--state)
                  proposal))
          (org-timegrid--set-cursor (org-timegrid-block-day moved)
                                    (org-timegrid-block-start moved) 0)))
      (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
      (if (and all-day (not to-timed))
          (org-timegrid--render-ui-change)
        (if to-timed
            (org-timegrid--render-ui-change)
          (org-timegrid--set-preview proposal)))
      (org-timegrid--scroll-cursor-into-view)
      (org-timegrid--schedule-keyboard-commit))))

(defun org-timegrid-copy-to-next-day (&optional count)
  "Copy the selected block COUNT days later, at the same time.
The cursor follows the copy, so holding the key spreads one entry across
consecutive days instead of stacking every copy on the same one."
  (interactive "p")
  (let* ((block (org-timegrid--selected-block))
         (start (org-timegrid-block-start block))
         (day (+ (org-timegrid-block-day block) (or count 1)))
         (title (org-timegrid-block-title block)))
    (unless (<= 0 day 6)
      (user-error "That day is outside the visible week"))
    (let ((copy (copy-org-timegrid-block block)))
      (setf (org-timegrid-block-day copy) day)
      (org-timegrid--backend-create
       title copy (org-timegrid-block-event block)
       (org-timegrid-event-source (org-timegrid-block-event block))))
    ;; The new timestamp belongs to the same heading, but its event identity
    ;; is not known until the backend data is reloaded, so follow its slot.
    (let* ((candidates (org-timegrid--blocks-starting-at day start))
           (lane (or (cl-position title candidates
                                  :key (lambda (candidate)
                                         (org-timegrid-block-title candidate))
                                  :test #'equal)
                     0)))
      (org-timegrid--set-cursor day start lane)
      (setf (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t)
      (org-timegrid--render-dynamic t)
      (org-timegrid--scroll-cursor-into-view))))

(defun org-timegrid-copy-to-previous-day (&optional count)
  "Copy the selected block COUNT days earlier, at the same time."
  (interactive "p")
  (org-timegrid-copy-to-next-day (- (or count 1))))

(defun org-timegrid-move-later (&optional count)
  "Move the selected block COUNT fifteen-minute slots later."
  (interactive "p")
  (org-timegrid--edit-selected
   (* (or count 1) org-timegrid-slot-minutes) 0 nil))

(defun org-timegrid-move-earlier (&optional count)
  "Move the selected block COUNT fifteen-minute slots earlier."
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
  (org-timegrid--reveal-cursor)
  (let* ((cursor (org-timegrid--ensure-cursor))
         (all-day (eq (org-timegrid--cursor-state-surface cursor) 'rail))
         (entry (org-timegrid--read-entry))
         (title (car entry)))
    (if (string-empty-p title)
        (message "Nothing created")
      (let* ((minutes (if all-day
                          1440
                        (org-timegrid--read-minutes
                         org-timegrid-default-duration-minutes)))
             (start (if all-day 0 (org-timegrid--cursor-state-minute cursor)))
             (block (org-timegrid--make-block
                     'new (org-timegrid--cursor-state-day cursor) start (+ start minutes)
                     title 'blue nil (if all-day 'all-day 'timed))))
        (org-timegrid--backend-create title block nil (cdr entry))))))

(defun org-timegrid-open-at-cursor ()
  "Visit the block under the cursor, or create one when the slot is empty."
  (interactive)
  (org-timegrid--reveal-cursor)
  (let ((block (org-timegrid--block-at-cursor)))
    (if (null block)
        (org-timegrid-create-at-cursor)
      (let ((event (org-timegrid-block-event block))
            (visitor (and org-timegrid--backend
                          (org-timegrid-backend-visit-function
                           org-timegrid--backend))))
        (if (and event (functionp visitor))
            (funcall visitor event)
          (message "No source to visit"))))))

;;; Keyboard copy, cut, and yank

(defvar org-timegrid--kill nil
  "Plist describing the most recently copied block.
Holds :title, :minutes, :all-day, and the opaque :event needed to
reproduce the entry's content.  :target is the backend record to which a
yank with a prefix adds the copied timestamp.  :cut records whether the
source timestamp was removed and must therefore be restored on yank.")

(defun org-timegrid-copy-selected ()
  "Copy the selected block for a later yank."
  (interactive)
  (let ((block (org-timegrid--selected-block)))
    (setq org-timegrid--kill
          (list :title (org-timegrid-block-title block)
                :minutes (- (org-timegrid-block-end block) (org-timegrid-block-start block))
                :all-day (and (org-timegrid-block-all-day-p block) t)
                :event (org-timegrid-block-event block)
                :cut nil
                :target (org-timegrid-event-source
                         (org-timegrid-block-event block))))
    (message "Copied %s" (org-timegrid-block-title block))))

(defun org-timegrid-cut-selected ()
  "Cut the selected block for a later yank.
Unlike a copy, yanking a cut block adds its time back to the original
backend record instead of duplicating that record."
  (interactive)
  (let* ((block (org-timegrid--selected-block))
         (event (org-timegrid-block-event block)))
    (setq org-timegrid--kill
          (list :title (org-timegrid-block-title block)
                :minutes (- (org-timegrid-block-end block) (org-timegrid-block-start block))
                :all-day (and (org-timegrid-block-all-day-p block) t)
                :event event
                :cut t
                :target (org-timegrid-event-source event)))
    (org-timegrid-remove-selected t)
    (message "Cut %s" (org-timegrid-block-title block))))

(defun org-timegrid-yank (&optional add-occurrence)
  "Yank the most recently copied or cut block at the cursor.
Ordinarily a copied block becomes an independent backend entry.  With a
prefix argument ADD-OCCURRENCE, add its timestamp to the original entry
instead.  A cut block always returns to its original entry."
  (interactive "P")
  (unless org-timegrid--kill
    (user-error "Nothing to yank; select a block and press M-w or C-w"))
  (org-timegrid--reveal-cursor)
  (let* ((cursor (org-timegrid--ensure-cursor))
         (rail (eq (org-timegrid--cursor-state-surface cursor) 'rail))
         (source-all-day (plist-get org-timegrid--kill :all-day))
         (source-minutes (plist-get org-timegrid--kill :minutes))
         (_ (when (and source-all-day (not rail) (> source-minutes 1440))
              (user-error "Multi-day blocks can only be pasted in the all-day rail")))
         (start (if rail 0 (org-timegrid--cursor-state-minute cursor)))
         (minutes (cond
                   (rail (if source-all-day source-minutes 1440))
                   (source-all-day org-timegrid-default-duration-minutes)
                   (t source-minutes)))
         (block (org-timegrid--make-block
                 'yank (org-timegrid--cursor-state-day cursor)
                 start (+ start minutes)
                 (plist-get org-timegrid--kill :title) 'blue nil
                 (if rail 'all-day 'timed))))
    (org-timegrid--backend-create
     (plist-get org-timegrid--kill :title) block
     (plist-get org-timegrid--kill :event)
     (and (or add-occurrence (plist-get org-timegrid--kill :cut))
          (plist-get org-timegrid--kill :target)))))

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
DURATION is unused: this reader has no range syntax, so it always returns
nil for the duration and leaves the caller to ask."
  (ignore duration)
  (let* ((day (floor absolute-start 1440))
         (minute (% absolute-start 1440))
         (date (calendar-gregorian-from-absolute day))
         (prefill (format "%04d-%02d-%02d %02d:%02d"
                          (nth 2 date) (nth 0 date) (nth 1 date)
                          (/ minute 60) (% minute 60)))
         (answer (read-string "Start (YYYY-MM-DD HH:MM): " prefill))
         (parsed (and (string-match
                       "\\([0-9]\\{4\\}\\)-\\([0-9]+\\)-\\([0-9]+\\)[ \t]+\\([0-9]+\\):\\([0-9]+\\)"
                       answer)
                      (+ (* 1440 (calendar-absolute-from-gregorian
                                  (list (string-to-number (match-string 2 answer))
                                        (string-to-number (match-string 3 answer))
                                        (string-to-number (match-string 1 answer)))))
                         (* 60 (string-to-number (match-string 4 answer)))
                         (string-to-number (match-string 5 answer))))))
    (cons (or parsed absolute-start) nil)))

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
     (org-timegrid-block-time-kind block))
    (org-timegrid--refresh-data)))

;;; Dates

(defun org-timegrid-goto-date ()
  "Show the week containing a date read from the user."
  (interactive)
  (let* ((cursor-absolute
          (+ (* (+ (org-timegrid--calendar-state-week-start org-timegrid--state)
                   (org-timegrid--cursor-state-day
                    (org-timegrid--ensure-cursor)))
                1440)
             (org-timegrid--cursor-state-minute
              (org-timegrid--ensure-cursor))))
         (answer (org-timegrid--read-timestamp
                   cursor-absolute org-timegrid-slot-minutes))
         (absolute (floor (car answer) 1440)))
    (org-timegrid--reload-state (org-timegrid-week-start absolute))
    (org-timegrid--set-cursor
     (- absolute (org-timegrid--calendar-state-week-start org-timegrid--state))
     (% (car answer) 1440))
    (org-timegrid--refresh)
    (org-timegrid--scroll-cursor-into-view)))

(defun org-timegrid-goto-today ()
  "Show the week containing today.
A visible cursor moves to the current slot; a hidden one stays hidden,
since jumping dates should not conjure a cursor nobody asked for."
  (interactive)
  (let ((today (calendar-absolute-from-gregorian (calendar-current-date)))
        (visible (and (org-timegrid--cursor) t)))
    (org-timegrid--reload-state (org-timegrid-week-start today))
    (setf (org-timegrid--calendar-state-cursor org-timegrid--state)
          (and visible
               (org-timegrid--default-cursor
                (org-timegrid--calendar-state-week-start
                 org-timegrid--state))))
    (org-timegrid--refresh)
    (org-timegrid--scroll-cursor-into-view)))

(defun org-timegrid-remove-or-page-up (&optional count)
  "Remove the selected block, or page the cursor up when none is selected.
Backspace sends DEL, so this key has to serve both the delete people
expect on a selected block and the paging DEL means in a view buffer."
  (interactive "p")
  (if (org-timegrid--selected-id)
      (org-timegrid-remove-selected)
    (org-timegrid-cursor-page-up count)))

(defun org-timegrid-dismiss ()
  "Hide the cursor and clear the selection and any preview.
The cursor's position is remembered, so a later movement key resumes from
where it was left.  Only an explicit refresh forgets it."
  (interactive)
  (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil
        (org-timegrid--calendar-state-cursor-visible org-timegrid--state) nil)
  (org-timegrid--render-ui-change))

(defun org-timegrid-wheel-up (event)
  "Scroll the SVG upward."
  (interactive "e")
  (when-let ((window (org-timegrid--event-window event)))
    (org-timegrid-scroll -90 window)))

(defun org-timegrid-wheel-down (event)
  "Scroll the SVG downward."
  (interactive "e")
  (when-let ((window (org-timegrid--event-window event)))
    (org-timegrid-scroll 90 window)))

(defun org-timegrid-shift-week (days)
  "Move the SVG week by DAYS."
  (org-timegrid--reload-state
   (+ (org-timegrid--calendar-state-week-start org-timegrid--state) days))
  (org-timegrid--refresh))

(defun org-timegrid-previous-week ()
  "Show the previous week."
  (interactive)
  (org-timegrid-shift-week -7))

(defun org-timegrid-next-week ()
  "Show the next week."
  (interactive)
  (org-timegrid-shift-week 7))

(defun org-timegrid-backward-day ()
  "Move the seven-day calendar backward by one day."
  (interactive)
  (org-timegrid-shift-week -1))

(defun org-timegrid-forward-day ()
  "Move the seven-day calendar forward by one day."
  (interactive)
  (org-timegrid-shift-week 1))

(defun org-timegrid--refresh-data ()
  "Reload the displayed week without moving the cursor or viewport."
  (org-timegrid--reload-state (org-timegrid--calendar-state-week-start org-timegrid--state))
  (org-timegrid--refresh t))

(defun org-timegrid-refresh ()
  "Manually reload the displayed week and reset its cursor and viewport."
  (interactive)
  (org-timegrid--reload-state (org-timegrid--calendar-state-week-start org-timegrid--state))
  (setf (org-timegrid--calendar-state-cursor org-timegrid--state) nil
        (org-timegrid--calendar-state-cursor-visible org-timegrid--state) nil)
  (setq-local org-timegrid--saved-vscroll 0)
  (org-timegrid--refresh)
  (when-let ((window (get-buffer-window (current-buffer) t)))
    (org-timegrid--set-vscroll window 0)))

(defvar org-timegrid-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map [down-mouse-1]
                #'org-timegrid-press)
    (define-key map [s-down-mouse-1]
                #'org-timegrid-press)
    (define-key map [S-down-mouse-1]
                #'org-timegrid-press)
    (define-key map [mouse-1] #'org-timegrid-click)
    (define-key map [double-mouse-1] #'org-timegrid-visit)
    (define-key map [mouse-movement] #'org-timegrid-pointer-feedback)
    (define-key map [header-line mouse-1] #'org-timegrid-header-click)
    (define-key map [header-line down-mouse-1] #'org-timegrid-header-press)
    (define-key map [header-line s-down-mouse-1] #'org-timegrid-header-press)
    (define-key map [header-line S-down-mouse-1] #'org-timegrid-header-press)
    (define-key map [header-line double-mouse-1] #'org-timegrid-header-visit)
    (dolist (area '(calendar-block calendar-resize))
      (define-key map (vector area 'down-mouse-1)
                  #'org-timegrid-press)
      (define-key map (vector area 's-down-mouse-1)
                  #'org-timegrid-press)
      (define-key map (vector area 'S-down-mouse-1)
                  #'org-timegrid-press)
      (define-key map (vector area 'mouse-1)
                  #'org-timegrid-click)
      (define-key map (vector area 'double-mouse-1)
                  #'org-timegrid-visit)
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
    ;; Remapping catches whatever key the user has put undo on, and the
    ;; explicit bindings are the floor for a command we cannot know about.
    (keymap-set map "<remap> <undo>" #'org-timegrid-undo)
    (keymap-set map "<remap> <undo-only>" #'org-timegrid-undo)
    (keymap-set map "<remap> <undo-redo>" #'org-timegrid-redo)
    (keymap-set map "C-/" #'org-timegrid-undo)
    (keymap-set map "C-_" #'org-timegrid-undo)
    (keymap-set map "C-x u" #'org-timegrid-undo)
    (keymap-set map "M-_" #'org-timegrid-redo)
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
    ;; Dates and files.
    (keymap-set map "j" #'org-timegrid-goto-date)
    (keymap-set map "." #'org-timegrid-goto-today)
    (keymap-set map "q" #'quit-window)
    map))

;; Keep reevaluation in a running Emacs from retaining the previous bindings.
(dolist (key '("M-S-<down>" "M-S-<up>" "M-S-<right>" "M-S-<left>"
               "M-S-s-<right>" "M-S-s-<left>"))
  (keymap-unset org-timegrid-mode-map key t))
(keymap-set org-timegrid-mode-map "M-<down>" #'org-timegrid-move-later)
(keymap-set org-timegrid-mode-map "M-<up>" #'org-timegrid-move-earlier)
(keymap-set org-timegrid-mode-map "M-<right>" #'org-timegrid-move-next-day)
(keymap-set org-timegrid-mode-map "M-<left>" #'org-timegrid-move-previous-day)
(keymap-unset org-timegrid-mode-map "M-s-<right>" t)
(keymap-unset org-timegrid-mode-map "M-s-<left>" t)
(keymap-set org-timegrid-mode-map "S-<right>" #'org-timegrid-grow-all-day-end)
(keymap-set org-timegrid-mode-map "S-<left>" #'org-timegrid-shrink-all-day-end)
(keymap-set org-timegrid-mode-map "C-S-<left>" #'org-timegrid-grow-all-day-start)
(keymap-set org-timegrid-mode-map "C-S-<right>" #'org-timegrid-shrink-all-day-start)
;; These live outside the `defvar' initializer so evaluating an updated
;; package installs them in an already-running Emacs as well.
(define-key org-timegrid-mode-map [s-down-mouse-1]
            #'org-timegrid-press)
(define-key org-timegrid-mode-map [S-down-mouse-1]
            #'org-timegrid-press)
(dolist (area '(calendar-block calendar-resize))
  (define-key org-timegrid-mode-map (vector area 's-down-mouse-1)
              #'org-timegrid-press)
  (define-key org-timegrid-mode-map (vector area 'S-down-mouse-1)
              #'org-timegrid-press)
  (define-key org-timegrid-mode-map (vector area 'mouse-movement)
              #'org-timegrid-pointer-feedback))
(define-key org-timegrid-mode-map [mouse-movement]
            #'org-timegrid-pointer-feedback)
(define-key org-timegrid-mode-map [header-line mouse-1]
            #'org-timegrid-header-click)
(define-key org-timegrid-mode-map [header-line down-mouse-1]
            #'org-timegrid-header-press)
(define-key org-timegrid-mode-map [header-line s-down-mouse-1]
            #'org-timegrid-header-press)
(define-key org-timegrid-mode-map [header-line S-down-mouse-1]
            #'org-timegrid-header-press)
(define-key org-timegrid-mode-map [header-line double-mouse-1]
            #'org-timegrid-header-visit)

(define-derived-mode org-timegrid-mode special-mode
  "Org Time Grid"
  "Major mode for an SVG week calendar.

The calendar owns one explicit cursor and one selected event.  The cursor
can occupy either a timed slot or an all-day rail cell; both mouse and
keyboard changes pass through the same damage-based renderer.

\\{org-timegrid-mode-map}"
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  ;; Image rows otherwise gain one baseline pixel and visible hour seams.
  (setq-local line-spacing -1)
  (setq-local track-mouse t)
  (setq-local mouse-fine-grained-tracking t)
  (setq-local auto-window-vscroll t)
  (add-hook 'window-size-change-functions
            #'org-timegrid--window-resized nil t)
  (add-hook 'pre-command-hook
            #'org-timegrid--commit-before-unrelated-command nil t)
  (add-hook 'kill-buffer-hook
            #'org-timegrid--cancel-timers nil t))

(defun org-timegrid--center-now (window)
  "Center the current time vertically in WINDOW."
  (let* ((now (decode-time))
         (minute (+ (* 60 (decoded-time-hour now))
                    (decoded-time-minute now)))
         (start-minute (* 60 org-timegrid-start-hour))
         (y (+ org-timegrid--grid-top-inset
               (* (- minute start-minute)
                  org-timegrid-pixels-per-minute)))
         (target (max 0 (- y (/ (window-body-height window t) 2)))))
    (org-timegrid--set-vscroll window target)))

;;;###autoload
(defun org-timegrid-open (backend &optional absolute-date)
  "Open BACKEND on the week containing ABSOLUTE-DATE.
Revisiting an existing calendar retains its pixel scroll position."
  (unless (org-timegrid-backend-p backend)
    (user-error "A calendar backend is required"))
  (let* ((existing (get-buffer org-timegrid-buffer-name))
         (buffer (or existing
                     (get-buffer-create org-timegrid-buffer-name)))
         (requested-week (and absolute-date
                              (org-timegrid-week-start absolute-date)))
         refreshp)
    (if existing
        (with-current-buffer buffer
          (let ((current-week (org-timegrid--calendar-state-week-start org-timegrid--state)))
            (when (or org-timegrid--stale
                      (not (eq org-timegrid--backend backend))
                      (and requested-week
                           (/= requested-week current-week)))
              (setq-local org-timegrid--backend backend)
              (setq-local org-timegrid--state
                          (org-timegrid--load-state
                           (or requested-week current-week)))
              (setq-local org-timegrid--stale nil)
              (setq refreshp t))))
      (with-current-buffer buffer
        (org-timegrid-mode)
        (setq-local org-timegrid--backend backend)
        (setq-local org-timegrid--state
                    (org-timegrid--load-state
                     (org-timegrid-week-start absolute-date)))
        (let ((owner buffer))
          (setq-local
           org-timegrid--clock-timer
           (run-at-time
            60 60
            (lambda () (org-timegrid--clock-tick owner))))
          (setq-local
           org-timegrid--data-timer
           (run-at-time
            org-timegrid-data-refresh-seconds
            org-timegrid-data-refresh-seconds
            (lambda () (org-timegrid--data-tick owner)))))))
    (pop-to-buffer buffer)
    (let ((window (get-buffer-window buffer t)))
      (with-current-buffer buffer
        (cond
         ((null existing)
          (org-timegrid--refresh)
          (when window
            (org-timegrid--center-now window)))
         ((or refreshp
              (/= (org-timegrid--window-width)
                  (or org-timegrid--last-width -1)))
          (org-timegrid--refresh t)))
        (when window
          (org-timegrid--schedule-scroll-restore window))))
    buffer))

(add-hook 'enable-theme-functions
          #'org-timegrid--theme-changed)
(add-hook 'disable-theme-functions
          #'org-timegrid--theme-changed)
(add-hook 'window-buffer-change-functions
          #'org-timegrid--restore-frame-calendars)

(provide 'org-timegrid)
(require 'org-timegrid-isearch)
;;; org-timegrid.el ends here
