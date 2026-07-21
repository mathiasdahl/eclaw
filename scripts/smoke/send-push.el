;;; smoke/send-push.el — offline send_push tool and eclaw-notify-send checks.

(require 'eclaw)

(defvar smoke-push--call-process-calls nil
  "List of call-process invocations captured by the smoke stub.")

(defun call-process (program &rest args)
  "Smoke stub for `call-process'."
  (push (list program args) smoke-push--call-process-calls)
  0)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke send-push FAIL: %s" label)))

(smoke--assert "eclaw-notify feature loaded"
               (featurep 'eclaw-notify))

(unless eclaw-notify-send-enabled
  (smoke--assert "send_push disabled in policy by default"
                 (not (eclaw-tool-policy-enabled-p "send_push"))))

(smoke--assert "send_push registered"
               (gethash "send_push" eclaw--tool-registry))

(let ((info (gethash "send_push" eclaw--tool-registry)))
  (smoke--assert "send_push tagged :write"
                 (eq (plist-get info :risk) :write)))

(smoke--assert "empty title rejected"
               (string-match-p "requires non-empty title"
                               (eclaw-notify-send "  " "Body")))

(smoke--assert "empty body rejected"
               (string-match-p "requires non-empty body"
                               (eclaw-notify-send "Title" "")))

(smoke--assert "not configured when disabled"
               (string-match-p "not configured or disabled"
                               (eclaw-notify-send "Title" "Body")))

(let* ((tmpdir (make-temp-file "eclaw-smoke-send-push-" t))
       (vapid-file (expand-file-name "push-vapid.json" tmpdir))
       (subs-file (expand-file-name "push-subscriptions.json" tmpdir))
       (sample-sub
        '(("endpoint" . "https://push.example.com/v1/test-endpoint")
          ("keys" . (("p256dh" . "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U")
                     ("auth" . "tBHItJI5svbpez7KI0CCXg")))
          ("expirationTime" . :json-null))))
  (setq eclaw-folder tmpdir)
  (setq eclaw-notify-vapid-file vapid-file)
  (setq eclaw-notify-subscriptions-file subs-file)
  (setq eclaw-notify-push-program "/usr/bin/true")
  (setq eclaw-notify-enabled t)
  (setq eclaw-notify--vapid-cache nil)
  (setq eclaw-notify--subscriptions-cache nil)
  (setq smoke-push--call-process-calls nil)

  (with-temp-buffer
    (insert "{\"publicKey\":\"BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U\","
            "\"privateKey\":\"UUxI4O8-FbRouAevSmBQ6o18hgE4nSG3qwvJTfKc-ls\","
            "\"subject\":\"mailto:smoke@example.com\"}")
    (write-region (point-min) (point-max) vapid-file nil 'silent))

  (eclaw-notify-add-subscription sample-sub)

  (let ((result (eclaw-notify-send "Smoke title" "Smoke body")))
    (smoke--assert "send succeeds when configured"
                   (string-match-p "Push notification sent" result))
    (smoke--assert "call-process invoked once"
                   (= 1 (length smoke-push--call-process-calls))))

  (let ((info (gethash "send_push" eclaw--tool-registry))
        (handler (plist-get (gethash "send_push" eclaw--tool-registry) :handler)))
    (ignore info)
    (setq smoke-push--call-process-calls nil)
    (let ((result (funcall handler '((title . "Tool title") (body . "Tool body")))))
      (smoke--assert "tool handler succeeds"
                     (string-match-p "Push notification sent" result))
      (smoke--assert "tool handler invokes push script"
                     (= 1 (length smoke-push--call-process-calls))))))

(message "smoke send-push: OK")
