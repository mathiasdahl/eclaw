;;; smoke/load.el — require eclaw and basic feature checks.

(require 'eclaw)

(unless (featurep 'eclaw-http)
  (error "smoke load: eclaw-http feature missing"))

(unless (featurep 'eclaw-tools)
  (error "smoke load: eclaw-tools feature missing"))

(unless (fboundp 'eclaw-chat)
  (error "smoke load: eclaw-chat not bound"))

(message "smoke load: OK")
