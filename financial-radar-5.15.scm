;; -*-scheme-*-
;;;; financial-radar-5.15.scm
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
;; Financial Radar Dashboard — modern CSS version for GnuCash 5.15+ / WebKitGTK 2.42+.
;; For GnuCash 5.14 on Windows use financial-radar.scm instead.
;;
;; Installation:
;;   macOS: '~/Library/Application Support/GnuCash/financial-radar'
;;   Linux : ~/.local/share/gnucash/financial-radar
;;   Windows: %APPDATA%\GnuCash\financial-radar  (once on 5.15+)
;;
;; In config-user.scm load exactly ONE of these two lines:
;;   (load (gnc-build-userdata-path "financial-radar/financial-radar.scm"))       ; 5.14 compat
;;   (load (gnc-build-userdata-path "financial-radar/financial-radar-5.15.scm"))  ; 5.15+ modern
;;
;; After copying, restart GnuCash.  The report appears under:
;;   Reports > Budget > Financial Radar

(define-module (gnucash reports financial-radar)
  #:use-module (gnucash engine)
  #:use-module (gnucash utilities)
  #:use-module (gnucash core-utils)
  #:use-module (gnucash app-utils)
  #:use-module (gnucash options)
  #:use-module (gnucash report)
  #:use-module (gnucash html)
  #:use-module (sw_expressions)
  #:use-module (srfi srfi-1))

;;;============================================================
;;; CONSTANTS
;;;============================================================

(define report-name "Financial Radar")
(define report-guid "7a2b3c4d-5e6f-7890-abcd-ef1234567890")

(define tab-general   (N_ "1. General"))
(define tab-budget    (N_ "2. Budget"))
(define tab-emergency (N_ "3. Emergency Fund"))
(define tab-cashflow  (N_ "5. Cash Flow"))
(define tab-networth  (N_ "6. Net Worth"))
(define tab-accounts  (N_ "7. Account Balances"))
(define tab-projected (N_ "8. Projected Balances"))
(define tab-upcoming  (N_ "9. Upcoming Transactions"))

(define opt-start-date  (N_ "Start Date"))
(define opt-end-date    (N_ "End Date"))
(define opt-nw-assets   (N_ "Asset Accounts"))
(define opt-nw-liabs    (N_ "Liability Accounts"))
(define opt-cf-accounts (N_ "Cash Accounts"))
(define opt-ef-liquid   (N_ "Liquid Asset Accounts"))
(define opt-ef-expenses (N_ "Monthly Expense Accounts"))
(define opt-ef-target   (N_ "Target Months"))
(define opt-ef-mode     (N_ "Mode"))
(define opt-ef-goal     (N_ "Target Dollar Amount"))
(define opt-acct-list   (N_ "Accounts to Display"))
(define opt-upcoming-period (N_ "Look-ahead Period"))
(define opt-budget          (N_ "Budget"))
(define opt-budget-expenses (N_ "Expense Accounts"))

(define tab-debt          (N_ "4. Debt Repayment"))
(define opt-debt-accounts (N_ "Debt Accounts"))
(define opt-debt-strategy (N_ "Strategy"))
(define opt-debt-extra    (N_ "Extra Monthly Payment"))

;;;============================================================
;;; OPTIONS GENERATOR
;;;============================================================

(define (fr-options-generator)
  (let ((options (gnc-new-optiondb)))

    (gnc-register-start-date-option options tab-general opt-start-date "a"
      (N_ "Start of the reporting period."))
    (gnc-register-end-date-option options tab-general opt-end-date "b"
      (N_ "End of the reporting period."))

    (gnc-register-account-list-option options tab-networth opt-nw-assets "a"
      (N_ "Accounts counted as assets for the Net Worth card.") '())
    (gnc-register-account-list-option options tab-networth opt-nw-liabs "b"
      (N_ "Accounts counted as liabilities for the Net Worth card.") '())

    (gnc-register-account-list-option options tab-cashflow opt-cf-accounts "a"
      (N_ "Asset/bank accounts to track for cash flow (same as the built-in Cash Flow report).") '())

    (gnc-register-account-list-option options tab-emergency opt-ef-liquid "a"
      (N_ "Liquid accounts (e.g. checking, savings) for emergency fund balance.") '())
    (gnc-register-account-list-option options tab-emergency opt-ef-expenses "b"
      (N_ "Expense accounts used to estimate average monthly spending.") '())
    (gnc-register-multichoice-option options tab-emergency opt-ef-mode "c"
      (N_ "How to measure the emergency fund.") "months"
      (list (vector 'months (N_ "Months of expenses"))
            (vector 'goal   (N_ "Dollar goal"))))
    (gnc-register-number-range-option options tab-emergency opt-ef-target "d"
      (N_ "Target number of months of expenses (Months mode).") 6 1 24 1)
    (gnc-register-number-range-option options tab-emergency opt-ef-goal "e"
      (N_ "Target dollar amount to save (Goal mode).") 10000 0 10000000 100)

    (gnc-register-account-list-option options tab-accounts opt-acct-list "a"
      (N_ "Accounts to display in the Account Balances card.") '())

    (gnc-register-account-list-option options tab-upcoming (N_ "Accounts") "a"
      (N_ "Accounts to show scheduled (upcoming) transactions for.") '())
    (gnc-register-multichoice-option options tab-upcoming opt-upcoming-period "b"
      (N_ "How far ahead to show scheduled transactions.") "end-next-month"
      (list (vector 'end-this-month (N_ "End of this month"))
            (vector 'end-next-month (N_ "End of next month"))
            (vector 'days-30        (N_ "30 days from today"))
            (vector 'days-60        (N_ "60 days from today"))
            (vector 'days-90        (N_ "90 days from today"))
            (vector 'months-6       (N_ "6 months from today"))))

    (gnc-register-account-list-option options tab-projected (N_ "Accounts") "a"
      (N_ "Accounts to use for projected balance calculations.") '())

    (gnc-register-budget-option options tab-budget opt-budget "a"
      (N_ "Budget to use for the Budget and Highest Spending cards.")
      (gnc-budget-get-default (gnc-get-current-book)))
    (gnc-register-account-list-option options tab-budget (N_ "Expense Accounts") "b"
      (N_ "Expense accounts to use for Planned vs Actual and Highest Spending cards.") '())

    ;; ── Debt Repayment Card ───────────────────────────────────────
    (gnc-register-account-list-option options
      tab-debt opt-debt-accounts "a"
      (N_ "Liability and credit-card accounts for the Debt Repayment summary card.")
      '())

    (gnc-register-multichoice-option options
      tab-debt opt-debt-strategy "b"
      (N_ "Payoff strategy for the Debt Repayment card.")
      "avalanche"
      (list (vector 'snowball        (N_ "Snowball — lowest balance first"))
            (vector 'avalanche       (N_ "Avalanche — highest APR first"))
            (vector 'custom-priority (N_ "Custom — Priority column"))
            (vector 'minimum-only    (N_ "Minimum Only"))))

    (gnc-register-number-range-option options
      tab-debt opt-debt-extra "c"
      (N_ "Extra dollars per month on top of all minimums.")
      0 0 100000 10)

    options))

;;;============================================================
;;; UTILITY FUNCTIONS
;;;============================================================

(define (fr-opt options tab key)
  (gnc:option-value (gnc:lookup-option options tab key)))

(define (fr-acct-opt options tab key)
  (gnc-optiondb-lookup-value options tab key))

(define (fr-date->t64 date-val)
  (if (pair? date-val) (car date-val) date-val))

(define (fr-expand-accounts accounts)
  (delete-duplicates
   (apply append
          (map (lambda (acc)
                 (cons acc (gnc-account-get-descendants acc)))
               (or accounts '())))))

(define (fr-leaf-accounts accounts)
  (filter (lambda (acc) (null? (gnc-account-get-children acc)))
          (fr-expand-accounts accounts)))

(define (fr-sum-balances accounts)
  (fold (lambda (acc total)
          (+ total (gnc-numeric-to-double (xaccAccountGetBalance acc))))
        0.0
        (fr-expand-accounts accounts)))

(define (fr-sum-balances-as-of accounts t-end)
  (fold
   (lambda (acc total)
     (+ total
        (fold
         (lambda (split subtotal)
           (let* ((txn  (xaccSplitGetParent split))
                  (date (xaccTransGetDate txn))
                  (val  (gnc-numeric-to-double (xaccSplitGetValue split))))
             (if (<= date t-end) (+ subtotal val) subtotal)))
         0.0
         (xaccAccountGetSplitList acc))))
   0.0
   (fr-expand-accounts accounts)))

(define (fr-sum-splits-pred accounts t-start t-end pred)
  (fold
   (lambda (acc subtotal)
     (+ subtotal
        (fold
         (lambda (split s)
           (let* ((txn  (xaccSplitGetParent split))
                  (date (xaccTransGetDate txn))
                  (val  (gnc-numeric-to-double (xaccSplitGetValue split))))
             (if (and (>= date t-start) (<= date t-end) (pred val))
                 (+ s val) s)))
         0.0
         (xaccAccountGetSplitList acc))))
   0.0
   (fr-expand-accounts accounts)))

(define (fr-sum-splits accounts t-start t-end)
  (fr-sum-splits-pred accounts t-start t-end (lambda (v) #t)))

(define (fr-sum-inflow accounts t-start t-end)
  (fr-sum-splits-pred accounts t-start t-end positive?))

(define (fr-sum-outflow accounts t-start t-end)
  (abs (fr-sum-splits-pred accounts t-start t-end negative?)))

(define (fr-fmt-money amount currency)
  (gnc:monetary->string
   (gnc:make-gnc-monetary
    currency
    (double-to-gnc-numeric
     (if (and (number? amount) (finite? amount)) amount 0.0)
     100 GNC-RND-ROUND))))

(define (fr-val->t64 v)
  (cond ((pair? v)   (car v))
        ((number? v) (inexact->exact v))
        (else        (current-time))))

(define (fr-fmt-date t64)
  (strftime "%b %-d, %Y" (localtime t64)))

(define (fr-fmt-short-date t64)
  (strftime "%-m/%-d" (localtime t64)))

(define (fr-midnight? t64)
  (let ((lt (localtime t64)))
    (and (= (tm:hour lt) 0)
         (= (tm:min lt) 0)
         (= (tm:sec lt) 0))))

(define (fr-display-range-end t64)
  (if (fr-midnight? t64) (- t64 1) t64))

(define (fr-safe-date db section name)
  (let* ((raw (gnc-optiondb-lookup-value db section name))
         (t64 (and raw (gnc:date-option-absolute-time raw))))
    (if (and t64 (integer? t64) (positive? t64))
        t64
        (current-time))))

(define (fr-safe-str s max-len)
  (let ((clean (gnc:html-string-sanitize s)))
    (if (> (string-length clean) max-len)
        (string-append (substring clean 0 (- max-len 1)) "…")
        clean)))

(define (fr-type-label type)
  (cond ((eqv? type ACCT-TYPE-BANK)      "Bank")
        ((eqv? type ACCT-TYPE-CASH)      "Cash")
        ((eqv? type ACCT-TYPE-CREDIT)    "Credit Card")
        ((eqv? type ACCT-TYPE-ASSET)     "Asset")
        ((eqv? type ACCT-TYPE-LIABILITY) "Liability")
        ((eqv? type ACCT-TYPE-STOCK)     "Stock")
        ((eqv? type ACCT-TYPE-MUTUAL)    "Mutual Fund")
        ((eqv? type ACCT-TYPE-INCOME)    "Income")
        ((eqv? type ACCT-TYPE-EXPENSE)   "Expense")
        ((eqv? type ACCT-TYPE-EQUITY)    "Equity")
        ((eqv? type ACCT-TYPE-SAVINGS)   "Savings")
        (else                            "Account")))

(define (fr-take lst n)
  (if (or (null? lst) (= n 0))
      '()
      (cons (car lst) (fr-take (cdr lst) (- n 1)))))

;;;============================================================
;;; CSS — modern (GnuCash 5.15+ / WebKitGTK 2.42+)
;;; Uses CSS custom properties, Grid, Flexbox, and unprefixed gradients.
;;;============================================================

(define fr-css
"<style>
:root {
  --bg:     #f1f5f9;
  --card:   #ffffff;
  --txt:    #1e293b;
  --sub:    #475569;
  --muted:  #94a3b8;
  --border: #e2e8f0;
  --pos:    #16a34a;
  --neg:    #dc2626;
  --accent: #2563eb;
  --warn:   #d97706;
  --radius: 12px;
  --shadow: 0 1px 3px rgba(0,0,0,.07), 0 4px 14px rgba(0,0,0,.05);
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--bg);
  color: var(--txt);
  padding: 24px;
  font-size: 14px;
  line-height: 1.5;
}

/* ── Header ─────────────────────────────────── */
.fr-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-bottom: 20px;
}
.fr-header h1 {
  font-size: 1.35rem;
  font-weight: 800;
  color: var(--txt);
  letter-spacing: -.02em;
}
.fr-header .period {
  font-size: .78rem;
  color: var(--muted);
  margin-left: 10px;
}

/* ── Two-column grid ─────────────────────────── */
.fr-grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 16px; }

/* ── Card ───────────────────────────────────── */
.card {
  background: var(--card);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  padding: 20px;
  overflow: hidden;
}
.card-hdr {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 14px;
}
.card-title {
  font-size: .68rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: .09em;
  color: var(--muted);
}

/* ── Typography ─────────────────────────────── */
.big {
  font-size: 1.85rem;
  font-weight: 800;
  line-height: 1;
  color: var(--txt);
  letter-spacing: -.02em;
}
.big.pos { color: var(--pos); }
.big.neg { color: var(--neg); }
.big-unit {
  font-size: 1rem;
  font-weight: 400;
  color: var(--muted);
  margin-left: 4px;
}
.meta { font-size: .76rem; color: var(--sub); margin-top: 12px; }
.meta-row { display: flex; justify-content: space-between; margin-top: 5px; }
.meta-val { font-weight: 600; color: var(--txt); }
.divider { height: 1px; background: var(--border); margin: 10px 0; }

/* ── Pills ──────────────────────────────────── */
.pill {
  display: inline-block;
  padding: 2px 10px;
  border-radius: 99px;
  font-size: .68rem;
  font-weight: 700;
  white-space: nowrap;
}
.pill.good  { background: #dcfce7; color: var(--pos); }
.pill.warn  { background: #fef3c7; color: var(--warn); }
.pill.bad   { background: #fee2e2; color: var(--neg); }
.pill.info  { background: #dbeafe; color: var(--accent); }
.pill.muted { background: var(--border); color: var(--sub); }

/* ── Progress Bar ───────────────────────────── */
.pb-wrap { margin: 10px 0 4px; }
.pb-bg { height: 8px; background: var(--border); border-radius: 99px; overflow: hidden; }
.pb-fill { height: 100%; border-radius: 99px; }
.pb-fill.green  { background: linear-gradient(90deg, #16a34a, #4ade80); }
.pb-fill.yellow { background: linear-gradient(90deg, #d97706, #fbbf24); }
.pb-fill.red    { background: linear-gradient(90deg, #dc2626, #f87171); }
.pb-fill.blue   { background: linear-gradient(90deg, #2563eb, #60a5fa); }

/* ── Flow Grid ──────────────────────────────── */
.flow-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-bottom: 10px; }
.flow-box { background: var(--bg); border-radius: 8px; padding: 10px 8px; text-align: center; }
.flow-lbl {
  font-size: .65rem;
  text-transform: uppercase;
  letter-spacing: .06em;
  color: var(--muted);
  margin-bottom: 5px;
}
.flow-val { font-size: 1.05rem; font-weight: 700; white-space: nowrap; }
.flow-val.pos { color: var(--pos); }
.flow-val.neg { color: var(--neg); }
.flow-val.neu { color: var(--accent); }

/* ── Account Rows ───────────────────────────── */
.acct-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 8px 0;
  border-bottom: 1px solid var(--border);
  font-size: .82rem;
  gap: 8px;
}
.acct-row:last-child { border-bottom: none; }
.acct-name { font-weight: 500; color: var(--txt); }
.acct-type { font-size: .68rem; color: var(--muted); margin-top: 1px; }
.acct-bal  { font-weight: 700; text-align: right; flex-shrink: 0; }
.acct-bal.neg { color: var(--neg); }

/* ── Transaction Rows ───────────────────────── */
.tx-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 0;
  border-bottom: 1px solid var(--border);
  font-size: .8rem;
}
.tx-row:last-child { border-bottom: none; }
.tx-date { color: var(--muted); min-width: 80px; flex-shrink: 0; font-size: .72rem; }
.tx-desc {
  flex: 1;
  font-weight: 500;
  color: var(--txt);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.tx-amt { font-weight: 700; flex-shrink: 0; }
.tx-amt.pos { color: var(--pos); }
.tx-amt.neg { color: var(--neg); }

/* ── Projection Grid ─────────────────────────── */
.proj-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
.proj-box { background: var(--bg); border-radius: 8px; padding: 12px 8px; text-align: center; }
.proj-lbl {
  font-size: .65rem;
  text-transform: uppercase;
  letter-spacing: .06em;
  color: var(--muted);
  margin-bottom: 6px;
}
.proj-val { font-size: 1rem; font-weight: 700; color: var(--txt); }

/* ── Category Rows ──────────────────────────── */
.cat-row { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; font-size: .8rem; }
.cat-rank {
  width: 20px;
  height: 20px;
  border-radius: 50%;
  color: #fff;
  font-size: .65rem;
  font-weight: 800;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
.cat-name { flex: 1; font-weight: 500; color: var(--txt); min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.cat-bar  { flex: 1.2; }
.cat-bar-bg { height: 5px; background: var(--border); border-radius: 99px; overflow: hidden; }
.cat-bar-fill { height: 100%; border-radius: 99px; }
.cat-amt { font-weight: 700; color: var(--txt); min-width: 72px; text-align: right; flex-shrink: 0; }

/* ── Empty State ────────────────────────────── */
.empty { text-align: center; padding: 24px 12px; color: var(--muted); font-size: .8rem; line-height: 1.6; }

/* ── Debt Repayment 4-box grid (CSS Grid — 5.15) ── */
.debt-grid-4 {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 8px;
  margin-bottom: 10px;
}
.debt-box { background: var(--bg); border-radius: 8px; padding: 10px 8px; text-align: center; }
.debt-lbl {
  font-size: .65rem;
  text-transform: uppercase;
  letter-spacing: .06em;
  color: var(--muted);
  margin-bottom: 5px;
}
.debt-val { font-size: 1rem; font-weight: 700; color: var(--txt); white-space: nowrap; }
.debt-val.neg  { color: var(--neg); }
.debt-val.warn { color: var(--warn); }

/* ── Row gap helper ─────────────────────────── */
.fr-gap { margin-bottom: 16px; }

/* ── Print / PDF ─────────────────────────────── */
@media print {
  @page { margin: 0.5cm; }
  html { print-color-adjust: exact; zoom: 0.59; }
  body { background: white; padding: 8px; }
  .fr-grid-2 { margin-bottom: 8px; }
  .fr-gap    { margin-bottom: 8px; }
  .card { box-shadow: none; border: 1px solid var(--border); padding: 13px 15px; break-inside: avoid; }
}
</style>")

;;;============================================================
;;; DEBT CARD — parsing helpers and compact simulation
;;; Mirrors debt-repayment.scm logic; kept self-contained so
;;; the dashboard card works even without the standalone planner.
;;;============================================================

(define fr-month-abbrevs
  '#("Jan" "Feb" "Mar" "Apr" "May" "Jun"
     "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (fr-debt-month-str now-t64 n)
  (let* ((tm  (localtime now-t64))
         (tot (+ (tm:mon tm) n))
         (yr  (+ (tm:year tm) 1900 (quotient tot 12)))
         (mo  (remainder tot 12)))
    (string-append (vector-ref fr-month-abbrevs mo) " " (number->string yr))))

(define (fr-debt-trim s)
  (let* ((l  (string->list s))
         (lf (let lp ((c l))
               (if (and (pair? c) (char-whitespace? (car c))) (lp (cdr c)) c)))
         (r  (reverse
              (let lp ((c (reverse lf)))
                (if (and (pair? c) (char-whitespace? (car c))) (lp (cdr c)) c)))))
    (list->string r)))

(define (fr-debt-split str delim)
  (let loop ((chars (string->list str)) (cur '()) (acc '()))
    (cond
      ((null? chars)
       (reverse (cons (list->string (reverse cur)) acc)))
      ((char=? (car chars) delim)
       (loop (cdr chars) '() (cons (list->string (reverse cur)) acc)))
      (else
       (loop (cdr chars) (cons (car chars) cur) acc)))))

(define (fr-debt-parse-num s default)
  (let ((n (string->number (fr-debt-trim s))))
    (if (and n (real? n) (>= n 0)) (exact->inexact n) default)))

(define (fr-debt-parse-int s default)
  (let ((n (string->number (fr-debt-trim s))))
    (if (and n (integer? n) (> n 0)) (inexact->exact n) default)))

(define (fr-debt-parse-note-kv text)
  (filter-map
   (lambda (raw-line)
     (let ((line (fr-debt-trim raw-line)))
       (if (or (string=? line "")
               (char=? (string-ref line 0) #\#)
               (char=? (string-ref line 0) #\;))
           #f
           (let loop ((chars   (string->list line))
                      (key-acc '())
                      (eq-seen #f)
                      (val-acc '()))
             (cond
               ((null? chars)
                (if eq-seen
                    (cons (string-downcase (fr-debt-trim (list->string (reverse key-acc))))
                          (fr-debt-trim (list->string (reverse val-acc))))
                    #f))
               ((and (not eq-seen) (char=? (car chars) #\=))
                (loop (cdr chars) key-acc #t val-acc))
               (eq-seen
                (loop (cdr chars) key-acc #t (cons (car chars) val-acc)))
               (else
                (loop (cdr chars) (cons (car chars) key-acc) #f val-acc)))))))
   (fr-debt-split text #\newline)))

(define (fr-debt-note-assump acc)
  ;; Returns (name apr% min-pay priority) from account notes, or #f if no valid APR.
  (let* ((kv    (fr-debt-parse-note-kv (or (xaccAccountGetNotes acc) "")))
         (apr-e (assoc "apr" kv)))
    (if (not apr-e)
        #f
        (let ((apr (fr-debt-parse-num (cdr apr-e) -1.0)))
          (if (< apr 0.0)
              #f
              (let* ((min-e (assoc "min-payment" kv))
                     (pri-e (assoc "priority" kv))
                     (minp  (if min-e (fr-debt-parse-num (cdr min-e) 0.0) 0.0))
                     (pri   (if pri-e (fr-debt-parse-int (cdr pri-e) 99) 99)))
                (list (fr-debt-trim (xaccAccountGetName acc))
                      apr minp pri)))))))

(define (fr-debt-build-list accounts)
  (filter-map
   (lambda (acc)
     (let* ((aname (fr-debt-trim (xaccAccountGetName acc)))
            (bal   (abs (gnc-numeric-to-double (xaccAccountGetBalance acc))))
            (hit   (fr-debt-note-assump acc)))
       (and hit (> bal 0.001)
            (list aname
                  bal
                  (/ (cadr hit) 1200.0)
                  (caddr hit)
                  (cadddr hit)
                  (cadr hit)))))
   accounts))

(define (fr-debt-simulate debt-list strategy extra max-months)
  (if (null? debt-list)
      (list 0 0.0 "" 0)
      (let* ((n     (length debt-list))
             (bals  (list->vector (map cadr   debt-list)))
             (rates (list->vector (map caddr  debt-list)))
             (mins  (list->vector (map cadddr debt-list)))
             (pris  (list->vector (map (lambda (d) (list-ref d 4)) debt-list)))
             (sbals (list->vector (map cadr   debt-list)))
             (names (list->vector (map car    debt-list)))
             (paid  (make-vector n #f))
             (cints (make-vector n 0.0))
             (pmths (make-vector n #f)))

        (define (all-done?)
          (every (lambda (i) (vector-ref paid i)) (iota n)))
        (define (freed-min)
          (fold (lambda (i s)
                  (if (vector-ref paid i) (+ s (vector-ref mins i)) s))
                0.0 (iota n)))
        (define (get-target)
          (let ((live (filter (lambda (i) (not (vector-ref paid i))) (iota n))))
            (if (null? live) -1
                (car (sort live
                           (cond
                             ((eq? strategy 'snowball)
                              (lambda (a b) (< (vector-ref sbals a) (vector-ref sbals b))))
                             ((eq? strategy 'avalanche)
                              (lambda (a b) (> (vector-ref rates a) (vector-ref rates b))))
                             ((eq? strategy 'custom-priority)
                              (lambda (a b) (< (vector-ref pris a) (vector-ref pris b))))
                             (else (lambda (a b) (< a b)))))))))

        (let loop ((m 1))
          (cond
            ((or (all-done?) (> m max-months))
             (let* ((fm   (if (all-done?) (- m 1) m))
                    (ti   (fold + 0.0 (map (lambda (i) (vector-ref cints i)) (iota n))))
                    (done (sort (filter (lambda (i) (vector-ref pmths i)) (iota n))
                                (lambda (a b) (< (vector-ref pmths a) (vector-ref pmths b)))))
                    (fi   (if (null? done) -1 (car done))))
               (list fm ti
                     (if (>= fi 0) (vector-ref names fi) "")
                     (if (>= fi 0) (vector-ref pmths fi) 0))))
            (else
             (let ((tgt  (if (eq? strategy 'minimum-only) -1 (get-target)))
                   (xtra (if (eq? strategy 'minimum-only) 0.0 (+ extra (freed-min)))))
               (let dloop ((i 0))
                 (when (< i n)
                   (unless (vector-ref paid i)
                     (let* ((b   (vector-ref bals i))
                            (int (* b (vector-ref rates i)))
                            (b2  (+ b int))
                            (pmt (min b2 (+ (vector-ref mins i)
                                            (if (= i tgt) xtra 0.0)))))
                       (vector-set! bals  i (- b2 pmt))
                       (vector-set! cints i (+ (vector-ref cints i) int))
                       (when (<= (vector-ref bals i) 0.001)
                         (vector-set! paid  i #t)
                         (vector-set! pmths i m))))
                   (dloop (+ i 1))))
               (loop (+ m 1)))))))))

(define (fr-debt-strategy-label s)
  (cond ((eq? s 'snowball)        "Snowball")
        ((eq? s 'avalanche)       "Avalanche")
        ((eq? s 'custom-priority) "Custom")
        ((eq? s 'minimum-only)    "Minimum Only")
        (else                     "Avalanche")))

;;;============================================================
;;; CARD: Debt Repayment Summary
;;;============================================================

(define (fr-card-debt debt-accounts strategy extra currency now)
  (let* ((uncfg?  (null? (or debt-accounts '())))
         (debts   (if uncfg? '()
                      (fr-debt-build-list (or debt-accounts '()))))
         (total   (fold + 0.0 (map cadr debts)))

         ;; ── Payoff calculation ────────────────────────────────────────
         (sim     (if (or uncfg? (null? debts))
                      (list 0 0.0 "" 0)
                      (fr-debt-simulate debts
                                        (or strategy 'avalanche)
                                        (or extra 0.0)
                                        600)))
         (fm      (list-ref sim 0))
         (ti      (list-ref sim 1))
         (fn      (list-ref sim 2))
         (fpm     (list-ref sim 3))
         (fmt     (lambda (n) (fr-fmt-money n currency)))
         (as-of   (strftime "%b %-d, %Y" (localtime now))))

    ;; ── Card rendering ────────────────────────────────────────────────
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Debt Repayment</span>"
     (if (not uncfg?)
         (string-append "<span class='pill info'>"
                        (gnc:html-string-sanitize (fr-debt-strategy-label strategy))
                        "</span>")
         "")
     "</div>"

     ;; ── Fallback / warning state ──────────────────────────────────────
     (if uncfg?
         "<div class='empty'>Configure debt accounts in Options &rarr; Debt Repayment.<br>Add apr=, min-payment=, and optionally priority= to each account&rsquo;s Notes field.</div>"
         (string-append
          "<div class='debt-grid-4'>"

          "<div class='debt-box'>"
          "<div class='debt-lbl'>Total Debt</div>"
          "<div class='debt-val neg'>" (fmt total) "</div>"
          "</div>"

          "<div class='debt-box'>"
          "<div class='debt-lbl'>Debt-Free Date</div>"
          "<div class='debt-val'>"
          (if (> fm 0) (gnc:html-string-sanitize (fr-debt-month-str now fm)) "&mdash;")
          "</div>"
          "</div>"

          "<div class='debt-box'>"
          "<div class='debt-lbl'>Total Interest</div>"
          "<div class='debt-val warn'>" (fmt ti) "</div>"
          "</div>"

          "<div class='debt-box'>"
          "<div class='debt-lbl'>Next Payoff</div>"
          "<div class='debt-val'>"
          (if (> fpm 0)
              (string-append
               (gnc:html-string-sanitize fn) ", "
               (gnc:html-string-sanitize (fr-debt-month-str now fpm)))
              "&mdash;")
          "</div>"
          "</div>"

          "</div>"))

     "<div style='font-size:.68rem;color:var(--muted);margin-top:6px'>As of " as-of "</div>"
     "</div>")))

;;;============================================================
;;; CARD: Net Worth
;;;============================================================

(define (fr-card-net-worth assets liabs currency)
  (let* ((asset-total (fr-sum-balances assets))
         (liab-total  (fr-sum-balances liabs))
         (net         (+ asset-total liab-total))
         (pos?        (>= net 0))
         (fmt         (lambda (n) (fr-fmt-money n currency)))
         (as-of       (strftime "%b %-d, %Y" (localtime (current-time)))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Net Worth</span>"
     "</div>"
     "<div class='big " (if pos? "pos" "neg") "'>" (fmt net) "</div>"
     "<div class='meta'>"
     "<div class='meta-row'><span>Total Assets</span>"
     "<span class='meta-val'>" (fmt asset-total) "</span></div>"
     "<div class='meta-row'><span>Total Liabilities</span>"
     "<span class='meta-val' style='color:var(--neg)'>" (fmt (abs liab-total)) "</span></div>"
     "</div>"
     (if (and (null? assets) (null? liabs))
         "<div class='empty' style='padding:10px 0 0'>Configure accounts<br>in Options &rarr; Net Worth.</div>"
         "")
     "<div style='font-size:.68rem;color:var(--muted);margin-top:8px'>As of " as-of "</div>"
     "</div>")))

;;;============================================================
;;; CARD: Cash Flow
;;;============================================================

(define (fr-card-cash-flow inflow outflow currency period-label)
  (let* ((net  (- inflow outflow))
         (pos? (>= net 0))
         (fmt  (lambda (n) (fr-fmt-money n currency))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Cash Flow</span>"
     "<span class='pill " (if pos? "good" "bad") "'>"
     (if pos? "Positive" "Negative") "</span>"
     "</div>"
     "<div class='flow-grid'>"
     "<div class='flow-box'><div class='flow-lbl'>Inflow</div>"
     "<div class='flow-val pos'>+" (fmt inflow) "</div></div>"
     "<div class='flow-box'><div class='flow-lbl'>Outflow</div>"
     "<div class='flow-val neg'>&minus;" (fmt outflow) "</div></div>"
     "<div class='flow-box'><div class='flow-lbl'>Net</div>"
     "<div class='flow-val " (if pos? "pos" "neg") "'>" (fmt net) "</div></div>"
     "</div>"
     "<div style='font-size:.72rem;color:var(--muted);text-align:center'>"
     "Period: " (gnc:html-string-sanitize period-label) "</div>"
     "</div>")))

;;;============================================================
;;; CARD: Emergency Fund
;;;============================================================

(define (fr-card-emergency-fund liquid monthly-exp target-months ef-mode goal-amount currency)
  (let* ((as-of   (strftime "%b %-d, %Y" (localtime (current-time))))
         (fmt     (lambda (n) (fr-fmt-money n currency)))
         (pct-str (lambda (p)
                    (number->string (inexact->exact (floor (min 100.0 p))))))
         (bar+pill (lambda (pct threshold-full threshold-half)
                     (let* ((bar-cls  (cond ((>= pct threshold-full) "green")
                                            ((>= pct threshold-half) "yellow")
                                            (else                    "red")))
                            (status   (cond ((>= pct threshold-full) "On Target")
                                            ((>= pct threshold-half) "Building")
                                            (else                    "Low")))
                            (pill-cls (cond ((>= pct threshold-full) "good")
                                            ((>= pct threshold-half) "warn")
                                            (else                    "bad"))))
                       (list bar-cls status pill-cls)))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Emergency Fund</span>"
     (if (eq? ef-mode 'goal)
         (let* ((pct      (* 100.0 (if (> goal-amount 0) (/ liquid goal-amount) 0.0)))
                (bpl      (bar+pill pct 100.0 50.0))
                (bar-cls  (car bpl))
                (status   (cadr bpl))
                (pill-cls (caddr bpl))
                (remaining (max 0.0 (- goal-amount liquid))))
           (string-append
            "<span class='pill " pill-cls "'>" status "</span>"
            "</div>"
            "<div class='big'>" (pct-str pct)
            "<span class='big-unit'>%</span></div>"
            "<div class='pb-wrap'><div class='pb-bg'>"
            "<div class='pb-fill " bar-cls "' style='width:" (pct-str pct) "%'>"
            "</div></div></div>"
            "<div class='meta'>"
            "<div class='meta-row'><span>Saved</span><span class='meta-val'>" (fmt liquid) "</span></div>"
            "<div class='meta-row'><span>Goal</span><span class='meta-val'>" (fmt goal-amount) "</span></div>"
            "<div class='meta-row'><span>Remaining</span><span class='meta-val'>" (fmt remaining) "</span></div>"
            "</div>"))
         (let* ((months   (if (> monthly-exp 0) (/ liquid monthly-exp) 0.0))
                (pct      (* 100.0 (/ months target-months)))
                (bpl      (bar+pill months target-months (* 0.5 target-months)))
                (bar-cls  (car bpl))
                (status   (cadr bpl))
                (pill-cls (caddr bpl))
                (mo->str  (lambda (n)
                            (let* ((f (inexact->exact (floor n)))
                                   (d (inexact->exact (round (* 10 (- n f))))))
                              (string-append (number->string f) "." (number->string d))))))
           (string-append
            "<span class='pill " pill-cls "'>" status "</span>"
            "</div>"
            "<div class='big'>" (mo->str months)
            "<span class='big-unit'>/ " (number->string (inexact->exact target-months)) " mo</span></div>"
            "<div class='pb-wrap'><div class='pb-bg'>"
            "<div class='pb-fill " bar-cls "' style='width:" (pct-str pct) "%'>"
            "</div></div></div>"
            "<div class='meta'>"
            "<div class='meta-row'><span>Liquid Assets</span><span class='meta-val'>" (fmt liquid) "</span></div>"
            "<div class='meta-row'><span>Est. Monthly Expenses</span><span class='meta-val'>" (fmt monthly-exp) "</span></div>"
            "</div>")))
     "<div style='font-size:.68rem;color:var(--muted);margin-top:8px'>As of " as-of "</div>"
     "</div>")))

;;;============================================================
;;; CARD: Account Balances
;;;============================================================

(define (fr-card-account-balances accounts)
  (let ((as-of (strftime "%b %-d, %Y" (localtime (current-time)))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Account Balances</span>"
     "</div>"
     (if (null? (or accounts '()))
         "<div class='empty'>No accounts selected.<br>Configure in Options &rarr; Account Balances.</div>"
         (let* ((total    (fr-sum-balances accounts))
                (currency (xaccAccountGetCommodity (car accounts)))
                (neg-tot? (< total 0)))
           (string-append
            (apply string-append
                   (map (lambda (acc)
                          (let* ((bal   (xaccAccountGetBalance acc))
                                 (bald  (gnc-numeric-to-double bal))
                                 (comm  (xaccAccountGetCommodity acc))
                                 (name  (xaccAccountGetName acc))
                                 (type  (xaccAccountGetType acc))
                                 (fmted (gnc:monetary->string (gnc:make-gnc-monetary comm bal)))
                                 (neg?  (< bald 0)))
                            (string-append
                             "<div class='acct-row'>"
                             "<div><div class='acct-name'>" (fr-safe-str name 28) "</div>"
                             "<div class='acct-type'>" (fr-type-label type) "</div></div>"
                             "<div class='acct-bal" (if neg? " neg" "") "'>" fmted "</div>"
                             "</div>")))
                        accounts))
            "<div class='divider'></div>"
            "<div class='acct-row'>"
            "<div><div class='acct-name' style='font-weight:700'>Total</div></div>"
            "<div class='acct-bal" (if neg-tot? " neg" "") "' style='font-weight:700'>"
            (fr-fmt-money total currency) "</div>"
            "</div>")))
     "<div style='font-size:.68rem;color:var(--muted);margin-top:8px'>As of " as-of "</div>"
     "</div>")))

;;;============================================================
;;; CARD: Upcoming Transactions
;;;============================================================

(define (fr-next-month-start t64)
  (let* ((lt  (localtime t64))
         (mon (tm:mon lt)))
    (set-tm:sec  lt 0) (set-tm:min lt 0) (set-tm:hour lt 0) (set-tm:mday lt 1)
    (set-tm:mon  lt (if (= mon 11) 0 (+ mon 1)))
    (set-tm:year lt (if (= mon 11) (+ (tm:year lt) 1) (tm:year lt)))
    (car (mktime lt))))

(define (fr-next-day-start t64)
  (let* ((lt (localtime t64)))
    (set-tm:sec lt 0) (set-tm:min lt 0) (set-tm:hour lt 0)
    (set-tm:mday lt (+ (tm:mday lt) 1))
    (car (mktime lt))))

(define (fr-day-slices t-start t-end)
  (let loop ((t t-start) (acc '()))
    (if (>= t t-end)
        (reverse acc)
        (let ((next (min t-end (fr-next-day-start t))))
          (loop next (cons (cons t next) acc))))))

(define (fr-card-upcoming accounts t-start t-end currency)
  (let* ((all-accounts (fr-expand-accounts accounts))
         (slices       (fr-day-slices t-start t-end))
         (cum-hashes   (map (lambda (slice)
                              (gnc-sx-all-instantiate-cashflow-all t-start (cdr slice)))
                            slices))
         (prev-hashes  (cons (make-hash-table) (drop-right cum-hashes 1)))
         (hash-amt     (lambda (h acc)
                         (let ((raw (hash-ref h (gncAccountGetGUID acc) #f)))
                           (if (and raw (not (eq? raw 0)))
                               (gnc-numeric-to-double raw) 0.0))))
         (entries
          (apply append
                 (map (lambda (slice curr-h prev-h)
                        (let ((label (fr-fmt-date (cdr slice))))
                          (filter (lambda (x) (not (= (caddr x) 0.0)))
                                  (map (lambda (acc)
                                         (list label (xaccAccountGetName acc)
                                               (- (hash-amt curr-h acc) (hash-amt prev-h acc))))
                                       all-accounts))))
                      slices cum-hashes prev-hashes)))
         (fmt (lambda (n) (fr-fmt-money (abs n) currency))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Upcoming Transactions</span>"
     "</div>"
     (if (null? (or accounts '()))
         "<div class='empty'>Select accounts in<br>Options &rarr; Upcoming Transactions.</div>"
         (if (null? entries)
             "<div class='empty'>No scheduled transactions<br>found for the selected period.</div>"
             (apply string-append
                    (map (lambda (entry)
                           (let* ((label (car entry))
                                  (name  (cadr entry))
                                  (amt   (caddr entry))
                                  (neg?  (< amt 0)))
                             (string-append
                              "<div class='tx-row'>"
                              "<span class='tx-date'>" (gnc:html-string-sanitize label) "</span>"
                              "<span class='tx-desc'>" (fr-safe-str name 18) "</span>"
                              "<span class='tx-amt " (if neg? "neg" "pos") "'>"
                              (if neg? "&minus;" "+") (fmt amt) "</span>"
                              "</div>")))
                         entries))))
     "<div style='font-size:.68rem;color:var(--muted);margin-top:8px'>As of "
     (strftime "%b %-d, %Y" (localtime (current-time))) "</div>"
     "</div>")))

;;;============================================================
;;; CARD: Projected Balances
;;;============================================================

(define (fr-card-projected-balances accounts t-end currency)
  (let* ((now          (current-time))
         (all-accounts (fr-expand-accounts accounts))
         (current-bal  (fr-sum-balances-as-of accounts now))
         (range-end    (max (+ now 1) t-end))
         (display-end  (fr-display-range-end range-end))
         (slices       (fr-day-slices now range-end))
         (cum-hashes   (map (lambda (s)
                              (gnc-sx-all-instantiate-cashflow-all now (cdr s)))
                            slices))
         (prev-hashes  (cons (make-hash-table) (drop-right cum-hashes 1)))
         (hash-amt     (lambda (h a)
                         (let ((raw (hash-ref h (gncAccountGetGUID a) #f)))
                           (if (and raw (not (eq? raw 0)))
                               (gnc-numeric-to-double raw) 0.0))))
         (slice-end    (lambda (n)
                         (if (and (> n 0) (<= n (length slices)))
                             (cdr (list-ref slices (- n 1)))
                             range-end)))
         (actual-delta (lambda (t-start t-stop)
                         (fold
                          (lambda (a total)
                            (+ total
                               (fold
                                (lambda (split subtotal)
                                  (let* ((txn  (xaccSplitGetParent split))
                                         (date (xaccTransGetDate txn))
                                         (val  (gnc-numeric-to-double (xaccSplitGetValue split))))
                                    (if (and (> date t-start) (<= date t-stop))
                                        (+ subtotal val) subtotal)))
                                0.0
                                (xaccAccountGetSplitList a))))
                          0.0 all-accounts)))
         (actual-deltas (map (lambda (slice)
                               (actual-delta (car slice) (cdr slice)))
                             slices))
         (sched-deltas  (map (lambda (ch ph)
                               (- (fold (lambda (a total)
                                          (+ total (- (hash-amt ch a) (hash-amt ph a))))
                                        0.0 all-accounts)))
                             cum-hashes prev-hashes))
         (day-deltas   (map + actual-deltas sched-deltas))
         (running-bals
          (let loop ((ds day-deltas) (bal current-bal) (res '()))
            (if (null? ds)
                (list->vector (reverse res))
                (let ((nb (+ bal (car ds))))
                  (loop (cdr ds) nb (cons nb res))))))
         (bal-at  (lambda (n)
                    (let* ((idx (- n 1)) (len (vector-length running-bals)))
                      (cond ((< idx 0)   current-bal)
                            ((< idx len) (vector-ref running-bals idx))
                            (else        (if (> len 0)
                                            (vector-ref running-bals (- len 1))
                                            current-bal))))))
         (days-total (max 1 (vector-length running-bals)))
         (mid-day    (max 1 (inexact->exact (round (/ days-total 2.0)))))
         (mid-t      (fr-display-range-end (slice-end mid-day)))
         (bal-mid    (bal-at mid-day))
         (bal-end    (bal-at days-total))
         (fmt     (lambda (n) (fr-fmt-money n currency)))
         (n->s    (lambda (n) (number->string (inexact->exact (round n)))))
         (chart   (lambda ()
                    (let* ((pts  (list (cons 0 current-bal)
                                       (cons mid-day bal-mid)
                                       (cons days-total bal-end)))
                           (bals   (map cdr pts))
                           (b-min  (apply min bals)) (b-max (apply max bals))
                           (spread (max 1.0 (- b-max b-min)))
                           (y-min  (- b-min (* 0.12 spread)))
                           (y-max  (+ b-max (* 0.12 spread)))
                           (y-rng  (max 1.0 (- y-max y-min)))
                           (W 360) (H 110) (lpad 42) (rpad 18) (tpad 8) (bpad 18)
                           (cw (- W lpad rpad)) (ch (- H tpad bpad))
                           (xf (lambda (d) (+ lpad (* cw (/ d days-total)))))
                           (yf (lambda (b) (+ tpad (* ch (/ (- y-max b) y-rng)))))
                           (xy  (map (lambda (p) (cons (xf (car p)) (yf (cdr p)))) pts))
                           (line-d (apply string-append
                                          (map (lambda (pt i)
                                                 (string-append (if (= i 0) "M" "L")
                                                                (n->s (car pt)) "," (n->s (cdr pt)) " "))
                                               xy (iota (length xy)))))
                           (bot    (+ tpad ch))
                           (area-d (string-append line-d
                                                  "L" (n->s (caar (reverse xy))) "," (n->s bot) " "
                                                  "L" (n->s (caar xy))           "," (n->s bot) " Z"))
                           (yfmt   (lambda (b)
                                     (if (>= (abs b) 1000)
                                         (string-append "$" (n->s (/ b 1000)) "k")
                                         (string-append "$" (n->s b))))))
                      (string-append
                       "<svg viewBox='0 0 " (n->s W) " " (n->s H) "'"
                       " style='width:100%;display:block;margin-top:12px'"
                       " xmlns='http://www.w3.org/2000/svg'>"
                       "<defs><linearGradient id='pg' x1='0' y1='0' x2='0' y2='1'>"
                       "<stop offset='0%' stop-color='#2563eb' stop-opacity='0.18'/>"
                       "<stop offset='100%' stop-color='#2563eb' stop-opacity='0.01'/>"
                       "</linearGradient></defs>"
                       "<path d='" area-d "' fill='url(#pg)'/>"
                       "<path d='" line-d "' fill='none' stroke='#2563eb' stroke-width='2'"
                       " stroke-linejoin='round' stroke-linecap='round'/>"
                       (apply string-append
                              (map (lambda (pt)
                                     (string-append
                                      "<circle cx='" (n->s (car pt)) "' cy='" (n->s (cdr pt))
                                      "' r='3' fill='#2563eb' stroke='white' stroke-width='1.5'/>"))
                                   xy))
                       "<text x='" (n->s (- lpad 4)) "' y='" (n->s (+ tpad 4))
                       "' font-size='8' fill='#94a3b8' text-anchor='end'>" (yfmt y-max) "</text>"
                       "<text x='" (n->s (- lpad 4)) "' y='" (n->s (- (+ tpad ch) 1))
                       "' font-size='8' fill='#94a3b8' text-anchor='end'>" (yfmt y-min) "</text>"
                       "<text x='" (n->s (xf 0))  "' y='" (n->s (- H 2))
                       "' font-size='8' fill='#94a3b8' text-anchor='middle'>Today</text>"
                       "<text x='" (n->s (xf mid-day)) "' y='" (n->s (- H 2))
                       "' font-size='8' fill='#94a3b8' text-anchor='middle'>"
                       (fr-fmt-short-date mid-t) "</text>"
                       "<text x='" (n->s (xf days-total)) "' y='" (n->s (- H 2))
                       "' font-size='8' fill='#94a3b8' text-anchor='middle'>"
                       (fr-fmt-short-date display-end) "</text>"
                       "</svg>")))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Projected Balances</span>"
     "</div>"
     (if (null? all-accounts)
         "<div class='empty'>Select accounts in<br>Options &rarr; Projected Balances.</div>"
         (string-append
          "<div class='proj-grid'>"
          "<div class='proj-box'><div class='proj-lbl'>Today</div>"
          "<div class='proj-val'>" (fmt current-bal) "</div></div>"
          "<div class='proj-box'><div class='proj-lbl'>" (fr-fmt-short-date mid-t) "</div>"
          "<div class='proj-val'>" (fmt bal-mid) "</div></div>"
          "<div class='proj-box'><div class='proj-lbl'>" (fr-fmt-short-date display-end) "</div>"
          "<div class='proj-val'>" (fmt bal-end) "</div></div>"
          "</div>"
          (chart)
          "<div style='font-size:.68rem;color:var(--muted);margin-top:4px'>As of "
          (strftime "%b %-d, %Y" (localtime (current-time))) "</div>"))
     "</div>")))

;;;============================================================
;;; CARD: Budget vs Actual
;;;============================================================

(define (fr-budget-period-totals budget expense-accounts t-start t-end)
  (if (not budget)
      (list 0.0 0.0 "")
      (let* ((n-periods  (gnc-budget-get-num-periods budget))
             (leaf-accts (fr-leaf-accounts expense-accounts)))
        (let ((result
               (fold
                (lambda (period acc)
                  (let ((p-start (gnc-budget-get-period-start-date budget period)))
                    (if (and (>= p-start t-start) (< p-start t-end))
                        (let ((p-planned (fold + 0.0
                                               (map (lambda (a)
                                                      (gnc-numeric-to-double
                                                       (gnc-budget-get-account-period-value budget a period)))
                                                    leaf-accts)))
                              (p-actual  (fold + 0.0
                                               (map (lambda (a)
                                                      (gnc-numeric-to-double
                                                       (gnc-budget-get-account-period-actual-value budget a period)))
                                                    leaf-accts)))
                              (lbl       (strftime "%b %Y" (localtime p-start))))
                          (list (+ (car acc) p-planned)
                                (+ (cadr acc) p-actual)
                                (append (caddr acc) (list lbl))))
                        acc)))
                (list 0.0 0.0 '())
                (iota n-periods))))
          (list (car result)
                (cadr result)
                (let ((labels (caddr result)))
                  (cond ((null? labels)        "No matching periods")
                        ((= (length labels) 1) (car labels))
                        (else (string-append (car labels) " – " (car (reverse labels)))))))))))

(define (fr-card-budget-vs-actual budget expense-accounts t-start t-end currency)
  (let* ((fmt     (lambda (n) (fr-fmt-money n currency)))
         (totals  (fr-budget-period-totals budget expense-accounts t-start t-end))
         (planned (car totals))
         (actual  (abs (cadr totals)))
         (periods (caddr totals))
         (diff    (- planned actual))
         (over?   (< diff 0))
         (pct-s   (if (> planned 0)
                      (number->string
                       (inexact->exact (floor (min 100.0 (* 100.0 (/ actual planned))))))
                      "0"))
         (bar-col (cond ((> actual planned)         "red")
                        ((> actual (* planned 0.8)) "yellow")
                        (else                       "green"))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Budget vs Actual</span>"
     "</div>"
     (if (not budget)
         "<div class='empty'>Select a budget in<br>Options &rarr; Budget to begin.</div>"
         (string-append
          "<div class='flow-grid' style='margin-bottom:14px'>"
          "<div class='flow-box'><div class='flow-lbl'>Planned</div>"
          "<div class='flow-val neu'>" (fmt planned) "</div></div>"
          "<div class='flow-box'><div class='flow-lbl'>Actual</div>"
          "<div class='flow-val " (if over? "neg" "pos") "'>" (fmt actual) "</div></div>"
          "<div class='flow-box'><div class='flow-lbl'>Remaining</div>"
          "<div class='flow-val " (if over? "neg" "pos") "'>"
          (if over? "&minus;" "") (fmt (abs diff)) "</div></div>"
          "</div>"
          "<div class='pb-wrap'><div class='pb-bg'>"
          "<div class='pb-fill " bar-col "' style='width:" pct-s "%'></div></div></div>"
          "<div style='display:flex;justify-content:space-between;font-size:.7rem;color:var(--muted);margin-top:4px'>"
          "<span>" pct-s "% spent</span>"
          (if over?
              "<span style='color:var(--neg);font-weight:700'>Over budget</span>"
              "<span></span>")
          "</div>"
          "<div style='font-size:.68rem;color:var(--muted);margin-top:8px'>"
          "Periods: " (gnc:html-string-sanitize periods) "</div>"))
     "</div>")))

;;;============================================================
;;; CARD: Highest Spending Categories
;;;============================================================

(define fr-cat-colors
  '("#2563eb" "#16a34a" "#d97706" "#7c3aed" "#dc2626"))

(define (fr-card-spending-categories expense-accounts t-start t-end currency period-label)
  (let* ((data
          (filter (lambda (x) (> (cdr x) 0.001))
                  (map (lambda (acc)
                         (cons (xaccAccountGetName acc)
                               (abs (fr-sum-splits (list acc) t-start t-end))))
                       (fr-leaf-accounts expense-accounts))))
         (sorted  (sort data (lambda (a b) (> (cdr a) (cdr b)))))
         (top12   (fr-take sorted 12))
         (max-val (if (null? top12) 1.0 (cdar top12)))
         (fmt     (lambda (n) (fr-fmt-money n currency))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Highest Spending</span>"
     "</div>"
     (if (null? top12)
         "<div class='empty'>No expense data for the selected period.</div>"
         (apply string-append
                (map (lambda (item rank color)
                       (let* ((pct   (if (> max-val 0) (* 100.0 (/ (cdr item) max-val)) 0.0))
                              (pct-s (number->string (inexact->exact (floor pct)))))
                         (string-append
                          "<div class='cat-row'>"
                          "<div class='cat-rank' style='background:" color "'>"
                          (number->string rank) "</div>"
                          "<div class='cat-name'>" (fr-safe-str (car item) 18) "</div>"
                          "<div class='cat-bar'><div class='cat-bar-bg'>"
                          "<div class='cat-bar-fill' style='width:" pct-s "%;background:" color "'>"
                          "</div></div></div>"
                          "<div class='cat-amt'>" (fmt (cdr item)) "</div>"
                          "</div>")))
                     top12 '(1 2 3 4 5) fr-cat-colors)))
     "<div style='font-size:.68rem;color:var(--muted);margin-top:8px'>"
     (gnc:html-string-sanitize period-label) "</div>"
     "</div>")))

;;;============================================================
;;; MAIN RENDERER
;;;============================================================

(define (fr-renderer report-obj)
  (let* ((options (gnc:report-options report-obj))
         (db      (gnc:optiondb options))

         (display-name (let ((v (gnc-optiondb-lookup-value db gnc:pagename-general
                                                           gnc:optname-reportname)))
                         (if (and v (string? v) (> (string-length v) 0)) v report-name)))

         (t-start (fr-safe-date db tab-general opt-start-date))
         (t-end   (fr-safe-date db tab-general opt-end-date))
         (period-label (string-append (fr-fmt-date t-start) " to " (fr-fmt-date t-end)))

         (nw-assets       (gnc-optiondb-lookup-value db tab-networth opt-nw-assets))
         (nw-liabs        (gnc-optiondb-lookup-value db tab-networth opt-nw-liabs))
         (cf-accounts     (gnc-optiondb-lookup-value db tab-cashflow opt-cf-accounts))
         (ef-liquid       (gnc-optiondb-lookup-value db tab-emergency opt-ef-liquid))
         (ef-expenses     (gnc-optiondb-lookup-value db tab-emergency opt-ef-expenses))
         (ef-target       (gnc-optiondb-lookup-value db tab-emergency opt-ef-target))
         (ef-mode         (gnc-optiondb-lookup-value db tab-emergency opt-ef-mode))
         (ef-goal         (gnc-optiondb-lookup-value db tab-emergency opt-ef-goal))
         (acct-list       (gnc-optiondb-lookup-value db tab-accounts opt-acct-list))
         (upcoming-accts  (gnc-optiondb-lookup-value db tab-upcoming (N_ "Accounts")))
         (upcoming-period (gnc-optiondb-lookup-value db tab-upcoming opt-upcoming-period))
         (proj-accounts   (gnc-optiondb-lookup-value db tab-projected (N_ "Accounts")))
         (upcoming-t-end  (let ((now (current-time)))
                            (cond
                             ((eq? upcoming-period 'end-this-month) (fr-next-month-start now))
                             ((eq? upcoming-period 'end-next-month) (fr-next-month-start (fr-next-month-start now)))
                             ((eq? upcoming-period 'days-30)  (+ now (* 30  24 3600)))
                             ((eq? upcoming-period 'days-60)  (+ now (* 60  24 3600)))
                             ((eq? upcoming-period 'days-90)  (+ now (* 90  24 3600)))
                             ((eq? upcoming-period 'months-6) (+ now (* 182 24 3600)))
                             (else (fr-next-month-start (fr-next-month-start now))))))
         (budget          (gnc-optiondb-lookup-value db tab-budget opt-budget))
         (budget-expenses (gnc-optiondb-lookup-value db tab-budget opt-budget-expenses))

         (debt-accounts (gnc-optiondb-lookup-value db tab-debt opt-debt-accounts))
         (debt-strategy (or (gnc-optiondb-lookup-value db tab-debt opt-debt-strategy) 'avalanche))
         (debt-extra    (exact->inexact
                         (or (gnc-optiondb-lookup-value db tab-debt opt-debt-extra) 0)))

         (currency
          (cond ((and nw-assets   (not (null? nw-assets)))   (xaccAccountGetCommodity (car nw-assets)))
                ((and acct-list   (not (null? acct-list)))   (xaccAccountGetCommodity (car acct-list)))
                ((and ef-liquid   (not (null? ef-liquid)))   (xaccAccountGetCommodity (car ef-liquid)))
                (else (gnc-default-report-currency))))

         (liquid-total          (fr-sum-balances ef-liquid))
         (period-secs           (max 1 (- t-end t-start)))
         (period-months         (/ period-secs (* 30.0 24 3600)))
         (total-period-expenses (abs (fr-sum-splits ef-expenses t-start t-end)))
         (monthly-exp           (if (> period-months 0) (/ total-period-expenses period-months) 0.0))
         (inflow                (fr-sum-inflow  cf-accounts t-start t-end))
         (outflow               (fr-sum-outflow cf-accounts t-start t-end))

         (document (gnc:make-html-document)))

    (gnc:html-document-add-object!
     document
     (gnc:make-html-text
      (string-append
       fr-css

       "<div class='fr-header'>"
       "<div>"
       "<h1>" (gnc:html-string-sanitize display-name) "</h1>"
       "<span class='period'>Personal Finance Dashboard</span>"
       "</div>"
       "<span class='pill info'>" (gnc:html-string-sanitize period-label) "</span>"
       "</div>"

       ;; ── Row 1: Budget vs Actual · Emergency Fund ─────────────
       "<div class='fr-grid-2'>"
       (fr-card-budget-vs-actual budget budget-expenses t-start t-end currency)
       (fr-card-emergency-fund liquid-total monthly-exp
                               (or ef-target 6) ef-mode (or ef-goal 10000) currency)
       "</div>"

       ;; ── Debt Repayment (full-width, spaced to match grid rows) ──
       "<div class='fr-gap'>"
       (fr-card-debt debt-accounts debt-strategy debt-extra
                     currency (current-time))
       "</div>"

       "<div class='fr-grid-2'>"
       (fr-card-cash-flow inflow outflow currency period-label)
       (fr-card-net-worth nw-assets nw-liabs currency)
       "</div>"

       "<div class='fr-grid-2'>"
       (fr-card-account-balances acct-list)
       (fr-card-projected-balances proj-accounts upcoming-t-end currency)
       "</div>"

       "<div class='fr-grid-2'>"
       (fr-card-upcoming upcoming-accts (current-time) upcoming-t-end currency)
       (fr-card-spending-categories budget-expenses t-start t-end currency period-label)
       "</div>")))

    document))

;;;============================================================
;;; REPORT REGISTRATION
;;;============================================================

(gnc:define-report
 'version         1
 'name            report-name
 'report-guid     report-guid
 'menu-path       (list gnc:menuname-budget)
 'options-generator fr-options-generator
 'renderer          fr-renderer)
