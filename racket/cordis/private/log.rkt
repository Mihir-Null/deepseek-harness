#lang racket/base
;; The `cordis` logger. Kernel diagnostics are logged on it with topic `cordis` and, for
;; errors, with the raised value as the log event's data.
(provide cordis-logger log-cordis)

(define cordis-logger (make-logger 'cordis (current-logger)))

;; level : (or/c 'fatal 'error 'warning 'info 'debug)
(define (log-cordis level message [data #f])
  (when (log-level? cordis-logger level 'cordis)
    (log-message cordis-logger level 'cordis message data #t)))
