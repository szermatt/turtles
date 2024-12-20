;;; turtles.el --- Screen-grabbing test utility -*- lexical-binding: t -*-

;; Copyright (C) 2024 Stephane Zermatten

;; Author: Stephane Zermatten <szermatt@gmx.net>
;; Maintainer: Stephane Zermatten <szermatt@gmail.com>
;; Version: 0.1snapshot
;; Package-Requires: ((emacs "26.1") (compat "30.0.1.0"))
;; Keywords: testing, unix
;; URL: http://github.com/szermatt/turtles

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; `http://www.gnu.org/licenses/'.

;;; Commentary:
;;
;; This package contains utilities for testing Emacs appearance in a
;; terminal.
;;

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'ert)
(require 'ert-x)
(require 'subr-x) ;; when-let
(require 'turtles-io)
(require 'turtles-instance)

(defcustom turtles-pop-to-buffer-actions
  '(turtles-pop-to-buffer-copy
    turtles-pop-to-buffer-embedded
    turtles-pop-to-buffer-new-frame)
  "Set of possible handlers of instance buffers.

This are actions called by `turtles-pop-to-buffer' to display
buffers from other instances. When more than on action is
available, `turtles-pop-to-buffer' show a list of possible
actions, identified by the short documentation string of the
function.

The signature of these functions must be (action inst buffer-name
&rest pop-to-buffer-args).

When ACTION is \\='check, the function must
check whether it can pop to BUFFER and, if yes, return non-nil.

When ACTION is \\='display, the function must do what it can do
display BUFFER.

INST is a live `turtles-instance' containing the buffer.

BUFFER-NAME is the name of a buffer in INST."
  :type '(list function)
  :group 'turtles)

(defvar turtles-pop-to-buffer-action-history nil
  "History of action choice from `turtles-pop-to-buffer-actions'.")

(defvar-local turtles--original-instance nil
  "The original instance the buffer was copied from.

Set by `turtles-pop-to-buffer-copy'.")

(defconst turtles-basic-colors
  ["#ff0000" "#00ff00" "#0000ff" "#ffff00" "#00ffff" "#ff00ff"]
  "Color vector used to detect faces, excluding white and black.

These colors are chosen to be distinctive and easy to recognize
automatically even with the low precision of
`turtles--color-values'. They don't need to be pretty, as they're
never actually visible.")

(defvar-local turtles-source-window nil
  "The turtles frame window the current buffer was grabbed from.

This is local variable set in a grab buffer filled by
`turtles-grab-window-into' or `turtles-grab-buffer-into'.")

(defvar-local turtles-source-buffer nil
  "The buffer the current buffer was grabbed from.

This is local variable set in a grab buffer filled by
`turtles-grab-window-into' or `turtles-grab-buffer-into'.")

(defvar-local turtles--left-margin-width 0
  "Width of the left margin left by `turtles--clip-in-frame-grab'.")

(defvar turtles-ert--result nil
  "Result of running a test in another Emacs instance.")

(defvar turtles-ert--load-cache nil
  "A hash map indicating which file was just loaded.

This is set while running tests to load a file just once on an
instance and discarded afterwards.

This is a hash map whose key is a (cons instance-id file-name)
and whose value is always t.")

(defun turtles-display-buffer-full-frame (buf)
  "Display BUF in the frame root window.

This is similar to Emacs 29's `display-buffer-full-frame', but
rougher and available in Emacs 26."
  (set-window-buffer (frame-root-window) buf))

(advice-add 'ert-run-test :around #'turtles-ert--around-ert-run-test)
(advice-add 'ert-run-tests :around #'turtles-ert--around-ert-run-tests)
(advice-add 'pop-to-buffer :around #'turtles--around-pop-to-buffer)

(defun turtles-grab-frame-into (buffer &optional grab-faces)
  "Grab a snapshot current frame into BUFFER.

This includes all windows and decorations. Unless that's what you
want to test, it's usually better to call `turtles-grab-buffer'
or `turtles-grab-win', which just return the window body.

If GRAB-FACES is empty, the colors are copied as
\\='font-lock-face text properties, with as much fidelity as the
terminal allows.

If GRAB-FACES is not empty, the faces on that list - and only
these faces - are recovered into \\='face text properties. Note
that in such case, no other face or color information is grabbed,
so any other face not in GRAB-FACE are absent."
  (unless (turtles-io-conn-live-p (turtles-upstream))
    (error "No upstream connection"))
  (pcase-let ((`(,grab-face-alist . ,cookies)
               (turtles--setup-grab-faces
                grab-faces

                ;; TODO: when grabbing just one buffer or window, just
                ;; pass in that buffer.
                (turtles--all-displayed-buffers))))
    (unwind-protect
        (progn
          (redraw-frame)
          (unless (redisplay t)
            (error "Emacs won't redisplay in this context, likely because of pending input."))
          (with-current-buffer buffer
            (delete-region (point-min) (point-max))
            (let ((grab (turtles-io-call-method
                         (turtles-upstream) 'grab (turtles-this-instance))))
              (insert grab))
            (font-lock-mode)
            (when grab-faces
              (turtles--faces-from-color grab-face-alist))))
      (turtles--teardown-grab-faces cookies))))

(defun turtles--all-displayed-buffers ()
  "Return a list of all buffers shown in a window."
  (let ((bufs (list)))
    (dolist (win (window-list))
      (when-let ((buf (window-buffer win)))
        (unless (memq buf bufs)
          (push buf bufs))))

    bufs))

(defun turtles-setup-buffer (&optional buf)
  "Setup the turtles frame to display BUF and return the window.

If BUF is nil, the current buffer is used instead."
  (or (get-buffer-window buf)
      (progn
        (turtles-display-buffer-full-frame buf)
        (frame-root-window))))

(defun turtles-grab-buffer-into (buf output-buf &optional grab-faces margins)
  "Display BUF in the grabbed frame and grab it into OUTPUT-BUF.

When this function returns, OUTPUT-BUF contains the textual
representation of BUF as displayed in the root window of the
grabbed frame.

If MARGIN is non-nil, include the left and right margins.

This function uses `turtles-grab-window-into' after setting up
the buffer. See the documentation of that function for details on
the buffer content and the effect of GRAB-FACES."
  (turtles-grab-window-into
   (turtles-setup-buffer buf) output-buf grab-faces margins))

(defun turtles-grab-mode-line-into (win-or-buf output-buf &optional grab-faces)
  "Grab the mode line of WIN-OR-BUF into OUTPUT-BUFE.

When this function returns, OUTPUT-BUF contains the textual
representation of the mode line of WIN-OR-BUF.

This function uses `turtles-grab-window-into' after setting up
the buffer. See the documentation of that function for details on
the buffer content and the effect of GRAB-FACES."
  (let ((win (if (bufferp win-or-buf)
                 (turtles-setup-buffer win-or-buf)
               win-or-buf)))
    (turtles-grab-frame-into output-buf grab-faces)
    (with-current-buffer output-buf
      (setq turtles-source-window win)
      (setq turtles-source-buffer (window-buffer win))
      (pcase-let ((`(,left _ ,right ,bottom) (window-edges win nil))
                  (`(_ _ _ ,body-bottom) (window-edges win 'body)))
        (turtles--clip left body-bottom right bottom)))))

(defun turtles-grab-header-line-into (win-or-buf output-buf &optional grab-faces)
  "Grab the header line of WIN-OR-BUF into OUTPUT-BUFE.

When this function returns, OUTPUT-BUF contains the textual
representation of the header line of WIN-OR-BUF.

This function uses `turtles-grab-window-into' after setting up
the buffer. See the documentation of that function for details on
the buffer content and the effect of GRAB-FACES."
  (let ((win (if (bufferp win-or-buf)
                 (turtles-setup-buffer win-or-buf)
               win-or-buf)))
    (turtles-grab-frame-into output-buf grab-faces)
    (with-current-buffer output-buf
      (setq turtles-source-window win)
      (setq turtles-source-buffer (window-buffer win))
      (pcase-let ((`(,left ,top ,right _) (window-edges win nil))
                  (`(_ ,body-top _ _) (window-edges win 'body)))
        (turtles--clip left top right body-top)))))

(defun turtles-grab-window-into (win output-buf &optional grab-faces margins)
  "Grab WIN into output-buf.

WIN must be a window on the turtles frame.

When this function returns, OUTPUT-BUF contains the textual
representation of the content of that window. The point, mark and
region are also set to corresponding positions in OUTPUT-BUF, if
possible.

If MARGIN is non-nil, include the left and right margins.

If GRAB-FACES is empty, the colors are copied as
\\='font-lock-face text properties, with as much fidelity as the
terminal allows.

If GRAB-FACES is not empty, the faces on that list - and only
these faces - are recovered into \\='face text properties. Note
that in such case, no other face or color information is grabbed,
so any other face not in GRAB-FACE are absent."
  (turtles-grab-frame-into output-buf grab-faces)
  (with-current-buffer output-buf
    (setq turtles-source-window win)
    (setq turtles-source-buffer (window-buffer win))
    (pcase-let ((`(,left _ ,right _) (window-edges win (not margins)))
                (`(,left-body ,top _ ,bottom) (window-edges win 'body)))
      (setq-local turtles--left-margin-width (- left-body left))
      (turtles--clip left top right bottom))

    (let ((point-pos (turtles-pos-in-window-grab (window-point win)))
          (mark-pos (turtles-pos-in-window-grab
                     (with-selected-window win (mark)) 'range)))
      (when point-pos
        (goto-char point-pos))
      (when mark-pos
        (push-mark mark-pos 'nomsg nil))

      (when (and point-pos
                 mark-pos
                 (with-selected-window win
                   (region-active-p)))
        (activate-mark)))))

(defun turtles-pos-in-window-grab (pos-in-source-buf &optional range)
  "Convert a position in the source buffer to the current buffer.

For this to work, the current buffer must be a grab buffer
created by `turtles-grab-window-into' or
`turtles-grab-buffer-into' and neither its content nor the
source buffer or source window must have changed since the grab.

POS-IN-SOURCE-BUF should be a position in the source buffer. It
might be nil, in which case this function returns nil.

When RANGE is non-nil, if the position is before window start,
set it at (point-min), if it is after window end, set it
at (point-max). This is appropriate when highlighting range
boundaries.

Return a position in the current buffer. If the point does not
appear in the grab, return nil."
  (let ((win turtles-source-window))
    (unless win
      (error "Current buffer does not contain a window grab"))
    (cond
     ((null pos-in-source-buf) nil)
     ((and range (<= pos-in-source-buf (window-start win)))
      (point-min))
     ((and range (>= pos-in-source-buf (window-end win)))
      (point-max))
     (t (pcase-let ((`(,left ,top _ _) (window-body-edges win))
                    (`(,x . ,y) (window-absolute-pixel-position
                                 pos-in-source-buf win)))
          (when (and x y)
            (save-excursion
              (goto-char (point-min))
              (forward-line (- y top))
              (move-to-column (+ (- x left) turtles--left-margin-width))
              (point))))))))

(defun turtles--clip-in-frame-grab (win margins)
  "Clip the frame grab in the current buffer to the body of WIN.

If MARGIN is non-nil, include the margins and set
`turtles--left-margin-width'."
  (pcase-let ((`(,left _ ,right _) (window-edges win (not margins)))
              (`(,left-body ,top _ ,bottom) (window-edges win 'body)))
    (setq-local turtles--left-margin-width (- left-body left))
    (turtles--clip left top right bottom)))

(defun turtles--clip (left top right bottom)
  "Clip the frame grab in the current buffer to the given edges.

LEFT TOP RIGHT and BOTTOM are coordinate relative to the current
buffer's origins."
  (save-excursion
    (goto-char (point-min))
    (while (progn
             (move-to-column right)
             (delete-region (point) (pos-eol))
             (= (forward-line 1) 0)))

    (when (> left 0)
      (goto-char (point-min))
      (while (progn
               (move-to-column left)
               (delete-region (pos-bol) (point))
               (= (forward-line 1) 0))))

    (goto-char (point-min))
    (forward-line bottom)
    (delete-region (point) (point-max))

    (when (> top 0)
      (goto-char (point-min))
      (forward-line top)
      (delete-region (point-min) (point)))))

(defun turtles--setup-grab-faces (grab-faces buffers)
  "Prepare buffer faces for grabbing GRAB-FACES on BUFFERS.

This function modifies the faces in all buffers so that they can
be detected from color by `turtles--faces-from-color'.

The color changes are reverted by `turtles--teardown-grab-faces'
or the grabbed buffers will look very ugly.

Return a (cons grab-face-alist cookies) with grab-face-alist the
alist to pass to `turtles--faces-from-color' and cookies to pass
to `turtles--teardown-grab-faces'."
  (when grab-faces
    (let ((color-count (length turtles-basic-colors))
          grab-face-alist cookies remapping)

      ;; That should be enough for any reasonable number of faces, but
      ;; if not, the vector can could be extended to use more
      ;; distinctive colors.
      (when (> (length grab-faces) (* color-count color-count))
        (error "Too many faces to highlight"))

      (dolist (face grab-faces)
        (let* ((idx (length remapping))
               (bg (aref turtles-basic-colors (% idx color-count)))
               (fg (aref turtles-basic-colors (/ idx color-count))))
          (push (cons face `(:background ,bg :foreground ,fg)) remapping)))

      (setq grab-face-alist (cl-copy-list remapping))

      ;; Set *all* other faces to white-on-black so there won't be any
      ;; confusion.
      (let* ((white-on-black `(:foreground "#ffffff" :background "#000000")))
        (dolist (face (face-list))
          (unless (memq face grab-faces)
            (push (cons face white-on-black) remapping))))

      (dolist (buf buffers)
        (with-current-buffer buf
          (push (cons buf (buffer-local-value 'face-remapping-alist buf))
                cookies)
          (setq-local face-remapping-alist remapping)))

      (cons grab-face-alist cookies))))

(defun turtles--teardown-grab-faces (cookies)
  "Revert buffer colors modified by `turtles--setup-grab-faces'.

COOKIES is one of the return values of
`turtles--setup-grab-faces'."
  (pcase-dolist (`(,buf . ,remapping) cookies)
    (with-current-buffer buf
      (setq-local face-remapping-alist remapping))))

(defun turtles--faces-from-color (face-alist)
  "Recognize faces from FACE-ALIST in current buffer.

This function replaces the font-lock-face color properties set by
ansi-color with face properties from FACE-ALIST.

FACE-ALIST must be an alist of face symbol to face spec, as
returned by turtles--setup-grab-faces. The colors in this alist
are mapped back to the symbols.

When this function returns, the buffer content should look like
the original content, but with only the faces from FACE-ALIST
set."
  (let ((reverse-face-alist
         (mapcar (lambda (cell)
                   (cons (turtles--color-values (cdr cell)) (car cell)))
                 face-alist))
        current-face range-start next)
    (save-excursion
      (goto-char (point-min))
      (setq next (point-min))
      (while
          (progn
            (goto-char next)
            (let* ((spec (get-text-property (point) 'font-lock-face))
                   (col (when spec (turtles--color-values spec)))
                   (face (when col (alist-get col reverse-face-alist nil nil #'equal))))
              (when face
                (setq current-face face)
                (setq range-start (point))))
            (setq next (next-property-change (point)))

            (let ((next (or next (point-max))))
              (when (> next (point))
                (remove-text-properties (point) next '(font-lock-face nil)))
              (when current-face
                (add-text-properties range-start next `(face ,current-face))
                (setq range-start nil)
                (setq current-face nil)))

            next)))))

(defun turtles--color-values (spec)
  "Extract fg/bg color values from SPEC with low precision.

The color values are constrained to `turtles-color-precision' and
are meant to be safely compared.

SPEC might be a face symbol, a face attribute list or a list of
face attribute lists.

Returns a list of 6 low-precision color values, first fg RGB,
then bg RGB, all integers between 0 and 4."
  (mapcar
   (lambda (c) (round (* 4.0 c)))
   (append
    (color-name-to-rgb (or (turtles--face-attr spec :foreground) "#ffffff"))
    (color-name-to-rgb (or (turtles--face-attr spec :background) "#000000")))))

(defun turtles--face-attr (spec attr)
  "Extract ATTR from SPEC.

SPEC might be a face symbol, a face attribute list or a list of
face attribute lists."
  (cond
   ((symbolp spec)
    (face-attribute-specified-or
     (face-attribute spec attr nil t)
     nil))
   ((consp spec)
    (or (cadr (memq attr spec))
        (car (delq nil
                   (mapcar
                    (lambda (s) (when (consp s) (turtles--face-attr s attr)))
                    spec)))))))

(defsubst turtles-mark-text-with-face (face marker &optional closing-marker)
  "Put section of text marked with FACE within MARKERS.

MARKER should either be a string made up of two markers of the
same length, such as \"[]\" or the opening marker string, with
the closing marker defined by CLOSING-MARKER.

This function is a thin wrapper around
`turtles-mark-text-with-face'. See the documentatin of that
function for details."
  (turtles-mark-text-with-faces
   `((,face ,marker . ,(when closing-marker (cons closing-marker nil))))))

(defun turtles-mark-text-with-faces (face-marker-alist)
  "Put section of text marked with specific faces with text markers.

FACE-MARKER-ALIST should be an alist of (face markers),
with face a face symbol to detect and marker.

The idea behind this function is to make face properties visible
in the text, to make easier to test buffer content with faces by
comparing two strings.

markers should be, either:

- a string made up an opening and closing substring of the same
  length or two strings. For example, \"()\" \"[]\" \"<<>>\"
  \"/**/\".

- two strings, the opening and closing substrings.
  For example: (\"s[\" \"]\")

This function is meant to highlight faces setup by turtles when
asked to grab faces. It won't work in the general case."
  (when face-marker-alist
    (save-excursion
      (let ((next (point-min))
            (closing nil))
        (while
            (progn
              (goto-char next)
              (when-let* ((face (get-text-property (point) 'face))
                          (markers (alist-get face face-marker-alist)))
                (pcase-let ((`(,op . ,close) (turtles--split-markers markers)))
                  (insert op)
                  (setq closing close)))
              (setq next (next-property-change (point)))

              (when closing
                (goto-char (or next (point-max)))
                (insert closing)
                (setq closing nil))

              next))))))

(defun turtles--split-markers (markers)
  "Return an opening and closing marker.

MARKERS must be either a string, to be split into two strings of
the same length or a list of two elements.

The return value is a (cons opening closing) containing two
strings"
  (cond
   ((and (consp markers) (length= markers 1))
    (turtles--split-markers (car markers)))
   ((and (consp markers) (length= markers 2))
    (cons (nth 0 markers) (nth 1 markers)))
   ((stringp markers)
    (let ((mid (/ (length markers) 2)))
      (cons (substring markers 0 mid) (substring markers mid))))
   (t (error "Unsupported markers: %s" markers))))

(defun turtles-mark-point (mark)
  "Add a mark on the current point, so `buffer-string' shows it."
  (insert mark))

(defun turtles-mark-region (marker &optional closing-marker)
  "Surround the active region with markers.

This function does nothing if the region is inactive.

If only MARKER is specified, it must be a string composed of two
strings of the same size that will be used as opening and closing
marker, such as \"[]\" or \"/**/\".

If both MARKER and CLOSING-MARKER are specified, MARKER is used
as opening marker and CLOSING-MARKER as closing."
  (when (region-active-p)
    (pcase-let ((`(,opening . ,closing)
                 (turtles--split-markers
                  (if closing-marker
                      (list marker closing-marker)
                    marker))))
      (let ((beg (min (point-marker) (mark-marker)))
            (end (max (point-marker) (mark-marker))))
        (save-excursion
          (goto-char end)
          (insert closing)
          (goto-char beg)
          (insert opening))))))

(defun turtles-grab-buffer-to-string (buf)
  "Grab BUF into a string.

See `turtles-grab-buffer-into' for more details."
  (with-temp-buffer
    (turtles-grab-buffer-into buf (current-buffer))
    (buffer-string)))

(defun turtles-grab-window-to-string (win)
  "Grab WIN into a string.

See `turtles-grab-window-into' for more details."
  (with-temp-buffer
    (turtles-grab-window-into win (current-buffer))
    (buffer-string)))

(defun turtles-grab-frame-to-string ()
  "Grab the frame into a string.

See `turtles-grab-frame-into' for more details."
  (with-temp-buffer
    (turtles-grab-frame-into (current-buffer))
    (buffer-string)))

(defun turtles-trim-buffer ()
  "Remove trailing spaces and final newlines.

This function avoids having to hardcode many spaces and newlines
resulting from frame capture in tests. It removes trailing spaces
in the whole buffer and any newlines at the end of the buffer."
  (delete-trailing-whitespace)
  (while (eq ?\n (char-before (point-max)))
    (delete-region (1- (point-max)) (point-max))))

(cl-defmacro turtles-ert-test (&key instance timeout)
  "Run the current test in another Emacs instance.

INSTANCE is the instance to start, the instance \\='default is used
if none is specified.

TIMEOUT is the time after which the server should give up waiting
for an answer from the instance."
  `(turtles-ert--test ,instance ,(macroexp-file-name) ,timeout))

(defun turtles-ert--test (inst-id file-name timeout)
  "Run the current test in another Emacs instance.

Expects the current test to be defined in FILE-NAME."
  (unless (turtles-this-instance)
    (let* ((test (ert-running-test))
           (test-sym (when test (ert-test-name test)))
           (inst-id (or inst-id 'default))
           (inst (turtles-get-instance inst-id)))
      (unless test
        (error "Call turtles-ert-test from inside a ERT test."))
      (cl-assert test-sym)

      (unless inst
        (error "No turtles instance defined with ID %s" inst-id))

      ;; Last ditch attempt at getting back the file name, if it was
      ;; lost. This only works starting with Emacs 29.1.
      (when (eval-when-compile (>= emacs-major-version 29))
        (unless file-name
          (setq file-name (ert-test-file-name test))))

      (turtles-start-instance inst)
      (let ((timeout (or timeout 10.0))
            (conn (turtles-instance-conn inst))
            res)
        (if file-name
            ;; Reload test from file-name. This guarantees that
            ;; everything around that test, such as requires, has also
            ;; been defined on the instance.
            (progn
              (setq res
                    (turtles-io-call-method
                     conn 'ert-test
                     `(progn
                        ,(unless (and turtles-ert--load-cache
                                      (gethash (cons inst-id file-name)
                                               turtles-ert--load-cache))
                           `(load ,file-name nil 'nomessage 'nosuffix))
                        (let ((test (ert-get-test (quote ,test-sym))))
                          (ert-run-test test)
                          (ert-test-most-recent-result test)))
                     :timeout timeout))
              (when turtles-ert--load-cache
                (puthash (cons inst-id file-name) t turtles-ert--load-cache)))

          ;; Forward test, including test body.
          ;;
          ;; This might fail if:
          ;; - the body captured unreadable objects
          ;; - the body calls functions that weren't loaded
          ;;
          ;; This is generally only OK for re-runs. Luckily this is
          ;; the situation were we're most likely to not have a
          ;; filename.
          (when (consp (ert-test-body test))
            ;; byte-compiling might make an otherwise unreadable body
            ;; readable by getting rid of unneeded captured variables.
            (setf (ert-test-body test)
                  (byte-compile (ert-test-body test))))
          (setq res
                (turtles-io-call-method
                 conn 'ert-test
                 `(let ((test ,test))
                    (require 'ert)
                    (require 'ert-x)
                    (require 'turtles)

                    (ert-run-test test)
                    (ert-test-most-recent-result test))
                 :timeout timeout)))

        (turtle--process-remote-result res)
        (setq turtles-ert--result res))

      ;; ert-pass interrupt the server-side portion of the test. The
      ;; real result will be collected from turtles-ert--result by
      ;; turtles-ert--around-ert-run-test. What follows is the
      ;; client-side portion of the test only.
      (ert-pass))))

(defun turtle--process-remote-result (result)
  "Post-process a RESULT from a remote instance."
  (when (and result (ert-test-result-with-condition-p result))
    (mapc (lambda (cell)
            (turtles--recreate-buttons (cdr cell)))
          (ert-test-result-with-condition-infos result))))

(defun turtles--recreate-buttons (text)
  "Re-create button properties in TEXT.

ERT uses buttons, which use property categories with special
symbols which don't survive a print1 then read. This function
re-creates these buttons by changing the value of the category
property."
  (let ((pos 0) (nextpos 0) (limit (length text)))
    (while (< pos limit)
      (setq nextpos (next-single-property-change pos 'category text limit))
      (when-let* ((cat (get-text-property pos 'category text))
                  (button (get-text-property pos 'button text))
                  (button-type
                   (when (string-suffix-p "-button" (symbol-name cat))
                     (intern (string-remove-suffix "-button" (symbol-name cat))))))
        (add-text-properties pos nextpos `(category ,(button-category-symbol button-type)) text))
      (setq pos nextpos))))

(defun turtles--around-pop-to-buffer (func buffer &rest args)
  "If BUFFER is a remote buffer, call `turtles-pop-to-buffer' on it.

ARGS is passed as-is to FUNC, normally `pop-to-buffer', which is
configured by `pop-to-buffer-actions'.

This function is meant to be used as around advice for
`pop-to-buffer'."
  (if (and (consp buffer) (eq 'turtles-buffer (car buffer)))
      (apply #'turtles-pop-to-buffer buffer args)
    (apply func buffer args)))

(defun turtles-ert--around-ert-run-test (func test &rest args)
  "Collect test results sent by another Emacs instance.

This function takes results set up by `turtles-ert-test' and puts
them into the local `ert-test' instance."
  (let ((turtles-ert--result nil))
    (apply func test args)
    (when turtles-ert--result
      (setf (ert-test-most-recent-result test) turtles-ert--result))))

(defun turtles-ert--around-ert-run-tests (func &rest args)
  "Collect test results sent by another Emacs instance.

This function takes results set up by `turtles-ert-test' and puts
them into the local `ert-test' instance."
  (let ((turtles-ert--load-cache (make-hash-table :test 'equal)))
    (apply func args)))

(cl-defun turtles-to-string (&key (name "grab")
                                   frame win buf minibuffer mode-line header-line
                                   margins faces region point (trim t))
  "Grab a section of the terminal and return the result as a string.

With no arguments, this function renders the current buffer in
the turtles frame, and returns the result as a string.

The rendered buffer is grabbed into an ERT test buffer with the
name \"grab\". When running interactively, ERT keeps such buffers
when tests fail so they can be checked out. Specify the keyword
argument NAME to modify the name of the test buffer.

The following keyword arguments modify what is grabbed:

  - The key argument BUF specifies a buffer to capture. It
    defaults to the current buffer. The buffer is installed into
    the single window of `turtles-frame', rendered, then
    grabbed.

  - The key argument WIN specifies a window to grab.

  - The key argument MODE-LINE specifies a window or buffer to
    grab the mode line of, or t to grab the mode line of the
    current buffer.

  - The key argument HEADER-LINE specifies a window or buffer to
    grab the header line of, or t to grab the header line of the
    current buffer.

  - Set the key argument MINIBUFFER to t to capture the content
    of the minibuffer window of `turtles-frame'.

  - Set the key argument FRAME to t to capture the whole frame.

  - If key argument MARGINS is non-nil, include the left and
    right margin when grabbing the content of a window or buffer.

The following keyword arguments post-process what was grabbed:

  - Set the key argument TRIM to nil to not trim the newlines
    at the end of the grabbed string. Without trimming, there
    is one newline per line of the grabbed window, even if
    the buffer content is shorter.

  - Pass a string to the key argument POINT to insert at point,
    so that position is visible in the returned string.

  - The key argument REGION makes the active region visible in
    the returned string. Pass a string composed of opening and
    closing strings of the same length, such as \"[]\" or
    \"/**/\", to mark the beginning and end of the region.
    Alternatively, you can also pass a list made up of two
    strings, the opening and closing string, which then don't
    need to be of the same size. See also `turtles-mark-region'.

  - The key argument FACES makes a specific set of faces visible
    in the returned string. Pass an alist with the symbols of the
    faces you want to highlight as key and either one string
    composed of opening and closing strings of the same length,
    such as \"[]\" or \"/**/\", to mark the beginning and end of
    the region. Alternatively, you can also pass a list made up
    of two strings, the opening and closing string, which then
    don't need to be of the same size. See also
    `turtles-mark-text-with-faces'"
  (let ((calling-buf (current-buffer)))
    (ert-with-test-buffer (:name name)
      (turtles--internal-grab
       frame win buf calling-buf minibuffer mode-line header-line faces margins)
      (when region
        (turtles-mark-region (if (consp region) (car region) region)
                              (if (consp region) (nth 1 region))))
      (when point
        (insert point))
      (turtles-mark-text-with-faces (turtles-ert--filter-faces-for-mark faces))
      (when trim
        (turtles-trim-buffer))
      (buffer-substring-no-properties (point-min) (point-max)))))

(cl-defmacro turtles-with-grab-buffer ((&key (name "grab")
                                              frame win buf minibuffer mode-line header-line
                                              margins faces)
                                        &rest body)
  "Grab a section of the terminal and store it into a test buffer.

With no arguments, this function renders the current buffer in
the turtles frame into an ERT test buffer and executes BODY.

The ERT test buffer with the name \"grab\". When running
interactively, ERT keeps such buffers when tests fail so they can
be checked out. Specify the keyword argument NAME to modify the
name of the test buffer.

The garbbed buffer contains a textual representation of the frame
or window captured on the turtles frame. When grabbing a buffer
or window, the point and region will be grabbed as well.
Additionally, unless FACES is specified, captured colors are
available as overlay colors, within the limits of the turtles
terminal, usually limited to 256 colors.

More keyword arguments can be specified in parentheses, before
BODY:

  - The key argument BUF specifies a buffer to capture. It
    defaults to the current buffer. The buffer is installed into
    the single window of `turtles-frame', rendered, then
    grabbed.

  - The key argument WIN specifies a window to grab.

  - The key argument MODE-LINE specifies a window or buffer to
    grab the mode line of, or t to grab the mode line of the
    current buffer.

  - The key argument HEADER-LINE specifies a window or buffer to
    grab the header line of, or t to grab the header line of the
    current buffer.

  - Set the key argument MINIBUFFER to t to capture the content
    of the minibuffer window of `turtles-frame'.

  - If key argument MARGINS is non-nil, include the left and
    right margin when grabbing the content of a window or buffer.

  - Set the key argument FRAME to t to capture the whole frame.

  - The key argument FACES asks for a specific set of faces to
    be detected and grabbed. They'll be available as face
    symbols set to the properties \\='face.

    If necessary, faces can be made easier to test with text
    comparison with `turtles-mark-text-with-faces'.

    Note that colors won't be available in the grabbed buffer
    content when FACES is specified."
  (declare (indent 1))
  (let ((calling-buf (make-symbol "calling-buf"))
        (faces-var (make-symbol "faces")))
    `(let ((,calling-buf (current-buffer))
           (,faces-var ,faces))
       (ert-with-test-buffer (:name ,name)
         (turtles--internal-grab
          ,frame ,win ,buf ,calling-buf ,minibuffer
          ,mode-line ,header-line ,faces-var ,margins)
         (turtles-mark-text-with-faces (turtles-ert--filter-faces-for-mark ,faces-var))

         ,@body))))

(defmacro turtles-read-from-minibuffer (read &rest body)
  "Run BODY while executing READ.

READ is a form that reads from the minibuffer and return the
result.

BODY is executed while READ is waiting for minibuffer input with
the minibuffer active. Input can be provided by calling
`execute-kbd-macro'. BODY must eventually either signal an error
or exit the minibuffer.

This macro allows mixing `execute-kbd-macro' and commands
manipulating minibuffer with grab commands such as
`turtles-to-string' and `turtles-with-grab-buffer'. `should'
can also be called directly on BODY.

This is provided here as a replacement to `ert-simulate-keys', as
the approach taken by `ert-simulate-keys' doesn't allow grabbing
intermediate states. This is because Emacs won't redisplay as
long as there's pending input.

Return whatever READ eventually evaluates to."
  (declare (indent 1))
  (let ((mb-result-var (make-symbol "mb-result")))
    `(progn
       (run-with-timer
        0 nil
        (lambda ()
          (setq ,mb-result-var (progn ,read))))
       (run-with-timer
        0 nil
        (lambda ()
          (progn ,@body)
          (when (active-minibuffer-window)
            (error "Minibuffer still active at end of body form"))))
       (sleep-for 0.01)
       ,mb-result-var)))

(defun turtles--internal-grab (frame win buf calling-buf minibuffer
                                     mode-line header-line grab-faces margins)
  "Internal macro implementation for grabbing into the current buffer.

Do not call this function outside of this file."
  (let ((cur (current-buffer))
        (grab-faces (turtles-ert--filter-faces-for-grab grab-faces)))
    (cond
     (buf (turtles-grab-buffer-into buf cur grab-faces margins))
     (win (turtles-grab-window-into win cur grab-faces margins))
     (minibuffer (turtles-grab-window-into (active-minibuffer-window) cur grab-faces margins))
     (mode-line (turtles-grab-mode-line-into
                 (if (eq t mode-line) calling-buf mode-line) cur grab-faces))
     (header-line (turtles-grab-header-line-into
                   (if (eq t header-line) calling-buf header-line) cur grab-faces))
     (frame (turtles-grab-frame-into cur grab-faces))
     (t (turtles-grab-buffer-into calling-buf cur grab-faces margins)))))

(defun turtles-ert--filter-faces-for-grab (faces)
  "Filter FACES t pass to `turtles-grab-buffer-into'"
  (mapcar (lambda (c) (if (consp c) (car c) c)) faces))

(defun turtles-ert--filter-faces-for-mark (faces)
  (delq nil (mapcar (lambda (c) (if (consp c) c)) faces)))

(defun turtles-pop-to-buffer (buffer &rest pop-to-buffer-args)
  "Open a BUFFER created in a remote instance.

Customize `turtles-pop-to-buffer-actions' to configure how this
function behaves.

If `pop-to-buffer' is used, directly or indirectly, by the
action, it'll be passed POP-TO-BUFFER-ARGS after the buffer
itself."
  (unless (and (consp buffer)
               (eq 'turtles-buffer (car buffer)))
    (error "Not a turtles buffer: %s" buffer))
  (let* ((inst-id (plist-get (cdr buffer) :instance ))
         (buffer-name (plist-get (cdr buffer) :name))
         (inst (alist-get inst-id turtles-instance-alist))
         actions)
    (unless inst-id
      (error "No instance defined for buffer: %s" buffer))
    (unless buffer-name
      (error "No buffer defined in %s" buffer))
    (unless inst
      (error "Unknown instance referenced in %s" buffer))
    (unless (turtles-instance-live-p inst)
      (error "Cannot display buffer. Instance %s is dead" inst-id))
    (setq actions
          (delq nil (mapcar (lambda (func)
                              (when (funcall func 'check inst buffer)
                                func))
                            turtles-pop-to-buffer-actions)))
    (cond
     ((length= actions 0)
      (error "No available action. Check out M-x configure-option turtles-pop-to-buffer-actions"))
     ((length= actions 1)
      (apply (car actions) 'display inst buffer-name pop-to-buffer-args))
     (t
      (let* ((action-alist (mapcar (lambda (func)
                                     (cons (or (car (split-string (documentation func) "\n"))
                                               (when (symbolp func) (symbol-name func))
                                               "Anonymous action")
                                           func))
                                   actions))
             (action
             (completing-read
              "Display buffer: "
              action-alist nil 'require-match nil 'pop-to-buffer-action-history)))
        (when action
          (apply (alist-get action action-alist nil nil 'string=)
                 'display inst buffer-name pop-to-buffer-args)))))))

(defun turtles-pop-to-buffer-embedded (action inst buffer-name &rest pop-to-buffer-args)
  "Display buffer in the terminal buffer.

When called with ACTION set to \\='display, connect to the
instance INST to order it to display buffer BUFFER-NAME, then pop
to the local terminal buffer showing that instance with
`pop-to-buffer' and POP-TO-BUFFER-ARGS.

This function is meant to be added to
`turtles-pop-to-buffer-actions'"
  (cond
   ((eq 'check action) t)
   ((eq 'display action)
    ;; Display the buffer in the instance.
    (turtles-instance-eval inst
     `(set-window-buffer (frame-root-window) (get-buffer ,buffer-name)))
    (let* ((term-buf (turtles-instance-term-buf inst))
          (term-bufname (buffer-name term-buf)))
      ;; Un-hide the buffer. This allows it to show colors.
      (when (string-prefix-p " " term-bufname)
        (with-current-buffer term-buf
          (rename-buffer (string-remove-prefix " " term-bufname))))
      ;; Display the terminal buffer
      (apply #'pop-to-buffer term-buf pop-to-buffer-args)))
   (t (error "Unknown action %s" action))))

(defun turtles-pop-to-buffer-copy (action inst buffer-name &rest pop-to-buffer-args)
  "Display a copy of the instance buffer.

When called with ACTION set to \\='display, connect to the
instance INST to copy the text, point and mark of BUFFER-NAME
into a local buffer, then display that local buffer with
`pop-to-buffer' and POP-TO-BUFFER-ARGS.

This allows seeing what is in the text buffer, but not interact
with it.

This function is meant to be added to
`turtles-pop-to-buffer-actions'"
  (cond
   ((eq 'check action) t)
   ((eq 'display action)
    (let* ((local-bufname (format "[%s] %s" (turtles-instance-id inst) buffer-name))
           (buf (get-buffer local-bufname)))
    (if (and buf (buffer-local-value 'turtles--original-instance buf))
        (apply #'pop-to-buffer buf pop-to-buffer-args)
      (setq buf (generate-new-buffer local-bufname))
      (let ((ret (turtles-instance-eval inst
                  `(with-current-buffer ,buffer-name
                     (list (buffer-string) (point) (mark) (region-active-p))))))
        (with-current-buffer buf
          (setq turtles--original-instance inst)
          (insert (nth 0 ret))
          (goto-char (nth 1 ret))
          (prog1 (apply #'pop-to-buffer buf pop-to-buffer-args)
            (when (nth 2 ret)
              (push-mark (nth 2 ret) 'nomsg nil)
              (when (nth 3 ret)
                (activate-mark)))))))))
   (t (error "Unknown action %s" action))))

(defun turtles-pop-to-buffer-new-frame (action inst buffer-name &rest _ignored)
  "Ask instance to open the buffer in a new frame.

When called with ACTION set to \\='display, display BUFFER-NAME
in the Turtles instance INST, by asking the instance to create a
new frame and show that buffer there.

This can only work when running in a window system. When called
with action set to \\='check, answer nil when running in a
terminal.

This function is meant to be added to `turtles-pop-to-buffer-actions'"
  (let ((params (frame-parameters)))
    (cond
     ((eq 'check action) (alist-get 'window-system params))
     ((eq 'display action)
      (turtles-instance-eval inst
       `(let ((buf (get-buffer ,buffer-name)))
          (select-frame (make-frame
                         '((window-system . ,(alist-get 'window-system params))
                           (display . ,(alist-get 'display params)))))
          (set-window-buffer (frame-root-window) buf)
          (make-frame-visible))))
     (t (error "Unknown action %s" action)))))

(provide 'turtles)

;;; turtles.el ends here
