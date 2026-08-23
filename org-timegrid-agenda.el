;;; org-timegrid-agenda.el --- Compact day strip for Org Agenda -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad

;; Author: Umar Ahmad
;; Maintainer: Umar Ahmad
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: calendar, outlines, convenience
;; URL: https://github.com/Gleek/org-timegrid

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Insert a read-only, one-day calendar strip into an existing Org Agenda
;; buffer, showing the hours around now.  Enable it with
;; `org-timegrid-agenda-mode'.

;; This does not replace or rewrite the agenda.  Org builds its buffer as it
;; always does; the strip is added at the end, after one named block, and
;; regenerated whenever the agenda is.  Everything interactive stays in the
;; standalone Week buffer, which `RET' on the strip opens: an editable image
;; inside a buffer that rebuilds itself on `g' would fight for the same keys.

;;; Code:

(require 'org-agenda)
(require 'org-timegrid-org)

(defgroup org-timegrid-agenda nil
  "Compact one-day calendar inside Org Agenda."
  :group 'org-timegrid
  :prefix "org-timegrid-agenda-")

(defcustom org-timegrid-agenda-minutes-before 180
  "Minutes of the current day shown before now."
  :type 'integer)

(defcustom org-timegrid-agenda-minutes-after 180
  "Minutes of the current day shown after now.
Six hours in total, which at the default scale is about the height the
text time grid used to cost, for a great deal more information."
  :type 'integer)

(defcustom org-timegrid-agenda-insert-after "To Refile"
  "Header of the agenda block the strip is inserted after.
The value is matched as a regexp against the buffer.  Nil, or a header
that is absent from this agenda, puts the strip at the top, which is
where a day view belongs when nothing was requested above it."
  :type '(choice (const :tag "Top of the buffer" nil) regexp))

(defcustom org-timegrid-agenda-separator t
  "Whether to close the strip with an agenda block separator.
Nil makes the block below read as part of the strip's own section, which
is what you want when the block below is the same day's untimed items."
  :type 'boolean)

(defcustom org-timegrid-agenda-heading-format "TODAY · %s"
  "Format string for the strip's heading, given a formatted date."
  :type 'string)

(defvar org-timegrid-agenda--theme-timer nil
  "Idle timer coalescing a burst of theme changes.")

(defvar org-timegrid-agenda-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "RET" #'org-timegrid-agenda-open-week)
    (define-key map [mouse-1] #'org-timegrid-agenda-open-week)
    map)
  "Keymap active on the inserted strip.")

(defun org-timegrid-agenda-open-week ()
  "Open the standalone Week calendar on the day the strip shows."
  (interactive)
  (org-timegrid-week))

(defun org-timegrid-agenda--window (now)
  "Return the visible minute range around NOW as a cons cell.
The range is clamped to the day, and keeps its full length when NOW sits
near midnight: a window that shrank at 23:00 would show almost nothing
at the time of day it matters most."
  (let* ((span (+ org-timegrid-agenda-minutes-before
                  org-timegrid-agenda-minutes-after))
         (span (min span 1440))
         (start (max 0 (min (- 1440 span)
                            (- now org-timegrid-agenda-minutes-before)))))
    (cons start (+ start span))))

(defun org-timegrid-agenda--separator-regexp ()
  "Return a regexp matching an Org Agenda block separator line, or nil."
  (cond ((characterp org-agenda-block-separator)
         (concat "^" (regexp-quote (char-to-string org-agenda-block-separator))
                 "+$"))
        ((stringp org-agenda-block-separator)
         (concat "^" (regexp-quote org-agenda-block-separator) "$"))))

(defun org-timegrid-agenda--remove ()
  "Delete any strip already present in this buffer.
Not every agenda command rebuilds the buffer before running
`org-agenda-finalize-hook', so insertion has to be idempotent rather than
assume it is starting from a freshly generated buffer.  Without this the
strips stack up, one per finalize."
  (let ((inhibit-read-only t)
        (position (point-min)))
    (while (setq position (text-property-any position (point-max)
                                             'org-timegrid-strip t))
      (delete-region position
                     (or (text-property-not-all position (point-max)
                                                'org-timegrid-strip t)
                         (point-max))))))

(defun org-timegrid-agenda--width ()
  "Return the pixel width available for the strip."
  (let ((window (get-buffer-window (current-buffer) t)))
    (max 320 (- (if window (window-body-width window t) 700) 20))))

;;;###autoload
(defun org-timegrid-agenda-insert ()
  "Insert the compact day strip into the current Org Agenda buffer.
Suitable for `org-agenda-finalize-hook'; `org-timegrid-agenda-mode' is
the usual way to install it."
  (when (derived-mode-p 'org-agenda-mode)
    (save-excursion
      (let* ((decoded (decode-time))
             (now (+ (* 60 (decoded-time-hour decoded))
                     (decoded-time-minute decoded)))
             (today (calendar-absolute-from-gregorian (calendar-current-date)))
             (window (org-timegrid-agenda--window now))
             (blocks (org-timegrid-day-blocks org-timegrid-org-backend today))
             (image (org-timegrid-day-image
                     blocks (car window) (cdr window)
                     (org-timegrid-agenda--width) now))
             (inhibit-read-only t)
             start)
        (org-timegrid-agenda--remove)
        (goto-char (point-min))
        (when (and org-timegrid-agenda-insert-after
                   (re-search-forward org-timegrid-agenda-insert-after nil t))
          (forward-line 1)
          ;; Find the end of that block.  A header is not enough to go by: a
          ;; block whose `org-agenda-overriding-header' is empty has no line
          ;; carrying the property, and the search would run to the end of
          ;; the buffer.  Org's own separator marks the boundary too.
          (let ((separator (org-timegrid-agenda--separator-regexp)))
            (while (and (not (eobp))
                        (not (org-get-at-bol 'org-agenda-structural-header))
                        (not (and separator (looking-at-p separator))))
              (forward-line 1))
            ;; Insert below the separator, so the strip opens the section
            ;; that follows rather than closing the one above it.
            (when (and separator (looking-at-p separator))
              (forward-line 1))))
        (setq start (point))
        (insert
         (propertize
          (concat (format org-timegrid-agenda-heading-format
                          (format-time-string "%A %-d %B"))
                  (format "  %s–%s  ↗\n"
                          (org-timegrid--format-minute (car window))
                          (org-timegrid--format-minute (cdr window))))
          'face 'org-agenda-structure
          'org-agenda-structural-header t)
         (propertize " " 'display image
                     'keymap org-timegrid-agenda-map
                     'help-echo "RET opens the week calendar")
         "\n")
        ;; Org puts a separator before each block it builds, so the strip
        ;; needs one after it or the block below appears to belong to it.
        (when (and org-timegrid-agenda-separator org-agenda-block-separator)
          (insert (propertize
                   (if (stringp org-agenda-block-separator)
                       org-agenda-block-separator
                     (make-string (window-width) org-agenda-block-separator))
                   'face 'org-agenda-structure)
                  "\n"))
        ;; Mark the whole insertion so the next finalize can find and replace
        ;; it instead of adding a second one.
        (put-text-property start (point) 'org-timegrid-strip t)))))

(defun org-timegrid-agenda--theme-changed (&rest _ignored)
  "Redraw inserted strips after Emacs changes theme faces.
A calendar buffer redraws itself; a strip is a finished image sitting in
someone else's buffer, so it has to be replaced.  Enabling one theme
disables another, so the work is deferred and coalesced."
  (when (timerp org-timegrid-agenda--theme-timer)
    (cancel-timer org-timegrid-agenda--theme-timer))
  (setq org-timegrid-agenda--theme-timer
        (run-at-time
         0 nil
         (lambda ()
           (setq org-timegrid-agenda--theme-timer nil)
           (dolist (buffer (buffer-list))
             (with-current-buffer buffer
               (when (and (derived-mode-p 'org-agenda-mode)
                          (text-property-any (point-min) (point-max)
                                             'org-timegrid-strip t))
                 (org-timegrid-agenda-insert))))))))

;;;###autoload
(define-minor-mode org-timegrid-agenda-mode
  "Show a compact one-day calendar strip in Org Agenda buffers.
The strip is read-only and regenerated with the agenda, so it is always
as current as the buffer around it."
  :global t
  :group 'org-timegrid-agenda
  (if org-timegrid-agenda-mode
      (progn
        (add-hook 'org-agenda-finalize-hook #'org-timegrid-agenda-insert)
        (add-hook 'enable-theme-functions
                  #'org-timegrid-agenda--theme-changed)
        (add-hook 'disable-theme-functions
                  #'org-timegrid-agenda--theme-changed))
    (remove-hook 'org-agenda-finalize-hook #'org-timegrid-agenda-insert)
    (remove-hook 'enable-theme-functions
                 #'org-timegrid-agenda--theme-changed)
    (remove-hook 'disable-theme-functions
                 #'org-timegrid-agenda--theme-changed)))

(provide 'org-timegrid-agenda)
;;; org-timegrid-agenda.el ends here
