;;; termgrab.el --- Screen-grabbing test utility -*- lexical-binding: t -*-

;; Copyright (C) 2024 Stephane Zermatten

;; Author: Stephane Zermatten <szermatt@gmx.net>
;; Maintainer: Stephane Zermatten <szermatt@gmail.com>
;; Version: 0.1snapshot
;; Package-Requires: ((emacs "29.1"))
;; Keywords: testing, unix
;; URL: http://github.com/szermatt/termgrab

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
;; This package contains utilities for testing the appearance of a
;; buffer or window in the terminal.
;;
(require 'server)
(require 'ansi-color)

(defcustom termgrab-tmux-exe "tmux"
  "Path to the tmux executable."
  :type 'string
  :group 'termgrab)

(defcustom termgrab-emacsclient-exe "emacsclient"
  "Path to the emacsclient executable tmux should run."
  :type 'string
  :group 'termgrab)

(defvar termgrab-server-proc nil)
(defvar termgrab-frame nil)
(defvar termgrab--socket nil)
(defvar termgrab--server-name nil)

(defun termgrab-live-p (&optional proc)
  (let ((proc (or proc termgrab-server-proc)))
    (and proc (process-live-p proc))))

(defun termgrab-require-server (&optional proc)
  (let ((proc (or proc termgrab-server-proc)))
    (unless (termgrab-live-p proc)
      (error "Missing termgrab tmux process proc:%s" (when proc (process-status proc))))))

(defun termgrab--tmux-cmd ()
  (list termgrab-tmux-exe "-S" termgrab--socket "-f" "/dev/null"))

(defun termgrab-start-server ()
  (unless (termgrab-live-p)
    (let ((server-use-tcp nil)
          (server-name (format "termgrab-%s" (emacs-pid)))
          proc new-frame new-frame-func)
      
      (setq termgrab--server-name server-name)
      (unless (server-running-p)
        (server-start nil 'inhibit-prompt))

      ;; Keep the tmux socket into the same directory as the server
      ;; socket, so they have the same access limits.
      (server-ensure-safe-dir server-socket-dir)
      (setq termgrab--socket (expand-file-name (concat "tmux-" server-name) server-socket-dir))
      (when (file-exists-p termgrab--socket)
        (delete-file termgrab--socket))
      
      (add-hook 'kill-emacs-hook #'termgrab-stop-server)
      (unwind-protect
          (progn
            (setq proc (make-process :name "*termgrab-server*"
                                     :buffer " *termgrab-server-output*"
                                     :connection-type 'pty
                                     :command (append (termgrab--tmux-cmd) '("-D"))))
            (set-process-query-on-exit-flag proc nil)
            (termgrab--wait-for 5 "server failed to start"
             (lambda () (file-exists-p termgrab--socket)))
            (setq new-frame-func (lambda () (setq new-frame (selected-frame))))
            (add-hook 'server-after-make-frame-hook new-frame-func)
            (unwind-protect
                (progn
                  (termgrab--tmux
                   proc
                   nil 
                   "new-session" "-d" "-s" "grab"
                   termgrab-emacsclient-exe
                   (concat "-socket-name=" (shell-quote-argument
                                            (expand-file-name server-name
                                                              server-socket-dir))) "-nw" "-c")
                  (termgrab--wait-for 5 "emacsclient failed to connect" (lambda () new-frame)))
              (remove-hook 'server-after-make-frame-hook new-frame-func))
            (setq termgrab-server-proc proc)
            (setq termgrab-frame new-frame)
            
            ;; Success. Don't kill process in the unwind section
            (setq proc nil))
        (when (and proc (termgrab-live-p proc))
          (kill-process proc))))))

(defun termgrab-stop-server ()
  (when termgrab--server-name
    (let ((server-use-tcp nil))
      ;; Unintuitively, this stops the server. server-force-delete
      ;; sounds more appropriate, but sometimes prompts.
      (server-start 'leave-dead 'inhibit-prompt)))
  (setq termgrab--server-name nil)
  
  (when termgrab-server-proc
    (when (process-live-p termgrab-server-proc)
      (kill-process termgrab-server-proc)))
  (setq termgrab-server-proc nil)
  (setq termgrab-frame nil)
  
  (when (and termgrab--socket (file-exists-p termgrab--socket))
    (delete-file termgrab--socket))
  (setq termgrab--socket nil))

(defun termgrab-grab-to-string ()
  (with-temp-buffer
    (termgrab-grab-into (current-buffer))
    (buffer-string)))

(defun termgrab-grab-into (buffer)
  (delete-region (point-min) (point-max))
  (termgrab--tmux termgrab-server-proc buffer
                  "capture-pane" "-t" "grab:0" "-e" "-b" "saved" ";"
                  "save-buffer" "-b" "saved" "-")
  (ansi-color-apply-on-region (point-min) (point-max)))

(defun termgrab--tmux (proc buffer &rest commands)
  (termgrab-require-server proc)
  (with-temp-buffer
    (let ((tmux-cmd (append (termgrab--tmux-cmd) '("-N" "--") commands))
          proc)
      (insert "cmd: ")
      (insert (mapconcat #'shell-quote-argument tmux-cmd " "))
      (insert "\n")
      (setq proc (make-process :name "*termgrab-client*"
                               :buffer (or buffer (current-buffer))
                               :stderr (current-buffer)
                               :sentinel #'ignore
                               :command tmux-cmd))
      (while (process-live-p proc)
        (accept-process-output))
      (when (not (zerop (process-exit-status proc)))
        (error "termgrab:tmux %s [%s] %s"
               (string-join commands " ")
               (process-exit-status proc)
               (buffer-substring-no-properties (point-min) (point-max)))))))
      

(defun termgrab--wait-for (timeout error-message predicate)
  (let ((start (current-time)))
    (while (and (< (time-to-seconds (time-subtract (current-time) start)) timeout)
                (not (funcall predicate)))
      (accept-process-output nil 0 500)))
  (unless (funcall predicate)
    (error (concat "termgrab:timeout: " error-message))))

(provide 'termgrab)

;;; termgrab.el ends here
