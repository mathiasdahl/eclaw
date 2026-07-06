;;; smoke/web-search.el — offline SSRF policy and registry checks.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke web-search FAIL: %s" label)))

(smoke--assert "eclaw-web-search feature loaded"
                 (featurep 'eclaw-web-search))

(let ((eclaw-jina-api-key "smoke-test-key"))
  (let ((headers (eclaw--ws-jina-headers)))
    (smoke--assert "Jina Authorization uses API key string"
                     (string-equal (cdr (assoc "Authorization" headers))
                                   "Bearer smoke-test-key"))))

(let ((eclaw-jina-api-key nil)
      (saved-key (getenv "JINA_API_KEY")))
  (setenv "JINA_API_KEY" nil)
  (unwind-protect
      (smoke--assert "web_search requires API key"
                       (string-match-p "JINA_API_KEY is required"
                                         (eclaw-web-search "emacs" 2)))
    (when saved-key (setenv "JINA_API_KEY" saved-key))))

(smoke--assert "reader plain-text body parsed"
                 (string-equal "Hello world"
                               (eclaw--ws-jina-parse-reader-text
                                "Title: Example\n\nMarkdown Content:\nHello world")))

(smoke--assert "https public URL allowed"
                 (eclaw--ws-url-allowed-p "https://example.com/article"))

(smoke--assert "http public URL allowed"
                 (eclaw--ws-url-allowed-p "http://example.org/"))

(smoke--assert "127.0.0.1 blocked"
                 (not (eclaw--ws-url-allowed-p "http://127.0.0.1/")))

(smoke--assert "localhost blocked"
                 (not (eclaw--ws-url-allowed-p "http://localhost/")))

(smoke--assert "metadata IP blocked"
                 (not (eclaw--ws-url-allowed-p "http://169.254.169.254/latest/meta-data")))

(smoke--assert "10/8 blocked"
                 (not (eclaw--ws-url-allowed-p "http://10.0.0.1/")))

(smoke--assert "172.16/12 blocked"
                 (not (eclaw--ws-url-allowed-p "http://172.16.0.1/")))

(smoke--assert "192.168/16 blocked"
                 (not (eclaw--ws-url-allowed-p "http://192.168.1.1/")))

(smoke--assert ".local hostname blocked"
                 (not (eclaw--ws-url-allowed-p "http://printer.local/setup")))

(smoke--assert "IPv6 loopback blocked"
                 (not (eclaw--ws-url-allowed-p "http://[::1]/")))

(smoke--assert "non-http scheme blocked"
                 (not (eclaw--ws-url-allowed-p "ftp://example.com/file")))

(let ((result (eclaw-web-fetch "http://127.0.0.1/")))
  (smoke--assert "web_fetch rejects blocked URL without HTTP"
                 (string-equal result eclaw--ws-url-blocked-msg)))

(when eclaw-web-search-enabled
  (smoke--assert "web_search enabled in policy by default"
                 (eclaw-tool-policy-enabled-p "web_search"))
  (smoke--assert "web_fetch enabled in policy by default"
                 (eclaw-tool-policy-enabled-p "web_fetch")))

(smoke--assert "web_search registered"
               (gethash "web_search" eclaw--tool-registry))
(smoke--assert "web_fetch registered"
               (gethash "web_fetch" eclaw--tool-registry))

(message "smoke web-search: OK")
