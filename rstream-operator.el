;;; rstream-operator.el --- Stream Operators -*- lexical-binding: t -*-

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
(require 'seq)

(require 'rstream-core)
(require 'rstream-util)

(defclass rstream-operator (rstream--forwarder)
  ((input
    :initarg :input
    :accessor rstream-operator--input))
  :documentation "\
An Operator allow you make some transformation on data from Producer.

Notice that Operator is unicast, it's usual to wrap it with
`rstream-broadcaster' to make it more useful."
  :abstract t)

(cl-defmethod rstream-producer-start ((obj rstream-operator) listener)
  (rstream-register-listener (rstream-operator--input obj) obj)
  (setf (rstream--forwarder-output obj) listener))

(cl-defmethod rstream-producer-stop ((obj rstream-operator))
  (rstream-delete-listener (rstream-operator--input obj) obj)
  (setf (rstream--forwarder-output obj) nil))

(defsubst rstream-apply-operator (obj operator-class &rest args)
  (rstream-broadcaster
   :producer (apply #'make-instance operator-class :input obj args)))

;; Map

(defun rstream-map (stream func)
  ""
  (rstream-apply-operator stream 'rstream-map--result
                          :func func))

(defclass rstream-map--result (rstream-operator)
  ((func :initarg :func)))

(cl-defmethod rstream-on-value ((obj rstream-map--result) value)
  (with-slots (func) obj
    (let ((result (funcall func value)))
      (cl-call-next-method obj result))))

;; MapTo

(defun rstream-map-to (stream value)
  (rstream-map stream (lambda (_) value)))

;; Inspect

(defun rstream-inspect (stream func)
  (rstream-map stream (lambda (v) (funcall func v) v)))

;; Filter

(defun rstream-filter (stream func)
  (rstream-apply-operator stream 'rstream-filter--result
                          :func func))

(defclass rstream-filter--result (rstream-operator)
  ((func :initarg :func)))

(cl-defmethod rstream-on-value ((obj rstream-filter--result) value)
  (with-slots (func) obj
    (let ((result (funcall func value)))
      (when result
        (cl-call-next-method)))))

;; Remove

(defun rstream-remove (stream func)
  (rstream-filter stream (lambda (x) (not (funcall func x)))))

;; Scan

(defun rstream-scan-from (stream func initial)
  (rstream-apply-operator stream 'rstream-scan--result
                          :seed initial :func func))

(defun rstream-scan (stream func)
  (rstream-apply-operator stream 'rstream-scan--result
                          :func func))

(defclass rstream-scan--result (rstream-operator)
  ((seed :initarg :seed) (func :initarg :func) (acc)))

(cl-defmethod rstream-producer-start ((obj rstream-scan--result) _listener)
  (let ((val (if (slot-boundp obj 'seed)
                 (oref obj seed)
               (rstream-uninitialized))))
    (oset obj acc val))
  (cl-call-next-method))

(cl-defmethod rstream-on-value ((obj rstream-scan--result) value)
  (with-slots (acc func) obj
    (if (rstream-initialized-p acc)
        (setf acc (funcall func acc value))
      (setf acc value))
    (cl-call-next-method obj acc)))

;; Distinct

(cl-defun rstream-distinct (stream &optional (testfn #'equal))
  (rstream-apply-operator stream 'rstream-distinct--result
                          :comparator testfn))

(defclass rstream-distinct--result (rstream-operator)
  ((comparator :initarg :comparator) (cache)))

(cl-defmethod rstream-producer-start ((obj rstream-distinct--result) _listener)
  (let ((comp (oref obj comparator)))
    (oset obj cache (if (memq comp '(equal eq eql))
                        (make-hash-table :test comp)
                      nil)))
  (cl-call-next-method))

(cl-defmethod rstream-on-value ((obj rstream-distinct--result) value)
  (with-slots (cache comparator) obj
    (let ((use-ht (hash-table-p cache)))
      (cl-labels ((find (val)
                    (if use-ht
                        (gethash val cache)
                      (seq-contains-p cache val comparator)))
                  (remember (val)
                    (if use-ht
                        (puthash val t cache)
                      (push val cache))))
        (when (not (find value))
          (remember value)
          (cl-call-next-method))))))

;; IgnoreUnchange

(cl-defun rstream-ignore-unchange (stream &optional (testfn #'equal))
  (rstream-apply-operator stream 'rstream-ignore-unchange--result
                          :comparator testfn))

(defclass rstream-ignore-unchange--result (rstream-operator)
  ((comparator :initarg :comparator)
   (cache)))

(cl-defmethod rstream-producer-start ((obj rstream-ignore-unchange--result)
                                      _listener)
  (slot-makeunbound obj 'cache)
  (cl-call-next-method))

(cl-defmethod rstream-on-value ((obj rstream-ignore-unchange--result) value)
  (with-slots (cache comparator) obj
    (if (rstream-initialized-p cache)
        (when (not (funcall comparator cache value))
          (oset obj cache value)
          (cl-call-next-method))
      (oset obj cache value)
      (cl-call-next-method))))

;; Take

(defun rstream-take (stream count)
  (rstream-broadcaster
   :producer (rstream-take--result :input stream
                                   :count count)))

(defclass rstream-take--result (rstream-operator)
  ((count :initarg :count)
   (counter)))

(cl-defmethod rstream-producer-start ((obj rstream-take--result) _listener)
  (oset obj counter 0)
  (cl-call-next-method))

(cl-defmethod rstream-on-value ((obj rstream-take--result) _value)
  (cl-call-next-method)
  (with-slots (count counter) obj
    (cl-incf counter)
    (when (= counter count)
      (rstream-send-complete obj))))

;; Drop

(defun rstream-drop (stream count)
  (rstream-broadcaster
   :producer (rstream-drop--result :input stream :count count)))

(defclass rstream-drop--result (rstream-operator)
  ((count :initarg :count) (counter)))

(cl-defmethod rstream-producer-start ((obj rstream-drop--result) _listener)
  (oset obj counter 0)
  (cl-call-next-method))

(cl-defmethod rstream-on-value ((obj rstream-drop--result) _value)
  (with-slots (count counter) obj
    (if (= counter (1+ count))
        (cl-call-next-method)
      (cl-incf counter))))

;; Switch

(defun rstream-switch (stream)
  (rstream-broadcaster
   :producer (rstream-switch--result :input stream)))

(defclass rstream-switch--result (rstream-operator)
  ((current-sub) (complete-p)))

(cl-defmethod rstream-producer-start ((obj rstream-switch--result) _listener)
  (oset obj current-sub nil)
  (oset obj complete-p nil)
  (cl-call-next-method))

(cl-defmethod rstream-on-value ((obj rstream-switch--result) value)
  (with-slots (complete-p current-sub) obj
    (when current-sub (rstream-unsubscribe current-sub))
    (let ((sub (rstream-subscribe value
                                  #'cl-call-next-method
                                  (lambda (err-type err-data)
                                    (rstream-send-error obj err-type err-data))
                                  (lambda ()
                                    (setf current-sub nil)
                                    (when complete-p
                                      (rstream-send-complete obj))))))
      (setf current-sub sub))))

(cl-defmethod rstream-on-complete ((obj rstream-switch--result))
  (with-slots (current-sub complete-p) obj
    (if current-sub
        (setf complete-p t)
      (cl-call-next-method))))

;; Debounce

(defun rstream-debounce (stream delay)
  (rstream-apply-operator stream 'rstream-debounce--result
                           :delay delay))

(defclass rstream-debounce--result (rstream-operator)
  ((delay :initarg :delay) (timer :initform nil) (latest-value)))

(cl-defmethod rstream-producer-start ((obj rstream-debounce--result) _lis)
  (oset obj latest-value (rstream-uninitialized))
  (cl-call-next-method))

(cl-defmethod rstream-on-value ((obj rstream-debounce--result) value)
  (with-slots (timer delay latest-value) obj
    (setf latest-value value)
    (when timer (cancel-timer timer))
    (setf timer (run-at-time (rstream--ms-to-sec delay) nil
                             (lambda ()
                               (cl-call-next-method obj latest-value))))))

(cl-defmethod rstream-on-error ((obj rstream-debounce--result) &rest _error)
  (let ((timer (oref obj timer)))
    (when timer (cancel-timer timer)))
  (cl-call-next-method))

(cl-defmethod rstream-on-complete ((obj rstream-debounce--result))
  (with-slots (timer latest-value) obj
    (when timer (cancel-timer timer))
    (when (rstream-initialized-p latest-value)
      (rstream-send-value obj latest-value)))
  (cl-call-next-method))

;; Throttle

(defun rstream-throttle (stream thresold)
  (rstream-apply-operator stream 'rstream-throttle--result
                          :thresold thresold))

(defclass rstream-throttle--result (rstream-operator)
  ((thresold :initarg :thresold) (timer)))

(cl-defmethod rstream-producer-start ((obj rstream-throttle--result) _)
  (oset obj timer nil)
  (cl-call-next-method))

(cl-defmethod rstream-on-value ((obj rstream-throttle--result) _value)
  (with-slots (timer thresold latest-value) obj
    (when (null timer)
      (setf timer (run-at-time (rstream--ms-to-sec thresold) nil
                               (lambda ()
                                 (setf timer nil))))
      (cl-call-next-method))))

(cl-defmethod rstream-on-error ((obj rstream-throttle--result) &rest _error)
  (let ((timer (oref obj timer)))
    (when timer (cancel-timer timer)))
  (cl-call-next-method))

(cl-defmethod rstream-on-complete ((obj rstream-throttle--result))
  (with-slots (timer) obj
    (when timer (cancel-timer timer)))
  (cl-call-next-method))

;; StartWith

(defun rstream-start-with (stream initial-value)
  (rstream-apply-operator stream 'rstream-start-with--result
                          :value initial-value))

(defclass rstream-start-with--result (rstream-operator)
  ((value :initarg :value)))

(cl-defmethod rstream-producer-start ((obj rstream-start-with--result)
                                      listener)
  (rstream-send-value listener (oref obj value))
  (cl-call-next-method))

(provide 'rstream-operator)

;; Local Variables:
;; coding: utf-8
;; End:

;;; rstream-operator.el ends here
