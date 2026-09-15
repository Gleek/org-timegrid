;;; org-timegrid-isearch.el --- Native title search for org-timegrid -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad
;; Author: Umar Ahmad <Gleek@users.noreply.github.com>
;; Maintainer: Umar Ahmad <Gleek@users.noreply.github.com>
;; Version: 0.1.0
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

;; Native incremental search for calendar block titles.  Invisible title
;; text attached to each SVG tile gives Isearch real buffer positions while
;; hooks keep the calendar's model cursor synchronized with each match.

;;; Code:

(require 'isearch)
(require 'org-timegrid)

(defcustom org-timegrid-isearch-week-limit 52
  "Number of previous and next weeks included in a title search.
A calendar has no natural first or last page, so cross-week search needs a
finite horizon.  Events in the horizon are fetched once per search."
  :type 'natnum
  :group 'org-timegrid)

(defvar-local org-timegrid-isearch--origin nil)
(defvar-local org-timegrid-isearch--point nil)
(defvar-local org-timegrid-isearch--anchors nil)
(defvar-local org-timegrid-isearch--events nil)

(defun org-timegrid-isearch--block-tile (block)
  "Return the vertical SVG tile containing BLOCK's start."
  (if (org-timegrid-block-all-day-p block)
      0
    (org-timegrid--tile-at-pixel
     (+ (org-timegrid--grid-top-inset)
        (* (- (org-timegrid-block-start block)
              (* 60 org-timegrid-start-hour))
           (org-timegrid--pixels-per-minute))))))

(defun org-timegrid-isearch--index ()
  "Append invisible block titles to their corresponding SVG tile lines."
  (when (and (derived-mode-p 'org-timegrid-mode)
             (vectorp org-timegrid--tile-markers))
    (let ((inhibit-read-only t)
          (offset 0)
          anchors
          (by-tile (make-vector org-timegrid--tile-count nil)))
      (dolist (block (org-timegrid--ordered-blocks))
        (when-let* ((tile (org-timegrid-isearch--block-tile block)))
          (push block (aref by-tile tile))))
      (dotimes (tile org-timegrid--tile-count)
        (let ((position (+ (aref org-timegrid--tile-markers tile) offset)))
          (aset org-timegrid--tile-markers tile position)
          (goto-char (1+ position))
          (dolist (block (nreverse (aref by-tile tile)))
            (let* ((start (point))
                   (text (concat (or (org-timegrid-block-title block) "") "\0")))
              (insert (propertize
                       text 'display ""
                       'org-timegrid-isearch-block block
                       'rear-nonsticky t))
              (push (cons (org-timegrid-block-id block) (cons start (point)))
                    anchors)
              (setq offset (+ offset (length text)))))))
      (setq-local org-timegrid-isearch--anchors (nreverse anchors)))))

(defun org-timegrid-isearch--start-position (backward)
  "Return an indexed position near the calendar cursor for BACKWARD search."
  (let* ((origin (org-timegrid--cursor-absolute))
         (blocks (org-timegrid--ordered-blocks))
         (block
          (or (if backward
                  (car (last
                        (seq-take-while
                         (lambda (candidate)
                           (<= (org-timegrid--block-absolute-start candidate)
                               origin))
                         blocks)))
                (seq-find
                 (lambda (candidate)
                   (>= (org-timegrid--block-absolute-start candidate) origin))
                 blocks))
              (if backward (car (last blocks)) (car blocks))))
         (range (and block
                     (cdr (cl-assoc
                           (org-timegrid-block-id block)
                           org-timegrid-isearch--anchors :test #'equal)))))
    (if range
        (if backward (cdr range) (car range))
      (if backward (point-max) (point-min)))))

(defun org-timegrid-isearch--sync ()
  "Select the block containing the current Isearch match."
  (when-let* (((and isearch-mode isearch-success
                    (> (length isearch-string) 0)))
              (position (match-beginning 0))
              ((< position (point-max)))
              (block (get-text-property position
                                        'org-timegrid-isearch-block)))
    (org-timegrid--goto-block block)))

(defun org-timegrid-isearch--visit-week (week)
  "Load and display WEEK while preserving active Isearch machinery."
  (org-timegrid--reload-state week)
  (org-timegrid--refresh t))

(defun org-timegrid-isearch--events ()
  "Return and cache events inside the cross-week search horizon."
  (or org-timegrid-isearch--events
      (let* ((week (org-timegrid--calendar-state-week-start org-timegrid--state))
             (span (* org-timegrid-isearch-week-limit
                      org-timegrid-days 1440)))
        (setq-local
         org-timegrid-isearch--events
         (org-timegrid-backend-list
          org-timegrid--backend (- (* week 1440) span)
          (+ (* (+ week org-timegrid-days) 1440) span))))))

(defun org-timegrid-isearch--event-regexp (string)
  "Return the regexp with which Isearch interprets STRING."
  (cond
   ((functionp isearch-regexp-function)
    (funcall isearch-regexp-function string nil))
   (isearch-regexp-function (word-search-regexp string))
   (isearch-regexp string)
   (t (regexp-quote string))))

(defun org-timegrid-isearch--matching-event (string)
  "Return the next event outside this week whose title matches STRING."
  (let* ((week (org-timegrid--calendar-state-week-start org-timegrid--state))
         (start (* week 1440))
         (end (* (+ week org-timegrid-days) 1440))
         (regexp (org-timegrid-isearch--event-regexp string))
         (case-fold-search isearch-case-fold-search)
         (events
          (seq-filter
           (lambda (event)
             (and (if isearch-forward
                      (>= (org-timegrid-event-start event) end)
                    (< (org-timegrid-event-start event) start))
                  (string-match-p regexp (org-timegrid-event-title event))))
           (org-timegrid-isearch--events))))
    (car (sort events
               (if isearch-forward
                   (lambda (left right)
                     (< (org-timegrid-event-start left)
                        (org-timegrid-event-start right)))
                 (lambda (left right)
                   (> (org-timegrid-event-start left)
                      (org-timegrid-event-start right))))))))

(defun org-timegrid-isearch--search-function ()
  "Return an Isearch function that continues across calendar weeks."
  (lambda (string &optional bound noerror count)
    (let ((search (isearch-search-fun-default)))
      ;; Lazy highlighting supplies BOUND and should stay on the visible week.
      (if bound
          (funcall search string bound noerror count)
        (let ((found (funcall search string nil t count)))
          (unless found
            (when-let* ((event (org-timegrid-isearch--matching-event string)))
              (org-timegrid-isearch--visit-week
               (org-timegrid--range-start
                (floor (org-timegrid-event-start event) 1440)))
              (goto-char (if isearch-forward (point-min) (point-max)))
              (setq found (funcall search string nil t count))))
          (or found
              (unless noerror
                (signal 'search-failed (list string)))))))))

(defun org-timegrid-isearch--push-state ()
  "Capture the displayed week for Isearch's state stack."
  (let ((week (org-timegrid--calendar-state-week-start org-timegrid--state)))
    (lambda (_state)
      (unless (= week
                 (org-timegrid--calendar-state-week-start org-timegrid--state))
        (org-timegrid-isearch--visit-week week)))))

(defun org-timegrid-isearch--finish ()
  "Restore the original calendar state when Isearch is aborted."
  (when isearch-mode-end-hook-quit
    (pcase-let ((`(,week ,cursor ,visible) org-timegrid-isearch--origin))
      (org-timegrid--reload-state week)
      (setf (org-timegrid--calendar-state-cursor org-timegrid--state) cursor
            (org-timegrid--calendar-state-cursor-visible org-timegrid--state)
            visible)
      (org-timegrid--refresh t)))
  (goto-char (min org-timegrid-isearch--point (point-max)))
  (remove-hook 'isearch-update-post-hook #'org-timegrid-isearch--sync t)
  (remove-hook 'isearch-mode-end-hook #'org-timegrid-isearch--finish t))

(defun org-timegrid-isearch--start (backward)
  "Search block titles natively, going BACKWARD when non-nil."
  (setq-local
   org-timegrid-isearch--origin
   (list (org-timegrid--calendar-state-week-start org-timegrid--state)
         (and (org-timegrid--cursor)
              (copy-org-timegrid--cursor-state (org-timegrid--cursor)))
         (org-timegrid--cursor-visible-p))
   org-timegrid-isearch--point (point)
   org-timegrid-isearch--events nil
   isearch-search-fun-function #'org-timegrid-isearch--search-function
   isearch-push-state-function #'org-timegrid-isearch--push-state)
  (goto-char (org-timegrid-isearch--start-position backward))
  (add-hook 'isearch-update-post-hook #'org-timegrid-isearch--sync nil t)
  (add-hook 'isearch-mode-end-hook #'org-timegrid-isearch--finish nil t)
  (isearch-mode (not backward)))

(defun org-timegrid-isearch-forward ()
  "Incrementally search block titles forward."
  (interactive)
  (org-timegrid-isearch--start nil))

(defun org-timegrid-isearch-backward ()
  "Incrementally search block titles backward."
  (interactive)
  (org-timegrid-isearch--start t))

(unless (advice-member-p #'org-timegrid-isearch--index
                         #'org-timegrid--insert-tiles)
  (advice-add 'org-timegrid--insert-tiles :after #'org-timegrid-isearch--index))

(keymap-set org-timegrid-mode-map "C-s" #'org-timegrid-isearch-forward)
(keymap-set org-timegrid-mode-map "C-r" #'org-timegrid-isearch-backward)

(provide 'org-timegrid-isearch)
;;; org-timegrid-isearch.el ends here
