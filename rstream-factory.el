;;; -*- lexical-binding: t; -*-

(require 'seq)

(require 'rstream-util)
(require 'rstream-core)

(defun rstream-create (start stop)
  "Create a stream with given function START and STOP.

START should accept one param as listener, and produce value to feed
listener.

STOP should accept no param and it is used to stop the proudcer."
  (let ((prod (rstream-functional-producer :start start :stop stop)))
    (rstream-broadcaster :producer prod)))

(defun rstream-from-seq (seq)
  "Create a synchronous stream from SEQ."
  (rstream-create (lambda (listener)
                    (seq-doseq (v seq)
                      (rstream-on-value listener v))
                    (rstream-on-complete listener))
                  ;; No teardown code for synchronous streams because they will
                  ;; emit all values directly after they were subscribed.
                  #'ignore))

(defun rstream-of (&rest elems)
  "Create a synchronous stream of ELEMS.

Values in ELEMS will be emitted sequentially."
  (rstream-from-seq elems))

(defun rstream-never ()
  "Create a stream never emits anything."
  (rstream-create #'ignore #'ignore))

(defun rstream-periodic (period)
  (rstream-broadcaster :producer (rstream-periodic-producer :period period)))

(defclass rstream-periodic-producer ()
  ((period :initarg :period) (counter) (timer)))

(cl-defmethod rstream-producer-start ((obj rstream-periodic-producer) listener)
  (with-slots (timer counter period) obj
    (setf counter 0)
    (let ((sec (rstream--ms-to-sec period)))
      (setf timer (run-with-timer sec sec
                                  (lambda ()
                                    (rstream-on-value listener counter)
                                    (cl-incf counter)))))))

(cl-defmethod rstream-producer-stop ((obj rstream-periodic-producer))
  (with-slots (timer) obj
    (cancel-timer timer)))

(provide 'rstream-factory)
;;; rstream-factory.el ends here
