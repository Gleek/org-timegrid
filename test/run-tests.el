;;; run-tests.el --- Run all org-timegrid tests -*- lexical-binding: t; -*-

(setq load-prefer-newer t)
(require 'ert)

(dolist (file (directory-files (file-name-directory load-file-name)
                              t "-test\\.el\\'"))
  (load file nil t t))

(ert-run-tests-batch-and-exit)
;;; run-tests.el ends here
