;;; rstream-core.el --- Core implementation -*- lexical-binding: t -*-

;; Copyright (C) 2020 Zhu Zihao

;; Author: Zhu Zihao <all_but_last@163.com>

;; This file is NOT part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(eval-when-compile (require 'cl-lib))

;;; Utils

(defsubst rstream--run-asap (func &rest args)
  "Run FUNC with ARGS asynchronously, as soon as possible."
  (apply #'run-at-time nil nil func args))

;;; Interfaces

;; Listener API

(cl-defgeneric rstream-on-value (listener value)
  "Handle arrived VALUE for LISTENER.")

(cl-defgeneric rstream-on-error (listener error-type error-data)
  "Handle arrived error in ERROR-TYPE with ERROR-DATA for LISTENER.")

(cl-defgeneric rstream-on-complete (listener)
  "Handle a graceful complete for LISTENER.")

;; They are different heads of the same hydra :).
(defalias 'rstream-send-value #'rstream-on-value
  "Send VALUE to STREAM.

\n(fn STREAM VALUE)")

(defalias 'rstream-send-error #'rstream-on-error
  "Send error in ERROR-TYPE with ERROR-DATA to STREAM.

\n(fn STREAM ERROR-TYPE ERROR-DATA)")

(defalias 'rstream-send-complete #'rstream-on-complete
  "Send a complete signal to STREAM.

\n(fn STREAM ERROR)")

;; Observable API

(cl-defgeneric rstream-register-listener (observable listener)
  "Attach LISTENER to OBSERVABLE.")

(cl-defgeneric rstream-delete-listener (observable listener)
  "Remove LISTENER from OBSERVABLE.")

;;; Core

(cl-defstruct (rstream-broadcaster-state--running
               (:copier nil))
  listeners revoke-token)

(cl-defstruct (rstream-broadcaster-state--closing
               (:copier nil))
  close-task revoke-token)

(cl-defstruct (rstream-broadcaster-state--error
               (:copier nil))
  error-type error-data)

(cl-defstruct (rstream-broadcaster
               (:constructor nil)
               (:constructor rstream-broadcaster--new (producer))
               (:copier nil))
  "A Broadcaster adapts a producer function and makes it
\"observable\" from different Listener. You can subscribe a
Broadcaster with callback and it will run your callback when
Producer produce a new value.

A Broadcaster is lazy and ref-counted, it won't start the
Producer unless first subscription happened, and it will
automatically stop the Producer when last subscription gone."
  (state 'pending
   :documentation "
Can be one of following type.

- Symbol `pending' ::
  Broadcaster is idle for any action.

- `rstream-broadcaster-state--running' ::
  Several listeners are listening to the broadcaster and receiving value
  from producer.

- `rstream-broadcaster-state--closing' ::
  Broadcaster is running a async close task, task can be canceled if new
  listener come in.

- Symbol `completed' ::
  The producer was completed and cannot advance to any other state or accept
  new listeners.

- `rstream-broadcaster-state--error' ::
  The producer was exited shamefully and cannot advance to any other state
  or accept new listeners.")
  producer)

(defalias 'rstream-broadcaster-new #'rstream-broadcaster--new
  "Create broadcaster with given PRODUCER.

PRODUCER is a function call with one argument, the broadcaster will be created.
You can use `rstream-send-value', `rstream-send-error', `rstream-send-complete'
to send different signal to the broadcaster.

PRODUCER may return a function call with zero argument to revoke the execution,
otherwise it should return nil.

\(fn PRODUCER)")

(defun rstream-broadcaster--teardown (obj new-state)
  (pcase-exhaustive (rstream-broadcaster-state obj)
    ((or (cl-struct rstream-broadcaster-state--running
                    revoke-token)
         (cl-struct rstream-broadcaster-state--closing
                    revoke-token))
     (when revoke-token (funcall revoke-token))))
  (setf (rstream-broadcaster-state obj) new-state))

 (cl-defmethod rstream-register-listener ((obj rstream-broadcaster) listener)
   (pcase-let* (((cl-struct rstream-broadcaster state producer) obj)
                (lis-list (list listener)))
     (pcase-exhaustive state
       ((cl-struct rstream-broadcaster-state--running
                   listeners revoke-token)
        (setf (rstream-broadcaster-state obj)
              (make-rstream-broadcaster-state--running
               :listeners (nconc listeners lis-list)
               :revoke-token revoke-token)))
       (`pending
        (let ((new-state (make-rstream-broadcaster-state--running
                          :listeners lis-list)))
          (setf (rstream-broadcaster-state obj) new-state)
          ;; NOTE: We must push the state to the broadcaster first, or any call
          ;; to `rstream-send-*' will complain about non-running state.
          (setf (rstream-broadcaster-state--running-revoke-token new-state)
                (funcall producer obj))))
       ((cl-struct rstream-broadcaster-state--closing
                   close-task revoke-token)
        (cancel-timer close-task)
        (setf (rstream-broadcaster-state obj)
              (make-rstream-broadcaster-state--running
               :listeners lis-list :revoke-token revoke-token))))))

(cl-defmethod rstream-delete-listener ((obj rstream-broadcaster) listener)
  (pcase-exhaustive (rstream-broadcaster-state obj)
    ((cl-struct rstream-broadcaster-state--running
                listeners revoke-token)
     (cl-assert (memq listener listeners))
     (let* ((rest (delq listener listeners))
            (new-state
              (if rest
                  (make-rstream-broadcaster-state--running
                   :listeners rest :revoke-token revoke-token)
                (make-rstream-broadcaster-state--closing
                 :close-task (rstream--run-asap
                              #'rstream-broadcaster--teardown obj 'pending)
                 :revoke-token revoke-token))))
       (setf (rstream-broadcaster-state obj)
             new-state)))))

(cl-defmethod rstream-on-value ((obj rstream-broadcaster) value)
  (let ((state (rstream-broadcaster-state obj)))
    (dolist (lis (rstream-broadcaster-state--running-listeners state))
      (rstream-send-value lis value))))

(cl-defmethod rstream-on-error ((obj rstream-broadcaster)
                                error-type error-data)
  (let* ((state (rstream-broadcaster-state obj))
         (listeners-backup (rstream-broadcaster-state--running-listeners
                            state)))
    (rstream-broadcaster--teardown
     obj (make-rstream-broadcaster-state--error
          :error-type error-type :error-data error-data))
    (if (null listeners-backup)
        (signal error-type error-data)
      (dolist (lis listeners-backup)
        (rstream-send-error lis error-type error-data)))))

(cl-defmethod rstream-on-complete ((obj rstream-broadcaster))
  (let* ((state (rstream-broadcaster-state obj))
         (listeners-backup (rstream-broadcaster-state--running-listeners
                            state)))
    (rstream-broadcaster--teardown obj 'completed)
    (dolist (lis listeners-backup)
      (rstream-send-complete lis))))

;;; Subscription

(defun rstream-subscribe-with (broadcaster listener)
  "Subscribe a BROADCASTER with given LISTENER."
  (rstream-register-listener broadcaster listener)
  (lambda () (rstream-delete-listener broadcaster listener)))

(defun rstream-unsubscribe (subscription)
  "Unsubscribe a SUBSCRIPTION.

If SUBSCRIPTION is the last subscription of target stream, stream will
stopped."
  (funcall subscription))

(cl-defstruct (rstream-functional-listener
               (:copier nil))
  on-value on-error on-complete)

(cl-defmethod rstream-on-value ((obj rstream-functional-listener) value)
  (funcall (rstream-functional-listener-on-value obj) value))

(cl-defmethod rstream-on-error ((obj rstream-functional-listener) &rest error)
  (apply (rstream-functional-listener-on-error obj) error))

(cl-defmethod rstream-on-complete ((obj rstream-functional-listener))
  (funcall (rstream-functional-listener-on-complete obj)))

(defun rstream-subscribe (broadcaster on-value on-error on-complete)
  "Subscribe a broadcaster.

Each value arrived in BROADCASTER will call ON-VALUE with that value.

When an error occurred in BROADCASTER, ON-ERROR will be triggered
with that error.

When BROADCASTER is completed, ON-COMPLETED will be triggered.

If BROADCASTER is stopped, this function will start the BROADCASTER to
produce value."
  (let ((listener (make-rstream-functional-listener :on-value on-value
                                                    :on-error on-error
                                                    :on-complete on-complete)))
    (rstream-subscribe-with broadcaster listener)))

;;; Footer
(provide 'rstream-core)

;; Local Variables:
;; coding: utf-8
;; End:

;;; rstream-core.el ends here
