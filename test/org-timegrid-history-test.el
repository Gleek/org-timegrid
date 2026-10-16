;;; org-timegrid-history-test.el --- Repeater history tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-timegrid-org)

(defun org-timegrid-history-test--minute (day hour)
  (+ (* (calendar-absolute-from-gregorian (list 10 day 2026)) 1440)
     (* hour 60)))

(defun org-timegrid-history-test--events ()
  (mapcan (lambda (event)
            (org-timegrid-org--expand-event
             event (org-timegrid-history-test--minute 1 0)
             (org-timegrid-history-test--minute 6 0)))
          (org-timegrid-org--buffer-events "history.org")))

(defmacro org-timegrid-history-test--with-entry (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (org-mode)
     (buffer-enable-undo)
     (insert "* Walk\n<2026-10-01 Thu 17:00-17:30 +1d>\n")
     (let ((org-timegrid-org--undo-transactions nil)
           (org-timegrid-org--redo-transactions nil)
           (org-timegrid-org--undo-direction nil)
           (org-timegrid-org-show-repeaters t)
           (org-timegrid-org-show-done t)
           (org-timegrid-org-filter-function (lambda (&rest _) t))
           (org-timegrid-org-repeater-history t)
           (org-timegrid-org-auto-save nil)
           (org-timegrid--edit-context nil))
       ,@body)))

(ert-deftest org-timegrid-history-opt-in-precedence ()
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: TIMEGRID_REPEATER_HISTORY t\n* Parent\n:PROPERTIES:\n:TIMEGRID_REPEATER_HISTORY: nil\n:END:\n** Child\n* Other\n")
    (org-mode)
    (let ((org-timegrid-org-repeater-history nil))
      (goto-char (point-min))
      (search-forward "** Child")
      (should-not (org-timegrid-org--repeater-history-p))
      (search-forward "* Other")
      (should (org-timegrid-org--repeater-history-p)))))

(ert-deftest org-timegrid-history-future-and-consecutive-edits ()
  (org-timegrid-history-test--with-entry
    (let ((event (nth 2 (org-timegrid-history-test--events))) (prompts 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (cl-incf prompts) "this and future")))
        (org-timegrid-org--update-event-range
         event (org-timegrid-history-test--minute 3 18)
         (+ 30 (org-timegrid-history-test--minute 3 18)))
        (org-timegrid-org--update-event-range
         event (org-timegrid-history-test--minute 3 19)
         (+ 45 (org-timegrid-history-test--minute 3 19))))
      (should (= prompts 1))
      (should (= (length (org-timegrid-org--buffer-events)) 2))
      (should (equal (mapcar (lambda (e) (% (org-timegrid-event-start e) 1440))
                            (org-timegrid-history-test--events))
                     '(1020 1020 1140 1140 1140))))))

(ert-deftest org-timegrid-history-single-resumes-and-undoes ()
  (org-timegrid-history-test--with-entry
    (let ((event (nth 2 (org-timegrid-history-test--events)))
          (before (buffer-string)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "just this")))
        (org-timegrid-org--update-event-range
         event (org-timegrid-history-test--minute 3 18)
         (+ 30 (org-timegrid-history-test--minute 3 18))))
      (should (equal (mapcar (lambda (e) (% (org-timegrid-event-start e) 1440))
                            (org-timegrid-history-test--events))
                     '(1020 1020 1080 1020 1020)))
      (let ((undo-in-progress t)) (undo-only 1))
      (should (equal before (buffer-string))))))

(ert-deftest org-timegrid-history-all-keeps-earlier-series ()
  (org-timegrid-history-test--with-entry
    (goto-char (point-max))
    (insert "<2026-10-03 Sat 18:00-18:45 +1d>\n")
    (let ((event (nth 2 (org-timegrid-history-test--events))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "all")))
        (org-timegrid-org--update-event-range
         event (+ 15 (org-timegrid-event-start event))
         (+ 30 (org-timegrid-event-end event))))
      (should (equal (mapcar (lambda (e) (% (org-timegrid-event-start e) 1440))
                            (org-timegrid-history-test--events))
                     '(1020 1020 1095 1095 1095))))))

(ert-deftest org-timegrid-history-disabled-keeps-independent-series ()
  (org-timegrid-history-test--with-entry
    (goto-char (point-max))
    (insert "<2026-10-03 Sat 18:00-18:30 +1d>\n")
    (let ((org-timegrid-org-repeater-history nil))
      (should (= 8 (length (org-timegrid-history-test--events)))))))

(ert-deftest org-timegrid-history-rejects-cross-date-and-read-only ()
  (org-timegrid-history-test--with-entry
    (let ((event (nth 2 (org-timegrid-history-test--events)))
          (before (buffer-string)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "just this")))
        (should-error (org-timegrid-org--update-event-range
                       event (org-timegrid-history-test--minute 4 18)
                       (+ 30 (org-timegrid-history-test--minute 4 18)))
                      :type 'user-error)
        (let ((buffer-read-only t))
          (should-error (org-timegrid-org--update-event-range
                         event (org-timegrid-history-test--minute 3 18)
                         (+ 30 (org-timegrid-history-test--minute 3 18)))
                        :type 'user-error)))
      (should (equal before (buffer-string))))))

(ert-deftest org-timegrid-history-first-and-before-existing-version ()
  (dolist (day '(1 2))
    (org-timegrid-history-test--with-entry
      (goto-char (point-max))
      (insert "<2026-10-03 Sat 19:00-19:30 +1d>\n")
      (let ((event (nth (1- day) (org-timegrid-history-test--events))))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "just this")))
          (org-timegrid-org--update-event-range
           event (org-timegrid-history-test--minute day 18)
           (+ 30 (org-timegrid-history-test--minute day 18))))
        (should (equal (mapcar (lambda (e) (% (org-timegrid-event-start e) 1440))
                              (org-timegrid-history-test--events))
                       (if (= day 1) '(1080 1020 1140 1140 1140)
                         '(1020 1080 1140 1140 1140))))))))

(ert-deftest org-timegrid-history-future-stops-at-next-series ()
  (org-timegrid-history-test--with-entry
    (goto-char (point-max))
    (insert "<2026-10-04 Sun 19:00-19:45 +1d>\n")
    (let ((event (nth 1 (org-timegrid-history-test--events))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "this and future")))
        (org-timegrid-org--update-event-range
         event (+ 60 (org-timegrid-event-start event))
         (+ 60 (org-timegrid-event-end event))))
      (should (equal (mapcar (lambda (e) (% (org-timegrid-event-start e) 1440))
                            (org-timegrid-history-test--events))
                     '(1020 1080 1080 1140 1140))))))

(ert-deftest org-timegrid-history-planning-split-identities ()
  (org-timegrid-history-test--with-entry
    (goto-char (point-min))
    (forward-line 1)
    (insert "SCHEDULED: ")
    (let ((event (nth 2 (org-timegrid-history-test--events))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "this and future")))
        (org-timegrid-org--update-event-range
         event (+ 60 (org-timegrid-event-start event))
         (+ 60 (org-timegrid-event-end event))))
      (let ((reloaded (nth 2 (org-timegrid-history-test--events))))
        (should (equal (org-timegrid-event-id event) (org-timegrid-event-id reloaded)))
        (should (eq (plist-get (org-timegrid-event-source reloaded) :kind) 'timestamp))))))

(ert-deftest org-timegrid-history-hourly-scoped-edit-is-atomic ()
  (org-timegrid-history-test--with-entry
    (goto-char (point-min))
    (search-forward "+1d")
    (replace-match "+1h")
    (let ((event (car (org-timegrid-history-test--events)))
          (before (buffer-string)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "just this")))
        (should-error (org-timegrid-org--update-event-range
                       event (+ 15 (org-timegrid-event-start event))
                       (+ 15 (org-timegrid-event-end event))) :type 'user-error))
      (should (equal before (buffer-string))))))

(ert-deftest org-timegrid-history-two-edits-undo-and-redo ()
  (org-timegrid-history-test--with-entry
    (let ((org-timegrid-org--undo-transactions nil)
          (org-timegrid-org--redo-transactions nil)
          (org-timegrid-org--undo-direction nil)
          (before (buffer-string))
          (event (nth 2 (org-timegrid-history-test--events))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "this and future")))
        (org-timegrid-org--update-event-range
         event (+ 60 (org-timegrid-event-start event))
         (+ 75 (org-timegrid-event-end event)))
        (org-timegrid-org--update-event-range
         event (+ 15 (org-timegrid-event-start event))
         (+ 15 (org-timegrid-event-end event))))
      (let ((after (buffer-string)))
        (org-timegrid-org--undo nil nil)
        (org-timegrid-org--undo t nil)
        (should (equal before (buffer-string)))
        (org-timegrid-org--undo nil t)
        (org-timegrid-org--undo t t)
        (should (equal after (buffer-string)))))))

(ert-deftest org-timegrid-history-delete-scopes-respect-breaks ()
  (dolist (choice '("just this" "this and future" "all"))
    (org-timegrid-history-test--with-entry
      (goto-char (point-max))
      (insert "<2026-10-03 Sat 18:00-18:30 +1d>\n<2026-10-05 Mon 19:00-19:30 +1d>\n")
      (let ((before (buffer-string))
            (event (nth 3 (org-timegrid-history-test--events)))
            (prompts 0))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (cl-incf prompts) choice)))
          (org-timegrid-org--remove-event event))
        (should (= prompts 1))
        (should (equal (mapcar (lambda (e) (nth 1 (calendar-gregorian-from-absolute
                                                  (floor (org-timegrid-event-start e) 1440))))
                              (org-timegrid-history-test--events))
                       (if (equal choice "all") '(1 2 5) '(1 2 3 5))))
        (let ((undo-in-progress t)) (undo-only 1))
        (should (equal before (buffer-string)))))))

(ert-deftest org-timegrid-history-delete-single-resumes ()
  (org-timegrid-history-test--with-entry
    (let ((event (nth 2 (org-timegrid-history-test--events))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "just this")))
        (org-timegrid-org--remove-event event))
      (should (equal (mapcar (lambda (e) (nth 1 (calendar-gregorian-from-absolute
                                                (floor (org-timegrid-event-start e) 1440))))
                            (org-timegrid-history-test--events))
                     '(1 2 4 5))))))

(ert-deftest org-timegrid-history-delete-first-planning-occurrence ()
  (org-timegrid-history-test--with-entry
    (goto-char (point-min))
    (forward-line 1)
    (insert "SCHEDULED: ")
    (let ((event (car (org-timegrid-history-test--events))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "just this")))
        (org-timegrid-org--remove-event event))
      (should-not (string-match-p "SCHEDULED:" (buffer-string)))
      (should (= 4 (length (org-timegrid-history-test--events)))))))

(ert-deftest org-timegrid-history-ordinary-timestamps-remain-independent ()
  (org-timegrid-history-test--with-entry
    (erase-buffer)
    (insert "* Walk\n<2026-10-01 Thu 09:00-09:30>\n<2026-10-01 Thu 17:00-17:30>\n")
    (let ((events (org-timegrid-history-test--events)))
      (should (= 2 (length events)))
      (should-not (plist-get (org-timegrid-event-metadata (car events)) :history)))))

(ert-deftest org-timegrid-history-refuses-undo-and-redo-after-source-edit ()
  (dolist (redo '(nil t))
    (org-timegrid-history-test--with-entry
      (org-timegrid-org--add-range (copy-marker 1) 1065422040 1065422070)
      (when redo (org-timegrid-org--undo nil nil))
      (goto-char (point-max))
      (insert "Manual source edit\n")
      (undo-boundary)
      (let ((before (buffer-string)))
        (should-error (org-timegrid-org--undo nil redo) :type 'user-error)
        (should (equal before (buffer-string)))))))

(ert-deftest org-timegrid-history-new-edit-drops-invalidated-transactions ()
  (org-timegrid-history-test--with-entry
    (org-timegrid-org--add-range (copy-marker 1) 1065422040 1065422070)
    (goto-char (point-max))
    (insert "Manual source edit\n")
    (undo-boundary)
    (let ((before (buffer-string)))
      (org-timegrid-org--add-range (copy-marker 1) 1065422100 1065422130)
      (should (= 1 (length org-timegrid-org--undo-transactions)))
      (org-timegrid-org--undo nil nil)
      (should (equal before (buffer-string))))))

(ert-deftest org-timegrid-history-checks-all-sources-before-undo ()
  (org-timegrid-history-test--with-entry
    (let ((first (current-buffer)))
      (with-temp-buffer
        (org-mode)
        (buffer-enable-undo)
        (insert "* Second\n")
        (let ((second (current-buffer)))
          (org-timegrid-org--transaction
           (lambda ()
             (dolist (buffer (list first second))
               (with-current-buffer buffer
                 (org-timegrid-org--add-range (copy-marker 1)
                                              1065422040 1065422070)))))
          ;; Make the final source invalid: an early mutation would otherwise
          ;; partially undo the multi-buffer transaction before noticing it.
          (with-current-buffer (caar (last (car org-timegrid-org--undo-transactions)))
            (goto-char (point-max))
            (insert "Manual source edit\n"))
          (let ((before (mapcar (lambda (buffer)
                                  (with-current-buffer buffer (buffer-string)))
                                (list first second))))
            (should-error (org-timegrid-org--undo nil nil) :type 'user-error)
            (should (equal before
                           (mapcar (lambda (buffer)
                                     (with-current-buffer buffer (buffer-string)))
                                   (list first second))))))))))

(ert-deftest org-timegrid-history-rolls-back-failed-bulk-edits ()
  (org-timegrid-history-test--with-entry
    (let ((before (buffer-string)))
      (should-error
       (org-timegrid-org--transaction
        (lambda ()
          (org-timegrid-org--add-range (copy-marker 1) 1065422040 1065422070)
          (org-timegrid-org--add-range (copy-marker 1) 1065422100 1065422130)
          (error "Failed bulk edit"))))
      (should (equal before (buffer-string)))
      (should-not org-timegrid-org--undo-transactions))))

(ert-deftest org-timegrid-history-old-fixed-repeaters-skip-to-query ()
  (dolist (unit '(hour day week))
    (let* ((step (pcase unit ('hour 60) ('day 1440) ('week 10080)))
           (event (org-timegrid-event-create
                   :id 'old :title "Old repeater" :start 1000000 :end 1000030
                   :metadata (list :repeater-value 1 :repeater-unit unit)))
           (start (+ 1000000 (* step 150000)))
           (events (org-timegrid-org--expand-event event start (+ start (* 3 step)))))
      (should (equal (mapcar #'org-timegrid-event-start events)
                     (list start (+ start step) (+ start (* 2 step))))))))

(ert-deftest org-timegrid-history-skipping-keeps-overlapping-occurrences ()
  (let* ((event (org-timegrid-event-create
                 :id 'overlap :title "Long repeater" :start 1000000 :end 1000180
                 :metadata '(:repeater-value 1 :repeater-unit hour)))
         (start (+ 1000000 (* 60 150000)))
         (events (org-timegrid-org--expand-event event start (+ start 120))))
    (should (equal (mapcar #'org-timegrid-event-start events)
                   (list (- start 120) (- start 60) start (+ start 60))))))
