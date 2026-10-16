;;; org-timegrid-regression-test.el --- Edit and lifecycle regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)
(require 'org-timegrid-agenda)

(defvar touch-screen-current-tool)
(defvar touch-screen-current-timer)

(defmacro org-timegrid-regression--with-source (&rest body)
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (org-mode)
     (buffer-enable-undo)
     (insert "* Task\n")
     (undo-boundary)
     (let ((org-timegrid-org--undo-transactions nil)
           (org-timegrid-org--redo-transactions nil)
           (org-timegrid-org--undo-direction nil)
           (org-timegrid-org--transaction-edits nil)
           (org-timegrid-org-auto-save nil)
           (org-timegrid-org-filter-function #'org-timegrid-org-default-filter)
           (org-timegrid-org-exclude-tags nil)
           (org-timegrid-org-exclude-todo-states nil)
           (org-timegrid-org-exclude-properties nil)
           (org-timegrid-org-show-repeaters t)
           (org-timegrid-org-show-done t))
       ,@body)))

(ert-deftest org-timegrid-regression-no-op-does-not-add-undo ()
  (org-timegrid-regression--with-source
    (org-timegrid-org--add-range (copy-marker 1) 1065422040 1065422070)
    (org-timegrid-org--with-edit (current-buffer) (point))
    (should (= 1 (length org-timegrid-org--undo-transactions)))
    (org-timegrid-org--undo nil nil)
    (should (equal "* Task\n" (buffer-string)))))

(ert-deftest org-timegrid-regression-failed-edit-preserves-undo ()
  (org-timegrid-regression--with-source
    (org-timegrid-org--add-range (copy-marker 1) 1065422040 1065422070)
    (should-error
     (org-timegrid-org--with-edit (current-buffer)
       (insert "discard me")
       (error "Failed edit")))
    (org-timegrid-org--undo nil nil)
    (should (equal "* Task\n" (buffer-string)))))

(ert-deftest org-timegrid-regression-nested-transaction-rolls-back ()
  (org-timegrid-regression--with-source
    (should-error
     (org-timegrid-org--transaction
      (lambda ()
        (org-timegrid-org--add-range (copy-marker 1) 1065422040 1065422070)
        (org-timegrid-org--transaction
         (lambda ()
           (org-timegrid-org--add-range (copy-marker 1) 1065422100 1065422130)))
        (error "Failed outer transaction"))))
    (should (equal "* Task\n" (buffer-string)))
    (should-not org-timegrid-org--undo-transactions)))

(ert-deftest org-timegrid-regression-save-failure-keeps-edit-undoable ()
  (dolist (bulk '(nil t))
    (org-timegrid-regression--with-source
      (cl-letf (((symbol-function 'org-timegrid-org--save-buffer)
                 (lambda () (error "Cannot save"))))
               (should-error
                (let ((edit (lambda ()
                              (org-timegrid-org--add-range
                               (copy-marker 1) 1065422040 1065422070))))
                  (if bulk (org-timegrid-org--transaction edit) (funcall edit)))))
      (should (string-match-p "<" (buffer-string)))
      (org-timegrid-org--undo nil nil)
      (should (equal "* Task\n" (buffer-string))))))

(ert-deftest org-timegrid-regression-rollback-handles-read-only-and-no-undo ()
  (dolist (disable-undo '(nil t))
    (org-timegrid-regression--with-source
      (when disable-undo (buffer-disable-undo))
      (unwind-protect
          (progn
            (should-error
             (org-timegrid-org--transaction
              (lambda ()
                (org-timegrid-org--add-range (copy-marker 1) 1065422040 1065422070)
                (setq buffer-read-only t)
                (error "Failed transaction"))))
            (should (equal "* Task\n" (buffer-string))))
        (setq buffer-read-only nil)))))

(ert-deftest org-timegrid-regression-failed-transaction-refreshes-view ()
  (let ((org-timegrid--backend
         (org-timegrid-backend-create :transaction-function #'funcall))
        refreshed)
    (cl-letf (((symbol-function 'org-timegrid--refresh-data)
               (lambda () (setq refreshed t))))
             (should-error (org-timegrid--transaction (lambda () (error "Failed edit"))))
             (should refreshed))))

(ert-deftest org-timegrid-regression-isearch-weeks-independent-of-day-count ()
  (with-temp-buffer
    (make-local-variable 'org-timegrid-isearch--events)
    (let* ((org-timegrid-days 1)
           (org-timegrid-isearch-week-limit 2)
           (org-timegrid-isearch--events 'unqueried)
           (org-timegrid--state (org-timegrid--calendar-state-create :week-start 100))
           query
           (org-timegrid--backend
            (org-timegrid-backend-create
             :list-function (lambda (start end) (setq query (list start end)) nil))))
      (org-timegrid-isearch--events)
      (should (equal query (list (* 86 1440) (* 115 1440)))))))

(ert-deftest org-timegrid-regression-disabling-agenda-removes-strip ()
  (with-temp-buffer
    (org-agenda-mode)
    (let ((inhibit-read-only t)
          (org-timegrid-agenda-mode t))
      (insert (propertize "calendar\n" 'org-timegrid-strip t) "Agenda\n")
      (org-timegrid-agenda-mode -1)
      (should (equal "Agenda\n" (buffer-string))))))

(ert-deftest org-timegrid-regression-quit-clears-drag-preview ()
  (let ((org-timegrid--state (org-timegrid--calendar-state-create))
        cleared)
    (cl-letf (((symbol-function 'org-timegrid--all-day-layout) #'ignore)
              ((symbol-function 'read-event) (lambda (&rest _) (signal 'quit nil)))
              ((symbol-function 'org-timegrid--clear-preview)
               (lambda () (setq cleared t))))
             (condition-case nil
                 (org-timegrid--track-drag-gesture
                  '(down-mouse-1 nil) #'ignore #'ignore #'ignore #'ignore)
               (quit nil)))
    (should cleared)))

(ert-deftest org-timegrid-regression-template-values-are-literal ()
  (let* ((title "Keep %{start}, %{end}, %<%Y> and %? literally")
         (org-timegrid-org-capture-template
          '(:target file :template "* %{title}\n%{time-range}\n%?")))
    (with-temp-buffer
      (org-mode)
      (org-timegrid-org--insert-capture-template title 1065422040 1065422070)
      (goto-char (point-min))
      (should (equal (buffer-substring-no-properties (point) (line-end-position))
                     (concat "* " title))))
    (should (equal (org-timegrid--format-copy-item title 1065422040 1065422070)
                   (concat "10:00–10:30  " title)))))

(ert-deftest org-timegrid-regression-failed-cut-preserves-kill-ring ()
  (let ((kill-ring '("Keep me"))
        (event (org-timegrid-event-create :id 'event :title "Event" :start 100 :end 130))
        (org-timegrid--backend
         (org-timegrid-backend-create :delete-function (lambda (_) (error "Cannot cut")))))
    (cl-letf (((symbol-function 'org-timegrid--logical-selection)
               (lambda () (list :start 100 :end 130 :events (list event))))
              ((symbol-function 'org-timegrid--refresh-data) #'ignore))
             (should-error (org-timegrid-cut-selected))
             (should (equal kill-ring '("Keep me"))))))

(ert-deftest org-timegrid-regression-yank-pop-validates-before-undo ()
  (let ((kill-ring '("new" "plain text"))
        (org-timegrid--last-yank-origin 144000)
        (last-command 'org-timegrid-yank)
        undone)
    (cl-letf (((symbol-function 'org-timegrid--backend-undo)
               (lambda (_) (setq undone t)))
              ((symbol-function 'org-timegrid--reload-state) #'ignore)
              ((symbol-function 'org-timegrid--set-cursor) #'ignore)
              ((symbol-function 'org-timegrid--reveal-cursor) #'ignore))
             (let ((kill-ring-yank-pointer kill-ring))
               (should-error (org-timegrid-yank-pop) :type 'user-error)
               (should-not undone)
               (should (eq kill-ring kill-ring-yank-pointer))))))

(ert-deftest org-timegrid-regression-bulk-delete-repeater-occurrences ()
  (dolist (choice '("just this" "this and future" "all" "independent"))
    (org-timegrid-regression--with-source
      (insert "<2026-10-01 Thu 09:00-09:30 +1d>\n")
      (let* ((org-timegrid-org-repeater-history (not (equal choice "independent")))
             (org-timegrid--edit-context nil)
             (start (* 1440 (calendar-absolute-from-gregorian '(10 1 2026))))
             (end (+ start (* 5 1440)))
             (events (org-timegrid-org--expand-event
                      (car (org-timegrid-org--buffer-events "test.org")) start end))
             (before (buffer-string))
             (prompts 0))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (cl-incf prompts) choice)))
                 (org-timegrid-org--transaction
                  (lambda ()
                    (org-timegrid-org--remove-event (nth 1 events))
                    (org-timegrid-org--remove-event (nth 2 events)))))
        (let ((remaining (mapcan (lambda (event)
                                   (org-timegrid-org--expand-event event start end))
                                 (org-timegrid-org--buffer-events "test.org"))))
          (should (equal (mapcar (lambda (event)
                                   (floor (- (org-timegrid-event-start event) start) 1440))
                                 remaining)
                         (pcase choice ("just this" '(0 3 4))
                                ("this and future" '(0)) (_ nil)))))
        (should (= prompts (if (equal choice "independent") 0 1)))
        (org-timegrid-org--undo nil nil)
        (should (equal before (buffer-string)))))))

(ert-deftest org-timegrid-regression-rail-cursor-keeps-grid-scroll ()
  (let* ((org-timegrid--state
          (org-timegrid--calendar-state-create
           :cursor (org-timegrid--cursor-state-create :surface 'rail :day 0 :minute 0)))
         scrolled)
    (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window)))
              ((symbol-function 'org-timegrid--window-scroll-pixels) (lambda (_) 500))
              ((symbol-function 'org-timegrid--set-vscroll)
               (lambda (&rest _) (setq scrolled t))))
             (org-timegrid--scroll-cursor-into-view)
             (should-not scrolled))))

(ert-deftest org-timegrid-regression-carry-in-event-is-keyboard-reachable ()
  (let* ((block (org-timegrid--make-block 'overnight -1 1380 1500 "Overnight"))
         (org-timegrid--state
          (org-timegrid--calendar-state-create :week-start 100 :blocks (list block))))
    (should (equal (org-timegrid--ordered-blocks) (list block)))
    (cl-letf (((symbol-function 'org-timegrid--cursor-moved) #'ignore))
             (org-timegrid--goto-block block))
    (should (= 0 (org-timegrid--cursor-state-day (org-timegrid--cursor))))
    (should (= 0 (org-timegrid--cursor-state-minute (org-timegrid--cursor))))))

(ert-deftest org-timegrid-regression-retime-all-day-can-add-clock-time ()
  (let* ((block (org-timegrid--make-block 'event 0 0 1440 "Event" nil nil 'all-day))
         (org-timegrid--state (org-timegrid--calendar-state-create :week-start 100
                                                                   :blocks (list block)
                                                                   :cursor-visible t
                                                                   :selected-id 'event))
         kind
         (org-timegrid--backend
          (org-timegrid-backend-create
           :update-function (lambda (_event _start _end _title time-kind) (setq kind time-kind)))))
    (setf (org-timegrid-block-event block)
          (org-timegrid-event-create :id 'event :title "Event" :start 144000 :end 145440 :all-day t))
    (cl-letf (((symbol-function 'org-timegrid--read-timestamp) (lambda (&rest _) '(144600 . 30)))
              ((symbol-function 'org-timegrid--refresh-data) #'ignore))
             (org-timegrid-retime-selected)
             (should (eq kind 'timed)))))

(ert-deftest org-timegrid-regression-opening-after-backend-error-is-retryable ()
  (let ((org-timegrid-buffer-name (generate-new-buffer-name " *timegrid-open-test*"))
        (org-timegrid--backend nil))
    (unwind-protect
        (progn
          (should-error
           (org-timegrid-open
            (org-timegrid-backend-create :list-function (lambda (&rest _) (error "Backend unavailable")))))
          (should-not (get-buffer org-timegrid-buffer-name)))
      (when-let* ((buffer (get-buffer org-timegrid-buffer-name))) (kill-buffer buffer)))))

(ert-deftest org-timegrid-regression-android-leaving-calendar-clears-target ()
  (require 'org-timegrid-android)
  (let ((data (vector 1 'origin 'previous-target))
        cleared)
    (cl-letf (((symbol-function 'posn-window) (lambda (_) (selected-window)))
              ((symbol-function 'org-timegrid--mouse-target) #'ignore)
              ((symbol-function 'org-timegrid--clear-preview) (lambda () (setq cleared t))))
             (org-timegrid-android--drag-update '(touchscreen-update ((1 . position))) data)
             (should-not (aref data 2))
             (should cleared))))

(ert-deftest org-timegrid-regression-clock-uses-supplied-minute ()
  (let ((svg (svg-create 900 1400)))
    (org-timegrid--draw-current-time svg 900 1400 100 '(:red "#ff0000") "monospace" 0 1 83 0)
    (should (string-match-p ">01:23<" (with-temp-buffer (svg-print svg) (buffer-string))))))

(ert-deftest org-timegrid-regression-time-readers-reject-invalid-input ()
  (dolist (answer '("2026-02-30 10:00" "2026-10-01 24:00" "2026-10-01 10:99" "junk"))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) answer)))
             (should-error (org-timegrid-read-timestamp-default 144000 30) :type 'user-error))))

(ert-deftest org-timegrid-regression-time-reader-accepts-valid-leap-day ()
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "2024-02-29 10:15")))
           (should (equal (org-timegrid-read-timestamp-default 144000 30)
                          (cons (+ (* 1440 (calendar-absolute-from-gregorian '(2 29 2024))) 615) nil)))))

(ert-deftest org-timegrid-regression-org-reader-understands-overnight-range ()
  (cl-letf (((symbol-function 'org-timegrid-calendar-read-date)
             (lambda (&rest _)
               (setq org-end-time-was-given "00:30")
               "2026-10-01 Thu 23:30")))
           (should (= 60 (cdr (org-timegrid-org-read-timestamp 1065422040 30))))))

(ert-deftest org-timegrid-regression-click-continuation-stays-on-its-day ()
  (let* ((block (org-timegrid--make-block 'event 0 1380 1500 "Overnight"))
         (org-timegrid--state (org-timegrid--calendar-state-create :blocks (list block))))
    (cl-letf (((symbol-function 'org-timegrid--cursor-moved) #'ignore))
             (org-timegrid--goto-block block 1))
    (should (= 1 (org-timegrid--cursor-state-day (org-timegrid--cursor))))
    (should (= 0 (org-timegrid--cursor-state-minute (org-timegrid--cursor))))))

(ert-deftest org-timegrid-regression-selection-does-not-paint-block-twice ()
  (with-temp-buffer
    (let* ((org-timegrid--state
            (org-timegrid--calendar-state-create
             :week-start 100 :cursor-visible t :selected-id 'event
             :cursor (org-timegrid--cursor-state-create :surface 'grid :day 0 :minute 600)
             :blocks (list (org-timegrid--make-block 'event 0 600 660 "UniqueTitle"))))
           (org-timegrid--tile-width 900)
           (org-timegrid--tile-height 60)
           (org-timegrid--tile-count 24)
           (static-svg (org-timegrid--svg))
           (static (with-temp-buffer (svg-print static-svg) (buffer-string))))
      (insert static (car (org-timegrid--dynamic-fragment)))
      (should (= 1 (how-many "UniqueTitle" (point-min) (point-max)))))))

(ert-deftest org-timegrid-regression-android-quit-clears-preview-and-touch-state ()
  (require 'org-timegrid-android)
  (let ((touch-screen-current-tool '(1 nil nil nil start))
        (touch-screen-current-timer 'timer)
        cleared)
    (cl-letf (((symbol-function 'posn-window) (lambda (_) (selected-window)))
              ((symbol-function 'org-timegrid--mouse-target)
               (lambda (_) '(:surface grid :day 0 :minute 600)))
              ((symbol-function 'org-timegrid--all-day-layout) #'ignore)
              ((symbol-function 'touch-screen-track-drag)
               (lambda (&rest _) (signal 'quit nil)))
              ((symbol-function 'org-timegrid--clear-preview) (lambda () (setq cleared t))))
             (condition-case nil (org-timegrid-android-long-press '(touchscreen-hold position))
               (quit nil))
             (should cleared)
             (should-not touch-screen-current-tool)
             (should-not touch-screen-current-timer))))

;;; org-timegrid-regression-test.el ends here
