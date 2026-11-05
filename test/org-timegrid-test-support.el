;;; org-timegrid-test-support.el --- Shared test helpers -*- lexical-binding: t; -*-

(require 'org-timegrid)

(defmacro org-timegrid-test--with-isolated-calendar (&rest body)
  "Run BODY with a fresh calendar, preserving any existing calendar buffer."
  (declare (indent 0) (debug t))
  (let ((saved (make-symbol "saved-calendar")))
    `(let ((,saved (get-buffer "*Org Time Grid*")))
       (when ,saved
         (with-current-buffer ,saved
           (rename-buffer (generate-new-buffer-name " *Timegrid saved calendar*"))))
       (unwind-protect
           (progn ,@body)
         (when-let* ((buffer (get-buffer "*Org Time Grid*"))) (kill-buffer buffer))
         (when (buffer-live-p ,saved)
           (with-current-buffer ,saved (rename-buffer "*Org Time Grid*")))))))

(defun org-timegrid-test--render-static ()
  "Render the static scene and retain its geometry for hit-testing assertions."
  (let* ((context (org-timegrid--capture-context))
         (scene (org-timegrid-scene-static org-timegrid--state context)))
    (setq org-timegrid--geometry (org-timegrid--scene-geometry scene)
          org-timegrid--image-height (org-timegrid--context-height context))
    (org-timegrid-svg-render scene)))

(provide 'org-timegrid-test-support)
;;; org-timegrid-test-support.el ends here
