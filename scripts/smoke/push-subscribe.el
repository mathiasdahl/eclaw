;;; smoke/push-subscribe.el — push subscription storage without live FCM.

(require 'json)
(require 'eclaw)
(require 'eclaw-notify)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke push-subscribe FAIL: %s" label)))

(let* ((tmpdir (make-temp-file "eclaw-smoke-push-" t))
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
  (setq eclaw-notify-subscribe-secret "smoke-secret")
  (setq eclaw-notify--vapid-cache nil)
  (setq eclaw-notify--subscriptions-cache nil)

  (with-temp-buffer
    (insert "{\"publicKey\":\"BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U\","
            "\"privateKey\":\"UUxI4O8-FbRouAevSmBQ6o18hgE4nSG3qwvJTfKc-ls\","
            "\"subject\":\"mailto:smoke@example.com\"}")
    (write-region (point-min) (point-max) vapid-file nil 'silent))

  (smoke--assert "subscribe secret rejects missing secret"
                 (not (eclaw-notify-subscribe-secret-valid-p nil)))
  (smoke--assert "subscribe secret accepts configured secret"
                 (eclaw-notify-subscribe-secret-valid-p "smoke-secret"))

  (smoke--assert "vapid public key loads"
                 (stringp (eclaw-notify-vapid-public-key)))

  (eclaw-notify-add-subscription sample-sub)
  (smoke--assert "subscription file written"
                 (file-readable-p subs-file))
  (let ((loaded (eclaw-notify--load-subscriptions-from-disk)))
    (smoke--assert "one subscription stored"
                   (= (length loaded) 1))
    (smoke--assert "endpoint preserved"
                   (string= (eclaw-notify--subscription-endpoint (car loaded))
                            "https://push.example.com/v1/test-endpoint")))

  (eclaw-notify-add-subscription
   '(("endpoint" . "https://push.example.com/v1/test-endpoint")
     ("keys" . (("p256dh" . "NEWKEY")
                ("auth" . "NEWAUTH")))))
  (let ((loaded (eclaw-notify--load-subscriptions-from-disk)))
    (smoke--assert "duplicate endpoint replaces subscription"
                   (and (= (length loaded) 1)
                        (string= (alist-get "p256dh" (alist-get "keys" (car loaded)))
                                 "NEWKEY"))))

  (smoke--assert "remove subscription succeeds"
                 (eclaw-notify-remove-subscription "https://push.example.com/v1/test-endpoint"))
  (smoke--assert "subscriptions empty after remove"
                 (null (eclaw-notify--load-subscriptions-from-disk)))

  (smoke--assert "truncate adds ellipsis"
                 (string-match-p "…\\'" (eclaw-notify--truncate (make-string 300 ?x)))))

(message "smoke push-subscribe: OK")
