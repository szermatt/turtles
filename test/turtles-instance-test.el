;;; turtles-instance-test.el --- Test turtles-instance.el -*- lexical-binding: t -*-

;; Copyright (C) 2024 Stephane Zermatten

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

(require 'compat)
(require 'ert)
(require 'ert-x)
(require 'turtles-instance)

(turtles-definstance turtles-test-restart ()
  "A one-off test instance to test restart.")

(turtles-definstance turtles-test-larger-frame (:width 132 :height 43)
  "A test instance with a larger frame.")

(ert-deftest turtles-instance-test-restart ()
  (turtles-start-server)
  (should turtles--server)
  (should (turtles-io-server-live-p turtles--server))

  (let ((inst (turtles-get-instance 'turtles-test-restart))
        buf proc)
    (should inst)
    (turtles-stop-instance inst)
    (turtles-start-instance inst)
    (should (turtles-instance-live-p inst))

    (setq buf (turtles-instance-term-buf inst))
    (should (buffer-live-p buf))
    (should (process-live-p (get-buffer-process buf)))

    (setq proc (turtles-io-conn-proc (turtles-instance-conn inst)))
    (should (process-live-p proc))

    (should (equal "ok" (turtles-io-call-method
                         (turtles-instance-conn inst) 'eval "ok")))


    (turtles-stop-instance inst)

    (should-not (turtles-instance-live-p inst))
    (should-not (buffer-live-p buf))
    (should-not (process-live-p proc))))

(ert-deftest turtles-instance-test-message ()
  (let ((inst (turtles-get-instance 'default)))
    (should inst)
    (turtles-start-instance inst)

    (let ((inhibit-message t))
      (ert-with-message-capture messages
        (turtles-io-call-method
         (turtles-instance-conn inst)
         'eval
         '(message "hello from turtles-test-message"))
        (let ((message "[default] hello from turtles-test-message"))
          (unless (member message (string-split messages "\n" 'omit-nulls))
            (error "message not found in %s" messages)))))))

(ert-deftest turtles-instance-test-last-message ()
  (let ((inst (turtles-get-instance 'default)))
    (should inst)
    (turtles-start-instance inst)

    (let ((inhibit-message t))
      (turtles-io-call-method
       (turtles-instance-conn inst)
       'eval
       '(message "a message from turtles")))

    (let ((messages (turtles-io-call-method
                     (turtles-instance-conn inst) 'last-messages 5)))
      (unless (member "a message from turtles" (split-string messages "\n"))
        (error "message not found in %s" messages)))))

(ert-deftest turtles-instance-test-default-size ()
  (let ((inst (turtles-get-instance 'default)))
    (should inst)
    (turtles-start-instance inst)
    (with-current-buffer (turtles-instance-term-buf inst)
      (should (equal 80 term-width))
      (should (equal 20 term-height)))))

(ert-deftest turtles-instance-test-larger-frame-size ()
  (let ((inst (turtles-get-instance 'turtles-test-larger-frame)))
    (should inst)
    (turtles-start-instance inst)
    (with-current-buffer (turtles-instance-term-buf inst)
      (should (equal 132 term-width))
      (should (equal 43 term-height)))))


(require 'turtles-instance)
