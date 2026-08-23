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

(defcustom org-timegrid-block-gap 3
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
  '((blue     . "#007aff")
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

(defcustom org-timegrid-cursor-step-minutes 30
  "Minutes the keyboard cursor moves per ordinary step.
Fifteen minutes is too fine to cross a day with, so the ordinary step is
half an hour and `org-timegrid-cursor-forward-slot' keeps the fine
grain."
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

(defcustom org-timegrid-buffer-name "*Org Time Grid*"
  "Name of the calendar buffer."
  :type 'string)

(defconst org-timegrid--label-width 48)
(defconst org-timegrid--lane-gap 3)
(defvar-local org-timegrid--geometry nil)
(defvar-local org-timegrid--image-height nil)
(defvar-local org-timegrid--last-width nil)
(defvar-local org-timegrid--pointer-overlay nil)
(defvar-local org-timegrid--resize-timer nil)
(defvar-local org-timegrid--clock-timer nil)
(defvar-local org-timegrid--data-timer nil)
(defvar-local org-timegrid--cursor-timer nil)
(defvar-local org-timegrid--scroll-restore-timer nil)
(defvar-local org-timegrid--stale nil)
(defvar-local org-timegrid--saved-vscroll 0
  "Pixel scroll position restored when this calendar is shown again.")
(defvar org-timegrid--theme-timer nil)
(defvar-local org-timegrid--backend nil)
(defvar-local org-timegrid--state nil)

(defun org-timegrid--make-block
    (id day start end title &optional color done)
  "Construct a renderer block from ID, DAY, START, END, TITLE and COLOR."
  (list :id id :day day :start start :end end :title title
        :color color :done done))

(defun org-timegrid--load-state (week-start)
  "Load renderer state for WEEK-START from the current backend."
  (let* ((events (org-timegrid-backend-list
                  org-timegrid--backend
                  (* week-start 1440) (* (+ week-start 7) 1440)))
         (blocks (org-timegrid-events-to-blocks events week-start)))
    ;; The cursor has a remembered position and a separate visibility, so
    ;; hiding it with C-g keeps the place, and block selection can record a
    ;; position without drawing anything.
    (list :week-start week-start :events events :blocks blocks
          :preview nil :cursor nil :cursor-visible nil)))

(defun org-timegrid--default-cursor (week-start)
  "Return the initial keyboard cursor for the week at WEEK-START.
It sits on the current fifteen-minute slot when today is visible, and on
the first visible day at the configured start hour otherwise."
  (let* ((today (calendar-absolute-from-gregorian (calendar-current-date)))
         (offset (- today week-start)))
    (if (<= 0 offset 6)
        (let ((now (decode-time)))
          (list :day offset
                :minute (org-timegrid--snap-minute
                         (+ (* 60 (decoded-time-hour now))
                            (decoded-time-minute now)))
                :lane 0))
      (list :day 0 :minute (* 60 org-timegrid-start-hour) :lane 0))))

(defun org-timegrid--snap-minute (minute)
  "Return MINUTE rounded down to a fifteen-minute slot inside one day."
  (let ((slots (/ (- (* 60 24) org-timegrid-slot-minutes)
                  org-timegrid-slot-minutes)))
    (* org-timegrid-slot-minutes
       (max 0 (min slots (floor minute org-timegrid-slot-minutes))))))

(defun org-timegrid--cursor ()
  "Return the remembered cursor position, which may be hidden."
  (plist-get org-timegrid--state :cursor))

(defun org-timegrid--cursor-visible-p ()
  "Return non-nil when the cursor is currently drawn."
  (plist-get org-timegrid--state :cursor-visible))

(defun org-timegrid--blocks-starting-at (day minute)
  "Return committed blocks starting inside DAY's slot at MINUTE.
A real Org range can start at 13:10, which is no slot at all, so the test
is whether the start falls within this slot rather than equalling it;
otherwise such a block could never be selected.  Shortest first, so a
nested child is offered before its parent.  Several blocks can share a
slot, which is what the cursor's :lane disambiguates."
  (when (and (numberp day) (numberp minute))
    (sort (seq-filter (lambda (block)
                        (and (not (plist-get block :preview))
                             (= (plist-get block :day) day)
                             (>= (plist-get block :start) minute)
                             (< (plist-get block :start)
                                (+ minute org-timegrid-slot-minutes))))
                      (copy-sequence (plist-get org-timegrid--state :blocks)))
          (lambda (left right)
            (< (- (plist-get left :end) (plist-get left :start))
               (- (plist-get right :end) (plist-get right :start)))))))

(defun org-timegrid--selected-id ()
  "Return the id of the block the cursor selects, or nil.
Selection is not stored: a block is selected exactly when the visible
cursor sits on its own first slot, which is why the highlight and the
cursor can never disagree."
  (when-let* (((org-timegrid--cursor-visible-p))
              (cursor (org-timegrid--cursor))
              (candidates (org-timegrid--blocks-starting-at
                           (plist-get cursor :day) (plist-get cursor :minute))))
    (plist-get (nth (min (or (plist-get cursor :lane) 0)
                         (1- (length candidates)))
                    candidates)
               :id)))

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
                              (= (plist-get item :day) (plist-get cursor :day))
                              (not (plist-get item :boundary-edge))))
                       (or geometry-list org-timegrid--geometry)))))
      (list :x (if lane
                   (plist-get lane :x)
                 (+ 1 org-timegrid--label-width
                    (* (plist-get cursor :day) column)))
            :y (* (- (plist-get cursor :minute)
                     (* 60 org-timegrid-start-hour))
                  org-timegrid-pixels-per-minute)
            :width (if lane (plist-get lane :width) (- column 2))
            :height (* org-timegrid-slot-minutes
                       org-timegrid-pixels-per-minute)))))

(defun org-timegrid--ensure-cursor ()
  "Return the cursor position, defaulting it when nothing is remembered."
  (or (org-timegrid--cursor)
      (let ((cursor (org-timegrid--default-cursor
                     (plist-get org-timegrid--state :week-start))))
        (setq-local org-timegrid--state
                    (plist-put org-timegrid--state :cursor cursor))
        cursor)))

(defun org-timegrid--reveal-cursor ()
  "Show the cursor, returning non-nil when it was hidden until now.
The first movement key reveals the cursor where it was left rather than
also moving it, so its position is visible before it is used."
  (unless (org-timegrid--cursor-visible-p)
    (org-timegrid--ensure-cursor)
    (setq-local org-timegrid--state
                (plist-put org-timegrid--state :cursor-visible t))
    t))

(defun org-timegrid--cursor-absolute ()
  "Return the cursor's absolute week minute."
  (let ((cursor (org-timegrid--ensure-cursor)))
    (+ (* (plist-get cursor :day) 1440) (plist-get cursor :minute))))

(defun org-timegrid--set-cursor (day minute &optional lane)
  "Move the cursor to DAY and MINUTE, clamped to the visible week.
LANE picks between blocks sharing that start, and defaults to zero."
  (setq-local org-timegrid--state
              (plist-put org-timegrid--state :cursor
                         (list :day (max 0 (min 6 day))
                               :minute (org-timegrid--snap-minute minute)
                               :lane (or lane 0))))
  (org-timegrid--cursor))

(defun org-timegrid--reload-state (week-start)
  "Reload WEEK-START from the backend, keeping cursor and selection.
Navigation and refresh drop preview and history, but they must not throw
the cursor back to today, and they must not clear the selection: every
edit refreshes, so a cleared selection would make repeated keyboard
nudges of one block impossible.  A selection that no longer resolves
after the reload is dropped."
  (let ((cursor (plist-get org-timegrid--state :cursor))
        (visible (plist-get org-timegrid--state :cursor-visible)))
    (setq-local org-timegrid--state (org-timegrid--load-state week-start))
    (when cursor
      (setq-local org-timegrid--state
                  (plist-put org-timegrid--state :cursor cursor))
      (setq-local org-timegrid--state
                  (plist-put org-timegrid--state :cursor-visible visible)))))

(defun org-timegrid--block (id)
  "Return the current renderer block identified by ID."
  (cl-find id (plist-get org-timegrid--state :blocks)
           :key (lambda (block) (plist-get block :id)) :test #'equal))

(defun org-timegrid--set-absolute-range
    (block absolute-start absolute-end)
  "Set BLOCK to ABSOLUTE-START and ABSOLUTE-END week-minute values."
  (let* ((day (floor absolute-start 1440))
         (day-start (* day 1440)))
    (plist-put block :day day)
    (plist-put block :start (- absolute-start day-start))
    (plist-put block :end (- absolute-end day-start))
    block))

(defun org-timegrid--proposal (origin target copying)
  "Return a drag proposal from ORIGIN to TARGET.
COPYING means retain the source block and propose a duplicate."
  (let* ((id (plist-get origin :block-id))
         (origin-day (plist-get origin :day))
         (target-day (plist-get target :day))
         (origin-minute (plist-get origin :minute))
         (target-minute (plist-get target :minute))
         (edge (plist-get origin :edge)))
    (cond
     ((or (null origin-day) (null origin-minute)
          (null target-day) (null target-minute))
      (list :error "Release inside a calendar cell"))
     ((null id)
      (if (/= origin-day target-day)
          (list :error "New ranges currently stay within one day")
        (let ((block (org-timegrid--make-block
                      'preview origin-day
                      (min origin-minute target-minute)
                      (+ (max origin-minute target-minute)
                         org-timegrid-slot-minutes)
                      "New block" 'blue)))
          (plist-put block :preview t)
          (list :kind 'create :block block))))
     (t
      (let ((source (org-timegrid--block id)))
        (if (null source)
            (list :error "That calendar block changed; refresh and try again")
          (let* ((block (copy-sequence source))
                 (absolute-start (+ (* (plist-get block :day) 1440)
                                    (plist-get block :start)))
                 (absolute-end (+ (* (plist-get block :day) 1440)
                                  (plist-get block :end)))
                 (duration (- absolute-end absolute-start))
                 (absolute-origin (+ (* origin-day 1440) origin-minute))
                 (absolute-target (+ (* target-day 1440) target-minute))
                 kind)
            (cond
             ((and (eq edge 'top) (not copying))
              (setq kind 'resize)
              (org-timegrid--set-absolute-range
               block (max 0 (min absolute-target
                                 (- absolute-end org-timegrid-slot-minutes)))
               absolute-end))
             ((and (eq edge 'bottom) (not copying))
              (setq kind 'resize)
              (org-timegrid--set-absolute-range
               block absolute-start
               (min (* 7 1440)
                    (max (+ absolute-target org-timegrid-slot-minutes)
                         (+ absolute-start org-timegrid-slot-minutes)))))
             (t
              (setq kind (if copying 'copy 'move))
              (let* ((grab-offset (- absolute-origin absolute-start))
                     (new-start (max 0 (min (- absolute-target grab-offset)
                                            (- (* 7 1440) duration)))))
                (org-timegrid--set-absolute-range
                 block new-start (+ new-start duration)))))
            (plist-put block :preview t)
            (list :kind kind :block block
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

(defun org-timegrid--layout-day (blocks day)
  "Lay out BLOCKS on DAY as nested, independently split sibling groups."
  (let* ((sorted (sort (cl-remove-if-not
                        (lambda (block) (= day (plist-get block :day)))
                        (copy-sequence blocks))
                       (lambda (left right)
                         (if (= (plist-get left :start)
                                (plist-get right :start))
                             (> (plist-get left :end)
                                (plist-get right :end))
                           (< (plist-get left :start)
                              (plist-get right :start))))))
         annotated)
    (dolist (block sorted)
      (let* ((containers
              (cl-remove-if-not
               (lambda (candidate)
                 (and (<= (plist-get candidate :start)
                           (plist-get block :start))
                      (>= (plist-get candidate :end)
                           (plist-get block :end))
                      (or (< (plist-get candidate :start)
                             (plist-get block :start))
                          (> (plist-get candidate :end)
                             (plist-get block :end)))
                      (>= (* (- (plist-get block :start)
                                (plist-get candidate :start))
                             org-timegrid-pixels-per-minute)
                          org-timegrid-title-clearance)))
               annotated))
             (parent
              (car (sort containers
                         (lambda (left right)
                           (> (plist-get left :nest-depth)
                              (plist-get right :nest-depth))))))
             (copy (copy-sequence block)))
        (setq copy
              (plist-put copy :nest-depth
                         (if parent
                             (1+ (plist-get parent :nest-depth))
                           0)))
        (setq copy
              (plist-put copy :root-id
                         (if parent
                             (plist-get parent :root-id)
                           (plist-get copy :id))))
        (setq copy
              (plist-put copy :parent-id
                         (and parent (plist-get parent :id))))
        (push copy annotated)))
    (setq annotated (nreverse annotated))
    (let ((siblings (make-hash-table :test #'equal))
          (local-layout (make-hash-table :test #'equal))
          (output (make-hash-table :test #'equal))
          (family-size (make-hash-table :test #'equal)))
      (dolist (block annotated)
        (let ((parent-id (plist-get block :parent-id))
              (root-id (plist-get block :root-id)))
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
           (puthash (plist-get child :id) child local-layout)))
       siblings)
      ;; Parents precede their children in ANNOTATED, so their completed path
      ;; is available when constructing each descendant's path.
      (mapcar
       (lambda (block)
         (let* ((copy (copy-sequence block))
                (id (plist-get copy :id))
                (parent-id (plist-get copy :parent-id))
                (parent (and parent-id (gethash parent-id output)))
                (local (gethash id local-layout))
                (step (cons (or (plist-get local :lane) 0)
                            (max 1 (or (plist-get local :lanes) 1))))
                (path (append (and parent (plist-get parent :layout-path))
                              (list step))))
           (setq copy (plist-put copy :layout-path path))
           (setq copy
                 (plist-put copy :nested-family
                            (> (gethash (plist-get copy :root-id)
                                        family-size 0)
                               1)))
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
    (dolist (step (plist-get block :layout-path))
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
  (if (or (plist-get block :preview) (plist-get block :done))
      (plist-get palette :muted)
    (org-timegrid--resolve-color (plist-get block :color) palette)))

(defun org-timegrid--color (block palette)
  "Return the fill color for BLOCK from PALETTE.
A block is a wash of its accent over the buffer background, so any colour
works without the palette having to know it in advance."
  (cond
   ((plist-get block :preview) (plist-get palette :preview-fill))
   ((plist-get block :done) (plist-get palette :done-fill))
   (t (org-timegrid--blend (org-timegrid--accent block palette)
                           (plist-get palette :background) 0.17))))

(defun org-timegrid--display-segments (block)
  "Return visible per-day segments and exact-midnight grips for BLOCK."
  (let* ((source-day (plist-get block :day))
         (source-start (plist-get block :start))
         (source-end (plist-get block :end))
         (absolute-start (+ (* source-day 1440) source-start))
         (absolute-end (+ (* source-day 1440) source-end))
         segments)
    (dotimes (day 7)
      (let* ((day-start (* day 1440))
             (day-end (+ day-start 1440))
             (segment-start (max absolute-start day-start))
             (segment-end (min absolute-end day-end)))
        (when (< segment-start segment-end)
          (let ((segment (copy-sequence block)))
            (plist-put segment :source-day source-day)
            (plist-put segment :source-start source-start)
            (plist-put segment :source-end source-end)
            (plist-put segment :day day)
            (plist-put segment :start (- segment-start day-start))
            (plist-put segment :end (- segment-end day-start))
            (plist-put segment :allow-top (= segment-start absolute-start))
            (plist-put segment :allow-bottom (= segment-end absolute-end))
            (push segment segments)))))
    ;; A range ending exactly at midnight needs a small bottom-edge target at
    ;; the top of the next day so it can be extended forward.
    (when (and (= (% absolute-end 1440) 0)
               (< 0 absolute-end (* 7 1440)))
      (let* ((day (/ absolute-end 1440))
             (grip (copy-sequence block)))
        (plist-put grip :source-day source-day)
        (plist-put grip :source-start source-start)
        (plist-put grip :source-end source-end)
        (plist-put grip :day day)
        (plist-put grip :start 0)
        (plist-put grip :end 1)
        (plist-put grip :title "")
        (plist-put grip :boundary-edge 'bottom)
        (plist-put grip :allow-top nil)
        (plist-put grip :allow-bottom t)
        (push grip segments)))
    ;; A range starting exactly at midnight gets its top-edge target at the
    ;; bottom of the preceding day so it can be extended backward.
    (when (and (= (% absolute-start 1440) 0)
               (< 0 absolute-start (* 7 1440)))
      (let* ((day (1- (/ absolute-start 1440)))
             (grip (copy-sequence block)))
        (plist-put grip :source-day source-day)
        (plist-put grip :source-start source-start)
        (plist-put grip :source-end source-end)
        (plist-put grip :day day)
        (plist-put grip :start 1439)
        (plist-put grip :end 1440)
        (plist-put grip :title "")
        (plist-put grip :boundary-edge 'top)
        (plist-put grip :allow-top t)
        (plist-put grip :allow-bottom nil)
        (push grip segments)))
    (nreverse segments)))

(defun org-timegrid-day-blocks (backend absolute-day)
  "Return BACKEND blocks on ABSOLUTE-DAY, clipped to it and given lanes.
Coordinates are minutes within that day, so a range running past midnight
arrives clipped at 1440 rather than spilling into a day that is not being
drawn.  Overlaps get plain side-by-side lanes: the Week view nests a child
inside its parent, which needs more height than one compact row has."
  (let* ((start (* absolute-day 1440))
         (blocks
          (mapcar
           (lambda (event)
             (list :id (org-timegrid-event-id event)
                   :day 0
                   :start (max 0 (- (org-timegrid-event-start event) start))
                   :end (min 1440 (- (org-timegrid-event-end event) start))
                   :title (org-timegrid-event-title event)
                   :color (org-timegrid-event-color event)
                   :done (eq (org-timegrid-event-state event) 'done)
                   :event event))
           (org-timegrid-backend-list backend start (+ start 1440)))))
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
      (let* ((lanes (max 1 (or (plist-get block :lanes) 1)))
             (lane (or (plist-get block :lane) 0))
             (lane-width (/ (- column (* (1- lanes) org-timegrid--lane-gap))
                            (float lanes)))
             (x (+ label-width 1 (* lane (+ lane-width
                                            org-timegrid--lane-gap))))
             ;; Clipped to the viewport, so a block that began before it
             ;; still shows the part that has not happened yet.
             (top (max start-minute (plist-get block :start)))
             (bottom (min end-minute (plist-get block :end)))
             (y (* (- top start-minute) scale))
             (block-height (max 3 (- (* (- bottom top) scale)
                                     org-timegrid-block-gap)))
             (characters (max 1 (floor (/ (- lane-width 8) character-width))))
             (lines (unless (< (plist-get block :start) start-minute)
                      (org-timegrid--wrap-title
                       (plist-get block :title) characters
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
                             :fill (if (plist-get block :done)
                                       (plist-get palette :muted)
                                     (plist-get palette :foreground)))))))
    ;; Shade an edge only when the day has something past it.  A shadow over
    ;; an empty evening claims there is more to see, and there is not.
    (when (and (> start-minute 0)
               (seq-some (lambda (block)
                           (< (plist-get block :start) start-minute))
                         blocks))
      (org-timegrid--draw-edge-shadow svg 0 0 width 1 palette))
    (when (and (< end-minute 1440)
               (seq-some (lambda (block)
                           (> (plist-get block :end) end-minute))
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
  (let* ((preview (plist-get org-timegrid--state :preview))
         (replace-id (plist-get preview :replace-id))
         (blocks (plist-get org-timegrid--state :blocks)))
    (mapcan
     #'org-timegrid--display-segments
     (if (null preview)
         blocks
       (append (if replace-id
                   (cl-remove replace-id blocks
                              :key (lambda (block) (plist-get block :id))
                              :test #'equal)
                 blocks)
               (list (plist-get preview :block)))))))

(defun org-timegrid--window-width ()
  "Return the prototype window's body width in pixels."
  (if-let ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window t)
    900))

(defun org-timegrid--ensure-state ()
  "Ensure the current prototype buffer has a usable calendar state.
Keep existing blocks when possible, but reconstruct missing date metadata."
  (let ((state (and (boundp 'org-timegrid--state) org-timegrid--state)))
    (unless (numberp (plist-get state :week-start))
      (setq-local
       org-timegrid--state
       (if (and (listp state) (plist-member state :blocks))
           (plist-put state :week-start
                      (org-timegrid-week-start))
         (org-timegrid--load-state (org-timegrid-week-start)))))
    org-timegrid--state))

(defun org-timegrid--svg ()
  "Build the calendar SVG and update hit-test geometry."
  (org-timegrid--ensure-state)
  (let* ((width (max 560 (org-timegrid--window-width)))
         (start-minute (* 60 org-timegrid-start-hour))
         (end-minute (* 60 org-timegrid-end-hour))
         (scale org-timegrid-pixels-per-minute)
         (height (ceiling (* (- end-minute start-minute) scale)))
         (column-width (/ (- width org-timegrid--label-width)
                          7.0))
         (svg (svg-create width height :stroke-width 0))
         (palette (org-timegrid--palette))
         (font-family (let ((family (face-attribute 'default :family nil t)))
                        (if (stringp family) family "monospace")))
         (today-column
          (- (calendar-absolute-from-gregorian (calendar-current-date))
             (plist-get org-timegrid--state :week-start)))
         (blocks (org-timegrid--effective-blocks))
         (day-blocks (make-vector 7 nil))
         geometry)
    (setq-local org-timegrid--image-height height)
    (svg-rectangle svg 0 0 width height :fill (plist-get palette :background))
    (svg-rectangle svg 0 0 org-timegrid--label-width height
                   :fill (plist-get palette :time-background))
    (dotimes (day 7)
      (let ((x (+ org-timegrid--label-width
                  (* day column-width))))
        (svg-rectangle svg x 0 column-width height
                       :fill (cond ((= day today-column) (plist-get palette :today))
                                   ((memq day '(5 6)) (plist-get palette :weekend))
                                   (t (plist-get palette :background))))
        (svg-line svg x 0 x height
                  :stroke (plist-get palette :grid) :stroke-width 1)
        (aset day-blocks day
              (org-timegrid--layout-day blocks day))))
    (svg-line svg width 0 width height
              :stroke (plist-get palette :grid) :stroke-width 1)
    (cl-loop for minute from start-minute to end-minute by 30 do
             (let* ((y (* (- minute start-minute) scale))
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
        (let* ((day-x (+ org-timegrid--label-width
                         (* day column-width)))
               (horizontal
                (org-timegrid--layout-frame
                 block day-x column-width))
               (x (car horizontal))
               (boundary-edge (plist-get block :boundary-edge))
               (raw-y
                (cond ((eq boundary-edge 'top)
                       (- height
                          org-timegrid-midnight-grip-pixels))
                      ((eq boundary-edge 'bottom) 0)
                      (t (* (- (plist-get block :start) start-minute) scale))))
               (raw-height
                (if boundary-edge
                    (+ org-timegrid-midnight-grip-pixels
                       org-timegrid-block-gap)
                  (* (- (plist-get block :end)
                        (plist-get block :start)) scale)))
               (gap org-timegrid-block-gap)
               (y (+ raw-y (/ gap 2.0)))
               (block-height (max 4 (- raw-height gap)))
               (block-width
                (max 4
                     (- (cdr horizontal) 1)))
               (selected (and (not (plist-get block :preview))
                              (equal (plist-get block :id)
                                     (org-timegrid--selected-id))))
               (fill (org-timegrid--color block palette))
               (accent (org-timegrid--accent block palette))
               (title (plist-get block :title))
               (font-size (if (< block-height 13) 8 10))
               (line-height (if (= font-size 8) 10 13))
               (characters
                (max 1 (floor (/ (- block-width 12)
                                 (* font-size 0.62)))))
               (max-lines
                (max 1 (floor (/ (max 1 (- block-height 3)) line-height))))
               (title-lines
                (org-timegrid--wrap-title
                 title characters max-lines))
               (clip-id (format "occs-block-%s-%x"
                                day (sxhash (plist-get block :id))))
               (clip (svg-clip-path svg :id clip-id))
               (radius (max 0 org-timegrid-corner-radius))
               (accent-radius (min 1.5 (/ radius 2.0))))
          (svg-rectangle clip x y block-width block-height
                         :rx radius :ry radius)
          (push (list :id (plist-get block :id) :day day
                      :start (plist-get block :start) :end (plist-get block :end)
                      :x x :y y :width block-width :height block-height
                      :preview (plist-get block :preview)
                      :allow-top (plist-get block :allow-top)
                      :allow-bottom (plist-get block :allow-bottom)
                      :boundary-edge boundary-edge)
                geometry)
          (svg-rectangle svg x y block-width block-height
                         :rx radius :ry radius :fill fill
                         :fill-opacity (if (plist-get block :preview) 0.72 1)
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
                             :fill (if (plist-get block :done)
                                       (plist-get palette :muted)
                                     (plist-get palette :foreground))))
          (when (and (not boundary-edge)
                     (< (length title-lines) max-lines))
            (svg-text svg
                      (org-timegrid--format-range
                       (or (plist-get block :source-start)
                           (plist-get block :start))
                       (or (plist-get block :source-end)
                           (plist-get block :end)))
                      :x (+ x 9)
                      :y (+ y 10 (* (length title-lines) line-height))
                      :font-size 9
                      :font-family font-family
                      :clip-path (format "url(#%s)" clip-id)
                      :fill (plist-get palette :secondary-text))))))
    ;; The keyboard cursor is one fifteen-minute slot drawn over the blocks.
    ;; Its fill is translucent so a block underneath stays readable, and it
    ;; is drawn only while visible.
    (when-let* (((org-timegrid--cursor-visible-p))
                ;; A selected block already draws its own outline, and two
                ;; borders around one slot read as a bug.
                ((null (org-timegrid--selected-id)))
                (cursor (org-timegrid--cursor))
                (cursor-minute (plist-get cursor :minute)))
      (when (<= start-minute cursor-minute (- end-minute
                                              org-timegrid-slot-minutes))
        ;; A cursor that selects a block narrows to that block's lane, which
        ;; is what makes one lane among several visible.  Otherwise it spans
        ;; the whole day column.
        (let* ((rectangle (org-timegrid--cursor-rectangle geometry))
               (x (plist-get rectangle :x))
               (width (plist-get rectangle :width))
               (y (* (- cursor-minute start-minute) scale)))
          (svg-rectangle svg x y width
                         (* org-timegrid-slot-minutes scale)
                         :fill (plist-get palette :cursor)
                         :fill-opacity org-timegrid-cursor-opacity
                         :stroke (plist-get palette :cursor)
                         :stroke-width 1
                         :rx org-timegrid-corner-radius))))
    (let* ((now (decode-time))
           (today (calendar-absolute-from-gregorian (calendar-current-date)))
           (today-day (- today (plist-get org-timegrid--state :week-start)))
           (now-minute (+ (* 60 (decoded-time-hour now))
                          (decoded-time-minute now))))
      (when (and (<= 0 today-day 6)
                 (<= start-minute now-minute end-minute))
        (let* ((y (* (- now-minute start-minute) scale))
               (today-x (+ org-timegrid--label-width
                            (* today-day column-width)))
               (label (format "%02d:%02d"
                              (decoded-time-hour now)
                              (decoded-time-minute now)))
               (bubble-width 34)
               (bubble-height 12)
               (bubble-x (/ (- org-timegrid--label-width bubble-width) 2.0))
               (bubble-right (+ bubble-x bubble-width))
               (today-line-x (if (= today-day 0) bubble-right today-x))
               (bubble-y (max 1 (min (- height bubble-height 1)
                                     (- y (/ bubble-height 2.0))))))
          ;; Keep the line as quiet context in the other day columns.  The
          ;; opaque segment and dot make today's column unambiguous.
          (svg-line svg bubble-right y width y
                    :stroke (plist-get palette :red) :stroke-width 2
                    :stroke-opacity 0.16)
          (svg-line svg today-line-x y (+ today-x column-width) y
                    :stroke (plist-get palette :red) :stroke-width 2)
          ;; On the first day the pill meets today's line, so a dot at the
          ;; same join only makes the marker look swollen.
          (when (> today-day 0)
            (svg-circle svg today-x y 4
                        :fill (plist-get palette :red)))
          (svg-rectangle svg bubble-x bubble-y bubble-width
                         bubble-height :rx 6 :ry 6
                         :fill (plist-get palette :red))
          (svg-text svg label :x (/ org-timegrid--label-width 2.0)
                    :y (+ bubble-y 9) :font-size 7 :font-weight "600"
                    :font-family font-family :text-anchor "middle"
                    :fill "#ffffff"))))
    (setq-local org-timegrid--geometry geometry)
    svg))

(defun org-timegrid--header ()
  "Return a pixel-aligned SVG header for the calendar."
  (org-timegrid--ensure-state)
  (let* ((window (get-buffer-window (current-buffer) t))
         (left-offset (if window (or (car (window-fringes window)) 0) 0))
         (canvas-width
          (max 560 (org-timegrid--window-width)))
         (width (+ left-offset canvas-width))
         (height 28)
         (column-width (/ (- canvas-width
                             org-timegrid--label-width)
                          7.0))
         (palette (org-timegrid--palette))
         (font-family (let ((family (face-attribute 'default :family nil t)))
                        (if (stringp family) family "monospace")))
         (week-start (plist-get org-timegrid--state :week-start))
         (today (calendar-absolute-from-gregorian (calendar-current-date)))
         (svg (svg-create width height :stroke-width 0)))
    (svg-rectangle svg 0 0 width height
                   :fill (plist-get palette :time-background))
    (svg-text svg "Time" :x (+ left-offset 5) :y 19
              :font-size 11 :font-weight "600"
              :font-family font-family :fill (plist-get palette :foreground))
    (dotimes (day 7)
      (let* ((absolute (+ week-start day))
             (x (+ left-offset
                   org-timegrid--label-width
                   (* day column-width))))
        (when (= absolute today)
          (svg-rectangle svg x 0 column-width height
                         :fill (plist-get palette :today)))
        (svg-line svg x 0 x height
                  :stroke (plist-get palette :grid) :stroke-width 1)
        (svg-text svg
                  (org-timegrid-date-label absolute)
                  :x (+ x 7) :y 19 :font-size 11 :font-weight "600"
                  :font-family font-family
                  :fill (plist-get palette :foreground))))
    (svg-line svg 0 (1- height) width (1- height)
              :stroke (plist-get palette :grid) :stroke-width 1)
    (propertize " " 'display (svg-image svg :ascent 0))))

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
                        `(pointer vdrag
                                  help-echo ,(if (eq boundary-edge 'top)
                                                 "Drag into this day to change the start time"
                                               "Drag into this day to change the end time")))
                  edges))
           (t
            (when (plist-get geometry :allow-top)
              (push (list `(rect . ((,x . ,(max 0 (- y slop)))
                                    . (,right . ,(+ y edge))))
                          'calendar-resize
                          '(pointer vdrag help-echo "Drag to change the start time"))
                    edges))
            (when (plist-get geometry :allow-bottom)
              (push (list `(rect . ((,x . ,(- bottom edge))
                                    . (,right . ,(+ bottom slop))))
                          'calendar-resize
                          '(pointer vdrag help-echo "Drag to change the end time"))
                    edges))
            (push (list `(rect . ((,x . ,y) . (,right . ,bottom)))
                        'calendar-block
                        '(pointer hand help-echo "Drag to move; double-click to open"))
                  bodies))))))
    (append edges bodies)))

(defun org-timegrid--refresh (&optional preserve-scroll)
  "Redraw the SVG, preserving pixel scroll when PRESERVE-SCROLL is non-nil."
  (org-timegrid--ensure-state)
  (let* ((window (get-buffer-window (current-buffer) t))
         (window-vscroll (and window (window-vscroll window t)))
         (vscroll (and preserve-scroll window
                       (if (and (zerop window-vscroll)
                                (> org-timegrid--saved-vscroll 0))
                           org-timegrid--saved-vscroll
                         window-vscroll)))
         (inhibit-read-only t)
         (previewp (plist-get org-timegrid--state :preview))
         (svg (org-timegrid--svg))
         (image-map (and (not previewp)
                         (org-timegrid--image-map)))
         (image (if image-map
                    (svg-image svg :ascent 0
                               :map image-map :original-map image-map)
                  (svg-image svg :ascent 0))))
    (when (overlayp org-timegrid--pointer-overlay)
      (delete-overlay org-timegrid--pointer-overlay)
      (setq-local org-timegrid--pointer-overlay nil))
    (erase-buffer)
    (let ((start (point)))
      (insert-image image " ")
      (add-text-properties start (point)
                           '(occs-svg-image t
                             help-echo "Drag empty time to create; drag blocks to move or resize")))
    (unless (and previewp header-line-format)
      (setq-local header-line-format
                  (org-timegrid--header)))
    (setq-local org-timegrid--last-width
                (org-timegrid--window-width))
    (set-buffer-modified-p nil)
    (when window
      (set-window-point window (point-min))
      (redisplay)
      (when vscroll
        (org-timegrid--set-vscroll window vscroll)))))

(defun org-timegrid--set-vscroll (window pixels)
  "Set WINDOW's pixel scroll to PIXELS and remember it."
  (set-window-vscroll window pixels t)
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
      0 nil
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
                 (zerop (window-vscroll window t))
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
                       org-timegrid--cursor-timer
                       org-timegrid--scroll-restore-timer))
    (when (timerp timer) (cancel-timer timer))))

(defun org-timegrid--clock-tick (buffer)
  "Redraw the current-time indicator in visible calendar BUFFER."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'org-timegrid-mode)
                 (null (plist-get org-timegrid--state :preview)))
        (org-timegrid--refresh t)))))

(defun org-timegrid--data-tick (buffer)
  "Reload visible calendar BUFFER, or mark it stale while hidden."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'org-timegrid-mode)
        (if (get-buffer-window buffer t)
            (org-timegrid-refresh)
          (setq-local org-timegrid--stale t))))))

(defun org-timegrid--position-image-xy (position)
  "Return stable full-SVG pixel coordinates for mouse POSITION.
Use window-relative X so crossing image-map hotspots and day columns cannot
reset the horizontal origin.  Glyph-relative Y retains the position within the
tall, pixel-scrolled SVG."
  (let ((window-xy (posn-x-y position))
        (object-xy (posn-object-x-y position)))
    (when (or window-xy object-xy)
      (cons (or (car-safe window-xy) (car-safe object-xy))
            (or (cdr-safe object-xy) (cdr-safe window-xy))))))

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
                           (floor (/ y
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
        (list :block-id (plist-get geometry :id)
              :day day :minute minute :edge edge)))))

(defun org-timegrid--set-preview (proposal)
  "Display PROPOSAL without committing it."
  (let ((preview (and proposal (not (plist-get proposal :error)) proposal)))
    (unless (equal preview (plist-get org-timegrid--state :preview))
      (setq-local org-timegrid--state (plist-put org-timegrid--state :preview preview))
      (org-timegrid--refresh t))))

(defun org-timegrid--clear-preview ()
  "Remove a pending SVG preview."
  (when (plist-get org-timegrid--state :preview)
    (setq-local org-timegrid--state (plist-put org-timegrid--state :preview nil))
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
    ;; Not interactively: a reload must not forget the cursor.
    (org-timegrid-refresh)))

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
    (org-timegrid-refresh)))

(defun org-timegrid-remove-selected (&optional keep-entry)
  "Remove the selected block from its calendar source.
KEEP-ENTRY skips the offer to delete the entry itself, which is what a
cut wants: the entry has to survive for the yank to copy it."
  (interactive)
  (let ((id (org-timegrid--selected-id)))
    (if (null id)
        (message "No block selected")
      (let* ((event (plist-get (org-timegrid--block id) :event))
             (deleter (org-timegrid-backend-delete-function
                       org-timegrid--backend)))
        (unless (and event (functionp deleter))
          (user-error "This backend cannot remove calendar entries"))
        (funcall deleter event)
        (org-timegrid-refresh)
        (unless keep-entry
          (org-timegrid--offer-entry-deletion event))))))

(defun org-timegrid-edit-selected-title ()
  "Edit the selected calendar block's source heading title."
  (interactive)
  (let* ((id (org-timegrid--selected-id))
         (source (and id (org-timegrid--block id))))
    (if (null source)
        (message "No block selected")
      (let ((title (org-timegrid--read-title (plist-get source :title))))
        (unless (string-empty-p title)
          (let ((event (plist-get source :event))
                (updater (org-timegrid-backend-update-function
                          org-timegrid--backend)))
            (unless (and event (functionp updater))
              (user-error "This backend cannot rename calendar entries"))
            (funcall updater event
                     (org-timegrid-event-start event)
                     (org-timegrid-event-end event)
                     title)
            (org-timegrid-refresh)))))))

(defun org-timegrid--read-title (&optional initial)
  "Read a block title in the echo area, prefilled with INITIAL."
  (read-string "Title: " initial))

(defun org-timegrid--block-absolute-range (block)
  "Return BLOCK's absolute (START . END) minute range."
  (let ((day-minute
         (* (+ (plist-get org-timegrid--state :week-start)
               (plist-get block :day))
            1440)))
    (cons (+ day-minute (plist-get block :start))
          (+ day-minute (plist-get block :end)))))

(defun org-timegrid--backend-create (title block &optional source-event target)
  "Ask the active backend to create TITLE using BLOCK's range."
  (let ((creator (org-timegrid-backend-create-function
                  org-timegrid--backend))
        (range (org-timegrid--block-absolute-range block)))
    (unless (functionp creator)
      (user-error "This backend cannot create calendar entries"))
    (if target
        (funcall creator title (car range) (cdr range) source-event target)
      (funcall creator title (car range) (cdr range) source-event))
    (org-timegrid-refresh)))

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
         (event (plist-get block :event))
         (range (org-timegrid--block-absolute-range block)))
    (unless (and event (functionp updater))
      (user-error "This backend cannot move or resize calendar entries"))
    (condition-case error-data
        (progn
          (funcall updater event (car range) (cdr range))
          (org-timegrid-refresh))
      (error
       (org-timegrid-refresh)
       (signal (car error-data) (cdr error-data))))))

(defun org-timegrid--apply (proposal)
  "Commit SVG drag PROPOSAL."
  (let ((error-message (plist-get proposal :error))
        (kind (plist-get proposal :kind))
        (block (copy-sequence (plist-get proposal :block))))
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
          (setq-local org-timegrid--state (plist-put org-timegrid--state :preview nil))
          (org-timegrid--refresh t))
        (unless (string-empty-p (car entry))
          (org-timegrid--backend-create
           (car entry) block nil (cdr entry)))))
     ((eq kind 'copy)
      (setq-local org-timegrid--state (plist-put org-timegrid--state :preview nil))
      (let ((source (org-timegrid--block (plist-get block :id))))
        (org-timegrid--backend-create
         (plist-get source :title) block (plist-get source :event))))
     ((memq kind '(move resize))
      (setq-local org-timegrid--state (plist-put org-timegrid--state :preview nil))
      (plist-put block :preview nil)
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
    (setq-local org-timegrid--state
                (plist-put org-timegrid--state :cursor-visible t))
    (if block
        (org-timegrid--goto-block block)
      (when (and (plist-get target :day) (plist-get target :minute))
        (org-timegrid--set-cursor (plist-get target :day)
                                  (plist-get target :minute))
        (org-timegrid--refresh t)))))

(defun org-timegrid-visit (event)
  "Visit the source event under double-click mouse EVENT."
  (interactive "@e")
  (let* ((target (org-timegrid--target (event-start event)))
         (block (org-timegrid--block
                 (plist-get target :block-id)))
         (calendar-event (plist-get block :event))
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
  "Track a complete create, move, copy, or resize gesture from EVENT."
  (interactive "@e")
  (when mark-active (deactivate-mark))
  (let* ((origin-position (event-start event))
         (origin (org-timegrid--target origin-position))
         ;; Super, which is the Option key under the usual macOS mapping.
         (copying (memq 'super (event-modifiers event)))
         (required-callback
          (and org-timegrid--backend
               (if (or copying (null (plist-get origin :block-id)))
                   (org-timegrid-backend-create-function
                    org-timegrid--backend)
                 (org-timegrid-backend-update-function
                  org-timegrid--backend)))))
    (if (and org-timegrid--backend
             (not (functionp required-callback)))
        (progn
          (org-timegrid-click (list 'mouse-1 origin-position))
          (message "Unsupported drag"))
      (let* (
           (origin-xy
            (org-timegrid--position-image-xy origin-position))
           (end-position origin-position)
           dragged finished next basic)
      (track-mouse
        (while (not finished)
          (setq next (read-event)
                basic (event-basic-type next))
          (cond
           ((mouse-movement-p next)
            (setq next
                  (org-timegrid--latest-motion-event next))
            (setq end-position (event-end next))
            (let ((xy
                   (org-timegrid--position-image-xy
                    end-position)))
              (when (and origin-xy xy (not (equal origin-xy xy)))
                (setq dragged t)
                (org-timegrid--set-preview
                 (org-timegrid--proposal
                  origin (org-timegrid--target end-position)
                  copying)))))
           ((memq basic '(mouse-1 drag-mouse-1))
            (setq end-position (event-end next) finished t))
           ((eq basic 'switch-frame))
           (t (push next unread-command-events)
              (setq finished 'cancelled)))))
      (cond
       ((eq finished 'cancelled)
        (org-timegrid--clear-preview))
       (dragged
        (org-timegrid--apply
         (org-timegrid--proposal
          origin (org-timegrid--target end-position)
          copying)))
       (t (org-timegrid-click
           (list 'mouse-1 origin-position))))))))

(defun org-timegrid-pointer-feedback (event)
  "Set a resize or move pointer under SVG mouse EVENT."
  (interactive "e")
  (let* ((position (event-end event))
         (window (posn-window position)))
    (when (windowp window)
      (with-current-buffer (window-buffer window)
        (let* ((target (org-timegrid--target position))
               (shape (cond ((plist-get target :edge) 'vdrag)
                            ((plist-get target :block-id) 'hand)))
               (point (posn-point position)))
          (when (integer-or-marker-p point)
            (unless (overlayp org-timegrid--pointer-overlay)
              (setq-local org-timegrid--pointer-overlay
                          (make-overlay point (1+ point))))
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
                              (+ (window-vscroll window t) pixels)))))
            (org-timegrid--set-vscroll window next)))))))

(defun org-timegrid--event-window (event)
  "Return the live calendar window associated with mouse EVENT."
  (let ((window (posn-window (event-start event))))
    (and (window-live-p window)
         (with-current-buffer (window-buffer window)
           (derived-mode-p 'org-timegrid-mode))
         window)))

;;; Keyboard cursor
;;
;; A full redraw of a realistic week costs about fifteen milliseconds, which
;; keeps up with a single keypress comfortably.  Held auto-repeat can outrun
;; it, so a burst updates the cursor in state and paints once when input
;; stops, mirroring how `org-timegrid--latest-motion-event' collapses queued
;; mouse motion.

(defun org-timegrid--cursor-flush (buffer)
  "Draw BUFFER's pending cursor movement."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local org-timegrid--cursor-timer nil)
      (when (derived-mode-p 'org-timegrid-mode)
        (org-timegrid--refresh t)
        (org-timegrid--scroll-cursor-into-view)))))

(defun org-timegrid--cursor-moved ()
  "Redraw after a cursor move, coalescing a burst of held keys."
  (if (input-pending-p)
      (let ((buffer (current-buffer)))
        (unless (timerp org-timegrid--cursor-timer)
          (setq-local org-timegrid--cursor-timer
                      (run-with-idle-timer
                       0 nil #'org-timegrid--cursor-flush buffer))))
    (when (timerp org-timegrid--cursor-timer)
      (cancel-timer org-timegrid--cursor-timer)
      (setq-local org-timegrid--cursor-timer nil))
    (org-timegrid--refresh t)
    (org-timegrid--scroll-cursor-into-view)))

(defun org-timegrid--scroll-cursor-into-view ()
  "Scroll the minimum amount that makes the whole cursor slot visible."
  (when-let* ((cursor (org-timegrid--cursor))
              (window (get-buffer-window (current-buffer) t)))
    (let* ((scale org-timegrid-pixels-per-minute)
           (start-minute (* 60 org-timegrid-start-hour))
           (top (* (- (plist-get cursor :minute) start-minute) scale))
           (bottom (+ top (* org-timegrid-slot-minutes scale)))
           (body (window-body-height window t))
           (vscroll (window-vscroll window t))
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
             (top (* (- (plist-get cursor :minute)
                        (* 60 org-timegrid-start-hour))
                     scale))
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
      (org-timegrid--set-cursor (+ (plist-get cursor :day) days)
                                (+ (plist-get cursor :minute) minutes)))
    (org-timegrid--cursor-moved)))

(defun org-timegrid--step-to-boundary (minute count)
  "Return MINUTE moved COUNT steps onto absolute clock boundaries.
From 02:15 one step forward is 03:00, not 03:15, so stepping always lands
on the hour rather than carrying an arbitrary offset around."
  (let* ((step (max 1 org-timegrid-cursor-step-minutes))
         (direction (if (< count 0) -1 1))
         (remaining (abs count))
         (result minute))
    (while (> remaining 0)
      (setq result
            (if (> direction 0)
                (* step (1+ (floor result step)))
              ;; Floor first so a mid-step position steps back to the
              ;; boundary below it rather than a full step past it.
              (let ((floored (* step (floor result step))))
                (if (= floored result) (- result step) floored))))
      (setq remaining (1- remaining)))
    result))

(defun org-timegrid--snap-toward (minute direction)
  "Round MINUTE onto the slot grid, in DIRECTION.
Org ranges need not be slot-aligned: a block ending at 14:10 has to
become 14:15 going forward, or a stop would send the cursor backwards and
so appear stuck."
  (let ((slot org-timegrid-slot-minutes))
    (if (> direction 0)
        (* slot (ceiling minute slot))
      (* slot (floor minute slot)))))

(defun org-timegrid--lane-count (day minute)
  "Return how many blocks start in the slot at DAY and MINUTE."
  (length (org-timegrid--blocks-starting-at day minute)))

(defun org-timegrid--next-stop (day minute direction)
  "Return the next cursor stop from MINUTE on DAY going DIRECTION.
One step at a time, unless a block edge falls in between.  Both starts
and ends are stops, so a block can be neither stepped over nor have the
gap after it skipped."
  (let* ((boundary (org-timegrid--step-to-boundary minute direction))
         (edges
          (delete-dups
           (mapcan
            (lambda (block)
              (append
               ;; A start snaps down, onto the slot that contains it and so
               ;; selects the block; an end snaps up, onto the first free
               ;; slot after it.  Snapping by direction instead would make
               ;; the two directions disagree about off-grid edges.
               (list (org-timegrid--snap-toward (plist-get block :start) -1))
               ;; An end at or past midnight is not a slot in this day.
               (when (< (plist-get block :end) (* 60 24))
                 (list (org-timegrid--snap-toward
                        (plist-get block :end) 1)))))
            (seq-filter (lambda (block)
                          (and (not (plist-get block :preview))
                               (= (plist-get block :day) day)))
                        (plist-get org-timegrid--state :blocks)))))
         (between (seq-filter
                   (lambda (edge)
                     (if (> direction 0)
                         (and (> edge minute) (< edge boundary))
                       (and (< edge minute) (> edge boundary))))
                   edges)))
    (cond
     ((null between) boundary)
     ((> direction 0) (apply #'min between))
     (t (apply #'max between)))))

(defun org-timegrid-cursor-forward (&optional count)
  "Move the cursor COUNT stops later.
A stop is the next step boundary, or a block edge when one comes first.
Where several blocks share a start, each of their lanes is a stop as
well, so vertical motion alone reaches both of two events beginning at
the same minute rather than only the shortest."
  (interactive "p")
  (if (org-timegrid--reveal-cursor)
      (org-timegrid--cursor-moved)
    (let* ((count (or count 1))
           (direction (if (< count 0) -1 1))
           (cursor (org-timegrid--cursor))
           (day (plist-get cursor :day))
           (minute (plist-get cursor :minute))
           (lane (or (plist-get cursor :lane) 0)))
      (dotimes (_ (abs count))
        (cond
         ((and (> direction 0)
               (< (1+ lane) (org-timegrid--lane-count day minute)))
          (setq lane (1+ lane)))
         ((and (< direction 0) (> lane 0))
          (setq lane (1- lane)))
         (t
          (setq minute (org-timegrid--next-stop day minute direction))
          ;; Arriving from below lands on the slot's last lane, so moving
          ;; back up retraces exactly the lanes moving down visited.
          (setq lane (if (> direction 0)
                         0
                       (max 0 (1- (org-timegrid--lane-count day minute))))))))
      (org-timegrid--set-cursor day minute lane))
    (org-timegrid--cursor-moved)))

(defun org-timegrid-cursor-backward (&optional count)
  "Move the cursor COUNT stops earlier."
  (interactive "p")
  (org-timegrid-cursor-forward (- (or count 1))))

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
           (lane (or (plist-get cursor :lane) 0))
           (lanes (org-timegrid--lane-count (plist-get cursor :day)
                                            (plist-get cursor :minute))))
      (if (and (> count 0) (< (1+ lane) lanes))
          (org-timegrid--set-cursor (plist-get cursor :day)
                                    (plist-get cursor :minute) (1+ lane))
        (if (and (< count 0) (> lane 0))
            (org-timegrid--set-cursor (plist-get cursor :day)
                                      (plist-get cursor :minute) (1- lane))
          (let* ((target (+ (plist-get cursor :day) count))
                 (week-offset (* 7 (floor target 7)))
                 (day (mod target 7))
                 (minute (plist-get cursor :minute)))
            (when (/= week-offset 0)
              (org-timegrid--reload-state
               (+ (plist-get org-timegrid--state :week-start)
                  week-offset)))
            (org-timegrid--set-cursor day minute 0)))
      (org-timegrid--cursor-moved)))))

(defun org-timegrid-cursor-backward-day (&optional count)
  "Move the cursor one lane to the left, or COUNT day columns."
  (interactive "p")
  (org-timegrid-cursor-forward-day (- (or count 1))))

(defun org-timegrid-cursor-day-start ()
  "Move the cursor to midnight in its own day."
  (interactive)
  (unless (org-timegrid--reveal-cursor)
    (org-timegrid--set-cursor (plist-get (org-timegrid--cursor) :day) 0))
  (org-timegrid--cursor-moved))

(defun org-timegrid-cursor-day-end ()
  "Move the cursor to the last slot of its own day."
  (interactive)
  (unless (org-timegrid--reveal-cursor)
    (org-timegrid--set-cursor (plist-get (org-timegrid--cursor) :day)
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
  (+ (* (plist-get block :day) 1440) (plist-get block :start)))

(defun org-timegrid--ordered-blocks ()
  "Return committed blocks ordered by start time.
Start order is what makes \\[org-timegrid-next-block] land on an
overlapping block first: anything that overlaps the current block by
definition starts before the current one ends."
  (sort (seq-filter (lambda (block) (not (plist-get block :preview)))
                    (copy-sequence (plist-get org-timegrid--state :blocks)))
        (lambda (left right)
          (let ((left-start (org-timegrid--block-absolute-start left))
                (right-start (org-timegrid--block-absolute-start right)))
            (if (= left-start right-start)
                (string< (format "%S" (plist-get left :id))
                         (format "%S" (plist-get right :id)))
              (< left-start right-start))))))

(defun org-timegrid--goto-block (block)
  "Move the cursor to BLOCK's own first slot, which selects it.
The lane records which of several blocks sharing that start is meant, so
co-starting entries stay individually reachable."
  (let* ((day (plist-get block :day))
         (start (plist-get block :start))
         (lane (or (cl-position (plist-get block :id)
                               (org-timegrid--blocks-starting-at day start)
                               :key (lambda (candidate) (plist-get candidate :id))
                               :test #'equal)
                   0)))
    (org-timegrid--set-cursor day start lane)
    (setq-local org-timegrid--state
                (plist-put org-timegrid--state :cursor-visible t))
    (org-timegrid--refresh t)
    (org-timegrid--scroll-cursor-into-view)))

(defun org-timegrid--move-selection (direction)
  "Select the next block in DIRECTION across the visible week.
DIRECTION is 1 for later or -1 for earlier.  Without a selection the
search starts from the cursor."
  (let* ((blocks (org-timegrid--ordered-blocks))
         (selected (org-timegrid--selected-id))
         (index (and selected
                     (cl-position selected blocks
                                  :key (lambda (block) (plist-get block :id))
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
  (let ((minute (plist-get (org-timegrid--ensure-cursor) :minute)))
    (org-timegrid--reload-state
     (+ (plist-get org-timegrid--state :week-start) (* direction 7)))
    (if-let ((blocks (org-timegrid--ordered-blocks)))
        (org-timegrid--goto-block
         (if (> direction 0) (car blocks) (car (last blocks))))
      (org-timegrid--set-cursor (if (> direction 0) 0 6) minute 0)
      (setq-local org-timegrid--state
                  (plist-put org-timegrid--state :cursor-visible t))
      (org-timegrid--refresh t)
      (message "No block in this week"))))

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
      (let* ((slot-start (org-timegrid--cursor-absolute))
             (slot-end (+ slot-start org-timegrid-slot-minutes)))
        (car (sort (seq-filter
                    (lambda (block)
                      (let* ((start (org-timegrid--block-absolute-start block))
                             (end (+ start (- (plist-get block :end)
                                              (plist-get block :start)))))
                        (and (not (plist-get block :preview))
                             (< start slot-end)
                             (> end slot-start))))
                    (copy-sequence (plist-get org-timegrid--state :blocks)))
                   (lambda (left right)
                     (< (- (plist-get left :end) (plist-get left :start))
                        (- (plist-get right :end) (plist-get right :start)))))))))

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

(defun org-timegrid--follow-block (id day minute)
  "Put the cursor back on block ID, or on DAY and MINUTE if it is gone.
Selection is derived from the cursor, so an edit that leaves the cursor
behind deselects the very block it changed, and the key cannot be pressed
twice.  Following by id also picks up the block's new lane."
  (if-let ((block (org-timegrid--block id)))
      (org-timegrid--goto-block block)
    (org-timegrid--set-cursor day minute 0)
    (setq-local org-timegrid--state
                (plist-put org-timegrid--state :cursor-visible t))
    (org-timegrid--refresh t)
    (org-timegrid--scroll-cursor-into-view)))

(defun org-timegrid--edit-selected (minutes days edge)
  "Shift the selected block by MINUTES and DAYS.
EDGE nil moves the whole block, `top' changes its start, and `bottom'
changes its end.  The cursor follows, so the key can be held down."
  (let* ((block (org-timegrid--selected-block))
         (anchor (if (eq edge 'bottom)
                     (plist-get block :end)
                   (plist-get block :start)))
         (day (plist-get block :day))
         ;; A bottom-edge proposal ends the block one slot *after* the
         ;; targeted slot, which is what a mouse release should do.  A
         ;; keyboard delta names the new end directly, so aim one slot
         ;; earlier to avoid moving twice as far.
         (bias (if (eq edge 'bottom) (- org-timegrid-slot-minutes) 0))
         (absolute (+ (* day 1440) anchor (* days 1440) minutes bias))
         (origin (list :block-id (plist-get block :id)
                       :day day :minute anchor :edge edge))
         (target (list :day (floor absolute 1440)
                       :minute (% absolute 1440)))
         (proposal (org-timegrid--proposal origin target nil)))
    (org-timegrid--apply proposal)
    (unless (plist-get proposal :error)
      (let ((moved (plist-get proposal :block)))
        (org-timegrid--follow-block (plist-get block :id)
                                    (plist-get moved :day)
                                    (plist-get moved :start))))))

(defun org-timegrid-copy-to-next-day (&optional count)
  "Copy the selected block COUNT days later, at the same time.
The cursor follows the copy, so holding the key spreads one entry across
consecutive days instead of stacking every copy on the same one."
  (interactive "p")
  (let* ((block (org-timegrid--selected-block))
         (start (plist-get block :start))
         (day (+ (plist-get block :day) (or count 1)))
         (title (plist-get block :title)))
    (unless (<= 0 day 6)
      (user-error "That day is outside the visible week"))
    (let ((copy (copy-sequence block)))
      (plist-put copy :day day)
      (org-timegrid--backend-create title copy (plist-get block :event)))
    ;; A copy is a new entry whose identity the calendar cannot predict, so
    ;; the slot is what the cursor follows.
    (let* ((candidates (org-timegrid--blocks-starting-at day start))
           (lane (or (cl-position title candidates
                                  :key (lambda (candidate)
                                         (plist-get candidate :title))
                                  :test #'equal)
                     0)))
      (org-timegrid--set-cursor day start lane)
      (setq-local org-timegrid--state
                  (plist-put org-timegrid--state :cursor-visible t))
      (org-timegrid--refresh t)
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

(defun org-timegrid-create-at-cursor ()
  "Create a block at the cursor, prompting for a title and a duration."
  (interactive)
  (org-timegrid--reveal-cursor)
  (let* ((cursor (org-timegrid--ensure-cursor))
         (entry (org-timegrid--read-entry))
         (title (car entry)))
    (if (string-empty-p title)
        (message "Nothing created")
      (let* ((minutes (org-timegrid--read-minutes
                       org-timegrid-default-duration-minutes))
             (start (plist-get cursor :minute))
             (block (org-timegrid--make-block
                     'new (plist-get cursor :day) start (+ start minutes)
                     title 'blue)))
        (org-timegrid--backend-create title block nil (cdr entry))))))

(defun org-timegrid-open-at-cursor ()
  "Visit the block under the cursor, or create one when the slot is empty."
  (interactive)
  (org-timegrid--reveal-cursor)
  (let ((block (org-timegrid--block-at-cursor)))
    (if (null block)
        (org-timegrid-create-at-cursor)
      (let ((event (plist-get block :event))
            (visitor (and org-timegrid--backend
                          (org-timegrid-backend-visit-function
                           org-timegrid--backend))))
        (if (and event (functionp visitor))
            (funcall visitor event)
          (message "No source to visit"))))))

;;; Keyboard copy, cut, and yank

(defvar org-timegrid--kill nil
  "Plist describing the most recently copied block.
Holds :title, :minutes, and the opaque :event needed to reproduce the
entry's content, so a yank survives cutting the original.")

(defun org-timegrid-copy-selected ()
  "Copy the selected block for a later yank."
  (interactive)
  (let ((block (org-timegrid--selected-block)))
    (setq org-timegrid--kill
          (list :title (plist-get block :title)
                :minutes (- (plist-get block :end) (plist-get block :start))
                :event (plist-get block :event)))
    (message "Copied %s" (plist-get block :title))))

(defun org-timegrid-cut-selected ()
  "Copy the selected block, then remove it from its calendar source."
  (interactive)
  (org-timegrid-copy-selected)
  (org-timegrid-remove-selected t))

(defun org-timegrid-yank ()
  "Create a copy of the most recently copied block at the cursor."
  (interactive)
  (unless org-timegrid--kill
    (user-error "Nothing copied yet; select a block and press M-w"))
  (org-timegrid--reveal-cursor)
  (let* ((cursor (org-timegrid--ensure-cursor))
         (minutes (plist-get org-timegrid--kill :minutes))
         (block (org-timegrid--make-block
                 'yank (plist-get cursor :day)
                 (plist-get cursor :minute)
                 (+ (plist-get cursor :minute) minutes)
                 (plist-get org-timegrid--kill :title) 'blue)))
    (org-timegrid--backend-create
     (plist-get org-timegrid--kill :title) block
     (plist-get org-timegrid--kill :event))))

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
         (week-start (plist-get org-timegrid--state :week-start))
         (absolute-start (+ (* (+ week-start (plist-get block :day)) 1440)
                            (plist-get block :start)))
         (minutes (- (plist-get block :end) (plist-get block :start)))
         (answer (org-timegrid--read-timestamp absolute-start minutes))
         (start (car answer))
         (duration (max org-timegrid-slot-minutes
                        (or (cdr answer)
                            (org-timegrid--read-minutes minutes))))
         (updater (org-timegrid-backend-update-function
                   org-timegrid--backend)))
    (unless (and (plist-get block :event) (functionp updater))
      (user-error "This backend cannot re-time calendar entries"))
    (funcall updater (plist-get block :event) start (+ start duration) nil)
    (org-timegrid-refresh)))

;;; Dates

(defun org-timegrid-goto-date ()
  "Show the week containing a date read from the user."
  (interactive)
  (let* ((cursor-absolute
          (+ (* (+ (plist-get org-timegrid--state :week-start)
                   (plist-get (org-timegrid--ensure-cursor) :day))
                1440)
             (plist-get (org-timegrid--ensure-cursor) :minute)))
         (answer (org-timegrid--read-timestamp
                   cursor-absolute org-timegrid-slot-minutes))
         (absolute (floor (car answer) 1440)))
    (org-timegrid--reload-state (org-timegrid-week-start absolute))
    (org-timegrid--set-cursor
     (- absolute (plist-get org-timegrid--state :week-start))
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
    (setq-local org-timegrid--state
                (plist-put org-timegrid--state :cursor
                           (and visible
                                (org-timegrid--default-cursor
                                 (plist-get org-timegrid--state :week-start)))))
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
  (setq-local org-timegrid--state
              (plist-put org-timegrid--state :preview nil))
  (setq-local org-timegrid--state
              (plist-put org-timegrid--state :cursor-visible nil))
  (org-timegrid--refresh t))

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
   (+ (plist-get org-timegrid--state :week-start) days))
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

(defun org-timegrid-refresh (&optional interactively)
  "Reload the displayed week from the current backend and redraw it.
Called INTERACTIVELY it also forgets the cursor, which is the one action
that resets it.  Automatic reloads keep it, so the periodic data timer
cannot quietly move the user's place."
  (interactive (list t))
  (org-timegrid--reload-state (plist-get org-timegrid--state :week-start))
  (when interactively
    (setq-local org-timegrid--state (plist-put org-timegrid--state :cursor nil))
    (setq-local org-timegrid--state
                (plist-put org-timegrid--state :cursor-visible nil)))
  (org-timegrid--refresh))

(defvar org-timegrid-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map [down-mouse-1]
                #'org-timegrid-press)
    (define-key map [s-down-mouse-1]
                #'org-timegrid-press)
    (define-key map [mouse-1] #'org-timegrid-click)
    (define-key map [double-mouse-1] #'org-timegrid-visit)
    (dolist (area '(calendar-block calendar-resize))
      (define-key map (vector area 'down-mouse-1)
                  #'org-timegrid-press)
      (define-key map (vector area 's-down-mouse-1)
                  #'org-timegrid-press)
      (define-key map (vector area 'mouse-1)
                  #'org-timegrid-click)
      (define-key map (vector area 'double-mouse-1)
                  #'org-timegrid-visit)
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
    ;; Fine cursor motion, kept clear of the resize and move keys.
    (keymap-set map "M-<down>" #'org-timegrid-cursor-forward-slot)
    (keymap-set map "M-<up>" #'org-timegrid-cursor-backward-slot)
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
    (keymap-set map "M-S-<down>" #'org-timegrid-move-later)
    (keymap-set map "M-S-<up>" #'org-timegrid-move-earlier)
    (keymap-set map "M-S-<right>" #'org-timegrid-move-next-day)
    (keymap-set map "M-S-<left>" #'org-timegrid-move-previous-day)
    ;; Super is Option under the usual macOS mapping, as it is for a
    ;; duplicating drag, so the copy gesture reads the same either way.
    (keymap-set map "M-S-s-<right>" #'org-timegrid-copy-to-next-day)
    (keymap-set map "M-S-s-<left>" #'org-timegrid-copy-to-previous-day)
    (keymap-set map "S-<down>" #'org-timegrid-grow-end)
    (keymap-set map "S-<up>" #'org-timegrid-shrink-end)
    (keymap-set map "C-S-<up>" #'org-timegrid-grow-start)
    (keymap-set map "C-S-<down>" #'org-timegrid-shrink-start)
    (keymap-set map "t" #'org-timegrid-retime-selected)
    (keymap-set map "M-w" #'org-timegrid-copy-selected)
    (keymap-set map "C-w" #'org-timegrid-cut-selected)
    (keymap-set map "C-y" #'org-timegrid-yank)
    ;; Dates and files.
    (keymap-set map "j" #'org-timegrid-goto-date)
    (keymap-set map "." #'org-timegrid-goto-today)
    (keymap-set map "q" #'quit-window)
    map))

(define-derived-mode org-timegrid-mode special-mode
  "Org Time Grid"
  "Major mode for an SVG week calendar.

The cursor is one slot of `org-timegrid-slot-minutes'.  A block is
selected exactly when the cursor sits on that block's own first slot, so
the mouse and the keyboard drive the same state.

\\{org-timegrid-mode-map}"
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local track-mouse t)
  (setq-local mouse-fine-grained-tracking t)
  (setq-local auto-window-vscroll t)
  (add-hook 'window-size-change-functions
            #'org-timegrid--window-resized nil t)
  (add-hook 'kill-buffer-hook
            #'org-timegrid--cancel-timers nil t))

(defun org-timegrid--center-now (window)
  "Center the current time vertically in WINDOW."
  (let* ((now (decode-time))
         (minute (+ (* 60 (decoded-time-hour now))
                    (decoded-time-minute now)))
         (start-minute (* 60 org-timegrid-start-hour))
         (y (* (- minute start-minute)
               org-timegrid-pixels-per-minute))
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
          (let ((current-week (plist-get org-timegrid--state :week-start)))
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
;;; org-timegrid.el ends here
