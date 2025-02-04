;;; subed-vtt.el --- WebVTT implementation for subed  -*- lexical-binding: t; -*-

;;; License:
;;
;; This file is not part of GNU Emacs.
;;
;; This is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.


;;; Commentary:

;; WebVTT implementation for subed-mode.
;; Since WebVTT doesn't use IDs, we'll use the starting timestamp.

;;; Code:

(require 'subed)
(require 'subed-config)
(require 'subed-debug)
(require 'subed-common)

;;; Syntax highlighting

(defconst subed-vtt-font-lock-keywords
  (list
   '("\\([0-9]+:\\)?[0-9]+:[0-9]+\\.[0-9]+" . 'subed-vtt-time-face)
   '(",[0-9]+ \\(-->\\) [0-9]+:" 1 'subed-vtt-time-separator-face t)
   '("^.*$" . 'subed-vtt-text-face))
  "Highlighting expressions for `subed-mode'.")


;;; Parsing

(defconst subed-vtt--regexp-timestamp "\\(\\([0-9]+\\):\\)?\\([0-9]+\\):\\([0-9]+\\)\\.\\([0-9]+\\)")
(defconst subed-vtt--regexp-separator "\\(?:[[:blank:]]*\n\\)+\\(?:NOTE[ \n]\\(?:.+?\n\\)+\n\\)*\n")
(defconst subed-vtt--regexp-identifier
  ;; According to https://developer.mozilla.org/en-US/docs/Web/API/WebVTT_API
  ;; Cues can start with an identifier which is a non empty line that does
  ;; not contain "-->".
  "^[ \t]*[^ \t\n-]\\(?:[^\n-]\\|-[^\n-]\\|--[^\n>]\\)*[ \t]*\n")

(cl-defmethod subed--timestamp-to-msecs (time-string &context (major-mode subed-vtt-mode))
  "Find HH:MM:SS.MS pattern in TIME-STRING and convert it to milliseconds.
Return nil if TIME-STRING doesn't match the pattern.
Use the format-specific function for MAJOR-MODE."
  (when (string-match subed--regexp-timestamp time-string)
    (let ((hours (string-to-number (or (match-string 2 time-string) "0")))
          (mins  (string-to-number (match-string 3 time-string)))
          (secs  (string-to-number (match-string 4 time-string)))
          (msecs (string-to-number (subed--right-pad (match-string 5 time-string) 3 ?0))))
      (+ (* (truncate hours) 3600000)
         (* (truncate mins) 60000)
         (* (truncate secs) 1000)
         (truncate msecs)))))

(cl-defmethod subed--msecs-to-timestamp (msecs &context (major-mode subed-vtt-mode))
  "Convert MSECS to string in the format HH:MM:SS.MS.
Use the format-specific function for MAJOR-MODE."
  (concat (format-seconds "%02h:%02m:%02s" (/ msecs 1000))
          "." (format "%03d" (mod msecs 1000))))

(cl-defmethod subed--subtitle-id (&context (major-mode subed-vtt-mode))
  "Return the ID of the subtitle at point or nil if there is no ID.
Use the format-specific function for MAJOR-MODE."
  (save-excursion
    (when (and (subed-jump-to-subtitle-time-start)
               (looking-at subed--regexp-timestamp))
      (match-string 0))))

(cl-defmethod subed--subtitle-id-at-msecs (msecs &context (major-mode subed-vtt-mode))
  "Return the ID of the subtitle at MSECS milliseconds.
Return nil if there is no subtitle at MSECS.  Use the
format-specific function for MAJOR-MODE."
  (save-excursion
    (goto-char (point-min))
    (let* ((secs       (/ msecs 1000))
           (only-hours (truncate (/ secs 3600)))
           (only-mins  (truncate (/ (- secs (* only-hours 3600)) 60))))
      ;; Move to first subtitle in the relevant hour
      (when (re-search-forward (format "\\(%s\\|\\`\\)%02d:" subed--regexp-separator only-hours) nil t)
        (beginning-of-line)
        ;; Move to first subtitle in the relevant hour and minute
        (re-search-forward (format "\\(\n\n\\|\\`\\)%02d:%02d" only-hours only-mins) nil t)))
    ;; Move to first subtitle that starts at or after MSECS
    (catch 'subtitle-id
      (while (<= (or (subed-subtitle-msecs-start) -1) msecs)
        ;; If stop time is >= MSECS, we found a match
        (let ((cur-sub-end (subed-subtitle-msecs-stop)))
          (when (and cur-sub-end (>= cur-sub-end msecs))
            (throw 'subtitle-id (subed-subtitle-id))))
        (unless (subed-forward-subtitle-id)
          (throw 'subtitle-id nil))))))

;;; Traversing

(cl-defmethod subed--jump-to-subtitle-id (&context (major-mode subed-vtt-mode) &optional sub-id)
  "Move to the ID of a subtitle and return point.
If SUB-ID is not given, focus the current subtitle's ID.
Return point or nil if no subtitle ID could be found.
WebVTT doesn't use IDs, so we use the starting timestamp instead.
Use the format-specific function for MAJOR-MODE."
  (if (stringp sub-id)
      ;; Look for a line that contains the timestamp, preceded by one or more
      ;; blank lines or the beginning of the buffer.
      (let* ((orig-point (point))
             (regex (concat "\\(" subed--regexp-separator "\\|\\`\\)\\(" (regexp-quote sub-id) "\\)"))
             (match-found (progn (goto-char (point-min))
                                 (re-search-forward regex nil t))))
        (if match-found
            (goto-char (match-beginning 2))
          (goto-char orig-point)))
    ;; Find one or more blank lines.
    (re-search-forward "\\([[:blank:]]*\n\\)+" nil t)
    ;; Find two or more blank lines or the beginning of the buffer, followed
    ;; by line starting with a timestamp.
    (let* ((regex (concat  "\\(" subed--regexp-separator "\\|\\`\\)"
                           "\\(?:" subed-vtt--regexp-identifier "\\)?"
                           "\\(" subed--regexp-timestamp "\\)"))
           (match-found (re-search-backward regex nil t)))
      (when match-found
        (goto-char (match-beginning 2)))))
  ;; Make extra sure we're on a timestamp, return nil if we're not
  (when (looking-at "^\\(\\([0-9]+:\\)?[0-9]+:[0-9]+\\.[0-9]+\\)")
    (point)))

(cl-defmethod subed--jump-to-subtitle-time-start (&context (major-mode subed-vtt-mode) &optional sub-id)
  "Move point to subtitle's start time.
If SUB-ID is not given, use subtitle on point.
Return point or nil if no start time could be found.
Use the format-specific function for MAJOR-MODE."
  (when (subed-jump-to-subtitle-id sub-id)
    (when (looking-at subed--regexp-timestamp)
      (point))))

(cl-defmethod subed--jump-to-subtitle-time-stop (&context (major-mode subed-vtt-mode) &optional sub-id)
  "Move point to subtitle's stop time.
If SUB-ID is not given, use subtitle on point.
Return point or nil if no stop time could be found.
Use the format-specific function for MAJOR-MODE."
  (when (subed-jump-to-subtitle-id sub-id)
    (re-search-forward " *--> *" (point-at-eol) t)
    (when (looking-at subed--regexp-timestamp)
      (point))))

(cl-defmethod subed--jump-to-subtitle-text (&context (major-mode subed-vtt-mode) &optional sub-id)
  "Move point on the first character of subtitle's text.
If SUB-ID is not given, use subtitle on point.
Return point or nil if a the subtitle's text can't be found.
Use the format-specific function for MAJOR-MODE."
  (when (subed-jump-to-subtitle-id sub-id)
    (forward-line 1)
    (point)))

(cl-defmethod subed--jump-to-subtitle-end (&context (major-mode subed-vtt-mode) &optional sub-id)
  "Move point after the last character of the subtitle's text.
If SUB-ID is not given, use subtitle on point.
Return point or nil if point did not change or if no subtitle end
can be found.  Use the format-specific function for MAJOR-MODE."
  (let ((orig-point (point)))
    (subed-jump-to-subtitle-text sub-id)
    ;; Look for next separator or end of buffer.  We can't use
    ;; `subed-vtt--regexp-separator' here because if subtitle text is empty,
    ;; it may be the only empty line in the separator, i.e. there's only one
    ;; "\n".
    (let ((regex (concat "\\([[:blank:]]*\n\\)+"
                         "\\(?:NOTE[ \n]\\(?:.+?\n\\)+\n\\)*"
                         "\\(" subed--regexp-timestamp "\\)\\|\\([[:blank:]]*\n*\\)\\'")))
      (when (re-search-forward regex nil t)
        (goto-char (match-beginning 0))))
    (unless (= (point) orig-point)
      (point))))

(cl-defmethod subed--forward-subtitle-id (&context (major-mode subed-vtt-mode))
  "Move point to next subtitle's ID.
Return point or nil if there is no next subtitle.  Use the
format-specific function for MAJOR-MODE."
  (when (re-search-forward (concat subed--regexp-separator
                                   "\\(?:" subed-vtt--regexp-identifier "\\)?"
                                   subed--regexp-timestamp)
                           nil t)
    (subed-jump-to-subtitle-id)))

(cl-defmethod subed--backward-subtitle-id (&context (major-mode subed-vtt-mode))
  "Move point to previous subtitle's ID.
Return point or nil if there is no previous subtitle.  Use the
format-specific function for MAJOR-MODE."
  (let ((orig-point (point)))
    (when (subed-jump-to-subtitle-id)
      (if (re-search-backward (concat "\\(" subed--regexp-separator "\\|\\`[[:space:]]*\\)\\(" subed--regexp-timestamp "\\)") nil t)
          (progn
            (goto-char (match-beginning 2))
            (point))
        (goto-char orig-point)
        nil))))

;;; Manipulation

(cl-defmethod subed--make-subtitle (&context (major-mode subed-vtt-mode) &optional id start stop text)
  "Generate new subtitle string.

ID, START default to 0.
STOP defaults to (+ START `subed-subtitle-spacing')
TEXT defaults to an empty string.

A newline is appended to TEXT, meaning you'll get two trailing
newlines if TEXT is nil or empty.  Use the format-specific
function for MAJOR-MODE."
  (format "%s --> %s\n%s\n"
          (subed-msecs-to-timestamp (or start 0))
          (subed-msecs-to-timestamp (or stop (+ (or start 0)
                                                subed-default-subtitle-length)))
          (or text "")))

(cl-defmethod subed--prepend-subtitle (&context (major-mode subed-vtt-mode) &optional id start stop text)
  "Insert new subtitle before the subtitle at point.

ID and START default to 0.
STOP defaults to (+ START `subed-subtitle-spacing')
TEXT defaults to an empty string.

Move point to the text of the inserted subtitle.  Return new
point.  Use the format-specific function for MAJOR-MODE."
  (subed-jump-to-subtitle-id)
  (insert (subed-make-subtitle id start stop text))
  (when (looking-at (concat "\\([[:space:]]*\\|^\\)" subed--regexp-timestamp))
    (insert "\n"))
  (forward-line -2)
  (subed-jump-to-subtitle-text))

(cl-defmethod subed--append-subtitle (&context (major-mode subed-vtt-mode) &optional id start stop text)
  "Insert new subtitle after the subtitle at point.

ID, START default to 0.
STOP defaults to (+ START `subed-subtitle-spacing')
TEXT defaults to an empty string.

Move point to the text of the inserted subtitle.  Return new
point.  Use the format-specific function for MAJOR-MODE."
  (unless (subed-forward-subtitle-id)
    ;; Point is on last subtitle or buffer is empty
    (subed-jump-to-subtitle-end)
    ;; Moved point to end of last subtitle; ensure separator exists
    (while (not (looking-at "\\(\\`\\|[[:blank:]]*\n[[:blank:]]*\n\\)"))
      (save-excursion (insert ?\n)))
    ;; Move to end of separator
    (goto-char (match-end 0)))
  (insert (subed-make-subtitle id start stop text))
  ;; Complete separator with another newline unless we inserted at the end
  (when (looking-at (concat "\\([[:space:]]*\\|^\\)" subed--regexp-timestamp))
    (insert ?\n))
  (forward-line -2)
  (subed-jump-to-subtitle-text))

(cl-defmethod subed--merge-with-next (&context (major-mode subed-vtt-mode))
  "Merge the current subtitle with the next subtitle.
Update the end timestamp accordingly.
Use the format-specific function for MAJOR-MODE."
  (save-excursion
    (subed-jump-to-subtitle-end)
    (let ((pos (point)) new-end)
      (if (subed-forward-subtitle-time-stop)
          (progn
            (when (looking-at subed--regexp-timestamp)
              (setq new-end (subed-timestamp-to-msecs (match-string 0))))
            (subed-jump-to-subtitle-text)
            (delete-region pos (point))
            (insert "\n")
            (subed-set-subtitle-time-stop new-end))
        (error "No subtitle to merge into")))))

;;; Maintenance


(cl-defmethod subed--sanitize-format (&context (major-mode subed-vtt-mode))
  "Remove surplus newlines and whitespace.
Use the format-specific function for MAJOR-MODE."
  (atomic-change-group
    (subed-save-excursion
     ;; Remove trailing whitespace from each line
     (delete-trailing-whitespace (point-min) (point-max))

     ;; Remove leading spaces and tabs from each line
     (goto-char (point-min))
     (while (re-search-forward "^[[:blank:]]+" nil t)
       (replace-match ""))

     ;; Remove leading newlines
     (goto-char (point-min))
     (while (looking-at "\\`\n+")
       (replace-match ""))

     ;; Replace separators between subtitles with double newlines
     (goto-char (point-min))
     (while (subed-forward-subtitle-id)
       (let ((prev-sub-end (save-excursion (when (subed-backward-subtitle-end)
                                             (point)))))
         (when (and prev-sub-end
                    (not (string= (buffer-substring prev-sub-end (point)) "\n\n")))
           (delete-region prev-sub-end (point))
           (insert "\n\n"))))

     ;; Two trailing newline if last subtitle text is empty, one trailing
     ;; newline otherwise; do nothing in empty buffer (no graphical
     ;; characters)
     (goto-char (point-min))
     (when (re-search-forward "[[:graph:]]" nil t)
       (goto-char (point-max))
       (subed-jump-to-subtitle-end)
       (unless (looking-at "\n\\'")
         (delete-region (point) (point-max))
         (insert "\n")))

     ;; One space before and after " --> "
     (goto-char (point-min))
     (while (re-search-forward (format "^%s" subed--regexp-timestamp) nil t)
       (when (looking-at "[[:blank:]]*-->[[:blank:]]*")
         (unless (= (length (match-string 0)) 5)
           (replace-match " --> ")))))))

(cl-defmethod subed--validate-format (&context (major-mode subed-vtt-mode))
  "Move point to the first invalid subtitle and report an error.
Use the format-specific function for MAJOR-MODE."
  (when (> (buffer-size) 0)
    (atomic-change-group
      (let ((orig-point (point)))
        (goto-char (point-min))
        (while (and (re-search-forward (format "^\\(%s\\)" subed--regexp-timestamp) nil t)
                    (goto-char (match-beginning 1)))
          ;; This regex is stricter than `subed--regexp-timestamp'
          (unless (looking-at "^\\([0-9]\\{2\\}:\\)?[0-9]\\{2\\}:[0-9]\\{2\\}\\(\\.[0-9]\\{0,3\\}\\)")
            (error "Found invalid start time: %S"  (substring (or (thing-at-point 'line :no-properties) "\n") 0 -1)))
          (when (re-search-forward "[[:blank:]]" (point-at-eol) t)
            (goto-char (match-beginning 0)))
          (unless (looking-at " --> ")
            (error "Found invalid separator between start and stop time: %S"
                   (substring (or (thing-at-point 'line :no-properties) "\n") 0 -1)))
          (condition-case nil
              (forward-char 5)
            (error nil))
          (unless (looking-at "\\([0-9]\\{2\\}:\\)?[0-9]\\{2\\}:[0-9]\\{2\\}\\(\\.[0-9]\\{0,3\\}\\)$")
            (error "Found invalid stop time: %S" (substring (or (thing-at-point 'line :no-properties) "\n") 0 -1))))
        (goto-char orig-point)))))

;;;###autoload
(define-derived-mode subed-vtt-mode subed-mode "Subed-VTT"
  "Major mode for editing WebVTT subtitle files."
  (setq-local subed--subtitle-format "vtt")
  (setq-local subed--regexp-timestamp subed-vtt--regexp-timestamp)
  (setq-local subed--regexp-separator subed-vtt--regexp-separator)
  (setq-local font-lock-defaults '(subed-vtt-font-lock-keywords))
  (setq-local syntax-propertize-function
              (syntax-propertize-rules
               ("^\n" (0 ">"))
               ("^\\(N\\)\\(O\\)TE\\_>" (1 "w 1") (2 "w 2"))))
  ;; Support for fill-paragraph (M-q)
  (let ((timestamps-regexp (concat subed--regexp-timestamp
                                   " *--> *"
                                   subed--regexp-timestamp)))
    (setq-local paragraph-separate
                (concat "^\\("
                        (mapconcat #'identity `("[[:blank:]]*"
                                                "[[:digit:]]+"
                                                ,timestamps-regexp)
                                   "\\|")
                        "\\)$"))
    (setq-local paragraph-start
                (concat "\\("
                        ;; Multiple speakers in the same
                        ;; subtitle are often distinguished with
                        ;; a "-" at the start of the line.
                        (mapconcat #'identity '("^-" "[[:graph:]]*$")
                                   "\\|")
                        "\\)"))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.vtt\\'" . subed-vtt-mode))

(provide 'subed-vtt)
;;; subed-vtt.el ends here
