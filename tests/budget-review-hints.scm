;; Run from repository root: guile --no-auto-compile tests/budget-review-hints.scm
(use-modules (ice-9 format) (srfi srfi-1) (srfi srfi-13) (srfi srfi-64))
(define wanted '(bsf-account-under-root? bsf-account-under-any? bsf-review-surplus-lots bsf-review-lots bsf-compute-review-data bsf-render-review-hint
                 bsf-category-type bsf-cumulative-budgeted bsf-cumulative-actual
                 bsf-select-actual bsf-compute-ytd-data bsf-render-data-row))
(call-with-input-file "budget-sinking-funds.scm"
  (lambda (port)
    (let loop ((form (read port)))
      (unless (eof-object? form)
        (when (and (pair? form) (eq? (car form) 'define)
                   (pair? (cadr form)) (memq (caadr form) wanted))
          (eval form (current-module)))
        (loop (read port))))))
(define (gnc-account-get-full-name a)
  (case a ((expense) "Expenses:Example Utility")
          ((groceries) "Expenses:Groceries")
          ((expenses) "Expenses")
          ((other) "Expenses:Example Utility Other")
          (else (symbol->string a))))
(define ACCT-TYPE-EXPENSE 9)
(define (xaccAccountGetType a) ACCT-TYPE-EXPENSE)
(define (gnc-numeric-to-double n) n)
(define allocations '(0 0 0 0 0 0 200 0 0))
(define actuals '(0 0 0 0 0 0 0 0 0))
(define calls 0)
(define (gnc-budget-get-account-period-value b a p)
  (set! calls (1+ calls)) (list-ref allocations p))
(define (gnc-budget-get-account-period-actual-value b a p)
  (set! calls (1+ calls)) (list-ref actuals p))
(define (gnc-commodity-get-fraction currency)
  (case currency ((JPY) 1) ((KWD) 1000) (else 100)))
(define (gnc-budget-get-period-start-date b p)
  (car (mktime (vector 0 0 12 1 p 126 0 0 -1 0 "UTC"))))
(define (gnc:html-string-sanitize s) s)
(define GNC-RND-ROUND 0)
(define (double-to-gnc-numeric n fraction rounding)
  (/ (inexact->exact (round (* n fraction))) fraction))
(define (gnc:make-gnc-monetary currency n) (cons currency n))
(define (gnc:monetary->string money)
  (let ((digits (case (car money) ((JPY) 0) ((KWD) 3) (else 2))))
    (string-append (if (eq? (car money) 'USD) "$" (symbol->string (car money)))
                   (format #f "~v,f" digits (exact->inexact (cdr money))))))
(define normal '(expense "Example Utility" 200 0 200 #f))
(define (data start end . currency)
  (bsf-compute-review-data #t 'b (list normal) '() start end #f
                           (if (null? currency) 'USD (car currency)) '(expense)))
(test-begin "budget-review-hints")
(test-equal "July allocation carried through September once"
  '((expense (6 . 200))) (data 0 8))
(test-equal "carryovers are not new contributions"
  '((0 . 200)) (bsf-review-lots '(200 0 0 0)))
(set! allocations '(0 0 0 0 0 0 100 75 25))
(test-equal "all contributing periods, chronological"
  '((expense (6 . 100) (7 . 75) (8 . 25))) (data 0 8))
(test-equal "later expenses consume oldest surplus first"
  '((1 . 75) (2 . 25)) (bsf-review-lots '(100 75 25 -100)))
(test-equal "earlier deficit consumes later funding"
  '((1 . 40)) (bsf-review-lots '(-60 100)))
(test-equal "negative budget adjustment consumes surplus"
  '((0 . 64)) (bsf-review-lots '(100 -36)))
(test-equal "deficit larger than savings clears all old lots"
  '((3 . 20)) (bsf-review-lots '(100 50 -200 70)))
(test-equal "no remaining balance" '() (bsf-review-lots '(100 -100)))
(test-equal "refund is dated to its posting period"
  '((2 . 36)) (bsf-review-lots '(100 -100 36)))
(set! allocations '(0 0 0 0 0 0 100 0 0))
(set! actuals '(0 0 0 0 0 0 99.64 0 0))
(set! normal '(expense "Example Utility" 100 99.64 0.36 #f))
(test-equal "small residual remains exact" '((expense (6 . 9/25))) (data 0 8))
(test-assert "formatted residual"
  (string-contains (bsf-render-review-hint 'b '((6 . 9/25)) 'USD)
                   "Jul 2026 ($0.36)"))
(test-assert "convention visible"
  (string-contains (bsf-render-review-hint 'b '((6 . 200)) 'USD) "estimated cumulative balance, net surplus FIFO"))
(test-assert "multiple wording"
  (string-contains (bsf-render-review-hint 'b '((6 . 100) (7 . 75)) 'USD)
                   "Review budget periods:"))
(test-equal "empty annotation" "" (bsf-render-review-hint 'b '() 'USD))
(test-equal "only current-period surplus needs no historical hint" '() (data 6 6))
(set! calls 0)
(test-equal "disabled" '()
  (bsf-compute-review-data #f 'b (list normal) '() 0 8 #f 'USD '(expense)))
(test-equal "disabled has no budget queries" 0 calls)
(test-equal "sinking fund excluded" '()
  (bsf-compute-review-data #t 'b (list normal) '((expense target)) 0 8 #f 'USD '()))
(test-equal "future purchase excluded" '()
  (bsf-compute-review-data #t 'b '((expense "Future" 100 0 100 #t)) '() 0 8 #f 'USD '()))
(test-equal "excluded categories have no budget queries" 0 calls)
(test-equal "empty selection shows no hints" '()
  (bsf-compute-review-data #t 'b (list normal) '() 0 8 #f 'USD '()))
(test-equal "unselected account shows no hints" '()
  (bsf-compute-review-data #t 'b (list normal) '() 0 8 #f 'USD '(groceries)))
(test-equal "similar names do not include category" '()
  (bsf-compute-review-data #t 'b (list normal) '() 0 8 #f 'USD '(other)))
(test-equal "unselected accounts cause no budget queries" 0 calls)
(test-equal "selected account shows hints"
  '((expense (6 . 9/25)))
  (bsf-compute-review-data #t 'b (list normal) '() 0 8 #f 'USD '(expense)))
(test-equal "selected parent includes descendants"
  '((expense (6 . 9/25)))
  (bsf-compute-review-data #t 'b (list normal) '() 0 8 #f 'USD '(expenses)))
(test-equal "selected sinking fund still excluded" '()
  (bsf-compute-review-data #t 'b (list normal) '((expense target)) 0 8 #f 'USD '(expense)))
(test-equal "selected future purchase still excluded" '()
  (bsf-compute-review-data #t 'b '((expense "Future" 100 0 100 #t)) '() 0 8 #f 'USD '(expense)))
(test-equal "selection leaves category record unchanged"
  '(expense "Example Utility" 100 99.64 0.36 #f) normal)
(set! normal '(expense "Example Utility" 0 0 0 #f))
(test-equal "zero monthly balance still explains earlier savings"
  '((expense (6 . 9/25))) (data 8 8))
(set! actuals '(0 0 0 0 0 0 100 0 0))
(test-equal "zero cumulative balance" '() (data 8 8))
(set! normal '(expense "Example Utility" 200 0 200 #f))
(set! allocations '(0 0 0 0 0 0 200 0 0))
(set! actuals '(0 0 0 0 0 0 0 0 0))
(test-equal "selected end before funding" '() (data 0 5))
(test-equal "current month includes July funding"
  '((expense (6 . 200))) (data 8 8))
(test-equal "narrow range retains earlier funding"
  '((expense (6 . 200))) (data 7 8))
(test-equal "selected start includes funding" '((expense (6 . 200))) (data 6 8))
(set! actuals '(0 0 0 0 0 0 30 -10 0))
(set! normal '(expense "Example Utility" 200 20 180 #f))
(test-equal "signed expense refunds preserved in existing totals"
  '((expense 200 20 180)) (bsf-compute-ytd-data 'b (list normal) #f 8))
(set! normal '(expense "Example Utility" 0 0 0 #f))
(test-equal "current-month zero Available does not hide cumulative hint"
  '((expense (6 . 170) (7 . 10))) (data 8 8))
(set! normal '(expense "Example Utility" 0 50 -50 #f))
(set! actuals '(0 0 0 0 0 0 30 -10 50))
(test-equal "current-month deficit consumes earlier savings"
  '((expense (6 . 120) (7 . 10))) (data 8 8))
(set! actuals '(0 0 0 0 0 0 30 -10 0))
(define before (bsf-compute-ytd-data 'b (list normal) #f 8))
(data 0 8)
(test-equal "existing cumulative totals unchanged" before
  (bsf-compute-ytd-data 'b (list normal) #f 8))
(test-equal "cumulative Available unchanged" 180 (list-ref (car before) 3))
(set! actuals '(0 0 0 0 0 0 0 0 0))
(set! allocations '(0 0 0 0 0 0 0.001 0 0))
(set! normal '(expense "Example Utility" 0.001 0 0.001 #f))
(test-equal "three decimal currency units" '((expense (6 . 1/1000))) (data 0 8 'KWD))
(test-assert "three decimal currency rendering"
  (string-contains (bsf-render-review-hint 'b '((6 . 1/1000)) 'KWD) "KWD0.001"))
(test-assert "zero decimal currency rendering"
  (string-contains (bsf-render-review-hint 'b '((6 . 200)) 'JPY) "JPY200)"))
;; Synthetic deficit fixtures: October spending viewed in November.
(test-equal "multiple deficits remain chronological"
  '((0 . -100) (1 . -75) (2 . -25)) (bsf-review-lots '(-100 -75 -25)))
(test-equal "later surplus covers oldest deficit first"
  '((1 . -75) (2 . -25)) (bsf-review-lots '(-100 -75 -25 100)))
(test-equal "earlier surplus covers later deficit"
  '((1 . -40)) (bsf-review-lots '(60 -100)))
(test-equal "covered deficits disappear" '() (bsf-review-lots '(-100 100)))
(test-equal "crossing through zero attributes only uncovered spending"
  '((3 . -20)) (bsf-review-lots '(-100 -50 200 -70)))
(set! allocations (make-list 12 0))
(set! actuals '(0 0 0 0 0 0 0 0 0 4000 0 0))
(set! normal '(expense "Example Travel" 0 0 0 #f))
(test-equal "November identifies uncovered October spending"
  '((expense (9 . -4000))) (data 10 10))
(test-equal "report before spending excludes future deficit" '() (data 8 8))
(test-equal "only current-period deficit needs no historical hint" '() (data 9 9))
(test-equal "existing cumulative deficit remains unchanged"
  '((expense 0 4000 -4000)) (bsf-compute-ytd-data 'b (list normal) #f 10))
(set! allocations '(0 0 0 0 0 0 0 0 0 0 1000 0))
(test-equal "November funding partially covers October deficit"
  '((expense (9 . -3000))) (data 10 10))
(set! actuals '(0 0 0 0 0 0 0 0 0 4000 500 0))
(test-equal "November net surplus covers October deficit"
  '((expense (9 . -3500))) (data 10 10))
(set! allocations '(0 0 0 0 0 0 0 0 0 0 4500 0))
(test-equal "fully covered cumulative deficit has no hint" '() (data 10 10))
(set! allocations (make-list 12 0))
(set! actuals '(0 0 0 0 0 0 0 0 0 0.36 0 0))
(test-equal "small uncovered deficit stays exact"
  '((expense (9 . -9/25))) (data 10 10))
(test-assert "deficit rendering retains period and sign"
  (string-contains (bsf-render-review-hint 'b '((9 . -4000)) 'USD)
                   "Oct 2026 ($-4000.00)"))
(test-assert "deficit convention visible"
  (string-contains (bsf-render-review-hint 'b '((9 . -4000)) 'USD)
                   "estimated cumulative deficit, net deficit FIFO"))
(test-assert "fractional non-USD deficit rendering"
  (string-contains (bsf-render-review-hint 'b '((9 . -1/1000)) 'KWD)
                   "KWD-0.001"))
(set! calls 0)
(test-equal "deficit disabled" '()
  (bsf-compute-review-data #f 'b (list normal) '() 10 10 #f 'USD '(expense)))
(test-equal "deficit unselected" '()
  (bsf-compute-review-data #t 'b (list normal) '() 10 10 #f 'USD '(groceries)))
(test-equal "deficit sinking fund excluded" '()
  (bsf-compute-review-data #t 'b (list normal) '((expense target)) 10 10 #f 'USD '(expense)))
(test-equal "deficit future purchase excluded" '()
  (bsf-compute-review-data #t 'b '((expense "Future" 0 0 0 #t)) '() 10 10 #f 'USD '(expense)))
(test-equal "excluded deficits cause no queries" 0 calls)
;; Exercise actual row rendering without requiring the GnuCash GUI.
(define (bsf-avl-class a b) "ok")
(define (bsf-fmt-money a c) "amount")
(define (bsf-split-display-name s) (cons "" s))
(define (bsf-category-badge c) "")
(define (bsf-fp-render-plan f t c) "")
(define (bsf-render-progress-bar a b c) "<progress/>")
(test-assert "annotation follows progress bar"
  (string-contains
   (bsf-render-data-row normal 'USD #f #t #f #f #f "HINT")
   "<progress/>HINT</td>"))
(test-assert "renderer independently excludes sinking funds"
  (not (string-contains
        (bsf-render-data-row normal 'USD #f #t '(expense target) #f #f "HINT") "HINT")))
(test-assert "renderer independently excludes future purchases"
  (not (string-contains
        (bsf-render-data-row '(expense "Future" 1 0 1 #t) 'USD #f #t #f #f #f "HINT") "HINT")))
(define runner (test-runner-current))
(test-end "budget-review-hints")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
