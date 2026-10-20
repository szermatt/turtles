;;; turtles.el --- Screen-grabbing test utility -*- lexical-binding: t -*-

;; Copyright (C) 2024, 2025 Stephane Zermatten

;; Author: Stephane Zermatten <szermatt@gmx.net>
;; Maintainer: Stephane Zermatten <szermatt@gmail.com>
;; Version: 2.1.1snapshot
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
(require 'pcase)
(require 'subr-x) ;; when-let
(require 'turtles-io)
(require 'turtles-instance)

(defcustom turtles-pop-to-buffer-actions
  '(turtles-pop-to-buffer-copy
    turtles-pop-to-buffer-embedded
    turtles-pop-to-buffer-other-frame)
  "Set of possible handlers of instance buffers.

This are actions called by `turtles-pop-to-buffer' to display
buffers from other instances. When more than on action is
available, `turtles-pop-to-buffer' show a list of possible
actions, identified by the short documentation string of the
function.

The signature of these functions must be (action inst bufname
&rest pop-to-buffer-args).

When ACTION is :check, the function must
check whether it can pop to BUFFER and, if yes, return non-nil.

When ACTION is :display, the function must do what it can do
display BUFFER.

INST is a live `turtles-instance' containing the buffer.

BUFNAME is the name of a buffer in INST."
  :type '(list function)
  :group 'turtles)

(defvar turtles-pop-to-buffer-action-history nil
  "History of action choice from `turtles-pop-to-buffer-actions'.")

(defvar-local turtles--original-instance nil
  "The original instance the buffer was copied from.

Set by `turtles-pop-to-buffer-copy'.")

(defconst turtles--basic-colors
  ["#ff0000" "#00ff00" "#0000ff" "#ffff00" "#00ffff" "#ff00ff"]
  "Color vector used to detect faces, excluding white and black.

These colors are chosen to be distinctive and easy to recognize
automatically even with the low precision of
`turtles--color-values'. They don't need to be pretty, as they're
never actually visible.")

(defvar-local turtles--left-margin-width 0
  "Width of the left margin left by `turtles--clip-in-frame-grab'.")

(defvar-local turtles--origin '(0 . 0)
  "Coordinates (X . Y) of the top-left corner of the current buffer grab.

This value is updated when the buffer is clipped and can be then used to
recover the original frame coordinates.")

(defvar turtles--ert-result nil
  "Result of running a test in another Emacs instance.")

(defvar turtles--ert-load-cache nil
  "A hash map indicating which file was just loaded.

This is set while running tests to load a file just once on an
instance and discarded afterwards.

This is a hash map whose key is a (cons instance-id file-name)
and whose value is always t.")

(defvar turtles--ert-test-abs-timeout nil
  "Absolute timeout value that ends just before the server gives up.

This value should be used as timeout within the test to be sure to end
in time.")

(defvar turtles--ert-setup-done nil
  "Non-nil if ERT integration setup was done.")

(defun turtles-ert-setup ()
  "Setup ERT integration (upstream only).

This isn't run inside instances."
  (unless (or turtles--ert-setup-done (turtles-this-instance))
    (advice-add 'ert-run-test :around #'turtles--around-ert-run-test)
    (advice-add 'ert-run-tests :around #'turtles--around-ert-run-tests)
    (advice-add 'pop-to-buffer :around #'turtles--around-pop-to-buffer)))

(defun turtles-ert-teardown ()
  "Tear Down ERT integration."
  (when turtles--ert-setup-done
    (advice-add 'ert-run-test :around #'turtles--around-ert-run-test)
    (advice-add 'ert-run-tests :around #'turtles--around-ert-run-tests)
    (advice-add 'pop-to-buffer :around #'turtles--around-pop-to-buffer)
    (setq turtles--ert-setup-done nil)))

(defun turtles-display-buffer-full-frame (buf)
  "Display BUF in the frame root window.

This is similar to Emacs 29's `display-buffer-full-frame', but
rougher and available in Emacs 26."
  (set-window-buffer (frame-root-window) buf))

(defun turtles-grab-frame (&optional win grab-faces)
  "Grab a snapshot of the current frame into the current buffer.

This includes all windows and decorations. Unless that's what you
want to test, it's usually better to call `turtles-grab-buffer'
or `turtles-grab-win', which just returns the window body.

If WIN is non-nil, this is the window that must be selected when
grabbing the frame. The grabbed pointer will be in that window.

If GRAB-FACES is empty, the colors are copied as
\\='face text properties, with as much fidelity as the
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
        (let (grabbed)
          (with-selected-window (or win (selected-window))
            (redraw-frame)
            (unless (redisplay t)
              (error "Emacs won't redisplay in this context, likely because of pending input"))
            (setq grabbed (turtles-io-call-method
                           (turtles-upstream)
                           'grab (turtles-this-instance))))
          (when (length= grabbed 0)
            (error "No frame data. If a menu is active, grab the menu instead."))
          (delete-region (point-min) (point-max))
          (insert (car grabbed))
          (goto-char (or (cdr grabbed) (point-min)))
          (when grab-faces
            (turtles--faces-from-color grab-face-alist)))
      (turtles--teardown-grab-faces cookies))))

(defun turtles-grab-menu ()
  "Grab a snapshot of the displayed menu into the current buffer.

This works for both menu-bar menu and pop-up menus.

Requires Emacs 28 or later."
  (unless (>= emacs-major-version 28)
    (error "Grabbing menus requires Emacs 28 or later"))
  (unless (turtles-io-conn-live-p (turtles-upstream))
    (error "No upstream connection"))
  (let (grabbed)
    (setq grabbed (turtles-io-call-method
                   (turtles-upstream)
                   'grab (turtles-this-instance)))
    (delete-region (point-min) (point-max))
    (insert (car grabbed)))

  ;; Identify menus by color and remove or clear everything else
  (turtles--detect-menu)
  (unless (turtles--clip-menu)
    (error "No menu"))
  (turtles--clear-non-menu)
  (goto-char (point-min)))

(defun turtles--detect-menu ()
  "Detect the parts of the buffer that show menu.

This function marks menu with the text property \\='turtles--menu t."
  (let ((colors (mapcar (lambda (spec)
                          (color-name-to-rgb
                           (turtles--face-attr spec :background)))
                        '(menu
                          tty-menu-enabled-face
                          tty-menu-disabled-face
                          tty-menu-selected-face)))
        (next (point-min)))
    (while
        (progn
          (goto-char next)
          (let* ((spec (get-text-property (point) 'face))
                 (col (when spec
                        (color-name-to-rgb
                         (turtles--face-attr spec :background))))
                 (is-menu (when col (member col colors))))
            (setq next (or (next-property-change (point)) (point-max)))
            (when is-menu
              (put-text-property (point) next 'turtles--menu t))
            (< next (point-max)))))))

(defun turtles--clip-menu ()
  "Clip out the region containing the menu."
  (pcase (turtles--compute-menu-clip)
    (`(,left ,top ,right ,bottom)
     (when (and left top right bottom)
       (prog1 t
         (turtles--clip left top right bottom))))
    (_ nil)))

(defun turtles--compute-menu-clip ()
  "Compute the smallest rectangular region containing the menu.

The menu sections must be marked with text property \\='turtles--menu t.

Returns a list containing the left, top, right and bottom position, as
appropriate for passing to `turtles--clip'."
  (let (left top right bottom)
    (goto-char (point-min))
    (let ((y 0))
      (while
          (let* ((bol (pos-bol))
                 (eol (pos-eol))
                 (beg (text-property-any bol eol 'turtles--menu t))
                 (end (when beg
                        (if (get-text-property (1- eol) 'turtles--menu)
                            eol
                          (previous-single-property-change
                           eol 'turtles--menu nil beg)))))
            (when beg
              (unless top (setq top y))
              (setq bottom (1+ y))
              (let ((beg-x (save-excursion
                             (goto-char beg)
                             (current-column)))
                    (end-x (save-excursion
                             (goto-char end)
                             (current-column))))
                (when (or (not left) (> left beg-x))
                  (setq left beg-x))
                (when (or (not right) (< right end-x))
                  (setq right end-x))))

            (cl-incf y)
            (zerop (forward-line 1)))))

    (list left top right bottom)))

(defun turtles--clear-non-menu ()
  "Clear the parts of the buffer not marked \\='turtles--menu t.

This function overwrites the parts before a menu region with spaces and
clears out the non-menu parts at the end of a line."
  (goto-char (point-min))
  (while
      (progn
        (skip-chars-forward "\n")
        (< (point) (point-max)))
    (if-let* ((pos (text-property-any (point) (pos-eol) 'turtles--menu t)))
        (progn
          ;; Fill the non-menu region with spaces, conserving column count.
          (turtles--clear-columns (point) pos)
          ;; Skip to the next non-menu character.
          (goto-char (or (text-property-any (point) (pos-eol) 'turtles--menu nil)
                         (pos-eol))))
      ;; This is the last non-menu area of the line, just delete it.
      (delete-region (point) (pos-eol)))))

(defun turtles--clear-columns (beg end)
  "Replace text between BEG and END with spaces.

Keeps the column count consistent, even there are special characters,
such as wide unicode chars.

Leaves the point at the end of the new text."
  (let (beg-col end-col)
    (goto-char beg)
    (setq beg-col (current-column))
    (goto-char end)
    (setq end-col (current-column))

    (delete-region beg end)
    (when (> end-col beg-col)
      (insert (make-string (- end-col beg-col) ?\ )))))

(defun turtles-grab-menu-bar (&optional grab-faces)
  "Grab the menu bar of the frame into the current buffer.

When this function returns, the current buffer contains the
textual representation of the menu bar.

This function uses `turtles-grab-frame'. See the documentation of
that function for details on the buffer content and the effect of
GRAB-FACES."
  (unless menu-bar-mode
    (error "Menu bar is not enabled"))
  (turtles-grab-frame nil grab-faces)
  (goto-char (point-min))
  (forward-line 1)
  (delete-region (point) (point-max))
  (goto-char (point-min)))

(defun turtles--all-displayed-buffers ()
  "Return a list of all buffers shown in a window."
  (let ((bufs (list)))
    (dolist (win (window-list))
      (when-let* ((buf (window-buffer win)))
        (unless (memq buf bufs)
          (push buf bufs))))

    bufs))

(defun turtles--setup-buffer (&optional buf)
  "Setup the turtles frame to display BUF and return the window.

If BUF is nil, the current buffer is used instead."
  (or (get-buffer-window buf)
      (progn
        (turtles-display-buffer-full-frame buf)
        (frame-root-window))))

(defun turtles-grab-buffer (buf &optional grab-faces margins)
  "Display BUF in the grabbed frame and grab it into the current buffer.

When this function returns, the current buffer contains the textual
representation of BUF as displayed in the root window of the
grabbed frame.

If MARGINS is non-nil, include the left and right margins.

This function uses `turtles-grab-window' after setting up
the buffer. See the documentation of that function for details on
the buffer content and the effect of GRAB-FACES."
  (turtles-grab-window (turtles--setup-buffer buf) grab-faces margins))

(defun turtles-grab-mode-line (win-or-buf &optional grab-faces)
  "Grab the mode line of WIN-OR-BUF into the current bufferE.

When this function returns, the current buffer contains the
textual representation of the mode line of WIN-OR-BUF.

This function uses `turtles-grab-window' after setting up
the buffer. See the documentation of that function for details on
the buffer content and the effect of GRAB-FACES."
  (let ((win (if (bufferp win-or-buf)
                 (turtles--setup-buffer win-or-buf)
               win-or-buf)))
    (turtles-grab-frame win grab-faces)
    (pcase-let ((`(,left _ ,right ,bottom) (window-edges win nil))
                (`(_ _ _ ,body-bottom) (window-edges win 'body)))
      (turtles--clip left body-bottom right bottom))))

(defun turtles-grab-header-line (win-or-buf &optional grab-faces)
  "Grab the header line of WIN-OR-BUF into the current bufferE.

When this function returns, the current buffer contains the
textual representation of the header line of WIN-OR-BUF.

This function uses `turtles-grab-window' after setting up
the buffer. See the documentation of that function for details on
the buffer content and the effect of GRAB-FACES."
  (let ((win (if (bufferp win-or-buf)
                 (turtles--setup-buffer win-or-buf)
               win-or-buf)))
    (turtles-grab-frame win grab-faces)
    (pcase-let ((`(,left ,top ,right _) (window-edges win nil))
                (`(_ ,body-top _ _) (window-edges win 'body)))
      (turtles--clip left top right body-top))))

(defun turtles-grab-window (win &optional grab-faces margins)
  "Grab WIN into the current buffer.

WIN must be a window on the turtles frame.

When this function returns, the current buffer contains the
textual representation of the content of that window. The point,
is also set to corresponding positions in the current buffer, if
possible.

If MARGINS is non-nil, include the left and right margins.

If GRAB-FACES is empty, the colors are copied as
\\='face text properties, with as much fidelity as the
terminal allows.

If GRAB-FACES is not empty, the faces on that list - and only
these faces - are recovered into \\='face text properties. Note
that in such case, no other face or color information is grabbed,
so any other face not in GRAB-FACE are absent."
  (turtles-grab-frame win grab-faces)
  (pcase-let ((`(,left _ ,right _) (window-edges win (not margins)))
              (`(,left-body ,top _ ,bottom) (window-edges win 'body)))
    (setq-local turtles--left-margin-width (- left-body left))
    (turtles--clip left top right bottom)))

(defun turtles--clip-in-frame-grab (win margins)
  "Clip the frame grab in the current buffer to the body of WIN.

If MARGINS is non-nil, include the margins and set
`turtles--left-margin-width'."
  (pcase-let ((`(,left _ ,right _) (window-edges win (not margins)))
              (`(,left-body ,top _ ,bottom) (window-edges win 'body)))
    (setq-local turtles--left-margin-width (- left-body left))
    (turtles--clip left top right bottom)))

(defun turtles--clip (left top right bottom)
  "Clip the frame grab in the current buffer to the given edges.

LEFT TOP RIGHT and BOTTOM are coordinate relative to the current
buffer's origins."
  (let ((origin (or (get-text-property (point-min) 'turtles-origin)
                    (cons 0 0))))
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
        (delete-region (point-min) (point))))

    (when (> (point-max) (point-min))
      (put-text-property (point-min) (1+ (point-min))
                         'turtles-origin
                         (cons (+ left (car origin))
                               (+ top (cdr origin)))))))

(defun turtles--to-frame-coordinates (pos)
  "Get the frame coordinates of POS.

This call reports the original coordinates of buffers clipped by
`turtles--clip'."
  (let ((origin (or (get-text-property (point-min) 'turtles-origin)
                    (cons 0 0))))
    (save-excursion
      (goto-char pos)

      (cons (+ (car origin) (current-column))
            (+ (cdr origin) (1- (line-number-at-pos)))))))


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
    (let ((color-count (length turtles--basic-colors))
          grab-face-alist cookies remapping)

      ;; That should be enough for any reasonable number of faces, but
      ;; if not, the vector can could be extended to use more
      ;; distinctive colors.
      (when (> (length grab-faces) (* color-count color-count))
        (error "Too many faces to highlight"))

      (dolist (face grab-faces)
        (let* ((idx (length remapping))
               (bg (aref turtles--basic-colors (% idx color-count)))
               (fg (aref turtles--basic-colors (/ idx color-count)))
               (extend (when (eval-when-compile (>= emacs-major-version 27))
                         `(:extend ,(turtles--extend-p face)))))
          (push (cons face `(:background ,bg :foreground ,fg . ,extend))
                remapping)))

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

This function replaces the face color properties set by
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
            (let* ((spec (get-text-property (point) 'face))
                   (col (when spec (turtles--color-values spec)))
                   (face (when col (alist-get col reverse-face-alist nil nil #'equal))))
              (when face
                (setq current-face face)
                (setq range-start (point))))
            (setq next (next-property-change (point)))

            (let ((next (or next (point-max))))
              (when (> next (point))
                (remove-text-properties (point) next '(face nil)))
              (when current-face
                (when (and (>= (- range-start 2) (point-min))
                           (eq (char-before range-start) ?\n)
                           (eq current-face (get-text-property (- range-start 2) 'face))
                           (turtles--extend-p current-face))
                  (cl-decf range-start))
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
asked to grab faces. It won't work in the general case.

If the region covered by the face spans newlines, you might get
different results under Emacs 26 than under Emacs 27 and later.
Under Emacs 26, faces always apply to the empty space between the
end of the line and the edge of the window. Under Emacs 27 and
later, only a few faces behave that way, such as region. This is
controlled by the:extend face attribute, which this function
checks and follows."
  (when face-marker-alist
    (save-excursion
      (let ((next (point-min))
            (closing nil)
            (extend nil))
        (while
            (progn
              (goto-char next)
              (when-let* ((face (get-text-property (point) 'face))
                          (markers (alist-get face face-marker-alist)))
                (pcase-let ((`(,op . ,close) (turtles--split-markers markers)))
                  (insert op)
                  (setq extend (turtles--extend-p face))
                  (setq closing close)))
              (setq next (or (next-single-property-change
                              (point) 'face) (point-max)))

              (when closing
                (goto-char next)
                (when (and extend (or (= next (point-max))
                                      (eq (char-after (point)) ?\n)))
                  (while (eq (char-before (point)) ?\ )
                    (goto-char (1- (point)))))
                (insert closing)
                (setq next (+ (length closing) next))
                (setq closing nil))

              (< next (point-max))))))))

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
  "Insert MARK on the current point.

The idea is to make the current position of the point visible
when looking at the `buffer-string'.

Only useful over insert to clarify intend."
  (insert mark))

(defun turtles-trim-buffer ()
  "Remove trailing spaces and final newlines.

This function avoids having to hardcode many spaces and newlines
resulting from frame capture in tests. It removes trailing spaces
in the whole buffer and any newlines at the end of the buffer."
  (delete-trailing-whitespace)
  (while (eq ?\n (char-before (point-max)))
    (delete-region (1- (point-max)) (point-max))))

(cl-defmacro turtles-ert-deftest
    (name (&key instance timeout) &body body)
  "Define an ERT test to run on a secondary Emacs instance.

This macro is the Turtles equivalent of `ert-deftest'. It is a full drop-in
replacement for `ert-deftest' with the following differences:

- The test is run in a secondary Emacs instance
- It supports additional, optional key arguments within parentheses
  after the name: INSTANCE and TIMEOUT.

NAME is the name of the ERT test.

:instance INSTANCE is the name of a Turtles instance previously defined with
`turtles-definstance'. It defaults to the instance \\='default.

:timeout TIMEOUT is the time, in seconds, that Turtles should wait for
the secondary instance to return a result before giving up. Increase
this value if your test is slow.

BODY, the rest, is interpreted by `ert-deftest', which see. It contains
an optional docstring, followed by :tags or :expect key arguments, then
the body, possibly containing special forms `should', `should-not',
`skip-when' or `skip-unless', as defined by `ert-deftest'."
  (declare (debug (&define [&name "test@" symbolp]
                           sexp [&optional stringp]
                           [&rest keywordp sexp] def-body))
           (doc-string 3)
           (indent 2))
  (let ((fname-var (make-symbol "fname")))
  `(let ((,fname-var (macroexp-file-name)))
     (turtles-ert-setup)
     ,(append
       `(ert-deftest ,name ())
       (car (turtles--ert-test-body-split body))
       `((turtles--ert-test ,instance ,fname-var ,timeout))
       (cdr (turtles--ert-test-body-split body))))))

(defun turtles--ert-test-body-split (body)
  "Split BODY into header and body.

BODY should be the body of an `ert-deftest'. The return header contains
the docstring and key arguments.

The result is a (cons HEADER REST)"
  (let ((header nil)
        (rest body))
    (when (stringp (car rest))
      (push (pop rest) header))
    (while (let ((maybe-sym (car rest)))
             (and (symbolp maybe-sym)
                  (string-prefix-p ":" (symbol-name maybe-sym))))
      (push (pop rest) header)
      (push (pop rest) header))
    (cons (nreverse header) rest)))

(defun turtles--ert-test (inst-id file-name timeout)
  "Run the current test in another Emacs instance.

This function is what turns an `ert-deftest' into a
`turtles-ert-deftest'.

INST-ID is the instance to start up. It default to \\='default.

FILE-NAME the file the test is defined in, if any.

TIMEOUT, if set, is the time, in seconds, to wait for an answer
from the instance. Set it for slow tests when the default timeout
just won't do."
  (unless (turtles-this-instance)
    (let* ((test (ert-running-test))
           (test-sym (when test (ert-test-name test)))
           (inst-id (or inst-id 'default))
           (inst (turtles-get-instance inst-id)))
      (unless test (error "Not in an ERT test"))
      (cl-assert test-sym)

      (unless inst
        (error "No turtles instance defined with ID %s" inst-id))

      (turtles-start-instance inst)
      (let* ((end-time (turtles-io--timeout-to-end-time (or timeout 10.0)))
             (early-end-time (time-subtract end-time (seconds-to-time 1.0)))
             (test-sexpr `(progn
                            (setq turtles--ert-test-abs-timeout '(absolute . ,early-end-time))
                            (ert-run-test test)
                            (ert-test-most-recent-result test)))
             (conn (turtles-instance-conn inst))
             res)
        (when (<= (turtles-io--remaining-seconds early-end-time) 0)
          (error "Turtles test timeout too short. Must be larger than 1s"))
        (if file-name
            ;; Reload test from file-name. This guarantees that
            ;; everything around that test, such as requires, has also
            ;; been defined on the instance.
            (progn
              (setq res
                    (turtles-io-call-method
                     conn 'ert-test
                     `(progn
                        ,(unless (and turtles--ert-load-cache
                                      (gethash (cons inst-id file-name)
                                               turtles--ert-load-cache))
                           `(load ,file-name nil 'nomessage 'nosuffix))

                        (let ((test (ert-get-test (quote ,test-sym))))
                          ,test-sexpr))
                     :timeout `(absolute . ,end-time)))
              (when turtles--ert-load-cache
                (puthash (cons inst-id file-name) t turtles--ert-load-cache)))

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

                    ,test-sexpr)
                 :timeout `(absolute . ,end-time))))

        (turtles--process-result-from-instance res)
        (setq turtles--ert-result res))

      ;; ert-pass interrupt the server-side portion of the test. The
      ;; real result will be collected from turtles--ert-result by
      ;; turtles--around-ert-run-test. What follows is the
      ;; client-side portion of the test only.
      (ert-pass))))

(defun turtles--process-result-from-instance (result)
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

(defun turtles--around-ert-run-test (func test &rest args)
  "Collect test results sent by another Emacs instance.

This function takes results set up by `turtles--ert-test' and puts
them into the local `ert-test' instance.

This function is meant to be used as around advice for
`ert-run-test'. FUNC is the original `ert-run-test' to call, TEST
the ert-test instance to run and ARGS whatever other argument
need to be forwarded to FUNC."
  (let ((turtles--ert-result nil))
    (apply func test args)
    (when turtles--ert-result
      (setf (ert-test-most-recent-result test) turtles--ert-result))))

(defun turtles--around-ert-run-tests (func &rest args)
  "Collect test results sent by another Emacs instance.

This function takes results set up by `turtles--ert-test' and puts
them into the local `ert-test' instance.

This function is meant to be used as around advice for
`ert-run-test'. FUNC is the original `ert-run-tests' to call ARGS
whatever other argument need to be forwarded to FUNC."
  (let ((turtles--ert-load-cache (make-hash-table :test 'equal)))
    (apply func args)))

(cl-defun turtles-to-string (&key (name "grab")
                                   frame win buf minibuffer mode-line header-line
                                   menu menu-bar
                                   margins faces point (trim t))
  "Grab a section of the terminal and return the result as a string.

With no arguments, this function renders the current buffer in
the turtles frame, and returns the result as a string.

The rendered buffer is grabbed into an ERT test buffer with the
name \"grab\". When running interactively, ERT keeps such buffers
when tests fail so they can be checked out. Specify the keyword
argument NAME to modify the name of the test buffer.

The following keyword arguments modify what is grabbed:

  - The key argument BUF specifies a buffer to capture. It
    defaults to the current buffer. The buffer is installed as
    single window in the frame, rendered, then grabbed.

  - The key argument WIN specifies a window to grab.

  - The key argument MODE-LINE specifies a window or buffer to
    grab the mode line of, or t to grab the mode line of the
    current buffer.

  - The key argument HEADER-LINE specifies a window or buffer to
    grab the header line of, or t to grab the header line of the
    current buffer.

  - Set the key argument MINIBUFFER to t to capture the content
    of the minibuffer window.

  - Set the key argument FRAME to t to capture the whole frame.

  - If key argument MARGINS is non-nil, include the left and
    right margin when grabbing the content of a window or buffer.

  - If key argument MENU is non-nil, grab the menu currently
    shown of the frame. This will fail if no menu is active.

  - If key argument MENU-BAR is non-nil, grab the frame's menu
    bar. This will fail if `menu-bar-mode' is not enabled.

The following keyword arguments post-process what was grabbed:

  - Set the key argument TRIM to nil to not trim the newlines
    at the end of the grabbed string. Without trimming, there
    is one newline per line of the grabbed window, even if
    the buffer content is shorter.

  - Pass a string to the key argument POINT to insert at point,
    so that position is visible in the returned string.

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
       frame win buf calling-buf minibuffer mode-line header-line
       menu menu-bar faces margins)
      (turtles--internal-postprocess point faces trim)
      (buffer-substring-no-properties (point-min) (point-max)))))

(cl-defmacro turtles-with-grab-buffer ((&key (name "grab")
                                              frame win buf minibuffer mode-line header-line
                                              menu menu-bar
                                              margins faces point (trim t))
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
or window, the point will be grabbed as well. Additionally,
unless FACES is specified, captured colors are available as
overlay colors, within the limits of the turtles terminal,
usually limited to 256 colors.

The following keyword arguments can be specified in parentheses,
before BODY, to modify what is grabbed:

  - The key argument BUF specifies a buffer to capture. It
    defaults to the current buffer. The buffer is installed as
    single window in the frame, rendered, then grabbed.

  - The key argument WIN specifies a window to grab.

  - The key argument MODE-LINE specifies a window or buffer to
    grab the mode line of, or t to grab the mode line of the
    current buffer.

  - The key argument HEADER-LINE specifies a window or buffer to
    grab the header line of, or t to grab the header line of the
    current buffer.

  - Set the key argument MINIBUFFER to t to capture the content
    of the minibuffer window.

  - If key argument MARGINS is non-nil, include the left and
    right margin when grabbing the content of a window or buffer.

  - Set the key argument FRAME to t to capture the whole frame.

  - If key argument MENU is non-nil, grab the menu currently
    shown of the frame. This will fail if no menu is active.

  - If key argument MENU-BAR is non-nil, grab the frame's menu
    bar. This will fail if `menu-bar-mode' is not enabled.

The following keyword arguments can be specified in parentheses,
before BODY, to customize how what is grabbed is post-processed:

  - The key argument FACES asks for a specific set of faces to
    be detected and grabbed. They'll be available as face
    symbols set to the properties \\='face.

    If necessary, faces can be made easier to test with text
    comparison with `turtles-mark-text-with-faces'.

    Note that colors won't be available in the grabbed buffer
    content when FACES is specified.

  - Pass a string to the key argument POINT to insert at point,
    so that position is visible in the returned string.

  - Set the key argument TRIM to nil to *not* trim the newlines
    at the end of the grabbed string. Without trimming, there is
    one newline per line of the grabbed window, even if the
    buffer content is shorter."
  (declare (indent 1))
  (let ((calling-buf (make-symbol "calling-buf"))
        (faces-var (make-symbol "faces")))
    `(let ((,calling-buf (current-buffer))
           (,faces-var ,faces))
       (ert-with-test-buffer (:name ,name)
         (turtles--internal-grab
          ,frame ,win ,buf ,calling-buf ,minibuffer
          ,mode-line ,header-line ,menu ,menu-bar ,faces-var ,margins)
         (turtles--internal-postprocess ,point ,faces-var ,trim)
         ,@body))))

(defun turtles--internal-postprocess (point faces trim)
  "Post-process a grabbed buffer.

This is a helper for macros in this file. Don't use it outside of
it; call the functions directly.

POINT marks the position of the cursor.

Any alist cell that FACES contains are forwarded to
`turtle-mark-text-with-faces'.

TRIM controls whether `turtles-trim-buffer' should be called"
  (when point
    (insert point))
  (when faces
    (turtles-mark-text-with-faces
     (delq nil (mapcar (lambda (c) (if (consp c) c)) faces))))
  (when trim
    (turtles-trim-buffer)))

(defmacro turtles-with-minibuffer (read &rest body)
  "Run BODY while executing READ.

READ is a form that reads from the minibuffer and return the
result.

BODY is executed while READ is waiting for minibuffer input with
the minibuffer active. The minibuffer exits at the end of BODY,
and the whole macro returns with the result of READ.

BODY can be a mix of:
 - Lisp expressions
 - :keys \"...\"
 - :events [...]
 - :command #\\='mycommand
 - :command-with-keybinding keybinding #\\='mycommand
 - :mouse-ev \\'event \\'(x . y)
 - :mouse-ev-list \\='((event (x . y)) (event (x . y)) ... )

See `turtles-interaction' for details on BODY elements.

Return whatever READ eventually evaluates to."
  (declare (indent 1))
  `(turtles--interaction-internal
    (lambda () ,read)
    ,(turtles--split-interaction-body body '(turtles--with-minibuffer-body-end))
    nil))

(defmacro turtles-interaction (&rest body)
  "Run BODY while interacting with Emacs.

Starts a `recursive-edit' and runs BODY to interact with the Emacs
interface.

BODY can be a mix of:
 - Lisp expressions
 - :keys \"...\"
 - :events [...]
 - :command #\\='mycommand
 - :command-with-keybinding keybinding #\\='mycommand
 - :mouse-ev \\'event \\'(x . y)
 - :mouse-ev-list \\='((event (x . y)) (event (x . y)) ... )

:keys must be followed by a string in the same format as accepted
by `kbd'. It tells Turtles to feed some input to Emacs to be
executed in the normal command loop. This is the real thing,
contrary to `execute-kbd-macro' or `ert-simulate-keys'.

:events works as :keys but takes an event array. This alternative
can be useful to feed non-keyboard events to the current
instance.

:mouse-ev and :mouse-ev-list send actual mouse events, so you don't have
to re-create these specific events.  x and y are 0-based frame
coordinates. event is the event name, as
understood by Emacs, such as:
 - \\='mouse-1 or \\='mouse-2 , for a click,
 - \\='down-mouse-1 for a button press,
 - \\='down-mouse-1 then \\='mouse-movement, then \\='drag-mouse-1 for
   a mouse drag or selection.

You can also add modifiers control, shift or meta/alt to event, so for
example the event for a control click is \\='C-mouse-1.

:command must be followed by a command. It tells turtle to make
Emacs execute that command in the normal command loop.

:command-with-keybinding must be followed by a keybinding and a
command. The command is executed in the normal command loop, with
`this-command-keys' reporting it to have been triggered by the
given keybinding.

It most cases, the difference between sending keys or launching a
command directly or interactively doesn't matter and it's just
more convenient to call commands directly as a lisp expression
rather than use :keys or :command.

BODY usually contains calls to `should' to check the Emacs state,
and `turtles-with-grab-buffer' or `turtles-to-string' to check
its display.

This is provided here as a replacement to `ert-simulate-keys', as
the approach taken by `ert-simulate-keys' doesn't allow grabbing
intermediate states, because Emacs won't redisplay as long as
there's pending input.

Does not return anything."
  (declare (indent 0))
  `(turtles--interaction-internal
    #'recursive-edit
    ,(turtles--split-interaction-body body '(ignore))
    'force-exit))

(cl-defun turtles-coords (needle &key (at 'center)
                                 frame win buf minibuffer mode-line header-line
                                 menu menu-bar margins)
  "Return the frame coordinates of the first match for NEEDLE.

Returns a (cons X Y) with 0-based frame coordinates.

The key argument AT specifies where in the match to return
coordinates for:
  - \\='center (the default): at the center of the match
  - \\='beginning: on the first character of the match
  - \\='end: just after the last character of the match

The search can be restricted using the same key arguments as
`turtles-to-string': FRAME, WIN, BUF, MINIBUFFER, MODE-LINE,
HEADER-LINE, MENU, MENU-BAR and MARGINS. With none of these
arguments set, the current buffer is searched."
  (let ((calling-buf (current-buffer)))
    (with-temp-buffer
      (turtles--internal-grab
       frame win buf calling-buf minibuffer mode-line header-line
       menu menu-bar nil margins)
      (goto-char (point-min))
      (search-forward needle)
      (turtles--to-frame-coordinates
       (turtles--match-position 0 at)))))

(cl-defun turtles-coords-regexp (regexp
                                 &key (group 0) (at 'center)
                                 frame win buf minibuffer mode-line header-line
                                 menu menu-bar margins)
  "Return the frame coordinates of the first match for REGEXP.

Returns a (cons X Y) with 0-based frame coordinates.

The key argument GROUP and AT specifies where in the match to return
coordinates for:
  - \\='center (the default): at the center of the match GROUP
  - \\='beginning: on the first character of the match GROUP
  - \\='end: just after the last character of the match GROUP

The search can be restricted using the same key arguments as
`turtles-to-string': FRAME, WIN, BUF, MINIBUFFER, MODE-LINE,
HEADER-LINE, MENU, MENU-BAR and MARGINS. With none of these
arguments set, the current buffer is searched."
  (let ((calling-buf (current-buffer)))
    (with-temp-buffer
      (turtles--internal-grab
       frame win buf calling-buf minibuffer mode-line header-line
       menu menu-bar nil margins)
      (goto-char (point-min))
      (search-forward-regexp regexp)
      (turtles--to-frame-coordinates
       (turtles--match-position group at)))))

(defun turtles--match-position (group at)
  "Return a position for match group GROUP.

AT specifies where in the group the position should be taken, at the
\\='center, \\='beginning or \\='end."
  (pcase at
    ('beginning (match-beginning group))
    ('end (match-end group))
    ('center (/ (+ (match-beginning group)
                   (match-end group))
                2))
    (_ (error "Unsupported :at value: %s" at))))

(cl-defun turtles-mouse-selection (start end &key steps (button 'mouse-1))
  "Generate a list of mouse events to drag from START to END.

START and END are frame coordinates as (cons X Y), as returned by
`turtles-coords' and `turtles-coords-regexp'.

The key argument STEPS, if specified, is the number of intermediate
`mouse-movement' events to generate between START and END.

The key argument BUTTON is the mouse button event ID to use, such as
\\='mouse-1 (the default), \\='mouse-2, \\='C-mouse-1, etc.

Returns a list of events suitable for passing to :mouse-ev-list."
  (let* ((ev-parsed (turtles--parse-event-type button))
         (basic-type (car ev-parsed))
         (mods (cdr ev-parsed))
         (down-ev (turtles--build-event-type basic-type 'down mods))
         (move-ev (turtles--build-event-type 'mouse-movement nil mods))
         (drag-ev (turtles--build-event-type basic-type 'drag mods))
         (events (list (list down-ev start)))
         (start-x (car start))
         (start-y (cdr start))
         (dx (- (car end) (car start)))
         (dy (- (cdr end) (cdr start))))
    (unless (string-match-p "mouse-[0-9]+" (symbol-name basic-type))
      (error "Unsupported button type: %s" basic-type))
    (dolist (mod mods)
      (unless (member mod '("C" "S" "M" "A"))
        (error "Unsupported button modifier: %s in %s" mod button)))
    (when (and steps (> steps 0))
      (dotimes (i steps)
        (push (list
               move-ev
               (cons
                (round (+ start-x (/ (* dx (float (1+ i))) (1+ steps))))
                (round (+ start-y (/ (* dy (float (1+ i))) (1+ steps))))))
              events)))
    (push (list drag-ev end) events)
    (nreverse events)))

(defun turtles--interaction-internal (readfunc bodyfunclist force-exit)
  "Implementation of `turtles-interaction'.

READFUNC is a function created from the READ argument of the macro.

BODYFUNCLIST is created from the BODY argument of the macro, by
`turtles--split-interaction-body'.

If FORCE-EXIT, forcibly exit all recursive edits after running
BODYFUNCLIST."
  (when noninteractive
    (error "Cannot work in noninteractive mode. Did you forget to use (turtles-ert-deftest)?"))
  (let ((read-timer nil)
        (body-started nil)
        (body-timer nil)
        (timeout-timer nil)
        (end-time (turtles-io--timeout-to-end-time (or turtles--ert-test-abs-timeout 10.0))))
    (unwind-protect
        (progn
          (pcase
              (catch 'turtles-interaction-return
                (setq read-timer
                      (run-with-timer
                       0 nil
                       (lambda ()
                         (let ((result (list 'read nil nil)))
                           (if (>= emacs-major-version 30)
                               (condition-case-unless-debug err
                                   (setf (nth 2 result) (funcall readfunc))
                                 (t (setf (nth 1 result) err)))
                             (setf (nth 2 result) (funcall readfunc)))
                           (throw 'turtles-interaction-return result)))))
                (setq body-timer
                      (run-with-timer
                       0 nil
                       (lambda ()
                         (setq body-started t)
                         ;; May throw turtles-interaction-return
                         ;; '(body err) when done, but more often ends
                         ;; up throwing 'exit to exit the minibuffer.
                         (turtles--run-once-input-processed
                          (lambda (newtimer)
                            (setq body-timer newtimer))
                          bodyfunclist
                          force-exit))))

                ;; We use a timer that throws for timeout, as
                ;; sleep-for usually just gets stuck on running
                ;; readfunc.
                (setq timeout-timer
                      (run-with-timer
                       (turtles-io--remaining-seconds end-time) nil
                       (lambda ()
                         (throw 'turtles-interaction-return 'timeout))))

                (sleep-for (max 0.0 (turtles-io--remaining-seconds end-time)))
                (error "Timed out"))

            ('timeout
             (error "Timed out. The BODY section failed to exit the recursive edit or minibuffer"))

            ;; The read section ended. The BODY section might not have
            ;; run fully, but it must have started, since it's what
            ;; should have made the READ section end.
            (`(read ,err ,result)
             ;; Forward errors. Starting with Emacs 30, error thrown
             ;; from within the read timer may be swallowed.
             (when err
               (signal (car err) (cdr err)))
             (unless body-started
               (error "READ section ended before BODY section could start (result: %s)" result))

             result)

            ;; The BODY section ended successfully. It's the
            ;; responsibility of the BODY section to make the READ
            ;; section exit, so it's wrong for the BODY section to end
            ;; successfully before the READ section.
            (`(body nil)
             (error "BODY section ended without exiting the READ section"))

            ;; The BODY section failed. We forward errors from the BODY
            ;; section. Starting with Emacs 30, errors thrown from
            ;; within the body timer may be swallowed otherwise.
            (`(body ,err)
             (signal (car err) (cdr err)))

            (other (error "Unexpected value: %s" other))))
      (when read-timer
        (cancel-timer read-timer))
      (when body-timer
        (cancel-timer body-timer))
      (when timeout-timer
        (cancel-timer timeout-timer)))))

(defun turtles--with-minibuffer-body-end ()
  "The end of the body of `turtles--with-minibuffer'.

This closes the minibuffer, in case the body left it open."
  (when-let* ((win (active-minibuffer-window)))
    (with-current-buffer (window-buffer win)
      (exit-minibuffer))))

(defun turtles--split-interaction-body (body body-end)
  "Interpret :keys and others in BODY.

This is the core code-generation logic of `turtles-interaction'.

This function splits a BODY containing a mix of Lisp expressions,
:keys string, :command cmd, :command-with-keybinding keybinding
cmd, into a list of lambdas that can be fed to
`turtles--interaction-internal'."
  (let* ((rest body)
         (lambdas nil)
         (current-lambda nil)
         (close-current-lambda
          (lambda ()
            (when current-lambda
              (push `(lambda () . ,(nreverse current-lambda)) lambdas)
              (setq current-lambda nil)))))
    (while rest
      (cond
       ((eq :keys (car rest))
        (pop rest)
        (push `(turtles--send-input (kbd ,(pop rest))) current-lambda)
        (funcall close-current-lambda))
       ((eq :events (car rest))
        (pop rest)
        (push `(turtles--send-input ,(pop rest)) current-lambda)
        (funcall close-current-lambda))
       ((eq :command (car rest))
        (pop rest)
        (push `(turtles--send-command ,(pop rest)) current-lambda)
        (funcall close-current-lambda))
       ((eq :command-with-keybinding (car rest))
        (pop rest)
        (let ((keybinding (kbd (pop rest)))
              (command (pop rest)))
          (push `(turtles--send-command ,command ,keybinding)
                current-lambda))
        (funcall close-current-lambda))
       ((eq :mouse-ev (car rest))
        (pop rest)
        (push `(turtles--send-mouse-ev-list (list (list ,(pop rest) ,(pop rest))))
              current-lambda)
        (funcall close-current-lambda))
       ((eq :mouse-ev-list (car rest))
        (pop rest)
        (push `(turtles--send-mouse-ev-list ,(pop rest)) current-lambda)
        (funcall close-current-lambda))
       ((and (symbolp (car rest)) (string-prefix-p ":" (symbol-name (car rest))))
        (error "Unknown symbol for interaction: %s" (pop rest)))
       (t (push (pop rest) current-lambda))))
    (push body-end current-lambda)
    (funcall close-current-lambda)

    `(list . ,(nreverse lambdas))))

(defun turtles--internal-grab (frame win buf calling-buf minibuffer
                                     mode-line header-line menu menu-bar
                                     grab-faces margins)
  "Internal macro implementation for grabbing into the current buffer.

Do not call this function outside of this file.

If FRAME is non-nil, call `turtles-grab-frame'.
If WIN is set, pass it to `turtles-grab-window'.
if BUF is set, pass it to `turtles-grab-buffer'.
If MINIBUFFER is non-nil, grab the minibuffer.
If MODE-LINE is non nil, pass it to `turtles-grab-mode-line'.
If HEADER-LINE is non nil, pass it to `turtles-grab-header-line'.
If MENU is non nil, pass it to `turtles-grab-menu'.
If MENU-BAR is non nil, call `turtles-grab-menu-bar'.
Otherwise, pass CALLING-BUF to `turtles-grab-buffer'.

Pass GRAB-FACES and MARGIN to whatever grab function is called,
 if relevant."
  (let ((grab-faces (mapcar (lambda (c) (if (consp c) (car c) c)) grab-faces)))
    (cond
     (buf (turtles-grab-buffer buf grab-faces margins))
     (win (turtles-grab-window win grab-faces margins))
     (minibuffer (turtles-grab-window (minibuffer-window) grab-faces margins))
     (mode-line (turtles-grab-mode-line
                 (if (eq t mode-line) calling-buf mode-line) grab-faces))
     (header-line (turtles-grab-header-line
                   (if (eq t header-line) calling-buf header-line) grab-faces))
     (menu (turtles-grab-menu))
     (menu-bar (turtles-grab-menu-bar grab-faces))
     (frame (turtles-grab-frame nil grab-faces))
     (t (turtles-grab-buffer calling-buf grab-faces margins)))))

(defun turtles--filter-faces-for-mark (faces)
  "Filter FACES to pass to `turtles-mark-text-with-faces'."
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
                              (when (funcall func :check inst buffer)
                                func))
                            turtles-pop-to-buffer-actions)))
    (cond
     ((length= actions 0)
      (error "No available action. Check out M-x configure-option turtles-pop-to-buffer-actions"))
     ((length= actions 1)
      (apply (car actions) :display inst buffer-name pop-to-buffer-args))
     (t
      (let* ((action-alist (mapcar (let ((counter 0))
                                     (lambda (func)
                                       (cons
                                        (if (symbolp func)
                                            (string-remove-prefix
                                             "turtles-pop-to-buffer-" (symbol-name func))
                                          (format "lambda-%d" (cl-incf counter)))
                                        func)))
                                   actions))
             (completion-extra-properties
              `(:annotation-function
                ,(lambda (key)
                   (let ((func (alist-get key action-alist nil nil #'string=)))
                     (when-let* ((shortdoc (car (split-string (documentation func) "\n"))))
                       (concat " " shortdoc))))))
             (action
              (alist-get
               (completing-read
                "Display buffer: "
                action-alist nil 'require-match nil 'pop-to-buffer-action-history)
               action-alist nil nil #'string=)))
        (when action
          (apply action :display inst buffer-name pop-to-buffer-args)))))))

(defun turtles-pop-to-buffer-embedded (action inst buffer-name &rest pop-to-buffer-args)
  "Display buffer in the terminal buffer.

When called with ACTION set to :display, connect to the
instance INST to order it to display buffer BUFFER-NAME, then pop
to the local terminal buffer showing that instance with
`pop-to-buffer' and POP-TO-BUFFER-ARGS.

This function is meant to be added to
`turtles-pop-to-buffer-actions'"
  (cond
   ((eq :check action) t)
   ((eq :display action)
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

When called with ACTION set to :display, connect to the
instance INST to copy the text, point and mark of BUFFER-NAME
into a local buffer, then display that local buffer with
`pop-to-buffer' and POP-TO-BUFFER-ARGS.

This allows seeing what is in the text buffer, but not interact
with it.

This function is meant to be added to
`turtles-pop-to-buffer-actions'"
  (cond
   ((eq :check action) t)
   ((eq :display action)
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

(defun turtles-pop-to-buffer-other-frame (action inst buffer-name &rest _ignored)
  "Open buffer on the instance, in another frame.

When called with ACTION set to :display, display BUFFER-NAME
in the Turtles instance INST, by asking the instance to create a
new frame and show that buffer there.

This can only work when running in a window system. When called
with action set to :check, answer nil when running in a
terminal.

This function is meant to be added to `turtles-pop-to-buffer-actions'"
  (let* ((params (frame-parameters))
         (window-system (alist-get 'window-system params))
         (display (alist-get 'display params)))
    (cond
     ((eq :check action) (alist-get 'window-system params))
     ((eq :display action)
      (turtles-instance-eval inst
       `(let ((buf (get-buffer ,buffer-name)))
          (select-frame
           (or
            (car (delq nil
                       (mapcar
                        (lambda (f)
                          (let ((params (frame-parameters f)))
                            (when (and (eq ',window-system
                                           (alist-get 'window-system params))
                                       (eq ',display
                                           (alist-get 'display params)))
                              f)))
                        (frame-list))))
            (make-frame
             '((window-system . ,(alist-get 'window-system params))
               (display . ,(alist-get 'display params))))))
          (set-window-buffer (frame-root-window) buf)
          (make-frame-visible))))
     (t (error "Unknown action %s" action)))))

(defun turtles--extend-p (face)
  "Return non-nil if FACE has a non-nil :extend attribute."
  (if (eval-when-compile (>= emacs-major-version 27))
      (face-attribute face :extend nil 'default)
    ;; Under Emacs 26, all faces are treated as if they had :extend t.
    ;; Returning t here is consistent with Emacs 26, but will mean
    ;; that some tests have to treat Emacs 26 differently to work
    ;; properly.
    t))

(provide 'turtles)

;;; turtles.el ends here
