;;; org-timegrid-svg.el --- SVG adapter for org-timegrid -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; SVG interpretation of bounded scene nodes. No file IO or display caches.

;;; Code:

(require 'org-timegrid-scene)
(require 'svg)

(defun org-timegrid--draw-repeater (svg x y color)
  "Draw a small repeat icon on SVG with its top left at X, Y in COLOR."
  (let ((top-transform (format "translate(%g %g) scale(0.24)" x y))
        (bottom-transform (format "translate(%g %g) scale(0.24)" x (1+ y))))
    (svg-node svg 'path :transform bottom-transform :fill color
              :stroke color :stroke-width 1.5 :stroke-linejoin "round"
              :d "M27.18 22.949h-22.497l4.492-4.494-0.754-0.754-5.743 5.744 5.743 5.743 0.754-0.754-4.419-4.42h23.491v-9.596h-1.066z")
    (svg-node svg 'path :transform top-transform :fill color
              :stroke color :stroke-width 1.5 :stroke-linejoin "round"
              :d "M4.793 9.088h22.488l-4.456 4.457 0.754 0.754 5.742-5.742-5.743-5.744-0.754 0.754 4.454 4.456h-23.552v9.596h1.066z")))

(defun org-timegrid--draw-text (svg text &rest args)
  "Draw TEXT in SVG using ARGS accepted by `svg-text'.
The extra :small-period option draws AM/PM at 80 percent of the font size.
Platform support files may advise this small seam when their SVG renderer
cannot display text elements."
  (if (not (plist-get args :small-period))
      (apply #'svg-text svg text args)
    (let ((size (plist-get args :font-size))
          (start 0))
      (cl-remf args :small-period)
      (let ((node (apply #'svg-node svg 'text args)))
        (while (string-match "[AP]M" text start)
          (dom-append-child node (substring text start (match-beginning 0)))
          (dom-append-child node
                            `(tspan ((font-size . ,(* size 0.8)))
                                    ,(match-string 0 text)))
          (setq start (match-end 0)))
        (dom-append-child node (substring text start))))))

(defun org-timegrid--draw-hour-label (svg minute y palette font-family)
  "Draw MINUTE's grid label on SVG at Y using PALETTE and FONT-FAMILY."
  (let* ((parts (split-string (org-timegrid--format-minute minute 'hour)))
         (suffix (cadr parts))
         (x (if suffix
                (- (org-timegrid--label-width) (org-timegrid--scale-pixels 22))
              (/ (org-timegrid--label-width) 2.0)))
         ;; Clock digits extend about 0.7 em above the baseline.
         (baseline (+ y (org-timegrid--scale-pixels 3.5))))
    (org-timegrid--draw-text
     svg (car parts) :x x :y baseline
     :font-size (org-timegrid--font-size 10) :font-family font-family
     :text-anchor (if suffix "end" "middle")
     :fill (plist-get palette :time-label))
    (when suffix
      (org-timegrid--draw-text
       svg suffix :x (+ x (org-timegrid--scale-pixels 3)) :y baseline
       :font-size (org-timegrid--font-size 7) :font-family font-family
       :text-anchor "start"
       :fill (plist-get palette :time-period)))))

(defun org-timegrid--draw-edge-shadow (svg x y width direction palette)
  "Shade WIDTH pixels of SVG inward from X and Y, going DIRECTION.
DIRECTION is 1 for an edge at the top and -1 for one at the bottom.
A shadow always darkens, whatever the theme.  The usual advice is to lift
rather than darken on a dark background, but a pale band across the foot
of a dark calendar reads as a highlight, not as depth.  Stacked bands
rather than an SVG gradient: five rectangles are indistinguishable at this
size and need no gradient definition."
  (let* ((bands 5)
         (band (/ (org-timegrid--scale-pixels
                   (float org-timegrid-compact-shadow-pixels))
                  bands))
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

(defun org-timegrid--draw-timed-background
    (svg width height column-width palette font-family start-minute end-minute
         scale days &optional week-start)
  "Paint shared background nodes into SVG, returning bounded SVG drawings."
  (mapcar (lambda (node)
            (cons (cdr node) (org-timegrid--paint-node svg node palette font-family)))
          (org-timegrid--background-nodes
           width height column-width palette start-minute end-minute scale days week-start)))

(defun org-timegrid--draw-clock-marker (svg geometry palette &optional selected outline-only)
  "Draw a boundary clock from GEOMETRY, using PALETTE's selection color.
OUTLINE-ONLY preserves the static bar's translucent fill during selection."
  (let* ((x (plist-get geometry :x))
         (y (plist-get geometry :y))
         (width (plist-get geometry :width))
         (height (plist-get geometry :height))
         (cx (+ x (/ width 2.0)))
         (cy (+ y (/ height 2.0)))
         (bar (min (org-timegrid--scale-pixels 6) (- width 2)))
         (radius (min (org-timegrid--scale-pixels 6)
                      (/ (- width 2) 2.0) (/ (- height 2) 2.0)))
         (color (plist-get palette :clock))
         (opacity (org-timegrid--block-opacity (plist-get geometry :preview)))
         (ink (plist-get palette :foreground))
         (ink-width (max 1 (org-timegrid--scale-pixels 1)))
         (selection (plist-get palette :blue)))
    (svg-rectangle svg (- cx (/ bar 2.0)) y bar height
                   :rx (min (/ bar 2.0) (plist-get geometry :radius))
                   :fill (if outline-only "none" color)
                   :fill-opacity opacity
                   :stroke (if selected selection "none")
                   :stroke-width (if selected 2 0))
    (when (and (not (plist-get geometry :boundary-edge)) (>= radius 4))
      ;; An opaque, preblended badge masks the day line and selection bar beneath it.
      (svg-circle svg cx cy radius
                  :fill (org-timegrid--blend color (plist-get palette :background) opacity)
                  :stroke (if selected selection "none")
                  :stroke-width (if selected 2 0))
      (svg-circle svg cx cy (* radius 0.65) :fill "none"
                  :stroke ink :stroke-width ink-width)
      (svg-polyline svg (list (cons cx (- cy (* radius 0.4)))
                              (cons cx cy)
                              (cons (+ cx (* radius 0.3)) (+ cy (* radius 0.18))))
                    :fill "none" :stroke ink :stroke-width ink-width
                    :stroke-linecap "round" :stroke-linejoin "round"))))

(defun org-timegrid--svg-block (svg geometry palette font-family)
  "Paint resolved GEOMETRY into SVG, using PALETTE and FONT-FAMILY."
  (let* ((block (plist-get geometry :block))
         (clock (plist-get geometry :clock))
         (day (plist-get geometry :day))
         (x (plist-get geometry :x)) (y (plist-get geometry :y))
         (block-width (plist-get geometry :width))
         (block-height (plist-get geometry :height))
         (boundary-edge (plist-get geometry :boundary-edge)))
    (if clock
        (org-timegrid--draw-clock-marker svg geometry palette)
      (let* ((fill (org-timegrid--color block palette))
             (accent (org-timegrid--accent block palette))
             (text-inset (org-timegrid--block-text-inset))
             (event (org-timegrid-block-event block))
             (repeater (and event (plist-get (org-timegrid-event-metadata event)
                                             :repeater-type)))
             (small-font (org-timegrid--font-size 8))
             (font-size (if (< block-height (org-timegrid--scale-pixels 13))
                            small-font
                          (org-timegrid--font-size 10)))
             (line-height (if (= font-size small-font)
                              (org-timegrid--scale-pixels 10)
                            (org-timegrid--scale-pixels 13)))
             (characters (max 1 (floor (/ (- block-width text-inset (if repeater 13 3))
                                          (* font-size 0.62)))))
             (max-lines (max 1 (floor (/ (max 1 (- block-height 3))
                                         line-height))))
             (title-lines (org-timegrid--wrap-title
                           (org-timegrid-block-title block) characters max-lines))
             (clip-id (format "occs-block-%s-%x" day
                              (sxhash (org-timegrid-block-id block))))
             (clip (svg-clip-path svg :id clip-id)))
        (svg-rectangle clip x y block-width block-height)
        (svg-rectangle svg x y block-width block-height
                       :fill fill
                       :fill-opacity (org-timegrid--block-opacity (org-timegrid-block-preview block))
                       :stroke "none" :stroke-width 0)
        (svg-rectangle svg (+ x 2) (+ y 2) (- text-inset 6) (max 1 (- block-height 4))
                       :fill accent)
        (when (and repeater
                   (not boundary-edge)
                   (>= block-width 25) (>= block-height 12))
          (org-timegrid--draw-repeater svg (- (+ x block-width) 10) (+ y 1) accent))
        (cl-loop for line in (unless boundary-edge title-lines)
                 for index from 0 do
                 (org-timegrid--draw-text svg line :x (+ x text-inset)
                                          :y (+ y (min (- block-height 1)
                                                       (+ (if (= font-size small-font)
                                                              (org-timegrid--scale-pixels 8)
                                                            (org-timegrid--scale-pixels 10))
                                                          (* index line-height))))
                                          :font-size font-size :font-weight "600"
                                          :font-family font-family
                                          :clip-path (format "url(#%s)" clip-id)
                                          :fill (if (org-timegrid-block-done block)
                                                    (plist-get palette :muted)
                                                  (plist-get palette :foreground))))
        (when (and (not boundary-edge) (< (length title-lines) max-lines))
          (org-timegrid--draw-text svg
                                   (org-timegrid--format-range
                                    (or (org-timegrid-block-source-start block) (org-timegrid-block-start block))
                                    (or (org-timegrid-block-source-end block) (org-timegrid-block-end block)))
                                   :x (+ x text-inset)
                                   :y (+ y (org-timegrid--scale-pixels 10)
                                         (* (length title-lines) line-height))
                                   :font-size (org-timegrid--font-size 9) :font-family font-family
                                   :small-period t
                                   :clip-path (format "url(#%s)" clip-id)
                                   :fill (plist-get palette :secondary-text)))))
    geometry))

(defun org-timegrid--draw-current-time
    (svg width height column-width palette font-family start-minute scale
         &optional now-minute today-day)
  "Draw the current time marker on SVG with WIDTH and PALETTE.
HEIGHT, COLUMN-WIDTH, FONT-FAMILY, START-MINUTE and SCALE determine its
geometry.  Return the marker's Y coordinate."
  (let* ((now (decode-time (and org-timegrid--render-context
                                (* 60 (org-timegrid--render-context-minute
                                       org-timegrid--render-context)))))
         (today (calendar-absolute-from-gregorian (org-timegrid--today)))
         (today-day (or today-day
                        (- today (org-timegrid--calendar-state-week-start
                                  org-timegrid--state))))
         (now-minute (or now-minute
                         (+ (* 60 (decoded-time-hour now))
                            (decoded-time-minute now)))))
    (when (and (<= 0 today-day (org-timegrid--last-day-index))
               (<= start-minute now-minute
                   (* 60 org-timegrid-end-hour)))
      (let* ((y (+ (org-timegrid--grid-top-inset)
                   (* (- now-minute start-minute) scale)))
             (today-x (+ (org-timegrid--label-width)
                         (* today-day column-width)))
             (label (org-timegrid--format-minute now-minute 'clock))
             (bubble-width (org-timegrid--scale-pixels 36))
             (bubble-height (org-timegrid--scale-pixels 14))
             (bubble-x (/ (- (org-timegrid--label-width) bubble-width) 2.0))
             (bubble-right (+ bubble-x bubble-width))
             (today-line-x (if (= today-day 0)
                               bubble-right
                             today-x))
             (edge-inset (org-timegrid--scale-pixels 1))
             (bubble-y (max edge-inset
                            (min (- height bubble-height edge-inset)
                                 (- y (/ bubble-height 2.0))))))
        (svg-line svg bubble-right y width y
                  :stroke (plist-get palette :red) :stroke-width 2
                  :stroke-opacity 0.16)
        (svg-line svg today-line-x y (+ today-x column-width) y
                  :stroke (plist-get palette :red) :stroke-width 2)
        (when (> today-day 0)
          (svg-circle svg today-x y 4 :fill (plist-get palette :red)))
        (svg-rectangle svg bubble-x bubble-y bubble-width bubble-height
                       :rx (/ bubble-height 2.0)
                       :ry (/ bubble-height 2.0)
                       :fill (plist-get palette :red))
        (org-timegrid--draw-text svg label :x (/ (org-timegrid--label-width) 2.0)
                                 :y (+ bubble-y (org-timegrid--scale-pixels 10))
                                 :font-size (org-timegrid--font-size 8)
                                 :font-weight "600"
                                 :font-family font-family :text-anchor "middle"
                                 :fill "#ffffff")
        y))))

(defun org-timegrid--svg-inner-xml (svg)
  "Return SVG's serialized child elements."
  (with-temp-buffer
    (svg-print svg)
    (let* ((xml (buffer-string))
           (start (1+ (string-match ">" xml)))
           (end (string-match "</svg>\\'" xml)))
      (substring xml start end))))

(defun org-timegrid--paint-node (svg node palette font)
  "Paint a bounded scene NODE into SVG using PALETTE and FONT.
Return the generated element. No cache, file or model mutation belongs here."
  (let* ((kind (car node)) (bounds (cdr node))
         (x (plist-get bounds :x)) (y (plist-get bounds :y))
         (width (plist-get bounds :width)) (height (plist-get bounds :height)))
    (pcase kind
      ((or 'rect 'line)
       (apply #'svg-node svg kind
              (append (if (eq kind 'rect)
                          (list :x x :y y :width width :height height)
                        (list :x1 x :y1 y :x2 (+ x width) :y2 (+ y height)))
                      (plist-get bounds :attributes))))
      ('hour-label
       (let ((group (svg-node svg 'g)))
         (org-timegrid--draw-hour-label group (plist-get bounds :minute)
                                        (plist-get bounds :baseline) palette font)
         group))
      ('block
       (let ((group (if-let* ((index (plist-get bounds :static-index)))
                        (svg-node svg 'g :id (format "timegrid-static-%d" index)) svg)))
         (org-timegrid--svg-block group bounds palette font)
         (if (eq group svg) (car (last (dom-children svg))) group)))
      ('edge-shadow
       (let ((group (svg-node svg 'g)))
         (org-timegrid--draw-edge-shadow group x (plist-get bounds :edge-y) width
                                         (plist-get bounds :direction) palette)
         group))
      ('current-time
       (let ((group (svg-node svg 'g)))
         (org-timegrid--draw-current-time
          group width (plist-get bounds :canvas-height) (plist-get bounds :column)
          palette font (plist-get bounds :start-minute) (org-timegrid--pixels-per-minute)
          (plist-get bounds :minute) (plist-get bounds :day))
         group))
      ('resize-handle
       (svg-rectangle svg x y width height :rx (/ height 2.0)
                      :fill (if (plist-get bounds :clock)
                                (plist-get palette :clock)
                              (org-timegrid--accent (plist-get bounds :block) palette))))
      ('selection
       (if (plist-get bounds :clock)
           (org-timegrid--draw-clock-marker svg bounds palette t t)
         (svg-rectangle svg x y width height :fill "none"
                        :stroke (plist-get palette :blue) :stroke-width 2)))
      ((or 'region 'cursor)
       (let ((color (plist-get palette (if (eq kind 'region) :region :cursor))))
         (svg-rectangle svg x y width height :fill color :stroke color :stroke-width 1
                        :fill-opacity (if (eq kind 'region) org-timegrid-region-opacity
                                        org-timegrid-cursor-opacity))))
      (_ (error "Unknown timegrid drawing kind: %S" kind)))))

(defun org-timegrid-svg-render (scene &optional output)
  "Render SCENE without displaying or caching it.
OUTPUT `fragment' returns inner XML, `fragments' returns bounded XML strings,
`drawings' returns bounded SVG elements, and nil returns a complete SVG tree."
  (let ((context (org-timegrid--scene-context scene)))
    (org-timegrid--with-render-context context
      (let ((svg (svg-create (or (org-timegrid--scene-width scene) (org-timegrid--render-context-width context))
                             (or (org-timegrid--scene-height scene) (org-timegrid--context-height context)) :stroke-width 0))
            (palette (org-timegrid--palette)) (font (org-timegrid--font-family)) drawings)
        (dolist (node (org-timegrid--scene-nodes scene))
          (let ((element (org-timegrid--paint-node svg node palette font)))
            (when (memq output '(fragments drawings))
              (push (cons (cdr node)
                          (if (eq output 'drawings) element
                            (with-temp-buffer (svg-print element) (buffer-string)))) drawings))))
        (pcase output
          ((or 'fragments 'drawings) (nreverse drawings))
          ('fragment (org-timegrid--svg-inner-xml svg))
          (_ svg))))))

(defun org-timegrid--draw-all-day-block
    (svg block left-offset column-width top palette font-family)
  "Draw one laid-out all-day BLOCK into SVG rail at TOP."
  (let* ((bounds (org-timegrid--all-day-geometry block left-offset column-width top))
         (x (plist-get bounds :x)) (y (plist-get bounds :y))
         (right (+ x (plist-get bounds :width)))
         (height (plist-get bounds :height))
         (arrow (min 9 (/ (- right x) 3.0)))
         (leftp (org-timegrid-block-continues-left block))
         (rightp (org-timegrid-block-continues-right block))
         (fill (org-timegrid--color block palette))
         (event (org-timegrid-block-event block))
         (repeater (and event (plist-get (org-timegrid-event-metadata event)
                                         :repeater-type)))
         (selected (equal (org-timegrid-block-id block) (org-timegrid--selected-id)))
         (mid (+ y (/ height 2.0)))
         ;; A single silhouette keeps the selection stroke on the outside of
         ;; continuation arrowheads.  Drawing the body and arrows separately
         ;; both exposed antialiasing seams and made the selected rectangle
         ;; cross through the arrow.
         (points
          (append (list (cons (+ x (if leftp arrow 0)) y)
                        (cons (- right (if rightp arrow 0)) y))
                  (when rightp (list (cons right mid)))
                  (list (cons (- right (if rightp arrow 0)) (+ y height))
                        (cons (+ x (if leftp arrow 0)) (+ y height)))
                  (when leftp (list (cons x mid))))))
    (svg-polygon svg points :fill fill
                 :stroke (if selected
                             (plist-get palette :blue)
                           (plist-get palette :background))
                 :stroke-width (if selected 2 1))
    (let* ((text-x (+ x (if leftp arrow 0) 9))
           (available (max 1 (- right text-x
                                (if repeater 14 5))))
           (characters (max 1 (floor (/ available
                                        (org-timegrid--scale-pixels 6.2)))))
           (title (truncate-string-to-width
                   (org-timegrid-block-title block) characters nil nil "…")))
      (org-timegrid--draw-text svg title :x text-x
                               :y (+ y (org-timegrid--scale-pixels 13))
                               :font-size (org-timegrid--font-size 10)
                               :font-weight "600" :font-family font-family
                               :fill (plist-get palette :foreground)))
    (when (and repeater (>= (- right x) 25))
      (org-timegrid--draw-repeater svg (- right 10) (+ y 3)
                                   (org-timegrid--accent block palette)))
    bounds))

(defun org-timegrid--draw-day-label
    (svg day-name day-number center baseline factor todayp palette font-family)
  "Draw DAY-NAME and DAY-NUMBER on SVG at CENTER and BASELINE.
FACTOR sets the scale; TODAYP highlights today.
PALETTE and FONT-FAMILY determine the label's appearance."
  (if todayp
      (let* ((name-width (* factor 8.0 (string-width day-name)))
             (circle-radius (* factor 12))
             (gap (* factor
                     (plist-get org-timegrid-single-day-label-style :gap)))
             (group-width (+ name-width gap (* 2 circle-radius)))
             (name-x (- center (/ group-width 2.0)))
             (number-x (+ name-x name-width gap circle-radius))
             ;; A leading "1" leaves noticeably less ink on the left than
             ;; its advance width suggests.  Nudge multi-digit dates onto the
             ;; circle's optical center while keeping its geometry unchanged.
             (number-text-x (- number-x
                               (if (> (length day-number) 1)
                                   (* factor 0.5)
                                 0))))
        (org-timegrid--draw-text svg day-name :x name-x :y baseline
                                 :font-size (* factor 14) :font-weight "500"
                                 :font-family font-family
                                 :fill (plist-get palette :foreground))
        (svg-circle svg number-x (- baseline (* factor 5)) circle-radius
                    :fill (plist-get palette :red))
        (org-timegrid--draw-text svg day-number :x number-text-x :y baseline
                                 :font-size (* factor 14) :font-weight "700"
                                 :font-family font-family :text-anchor "middle"
                                 :fill "#ffffff"))
    (org-timegrid--draw-text svg (format "%s %s" day-name day-number)
                             :x center :y baseline
                             :font-size (* factor 14) :font-weight "500"
                             :font-family font-family :text-anchor "middle"
                             :fill (plist-get palette :foreground))))

(defun org-timegrid-svg-header (scene)
  "Return a pixel-aligned SVG header for the calendar."
  (org-timegrid--with-render-context (org-timegrid--scene-context scene)
    (let* ((properties (cdar (org-timegrid--scene-nodes scene)))
           (org-timegrid--state (plist-get properties :state))
           (left-offset (plist-get properties :left-offset))
           (window nil)
           (width (org-timegrid--scene-width scene))
           (all-day (plist-get properties :layout))
           (rail-rows (plist-get properties :rows))
           (event-rows (1- rail-rows))
           (header-title-height (org-timegrid--header-title-height))
           (date-factor (org-timegrid--frame-font-factor window))
           (rail-top (org-timegrid--rail-top))
           (lane-height (org-timegrid--all-day-lane-height))
           (height (org-timegrid--scene-height scene))
           (column-width (org-timegrid--column-width))
           (palette (org-timegrid--palette))
           (font-family (org-timegrid--font-family))
           (week-start (org-timegrid--calendar-state-week-start org-timegrid--state))
           (today (calendar-absolute-from-gregorian (org-timegrid--today)))
           (month-parts (org-timegrid--header-month-parts week-start))
           (month-title (car month-parts))
           (year-title (cadr month-parts))
           (title-x (+ left-offset 8))
           (svg (svg-create width height :stroke-width 0))
           )
      (svg-rectangle svg 0 0 width height
                     :fill (plist-get palette :time-background))
      (org-timegrid--draw-text svg month-title :x title-x
                               :y (plist-get org-timegrid-header-title-style :baseline)
                               :font-size (plist-get org-timegrid-header-title-style :font-size)
                               :font-weight "700"
                               :font-family font-family :fill (plist-get palette :foreground))
      (org-timegrid--draw-text svg year-title
                               :x (+ title-x
                                     (* (plist-get org-timegrid-header-title-style :character-width)
                                        (string-width month-title))
                                     8)
                               :y (plist-get org-timegrid-header-title-style :baseline)
                               :font-size (plist-get org-timegrid-header-title-style :font-size)
                               :font-weight "300"
                               :font-family font-family
                               :fill (plist-get palette :secondary-text))
      (when (> org-timegrid-days 1)
        (org-timegrid--draw-text svg (org-timegrid--week-label week-start)
                                 :x (+ left-offset 7)
                                 :y (+ header-title-height (* date-factor 20))
                                 :font-size (* date-factor 14) :font-family font-family
                                 :fill (plist-get palette
                                                  (if (org-timegrid--week-current-p week-start today)
                                                      :red
                                                    :secondary-text))))
      (dotimes (day org-timegrid-days)
        (let* ((absolute (+ week-start day))
               (date (calendar-gregorian-from-absolute absolute))
               (day-name (calendar-day-name date t))
               (day-number (number-to-string (nth 1 date)))
               (x (+ left-offset
                     (org-timegrid--label-width)
                     (* day column-width)))
               (center (+ x (/ column-width 2.0)))
               (baseline (+ header-title-height (* date-factor 20))))
          (unless (= org-timegrid-days 1)
            (org-timegrid--draw-day-label
             svg day-name day-number center baseline date-factor
             (= absolute today) palette font-family))))
      (svg-line svg 0 (1- rail-top)
                width (1- rail-top)
                :stroke (plist-get palette :grid) :stroke-width 1)
      (if (= org-timegrid-days 1)
          (let* ((date (calendar-gregorian-from-absolute week-start))
                 (day-name (calendar-day-name date t))
                 (day-number (number-to-string (nth 1 date)))
                 (center (+ left-offset (/ (org-timegrid--label-width) 2.0)))
                 (single-factor (org-timegrid--single-day-label-factor window))
                 (baseline (+ rail-top (* single-factor 25)))
                 (todayp (= week-start today)))
            (org-timegrid--draw-day-label
             svg day-name day-number
             (+ center (* single-factor
                          (plist-get org-timegrid-single-day-label-style :x-offset)))
             baseline single-factor todayp
             palette font-family))
        (org-timegrid--draw-text svg "all-day" :x (+ left-offset 5)
                                 :y (+ rail-top (org-timegrid--scale-pixels 15))
                                 :font-size (org-timegrid--font-size 9) :font-family font-family
                                 :fill (plist-get palette :secondary-text)))
      (dotimes (day org-timegrid-days)
        (let ((x (+ left-offset (org-timegrid--label-width) (* day column-width))))
          (svg-line svg x rail-top x height
                    :stroke (plist-get palette :grid) :stroke-width 1)))
      (dolist (block all-day)
        (when (< (org-timegrid-block-rail-lane block) org-timegrid-all-day-max-lanes)
          (org-timegrid--draw-all-day-block
           svg block left-offset column-width
           (+ rail-top (* (org-timegrid-block-rail-lane block) lane-height))
           palette font-family)))
      (when-let* (((org-timegrid--cursor-visible-p))
                  (cursor (org-timegrid--cursor))
                  ((eq (org-timegrid--cursor-state-surface cursor) 'rail))
                  ((null (org-timegrid--selected-id))))
        (let* ((cursor-height (* org-timegrid-slot-minutes
                                 (org-timegrid--pixels-per-minute)))
               (x (+ left-offset (org-timegrid--label-width)
                     (* (org-timegrid--cursor-state-day cursor) column-width) 1))
               (y (+ rail-top
                     (* (org-timegrid--cursor-state-lane cursor)
                        lane-height)
                     (/ (- lane-height cursor-height) 2.0))))
          (svg-rectangle svg x y (- column-width 2)
                         cursor-height
                         :fill (plist-get palette :cursor)
                         :fill-opacity org-timegrid-cursor-opacity
                         :stroke (plist-get palette :cursor)
                         :stroke-width 1)))
      (dotimes (day org-timegrid-days)
        (let ((hidden
               (seq-count
                (lambda (block)
                  (and (>= (org-timegrid-block-rail-lane block)
                           org-timegrid-all-day-max-lanes)
                       (< (* day 1440) (org-timegrid-block-rail-end block))
                       (< (org-timegrid-block-rail-start block) (* (1+ day) 1440))))
                all-day)))
          (when (> hidden 0)
            (org-timegrid--draw-text svg (format "+%d more" hidden)
                                     :x (+ left-offset (org-timegrid--label-width)
                                           (* day column-width) 7)
                                     :y (+ rail-top (* event-rows lane-height)
                                           (org-timegrid--scale-pixels 15))
                                     :font-size (org-timegrid--font-size 9) :font-family font-family
                                     :fill (plist-get palette :secondary-text)))))
      (svg-line svg 0 (1- height) width (1- height)
                :stroke (plist-get palette :grid) :stroke-width 1)
      (dolist (node (cdr (org-timegrid--scene-nodes scene)))
        (org-timegrid--paint-node svg node palette font-family))
      (cons svg (org-timegrid--scene-geometry scene)))))

(defun org-timegrid-svg-tile (x y width height background shapes overlay)
  "Compose a tile from explicit bounds and SVG fragments, without cache access."
  (format
   (concat "<svg width=\"%s\" height=\"%s\" viewBox=\"%s %s %s %s\" "
           "version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" "
           "xmlns:xlink=\"http://www.w3.org/1999/xlink\">%s%s%s</svg>")
   width height x y width height background (or shapes "") (or overlay "")))

(defun org-timegrid-svg-image (drawing &rest properties)
  "Create an Emacs image for SVG DRAWING with display PROPERTIES.
The caller owns the returned resource and decides when to flush it."
  (if (stringp drawing)
      (apply #'create-image drawing 'svg t properties)
    (apply #'svg-image drawing properties)))

(provide 'org-timegrid-svg)
;;; org-timegrid-svg.el ends here
