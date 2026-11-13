#lang racket/base
;; cordis/plugin: the plugin struct API (contract section 6).
;;
;; A plugin is data: a body procedure with its name, the services it injects, a config
;; schema, the services it declares to provide, and a custodian mode. `ctx-plugin` mounts
;; one on a context.
(require "private/plugin-api.rkt")
(provide (all-from-out "private/plugin-api.rkt"))
