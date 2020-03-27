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
(require 'eieio)
(require 'eieio-base)

(defsubst rstream--run-asap (func &rest args)
  "Run FUNC with ARGS asynchronously, as soon as possible."
  (apply #'run-at-time nil nil func args))

;;; Interfaces

;; Producer API

(cl-defgeneric rstream-producer-start (producer listener)
  "Start PRODUCER sending values to LISTENER")

(cl-defgeneric rstream-producer-stop (producer)
  "Stop a running PRODUCER.")

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

(defclass rstream-functional-producer ()
  ((start :initarg :start)
   (stop :initarg :stop)))

(cl-defmethod rstream-producer-start ((obj rstream-functional-producer)
                                      listener)
  (funcall (oref obj start) listener))

(cl-defmethod rstream-producer-stop ((obj rstream-functional-producer))
  (funcall (oref obj stop)))

(defclass rstream-functional-listener ()
  ((on-value :initarg :on-value)
   (on-error :initarg :on-error)
   (on-complete :initarg :on-complete)))

(cl-defmethod rstream-on-value ((obj rstream-functional-listener) value)
  (funcall (oref obj on-value) value))

(cl-defmethod rstream-on-error ((obj rstream-functional-listener) &rest error)
  (apply (oref obj on-error) error))

(cl-defmethod rstream-on-complete ((obj rstream-functional-listener))
  (funcall (oref obj on-complete)))

;;; Core

(defclass rstream-broadcaster-state--pending (eieio-singleton) ())

(defclass rstream-broadcaster-state--running ()
  ((listeners :initarg :listeners)))

(defclass rstream-broadcaster-state--complete (eieio-singleton) ())

(defclass rstream-broadcaster-state--error ()
  ((error-type :initarg :error-type)
   (error-data :initarg :error-data)))

(defclass rstream-broadcaster-state--closing ()
  ((close-task :initarg :close-task)))

(defclass rstream-broadcaster ()
  ((state
    :initform (rstream-broadcaster-state--pending)
    :documentation "\
This slot can be one of following type.

- `rstream-broadcaster-state--pending' ::
  Broadcaster is idle for any action.

- `rstream-broadcaster-state--running' ::
  Several listeners are listening to the broadcaster and receiving value
  from producer.

- `rstream-broadcaster-state--closing' ::
  Broadcaster is running a async close task, task can be canceled if new
  listener come in.

- `rstream-broadcaster-state--complete' ::
  The producer was completed and cannot advance to any other state or accept
  new listeners.

- `rstream-broadcaster-state--error' ::
  The producer was exited shamefully and cannot advance to any other state
  or accept new listeners.")
   (producer
    :initarg :producer))
  :documentation "\
A Broadcaster adapts a Producer and makes it \"observable\" from different
Listener. You can subscribe a Broadcaster with callback and it will run your
callback when Producer produce a new value.

A Broadcaster is lazy and ref-counted, it won't start the Producer unless first
subscription happened, and it will automatically stop the Producer when last
subscription gone.")

(cl-defmethod rstream-register-listener ((obj rstream-broadcaster) listener)
  (let ((state (oref obj state))
        (prod (oref obj producer))
        (lis-list (list listener)))
    (cl-typecase state
      (rstream-broadcaster-state--running
       (oset obj state (rstream-broadcaster-state--running
                        :listeners (append (oref state listeners) lis-list))))
      (rstream-broadcaster-state--pending
       (oset obj state (rstream-broadcaster-state--running
                        :listeners lis-list))
       (rstream-producer-start prod obj))
      (rstream-broadcaster-state--closing
       (cancel-timer (oref state close-task))
       (oset obj state (rstream-broadcaster-state--running
                        :listeners lis-list)))
      (otherwise
       (error "Broadcaster was terminated: %S" obj)))))

(cl-defmethod rstream-delete-listener ((obj rstream-broadcaster) listener)
  (let ((state (oref obj state)))
    (cl-typecase state
      (rstream-broadcaster-state--running
       (let* ((rest (remq listener (oref state listeners)))
              (close-task (lambda ()
                            (oset obj state
                                  (rstream-broadcaster-state--pending))))
              (new-state (if rest
                             (rstream-broadcaster-state--running
                              :listeners rest)
                           (rstream-broadcaster-state--closing
                            :close-task (rstream--run-asap close-task)))))
         (oset obj state new-state)))
      (otherwise
       (error "Not in running state: %S" obj)))))

(cl-defmethod rstream-on-value ((obj rstream-broadcaster) value)
  (let ((state (oref obj state)))
    (cl-check-type state rstream-broadcaster-state--running)
    (dolist (lis (oref state listeners))
      (rstream-send-value lis value))))

(cl-defmethod rstream-on-error ((obj rstream-broadcaster)
                                error-type error-data)
  (let ((state (oref obj state)))
    (cl-check-type state rstream-broadcaster-state--running)
    (let ((listeners-backup (oref state listeners)))
      (oset obj state (rstream-broadcaster-state--error
                       :error-type error-type :error-data error-data))
      (if (null listeners-backup)
          (signal error-type error-data)
        (dolist (lis listeners-backup)
          (rstream-send-error lis error-type error-data))))))

(cl-defmethod rstream-on-complete ((obj rstream-broadcaster))
  (let ((state (oref obj state)))
    (cl-check-type state rstream-broadcaster-state--running)
    (let ((listeners-backup (oref state listeners)))
      (oset obj state (rstream-broadcaster-state--complete))
      (dolist (lis listeners-backup)
        (rstream-send-complete lis)))))

(defclass rstream-subscription ()
  ((listener :initarg :listener)
   (broadcaster :initarg :broadcaster)))

(defun rstream-subscribe (broadcaster on-value on-error on-complete)
  "Subscribe a broadcaster.

Each value arrived in BROADCASTER will call ON-VALUE with that value.

When an error occurred in BROADCASTER, ON-ERROR will be triggered
with that error.

When BROADCASTER is completed, ON-COMPLETED will be triggered.

If BROADCASTER is stopped, this function will start the BROADCASTER to
produce value."
  (let ((listener (rstream-functional-listener :on-value on-value
                                               :on-error on-error
                                               :on-complete on-complete)))
    (rstream-register-listener broadcaster listener)
    (rstream-subscription :listener listener :broadcaster broadcaster)))

(defun rstream-unsubscribe (subscription)
  "Unsubscribe a SUBSCRIPTION.

If SUBSCRIPTION is the last subscription of target stream, stream will
stopped."
  (rstream-delete-listener (oref subscription broadcaster)
                           (oref subscription listener)))

;;; Internal

(defclass rstream--forwarder ()
  ((output
    :initarg :output
    :accessor rstream--forwarder-output))
  :abstract t
  :documentation "\
A listener which forwards all received message to its output.

This provides a blanket implementation for operator/aggregator like class,
for internal usage only.")

(cl-defmethod rstream-on-value ((obj rstream--forwarder) value)
  (rstream-send-value (rstream--forwarder-output obj) value))

(cl-defmethod rstream-on-error ((obj rstream--forwarder) &rest error)
  (apply #'rstream-send-error (rstream--forwarder-output obj) error))

(cl-defmethod rstream-on-complete ((obj rstream--forwarder))
  (rstream-send-complete (rstream--forwarder-output obj)))

(provide 'rstream-core)

;; Local Variables:
;; coding: utf-8
;; End:

;;; rstream-core.el ends here
