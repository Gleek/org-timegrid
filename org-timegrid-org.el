;;; org-timegrid-org.el --- Org backend for org-timegrid -*- lexical-binding: t; -*-

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

;; Read timed events from live Org buffers and write edits back to them, as an
;; implementation of the org-timegrid backend protocol.  Timestamps that carry
;; a clock time are included, whether plain or after SCHEDULED or DEADLINE;
;; repeaters are expanded into concrete occurrences here, so the renderer never
;; sees repeater syntax.  Edits leave their buffers modified but unsaved, as
;; Org Agenda commands do.

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-agenda)
(require 'org-timegrid-model)
;; The backend value names renderer functions, so the renderer has to be
;; loaded, not autoloaded.  There is no cycle: `org-timegrid.el' never
;; requires Org.
(require 'org-timegrid)

(defgroup org-timegrid-org nil
  "Org data support for `org-timegrid'."
  :group 'org-timegrid
  :prefix "org-timegrid-org-")

(defcustom org-timegrid-org-files 'agenda
  "Files queried for timed Org ranges.
The symbol `agenda' means use `org-agenda-files'.  A function value is
called without arguments.  A list is used literally, so an empty list
queries no files beyond `org-timegrid-org-extra-files' and the
capture file."
  :type '(choice (const :tag "Org agenda files" agenda)
                 (function :tag "File-producing function")
                 (repeat :tag "Explicit files" file)))

(defcustom org-timegrid-org-extra-files nil
  "Files always queried in addition to `org-timegrid-org-files'."
  :type '(repeat file))

(defcustom org-timegrid-org-capture-file nil
  "File reserved for calendar-created Org entries.
The date query always includes this file, even when it is not in
`org-agenda-files'.  Nil uses the first agenda file, which is commonly an
inbox.  New entries are inserted into its live buffer and left unsaved."
  :type '(choice (const :tag "First Org agenda file" nil) file))

(defcustom org-timegrid-org-capture-todo-keyword "TODO"
  "TODO keyword used for entries drawn on the calendar."
  :type 'string)

(defcustom org-timegrid-org-show-repeaters t
  "Whether repeating Org timestamps appear on the calendar.
When nil, the calendar omits both the anchor and generated occurrences of
timestamps with an Org repeater."
  :type 'boolean)

(defcustom org-timegrid-org-tag-color-alist nil
  "Map Org tag strings to calendar colours.
A value is a name in `org-timegrid-colors' or any colour string.  Tags
are checked in the order they appear on the heading, so the first mapped
tag wins and a heading may carry others freely.  An unmapped heading uses
`org-timegrid-default-color'; colour means something on a calendar, so
inventing one per tag would be noise."
  :type '(alist :key-type (string :tag "Org tag")
                :value-type (choice (symbol :tag "Colour name")
                                    (color :tag "Colour"))))

(defcustom org-timegrid-org-color-function
  #'org-timegrid-org-tag-color
  "Function returning the colour for an Org heading, or nil for the default.
It receives the `org-element' headline, so it can colour by TODO state,
priority, property, or file as easily as by tag."
  :type 'function)

(defun org-timegrid-org-tag-color (headline)
  "Return the colour mapped to HEADLINE's first mapped tag, or nil."
  (seq-some (lambda (tag)
              (cdr (assoc tag org-timegrid-org-tag-color-alist)))
            (org-element-property :tags headline)))

(defun org-timegrid-org--capture-target ()
  "Return the file calendar entries are written to, or nil.
Named apart from `org-timegrid-org-capture-file': a function and a user
option sharing one name is legal and confusing, and it also makes a
minor mode indistinguishable from an option to any code that inspects
symbols."
  (or org-timegrid-org-capture-file
      (car (org-agenda-files))))

(defun org-timegrid-org--files ()
  "Return the existing, deduplicated Org files to query."
  (let ((files
         (append
          (cond ((eq org-timegrid-org-files 'agenda)
                 (org-agenda-files))
                ((functionp org-timegrid-org-files)
                 (funcall org-timegrid-org-files))
                ((listp org-timegrid-org-files)
                 org-timegrid-org-files)
                (t nil))
          org-timegrid-org-extra-files
          (and (org-timegrid-org--capture-target)
               (list (org-timegrid-org--capture-target))))))
    (delete-dups
     (cl-loop for file in files
              for expanded = (expand-file-name file)
              when (or (file-readable-p expanded)
                       (find-buffer-visiting expanded))
              collect expanded))))

(defun org-timegrid-org--format-date (absolute-day)
  "Format ABSOLUTE-DAY for an Org timestamp."
  (let* ((date (calendar-gregorian-from-absolute absolute-day))
         (month (nth 0 date))
         (day (nth 1 date))
         (year (nth 2 date)))
    (format "%04d-%02d-%02d %s" year month day
            (calendar-day-name date t))))

(defun org-timegrid-org--format-clock (minute-of-day)
  "Format MINUTE-OF-DAY as a 24-hour Org clock value."
  (format "%02d:%02d" (/ minute-of-day 60) (% minute-of-day 60)))

(defun org-timegrid-org--format-range (start end)
  "Format absolute minute START and END as an active Org range."
  (let* ((start-day (floor start 1440))
         (end-day (floor end 1440))
         (start-clock (% start 1440))
         (end-clock (% end 1440))
         (start-date (org-timegrid-org--format-date start-day))
         (end-date (org-timegrid-org--format-date end-day)))
    (if (= start-day end-day)
        (format "<%s %s-%s>" start-date
                (org-timegrid-org--format-clock start-clock)
                (org-timegrid-org--format-clock end-clock))
      (format "<%s %s>--<%s %s>" start-date
              (org-timegrid-org--format-clock start-clock)
              end-date
              (org-timegrid-org--format-clock end-clock)))))

(defun org-timegrid-org--duplicate-entry-string
    (source title start end)
  "Return a top-level copy of SOURCE using TITLE and range START through END."
  (let* ((source-data (org-timegrid-event-source source))
         (marker (plist-get source-data :marker))
         subtree)
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "The source entry is no longer live"))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker)
       (org-back-to-heading t)
       (let ((begin (point)))
         (org-end-of-subtree t t)
         (setq subtree (buffer-substring-no-properties begin (point))))))
    (with-temp-buffer
      (org-mode)
      (insert subtree)
      (goto-char (point-min))
      (org-edit-headline title)
      (while (> (or (org-current-level) 1) 1)
        (org-promote-subtree))
      ;; A duplicate gets a fresh range and no identity properties.
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*:\\(?:ID\\|CUSTOM_ID\\):.*\\(?:\n\\|\\'\\)" nil t)
        (replace-match ""))
      (let (ranges)
        (org-element-map (org-element-parse-buffer) 'timestamp
          (lambda (timestamp)
            (push (cons (org-element-property :begin timestamp)
                        (org-element-property :end timestamp))
                  ranges)))
        (dolist (range (sort ranges (lambda (left right)
                                      (> (car left) (car right)))))
          (delete-region (car range) (cdr range))))
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*\\(?:SCHEDULED:\\|DEADLINE:\\|CLOSED:\\|[ \t]\\)+$"
              nil t)
        (replace-match ""))
      ;; Removing the timestamps and planning values leaves their lines
      ;; empty, so drop the blank run between the heading and the body.
      (goto-char (point-min))
      (forward-line 1)
      (while (and (not (eobp)) (looking-at-p "[ \t]*$"))
        (delete-region (point) (min (point-max) (line-beginning-position 2))))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (org-timegrid-org--format-range start end) "\n")
      (buffer-string))))

(defcustom org-timegrid-org-after-create-hook nil
  "Hook run on a heading the calendar has just created.
Point is on the new heading in its own buffer, inside the change group
that inserted it, so a property set here is part of the entry's single
undo step.  This is where a configuration matches whatever its capture
templates do — stamping a CAPTURED property, filing an ID, adding a
default tag."
  :type 'hook)

(defun org-timegrid-org--add-range (marker start end)
  "Add the range from START to END to the heading at MARKER."
  (unless (and (markerp marker) (marker-buffer marker))
    (user-error "The selected Org heading is no longer live"))
  (with-current-buffer (marker-buffer marker)
    (org-with-wide-buffer
     (goto-char marker)
     (org-back-to-heading t)
     (undo-boundary)
     (atomic-change-group
       (org-end-of-meta-data t)
       (unless (bolp) (insert "\n"))
       (insert (org-timegrid-org--format-range start end) "\n"))
     (undo-boundary)
     (org-timegrid-org--note-edit))))

(defun org-timegrid-org--create-event (title start end &optional source target)
  "Create TITLE from absolute minute START to END in the capture buffer."
  (if target
      (progn
        (org-timegrid-org--add-range target start end)
        (message "Added time block to %s" title))
    (let ((file (org-timegrid-org--capture-target))
          (entry (if source
                     (org-timegrid-org--duplicate-entry-string
                      source title start end)
                   (concat "* " org-timegrid-org-capture-todo-keyword
                           " " title "\n"
                           (org-timegrid-org--format-range start end)
                           "\n"))))
      (unless file
        (user-error "Set `org-timegrid-org-capture-file' first"))
      (let ((buffer (find-file-noselect (expand-file-name file))))
        (with-current-buffer buffer
          (unless (derived-mode-p 'org-mode)
            (org-mode))
          (org-with-wide-buffer
           (goto-char (point-max))
           (undo-boundary)
           (atomic-change-group
             (unless (or (= (point-min) (point-max)) (bolp))
               (insert "\n"))
             (unless (or (= (point-min) (point-max))
                         (save-excursion
                           (forward-line -1)
                           (looking-at-p "[[:space:]]*$")))
               (insert "\n"))
             (let ((beginning (point)))
               (insert entry)
               ;; Run the hook inside the change group, with point on the new
               ;; heading, so anything it adds belongs to the same undo step as
               ;; the entry rather than needing a second undo of its own.
               (goto-char beginning)
               (run-hooks 'org-timegrid-org-after-create-hook)))
           (undo-boundary))
          (org-timegrid-org--note-edit)
          (message "Added %s" title))))))

(defun org-timegrid-org--heading-candidates ()
  "Return completion candidates for unfinished TODO headings."
  (let (candidates)
    (dolist (file (org-timegrid-org--files))
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (org-element-map (org-element-parse-buffer) 'headline
           (lambda (headline)
             (when (and (org-element-property :todo-keyword headline)
                        (not (eq (org-element-property :todo-type headline)
                                 'done)))
               (let* ((title (org-element-property :raw-value headline))
                      (todo (org-element-property :todo-keyword headline))
                      (tags (org-element-property :tags headline))
                      (marker (copy-marker
                               (org-element-property :begin headline)))
                      (path (save-excursion
                              (goto-char marker)
                              (org-get-outline-path)))
                      (context (string-join
                                (append path
                                        (list (file-name-nondirectory file)))
                                " / "))
                      (tag-text (and tags
                                     (concat ":" (string-join tags ":") ":")))
                      (display
                       (string-join
                        (delq nil
                              (list (propertize todo 'face
                                               (org-get-todo-face todo))
                                    title
                                    (and tag-text
                                         (propertize tag-text 'face 'org-tag))
                                    (propertize (format "[%s]" context)
                                                'face 'shadow)))
                        "  ")))
                 (push (cons display (cons title marker)) candidates))))))))
    (nreverse candidates)))

(defun org-timegrid-org-read-entry ()
  "Read an agenda TODO heading, or a title for a new capture entry."
  (let* ((candidates (org-timegrid-org--heading-candidates))
         (choice (completing-read "Task: " candidates nil nil))
         (match (assoc choice candidates)))
    (if match
        (cdr match)
      (cons choice nil))))

(defvar org-timegrid-org--edited-buffers nil
  "Buffers this calendar has edited, most recent first.")

(defun org-timegrid-org--note-edit ()
  "Remember the current buffer as the calendar's most recent edit.
Undo has to happen where the change landed, and only the backend knows
where that was."
  (setq org-timegrid-org--edited-buffers
        (cons (current-buffer)
              (seq-filter #'buffer-live-p
                          (delq (current-buffer)
                                org-timegrid-org--edited-buffers)))))

(defun org-timegrid-org--undo (continue redo)
  "Undo, or REDO, the calendar's most recent Org edit.
CONTINUE means this call extends an unbroken run of them, so the source
buffer keeps walking back through its own undo history instead of
undoing the previous undo.  Each calendar edit is bracketed by
`undo-boundary', so one press is one edit."
  (setq org-timegrid-org--edited-buffers
        (seq-filter #'buffer-live-p org-timegrid-org--edited-buffers))
  (let ((buffer (car org-timegrid-org--edited-buffers)))
    (unless buffer
      (user-error "The calendar has made no edit to undo"))
    (with-current-buffer buffer
      (when buffer-read-only
        (user-error "%s is read-only" (buffer-name)))
      ;; Contain `undo's own `this-command' assignment: the run is tracked
      ;; by the caller's command, which must survive this call.
      (let ((last-command (and continue 'undo))
            (this-command this-command))
        (if redo (undo-redo) (undo))))))

(defun org-timegrid-org--remove-entry (event)
  "Delete the whole Org heading that owned EVENT.
Its timestamp has already gone by the time this runs, so the marker is
the only identity left to check."
  (let ((marker (plist-get (org-timegrid-event-source event) :marker)))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "The Org source marker is no longer live"))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (when buffer-read-only
         (user-error "The source Org buffer is read-only"))
       (goto-char marker)
       (org-back-to-heading t)
       (undo-boundary)
       (delete-region (point)
                      (save-excursion (org-end-of-subtree t t) (point)))
       (undo-boundary))
      (org-timegrid-org--note-edit))
    (message "Deleted %s" (org-timegrid-event-title event))))

(defun org-timegrid-org--timestamp-at-marker (marker)
  "Return the Org timestamp element at MARKER, or signal an error."
  (unless (and (markerp marker) (marker-buffer marker))
    (user-error "The source timestamp marker is no longer live"))
  (with-current-buffer (marker-buffer marker)
    (save-restriction
      (widen)
      (goto-char marker)
      (let ((element (or (org-element-timestamp-parser)
                         (org-element-context))))
        (unless (eq (org-element-type element) 'timestamp)
          (user-error "The source timestamp changed; refresh the calendar"))
        element))))

(defun org-timegrid-org--put-endpoint
    (timestamp endpoint absolute-minute)
  "Set TIMESTAMP ENDPOINT from ABSOLUTE-MINUTE.
ENDPOINT is the symbol `start' or `end'."
  (let* ((absolute-day (floor absolute-minute 1440))
         (minute-of-day (% absolute-minute 1440))
         (date (calendar-gregorian-from-absolute absolute-day))
         (suffix (symbol-name endpoint)))
    (org-element-put-property
     timestamp (intern (format ":year-%s" suffix)) (nth 2 date))
    (org-element-put-property
     timestamp (intern (format ":month-%s" suffix)) (nth 0 date))
    (org-element-put-property
     timestamp (intern (format ":day-%s" suffix)) (nth 1 date))
    (org-element-put-property
     timestamp (intern (format ":hour-%s" suffix)) (/ minute-of-day 60))
    (org-element-put-property
     timestamp (intern (format ":minute-%s" suffix)) (% minute-of-day 60))))

(defun org-timegrid-org--rewrite-timestamp
    (timestamp start end)
  "Return TIMESTAMP rewritten to absolute START and END minutes."
  (let ((copy (copy-tree timestamp)))
    (org-element-put-property copy :type 'active-range)
    (org-element-put-property
     copy :range-type
     (if (= (floor start 1440) (floor end 1440))
         'timerange
       'daterange))
    (org-timegrid-org--put-endpoint copy 'start start)
    (org-timegrid-org--put-endpoint copy 'end end)
    (org-element-interpret-data copy)))

(defun org-timegrid-org--validate-event-source (event timestamp)
  "Ensure TIMESTAMP still matches the source represented by EVENT."
  (let ((expected (plist-get (org-timegrid-event-metadata event)
                             :raw-value))
        (actual (org-element-property :raw-value timestamp)))
    (unless (equal expected actual)
      (user-error "The source timestamp changed; refresh the calendar"))))

(defun org-timegrid-org--rename-heading (marker title)
  "Rename the Org heading owning MARKER to TITLE."
  (with-current-buffer (marker-buffer marker)
    (org-with-wide-buffer
     (goto-char marker)
     (org-back-to-heading t)
     (org-edit-headline title))))

(defun org-timegrid-org--update-event-range
    (event start end &optional title)
  "Update EVENT to absolute range START through END and optional TITLE."
  (let* ((source (org-timegrid-event-source event))
         (marker (plist-get source :marker))
         (timestamp (org-timegrid-org--timestamp-at-marker marker)))
    (org-timegrid-org--validate-event-source event timestamp)
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (when buffer-read-only
         (user-error "The source Org buffer is read-only"))
       (undo-boundary)
       (atomic-change-group
         (let* ((base-start
                 (org-timegrid-org--timestamp-minutes timestamp nil))
                (occurrence-start (org-timegrid-event-start event))
                (new-base-start (+ base-start (- start occurrence-start)))
                (new-base-end (+ new-base-start (- end start)))
                (replacement
                 (org-timegrid-org--rewrite-timestamp
                  timestamp new-base-start new-base-end)))
           (goto-char (org-element-property :begin timestamp))
           (delete-region (org-element-property :begin timestamp)
                          (org-element-property :end timestamp))
           (insert replacement))
         (when title
           (org-timegrid-org--rename-heading marker title)))
       (undo-boundary))
      (org-timegrid-org--note-edit))
    (message "%s %s" (if title "Renamed" "Retimed")
             (org-timegrid-event-title event))))

(defun org-timegrid-org--timestamp-region (timestamp kind)
  "Return the region to delete for TIMESTAMP of KIND as a cons cell.
The three kinds differ in one respect only: a SCHEDULED or DEADLINE value
takes its keyword with it, because a planning line whose timestamp is
gone plans nothing.  Everything after this point treats them alike."
  (let ((begin (org-element-property :begin timestamp))
        (end (org-element-property :end timestamp)))
    (if (not (memq kind '(scheduled deadline)))
        (cons begin end)
      (save-excursion
        (goto-char begin)
        (let ((label (upcase (symbol-name kind))))
          (unless (and (re-search-backward (concat "\\_<" label ":[ \t]*")
                                           (line-beginning-position) t)
                       (= (match-end 0) begin))
            (user-error "The planning timestamp label changed"))
          (cons (match-beginning 0) end))))))

(defun org-timegrid-org--remove-event (event)
  "Remove EVENT's time from its Org heading, keeping the heading itself."
  (let* ((source (org-timegrid-event-source event))
         (marker (plist-get source :marker))
         (timestamp (org-timegrid-org--timestamp-at-marker marker)))
    (org-timegrid-org--validate-event-source event timestamp)
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (when buffer-read-only
         (user-error "The source Org buffer is read-only"))
       (undo-boundary)
       (atomic-change-group
         (let ((region (org-timegrid-org--timestamp-region
                        timestamp (plist-get source :kind))))
           (delete-region (car region) (cdr region))
           (goto-char (car region))
           ;; What is left behind belongs to neither the entry nor the
           ;; calendar: a gap between two values sharing a planning line,
           ;; or an empty line where the value stood alone.
           (when (looking-at "[ \t]\\{2,\\}")
             (replace-match " "))
           (when (save-excursion
                   (beginning-of-line)
                   (looking-at-p "[ \t]*$"))
             (delete-region (line-beginning-position)
                            (min (point-max) (1+ (line-end-position)))))))
       (undo-boundary))
      (org-timegrid-org--note-edit))
    (message "Untimed %s" (org-timegrid-event-title event))))

(defun org-timegrid-org--timestamp-timed-p (timestamp)
  "Return non-nil when TIMESTAMP carries a clock start time.
An endpoint is optional.  An entry timed 09:00 with no end is a real
plan, and hiding it made the calendar disagree with the file; it is shown
`org-timegrid-default-duration-minutes' long instead.  Date-only values
still have no place on a time grid."
  (and timestamp
       (memq (org-element-property :type timestamp)
             '(active active-range))
       (integerp (org-element-property :hour-start timestamp))
       (integerp (org-element-property :minute-start timestamp))))

(defun org-timegrid-org--timestamp-minutes (timestamp endp)
  "Return TIMESTAMP start or end as an absolute minute.
ENDP selects the endpoint.  A clock-only range whose endpoint is not later
than its start is treated as ending on the following day.  A timestamp
with no end time gets `org-timegrid-default-duration-minutes'."
  ;; A plain timestamp reports its end hour as a copy of its start, so
  ;; `range-type' is the only trustworthy sign that an end was written.
  (if (and endp (not (org-element-property :range-type timestamp)))
      (+ (org-timegrid-org--timestamp-minutes timestamp nil)
         org-timegrid-default-duration-minutes)
    (let* ((suffix (if endp "-end" "-start"))
           (year (or (org-element-property
                      (intern (format ":year%s" suffix)) timestamp)
                     (org-element-property :year-start timestamp)))
           (month (or (org-element-property
                       (intern (format ":month%s" suffix)) timestamp)
                      (org-element-property :month-start timestamp)))
           (day (or (org-element-property
                     (intern (format ":day%s" suffix)) timestamp)
                    (org-element-property :day-start timestamp)))
           (hour (org-element-property
                  (intern (format ":hour%s" suffix)) timestamp))
           (minute (org-element-property
                    (intern (format ":minute%s" suffix)) timestamp))
           (absolute
            (+ (* (calendar-absolute-from-gregorian (list month day year)) 1440)
               (* hour 60) minute)))
      (if endp
          (let ((start
                 (+ (* (calendar-absolute-from-gregorian
                        (list (org-element-property :month-start timestamp)
                              (org-element-property :day-start timestamp)
                              (org-element-property :year-start timestamp)))
                       1440)
                    (* (org-element-property :hour-start timestamp) 60)
                    (org-element-property :minute-start timestamp))))
            (if (<= absolute start) (+ absolute 1440) absolute))
        absolute))))

(defun org-timegrid-org--timestamp-position (headline timestamp)
  "Return TIMESTAMP's source position within HEADLINE."
  (or (org-element-property :begin timestamp)
      (let ((raw (org-element-property :raw-value timestamp)))
        (save-excursion
          (goto-char (org-element-property :begin headline))
          (when (search-forward raw (org-element-property :end headline) t)
            (match-beginning 0))))))

(defun org-timegrid-org--event-id (file position kind)
  "Build a stable-enough identity for FILE POSITION and KIND."
  (list file position kind))

(defun org-timegrid-org--event
    (file headline timestamp kind)
  "Create a calendar event for FILE HEADLINE TIMESTAMP of KIND."
  (let* ((todo (org-element-property :todo-keyword headline))
         (done (and todo (member todo org-done-keywords)))
         (begin (org-timegrid-org--timestamp-position
                 headline timestamp)))
    (unless begin
      (error "Cannot locate Org timestamp source for %s"
             (org-element-property :raw-value timestamp)))
    (org-timegrid-event-create
     :id (org-timegrid-org--event-id file begin kind)
     :title (or (org-element-property :raw-value headline) "Untitled")
     :start (org-timegrid-org--timestamp-minutes timestamp nil)
     :end (org-timegrid-org--timestamp-minutes timestamp t)
     :tags (org-element-property :tags headline)
     :state (if done 'done todo)
     :color (funcall org-timegrid-org-color-function headline)
     :source (list :file file :marker (copy-marker begin) :kind kind)
     :metadata
     (list :planning-type kind
           :raw-value (org-element-property :raw-value timestamp)
           :repeater-type (org-element-property :repeater-type timestamp)
           :repeater-value (org-element-property :repeater-value timestamp)
           :repeater-unit (org-element-property :repeater-unit timestamp)))))

(defun org-timegrid-org--add-months (absolute-minute months)
  "Add MONTHS to ABSOLUTE-MINUTE while preserving its wall-clock time."
  (let* ((absolute-day (floor absolute-minute 1440))
         (minute-of-day (% absolute-minute 1440))
         (date (calendar-gregorian-from-absolute absolute-day))
         (month-index (+ (* (nth 2 date) 12) (1- (nth 0 date)) months))
         (year (floor month-index 12))
         (month (1+ (% month-index 12)))
         (day (min (nth 1 date) (calendar-last-day-of-month month year))))
    (+ (* (calendar-absolute-from-gregorian (list month day year)) 1440)
       minute-of-day)))

(defun org-timegrid-org--next-repetition
    (absolute-minute value unit)
  "Advance ABSOLUTE-MINUTE by repeater VALUE and UNIT."
  (pcase unit
    ('hour (+ absolute-minute (* value 60)))
    ('day (+ absolute-minute (* value 1440)))
    ('week (+ absolute-minute (* value 7 1440)))
    ('month (org-timegrid-org--add-months absolute-minute value))
    ('year (org-timegrid-org--add-months absolute-minute (* value 12)))
    (_ (error "Unsupported Org repeater unit: %S" unit))))

(defun org-timegrid-org--expand-event (event query-start query-end)
  "Expand EVENT occurrences intersecting QUERY-START through QUERY-END."
  (let* ((metadata (org-timegrid-event-metadata event))
         (value (plist-get metadata :repeater-value))
         (unit (plist-get metadata :repeater-unit))
         (base-start (org-timegrid-event-start event))
         (duration (- (org-timegrid-event-end event) base-start)))
    (if (not (and (integerp value) (> value 0) unit))
        (and (< base-start query-end)
             (> (+ base-start duration) query-start)
             (list event))
      (let ((occurrence-start base-start)
            (iterations 0)
            occurrences)
        (while (and (< occurrence-start query-end)
                    (< iterations 100000))
          (when (> (+ occurrence-start duration) query-start)
            (let ((occurrence (copy-org-timegrid-event event)))
              (setf (org-timegrid-event-id occurrence)
                    (list (org-timegrid-event-id event)
                          occurrence-start)
                    (org-timegrid-event-start occurrence)
                    occurrence-start
                    (org-timegrid-event-end occurrence)
                    (+ occurrence-start duration)
                    (org-timegrid-event-metadata occurrence)
                    (plist-put (copy-sequence metadata)
                               :occurrence-start occurrence-start))
              (push occurrence occurrences)))
          (let ((next (org-timegrid-org--next-repetition
                       occurrence-start value unit)))
            (unless (> next occurrence-start)
              (error "Org repeater did not advance: %S" event))
            (setq occurrence-start next
                  iterations (1+ iterations))))
        (when (= iterations 100000)
          (error "Org repeater expansion exceeded safety limit"))
        (nreverse occurrences)))))

(defun org-timegrid-org--buffer-events (&optional file)
  "Extract explicit timed ranges from the current Org buffer.
FILE defaults to `buffer-file-name'."
  (let* ((file (or file buffer-file-name (buffer-name)))
         (tree (org-element-parse-buffer))
         events seen)
    (org-element-map tree 'headline
      (lambda (headline)
        (dolist (planning `((scheduled . ,(org-element-property
                                           :scheduled headline))
                            (deadline . ,(org-element-property
                                          :deadline headline))))
          (let ((timestamp (cdr planning)))
            (when (org-timegrid-org--timestamp-timed-p timestamp)
              (push (org-element-property :begin timestamp) seen)
              (push (org-timegrid-org--event
                     file headline timestamp (car planning))
                    events))))
        (let ((section
               (cl-find-if
                (lambda (element) (eq (org-element-type element) 'section))
                (org-element-contents headline))))
          (when section
            (org-element-map section 'timestamp
              (lambda (timestamp)
                (when (and
                       (org-timegrid-org--timestamp-timed-p timestamp)
                       (not (memq (org-element-property :begin timestamp) seen)))
                  (push (org-timegrid-org--event
                         file headline timestamp 'timestamp)
                        events))))))))
    (nreverse events)))

(defun org-timegrid-org--list-events (start end)
  "Return Org events intersecting absolute minutes START through END."
  (cl-loop for file in (org-timegrid-org--files)
           append
           (with-current-buffer (find-file-noselect file)
             (org-with-wide-buffer
              (mapcan (lambda (event)
                        (let ((metadata (org-timegrid-event-metadata event)))
                          (unless (and
                                   (not org-timegrid-org-show-repeaters)
                                   (plist-get metadata :repeater-type))
                            (org-timegrid-org--expand-event
                             event start end))))
                      (org-timegrid-org--buffer-events file))))))

(defun org-timegrid-org--visit-event (event)
  "Visit the Org heading that owns EVENT."
  (let* ((source (org-timegrid-event-source event))
         (marker (plist-get source :marker)))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "The Org source marker is no longer live"))
    (pop-to-buffer-same-window (marker-buffer marker))
    (goto-char marker)
    (org-back-to-heading t)
    (org-fold-show-context)))

(defun org-timegrid-org-selected-marker ()
  "Return the Org heading marker for the selected calendar block.
Signal a user error if no block is selected, its backend is not Org, or
its source entry is no longer available."
  (let* ((block (org-timegrid--selected-block))
         (event (plist-get block :event))
         (source (and event (org-timegrid-event-source event)))
         (marker (plist-get source :marker)))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "The selected block has no Org source entry"))
    marker))

(defvar org-timegrid-org-backend nil
  "Org backend used by the integrated Week view.")

(setq org-timegrid-org-backend
      (org-timegrid-backend-create
       :name "Org"
       :list-function #'org-timegrid-org--list-events
       :create-function #'org-timegrid-org--create-event
       :update-function #'org-timegrid-org--update-event-range
       :delete-function #'org-timegrid-org--remove-event
       :delete-entry-function #'org-timegrid-org--remove-entry
       :undo-function #'org-timegrid-org--undo
       :visit-function #'org-timegrid-org--visit-event
       :read-entry-function #'org-timegrid-org-read-entry
       :read-timestamp-function #'org-timegrid-org-read-timestamp))

(defun org-timegrid-org-read-timestamp (absolute-start duration)
  "Read a start, and possibly a duration, through the Org date prompt.
The prompt is prefilled from ABSOLUTE-START so accepting it costs one
key.  A typed time range such as `10:00-11:30' carries the duration, and
that is returned; otherwise the duration is nil and the caller asks for
it.  DURATION is unused because only a typed range can supply one here."
  (ignore duration)
  (let* ((day (floor absolute-start 1440))
         (minute (% absolute-start 1440))
         (date (calendar-gregorian-from-absolute day))
         (default-time (encode-time 0 (% minute 60) (/ minute 60)
                                    (nth 1 date) (nth 0 date) (nth 2 date)))
         (prefill (format-time-string "%Y-%m-%d %H:%M" default-time))
         (org-end-time-was-given nil)
         (answer (org-read-date t nil nil "Time" default-time prefill))
         (parsed (org-parse-time-string answer))
         (clock (+ (* 60 (nth 2 parsed)) (nth 1 parsed)))
         (start (+ (* 1440 (calendar-absolute-from-gregorian
                            (list (nth 4 parsed) (nth 3 parsed) (nth 5 parsed))))
                   clock))
         ;; `org-end-time-was-given' is how `org-schedule' picks up a typed
         ;; range, and it is the only reliable signal that one was given.
         (end (and (stringp org-end-time-was-given)
                   (string-match "\\([0-9]+\\):\\([0-9]+\\)"
                                 org-end-time-was-given)
                   (+ (* 60 (string-to-number
                             (match-string 1 org-end-time-was-given)))
                      (string-to-number
                       (match-string 2 org-end-time-was-given))))))
    (cons start (and end (> end clock) (- end clock)))))

;;;###autoload
(defun org-timegrid-week (&optional absolute-date)
  "Open the Org-backed week containing ABSOLUTE-DATE."
  (interactive)
  (org-timegrid-open org-timegrid-org-backend absolute-date))

(provide 'org-timegrid-org)
;;; org-timegrid-org.el ends here
