;;; org-timegrid-test.el --- Tests for org-timegrid -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)

(ert-deftest org-timegrid-test-svg-colors-are-normalized ()
  (dolist (case '(("Red1" nil "#ff0000")
                  ("#abc" nil "#aabbcc")
                  ("not-a-color" "#3a5fcd" "#3a5fcd")))
    (pcase-let ((`(,color ,fallback ,expected) case))
      (ert-info ((format "color %s" color))
        (should (equal (org-timegrid--svg-color color fallback) expected))))))

(ert-deftest org-timegrid-test-face-color-is-svg-safe ()
  (cl-letf (((symbol-function 'face-attribute)
             (lambda (&rest _ignored) "Red1")))
    (should (equal (org-timegrid--face-color 'error :foreground "#d94b4b")
                   "#ff0000"))))

(ert-deftest org-timegrid-test-text-scale-controls-svg-scale ()
  (with-temp-buffer
    (let ((org-timegrid-pixels-per-minute 0.9)
          (org-timegrid-default-zoom 1.0))
      (cl-letf (((symbol-function 'org-timegrid--default-font-height)
                 (lambda (&optional _window) 36))
                ((symbol-function 'org-timegrid--frame-font-factor)
                 (lambda (&optional _window) 1))
                ((symbol-function 'org-timegrid--default-font-size)
                 (lambda (&optional _window) 20)))
        (should (= (org-timegrid--zoom-factor) 2))
        (should (= (org-timegrid--pixels-per-minute) 1.8))
        (should (= (org-timegrid--font-size 10) 20))
        (should (= (org-timegrid--grid-top-inset) 12))
        (should (= (org-timegrid--header-title-height) 44))
        (should (= (org-timegrid--rail-top) 74))))))

(ert-deftest org-timegrid-test-text-scale-keeps-svg-width-fixed ()
  (with-temp-buffer
    (let ((org-timegrid-days 7)
          (org-timegrid-default-zoom 1.0))
      (cl-letf (((symbol-function 'org-timegrid--window-width)
                 (lambda () 700))
                ((symbol-function 'org-timegrid--default-font-size)
                 (lambda (&optional _window) 40)))
        (let ((rectangle
               (progn
                 (setq-local org-timegrid--state
                             (org-timegrid--calendar-state-create
                              :week-start 100
                              :cursor (org-timegrid--cursor-state-create
                                       :surface 'grid :day 0 :minute 60)
                              :cursor-visible t))
                 (org-timegrid--cursor-rectangle))))
          (should (= (plist-get rectangle :x)
                     (1+ (* org-timegrid--label-width 4))))
          (should (= (plist-get rectangle :width)
                     (- (/ (- 700 (* org-timegrid--label-width 4)) 7.0) 2)))
          (should (= (plist-get rectangle :height)
                     (* org-timegrid-slot-minutes
                        org-timegrid-pixels-per-minute 4))))))))

(ert-deftest org-timegrid-test-label-gutter-has-frame-font-minimum ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'org-timegrid--zoom-factor)
               (lambda (&optional _window) 0.5))
              ((symbol-function 'org-timegrid--frame-font-factor)
               (lambda (&optional _window) 1)))
      (should (= (org-timegrid--label-width)
                 org-timegrid--label-width)))))

(ert-deftest org-timegrid-test-fixed-header-factor-ignores-calendar-zoom ()
  (let ((org-timegrid-default-zoom 3))
    (cl-letf (((symbol-function 'frame-char-height)
               (lambda (&optional _frame) org-timegrid--reference-font-height))
              ((symbol-function 'org-timegrid--default-font-height)
               (lambda (&optional _window) 72)))
      (should (= (org-timegrid--frame-font-factor) 1)))))

(ert-deftest org-timegrid-test-compact-strip-uses-effective-zoom ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'org-timegrid--zoom-factor)
               (lambda (&optional _window) 2))
              ((symbol-function 'org-timegrid--frame-font-factor)
               (lambda (&optional _window) 1)))
      (let ((data (plist-get (cdr (org-timegrid-day-image nil 0 60 400))
                             :data)))
        (should (string-match-p "height=\"114\"" data))
        (should (string-match-p "font-size=\"22\"" data))))))

(ert-deftest org-timegrid-test-plain-c-x-plus-zooms-calendar ()
  (should (eq (lookup-key org-timegrid-mode-map (kbd "C-x +"))
              #'text-scale-adjust)))

(ert-deftest org-timegrid-test-precision-scroll-uses-calendar-pixels ()
  (let (scrolled)
    (cl-letf (((symbol-function 'org-timegrid--event-window)
               (lambda (_event) 'calendar-window))
              ((symbol-function 'org-timegrid-scroll)
               (lambda (pixels window) (setq scrolled (list pixels window)))))
      (org-timegrid-precision-scroll
       '(wheel-up nil nil nil (0.0 . 7.5)))
      (should (equal scrolled '(-7.5 calendar-window))))))

(ert-deftest org-timegrid-test-scroll-boundary-distinguishes-rebound-from-reversal ()
  (with-temp-buffer
    (org-timegrid-mode)
    (setq-local org-timegrid--image-height 1000
                org-timegrid--scroll-boundary '(top . 10.0))
    (let (scrolled now)
      (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
                ((symbol-function 'window-buffer)
                 (lambda (_window) (current-buffer)))
                ((symbol-function 'window-body-height)
                 (lambda (&rest _ignored) 500))
                ((symbol-function 'org-timegrid--window-scroll-pixels)
                 (lambda (_window) 0))
                ((symbol-function 'org-timegrid--set-vscroll)
                 (lambda (_window pixels) (setq scrolled pixels)))
                ((symbol-function 'float-time) (lambda (&optional _time) now)))
        (dolist (case '((10.2 nil rebound) (10.4 90 deliberate-reversal)))
          (pcase-let ((`(,time ,expected ,name) case))
            (ert-info (name)
              (setq now time scrolled nil
                    org-timegrid--scroll-boundary '(top . 10.0))
              (org-timegrid-scroll 90 'calendar-window)
              (should (equal scrolled expected)))))))))

(ert-deftest org-timegrid-test-precision-scroll-overrides-global-mode-locally ()
  (with-temp-buffer
    (setq-local minor-mode-overriding-map-alist
                '((pixel-scroll-precision-mode . old-map)))
    (org-timegrid--install-precision-scroll-override)
    (should (eq (lookup-key
                 (cdr (assq 'pixel-scroll-precision-mode
                            minor-mode-overriding-map-alist))
                 [remap pixel-scroll-precision])
                #'org-timegrid-precision-scroll))))

(ert-deftest org-timegrid-test-range-start-keeps-date-in-visible-range ()
  (let ((org-timegrid-days 3)
        (calendar-week-start-day 0))
    (dolist (case '(((9 1 2026) (8 30 2026) week-start-visible)
                    ((9 2 2026) (8 31 2026) trailing-range)))
      (pcase-let ((`(,date ,expected ,name) case))
        (ert-info (name)
          (should (= (org-timegrid--range-start
                      (calendar-absolute-from-gregorian date))
                     (calendar-absolute-from-gregorian expected))))))))

(ert-deftest org-timegrid-test-load-state-honours-visible-day-count ()
  (let* ((org-timegrid-days 3)
         requested-start requested-end
         (org-timegrid--backend
          (org-timegrid-backend-create
           :name "test"
           :list-function
           (lambda (start end)
             (setq requested-start start
                   requested-end end)
             nil))))
    (org-timegrid--load-state 100)
    (should (= requested-start (* 100 1440)))
    (should (= requested-end (* 103 1440)))))

(ert-deftest org-timegrid-test-model-preserves-explicit-time-kinds ()
  (let* ((event (org-timegrid-event-create
                 :id 'date-only :title "Holiday" :start 14400 :end 15840
                 :all-day t))
         (block (org-timegrid-event-to-block event 10)))
    (should (org-timegrid-block-p block))
    (should (eq (org-timegrid-block-time-kind block) 'all-day)))
  (dolist (case '((timed 0 60 120 -120 0 0 60)
                  (all-day 0 0 2880 -1440 -1 0 2880)))
    (pcase-let ((`(,kind ,day ,start ,end ,delta
                          ,expected-day ,expected-start ,expected-end)
                 case))
      (ert-info ((symbol-name kind))
        (let* ((block (org-timegrid-block-create
                       :id kind :day day :start start :end end
                       :time-kind kind))
               (moved (org-timegrid--transform-block-range block delta nil)))
          (should (equal (list (org-timegrid-block-time-kind moved)
                               (org-timegrid-block-day moved)
                               (org-timegrid-block-start moved)
                               (org-timegrid-block-end moved))
                         (list kind expected-day expected-start expected-end))))))))

(ert-deftest org-timegrid-test-backend-supports-modern-and-legacy-contracts ()
  (let* ((event (org-timegrid-event-create
                 :id 'event :title "Event" :start 144000 :end 144030))
         (block (org-timegrid-block-create
                 :id 'event :day 0 :start 0 :end 30
                 :title "Event" :time-kind 'timed))
         (org-timegrid--state
          (org-timegrid--calendar-state-create :week-start 100)))
    (cl-letf (((symbol-function 'org-timegrid--refresh-data) #'ignore))
      (dolist (contract '(modern legacy))
        (ert-info ((symbol-name contract))
          (let ((created nil)
                (updated nil))
            (let ((org-timegrid--backend
                   (org-timegrid-backend-create
                    :name (symbol-name contract)
                    :list-function (lambda (_start _end) nil)
                    :create-function
                    (if (eq contract 'modern)
                        (lambda (_title _start _end
                                 &optional _source _target time-kind)
                          (setq created time-kind))
                      (lambda (_title _start _end _source)
                        (setq created t))))))
              (org-timegrid--backend-create "Event" block))
            (org-timegrid--call-update
             (if (eq contract 'modern)
                 (lambda (_event _start _end _title time-kind)
                   (setq updated time-kind))
               (lambda (_event _start _end) (setq updated t)))
             event 144015 144045 nil 'timed)
            (should (equal created (if (eq contract 'modern) 'timed t)))
            (should (equal updated (if (eq contract 'modern) 'timed t)))))))))

(ert-deftest org-timegrid-test-mixed-kind-render-smoke ()
  (let* ((org-timegrid-days 3)
         (week 100)
         (timed-event (org-timegrid-event-create
                       :id 'timed :title "Meeting"
                       :start (+ (* week 1440) 600)
                       :end (+ (* week 1440) 660)))
         (all-day-event (org-timegrid-event-create
                         :id 'all-day :title "Holiday"
                         :start (* week 1440) :end (* (1+ week) 1440)
                         :all-day t))
         (blocks (org-timegrid-events-to-blocks
                  (list timed-event all-day-event) week)))
    (with-temp-buffer
      (org-timegrid-mode)
      (setq-local org-timegrid--state
                  (org-timegrid--calendar-state-create
                   :week-start week
                   :events (list timed-event all-day-event)
                   :blocks blocks))
      (should (eq (car (org-timegrid--svg)) 'svg))
      (should (stringp (org-timegrid--header)))
      (should (= (length (org-timegrid--timed-blocks)) 1))
      (should (= (length (org-timegrid--all-day-blocks)) 1)))))

(ert-deftest org-timegrid-test-org-preserves-kind-through-entry-lifecycle ()
  (with-temp-buffer
    (org-mode)
    (insert "* Event\n")
    (let* ((start (* 1440
                     (calendar-absolute-from-gregorian '(8 26 2026))))
           (marker (copy-marker (point-min))))
      ;; A full-day duration explicitly marked timed must not be inferred as
      ;; all-day merely from its endpoints.
      (org-timegrid-org--create-event
       "Event" start (+ start 1440) nil marker 'timed)
      (goto-char (point-min))
      (should (re-search-forward "00:00" nil t))
      (let ((event (car (org-timegrid-org--buffer-events "test.org"))))
        (should-not (org-timegrid-event-all-day event))
        (org-timegrid-org--update-event-range
         event start (+ start 1440) nil 'all-day)
        (goto-char (point-min))
        (should-not (re-search-forward "[0-9][0-9]:[0-9][0-9]" nil t))
        (let ((event (car (org-timegrid-org--buffer-events "test.org"))))
          (should (org-timegrid-event-all-day event))
          (org-timegrid-org--update-event-range
           event start (+ start 30) nil 'timed)
          (goto-char (point-min))
          (should (re-search-forward "00:00-00:30" nil t))
          (should-not (org-timegrid-event-all-day
                       (car (org-timegrid-org--buffer-events "test.org")))))))))

(ert-deftest org-timegrid-test-drag-proposal-transition-matrix ()
  (let ((org-timegrid-default-duration-minutes 45)
        (cases
         '((timed-to-all-day
            (meeting 1 600 690 timed)
            (:surface grid :block-id meeting :day 1 :minute 615)
            (:surface rail :day 4 :minute 0)
            nil move (all-day 4 0 1440))
           (all-day-to-timed
            (holiday 2 0 1440 all-day)
            (:surface rail :block-id holiday :day 2 :minute 0)
            (:surface grid :day 5 :minute 780)
            nil move (timed 5 780 825))
           (multi-day-to-grid-rejected
            (trip 2 0 2880 all-day)
            (:surface rail :block-id trip :day 2 :minute 0)
            (:surface grid :day 5 :minute 780)
            nil nil error)
           (resize-all-day-start
            (trip 1 0 4320 all-day)
            (:surface rail :block-id trip :day 1 :minute 0 :edge top)
            (:surface rail :day 2 :minute 0)
            nil resize (all-day 2 0 2880))
           (resize-all-day-end
            (trip 1 0 4320 all-day)
            (:surface rail :block-id trip :day 1 :minute 0 :edge bottom)
            (:surface rail :day 5 :minute 0)
            nil resize (all-day 1 0 7200))
           (duplicate-entry
            (meeting 1 600 660 timed)
            (:surface grid :block-id meeting :day 1 :minute 615)
            (:surface grid :day 2 :minute 615)
            duplicate-entry duplicate-entry (timed 2 600 660))
           (add-occurrence
            (meeting 1 600 660 timed)
            (:surface grid :block-id meeting :day 1 :minute 615)
            (:surface grid :day 2 :minute 615)
            add-occurrence add-occurrence (timed 2 600 660)))))
    (dolist (case cases)
      (pcase-let* ((`(,name (,id ,day ,start ,end ,time-kind)
                              ,origin ,target ,requested-kind
                              ,expected-kind ,expected-block)
                    case)
                   (source (org-timegrid-block-create
                            :id id :day day :start start :end end
                            :title (symbol-name id) :time-kind time-kind))
                   (source-before (copy-org-timegrid-block source))
                   (org-timegrid--state
                    (org-timegrid--calendar-state-create
                     :week-start 100 :blocks (list source)))
                   (proposal (org-timegrid--proposal
                              origin target requested-kind))
                   (block (org-timegrid--operation-block proposal)))
        (ert-info ((symbol-name name))
          (should (eq (org-timegrid--operation-kind proposal) expected-kind))
          (if (eq expected-block 'error)
              (should (org-timegrid--operation-error proposal))
            (should-not (org-timegrid--operation-error proposal))
            (should
             (equal (list (org-timegrid-block-time-kind block)
                          (org-timegrid-block-day block)
                          (org-timegrid-block-start block)
                          (org-timegrid-block-end block))
                    expected-block)))
          ;; Constructing a hover preview must never mutate its source.
          (should (equal source source-before)))))))

(ert-deftest org-timegrid-test-mouse-input-routing-contract ()
  ;; Every image-map area must retain ownership of its logical surface while
  ;; a preview changes the pixels beneath the pointer.
  (dolist (case '((header-line t)
                  (calendar-rail-block t)
                  (calendar-rail-resize t)
                  (nil nil)
                  (calendar-block nil)
                  (calendar-resize nil)))
    (pcase-let ((`(,area ,railp) case))
      (ert-info ((format "area %s" area))
        (should (eq (and (org-timegrid--rail-area-p area) t) railp)))))
  ;; All-day resize edges are horizontal targets.
  (let ((org-timegrid--header-geometry
         '((:id trip :x 100 :y 50 :width 200 :height 18
                :allow-left t :allow-right t))))
    (let ((map (org-timegrid--header-image-map)))
      (should (= (length map) 3))
      (should (equal (plist-get (nth 2 (car map)) 'pointer) 'hdrag))
      (should (equal (plist-get (nth 2 (cadr map)) 'pointer) 'hdrag))))
  ;; A double press must never enter the drag tracker; its release visits.
  (dolist (case `((,org-timegrid-mode-map [down-mouse-1]
                   org-timegrid-press)
                  (,org-timegrid-mode-map [double-down-mouse-1]
                   org-timegrid-ignore-double-press)
                  (,org-timegrid-mode-map [double-mouse-1]
                   org-timegrid-visit)
                  (,org-timegrid-mode-map
                   [calendar-block double-down-mouse-1]
                   org-timegrid-ignore-double-press)
                  (,org-timegrid--header-map
                   [calendar-rail-block double-down-mouse-1]
                   org-timegrid-ignore-double-press)
                  (,org-timegrid--header-map
                   [calendar-rail-block double-mouse-1]
                   org-timegrid-header-visit)))
    (pcase-let ((`(,map ,event ,command) case))
      (ert-info ((format "event %s" event))
        (should (eq (lookup-key map event) command))))))

(ert-deftest org-timegrid-test-cross-surface-preview-does-not-resize-drag-rail ()
  (let* ((source (org-timegrid-block-create
                  :id 'meeting :day 1 :start 600 :end 660
                  :title "Meeting" :time-kind 'timed))
         (org-timegrid--state
          (org-timegrid--calendar-state-create
           :week-start 100 :blocks (list source)))
         (org-timegrid--drag-rail-rows
          (org-timegrid--rail-row-count (org-timegrid--all-day-layout))))
    (should (= org-timegrid--drag-rail-rows 1))
    (setf (org-timegrid--calendar-state-preview org-timegrid--state)
          (org-timegrid--proposal
           '(:surface grid :block-id meeting :day 1 :minute 615)
           '(:surface rail :day 4 :minute 0) nil))
    ;; The preview now needs an event row plus the usual empty row, but the
    ;; active gesture retains the one-row coordinate system it began with.
    (should (= (org-timegrid--rail-row-count (org-timegrid--all-day-layout)) 2))
    (should (= org-timegrid--drag-rail-rows 1))))

(ert-deftest org-timegrid-test-yank-selects-entry-identity-semantics ()
  (let* ((source (org-timegrid-event-create
                  :id 'source :title "Meeting" :start 100 :end 160
                  :source 'source-record))
         (org-timegrid--state
          (org-timegrid--calendar-state-create
           :week-start 0
           :cursor (org-timegrid--cursor-state-create
                    :surface 'grid :day 2 :minute 600 :lane 0)
           :cursor-visible t))
         (org-timegrid--kill
          (list :title "Meeting" :minutes 60 :all-day nil
                :event source :target 'source-record :cut nil))
         targets)
    (cl-letf (((symbol-function 'org-timegrid--backend-create)
               (lambda (_title _block _source target) (push target targets)))
              ((symbol-function 'org-timegrid--reveal-cursor) #'ignore))
      (org-timegrid-yank)
      (org-timegrid-yank t)
      (setq org-timegrid--kill
            (plist-put org-timegrid--kill :cut t))
      (org-timegrid-yank))
    (should (equal (nreverse targets)
                   '(nil source-record source-record)))))

(ert-deftest org-timegrid-test-date-picker-groups-events-by-visible-day ()
  (let ((events (list
                 (org-timegrid-event-create
                  :id 'blue :title "Blue" :start (* 101 1440)
                  :end (+ (* 101 1440) 60) :color 'blue)
                 (org-timegrid-event-create
                  :id 'also-blue :title "Also blue" :start (* 101 1440)
                  :end (+ (* 101 1440) 120) :color 'blue)
                 (org-timegrid-event-create
                  :id 'trip :title "Trip" :start (* 102 1440)
                  :end (* 105 1440) :color 'green))))
    (let* ((backend (org-timegrid-backend-create
                     :name "Test"
                     :list-function (lambda (_start _end) events)))
           (days (org-timegrid-calendar--events-by-day backend 100 104)))
      (should (eq (gethash 101 days) t))
      (should (eq (gethash 102 days) t))
      (should (eq (gethash 103 days) t))
      (should-not (gethash 104 days)))
    (let* ((org-timegrid-calendar-event-predicate
            (lambda (event) (eq (org-timegrid-event-id event) 'trip)))
           (backend (org-timegrid-backend-create
                     :name "Filtered test"
                     :list-function (lambda (_start _end) events)))
           (days (org-timegrid-calendar--events-by-day backend 100 104)))
      (should-not (gethash 101 days))
      (should (eq (gethash 102 days) t))
      (should (eq (gethash 103 days) t)))))

(ert-deftest org-timegrid-test-tiles-partition-and-map-the-whole-canvas ()
  "Tiles continuously partition the canvas and own every pixel."
  (let ((org-timegrid--tile-height 54)
        ;; 24 hours at 0.9 px per minute plus the 6px top inset.
        (org-timegrid--image-height 1302)
        (org-timegrid--tile-count 24)
        (bottom 0))
    (dotimes (tile org-timegrid--tile-count)
      (pcase-let ((`(,top . ,height) (org-timegrid--tile-bounds tile)))
        (should (= top bottom))
        (should (>= height org-timegrid--tile-height))
        (setq bottom (+ top height))))
    (should (= bottom org-timegrid--image-height))
    (dotimes (pixel (ceiling org-timegrid--image-height))
      (let* ((tile (org-timegrid--tile-at-pixel pixel))
             (bounds (org-timegrid--tile-bounds tile)))
        (should (<= (car bounds) pixel))
        (should (< pixel (+ (car bounds) (cdr bounds))))
        (should (equal (org-timegrid--tiles-intersecting pixel (1+ pixel))
                       (list tile)))))))

(ert-deftest org-timegrid-test-cursor-renders-on-every-cell ()
  "Every valid grid and all-day cell renders exactly one cursor."
  (with-temp-buffer
    (let* ((org-timegrid-days 7)
           (org-timegrid-start-hour 0)
           (org-timegrid-end-hour 24)
           (org-timegrid--tile-width 900)
           (org-timegrid--tile-height 61)
           ;; A fractional scale makes the final tile absorb more than one
           ;; slot, exercising the same layout rule at every cursor position.
           (org-timegrid--image-height 1458.72)
           (org-timegrid--tile-count 23)
           (org-timegrid-cursor-opacity 0.314159)
           (org-timegrid--geometry nil)
           (org-timegrid--state
            (org-timegrid--calendar-state-create
             :week-start 0 :blocks nil :cursor-visible t))
           (original-svg-rectangle (symbol-function 'svg-rectangle))
           reached-tiles)
      (cl-labels
          ((render-and-count-cursors
            (function)
            (let ((count 0)
                  value)
              (cl-letf
                  (((symbol-function 'svg-rectangle)
                    (lambda (svg x y width height &rest properties)
                      (when (equal (plist-get properties :fill-opacity)
                                   org-timegrid-cursor-opacity)
                        (cl-incf count))
                      (apply original-svg-rectangle
                             svg x y width height properties))))
                (setq value (funcall function)))
              (cons count value))))
        (cl-letf (((symbol-function 'org-timegrid--window-width)
                   (lambda () 900))
                  ((symbol-function 'org-timegrid--pixels-per-minute)
                   (lambda () 1.008))
                  ((symbol-function 'org-timegrid--grid-top-inset)
                   (lambda () 6.72)))
          ;; Every timed cell on every day must paint once into existing
          ;; tiles.  Collecting the tiles also proves the whole canvas is
          ;; reachable, including the enlarged final tile.
          (dotimes (day org-timegrid-days)
            (cl-loop for minute from 0 below 1440
                     by org-timegrid-slot-minutes do
                     (org-timegrid--set-cursor day minute 0)
                     (pcase-let* ((`(,count . ,rendered)
                                   (render-and-count-cursors
                                    #'org-timegrid--dynamic-fragment))
                                  (tiles (cdr rendered)))
                       (should (= count 1))
                       (should tiles)
                       (dolist (tile tiles)
                         (should (<= 0 tile (1- org-timegrid--tile-count)))
                         (cl-pushnew tile reached-tiles)))))
          (should (equal (sort reached-tiles #'<)
                         (number-sequence 0 (1- org-timegrid--tile-count))))
          ;; With no all-day events, lane zero is the one valid rail cell for
          ;; each day.  It must paint once in the header and nowhere else.
          (dotimes (day org-timegrid-days)
            (org-timegrid--set-all-day-cursor day 0)
            (pcase-let ((`(,count . ,_)
                         (render-and-count-cursors
                          (lambda ()
                            (org-timegrid--dynamic-fragment)
                            (org-timegrid--header)))))
              (should (= count 1)))))))))

(provide 'org-timegrid-test)
;;; org-timegrid-test.el ends here
