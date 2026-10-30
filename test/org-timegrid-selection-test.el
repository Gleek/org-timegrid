;;; org-timegrid-selection-test.el --- Selection after edits -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)

(ert-deftest org-timegrid-selection-survives-heading-edits ()
  "Heading edits reselect at the cursor, including repeated occurrences."
  (dolist (timestamp '("<2026-10-24 Sat 09:00-10:00>"
                       "<2026-10-24 Sat>"
                       "<2026-10-24 Sat 09:00-10:00 +1d>"
                       "CLOCK: [2026-10-24 Sat 09:00]--[2026-10-24 Sat 10:00] =>  1:00"))
    (with-temp-buffer
      (org-mode)
      (insert "* Other\n<2026-10-24 Sat 09:00-10:00>\n* Task\n"
              timestamp "\n")
      (let* ((source (current-buffer))
             (week (calendar-absolute-from-gregorian '(10 24 2026)))
             (org-timegrid-org-auto-save nil)
             (org-timegrid-org-show-clocks t)
             (org-timegrid-org-show-done t)
             (org-timegrid-org-filter-function (lambda (&rest _) t))
             (org-timegrid-org-repeater-history nil)
             (org-timegrid--backend
              (copy-org-timegrid-backend org-timegrid-org-backend)))
        (setf (org-timegrid-backend-list-function org-timegrid--backend)
              (lambda (start end)
                (with-current-buffer source
                  (mapcan (lambda (event)
                            (org-timegrid-org--expand-event event start end))
                          (org-timegrid-org--buffer-events "selection.org")))))
        (with-temp-buffer
          (make-local-variable 'org-timegrid--state)
          (let* ((org-timegrid--state (org-timegrid--load-state week))
                 (block (car (last (org-timegrid--calendar-state-blocks
                                    org-timegrid--state)))))
            (setf (org-timegrid--calendar-state-cursor org-timegrid--state)
                  (org-timegrid--cursor-state-create
                   :surface (if (org-timegrid-block-all-day-p block) 'rail 'grid)
                   :day (org-timegrid-block-day block)
                   :minute (org-timegrid-block-start block)
                   :lane (if (and (not (org-timegrid-block-all-day-p block))
                                  (= (org-timegrid-block-day block) 0))
                             1 0))
                  (org-timegrid--calendar-state-cursor-visible org-timegrid--state) t
                  (org-timegrid--calendar-state-selected-id org-timegrid--state)
                  (org-timegrid-block-id block))
            (let ((cursor (org-timegrid--cursor))
                  (start (org-timegrid-event-start (org-timegrid-block-event block))))
              (cl-letf (((symbol-function 'org-timegrid--refresh-data)
                         (lambda (&rest _) (org-timegrid--reload-state week)))
                        ((symbol-function 'org-timegrid--read-title)
                         (lambda (&rest _) "Longer task title")))
                (dolist (action
                         (list #'org-timegrid-edit-selected-title
                               (lambda ()
                                 (org-timegrid-org--run-selected-command
                                  (lambda () (interactive) (org-todo "TODO"))))
                               (lambda ()
                                 (org-timegrid-org--run-selected-command
                                  (lambda () (interactive) (org-set-tags '("work")))))))
                  (funcall action)
                  (let ((selected (org-timegrid--selected-block)))
                    (should (equal (org-timegrid-block-title selected) "Longer task title"))
                    (should (= (org-timegrid-event-start (org-timegrid-block-event selected))
                               start))
                    (should (equal (org-timegrid--cursor) cursor))
                    (should (org-timegrid--cursor-visible-p))))))))))))

;;; org-timegrid-selection-test.el ends here
