;; -*-scheme-*-
;;;; budget-sinking-funds.scm — Budget Report with Sinking Funds
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
;; YNAB / Actual Budget-style cumulative available-balance report for GnuCash.
;;
;; Shows for each expense category:
;;   Available = (Budgeted to date) - (Spent to date)
;; Negative balances (overspending) carry forward — nothing is clamped to zero.
;;
;; Two category types are auto-detected:
;;   Sinking Fund    — any visible leaf expense account with a valid target= note
;;                     (unless also classified as a Future Purchase).
;;   Future Purchase — any leaf expense account beneath a placeholder account
;;                     named exactly "Future Purchases".
;; Both participate in the same unified budget table with the same
;; budgeted/spent/available calculations as normal expense categories.
;;
;; Compatible: GnuCash 5.14+ (Windows/macOS/Linux). Read-only.
;;
;; Installation
;; ─────────────
;;   macOS  : ~/Library/Application Support/GnuCash/financial-radar/
;;   Windows: %APPDATA%\GnuCash\financial-radar\
;;   Linux  : ~/.local/share/gnucash/financial-radar/
;;
;; In config-user.scm add:
;;   (load (gnc-build-userdata-path "financial-radar/budget-sinking-funds.scm"))
;;
;; Restart GnuCash → Reports > Budget > Budget Report with Sinking Funds

(define-module (gnucash reports budget-sinking-funds)
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

(define bsf-report-name "Budget Report with Sinking Funds")
(define bsf-report-guid "c4e5f6a7-b8c9-d0e1-f2a3-b4c5d6e7f8a9")

(define bsf-tab-general  (N_ "General"))
(define bsf-tab-accounts (N_ "Accounts"))
(define bsf-tab-display  (N_ "Display"))

(define bsf-opt-budget              (N_ "Budget"))
(define bsf-opt-date-range          (N_ "Date range"))
(define bsf-opt-period-start        (N_ "Custom: from period"))
(define bsf-opt-period-start-exact  (N_ "Custom: exact start period"))
(define bsf-opt-period-end          (N_ "Custom: through period"))
(define bsf-opt-period-exact        (N_ "Custom: exact end period"))
(define bsf-opt-included-accounts   (N_ "Included Accounts"))
(define bsf-opt-show-zeros          (N_ "Show zero-balance categories"))
(define bsf-opt-exclude-off-budget  (N_ "Exclude Off Budget accounts"))
(define bsf-opt-hidden-accounts     (N_ "Hidden Accounts"))
(define bsf-opt-show-progress       (N_ "Show spending progress bars"))

;;;============================================================
;;; OPTIONS GENERATOR
;;;============================================================

(define (bsf-options-generator)
  (let ((options               (gnc-new-optiondb))
        (ui-start-period-type  'first)
        (ui-end-period-type    'current))

    ;; ── General ──────────────────────────────────────────────────────
    (gnc-register-budget-option options
      bsf-tab-general bsf-opt-budget "a"
      (N_ "Budget to use for this report.")
      (gnc-budget-get-default (gnc-get-current-book)))

    ;; Friendly date-range preset. "Custom range" reveals the four
    ;; period pickers below so power users can target any span.
    (gnc-register-multichoice-callback-option options
      bsf-tab-general bsf-opt-date-range "b"
      (N_ "Period range to include in the report.")
      "ytd"
      (list (vector 'ytd        (N_ "Year to date — carry forward from period 1"))
            (vector 'this-month (N_ "This month only"))
            (vector 'last-month (N_ "Last month only"))
            (vector 'next-month (N_ "Next month only"))
            (vector 'full-year  (N_ "Full budget year"))
            (vector 'custom     (N_ "Custom range")))
      (lambda (new-val)
        (let ((custom? (eq? new-val 'custom)))
          (gnc-optiondb-set-option-selectable-by-name
           options bsf-tab-general bsf-opt-period-start custom?)
          (gnc-optiondb-set-option-selectable-by-name
           options bsf-tab-general bsf-opt-period-end custom?)
          (if (not custom?)
              (begin
                (gnc-optiondb-set-option-selectable-by-name
                 options bsf-tab-general bsf-opt-period-start-exact #f)
                (gnc-optiondb-set-option-selectable-by-name
                 options bsf-tab-general bsf-opt-period-exact #f))
              #f))))

    ;; ── Custom range (grayed out unless Date range = "Custom range") ─
    (gnc-register-multichoice-callback-option options
      bsf-tab-general bsf-opt-period-start "c"
      (N_ "First budget period to include.")
      "first"
      (list (vector 'first   (N_ "First period"))
            (vector 'current (N_ "Current period (today)"))
            (vector 'last    (N_ "Last period"))
            (vector 'manual  (N_ "Manual — enter period number below")))
      (lambda (new-val)
        (gnc-optiondb-set-option-selectable-by-name
         options bsf-tab-general bsf-opt-period-start-exact
         (eq? new-val 'manual))
        (set! ui-start-period-type new-val)))

    (gnc-register-number-range-option options
      bsf-tab-general bsf-opt-period-start-exact "d"
      (N_ "Exact start period when 'Manual' is selected (1 = first period).")
      1 1 60 1)

    (gnc-register-multichoice-callback-option options
      bsf-tab-general bsf-opt-period-end "e"
      (N_ "Last budget period to include.")
      "current"
      (list (vector 'first   (N_ "First period"))
            (vector 'current (N_ "Current period (today)"))
            (vector 'last    (N_ "Last period"))
            (vector 'manual  (N_ "Manual — enter period number below")))
      (lambda (new-val)
        (gnc-optiondb-set-option-selectable-by-name
         options bsf-tab-general bsf-opt-period-exact
         (eq? new-val 'manual))
        (set! ui-end-period-type new-val)))

    (gnc-register-number-range-option options
      bsf-tab-general bsf-opt-period-exact "f"
      (N_ "Exact end period when 'Manual' is selected (1 = first period).")
      1 1 60 1)

    ;; ── Accounts ─────────────────────────────────────────────────────
    (gnc-register-simple-boolean-option options
      bsf-tab-accounts bsf-opt-show-zeros "a"
      (N_ "Include categories with no budget and no activity in this period range.")
      #f)

    (let* ((book-root    (gnc-get-current-root-account))
           (top-accounts (gnc-account-get-children book-root))
           (default-accts
            (filter (lambda (a)
                      (member (xaccAccountGetName a)
                              '("Assets" "Expenses" "Liabilities")
                              string=?))
                    top-accounts)))
      (gnc-register-account-list-option options
        bsf-tab-accounts bsf-opt-included-accounts "b"
        (N_ "Accounts to scan for budget categories. All leaf accounts under the selected accounts are included as budget rows. Defaults to Assets, Expenses, and Liabilities.")
        default-accts))

    (gnc-register-simple-boolean-option options
      bsf-tab-accounts bsf-opt-exclude-off-budget "c"
      (N_ "Automatically hide any account named 'Off Budget' and all of its sub-accounts.")
      #t)

    (gnc-register-account-list-option options
      bsf-tab-accounts bsf-opt-hidden-accounts "d"
      (N_ "Accounts to hide from this report. Selecting a parent account also hides its sub-accounts.")
      '())

    ;; ── Display ───────────────────────────────────────────────────────
    (gnc-register-simple-boolean-option options
      bsf-tab-display bsf-opt-show-progress "a"
      (N_ "Show a compact spending progress bar under each category name.")
      #t)

    ;; All custom fields start disabled; the date-range callback
    ;; enables/disables period-start and period-end, and their own
    ;; callbacks gate the exact-period fields.
    (gnc-optiondb-set-option-selectable-by-name
     options bsf-tab-general bsf-opt-period-start #f)
    (gnc-optiondb-set-option-selectable-by-name
     options bsf-tab-general bsf-opt-period-start-exact #f)
    (gnc-optiondb-set-option-selectable-by-name
     options bsf-tab-general bsf-opt-period-end #f)
    (gnc-optiondb-set-option-selectable-by-name
     options bsf-tab-general bsf-opt-period-exact #f)

    (gnc:options-set-default-section options bsf-tab-general)
    options))

;;;============================================================
;;; ACCOUNT CLASSIFICATION
;;; Detects Future Purchase accounts by walking DOWN from the root,
;;; collecting every account named "Future Purchases", then checking
;;; whether a candidate account's full path starts with any of
;;; those roots.  This avoids xaccAccountGetParent which is not
;;; reliably bound in all GnuCash builds.
;;;
;;; Future Purchase → any leaf under a "Future Purchases" placeholder.
;;; Sinking Fund    → any other visible leaf with a valid target= note.
;;;============================================================

(define (bsf-find-fp-roots root)
  (filter (lambda (a)
            (string=? (xaccAccountGetName a) "Future Purchases"))
          (gnc-account-get-descendants root)))

(define (bsf-account-under-root? acct root)
  (let ((full (gnc-account-get-full-name acct)))
    (let* ((root-full (gnc-account-get-full-name root))
           (prefix    (string-append root-full ":"))
           (plen      (string-length prefix)))
      (or (string=? full root-full)
          (and (>= (string-length full) plen)
               (string=? (substring full 0 plen) prefix))))))

(define (bsf-account-under-any? acct roots)
  (any (lambda (root) (bsf-account-under-root? acct root)) roots))

(define (bsf-future-purchase? acct fp-roots)
  (any (lambda (fp-root)
         (bsf-account-under-root? acct fp-root))
       fp-roots))

(define (bsf-find-off-budget-roots root)
  (filter (lambda (a)
            (string=? (xaccAccountGetName a) "Off Budget"))
          (gnc-account-get-descendants root)))

(define (bsf-hidden-account? acct hidden-roots)
  (any (lambda (hidden-root)
         (bsf-account-under-root? acct hidden-root))
       hidden-roots))

;; Return the category type symbol for a record given its target entry.
;;   index 5 (is-future-purchase?) → 'future-purchase (highest precedence)
;;   target-entry truthy           → 'sinking-fund
;;   otherwise                     → 'normal
(define (bsf-category-type rec target-entry)
  (cond
    ((list-ref rec 5) 'future-purchase)
    (target-entry     'sinking-fund)
    (else             'normal)))

;;;============================================================
;;; BUDGET PERIOD HELPERS
;;; Period indexes are 0-based internally; 1-based in UI labels.
;;;============================================================

(define (bsf-period-for-today budget)
  (let* ((now (current-time))
         (n   (gnc-budget-get-num-periods budget)))
    (let loop ((p 0) (found 0))
      (if (>= p n)
          found
          (if (<= (gnc-budget-get-period-start-date budget p) now)
              (loop (1+ p) p)
              found)))))

;; Resolve a period-type symbol + optional manual number to a 0-based index.
;; Used for both start and end period options.
(define (bsf-resolve-period budget period-type period-exact)
  (let ((n (gnc-budget-get-num-periods budget)))
    (case period-type
      ((first)  0)
      ((last)   (1- n))
      ((manual) (max 0 (min (1- n) (1- (inexact->exact period-exact)))))
      (else     (bsf-period-for-today budget)))))

;; Map a date-range preset symbol to a (start . end) pair of 0-based period indices.
;; Falls through to the custom period pickers when preset is 'custom.
(define (bsf-resolve-preset budget preset
                            period-start-type period-start-exact
                            period-end-type   period-end-exact)
  (let* ((n       (gnc-budget-get-num-periods budget))
         (current (bsf-period-for-today budget)))
    (case preset
      ((ytd)        (cons 0 current))
      ((this-month) (cons current current))
      ((last-month) (let ((p (max 0 (1- current)))) (cons p p)))
      ((next-month) (let ((p (min (1- n) (1+ current)))) (cons p p)))
      ((full-year)  (cons 0 (1- n)))
      (else
       (let* ((rs (bsf-resolve-period budget period-start-type period-start-exact))
              (re (bsf-resolve-period budget period-end-type   period-end-exact)))
         (cons (min rs re) (max rs re)))))))

;; Human-readable label for start-period through end-period.
;; Single-period: "May 2026 (period 5 of 12)"
;; Multi-period : "Jan 2026 - May 2026 (5 of 12 periods)"
(define (bsf-period-label budget start-period end-period)
  (let* ((n-total  (gnc-budget-get-num-periods budget))
         (n-shown  (- end-period start-period -1))
         (start-str (strftime "%b %Y"
                              (localtime (gnc-budget-get-period-start-date budget start-period))))
         (end-str   (strftime "%b %Y"
                              (localtime (gnc-budget-get-period-end-date   budget end-period)))))
    (if (= start-period end-period)
        (string-append start-str
                       " (period " (number->string (1+ start-period))
                       " of " (number->string n-total) ")")
        (string-append start-str " - " end-str
                       " (" (number->string n-shown)
                       " of " (number->string n-total) " periods)"))))

;;;============================================================
;;; BUDGET CALCULATIONS
;;; Amounts are summed from START-PERIOD through END-PERIOD (both
;;; inclusive, 0-based).  Setting start-period=0 gives full carry-
;;; forward from the beginning of the budget (YNAB style).  Setting
;;; start-period=end-period gives a single-period snapshot.
;;; Available = Budgeted - Actual.  Negatives are preserved.
;;;============================================================

(define (bsf-cumulative-budgeted budget acct start-period end-period)
  (apply + (map (lambda (p)
                  (gnc-numeric-to-double
                   (gnc-budget-get-account-period-value budget acct p)))
                (iota (- (1+ end-period) start-period) start-period))))

(define (bsf-cumulative-actual budget acct start-period end-period)
  (abs (apply + (map (lambda (p)
                       (gnc-numeric-to-double
                        (gnc-budget-get-account-period-actual-value budget acct p)))
                     (iota (- (1+ end-period) start-period) start-period)))))

;;;============================================================
;;; DATA COLLECTION
;;; Record format (indices 0–5):
;;;   0:acct  1:display-name  2:budgeted  3:actual  4:available
;;;   5:is-future-purchase?
;;; display-name has the matched included-account root prefix stripped.
;;; Records sorted by full path.
;;;============================================================

(define (bsf-display-name acct included-accounts)
  (let ((full (gnc-account-get-full-name acct)))
    (let loop ((roots included-accounts))
      (if (null? roots)
          full
          (let* ((root-full (gnc-account-get-full-name (car roots)))
                 (prefix    (string-append root-full ":"))
                 (plen      (string-length prefix)))
            (if (and (>= (string-length full) plen)
                     (string=? (substring full 0 plen) prefix))
                (substring full plen)
                (loop (cdr roots))))))))

(define (bsf-collect-data budget start-period end-period show-zeros?
                          exclude-off-budget? hidden-accounts included-accounts)
  (let* ((root     (gnc-get-current-root-account))
         (all      (gnc-account-get-descendants root))
         (fp-roots (bsf-find-fp-roots root))
         (hidden-roots (append (if exclude-off-budget?
                                   (bsf-find-off-budget-roots root)
                                   '())
                               hidden-accounts))
         ;; Exclude the "Future Purchases" placeholder accounts themselves
         ;; (they are containers, not budget rows).
         (special-root-paths
          (map gnc-account-get-full-name fp-roots))
         (leaves   (filter (lambda (a)
                             (and (bsf-account-under-any? a included-accounts)
                                  (null? (gnc-account-get-children a))
                                  (not (bsf-hidden-account? a hidden-roots))
                                  (not (member (gnc-account-get-full-name a)
                                               special-root-paths string=?))))
                           all))
         (records
          (filter-map
           (lambda (acct)
             (let* ((bgt (bsf-cumulative-budgeted budget acct start-period end-period))
                    (act (bsf-cumulative-actual   budget acct start-period end-period))
                    (avl (- bgt act)))
               (if (or show-zeros?
                       (> (+ (abs bgt) (abs act)) 0.001)
                       (bsf-has-target-note? acct))
                   (list acct
                         (bsf-display-name acct included-accounts)
                         bgt act avl
                         (bsf-future-purchase? acct fp-roots))
                   #f)))
           leaves)))
    (sort records
          (lambda (a b)
            (string<? (gnc-account-get-full-name (car a))
                      (gnc-account-get-full-name (car b)))))))

;;;============================================================
;;; DISPLAY NAME SPLITTING
;;; Extracts (group-key . leaf-name) from a display name.
;;; group-key = first path segment (or "" for top-level accounts).
;;; leaf-name = last path segment.
;;; Examples:
;;;   "Auto:Gas"                     → ("Auto"  . "Gas")
;;;   "Groceries"                    → (""      . "Groceries")
;;;   "Gifts:Sinking Funds:Christmas"→ ("Gifts" . "Christmas")
;;;   "Auto:Repairs:Car Repairs"     → ("Auto"  . "Car Repairs")
;;;============================================================

(define (bsf-split-display-name display-name)
  (let* ((len (string-length display-name))
         (first-colon
          (let loop ((i 0))
            (cond ((>= i len) -1)
                  ((char=? (string-ref display-name i) #\:) i)
                  (else (loop (1+ i))))))
         (last-colon
          (let loop ((i (1- len)))
            (cond ((< i 0) -1)
                  ((char=? (string-ref display-name i) #\:) i)
                  (else (loop (1- i)))))))
    (if (= first-colon -1)
        (cons "" display-name)
        (cons (substring display-name 0 first-colon)
              (substring display-name (1+ last-colon) len)))))

;;;============================================================
;;; GROUPING
;;; Groups a sorted record list by group-key, preserving order.
;;; Returns an alist: ((group-key . (record ...)) ...)
;;; The "" group (top-level accounts) appears in its natural
;;; alphabetical position among the other groups.
;;;============================================================

;; Records arrive pre-sorted by full path, so groups naturally appear in
;; alphabetical order.  We preserve that order by appending new groups at
;; the end — no reverse needed.
(define (bsf-group-records records)
  (let loop ((recs records) (groups '()) (seen-keys '()))
    (if (null? recs)
        groups
        (let* ((rec  (car recs))
               (key  (car (bsf-split-display-name (list-ref rec 1))))
               (rest (cdr recs)))
          (if (member key seen-keys string=?)
              ;; Key already open — append this record to it
              (loop rest
                    (map (lambda (g)
                           (if (string=? (car g) key)
                               (cons key (append (cdr g) (list rec)))
                               g))
                         groups)
                    seen-keys)
              ;; New key — open a new group at the end
              (loop rest
                    (append groups (list (cons key (list rec))))
                    (append seen-keys (list key))))))))

;;;============================================================
;;; PLANNING TARGET METADATA
;;; Planning targets are read from account Notes for every visible
;;; leaf expense account.  An account with a valid target= becomes a
;;; sinking fund (or keeps its future-purchase classification).
;;;
;;; Target alist entry: (display-name amount date-or-#f)
;;;   amount       — positive number
;;;   date-or-#f   — (year . month) cons or #f
;;;============================================================

(define bsf-month-names
  '#("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (bsf-fp-trim s)
  (string-trim-right (string-trim s)))

(define (bsf-fp-split-lines text)
  (let loop ((chars (string->list text)) (cur '()) (acc '()))
    (cond
      ((null? chars)
       (reverse (cons (list->string (reverse cur)) acc)))
      ((char=? (car chars) #\newline)
       (loop (cdr chars) '() (cons (list->string (reverse cur)) acc)))
      (else
       (loop (cdr chars) (cons (car chars) cur) acc)))))

(define (bsf-fp-parse-amount s)
  (let ((n (string->number (bsf-fp-trim s))))
    (if (and n (real? n) (finite? n) (> n 0.0))
        (exact->inexact n)
        #f)))

(define (bsf-fp-parse-date s)
  ;; Accepts YYYY-MM-DD or YYYY-MM.  Returns (year . month) or #f.
  (let ((t (bsf-fp-trim s)))
    (if (>= (string-length t) 7)
        (let ((y (string->number (substring t 0 4)))
              (m (string->number (substring t 5 7))))
          (if (and y m (integer? y) (integer? m)
                   (>= y 2000) (>= m 1) (<= m 12))
              (cons y m)
              #f))
        #f)))

(define (bsf-fp-months-remaining year month)
  ;; Signed count: positive = months until target, negative = past.
  (let* ((now (localtime (current-time)))
         (ny  (+ 1900 (tm:year now)))
         (nm  (+ 1 (tm:mon now))))
    (- (+ (* year 12) month)
       (+ (* ny 12) nm))))


;;;============================================================
;;; ACCOUNT NOTE PARSING (key=value)
;;; Reads planning target metadata stored in GnuCash account
;;; notes via xaccAccountGetNotes.  Recognised fields:
;;;   target=<amount>           e.g. target=2600
;;;   target-date=<YYYY-MM-DD>  e.g. target-date=2027-05-13
;;; Applied to all visible leaf expense accounts.
;;;============================================================

;; Parse key=value lines from a raw notes string.
;; Returns alist of (lowercase-trimmed-key . trimmed-value).
;; Blank lines and lines starting with # are skipped.
;; Lines without an '=' sign are ignored.
(define (bsf-parse-note-kv text)
  (filter-map
   (lambda (raw-line)
     (let ((line (bsf-fp-trim raw-line)))
       (if (or (string=? line "")
               (char=? (string-ref line 0) #\#))
           #f
           (let loop ((chars   (string->list line))
                      (key-acc '())
                      (eq-seen #f)
                      (val-acc '()))
             (cond
               ((null? chars)
                (if eq-seen
                    (cons (string-downcase
                           (bsf-fp-trim (list->string (reverse key-acc))))
                          (bsf-fp-trim (list->string (reverse val-acc))))
                    #f))
               ((and (not eq-seen) (char=? (car chars) #\=))
                (loop (cdr chars) key-acc #t val-acc))
               (eq-seen
                (loop (cdr chars) key-acc #t (cons (car chars) val-acc)))
               (else
                (loop (cdr chars) (cons (car chars) key-acc) #f val-acc)))))))
   (bsf-fp-split-lines text)))

;; Return #t if the account has a syntactically valid target= note value.
;; Used to force-include target accounts even when budget activity is zero.
(define (bsf-has-target-note? acct)
  (let* ((kv   (bsf-parse-note-kv (or (xaccAccountGetNotes acct) "")))
         (t-kv (assoc "target" kv)))
    (and t-kv (bsf-fp-parse-amount (cdr t-kv)) #t)))

;; For each visible leaf expense record, read account notes and extract
;; target / target-date metadata.  Records without a valid target= are skipped.
;; Returns (targets . warnings).
;;   targets  : ((display-name amount date-or-#f) ...)
;;   warnings : list of human-readable strings for bad note values.
(define (bsf-note-targets-for-records records)
  (let* ((warnings '())
         (add-warn! (lambda (msg)
                      (set! warnings (append warnings (list msg)))))
         (targets
          (filter-map
           (lambda (rec)
             (let* ((acct  (list-ref rec 0))
                    (dname (list-ref rec 1))
                    (kv    (bsf-parse-note-kv
                            (or (xaccAccountGetNotes acct) "")))
                    (t-kv  (assoc "target" kv))
                    (d-kv  (assoc "target-date" kv)))
               (if (not t-kv)
                   #f
                   (let ((amount (bsf-fp-parse-amount (cdr t-kv))))
                     (if (not amount)
                         (begin
                           (add-warn!
                            (string-append
                             "Account &ldquo;"
                             (gnc:html-string-sanitize (xaccAccountGetName acct))
                             "&rdquo;: invalid note &ldquo;target&rdquo; value &ldquo;"
                             (gnc:html-string-sanitize (cdr t-kv))
                             "&rdquo;"))
                           #f)
                         (let ((date (if d-kv
                                        (let ((d (bsf-fp-parse-date (cdr d-kv))))
                                          (if (not d)
                                              (begin
                                                (add-warn!
                                                 (string-append
                                                  "Account &ldquo;"
                                                  (gnc:html-string-sanitize
                                                   (xaccAccountGetName acct))
                                                  "&rdquo;: invalid note &ldquo;target-date&rdquo; value &ldquo;"
                                                  (gnc:html-string-sanitize (cdr d-kv))
                                                  "&rdquo;"))
                                                #f)
                                              d))
                                        #f)))
                           (list acct amount date)))))))
           records)))
    (cons targets warnings)))

;;;============================================================
;;; FORMATTING HELPERS
;;;============================================================

(define (bsf-fmt-money amount currency)
  (gnc:monetary->string
   (gnc:make-gnc-monetary
    currency
    (double-to-gnc-numeric
     (if (and (number? amount) (finite? amount)) amount 0.0)
     100 GNC-RND-ROUND))))

;; CSS class for the Available cell (and progress bar fill).
(define (bsf-avl-class avl bgt)
  (cond
    ((and (< (abs avl) 0.001) (< (abs bgt) 0.001)) "avl-gray")
    ((< avl (- 0.001))                               "avl-red")
    ((and (> bgt 0.001) (< avl (* bgt 0.10)))        "avl-yellow")
    (else                                             "avl-green")))

;;;============================================================
;;; PROGRESS BAR RENDERER
;;; Renders a compact 3-px-tall spending bar under the category
;;; name.  Fill width = spent/budgeted, capped at 100%.
;;; avl-cls is reused for bar color so both indicators match.
;;;============================================================

(define (bsf-render-progress-bar spent budgeted avl-cls)
  (let* ((raw  (if (> budgeted 0.001)
                   (* 100.0 (/ spent budgeted))
                   (if (> spent 0.001) 100.0 0.0)))
         (fill (min 100.0 (max 0.0 raw)))
         (pct  (number->string (inexact->exact (round fill)))))
    (string-append
     "<div class='pb-wrap'>"
     "<div class='pb-track'>"
     "<div class='pb-fill " avl-cls "' style='width:" pct "%'></div>"
     "</div>"
     "</div>")))

;;;============================================================
;;; BADGE RENDERER
;;; Returns a small inline HTML badge for a category type.
;;; Returns "" for 'normal.  New types can be added here.
;;;============================================================

(define (bsf-category-badge cat-type)
  (case cat-type
    ((sinking-fund)    "<span class='badge badge-sf'>Sinking Fund</span>")
    ((future-purchase) "<span class='badge badge-fp'>Future Purchase</span>")
    ((debt)            "<span class='badge badge-debt'>Debt</span>")
    ((subscription)    "<span class='badge badge-sub'>Subscription</span>")
    (else              "")))

;;;============================================================
;;; PLANNING METADATA RENDERER
;;; Renders compact target/progress info below the category name
;;; for Sinking Fund or Future Purchase rows with a target entry.
;;; target-entry is (display-name amount date-or-#f) or #f.
;;; avl is the row's existing available value (funded so far).
;;;============================================================

(define (bsf-fp-render-plan avl target-entry currency)
  (if (not target-entry)
      ""
      (let* ((fmt       (lambda (n) (bsf-fmt-money n currency)))
             (amount    (cadr  target-entry))
             (date      (caddr target-entry))
             (funded    avl)
             (remaining (max 0.0 (- amount funded)))
             (pct-raw   (if (> amount 0.001)
                            (* 100.0 (/ funded amount))
                            0.0))
             (pct       (inexact->exact (round (min 100.0 (max 0.0 pct-raw)))))
             (date-info (if date
                            (let* ((mo (bsf-fp-months-remaining
                                        (car date) (cdr date)))
                                   (mn (vector-ref bsf-month-names
                                                   (1- (cdr date))))
                                   (yr (number->string (car date)))
                                   (lbl (string-append mn " " yr)))
                              (cond
                                ((<= mo 0)
                                 (if (> remaining 0.001)
                                     (string-append
                                      "<span class='fp-pi fp-overdue'>"
                                      lbl " &mdash; Overdue</span>")
                                     (string-append
                                      "<span class='fp-pi fp-due-now'>"
                                      lbl " &mdash; Due now</span>")))
                                (else
                                 (string-append
                                  "<span class='fp-pi'>"
                                  lbl " &mdash; "
                                  (fmt (/ remaining mo))
                                  "/mo needed</span>"))))
                            "")))
        (string-append
         "<div class='fp-plan'>"
         "<span class='fp-pi'>Target " (fmt amount) "</span>"
         "<span class='fp-pi'>Remaining " (fmt remaining) "</span>"
         "<span class='fp-pi'>" (number->string pct) "% funded</span>"
         date-info
         "</div>"))))

;;;============================================================
;;; CSS
;;;============================================================

(define bsf-css
  "<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  font-size: 13px; background: #f1f5f9; color: #1e293b; padding: 20px;
}

/* ── Page header ─────────────────────────────────────────── */
.bsf-header {
  background: #1e293b; color: #f1f5f9; border-radius: 10px;
  padding: 18px 24px; margin-bottom: 16px;
}
.bsf-header h1 { font-size: 1.25rem; font-weight: 700; }
.bsf-period-bar {
  font-size: .75rem; color: #64748b; margin-bottom: 18px; padding: 0 2px;
}

/* ── Card shell ──────────────────────────────────────────── */
.card {
  background: #fff; border-radius: 10px;
  box-shadow: 0 1px 4px rgba(0,0,0,.08);
  margin-bottom: 20px; overflow: hidden;
}
.card-hdr {
  background: #f8fafc; padding: 11px 18px;
  border-bottom: 1px solid #e2e8f0; overflow: hidden;
}
.card-title { font-weight: 700; font-size: .88rem; color: #1e293b; float: left; }
.card-badge { float: right; }
.pill {
  display: inline-block; border-radius: 99px; padding: 2px 10px;
  font-size: .68rem; font-weight: 600;
}
.pill-count { background: #f1f5f9; color: #475569; border: 1px solid #e2e8f0; }

/* ── Main table ──────────────────────────────────────────── */
.bsf-table { width: 100%; border-collapse: collapse; }
.bsf-table thead th {
  background: #f8fafc; font-size: .7rem; font-weight: 700;
  text-transform: uppercase; letter-spacing: .05em; color: #64748b;
  padding: 7px 16px; border-bottom: 2px solid #e2e8f0; white-space: nowrap;
}
.bsf-table thead th.r { text-align: right; }
.bsf-table tbody tr { border-bottom: 1px solid #f1f5f9; }
.bsf-table tbody tr:last-child { border-bottom: none; }
.bsf-table tbody tr:hover { background: #f8fafc; }
.bsf-table td { padding: 6px 16px; font-size: .82rem; vertical-align: middle; }

/* ── Group header rows ───────────────────────────────────── */
.group-row { background: #f8fafc !important; border-top: 1px solid #e2e8f0; }
.group-row:hover { background: #f1f5f9 !important; }
.group-name {
  font-weight: 700; font-size: .75rem;
  text-transform: uppercase; letter-spacing: .05em;
  color: #64748b; padding-left: 16px;
}
.group-num { color: #64748b; }

/* ── Leaf rows ───────────────────────────────────────────── */
.col-name { color: #334155; }
.col-name.indent { padding-left: 28px; }
.col-num {
  text-align: right; color: #475569;
  font-variant-numeric: tabular-nums; white-space: nowrap;
}
.col-avl {
  text-align: right; font-weight: 600;
  font-variant-numeric: tabular-nums; white-space: nowrap;
}

/* ── Available status colors ─────────────────────────────── */
.avl-green  { color: #15803d; }
.avl-yellow { color: #b45309; }
.avl-red    { color: #dc2626; }
.avl-gray   { color: #94a3b8; font-weight: 400; }

/* ── Totals row ──────────────────────────────────────────── */
.totals-row td {
  font-weight: 700; background: #f8fafc;
  border-top: 2px solid #e2e8f0 !important;
  padding-top: 9px; padding-bottom: 9px;
}

/* ── Progress bars ───────────────────────────────────────── */
.pb-wrap { margin-top: 4px; }
.pb-track {
  height: 3px; background: #e2e8f0;
  border-radius: 2px; overflow: hidden; width: 100%;
}
.pb-fill { height: 100%; border-radius: 2px; }
.pb-fill.avl-green  { background: #16a34a; }
.pb-fill.avl-yellow { background: #ca8a04; }
.pb-fill.avl-red    { background: #dc2626; }
.pb-fill.avl-gray   { background: #cbd5e1; }

/* ── Category type badges ────────────────────────────────── */
.badge {
  display: inline-block; border-radius: 4px;
  padding: 1px 6px; font-size: .6rem; font-weight: 600;
  margin-left: 6px; vertical-align: middle; letter-spacing: .02em;
}
.badge-sf   { background: #dbeafe; color: #1d4ed8; }
.badge-fp   { background: #ede9fe; color: #5b21b6; }
.badge-debt { background: #fce7f3; color: #9d174d; }
.badge-sub  { background: #fef3c7; color: #92400e; }

/* ── Future Purchase planning metadata ───────────────────── */
.fp-plan { margin-top: 3px; font-size: .66rem; color: #64748b; line-height: 1.6; }
.fp-pi { margin-right: 10px; white-space: nowrap; }
.fp-overdue { color: #dc2626; font-weight: 600; }
.fp-due-now { color: #b45309; font-weight: 600; }

/* ── Future Purchase parse warnings ─────────────────────── */
.fp-warn {
  font-size: .7rem; color: #78350f; background: #fffbeb;
  border: 1px solid #fde68a; border-radius: 6px;
  padding: 6px 12px; margin-bottom: 12px;
}
.fp-warn-ttl { font-weight: 700; margin-bottom: 2px; }
.fp-warn-item { padding-left: 8px; }

/* ── Legend ──────────────────────────────────────────────── */
.legend-card {
  background: #fff; border-radius: 10px;
  box-shadow: 0 1px 4px rgba(0,0,0,.08);
  padding: 10px 18px 12px; margin-bottom: 20px;
  overflow: hidden; font-size: .72rem;
}
.legend-section { float: left; margin-right: 28px; margin-top: 2px; }
.legend-title { font-weight: 700; color: #94a3b8; margin-right: 10px; }
.legend-section span + span { margin-left: 10px; }

/* ── Empty state ─────────────────────────────────────────── */
.empty {
  text-align: center; padding: 32px 16px;
  color: #94a3b8; font-size: .82rem; line-height: 1.8;
}

/* ── Print ───────────────────────────────────────────────── */
@media print {
  @page { margin: 0.8cm; size: letter; }
  html {
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
    zoom: 0.82;
  }
  body { background: white; padding: 0; font-size: 11px; color: #000; }
  .bsf-header {
    background: #1e293b !important; color: white !important;
    border-radius: 6px; padding: 10px 16px; margin-bottom: 10px;
  }
  .card {
    box-shadow: none; border: 1px solid #d1d5db;
    margin-bottom: 10px; border-radius: 6px;
  }
  .card-hdr { background: #f9fafb !important; }
  .bsf-table { page-break-inside: auto; break-inside: auto; }
  .bsf-table tbody.category-section {
    page-break-inside: avoid; break-inside: avoid;
  }
  .bsf-table tbody tr { page-break-inside: avoid; break-inside: avoid; }
  .bsf-table thead { display: table-header-group; }
  .group-row {
    background: #f3f4f6 !important;
    page-break-after: avoid; break-after: avoid;
  }
  .totals-row { page-break-inside: avoid; break-inside: avoid; }
  .pb-track { background: #e5e7eb; }
  .pb-fill { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .badge { border: 1px solid currentColor; }
  .legend-card {
    box-shadow: none; border: 1px solid #d1d5db;
    page-break-inside: avoid; break-inside: avoid;
  }
  .bsf-period-bar { margin-bottom: 10px; }
  .fp-plan { color: #475569; }
  .fp-warn { border-color: #d97706; }
}
</style>")

;;;============================================================
;;; HTML: GROUP HEADER ROW
;;; One row per non-empty group key.  Shows the group name and
;;; the subtotal budgeted / spent / available for that group.
;;;============================================================

(define (bsf-render-group-header group-key records currency)
  (let* ((fmt       (lambda (n) (bsf-fmt-money n currency)))
         (total-bgt (fold + 0.0 (map (lambda (r) (list-ref r 2)) records)))
         (total-act (fold + 0.0 (map (lambda (r) (list-ref r 3)) records)))
         (total-avl (fold + 0.0 (map (lambda (r) (list-ref r 4)) records)))
         (cls       (bsf-avl-class total-avl total-bgt)))
    (string-append
     "<tr class='group-row'>"
     "<td class='group-name'>" (gnc:html-string-sanitize group-key) "</td>"
     "<td class='col-num group-num'>" (fmt total-bgt) "</td>"
     "<td class='col-num group-num'>" (fmt total-act) "</td>"
     "<td class='col-avl group-num'><span class='" cls "'>"
     (fmt total-avl) "</span></td>"
     "</tr>")))

;;;============================================================
;;; HTML: DATA ROW
;;; One row per leaf expense account.
;;;============================================================

;; fp-target: entry from the target alist — (display-name amount date-or-#f) or #f.
(define (bsf-render-data-row rec currency indented? show-progress? fp-target)
  (let* ((display-name (list-ref rec 1))
         (bgt          (list-ref rec 2))
         (act          (list-ref rec 3))
         (avl          (list-ref rec 4))
         (cat-type     (bsf-category-type rec fp-target))
         (cls          (bsf-avl-class avl bgt))
         (fmt          (lambda (n) (bsf-fmt-money n currency)))
         (leaf-name    (cdr (bsf-split-display-name display-name)))
         (name-cls     (if indented? "col-name indent" "col-name")))
    (string-append
     "<tr>"
     "<td class='" name-cls "'>"
     (gnc:html-string-sanitize leaf-name)
     (bsf-category-badge cat-type)
     (bsf-fp-render-plan avl fp-target currency)
     (if show-progress? (bsf-render-progress-bar act bgt cls) "")
     "</td>"
     "<td class='col-num'>" (fmt bgt) "</td>"
     "<td class='col-num'>" (fmt act) "</td>"
     "<td class='col-avl'><span class='" cls "'>" (fmt avl) "</span></td>"
     "</tr>")))

;;;============================================================
;;; HTML: SECTION CARD
;;; Renders one section (Assets / Expenses / Liabilities /
;;; Future Purchases) as a card with group subtotals and a
;;; section total row.  For the Future Purchases section, a
;;; leading "Future Purchases:" prefix is stripped from display
;;; names so the section title is not repeated as a group header.
;;;============================================================

;; plan-targets: alist of (acct amount date-or-#f) entries keyed by account object.
(define (bsf-render-section-card section-name records currency show-progress? plan-targets is-fp-section?)
  (let* ((fmt (lambda (n) (bsf-fmt-money n currency)))
         ;; For the FP section strip the "Future Purchases:" segment so the
         ;; section title is not echoed as a group header in the typical layout.
         (adj-recs
          (if (not is-fp-section?)
              records
              (map (lambda (r)
                     (let* ((dname  (list-ref r 1))
                            (prefix "Future Purchases:")
                            (plen   (string-length prefix)))
                       (if (and (>= (string-length dname) plen)
                                (string=? (substring dname 0 plen) prefix))
                           (list (list-ref r 0)
                                 (substring dname plen)
                                 (list-ref r 2)
                                 (list-ref r 3)
                                 (list-ref r 4)
                                 (list-ref r 5))
                           r)))
                   records)))
         (groups    (bsf-group-records adj-recs))
         (total-bgt (fold + 0.0 (map (lambda (r) (list-ref r 2)) records)))
         (total-act (fold + 0.0 (map (lambda (r) (list-ref r 3)) records)))
         (total-avl (fold + 0.0 (map (lambda (r) (list-ref r 4)) records)))
         (tot-cls   (bsf-avl-class total-avl total-bgt))
         (n-cats    (length records)))
    (string-append
     "<div class='card'>"
     "<div class='card-hdr'>"
     "<span class='card-title'>" (gnc:html-string-sanitize section-name) "</span>"
     "<span class='card-badge'>"
     "<span class='pill pill-count'>"
     (number->string n-cats)
     (if (= n-cats 1) " category" " categories")
     "</span></span>"
     "</div>"
     "<table class='bsf-table'>"
     "<thead><tr>"
     "<th>Category</th>"
     "<th class='r'>Budgeted</th>"
     "<th class='r'>Activity</th>"
     "<th class='r'>Available</th>"
     "</tr></thead>"
     (apply string-append
            (map (lambda (group)
                   (let* ((gkey     (car group))
                          (grecs    (cdr group))
                          (header   (if (string=? gkey "")
                                        ""
                                        (bsf-render-group-header gkey grecs currency)))
                          (indented? (not (string=? gkey "")))
                          (rows     (apply string-append
                                           (map (lambda (r)
                                                  (bsf-render-data-row
                                                   r currency indented? show-progress?
                                                   (assq (list-ref r 0) plan-targets)))
                                                grecs))))
                     (string-append
                      "<tbody class='category-section'>"
                      header rows
                      "</tbody>")))
                 groups))
     "<tbody class='totals-section'>"
     "<tr class='totals-row'>"
     "<td class='col-name'>Section Total</td>"
     "<td class='col-num'>" (fmt total-bgt) "</td>"
     "<td class='col-num'>" (fmt total-act) "</td>"
     "<td class='col-avl'><span class='" tot-cls "'>"
     (fmt total-avl) "</span></td>"
     "</tr>"
     "</tbody>"
     "</table>"
     "</div>")))

;;;============================================================
;;; HTML: GRAND TOTAL CARD
;;; Summarises all sections in a single row beneath the section
;;; cards.
;;;============================================================

(define (bsf-render-grand-total-card total-bgt total-act total-avl currency)
  (let* ((fmt     (lambda (n) (bsf-fmt-money n currency)))
         (tot-cls (bsf-avl-class total-avl total-bgt)))
    (string-append
     "<div class='card'>"
     "<table class='bsf-table'>"
     "<tbody class='totals-section'>"
     "<tr class='totals-row'>"
     "<td class='col-name'>Grand Total</td>"
     "<td class='col-num'>" (fmt total-bgt) "</td>"
     "<td class='col-num'>" (fmt total-act) "</td>"
     "<td class='col-avl'><span class='" tot-cls "'>"
     (fmt total-avl) "</span></td>"
     "</tr>"
     "</tbody>"
     "</table>"
     "</div>")))

;;;============================================================
;;; HTML: ALL SECTIONS
;;; Orchestrates multi-section rendering.  Non-FP records are
;;; split by included-account root and rendered in the order
;;; those roots appear in the option.  Future Purchase records
;;; are extracted and placed in a final "Future Purchases" card.
;;; Empty sections are omitted.  A grand total card follows.
;;;============================================================

(define (bsf-render-all-sections records currency show-progress? plan-targets included-accounts)
  (cond
    ((null? included-accounts)
     (string-append
      "<div class='card'><div class='empty'>"
      "Select accounts in "
      "<em>Options &rarr; Accounts &rarr; Included Accounts</em> to begin."
      "</div></div>"))
    ((null? records)
     (string-append
      "<div class='card'><div class='empty'>"
      "No budget activity found for this period.<br>"
      "Select a budget in <em>Options &rarr; General</em> or enable "
      "<em>Show zero-balance categories</em>."
      "</div></div>"))
    (else
     (let* ((fp-records     (filter (lambda (r) (list-ref r 5)) records))
            (non-fp-records (filter (lambda (r) (not (list-ref r 5))) records))
            (section-data
             (filter-map
              (lambda (root)
                (let ((sec-recs (filter (lambda (r)
                                          (bsf-account-under-root? (list-ref r 0) root))
                                        non-fp-records)))
                  (if (null? sec-recs) #f (cons root sec-recs))))
              included-accounts))
            (gt-bgt (fold + 0.0 (map (lambda (r) (list-ref r 2)) records)))
            (gt-act (fold + 0.0 (map (lambda (r) (list-ref r 3)) records)))
            (gt-avl (fold + 0.0 (map (lambda (r) (list-ref r 4)) records))))
       (string-append
        (apply string-append
               (map (lambda (sec)
                      (bsf-render-section-card
                       (xaccAccountGetName (car sec))
                       (cdr sec)
                       currency show-progress? plan-targets #f))
                    section-data))
        (if (null? fp-records)
            ""
            (bsf-render-section-card
             "Future Purchases" fp-records
             currency show-progress? plan-targets #t))
        (bsf-render-grand-total-card gt-bgt gt-act gt-avl currency))))))

;;;============================================================
;;; HTML: LEGEND
;;; Unified legend for status colors and category type badges.
;;;============================================================

(define (bsf-render-legend)
  (string-append
   "<div class='legend-card'>"

   "<div class='legend-section'>"
   "<span class='legend-title'>Available</span>"
   "<span class='avl-green'>&#9679; Healthy</span>"
   "<span class='avl-yellow'>&#9679; &lt;10% remaining</span>"
   "<span class='avl-red'>&#9679; Overspent</span>"
   "<span class='avl-gray'>&#9679; No activity</span>"
   "</div>"

   "<div class='legend-section'>"
   "<span class='legend-title'>Category types</span>"
   "<span class='badge badge-sf'>Sinking Fund</span>"
   "<span class='badge badge-fp'>Future Purchase</span>"
   "</div>"

   "</div>"))

;;;============================================================
;;; HTML: PLANNING TARGET WARNINGS
;;; Renders a small amber notice block for account-note metadata
;;; warnings.  Returns "" when list is empty.
;;;============================================================

(define (bsf-render-fp-warnings warnings)
  (if (null? warnings)
      ""
      (string-append
       "<div class='fp-warn'>"
       "<div class='fp-warn-ttl'>&#9888; Planning target issues:</div>"
       (apply string-append
              (map (lambda (w)
                     (string-append "<div class='fp-warn-item'>" w "</div>"))
                   warnings))
       "</div>")))

;;;============================================================
;;; MAIN RENDERER
;;;============================================================

(define (bsf-renderer report-obj)
  (let* ((options      (gnc:report-options report-obj))

         (budget             (gnc-optiondb-lookup-value options bsf-tab-general bsf-opt-budget))
         (date-range-preset  (or (gnc-optiondb-lookup-value options bsf-tab-general bsf-opt-date-range) 'ytd))
         (period-start-type  (or (gnc-optiondb-lookup-value options bsf-tab-general bsf-opt-period-start) 'first))
         (period-start-exact (or (gnc-optiondb-lookup-value options bsf-tab-general bsf-opt-period-start-exact) 1))
         (period-end-type    (or (gnc-optiondb-lookup-value options bsf-tab-general bsf-opt-period-end) 'current))
         (period-end-exact   (or (gnc-optiondb-lookup-value options bsf-tab-general bsf-opt-period-exact) 1))
         (show-zeros?        (not (equal? #f (gnc-optiondb-lookup-value options bsf-tab-accounts bsf-opt-show-zeros))))
         (included-accounts  (or (gnc-optiondb-lookup-value options bsf-tab-accounts bsf-opt-included-accounts) '()))
         (exclude-off-budget? (not (equal? #f (gnc-optiondb-lookup-value options bsf-tab-accounts bsf-opt-exclude-off-budget))))
         (hidden-accounts    (or (gnc-optiondb-lookup-value options bsf-tab-accounts bsf-opt-hidden-accounts) '()))
         (show-progress      (not (equal? #f (gnc-optiondb-lookup-value options bsf-tab-display bsf-opt-show-progress))))

         (report-title (let ((n (gnc:report-name report-obj)))
                         (if (and n (not (string=? n "")))
                             n
                             bsf-report-name)))

         (now      (current-time))
         (date-str (strftime "%B %-d, %Y" (localtime now)))
         (currency (gnc-default-report-currency))

         (document (gnc:make-html-document)))

    (gnc:html-document-add-object!
     document
     (gnc:make-html-text
      (string-append
       bsf-css

       ;; ── Page header ──────────────────────────────────────────────
       "<div class='bsf-header'>"
       "<h1>" (gnc:html-string-sanitize report-title) "</h1>"
       "</div>"

       (if (not budget)

           (string-append
            "<div class='card'><div class='empty'>"
            "Select a budget in "
            "<em>Options &rarr; General &rarr; Budget</em> to begin."
            "</div></div>")

           (let* ((period-range (bsf-resolve-preset budget date-range-preset
                                                    period-start-type period-start-exact
                                                    period-end-type   period-end-exact))
                  (start-period (car period-range))
                  (end-period   (cdr period-range))
                  (period-lbl  (bsf-period-label budget start-period end-period))
                  (records     (bsf-collect-data budget start-period end-period show-zeros?
                                                  exclude-off-budget? hidden-accounts included-accounts))
                  ;; Read planning targets from account notes (all leaf records).
                  (note-parsed    (bsf-note-targets-for-records records))
                  (plan-targets   (car note-parsed))
                  (plan-warnings  (cdr note-parsed)))

             (string-append

              ;; ── Period info ──────────────────────────────────────
              "<div class='bsf-period-bar'>"
              (if (= start-period end-period)
                  "Single period &mdash; "
                  "Cumulative totals &mdash; ")
              "<strong>" (gnc:html-string-sanitize period-lbl) "</strong>"
              "<br>As of " (gnc:html-string-sanitize date-str)
              "</div>"

              ;; ── Target parse warnings (unobtrusive, amber) ───────
              (bsf-render-fp-warnings plan-warnings)

              ;; ── Section cards ────────────────────────────────────
              (bsf-render-all-sections records currency show-progress plan-targets included-accounts)

              ;; ── Legend ───────────────────────────────────────────
              (bsf-render-legend)))))))

    document))

;;;============================================================
;;; REPORT REGISTRATION
;;;============================================================

(gnc:define-report
 'version           1
 'name              bsf-report-name
 'report-guid       bsf-report-guid
 'menu-path         (list gnc:menuname-budget)
 'options-generator bsf-options-generator
 'renderer          bsf-renderer)
