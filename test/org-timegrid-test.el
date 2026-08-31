;;; org-timegrid-test.el --- Tests for org-timegrid -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)

(ert-deftest org-timegrid-test-event-kind-survives-block-conversion ()
  (let* ((event (org-timegrid-event-create
                 :id 'date-only :title "Holiday" :start 14400 :end 15840
                 :all-day t))
         (block (org-timegrid-event-to-block event 10)))
    (should (org-timegrid-block-p block))
    (should (eq (org-timegrid-block-time-kind block) 'all-day))))

(ert-deftest org-timegrid-test-one-transform-handles-both-time-kinds ()
  (let* ((timed (org-timegrid-block-create
                 :id 'timed :day 0 :start 60 :end 120 :time-kind 'timed))
         (all-day (org-timegrid-block-create
                   :id 'all-day :day 0 :start 0 :end 2880
                   :time-kind 'all-day))
         (moved-timed (org-timegrid--transform-block-range timed -120 nil))
         (moved-all-day
          (org-timegrid--transform-block-range all-day -1440 nil)))
    (should (= (org-timegrid-block-day moved-timed) 0))
    (should (= (org-timegrid-block-start moved-timed) 0))
    (should (= (org-timegrid-block-end moved-timed) 60))
    (should (eq (org-timegrid-block-time-kind moved-timed) 'timed))
    ;; All-day spans may continue beyond the visible week.
    (should (= (org-timegrid-block-day moved-all-day) -1))
    (should (= (org-timegrid-block-start moved-all-day) 0))
    (should (= (org-timegrid-block-end moved-all-day) 2880))
    (should (eq (org-timegrid-block-time-kind moved-all-day) 'all-day))))

(ert-deftest org-timegrid-test-backend-receives-explicit-time-kind ()
  (let* ((received nil)
         (org-timegrid--backend
          (org-timegrid-backend-create
           :name "test"
           :list-function (lambda (_start _end) nil)
           :create-function
           (lambda (_title _start _end &optional _source _target time-kind)
             (setq received time-kind))))
         (org-timegrid--state
          (org-timegrid--calendar-state-create :week-start 100))
         (block (org-timegrid-block-create
                 :id 'midnight :day 0 :start 0 :end 1440
                 :title "Timed full day" :time-kind 'timed)))
    (cl-letf (((symbol-function 'org-timegrid--refresh-data) #'ignore))
      (org-timegrid--backend-create "Timed full day" block))
    (should (eq received 'timed))))

(ert-deftest org-timegrid-test-legacy-backend-create-arity-still-works ()
  (let* ((called nil)
         (org-timegrid--backend
          (org-timegrid-backend-create
           :name "legacy"
           :list-function (lambda (_start _end) nil)
           :create-function
           (lambda (_title _start _end _source) (setq called t))))
         (org-timegrid--state
          (org-timegrid--calendar-state-create :week-start 100))
         (block (org-timegrid-block-create
                 :id 'legacy :day 0 :start 0 :end 30
                 :title "Legacy" :time-kind 'timed)))
    (cl-letf (((symbol-function 'org-timegrid--refresh-data) #'ignore))
      (org-timegrid--backend-create "Legacy" block))
    (should called)))

(ert-deftest org-timegrid-test-legacy-three-argument-update-still-works ()
  (let* ((called nil)
         (event (org-timegrid-event-create
                 :id 'legacy :title "Legacy" :start 144000 :end 144030))
         (updater (lambda (_event _start _end) (setq called t))))
    (org-timegrid--call-update updater event 144015 144045 nil 'timed)
    (should called)))

(ert-deftest org-timegrid-test-mixed-kind-render-smoke ()
  (let* ((week 100)
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

(ert-deftest org-timegrid-test-org-update-converts-kind-explicitly ()
  (with-temp-buffer
    (org-mode)
    (insert "* Event\n<2026-08-26 Wed>\n")
    (let* ((event (car (org-timegrid-org--buffer-events "test.org")))
           (start (org-timegrid-event-start event)))
      (org-timegrid-org--update-event-range
       event start (+ start 30) nil 'timed)
      (goto-char (point-min))
      (should (re-search-forward "00:00-00:30" nil t))
      (let ((updated (car (org-timegrid-org--buffer-events "test.org"))))
        (should-not (org-timegrid-event-all-day updated))
        (org-timegrid-org--update-event-range
         updated start (+ start 1440) nil 'all-day)
        (goto-char (point-min))
        (should-not (re-search-forward "[0-9][0-9]:[0-9][0-9]" nil t))
        (should (org-timegrid-event-all-day
                 (car (org-timegrid-org--buffer-events "test.org"))))))))

(ert-deftest org-timegrid-test-org-create-does-not-infer-explicit-timed-kind ()
  (with-temp-buffer
    (org-mode)
    (insert "* Event\n")
    (let* ((start (* 1440
                     (calendar-absolute-from-gregorian '(8 26 2026))))
           (marker (copy-marker (point-min))))
      (org-timegrid-org--create-event
       "Event" start (+ start 1440) nil marker 'timed)
      (goto-char (point-min))
      (should (re-search-forward "00:00" nil t)))))

(ert-deftest org-timegrid-test-drag-proposal-converts-timed-to-all-day ()
  (let* ((source (org-timegrid-block-create
                  :id 'meeting :day 1 :start 600 :end 690
                  :title "Meeting" :time-kind 'timed))
         (org-timegrid--state
          (org-timegrid--calendar-state-create
           :week-start 100 :blocks (list source)))
         (proposal
          (org-timegrid--proposal
           '(:surface grid :block-id meeting :day 1 :minute 615)
           '(:surface rail :day 4 :minute 0)
           nil))
         (block (org-timegrid--operation-block proposal)))
    ;; Merely constructing the hover preview changes no source data.
    (should (eq (org-timegrid--operation-kind proposal) 'move))
    (should (eq (org-timegrid-block-time-kind block) 'all-day))
    (should (= (org-timegrid-block-day block) 4))
    (should (= (org-timegrid-block-start block) 0))
    (should (= (org-timegrid-block-end block) 1440))
    (should (eq (org-timegrid-block-time-kind source) 'timed))
    (should (= (org-timegrid-block-start source) 600))
    (should (= (org-timegrid-block-end source) 690))))

(ert-deftest org-timegrid-test-drag-proposal-converts-all-day-to-default-time ()
  (let* ((source (org-timegrid-block-create
                  :id 'holiday :day 2 :start 0 :end 1440
                  :title "Holiday" :time-kind 'all-day))
         (org-timegrid-default-duration-minutes 45)
         (org-timegrid--state
          (org-timegrid--calendar-state-create
           :week-start 100 :blocks (list source)))
         (proposal
          (org-timegrid--proposal
           '(:surface rail :block-id holiday :day 2 :minute 0)
           '(:surface grid :day 5 :minute 780)
           nil))
         (block (org-timegrid--operation-block proposal)))
    (should (eq (org-timegrid-block-time-kind block) 'timed))
    (should (= (org-timegrid-block-day block) 5))
    (should (= (org-timegrid-block-start block) 780))
    (should (= (org-timegrid-block-end block) 825))))

(ert-deftest org-timegrid-test-multi-day-drag-to-time-grid-is-rejected ()
  (let* ((source (org-timegrid-block-create
                  :id 'trip :day 2 :start 0 :end 2880
                  :title "Trip" :time-kind 'all-day))
         (org-timegrid--state
          (org-timegrid--calendar-state-create
           :week-start 100 :blocks (list source)))
         (proposal
          (org-timegrid--proposal
           '(:surface rail :block-id trip :day 2 :minute 0)
           '(:surface grid :day 5 :minute 780)
           nil)))
    (should (org-timegrid--operation-error proposal))))

(ert-deftest org-timegrid-test-all-day-edge-drag-resizes-by-whole-days ()
  (let* ((source (org-timegrid-block-create
                  :id 'trip :day 1 :start 0 :end 4320
                  :title "Trip" :time-kind 'all-day))
         (org-timegrid--state
          (org-timegrid--calendar-state-create
           :week-start 100 :blocks (list source)))
         (start-proposal
          (org-timegrid--proposal
           '(:surface rail :block-id trip :day 1 :minute 0 :edge top)
           '(:surface rail :day 2 :minute 0)
           nil))
         (end-proposal
          (org-timegrid--proposal
           '(:surface rail :block-id trip :day 1 :minute 0 :edge bottom)
           '(:surface rail :day 5 :minute 0)
           nil))
         (start-block (org-timegrid--operation-block start-proposal))
         (end-block (org-timegrid--operation-block end-proposal)))
    (should (eq (org-timegrid--operation-kind start-proposal) 'resize))
    (should (= (org-timegrid-block-day start-block) 2))
    (should (= (org-timegrid-block-end start-block) 2880))
    (should (eq (org-timegrid--operation-kind end-proposal) 'resize))
    (should (= (org-timegrid-block-day end-block) 1))
    (should (= (org-timegrid-block-end end-block) 7200))))

(ert-deftest org-timegrid-test-all-day-edge-hotspots-use-horizontal-drag ()
  (let ((org-timegrid--header-geometry
         '((:id trip :x 100 :y 50 :width 200 :height 18
                :allow-left t :allow-right t))))
    (let ((map (org-timegrid--header-image-map)))
      (should (= (length map) 3))
      (should (equal (plist-get (nth 2 (car map)) 'pointer) 'hdrag))
      (should (equal (plist-get (nth 2 (cadr map)) 'pointer) 'hdrag)))))

(ert-deftest org-timegrid-test-rail-image-map-areas-retain-surface-ownership ()
  ;; Rendering a drag preview changes the hotspot beneath the pointer.  These
  ;; must all remain the same logical surface or the preview oscillates
  ;; between the rail and grid and an existing-block drag can become create.
  (dolist (area '(header-line calendar-rail-block calendar-rail-resize))
    (should (org-timegrid--rail-area-p area)))
  (dolist (area '(nil calendar-block calendar-resize))
    (should-not (org-timegrid--rail-area-p area))))

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

(ert-deftest org-timegrid-test-drag-copy-kinds-remain-distinct ()
  (let* ((source (org-timegrid-block-create
                  :id 'meeting :day 1 :start 600 :end 660
                  :title "Meeting" :time-kind 'timed))
         (org-timegrid--state
          (org-timegrid--calendar-state-create
           :week-start 100 :blocks (list source)))
         (origin '(:surface grid :block-id meeting :day 1 :minute 615))
         (target '(:surface grid :day 2 :minute 615)))
    (should
     (eq (org-timegrid--operation-kind
          (org-timegrid--proposal origin target 'duplicate-entry))
         'duplicate-entry))
    (should
     (eq (org-timegrid--operation-kind
          (org-timegrid--proposal origin target 'add-occurrence))
         'add-occurrence))))

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

(provide 'org-timegrid-test)
;;; org-timegrid-test.el ends here
