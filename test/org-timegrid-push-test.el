;;; org-timegrid-push-test.el --- Push gestures -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-test-support
         (expand-file-name "org-timegrid-test-support.el"
                           (file-name-directory load-file-name)))
(require 'org-timegrid-org)

(defmacro org-timegrid-push-test--with-events (specs &rest body)
  "Run BODY with SPECS as tasks, measured in minutes relative to day 100."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (let* ((events (mapcar (lambda (spec)
                             (org-timegrid-event-create
                              :id (nth 0 spec) :title (symbol-name (nth 0 spec))
                              :start (+ 144000 (nth 1 spec))
                              :end (+ 144000 (nth 2 spec))
                              :metadata (nth 3 spec) :all-day (nth 4 spec)))
                           ,specs))
            (visible (seq-filter (lambda (event)
                                   (and (< (org-timegrid-event-start event)
                                           (* (+ 100 org-timegrid-days) 1440))
                                        (> (org-timegrid-event-end event) 144000)))
                                 events))
            (org-timegrid--backend
             (org-timegrid-backend-create :list-function (lambda (&rest _) events)
                                          :update-function #'ignore))
            (org-timegrid--state
             (org-timegrid--calendar-state-create
              :week-start 100 :events visible :selected-id 'a :cursor-visible t
              :blocks (org-timegrid-events-to-blocks visible 100)))
            (context (org-timegrid--push-context (org-timegrid--block 'a))))
       (cl-letf (((symbol-function 'org-timegrid--reconcile) #'ignore))
         ,@body))))

(defun org-timegrid-push-test--ranges (proposal)
  "Return sorted (ID START END) relative ranges from PROPOSAL."
  (sort (mapcar (lambda (block)
                  (let ((range (org-timegrid--block-absolute-range block)))
                    (list (org-timegrid-block-id block)
                          (- (car range) 144000) (- (cdr range) 144000))))
                (org-timegrid--operation-blocks proposal))
        (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b))))))

(ert-deftest org-timegrid-push-gaps-and-reversing ()
  (org-timegrid-push-test--with-events '((a 60 90) (b 105 135) (c 150 180))
    (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context 15))
                   '((a 75 105))))
    (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context 45))
                   '((a 105 135) (b 135 165) (c 165 195))))
    (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context 0))
                   '((a 60 90))))
    (should (= (org-timegrid-event-start (car events)) 144060))))

(ert-deftest org-timegrid-push-stays-within-visible-dates-without-queries ()
  (let ((org-timegrid-days 1))
    (org-timegrid-push-test--with-events '((a 60 90) (b 90 120) (c 1440 1470))
      (setf (org-timegrid-backend-list-function org-timegrid--backend)
            (lambda (&rest _) (ert-fail "Push queried beyond the visible snapshot")))
      (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context 1440))
                     '((a 1380 1410) (b 1410 1440)))))))

(ert-deftest org-timegrid-push-backward-across-visible-days ()
  (org-timegrid-push-test--with-events '((a 1470 1500) (b 1440 1470) (c 1395 1425))
    (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context -45))
                   '((a 1425 1455) (b 1395 1425) (c 1365 1395))))))

(ert-deftest org-timegrid-push-clamps-at-start-and-partial-overlap-groups ()
  (let ((org-timegrid-days 1))
    (org-timegrid-push-test--with-events '((a 60 90) (b 15 45) (offscreen -45 -15))
      (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context -90))
                     '((a 30 60) (b 0 30)))))
    (org-timegrid-push-test--with-events '((a 1320 1350) (b 1380 1470) (c 1410 1440))
      (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context 120))
                     '((a 1350 1380)))))))

(ert-deftest org-timegrid-push-excludes-original-overlaps-transitively ()
  (org-timegrid-push-test--with-events '((a 60 90) (long 0 300) (b 90 120)
                                       (c 110 150) (d 140 180) (e 200 230))
    ;; The long excluded task overlaps every downstream task. It must not join.
    (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context 30))
                   '((a 90 120) (b 120 150) (c 140 180) (d 170 210) (e 210 240))))))

(ert-deftest org-timegrid-push-crosses-visible-days-with-overlap-groups ()
  (let ((org-timegrid-days 3))
    (org-timegrid-push-test--with-events '((a 1380 1440) (b 1440 2880)
                                         (c 2800 2920) (d 2920 2950))
      (let ((proposal (org-timegrid--push-proposal context 30)))
        (should (equal (org-timegrid-push-test--ranges proposal)
                       '((a 1410 1470) (b 1470 2910) (c 2830 2950) (d 2950 2980))))
        (setf (org-timegrid--calendar-state-preview org-timegrid--state) proposal)
        (should (seq-every-p #'org-timegrid-block-preview
                            (org-timegrid--effective-blocks)))))))

(ert-deftest org-timegrid-push-repeaters-and-all-day-allow-overlap ()
  (org-timegrid-push-test--with-events '((a 60 90) (repeat 90 180 (:repeater-type cumulate))
                                       (date 0 1440 nil t) (b 120 150))
    (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context 60))
                   '((a 120 150) (b 150 180))))))

(ert-deftest org-timegrid-push-preview-moves-and-highlights-whole-stack ()
  (org-timegrid-push-test--with-events '((a 60 90) (b 90 120) (c 110 140) (long 0 300))
    (let* ((proposal (org-timegrid--push-proposal context 30))
           (palette (org-timegrid--palette)))
      (setf (org-timegrid--calendar-state-preview org-timegrid--state) proposal)
      (should (equal (org-timegrid-push-test--ranges
                      (org-timegrid--operation-create :blocks (org-timegrid--effective-blocks)))
                     '((a 90 120) (b 120 150) (c 140 170) (long 0 300))))
      (dolist (block (org-timegrid--operation-blocks proposal))
        (should (equal (org-timegrid--color block palette) (plist-get palette :preview-fill))))
      (org-timegrid--clear-preview)
      (should (equal (org-timegrid-push-test--ranges
                      (org-timegrid--operation-create :blocks (org-timegrid--effective-blocks)))
                     '((a 60 90) (b 90 120) (c 110 140) (long 0 300)))))))

(ert-deftest org-timegrid-push-clock-barrier-clamps-movement ()
  (org-timegrid-push-test--with-events '((a 60 90) (b 90 120) (clock 150 180 (:clock t)))
    (should (equal (org-timegrid-push-test--ranges (org-timegrid--push-proposal context 90))
                   '((a 90 120) (b 120 150))))))

(ert-deftest org-timegrid-push-keyboard-retains-exclusions-and-cancels ()
  (org-timegrid-push-test--with-events '((a 60 90) (long 0 300) (b 105 135))
    (cl-letf (((symbol-function 'org-timegrid--schedule-keyboard-commit) #'ignore))
      (org-timegrid-push-later)
      (org-timegrid-push-later)
      (should (equal (org-timegrid-push-test--ranges org-timegrid--keyboard-edit)
                     '((a 90 120) (b 120 150))))
      (org-timegrid-push-earlier)
      (should (equal (org-timegrid-push-test--ranges org-timegrid--keyboard-edit)
                     '((a 75 105))))
      (let ((this-command 'org-timegrid-dismiss))
        (org-timegrid--commit-before-unrelated-command))
      (org-timegrid-dismiss)
      (should-not org-timegrid--keyboard-edit)
      (should-not (org-timegrid--calendar-state-preview org-timegrid--state)))))

(ert-deftest org-timegrid-push-org-commit-undo-and-rollback ()
  (with-temp-buffer
    (org-mode)
    (insert "* A\n<2026-11-12 Thu 10:00-11:00>\n* B\n<2026-11-12 Thu 11:00-12:00>\n")
    (buffer-enable-undo)
    (let* ((source (current-buffer)) (before (buffer-string)) after
           (org-timegrid-org-auto-save nil)
           (org-timegrid-org--undo-transactions nil)
           (org-timegrid-org--redo-transactions nil)
           (org-timegrid-org--undo-direction nil)
           (events (org-timegrid-org--buffer-events "push.org"))
           (week (floor (org-timegrid-event-start (car events)) 1440))
           (org-timegrid--backend
            (org-timegrid-backend-create
             :list-function (lambda (&rest _) events)
             :update-function #'org-timegrid-org--update-event-range
             :transaction-function #'org-timegrid-org--transaction))
           (org-timegrid--state
            (org-timegrid--calendar-state-create
             :week-start week :events events
             :blocks (org-timegrid-events-to-blocks events week)))
           (context (org-timegrid--push-context (car (org-timegrid--calendar-state-blocks
                                                     org-timegrid--state))))
           (proposal (org-timegrid--push-proposal context 30)))
      (cl-letf (((symbol-function 'org-timegrid--refresh-data) #'ignore)
                ((symbol-function 'org-timegrid--reconcile) #'ignore))
        (org-timegrid--apply proposal)
        (setq after (buffer-string))
        (should (equal (mapcar (lambda (event)
                                 (cons (org-timegrid-event-start event)
                                       (org-timegrid-event-end event)))
                               (org-timegrid-org--buffer-events "push.org"))
                       (mapcar #'org-timegrid--block-absolute-range
                               (org-timegrid--operation-blocks proposal))))
        (should (= 1 (length org-timegrid-org--undo-transactions)))
        (org-timegrid-org--undo nil nil)
        (should (equal before (buffer-string)))
        (org-timegrid-org--undo t t)
        (should (equal after (buffer-string)))
        (org-timegrid-org--undo nil nil)
        ;; Refresh snapshots after undo, then fail the second write.
        (setq events (org-timegrid-org--buffer-events "push.org"))
        (setf (org-timegrid--calendar-state-events org-timegrid--state) events)
        (setq context (org-timegrid--push-context (org-timegrid-event-to-block (car events) week)))
        (let ((writes 0)
              (update (symbol-function 'org-timegrid-org--update-event-range)))
          (setf (org-timegrid-backend-update-function org-timegrid--backend)
                (lambda (&rest args)
                  (if (= (cl-incf writes) 2) (user-error "Read-only task")
                    (apply update args))))
          (should-error (org-timegrid--apply (org-timegrid--push-proposal context 30)))
          (should (equal before (with-current-buffer source (buffer-string)))))))))

(ert-deftest org-timegrid-push-mouse-release-and-cancellation ()
  (dolist (cancel '(nil t))
    (org-timegrid-push-test--with-events '((a 60 90) (b 90 120))
      (let* ((origin (list (selected-window) 1 '(0 . 0) 0))
             (motion (list (selected-window) 1 '(0 . 15) 0))
             (release (list (selected-window) 1 '(0 . 30) 0))
             (inputs (list (list 'mouse-movement motion)
                           (if cancel ?\C-g
                             (list 'M-drag-mouse-1 origin release))))
             (unread-command-events nil) applied)
        (cl-letf (((symbol-function 'org-timegrid--target)
                   (lambda (position) (org-timegrid--mouse-target position)))
                  ((symbol-function 'org-timegrid--mouse-target)
                   (lambda (position)
                     (list :surface 'grid :block-id 'a :day 0 :edge 'top
                           :minute (+ 60 (cdr (posn-x-y position))))))
                  ((symbol-function 'org-timegrid--mouse-position-xy) #'posn-x-y)
                  ((symbol-function 'read-event) (lambda (&rest _) (pop inputs)))
                  ((symbol-function 'input-pending-p) (lambda () nil))
                  ((symbol-function 'org-timegrid--apply) (lambda (p) (setq applied p))))
          (org-timegrid-press (list 'M-down-mouse-1 origin)))
        (if cancel
            (progn (should-not applied) (should (equal unread-command-events '(7))))
          ;; Release position wins, and grabbing an edge still moves whole tasks.
          (should (equal (org-timegrid-push-test--ranges applied)
                         '((a 90 120) (b 120 150)))))
        (should-not (org-timegrid--calendar-state-preview org-timegrid--state))))))

(ert-deftest org-timegrid-push-keyboard-stops-at-view-edge ()
  (let ((org-timegrid-days 1))
    (org-timegrid-push-test--with-events '((a 1410 1440) (offscreen 1440 1470))
      (cl-letf (((symbol-function 'org-timegrid--schedule-keyboard-commit) #'ignore))
        (org-timegrid-push-later 4))
      (should (equal (org-timegrid-push-test--ranges org-timegrid--keyboard-edit)
                     '((a 1410 1440))))
      (org-timegrid--commit-keyboard-edit)
      (should (= (org-timegrid--calendar-state-week-start org-timegrid--state) 100))
      (should (eq (org-timegrid--selected-id) 'a))
      (should-not org-timegrid--keyboard-edit))))

(ert-deftest org-timegrid-keyboard-cancels-normal-moves-and-pushes ()
  (dolist (command '(org-timegrid-move-later org-timegrid-push-later))
    (org-timegrid-push-test--with-events '((a 60 90) (b 105 135))
      (cl-letf (((symbol-function 'org-timegrid--schedule-keyboard-commit) #'ignore)
                ((symbol-function 'org-timegrid--apply)
                 (lambda (&rest _) (ert-fail "Cancelled edit was committed"))))
        (funcall command)
        (let ((this-command 'org-timegrid-dismiss))
          (org-timegrid--commit-before-unrelated-command))
        (should-not org-timegrid--keyboard-edit)
        (should-not (org-timegrid--calendar-state-preview org-timegrid--state))))))

(provide 'org-timegrid-push-test)
