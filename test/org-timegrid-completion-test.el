;;; org-timegrid-completion-test.el --- Task annotations -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)

(ert-deftest org-timegrid-completion-last-duration ()
  (dolist (example
           '(("<2026-10-15 Thu 10:00-10:45>\n<2026-10-10 Sat 10:00-12:00>" 45)
             ("<2026-10-15 Thu 23:30-00:15>" 45)
             ("<2026-10-15 Thu 23:30>--<2026-10-16 Fri 01:00>" 90)
             ("<2026-10-15 Thu 10:00-10:45>\n<2026-10-16 Fri 10:00>" nil)
             ("<2026-10-15 Thu>" nil)
             ("[2026-10-15 Thu 10:00-10:45]" nil)
             ("" nil)))
    (with-temp-buffer
      (org-mode)
      (insert "* TODO Parent\n" (car example)
              "\n** Child\n<2026-10-17 Sat 10:00-13:00>\n")
      (let ((headline (car (org-element-map (org-element-parse-buffer)
                              'headline #'identity))))
        (should (equal (org-timegrid-org--heading-last-duration headline)
                       (cadr example)))))))

(ert-deftest org-timegrid-completion-annotations-and-selection ()
  (with-temp-buffer
    (org-mode)
    (insert "* Parent :work:\n** TODO Task :focus:\n<2026-10-15 Thu 10:00-10:45>\n")
    (let ((source (current-buffer))
          (org-use-tag-inheritance t))
      (cl-letf (((symbol-function 'org-timegrid-org--files)
                 (lambda () '("test.org")))
                ((symbol-function 'find-file-noselect) (lambda (_) source))
                ((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (let* ((metadata (completion-metadata "" table nil))
                          (candidate (car (all-completions "" table)))
                          (annotate (completion-metadata-get
                                     metadata 'affixation-function))
                          (annotation (nth 2 (car (funcall annotate (list candidate))))))
                     (should (eq (completion-metadata-get metadata 'category)
                                 'org-timegrid-entry))
                     (should (string-match-p "last: 45m" annotation))
                     (should (string-match-p ":work:focus:" annotation))
                     (should (string-match-p "test.org" annotation))
                     (should-not (string-match-p "test.org" candidate))
                     (should-not (string-match-p ":focus:" candidate))
                     (substring-no-properties candidate)))))
        (let ((entry (org-timegrid-org-read-entry)))
          (should (equal (car entry) "Task"))
          (should (eq (marker-buffer (cdr entry)) source)))))))

(ert-deftest org-timegrid-completion-new-entry ()
  (cl-letf (((symbol-function 'org-timegrid-org--heading-candidates) #'ignore)
            ((symbol-function 'completing-read) (lambda (&rest _) "New task")))
    (should (equal (org-timegrid-org-read-entry) '("New task")))))

(ert-deftest org-timegrid-completion-aligned-columns ()
  (let* ((short (propertize "Short" 'org-timegrid-columns
                            '("last: 5m" ":work:" "one.org")))
         (long (propertize "Longer task" 'org-timegrid-columns
                           '("last: 120m" ":work:focus:" "two.org")))
         (empty (propertize "Untimed" 'org-timegrid-columns
                            '("" "" "three.org")))
         (candidates (mapcar #'list (list short long empty)))
         (rows (org-timegrid-org--affix-entries
                (mapcar #'substring-no-properties (list short long empty))
                candidates))
         (lines (mapcar (lambda (row) (apply #'concat row)) rows)))
    (dolist (pattern '("last:" ":work:"))
      (should (= (string-match pattern (nth 0 lines))
                 (string-match pattern (nth 1 lines)))))
    (should (= (string-match "one.org" (nth 0 lines))
               (string-match "two.org" (nth 1 lines))
               (string-match "three.org" (nth 2 lines))))))

;;; org-timegrid-completion-test.el ends here
