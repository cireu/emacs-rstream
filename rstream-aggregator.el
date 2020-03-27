;;; rstream-aggregator.el --- Stream Aggregators -*- lexical-binding: t -*-

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

(require 'seq)

(require 'rstream-core)
(require 'rstream-util)

(defclass rstream-aggregator (rstream--forwarder)
  ((inputs
    :initarg :inputs
    :accessor rstream-aggregator--inputs))
  :documentation "\
An Aggregator collect values from different stream,
and place them properly in new stream."
  :abstract t)

(cl-defmethod rstream-producer-start ((obj rstream-aggregator) listener)
  (setf (rstream--forwarder-output obj) listener))

(cl-defmethod rstream-producer-stop ((obj rstream-aggregator))
  (setf (rstream--forwarder-output obj) nil))

(defsubst rstream-apply-aggregator (aggregator-class streams &rest args)
  (rstream-broadcaster
   :producer (apply #'make-instance aggregator-class
                    :inputs (seq-into streams 'vector)
                    args)))

;;; Merge

(defun rstream-merge (&rest streams)
  (rstream-apply-aggregator 'rstream--merge-result streams))

(defclass rstream--merge-result (rstream-aggregator)
  ((active-count)))

(cl-defmethod rstream-on-complete ((obj rstream--merge-result))
  (with-slots (active-count) obj
    (cl-decf active-count)
    (when (= active-count 0)
      (cl-call-next-method))))

(cl-defmethod rstream-producer-start ((obj rstream--merge-result) _listener)
  (with-slots (active-count) obj
    (setf active-count 0)
    (seq-doseq (in (rstream-aggregator--inputs obj))
      (rstream-register-listener in obj)
      (cl-incf active-count)))
  (cl-call-next-method))

(cl-defmethod rstream-producer-stop ((obj rstream--merge-result))
  (seq-doseq (in (rstream-aggregator--inputs obj))
    (rstream-delete-listener in obj))
  (cl-call-next-method))

;; Combine

(defun rstream-combine (&rest streams)
  (rstream-apply-aggregator 'rstream--combine-result streams))

(defclass rstream--combine-result (rstream-aggregator)
  ((values) (active-count) (listeners)))

(defclass rstream-combine--listener (rstream-aggregator)
  ((source :initarg :source)))

(cl-defmethod rstream-on-value ((obj rstream-combine--listener) value)
  (rstream-combine--upload-value obj value))

(cl-defmethod rstream-on-complete ((obj rstream-combine--listener))
  (rstream-aggregator--try-complete (rstream--forwarder-output obj)))

(defun rstream-combine--upload-value (obj value)
  (let* ((aggregator (rstream--forwarder-output obj))
         (source (oref obj source))
         (all-inputs (rstream-aggregator--inputs aggregator))
         (idx (seq-position all-inputs source #'eq))
         (values (oref aggregator values)))
    (setf (seq-elt values idx) value)
    (when (seq-every-p #'rstream-initialized-p values)
      (rstream-send-value aggregator (seq-into values 'list)))))

(defun rstream-aggregator--try-complete (obj)
  (with-slots (active-count) obj
    (cl-decf active-count)
    (when (= active-count 0)
      (rstream-send-complete obj))))

(cl-defmethod rstream-producer-start ((obj rstream--combine-result) _listener)
  (with-slots (values active-count listeners) obj
    (setf active-count 0)
    (let* ((inputs (rstream-aggregator--inputs obj))
           (len (length inputs))
           (val-vec (make-vector len (rstream-uninitialized)))
           (lis (seq-map (lambda (in)
                           (let ((l (rstream-combine--listener :source in
                                                               :output obj)))
                             (rstream-register-listener in l)
                             (cl-incf active-count)
                             l))
                         inputs)))
      (setf values val-vec)
      (setf listeners lis)))
  (cl-call-next-method))

(cl-defmethod rstream-producer-stop ((obj rstream--combine-result))
  (let ((x (seq-mapn #'list
                     (rstream-aggregator--inputs obj)
                     (oref obj listeners))))
    (seq-doseq (it x)
      (apply #'rstream-delete-listener it)))
  (cl-call-next-method))

;; Concat

(defun rstream-concat (&rest streams)
  (rstream-apply-aggregator 'rstream-concat--result streams))

(defclass rstream-concat--result (rstream-aggregator)
  ((current-index)))

(cl-defmethod rstream-on-complete ((obj rstream-concat--result))
  (with-slots (current-index) obj
    (let* ((inputs (rstream-aggregator--inputs obj))
           (current-stream (seq-elt inputs current-index)))
      (rstream-delete-listener current-stream obj)
      (cl-incf current-index)
      (if (< current-index (length inputs))
          (rstream-register-listener (seq-elt inputs current-index) obj)
        (cl-call-next-method)))))

(cl-defmethod rstream-producer-start ((obj rstream-concat--result) _listener)
  (with-slots (current-index) obj
    (setf current-index 0)
    (rstream-register-listener (seq-elt (rstream-aggregator--inputs obj)
                                        current-index)
                               obj))
  (cl-call-next-method))

(cl-defmethod rstream-producer-stop ((obj rstream-concat--result))
  (with-slots (current-index) obj
    (let ((inputs (rstream-aggregator--inputs obj)))
      (when (< current-index (length inputs))
        (rstream-delete-listener (seq-elt inputs current-index) obj))))
  (cl-call-next-method))

;; Race

;; (defclass rstream-race--result (rstream-aggregator)
;;   ((survivers) ()))

;; (cl-defmethod rstream-producer-start ((obj rstream-race--result) listener)
;;   )

(provide 'rstream-aggregator)

;; Local Variables:
;; coding: utf-8
;; End:

;;; rstream-aggregator.el ends here
