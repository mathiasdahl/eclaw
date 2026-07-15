;;; smoke/get-datetime.el — get_datetime tool output.

(require 'eclaw)
(require 'json)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke get-datetime FAIL: %s" label)))

(let* ((session-time (encode-time 5 9 15 14 7 2026))
       (session-iso (eclaw--iso-timestamp session-time))
       (result))
  (setq eclaw--session-started session-time)
  (setq result (eclaw-tool-get-datetime))
  (let* ((tools (eclaw-tool-definitions))
         (tool (seq-find (lambda (entry)
                           (equal (alist-get 'name (alist-get 'function entry))
                                  "get_datetime"))
                         tools))
         (params (alist-get 'parameters (alist-get 'function tool)))
         (encoded (json-encode params)))
    (smoke--assert "parameters type object"
                   (string-match-p "\"type\":\"object\"" encoded))
    (smoke--assert "parameters properties not null"
                   (and (string-match-p "\"properties\":" encoded)
                        (not (string-match-p "\"properties\":null" encoded)))))
  (let ((stale '((type . "object") (properties) (required . [])))
        (encoded)
        (tool-entry))
    (puthash "get_datetime"
             (list :description "stale"
                   :parameters stale
                   :handler #'eclaw-tool-get-datetime
                   :risk :read)
             eclaw--tool-registry)
    (setq tool-entry (seq-find (lambda (entry)
                                 (equal (alist-get 'name
                                                   (alist-get 'function entry))
                                        "get_datetime"))
                               (eclaw-tool-definitions)))
    (setq encoded (json-encode (alist-get 'parameters
                                          (alist-get 'function tool-entry))))
    (smoke--assert "stale nil properties normalized in tool-definitions"
                   (and (string-match-p "\"properties\":{}" encoded)
                        (not (string-match-p "\"properties\":null" encoded)))))
  (smoke--assert "now line present"
                 (string-match-p "^now: " result))
  (smoke--assert "session_started line present"
                 (string-match-p (format "session_started: %s"
                                         (regexp-quote session-iso))
                                 result))
  (smoke--assert "now includes time of day"
                 (string-match-p "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]" result))

  (setq eclaw--session-started nil)
  (setq result (eclaw-tool-get-datetime))
  (smoke--assert "now line present without session"
                 (string-match-p "^now: " result))
  (smoke--assert "session_started omitted without session"
                 (not (string-match-p "session_started:" result)))

  (message "smoke get-datetime: OK"))
