;;; org-timegrid-test.el --- Tests for org-timegrid -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)
(require 'org-timegrid-agenda)

(defun org-timegrid-test--svg-image-spec (svg &rest properties)
  "Return an image spec for SVG without invoking an image backend."
  (append (list 'image :type 'svg :data
                (with-temp-buffer
                  (svg-print svg)
                  (buffer-string)))
          properties))

(defmacro org-timegrid-test--with-svg-data (&rest body)
  "Run BODY with real SVG support or an XML-only image substitute."
  (declare (indent 0) (debug t))
  `(if (image-type-available-p 'svg)
       (progn ,@body)
     (cl-letf (((symbol-function 'svg-image)
                #'org-timegrid-test--svg-image-spec))
       ,@body)))

(ert-deftest org-timegrid-test-org-default-filter ()
  (with-temp-buffer
    (org-mode)
    (insert "* DONE Hidden :private:\n:PROPERTIES:\n:CALENDAR: no\n:END:\n<2026-09-05 Sat 10:00 +1w>\n")
    (let* ((tree (org-element-parse-buffer))
           (headline (org-element-map tree 'headline #'identity nil t))
           (timestamp (org-element-map headline 'timestamp #'identity nil t)))
      (should (org-timegrid-org-default-filter headline timestamp))
      (let ((org-timegrid-org-show-done nil))
        (should-not (org-timegrid-org-default-filter headline timestamp)))
      (let ((org-timegrid-org-show-repeaters nil))
        (should-not (org-timegrid-org-default-filter headline timestamp)))
      (let ((org-timegrid-org-exclude-tags '("private")))
        (should-not (org-timegrid-org-default-filter headline timestamp)))
      (let ((org-timegrid-org-exclude-todo-states '("DONE")))
        (should-not (org-timegrid-org-default-filter headline timestamp)))
      (let ((org-timegrid-org-exclude-properties '(("CALENDAR" . "no"))))
        (should-not (org-timegrid-org-default-filter headline timestamp)))
      (let ((org-timegrid-org-exclude-properties '(("CALENDAR"))))
        (should-not (org-timegrid-org-default-filter headline timestamp))))))

(ert-deftest org-timegrid-test-org-custom-filter-keeps-time-gate ()
  (with-temp-buffer
    (org-mode)
    (insert "* Keep\n<2026-09-05 Sat 10:00>\n* Reject\n<2026-09-05 Sat 11:00>\n* Inactive\n[2026-09-05 Sat 12:00]\n")
    (let ((org-timegrid-org-filter-function
           (lambda (headline _timestamp)
             (equal (org-element-property :raw-value headline) "Keep"))))
      (should (equal (mapcar #'org-timegrid-event-title
                             (org-timegrid-org--buffer-events "test.org"))
                     '("Keep"))))))

(ert-deftest org-timegrid-test-svg-colors-are-normalized ()
  (dolist (case '(("Red1" nil "#ff0000")
                  ("#abc" nil "#aabbcc")
                  ("not-a-color" "#3a5fcd" "#3a5fcd")))
    (pcase-let ((`(,color ,fallback ,expected) case))
      (ert-info ((format "color %s" color))
        (should (equal (org-timegrid--svg-color color fallback) expected))))))

(ert-deftest org-timegrid-test-android-text-uses-paths ()
  (require 'org-timegrid-android)
  (unwind-protect
      (let ((svg (svg-create 100 20)))
        (org-timegrid-android--draw-text
         svg "Test 12" :x 2 :y 12 :font-size 10 :fill "#123456")
        (let ((xml (with-temp-buffer
                     (svg-print svg)
                     (buffer-string))))
          (should (string-match-p "<path" xml))
          (should (string-match-p "fill=\"#123456\"" xml))
          (should-not (string-match-p "<text" xml)))
        (let ((regular (svg-create 20 20))
              (medium (svg-create 20 20)))
          (org-timegrid-android--draw-text regular "A" :font-weight 400)
          (org-timegrid-android--draw-text medium "A" :font-weight 500)
          (should-not
           (equal (with-temp-buffer (svg-print regular) (buffer-string))
                  (with-temp-buffer (svg-print medium) (buffer-string))))))
    (advice-remove 'org-timegrid--draw-text
                   #'org-timegrid-android--draw-text)))

(ert-deftest org-timegrid-test-android-touch-scroll-uses-pixel-delta ()
  (require 'org-timegrid-android)
  (let ((org-timegrid-android-scroll-scale 0.5)
        (org-timegrid-android-scroll-max-step 40)
        seen)
    (with-current-buffer (window-buffer (selected-window))
      (setq-local org-timegrid--scroll-boundary '(bottom . 1.0)))
    (cl-letf (((symbol-function 'org-timegrid-scroll)
               (lambda (pixels window) (setq seen (list pixels window)))))
      (org-timegrid-android-scroll
       (list 'touchscreen-scroll (selected-window) 4 37))
      (should (equal seen (list 18.5 (selected-window))))
      (org-timegrid-android-scroll
       (list 'touchscreen-scroll (selected-window) 4 200))
      (should (equal seen (list 40 (selected-window))))
      (should-not
       (buffer-local-value 'org-timegrid--scroll-boundary
                           (window-buffer (selected-window)))))))

(ert-deftest org-timegrid-test-android-configures-shared-one-day-view ()
  (require 'org-timegrid-android)
  (with-temp-buffer
    (org-timegrid-mode)
    (org-timegrid-android--configure-buffer)
    (should (= org-timegrid-days 1))
    (should (= org-timegrid-default-zoom org-timegrid-android-zoom))
    (should-not touch-screen-display-keyboard)
    (should (equal org-timegrid-header-title-style
                   org-timegrid-android-header-title-style))
    (should (equal org-timegrid-single-day-label-style
                   org-timegrid-android-single-day-label-style))
    (let ((org-timegrid-android-display-keyboard t))
      (org-timegrid-android--configure-buffer)
      (should touch-screen-display-keyboard)
      (should-not touch-screen-keyboard-function))))

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

(ert-deftest org-timegrid-test-agenda-strip-uses-timegrid-scale ()
  (with-temp-buffer
    (org-timegrid-test--with-svg-data
      (cl-letf (((symbol-function 'org-timegrid--zoom-factor)
                 (lambda (&optional _window) 2))
                ((symbol-function 'org-timegrid--frame-font-factor)
                 (lambda (&optional _window) 1)))
        (let ((data (plist-get (cdr (org-timegrid-day-image nil 0 60 400))
                               :data)))
          (should (string-match-p "height=\"120\"" data))
          (should (string-match-p "font-size=\"20\"" data)))))))

(ert-deftest org-timegrid-test-agenda-strip-labels-unaligned-window ()
  (with-temp-buffer
    (org-timegrid-test--with-svg-data
      (let ((data (plist-get (cdr (org-timegrid-day-image nil 557 617 400))
                             :data)))
        (should (string-match-p ">[[:space:]]*10:00</text>" data))))))

(ert-deftest org-timegrid-test-agenda-strip-follows-agenda-day ()
  (let ((org-starting-day 12345))
    (should (= (org-timegrid-agenda--display-day) 12345))
    (cl-letf (((symbol-function 'org-timegrid-week)
               (lambda (day) day)))
      (should (= (org-timegrid-agenda-open-week) 12345)))))

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

(ert-deftest org-timegrid-test-isearch-finds-nearest-adjacent-week ()
  (with-temp-buffer
    (let* ((org-timegrid-days 7)
           (org-timegrid-isearch-week-limit 2)
           (org-timegrid--state
            (org-timegrid--calendar-state-create :week-start 100))
           (events
            (list (org-timegrid-event-create
                   :id 'past :title "Needle past" :start (* 95 1440)
                   :end (+ (* 95 1440) 60))
                  (org-timegrid-event-create
                   :id 'near :title "Needle near" :start (* 108 1440)
                   :end (+ (* 108 1440) 60))
                  (org-timegrid-event-create
                   :id 'far :title "Needle far" :start (* 113 1440)
                   :end (+ (* 113 1440) 60))))
           (org-timegrid--backend
            (org-timegrid-backend-create
             :name "search" :list-function (lambda (_start _end) events)))
           (isearch-regexp nil)
           (isearch-regexp-function nil)
           (isearch-case-fold-search t))
      (let ((isearch-forward t))
        (should (eq (org-timegrid-event-id
                     (org-timegrid-isearch--matching-event "needle"))
                    'near)))
      (let ((isearch-forward nil))
        (should (eq (org-timegrid-event-id
                     (org-timegrid-isearch--matching-event "needle"))
                    'past))))))

(ert-deftest org-timegrid-test-isearch-index-follows-block-order ()
  (with-temp-buffer
    (insert " \n ")
    (let* ((org-timegrid--tile-count 2)
           (org-timegrid--tile-markers (vector 1 3))
           (first (org-timegrid-block-create :id 'first :title "First"))
           (second (org-timegrid-block-create :id 'second :title "Second")))
      (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                ((symbol-function 'org-timegrid--ordered-blocks)
                 (lambda () (list first second))))
        (org-timegrid-isearch--index))
      (should (< (caar (mapcar #'cdr org-timegrid-isearch--anchors))
                 (caadr (mapcar #'cdr org-timegrid-isearch--anchors))))
      (should (= (aref org-timegrid--tile-markers 1)
                 (+ 3 (length "First\0Second\0")))))))

(ert-deftest org-timegrid-test-isearch-sync-preserves-native-search-state ()
  (with-temp-buffer
    (insert (propertize "needle" 'org-timegrid-isearch-block 'block))
    (goto-char (point-max))
    (set-match-data (list (point-min) (point-max)))
    (let ((isearch-mode t)
          (isearch-success t)
          (isearch-string "needle")
          (point (point))
          (match-data (match-data t)))
      (cl-letf (((symbol-function 'org-timegrid--goto-block)
                 (lambda (_block)
                   (goto-char (point-min))
                   (string-match "other" "other"))))
        (org-timegrid-isearch--sync))
      (should (= (point) point))
      (should (equal (match-data t) match-data)))))

(ert-deftest org-timegrid-test-isearch-abort-restores-selection ()
  (with-temp-buffer
    (insert " ")
    (let* ((cursor (org-timegrid--cursor-state-create
                    :surface 'grid :day 2 :minute 600 :lane 0))
           (org-timegrid--state
            (org-timegrid--calendar-state-create
             :week-start 100
             :cursor (org-timegrid--cursor-state-create
                      :surface 'rail :day 4 :minute 0 :lane 0)
             :cursor-visible t :selected-id 'search-match))
           (org-timegrid-isearch--origin
            (list 100 cursor t 'original-selection))
           (org-timegrid-isearch--point (point-min))
           (isearch-mode-end-hook-quit t))
      (cl-letf (((symbol-function 'org-timegrid--reload-state) #'ignore)
                ((symbol-function 'org-timegrid--refresh) #'ignore))
        (org-timegrid-isearch--finish))
      (should (eq (org-timegrid--calendar-state-selected-id
                   org-timegrid--state)
                  'original-selection))
      (should (equal (org-timegrid--cursor) cursor)))))

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
      (org-timegrid-test--with-svg-data
        (should (eq (car (org-timegrid--svg)) 'svg))
        (should (stringp (org-timegrid--header))))
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
          (let ((event (car (org-timegrid-org--buffer-events "test.org"))))
            (should-not (org-timegrid-event-all-day event))
            (should (= (org-timegrid-event-start event) start))
            (should (= (org-timegrid-event-end event) (+ start 30)))))))))

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

(ert-deftest org-timegrid-test-header-navigation-targets ()
  (let ((org-timegrid-days 1))
    (cl-letf (((symbol-function 'org-timegrid--header-left-offset) (lambda (_) 0)))
      (should (eq (org-timegrid--header-navigation-action
                   nil '(20 . 10) (selected-window))
                  #'org-timegrid-goto-date)))
    (cl-letf (((symbol-function 'org-timegrid--header-left-offset) (lambda (_) 0)))
      (should (eq (org-timegrid--header-navigation-action
                   nil (cons 1 (1+ (org-timegrid--header-title-height)))
                   (selected-window))
                  #'org-timegrid-goto-today)))))

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
         (kill-ring
          (list
           (propertize
            "Meeting" 'org-timegrid-payload
            (list :version 1 :cut nil
                  :items (list (list :title "Meeting" :offset 0 :duration 60
                                     :time-kind 'timed :event source
                                     :target 'source-record))))))
         targets)
    (cl-letf (((symbol-function 'org-timegrid--backend-create)
               (lambda (_title _block _source target) (push target targets)))
              ((symbol-function 'org-timegrid--transaction)
               (lambda (function) (funcall function)))
              ((symbol-function 'org-timegrid--reveal-cursor) #'ignore))
      (org-timegrid-yank)
      (org-timegrid-yank t)
      (let ((payload (get-text-property 0 'org-timegrid-payload
                                        (car kill-ring))))
        (put-text-property 0 (length (car kill-ring)) 'org-timegrid-payload
                           (plist-put payload :cut t) (car kill-ring)))
      (org-timegrid-yank))
    (should (equal (nreverse targets)
                   '(nil source-record source-record)))))

(ert-deftest org-timegrid-test-calendar-region-is-half-open-and-reversible ()
  (let ((org-timegrid--state
         (org-timegrid--calendar-state-create
          :week-start 100
          :cursor (org-timegrid--cursor-state-create
                   :surface 'grid :day 2 :minute 600 :lane 0)
          :cursor-visible t)))
    (cl-letf (((symbol-function 'org-timegrid--render-ui-change) #'ignore))
      (org-timegrid-set-mark-command))
    (org-timegrid--set-cursor 2 615)
    (should (equal (org-timegrid--region-range)
                   (cons (+ (* 102 1440) 600) (+ (* 102 1440) 615))))
    (org-timegrid--set-cursor 2 585)
    (should (equal (org-timegrid--region-range)
                   (cons (+ (* 102 1440) 585) (+ (* 102 1440) 600))))))

(ert-deftest org-timegrid-test-region-damage-keeps-cross-day-column-changes ()
  (should (equal (org-timegrid--range-difference '(100 . 200) '(100 . 150))
                 '((150 . 200))))
  (should (equal (org-timegrid--range-difference '(100 . 150) '(100 . 200))
                 nil))
  (should (equal (org-timegrid--range-difference '(100 . 300) '(150 . 250))
                 '((100 . 150) (250 . 300)))))

(ert-deftest org-timegrid-test-free-region-copy-is-text-only ()
  (let* ((org-timegrid--backend
          (org-timegrid-backend-create :name "empty"
                                       :list-function (lambda (&rest _) nil)))
         (org-timegrid--state
          (org-timegrid--calendar-state-create
           :week-start 100 :mark (+ (* 100 1440) 600) :region-active t
           :cursor (org-timegrid--cursor-state-create
                    :surface 'grid :day 0 :minute 660 :lane 0)
           :cursor-visible t))
         kill-ring)
    (cl-letf (((symbol-function 'org-timegrid--render-ui-change) #'ignore))
      (org-timegrid-copy-selected))
    (should (string-match-p "\n[0-9:]+–[0-9:]+  Free" (car kill-ring)))
    (should-not (get-text-property 0 'org-timegrid-payload (car kill-ring)))))

(ert-deftest org-timegrid-test-copy-text-groups-items-by-day ()
  (let* ((day (calendar-absolute-from-gregorian '(9 14 2026)))
         (start (+ (* day 1440) 480))
         (selection
          (list :start start :end (+ start 180)
                :events
                (list (org-timegrid-event-create
                       :title "First" :start start :end (+ start 45))
                      (org-timegrid-event-create
                       :title "Second" :start (+ start 60)
                       :end (+ start 120))))))
    (should
     (equal (org-timegrid--selection-text selection)
            (concat "Mon 14 Sep 2026\n"
                    "08:00–08:45  First\n"
                    "08:45–09:00  Free\n"
                    "09:00–10:00  Second\n"
                    "10:00–11:00  Free")))
    (should
     (equal (org-timegrid--selection-text
             (list :start start :end (+ start 1440) :events nil))
            (concat "Mon 14 Sep 2026\n08:00–24:00  Free\n\n"
                    "Tue 15 Sep 2026\n00:00–08:00  Free")))))

(ert-deftest org-timegrid-test-org-bulk-transaction-undoes-as-one-unit ()
  (with-temp-buffer
    (org-mode)
    (insert "* Task\n<2026-09-14 Mon 09:00-10:00>\n<2026-09-14 Mon 11:00-12:00>\n")
    (setq buffer-undo-list nil)
    (let ((events (org-timegrid-org--buffer-events "test.org"))
          (org-timegrid-org--undo-transactions nil)
          (org-timegrid-org--redo-transactions nil)
          (org-timegrid-org--undo-direction nil)
          (org-timegrid-org-auto-save nil))
      (org-timegrid-org--transaction
       (lambda ()
         (org-timegrid-org--remove-event (nth 0 events))
         (should-not (org-timegrid-org--entry-empty-p (nth 0 events)))
         (org-timegrid-org--remove-event (nth 1 events))
         (should (org-timegrid-org--entry-empty-p (nth 1 events)))))
      (should (= (length org-timegrid-org--undo-transactions) 1))
      (should-not (string-match-p "<2026" (buffer-string)))
      (org-timegrid-org--undo nil nil)
      (should (= (how-many "<2026" (point-min) (point-max)) 2))
      ;; Starting a new ordinary undo run reverses the previous run, like
      ;; native `undo'; no dedicated redo command is required.
      (org-timegrid-org--undo nil nil)
      (should-not (string-match-p "<2026" (buffer-string)))
      (org-timegrid-org--undo nil nil)
      (should (= (how-many "<2026" (point-min) (point-max)) 2)))))

(ert-deftest org-timegrid-test-org-bulk-create-removes-first-entry-too ()
  (let* ((file (make-temp-file "org-timegrid-bulk-" nil ".org"
                               "* Existing\n"))
         (org-timegrid-org-capture-file file)
         (org-timegrid-org-capture-template
          '(:target file :template "* %{title}\n%{time-range}\n"))
         (org-timegrid-org--undo-transactions nil)
         (org-timegrid-org--redo-transactions nil)
         (org-timegrid-org--undo-direction nil)
         (org-timegrid-org-auto-save nil))
    (unwind-protect
        (progn
          (org-timegrid-org--transaction
           (lambda ()
             (org-timegrid-org--create-event "First" 1065417600 1065417660)
             (org-timegrid-org--create-event "Second" 1065417720 1065417780)
             (org-timegrid-org--create-event "Third" 1065417840 1065417900)))
          (with-current-buffer (find-file-noselect file)
            (should (string-match-p "First" (buffer-string))))
          (org-timegrid-org--undo nil nil)
          (with-current-buffer (find-file-noselect file)
            (should (equal (buffer-string) "* Existing\n"))))
      (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest org-timegrid-test-org-bulk-duplicate-removes-first-entry-too ()
  (let* ((source-buffer (generate-new-buffer " *timegrid-sources*"))
         (file (make-temp-file "org-timegrid-duplicates-" nil ".org"
                               "* Existing\n"))
         (org-timegrid-org-capture-file file)
         (org-timegrid-org--undo-transactions nil)
         (org-timegrid-org--redo-transactions nil)
         (org-timegrid-org--undo-direction nil)
         (org-timegrid-org-auto-save nil)
         events)
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (org-mode)
            (insert "* First\n<2026-09-14 Mon 08:00-09:00>\n"
                    "* Second\n<2026-09-14 Mon 10:00-11:00>\n"
                    "* Third\n<2026-09-14 Mon 12:00-13:00>\n")
            (setq events (org-timegrid-org--buffer-events "sources.org")))
          (org-timegrid-org--transaction
           (lambda ()
             (cl-loop for event in events
                      for start from 1065423360 by 120
                      do (org-timegrid-org--create-event
                          (org-timegrid-event-title event)
                          start (+ start 60) event))))
          (org-timegrid-org--undo nil nil)
          (with-current-buffer (find-file-noselect file)
            (should (equal (buffer-string) "* Existing\n"))))
      (when (buffer-live-p source-buffer) (kill-buffer source-buffer))
      (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer))
      (delete-file file))))

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
    (org-timegrid-test--with-svg-data
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
              (should (= count 1))))))))))

(provide 'org-timegrid-test)
;;; org-timegrid-test.el ends here
