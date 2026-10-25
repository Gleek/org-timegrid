;;; org-timegrid-clock-test.el --- Clock display tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)

(defvar touch-screen-current-tool)
(defvar touch-screen-current-timer)

(defun org-timegrid-clock--event-p (event)
  (plist-get (org-timegrid-event-metadata event) :clock))

(defmacro org-timegrid-clock--with-source (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (org-mode)
     (buffer-enable-undo)
     (let ((org-timegrid-org-show-clocks t)
           (org-timegrid-org-auto-save nil)
           (org-timegrid-org--undo-transactions nil)
           (org-timegrid-org--redo-transactions nil)
           (org-timegrid-org--undo-direction nil)
           (org-timegrid-org-filter-function #'org-timegrid-org-default-filter)
           (org-timegrid-org-show-done t)
           (org-timegrid-org-exclude-tags nil)
           (org-timegrid-org-exclude-properties nil)
           (org-timegrid-org-exclude-todo-states nil))
       ,@body)))

(ert-deftest org-timegrid-clock-records-are-separate-from-plans-and-inactive-dates ()
  (org-timegrid-clock--with-source
    (insert "* Task\n<2026-10-24 Sat 09:00-10:00 +1d>\n"
            "[2026-10-24 Sat 08:00-09:00]\n:LOGBOOK:\n"
            "CLOCK: [2026-10-24 Sat 09:20]--[2026-10-24 Sat 10:15] =>  0:55\n"
            ":END:\n** Child\n:LOGBOOK:\n"
            "CLOCK: [2026-10-24 Sat 23:30]--[2026-10-25 Sun 00:30] =>  1:00\n"
            ":END:\n")
    (let* ((events (org-timegrid-org--buffer-events))
           (clocks (seq-filter #'org-timegrid-clock--event-p
                               events))
           (plan (seq-find (lambda (event)
                             (plist-get (org-timegrid-event-metadata event) :history))
                           events)))
      (should (= 3 (length events)))
      (should (= 2 (length clocks)))
      (should plan)
      (should-not (plist-get (org-timegrid-event-metadata plan) :history-until))
      (should (equal '("Task" "Child") (mapcar #'org-timegrid-event-title clocks)))
      (should (equal '(55 60) (mapcar (lambda (event)
                                       (- (org-timegrid-event-end event)
                                          (org-timegrid-event-start event))) clocks)))
      (dolist (event clocks)
        (should-not (plist-get (org-timegrid-event-metadata event) :history))
        (goto-char (plist-get (org-timegrid-event-source event) :marker))
        (should (looking-at-p "\\[2026-"))))
    (let ((org-timegrid-org-show-clocks nil))
      (should (= 1 (length (org-timegrid-org--buffer-events)))))
    (let ((org-timegrid-org-filter-function (lambda (&rest _) nil)))
      (should-not (org-timegrid-org--buffer-events)))))

(ert-deftest org-timegrid-clock-query-preserves-boundaries-and-repeaters ()
  (org-timegrid-clock--with-source
    (insert "* Task\n<2026-10-01 Thu 09:00-10:00 +1d>\n:LOGBOOK:\n"
            "CLOCK: [2026-10-23 Fri 23:30]--[2026-10-24 Sat 00:30] =>  1:00\n"
            "CLOCK: [2026-10-24 Sat 00:30]--[2026-10-24 Sat 01:00] =>  0:30\n"
            "CLOCK: [2026-10-24 Sat 23:30]--[2026-10-25 Sun 00:00] =>  0:30\n"
            "CLOCK: [2026-10-25 Sun 00:00]--[2026-10-25 Sun 01:00] =>  1:00\n:END:\n")
    (let* ((day (* 1440 (calendar-absolute-from-gregorian '(10 24 2026))))
           (all (org-timegrid-org--buffer-events "benchmark"))
           (source (current-buffer)))
      (dolist (range '((0 1440 3) (30 60 1) (1440 2880 1)))
        (let* ((start (+ day (nth 0 range))) (end (+ day (nth 1 range)))
               (bounded (org-timegrid-org--buffer-events nil start end)))
          (should (= (nth 2 range)
                     (seq-count #'org-timegrid-clock--event-p
                                bounded)))
          (cl-letf (((symbol-function 'org-timegrid-org--files) (lambda () '("benchmark")))
                    ((symbol-function 'find-file-noselect) (lambda (&rest _) source)))
            (should
             (equal (mapcar #'org-timegrid-event-id
                            (org-timegrid-org--list-events start end))
                    (mapcar #'org-timegrid-event-id
                            (mapcan (lambda (event)
                                      (org-timegrid-org--expand-event event start end)) all))))))))))

(ert-deftest org-timegrid-clock-running-grows-with-now-and-skips-zero-closed-clocks ()
  (org-timegrid-clock--with-source
    (insert "* Task\n:LOGBOOK:\n"
            "CLOCK: [2026-10-24 Sat 09:00]--[2026-10-24 Sat 09:00] =>  0:00\n"
            "CLOCK: [2026-10-24 Sat 10:00]\n:END:\n")
    (let ((real-decode (symbol-function 'decode-time)))
      (dolist (minute '(0 15 30))
        (cl-letf (((symbol-function 'decode-time)
                   (lambda (&rest args)
                     (apply real-decode
                            (if args args (list (encode-time 0 minute 10 24 10 2026)))))))
          (let* ((events (org-timegrid-org--buffer-events))
                 (event (car events)))
            (should (= 1 (length events)))
            (should (plist-get (org-timegrid-event-metadata event) :running))
            (should (= (max 1 minute) (- (org-timegrid-event-end event)
                                         (org-timegrid-event-start event))))))))))

(ert-deftest org-timegrid-clock-running-mutations-leave-source-unchanged ()
  (org-timegrid-clock--with-source
    (insert "* Task\nCLOCK: [2020-01-01 Wed 09:00]\n")
    (let* ((event (car (org-timegrid-org--buffer-events)))
           (before (buffer-string))
           (start (org-timegrid-event-start event))
           (end (org-timegrid-event-end event)))
      (should-error (org-timegrid-org--update-event-range event (1+ start) (1+ end))
                    :type 'user-error)
      (should-error (org-timegrid-org--remove-event event) :type 'user-error)
      (should-error (org-timegrid-org--remove-entry event) :type 'user-error)
      (should-error (org-timegrid-org--create-event "Copy" start end event) :type 'user-error)
      (should (equal before (buffer-string))))))

(ert-deftest org-timegrid-clock-move-resize-rename-and-undo ()
  (org-timegrid-clock--with-source
    (insert "* Task\n<2026-10-24 Sat 09:00-10:00>\n:LOGBOOK:\n"
            "CLOCK: [2026-10-24 Sat 09:20]--[2026-10-24 Sat 10:15] =>  0:55\n"
            ":END:\n")
    (let* ((before (buffer-string))
           (event (seq-find #'org-timegrid-clock--event-p
                            (org-timegrid-org--buffer-events)))
           (start (org-timegrid-event-start event)))
      (org-timegrid-org--update-event-range event (+ start 1440) (+ start 1495) nil 'timed)
      (should (string-match-p
               (regexp-quote "CLOCK: [2026-10-25 Sun 09:20]--[2026-10-25 Sun 10:15] =>  0:55")
               (buffer-string)))
      ;; A second optimistic edit must validate against the rewritten clock.
      (org-timegrid-org--update-event-range event (+ start 1440) (+ start 1530) "Renamed" 'timed)
      (should (string-prefix-p "* Renamed\n" (buffer-string)))
      (should (string-match-p
               (regexp-quote "[2026-10-25 Sun 10:50] =>  1:30") (buffer-string)))
      (should (string-match-p (regexp-quote "<2026-10-24 Sat 09:00-10:00>") (buffer-string)))
      (should-error (org-timegrid-org--update-event-range event start (+ start 1440) nil 'all-day)
                    :type 'user-error)
      (org-timegrid-org--undo nil nil)
      (org-timegrid-org--undo t nil)
      (should (equal before (buffer-string)))
      (org-timegrid-org--undo nil t)
      (should (string-match-p (regexp-quote "[2026-10-25 Sun 09:20]") (buffer-string))))))

(ert-deftest org-timegrid-clock-delete-and-cut-paste-preserve-clock-kind ()
  (org-timegrid-clock--with-source
    (insert "* Task\n:LOGBOOK:\n"
            "CLOCK: [2026-10-24 Sat 23:30]--[2026-10-25 Sun 00:30] =>  1:00\n"
            "- A note\n:END:\n")
    (let* ((before (buffer-string))
           (event (car (org-timegrid-org--buffer-events)))
           (start (org-timegrid-event-start event))
           (end (org-timegrid-event-end event))
           (org-clock-into-drawer t))
      (org-timegrid-org--remove-event event)
      (should-not (string-match-p "CLOCK:\\|=>" (buffer-string)))
      (should (string-match-p "- A note" (buffer-string)))
      (org-timegrid-org--create-event "Task" (+ start 1440) (+ end 1440)
                                      event (org-timegrid-event-source event) 'timed)
      (let ((events (org-timegrid-org--buffer-events)))
        (should (= 1 (length events)))
        (should (plist-get (org-timegrid-event-metadata (car events)) :clock))
        (should (= (+ start 1440) (org-timegrid-event-start (car events)))))
      (should (string-match-p (regexp-quote "[2026-10-26 Mon 00:30] =>  1:00") (buffer-string)))
      (org-timegrid-org--undo nil nil)
      (org-timegrid-org--undo t nil)
      (should (equal before (buffer-string))))))

(ert-deftest org-timegrid-clock-copy-keeps-only-requested-clock ()
  (org-timegrid-clock--with-source
    (insert "* Task\n<2026-10-24 Sat 09:00-10:00>\n:LOGBOOK:\n"
            "CLOCK: [2026-10-24 Sat 09:20]--[2026-10-24 Sat 10:15] =>  0:55\n"
            "CLOCK: [2026-10-23 Fri 09:00]--[2026-10-23 Fri 10:00] =>  1:00\n:END:\n")
    (let* ((events (org-timegrid-org--buffer-events))
           (clock (seq-find #'org-timegrid-clock--event-p events))
           (start (org-timegrid-event-start clock))
           (org-clock-into-drawer t)
           (copy (org-timegrid-org--duplicate-entry-string clock "Copy" (+ start 1440) (+ start 1500) nil t)))
      (erase-buffer)
      (insert copy)
      (let ((events (org-timegrid-org--buffer-events)))
        (should (= 1 (length events)))
        (should (plist-get (org-timegrid-event-metadata (car events)) :clock))
        (should (equal "Copy" (org-timegrid-event-title (car events))))))))

(ert-deftest org-timegrid-clock-rejects-stale-source ()
  (org-timegrid-clock--with-source
    (insert "* Task\nCLOCK: [2026-10-24 Sat 09:00]--[2026-10-24 Sat 10:00] =>  1:00\n")
    (let* ((event (car (org-timegrid-org--buffer-events)))
           (start (org-timegrid-event-start event)))
      (goto-char (point-min))
      (search-forward "10:00")
      (replace-match "10:30")
      (let ((before (buffer-string)))
        (should-error (org-timegrid-org--update-event-range event start (+ start 60)) :type 'user-error)
        (should-error (org-timegrid-org--remove-event event) :type 'user-error)
        (should (equal before (buffer-string)))))))

(ert-deftest org-timegrid-clock-keeps-heading-after-removing-plan ()
  (org-timegrid-clock--with-source
    (let ((org-timegrid-org-auto-save nil))
      (insert "* Task\n<2026-10-24 Sat 09:00-10:00>\n"
              "CLOCK: [2026-10-24 Sat 09:20]--[2026-10-24 Sat 10:15] =>  0:55\n")
      (let ((plan (seq-find (lambda (event)
                              (eq (plist-get (org-timegrid-event-source event) :kind)
                                  'timestamp))
                            (org-timegrid-org--buffer-events))))
        (org-timegrid-org--remove-event plan)
        (should-not (org-timegrid-org--entry-empty-p plan))
        (should (= 1 (length (org-timegrid-org--buffer-events))))))))

(ert-deftest org-timegrid-clock-refresh-preserves-edit-preview ()
  (with-temp-buffer
    (setq-local major-mode 'org-timegrid-mode
                org-timegrid--backend org-timegrid-org-backend
                org-timegrid--state (org-timegrid--calendar-state-create))
    (dolist (refresh (list #'org-timegrid-org--refresh-clocks
                          (lambda () (org-timegrid--data-tick (current-buffer)))))
      (let (refreshed)
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t))
                  ((symbol-function 'org-timegrid--refresh-data)
                   (lambda () (setq refreshed t))))
          (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil)
          (funcall refresh)
          (should refreshed)
          (setq refreshed nil)
          (setf (org-timegrid--calendar-state-preview org-timegrid--state) 'editing)
          (funcall refresh)
          (should-not refreshed)
          (should org-timegrid--stale))))))

(ert-deftest org-timegrid-clock-minute-tick-reloads-running-events ()
  (with-temp-buffer
    (setq-local major-mode 'org-timegrid-mode
                org-timegrid--state
                (org-timegrid--calendar-state-create
                 :events (list (org-timegrid-event-create :metadata '(:running t)))))
    (let (refreshed)
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t))
                ((symbol-function 'org-timegrid--refresh-data)
                 (lambda () (setq refreshed t))))
        (org-timegrid--clock-tick (current-buffer))
        (should refreshed)
        (setq refreshed nil)
        (setf (org-timegrid--calendar-state-preview org-timegrid--state) 'editing)
        (org-timegrid--clock-tick (current-buffer))
        (should-not refreshed)))))

(defun org-timegrid-clock--display-block (id start end &optional clock day)
  (org-timegrid-event-to-block
   (org-timegrid-event-create
    :id id :title "Proposal" :start (+ (* 100 1440) (* (or day 0) 1440) start)
    :end (+ (* 100 1440) (* (or day 0) 1440) end) :metadata (and clock '(:clock t)))
   100))

(ert-deftest org-timegrid-clock-android-drag-uses-clock-boundaries ()
  (require 'org-timegrid-android)
  (dolist (clock '(nil t))
    (let* ((touch-screen-current-tool '(1 nil nil nil start))
           (touch-screen-current-timer nil)
           (org-timegrid--state
            (org-timegrid--calendar-state-create
             :blocks (list (org-timegrid-clock--display-block 'event 120 180 clock))))
           tracked)
      (cl-letf (((symbol-function 'posn-window) (lambda (_) (selected-window)))
                ((symbol-function 'org-timegrid--mouse-target)
                 (lambda (_) '(:surface grid :block-id event :day 0 :minute 120)))
                ((symbol-function 'org-timegrid--all-day-layout) #'ignore)
                ((symbol-function 'org-timegrid--clear-preview) #'ignore)
                ((symbol-function 'touch-screen-track-drag)
                 (lambda (&rest _)
                   (setq tracked t)
                   (should (eq clock (and org-timegrid--drag-clock-p t)))
                   nil)))
        (org-timegrid-android-long-press '(touchscreen-hold position))
        (should tracked)))))

(ert-deftest org-timegrid-clock-overlays-preserve-the-day-boundary-and-plan-width ()
  (let ((plan (org-timegrid-clock--display-block 'plan 120 180)))
    (dolist (ranges '(nil ((180 240)) ((150 210)) ((120 180))
                         ((120 180) (150 210))))
      (let* ((clocks (mapcar (lambda (range)
                              (org-timegrid-clock--display-block range (car range) (cadr range) t))
                            ranges))
             (layout (org-timegrid--layout-day (cons plan clocks) 0))
             (frames (mapcar (lambda (block) (org-timegrid--layout-frame block 0 200))
                             (seq-filter #'org-timegrid--clock-block-p layout))))
        (should (equal '(0 . 200) (org-timegrid--layout-frame (car layout) 0 200)))
        (should (= (length clocks) (length frames)))
        (dolist (frame frames)
          (should (equal frame (car frames)))
          (should (= 200 (+ (car frame) (* (cdr frame) 0.75))))
          (should (< (cdr frame) 40)))))))

(ert-deftest org-timegrid-clock-overnight-has-a-centered-icon-on-each-day ()
  (with-temp-buffer
    (let* ((org-timegrid-days 2)
           (org-timegrid-start-hour 0)
           (org-timegrid-end-hour 24)
           (org-timegrid-default-zoom 1.0)
           (org-timegrid--state
            (org-timegrid--calendar-state-create
             :week-start 100
             :blocks (list (org-timegrid-clock--display-block 'clock 1380 1500 t))))
           (svg (org-timegrid--svg))
           (circles (dom-by-tag svg 'circle)))
      (should (= 2 (length org-timegrid--geometry)))
      (should (equal '(0 1) (sort (mapcar (lambda (g) (plist-get g :day))
                                         org-timegrid--geometry) #'<)))
      (dolist (geometry org-timegrid--geometry)
        (should (eq 'clock (plist-get geometry :id)))
        (let ((cx (+ (plist-get geometry :x) (/ (plist-get geometry :width) 2.0)))
              (cy (+ (plist-get geometry :y) (/ (plist-get geometry :height) 2.0))))
          (should (seq-some (lambda (circle)
                              (and (= cx (dom-attr circle 'cx))
                                   (= cy (dom-attr circle 'cy)))) circles)))))))

(ert-deftest org-timegrid-clock-rail-hit-testing-and-cursor-use-the-narrow-geometry ()
  (with-temp-buffer
    (let* ((org-timegrid-days 1)
           (blocks (list (org-timegrid-clock--display-block 'plan 120 180)
                         (org-timegrid-clock--display-block 'clock 120 240 t)))
           (org-timegrid--state
            (org-timegrid--calendar-state-create
             :week-start 100 :blocks blocks :cursor-visible t :selected-id 'clock
             :cursor (org-timegrid--cursor-state-create :surface 'grid :day 0 :minute 120))))
      (org-timegrid--svg)
      (dolist (geometry org-timegrid--geometry)
        (let ((xy (cons (+ (plist-get geometry :x) (/ (plist-get geometry :width) 2))
                        (+ (plist-get geometry :y) (/ (plist-get geometry :height) 2)))))
          (cl-letf (((symbol-function 'org-timegrid--position-image-xy) (lambda (_) xy)))
            (should (eq (plist-get (org-timegrid--target nil) :block-id)
                        (plist-get geometry :id))))))
      (let* ((clock (seq-find (lambda (geometry) (eq (plist-get geometry :id) 'clock))
                              org-timegrid--geometry))
             (plan (seq-find (lambda (geometry) (eq (plist-get geometry :id) 'plan))
                             org-timegrid--geometry))
             (cursor (org-timegrid--cursor-rectangle))
             (x (+ (plist-get clock :x) (/ (plist-get clock :width) 2)))
             (y (+ (plist-get plan :y) (plist-get plan :height)))
             (hotspot (seq-find
                       (lambda (entry)
                         (pcase-let ((`((rect . ((,left . ,top) . (,right . ,bottom))) ,_ ,_) entry))
                           (and (<= left x right) (<= top y bottom))))
                       (org-timegrid--image-map))))
        (should (= (plist-get cursor :x) (plist-get clock :x)))
        (should (= (plist-get cursor :width) (plist-get clock :width)))
        ;; A plan's resize edge must not steal the clock strip's body hotspot.
        (should (eq (cadr hotspot) 'calendar-block))
        (should (string-prefix-p "Clock " (plist-get (nth 2 hotspot) 'help-echo))))
      (should (string-prefix-p "Clock " (org-timegrid--block-details (cadr blocks)))))))

(ert-deftest org-timegrid-clock-boundary-badge-click-and-drag-keep-the-owning-day ()
  (with-temp-buffer
    (let* ((org-timegrid-days 3)
           (block (org-timegrid-clock--display-block 'clock 120 180 t))
           (org-timegrid--state
            (org-timegrid--calendar-state-create :week-start 100 :blocks (list block))))
      (org-timegrid--svg)
      (let* ((column (org-timegrid--column-width))
             (geometry (car org-timegrid--geometry))
             ;; This half of the badge crosses into the following day's column.
             (xy (cons (+ (org-timegrid--label-width) column 2)
                       (+ (plist-get geometry :y) (/ (plist-get geometry :height) 2)))))
        (cl-letf (((symbol-function 'org-timegrid--position-image-xy) (lambda (_) xy)))
          (should (= 0 (plist-get (org-timegrid--target nil) :day)))
          (should (eq 'clock (plist-get (org-timegrid--target nil) :block-id)))
          (let ((org-timegrid--drag-clock-p t))
            (setq xy (cons (+ (org-timegrid--label-width) (* 2 column)) (cdr xy)))
            (should (= 1 (plist-get (org-timegrid--target nil) :day)))))))))

(ert-deftest org-timegrid-clock-last-day-badge-fits-the-canvas ()
  (with-temp-buffer
    (let* ((org-timegrid-days 3)
           (block (org-timegrid-clock--display-block 'clock 120 180 t 2))
           (org-timegrid--state
            (org-timegrid--calendar-state-create :week-start 100 :blocks (list block))))
      (org-timegrid--svg)
      (let ((geometry (car org-timegrid--geometry)))
        (should (<= (+ (plist-get geometry :x) (plist-get geometry :width))
                    (org-timegrid--canvas-width)))))))

;;; org-timegrid-clock-test.el ends here
