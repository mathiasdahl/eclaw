;;; eclaw-mail.el --- Recipient-restricted email tool for eclaw  -*- lexical-binding: nil -*-

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
;; `send_email' tool: send mail only to configured work or home addresses
;; via the user's personal `mailme-mail' backend.
;;

;;; Code:

(require 'subr-x)
(require 'eclaw-tools)

(declare-function eclaw-progress-message "eclaw" (format-string &rest args))
(declare-function mailme-mail nil (body address))

(defgroup eclaw-mail nil
  "Recipient-restricted email tool for eclaw."
  :group 'eclaw)

(defcustom eclaw-mail-enabled t
  "When non-nil, register the `send_email' tool."
  :type 'boolean
  :group 'eclaw-mail)

(defcustom eclaw-mail-work-address nil
  "Work inbox for `send_email' when recipient is work.
Set in init.el; not exposed to the model."
  :type 'string
  :group 'eclaw-mail)

(defcustom eclaw-mail-home-address nil
  "Personal inbox for `send_email' when recipient is home.
Set in init.el; not exposed to the model."
  :type 'string
  :group 'eclaw-mail)

(defconst eclaw-mail-max-subject-length 500
  "Maximum characters allowed in a `send_email' subject line.")

(defconst eclaw-mail-max-body-length 8000
  "Maximum characters allowed in a `send_email' body.")

(defun eclaw-mail--non-empty-string-p (value)
  "Non-nil when VALUE is a non-empty string after trim."
  (and (stringp value)
       (not (string-empty-p (string-trim value)))))

(defun eclaw-mail--normalize-recipient (recipient)
  "Return normalized recipient symbol `work' or `home', or nil when invalid."
  (pcase (downcase (string-trim (or recipient "")))
    ("work" 'work)
    ("home" 'home)
    (_ nil)))

(defun eclaw-mail--address-for-recipient (recipient)
  "Return configured email address for normalized RECIPIENT symbol, or nil."
  (pcase recipient
    ('work
     (let ((addr (and (stringp eclaw-mail-work-address)
                      (string-trim eclaw-mail-work-address))))
       (and addr (not (string-empty-p addr)) addr)))
    ('home
     (let ((addr (and (stringp eclaw-mail-home-address)
                      (string-trim eclaw-mail-home-address))))
       (and addr (not (string-empty-p addr)) addr)))
    (_ nil)))

(defun eclaw-mail--format-body (subject body)
  "Return BODY with SUBJECT prepended for `mailme-mail'."
  (concat "Subject: " subject "\n\n" body))

(defun eclaw-mail-send (recipient subject body)
  "Send mail to RECIPIENT (`work' or `home' string) via `mailme-mail'.
SUBJECT and BODY are plain text.  Return a status string."
  (let* ((subj (string-trim (or subject "")))
         (text (or body ""))
         (who (eclaw-mail--normalize-recipient recipient)))
    (cond
     ((null who)
      "Error: send_email recipient must be work or home.")
     ((not (eclaw-mail--non-empty-string-p subj))
      "Error: send_email requires non-empty subject.")
     ((not (eclaw-mail--non-empty-string-p text))
      "Error: send_email requires non-empty body.")
     ((> (length subj) eclaw-mail-max-subject-length)
      (format "Error: send_email subject exceeds max length (%d)."
              eclaw-mail-max-subject-length))
     ((> (length text) eclaw-mail-max-body-length)
      (format "Error: send_email body exceeds max length (%d)."
              eclaw-mail-max-body-length))
     (t
      (let ((address (eclaw-mail--address-for-recipient who)))
        (cond
         ((null address)
          (format "Error: send_email address for %s is not configured."
                  (symbol-name who)))
         ((not (fboundp 'mailme-mail))
          "Error: send_email requires `mailme-mail' to be defined.")
         (t
          (eclaw-progress-message "eclaw: send_email to %s" (symbol-name who))
          (condition-case err
              (progn
                (mailme-mail (eclaw-mail--format-body subj text) address)
                (format "Email sent to %s." (symbol-name who)))
            (error
             (format "Error sending email to %s: %s"
                     (symbol-name who)
                     (error-message-string err)))))))))))

(defun eclaw-mail--send-email-parameters-schema ()
  "Return JSON Schema parameters object for `send_email'."
  `((type . "object")
    (properties
     . ((recipient . ((type . "string")
                       (description . "Recipient: work or home.")
                       (enum . ["work" "home"])))
        (subject . ((type . "string")
                    (description . "Email subject line.")))
        (body . ((type . "string")
                 (description . "Plain-text email body.")))))
    (required . ["recipient" "subject" "body"])))

(defun eclaw-mail--register-send-email-tool ()
  "Register the `send_email' tool with recipient enum in JSON schema."
  (eclaw--register-tool
   "send_email"
   "Send an email to work or home only (never to arbitrary addresses)."
   (eclaw-mail--send-email-parameters-schema)
   (lambda (args)
     (eclaw-mail-send (alist-get 'recipient args)
                      (alist-get 'subject args)
                      (alist-get 'body args)))
   :write))

(when eclaw-mail-enabled
  (eclaw-mail--register-send-email-tool))

(provide 'eclaw-mail)
;;; eclaw-mail.el ends here
