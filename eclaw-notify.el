;;; eclaw-notify.el --- Web Push notifications for eclaw  -*- lexical-binding: t -*-

;; Copyright (C) 2026-2026  Mathias Dahl

;; Author: Mathias Dahl <mathias.dahl@gmail.com>
;; Maintainer: Mathias Dahl <mathias.dahl@gmail.com>

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;;
;; Browser Web Push for the eclaw chat UI.  Subscription storage and
;; orchestration live here; VAPID signing and payload encryption are delegated
;; to an external Python script (`scripts/eclaw-web-push.py' via pywebpush).

;;; Code:

(require 'json)
(require 'subr-x)
(require 'eclaw-tools)

(declare-function eclaw--folder "eclaw" ())
(declare-function eclaw-debug-message "eclaw" (format-string &rest args))
(declare-function eclaw-message "eclaw" (format-string &rest args))
(declare-function eclaw-progress-message "eclaw" (format-string &rest args))

(defvar eclaw-notify--repo-dir nil
  "Directory containing `eclaw.el', set when this file loads.")

(defvar eclaw-notify--vapid-cache nil
  "Cached alist from `eclaw-notify--vapid-file', or nil to reload.")

(defvar eclaw-notify--subscriptions-cache nil
  "Cached subscription list, or nil to reload from disk.")

(defgroup eclaw-notify nil
  "Web Push notifications for eclaw."
  :group 'eclaw
  :prefix "eclaw-notify-")

(defcustom eclaw-notify-enabled nil
  "When non-nil, enable the Web Push subsystem (subscribe UI and sends).
Requires VAPID keys, at least one stored subscription, and
`eclaw-notify-push-program'."
  :type 'boolean
  :group 'eclaw-notify)

(defcustom eclaw-notify-on-chat-complete t
  "When non-nil, send a Web Push when `eclaw-chat' completes.
Requires `eclaw-notify-enabled' and configured push infrastructure."
  :type 'boolean
  :group 'eclaw-notify)

(defcustom eclaw-notify-send-enabled nil
  "When non-nil, default tool policy enables the `send_push' tool."
  :type 'boolean
  :group 'eclaw-notify)

(defcustom eclaw-notify-title "eclaw"
  "Notification title sent after each completed chat turn."
  :type 'string
  :group 'eclaw-notify)

(defcustom eclaw-notify-body-max-length 240
  "Maximum characters of the assistant reply included in push body text."
  :type 'integer
  :group 'eclaw-notify)

(defcustom eclaw-notify-click-url nil
  "URL opened when the user clicks a push notification.
Set to your deployed chat page (for example \"https://example.com/secretpath/\")."
  :type 'string
  :group 'eclaw-notify)

(defcustom eclaw-notify-vapid-file nil
  "Path to JSON file with VAPID keys for Web Push.
When nil, uses `<eclaw-folder>/push-vapid.json'.  Expected keys:
`publicKey', `privateKey', and `subject' (mailto: contact for VAPID)."
  :type 'file
  :group 'eclaw-notify)

(defcustom eclaw-notify-subscriptions-file nil
  "Path to JSON file listing browser push subscriptions.
When nil, uses `<eclaw-folder>/push-subscriptions.json'."
  :type 'file
  :group 'eclaw-notify)

(defcustom eclaw-notify-subscribe-secret nil
  "Optional shared secret required on POST /api/push/subscribe.
Set in init.el; never expose to the model or skills."
  :type 'string
  :group 'eclaw-notify)

(defcustom eclaw-notify-push-program nil
  "Absolute path to Python interpreter with pywebpush installed.
Example: \"~/.local/share/eclaw-venv/bin/python3\"."
  :type 'file
  :group 'eclaw-notify)

(defcustom eclaw-notify-push-script nil
  "Path to `eclaw-web-push.py'.  When nil, uses `scripts/eclaw-web-push.py'
under the eclaw repo directory."
  :type 'file
  :group 'eclaw-notify)

(defconst eclaw-notify-send-max-title-length 100
  "Maximum characters allowed in a `send_push' title.")

(defconst eclaw-notify-send-max-body-length 500
  "Maximum characters allowed in a `send_push' body.")

(defun eclaw-notify--non-empty-string-p (value)
  "Non-nil when VALUE is a non-empty string after trim."
  (and (stringp value)
       (not (string-empty-p (string-trim value)))))

(defun eclaw-notify--repo-dir ()
  "Return directory containing eclaw sources."
  (or eclaw-notify--repo-dir
      (when-let ((file (locate-file "eclaw.el" load-path)))
        (setq eclaw-notify--repo-dir (file-name-directory file)))
      (error "Cannot locate eclaw repo; set `eclaw-notify-push-script'")))

(defun eclaw-notify--vapid-file ()
  "Return absolute path to the VAPID key JSON file."
  (or (and eclaw-notify-vapid-file
           (expand-file-name eclaw-notify-vapid-file))
      (expand-file-name "push-vapid.json" (eclaw--folder))))

(defun eclaw-notify--subscriptions-file ()
  "Return absolute path to push subscription storage."
  (or (and eclaw-notify-subscriptions-file
           (expand-file-name eclaw-notify-subscriptions-file))
      (expand-file-name "push-subscriptions.json" (eclaw--folder))))

(defun eclaw-notify--push-script ()
  "Return absolute path to the external push sender script."
  (or (and eclaw-notify-push-script
           (expand-file-name eclaw-notify-push-script))
      (expand-file-name "scripts/eclaw-web-push.py" (eclaw-notify--repo-dir))))

(defun eclaw-notify--invalidate-vapid-cache ()
  (setq eclaw-notify--vapid-cache nil))

(defun eclaw-notify--invalidate-subscriptions-cache ()
  (setq eclaw-notify--subscriptions-cache nil))

(defun eclaw-notify--json-get (key alist)
  "Return value for string KEY in JSON object ALIST, or nil.
Uses `assoc-string' because `alist-get' compares with `eq' by default."
  (cdr (assoc-string key alist)))


(defun eclaw-notify--read-vapid ()
  "Return VAPID alist from disk, or nil when missing/invalid."
  (unless eclaw-notify--vapid-cache
    (let ((file (eclaw-notify--vapid-file)))
      (setq eclaw-notify--vapid-cache
            (when (file-readable-p file)
              (let ((json-object-type 'alist)
                    (json-array-type 'list)
                    (json-key-type 'string))
                (condition-case nil
                    (json-read-file file)
                  (error nil)))))))
  eclaw-notify--vapid-cache)

(defun eclaw-notify-vapid-public-key ()
  "Return URL-safe base64 VAPID public key string, or nil when unavailable."
  (let ((vapid (eclaw-notify--read-vapid)))
    (when vapid
      (let ((key (or (eclaw-notify--json-get "publicKey" vapid)
                     (eclaw-notify--json-get "public_key" vapid))))
        (when (and (stringp key) (not (string-empty-p key)))
          key)))))


(defun eclaw-notify--load-subscriptions-from-disk ()
  "Return subscription list from `eclaw-notify--subscriptions-file'."
  (let ((file (eclaw-notify--subscriptions-file)))
    (if (file-readable-p file)
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'string))
          (condition-case nil
              (let ((data (json-read-file file)))
                (if (listp data) data '()))
            (error '())))
      '())))

(defun eclaw-notify--load-subscriptions ()
  "Return cached subscription list."
  (or eclaw-notify--subscriptions-cache
      (setq eclaw-notify--subscriptions-cache
            (eclaw-notify--load-subscriptions-from-disk))))

(defun eclaw-notify--save-subscriptions (subs)
  "Persist SUBS list to `eclaw-notify--subscriptions-file'."
  (let ((file (eclaw-notify--subscriptions-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (let ((json-object-type 'alist)
            (json-array-type 'list)
            (json-key-type 'string))
        (insert (json-encode subs))
        (write-region (point-min) (point-max) file nil 'silent)))
    (setq eclaw-notify--subscriptions-cache subs)))

(defun eclaw-notify--subscription-endpoint (sub)
  "Return endpoint string from subscription alist SUB, or nil."
  (let ((endpoint (eclaw-notify--json-get "endpoint" sub)))
    (when (and (listp sub) (stringp endpoint))
      endpoint)))


(defun eclaw-notify--subscription-valid-p (sub)
  "Non-nil when SUB looks like a Web Push subscription object."
  (and (listp sub)
       (let ((endpoint (eclaw-notify--json-get "endpoint" sub)))
         (and (stringp endpoint) (not (string-empty-p endpoint))))
       (let ((keys (eclaw-notify--json-get "keys" sub)))
         (and (listp keys)
              (stringp (eclaw-notify--json-get "p256dh" keys))
              (stringp (eclaw-notify--json-get "auth" keys))))))


(defun eclaw-notify--normalize-subscription (sub)
  "Return subscription alist with string keys, or signal on invalid SUB."
  (unless (eclaw-notify--subscription-valid-p sub)
    (error "invalid push subscription JSON"))
  (let ((keys (eclaw-notify--json-get "keys" sub)))
    (list (cons "endpoint" (eclaw-notify--json-get "endpoint" sub))
          (cons "keys"
                (list (cons "p256dh" (eclaw-notify--json-get "p256dh" keys))
                      (cons "auth" (eclaw-notify--json-get "auth" keys))))
          (cons "expirationTime"
                (or (eclaw-notify--json-get "expirationTime" sub) :json-null)))))


(defun eclaw-notify-subscribe-secret-valid-p (secret)
  "Non-nil when SECRET matches `eclaw-notify-subscribe-secret'."
  (or (null eclaw-notify-subscribe-secret)
      (string-empty-p eclaw-notify-subscribe-secret)
      (and (stringp secret)
           (string= secret eclaw-notify-subscribe-secret))))

(defun eclaw-notify-add-subscription (sub)
  "Store subscription SUB; replace any existing entry with the same endpoint."
  (let* ((normalized (eclaw-notify--normalize-subscription sub))
         (endpoint (eclaw-notify--subscription-endpoint normalized))
         (subs (seq-remove
                (lambda (existing)
                  (string= endpoint (eclaw-notify--subscription-endpoint existing)))
                (eclaw-notify--load-subscriptions))))
    (eclaw-notify--save-subscriptions (append subs (list normalized)))
    (eclaw-debug-message "eclaw notify: stored push subscription for %s" endpoint)
    t))

(defun eclaw-notify-remove-subscription (endpoint)
  "Remove subscription with ENDPOINT; return t when one was removed."
  (unless (and (stringp endpoint) (not (string-empty-p endpoint)))
    (error "missing subscription endpoint"))
  (let* ((subs (eclaw-notify--load-subscriptions))
         (remaining (seq-remove
                     (lambda (sub)
                       (string= endpoint (eclaw-notify--subscription-endpoint sub)))
                     subs)))
    (when (< (length remaining) (length subs))
      (eclaw-notify--save-subscriptions remaining)
      (eclaw-debug-message "eclaw notify: removed push subscription for %s" endpoint)
      t)))

(defun eclaw-notify--truncate (text)
  "Return TEXT trimmed to `eclaw-notify-body-max-length' with ellipsis."
  (let* ((clean (replace-regexp-in-string "[\r\n]+" " "
                                          (string-trim (or text ""))))
         (max-len (max 1 eclaw-notify-body-max-length)))
    (if (> (length clean) max-len)
        (concat (substring clean 0 max-len) "…")
      clean)))

(defun eclaw-notify--configured-p ()
  "Non-nil when push infrastructure is set up."
  (and eclaw-notify-push-program
       (file-readable-p (eclaw-notify--push-script))
       (file-readable-p (eclaw-notify--vapid-file))
       (eclaw-notify-vapid-public-key)
       (not (null (eclaw-notify--load-subscriptions)))))

(defun eclaw-notify--ready-p ()
  "Non-nil when push can be attempted."
  (and eclaw-notify-enabled (eclaw-notify--configured-p)))


(defun eclaw-notify-message (title body &optional url)
  "Send Web Push with TITLE and BODY to all stored subscriptions.
Optional URL is opened when the user clicks the notification.
No-op when push is not configured; errors are logged and ignored."
  (when (eclaw-notify--ready-p)
    (let* ((script (eclaw-notify--push-script))
         (vapid-file (eclaw-notify--vapid-file))
         (subs-file (eclaw-notify--subscriptions-file))
         (click-url (or url eclaw-notify-click-url ""))
         (args (list script
                     "--vapid-file" vapid-file
                     "--subscriptions-file" subs-file
                     "--title" (or title eclaw-notify-title)
                     "--body" (or body "")
                     "--url" click-url)))
    (condition-case err
        (let ((status
               (apply #'call-process eclaw-notify-push-program nil
                      '(nil . "eclaw notify push error") nil args)))
          (when (and (numberp status) (not (zerop status)))
            (eclaw-debug-message "eclaw notify: push script exit %s" status))
          (setq eclaw-notify--subscriptions-cache nil)
          status)
      (error
       (eclaw-debug-message "eclaw notify: push failed: %s"
                            (error-message-string err))
       nil)))))

(defun eclaw-notify-send (title body &optional url)
  "Send Web Push with TITLE and BODY via `eclaw-notify-message'.
Optional URL is opened when the user clicks the notification.
Return a status string."
  (let* ((subj (string-trim (or title "")))
         (text (string-trim (or body ""))))
    (cond
     ((not (eclaw-notify--non-empty-string-p subj))
      "Error: send_push requires non-empty title.")
     ((not (eclaw-notify--non-empty-string-p text))
      "Error: send_push requires non-empty body.")
     ((> (length subj) eclaw-notify-send-max-title-length)
      (format "Error: send_push title exceeds max length (%d)."
              eclaw-notify-send-max-title-length))
     ((> (length text) eclaw-notify-send-max-body-length)
      (format "Error: send_push body exceeds max length (%d)."
              eclaw-notify-send-max-body-length))
     ((not (eclaw-notify--ready-p))
      "Error: push notifications are not configured or disabled.")
     (t
      (eclaw-progress-message "eclaw: send_push %s" subj)
      (let ((status (eclaw-notify-message subj text url)))
        (cond
         ((and (numberp status) (zerop status)) "Push notification sent.")
         ((numberp status)
          (format "Error: push script exit %s." status))
         (t "Error: push notification send failed.")))))))

(defun eclaw-notify--send-push-parameters-schema ()
  "Return JSON Schema parameters object for `send_push'."
  `((type . "object")
    (properties
     . ((title . ((type . "string")
                   (description . "Notification title.")))
        (body . ((type . "string")
                 (description . "Notification body text.")))
        (url . ((type . "string")
                (description . "Optional URL opened when the notification is clicked.")))))
    (required . ["title" "body"])))

(defun eclaw-notify--register-send-push-tool ()
  "Register the `send_push' tool."
  (eclaw--register-tool
   "send_push"
   "Send a Web Push notification to subscribed browsers."
   (eclaw-notify--send-push-parameters-schema)
   (lambda (args)
     (eclaw-notify-send (alist-get 'title args)
                        (alist-get 'body args)
                        (alist-get 'url args)))
   :write))

(defun eclaw-notify-chat-complete (_prompt reply)
  "Notify after `eclaw-chat' with a preview of assistant REPLY."
  (when eclaw-notify-on-chat-complete
    (eclaw-notify-message eclaw-notify-title (eclaw-notify--truncate reply))))

(eclaw-notify--register-send-push-tool)

(when load-file-name
  (setq eclaw-notify--repo-dir (file-name-directory load-file-name)))

(provide 'eclaw-notify)
;;; eclaw-notify.el ends here
