;;; smoke/web-settings-json.el — settings API JSON shape checks.

(require 'json)
(require 'eclaw)
(require 'eclaw-notify)

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

(defun smoke--parse-positive-integer (value field-name)
  "Mirror `eclaw-web--parse-positive-integer'."
  (let ((n (cond
            ((integerp value) value)
            ((and (numberp value) (= value (truncate value)))
             (truncate value))
            ((and (stringp value) (string-match-p "\\`[0-9]+\\'" value))
             (string-to-number value))
            (t (error "%s must be a positive integer" field-name)))))
    (unless (> n 0)
      (error "%s must be a positive integer" field-name))
    n))

(defun smoke--parse-boolean-setting (value field-name)
  "Mirror `eclaw-web--parse-boolean-setting'."
  (let ((enabled (smoke--json-bool value)))
    (unless (member enabled '(t nil))
      (error "%s must be a boolean" field-name))
    enabled))

(defun smoke--settings-tools-from-body (body)
  "Mirror tools extraction from `eclaw-web--handle-patch-settings'."
  (let* ((data (json-read-from-string body))
         (tools-entry (assoc-string "tools" data)))
    (when tools-entry (or (cdr tools-entry) '()))))

(defun smoke--settings-model-from-body (body)
  "Mirror model extraction from `eclaw-web--handle-patch-settings'."
  (let* ((data (json-read-from-string body))
         (model-entry (assoc-string "model" data)))
    (when model-entry (cdr model-entry))))

(defun smoke--settings-max-tokens-from-body (body)
  "Mirror max_tokens_per_prompt extraction from PATCH settings body."
  (let* ((data (json-read-from-string body))
         (entry (assoc-string "max_tokens_per_prompt" data)))
    (when entry (cdr entry))))

(defun smoke--settings-max-completions-from-body (body)
  "Mirror max_completions_per_prompt extraction from PATCH settings body."
  (let* ((data (json-read-from-string body))
         (entry (assoc-string "max_completions_per_prompt" data)))
    (when entry (cdr entry))))

(defun smoke--settings-push-on-chat-complete-from-body (body)
  "Mirror push_on_chat_complete extraction from PATCH settings body."
  (let* ((data (json-read-from-string body))
         (entry (assoc-string "push_on_chat_complete" data)))
    (when entry (cdr entry))))

(defun smoke--settings-response-alist ()
  "Mirror `eclaw-web--settings-response-alist' without web-server."
  `(("tools" . ,(vconcat (smoke--tool-policy-json)))
    ("policy_file" . ,(expand-file-name "tool-policy.el" eclaw-folder))
    ("models" . ,(vconcat eclaw-available-models))
    ("model" . ,(eclaw-normalize-model eclaw-model))
    ("max_tokens_per_prompt" . ,eclaw-max-tokens-per-prompt)
    ("max_completions_per_prompt" . ,eclaw-max-completions-per-prompt)
    ("push_on_chat_complete" . ,(if eclaw-notify-on-chat-complete t :json-false))))

(let* ((tmpdir (make-temp-file "eclaw-smoke-settings-" t))
       (json-object-type 'alist)
       (json-array-type 'list)
       (json-key-type 'string))
  (setq eclaw-folder tmpdir)
  (setq eclaw--tool-policy-loaded nil)
  (setq eclaw--tool-policy nil)

  (let* ((payload (smoke--settings-response-alist))
         (encoded (json-read-from-string (json-encode payload)))
         (tools (cdr (assoc-string "tools" encoded)))
         (models (cdr (assoc-string "models" encoded)))
         (model (cdr (assoc-string "model" encoded)))
         (max-tokens (cdr (assoc-string "max_tokens_per_prompt" encoded)))
         (max-completions (cdr (assoc-string "max_completions_per_prompt" encoded)))
         (push-on-chat-complete (cdr (assoc-string "push_on_chat_complete" encoded))))
    (smoke--assert "tools is a list"
                   (listp tools))
    (smoke--assert "tools is non-empty"
                   (> (length tools) 0))
    (smoke--assert "models is a non-empty list"
                   (and (listp models) (> (length models) 0)))
    (smoke--assert "model is a string in models"
                   (and (stringp model) (member model models)))
    (smoke--assert "max_tokens_per_prompt is positive integer"
                   (and (integerp max-tokens) (> max-tokens 0)))
    (smoke--assert "max_completions_per_prompt is positive integer"
                   (and (integerp max-completions) (> max-completions 0)))
    (smoke--assert "push_on_chat_complete is boolean not null"
                   (member push-on-chat-complete '(t :json-false)))
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
                   (equal updates '(("eval_elisp" . nil)))))

  (let* ((body "{\"model\":\"deepseek/deepseek-v4-pro\"}")
         (model-id (smoke--settings-model-from-body body)))
    (smoke--assert "PATCH body exposes model string"
                   (stringp model-id))
    (eclaw-set-model model-id)
    (smoke--assert "model update applies to eclaw-model"
                   (string= eclaw-model "deepseek/deepseek-v4-pro")))

  (let* ((body "{\"max_tokens_per_prompt\":50000,\"max_completions_per_prompt\":8}")
         (max-tokens (smoke--settings-max-tokens-from-body body))
         (max-completions (smoke--settings-max-completions-from-body body)))
    (smoke--assert "PATCH body exposes max_tokens_per_prompt"
                   (= max-tokens 50000))
    (smoke--assert "PATCH body exposes max_completions_per_prompt"
                   (= max-completions 8))
    (setq eclaw-max-tokens-per-prompt
          (smoke--parse-positive-integer max-tokens "max_tokens_per_prompt"))
    (setq eclaw-max-completions-per-prompt
          (smoke--parse-positive-integer max-completions "max_completions_per_prompt"))
    (smoke--assert "prompt limit update applies to eclaw-max-tokens-per-prompt"
                   (= eclaw-max-tokens-per-prompt 50000))
    (smoke--assert "prompt limit update applies to eclaw-max-completions-per-prompt"
                   (= eclaw-max-completions-per-prompt 8)))

  (let* ((body "{\"push_on_chat_complete\":false}")
         (value (smoke--settings-push-on-chat-complete-from-body body)))
    (smoke--assert "PATCH body exposes push_on_chat_complete"
                   (eq value :json-false))
    (setq eclaw-notify-on-chat-complete
          (smoke--parse-boolean-setting value "push_on_chat_complete"))
    (smoke--assert "push_on_chat_complete update applies to eclaw-notify-on-chat-complete"
                   (not eclaw-notify-on-chat-complete)))

  (message "smoke web-settings-json: OK"))
