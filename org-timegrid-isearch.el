;;; org-timegrid-isearch.el --- Incremental title search for org-timegrid -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Optional incremental search for calendar block titles.  Requiring this
;; library binds C-s and C-r in `org-timegrid-mode-map'.

;;; Code:

(require 'cl-lib)
(require 'isearch)
(require 'seq)
(require 'subr-x)
(require 'org-timegrid)

(defvar org-timegrid-isearch-history nil)
(defvar org-timegrid-isearch--buffer nil)
(defvar org-timegrid-isearch--direction 1)
(defvar org-timegrid-isearch--query "")
(defvar org-timegrid-isearch--current-id nil)
(defvar org-timegrid-isearch--origin-minute nil)

(defun org-timegrid-isearch--matches (query)
  "Return ordered blocks whose titles contain QUERY."
  (let ((case-fold-search
         (and isearch-case-fold-search
              (or (not search-upper-case)
                  (isearch-no-upper-case-p query t)))))
    (with-current-buffer org-timegrid-isearch--buffer
      (seq-filter
       (lambda (block)
         (string-match-p
          (regexp-quote query) (or (org-timegrid-block-title block) "")))
       (org-timegrid--ordered-blocks)))))

(defun org-timegrid-isearch--first-from-origin (matches direction)
  "Choose the first of MATCHES from the search origin in DIRECTION."
  (or (if (> direction 0)
          (seq-find
           (lambda (block)
             (>= (org-timegrid--block-absolute-start block)
                 org-timegrid-isearch--origin-minute))
           matches)
        (car (last
              (seq-take-while
               (lambda (block)
                 (<= (org-timegrid--block-absolute-start block)
                     org-timegrid-isearch--origin-minute))
               matches))))
      (if (> direction 0) (car matches) (car (last matches)))))

(defun org-timegrid-isearch--select (query direction &optional repeat)
  "Select a title matching QUERY in DIRECTION.
When REPEAT is non-nil, move past the current match and wrap if needed."
  (let* ((matches (org-timegrid-isearch--matches query))
         (current
          (and repeat org-timegrid-isearch--current-id
               (cl-position org-timegrid-isearch--current-id matches
                            :key (lambda (block) (org-timegrid-block-id block))
                            :test #'equal)))
         (block
          (cond
           ((null matches) nil)
           (current
            (nth (mod (+ current direction) (length matches)) matches))
           (t (org-timegrid-isearch--first-from-origin matches direction)))))
    (if block
        (progn
          (setq org-timegrid-isearch--current-id (org-timegrid-block-id block))
          (with-current-buffer org-timegrid-isearch--buffer
            (org-timegrid--goto-block block))
          t)
      (minibuffer-message " [No matching block]")
      nil)))

(defun org-timegrid-isearch--update ()
  "Update the calendar after the minibuffer search text changes."
  (let ((query (minibuffer-contents-no-properties)))
    (unless (equal query org-timegrid-isearch--query)
      (setq org-timegrid-isearch--query query
            org-timegrid-isearch--current-id nil)
      (unless (string-empty-p query)
        (org-timegrid-isearch--select
         query org-timegrid-isearch--direction)))))

(defun org-timegrid-isearch--repeat (direction)
  "Repeat the active calendar title search in DIRECTION."
  (setq org-timegrid-isearch--direction direction)
  (let ((query (minibuffer-contents-no-properties)))
    (if (and (string-empty-p query) org-timegrid-isearch-history)
        (progn
          (insert (car org-timegrid-isearch-history))
          (org-timegrid-isearch--update))
      (unless (string-empty-p query)
        (org-timegrid-isearch--select query direction t)))))

(defun org-timegrid-isearch-repeat-forward ()
  "Repeat the active calendar title search forward."
  (interactive)
  (org-timegrid-isearch--repeat 1))

(defun org-timegrid-isearch-repeat-backward ()
  "Repeat the active calendar title search backward."
  (interactive)
  (org-timegrid-isearch--repeat -1))

(defvar org-timegrid-isearch-map
  (let ((map (copy-keymap minibuffer-local-map)))
    (keymap-set map "C-s" #'org-timegrid-isearch-repeat-forward)
    (keymap-set map "C-r" #'org-timegrid-isearch-repeat-backward)
    map)
  "Minibuffer keymap used while searching calendar block titles.")

(defun org-timegrid-isearch--start (direction)
  "Incrementally search calendar block titles in DIRECTION."
  (let* ((calendar (current-buffer))
         (saved-week (org-timegrid--calendar-state-week-start org-timegrid--state))
         (saved-cursor (and (org-timegrid--cursor)
                            (copy-org-timegrid--cursor-state
                             (org-timegrid--cursor))))
         (saved-visible (org-timegrid--cursor-visible-p))
         (org-timegrid-isearch--buffer calendar)
         (org-timegrid-isearch--direction direction)
         (org-timegrid-isearch--query "")
         (org-timegrid-isearch--current-id nil)
         (org-timegrid-isearch--origin-minute
          (org-timegrid--cursor-absolute)))
    (condition-case nil
        (minibuffer-with-setup-hook
            (lambda ()
              (add-hook 'post-command-hook
                        #'org-timegrid-isearch--update nil t))
          (read-from-minibuffer
           (if (> direction 0) "I-search: " "I-search backward: ")
           nil org-timegrid-isearch-map nil
           'org-timegrid-isearch-history))
      (quit
       (with-current-buffer calendar
         (org-timegrid--reload-state saved-week)
         (setf (org-timegrid--calendar-state-cursor org-timegrid--state)
               saved-cursor
               (org-timegrid--calendar-state-cursor-visible
                org-timegrid--state)
               saved-visible)
         (org-timegrid--refresh t)
         (when saved-visible
           (org-timegrid--scroll-cursor-into-view)))
       (message "Quit")))))

(defun org-timegrid-isearch-forward ()
  "Incrementally search block titles forward."
  (interactive)
  (org-timegrid-isearch--start 1))

(defun org-timegrid-isearch-backward ()
  "Incrementally search block titles backward."
  (interactive)
  (org-timegrid-isearch--start -1))

(keymap-set org-timegrid-mode-map "C-s" #'org-timegrid-isearch-forward)
(keymap-set org-timegrid-mode-map "C-r" #'org-timegrid-isearch-backward)

(provide 'org-timegrid-isearch)
;;; org-timegrid-isearch.el ends here
