;;; org-timegrid-diary-test.el --- Diary entry tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)

(defmacro org-timegrid-diary--with-source (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (org-mode)
     (buffer-enable-undo)
     (let ((org-timegrid-org-auto-save nil)
           (org-timegrid-org-show-repeaters t)
           (org-timegrid-org-show-diary t)
           (org-timegrid-org-show-done t)
           (org-timegrid-org-exclude-tags nil)
           (org-timegrid-org-filter-function #'org-timegrid-org-default-filter)
           (org-timegrid-query-options '(:cache-range nil))
           (org-timegrid-org--undo-transactions nil)
           (org-timegrid-org--redo-transactions nil)
           (org-timegrid-org--undo-direction nil)
           (start (* 1440 (calendar-absolute-from-gregorian '(11 1 2026))))
           (end (* 1440 (calendar-absolute-from-gregorian '(12 1 2026)))))
       ,@body)))

(ert-deftest org-timegrid-diary-resolves-timed-and-all-day-occurrences ()
  (org-timegrid-diary--with-source
    (insert "* Monthly touchbase :work:\n<%%(diary-float t 1 3) 14:00-15:00>\n"
            "* Last Friday\n<%%(diary-float t 5 -1)>\n"
            "* Single time\n<%%(diary-float t 1 3) 09:00>\n")
    (let* ((events (org-timegrid-org--buffer-events nil start end))
           (meeting (seq-find (lambda (event)
                                (equal (org-timegrid-event-title event) "Monthly touchbase"))
                              events))
           (all-day (seq-find #'org-timegrid-event-all-day events))
           (single (seq-find (lambda (event)
                               (equal (org-timegrid-event-title event) "Single time")) events)))
      (should (= 3 (length events)))
      (should (= (org-timegrid-event-start meeting) (+ start (* 15 1440) (* 14 60))))
      (should (= 60 (- (org-timegrid-event-end meeting) (org-timegrid-event-start meeting))))
      (should (equal '("work") (org-timegrid-event-tags meeting)))
      (should (= (org-timegrid-event-start all-day) (+ start (* 26 1440))))
      (should (= 1440 (- (org-timegrid-event-end all-day) (org-timegrid-event-start all-day))))
      (should (= org-timegrid-default-duration-minutes
                 (- (org-timegrid-event-end single) (org-timegrid-event-start single))))
      (should (= 3 (length (delete-dups (mapcar #'org-timegrid-event-id events)))))
      (dolist (event events)
        (should (plist-get (org-timegrid-event-metadata event) :diary))
        (should (eq #'org-timegrid--draw-diary (org-timegrid--event-icon event)))))))

(ert-deftest org-timegrid-diary-standalone-generates-titles-times-and-multiple-events ()
  (org-timegrid-diary--with-source
    (insert "* Generated\n"
            "%%(when (diary-float t 1 3) '(\"9am-10am First\" \"14:00 Second\" \"Holiday\"))\n"
            "* Literal diary text\n%%(diary-float t 1 3) 11:00-12:00 Team meeting\n")
    (let* ((events (org-timegrid-org--buffer-events nil start end))
           (first (seq-find (lambda (event) (equal (org-timegrid-event-title event) "9am-10am First")) events)))
      (should (= 4 (length events)))
      (should (= (org-timegrid-event-start first) (+ start (* 15 1440) (* 9 60))))
      (should (= 60 (- (org-timegrid-event-end first) (org-timegrid-event-start first))))
      (should (= 1 (length (seq-filter #'org-timegrid-event-all-day events))))
      (should (= 4 (length (delete-dups (mapcar #'org-timegrid-event-id events)))))
      (dolist (event events)
        (should-error (org-timegrid-org--update-event-range
                       event (org-timegrid-event-start event) (org-timegrid-event-end event))
                      :type 'user-error)))))

(ert-deftest org-timegrid-diary-cache-reuses-range-and-force-reevaluates ()
  (org-timegrid-diary--with-source
    (insert "* Monthly\n<%%(diary-float t 1 3) 14:00-15:00>\n")
    (let ((evaluate (symbol-function 'org-diary-sexp-entry)) (calls 0))
      (cl-letf (((symbol-function 'org-diary-sexp-entry)
                 (lambda (&rest args) (cl-incf calls) (apply evaluate args))))
        (should (= 1 (length (org-timegrid-org--cached-events "diary.org" start end))))
        (let* ((initial calls)
               (day (+ start (* 15 1440))))
          (should (= 1 (length (org-timegrid-org--cached-events "diary.org" day (+ day 1440)))))
          (should (= initial calls))
          (let ((org-timegrid-query-options '(:force t)))
            (org-timegrid-org--cached-events "diary.org" start end))
          (should (> calls initial)))))))

(ert-deftest org-timegrid-diary-and-repeaters-toggle-independently-through-cache ()
  (org-timegrid-diary--with-source
    (insert "* Diary timestamp\n<%%(diary-float t 1 3) 14:00-15:00>\n"
            "* Generated diary\n%%(diary-float t 1 3) 09:00 Meeting\n"
            "* Repeater\n<2026-11-16 Mon 10:00-11:00 +1w>\n"
            "* Regular\n<2026-11-16 Mon 11:00-12:00>\n")
    (let ((day (+ start (* 15 1440))))
      (dolist (settings '((t t 4) (t nil 2) (nil t 3) (nil nil 1) (t t 4)))
        (let ((org-timegrid-org-show-repeaters (nth 0 settings))
              (org-timegrid-org-show-diary (nth 1 settings)))
          (should (= (nth 2 settings)
                     (length (org-timegrid-org--cached-events
                              "diary.org" day (+ day 1440))))))))))

(ert-deftest org-timegrid-diary-is-view-only-in-previews-and-backend-mutations ()
  (org-timegrid-diary--with-source
    (insert "* Timed\n<%%(diary-float t 1 3) 14:00-15:00>\n"
            "* Untimed\n<%%(diary-float t 5 -1)>\n"
            "* Generated\n%%(when (diary-float t 1 3) \"10:00-11:00 Meeting\")\n")
    (let ((before (buffer-string))
          (events (org-timegrid-org--buffer-events nil start end))
          (org-timegrid--backend org-timegrid-org-backend))
      (should (= 3 (length events)))
      (dolist (event events)
        (let* ((a (org-timegrid-event-start event))
               (b (org-timegrid-event-end event))
               (block (car (org-timegrid-events-to-blocks (list event) (floor a 1440))))
               (error-data (should-error (org-timegrid--prepare-block-edit block)
                                         :type 'user-error)))
          (should (string-match-p "Diary entries are view only" (cadr error-data)))
          (should-error (org-timegrid-org--update-event-range event (+ a 15) (+ b 15))
                        :type 'user-error)
          (should-error (org-timegrid-org--update-event-range event a (+ b 15))
                        :type 'user-error)
          (should-error (org-timegrid-org--update-event-range event a b "Rename")
                        :type 'user-error)
          (should-error (org-timegrid-org--create-event "Copy" a b event)
                        :type 'user-error)
          (should-error (org-timegrid-org--remove-event event) :type 'user-error)
          (should-error (org-timegrid-org--remove-entry event) :type 'user-error)
          (unless (org-timegrid-event-all-day event)
            (should-error (org-timegrid--push-context block) :type 'user-error))))
      (should (equal before (buffer-string))))))

(ert-deftest org-timegrid-diary-drag-snaps-back-and-warns-after-redraw ()
  (org-timegrid-diary--with-source
    (insert "* Meeting\n<%%(diary-float t 1 3) 14:00-15:00>\n")
    (let* ((before (buffer-string))
           (event (car (org-timegrid-org--buffer-events nil start end)))
           (week (floor (org-timegrid-event-start event) 1440))
           (block (car (org-timegrid-events-to-blocks (list event) week)))
           (org-timegrid--backend org-timegrid-org-backend)
           (org-timegrid--state (org-timegrid--calendar-state-create
                                :week-start week :events (list event) :blocks (list block)))
           (origin (list (selected-window) 1 '(0 . 0) 0))
           (motion (list (selected-window) 1 '(0 . 15) 0))
           (set-preview (symbol-function 'org-timegrid--set-preview)))
      (dolist (edge '(nil top bottom))
        (let ((inputs (list (list 'mouse-movement motion)
                            (list 'drag-mouse-1 origin motion)))
              previewed redrawn warning)
          (cl-letf (((symbol-function 'org-timegrid--reconcile) #'ignore)
                    ((symbol-function 'org-timegrid--all-day-layout) #'ignore)
                    ((symbol-function 'org-timegrid--latest-motion-event) #'identity)
                    ((symbol-function 'read-event) (lambda (&rest _) (pop inputs)))
                    ((symbol-function 'org-timegrid--set-preview)
                     (lambda (proposal)
                       (when proposal (setq previewed t))
                       (funcall set-preview proposal)))
                    ((symbol-function 'redisplay) (lambda (&rest _) (setq redrawn t)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (should redrawn)
                       (should-not (org-timegrid--calendar-state-preview org-timegrid--state))
                       (should-not (org-timegrid--calendar-state-gesture org-timegrid--state))
                       (setq warning (apply #'format format-string args)))))
            (org-timegrid--track-drag-gesture
             (list 'down-mouse-1 origin) #'posn-x-y
             (lambda (_) (list :block-id (org-timegrid-block-id block)))
             (lambda (_from _to) (org-timegrid--edit-proposal block 15 0 edge))
             #'ignore))
          (should previewed)
          (should (string-match-p "Diary entries are view only" warning))
          (should (equal (org-timegrid--block-absolute-range block)
                         (cons (org-timegrid-event-start event) (org-timegrid-event-end event))))))
      (should (equal before (buffer-string))))))

(ert-deftest org-timegrid-diary-filter-and-bad-expression-do-not-hide-other-events ()
  (org-timegrid-diary--with-source
    (insert "* Bad\n<%%(error \"broken\") 14:00-15:00>\n"
            "* Meeting :hidden:\n<%%(diary-float t 1 3) 14:00-15:00>\n"
            "* Regular\n<2026-11-16 Mon 10:00-11:00>\n")
    (should (= 2 (length (org-timegrid-org--buffer-events nil start end))))
    (let ((org-timegrid-org-show-diary nil))
      (should (= 1 (length (org-timegrid-org--buffer-events nil start end)))))
    (let ((org-timegrid-org-exclude-tags '("hidden")))
      (should (= 1 (length (org-timegrid-org--buffer-events nil start end)))))))

(ert-deftest org-timegrid-diary-overnight-intersects-next-day-query ()
  (org-timegrid-diary--with-source
    (insert "* Night shift\n<%%(diary-float t 1 3) 23:00-01:00>\n")
    (let* ((day (+ start (* 16 1440)))
           (events (org-timegrid-org--buffer-events nil day (+ day 1440))))
      (should (= 1 (length events)))
      (should (= (- day 60) (org-timegrid-event-start (car events))))
      (should (= (+ day 60) (org-timegrid-event-end (car events)))))))

(provide 'org-timegrid-diary-test)
;;; org-timegrid-diary-test.el ends here
