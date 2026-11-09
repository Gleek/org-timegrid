;;; org-timegrid-android.el --- Android support for org-timegrid -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad
;; Author: Umar Ahmad <Gleek@users.noreply.github.com>
;; Assisted-by: Codex:gpt-5.6-sol
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

;; Android Emacs's bundled librsvg cannot render SVG text elements.  Render
;; text using pre-generated Noto Sans outlines while leaving other platforms
;; untouched.

;;; Code:

(require 'org-timegrid)
(require 'org-timegrid-android-font)

(defvar touch-screen-current-tool)
(defvar touch-screen-current-timer)
(defvar touch-screen-display-keyboard)
(defvar touch-screen-keyboard-function)
(defvar android-keyboard-bell-duration)

(defcustom org-timegrid-android-haptic-duration 60
  "Vibration duration in milliseconds when a calendar long press is ready.
Use a value between 10 and 1000, or nil to disable feedback."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'org-timegrid)

(defvar org-timegrid-android-scroll-scale 0.65
  "Scale physical Android touch pixels into calendar SVG pixels.")

(defcustom org-timegrid-android-zoom 1.5
  "Calendar zoom used on Android."
  :type 'number
  :group 'org-timegrid)

(defcustom org-timegrid-android-display-keyboard nil
  "Whether to display Android's on-screen keyboard in timegrid buffers.
Enable this to use keyboard commands that have no touch gesture."
  :type 'boolean
  :group 'org-timegrid)

(defvar org-timegrid-android-header-title-style
  '(:font-size 78 :character-width 47 :height 122 :baseline 86)
  "Month and year title geometry used on Android.")

(defvar org-timegrid-android-single-day-label-style
  '(:scale 0.85 :x-offset 2 :gap 8)
  "Weekday and date label geometry used on Android.")

(defun org-timegrid-android--draw-text (svg text &rest args)
  "Draw TEXT into SVG using the bundled Noto Sans outlines."
  (let* ((size (float (or (plist-get args :font-size) 10)))
         (scale (/ size org-timegrid-android-font-units-per-em))
         (weight (plist-get args :font-weight))
         (weight (if (stringp weight) (string-to-number weight) (or weight 400)))
         (font (if (>= weight 500)
                   org-timegrid-android-font-bold
                 org-timegrid-android-font-regular))
         (fallback (assq ?? font))
         (glyphs (mapcar (lambda (character)
                           (or (assq character font) fallback))
                         (string-to-list text)))
         (small-period (plist-get args :small-period))
         (width (* scale (cl-loop for glyph in glyphs
                                  sum (* (cadr glyph)
                                         (if (and small-period
                                                  (memq (car glyph) '(?A ?P ?M)))
                                             0.8 1)))))
         (anchor (plist-get args :text-anchor))
         (x (float (or (plist-get args :x) 0)))
         (y (float (or (plist-get args :y) size)))
         (x (cond ((equal anchor "middle") (- x (/ width 2)))
                  ((equal anchor "end") (- x width))
                  (t x)))
         (outer (if-let* ((clip-path (plist-get args :clip-path)))
                    (svg-node svg 'g :clip-path clip-path)
                  svg))
         (group (svg-node
                 outer 'g
                 :transform (format "translate(%g %g) scale(%g %g)"
                                    x y scale (- scale))
                 :fill (or (plist-get args :fill) "currentColor")
                 :fill-opacity (or (plist-get args :fill-opacity) 1))))
    (let ((offset 0))
      (dolist (glyph glyphs)
        (let ((size (if (and small-period (memq (car glyph) '(?A ?P ?M))) 0.8 1)))
          (unless (string-empty-p (caddr glyph))
            (svg-node group 'path :d (caddr glyph)
                      :transform (format "translate(%g 0) scale(%g)" offset size)))
          (setq offset (+ offset (* size (cadr glyph)))))))))

(defun org-timegrid-android-scroll (event)
  "Scroll the calendar by the native pixel delta in touch EVENT."
  (interactive "e")
  (let ((window (nth 1 event))
        (dy (nth 3 event)))
    (when (and (window-live-p window) (numberp dy))
      (let* ((scaled (* dy org-timegrid-android-scroll-scale))
             ;; Filter discontinuities between native touch samples.
             (step (max -48 (min 48 scaled))))
        ;; Wheel devices can emit a short opposite-direction rebound at an
        ;; edge.  A finger reversing at 23:00 is intentional, so never carry
        ;; that wheel-only suppression state into an Android touch update.
        (with-current-buffer (window-buffer window)
          (setq-local org-timegrid--scroll-boundary nil))
        (org-timegrid-scroll step window)))))

(defun org-timegrid-android--proposal (origin target)
  "Build a touch edit proposal between calendar ORIGIN and TARGET."
  (let ((proposal
         (if (and (eq (plist-get origin :surface) 'rail)
           (null (plist-get origin :block-id)))
      (if (eq (plist-get target :surface) 'rail)
          (org-timegrid--all-day-create-proposal origin target)
        (org-timegrid--operation-create :error "Release inside an all-day cell"))
    (org-timegrid--proposal origin target nil))))
    (setf (org-timegrid--operation-handle proposal)
          (and (plist-get origin :edge)
               (eq (org-timegrid--operation-kind proposal) 'resize)))
    proposal))

(defun org-timegrid-android--drag-update (event data)
  "Update the calendar preview from raw touchscreen EVENT and DATA."
  (aset data 2 nil)
  (when-let* ((tool (assq (aref data 0) (cadr event)))
              (position (cdr tool))
              (window (posn-window position))
              ((window-live-p window)))
    (aset data 2 (org-timegrid--mouse-target position)))
  (if (aref data 2)
      (org-timegrid--set-preview
       (org-timegrid-android--proposal (aref data 1) (aref data 2)))
    (org-timegrid--clear-preview)))

(defun org-timegrid-android--haptic-feedback ()
  "Vibrate briefly to signal that a calendar touch action is ready."
  (when (and (eq window-system 'android) org-timegrid-android-haptic-duration)
    (let ((android-keyboard-bell-duration org-timegrid-android-haptic-duration)
          (ring-bell-function nil)
          (visible-bell nil))
      (ding t))))

(defun org-timegrid-android-long-press (event)
  "Create, move, or resize a block using a held touch EVENT."
  (interactive "e")
  (let* ((position (cadr event))
         (window (posn-window position))
         (tool-id (car-safe touch-screen-current-tool))
         (start-position (nth 4 touch-screen-current-tool)))
    (when (and tool-id start-position (window-live-p window))
      (with-selected-window window
        (let* ((origin (org-timegrid--mouse-target position))
               (data (vector tool-id origin origin))
               (start-event
                (list 'touchscreen-begin (cons tool-id start-position))))
          (when origin
            (unwind-protect
                (let ((result
                       (org-timegrid--with-gesture origin
                         (when (plist-get origin :edge)
                           (org-timegrid--set-preview
                            (org-timegrid-android--proposal origin origin))
                           (redisplay t))
                         (org-timegrid-android--haptic-feedback)
                         (funcall (intern "touch-screen-track-drag") start-event
                                  #'org-timegrid-android--drag-update data))))
                  (cond
                   ((eq result t)
                    (org-timegrid--apply
                     (org-timegrid-android--proposal origin (aref data 2))))
                   ((eq result 'no-drag)
                    (org-timegrid--clear-preview)
                    (org-timegrid-context-menu (list 'mouse-3 position)))))
              (setq touch-screen-current-tool nil touch-screen-current-timer nil)
              (org-timegrid--clear-preview))))))))

(defun org-timegrid-android--configure-buffer ()
  "Apply the one-day touch layout without maintaining a second renderer."
  (setq-local echo-keystrokes 0
              touch-screen-display-keyboard
              org-timegrid-android-display-keyboard
              touch-screen-keyboard-function
              (unless org-timegrid-android-display-keyboard (lambda () nil))
              org-timegrid-days 1
              org-timegrid--resize-pixels 24
              org-timegrid--resize-slop 10
              org-timegrid-default-zoom org-timegrid-android-zoom
              org-timegrid-header-title-style
              org-timegrid-android-header-title-style
              org-timegrid-single-day-label-style
              org-timegrid-android-single-day-label-style))

(defun org-timegrid-android--configure-date-picker ()
  "Give the existing Org date picker reliable touch hit-testing."
  (buffer-face-set '(:family "monospace" :height 140)))

(defun org-timegrid-android--plain-tile-image-map (&rest _)
  "Return no SVG hotspot map so Android receives uniform touch events."
  nil)

(defun org-timegrid-android--grid-palette (palette)
  "Make grid lines in PALETTE readable on a phone screen."
  (let ((foreground (plist-get palette :foreground))
        (background (plist-get palette :background)))
    (plist-put palette :grid (org-timegrid--blend foreground background 0.30))
    (plist-put palette :half-grid (org-timegrid--blend foreground background 0.16))
    (plist-put palette :grid-width 2)))

(defun org-timegrid-android--install-touch-bindings ()
  "Prefer native scrolling over desktop press-and-drag gestures."
  (dolist (key '([down-mouse-1] [s-down-mouse-1] [S-down-mouse-1]
                 [header-line down-mouse-1]
                 [header-line s-down-mouse-1]
                 [header-line S-down-mouse-1]
                 [calendar-block down-mouse-1]
                 [calendar-block s-down-mouse-1]
                 [calendar-block S-down-mouse-1]
                 [calendar-resize down-mouse-1]
                 [calendar-resize s-down-mouse-1]
                 [calendar-resize S-down-mouse-1]))
    (define-key org-timegrid-mode-map key nil))
  (dolist (key '([down-mouse-1] [header-line down-mouse-1]
                 [calendar-rail-block down-mouse-1]
                 [calendar-rail-resize down-mouse-1]))
    (define-key org-timegrid--header-map key nil))
  (define-key org-timegrid-mode-map [touchscreen-scroll]
              #'org-timegrid-android-scroll)
  (define-key org-timegrid-mode-map [touchscreen-hold]
              #'org-timegrid-android-long-press)
  (dolist (area '(calendar-block calendar-resize))
    (define-key org-timegrid-mode-map (vector area 'touchscreen-scroll)
                #'org-timegrid-android-scroll)
    (define-key org-timegrid-mode-map (vector area 'touchscreen-hold)
                #'org-timegrid-android-long-press))
  (dolist (area '(header-line calendar-rail-block calendar-rail-resize))
    (define-key org-timegrid--header-map (vector area 'touchscreen-scroll)
                #'org-timegrid-android-scroll)
    (define-key org-timegrid--header-map (vector area 'touchscreen-hold)
                #'org-timegrid-android-long-press))
  (add-hook 'org-timegrid-mode-hook #'org-timegrid-android--configure-buffer)
  (when-let* ((buffer (get-buffer "*Org Time Grid*")))
    (with-current-buffer buffer
      (org-timegrid-android--configure-buffer))))

(advice-remove 'org-timegrid--draw-text
               #'org-timegrid-android--draw-text)

(when (eq system-type 'android)
  ;; Touch support is built into recent Android Emacs, but is absent from
  ;; supported desktop Emacs 29.  Load it only on the platform that uses it.
  (or (featurep 'touch-screen) (load "touch-screen" nil t))
  (advice-add 'org-timegrid--draw-text :override
              #'org-timegrid-android--draw-text)
  (advice-remove 'org-timegrid--palette #'org-timegrid-android--grid-palette)
  (advice-add 'org-timegrid--face-palette :filter-return
              #'org-timegrid-android--grid-palette)
  (add-hook 'org-timegrid-calendar-setup-hook
            #'org-timegrid-android--configure-date-picker)
  (when (fboundp (intern "touch-screen-track-drag"))
    (org-timegrid-android--install-touch-bindings))
  (advice-remove 'org-timegrid--tile-image-map
                 #'org-timegrid-android--plain-tile-image-map)
  (advice-add 'org-timegrid--tile-image-map :override
              #'org-timegrid-android--plain-tile-image-map))

(provide 'org-timegrid-android)
;;; org-timegrid-android.el ends here
