;;; smoke/load.el — require eclaw and basic feature checks.

(require 'eclaw)

(unless (featurep 'eclaw-http)
  (error "smoke load: eclaw-http feature missing"))

(unless (featurep 'eclaw-tools)
  (error "smoke load: eclaw-tools feature missing"))

(unless (featurep 'eclaw-web-search)
  (error "smoke load: eclaw-web-search feature missing"))

(unless (fboundp 'eclaw-chat)
  (error "smoke load: eclaw-chat not bound"))

(when eclaw-web-search-enabled
  (unless (gethash "web_search" eclaw--tool-registry)
    (error "smoke load: web_search tool not registered"))
  (unless (gethash "web_fetch" eclaw--tool-registry)
    (error "smoke load: web_fetch tool not registered")))

(message "smoke load: OK")
