;;; org-timegrid-update-test.el --- Shared update behavior -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-timegrid)
(require 'org-timegrid-test-support
         (expand-file-name "org-timegrid-test-support.el"
                           (file-name-directory load-file-name)))

(defmacro org-timegrid-update-test--calendar (&rest body)
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let* ((event (org-timegrid-event-create :id 'one :title "Task"
                                              :start 144600 :end 144645))
            (block (car (org-timegrid-events-to-blocks (list event) 100)))
            (org-timegrid--state
             (org-timegrid--calendar-state-create
              :week-start 100 :events (list event) :blocks (list block)
              :cursor (org-timegrid--cursor-state-create :surface 'grid :day 0 :minute 600)
              :cursor-visible t :selected-id 'one))
            (org-timegrid--backend
             (org-timegrid-backend-create :name "Dummy" :update-function #'ignore))
            (org-timegrid--static-inner "background")
            (grid 0) (header 0) (full 0) (present 0) (prepared 0))
       (cl-letf (((symbol-function 'org-timegrid--render-dynamic) (lambda () (cl-incf grid)))
                 ((symbol-function 'org-timegrid--render-header-dynamic) (lambda () (cl-incf header)))
                 ((symbol-function 'org-timegrid--refresh) (lambda (&rest _) (cl-incf full)))
                 ((symbol-function 'redisplay) (lambda (&rest _) (cl-incf present)))
                 ((symbol-function 'org-timegrid--schedule-preview-preparation)
                  (lambda (&rest _) (cl-incf prepared)))
                 ((symbol-function 'org-timegrid--schedule-prewarm) #'ignore)
                 ((symbol-function 'org-timegrid--scroll-cursor-into-view) #'ignore))
         ,@body))))

(ert-deftest org-timegrid-update-nested-and-unchanged ()
  "Nested mutations paint and schedule preparation once; repeated state does neither."
  (org-timegrid-update-test--calendar
    (let ((proposal (org-timegrid--edit-proposal block 15 0 nil)))
      (org-timegrid--update
       (lambda ()
         (org-timegrid--set-cursor 0 615)
         (org-timegrid--set-preview proposal)
         (should (= grid 0))))
      (should (= grid 1))
      (should (= prepared 1))
      (should (= present 1))
      (should (eq proposal (org-timegrid--calendar-state-preview org-timegrid--state)))
      (org-timegrid--set-preview proposal)
      (should (= grid 1))
      (should (= prepared 1)))))

(ert-deftest org-timegrid-update-rail-routing ()
  "Rail transitions and previews are reconciled through the same renderer."
  (org-timegrid-update-test--calendar
    (org-timegrid--update (lambda () (org-timegrid--set-all-day-cursor 0 0)))
    (should (= grid 1))
    (should (= header 1))
    (org-timegrid--update (lambda () (org-timegrid--set-all-day-cursor 1 0)))
    (should (= grid 2))
    (should (= header 2))
    (let* ((all-day (org-timegrid--make-block 'rail 1 0 1440 "Rail" nil nil 'all-day))
           (first (org-timegrid--edit-proposal all-day 0 0 nil))
           (second (org-timegrid--edit-proposal all-day 0 1 nil)))
      (org-timegrid--set-preview first)
      (should (= grid 3))
      (org-timegrid--set-preview second)
      (should (= grid 4))
      (org-timegrid--clear-preview)
      (should (= grid 5)))))

(ert-deftest org-timegrid-update-viewport-and-cursor-following ()
  "Viewport requests preserve, reset, or align the view while batching changes."
  (org-timegrid-update-test--calendar
    (let ((followed 0) views)
      (cl-letf (((symbol-function 'org-timegrid--refresh)
                 (lambda (&rest args) (push args views)))
                ((symbol-function 'org-timegrid--scroll-cursor-into-view)
                 (lambda () (cl-incf followed))))
        (dolist (view '(preserve reset (540 . top)))
          (org-timegrid--with-update view
            (org-timegrid--set-cursor
             0 (+ 15 (org-timegrid--cursor-state-minute (org-timegrid--cursor))))
            (org-timegrid--set-preview (org-timegrid--edit-proposal block 15 0 nil))))
        (should (equal (nreverse views) '((t nil nil) (nil nil nil) (nil 540 top))))
        (should (= followed 1))
        (should (= prepared 3))
        (should (= grid 0))))))

(ert-deftest org-timegrid-update-keyboard-preview-and-commit ()
  "Keyboard nudges publish previews without writes, then commit and follow once."
  (org-timegrid-update-test--calendar
    (let ((writes 0))
      (setf (org-timegrid-backend-update-function org-timegrid--backend)
            (lambda (&rest _) (cl-incf writes)))
      (cl-letf (((symbol-function 'org-timegrid--schedule-keyboard-commit) #'ignore))
        (org-timegrid--edit-selected 15 0 nil)
        (org-timegrid--edit-selected 15 0 nil))
      (should (= writes 0))
      (should (= grid 2))
      (should (= 630 (org-timegrid-block-start
                      (org-timegrid--operation-block
                       (org-timegrid--calendar-state-preview org-timegrid--state)))))
      (org-timegrid--commit-keyboard-edit)
      (should (= writes 1))
      (should (= full 1))
      (should (= grid 2))
      (should-not (org-timegrid--calendar-state-preview org-timegrid--state))
      (should (= 630 (org-timegrid--cursor-state-minute (org-timegrid--cursor)))))))

(ert-deftest org-timegrid-update-error-and-buffer-switch ()
  "A changed model reconciles in its owner buffer, including during unwinding."
  (org-timegrid-update-test--calendar
    (should-error
     (org-timegrid--update
      (lambda ()
        (org-timegrid--set-cursor 0 615)
        (user-error "Stop"))) :type 'user-error)
    (should (= grid 1))
    (let ((owner (current-buffer)))
      (with-temp-buffer
        (let ((other (current-buffer)))
          (with-current-buffer owner
            (org-timegrid--update
             (lambda ()
               (org-timegrid--set-cursor 0 630)
               (set-buffer other)))))))
    (should (= grid 2))))

(ert-deftest org-timegrid-update-unchanged-scene-skips-svg ()
  "Reconciliation can visit an unchanged grid without creating SVG or images."
  (with-temp-buffer
    (let* ((org-timegrid--state
            (org-timegrid--calendar-state-create
             :week-start 100 :cursor-visible t
             :cursor (org-timegrid--cursor-state-create :surface 'rail :day 0 :lane 0)))
           (org-timegrid--scene (org-timegrid--build-scene)))
      (cl-letf (((symbol-function 'org-timegrid--scene-patch)
                 (lambda (&rest _) (ert-fail "Unchanged grid generated SVG"))))
        (org-timegrid--render-dynamic)))))

(ert-deftest org-timegrid-update-open-reuses-current-state ()
  "Opening commits initial state once and reuses a compatible existing calendar."
  (let* ((queries 0) (paints 0)
         (backend (org-timegrid-backend-create
                   :name "Dummy" :list-function (lambda (&rest _) (cl-incf queries) nil))))
    (save-window-excursion
      (org-timegrid-test--with-isolated-calendar
        (cl-letf (((symbol-function 'org-timegrid--refresh)
                   (lambda (&rest _)
                     (should (org-timegrid--calendar-state-p org-timegrid--state))
                     (setq org-timegrid--last-width (org-timegrid--window-width))
                     (cl-incf paints))))
          (org-timegrid-open backend 100)
          (org-timegrid-open backend 100)
          (should (= queries 1))
          (should (= paints 1))
          (org-timegrid-open backend 200)
          (should (= queries 2))
          (should (= paints 2)))))))

(ert-deftest org-timegrid-update-tests-preserve-existing-calendar-on-error ()
  "Test cleanup restores an existing calendar even when a test fails."
  (org-timegrid-test--with-isolated-calendar
    (let ((existing (get-buffer-create "*Org Time Grid*")))
      (with-current-buffer existing (insert "Existing calendar"))
      (should-error
       (org-timegrid-test--with-isolated-calendar
         (get-buffer-create "*Org Time Grid*")
         (error "Test failure")))
      (should (eq existing (get-buffer "*Org Time Grid*")))
      (should (equal "Existing calendar" (with-current-buffer existing (buffer-string)))))))

(ert-deftest org-timegrid-update-nested-clock-keeps-model-and-viewport ()
  "A timer during an update cannot replace a pending model or viewport change."
  (org-timegrid-update-test--calendar
    (let ((clocks 0))
      (cl-letf (((symbol-function 'org-timegrid--render-clock) (lambda () (cl-incf clocks))))
        (org-timegrid--with-update nil
          (org-timegrid--set-cursor 0 615)
          (org-timegrid--update #'ignore 'clock))
        (should (= clocks 1))
        (should (= grid 1))
        (org-timegrid--update
         (lambda ()
           (org-timegrid--set-cursor 0 630)
           (org-timegrid--update #'ignore 'clock)) 'reset)
        (should (= clocks 1))
        (should (= full 1))))))

(ert-deftest org-timegrid-update-poll-keeps-unchanged-views ()
  "Polling retains warm views until events or their render context change."
  (org-timegrid-update-test--calendar
    (setq-local major-mode 'org-timegrid-mode)
    (let ((events (list (copy-org-timegrid-event event))) views)
      (setf (org-timegrid-backend-list-function org-timegrid--backend)
            (lambda (&rest _) events))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window))))
        (setq views (list (org-timegrid--cached-view-create :key (org-timegrid--view-key t)))
              org-timegrid--view-cache views)
        (org-timegrid--data-tick (current-buffer))
        (should (eq views org-timegrid--view-cache))
        (should (= full 0))
        ;; Changed appearance/date context still needs a redraw with identical events.
        (setq org-timegrid--view-cache-context nil)
        (org-timegrid--data-tick (current-buffer))
        (should (= full 1))
        (setq events (list (org-timegrid-event-create
                           :id 'replacement :title "New task" :start 144660 :end 144720)))
        (org-timegrid--data-tick (current-buffer))
        (should (= full 2))
        (should-not org-timegrid--view-cache)
        (should (equal '(replacement)
                       (mapcar #'org-timegrid-block-id
                               (org-timegrid--calendar-state-blocks org-timegrid--state))))
        (should-not (org-timegrid--selected-id))
        (should-not org-timegrid--stale)))))

(ert-deftest org-timegrid-update-show-reloads-stale-data ()
  "Showing or finishing an edit reloads deferred data before repainting."
  (dolist (trigger '(show resize edit))
    (org-timegrid-update-test--calendar
      (setq-local major-mode 'org-timegrid-mode org-timegrid--stale t)
      (let ((events (list (org-timegrid-event-create
                           :id 'new :title "Updated while hidden" :start 144660 :end 144720)))
            deferred)
        (setf (org-timegrid-backend-list-function org-timegrid--backend)
              (lambda (&rest _) events))
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (setq org-timegrid--last-width (window-body-width nil t)
                org-timegrid--last-zoom-factor (org-timegrid--zoom-factor))
          (when (eq trigger 'edit)
            (setf (org-timegrid--calendar-state-preview org-timegrid--state)
                  (org-timegrid--edit-proposal block 15 0 nil)))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_delay _repeat function &rest _) (setq deferred function))))
            (pcase trigger
              ('show (org-timegrid--restore-frame-calendars (selected-frame)))
              ('resize (org-timegrid--window-resized (selected-window)))
              ('edit (org-timegrid--clear-preview))))
          (should deferred)
          (should org-timegrid--stale)
          (funcall deferred)
          (should-not org-timegrid--stale)
          (should (equal '(new)
                         (mapcar #'org-timegrid-event-id
                                 (org-timegrid--calendar-state-events org-timegrid--state))))
          (should (= full 1)))))))

;;; org-timegrid-update-test.el ends here
