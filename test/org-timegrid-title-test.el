;;; org-timegrid-title-test.el --- Visible Org titles -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)

(ert-deftest org-timegrid-title-keeps-markup-for-editing ()
  (with-temp-buffer
    (org-mode)
    (setq-local org-hide-emphasis-markers t
                org-pretty-entities t
                org-pretty-entities-include-sub-superscripts t)
    (let ((raw "[[https://example.com][Meeting]] *bold* /italic/ _under_ +strike+ =code= ~literal~ \\alpha x_{2}"))
      (insert "* TODO [#A] " raw " :work:\n<2026-11-10 Tue 10:00>\n")
      (let* ((event (car (org-timegrid-org--buffer-events "test.org")))
             (block (org-timegrid-event-to-block
                     event (calendar-absolute-from-gregorian '(11 10 2026)))))
        (should (equal (org-timegrid-event-title event) raw))
        (should (equal (org-timegrid-block-title block) raw))
        (should (equal (org-timegrid-block-display-title block)
                       "Meeting bold italic under strike code literal α x2"))
        (should (string-match-p "Meeting bold" (org-timegrid--block-details block)))))))

(ert-deftest org-timegrid-title-respects-org-display-settings ()
  (with-temp-buffer
    (org-mode)
    (setq-local org-hide-emphasis-markers nil org-pretty-entities nil)
    (insert "* [[https://example.com]] *bold* \\alpha\n<2026-11-10 Tue 10:00>\n")
    (let ((event (car (org-timegrid-org--buffer-events "test.org"))))
      (should (equal (plist-get (org-timegrid-event-metadata event) :display-title)
                     "https://example.com *bold* \\alpha")))))

(ert-deftest org-timegrid-title-open-link-through-org ()
  (with-temp-buffer
    (org-mode)
    (insert "* [[https://example.com][Meeting]]\n<2026-11-10 Tue 10:00>\n")
    (let* ((event (car (org-timegrid-org--buffer-events "test.org")))
           (marker (plist-get (org-timegrid-event-source event) :marker))
           opened)
      (cl-letf (((symbol-function 'org-timegrid-org-selected-marker) (lambda () marker))
                ((symbol-function 'org-timegrid--refresh-data) #'ignore)
                ((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
        (call-interactively #'org-timegrid-org-open-at-point)
        (should (equal opened "https://example.com"))))))
