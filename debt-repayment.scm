;; -*-scheme-*-
;;;; debt-repayment.scm — Debt Repayment Planner
;;
;; Compatible: GnuCash 5.14 (Windows) and 5.15+ (macOS). Read-only.
;;
;; Installation
;; ─────────────
;;   macOS  : ~/Library/Application Support/GnuCash/financial-radar/
;;   Windows: %APPDATA%\GnuCash\financial-radar\
;;   Linux  : ~/.local/share/gnucash/financial-radar/
;;
;; In config-user.scm add:
;;   (load (gnc-build-userdata-path "financial-radar/debt-repayment.scm"))
;;
;; Restart GnuCash → Reports > Budget > Debt Repayment Planner
;;
;; Debt assumptions are read from account Notes.  Open each liability or
;; credit account in GnuCash and add key=value lines to its Notes field:
;;   apr=28.49
;;   min-payment=100
;;   priority=1   (optional; lower number = higher priority)

(define-module (gnucash reports debt-repayment-planner)
  #:use-module (gnucash engine)
  #:use-module (gnucash utilities)
  #:use-module (gnucash core-utils)
  #:use-module (gnucash app-utils)
  #:use-module (gnucash options)
  #:use-module (gnucash report)
  #:use-module (gnucash html)
  #:use-module (srfi srfi-1))

;;;============================================================
;;; CONSTANTS
;;;============================================================

(define dp-report-name "Debt Repayment Planner")
(define dp-report-guid "b9c8d7e6-f5a4-3210-fedc-ba9876543210")

(define dp-tab-debts    (N_ "Debts"))
(define dp-tab-strategy (N_ "Strategy"))
(define dp-tab-display  (N_ "Display"))

(define dp-opt-accounts    (N_ "Debt Accounts"))
(define dp-opt-strategy    (N_ "Strategy"))
(define dp-opt-extra       (N_ "Extra Monthly Payment"))
(define dp-opt-max-months  (N_ "Max Projection Months"))
(define dp-opt-show-detail (N_ "Show Account Detail Table"))
(define dp-opt-show-sched  (N_ "Show Monthly Schedule"))

;;;============================================================
;;; OPTIONS GENERATOR
;;; Uses gnc-new-optiondb + gnc-register-* (GnuCash 5.x C++ API).
;;;============================================================

(define (dp-options-generator)
  (let ((options (gnc-new-optiondb)))

    ;; ── Debts tab ─────────────────────────────────────────────────────
    ;; Account multi-select: pick your liability/credit accounts
    (gnc-register-account-list-option options
      dp-tab-debts dp-opt-accounts "a"
      (N_ "Liability and credit card accounts to include in the payoff plan.")
      '())

    ;; ── Strategy tab ──────────────────────────────────────────────────
    (gnc-register-multichoice-option options
      dp-tab-strategy dp-opt-strategy "a"
      (N_ "Payoff strategy to apply.")
      "avalanche"
      (list (vector 'minimum-only    (N_ "Minimum Only"))
            (vector 'snowball        (N_ "Snowball — lowest balance first"))
            (vector 'avalanche       (N_ "Avalanche — highest APR first"))
            (vector 'custom-priority (N_ "Custom Priority — Priority column"))))

    ;; Extra dollars on top of all minimums each month
    (gnc-register-number-range-option options
      dp-tab-strategy dp-opt-extra "b"
      (N_ "Extra dollars to pay on top of all minimums each month.")
      0 0 100000 10)

    ;; Safety cap so the simulation never runs unbounded
    (gnc-register-number-range-option options
      dp-tab-strategy dp-opt-max-months "c"
      (N_ "Maximum months to project (safety cap). Default 600 = 50 years.")
      600 1 1200 1)

    ;; ── Display tab ───────────────────────────────────────────────────
    (gnc-register-simple-boolean-option options
      dp-tab-display dp-opt-show-detail "a"
      (N_ "Show per-debt payoff order table.")
      #t)

    (gnc-register-simple-boolean-option options
      dp-tab-display dp-opt-show-sched "b"
      (N_ "Show month-by-month schedule (one row per account per month, capped at 24 months).")
      #f)

    options))

;;;============================================================
;;; STRING UTILITIES
;;;============================================================

;; Split str on delimiter char, returning a list of substrings.
(define (dp-string-split str delim)
  (let loop ((chars (string->list str)) (cur '()) (acc '()))
    (cond
      ((null? chars)
       (reverse (cons (list->string (reverse cur)) acc)))
      ((char=? (car chars) delim)
       (loop (cdr chars) '() (cons (list->string (reverse cur)) acc)))
      (else
       (loop (cdr chars) (cons (car chars) cur) acc)))))

;; Trim leading/trailing whitespace from a string.
(define (dp-trim str)
  (let* ((lst (string->list str))
         (l   (let lp ((c lst))
                (if (and (pair? c) (char-whitespace? (car c))) (lp (cdr c)) c)))
         (r   (reverse (let lp ((c (reverse l)))
                         (if (and (pair? c) (char-whitespace? (car c))) (lp (cdr c)) c)))))
    (list->string r)))

;; Parse a non-negative decimal string; return default on failure.
(define (dp-parse-double str default)
  (let ((n (string->number (dp-trim str))))
    (if (and n (real? n) (>= n 0)) (exact->inexact n) default)))

;; Parse a positive integer string; return default on failure.
(define (dp-parse-int str default)
  (let ((n (string->number (dp-trim str))))
    (if (and n (integer? n) (> n 0)) (inexact->exact n) default)))

;;;============================================================
;;; ACCOUNT NOTE PARSING (key=value)
;;; Reads debt assumption metadata stored in GnuCash account
;;; notes via xaccAccountGetNotes.  Recognised fields:
;;;   apr=<pct>           e.g. apr=28.49
;;;   min-payment=<amt>   e.g. min-payment=125
;;;   priority=<int>      e.g. priority=2
;;;============================================================

;; Parse key=value lines from a raw string.
;; Returns alist of (lowercase-trimmed-key . trimmed-value).
;; Blank lines and lines starting with # or ; are skipped.
;; Lines without an '=' sign are ignored.
(define (dp-parse-note-kv text)
  (filter-map
   (lambda (raw-line)
     (let ((line (dp-trim raw-line)))
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
                    (cons (string-downcase
                           (dp-trim (list->string (reverse key-acc))))
                          (dp-trim (list->string (reverse val-acc))))
                    #f))
               ((and (not eq-seen) (char=? (car chars) #\=))
                (loop (cdr chars) key-acc #t val-acc))
               (eq-seen
                (loop (cdr chars) key-acc #t (cons (car chars) val-acc)))
               (else
                (loop (cdr chars) (cons (car chars) key-acc) #f val-acc)))))))
   (dp-string-split text #\newline)))

;; Read account notes and build an assumption alist from them.
;; Returns an alist with keys apr, min-payment, priority, or #f
;; if no valid APR is found.  Invalid field values warn via add-warn! but
;; do not prevent the other fields from being used.
(define (dp-note-assumption acc add-warn!)
  (let* ((name   (dp-trim (xaccAccountGetName acc)))
         (kv     (dp-parse-note-kv (or (xaccAccountGetNotes acc) "")))
         (apr-e  (assoc "apr" kv))
         (min-e  (assoc "min-payment" kv))
         (pri-e  (assoc "priority" kv)))
    (if (not apr-e)
        #f
        (let ((apr (dp-parse-double (cdr apr-e) -1.0)))
          (if (< apr 0.0)
              (begin
                (add-warn!
                 (string-append
                  "Account \"" (gnc:html-string-sanitize name)
                  "\": note field \"apr\" is not a valid number (\""
                  (gnc:html-string-sanitize (cdr apr-e)) "\")"))
                #f)
              (let* ((minp (if min-e
                               (let ((v (dp-parse-double (cdr min-e) -1.0)))
                                 (if (>= v 0.0)
                                     v
                                     (begin
                                       (add-warn!
                                        (string-append
                                         "Account \"" (gnc:html-string-sanitize name)
                                         "\": note field \"min-payment\" is not a valid number (\""
                                         (gnc:html-string-sanitize (cdr min-e)) "\"); using 0"))
                                       0.0)))
                               0.0))
                     (pri  (if pri-e
                               (let ((v (dp-parse-int (cdr pri-e) 0)))
                                 (if (> v 0)
                                     v
                                     (begin
                                       (add-warn!
                                        (string-append
                                         "Account \"" (gnc:html-string-sanitize name)
                                         "\": note field \"priority\" must be a positive integer (\""
                                         (gnc:html-string-sanitize (cdr pri-e)) "\"); using 99"))
                                       99)))
                               99)))
                (list (cons 'name     name)
                      (cons 'apr      apr)
                      (cons 'min      minp)
                      (cons 'priority pri))))))))

;; Return the first n elements of lst (safe — stops at end of list).
(define (dp-take lst n)
  (if (or (null? lst) (= n 0)) '()
      (cons (car lst) (dp-take (cdr lst) (- n 1)))))

;;;============================================================
;;; BALANCE EXTRACTION
;;; Reads live account balances from the GnuCash book.
;;; Treats liabilities as positive amounts for display.
;;; Never writes to accounts.
;;;============================================================

;; Return the absolute balance of an account as a Scheme double.
;; Liability/credit accounts report negative balances in GnuCash;
;; abs() gives us the amount owed as a positive number.
(define (dp-account-balance acc)
  (abs (gnc-numeric-to-double (xaccAccountGetBalance acc))))

;;;============================================================
;;; DEBT BUILDING + WARNINGS
;;; Reads assumptions from account notes only.
;;; Collects: debts to simulate, and warning categories.
;;;============================================================

;; Returns: (debts missing-assumptions non-amortizing note-warnings)
;;
;;   debts               : list of (name start-bal monthly-rate min-pay priority apr%)
;;   missing-assumptions : list of account names with no apr= in their notes
;;   non-amortizing      : list of (name min-pay monthly-interest apr%)
;;                         — debts where min-pay <= monthly interest at start
;;   note-warnings       : list of strings for invalid account-note field values
(define (dp-build-all accounts)
  (let* ((debts '())
         (missing-assumptions '())
         (note-warnings '())
         (add-note-warn! (lambda (msg)
                           (set! note-warnings (append note-warnings (list msg)))))

         ;; Process each selected account
         (dummy
          (for-each
           (lambda (acc)
             (let* ((name (dp-trim (xaccAccountGetName acc)))
                    (bal  (dp-account-balance acc))
                    (a    (dp-note-assumption acc add-note-warn!)))
               (cond
                 (a
                  (when (> bal 0.001)
                    (let* ((apr  (cdr (assq 'apr  a)))
                           (minp (cdr (assq 'min  a)))
                           (pri  (cdr (assq 'priority a)))
                           (rate (/ apr 100.0 12.0)))
                      (set! debts
                            (append debts
                                    (list (list name bal rate minp pri apr)))))))
                 (else
                  (set! missing-assumptions (cons name missing-assumptions))))))
           accounts))

         ;; Non-amortizing: min payment does not exceed monthly interest at start balance.
         ;; We still include them in simulation (extra payments may save them),
         ;; but we warn the user.
         (non-amortizing
          (filter-map
           (lambda (d)
             (let* ((name (list-ref d 0))
                    (bal  (list-ref d 1))
                    (rate (list-ref d 2))
                    (minp (list-ref d 3))
                    (apr  (list-ref d 5))
                    (intr (* bal rate)))
               (if (<= minp intr)
                   (list name minp intr apr)
                   #f)))
           debts)))

    (list debts missing-assumptions non-amortizing note-warnings)))

;;;============================================================
;;; PAYOFF SIMULATION
;;; Month-by-month simulation. Modifies mutable state vectors.
;;; Returns structured results for rendering. Never touches
;;; GnuCash account data — operates only on extracted balances.
;;;============================================================

;; debt state vector indices
(define dp-sv-NAME  0)
(define dp-sv-BAL   1)
(define dp-sv-RATE  2)
(define dp-sv-MINP  3)
(define dp-sv-PRI   4)
(define dp-sv-APR   5)
(define dp-sv-PAID  6)   ; #f or month-number when paid off
(define dp-sv-CINT  7)   ; cumulative interest paid
(define dp-sv-SBAL  8)   ; original starting balance (immutable after init)

;; Simulate month-by-month payoff.
;;
;; debts    : list of (name start-bal monthly-rate min-pay priority apr%)
;; strategy : symbol — minimum-only | snowball | avalanche | custom-priority
;; extra    : double — extra dollars per month on top of minimums
;; max-months : integer — safety cap
;;
;; Returns:
;;   (total-months total-interest payoff-order debt-results schedule capped?)
;;
;;   debt-results : list of (name start-bal apr% min-pay paid-month cum-interest)
;;                  sorted by paid-month ascending
;;   schedule     : list of (month-num . rows)
;;                  row = (name start-bal-this-month interest payment end-bal)
(define (dp-simulate debts strategy extra max-months)
  (if (null? debts)
      (list 0 0.0 '() '() '() #f)
      (let* ((n     (length debts))
             ;; Build mutable state vectors
             (sv    (list->vector
                     (map (lambda (d)
                            (vector (list-ref d 0)   ; 0 NAME
                                    (list-ref d 1)   ; 1 BAL  (current)
                                    (list-ref d 2)   ; 2 RATE
                                    (list-ref d 3)   ; 3 MINP
                                    (list-ref d 4)   ; 4 PRI
                                    (list-ref d 5)   ; 5 APR%
                                    #f               ; 6 PAID month
                                    0.0              ; 7 CINT cumulative interest
                                    (list-ref d 1))) ; 8 SBAL starting balance
                          debts)))
             (total-int  0.0)
             (payoff-ord '())
             (schedule   '()))

        ;; State accessors
        (define (sv-ref field i) (vector-ref (vector-ref sv i) field))
        (define (sv-set! field i val) (vector-set! (vector-ref sv i) field val))
        (define (paid? i) (sv-ref dp-sv-PAID i))
        (define (all-paid?) (every paid? (iota n)))

        ;; Return index of the debt that should receive the extra payment this month.
        ;; Selects from live (unpaid) debts according to strategy.
        (define (get-target)
          (let ((live (filter (lambda (i) (not (paid? i))) (iota n))))
            (if (null? live) -1
                (car (sort live
                           (lambda (i j)
                             (cond
                               ((eq? strategy 'snowball)
                                (< (sv-ref dp-sv-SBAL i) (sv-ref dp-sv-SBAL j)))
                               ((eq? strategy 'avalanche)
                                (> (sv-ref dp-sv-RATE i) (sv-ref dp-sv-RATE j)))
                               ((eq? strategy 'custom-priority)
                                (< (sv-ref dp-sv-PRI i) (sv-ref dp-sv-PRI j)))
                               (else (< i j)))))))))

        ;; Sum minimum payments from already-paid debts — these roll into extra pool.
        (define (freed-min)
          (fold (lambda (i s)
                  (if (paid? i) (+ s (sv-ref dp-sv-MINP i)) s))
                0.0 (iota n)))

        ;; Simulate one month. Captures per-account rows for the schedule.
        (define (do-month! month-num)
          (let* ((tgt   (if (eq? strategy 'minimum-only) -1 (get-target)))
                 ;; Extra pool = user extra + freed minimums from paid-off debts
                 (xtra  (if (eq? strategy 'minimum-only)
                            0.0
                            (+ extra (freed-min))))
                 (rows  '()))

            (let dloop ((i 0))
              (when (< i n)
                (unless (paid? i)
                  (let* ((start-bal (sv-ref dp-sv-BAL  i))   ; balance before interest
                         (rate      (sv-ref dp-sv-RATE i))
                         (minp      (sv-ref dp-sv-MINP i))
                         ;; Monthly interest charge
                         (interest  (* start-bal rate))
                         (bal-after-int (+ start-bal interest))
                         ;; Extra payment only goes to the target debt
                         (this-extra (if (= i tgt) xtra 0.0))
                         ;; Payment = minimum + any extra, capped at total owed
                         (payment    (min bal-after-int (+ minp this-extra)))
                         ;; Ending balance (floor at zero)
                         (end-bal    (max 0.0 (- bal-after-int payment))))

                    ;; Update mutable state
                    (sv-set! dp-sv-BAL  i end-bal)
                    (sv-set! dp-sv-CINT i (+ (sv-ref dp-sv-CINT i) interest))
                    (set! total-int (+ total-int interest))

                    ;; Record this account's row for the monthly schedule
                    (set! rows (cons (list (sv-ref dp-sv-NAME i)
                                          start-bal interest payment end-bal)
                                     rows))

                    ;; Mark debt as paid when balance reaches zero
                    (when (< end-bal 0.001)
                      (sv-set! dp-sv-PAID i month-num)
                      (set! payoff-ord (append payoff-ord
                                               (list (sv-ref dp-sv-NAME i)))))))
                (dloop (+ i 1))))

            ;; Prepend month entry (rows are reversed; caller reverses schedule)
            (set! schedule (cons (cons month-num (reverse rows)) schedule))))

        ;; Build final debt-results sorted by strategy targeting order so the
        ;; table reflects how each method thinks, not just when debts finish.
        ;; Snowball: asc start-bal  Avalanche: desc APR  Custom: asc priority
        ;; Minimum-only: asc payoff month (no targeting order to express)
        ;; row: (name start-bal apr% min-pay paid-month cum-interest priority)
        (define (build-debt-results cap-month)
          (let ((raw (map (lambda (i)
                            (list (sv-ref dp-sv-NAME  i)
                                  (sv-ref dp-sv-SBAL  i)
                                  (sv-ref dp-sv-APR   i)
                                  (sv-ref dp-sv-MINP  i)
                                  (or (paid? i) cap-month)
                                  (sv-ref dp-sv-CINT  i)
                                  (sv-ref dp-sv-PRI   i)))
                          (iota n))))
            (sort raw
                  (cond
                    ((eq? strategy 'snowball)
                     (lambda (a b) (< (list-ref a 1) (list-ref b 1))))
                    ((eq? strategy 'avalanche)
                     (lambda (a b) (> (list-ref a 2) (list-ref b 2))))
                    ((eq? strategy 'custom-priority)
                     (lambda (a b) (< (list-ref a 6) (list-ref b 6))))
                    (else
                     (lambda (a b) (< (list-ref a 4) (list-ref b 4))))))))

        ;; Run the simulation
        (let loop ((month 1))
          (cond
            ((all-paid?)
             (list (- month 1)
                   total-int
                   payoff-ord
                   (build-debt-results (- month 1))
                   (reverse schedule)
                   #f))
            ((> month max-months)
             (list max-months
                   total-int
                   payoff-ord
                   (build-debt-results max-months)
                   (reverse schedule)
                   #t))
            (else
             (do-month! month)
             (if (all-paid?)
                 (list month
                       total-int
                       payoff-ord
                       (build-debt-results month)
                       (reverse schedule)
                       #f)
                 (loop (+ month 1)))))))))

;;;============================================================
;;; FORMATTING UTILITIES
;;;============================================================

;; Format a double as a currency string using GnuCash's formatter.
(define (dp-fmt-money amount currency)
  (gnc:monetary->string
   (gnc:make-gnc-monetary
    currency
    (double-to-gnc-numeric
     (if (and (number? amount) (finite? amount)) amount 0.0)
     100 GNC-RND-ROUND))))

;; Format a percentage to 2 decimal places (e.g. 28.49 → "28.49%").
(define (dp-fmt-pct pct)
  (let* ((v       (if (and (number? pct) (finite? pct)) (exact->inexact pct) 0.0))
         (rounded (inexact->exact (round (* v 100))))
         (whole   (quotient rounded 100))
         (frac    (abs (remainder rounded 100))))
    (string-append (number->string whole) "."
                   (if (< frac 10)
                       (string-append "0" (number->string frac))
                       (number->string frac))
                   "%")))

(define dp-month-abbrevs
  '#("Jan" "Feb" "Mar" "Apr" "May" "Jun"
     "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

;; Format a month offset from t64 without calling localtime on the future
;; timestamp. Some Windows builds only support 32-bit time_t in localtime.
(define (dp-months-ahead t64 n)
  (let* ((tm  (localtime t64))
         (tot (+ (tm:mon tm) n))
         (yr  (+ (tm:year tm) 1900 (quotient tot 12)))
         (mo  (remainder tot 12)))
    (string-append (vector-ref dp-month-abbrevs mo) " " (number->string yr))))

;; Human-readable duration from a month count.
(define (dp-months->str n)
  (let* ((yr (quotient n 12))
         (mo (remainder n 12)))
    (cond ((and (= yr 0) (= mo 0)) "< 1 mo")
          ((= yr 0) (string-append (number->string mo) " mo"))
          ((= mo 0) (string-append (number->string yr) " yr"))
          (else (string-append (number->string yr) " yr "
                               (number->string mo) " mo")))))

;; Human label for a strategy symbol.
(define (dp-strategy-label s)
  (cond ((eq? s 'snowball)        "Snowball")
        ((eq? s 'avalanche)       "Avalanche")
        ((eq? s 'custom-priority) "Custom Priority")
        (else                     "Minimum Only")))

;;;============================================================
;;; CSS — GnuCash 5.14 / WebKitGTK 2.38-2.40 compatible
;;; Table + float layout only. No grid, flex, or CSS variables.
;;; Triple-gradient cascade for progress bars (WebKit prefix).
;;;============================================================

(define dp-css
"<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: #f1f5f9; color: #1e293b;
  padding: 24px; font-size: 14px; line-height: 1.5;
}
.dp-header {
  display: table; width: 100%; border-collapse: collapse; margin-bottom: 20px;
}
.dp-header > div { display: table-cell; vertical-align: baseline; }
.dp-header > span {
  display: table-cell; width: 1px; text-align: right;
  vertical-align: middle; white-space: nowrap; padding-left: 16px;
}
.dp-header h1 { font-size: 1.35rem; font-weight: 800; color: #1e293b; letter-spacing: -.02em; }
.dp-header .sub { font-size: .76rem; color: #94a3b8; margin-left: 10px; }
.card {
  background: #fff; border-radius: 12px;
  box-shadow: 0 1px 3px rgba(0,0,0,.07), 0 4px 14px rgba(0,0,0,.05);
  padding: 20px; margin-bottom: 16px; overflow: hidden;
}
.card-hdr { display: table; width: 100%; border-collapse: collapse; margin-bottom: 14px; }
.card-title {
  display: table-cell; font-size: .68rem; font-weight: 700;
  text-transform: uppercase; letter-spacing: .09em; color: #94a3b8; vertical-align: middle;
}
.card-badge { display: table-cell; width: 1px; text-align: right; vertical-align: middle; white-space: nowrap; }
/* 3-column stat grid using floats */
.stat-grid { overflow: hidden; margin-bottom: 10px; }
.stat-box {
  float: left; width: 31%; margin-right: 3.5%;
  background: #f8fafc; border-radius: 8px; padding: 12px 10px; text-align: center;
}
.stat-box:nth-child(3n) { margin-right: 0; }
.stat-box:nth-child(3n+1):nth-last-child(-n+3),
.stat-box:nth-child(3n+1):nth-last-child(-n+3) ~ .stat-box { margin-bottom: 0; }
.stat-lbl { font-size: .63rem; text-transform: uppercase; letter-spacing: .06em; color: #94a3b8; margin-bottom: 5px; }
.stat-val { font-size: 1.05rem; font-weight: 800; color: #1e293b; white-space: nowrap; overflow: hidden; }
.stat-val.neg   { color: #dc2626; }
.stat-val.warn  { color: #d97706; }
.stat-val.acc   { color: #2563eb; }
.stat-val.pos   { color: #16a34a; }
.stat-val.muted { color: #94a3b8; }
.pill {
  display: inline-block; padding: 2px 10px; border-radius: 99px;
  font-size: .68rem; font-weight: 700; white-space: nowrap;
}
.pill.good  { background: #dcfce7; color: #16a34a; }
.pill.warn  { background: #fef3c7; color: #d97706; }
.pill.bad   { background: #fee2e2; color: #dc2626; }
.pill.info  { background: #dbeafe; color: #2563eb; }
.pill.muted { background: #e2e8f0; color: #475569; }
.pb-wrap { margin: 10px 0 4px; }
.pb-bg { height: 8px; background: #e2e8f0; border-radius: 99px; overflow: hidden; }
.pb-fill { height: 100%; border-radius: 99px; }
.pb-fill.green  { background: #16a34a; background: -webkit-linear-gradient(left,#16a34a,#4ade80); background: linear-gradient(90deg,#16a34a,#4ade80); }
.pb-fill.yellow { background: #d97706; background: -webkit-linear-gradient(left,#d97706,#fbbf24); background: linear-gradient(90deg,#d97706,#fbbf24); }
.pb-fill.red    { background: #dc2626; background: -webkit-linear-gradient(left,#dc2626,#f87171); background: linear-gradient(90deg,#dc2626,#f87171); }
/* Data tables */
.dp-table { width: 100%; border-collapse: collapse; font-size: .8rem; }
.dp-table th {
  text-align: left; font-size: .64rem; font-weight: 700;
  text-transform: uppercase; letter-spacing: .06em; color: #94a3b8;
  padding: 4px 8px 8px 0; border-bottom: 2px solid #e2e8f0;
}
.dp-table th.r { text-align: right; }
.dp-table td { padding: 8px 8px 8px 0; border-bottom: 1px solid #f1f5f9; color: #1e293b; vertical-align: middle; }
.dp-table td.r { text-align: right; font-weight: 600; }
.dp-table tr:last-child td { border-bottom: none; }
.dp-table .c-red { color: #dc2626; font-weight: 600; }
.dp-table .c-grn { color: #16a34a; font-weight: 600; }
/* Monthly schedule — slightly smaller font to fit more columns */
.sched-table { width: 100%; border-collapse: collapse; font-size: .76rem; }
.sched-table th {
  font-size: .62rem; font-weight: 700; text-transform: uppercase;
  letter-spacing: .05em; color: #94a3b8;
  padding: 3px 6px 6px 0; border-bottom: 2px solid #e2e8f0; text-align: right;
}
.sched-table th.l { text-align: left; }
.sched-table td { padding: 5px 6px 5px 0; border-bottom: 1px solid #f8fafc; text-align: right; color: #475569; }
.sched-table td.l { text-align: left; color: #1e293b; }
.sched-table tr.payoff-row td { background: #f0fdf4; color: #15803d; font-weight: 600; }
.sched-table tr.month-hdr td {
  background: #f1f5f9; color: #475569; font-weight: 700;
  font-size: .7rem; border-top: 1px solid #e2e8f0;
}
/* Warnings */
.warn-card { border-left: 4px solid #d97706; }
.warn-card .card-title { color: #d97706; }
.warn-list { list-style: none; padding: 0; }
.warn-list li { padding: 5px 0; border-bottom: 1px solid #fef3c7; font-size: .82rem; color: #92400e; }
.warn-list li:last-child { border-bottom: none; }
.warn-list li::before { content: '! '; }
.empty { text-align: center; padding: 32px 12px; color: #94a3b8; font-size: .82rem; line-height: 1.8; }
@media print {
  @page { margin: 0.6cm; }
  html { -webkit-print-color-adjust: exact; print-color-adjust: exact; zoom: 0.68; }
  body { background: white; padding: 12px; }
  .card { box-shadow: none; border: 1px solid #e2e8f0; page-break-inside: avoid; break-inside: avoid; }
}
</style>")

;;;============================================================
;;; HTML: WARNINGS CARD
;;;============================================================

;; Renders a warning card if there are any issues to report.
;; Returns "" if no warnings.
(define (dp-card-warnings missing-assumptions
                          non-amortizing capped? max-months note-warnings)
  (let ((items '()))

    ;; Account note parse warnings (invalid field values)
    (for-each
     (lambda (w) (set! items (cons w items)))
     note-warnings)

    ;; Projection exceeded cap
    (when capped?
      (set! items (cons (string-append "Projection reached the "
                                       (number->string max-months)
                                       "-month cap without paying off all debts. "
                                       "Increase Max Projection Months or add a larger Extra Monthly Payment.")
                        items)))

    ;; Non-amortizing debts: min payment does not cover monthly interest.
    ;; na = (name min-pay-dollars monthly-interest-dollars apr%)
    (for-each
     (lambda (na)
       (set! items
             (cons (string-append (car na)
                                  " (APR " (dp-fmt-pct (list-ref na 3)) ")"
                                  ": the minimum payment does not cover monthly interest. "
                                  "The balance will grow unless extra payments are applied.")
                   items)))
     non-amortizing)

    ;; Selected accounts with no apr= in account notes
    (for-each
     (lambda (name)
       (set! items
             (cons (string-append "Account \"" name
                                  "\" has no debt assumptions in its Notes. "
                                  "It is excluded from the payoff calculation. "
                                  "Add apr= and min-payment= (and optionally priority=) "
                                  "to the account's Notes field.")
                   items)))
     missing-assumptions)

    (if (null? items)
        ""
        (string-append
         "<div class='card warn-card'>"
         "<div class='card-hdr'>"
         "<span class='card-title'>Warnings</span>"
         "<span class='card-badge'><span class='pill warn'>"
         (number->string (length items)) " issue(s)</span></span>"
         "</div>"
         "<ul class='warn-list'>"
         (apply string-append
                (map (lambda (item)
                       (string-append "<li>"
                                      (gnc:html-string-sanitize item)
                                      "</li>"))
                     (reverse items)))
         "</ul>"
         "</div>"))))

;;;============================================================
;;; HTML: SUMMARY CARD
;;; Six stat boxes: total debt, total minimums, extra payment,
;;; strategy, debt-free date, total interest.
;;;============================================================

(define (dp-card-summary total-debt total-minimums extra strategy
                          months total-interest currency now capped?)
  (let* ((fmt     (lambda (n) (dp-fmt-money n currency)))
         (int-pct (if (> total-debt 0.001)
                      (inexact->exact (round (* 100.0 (/ total-interest total-debt))))
                      0))
         (bar-col (cond ((> int-pct 30) "red")
                        ((> int-pct 10) "yellow")
                        (else           "green")))
         (bar-w   (number->string (max 0 (min 100 int-pct))))
         (df-date (if capped? (string-append ">" (number->string months) " mo")
                      (string-append (dp-months->str months)
                                     " — " (dp-months-ahead now months)))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Payoff Summary</span>"
     "<span class='card-badge'>"
     "<span class='pill info'>" (gnc:html-string-sanitize (dp-strategy-label strategy))
     "</span></span>"
     "</div>"

     ;; Row 1: total debt · total minimums · extra payment
     "<div class='stat-grid'>"
     "<div class='stat-box'><div class='stat-lbl'>Total Starting Debt</div>"
     "<div class='stat-val neg'>" (fmt total-debt) "</div></div>"
     "<div class='stat-box'><div class='stat-lbl'>Total Min Payments</div>"
     "<div class='stat-val acc'>" (fmt total-minimums) "/mo</div></div>"
     "<div class='stat-box'><div class='stat-lbl'>Extra Payment</div>"
     "<div class='stat-val " (if (> extra 0.001) "pos" "muted") "'>"
     (if (> extra 0.001) (fmt extra) "&mdash;") "</div></div>"
     "</div>"

     ;; Row 2: strategy · debt-free date · total interest
     "<div class='stat-grid'>"
     "<div class='stat-box'><div class='stat-lbl'>Strategy</div>"
     "<div class='stat-val' style='font-size:.85rem'>"
     (gnc:html-string-sanitize (dp-strategy-label strategy)) "</div></div>"
     "<div class='stat-box'><div class='stat-lbl'>Debt-Free Date</div>"
     "<div class='stat-val " (if capped? "warn" "pos") "' style='font-size:.85rem'>"
     (gnc:html-string-sanitize df-date) "</div></div>"
     "<div class='stat-box'><div class='stat-lbl'>Total Interest</div>"
     "<div class='stat-val warn'>" (fmt total-interest) "</div></div>"
     "</div>"

     ;; Interest-to-principal progress bar
     "<div class='pb-wrap'><div class='pb-bg'>"
     "<div class='pb-fill " bar-col "' style='width:" bar-w "%'></div>"
     "</div></div>"
     "<div style='font-size:.7rem;color:#94a3b8;margin-top:4px'>"
     (number->string int-pct) "% of principal will be paid as interest"
     "</div>"
     "</div>")))

;;;============================================================
;;; HTML: PAYOFF ORDER TABLE
;;; One row per debt, sorted by payoff month (earliest first).
;;; Columns: Account · Start Balance · APR · Min Pay ·
;;;          Payoff Month · Payoff Date · Interest Paid
;;;============================================================

(define (dp-card-payoff-table debt-results currency now)
  ;; debt-results is already sorted by paid-month (build-debt-results sorts it)
  ;; row: (name start-bal apr% min-pay paid-month cum-interest)
  (let* ((fmt        (lambda (n) (dp-fmt-money n currency)))
         (total-sbal (fold + 0.0 (map cadr debt-results)))
         (total-int  (fold + 0.0 (map (lambda (r) (list-ref r 5)) debt-results))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Payoff Order</span>"
     "</div>"
     "<table class='dp-table'>"
     "<thead><tr>"
     "<th>Account</th>"
     "<th class='r'>Start Balance</th>"
     "<th class='r'>APR</th>"
     "<th class='r'>Min Payment</th>"
     "<th class='r'>Payoff Month</th>"
     "<th class='r'>Payoff Date</th>"
     "<th class='r'>Interest Paid</th>"
     "</tr></thead>"
     "<tbody>"
     (apply string-append
            (map (lambda (r rank)
                   (let* ((name  (list-ref r 0))
                          (sbal  (list-ref r 1))
                          (apr   (list-ref r 2))
                          (minp  (list-ref r 3))
                          (pm    (list-ref r 4))
                          (cint  (list-ref r 5)))
                     (string-append
                      "<tr>"
                      "<td><span style='color:#94a3b8;font-size:.65rem;margin-right:6px'>"
                      (number->string rank) ".</span>"
                      (gnc:html-string-sanitize name) "</td>"
                      "<td class='r'>" (fmt sbal) "</td>"
                      "<td class='r c-red'>" (dp-fmt-pct apr) "</td>"
                      "<td class='r'>" (fmt minp) "</td>"
                      "<td class='r'>" (number->string pm) "</td>"
                      "<td class='r c-grn'>"
                      (gnc:html-string-sanitize (dp-months-ahead now pm)) "</td>"
                      "<td class='r'>" (fmt cint) "</td>"
                      "</tr>")))
                 debt-results
                 (iota (length debt-results) 1)))
     ;; Totals row
     "<tr style='border-top:2px solid #e2e8f0;font-weight:700'>"
     "<td>Total</td>"
     "<td class='r'>" (fmt total-sbal) "</td>"
     "<td></td><td></td><td></td><td></td>"
     "<td class='r'>" (fmt total-int) "</td>"
     "</tr>"
     "</tbody></table>"
     "</div>")))

;;;============================================================
;;; HTML: MONTHLY SCHEDULE (per-account rows)
;;; Columns: Month · Account · Start Bal · Interest · Payment · End Bal
;;; Capped at 24 months displayed. Payoff rows highlighted.
;;;============================================================

(define (dp-card-schedule schedule debt-results currency now)
  ;; schedule : list of (month-num . rows)
  ;;   row    : (name start-bal interest payment end-bal)
  ;; debt-results for payoff detection
  (let* ((fmt          (lambda (n) (dp-fmt-money n currency)))
         (max-display  24)
         (display-sched (dp-take schedule max-display))
         (truncated?   (> (length schedule) max-display))
         ;; Map month-number → list of account names paid that month
         (payoff-at    (lambda (m)
                         (filter-map (lambda (r)
                                       (if (= (list-ref r 4) m)
                                           (list-ref r 0) #f))
                                     debt-results))))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>Monthly Schedule</span>"
     "<span class='card-badge'>"
     (if truncated?
         (string-append "<span class='pill warn'>First " (number->string max-display)
                        " of " (number->string (length schedule)) " months</span>")
         "")
     "</span>"
     "</div>"
     "<table class='sched-table'>"
     "<thead><tr>"
     "<th class='l'>Mo.</th>"
     "<th class='l'>Account</th>"
     "<th>Start Balance</th>"
     "<th>Interest</th>"
     "<th>Payment</th>"
     "<th>End Balance</th>"
     "</tr></thead>"
     "<tbody>"
     (apply string-append
            (map (lambda (month-entry)
                   (let* ((mon      (car month-entry))
                          (rows     (cdr month-entry))
                          (date-s   (dp-months-ahead now mon))
                          (paid-here (payoff-at mon)))
                     (apply string-append
                            (map (lambda (row)
                                   (let* ((name    (list-ref row 0))
                                          (sbal    (list-ref row 1))
                                          (intr    (list-ref row 2))
                                          (pay     (list-ref row 3))
                                          (ebal    (list-ref row 4))
                                          (payoff? (member name paid-here string=?))
                                          (cls     (if payoff? " class='payoff-row'" "")))
                                     (string-append
                                      "<tr" cls ">"
                                      "<td class='l'>" (number->string mon)
                                      "<br><span style='color:#94a3b8;font-size:.65rem'>"
                                      (gnc:html-string-sanitize date-s) "</span></td>"
                                      "<td class='l'>"
                                      (gnc:html-string-sanitize name)
                                      (if payoff?
                                          " <span class='pill good' style='font-size:.55rem;padding:1px 5px'>PAID</span>"
                                          "")
                                      "</td>"
                                      "<td>" (fmt sbal) "</td>"
                                      "<td>" (fmt intr) "</td>"
                                      "<td>" (fmt pay) "</td>"
                                      "<td>" (fmt ebal) "</td>"
                                      "</tr>")))
                                 rows))))
                 display-sched))
     "</tbody></table>"
     (if truncated?
         (string-append
          "<div style='font-size:.7rem;color:#94a3b8;margin-top:8px;text-align:center'>"
          "Showing first " (number->string max-display) " months of "
          (number->string (length schedule)) " total. "
          "Increase Max Projection Months to see more.</div>")
         "")
     "</div>")))

;;;============================================================
;;; MAIN RENDERER
;;; Entry point called by GnuCash when the report is rendered.
;;;============================================================

(define (dp-renderer report-obj)
  (let* ((options  (gnc:report-options report-obj))
         (db       (gnc:optiondb options))

         ;; Read all options from the option database
         (accounts    (or (gnc-optiondb-lookup-value db dp-tab-debts dp-opt-accounts) '()))
         (strategy    (or (gnc-optiondb-lookup-value db dp-tab-strategy dp-opt-strategy) 'avalanche))
         (extra       (exact->inexact
                       (or (gnc-optiondb-lookup-value db dp-tab-strategy dp-opt-extra) 0)))
         (max-months  (inexact->exact
                       (or (gnc-optiondb-lookup-value db dp-tab-strategy dp-opt-max-months) 600)))
         (show-detail (not (equal? #f (gnc-optiondb-lookup-value db dp-tab-display dp-opt-show-detail))))
         (show-sched  (not (equal? #f (gnc-optiondb-lookup-value db dp-tab-display dp-opt-show-sched))))

         (now      (current-time))
         (date-str (strftime "%b %-d, %Y" (localtime now)))

         ;; Determine report currency from the first selected account.
         (currency
          (if (and (not (null? accounts)))
              (xaccAccountGetCommodity (car accounts))
              (gnc-default-report-currency)))

         ;; Build debt list + collect warnings from account notes
         (build-result        (dp-build-all accounts))
         (debts               (list-ref build-result 0))
         (missing-assumptions (list-ref build-result 1))
         (non-amortizing      (list-ref build-result 2))
         (note-warnings       (list-ref build-result 3))

         (document (gnc:make-html-document)))

    (gnc:html-document-add-object!
     document
     (gnc:make-html-text
      (string-append
       dp-css

       ;; ── Page header ──────────────────────────────────────────────
       "<div class='dp-header'>"
       "<div>"
       "<h1>Debt Repayment Planner</h1>"
       "</div>"
       "<span class='pill muted'>As of " (gnc:html-string-sanitize date-str) "</span>"
       "</div>"

       (if (and (null? accounts) (null? debts))

           ;; ── Getting-started placeholder ──────────────────────────
           (string-append
            "<div class='card'>"
            "<div class='empty'>"
            "<strong>Getting started:</strong><br>"
            "1. Open <em>Options &rarr; Debts &rarr; Debt Accounts</em> "
            "and select your liability / credit card accounts.<br>"
            "2. Open each account in GnuCash and add to its Notes field:<br><br>"
            "<code>apr=28.49</code><br>"
            "<code>min-payment=100</code><br>"
            "<code>priority=1</code> (optional)"
            "</div></div>")

           ;; ── Normal rendering path ────────────────────────────────
           (if (null? debts)

               ;; Accounts selected but none could be built (all zero or all missing assumptions)
               (string-append
                (dp-card-warnings missing-assumptions
                                  non-amortizing #f max-months note-warnings)
                "<div class='card'><div class='empty'>"
                "No debts to simulate. Selected accounts either have zero balances "
                "or are missing apr= in their account Notes. See warnings above."
                "</div></div>")

               ;; ── Run simulation ───────────────────────────────────
               (let* ((sim           (dp-simulate debts strategy extra max-months))
                      (total-months  (list-ref sim 0))
                      (total-int     (list-ref sim 1))
                      (debt-results  (list-ref sim 3))
                      (schedule      (list-ref sim 4))
                      (capped?       (list-ref sim 5))
                      (total-debt    (fold + 0.0 (map cadr debts)))
                      (total-minimums (fold + 0.0 (map (lambda (d) (list-ref d 3)) debts))))
                 (string-append
                  ;; Warnings (if any)
                  (dp-card-warnings missing-assumptions
                                    non-amortizing capped? max-months note-warnings)
                  ;; Summary
                  (dp-card-summary total-debt total-minimums extra strategy
                                   total-months total-int currency now capped?)
                  ;; Payoff order table
                  (if show-detail
                      (dp-card-payoff-table debt-results currency now)
                      "")
                  ;; Monthly schedule
                  (if show-sched
                      (dp-card-schedule schedule debt-results currency now)
                      ""))))))))

    document))

;;;============================================================
;;; REPORT REGISTRATION
;;;============================================================

(gnc:define-report
 'version         1
 'name            dp-report-name
 'report-guid     dp-report-guid
 'menu-path       (list gnc:menuname-budget)
 'options-generator dp-options-generator
 'renderer          dp-renderer)
