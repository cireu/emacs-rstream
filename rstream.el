;;; rstream.el --- Reactive stream in Elisp -*- lexical-binding: t -*-

;; Copyright (C) 2020 Zhu Zihao

;; Author: Zhu Zihao <all_but_last@163.com>
;; URL: https://github.com/cireu/emacs-rstream
;; Version: 0.0.1
;; Package-Requires: ((emacs "25.0"))
;; Keywords: lisp

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

(require 'rstream-core)
(require 'rstream-operator)
(require 'rstream-aggregator)
(require 'rstream-factory)

(provide 'rstream)

;; Local Variables:
;; coding: utf-8
;; End:

;;; rstream.el ends here
