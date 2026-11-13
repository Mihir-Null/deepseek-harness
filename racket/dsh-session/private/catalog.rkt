#lang racket/base
;; The constant sets of event type names: every type this build knows, the surface-eligible
;; types, and the types that need a message projection. They are constants of the build and
;; never depend on which plugins are loaded. `dsh-session/events` re-exports them.

(require racket/set
         "names.rkt")

(provide known-session-event-types
         surface-event-types
         message-projection-event-types)

;; source: packages/core/session/src/known-event-types.ts (KNOWN_SESSION_EVENT_TYPES)
(define known-session-event-types
  (set "agent-preset/selected"
       "agent/inbox/spliced"
       "approval/asked"
       "approval/decided"
       "approval/policy"
       "assistant/attempt"
       "assistant/message"
       "command/done"
       "command/run"
       "compaction/end"
       "compaction/prune"
       "compaction/start"
       "compaction/summary"
       "deliverables/presented"
       "developer/message"
       "feedback/message-delete"
       "feedback/message-put"
       "feedback/record"
       "goal/change"
       "hook/invoked"
       "hook/result"
       "image/offload"
       "job/registered"
       "job/settled"
       "llm/retry"
       "llm/retry-started"
       "model/selection"
       "permission/preset"
       "plan/mode"
       "request/context"
       "request/header"
       "sandbox/mode"
       "schedule/change"
       "session-log-deepseek/delivery-accepted"
       "session/end-seed"
       "session/title"
       "session/title-llm-request"
       "step/end"
       "step/start"
       "subagent/catalog"
       "subagent/descriptor"
       "subagent/model-selection-policy"
       "system/message"
       "team/member"
       "team/message/delivered"
       "team/message/queued"
       "team/mode"
       "team/task"
       "todo/write"
       "tool-workflow/agent-end"
       "tool-workflow/agent-start"
       "tool-workflow/run-end"
       "tool-workflow/run-start"
       "tool/call"
       "tool/ptc-dispatch"
       "tool/ptc-dispatch-start"
       "tool/result"
       "turn/end"
       "turn/start"
       "user/message"
       "web/deepseek-search-llm-request"
       "working-directory/change"
       "workspace/changes"))

;; source: packages/core/session/src/surface.ts (SURFACE_EVENT_TYPES)
(define surface-event-types
  (list->set surface-event-type-names))

;; source: packages/core/session/src/known-event-types.ts (MESSAGE_PROJECTION_EVENT_TYPES)
(define message-projection-event-types
  (set "image/offload"))
