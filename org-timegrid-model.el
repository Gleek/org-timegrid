;;; org-timegrid-model.el --- Records and backend protocol for org-timegrid -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad

;; Author: Umar Ahmad
;; Maintainer: Umar Ahmad
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
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

;; Data records and layout helpers shared by the calendar renderer and its
;; backends.  This file deliberately has no Org dependency.

;;; Code:

(require 'calendar)
(require 'cl-lib)

(cl-defstruct (org-timegrid-event
               (:constructor org-timegrid-event-create))
  "A backend-neutral timed calendar event.
START and END are integer minutes based on Emacs absolute Gregorian dates.
SOURCE is opaque to the renderer and belongs to the backend."
  id title start end tags state color source metadata)

(cl-defstruct (org-timegrid-backend
               (:constructor org-timegrid-backend-create))
  "Operations supplied by a calendar data backend.
LIST-FUNCTION receives inclusive START and exclusive END absolute minutes.
CREATE-FUNCTION receives TITLE, START, END, an optional source event to
duplicate, and an optional existing backend record selected by
READ-ENTRY-FUNCTION or retained from an event's SOURCE while cutting it.
UPDATE-FUNCTION receives an existing event, its new START and END, and an
optional heading title.  DELETE-FUNCTION removes an event's time;
DELETE-ENTRY-FUNCTION removes the record that carried it.  UNDO-FUNCTION
receives non-nil when it continues an unbroken run of undos, and REDO
when the caller wants the reverse; the backend owns undo because only it
knows where the edit landed.  READ-ENTRY-FUNCTION may return a cons of the
display title and an opaque existing record.  READ-TIMESTAMP-FUNCTION lets a
backend supply its own date prompt.  Mutation functions may be nil."
  name list-function create-function update-function delete-function
  delete-entry-function undo-function visit-function
  read-entry-function read-timestamp-function)

(defcustom org-timegrid-slot-minutes 15
  "Granularity of the calendar, in minutes.
Edits snap to this, it is the smallest range an entry may have, and it is
the height of the keyboard cursor."
  ;; The group is declared in `org-timegrid', which requires this file rather
  ;; than the other way round, so it is named here instead of inherited.
  :group 'org-timegrid
  :type 'integer)

(defun org-timegrid-week-start (&optional absolute-date)
  "Return the first absolute date of the week containing ABSOLUTE-DATE."
  (let* ((absolute (or absolute-date
                       (calendar-absolute-from-gregorian
                        (calendar-current-date))))
         (weekday (calendar-day-of-week
                   (calendar-gregorian-from-absolute absolute)))
         (first-day (if (boundp 'calendar-week-start-day)
                        calendar-week-start-day
                      1)))
    (- absolute (mod (- weekday first-day) 7))))

(defun org-timegrid-date-label (absolute-date)
  "Return a compact label for ABSOLUTE-DATE."
  (let* ((date (calendar-gregorian-from-absolute absolute-date))
         (month (nth 0 date))
         (day (nth 1 date))
         (day-name (calendar-day-name date t)))
    (format "%s %d/%d" day-name day month)))

(defun org-timegrid-event-valid-p (event)
  "Return non-nil when EVENT satisfies the renderer contract."
  (and (org-timegrid-event-p event)
       (org-timegrid-event-id event)
       (stringp (org-timegrid-event-title event))
       (integerp (org-timegrid-event-start event))
       (integerp (org-timegrid-event-end event))
       (< (org-timegrid-event-start event)
          (org-timegrid-event-end event))))

(defun org-timegrid-backend-list (backend start end)
  "Return validated BACKEND events intersecting START through END."
  (unless (and (org-timegrid-backend-p backend)
               (functionp
                (org-timegrid-backend-list-function backend)))
    (error "Calendar backend has no event listing function"))
  (cl-remove-if-not
   (lambda (event)
     (and (org-timegrid-event-valid-p event)
          (< (org-timegrid-event-start event) end)
          (> (org-timegrid-event-end event) start)))
   (funcall (org-timegrid-backend-list-function backend) start end)))

(defun org-timegrid-event-to-block (event week-start)
  "Convert EVENT to renderer coordinates relative to WEEK-START."
  (let* ((week-minute (* week-start 1440))
         (relative-start (- (org-timegrid-event-start event)
                            week-minute))
         (relative-end (- (org-timegrid-event-end event)
                          week-minute))
         (day (floor relative-start 1440))
         (day-start (* day 1440)))
    (list :id (org-timegrid-event-id event)
          :day day
          :start (- relative-start day-start)
          :end (- relative-end day-start)
          :title (org-timegrid-event-title event)
          :tags (org-timegrid-event-tags event)
          :state (org-timegrid-event-state event)
          :color (org-timegrid-event-color event)
          :done (eq (org-timegrid-event-state event) 'done)
          :event event)))

(defun org-timegrid-events-to-blocks (events week-start)
  "Convert EVENTS to renderer blocks relative to WEEK-START."
  (mapcar (lambda (event)
            (org-timegrid-event-to-block event week-start))
          events))

(defun org-timegrid--assign-group-lanes (group)
  "Return copies of GROUP blocks annotated with overlap lanes."
  (let (lane-ends assigned)
    (dolist (block group)
      (let ((lane 0))
        (while (and (< lane (length lane-ends))
                    (> (nth lane lane-ends) (plist-get block :start)))
          (setq lane (1+ lane)))
        (if (= lane (length lane-ends))
            (setq lane-ends
                  (append lane-ends (list (plist-get block :end))))
          (setf (nth lane lane-ends) (plist-get block :end)))
        (push (plist-put (copy-sequence block) :lane lane) assigned)))
    (let ((count (max 1 (length lane-ends))))
      (mapcar (lambda (block) (plist-put block :lanes count))
              (nreverse assigned)))))

(defun org-timegrid-basic-layout-day (blocks day)
  "Annotate BLOCKS on DAY with stable overlap lanes."
  (let ((sorted (sort (cl-remove-if-not
                       (lambda (block) (= day (plist-get block :day)))
                       (copy-sequence blocks))
                      (lambda (left right)
                        (< (plist-get left :start)
                           (plist-get right :start)))))
        group group-end output)
    (dolist (block sorted)
      (if (or (null group) (< (plist-get block :start) group-end))
          (progn
            (push block group)
            (setq group-end
                  (max (or group-end 0) (plist-get block :end))))
        (setq output
              (nconc output
                     (org-timegrid--assign-group-lanes
                      (nreverse group))))
        (setq group (list block)
              group-end (plist-get block :end))))
    (when group
      (setq output
            (nconc output
                   (org-timegrid--assign-group-lanes
                    (nreverse group)))))
    output))

(provide 'org-timegrid-model)
;;; org-timegrid-model.el ends here
