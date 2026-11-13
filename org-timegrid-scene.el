;;; org-timegrid-scene.el --- Drawing contracts for org-timegrid -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Components consume calendar state and a captured render context. They return
;; (KIND . PROPERTIES) nodes with :key, :x, :y, :width and :height. Optional
;; :bleed declares visual overflow (such as stroke width) outside that box.
;; Nodes contain data, never SVG, images, buffers or timers.
;; Style settings register here at their declaration; the display runtime owns
;; cache identity and lifetime. The SVG adapter interprets the drawing kinds.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'subr-x)
(require 'org-timegrid-model)

(defvar org-timegrid--geometry)
(defvar org-timegrid--scene)

(declare-function org-timegrid--default-font-size "org-timegrid-display" (&optional window))
(declare-function org-timegrid--window-width "org-timegrid-display" ())
(declare-function org-timegrid--face-palette "org-timegrid-display" ())

(defvar org-timegrid--style-variables '(org-timegrid-slot-minutes)
  "Settings consumed by drawing components, registered at their declarations.")

(defmacro org-timegrid--defstyle (name value doc &rest options)
  "Declare drawing input NAME with VALUE and DOC.
With OPTIONS, declare a Custom option; otherwise declare an internal variable.
Its captured value automatically participates in display cache identity."
  (declare (indent 2) (doc-string 3))
  `(progn
     (,(if options 'defcustom 'defvar) ,name ,value ,doc ,@options)
     (cl-pushnew ',name org-timegrid--style-variables)))

(cl-defstruct (org-timegrid--render-context
               (:constructor org-timegrid--render-context-create))
  "A value snapshot shared by layout, painting and display cache identity.
MINUTE is last because it expires only the current-time overlay."
  settings width zoom frame-scale font palette today header-offset minute)

(defvar org-timegrid--render-context nil
  "Rendering inputs bound for the current composition, or nil outside it.")

(defconst org-timegrid--label-width 54)

(defconst org-timegrid--base-pixels-per-minute 0.9)
(defconst org-timegrid--cursor-opacity 0.22)
(defconst org-timegrid--compact-shadow-pixels 10)

(defconst org-timegrid--grid-top-inset 6
  "Pixels between the sticky date rail and the midnight grid line.")

(cl-defstruct (org-timegrid--scene (:constructor org-timegrid--scene-create))
  "Resolved drawing nodes and preview bounds, independent of the image renderer."
  nodes geometry context width height)

(defgroup org-timegrid nil
  "An SVG week calendar for Emacs, edited by mouse and keyboard."
  :group 'calendar
  :prefix "org-timegrid-")

(org-timegrid--defstyle org-timegrid-start-hour 0
  "First hour drawn in the week canvas."
  :type 'integer)

(org-timegrid--defstyle org-timegrid-end-hour 24
  "Hour at the bottom edge of the week canvas."
  :type 'integer)

(org-timegrid--defstyle org-timegrid-time-format '12h
  "Clock format for calendar labels and displayed time ranges.
With `12h', hour labels use smaller AM/PM suffixes.
Org timestamps retain their standard 24-hour format.
Run `org-timegrid-refresh' after changing this option in an open calendar."
  :type '(choice (const :tag "12-hour (3 PM)" 12h)
                 (const :tag "24-hour (15:00)" 24h)))

(org-timegrid--defstyle org-timegrid-days 7
  "Number of consecutive days displayed in the calendar.
The initial range is positioned using `org-timegrid-range-alignment'.
The value must be a positive integer."
  :type '(integer :tag "Days"))

(org-timegrid--defstyle org-timegrid-highlight-current-day nil
  "Non-nil means tint today's column in the timed grid.")

(org-timegrid--defstyle org-timegrid-default-zoom 0.7
  "Base zoom multiplier for scalable calendar content.
The value must be a positive number.  Buffer-local text-scale commands apply
on top of it and reset to this configured base."
  :type 'number)

(org-timegrid--defstyle org-timegrid--resize-pixels 8
  "Height of the top and bottom resize zones in pixels.")

(org-timegrid--defstyle org-timegrid--resize-slop 3
  "Extra pixels outside a block that count as a resize edge.")

(org-timegrid--defstyle org-timegrid-colors
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
backend can speak in terms a user recognises.")

(org-timegrid--defstyle org-timegrid-default-color 'blue
  "Colour for an event whose backend gives it none.
A name in `org-timegrid-colors', or any colour string."
  :type '(choice symbol color))

(org-timegrid--defstyle org-timegrid-all-day-max-lanes 5
  "Maximum number of all-day event lanes shown in the sticky date rail.
Overflow is summarized per day."
  :type 'integer)

(org-timegrid--defstyle org-timegrid-header-title-style
    '(:font-size 24 :character-width 14.6 :height 44 :baseline 35)
  "Geometry of the month and year title in SVG pixels.")

(org-timegrid--defstyle org-timegrid-single-day-label-style
    '(:scale 1.0 :x-offset -4 :gap 5)
  "Scale, optical offset, and gap of the one-day weekday and date label.")

(defconst org-timegrid--lane-gap 3)

(defconst org-timegrid--clock-rail-width 20
  "Reference width in pixels of a day's clock rail.")

(org-timegrid--defstyle org-timegrid--clock-corner-radius 3
  "Reference corner radius in pixels for clock boundary highlights.")

(defconst org-timegrid--header-date-height 30)

(defconst org-timegrid--reference-font-size 10
  "Default-face pixel size for which the SVG's design sizes are specified.")

(defconst org-timegrid--reference-font-height 18
  "Frame character height for which the fixed header sizes are specified.")

(defvar org-timegrid--static-render nil)

(defvar-local org-timegrid--state nil)

(defun org-timegrid--context-key (context)
  "Return CONTEXT's static identity, excluding the separately drawn clock."
  (when context
    (let ((key (copy-org-timegrid--render-context context)))
      (setf (org-timegrid--render-context-minute key) nil)
      key)))

(defmacro org-timegrid--with-render-context (context &rest body)
  "Evaluate BODY with drawing inputs from CONTEXT.
Dynamic bindings let small geometry helpers share the same frozen values;
components cannot accidentally observe a newer setting halfway through a pass."
  (declare (indent 1) (debug t))
  (let ((inputs (make-symbol "context")))
    `(let ((,inputs ,context))
       (if (eq ,inputs org-timegrid--render-context)
           (progn ,@body)
         (let ((org-timegrid--render-context ,inputs))
           (cl-progv (mapcar #'car (org-timegrid--render-context-settings ,inputs))
               (mapcar #'cdr (org-timegrid--render-context-settings ,inputs))
             ,@body))))))

(defun org-timegrid--context-height (context)
  "Return the full time-grid height for CONTEXT."
  (org-timegrid--with-render-context context
    (+ (org-timegrid--grid-top-inset)
       (ceiling (* 60 (- org-timegrid-end-hour org-timegrid-start-hour)
                   (org-timegrid--pixels-per-minute))))))

(defun org-timegrid--identify-node (node)
  "Give NODE an identity local to its component and event segment."
  (let ((bounds (cdr node)))
    (setq bounds (plist-put (copy-sequence bounds) :bleed
                            (pcase (car node)
                              ('block (if (plist-member bounds :static-index) 2 1))
                              ('selection 1)
                              ((or 'region 'cursor) 0.5)
                              (_ 0))))
    (cons (car node)
          (plist-put bounds :key
                     (list (car node) (plist-get bounds :id)
                           (plist-get bounds :day) (plist-get bounds :boundary-edge)
                           (and (eq (car node) 'region) (plist-get bounds :x)))))))

(defun org-timegrid--last-day-index ()
  "Return the zero-based index of the final visible day."
  (1- org-timegrid-days))

(defun org-timegrid--clock-edge-padding ()
  "Return space for the clock badge beyond the final day's boundary."
  (* (org-timegrid--scale-pixels org-timegrid--clock-rail-width) 0.5))

(defun org-timegrid--zoom-factor (&optional window)
  "Return the unified SVG scale implied by WINDOW's default font.
Typography and geometry share this factor so their alignment is preserved."
  (if org-timegrid--render-context
      (org-timegrid--render-context-zoom org-timegrid--render-context)
    (/ (org-timegrid--default-font-size window)
       (float org-timegrid--reference-font-size))))

(defun org-timegrid--frame-font-factor (&optional window)
  "Return WINDOW's fixed-header scale without calendar or text zoom."
  (if org-timegrid--render-context
      (org-timegrid--render-context-frame-scale org-timegrid--render-context)
    (let* ((window (or window (get-buffer-window (current-buffer) t)))
           (frame (and (window-live-p window) (window-frame window))))
      (/ (frame-char-height frame)
         (float org-timegrid--reference-font-height)))))

(defun org-timegrid--frame-scale-pixels (pixels &optional window)
  "Scale PIXELS with WINDOW's frame font, excluding buffer-local zoom."
  (* pixels (org-timegrid--frame-font-factor window)))

(defun org-timegrid--single-day-label-factor (&optional window)
  "Return the unified scale for WINDOW's one-day weekday and date label."
  (* (plist-get org-timegrid-single-day-label-style :scale)
     (max (org-timegrid--frame-font-factor window)
          (org-timegrid--zoom-factor window))))

(defun org-timegrid--scale-pixels (pixels)
  "Scale vertical PIXELS by the current buffer's text zoom."
  (* pixels (org-timegrid--zoom-factor)))

(defun org-timegrid--pixels-per-minute ()
  "Return the zoom-adjusted vertical calendar scale."
  (* org-timegrid--base-pixels-per-minute (org-timegrid--zoom-factor)))

(defun org-timegrid--font-size (size)
  "Return SVG font SIZE adjusted by the unified calendar zoom."
  (* size (org-timegrid--zoom-factor)))

(defun org-timegrid--font-family ()
  "Return the default SVG font family, falling back to monospace."
  (if org-timegrid--render-context
      (org-timegrid--render-context-font org-timegrid--render-context)
    (let ((family (face-attribute 'default :family nil t)))
      (if (stringp family) family "monospace"))))

(defun org-timegrid--label-width ()
  "Return the width of the time-label gutter.
Let it grow with buffer zoom, but not shrink below the frame-font width needed
by the fixed week label in the header."
  (max (org-timegrid--scale-pixels org-timegrid--label-width)
       (org-timegrid--frame-scale-pixels org-timegrid--label-width)))

(defun org-timegrid--grid-top-inset ()
  "Return the zoom-adjusted inset above the timed grid."
  (org-timegrid--scale-pixels org-timegrid--grid-top-inset))

(defun org-timegrid--header-title-height ()
  "Return the fixed month-and-year title section height."
  (plist-get org-timegrid-header-title-style :height))

(defun org-timegrid--rail-top ()
  "Return the top of the all-day rail.
The title stays fixed and the date row follows only the frame's base font."
  (+ (org-timegrid--header-title-height)
     (if (= org-timegrid-days 1)
         0
       (org-timegrid--frame-scale-pixels org-timegrid--header-date-height))))

(defun org-timegrid--all-day-lane-height ()
  "Return the zoom-adjusted height of one all-day lane."
  (org-timegrid--scale-pixels 22))

(defun org-timegrid--timed-blocks ()
  "Return the current state's timed blocks."
  (seq-remove #'org-timegrid-block-all-day-p
              (org-timegrid--calendar-state-blocks org-timegrid--state)))

(defun org-timegrid--all-day-blocks ()
  "Return the current state's all-day blocks."
  (seq-filter #'org-timegrid-block-all-day-p
              (org-timegrid--calendar-state-blocks org-timegrid--state)))

(defun org-timegrid--cursor ()
  "Return the remembered cursor position, which may be hidden."
  (org-timegrid--calendar-state-cursor org-timegrid--state))

(defun org-timegrid--cursor-visible-p ()
  "Return non-nil when the cursor is currently drawn."
  (org-timegrid--calendar-state-cursor-visible org-timegrid--state))

(defun org-timegrid--selected-id ()
  "Return the explicitly selected block id, or nil while hidden."
  (and (org-timegrid--cursor-visible-p)
       (org-timegrid--calendar-state-selected-id org-timegrid--state)))

(defun org-timegrid--cursor-rectangle (&optional geometry-list)
  "Return the cursor slot's pixel rectangle, or nil while it is hidden.
The rectangle narrows to the selected block's lane, which is how one lane
among several is visible at all.  GEOMETRY-LIST defaults to the committed
geometry.  GEOMETRY-LIST may supply an alternative layout."
  (when-let* (((org-timegrid--cursor-visible-p))
              (cursor (org-timegrid--cursor)))
    (let* ((column (org-timegrid--column-width))
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
                 (+ 1 (org-timegrid--label-width)
                    (* (org-timegrid--cursor-state-day cursor) column)))
            :y (+ (org-timegrid--grid-top-inset)
                  (* (- (org-timegrid--cursor-state-minute cursor)
                        (* 60 org-timegrid-start-hour))
                     (org-timegrid--pixels-per-minute)))
            :width (if lane (plist-get lane :width) (- column 2))
            :height (* org-timegrid-slot-minutes
                       (org-timegrid--pixels-per-minute))))))

(defun org-timegrid--cursor-calendar-minute ()
  "Return the cursor as an absolute Gregorian minute."
  (+ (* (org-timegrid--calendar-state-week-start org-timegrid--state) 1440)
     (org-timegrid--cursor-absolute)))

(defun org-timegrid-region-active-p ()
  "Return non-nil when the calendar mark is active."
  (and (org-timegrid--calendar-state-region-active org-timegrid--state)
       (integerp (org-timegrid--calendar-state-mark org-timegrid--state))))

(defun org-timegrid--region-range ()
  "Return the active calendar region as a normalized half-open range.
Mark and point are boundaries, as in an ordinary Emacs buffer.  The
calendar's block cursor paints the slot after point, but that slot is
not itself part of the region."
  (when (org-timegrid-region-active-p)
    (let ((mark (org-timegrid--calendar-state-mark org-timegrid--state))
          (point (org-timegrid--cursor-calendar-minute)))
      (cons (min mark point) (max mark point)))))

(defun org-timegrid--today ()
  "Return the date captured for this drawing pass."
  (if org-timegrid--render-context
      (org-timegrid--render-context-today org-timegrid--render-context)
    (calendar-current-date)))

(defun org-timegrid--clock-block-p (block)
  "Return non-nil when BLOCK represents a recorded clock."
  (when-let* ((event (org-timegrid-block-event block)))
    (plist-get (org-timegrid-event-metadata event) :clock)))

(defun org-timegrid--layout-day (blocks day)
  "Lay out DAY's plans separately from its clock rail."
  (let (plans clocks)
    (dolist (block blocks)
      (when (= day (org-timegrid-block-day block))
        (if (org-timegrid--clock-block-p block)
            (push block clocks)
          (push block plans))))
    ;; Clocks share the day boundary, even when their ranges overlap.
    (append (org-timegrid--layout-plans plans day) (nreverse clocks))))

(defun org-timegrid--layout-plans (blocks day)
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
                             (org-timegrid--pixels-per-minute))
                          (org-timegrid--scale-pixels 18))))
               annotated))
             (parent
              (cl-reduce (lambda (left right)
                           (if (and left
                                    (>= (org-timegrid-block-nest-depth left)
                                        (org-timegrid-block-nest-depth right)))
                               left right))
                         containers :initial-value nil))
             (copy (copy-org-timegrid-block block)))
        (setf (org-timegrid-block-nest-depth copy)
              (if parent
                  (1+ (org-timegrid-block-nest-depth parent))
                0)
              (org-timegrid-block-parent-id copy)
              (and parent (org-timegrid-block-id parent)))
        (push copy annotated)))
    (setq annotated (nreverse annotated))
    (let ((siblings (make-hash-table :test #'equal))
          (local-layout (make-hash-table :test #'equal))
          (output (make-hash-table :test #'equal)))
      (dolist (block annotated)
        (let ((parent-id (org-timegrid-block-parent-id block)))
          (puthash parent-id
                   (cons block (gethash parent-id siblings))
                   siblings)))
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
           (setf (org-timegrid-block-layout-path copy) path)
           (puthash id copy output)
           copy))
       annotated))))

(defun org-timegrid--preview-frame (block)
  "Keep BLOCK's preview lane steady until the edit is committed."
  (when (and (not org-timegrid--static-render) (org-timegrid-block-preview block))
    (let* ((matches
            (lambda (bounds)
              (and (equal (org-timegrid-block-id block) (plist-get bounds :id))
                   (= (org-timegrid-block-day block) (plist-get bounds :day))
                   (eq (org-timegrid-block-boundary-edge block) (plist-get bounds :boundary-edge)))))
           (bounds (or (seq-find matches (and org-timegrid--scene (org-timegrid--scene-geometry org-timegrid--scene)))
                       (seq-find matches org-timegrid--geometry))))
      (when bounds
        (cons (plist-get bounds :x)
              (+ (plist-get bounds :width) (if (org-timegrid--clock-block-p block) 0 1)))))))

(defun org-timegrid--layout-frame
    (block day-x column-width)
  "Return BLOCK's horizontal (X . WIDTH) inside a day column.
DAY-X and COLUMN-WIDTH describe the full column."
  (or (org-timegrid--preview-frame block)
      (let ((x day-x)
            (width column-width)
            (depth 0))
        (when (org-timegrid--clock-block-p block)
          (let* ((rail (min (* column-width 0.3)
                            (org-timegrid--scale-pixels org-timegrid--clock-rail-width)))
                 (bar (min (org-timegrid--scale-pixels 6) (- rail 2))))
            (setq x (+ x column-width (- (/ (+ rail bar) 2.0))) width rail)))
        (dolist (step (org-timegrid-block-layout-path block))
          (when (> depth 0)
            (setq x (+ x 8)
                  width (max 4 (- width 8))))
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
        (cons x width))))

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

(defun org-timegrid--format-minute (minute &optional style)
  "Format MINUTE using `org-timegrid-time-format', wrapping at midnight.
STYLE `hour' omits minutes in 12-hour grid labels; `compact' omits zero
minutes and suffix spacing; `clock' omits AM/PM for the current-time pill."
  (let* ((hour (/ (mod minute 1440) 60))
         (minutes (mod minute 60)))
    (if (eq org-timegrid-time-format '24h)
        (format "%02d:%02d" hour minutes)
      (concat (number-to-string (1+ (mod (1- hour) 12)))
              (unless (or (eq style 'hour) (and (eq style 'compact) (zerop minutes)))
                (format ":%02d" minutes))
              (unless (eq style 'clock)
                (concat (unless (eq style 'compact) " ")
                        (if (< hour 12) "AM" "PM")))))))

(defun org-timegrid--format-range (start end)
  "Format START and END minutes, omitting repeated AM/PM and zero minutes."
  (let* ((day-offset (floor end 1440))
         (twelve-hour (not (eq org-timegrid-time-format '24h)))
         (start-label (org-timegrid--format-minute start 'compact))
         (end-label (org-timegrid--format-minute end 'compact)))
    (when twelve-hour
      (setq start-label (string-remove-suffix (substring end-label -2) start-label)))
    (format "%s%s%s%s"
            start-label (if twelve-hour " – " "–") end-label
            (if (> day-offset 0) (format " (+%d)" day-offset) ""))))

(defun org-timegrid--block-details (block)
  "Return BLOCK's complete time range and title for transient UI."
  (format "%s[%s-%s] %s"
          (if (org-timegrid--clock-block-p block) "Clock " "")
          (org-timegrid--format-minute (org-timegrid-block-start block))
          (org-timegrid--format-minute (org-timegrid-block-end block))
          (or (org-timegrid-block-display-title block) "")))

(defun org-timegrid--resolve-color (color palette)
  "Return COLOR as a colour string, resolving a name through PALETTE.
COLOR is a name in `org-timegrid-colors', any colour string, or nil for
`org-timegrid-default-color'.  An unknown name falls back to the theme's
own accent rather than drawing nothing."
  (let ((color (or color org-timegrid-default-color)))
    (org-timegrid--normalize-color
     (or (and (symbolp color) (cdr (assq color org-timegrid-colors)))
         (and (stringp color) (color-defined-p color) color)
         (cdr (assq org-timegrid-default-color org-timegrid-colors)))
     (plist-get palette :blue))))

(defun org-timegrid--accent (block palette)
  "Return the accent color for BLOCK from PALETTE."
  (if (org-timegrid-block-done block)
      (plist-get palette :muted)
    (org-timegrid--resolve-color (org-timegrid-block-color block) palette)))

(defun org-timegrid--block-text-inset ()
  "Return text spacing that clears the zoom-scaled block accent bar."
  (+ 6 (max 3 (org-timegrid--scale-pixels 1.25))))

(defun org-timegrid--block-opacity (preview)
  "Return the shared fill opacity for blocks and clocks, given PREVIEW."
  (if preview 0.72 0.7))

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
    (dotimes (day org-timegrid-days)
      (let* ((day-start (* day 1440))
             (day-end (+ day-start 1440))
             (segment-start (max absolute-start day-start))
             (segment-end (min absolute-end day-end)))
        (when (< segment-start segment-end)
          (let ((segment (copy-org-timegrid-block block)))
            (setf (org-timegrid-block-source-start segment) source-start
                  (org-timegrid-block-source-end segment) source-end
                  (org-timegrid-block-day segment) day
                  (org-timegrid-block-start segment) (- segment-start day-start)
                  (org-timegrid-block-end segment) (- segment-end day-start)
                  (org-timegrid-block-allow-top segment)
                  (= segment-start absolute-start)
                  (org-timegrid-block-allow-bottom segment)
                  (= segment-end absolute-end))
            (push segment segments)))))
    ;; A range ending exactly at midnight needs a bottom-edge target at
    ;; the top of the next day so it can be extended forward.
    (when (and (= (% absolute-end 1440) 0)
               (< 0 absolute-end (* org-timegrid-days 1440)))
      (let* ((day (/ absolute-end 1440))
             (grip (copy-org-timegrid-block block)))
        (setf (org-timegrid-block-source-start grip) source-start
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
               (< 0 absolute-start (* org-timegrid-days 1440)))
      (let* ((day (1- (/ absolute-start 1440)))
             (grip (copy-org-timegrid-block block)))
        (setf (org-timegrid-block-source-start grip) source-start
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

(defun org-timegrid--background-nodes
    (width height column-width palette start-minute end-minute
           scale days &optional week-start)
  "Describe the shared timed-grid background as bounded drawing nodes.
WIDTH, HEIGHT and COLUMN-WIDTH specify pixel dimensions.
PALETTE and FONT-FAMILY control its appearance; START-MINUTE, END-MINUTE
and SCALE determine the time range and vertical scale.
DAYS controls the columns; WEEK-START enables weekend shading.
Return nodes in paint order."
  (let ((grid-width (or (plist-get palette :grid-width) 1))
        drawings)
    (push (org-timegrid--shape-node
           'background 'rect 0 0 width height :fill (plist-get palette :background)) drawings)
    (push (org-timegrid--shape-node
           'gutter 'rect 0 0 (org-timegrid--label-width) height
           :fill (plist-get palette :time-background)) drawings)
    (dotimes (day days)
      (let* ((x (+ (org-timegrid--label-width) (* day column-width)))
             (absolute (and week-start (+ week-start day)))
             (weekday (and absolute
                           (calendar-day-of-week
                            (calendar-gregorian-from-absolute absolute)))))
        (push (org-timegrid--shape-node
               (list 'day day) 'rect x 0 column-width height
               :fill (cond ((and org-timegrid-highlight-current-day absolute
                                 (= absolute (calendar-absolute-from-gregorian
                                              (org-timegrid--today))))
                            (plist-get palette :today))
                           ((memq weekday '(0 6)) (plist-get palette :weekend))
                           (t (plist-get palette :background)))) drawings)
        (push (org-timegrid--shape-node
               (list 'column day) 'line x 0 0 height :stroke (plist-get palette :grid)
               :stroke-width grid-width) drawings)))
    (push (org-timegrid--shape-node
           'last-column 'line (+ (org-timegrid--label-width) (* days column-width)) 0 0 height
           :stroke (plist-get palette :grid)
           :stroke-width grid-width) drawings)
    (cl-loop for minute from (* 30 (ceiling start-minute 30))
             to end-minute by 30 do
             (let* ((y (+ (org-timegrid--grid-top-inset)
                          (* (- minute start-minute) scale)))
                    (hourp (zerop (% minute 60))))
               (push (org-timegrid--shape-node
                      (list 'grid minute) 'line (org-timegrid--label-width) y
                      (- width (org-timegrid--label-width)) 0
                      :stroke (plist-get palette (if hourp :grid :half-grid))
                      :stroke-width grid-width) drawings)
               (when (and hourp (< minute end-minute))
                 (let ((size (org-timegrid--font-size 10)))
                   (push (cons 'hour-label
                               (list :key (list 'hour minute) :minute minute :baseline y
                                     :x 0 :y (- (+ y (* scale 3.5)) (* 1.5 size))
                                     :width (- (org-timegrid--label-width) 2)
                                     :height (* 2 size))) drawings)))))
    (nreverse drawings)))

(defun org-timegrid--effective-blocks ()
  "Return per-day display segments with the current preview applied."
  (let* ((preview (org-timegrid--calendar-state-preview org-timegrid--state))
         (preview-block (and preview (org-timegrid--operation-block preview)))
         (previews (and preview-block
                        (if (eq (org-timegrid--operation-kind preview) 'push)
                            (org-timegrid--operation-blocks preview)
                          (list preview-block))))
         (ids (org-timegrid--operation-replaced-ids preview)))
    (mapcan
     #'org-timegrid--display-segments
     (append (seq-remove (lambda (block) (member (org-timegrid-block-id block) ids))
                         (org-timegrid--timed-blocks))
             (seq-remove #'org-timegrid-block-all-day-p previews)))))

(defun org-timegrid--canvas-width ()
  "Return the shared SVG width used by rendering and hit testing."
  (if org-timegrid--render-context
      (org-timegrid--render-context-width org-timegrid--render-context)
    (max 560 (org-timegrid--window-width))))

(defun org-timegrid--column-width (&optional width)
  "Return a day column's width in WIDTH or the current calendar canvas."
  (/ (- (or width (org-timegrid--canvas-width)) (org-timegrid--label-width)
        (org-timegrid--clock-edge-padding))
     (float org-timegrid-days)))

(defun org-timegrid--block-geometry
    (block canvas-height start-minute scale column-width)
  "Resolve BLOCK into pixel bounds without drawing or changing view state."
  (let* ((clock (org-timegrid--clock-block-p block))
         (day (org-timegrid-block-day block))
         (day-x (+ (org-timegrid--label-width) (* day column-width)))
         (horizontal (org-timegrid--layout-frame block day-x column-width))
         (x (car horizontal))
         (boundary-edge (org-timegrid-block-boundary-edge block))
         (grip (org-timegrid--scale-pixels 6))
         (raw-y (cond ((eq boundary-edge 'top)
                       (- canvas-height grip))
                      ((eq boundary-edge 'bottom)
                       (org-timegrid--grid-top-inset))
                      (t (+ (org-timegrid--grid-top-inset)
                            (* (- (org-timegrid-block-start block) start-minute)
                               scale)))))
         (raw-height
          (if boundary-edge
              (+ grip (org-timegrid--scale-pixels 1))
            ;; Keep short entries readable without changing their real times.
            (* (max org-timegrid-slot-minutes
                    (- (org-timegrid-block-end block)
                       (org-timegrid-block-start block)))
               scale)))
         (gap (org-timegrid--scale-pixels 1))
         ;; Whole-pixel edges keep the gap clear without a block outline.
         (y (ceiling (+ raw-y (/ gap 2.0))))
         (block-height
          (max 4 (- (floor (- (+ raw-y raw-height) (/ gap 2.0))) y)))
         (block-width (max 4 (- (cdr horizontal) (if clock 0 1))))
         (radius (if clock
                     (min (org-timegrid--scale-pixels org-timegrid--clock-corner-radius)
                          (/ block-width 2.0) (/ block-height 2.0))
                   0))
         (geometry
          (list :block block :id (org-timegrid-block-id block) :day day
                :start (org-timegrid-block-start block) :end (org-timegrid-block-end block)
                :x x :y y :width block-width :height block-height
                :radius radius :clock clock :preview (org-timegrid-block-preview block)
                :title (org-timegrid-block-display-title block) :color (org-timegrid-block-color block)
                :done (org-timegrid-block-done block)
                :allow-top (org-timegrid-block-allow-top block)
                :allow-bottom (org-timegrid-block-allow-bottom block)
                :boundary-edge boundary-edge)))
    geometry))

(defun org-timegrid--timed-layout ()
  "Return timed display layout, painting clock badges above plans."
  (let* ((blocks (org-timegrid--effective-blocks))
         (layout (cl-loop for day below org-timegrid-days
                          append (org-timegrid--layout-day blocks day))))
    ;; Badges cross day boundaries, so paint them above every day's plans.
    (append (seq-remove #'org-timegrid--clock-block-p layout)
            (seq-filter #'org-timegrid--clock-block-p layout))))

(defun org-timegrid-scene-static (state context)
  "Build committed drawing nodes from STATE and CONTEXT, without display effects."
  (org-timegrid--with-render-context context
    (let* ((org-timegrid--state (org-timegrid--calendar-state-create
                                 :week-start (org-timegrid--calendar-state-week-start state)
                                 :events (org-timegrid--calendar-state-events state)
                                 :blocks (org-timegrid--calendar-state-blocks state)))
           (org-timegrid--static-render t)
           (width (org-timegrid--render-context-width context))
           (start-minute (* 60 org-timegrid-start-hour))
           (end-minute (* 60 org-timegrid-end-hour))
           (scale (org-timegrid--pixels-per-minute))
           (height (org-timegrid--context-height context))
           (column-width (org-timegrid--column-width))
           (nodes (nreverse (org-timegrid--background-nodes
                             width height column-width (org-timegrid--palette)
                             start-minute end-minute scale org-timegrid-days
                             (org-timegrid--calendar-state-week-start state))))
           geometry)
      (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil)
      (dolist (block (org-timegrid--timed-layout))
        (let ((bounds (org-timegrid--block-geometry block height start-minute scale column-width)))
          (push (org-timegrid--identify-node
                 (cons 'block (append (list :static-index (length geometry))
                                      bounds))) nodes)
          (push bounds geometry)))
      (org-timegrid--scene-create :nodes (nreverse nodes) :geometry geometry :context context))))

(defun org-timegrid--shape-node (key kind x y width height &rest attributes)
  "Describe a bounded KIND with KEY and drawing ATTRIBUTES, without rendering."
  (cons kind (list :key key :x x :y y :width width :height height
                   :bleed (/ (or (plist-get attributes :stroke-width) 0) 2.0)
                   :attributes attributes)))

(defun org-timegrid-scene-build (state context base-geometry previous &optional proposal)
  "Describe the dynamic grid, optionally substituting preview PROPOSAL.
Neither scene construction nor speculative layout changes the displayed state."
  (org-timegrid--with-render-context context
    (let* ((org-timegrid--state (copy-org-timegrid--calendar-state state))
           (org-timegrid--geometry base-geometry)
           (org-timegrid--scene previous)
           (height (org-timegrid--context-height context))
           (start-minute (* 60 org-timegrid-start-hour))
           (column-width (org-timegrid--column-width))
           (scale (org-timegrid--pixels-per-minute)) nodes geometry)
      (when proposal
        (setf (org-timegrid--calendar-state-preview org-timegrid--state) proposal))
      (let* ((preview (org-timegrid--calendar-state-preview org-timegrid--state))
             (selected (and (null preview) (org-timegrid--selected-id))))
        (when-let* ((range (and (null preview) (org-timegrid--region-range)))
                    ((< (car range) (cdr range))))
          (dotimes (day org-timegrid-days)
            (let* ((day-start (* (+ (org-timegrid--calendar-state-week-start org-timegrid--state)
                                    day) 1440))
                   (start (max (car range) day-start))
                   (end (min (cdr range) (+ day-start 1440))))
              (when (< start end)
                (push (cons 'region
                            (list :x (+ 1 (org-timegrid--label-width) (* day column-width))
                                  :y (+ (org-timegrid--grid-top-inset)
                                        (* (- start day-start start-minute) scale))
                                  :width (- column-width 2) :height (* (- end start) scale)))
                      nodes)))))
        (if selected
            (dolist (bounds org-timegrid--geometry)
              (when (and (equal selected (plist-get bounds :id))
                         (not (plist-get bounds :boundary-edge)))
                (push (cons 'selection bounds) nodes)))
          (when preview
            (dolist (block (org-timegrid--timed-layout))
              (when (and (org-timegrid-block-preview block)
                         (not (org-timegrid-block-boundary-edge block)))
                (let ((bounds (org-timegrid--block-geometry
                               block height start-minute scale column-width)))
                  (push bounds geometry)
                  (push (cons 'block bounds) nodes)
                  (when (and (org-timegrid--operation-handle preview)
                             (org-timegrid--operation-edge preview)
                             (eq (org-timegrid--operation-kind preview) 'resize)
                             (plist-get bounds (if (eq (org-timegrid--operation-edge preview) 'top)
                                                   :allow-top :allow-bottom)))
                    (let* ((clock (plist-get bounds :clock))
                           (width (min (plist-get bounds :width)
                                       (org-timegrid--scale-pixels (if clock 8 32))))
                           (height (if clock width (org-timegrid--scale-pixels 3))))
                      (push (cons 'resize-handle
                                  (list :block block :clock clock
                                        :x (+ (plist-get bounds :x)
                                              (/ (- (plist-get bounds :width) width) 2.0))
                                        :y (- (+ (plist-get bounds :y)
                                                 (if (eq (org-timegrid--operation-edge preview) 'top) 0
                                                   (plist-get bounds :height)))
                                              (/ height 2.0))
                                        :width width :height height))
                            nodes))))))))
        (when (and (null preview) (org-timegrid--cursor-visible-p) (null selected)
                   (eq (org-timegrid--cursor-state-surface (org-timegrid--cursor)) 'grid))
          (when-let* ((bounds (org-timegrid--cursor-rectangle org-timegrid--geometry)))
            (push (cons 'cursor bounds) nodes))))
      (org-timegrid--scene-create :nodes (mapcar #'org-timegrid--identify-node (nreverse nodes)) :geometry (nreverse geometry) :context context))))

(defun org-timegrid--block-paint-key (bounds)
  "Compare all appearance data, excluding only resolved movement and layout.
New painting properties automatically disable partial edge repainting when they
change; callers never maintain a separate list of cache-sensitive styles."
  (let* ((source (plist-get bounds :block))
         (block (and (org-timegrid-block-p source) (copy-org-timegrid-block source))))
    (when block
      (setf (org-timegrid-block-start block) nil (org-timegrid-block-end block) nil
            (org-timegrid-block-source-start block) nil (org-timegrid-block-source-end block) nil
            (org-timegrid-block-nest-depth block) nil (org-timegrid-block-parent-id block) nil
            (org-timegrid-block-layout-path block) nil (org-timegrid-block-lane block) nil
            (org-timegrid-block-lanes block) nil))
    (cl-loop for (key value) on bounds by #'cddr
             unless (memq key '(:y :height :start :end))
             append (list key (if (and (eq key :block) block) block value)))))

(defun org-timegrid--block-damage (old new)
  "Compare OLD and NEW preview bounds, returning changed pixel rectangles.
Return nil for a full repaint when horizontal layout or style changes."
  (when (and old new (= (length old) (length new))
             (cl-every (lambda (a b)
                         (equal (org-timegrid--block-paint-key a) (org-timegrid--block-paint-key b)))
                       old new))
    (let (damage)
      (cl-mapc
       (lambda (a b)
         (let* ((top-a (plist-get a :y)) (top-b (plist-get b :y))
                (end-a (+ top-a (plist-get a :height)))
                (end-b (+ top-b (plist-get b :height)))
                (edge-pad (if (plist-get b :clock)
                              (+ 2 (org-timegrid--scale-pixels org-timegrid--clock-corner-radius)) 2))
                (font (org-timegrid--font-size 10))
                (characters (max 1 (floor (/ (- (plist-get b :width)
                                                (org-timegrid--block-text-inset) 13)
                                             (* font 0.62)))))
                (label-height
                 (org-timegrid--scale-pixels
                  (+ 10 (* 13 (1+ (length (org-timegrid--wrap-title
                                           (or (plist-get b :title) "") characters
                                           (1+ (length (or (plist-get b :title) "")))))))))))
           (dolist (range (append (list (cons (min top-a top-b) (max top-a top-b))
                                        (cons (min end-a end-b) (max end-a end-b)))
                                  (unless (plist-get b :clock)
                                    (list (cons top-a (min end-a (+ top-a label-height)))
                                          (cons top-b (min end-b (+ top-b label-height)))))))
             (when (< (car range) (cdr range))
               (push (list :x (- (plist-get b :x) 2) :width (+ (plist-get b :width) 4)
                           :y (- (car range) edge-pad)
                           :height (+ (- (cdr range) (car range)) (* 2 edge-pad))) damage)))
           (when (plist-get b :clock)
             (dolist (shape (list a b))
               (let ((center (+ (plist-get shape :y) (/ (plist-get shape :height) 2.0))))
                 (push (list :x (- (plist-get shape :x) 2) :width (+ (plist-get shape :width) 4)
                             :y (- center edge-pad) :height (* 2 edge-pad)) damage))))))
       old new)
      damage)))

(defun org-timegrid--padded-bounds (bounds margin)
  "Expand pixel BOUNDS by MARGIN on every side."
  (list :x (- (plist-get bounds :x) margin) :y (- (plist-get bounds :y) margin)
        :width (+ (plist-get bounds :width) (* 2 margin))
        :height (+ (plist-get bounds :height) (* 2 margin))))

(defun org-timegrid--scene-damage (old new)
  "Return changed pixel rectangles between OLD and NEW scenes.
Compare resolved drawing data without SVG, buffers or image-cache effects."
  (let* ((old-nodes (and old (org-timegrid--scene-nodes old)))
         (new-nodes (org-timegrid--scene-nodes new))
         (before (or (cl-loop for node in old-nodes when (eq (car node) 'block) collect (cdr node))
                     (and old (org-timegrid--scene-geometry old))))
         (after (or (cl-loop for node in new-nodes when (eq (car node) 'block) collect (cdr node))
                    (org-timegrid--scene-geometry new)))
         (damage (unless (equal before after)
                   (or (org-timegrid--block-damage before after)
                       (mapcar (lambda (bounds) (org-timegrid--padded-bounds bounds 1))
                               (append before after))))))
    (when (and old (not (equal (org-timegrid--context-key (org-timegrid--scene-context old))
                               (org-timegrid--context-key (org-timegrid--scene-context new)))))
      (setq damage (mapcar (lambda (node)
                             (org-timegrid--padded-bounds (cdr node)
                                                          (or (plist-get (cdr node) :bleed) 0)))
                           (append old-nodes new-nodes))))
    (dolist (pair (list (cons old-nodes new-nodes) (cons new-nodes old-nodes)))
      (dolist (node (car pair))
        (unless (or (eq (car node) 'block) (member node (cdr pair)))
          (let* ((bounds (cdr node))
                 (other (and (eq (car node) 'region)
                             (seq-find (lambda (candidate)
                                         (and (eq (car candidate) 'region)
                                              (= (plist-get bounds :x)
                                                 (plist-get (cdr candidate) :x))
                                              (= (plist-get bounds :width)
                                                 (plist-get (cdr candidate) :width))))
                                       (cdr pair)))))
            (if (not other)
                (push (org-timegrid--padded-bounds
                       bounds (or (plist-get bounds :bleed)
                                  (if (eq (car node) 'selection) 1 0.5))) damage)
              (let* ((top (plist-get bounds :y))
                     (end (+ top (plist-get bounds :height)))
                     (other-top (plist-get (cdr other) :y))
                     (other-end (+ other-top (plist-get (cdr other) :height))))
                ;; Repaint changed fill and both borders, preserving the middle.
                (dolist (range (append (org-timegrid--range-difference
                                        (cons top end) (cons other-top other-end))
                                       (list (cons top top) (cons end end))))
                  (push (org-timegrid--padded-bounds
                         (list :x (plist-get bounds :x) :width (plist-get bounds :width)
                               :y (car range) :height (- (cdr range) (car range))) 0.5) damage))))))))
    damage))

(defun org-timegrid--all-day-less-p (left right)
  "Return non-nil when all-day block LEFT should sort before RIGHT."
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

(defun org-timegrid--compute-all-day-layout ()
  "Return visible all-day blocks annotated with stable rail lanes.
The ordering favours earlier and longer spans, then title and identity."
  (let* ((week-end (* org-timegrid-days 1440))
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

(defun org-timegrid--rail-row-count (layout)
  "Return the visible rail row count needed for all-day LAYOUT.
The final row is intentionally empty and can hold a cross-surface preview."
  (let ((highest-lane (if layout
                          (apply #'max
                                 (mapcar #'org-timegrid-block-rail-lane layout))
                        -1)))
    (1+ (min org-timegrid-all-day-max-lanes (1+ highest-lane)))))

(defun org-timegrid--header-month-parts (week-start)
  "Return the visible month title for WEEK-START as (PRIMARY SECONDARY).
SECONDARY is the final year and is drawn with lighter weight.  PRIMARY
includes both month names when the visible week crosses a boundary."
  (let* ((first (calendar-gregorian-from-absolute week-start))
         (last (calendar-gregorian-from-absolute
                (+ week-start (org-timegrid--last-day-index))))
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
ABSOLUTE-DATE is the first displayed day."
  (org-timegrid--iso-week-format
   (+ absolute-date (floor org-timegrid-days 2)) "W%V"))

(defun org-timegrid--week-current-p (week-start today)
  "Return non-nil when the range starting at WEEK-START includes TODAY."
  (<= week-start today (+ week-start (org-timegrid--last-day-index))))

(defun org-timegrid--edge-height (geometry)
  "Return the pixel resize-zone height for GEOMETRY."
  (min org-timegrid--resize-pixels
       (max 1 (/ (- (plist-get geometry :height) 2) 2.0))))

(defun org-timegrid--edge-at (geometry y)
  "Return `top', `bottom', or nil for the resize zone at pixel Y in GEOMETRY.
A zone reaches `org-timegrid--edge-height' pixels into the block and
the configured platform slop outside it, which is exactly the
hotspot geometry built by `org-timegrid--image-map'.  Slop must not
extend inwards: on a single-slot block the two zones would meet and
leave no central move target."
  (or (plist-get geometry :boundary-edge)
      (let* ((edge-height (org-timegrid--edge-height geometry))
             (slop org-timegrid--resize-slop)
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

(defun org-timegrid--normalize-color (color &optional fallback)
  "Return COLOR as an SVG-safe six-digit hexadecimal string.
Emacs accepts X11 names such as `Red1' that SVG does not.  Resolve every
color through Emacs before handing it to the SVG renderer.  Use FALLBACK
when COLOR cannot be resolved."
  (when-let* ((rgb (or (org-timegrid--rgb color)
                       (org-timegrid--rgb fallback))))
    (apply #'color-rgb-to-hex (append rgb '(2)))))

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

(defun org-timegrid--cursor-absolute ()
  "Return the cursor's absolute week minute."
  (let ((cursor (org-timegrid--ensure-cursor)))
    (+ (* (org-timegrid--cursor-state-day cursor) 1440)
       (org-timegrid--cursor-state-minute cursor))))

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
         (start (org-timegrid--block-absolute-start block))
         (end (+ (* (org-timegrid-block-day block) 1440)
                 (org-timegrid-block-end block)))
         (duration (- end start))
         (week-end (* org-timegrid-days 1440)))
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

;;; Keyboard cursor

(defun org-timegrid--range-difference (left right)
  "Return portions of minute range LEFT not covered by RIGHT."
  (cond
   ((or (null left) (<= (cdr left) (car left))) nil)
   ((or (null right) (<= (cdr right) (car right))) (list left))
   ((or (<= (cdr left) (car right)) (>= (car left) (cdr right)))
    (list left))
   (t
    (delq nil
          (list (and (< (car left) (car right))
                     (cons (car left) (min (cdr left) (car right))))
                (and (> (cdr left) (cdr right))
                     (cons (max (car left) (cdr right)) (cdr left))))))))

;;; Keyboard block selection

(defun org-timegrid--block-absolute-start (block)
  "Return BLOCK's absolute week start minute."
  (+ (* (org-timegrid-block-day block) 1440) (org-timegrid-block-start block)))

(defun org-timegrid--edit-proposal (block minutes days edge)
  "Return one timed or all-day edit preview for BLOCK.
MINUTES and DAYS form the interval delta; EDGE selects a resize endpoint."
  (when (and (null edge) (/= minutes 0)
             (not (org-timegrid-block-all-day-p block)))
    (let ((start (org-timegrid-block-start block)))
      (setq minutes (- (* org-timegrid-slot-minutes
                          (round (+ start minutes) org-timegrid-slot-minutes))
                       start))))
  (org-timegrid--operation-create
   :kind (if edge 'resize 'move) :edge edge
   :block (org-timegrid--transform-block-range
           block (+ minutes (* days 1440)) edge)
   :replace-id (org-timegrid-block-id block)))

(defun org-timegrid--palette ()
  "Return the captured palette, or resolve it from the current faces."
  (if org-timegrid--render-context
      (org-timegrid--render-context-palette org-timegrid--render-context)
    (org-timegrid--face-palette)))

(defun org-timegrid--default-cursor (week-start)
  "Return the initial keyboard cursor for the week at WEEK-START.
It sits on the current calendar slot when today is visible, and on
the first visible day at the configured start hour otherwise."
  (let* ((today (calendar-absolute-from-gregorian (org-timegrid--today)))
         (offset (- today week-start)))
    (if (<= 0 offset (org-timegrid--last-day-index))
        (let ((now (decode-time (and org-timegrid--render-context
                                     (* 60 (org-timegrid--render-context-minute
                                            org-timegrid--render-context))))))
          (org-timegrid--cursor-state-create
           :surface 'grid :day offset
           :minute (org-timegrid--visible-minute
                    (+ (* 60 (decoded-time-hour now))
                       (decoded-time-minute now)))
           :lane 0))
      (org-timegrid--cursor-state-create
       :surface 'grid :day 0
       :minute (* 60 org-timegrid-start-hour) :lane 0))))

(defun org-timegrid--ensure-cursor ()
  "Return the cursor position, defaulting it when nothing is remembered."
  (or (org-timegrid--cursor)
      (let ((cursor (org-timegrid--default-cursor
                     (org-timegrid--calendar-state-week-start
                      org-timegrid--state))))
        (setf (org-timegrid--calendar-state-cursor org-timegrid--state) cursor)
        cursor)))

(defun org-timegrid-scene-day (blocks start-minute end-minute width now context)
  "Compose a read-only day strip from BLOCKS and captured CONTEXT."
  (org-timegrid--with-render-context context
    (let* ((org-timegrid-days 1) (org-timegrid--static-render t)
           (scale (org-timegrid--pixels-per-minute))
           (height (+ (org-timegrid--grid-top-inset)
                      (ceiling (* (max 60 (- end-minute start-minute)) scale))))
           (column (org-timegrid--column-width width))
           (nodes (nreverse (org-timegrid--background-nodes
                             width height column (org-timegrid--palette)
                             start-minute end-minute scale 1))))
      (dolist (block (org-timegrid--layout-day blocks 0))
        (when (and (> (org-timegrid-block-end block) start-minute)
                   (< (org-timegrid-block-start block) end-minute))
          (push (org-timegrid--identify-node
                 (cons 'block (org-timegrid--block-geometry
                               block height start-minute scale column))) nodes)))
      (dolist (edge '(top bottom))
        (when (and (if (eq edge 'top) (> start-minute 0) (< end-minute 1440))
                   (seq-some (lambda (block)
                               (if (eq edge 'top) (< (org-timegrid-block-start block) start-minute)
                                 (> (org-timegrid-block-end block) end-minute))) blocks))
          (let ((shadow (org-timegrid--scale-pixels org-timegrid--compact-shadow-pixels)))
            (push (cons 'edge-shadow
                        (list :key edge :x 0 :y (if (eq edge 'top) 0 (- height shadow))
                              :width width :height shadow :edge-y (if (eq edge 'top) 0 height)
                              :direction (if (eq edge 'top) 1 -1))) nodes))))
      (when (and now (<= start-minute now end-minute))
        (push (cons 'current-time
                    (list :key 'clock :x 0 :y 0 :width width :height height
                          :canvas-height height :column column :start-minute start-minute
                          :minute now :day 0)) nodes))
      (org-timegrid--scene-create :nodes (nreverse nodes) :context context :width width :height height))))

(defun org-timegrid-scene-clock (state context)
  "Describe the current-time overlay from STATE and captured CONTEXT."
  (org-timegrid--with-render-context context
    (let* ((time (decode-time (* 60 (org-timegrid--render-context-minute context))))
           (minute (+ (* 60 (decoded-time-hour time)) (decoded-time-minute time)))
           (day (- (calendar-absolute-from-gregorian (org-timegrid--today))
                   (org-timegrid--calendar-state-week-start state)))
           (start (* 60 org-timegrid-start-hour))
           (y (+ (org-timegrid--grid-top-inset) (* (- minute start) (org-timegrid--pixels-per-minute))))
           (radius (/ (org-timegrid--scale-pixels 14) 2.0)))
      (org-timegrid--scene-create
       :context context
       :nodes (when (and (<= 0 day (org-timegrid--last-day-index))
                         (<= start minute (* 60 org-timegrid-end-hour)))
                (list (cons 'current-time
                            (list :key 'clock :x 0 :y (- y radius 1)
                                  :width (org-timegrid--canvas-width) :height (* 2 (+ radius 1))
                                  :canvas-height (org-timegrid--context-height context)
                                  :column (org-timegrid--column-width) :start-minute start
                                  :minute minute :day day))))))))

(defun org-timegrid--all-day-geometry (block left-offset column-width top)
  "Return BLOCK's rail bounds without generating an image or SVG."
  (let ((x (+ left-offset (org-timegrid--label-width)
              (* (/ (org-timegrid-block-rail-start block) 1440.0) column-width) 2))
        (right (+ left-offset (org-timegrid--label-width)
                  (* (/ (org-timegrid-block-rail-end block) 1440.0) column-width) -2)))
    (list :id (org-timegrid-block-id block) :lane (org-timegrid-block-rail-lane block)
          :x x :y (+ top 2) :width (- right x)
          :height (- (org-timegrid--all-day-lane-height) (org-timegrid--scale-pixels 4))
          :allow-left (not (org-timegrid-block-continues-left block))
          :allow-right (not (org-timegrid-block-continues-right block)))))

(defun org-timegrid-scene-header (state context left-offset)
  "Compose the header component from STATE, CONTEXT and LEFT-OFFSET."
  (org-timegrid--with-render-context context
    (let* ((org-timegrid--state (copy-org-timegrid--calendar-state state))
           (layout (org-timegrid--compute-all-day-layout))
           (rows (or (plist-get (org-timegrid--calendar-state-gesture state) :rail-rows)
                     (org-timegrid--rail-row-count layout)))
           (height (max (+ (org-timegrid--rail-top) (* rows (org-timegrid--all-day-lane-height)))
                        (if (= org-timegrid-days 1)
                            (+ (org-timegrid--rail-top) (* (org-timegrid--single-day-label-factor) 42)) 0)))
           (width (+ left-offset (org-timegrid--canvas-width)))
           (selected (and (org-timegrid--selected-id)
                          (seq-find (lambda (block) (equal (org-timegrid-block-id block)
                                                           (org-timegrid--selected-id))) layout)))
           (cursor (and (org-timegrid--cursor-visible-p) (not selected)
                        (org-timegrid--cursor)
                        (eq (org-timegrid--cursor-state-surface (org-timegrid--cursor)) 'rail)
                        (copy-org-timegrid--cursor-state (org-timegrid--cursor))))
           (header-state (org-timegrid--calendar-state-create
                          :week-start (org-timegrid--calendar-state-week-start state)
                          :selected-id (and selected (org-timegrid-block-id selected))
                          :cursor cursor :cursor-visible (and (or cursor selected) t))))
      (org-timegrid--scene-create
       :context context :width width :height height
       :geometry (nreverse (cl-loop for block in layout
                                    when (< (org-timegrid-block-rail-lane block) org-timegrid-all-day-max-lanes)
                                    collect (org-timegrid--all-day-geometry
                                             block left-offset (org-timegrid--column-width)
                                             (+ (org-timegrid--rail-top)
                                                (* (org-timegrid-block-rail-lane block)
                                                   (org-timegrid--all-day-lane-height))))))
       :nodes (list (cons 'header
                          (list :key 'header :x 0 :y 0 :width width :height height
                                :state header-state :layout layout :rows rows :left-offset left-offset)))))))

(defun org-timegrid--snap-minute (minute)
  "Return MINUTE rounded down to a calendar slot inside one day."
  (let ((slots (/ (- (* 60 24) org-timegrid-slot-minutes)
                  org-timegrid-slot-minutes)))
    (* org-timegrid-slot-minutes
       (max 0 (min slots (floor minute org-timegrid-slot-minutes))))))

(defun org-timegrid--visible-minute (minute)
  "Clamp MINUTE to a rendered grid slot."
  (max (* 60 org-timegrid-start-hour)
       (min (- (* 60 org-timegrid-end-hour) org-timegrid-slot-minutes)
            (org-timegrid--snap-minute minute))))

(provide 'org-timegrid-scene)
;;; org-timegrid-scene.el ends here
