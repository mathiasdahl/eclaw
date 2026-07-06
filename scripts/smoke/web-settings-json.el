;;; smoke/web-settings-json.el — settings API JSON shape checks.

(require 'json)
(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke web-settings-json FAIL: %s" label)))

(defun smoke--tool-policy-json ()
  "Mirror `eclaw-web--tool-policy-json' for smoke tests without web-server."
  (mapcar
   (lambda (row)
     `(("name" . ,(plist-get row 'name))
       ("description" . ,(plist-get row 'description))
       ("risk" . ,(plist-get row 'risk))
       ("enabled" . ,(if (plist-get row 'enabled) t :json-false))))
   (eclaw-tool-policy-list)))

(defun smoke--json-bool (value)
  "Mirror `eclaw-web--json-bool'."
  (cond ((eq value :json-false) nil)
        ((eq value :json-true) t)
        (t value)))

(defun smoke--parse-tool-policy-updates (tools-alist)
  "Mirror `eclaw-web--parse-tool-policy-updates'."
  (unless (listp tools-alist)
    (error "settings body requires object \"tools\""))
  (let (updates)
    (dolist (pair tools-alist)
      (unless (stringp (car pair))
        (error "invalid tool name in settings update"))
      (let ((enabled (smoke--json-bool (cdr pair))))
        (unless (member enabled '(t nil))
          (error "tool %S enabled value must be boolean" (car pair)))
        (push (cons (car pair) enabled) updates)))
    (nreverse updates)))

(defun smoke--settings-tools-from-body (body)
  "Mirror tools extraction from `eclaw-web--handle-patch-settings'."
  (let* ((data (json-read-from-string body))
         (tools-entry (assoc-string "tools" data)))
    (when tools-entry (or (cdr tools-entry) '()))))

(let* ((tmpdir (make-temp-file "eclaw-smoke-settings-" t))
       (json-object-type 'alist)
       (json-array-type 'list)
       (json-key-type 'string))
  (setq eclaw-folder tmpdir)
  (setq eclaw--tool-policy-loaded nil)
  (setq eclaw--tool-policy nil)

  (let* ((payload `(("tools" . ,(vconcat (smoke--tool-policy-json)))
                    ("policy_file" . ,(expand-file-name "tool-policy.el" tmpdir))))
         (encoded (json-read-from-string (json-encode payload)))
         (tools (cdr (assoc-string "tools" encoded))))
    (smoke--assert "tools is a list"
                   (listp tools))
    (smoke--assert "tools is non-empty"
                   (> (length tools) 0))
    (let* ((first (car tools))
           (name (cdr (assoc-string "name" first)))
           (risk (cdr (assoc-string "risk" first)))
           (enabled (cdr (assoc-string "enabled" first))))
      (smoke--assert "first tool has name string"
                     (stringp name))
      (smoke--assert "first tool has risk string"
                     (stringp risk))
      (smoke--assert "enabled is boolean not null"
                     (member enabled '(t :json-false)))))

  (let* ((body "{\"tools\":{\"eval_elisp\":false}}")
         (tools-obj (smoke--settings-tools-from-body body))
         (updates (smoke--parse-tool-policy-updates tools-obj)))
    (smoke--assert "PATCH body exposes tools object"
                   (listp tools-obj))
    (smoke--assert "PATCH body parses eval_elisp disabled"
                   (equal updates '(("eval_elisp" . nil))))))

(message "smoke web-settings-json: OK")
