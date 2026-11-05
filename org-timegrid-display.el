;;; org-timegrid-display.el --- Display runtime for org-timegrid -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The sole owner of image caches, tile damage, display updates and timers.

;;; Code:

(require 'org-timegrid-scene)
(require 'face-remap)
(require 'org-timegrid-svg)

(defvar org-timegrid-preview-prefetch)
(defvar org-timegrid-data-refresh-seconds)
(defvar org-timegrid--backend)
(defvar org-timegrid--header-map)
(defvar org-timegrid--pointer-overlay)
(defvar org-timegrid--keyboard-edit-timer)
(defvar org-timegrid--fringe-remap-cookie)

(declare-function org-timegrid--load-state "org-timegrid" (week-start))
(declare-function org-timegrid--reload-state "org-timegrid" (week-start &optional state))
(declare-function org-timegrid--ensure-state "org-timegrid" ())

(defvar-local org-timegrid--palette-cache nil
  "One resolved face-color key and its derived drawing palette.")

(defvar-local org-timegrid--displayed-context nil
  "Inputs of the frame currently presented to the user; shared with hit testing.")

(defun org-timegrid--display-context ()
  "Return the input contract for interpreting positions in the displayed calendar."
  (or org-timegrid--displayed-context (org-timegrid--capture-context)))

(defvar-local org-timegrid--geometry nil)

(defvar-local org-timegrid--header-geometry nil)

(defvar-local org-timegrid--image-height nil)

(defvar-local org-timegrid--last-width nil)

(defvar-local org-timegrid--resize-timer nil)

(defvar-local org-timegrid--clock-timer nil)

(defvar-local org-timegrid--data-timer nil)

(defvar-local org-timegrid--scroll-restore-timer nil)

(defvar-local org-timegrid--stale nil)

(defvar-local org-timegrid--saved-vscroll 0
  "Pixel scroll position restored when this calendar is shown again.")

(defvar-local org-timegrid--last-zoom-factor 1.0
  "Zoom factor used by the currently rendered SVG tiles.")

(defvar-local org-timegrid--tile-columns 1)

(defvar-local org-timegrid--tile-column-bounds nil)

(defvar-local org-timegrid--hotspots nil)

(defvar-local org-timegrid--static-fragments nil)

(defvar-local org-timegrid--block-fragments nil)

(defvar-local org-timegrid--scene nil)

(defvar-local org-timegrid--excluded-tiles nil)

(defvar-local org-timegrid--transient-images nil)

(defvar-local org-timegrid--pending-image-flush nil
  "Displayed images to flush again after their buffer contents are replaced.")

(defvar-local org-timegrid--tile-height nil)

(defvar-local org-timegrid--tile-count nil)

(defvar-local org-timegrid--tile-width nil)

(defvar-local org-timegrid--tile-markers nil)

(defvar-local org-timegrid--static-inner nil)

(defvar-local org-timegrid--static-images nil)

(defvar-local org-timegrid--dynamic-tiles nil)

(defvar-local org-timegrid--clock-fragment nil)

(defvar-local org-timegrid--clock-tiles nil)

(defvar-local org-timegrid--base-excluded-id nil)

(defvar org-timegrid--theme-timer nil)

(defvar org-timegrid--image-flush-context nil
  "Active flush batch: a changed flag followed by visible calendar frames.")

(defmacro org-timegrid--with-image-flush (&rest body)
  "Run BODY, redrawing secondary frames once after any image flushes."
  (declare (indent 0) (debug t))
  `(if org-timegrid--image-flush-context
       (progn ,@body)
     (let ((org-timegrid--image-flush-context
            (cons nil (delete-dups
                       (mapcar #'window-frame
                               (get-buffer-window-list (current-buffer) nil 'visible))))))
       (unwind-protect (progn ,@body)
         (when (car org-timegrid--image-flush-context)
           (mapc #'redraw-frame (cddr org-timegrid--image-flush-context)))))))

(defmacro org-timegrid--with-update (view &rest body)
  "Apply BODY's state changes with VIEW through `org-timegrid--update'."
  (declare (indent 1) (debug t))
  `(org-timegrid--update (lambda () ,@body) ,view))

(defvar-local org-timegrid--view-cache nil)

(defvar-local org-timegrid--view-cache-context nil)

(defvar-local org-timegrid--prewarm-timer nil)

(defvar-local org-timegrid--prewarm-images nil)

(defvar-local org-timegrid--prewarm-view nil)

(defvar-local org-timegrid--preview-cache nil)

(defvar-local org-timegrid--preview-images nil
  "Images owned by the preview cache, with value t or `decoded'.")

(defvar-local org-timegrid--preview-order nil)

(defvar-local org-timegrid--preview-context nil)

(defvar-local org-timegrid--preview-candidates nil)

(defvar-local org-timegrid--preview-jobs nil)

(defvar-local org-timegrid--preview-timer nil)

(defconst org-timegrid--preview-cache-limit 128)

(defconst org-timegrid--view-fields
  '(org-timegrid--static-inner org-timegrid--static-fragments org-timegrid--block-fragments
                               org-timegrid--static-images org-timegrid--geometry org-timegrid--image-height
                               org-timegrid--tile-columns org-timegrid--tile-column-bounds org-timegrid--hotspots
                               org-timegrid--tile-width org-timegrid--tile-height
                               org-timegrid--tile-count org-timegrid--base-excluded-id
                               org-timegrid--clock-fragment org-timegrid--clock-tiles))

(cl-defstruct (org-timegrid--cached-view
               (:constructor org-timegrid--cached-view-create))
  key fields header header-key header-geometry warm)

(defvar-local org-timegrid--all-day-layout-cache nil)

(defvar org-timegrid--update-context nil
  "Dynamically bound owner buffer and viewport request for an update.")

(defvar org-timegrid--force-data-refresh nil)

(defvar org-timegrid--cache-anchor nil)

(defun org-timegrid--capture-context ()
  "Capture every declared drawing input without retaining a window or buffer."
  (let ((org-timegrid--render-context nil))
    (org-timegrid--render-context-create
     :settings (mapcar (lambda (name) (cons name (copy-tree (symbol-value name))))
                       org-timegrid--style-variables)
     :width (org-timegrid--canvas-width) :zoom (org-timegrid--zoom-factor)
     :frame-scale (org-timegrid--frame-font-factor) :font (org-timegrid--font-family)
     :palette (org-timegrid--palette) :today (calendar-current-date)
     :header-offset (org-timegrid--header-left-offset (get-buffer-window (current-buffer) t))
     :minute (floor (float-time) 60))))

(defun org-timegrid-day-image (blocks start-minute end-minute width &optional now)
  "Return the read-only day strip for BLOCKS, sharing calendar drawing components."
  (let* ((org-timegrid-days 1)
         (context (org-timegrid--capture-context)))
    (org-timegrid-svg-image (org-timegrid-svg-render
                             (org-timegrid-scene-day blocks start-minute end-minute width now context))
                            :scale 1 :ascent 'center)))

(defun org-timegrid--update-clock-fragment ()
  "Ask the scene and SVG layers for the current-time overlay."
  (let* ((context (or org-timegrid--render-context (org-timegrid--capture-context)))
         (scene (org-timegrid-scene-clock org-timegrid--state context))
         (node (car (org-timegrid--scene-nodes scene))))
    (setq-local org-timegrid--clock-fragment (and node (org-timegrid-svg-render scene 'fragment))
                org-timegrid--clock-tiles (and node (org-timegrid--geometry-tiles (cdr node))))))

(defun org-timegrid--tile-bounds (tile)
  "Return TILE's (TOP . HEIGHT) inside the canvas, in canvas pixels.
The last tile takes whatever is left over.  A leftover of a few pixels
would still take a whole text line on screen, and that looks like a blank
band under the grid."
  (let* ((row (/ tile org-timegrid--tile-columns))
         (top (* row org-timegrid--tile-height))
         (lastp (>= row (1- (/ org-timegrid--tile-count org-timegrid--tile-columns))))
         (height (if lastp
                     (- org-timegrid--image-height top)
                   org-timegrid--tile-height)))
    (cons top (max 0 height))))

(defun org-timegrid--tile-at-pixel (pixel)
  "Return the first tile on the row containing canvas PIXEL."
  (when (and (numberp org-timegrid--tile-count) (> org-timegrid--tile-count 0))
    (* org-timegrid--tile-columns
       (min (1- (/ org-timegrid--tile-count org-timegrid--tile-columns))
            (floor (max 0 pixel) org-timegrid--tile-height)))))

(defun org-timegrid--tile-x-bounds (tile)
  "Return TILE's (LEFT . WIDTH) in integer canvas pixels."
  (cond
   (org-timegrid--tile-column-bounds
    (aref org-timegrid--tile-column-bounds (% tile org-timegrid--tile-columns)))
   ((= org-timegrid--tile-columns 1) (cons 0 org-timegrid--tile-width))
   (t
    (let* ((column (% tile org-timegrid--tile-columns))
           (label (org-timegrid--label-width))
           (width (org-timegrid--column-width))
           (left (if (zerop column) 0 (round (+ label (* (1- column) width)))))
           (right (if (= column (1- org-timegrid--tile-columns))
                      org-timegrid--tile-width
                    (round (+ label (* column width))))))
      (cons left (- right left))))))

(defun org-timegrid--tiles-intersecting (top bottom &optional left right)
  "Return tiles intersecting TOP, BOTTOM and optional LEFT, RIGHT."
  (let ((top (max 0 top))
        (bottom (min org-timegrid--image-height bottom))
        (last-row (1- (/ org-timegrid--tile-count org-timegrid--tile-columns))))
    (when (< top bottom)
      (let ((columns
             (cl-loop for column below org-timegrid--tile-columns
                      for bounds = (and left (org-timegrid--tile-x-bounds column))
                      when (or (null left) (and (< (car bounds) right)
                                                (< left (+ (car bounds) (cdr bounds)))))
                      collect column)))
        (cl-loop for row from (min last-row (floor top org-timegrid--tile-height))
                 to (min last-row (1- (ceiling bottom org-timegrid--tile-height)))
                 append (mapcar (lambda (column) (+ (* row org-timegrid--tile-columns) column))
                                columns))))))

(defun org-timegrid--tile-xml (tile &optional fragment)
  "Return TILE's prepared background with dynamic FRAGMENT above it."
  (pcase-let* ((`(,y . ,height) (org-timegrid--tile-bounds tile))
               (`(,x . ,width) (org-timegrid--tile-x-bounds tile)))
    (org-timegrid-svg-tile x y width height org-timegrid--static-inner
                           (and org-timegrid--static-fragments
                                (aref org-timegrid--static-fragments tile))
                           fragment)))

(defun org-timegrid--tile-image-map (tile &optional hotspots)
  "Return HOTSPOTS clipped and translated into TILE's coordinates."
  (pcase-let* ((`(,top . ,height) (org-timegrid--tile-bounds tile))
               (`(,x . ,width) (org-timegrid--tile-x-bounds tile))
               (bottom (+ top height)) (edge (+ x width))
               (translated nil))
    (dolist (entry (or hotspots org-timegrid--hotspots (org-timegrid--image-map)))
      (pcase-let ((`((rect . ((,left . ,y) . (,right . ,end))) ,id ,properties) entry))
        (when (and (< y bottom) (> end top) (< left edge) (> right x))
          (push (list `(rect . ((,(- (max left x) x) . ,(- (max y top) top))
                                . (,(- (min right edge) x) . ,(- (min end bottom) top))))
                      id properties) translated))))
    (nreverse translated)))

(defun org-timegrid--create-tile-image (tile &optional fragment hotspots)
  "Create TILE's image, adding optional dynamic SVG FRAGMENT.
Use HOTSPOTS as the image map when provided."
  (let ((map (org-timegrid--tile-image-map tile hotspots))
        ;; The current-time marker is calendar chrome, so paint it after
        ;; selection and preview fragments instead of letting those cover it.
        (fragment (concat fragment
                          (and (memq tile org-timegrid--clock-tiles)
                               org-timegrid--clock-fragment))))
    ;; Pass `:scale 1' like the header image does.  Without it Emacs scales
    ;; the tile by `image-scaling-factor', which is `char-width / 10' by
    ;; default.  The header would keep its size and the grid would not, so the
    ;; columns drift away from the day names.
    (apply #'org-timegrid-svg-image (org-timegrid--tile-xml tile fragment)
           :ascent 90 :scale 1 (and map (list :map map :original-map map)))))

(defun org-timegrid--clear-preview-cache ()
  "Cancel preparation and release this gesture's decoded images."
  (when (timerp org-timegrid--preview-timer)
    (cancel-timer org-timegrid--preview-timer))
  (when org-timegrid--preview-cache
    (org-timegrid--with-image-flush
      (maphash (lambda (_ image) (org-timegrid--flush-image image)) org-timegrid--preview-cache)))
  (setq org-timegrid--preview-cache nil org-timegrid--preview-images nil
        org-timegrid--preview-order nil
        org-timegrid--preview-context nil org-timegrid--preview-candidates nil
        org-timegrid--preview-jobs nil org-timegrid--preview-timer nil))

(defun org-timegrid--ensure-preview-cache ()
  "Keep prepared images only while the background and clock are unchanged."
  (unless (and (eq (car org-timegrid--preview-context) org-timegrid--static-images)
               (equal (cdr org-timegrid--preview-context) org-timegrid--clock-fragment)
               org-timegrid--preview-cache)
    (org-timegrid--clear-preview-cache)
    (setq org-timegrid--preview-context
          (cons org-timegrid--static-images org-timegrid--clock-fragment)
          org-timegrid--preview-cache (make-hash-table :test #'equal)
          org-timegrid--preview-images (make-hash-table :test #'equal))))

(defun org-timegrid--prefetch-block ()
  "Return the timed block being moved or resized, if prefetch is enabled."
  (when-let* ((org-timegrid-preview-prefetch)
              (org-timegrid--state)
              (preview (org-timegrid--calendar-state-preview org-timegrid--state))
              ((memq (org-timegrid--operation-kind preview) '(move resize)))
              (block (org-timegrid--operation-block preview))
              ((not (org-timegrid-block-all-day-p block))))
    block))

(defun org-timegrid--make-tile-image (tile &optional fragment hotspots)
  "Create TILE's image or reuse an image prepared for this preview."
  (if (not (and fragment (org-timegrid--prefetch-block)))
      (org-timegrid--create-tile-image tile fragment hotspots)
    (org-timegrid--ensure-preview-cache)
    (let* ((key (cons tile fragment)) (image (gethash key org-timegrid--preview-cache)))
      (unless image
        (setq image (org-timegrid--create-tile-image tile fragment hotspots))
        ;; Remove aliases in the normal recent cache before owning this image.
        (org-timegrid--retire-image nil image)
        (puthash key image org-timegrid--preview-cache)
        (puthash image t org-timegrid--preview-images))
      (setq org-timegrid--preview-order (cons key (delete key org-timegrid--preview-order)))
      (when (> (length org-timegrid--preview-order) org-timegrid--preview-cache-limit)
        (let* ((old-key (car (last org-timegrid--preview-order)))
               (old (gethash old-key org-timegrid--preview-cache)))
          (setq org-timegrid--preview-order (butlast org-timegrid--preview-order))
          (remhash old-key org-timegrid--preview-cache)
          (remhash old org-timegrid--preview-images)
          (unless (seq-some (lambda (marker) (equal old (get-text-property marker 'display)))
                            org-timegrid--tile-markers)
            (org-timegrid--flush-image old))))
      image)))

(defun org-timegrid--prepare-preview-next ()
  "Prepare one candidate's geometry or decode one visible image."
  (org-timegrid--ensure-preview-cache)
  (if org-timegrid--preview-jobs
      (let* ((key (pop org-timegrid--preview-jobs))
             (image (org-timegrid--make-tile-image (car key) (cdr key))))
        (image-size image t)
        (puthash image 'decoded org-timegrid--preview-images))
    (when org-timegrid--preview-candidates
      (let* ((scene (org-timegrid--build-scene (pop org-timegrid--preview-candidates)))
             (window (get-buffer-window (current-buffer) t))
             (top (org-timegrid--window-scroll-pixels window))
             (visible (org-timegrid--tiles-intersecting top (+ top (window-body-height window t)))))
        (pcase-let ((`(,fragment ,tiles ,changed) (org-timegrid--scene-patch scene)))
          (setq org-timegrid--preview-jobs
                (cl-loop for tile in tiles for key = (cons tile fragment)
                         when (and (memq tile visible) (memq tile changed)
                                   (not (eq (gethash (gethash key org-timegrid--preview-cache)
                                                     org-timegrid--preview-images) 'decoded)))
                         collect key)))))))

(defun org-timegrid--arm-preview-preparation ()
  "Yield between preparation steps and give pending input priority."
  (when (timerp org-timegrid--preview-timer) (cancel-timer org-timegrid--preview-timer))
  (when (or org-timegrid--preview-jobs org-timegrid--preview-candidates)
    (let ((buffer (current-buffer)))
      (setq org-timegrid--preview-timer
            (run-at-time
             0.001 nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq org-timegrid--preview-timer nil)
                   (if (and (get-buffer-window buffer t) (not org-timegrid--stale)
                            (org-timegrid--prefetch-block))
                       (progn
                         (unless (input-pending-p) (org-timegrid--prepare-preview-next))
                         (org-timegrid--arm-preview-preparation))
                     (org-timegrid--clear-preview-cache))))))))))

(defun org-timegrid--schedule-preview-preparation (old)
  "Prepare nearby snap positions after changing OLD preview."
  (if-let* ((block (org-timegrid--prefetch-block)))
      (let* ((preview (org-timegrid--calendar-state-preview org-timegrid--state))
             (edge (org-timegrid--operation-edge preview))
             (before (and old (equal (org-timegrid--operation-replace-id old)
                                     (org-timegrid--operation-replace-id preview))
                          (org-timegrid--operation-block old)))
             (minute (if (eq edge 'bottom) #'org-timegrid-block-end #'org-timegrid--block-absolute-start))
             (direction (cond ((and before (< (funcall minute block) (funcall minute before))) -1)
                              ((and before (> (funcall minute block) (funcall minute before))) 1)
                              ((eq edge 'top) -1) (t 1))))
        (org-timegrid--ensure-preview-cache)
        (setq org-timegrid--preview-jobs nil
              org-timegrid--preview-candidates
              (mapcar (lambda (offset)
                        (let ((candidate (org-timegrid--edit-proposal block
                                                                      (* direction offset org-timegrid-slot-minutes) 0 edge)))
                          (setf (org-timegrid--operation-handle candidate)
                                (org-timegrid--operation-handle preview))
                          candidate))
                      '(1 2 -1 3 -2 -3)))
        (org-timegrid--arm-preview-preparation))
    (org-timegrid--clear-preview-cache)))

(defun org-timegrid--retire-image (image &optional replacement)
  "Keep up to 32 recent transient IMAGEs, releasing older ones.
Remove REPLACEMENT's aliases so eviction cannot flush the next display."
  (setq org-timegrid--transient-images
        (cl-delete replacement org-timegrid--transient-images :test #'equal))
  (when (and image (not (equal image replacement))
             (not (and org-timegrid--preview-images
                       (gethash image org-timegrid--preview-images))))
    (setq org-timegrid--transient-images
          (cons image (cl-delete image org-timegrid--transient-images :test #'equal)))
    (when (> (length org-timegrid--transient-images) 32)
      (org-timegrid--flush-images (nthcdr 32 org-timegrid--transient-images))
      (setcdr (nthcdr 31 org-timegrid--transient-images) nil))))

(defun org-timegrid--flush-image (image)
  "Release IMAGE and invalidate every visible calendar frame."
  ;; `image-flush' only marks the frame that actually frees the image.
  ;; With shared caches, flushing all frames can mark a hidden frame first
  ;; and leave the calendar's glyphs referring to recycled image IDs.
  (org-timegrid--with-image-flush
    (setcar org-timegrid--image-flush-context t)
    (when-let* ((frame (cadr org-timegrid--image-flush-context)))
      (image-flush image frame))
    (image-flush image t)))

(defun org-timegrid--flush-images (images &optional header)
  "Release decoded IMAGES and HEADER from Emacs's native image cache."
  (org-timegrid--with-image-flush
    (mapc (lambda (image) (when image (org-timegrid--flush-image image))) images)
    (when-let* ((image (and (stringp header) (get-text-property 0 'display header))))
      (org-timegrid--flush-image image))))

(defun org-timegrid--flush-view (view)
  "Release decoded images belonging to cached VIEW."
  (org-timegrid--flush-images
   (cdr (assq 'org-timegrid--static-images (org-timegrid--cached-view-fields view)))
   (org-timegrid--cached-view-header view)))

(defun org-timegrid--clear-view-cache ()
  "Discard rendered views and their decoded images."
  (org-timegrid--with-image-flush
    (org-timegrid--clear-preview-cache)
    (dolist (tile org-timegrid--excluded-tiles)
      (org-timegrid--retire-image (aref org-timegrid--static-images tile)))
    (setq org-timegrid--excluded-tiles nil)
    (mapc #'org-timegrid--flush-view org-timegrid--view-cache)
    ;; Displayed images can outlive their cache entry, including rail previews.
    (setq org-timegrid--pending-image-flush
          (cons (and (stringp header-line-format) (get-text-property 0 'display header-line-format))
                (mapcar (lambda (marker) (get-text-property marker 'display))
                        org-timegrid--tile-markers)))
    (org-timegrid--flush-images
     (append org-timegrid--static-images org-timegrid--transient-images
             org-timegrid--pending-image-flush))
    (setq org-timegrid--view-cache nil org-timegrid--transient-images nil
          org-timegrid--prewarm-images nil org-timegrid--prewarm-view nil)))

(defun org-timegrid--view-key (&optional snapshot)
  "Return the current data key, invalidating incompatible display caches.
With SNAPSHOT, copy event records before retaining the key."
  (let* ((inputs (or org-timegrid--render-context (org-timegrid--capture-context)))
         ;; Current time has its own small overlay and never expires a whole view.
         (context (org-timegrid--context-key inputs)))
    (unless (equal context org-timegrid--view-cache-context)
      (org-timegrid--clear-view-cache)
      (setq org-timegrid--view-cache-context (copy-tree context)))
    (list org-timegrid--backend
          (org-timegrid--calendar-state-week-start org-timegrid--state)
          (if snapshot
              (mapcar #'org-timegrid-event-snapshot (org-timegrid--calendar-state-events org-timegrid--state))
            (org-timegrid--calendar-state-events org-timegrid--state)))))

(defun org-timegrid--cached-view ()
  "Find a rendered view matching the current dates and events."
  (let ((key (org-timegrid--view-key)))
    (seq-find (lambda (view) (equal key (org-timegrid--cached-view-key view)))
              org-timegrid--view-cache)))

(defun org-timegrid--cached-header ()
  "Reuse the sticky header when its all-day UI has not changed."
  (let* ((view (org-timegrid--cached-view))
         (context (or org-timegrid--render-context (org-timegrid--capture-context)))
         (scene (org-timegrid-scene-header
                 org-timegrid--state context
                 (org-timegrid--header-left-offset (get-buffer-window (current-buffer) t))))
         (key (copy-org-timegrid--scene scene)))
    (setf (org-timegrid--scene-context key) (org-timegrid--context-key context))
    (if (and view (org-timegrid--cached-view-header view)
             (equal key (org-timegrid--cached-view-header-key view)))
        (progn
          (setq org-timegrid--header-geometry (org-timegrid--cached-view-header-geometry view))
          (org-timegrid--cached-view-header view))
      (let ((header (org-timegrid--header scene)))
        (when view
          (when-let* ((old (org-timegrid--cached-view-header view)))
            (org-timegrid--retire-image (get-text-property 0 'display old)
                                        (get-text-property 0 'display header)))
          (setf (org-timegrid--cached-view-header view) header
                (org-timegrid--cached-view-header-key view) key
                (org-timegrid--cached-view-header-geometry view) org-timegrid--header-geometry))
        header))))

(defun org-timegrid--cache-static-tiles (&optional excluded-id)
  "Restore a nearby view, hiding EXCLUDED-ID without relaying out its neighbours."
  (dolist (tile org-timegrid--excluded-tiles)
    (org-timegrid--retire-image (aref org-timegrid--static-images tile)))
  (setq org-timegrid--excluded-tiles nil)
  (let ((view (org-timegrid--cached-view)))
    (unless view
      (org-timegrid--build-static-tiles)
      (let ((day (org-timegrid--calendar-state-week-start org-timegrid--state)))
        (setq org-timegrid--view-cache
              (cl-delete-if (lambda (old)
                              (when (= day (nth 1 (org-timegrid--cached-view-key old)))
                                (org-timegrid--flush-view old) t))
                            org-timegrid--view-cache)))
      (setq view (org-timegrid--cached-view-create :key (org-timegrid--view-key t)))
      (setf (org-timegrid--cached-view-fields view)
            (mapcar (lambda (name) (cons name (symbol-value name))) org-timegrid--view-fields))
      (push view org-timegrid--view-cache))
    (dolist (field (org-timegrid--cached-view-fields view)) (set (car field) (cdr field)))
    (let ((tiles org-timegrid--clock-tiles) (fragment org-timegrid--clock-fragment))
      (org-timegrid--update-clock-fragment)
      (unless (equal fragment org-timegrid--clock-fragment)
        (org-timegrid--with-image-flush
          (dolist (tile (delete-dups (append tiles org-timegrid--clock-tiles)))
            (org-timegrid--flush-image (aref org-timegrid--static-images tile))
            (aset org-timegrid--static-images tile (org-timegrid--make-tile-image tile))))))
    (setf (org-timegrid--cached-view-fields view)
          (mapcar (lambda (name) (cons name (symbol-value name))) org-timegrid--view-fields)))
  (when excluded-id
    ;; Keep neighbouring blocks steady during a drag.  Only cells occupied by
    ;; its source need a new background; the cached normal view stays intact.
    (setq org-timegrid--static-images (copy-sequence org-timegrid--static-images)
          org-timegrid--static-fragments (copy-sequence org-timegrid--static-fragments)
          org-timegrid--base-excluded-id excluded-id
          org-timegrid--geometry
          (cl-remove excluded-id org-timegrid--geometry :key (lambda (g) (plist-get g :id)) :test #'equal)
          org-timegrid--hotspots (org-timegrid--image-map))
    (let (changed)
      (dolist (fragment org-timegrid--block-fragments)
        (when (equal excluded-id (plist-get (car fragment) :id))
          (dolist (tile (org-timegrid--geometry-tiles (car fragment)))
            (aset org-timegrid--static-fragments tile
                  (string-replace (cdr fragment) "" (aref org-timegrid--static-fragments tile)))
            (cl-pushnew tile changed))))
      (dolist (tile changed)
        (aset org-timegrid--static-images tile (org-timegrid--make-tile-image tile)))
      (setq org-timegrid--excluded-tiles changed))))

(defun org-timegrid--prewarm-next ()
  "Prepare one view or decode one image without changing the calendar."
  (cond
   ((or org-timegrid--stale
        (org-timegrid--calendar-state-preview org-timegrid--state)))
   ((input-pending-p) (org-timegrid--schedule-prewarm))
   (org-timegrid--prewarm-images
    (image-size (pop org-timegrid--prewarm-images) t)
    (unless org-timegrid--prewarm-images
      (setf (org-timegrid--cached-view-warm org-timegrid--prewarm-view) t))
    (org-timegrid--schedule-prewarm))
   (t
    (let* ((anchor (org-timegrid--calendar-state-week-start org-timegrid--state))
           (offset
            (seq-find
             (lambda (offset)
               (not (seq-some
                     (lambda (view) (and (= (+ anchor offset) (nth 1 (org-timegrid--cached-view-key view)))
                                         (org-timegrid--cached-view-warm view)))
                     org-timegrid--view-cache)))
             '(1 -1 7 -7 2 -2 3 -3 4 -4 5 -5 6 -6 -8 -9 -10 -11 -12 -13 -14)))
           (fields (append '(org-timegrid--state org-timegrid--header-geometry
                                                 org-timegrid--all-day-layout-cache)
                           org-timegrid--view-fields)))
      (when offset
        (let ((org-timegrid--cache-anchor (* anchor 1440)))
          (cl-progv fields (mapcar #'symbol-value fields)
            (setq org-timegrid--state (org-timegrid--load-state (+ anchor offset)))
            (org-timegrid--cache-static-tiles)
            (let ((header (org-timegrid--cached-header))
                  (window (get-buffer-window (current-buffer) t)))
              (setq org-timegrid--prewarm-view (org-timegrid--cached-view)
                    org-timegrid--prewarm-images
                    (cons (get-text-property 0 'display header)
                          (mapcar (lambda (tile) (aref org-timegrid--static-images tile))
                                  (org-timegrid--tiles-intersecting
                                   0 (if window (window-body-height window t)
                                       org-timegrid--image-height))))))))
        (org-timegrid--schedule-prewarm))))))

(defun org-timegrid--schedule-prewarm ()
  "Bound the cache to two weeks back and one ahead; warm during idle time."
  (when (timerp org-timegrid--prewarm-timer) (cancel-timer org-timegrid--prewarm-timer))
  (let ((buffer (current-buffer))
        (anchor (org-timegrid--calendar-state-week-start org-timegrid--state)))
    (org-timegrid--with-image-flush
      (setq org-timegrid--view-cache
            (cl-delete-if
             (lambda (view)
               (let ((day (nth 1 (org-timegrid--cached-view-key view))))
                 (when (or (< day (- anchor 14)) (> day (+ anchor 7)))
                   (org-timegrid--flush-view view) t)))
             org-timegrid--view-cache)))
    (when (and org-timegrid--prewarm-images
               (not (memq org-timegrid--prewarm-view org-timegrid--view-cache)))
      (setq org-timegrid--prewarm-images nil org-timegrid--prewarm-view nil))
    (setq org-timegrid--prewarm-timer
          (run-with-idle-timer
           (time-add (or (current-idle-time) 0) (if org-timegrid--prewarm-images 0.01 0.25)) nil
           (lambda ()
             (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
               (with-current-buffer buffer
                 (setq org-timegrid--prewarm-timer nil)
                 (org-timegrid--prewarm-next))))))))

(defun org-timegrid--build-static-tiles ()
  "Prepare day/hour tiles from drawings that already carry bounds."
  (let ((org-timegrid--state (copy-org-timegrid--calendar-state org-timegrid--state)))
    (setf (org-timegrid--calendar-state-preview org-timegrid--state) nil)
    (setq org-timegrid--block-fragments nil)
    (let* ((context (or org-timegrid--render-context (org-timegrid--capture-context)))
           (scene (org-timegrid-scene-static org-timegrid--state context))
           (drawings (org-timegrid-svg-render scene 'fragments)))
      (setq org-timegrid--geometry (org-timegrid--scene-geometry scene)
            org-timegrid--image-height (org-timegrid--context-height context)
            org-timegrid--static-inner ""
            org-timegrid--tile-columns (1+ org-timegrid-days)
            org-timegrid--tile-width (org-timegrid--canvas-width)
            org-timegrid--tile-height (ceiling (* 60 (org-timegrid--pixels-per-minute)))
            org-timegrid--tile-count
            (* org-timegrid--tile-columns
               (max 1 (floor org-timegrid--image-height org-timegrid--tile-height)))
            org-timegrid--base-excluded-id nil
            org-timegrid--tile-column-bounds nil
            org-timegrid--tile-column-bounds
            (vconcat (cl-loop for column below org-timegrid--tile-columns
                              collect (org-timegrid--tile-x-bounds column)))
            org-timegrid--static-fragments (make-vector org-timegrid--tile-count nil))
      (dolist (drawing drawings)
        (let ((fragment (cdr drawing)))
          (when (plist-member (car drawing) :block)
            (push (cons (car drawing) fragment) org-timegrid--block-fragments))
          (dolist (tile (org-timegrid--geometry-tiles (car drawing)))
            (push fragment (aref org-timegrid--static-fragments tile)))))
      (dotimes (tile org-timegrid--tile-count)
        (aset org-timegrid--static-fragments tile
              (apply #'concat (nreverse (aref org-timegrid--static-fragments tile))))))
    (org-timegrid--update-clock-fragment)
    (setq org-timegrid--static-images (make-vector org-timegrid--tile-count nil)
          org-timegrid--hotspots (org-timegrid--image-map))
    (dotimes (tile org-timegrid--tile-count)
      (aset org-timegrid--static-images tile
            (org-timegrid--make-tile-image tile nil org-timegrid--hotspots)))))

(defun org-timegrid--geometry-tiles (geometry &optional margin)
  "Return tiles intersected by GEOMETRY and its visual MARGIN."
  (let ((margin (or margin (plist-get geometry :bleed) 0))
        (top (plist-get geometry :y)))
    (org-timegrid--tiles-intersecting
     (- top margin)
     (+ top (plist-get geometry :height) margin)
     (- (plist-get geometry :x) margin)
     (+ (plist-get geometry :x) (plist-get geometry :width) margin))))

(defun org-timegrid--build-scene (&optional proposal)
  "Build the interactive scene through the same contract used for static drawings."
  (org-timegrid-scene-build
   org-timegrid--state (or org-timegrid--render-context (org-timegrid--capture-context))
   (or (mapcar #'car org-timegrid--block-fragments) org-timegrid--geometry)
   org-timegrid--scene proposal))

(defun org-timegrid--scene-patch (scene)
  "Return SCENE's SVG fragment, occupied tiles and changed tiles.
Both live rendering and prefetch consume this same patch."
  (let (tiles)
    (dolist (node (org-timegrid--scene-nodes scene))
      (dolist (tile (org-timegrid--geometry-tiles
                     (cdr node)))
        (cl-pushnew tile tiles)))
    (list (org-timegrid-svg-render scene 'fragment) (sort tiles #'<)
          (delete-dups (mapcan #'org-timegrid--geometry-tiles
                               (org-timegrid--scene-damage org-timegrid--scene scene))))))

(defun org-timegrid--set-tile-image (tile image)
  "Display IMAGE at TILE's buffer marker."
  (let ((marker (aref org-timegrid--tile-markers tile))
        (inhibit-read-only t))
    (let ((old (get-text-property marker 'display)))
      (put-text-property marker (1+ marker) 'display image)
      (org-timegrid--retire-image
       (and old (not (eq old (aref org-timegrid--static-images tile))) old) image))))

(defun org-timegrid--render-dynamic ()
  "Apply the current scene's changed tiles without forcing redisplay."
  (let* ((preview (org-timegrid--calendar-state-preview org-timegrid--state))
         (excluded (and preview (org-timegrid--operation-replace-id preview))))
    (when (and (vectorp org-timegrid--tile-markers)
               (not (equal excluded org-timegrid--base-excluded-id)))
      (let* ((window (get-buffer-window (current-buffer) t))
             (scroll (and window
                          (org-timegrid--window-scroll-pixels window))))
        (org-timegrid--cache-static-tiles excluded)
        (org-timegrid--insert-tiles)
        (when window (org-timegrid--set-vscroll window scroll)))))
  (let ((scene (org-timegrid--build-scene)))
    (unless (equal scene org-timegrid--scene)
      (pcase-let ((`(,fragment ,new-tiles ,changed) (org-timegrid--scene-patch scene)))
        ;; Clock invalidation can discard the old scene before a region clears.
        ;; Retire every tile that no longer belongs to the dynamic surface.
        (dolist (tile (delete-dups
                       (append changed (cl-set-difference org-timegrid--dynamic-tiles new-tiles))))
          (org-timegrid--set-tile-image
           tile (if (memq tile new-tiles)
                    (org-timegrid--make-tile-image tile fragment)
                  (aref org-timegrid--static-images tile))))
        (setq org-timegrid--dynamic-tiles new-tiles org-timegrid--scene scene))))
  (set-buffer-modified-p nil))

(defun org-timegrid--insert-tiles ()
  "Replace the buffer with the cached hour tiles."
  (let ((inhibit-read-only t))
    (dolist (tile org-timegrid--dynamic-tiles)
      (when-let* ((position (and (vectorp org-timegrid--tile-markers)
                                 (< tile (length org-timegrid--tile-markers))
                                 (aref org-timegrid--tile-markers tile)))
                  (image (get-text-property position 'display)))
        (org-timegrid--retire-image image)))
    (erase-buffer)
    (org-timegrid--flush-images org-timegrid--pending-image-flush)
    (setq org-timegrid--pending-image-flush nil)
    (setq-local org-timegrid--tile-markers
                (make-vector org-timegrid--tile-count nil))
    (dotimes (tile org-timegrid--tile-count)
      (let ((start (point)))
        (aset org-timegrid--tile-markers tile start)
        (insert (propertize " "
                            'org-timegrid-tile tile
                            'occs-svg-image t
                            'help-echo
                            "Drag empty time to create; drag blocks to move or resize"
                            'display (aref org-timegrid--static-images tile)))
        ;; No newline after the last tile.  It would leave an empty final
        ;; line, which shows up as blank space under the calendar.
        (when (and (< tile (1- org-timegrid--tile-count))
                   (zerop (% (1+ tile) org-timegrid--tile-columns)))
          (insert "\n"))))
    (setq-local org-timegrid--dynamic-tiles nil
                org-timegrid--scene nil)
    (set-buffer-modified-p nil)))

(defun org-timegrid--all-day-layout ()
  "Return rail layout, reusing it until data, preview or day count changes."
  (let ((key (list (org-timegrid--calendar-state-blocks org-timegrid--state)
                   (org-timegrid--calendar-state-preview org-timegrid--state)
                   org-timegrid-days)))
    (unless (equal key (car org-timegrid--all-day-layout-cache))
      (setq org-timegrid--all-day-layout-cache
            (cons key (org-timegrid--compute-all-day-layout))))
    (cdr org-timegrid--all-day-layout-cache)))

(defun org-timegrid--header (&optional scene)
  "Present the header returned by the SVG adapter."
  (org-timegrid--ensure-state)
  (let* ((context (or org-timegrid--render-context (org-timegrid--capture-context)))
         (drawing (org-timegrid-svg-header
                   (or scene (org-timegrid-scene-header
                              org-timegrid--state context
                              (org-timegrid--header-left-offset (get-buffer-window (current-buffer) t)))))))
    (setq-local org-timegrid--header-geometry (cdr drawing))
    (let ((map (org-timegrid--header-image-map)))
      (propertize " " 'display (org-timegrid-svg-image (car drawing) :ascent 100 :scale 1
                                                       :map map :original-map map)
                  'keymap org-timegrid--header-map
                  'help-echo "Click to select an all-day cell or event"))))

(defun org-timegrid--refresh (&optional preserve-scroll minute alignment)
  "Rebuild cached tiles.
When PRESERVE-SCROLL is non-nil, preserve the pixel scroll position.
When MINUTE is a number, position it using ALIGNMENT before redisplay.
ALIGNMENT defaults to `center'."
  (org-timegrid--ensure-state)
  (org-timegrid--with-render-context (or org-timegrid--render-context (org-timegrid--capture-context))
    (org-timegrid--sync-fringe-background)
    (let* ((window (get-buffer-window (current-buffer) t))
           (vscroll (and preserve-scroll window
                         (let ((current (org-timegrid--window-scroll-pixels
                                         window)))
                           (if (and (zerop current)
                                    (> org-timegrid--saved-vscroll 0))
                               org-timegrid--saved-vscroll
                             current))))
           (previewp (org-timegrid--calendar-state-preview org-timegrid--state)))
      (when (overlayp org-timegrid--pointer-overlay)
        (delete-overlay org-timegrid--pointer-overlay)
        (setq-local org-timegrid--pointer-overlay nil))
      (org-timegrid--cache-static-tiles
       (and previewp (org-timegrid--operation-replace-id previewp)))
      (org-timegrid--insert-tiles)
      (org-timegrid--render-dynamic)
      (unless (and previewp header-line-format)
        (setq-local header-line-format
                    (org-timegrid--cached-header)))
      (setq-local org-timegrid--last-width
                  (org-timegrid--window-width))
      (setq-local org-timegrid--displayed-context org-timegrid--render-context)
      (set-buffer-modified-p nil)
      (when window
        ;; Position the viewport before redisplay, so the rebuilt calendar
        ;; never appears briefly at the top.
        (cond
         ((numberp minute)
          (org-timegrid--align-minute window minute alignment))
         (vscroll
          (org-timegrid--set-vscroll window vscroll))
         (t
          (set-window-start window (point-min) t)
          (set-window-point window (point-min))
          (set-window-vscroll window 0 t)))
        (redisplay t))
      (unless previewp (org-timegrid--schedule-prewarm)))))

(defun org-timegrid--schedule-scroll-restore (window)
  "Restore WINDOW after the buffer switch has finished redisplaying."
  (when (timerp org-timegrid--scroll-restore-timer)
    (cancel-timer org-timegrid--scroll-restore-timer))
  (let ((buffer (current-buffer)))
    (setq-local
     org-timegrid--scroll-restore-timer
     (run-at-time
      0.01 nil
      (lambda ()
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq-local org-timegrid--scroll-restore-timer nil)
            (org-timegrid--restore-scroll window))))))))

(defun org-timegrid--restore-frame-calendars (frame)
  "Restore calendars newly displayed in a window on FRAME."
  (dolist (window (window-list frame 'no-minibuffer))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'org-timegrid-mode)
        (when org-timegrid--stale (org-timegrid--window-resized window))
        (when (> org-timegrid--saved-vscroll 0)
          (org-timegrid--schedule-scroll-restore window))))))

(defun org-timegrid--theme-changed (&rest _ignored)
  "Redraw live SVG calendars after an Emacs theme face change."
  (when (timerp org-timegrid--theme-timer)
    (cancel-timer org-timegrid--theme-timer))
  (setq org-timegrid--theme-timer
        (run-at-time
         0 nil
         (lambda ()
           (setq org-timegrid--theme-timer nil)
           (dolist (buffer (buffer-list))
             (with-current-buffer buffer
               (when (derived-mode-p 'org-timegrid-mode)
                 (if (/= (org-timegrid--zoom-factor)
                         org-timegrid--last-zoom-factor)
                     (org-timegrid--text-scale-changed)
                   (org-timegrid--with-update 'preserve)))))))))

(defun org-timegrid--window-resized (window)
  "Schedule a redraw when WINDOW has a new pixel width or default font size."
  (let ((buffer (window-buffer window))
        (width (window-body-width window t))
        (factor (org-timegrid--zoom-factor window)))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'org-timegrid-mode)
                 (or org-timegrid--stale
                     (/= width (or org-timegrid--last-width -1))
                     (/= factor org-timegrid--last-zoom-factor)))
        (when (timerp org-timegrid--resize-timer)
          (cancel-timer org-timegrid--resize-timer))
        (setq-local
         org-timegrid--resize-timer
         (run-at-time
          0 nil
          (lambda ()
            (when (and (buffer-live-p buffer) (window-live-p window)
                       (eq buffer (window-buffer window)))
              (with-current-buffer buffer
                (setq-local org-timegrid--resize-timer nil)
                (org-timegrid--with-update 'preserve
                  (when (and org-timegrid--stale
                             (not (org-timegrid--calendar-state-preview org-timegrid--state)))
                    (org-timegrid--refresh-data t))
                  (when (/= (org-timegrid--zoom-factor window)
                            org-timegrid--last-zoom-factor)
                    (org-timegrid--text-scale-changed))))))))))))

(defun org-timegrid--start-timers ()
  "Start the data and clock services owned by the current calendar display."
  (dolist (timer (list org-timegrid--clock-timer org-timegrid--data-timer))
    (when (timerp timer) (cancel-timer timer)))
  (let ((buffer (current-buffer)))
    (setq org-timegrid--clock-timer (run-at-time 60 60 #'org-timegrid--clock-tick buffer)
          org-timegrid--data-timer (run-at-time org-timegrid-data-refresh-seconds
                                                org-timegrid-data-refresh-seconds
                                                #'org-timegrid--data-tick buffer))))

(defun org-timegrid--cancel-timers ()
  "Cancel timers owned by the calendar buffer."
  (org-timegrid--clear-preview-cache)
  (dolist (timer (list org-timegrid--prewarm-timer org-timegrid--resize-timer
                       org-timegrid--clock-timer
                       org-timegrid--data-timer
                       org-timegrid--keyboard-edit-timer
                       org-timegrid--scroll-restore-timer))
    (when (timerp timer) (cancel-timer timer))))

(defun org-timegrid--clock-tick (buffer)
  "Redraw the current time indicator in visible calendar BUFFER."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'org-timegrid-mode)
                 (null (org-timegrid--calendar-state-preview org-timegrid--state)))
        (if (seq-some (lambda (event)
                        (plist-get (org-timegrid-event-metadata event) :running))
                      (org-timegrid--calendar-state-events org-timegrid--state))
            (org-timegrid--refresh-data t)
          (org-timegrid--with-update 'clock))))))

(defun org-timegrid--render-clock ()
  "Refresh clock chrome and any overlying scene images."
  (let ((old-tiles org-timegrid--clock-tiles))
    (org-timegrid--update-clock-fragment)
    (dolist (tile (delete-dups
                   (append old-tiles org-timegrid--clock-tiles)))
      (aset org-timegrid--static-images tile
            (org-timegrid--make-tile-image tile))
      (unless (memq tile org-timegrid--dynamic-tiles)
        (org-timegrid--set-tile-image
         tile (aref org-timegrid--static-images tile))))
    (when org-timegrid--dynamic-tiles
      ;; Reconciliation will repaint images over the changed clock chrome.
      (setq org-timegrid--scene nil))))

(defun org-timegrid--data-tick (buffer)
  "Reload visible calendar BUFFER, or defer while hidden or editing."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'org-timegrid-mode)
        (if (and (get-buffer-window buffer t)
                 (not (and org-timegrid--state
                           (org-timegrid--calendar-state-preview org-timegrid--state))))
            (org-timegrid--refresh-data t)
          (setq-local org-timegrid--stale t))))))

(defun org-timegrid--render-header-dynamic ()
  "Compare header scenes and present an image only when its drawing changes."
  (let ((old header-line-format) (new (org-timegrid--cached-header)))
    (unless (eq old new)
      (setq-local header-line-format new)
      (when (and (stringp old)
                 (not (seq-some (lambda (view) (eq old (org-timegrid--cached-view-header view)))
                                org-timegrid--view-cache)))
        (org-timegrid--retire-image (get-text-property 0 'display old)
                                    (get-text-property 0 'display new)))
      (when (get-buffer-window (current-buffer) t) (force-mode-line-update t)))))

(defun org-timegrid--update (change &optional view)
  "Apply CHANGE and reconcile the display once, including nested updates.
CHANGE is a function that updates calendar data.  VIEW optionally requests
`reset', `preserve', `clock', or (MINUTE . ALIGNMENT) for the viewport."
  (if (eq (car org-timegrid--update-context) (current-buffer))
      (progn
        (when (and view (or (not (eq view 'clock))
                            (null (cdr org-timegrid--update-context))))
          (setcdr org-timegrid--update-context view))
        (funcall change))
    ;; Cursor setters replace positions, so a shallow state copy is sufficient.
    (let ((old (if org-timegrid--state
                   (copy-org-timegrid--calendar-state org-timegrid--state)
                 (org-timegrid--calendar-state-create)))
          (org-timegrid--update-context (cons (current-buffer) view)))
      (unwind-protect (funcall change)
        (when (buffer-live-p (car org-timegrid--update-context))
          (with-current-buffer (car org-timegrid--update-context)
            (org-timegrid--with-render-context (org-timegrid--capture-context)
              (org-timegrid--reconcile old (cdr org-timegrid--update-context)))))))))

(defun org-timegrid--reconcile (old view)
  "Reconcile OLD and current calendar data, then schedule preparation."
  (when org-timegrid--state
    (let* ((before (org-timegrid--calendar-state-preview old))
           (preview (org-timegrid--calendar-state-preview org-timegrid--state))
           (data-changed (not (eq (org-timegrid--calendar-state-blocks old)
                                  (org-timegrid--calendar-state-blocks org-timegrid--state))))
           (style-changed
            (and org-timegrid--displayed-context
                 (not (equal (org-timegrid--context-key org-timegrid--render-context)
                             (org-timegrid--context-key org-timegrid--displayed-context)))))
           (full (or style-changed (and view (not (eq view 'clock)))
                     (null org-timegrid--static-inner)
                     data-changed
                     (not (equal (org-timegrid--calendar-state-week-start old)
                                 (org-timegrid--calendar-state-week-start org-timegrid--state))))))
      (when (or style-changed view data-changed (not (equal old org-timegrid--state)))
        (if full
            ;; Keep the old frame until replacement tiles and scroll are ready.
            (let ((inhibit-redisplay t))
              (org-timegrid--clear-preview-cache)
              (org-timegrid--refresh (not (or (eq view 'reset) (consp view)))
                                     (car-safe view) (cdr-safe view)))
          (when (eq view 'clock) (org-timegrid--render-clock))
          (org-timegrid--render-header-dynamic)
          (org-timegrid--render-dynamic))
        (setq-local org-timegrid--displayed-context org-timegrid--render-context)
        (redisplay t)
        (when (and (memq view '(nil reset)) (org-timegrid--cursor-visible-p)
                   (not (equal (org-timegrid--calendar-state-cursor old)
                               (org-timegrid--cursor))))
          (org-timegrid--scroll-cursor-into-view))
        (when (or full (not (equal before preview)))
          (org-timegrid--schedule-preview-preparation before)
          (when (and before (not preview))
            (if org-timegrid--stale
                (when-let* ((window (get-buffer-window (current-buffer) t)))
                  (org-timegrid--window-resized window))
              (org-timegrid--schedule-prewarm))))))))

(defun org-timegrid--refresh-data (&optional if-changed)
  "Reload the displayed week through the shared update path.
With IF-CHANGED, keep rendered views when backend events are unchanged."
  (let* ((inhibit-redisplay t)
         (week (org-timegrid--calendar-state-week-start org-timegrid--state))
         (state (org-timegrid--load-state week)))
    (setq org-timegrid--stale nil)
    (unless (and if-changed
                 (equal (org-timegrid--calendar-state-events state)
                        (org-timegrid--calendar-state-events org-timegrid--state))
                 (org-timegrid--cached-view))
      (org-timegrid--with-update 'preserve
        (org-timegrid--clear-view-cache)
        (org-timegrid--reload-state week state)))))

(defun org-timegrid--default-font-height (&optional window)
  "Return the rendered default-face height for WINDOW in pixels.
Use the current calendar window when WINDOW is nil, with a frame-based
fallback for buffers that are not displayed."
  (let ((window (or window (get-buffer-window (current-buffer) t))))
    (if (window-live-p window)
        (window-font-height window 'default)
      (default-font-height))))

(defun org-timegrid--frame-font-size (&optional window)
  "Return WINDOW's resolved, unscaled default-face font size in pixels.
Use the reference size on terminal frames, which have no pixel font size."
  (let* ((window (or window (get-buffer-window (current-buffer) t)))
         (frame (and (window-live-p window) (window-frame window))))
    (if (display-graphic-p frame)
        (aref (font-info (face-font 'default frame) frame) 2)
      org-timegrid--reference-font-size)))

(defun org-timegrid--default-font-size (&optional window)
  "Return WINDOW's effective default-face font size in SVG pixels."
  (unless (and (numberp org-timegrid-default-zoom)
               (> org-timegrid-default-zoom 0))
    (user-error "Org-timegrid-default-zoom must be positive"))
  (let* ((window (or window (get-buffer-window (current-buffer) t)))
         (frame (and (window-live-p window) (window-frame window)))
         (frame-height (frame-char-height frame)))
    (* (org-timegrid--frame-font-size window)
       org-timegrid-default-zoom
       (/ (org-timegrid--default-font-height window)
          (float frame-height)))))

(defun org-timegrid--remapped-color (face attribute)
  "Return ATTRIBUTE of FACE as remapped in this buffer, or nil.
`face-remapping-alist' is how a buffer gets a background of its own --
solaire-mode dims every buffer that is not visiting a file, and per-buffer
theming works the same way -- and `face-attribute' does not consult it.
Reading the global face instead draws a calendar that does not match the
buffer it sits in.  An entry is a face, or a list of faces with the first
taking priority, or an inline attribute list."
  (let ((remap (cdr (assq face face-remapping-alist))))
    (seq-some
     (lambda (entry)
       (cond ((and (symbolp entry) (facep entry))
              (let ((value (face-attribute entry attribute nil t)))
                (and (stringp value) value)))
             ((and (consp entry) (keywordp (car entry)))
              (plist-get entry attribute))))
     (if (proper-list-p remap) remap (list remap)))))

(defun org-timegrid--face-color
    (face attribute fallback)
  "Return FACE ATTRIBUTE as a color string, or FALLBACK.
Buffer-local face remapping wins, so the drawing matches the buffer it is
drawn into rather than the frame's idea of the face."
  (let ((value (or (org-timegrid--remapped-color face attribute)
                   (face-attribute face attribute nil t))))
    (org-timegrid--normalize-color value fallback)))

(defun org-timegrid--face-palette ()
  "Resolve current face colors, reusing their derived palette while unchanged."
  (let* ((background (org-timegrid--face-color
                      'default :background "#ffffff"))
         (foreground (org-timegrid--face-color
                      'default :foreground "#30343a"))
         (muted (org-timegrid--face-color
                 'shadow :foreground foreground))
         ;; Chrome only: the selection outline and the current-time line.
         ;; Event colours come from `org-timegrid-colors'.
         (blue (org-timegrid--face-color
                'link :foreground "#3979d6"))
         (red (org-timegrid--face-color
               'error :foreground "#d94b4b"))
         (highlight (org-timegrid--face-color
                     'highlight :background blue))
         (cursor (org-timegrid--face-color 'cursor :background blue))
         (region (org-timegrid--face-color 'region :background muted))
         (key (list background foreground muted blue red highlight cursor region)))
    (unless (equal key (car org-timegrid--palette-cache))
      (setq org-timegrid--palette-cache
            (cons key (list :background background :foreground foreground :muted muted
                            :grid (org-timegrid--blend foreground background 0.16)
                            :half-grid (org-timegrid--blend foreground background 0.08)
                            :time-background
                            (org-timegrid--blend foreground background 0.035)
                            :time-label
                            (org-timegrid--blend foreground background 0.82)
                            :time-period
                            (org-timegrid--blend foreground background 0.70)
                            :secondary-text
                            (org-timegrid--blend foreground background 0.72)
                            :weekend (org-timegrid--blend foreground background 0.025)
                            :today (org-timegrid--blend highlight background 0.10)
                            :blue blue :red red
                            :clock (org-timegrid--blend red background 0.75)
                            :cursor cursor
                            :region region
                            :preview-fill (org-timegrid--blend muted background 0.18)
                            :done-fill (org-timegrid--blend muted background 0.11)))))
    (copy-sequence (cdr org-timegrid--palette-cache))))

(defun org-timegrid--window-width ()
  "Return the calendar window's body width in pixels."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window t)
    900))

(defun org-timegrid--header-left-offset (window)
  "Return the gap between WINDOW's left edge and its text area.
The header line starts at the window edge, but the tiles are text, so they
start after the fringe, the margin and a left-hand scroll bar.  Measure the
gap instead of counting the fringe alone, or the header sits to the left of
the grid by the width of whatever else is there."
  (if org-timegrid--render-context
      (org-timegrid--render-context-header-offset org-timegrid--render-context)
    (if (window-live-p window)
        (max 0 (- (nth 0 (window-edges window t nil t))
                  (nth 0 (window-edges window nil nil t))))
      0)))

(defun org-timegrid--sync-fringe-background ()
  "Match this buffer's fringes to its time-label gutter."
  (when org-timegrid--fringe-remap-cookie
    (face-remap-remove-relative org-timegrid--fringe-remap-cookie))
  (setq-local
   org-timegrid--fringe-remap-cookie
   (face-remap-add-relative
    'fringe
    (list :background
          (plist-get (org-timegrid--palette) :time-background)))))

(defun org-timegrid--header-image-map ()
  "Return move and horizontal-resize hotspots for all-day blocks."
  (let (edges bodies)
    (dolist (geometry org-timegrid--header-geometry)
      (let* ((block (and (org-timegrid--calendar-state-p org-timegrid--state)
                         (org-timegrid--block (plist-get geometry :id))))
             (details (and block (org-timegrid--block-details block)))
             (x (round (plist-get geometry :x)))
             (y (round (plist-get geometry :y)))
             (right (round (+ (plist-get geometry :x)
                              (plist-get geometry :width))))
             (bottom (round (+ (plist-get geometry :y)
                               (plist-get geometry :height))))
             (edge (min org-timegrid--resize-pixels
                        (max 1 (floor (/ (- right x) 2.0))))))
        (when (plist-get geometry :allow-left)
          (push (list `(rect . ((,x . ,y) . (,(+ x edge) . ,bottom)))
                      'calendar-rail-resize
                      `(pointer hdrag help-echo ,details))
                edges))
        (when (plist-get geometry :allow-right)
          (push (list `(rect . ((,(- right edge) . ,y) . (,right . ,bottom)))
                      'calendar-rail-resize
                      `(pointer hdrag help-echo ,details))
                edges))
        (push (list `(rect . ((,x . ,y) . (,right . ,bottom)))
                    'calendar-rail-block
                    `(pointer hand help-echo ,details))
              bodies)))
    (append edges bodies)))

(defun org-timegrid--image-map ()
  "Return hotspots with clock strips above underlying plan hotspots."
  (let (clocks plans)
    (dolist (geometry org-timegrid--geometry)
      (if (plist-get geometry :clock) (push geometry clocks) (push geometry plans)))
    (append (org-timegrid--geometry-image-map (nreverse clocks))
            (org-timegrid--geometry-image-map (nreverse plans)))))

(defun org-timegrid--geometry-image-map (geometries)
  "Return pixel hotspots for block movement and edge resizing."
  (let (edges bodies)
    (dolist (geometry geometries)
      (unless (plist-get geometry :preview)
        (let* ((block (and (org-timegrid--calendar-state-p org-timegrid--state)
                           (org-timegrid--block (plist-get geometry :id))))
               (details (and block (org-timegrid--block-details block)))
               (x (round (plist-get geometry :x)))
               (y (round (plist-get geometry :y)))
               (right (round (+ (plist-get geometry :x)
                                (plist-get geometry :width))))
               (bottom (round (+ (plist-get geometry :y)
                                 (plist-get geometry :height))))
               (edge (max 1 (round
                             (org-timegrid--edge-height
                              geometry))))
               (slop org-timegrid--resize-slop)
               (boundary-edge (plist-get geometry :boundary-edge)))
          (cond
           (boundary-edge
            (push (list `(rect . ((,x . ,y) . (,right . ,bottom)))
                        'calendar-resize
                        `(pointer nhdrag
                                  help-echo ,details))
                  edges))
           (t
            (when (plist-get geometry :allow-top)
              (push (list `(rect . ((,x . ,(max 0 (- y slop)))
                                    . (,right . ,(+ y edge))))
                          'calendar-resize
                          `(pointer nhdrag help-echo ,details))
                    edges))
            (when (plist-get geometry :allow-bottom)
              (push (list `(rect . ((,x . ,(- bottom edge))
                                    . (,right . ,(+ bottom slop))))
                          'calendar-resize
                          `(pointer nhdrag help-echo ,details))
                    edges))
            (push (list `(rect . ((,x . ,y) . (,right . ,bottom)))
                        'calendar-block
                        `(pointer hand help-echo ,details))
                  bodies))))))
    (append edges bodies)))

(defun org-timegrid--text-scale-changed ()
  "Rerender the calendar after a buffer-local text scaling change.
Keep the same calendar minute at the vertical center of the window."
  (when (derived-mode-p 'org-timegrid-mode)
    (let* ((window (get-buffer-window (current-buffer) t))
           (old-factor org-timegrid--last-zoom-factor)
           (new-factor (org-timegrid--zoom-factor))
           (body (and window (window-body-height window t)))
           (scroll (and window (org-timegrid--window-scroll-pixels window)))
           (old-inset (* org-timegrid--grid-top-inset old-factor))
           (old-scale (* org-timegrid--base-pixels-per-minute old-factor))
           (anchor-minute
            (and body scroll
                 (+ (* 60 org-timegrid-start-hour)
                    (/ (- (+ scroll (/ body 2.0)) old-inset)
                       old-scale)))))
      (setq-local org-timegrid--last-zoom-factor new-factor)
      (org-timegrid--with-update (cons anchor-minute nil)))))

(defun org-timegrid--install-text-scale-hook ()
  "Install SVG zoom support in the current calendar buffer."
  (setq-local org-timegrid--last-zoom-factor (org-timegrid--zoom-factor))
  (add-hook 'text-scale-mode-hook #'org-timegrid--text-scale-changed nil t))

(defun org-timegrid--window-scroll-pixels (window)
  "Return WINDOW's absolute pixel offset in the tiled calendar."
  (let* ((start (window-start window))
         (tile (or (get-text-property start 'org-timegrid-tile) 0)))
    (+ (if org-timegrid--tile-count
           (car (org-timegrid--tile-bounds tile))
         0)
       (window-vscroll window t))))

(defun org-timegrid--set-vscroll (window pixels)
  "Set WINDOW's pixel scroll to PIXELS and remember it."
  (let* ((pixels (max 0 (round pixels)))
         (pixels (if (numberp org-timegrid--image-height)
                     (min pixels (1- (ceiling org-timegrid--image-height)))
                   pixels))
         (tile (or (org-timegrid--tile-at-pixel pixels) 0))
         (top (if org-timegrid--tile-count
                  (car (org-timegrid--tile-bounds tile))
                0))
         (within (- pixels top)))
    (when (and (vectorp org-timegrid--tile-markers)
               (< tile (length org-timegrid--tile-markers)))
      (let ((marker (aref org-timegrid--tile-markers tile)))
        (set-window-start window marker t)
        (set-window-point
         window
         (aref org-timegrid--tile-markers
               (min (1- (length org-timegrid--tile-markers))
                    (+ org-timegrid--tile-columns tile))))))
    (set-window-vscroll window within t))
  (setq-local org-timegrid--saved-vscroll pixels))

(defun org-timegrid--restore-scroll (window)
  "Restore this calendar's saved pixel position in WINDOW."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (set-window-point window (point-min))
    (org-timegrid--set-vscroll window org-timegrid--saved-vscroll)))

(defun org-timegrid--scroll-cursor-into-view ()
  "Scroll the minimum amount needed to make the whole cursor slot visible."
  (when-let* ((cursor (org-timegrid--cursor))
              ((eq (org-timegrid--cursor-state-surface cursor) 'grid))
              (window (get-buffer-window (current-buffer) t)))
    (let* ((scale (org-timegrid--pixels-per-minute))
           (start-minute (* 60 org-timegrid-start-hour))
           (top (+ (org-timegrid--grid-top-inset)
                   (* (- (org-timegrid--cursor-state-minute cursor) start-minute) scale)))
           (bottom (+ top (* org-timegrid-slot-minutes scale)))
           (body (window-body-height window t))
           (vscroll (org-timegrid--window-scroll-pixels window))
           (maximum (max 0 (- (or org-timegrid--image-height 0) body))))
      (cond
       ((< top vscroll)
        (org-timegrid--set-vscroll window (max 0 (min maximum top))))
       ((> bottom (+ vscroll body))
        (org-timegrid--set-vscroll
         window (max 0 (min maximum (- bottom body)))))))))

(defun org-timegrid--align-minute (window minute &optional alignment)
  "Position MINUTE vertically in WINDOW using ALIGNMENT.
ALIGNMENT is `top' or `center', defaulting to `center'."
  (let* ((start-minute (* 60 org-timegrid-start-hour))
         (y (+ (org-timegrid--grid-top-inset)
               (* (- minute start-minute)
                  (org-timegrid--pixels-per-minute))))
         (body (window-body-height window t))
         (maximum (max 0 (- (or org-timegrid--image-height 0) body)))
         (target (max 0 (min maximum (- y (if (eq alignment 'top) 0 (/ body 2)))))))
    (org-timegrid--set-vscroll window target)))

(provide 'org-timegrid-display)
;;; org-timegrid-display.el ends here
