;;; -*- lexical-binding: t; -*-

(require 'eieio)

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

(cl-defgeneric rstream-on-error (listener error)
  "Handle arrived ERROR for LISTENER.")

(cl-defgeneric rstream-on-complete (listener)
  "Handle a graceful complete for LISTENER.")

;; Observable API

(cl-defgeneric rstream-register-listener (observable listener))

(cl-defgeneric rstream-delete-listener (observable listener))

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

(cl-defmethod rstream-on-error ((obj rstream-functional-listener) error)
  (funcall (oref obj on-error) error))

(cl-defmethod rstream-on-complete ((obj rstream-functional-listener))
  (funcall (oref obj on-complete)))


;;; Core

(defclass rstream-broadcaster ()
  ((status
    :initform 'pending
    :reader rstream-broadcaster-status
    :writer rstream-broadcaster-advance-status
    :documentation "\
Represent the active status of producer, should be one of following symbol.

- pending :: The producer is idled and there's no listeners.
- running :: The producer is forwarding value to listeners.
- closing :: The stop task of producer was put into async queue.
- done :: The producer has sent all values to listeners.
- error ::  The producer occured an error during the process of production.")
   (producer
    :initarg :producer)
   (listeners
    :initform nil)
   (stop-task-runner
    :initform nil
    :documentation ""))
  :documentation "\
A Broadcaster adapts a Producer and makes it \"observable\" from different
Listener. You can subscribe a Broadcaster with callback and it will run your
callback when Producer produce a new value.

A Broadcaster is lazy and ref-counted, it won't start the Producer unless first
subscription happened, and it will automatically stop the Producer when last
subscription gone.")

(cl-defmethod rstream-register-listener ((obj rstream-broadcaster) listener)
  (with-slots (listeners producer stop-task-runner) obj
    (let ((status (rstream-broadcaster-status obj)))
      (when (not (memq status '(done error)))
        (setf listeners (nconc listeners (list listener)))
        (when (eq status 'pending)
          (rstream-producer-start producer obj))
        (when (eq status 'closing)
          (cancel-timer stop-task-runner)
          (setf stop-task-runner nil))
        (rstream-broadcaster-advance-status obj 'running)))))

(cl-defmethod rstream-delete-listener ((obj rstream-broadcaster) listener)
  (with-slots (listeners producer stop-task-runner) obj
    (let* ((status (rstream-broadcaster-status obj))
           (should-reset-p
             (and (eq status 'running)
                  (null (setf listeners (delq listener listeners))))))
      (when should-reset-p
        (rstream-broadcaster-advance-status obj 'closing)
        (setf stop-task-runner
              (rstream--run-asap #'rstream-broadcaster--teardown
                                 obj 'pending))))))

(cl-defmethod rstream-on-value ((obj rstream-broadcaster) value)
  (dolist (lis (oref obj listeners))
    (rstream-on-value lis value)))

(cl-defmethod rstream-on-error ((obj rstream-broadcaster) error)
  (with-slots (listeners) obj
    (let ((listeners-backup listeners))
      (rstream-broadcaster--teardown obj 'error)
      (if (null listeners-backup)
          (signal (car error) (cdr error))
        (dolist (lis listeners-backup)
          (rstream-on-error lis error))))))

(cl-defmethod rstream-on-complete ((obj rstream-broadcaster))
  (with-slots (listeners) obj
    (let ((listeners-backup listeners))
      (rstream-broadcaster--teardown obj 'done)
      (dolist (lis listeners-backup)
        (rstream-on-complete lis)))))

(defun rstream-broadcaster--teardown (broadcaster status)
  "Stop producer and clean all listeners of BROADCASTER, advance to STATUS."
  (with-slots (producer listeners) broadcaster
    (rstream-producer-stop producer)
    (setf listeners nil)
    (rstream-broadcaster-advance-status broadcaster status)))

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

;;; Debug use

(defalias 'rstream-force-send-value #'rstream-on-value
  "Force send VALUE to STREAM.

Use this only when you know what you are doing.
\n(fn STREAM VALUE)")

(defalias 'rstream-force-send-error #'rstream-on-error
  "Force send ERROR to STREAM.

Use this only when you know what you are doing.
\n(fn STREAM ERROR)")

(defalias 'rstream-force-send-complete #'rstream-on-complete
  "Force send a complete signal to STREAM.

Use this only when you know what you are doing.
\n(fn STREAM ERROR)")

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
  (rstream-on-value (rstream--forwarder-output obj) value))

(cl-defmethod rstream-on-error ((obj rstream--forwarder) error)
  (rstream-on-error (rstream--forwarder-output obj) error))

(cl-defmethod rstream-on-complete ((obj rstream--forwarder))
  (rstream-on-complete (rstream--forwarder-output obj)))

(provide 'rstream-core)
;;; rstream-core.el ends here
