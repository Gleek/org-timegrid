;;; org-timegrid-contract-test.el --- Layer contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-timegrid)

(defvar org-timegrid-contract-test-tone "#102030")

(ert-deftest org-timegrid-contract-scenes-use-only-captured-inputs ()
  "Static and interactive components need no SVG, files, window or cache access."
  (with-temp-buffer
    (let* ((org-timegrid-days 1)
           (block (org-timegrid--make-block 'event 0 600 660 "Plan"))
           (state (org-timegrid--calendar-state-create :week-start 100 :blocks (list block)))
           (context (org-timegrid--capture-context))
           (static (org-timegrid-scene-static state context))
           (header (org-timegrid-scene-header state context 0))
           (strip (org-timegrid-scene-day (list block) 557 737 400 660 context))
           (clock (org-timegrid-scene-clock state context))
           (proposal (org-timegrid--keyboard-proposal block -15 0 'top))
           (preview (org-timegrid-scene-build state context
                                              (org-timegrid--scene-geometry static) nil proposal)))
      (let ((org-timegrid-days 7) (org-timegrid-pixels-per-minute 42)
            (org-timegrid--geometry 'untouched) (org-timegrid--timed-layout-cache 'untouched))
        (cl-letf (((symbol-function 'svg-create) (lambda (&rest _) (error "SVG in component")))
                  ((symbol-function 'create-image) (lambda (&rest _) (error "Image in component")))
                  ((symbol-function 'org-timegrid-backend-list) (lambda (&rest _) (error "Storage in component")))
                  ((symbol-function 'org-timegrid--clear-view-cache) (lambda () (error "Cache in component")))
                  ((symbol-function 'org-timegrid--face-palette) (lambda () (error "Live faces in component")))
                  ((symbol-function 'org-timegrid--window-width) (lambda () (error "Live window in component")))
                  ((symbol-function 'org-timegrid--default-font-size) (lambda (&rest _) (error "Live font in component")))
                  ((symbol-function 'calendar-current-date) (lambda () (error "Live date in component"))))
          (should (equal static (org-timegrid-scene-static state context)))
          (should (equal header (org-timegrid-scene-header state context 0)))
          (should (equal strip (org-timegrid-scene-day (list block) 557 737 400 660 context)))
          (should (equal clock (org-timegrid-scene-clock state context)))
          (should (equal preview (org-timegrid-scene-build
                                  state context (org-timegrid--scene-geometry static) nil proposal))))
        (should (eq org-timegrid--geometry 'untouched))
        (should (eq org-timegrid--timed-layout-cache 'untouched)))
      (should (= (org-timegrid--render-context-minute context)
                 (org-timegrid--render-context-minute (org-timegrid--scene-context header))))
      (should-not (org-timegrid--calendar-state-preview state))
      (dolist (node (append (org-timegrid--scene-nodes static) (org-timegrid--scene-nodes preview)))
        (dolist (property '(:key :x :y :width :height))
          (should (plist-member (cdr node) property)))))))

(ert-deftest org-timegrid-contract-component-style-invalidates-automatically ()
  "A component declares its style once; adding it needs no cache integration."
  (with-temp-buffer
    (org-timegrid-mode)
    (let ((org-timegrid--style-variables (copy-sequence org-timegrid--style-variables))
          (org-timegrid-contract-test-tone "#102030")
          (background (symbol-function 'org-timegrid--background-nodes)))
      (eval '(org-timegrid--defstyle org-timegrid-contract-test-tone "#102030" "Test component ink."))
      (cl-letf (((symbol-function 'org-timegrid--background-nodes)
                 (lambda (&rest args)
                   (append (apply background args)
                           (list (org-timegrid--shape-node 'extra-band 'rect 100 60 50 10
                                                           :fill org-timegrid-contract-test-tone)))))
                ((symbol-function 'create-image) (lambda (data &rest _) (list 'image :data data)))
                ((symbol-function 'image-flush) #'ignore)
                ((symbol-function 'redisplay) #'ignore)
                ((symbol-function 'org-timegrid--schedule-prewarm) #'ignore)
                ((symbol-function 'org-timegrid-backend-list) (lambda (&rest _) (error "Style accessed storage"))))
        (org-timegrid--with-update 'preserve
          (setq org-timegrid--state (org-timegrid--calendar-state-create :week-start 100)))
        (let ((old-images org-timegrid--static-images)
              (old-context org-timegrid--view-cache-context))
          ;; An idle cache lookup may discover the change before the next update.
          (setq org-timegrid-contract-test-tone "#abcdef")
          (org-timegrid--cached-view)
          (org-timegrid--with-update nil (ignore))
          (should-not (eq old-images org-timegrid--static-images))
          (should (equal "#102030" (alist-get 'org-timegrid-contract-test-tone
                                              (org-timegrid--render-context-settings old-context))))
          (should (seq-some (lambda (xml) (string-match-p "#abcdef" xml))
                            org-timegrid--static-fragments))
          (setq old-images org-timegrid--static-images)
          (org-timegrid--with-update nil (setq org-timegrid-contract-test-tone "#abcdef"))
          (should (eq old-images org-timegrid--static-images)))))))

(ert-deftest org-timegrid-contract-overflow-is-part-of-the-drawing ()
  "A thicker stroke reaches adjacent tiles without changing cache code."
  (let* ((org-timegrid--tile-columns 1) (org-timegrid--tile-count 4)
         (org-timegrid--tile-width 200) (org-timegrid--tile-height 60)
         (org-timegrid--image-height 240)
         (node (org-timegrid--shape-node 'divider 'line 0 60 200 0 :stroke-width 10)))
    (should (equal '(0 1) (org-timegrid--geometry-tiles (cdr node))))))

(ert-deftest org-timegrid-contract-storage-snapshots-do-not-alias-cache-values ()
  "A backend reusing records cannot change a previously displayed snapshot."
  (let* ((calls 0)
         (prepare (lambda () (cl-incf calls)))
         (record (org-timegrid-event-create :id 'event :title "Plan" :start 100 :end 160
                                            :metadata (list :clock t :prepare-edit prepare)))
         (backend (org-timegrid-backend-create :list-function (lambda (&rest _) (list record))))
         (before (org-timegrid-backend-list backend 0 200)))
    (setf (org-timegrid-event-end record) 180)
    (setf (plist-get (org-timegrid-event-metadata record) :clock) nil)
    (should (eq prepare (plist-get (org-timegrid-event-metadata (car before)) :prepare-edit)))
    (funcall (plist-get (org-timegrid-event-metadata (car before)) :prepare-edit))
    (should (= calls 1))
    (should (= 160 (org-timegrid-event-end (car before))))
    (should (plist-get (org-timegrid-event-metadata (car before)) :clock))
    (should-not (equal before (org-timegrid-backend-list backend 0 200)))))

(ert-deftest org-timegrid-contract-style-damage-and-clock-identity ()
  "Paint changes repaint unchanged boxes; a clock tick preserves static identity."
  (let* ((context (org-timegrid--capture-context))
         (changed (copy-org-timegrid--render-context context))
         (nodes '((cursor :key cursor :x 10 :y 20 :width 30 :height 40)))
         (before (org-timegrid--scene-create :nodes nodes :context context)))
    (setf (org-timegrid--render-context-palette changed) '(:cursor "#ff0000"))
    (should (org-timegrid--scene-damage before (org-timegrid--scene-create :nodes nodes :context changed)))
    (setq changed (copy-org-timegrid--render-context context))
    (cl-incf (org-timegrid--render-context-minute changed))
    (should (equal (org-timegrid--context-key context) (org-timegrid--context-key changed)))
    (should-not (org-timegrid--scene-damage before (org-timegrid--scene-create :nodes nodes :context changed)))))
(ert-deftest org-timegrid-contract-palette-snapshots-survive-face-changes ()
  "A cached palette follows face changes without modifying an earlier scene."
  (let ((ink "#112233") (org-timegrid--palette-cache nil))
    (cl-letf (((symbol-function 'org-timegrid--face-color)
               (lambda (_face attribute _fallback)
                 (if (eq attribute :background) "#ffffff" ink))))
      (let* ((before (org-timegrid--capture-context))
             (again (org-timegrid--capture-context)))
        (should (equal (org-timegrid--context-key before) (org-timegrid--context-key again)))
        (setq ink "#445566")
        (let ((after (org-timegrid--capture-context)))
          (should (equal "#112233" (plist-get (org-timegrid--render-context-palette before) :foreground)))
          (should (equal "#445566" (plist-get (org-timegrid--render-context-palette after) :foreground)))
          (should-not (equal (org-timegrid--context-key before) (org-timegrid--context-key after))))))))

(ert-deftest org-timegrid-contract-hit-testing-uses-the-presented-layout ()
  "Changing a setting before repaint must not reinterpret an already visible image."
  (with-temp-buffer
    (let* ((org-timegrid-days 1)
           (org-timegrid--state (org-timegrid--calendar-state-create :week-start 100))
           (org-timegrid--displayed-context (org-timegrid--capture-context))
           (org-timegrid--image-height (org-timegrid--context-height org-timegrid--displayed-context))
           (xy (cons (+ (org-timegrid--label-width) (/ (org-timegrid--column-width) 2))
                     (+ (org-timegrid--grid-top-inset) (* 600 (org-timegrid--pixels-per-minute))))))
      (let ((org-timegrid-days 7) (org-timegrid-pixels-per-minute 42))
        (cl-letf (((symbol-function 'org-timegrid--position-image-xy) (lambda (_) xy)))
          (let ((target (org-timegrid--target nil)))
            (should (= 0 (plist-get target :day)))
            (should (= 600 (plist-get target :minute)))))
        (should (= 7 org-timegrid-days))))))

(ert-deftest org-timegrid-contract-context-preserves-component-locals ()
  "The context wrapper must not capture a component's own local input names."
  (let ((inputs 'component-data)
        (context (org-timegrid--capture-context)))
    (should (eq inputs (org-timegrid--with-render-context context inputs)))))

(defmacro org-timegrid-contract-test--display (&rest body)
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (org-timegrid-mode)
     (let ((org-timegrid-days 1))
       (cl-letf (((symbol-function 'create-image) (lambda (data &rest _) (list 'image :data data)))
                 ((symbol-function 'image-flush) #'ignore)
                 ((symbol-function 'redisplay) #'ignore)
                 ((symbol-function 'org-timegrid--schedule-prewarm) #'ignore))
         ,@body))))

(ert-deftest org-timegrid-contract-header-components-need-no-cache-rule ()
  "A new header node follows model changes without extending a cache key."
  (org-timegrid-contract-test--display
   (let ((build (symbol-function 'org-timegrid-scene-header)))
     (cl-letf (((symbol-function 'org-timegrid-scene-header)
                (lambda (state context offset)
                  (let ((scene (funcall build state context offset)))
                    (when (org-timegrid--calendar-state-region-active state)
                      (setf (org-timegrid--scene-nodes scene)
                            (append (org-timegrid--scene-nodes scene)
                                    (list (org-timegrid--shape-node
                                           'status 'rect 10 10 5 5 :fill "#abcdef")))))
                    scene))))
       (org-timegrid--with-update 'preserve
         (setq org-timegrid--state
               (org-timegrid--calendar-state-create
                :week-start 100 :cursor-visible t
                :cursor (org-timegrid--cursor-state-create :surface 'grid :day 0 :minute 600)))
         (setf (org-timegrid--calendar-state-mark org-timegrid--state)
               (- (org-timegrid--cursor-calendar-minute) 15)))
       (let ((before header-line-format))
         (org-timegrid--with-update nil
           (setf (org-timegrid--calendar-state-region-active org-timegrid--state) t))
         (should-not (eq before header-line-format))
         (should (string-match-p "#abcdef" (plist-get (cdr (get-text-property 0 'display header-line-format)) :data))))))))

(ert-deftest org-timegrid-contract-timed-previews-reuse-header-images ()
  "Comparing every surface must not repaint an unchanged header during a drag."
  (org-timegrid-contract-test--display
   (let* ((event (org-timegrid-event-create :id 'plan :title "Plan" :start 144600 :end 144660))
          (blocks (org-timegrid-events-to-blocks (list event) 100)))
     (org-timegrid--with-update 'preserve
       (setq org-timegrid--state (org-timegrid--calendar-state-create
                                  :week-start 100 :events (list event) :blocks blocks)))
     (let ((before header-line-format))
       (cl-letf (((symbol-function 'org-timegrid-svg-header)
                  (lambda (&rest _) (error "Unchanged header was repainted"))))
         (org-timegrid--set-preview (org-timegrid--keyboard-proposal (car blocks) 15 0 nil))
         (should (eq before header-line-format))
         (org-timegrid--clear-preview)
         (should (eq before header-line-format)))))))

(ert-deftest org-timegrid-contract-new-block-paint-properties-repaint-interiors ()
  "Moving a block must not hide changes to existing or newly added paint data."
  (dolist (property '(:preview :extra-paint))
    (let* ((before '(:id one :x 10 :y 100 :width 100 :height 200))
           (after (plist-put (copy-sequence before) :y 110))
           (painted (plist-put (copy-sequence after) property t))
           (old (org-timegrid--scene-create :nodes (list (cons 'block before)) :geometry (list before)))
           (new (org-timegrid--scene-create :nodes (list (cons 'block painted)) :geometry (list after))))
      (should (seq-some (lambda (rectangle)
                          (<= (plist-get rectangle :y) 200
                              (+ (plist-get rectangle :y) (plist-get rectangle :height))))
                        (org-timegrid--scene-damage old new))))))

(ert-deftest org-timegrid-contract-org-reader-uses-query-options-not-view-state ()
  "Source caching receives explicit hints and always covers the requested data."
  (require 'org-timegrid-org)
  (with-temp-buffer
    (org-mode)
    (insert "* Plan\n<2026-10-26 Mon 10:00-11:00>\n")
    (let* ((source (current-buffer))
           (start (* 1440 (calendar-absolute-from-gregorian '(10 26 2026))))
           (end (+ start 1440))
           (org-timegrid-days 'not-a-view)
           (org-timegrid-query-options nil)
           (options (list :force t :cache-range (cons (+ start 600) (+ start 601))))
           (backend (org-timegrid-backend-create
                     :list-function
                     (lambda (from to)
                       (should (equal options org-timegrid-query-options))
                       (with-current-buffer source
                         (org-timegrid-org--cached-events "dummy.org" from to))))))
      (should (= 1 (length (org-timegrid-backend-list backend start end options))))
      (should (= start (nth 1 org-timegrid-org--events-cache)))
      (should (= end (nth 2 org-timegrid-org--events-cache)))
      (should-not org-timegrid-query-options))))

;;; org-timegrid-contract-test.el ends here
