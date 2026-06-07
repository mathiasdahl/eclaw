;;; eclaw-web-search.el --- Web search and fetch tools for eclaw  -*- lexical-binding: nil -*-

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
;; Provider-based `web_search' and `web_fetch' tools (Jina by default).
;; Adding a provider = two functions + one registry row.
;;

;;; Code:

(require 'json)
(require 'subr-x)
(require 'url-parse)
(require 'eclaw-tools)
(require 'eclaw-http)

(defgroup eclaw-web-search nil
  "Web search and fetch tools for eclaw."
  :group 'eclaw)

(defcustom eclaw-web-search-enabled t
  "When non-nil, register `web_search' and `web_fetch' tools."
  :type 'boolean
  :group 'eclaw-web-search)

(defcustom eclaw-web-search-provider 'jina
  "Active web search/fetch provider."
  :type '(choice (const :tag "Jina" jina))
  :group 'eclaw-web-search)

(defcustom eclaw-jina-api-key nil
  "Optional Jina API key override.
When nil, `eclaw-get-jina-api-key' reads `JINA_API_KEY' from the environment.
Get a free key at https://jina.ai/?sui=apikey — required for `web_search'."
  :type 'string
  :group 'eclaw-web-search)

(defun eclaw-get-jina-api-key ()
  "Return the configured Jina API key string, or nil when unset."
  (let ((from-var (and (stringp eclaw-jina-api-key)
                       (not (string-empty-p eclaw-jina-api-key))
                       eclaw-jina-api-key))
        (from-env (getenv "JINA_API_KEY")))
    (or from-var
        (and from-env (not (string-empty-p from-env)) from-env))))

(defcustom eclaw-jina-search-url "https://s.jina.ai/"
  "Jina Search API endpoint URL."
  :type 'string
  :group 'eclaw-web-search)

(defcustom eclaw-jina-reader-url "https://r.jina.ai/"
  "Jina Reader API endpoint URL."
  :type 'string
  :group 'eclaw-web-search)

(defcustom eclaw-web-search-default-max-results 5
  "Default maximum search results when `max_results' is omitted."
  :type 'integer
  :group 'eclaw-web-search)

(defcustom eclaw-web-search-max-results 10
  "Hard cap on search results returned to the model."
  :type 'integer
  :group 'eclaw-web-search)

(defcustom eclaw-web-fetch-max-chars 32000
  "Maximum characters returned by `web_fetch' before truncation."
  :type 'integer
  :group 'eclaw-web-search)

(defconst eclaw--ws-url-blocked-msg
  "Error: URL not allowed (eclaw web fetch policy)."
  "Denial message for blocked `web_fetch' URLs.")

(defvar eclaw--ws-provider-alist
  '((jina . (:search eclaw--ws-jina-search
              :fetch eclaw--ws-jina-fetch)))
  "Alist mapping provider symbol to (:search FN :fetch FN) plists.")

(defun eclaw--ws-effective-max-results (max-results)
  "Return clamped result count from optional MAX-RESULTS."
  (let ((n (if (and max-results (integerp max-results) (> max-results 0))
               max-results
             eclaw-web-search-default-max-results)))
    (min n eclaw-web-search-max-results)))

(defun eclaw--ws-jina-headers ()
  "Return Jina API request headers alist."
  (let ((headers '(("Accept" . "application/json")
                   ("Content-Type" . "application/json"))))
    (when-let ((key (eclaw-get-jina-api-key)))
      (push (cons "Authorization" (concat "Bearer " key)) headers))
    headers))

(defun eclaw--ws-format-search-results (items)
  "Format search ITEMS alist list into numbered model-ready text."
  (if (null items)
      "(no results)"
    (let (lines n)
      (setq n 0)
      (dolist (item items)
        (setq n (1+ n))
        (let* ((title (or (alist-get 'title item) "(untitled)"))
               (url (or (alist-get 'url item) ""))
               (snippet (or (alist-get 'description item)
                            (alist-get 'content item)
                            "")))
          (push (format "%d. %s\n   URL: %s\n   Snippet: %s"
                        n title url snippet)
                lines)))
      (string-join (nreverse lines) "\n\n"))))

(defun eclaw--ws-truncate-fetch-content (content)
  "Return CONTENT truncated to `eclaw-web-fetch-max-chars' when needed."
  (let ((max-chars eclaw-web-fetch-max-chars))
    (if (<= (length content) max-chars)
        content
      (concat (substring content 0 max-chars)
              (format "\n[eclaw: content truncated to %d characters]"
                      max-chars)))))

(defun eclaw--ws-parse-url (url)
  "Return parsed URL object for string URL, or nil when invalid."
  (condition-case nil
      (url-generic-parse-url url)
    (error nil)))

(defun eclaw--ws-host-downcase (host)
  "Return downcased HOST string, or empty string when nil."
  (downcase (or host "")))

(defun eclaw--ws-ipv4-p (host)
  "Non-nil when HOST looks like an IPv4 address."
  (and host (string-match-p "\\`[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\'" host)))

(defun eclaw--ws-ipv4-private-p (host)
  "Non-nil when HOST is a private or metadata IPv4 address."
  (when (eclaw--ws-ipv4-p host)
    (let ((octets (mapcar #'string-to-number (split-string host "\\."))))
      (when (= (length octets) 4)
        (let ((a (nth 0 octets))
              (b (nth 1 octets))
              (c (nth 2 octets))
              (d (nth 3 octets)))
          (or (= a 127)
              (= a 10)
              (and (= a 172) (<= 16 b 31))
              (and (= a 192) (= b 168))
              (and (= a 169) (= b 254) (= c 169) (= d 254))))))))

(defun eclaw--ws-normalize-host (host)
  "Return HOST without IPv6 zone/bracket wrappers, downcased."
  (let ((h (downcase (or host ""))))
    (if (and (string-prefix-p "[" h) (string-suffix-p "]" h))
        (substring h 1 -1)
      h)))

(defun eclaw--ws-ipv6-local-p (host)
  "Non-nil when HOST is IPv6 loopback or link-local."
  (let ((h (eclaw--ws-normalize-host host)))
    (or (string-equal h "::1")
        (string-prefix-p "fe80:" h))))

(defun eclaw--ws-host-blocked-p (host)
  "Non-nil when HOST must not be fetched (SSRF policy)."
  (let ((h (eclaw--ws-normalize-host host)))
    (or (string-empty-p h)
        (string-equal h "localhost")
        (string-match-p "\\.local\\'" h)
        (eclaw--ws-ipv4-private-p h)
        (eclaw--ws-ipv6-local-p h))))

(defun eclaw--ws-url-allowed-p (url)
  "Non-nil when URL passes `web_fetch' SSRF policy."
  (when-let* ((parsed (eclaw--ws-parse-url url))
              (scheme (url-type parsed))
              (host (url-host parsed)))
    (and (member scheme '("http" "https"))
         (not (eclaw--ws-host-blocked-p host)))))

(defun eclaw--ws-provider-fetch-fn (provider)
  "Return fetch function symbol for PROVIDER, or signal when unknown."
  (if-let* ((entry (assoc provider eclaw--ws-provider-alist))
            (fn (plist-get (cdr entry) :fetch)))
      fn
    (error "eclaw: unknown web search provider %S" provider)))

(defun eclaw--ws-provider-search-fn (provider)
  "Return search function symbol for PROVIDER, or signal when unknown."
  (if-let* ((entry (assoc provider eclaw--ws-provider-alist))
            (fn (plist-get (cdr entry) :search)))
      fn
    (error "eclaw: unknown web search provider %S" provider)))

(defun eclaw--ws-jina-search (query max-results)
  "Search the web via Jina; return model-ready text or an error string."
  (let ((q (string-trim (or query ""))))
    (cond
     ((string-empty-p q)
      "Error: web_search requires non-empty query.")
     ((not (eclaw-get-jina-api-key))
      "Error: JINA_API_KEY is required for web_search. Get a free key at https://jina.ai/?sui=apikey")
     (t
      (condition-case err
          (let* ((num (eclaw--ws-effective-max-results max-results))
                 (response
                  (eclaw-http-post-json
                   eclaw-jina-search-url
                   (eclaw--ws-jina-headers)
                   `((q . ,q) (num . ,num))))
                 (items (or (alist-get 'data response) '())))
            (if (listp items)
                (eclaw--ws-format-search-results items)
              (format "Error: unexpected Jina search response shape: %S"
                      (eclaw--truncate-string (prin1-to-string response) 200))))
        (error
         (format "Error: Jina search failed: %s" (error-message-string err))))))))

(defun eclaw--ws-jina-extract-fetch-content (response)
  "Return page content string from parsed Jina reader RESPONSE alist."
  (or (when-let ((data (alist-get 'data response)))
        (if (stringp data)
            data
          (alist-get 'content data)))
      (alist-get 'content response)))

(defun eclaw--ws-jina-parse-reader-text (text)
  "Return page content from Jina Reader plain-text response TEXT."
  (let ((body (string-trim (or text ""))))
    (cond
     ((string-empty-p body) nil)
     ((string-match "Markdown Content:\n" body)
      (string-trim (substring body (match-end 0))))
     (t body))))

(defun eclaw--ws-jina-parse-reader-body (text)
  "Return page content from Jina Reader response body TEXT (JSON or plain text)."
  (let ((trimmed (string-trim-left (or text ""))))
    (or (when (string-prefix-p "{" trimmed)
          (condition-case nil
              (let ((json-object-type 'alist)
                    (json-array-type 'list)
                    (json-key-type 'symbol))
                (eclaw--ws-jina-extract-fetch-content
                 (json-read-from-string trimmed)))
            (error nil)))
        (eclaw--ws-jina-parse-reader-text text))))

(defun eclaw--ws-jina-fetch-response (url)
  "Return Jina reader content for allowed URL, or nil when empty."
  (let* ((buffer
          (eclaw--http-post
           eclaw-jina-reader-url
           (eclaw--ws-jina-headers)
           (json-encode `((url . ,url)))))
         (text (eclaw-http-read-response buffer))
         (content (eclaw--ws-jina-parse-reader-body text)))
    (when (and content (not (string-empty-p content)))
      content)))

(defun eclaw--ws-jina-fetch (url)
  "Fetch URL content via Jina Reader; return text or an error string."
  (let ((target (string-trim (or url ""))))
    (cond
     ((string-empty-p target)
      "Error: web_fetch requires non-empty url.")
     ((not (eclaw--ws-url-allowed-p target))
      eclaw--ws-url-blocked-msg)
     (t
      (condition-case err
          (if-let ((content (eclaw--ws-jina-fetch-response target)))
              (eclaw--ws-truncate-fetch-content content)
            (format "Error: Jina reader returned no content for %s"
                    (eclaw--truncate-string target 120)))
        (error
         (format "Error: Jina reader failed: %s" (error-message-string err))))))))

(defun eclaw-web-search (query &optional max-results)
  "Search the web using `eclaw-web-search-provider'; return result text."
  (funcall (eclaw--ws-provider-search-fn eclaw-web-search-provider)
           query max-results))

(defun eclaw-web-fetch (url)
  "Fetch URL content using `eclaw-web-search-provider'; return result text."
  (funcall (eclaw--ws-provider-fetch-fn eclaw-web-search-provider) url))

(when eclaw-web-search-enabled
  (eclaw-deftool web_search
    "Search the live web for current information. Returns numbered results with URLs and snippets."
    ((query :string "Search query string.")
     (max_results :integer
                  "Maximum number of results (default 5; hard cap 10)."
                  :optional))
    (if query
        (eclaw-web-search query max_results)
      "Error: web_search requires \"query\" in arguments."))
  (eclaw-deftool web_fetch
    "Fetch and read the main text content of a specific URL."
    ((url :string "HTTP or HTTPS URL to fetch."))
    (if url
        (eclaw-web-fetch url)
      "Error: web_fetch requires \"url\" in arguments.")))

(provide 'eclaw-web-search)
;;; eclaw-web-search.el ends here
