#lang racket/base
;; cordis/plugin: the plugin struct API (contract section 6) and `define-plugin` (section 9).
;;
;; A plugin is data: a body procedure with its name, the services it injects, a config
;; schema, the services it declares to provide, and a custodian mode. `ctx-plugin` mounts
;; one on a context. `define-plugin` declares one and binds its injected services in the
;; body; `plugin-info` returns a plugin's declaration as a hash.
(require "private/plugin-api.rkt"
         "private/define-plugin.rkt")
(provide (all-from-out "private/plugin-api.rkt")
         (all-from-out "private/define-plugin.rkt"))
