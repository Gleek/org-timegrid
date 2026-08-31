;;; org-timegrid-calendar.el --- Mark events in Org's date picker -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad

;; Author: Umar Ahmad
;; Maintainer: Umar Ahmad
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: calendar, outlines, convenience
;; URL: https://github.com/Gleek/org-timegrid

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Mark event dates in the ordinary Calendar displayed by `org-read-date'.
;; Calendar continues to own rendering, navigation, and selection; this
;; library only installs temporary, standard Calendar marks while the prompt
;; is active.

;;; Code:

(require 'org)
(require 'org-timegrid-model)
(require 'org-timegrid)

(defgroup org-timegrid-calendar nil
  "Timegrid decorations for the standard Emacs Calendar."
  :group 'org-timegrid
  :prefix "org-timegrid-calendar-")

(defface org-timegrid-calendar-event-face
  '((t :inherit link :underline nil :weight bold))
  "Face used for dates containing timegrid events."
  :group 'org-timegrid-calendar)

(defcustom org-timegrid-calendar-highlight-dates t
  "Whether `org-read-date' marks dates containing timegrid events.
This affects only date prompts opened through
`org-timegrid-calendar-read-date', including org-timegrid's `j' command.
It does not change unrelated Calendar buffers or Org date prompts."
  :type 'boolean)

(defcustom org-timegrid-calendar-event-predicate nil
  "Optional function deciding which events mark the date picker.
The function receives one `org-timegrid-event' and should return non-nil
when that event should mark its dates.  Nil includes every event returned
by the backend."
  :type '(choice (const :tag "All events" nil) function))

(defvar-local org-timegrid-calendar--overlays nil)
(defvar displayed-month)
(defvar displayed-year)

(defun org-timegrid-calendar--events-by-day (backend start-day end-day)
  "Return marked days from BACKEND between START-DAY and END-DAY.
END-DAY is exclusive."
  (let ((days (make-hash-table :test #'eql)))
    (dolist (event (org-timegrid-backend-list
                    backend (* start-day 1440) (* end-day 1440)))
      (when (or (null org-timegrid-calendar-event-predicate)
                (funcall org-timegrid-calendar-event-predicate event))
        (let ((first (max start-day
                          (floor (org-timegrid-event-start event) 1440)))
              (last (min (1- end-day)
                         (floor (1- (org-timegrid-event-end event)) 1440))))
          (cl-loop for day from first to last
                   do (puthash day t days)))))
    days))

(defun org-timegrid-calendar--refresh (backend)
  "Redraw standard Calendar marks from BACKEND."
  (mapc #'delete-overlay org-timegrid-calendar--overlays)
  (setq org-timegrid-calendar--overlays nil)
  (when org-timegrid-calendar-highlight-dates
    (let* ((center (calendar-absolute-from-gregorian
                    (list displayed-month 1 displayed-year)))
           ;; This safely covers Calendar's previous, current, and next month.
           (first-day (- center 31))
           (after-day (+ center 63))
                 (days (org-timegrid-calendar--events-by-day
                        backend first-day after-day)))
      (maphash
       (lambda (day _present)
         (let ((date (calendar-gregorian-from-absolute day)))
           (when (calendar-date-is-visible-p date)
             (save-excursion
               (calendar-cursor-to-visible-date date)
               (let ((before (overlays-at (point))))
                 (calendar-mark-visible-date
                  date 'org-timegrid-calendar-event-face)
                 (setq org-timegrid-calendar--overlays
                       (nconc (seq-difference (overlays-at (point)) before)
                              org-timegrid-calendar--overlays)))))))
       days))))

;;;###autoload
(defun org-timegrid-calendar-read-date (backend &rest args)
  "Read a date with `org-read-date', marking events supplied by BACKEND.
ARGS are passed to `org-read-date' unchanged.  Marks follow Calendar month
navigation and are removed when the prompt closes."
  (let (calendar-buffer-used refresh)
    (setq refresh
          (lambda ()
            (setq calendar-buffer-used (current-buffer))
            (org-timegrid-calendar--refresh backend)))
    (unwind-protect
        ;; Calendar runs one of these after every three-month render, both on
        ;; entry and when navigation brings another month into view.
        (let ((calendar-today-visible-hook
               (cons refresh calendar-today-visible-hook))
              (calendar-today-invisible-hook
               (cons refresh calendar-today-invisible-hook)))
          (apply #'org-read-date args))
      (when (buffer-live-p calendar-buffer-used)
        (with-current-buffer calendar-buffer-used
          (mapc #'delete-overlay org-timegrid-calendar--overlays)
          (setq org-timegrid-calendar--overlays nil))))))

(provide 'org-timegrid-calendar)
;;; org-timegrid-calendar.el ends here
