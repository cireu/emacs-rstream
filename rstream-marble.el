;;; -*- lexical-binding: t; -*-

(require 'svg)
(require 'rstream-core)
(require 'rstream-util)

(defclass rstream-marble-diagram-producer ()
  ((tick-length :initarg :tick-length)
   (env :initarg :env :initform nil)
   (error-value :initarg :error-value :initform nil)
   (diagram-string :initarg :diagram-string)
   (timer :initform nil)
   (index :initform 0)))

(cl-defmethod rstream-producer-start ((obj rstream-marble-diagram-producer)
                                      listener)
  (with-slots (tick-length timer) obj
    (setf (oref obj index) 0)
    (setf timer (run-at-time nil (rstream--ms-to-sec tick-length)
                             #'rstream-marble--schedule obj listener))))

(cl-defmethod rstream-producer-stop ((obj rstream-marble-diagram-producer))
  (cancel-timer (oref obj timer)))

(defun rstream-marble--schedule (prod listener)
  (with-slots (diagram-string index error-value env) prod
    (let ((char (aref diagram-string index)))
      (pcase char
        (?- nil)
        (?| (rstream-on-complete listener))
        (?# (rstream-on-error listener error-value))
        (c
         (let* ((s (char-to-string c))
                (val (pcase (assq (intern s) env)
                       (`(,_ . ,val) val)
                       (`nil s))))
           (rstream-on-value listener val)
           (cl-incf index)))))
    (if (= index (1- (length diagram-string)))
        (rstream-on-complete listener)
      (cl-incf index))))

(cl-defun rstream-from-marble-diagram (diagram-string &key
                                                        (tick-length 1)
                                                        env
                                                        error-value)
  (rstream-broadcaster
   :producer (rstream-marble-diagram-producer
              :diagram-string diagram-string
              :tick-length tick-length
              :env env
              :error-value error-value)))




(provide 'rstream-marble)
;;; rstream-marble.el ends here
