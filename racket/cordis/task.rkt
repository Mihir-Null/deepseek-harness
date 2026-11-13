#lang racket/base
;; cordis/task: cooperative tasks on threads (contract section 2), usable without a context.
;;
;; A scheduler owns one baton; a task is a thread that runs only while it holds the baton.
;; `await` and the other wait points release the baton and reacquire it, in FIFO order,
;; before they return or raise. A task runs with breaks disabled: a break is raised only at
;; a wait point or by `task-check-break`, and not where the code masks breaks itself
;; (`parameterize-break #f`, an exception handler, a `dynamic-wind` pre or post thunk).
(require racket/contract/base
         "private/scheduler.rkt"
         "private/errors.rkt")

(provide
 (struct-out exn:fail:cordis)
 (struct-out exn:fail:cordis:task-killed)
 (contract-out
  [make-scheduler (->* () (#:name symbol? #:custodian custodian?) scheduler?)]
  [scheduler? (-> any/c boolean?)]
  ;; Stops the manager; tasks that wait for the baton never run. Idempotent.
  [scheduler-shutdown! (-> scheduler? void?)]
  [current-scheduler (parameter/c (or/c scheduler? #f))]
  ;; Milliseconds a task may hold the baton before a warning is logged; #f disables it.
  [current-baton-warn-ms (parameter/c (or/c #f (>=/c 0)))]
  ;; The new task is queued for the baton before `spawn-task` returns.
  [spawn-task (->* ((-> any))
                   (#:name (or/c symbol? string? #f) #:scheduler scheduler?)
                   task?)]
  [task? (-> any/c boolean?)]
  [task-done? (-> task? boolean?)]
  ;; The thunk's values; re-raises what it raised; `exn:fail:cordis:task-killed` if the
  ;; task's thread died first. Waits when the task has not finished.
  [task-result (-> task? any)]
  [task-thread (-> task? thread?)]
  ;; Breaks the task's thread: the break is raised at the task's next wait point.
  [task-cancel! (-> task? void?)]
  ;; Kills the task's thread, wherever it is; nothing in the task runs after that.
  [task-kill! (-> task? void?)]
  [in-task? (->* () ((or/c scheduler? #f)) boolean?)]
  [await (-> evt? any)]
  [await/timeout (->* ((>=/c 0) evt?) ((-> any)) any)]
  [await-all (-> (listof evt?) list?)]
  [yield-task (-> void?)]
  ;; Raises a break that is pending for the calling task; otherwise returns at once.
  [task-check-break (-> void?)]
  [task-sleep (-> (>=/c 0) void?)]
  [blocking (-> (-> any) any)]
  [call-in-kernel (->* ((-> any)) (#:scheduler scheduler?) any)]))
