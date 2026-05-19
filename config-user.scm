;; -*-scheme-*-
;;;; config-user.scm -- example GnuCash user config for Financial Radar reports.
;;
;; Copyright (C) 2026 Andre Powell
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, see <https://www.gnu.org/licenses/>.
;;
;; GnuCash 5.15+ (macOS/Linux) — use financial-radar-5.15.scm
;; GnuCash 5.14  (Windows portable) — swap to financial-radar.scm
(load (gnc-build-userdata-path "financial-radar/financial-radar-5.15.scm"))
(load (gnc-build-userdata-path "financial-radar/debt-repayment.scm"))
(load (gnc-build-userdata-path "financial-radar/budget-sinking-funds.scm"))
