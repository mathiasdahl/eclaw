;;; smoke/describe-symbol.el — exercise describe_symbol and apropos.

(require 'eclaw)

(defun smoke--assert (label condition)
  (unless condition
    (error "smoke describe-symbol FAIL: %s" label)))

(let ((fn-result (eclaw-tool-describe-symbol "eclaw-tool-buffer-read" "function"))
      (macro-result (eclaw-tool-describe-symbol "eclaw-deftool" "function"))
      (auto-result (eclaw-tool-describe-symbol "eclaw-tool-buffer-read" "auto"))
      (var-result (eclaw-tool-describe-symbol "eclaw-debug" "variable"))
      (bad-result (eclaw-tool-describe-symbol "eclaw-smoke-no-such-symbol-xyz" "auto"))
      (apropos-result (eclaw-tool-apropos "eclaw-deftool" 5)))
  (smoke--assert "function kind has documentation"
                 (string-match-p "Documentation:" fn-result))
  (smoke--assert "function kind has arglist"
                 (string-match-p "Arglist:" fn-result))
  (smoke--assert "macro function has documentation"
                 (string-match-p "Documentation:" macro-result))
  (smoke--assert "macro function has defined-in"
                 (string-match-p "Defined in:" macro-result))
  (smoke--assert "auto kind matches function output shape"
                 (string-match-p "Kind: function" auto-result))
  (smoke--assert "variable kind has documentation"
                 (string-match-p "Documentation:" var-result))
  (smoke--assert "variable result has no Value line"
                 (not (string-match-p "^Value:" var-result)))
  (smoke--assert "unknown symbol is error string"
                 (string-match-p "^Error: describe_symbol: unknown symbol"
                                 bad-result))
  (smoke--assert "apropos finds eclaw-deftool"
                 (string-match-p "eclaw-deftool" apropos-result))
  (smoke--assert "apropos includes doc summary separator"
                 (string-match-p " — " apropos-result))
  (smoke--assert "apropos has no symbol values"
                 (not (string-match-p "Value:" apropos-result)))
  (message "smoke describe-symbol: OK"))
