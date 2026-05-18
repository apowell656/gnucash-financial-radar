;; GnuCash 5.15+ (macOS/Linux) — use financial-radar-5.15.scm
;; GnuCash 5.14  (Windows portable) — swap to financial-radar.scm
(load (gnc-build-userdata-path "financial-radar/financial-radar-5.15.scm"))
(load (gnc-build-userdata-path "financial-radar/debt-repayment.scm"))
(load (gnc-build-userdata-path "financial-radar/budget-sinking-funds.scm"))