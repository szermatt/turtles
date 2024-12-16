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

(require 'compat)
(require 'term)
(require 'server)
(require 'turtles-io)
(require 'subr-x) ;; when-let

(defvar term-home-marker) ;; declared in term.el
(defvar term-width) ;; declared in term.el
(defvar term-height) ;; declared in term.el

(defvar turtles--server nil)
(defvar turtles--conn nil)
(defvar turtles--file-name (or (when load-file-name
                                 (expand-file-name load-file-name default-directory))
                               (buffer-file-name)))
(defconst turtles-buffer-name " *turtles-term*")

(defconst turtles-basic-colors
  ["#ff0000" "#00ff00" "#0000ff" "#ffff00" "#00ffff" "#ff00ff"
   "#800000" "#008000" "#000080" "#808000" "#008080" "#800080"]
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

(defvar turtles--should-send-messages-up 0
  "When this is > 0, send messages to the server.")

(defvar turtles--sending-messages-up 0
  "Set to > 0 while processing code to send messages to the server.

This is used in `tultles--send-messages-up' to avoid entering
into a loop, sending messages while sending messages.")

(defun turtles-client-p ()
  (and turtles--conn (not turtles--server)))

(defun turtles-start ()
  (interactive)
  (unless (turtles-io-server-live-p turtles--server)
    (server-ensure-safe-dir server-socket-dir)
    (setq turtles--server
          (turtles-io-server
           (expand-file-name (format "turtles-%s" (emacs-pid))
                             server-socket-dir)
           `((grab . ,(turtles-io-method-handler (_ignored)
                        (with-current-buffer (get-buffer turtles-buffer-name)
                          ;; Wait until all output from the other
                          ;; Emacs instance have been processed, as
                          ;; it's likely in the middle of a redisplay.
                          (while (accept-process-output
                                  (get-buffer-process (current-buffer)) 0.05))

                          (buffer-substring term-home-marker (point-max)))))
             (message . ,(lambda (_conn _id _method msg)
                           (message msg)))))))

  (unless (and (turtles-io-conn-live-p turtles--conn)
               (term-check-proc (get-buffer-create turtles-buffer-name)))
    (mapc (lambda (c) (turtles-io-call-method-async c 'exit nil nil))
          (turtles-io-server-connections turtles--server))
    (setq turtles--conn nil)
    (setf (turtles-io-server-on-new-connection turtles--server)
          (lambda (conn)
            (setf turtles--conn conn)
            (setf (turtles-io-server-on-new-connection turtles--server) nil)))
    (unwind-protect
        (with-current-buffer (get-buffer-create turtles-buffer-name)
          (term-mode)
          (setq-local term-width 80)
          (setq-local term-height 20)
          (let ((cmdline `(,(expand-file-name invocation-name invocation-directory)
                           "-nw" "-Q")))
            (setq cmdline (append cmdline (turtles--dirs-from-load-path)))
            (setq cmdline (append cmdline `("-l" ,turtles--file-name)))
            (when (>= emacs-major-version 29)
              ;; COLORTERM=truecolor tells Emacs to use 24bit terminal
              ;; colors even though the termcap entry for eterm-color
              ;; only defines 256. That works, because term.el in
              ;; Emacs 29.1 and later support 24 bit colors.
              (setq cmdline `("env" "COLORTERM=truecolor" . ,cmdline)))
            (term-exec (current-buffer) "*turtles*" (car cmdline) nil (cdr cmdline)))
          (term-char-mode)
          (set-process-query-on-exit-flag (get-buffer-process (current-buffer)) nil)

          (term-send-raw-string
           (format "\033xturtles--launch\n%s\n"
                   (turtles-io-server-socket turtles--server)))
          (turtles-io-wait-for 5 "Turtles Emacs failed to connect"
                               (lambda () turtles--conn)))
      (setf (turtles-io-server-on-new-connection turtles--server) nil))))

(defun turtles-stop ()
  (interactive)
  (when (turtles-io-server-live-p turtles--server)
    (mapc (lambda (c) (turtles-io-notify c 'exit))
          (turtles-io-server-connections turtles--server))
    (delete-process (turtles-io-server-proc turtles--server)))
  (setq turtles--server nil)
  (setq turtles--conn nil))

(defun turtles-fail-unless-live ()
  (unless (turtles-io-conn-live-p turtles--conn)
    (error "No Turtles! Call turtles-start")))

(defun turtles--dirs-from-load-path ()
  (let ((args nil))
    (dolist (path load-path)
      (push "-L" args)
      (push path args))
    (nreverse args)))

(defun turtles-display-buffer-full-frame (buf)
  "Display BUF in the frame root window.

This is similar to Emacs 29's `display-buffer-full-frame', but
rougher and available in Emacs 26."
  (set-window-buffer (frame-root-window) buf))

(defmacro turtles--with-incremented-var (var &rest body)
  "Increment VAR while BODY is running.

This is used instead of a let to account for the possibility of
more than one instance of BODY running at the same time, with
special cases like reading from the minibuffer."
  (declare (indent 1))
  `(progn
     (cl-incf ,var)
     (unwind-protect
         (progn ,@body)
       (cl-decf ,var))))

(defun turtles--launch (socket)
  (interactive "F")
  (turtles-display-buffer-full-frame (messages-buffer))
  (setq load-prefer-newer t)
  (advice-add 'message :after #'turtles--send-message-up)
  (setq turtles--conn
        (turtles-io-connect
         socket
         `((eval . ,(turtles-io-method-handler (expr)
                      (turtles--with-incremented-var turtles--should-send-messages-up
                        (eval expr))))
           (exit . ,(lambda (_conn _id _method _params)
                      (kill-emacs nil)))))))

(defun turtles--send-message-up (msg &rest args)
  "Send a message to the server."
  (when (and turtles--conn
             (> turtles--should-send-messages-up 0)
             (not (> turtles--sending-messages-up 0)))
    (turtles--with-incremented-var turtles--sending-messages-up
      (turtles-io-notify turtles--conn 'message
                         (concat (format "[PID %s] " (emacs-pid))
                                 (apply #'format msg args))))))

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
  (turtles-fail-unless-live)
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
            (let ((grab (turtles-io-call-method  turtles--conn 'grab)))
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

(defun turtles-grab-buffer-into (buf output-buf &optional grab-faces)
  "Display BUF in the grabbed frame and grab it into OUTPUT-BUF.

When this function returns, OUTPUT-BUF contains the textual
representation of BUF as displayed in the root window of the
grabbed frame.

This function uses `turtles-grab-window-into' after setting up
the buffer. See the documentation of that function for details on
the buffer content and the effect of GRAB-FACES."
  (turtles-grab-window-into (turtles-setup-buffer buf) output-buf grab-faces))

(defun turtles-new-client-frame ()
  "Ask the client instance to create a new frame.

This opens a new frame on the Emacs instance run by turtles on a
window system, which is convenient for debugging.

The frame that is created is on the same display as the current
frame, which only makes sense for graphical displays."
  (interactive)
  (turtles-fail-unless-live)
  (let ((params (frame-parameters)))
    (unless (alist-get 'window-system params)
      (error "No window system"))
    (message "New client frame: %s"
             (turtles-io-call-method
              turtles--conn 'eval
              `(progn
                 (prin1-to-string
                  (make-frame
                   '((window-system . ,(alist-get 'window-system params))
                     (display . ,(alist-get 'display params))))))))))

(defun turtles-grab-window-into (win output-buf &optional grab-faces)
  "Grab WIN into output-buf.

WIN must be a window on the turtles frame.

When this function returns, OUTPUT-BUF contains the textual
representation of the content of that window. The point, mark and
region are also set to corresponding positions in OUTPUT-BUF, if
possible.

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
    (turtles--clip-in-frame-grab win)

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
  (unless turtles-source-window
    (error "Current buffer does not contain a window grab"))

  (cond
   ((null pos-in-source-buf) nil)
   ((and range (<= pos-in-source-buf
                   (window-start turtles-source-window)))
    (point-min))
   ((and range (>= pos-in-source-buf
                   (window-end turtles-source-window)))
    (point-max))
   (t (pcase-let ((`(,x . ,y) (window-absolute-pixel-position
                               pos-in-source-buf turtles-source-window)))
        (when (and x y)
          (save-excursion
            (goto-char (point-min))
            (forward-line y)
            (move-to-column x)
            (point)))))))

(defun turtles--clip-in-frame-grab (win)
  "Clip the frame grab in the current buffer to the body of WIN."
  (save-excursion
    (pcase-let ((`(,left ,top ,right ,bottom) (window-body-edges win)))
      (goto-char (point-min))
      (while (progn
               (move-to-column right)
               (delete-region (point) (pos-eol))
               (= (forward-line 1) 0)))

      (when (> left 0)
        (goto-char (point-min))
        (while (progn
                 (move-to-column left)
                 (when (and noninteractive
                            (not (char-before ?|)))
                   (error
                    (concat "Capturing a window to the right of another "
                            "doesn't work because of rendering errors in "
                            "batch mode. Either always split horizontally "
                            "or run tests in non-batch mode.")))
                 (delete-region (pos-bol) (point))
                 (= (forward-line 1) 0))))

      (goto-char (point-min))
      (forward-line bottom)
      (delete-region (point) (point-max))

      (when (> top 0)
        (goto-char (point-min))
        (forward-line top)
        (delete-region (point-min) (point))))))

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

(defun turtles--set-window-size (width height)
  "Set the process terminal size to WIDTH x HEIGHT."
  (with-current-buffer (get-buffer turtles-buffer-name)
    (set-process-window-size
     (get-buffer-process (current-buffer)) height width)
    (term-reset-size height width)))

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

(provide 'turtles)

;;; turtles.el ends here
