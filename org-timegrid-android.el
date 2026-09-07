;;; org-timegrid-android.el --- Android support for org-timegrid -*- lexical-binding: t; -*-

;; Android Emacs's bundled librsvg cannot render SVG text elements.  Render
;; text using pre-generated Noto Sans outlines while leaving other platforms
;; untouched.

(require 'org-timegrid)
(require 'org-timegrid-android-font)

(defvar touch-screen-current-tool)
(defvar touch-screen-current-timer)
(defvar touch-screen-display-keyboard)
(defvar touch-screen-keyboard-function)

(defcustom org-timegrid-android-scroll-scale 0.65
  "Scale physical Android touch pixels into calendar SVG pixels."
  :type 'number
  :group 'org-timegrid)

(defcustom org-timegrid-android-scroll-max-step 48
  "Largest pixel step accepted from one Android touch update.
This filters occasional discontinuities when Android changes touch samples."
  :type 'number
  :group 'org-timegrid)

(defcustom org-timegrid-android-zoom 1.5
  "Calendar zoom used on Android."
  :type 'number
  :group 'org-timegrid)

(defcustom org-timegrid-android-display-keyboard nil
  "Whether to display Android's on-screen keyboard in timegrid buffers.
Enable this to use keyboard commands that have no touch gesture."
  :type 'boolean
  :group 'org-timegrid)

(defcustom org-timegrid-android-header-title-style
  '(:font-size 78 :character-width 47 :height 122 :baseline 86)
  "Month and year title geometry used on Android."
  :type 'plist
  :group 'org-timegrid)

(defcustom org-timegrid-android-single-day-label-style
  '(:scale 0.85 :x-offset 2 :gap 8)
  "Weekday and date label geometry used on Android."
  :type 'plist
  :group 'org-timegrid)

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
         (width (* scale (apply #'+ (mapcar #'cadr glyphs))))
         (anchor (plist-get args :text-anchor))
         (x (float (or (plist-get args :x) 0)))
         (y (float (or (plist-get args :y) size)))
         (x (cond ((equal anchor "middle") (- x (/ width 2)))
                  ((equal anchor "end") (- x width))
                  (t x)))
         (outer (if-let ((clip-path (plist-get args :clip-path)))
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
        (unless (string-empty-p (caddr glyph))
          (svg-node group 'path :d (caddr glyph)
                    :transform (format "translate(%d 0)" offset)))
        (setq offset (+ offset (cadr glyph)))))))

(defun org-timegrid-android-scroll (event)
  "Scroll the calendar by the native pixel delta in touch EVENT."
  (interactive "e")
  (let ((window (nth 1 event))
        (dy (nth 3 event)))
    (when (and (window-live-p window) (numberp dy))
      (let* ((scaled (* dy org-timegrid-android-scroll-scale))
             (step (max (- org-timegrid-android-scroll-max-step)
                        (min org-timegrid-android-scroll-max-step scaled))))
        ;; Wheel devices can emit a short opposite-direction rebound at an
        ;; edge.  A finger reversing at 23:00 is intentional, so never carry
        ;; that wheel-only suppression state into an Android touch update.
        (with-current-buffer (window-buffer window)
          (setq-local org-timegrid--scroll-boundary nil))
        (org-timegrid-scroll step window)))))

(defun org-timegrid-android--drag-update (event data)
  "Update the calendar preview from raw touchscreen EVENT and DATA."
  (when-let* ((tool (assq (aref data 0) (cadr event)))
              (position (cdr tool))
              (window (posn-window position))
              ((window-live-p window)))
    (with-selected-window window
      (when-let ((target (org-timegrid--target position)))
        (aset data 2 target)
        (org-timegrid--set-preview
         (org-timegrid--proposal (aref data 1) target nil))))))

(defun org-timegrid-android-long-press (event)
  "Create, move, or resize a block using a held touch EVENT."
  (interactive "e")
  (let* ((position (cadr event))
         (window (posn-window position))
         (tool-id (car-safe touch-screen-current-tool))
         (start-position (nth 4 touch-screen-current-tool)))
    (when (and tool-id start-position (window-live-p window))
      (with-selected-window window
        (let* ((origin (org-timegrid--target position))
               (data (vector tool-id origin origin))
               (start-event
                (list 'touchscreen-begin (cons tool-id start-position)))
               result)
          (when origin
            (unwind-protect
                (setq result
                      (funcall (intern "touch-screen-track-drag")
                               start-event
                               #'org-timegrid-android--drag-update data))
              (setq touch-screen-current-tool nil
                    touch-screen-current-timer nil))
            (cond
             ((eq result t)
              (org-timegrid--apply
               (org-timegrid--proposal origin (aref data 2) nil)))
             ((eq result 'no-drag)
              (org-timegrid-context-menu (list 'mouse-3 position)))
             (t (org-timegrid--clear-preview)))))))))

(defun org-timegrid-android--configure-buffer ()
  "Apply the one-day touch layout without maintaining a second renderer."
  (setq-local touch-screen-display-keyboard
              org-timegrid-android-display-keyboard
              touch-screen-keyboard-function
              (unless org-timegrid-android-display-keyboard (lambda () nil))
              org-timegrid-days 1
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
                #'org-timegrid-android-scroll))
  (add-hook 'org-timegrid-mode-hook #'org-timegrid-android--configure-buffer)
  (when-let ((buffer (get-buffer org-timegrid-buffer-name)))
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
