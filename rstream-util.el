;;; rstream-util.el --- Utilities -*- lexical-binding: t -*-

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

(defsubst rstream--ms-to-sec (ms)
  (/ ms 1000.0))

(defconst rstream--uninitialized (make-symbol "uninitialized"))

(defsubst rstream-uninitialized ()
  "Return the placeholder presents `uninitialized'."
  rstream--uninitialized)

(defsubst rstream-initialized-p (place)
  "Return non-nil if PLACE is initialized."
  (not (eq place rstream--uninitialized)))

(defclass rstream-forwarder ()
  ((output
    :initarg :output))
  :documentation "\
A listener which forwards all received message to its output.")

(cl-defmethod rstream-on-value ((obj rstream-forwarder) value)
  (rstream-send-value (oref obj output) value))

(cl-defmethod rstream-on-error ((obj rstream-forwarder) &rest error)
  (apply #'rstream-send-error (oref obj output) error))

(cl-defmethod rstream-on-complete ((obj rstream-forwarder))
  (rstream-send-complete (oref obj output)))

(provide 'rstream-util)

;; Local Variables:
;; coding: utf-8
;; End:

;;; rstream-util.el ends here
