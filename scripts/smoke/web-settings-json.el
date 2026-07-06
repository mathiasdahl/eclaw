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
         (tools (alist-get "tools" encoded)))
    (smoke--assert "tools is a list"
                   (listp tools))
    (smoke--assert "tools is non-empty"
                   (> (length tools) 0))
    (let* ((first (car tools))
           (name (alist-get "name" first))
           (risk (alist-get "risk" first))
           (enabled (alist-get "enabled" first)))
      (smoke--assert "first tool has name string"
                     (stringp name))
      (smoke--assert "first tool has risk string"
                     (stringp risk))
      (smoke--assert "enabled is boolean not null"
                     (member enabled '(t :json-false))))))

(message "smoke web-settings-json: OK")
