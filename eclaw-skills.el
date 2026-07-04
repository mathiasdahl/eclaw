;;; eclaw-skills.el --- Agent skills index for eclaw  -*- lexical-binding: nil -*-

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
;; Agent Skills discovery (`skills/*/SKILL.md' under `eclaw-folder'),
;; mtime-based cache, and the index block appended to the system message.
;;

;;; Code:

;; Runtime: `eclaw' loads this before `eclaw-system-message'.
(declare-function eclaw-debug-message "eclaw" (format-string &rest args))
(declare-function eclaw--folder "eclaw" ())

;;; Agent skills (Agent Skills index under `eclaw-folder')

(defvar eclaw--skills-cache nil
  "Internal plist used by `eclaw--project-skills-index'.
Keys are :folder (string directory), :signature (string), :skills (list).")

(defun eclaw--file-mtime-float (file)
  "Return modification time of FILE as a float, for stable comparisons."
  (let ((attr (file-attributes file)))
    (unless attr
      (error "Cannot stat %S" file))
    (float-time
     (if (fboundp 'file-attribute-modification-time)
         (file-attribute-modification-time attr)
       (nth 5 attr)))))

(defun eclaw--skill-yaml-get (key beg end)
  "In the current buffer, read simple `KEY: value' line between BEG and END.
Value is the rest of the line after the first colon, `string-trim'ed.
Returns nil if missing or empty."
  (save-restriction
    (narrow-to-region beg end)
    (goto-char (point-min))
    (when (re-search-forward (concat "^" (regexp-quote key) ":[ \t]*") nil t)
      (let* ((raw (buffer-substring-no-properties (point) (line-end-position)))
             (val (string-trim raw)))
        (when (and (> (length val) 1)
                   (eq (aref val 0) ?\")
                   (eq (aref val (1- (length val))) ?\"))
          (setq val (substring val 1 (1- (length val)))))
        (unless (string-empty-p val)
          val)))))

(defun eclaw--skill-fallback-description (body-beg body-end)
  "From Markdown body between BODY-BEG and BODY-END, derive a short summary."
  (save-restriction
    (narrow-to-region body-beg body-end)
    (goto-char (point-min))
    (skip-chars-forward "\n\t ")
    (cond
     ((eobp)
      "No description.")
     ((looking-at "^#\\(?:#+\\)?[ \t]+\\(.*\\)$")
      (string-trim (match-string-no-properties 1)))
     (t
      (string-trim (buffer-substring-no-properties (point) (line-end-position)))))))

(defun eclaw--parse-skill-md (filepath default-dir-name)
  "Parse SKILL.md at FILEPATH for index fields.
Return plist (:name :description :path).  DEFAULT-DIR-NAME is used when
`name' is missing from YAML frontmatter."
  (with-temp-buffer
    (insert-file-contents-literally filepath)
    (set-buffer-multibyte t)
    (let (name description body-beg)
      (goto-char (point-min))
      (if (not (looking-at "^---[ \t]*\n"))
          (setq body-beg (point-min))
        (forward-line)
        (let ((fm-start (point))
              fm-end)
          (if (not (re-search-forward "^---[ \t]*\n" nil t))
              (progn
                (setq fm-end (point-max))
                (setq name (eclaw--skill-yaml-get "name" fm-start fm-end))
                (setq description (eclaw--skill-yaml-get "description" fm-start fm-end))
                (setq body-beg (point-max)))
            (setq fm-end (match-beginning 0))
            (setq name (eclaw--skill-yaml-get "name" fm-start fm-end))
            (setq description (eclaw--skill-yaml-get "description" fm-start fm-end))
            (setq body-beg (point)))))
      (unless name
        (setq name default-dir-name))
      (unless description
        (setq description (eclaw--skill-fallback-description body-beg (point-max))))
      (list :name name
            :description description
            :path (expand-file-name filepath)))))

(defun eclaw--path-is-project-skill-md-p (path-in)
  "Non-nil if PATH-IN matches a path from `eclaw--project-skills-index'."
  (when (and path-in (not (string-empty-p path-in)))
    (let ((file (expand-file-name path-in))
          (hit nil))
      (dolist (s (or (eclaw--project-skills-index) nil))
        (when (string-equal file (plist-get s :path))
          (setq hit t)))
      hit)))

(defun eclaw--skills-load-from-directory (skills-dir)
  "Scan SKILLS-DIR once; return plist (:signature :skills).
:signature changes when any `SKILL.md' mtime changes; :skills is sorted by name."
  (if (not (file-directory-p skills-dir))
      (list :signature "" :skills nil)
    (let (parts skills)
      (dolist (entry (directory-files skills-dir nil "^[^.]" t))
        (let* ((sub (expand-file-name entry skills-dir))
               (md (expand-file-name "SKILL.md" sub)))
          (when (and (file-directory-p sub) (file-exists-p md))
            (push (format "%s:%f" md (eclaw--file-mtime-float md)) parts)
            (condition-case err
                (push (eclaw--parse-skill-md md entry) skills)
              (error (eclaw-debug-message "eclaw: skipping skill %S: %S" md err))))))
      (list :signature (mapconcat #'identity (sort parts #'string<) "|")
            :skills (sort skills (lambda (a b)
                                   (string-lessp (plist-get a :name)
                                                 (plist-get b :name))))))))

(defun eclaw--project-skills-index ()
  "Return cached list of skill plists under `eclaw-folder'/`skills/', or nil if none.
List is sorted by name."
  (let ((folder (eclaw--folder)))
    (let* ((skills-dir (expand-file-name "skills" folder))
           (loaded (eclaw--skills-load-from-directory skills-dir))
           (sig (plist-get loaded :signature))
           (skills (plist-get loaded :skills))
           (cached eclaw--skills-cache))
      (if (and cached
               (equal folder (plist-get cached :folder))
               (equal sig (plist-get cached :signature)))
          (plist-get cached :skills)
        (let ((plist (list :folder folder :signature sig :skills skills)))
          (setq eclaw--skills-cache plist)
          (when skills
            (eclaw-debug-message
             "eclaw: skills index loaded (%d skill%s)"
             (length skills)
             (if (= 1 (length skills)) "" "s")))
          skills)))))

(defun eclaw--skills-system-block ()
  "Return Markdown text listing agent skills for the system prompt, or \"\"."
  (if-let ((skills (eclaw--project-skills-index)))
      (concat "\n\n## Agent skills (index only)\n\n"
              "These entries follow the Agent Skills convention (each skill is a "
              "directory under `skills/' with a `SKILL.md'). Only this index "
              "is included here; the full instructions live in each file path below. "
              "When the user's task fits a skill's description, use the `read_file' "
              "tool on that path first, then follow the skill.\n\n"
              (mapconcat
               (lambda (s)
                 (format "- **%s**: %s\n  Path: `read_file` with path `%s`."
                         (plist-get s :name)
                         (plist-get s :description)
                         (plist-get s :path)))
               skills
               "\n"))
    ""))

(provide 'eclaw-skills)
;;; eclaw-skills.el ends here
