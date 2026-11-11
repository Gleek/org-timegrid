;;; org-timegrid-title-test.el --- Visible Org titles -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-timegrid-org)

(defun org-timegrid-title-test--timestamp (text)
  "Return TEXT in the timestamp syntax produced by the installed Org."
  (with-temp-buffer
    (org-mode)
    (insert text)
    (org-element-interpret-data
     (org-element-map (org-element-parse-buffer) 'timestamp #'identity nil t))))

(ert-deftest org-timegrid-title-timestamps ()
  (dolist (stamp '("<2026-11-10 Tue 10:00-11:00>"
                   "<2026-11-10 Tue>"
                   "<2026-11-10 Tue 10:00 +1w>"))
    (with-temp-buffer
      (org-mode)
      (insert "* Meeting " stamp "\n** Child\n<2026-11-11 Wed 12:00>\n")
      (let ((events (org-timegrid-org--buffer-events "test.org")))
        (should (= (length events) 2))
        (should (equal (org-timegrid-event-title (car events))
                       (concat "Meeting " stamp)))
        (should (equal (plist-get (org-timegrid-event-metadata (car events))
                                 :raw-value)
                       stamp))
        (should (equal (org-timegrid-event-title (cadr events)) "Child"))))))

(ert-deftest org-timegrid-title-retime-and-add-body-block ()
  (with-temp-buffer
    (org-mode)
    (insert "* Meeting <2026-11-10 Tue 10:00-11:00>\n")
    (let* ((org-timegrid-org-auto-save nil)
           (event (car (org-timegrid-org--buffer-events "test.org")))
           (start (+ 60 (org-timegrid-event-start event)))
           (end (+ 60 (org-timegrid-event-end event)))
           (heading (concat "* Meeting "
                            (org-timegrid-title-test--timestamp
                             "<2026-11-10 Tue 11:00-12:00>") "\n")))
      (org-timegrid-org--update-anchor-range event start end)
      (should (equal (buffer-string) heading))
      (org-timegrid-org--add-range (plist-get (org-timegrid-event-source event) :marker)
                                   (+ start 120) (+ end 120))
      (should (equal (buffer-string)
                     (concat heading
                             "<2026-11-10 Tue 13:00-14:00>\n")))
      (let ((events (org-timegrid-org--buffer-events "test.org")))
        (should (= (length events) 2))
        (should (equal (mapcar #'org-timegrid-event-start events)
                       (list start (+ start 120))))
        (should (equal (org-timegrid-event-title (car events))
                       (org-timegrid-event-title (cadr events))))))))

(ert-deftest org-timegrid-title-completion-and-duration ()
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Meeting <2026-11-10 Tue 10:00-11:00>\n"
            "** Inactive [2026-11-10 Tue 10:00-11:00]\n")
    (let* ((headlines (org-element-map (org-element-parse-buffer) 'headline #'identity))
           (meeting (cadr headlines)))
      (should-not (org-timegrid-org-default-entry-filter (car headlines)))
      (should (org-timegrid-org-default-entry-filter meeting))
      (should (= 60 (org-timegrid-org--heading-last-duration meeting)))
      (should-not (org-timegrid-org-default-entry-filter (nth 2 headlines))))))

(ert-deftest org-timegrid-title-retime-refreshes-all-block-labels ()
  (with-temp-buffer
    (org-mode)
    (insert "* Meeting <2026-11-10 Tue 10:00-11:00>\n"
            "<2026-11-10 Tue 13:00-14:00>\n")
    (let ((title (concat "Meeting "
                         (org-timegrid-title-test--timestamp
                          "<2026-11-10 Tue 11:00-12:00>")))
          (source (current-buffer))
          (org-timegrid-org-auto-save nil))
      (with-temp-buffer
        (let* ((org-timegrid--backend
                (org-timegrid-backend-create
                 :list-function (lambda (&rest _)
                                  (with-current-buffer source
                                    (org-timegrid-org--buffer-events "test.org")))
                 :update-function #'org-timegrid-org--update-event-range))
               (org-timegrid--state
                (org-timegrid--load-state
                 (calendar-absolute-from-gregorian '(11 10 2026))))
               (block (copy-org-timegrid-block
                       (car (org-timegrid--calendar-state-blocks org-timegrid--state)))))
          (cl-incf (org-timegrid-block-start block) 60)
          (cl-incf (org-timegrid-block-end block) 60)
          (cl-letf (((symbol-function 'org-timegrid--update)
                     (lambda (change &optional _) (funcall change)))
                    ((symbol-function 'org-timegrid--goto-block) #'ignore))
            (org-timegrid--backend-update block))
          (let ((blocks (org-timegrid--calendar-state-blocks org-timegrid--state)))
            (should (= (length blocks) 2))
            (dolist (updated blocks)
              (should (equal (org-timegrid-block-title updated) title))
              (should (equal (org-timegrid-block-display-title updated)
                             title)))))))))

(ert-deftest org-timegrid-title-reload-only-for-changed-title-timestamps ()
  (dolist (example '((0 0 nil) (0 60 t) (1 60 nil)))
    (with-temp-buffer
      (org-mode)
      ;; Use Org's native format so a no-op does not reformat the title.
      (insert "* Meeting "
              (org-timegrid-title-test--timestamp
               "<2026-11-10 Tue 10:00-11:00>") "\n"
              "<2026-11-10 Tue 13:00-14:00>\n")
      (let* ((org-timegrid-org-auto-save nil)
             (event (nth (car example) (org-timegrid-org--buffer-events "test.org")))
             (delta (cadr example)))
        (org-timegrid-org--update-anchor-range
         event (+ (org-timegrid-event-start event) delta)
         (+ (org-timegrid-event-end event) delta))
        (should (eq (plist-get (org-timegrid-event-metadata event) :reload-after-edit)
                    (nth 2 example)))))))

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
