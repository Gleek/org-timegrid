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

(provide 'org-timegrid-test)
;;; org-timegrid-test.el ends here
