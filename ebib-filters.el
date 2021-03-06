;;; ebib-filters.el --- Part of Ebib, a BibTeX database manager

;; Copyright (c) 2003-2014 Joost Kremers
;; All rights reserved.

;; Author: Joost Kremers <joostkremers@fastmail.fm>
;; Maintainer: Joost Kremers <joostkremers@fastmail.fm>
;; Created: 2014
;; Version: 2.3
;; Keywords: text bibtex

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;;
;; 1. Redistributions of source code must retain the above copyright
;;    notice, this list of conditions and the following disclaimer.
;; 2. Redistributions in binary form must reproduce the above copyright
;;    notice, this list of conditions and the following disclaimer in the
;;    documentation and/or other materials provided with the distribution.
;; 3. The name of the author may not be used to endorse or promote products
;;    derived from this software without specific prior written permission.
;;
;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
;; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
;; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
;; IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
;; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
;; NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES ; LOSS OF USE,
;; DATA, OR PROFITS ; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
;; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;;; Commentary:

;; This file is part of Ebib, a BibTeX database manager for Emacs. It
;; contains the filter code.

;;; Code:

(require 'cl-lib)
(require 'ebib-utils)
(require 'ebib-keywords)
(require 'ebib-db)

(defgroup ebib-filters nil "Filter settings for Ebib" :group 'ebib)

(defcustom ebib-filters-display-as-lisp nil
  "If set, display filters as Lisp expressions."
  :group 'ebib-filters
  :type 'boolean)

(defcustom ebib-filters-ignore-case t
  "If set, ignore case in filter names."
  :group 'ebib-filters
  :type 'boolean)

(defcustom ebib-filters-default-file "~/.emacs.d/ebib-filters"
  "File for saving filters."
  :group 'ebib-filters
  :type 'file)

(defvar ebib--filters-alist nil "Alist of saved filters.")
(defvar ebib--filters-last-filter nil "The last used filter.")
(defvar ebib--filters-modified nil "T if `ebib--filters-alist' has been modified.")

;; The filters keymap
(eval-and-compile
  (define-prefix-command 'ebib-filters-map)
  (suppress-keymap 'ebib-filters-map 'no-digits)
  (define-key ebib-filters-map "&" 'ebib-filters-logical-and)
  (define-key ebib-filters-map "|" 'ebib-filters-logical-or)
  (define-key ebib-filters-map "~" 'ebib-filters-logical-not)
  (define-key ebib-filters-map "a" 'ebib-filters-apply-filter)
  (define-key ebib-filters-map "c" 'ebib-filters-cancel-filter)
  (define-key ebib-filters-map "d" 'ebib-filters-delete-filter)
  (define-key ebib-filters-map "D" 'ebib-filters-delete-all-filters)
  (define-key ebib-filters-map "l" 'ebib-filters-load-from-file)
  (define-key ebib-filters-map "L" 'ebib-filters-reapply-last-filter)
  (define-key ebib-filters-map "r" 'ebib-filters-reapply-filter)
  (define-key ebib-filters-map "R" 'ebib-filters-rename-filter)
  (define-key ebib-filters-map "s" 'ebib-filters-store-filter)
  (define-key ebib-filters-map "S" 'ebib-filters-save-filters)
  (define-key ebib-filters-map "v" 'ebib-filters-view-filter)
  (define-key ebib-filters-map "V" 'ebib-filters-view-all-filters)
  (define-key ebib-filters-map "w" 'ebib-filters-write-to-file))

(defun ebib-filters-view-filter ()
  "Display the currently active filter in the minibuffer."
  (interactive)
  (ebib--execute-when
    ((filtered-db)
     (message (ebib--filters-pp-filter (ebib-db-get-filter ebib--cur-db))))
    ((default)
     (error "No filter is active"))))

(defun ebib-filters-view-all-filters ()
  "Display all filters in a *Help* buffer."
  (interactive)
  (with-help-window (help-buffer)
    (let ((print-length nil)
          (print-level nil)
          (print-circle nil))
      (princ "Currently stored filters:\n\n")
      (if ebib--filters-alist
          (pp ebib--filters-alist)
        (princ "None.")))))

(defun ebib--filters-select-filter (prompt)
  "Select a filter from the saved filters.
Return the filter as a list (NAME FILTER)."
  (if (not ebib--filters-alist)
      (error "No stored filters")
    (let* ((completion-ignore-case ebib-filters-ignore-case)
           (name (completing-read prompt
                                  (sort (copy-alist ebib--filters-alist)
                                        (lambda (x y) (string-lessp (car x) (car y))))
                                  nil t)))
      (ebib--filters-get-filter name))))

(defun ebib-filters-rename-filter ()
  "Rename a filter."
  (interactive)
  (let ((filter (ebib--filters-select-filter "Rename filter: "))
        (new-name (read-from-minibuffer "Enter new name: ")))
    (if (ebib--filters-exists-p new-name)
        (error (format "A filter named `%s' already exists" new-name))
      (setcar filter new-name)
      (setq ebib--filters-modified t))))

(defun ebib-filters-store-filter ()
  "Store the current filter."
  (interactive)
  (let ((filter (or (ebib-db-get-filter ebib--cur-db)
                    ebib--filters-last-filter)))
    (if filter
        (let ((name (read-from-minibuffer "Enter filter name: ")))
          (when (or (not (ebib--filters-exists-p name))
                    (y-or-n-p (format "Filter `%s' already exists. Overwrite " name)))
            (ebib--filters-add-filter name filter 'overwrite)
            (setq ebib--filters-modified t)
            (message "Filter stored.")))
      (message "No filter to store"))))

(defun ebib-filters-delete-filter ()
  "Delete a filter from the stored filters."
  (interactive)
  (let ((filter (ebib--filters-select-filter "Delete filter: ")))
    (when filter
      (setq ebib--filters-alist (delq filter ebib--filters-alist))
      (setq ebib--filters-modified t)
      (message "Filter %s deleted" (car filter)))))

(defun ebib-filters-delete-all-filters ()
  "Delete all stored filters."
  (interactive)
  (setq ebib--filters-alist nil)
  (setq ebib--filters-modified t)
  (message "All stored filters deleted."))

(defun ebib-filters-load-from-file (file)
  "Read filters from FILE.
If there are stored filters, ask whether they should be
overwritten en bloc or whether the new filters should be
appended."
  (interactive "fRead filters from file: ")
  (setq file (expand-file-name file))
  (setq ebib--log-error nil)
  (let ((overwrite
         (if ebib--filters-alist
             (eq ?o (read-char-choice "There are stored filters: (o)verwrite/(a)ppend? " '(?o ?a))))))
    (ebib--filters-load-file file overwrite)
    (setq ebib--filters-modified t))
  (if (and ebib--log-error
           (= ebib--log-error 0))
      (message "No filters found in %s" file)
    (message "Filters loaded from %s" file)))

(defun ebib-filters-save-filters ()
  "Save all filters in `ebib-filters-default-file'.
If there are no stored filters, the filter file is deleted."
  (interactive)
  (ebib--filters-update-filters-file)
  (setq ebib--filters-modified nil))

(defun ebib-filters-write-to-file ()
  "Write filters to FILE."
  (interactive)
  (if (not ebib--filters-alist)
      (message "No stored filters")
    (let ((file (read-file-name "Save filters to file: ")))
      (ebib--filters-save-file file))))

(defun ebib--filters-run-filter (db)
  "Run the filter of DB.
Return a sorted list of entry keys that match DB's filter."
  ;; The filter uses a macro `contains', which we locally define here. This
  ;; macro in turn uses a dynamic variable `entry', which we must set
  ;; before eval'ing the filter.
  (let ((filter (ebib-db-get-filter db)))
    (eval
     `(cl-macrolet ((contains (field regexp)
                              `(ebib--search-in-entry ,regexp entry ,(unless (cl-equalp field "any") field))))
        (sort (delq nil (mapcar (lambda (key)
                                  (let ((entry (ebib-db-get-entry key db 'noerror)))
                                    (when ,filter
                                      key)))
                                (ebib-db-list-keys db 'nosort)))
              'string<)))))

(defun ebib--filters-pp-filter (filter)
  "Convert FILTER into a string suitable for displaying.
If `ebib--filters-display-as-lisp' is set, this simply converts
FILTER into a string representation of the Lisp expression.
Otherwise, it is converted into infix notation. If FILTER is NIL,
return value is also NIL."
  (when filter
    (if ebib-filters-display-as-lisp
        (format "%S" filter)
      (cl-labels
          ((pp-filter (f)
                      (cond
                       ((listp f) ; f is either a list or a string
                        (let ((op (cl-first f)))
                          (cond
                           ((eq op 'not)
                            (format "not %s" (pp-filter (cl-second f))))
                           ((eq op 'contains)
                            (format "(%s contains \"%s\")" (pp-filter (cl-second f)) (pp-filter (cl-third f))))
                           ((member op '(and or))
                            (format "(%s %s %s)" (pp-filter (cl-second f)) op (pp-filter (cl-third f)))))))
                       (t (if (string= f "any") 
                              "any field"
                            f)))))
        (let ((pretty-filter (pp-filter filter)))
          (if (string-match "\\`(\\(.*\\))\\'" pretty-filter) ; remove the outer parentheses
              (match-string 1 pretty-filter)
            pretty-filter))))))

(defun ebib--filters-load-file (file &optional overwrite)
  "Load filters from FILE.
If OVERWRITE in non-NIL, the existing filters are discarded.
Otherwise the new filters are added to the existing ones, unless
there is a name conflict."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((flist (when (search-forward "(" nil t)
                     (forward-char -1)
                     (read (current-buffer)))))
        (if (not (listp flist))
            (ebib--log 'warning "No filters found in %s\n" file)
          (ebib--log 'log "%s: Loading filters from file %s.\n" (format-time-string "%d %b %Y, %H:%M:%S") file)
          (if overwrite
              (setq ebib--filters-alist nil))
          (mapc (lambda (filter)
                  (ebib--filters-add-filter (car filter) (cadr filter)))
                flist))))))

(defun ebib--filters-save-file (file)
  "Write `ebib--filters-alist' to FILE"
  (with-temp-buffer
    (let ((print-length nil)
          (print-level nil)
          (print-circle nil))
      (insert ";; -*- mode: emacs-lisp -*-\n\n")
      (insert (format ";; Ebib filters file\n;; Saved on %s\n\n" (format-time-string "%Y.%m.%d %H:%M")))
      (pp ebib--filters-alist (current-buffer))
      (condition-case nil ;; TODO I should use this for the keywords file as well, so that ebib--quit doesn't terminate prematurely.
	  (write-region (point-min) (point-max) file)
	(file-error (message "Can't write %s" file))))))

(defun ebib--filters-update-filters-file ()
  "Update the filters file.
If changes have been made to the stored filters there are stored filters, they are saved to
`ebib-filters-default-file', otherwise this file is deleted."
  (when ebib--filters-modified
    (if ebib--filters-alist
        (ebib--filters-save-file ebib-filters-default-file)
      (condition-case nil
          (when (file-exists-p ebib-filters-default-file)
            (delete-file ebib-filters-default-file delete-by-moving-to-trash)
            (message "Filter file %s deleted." ebib-filters-default-file))
        (file-error (message "Can't delete %s" ebib-filters-default-file))))))

(defun ebib--filters-add-filter (name filter &optional overwrite)
  "Add FILTER under NAME in `ebib--filters-alist'.
If a filter with NAME already exists, the filter is not added,
unless OVERWRITE is non-NIL."
  (if (ebib--filters-exists-p name)
      (if overwrite
          (setcdr (ebib--filters-get-filter name) (list filter))
        (ebib--log 'message "Filter name conflict: \"%s\".\n" name))
    (add-to-list 'ebib--filters-alist (list name filter) 'append)))

(defun ebib--filters-get-filter (name &optional noerror)
  "Return the filter record corresponding to NAME.
Return a list (NAME FILTER) if found. If there is no
filter named NAME, raise an error, unless NOERROR is non-NIL."
  (or (assoc-string name ebib--filters-alist ebib-filters-ignore-case)
      (unless noerror
        (error "Invalid filter %s" name))))

(defun ebib--filters-exists-p (name)
  "Return non-NIL if a filter with NAME already exists."
  (assoc-string name ebib--filters-alist ebib-filters-ignore-case))

(provide 'ebib-filters)

;;; ebib-filters.el ends here
