# Recon 20: Racket mechanisms and ecosystem checks

This note records what the installed Racket can do for the port, checked by running code. It does not study a dsh package area, so it uses the section headings the task assigned instead of the standard recon headings. Pinned dsh commit: `e8f7b93a3`. Host: Ubuntu 24.04.5, Linux 6.18 x86_64, 4 CPUs, 15 GB RAM.

Every statement marked **Observed** comes from a program that was run on this machine during the recon (2026-11-13). Each snippet in [Mechanism probes](#mechanism-probes) is a complete program: save it as a `.rkt` file and run it with `racket file.rkt`. All 28 snippets were extracted from the finished note and run once more, each exiting with status 0; the output blocks are the output of those programs. Millisecond figures vary by run. The longer exploratory probes lived in a session scratch directory that is not kept; everything needed to repeat them is inline here.

Cross-references: the kernel design these findings feed is [cordis-analysis.md](../cordis-analysis.md) (sections 4.1 to 4.10) and the kernel behavior is in [01-cordis-core.md](01-cordis-core.md). Section [Recommendations](#recommendations) lists where the findings confirm that design and where they require a change.

## Installed distribution

**Version and layout.** `racket --version` prints `Welcome to Racket v9.3 [cs].` The binaries are `/usr/local/bin/racket` and `/usr/local/bin/raco`; the installation is under `/opt/racket` (`collects/`, `share/pkgs/`, `etc/config.rktd`, and the full HTML documentation in `/opt/racket/doc`, 152 manuals, usable offline). The VM is Chez Scheme (`(system-type 'vm)` is `chez-scheme`), platform `x86_64-linux`.

**Full or minimal.** This is the full distribution. `raco pkg show --all | wc -l` printed 240 at the start of the recon: 235 installation-scope packages plus header lines, and an empty user scope. The package `main-distribution` is installed. The packages recorded as explicitly installed (not as dependencies) are `main-distribution`, `racket-lib`, `http-easy`, `megaparsack` and `threading`; the last three are additions to the main distribution and bring dependencies with them (among them `http-easy-lib`, `actor-lib`, `resource-pool-lib`, `megaparsack-lib`, `functional-lib`, `collections-lib`, `curly-fn-lib`, `match-plus`, `namespaced-transformer-lib`, `static-rename-lib`, `threading-lib`).

**Catalogs** (`raco pkg config catalogs`): `https://download.racket-lang.org/releases/9.3/catalog/`, `https://download.rhombus-lang.org/releases/current/catalog/`, `https://pkgs.racket-lang.org`, `https://planet-compats.racket-lang.org`.

**Collections that load** (each checked with `(dynamic-require 'X (void))`):

| Requested | Result |
|---|---|
| `racket/sandbox` | loads |
| `web-server/servlet-env`, `web-server/servlet`, `web-server/dispatch`, `web-server/web-server`, `web-server/safety-limits` | load |
| `net/http-client`, `net/url`, `net/url-connect`, `net/head`, `net/base64`, `net/uri-codec`, `net/cookies` | load |
| `net/http-easy` | loads (package `http-easy` is preinstalled) |
| `net/rfc6455` (WebSocket) | **does not load**; package `rfc6455` is not installed. See below |
| `json` | loads; `(submod json for-extension)` also exports `read-json*` and `write-json*` |
| `db`, `db/sqlite3` | load; `(sqlite3-available?)` is `#t` |
| `file/glob`, `file/sha1`, `file/md5`, `file/gunzip`, `file/gzip`, `file/tar`, `file/untar`, `file/zip`, `file/unzip` | load |
| `racket/unit`, `racket/class`, `racket/generic`, `racket/contract`, `racket/control`, `racket/generator`, `racket/engine` | load |
| `syntax/parse`, `syntax/module-reader`, `racket/rerequire`, `compiler/cm`, `racket/runtime-path`, `racket/lazy-require` | load |
| `rackunit`, `rackunit/text-ui` | load |
| `typed/racket` | loads |
| `racket/place`, `racket/future` | load; `(place-enabled?)` and `(futures-enabled?)` are `#t`, `(processor-count)` is 4 |
| `ffi/unsafe`, `ffi/unsafe/custodian`, `ffi/unsafe/port`, `ffi/unsafe/os-thread` | load |
| `openssl`, `openssl/libcrypto`, `openssl/libssl` | load; `ssl-available?` is `#t`; client protocols `(secure auto tls tls11 tls12 tls13)` |
| `racket/async-channel`, `data/queue`, `data/heap`, `data/gvector`, `data/skip-list`, `racket/treelist` | load |
| `scribble/base`, `scribble/manual` | load |
| `parser-tools/lex`, `parser-tools/yacc`, `megaparsack`, `threading`, `data/collection`, `actor` | load |
| `racket/logging`, `racket/serialize`, `racket/fasl`, `racket/date`, `srfi/19`, `racket/cmdline`, `expeditor`, `readline`, `xml`, `html` | load |
| `yaml` | **did not load** at the start; installed during this recon. See below |
| `racket/pty`, `crypto`, `uuid`, `libuuid`, `gregor`, `sha`, `zstd`, `lz4`, `brotli`, `rhombus`, `resource-pool`, `data/ring-buffer` | do not exist here |

**SQLite.** `(sqlite3-available?)` returns `#t`. The library is the system `libsqlite3.so.0`, version 3.45.1, compiled with JSON functions, FTS5, R-Tree and WAL support (`pragma compile_options` lists `ENABLE_FTS5`, `ENABLE_RTREE`, `THREADSAFE=1`; `select json_extract(...)` works). There is no `sqlite3` command-line tool on PATH.

**YAML.** The catalog package is `yaml` (source `github://github.com/esilkensen/yaml/master`, checksum `1f131712adbb1dca3b98a39400569c8209ac1944`, MIT, pure Racket, about 5,600 lines, a port of PyYAML; dependencies `base`, `srfi-lite-lib`, `typed-racket-lib`, all present). It was not installed. As the task directed, `raco pkg install --auto --scope user yaml` was run: it resolved the name through the configured catalogs, downloaded from GitHub, compiled, built documentation and finished with exit code 0 in 39 seconds, with no proxy or TLS error and no extra settings. It is now installed in user scope (`/root/.local/share/racket/9.3/pkgs/yaml`). What the package does and does not do for the `cordis.yml` dialect is in [YAML](#yaml).

**WebSocket.** Package `rfc6455` (source `https://git.leastfixedpoint.com/tonyg/racket-rfc6455.git`, checksum `e3a87e914e25841a6e1bb996aa001aeb178284bf`, about 1,600 lines; the file header states LGPL-3.0; dependencies `base`, `net-lib`, `rackunit-lib`, `web-server-lib`, all present). `raco pkg install --auto --scope user --no-docs rfc6455` succeeded in 8 seconds. It was used for the probe in [WebSocket](#websocket) and then removed again with `raco pkg remove --scope user rfc6455`, so that the user scope holds only what the task asked for. `web-server` itself has no WebSocket module in this version.

**Zstandard.** No Racket binding is installed. The shared library is present: `ldconfig -p | grep zstd` prints `libzstd.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libzstd.so.1` (version 1.5.5). There is no unversioned `libzstd.so`, so an FFI load must name the version: `(ffi-lib "libzstd" '("1" #f))`. **Observed:** a 12-line FFI binding of `ZSTD_compressBound`, `ZSTD_compress`, `ZSTD_decompress` and `ZSTD_isError` compressed 11,000 bytes to 29 and round-tripped. The catalog offers `zstd` (`git+https://git.sr.ht/~williewillus/racket-zstd`, FFI bindings; exports `(compress bytes level)` and `(decompress bytes)`; it installed without error into an isolated add-on directory) and `libzstd` (ships the shared library for Linux and macOS). There is no `zstd` command-line tool.

**Other native libraries present** (`ldconfig -p`): `libssl.so.3`, `libcrypto.so.3`, `libz.so.1`, `libyaml-0.so.2`, `liblz4.so.1`, `libbrotlienc/dec.so.1`, `libuuid.so.1`, `libffi.so.8`, `libpcre2-8.so.0`.

**Other tools on PATH:** `node` v22.23.4 (the repository asks for Node 24.9 or later, so running the TypeScript dsh here was not attempted in this recon), `python3` 3.13.18, `git`, `curl`, `script`, `setsid`, `unshare`. Not present: `bwrap`, `zstd`, `sqlite3`.

**Start-up time** (wall clock of one fresh process, compiled libraries):

| Command | ms |
|---|---|
| `racket -n -e ''` | 75 |
| `racket -l racket/base -e ''` | 109 |
| `racket -l racket -e ''` | 257 |
| `racket/base` + `json` + `racket/contract` | 197 |
| `racket/base` + `racket/class` | 245 |
| `racket/base` + `racket/sandbox` | 259 |
| `racket/base` + `db` | 269 |
| `racket/base` + `syntax/parse` (at run time) | 279 |
| `racket/base` + `net/http-easy` | 321 |
| `typed/racket/base` | 324 |
| `racket/base` + `yaml` | 505 |
| `racket/base` + `web-server/servlet-env` | 606 |

A `raco exe` launcher for a small command-line program took 1.6 s to build, is 6.2 MB, and starts in about 210 ms; `raco distribute` produced a 56 MB self-contained directory that ran from another working directory with its `define-runtime-path` data. A module loaded from source takes about 20 ms where the same module from a `.zo` file takes 1 ms.

## Network and install method

**Does `raco pkg install` from the catalog work here?** Yes, with no extra settings. **Observed:**

- `raco pkg install --auto --scope user yaml`: success, 39 s (most of it compiling and building documentation).
- `raco pkg install --auto --scope user --no-docs rfc6455`: success, 8 s. The source is a git repository on a host other than GitHub.
- `PLTADDONDIR=<dir> raco pkg install --auto --scope user --no-docs zstd`: success, 6 s. The source is `git+https://git.sr.ht/...`.
- `raco pkg catalog-show <name>` answers for every name tried.

**Why no settings were needed.** Outbound HTTPS in this environment goes through a local proxy at `http://127.0.0.1:33327` that re-terminates TLS. Racket's `net/url` reads `HTTPS_PROXY` and `NO_PROXY` from the environment: `(current-proxy-servers)` is `((https 127.0.0.1 33327 #f))` in a fresh process. Racket's OpenSSL binding reads `SSL_CERT_FILE`: `(ssl-default-verify-sources)` is `(/root/.ccr/ca-bundle.crt (directory /usr/lib/ssl/certs))`, and that bundle contains the proxy's CA. A verified request (`(parameterize ([current-https-protocol 'secure]) (get-pure-port (string->url "https://pkgs.racket-lang.org/pkg/yaml")))`) succeeded. No TLS or proxy error occurred at any point, so nothing from `/root/.ccr/README.md` had to be applied.

**Proxy awareness differs by library. Observed:**

- `net/url` (`get-pure-port` and friends): uses the proxy from the environment.
- `net/http-easy`: a default session reached an HTTPS host; an explicit `(make-session #:proxies (list (make-https-proxy "http://127.0.0.1:33327")))` also works.
- `net/http-client` (`http-sendrecv`, `http-conn-open`): has no proxy logic. A proxied request needs `http-conn-CONNECT-tunnel` to the proxy and then `http-conn-open!` with the returned ports; this worked with `(ssl-secure-client-context)`. A direct `http-sendrecv` to an HTTPS host also returned 200 in this session, so direct egress was possible for that host; the port must not rely on that.
- **TLS verification is off by default.** `#:ssl? #t` and `current-https-protocol`'s default `'auto` do not verify certificates: a client connected with `'auto` to a local server using the self-signed `openssl/test.pem` and read data; with `'secure` or `(ssl-secure-client-context)` the same connection failed with `certificate verify failed`. Every provider adapter must pass a secure context.

**Isolating installs.** `PLTADDONDIR=/abs/path` gives a process its own user scope (packages, links file, compiled files). This was used for four separate installs. The path must be absolute and free of `..`: a value such as `$PWD/../addon` made `raco pkg` fail with `find-relative-path: contract violation ... expected: (and/c path-for-some-system? simple-form?)`.

**Hermetic builds and tests when the network is unavailable.** Three approaches were run:

1. *Vendor and link.* Copy the package source into the repository and install it as a link. **Observed:** `raco pkg install --link --scope user --no-docs --batch --deps fail ./vendor/yaml ./vendor/rfc6455` into a fresh `PLTADDONDIR` took 16 s (compilation of yaml's Typed Racket modules dominates) and needed no network, because every dependency of both packages is in the main distribution. `--deps fail` turns a missing dependency into an error instead of a download.
2. *Link the repository's own packages.* `raco pkg install --link --scope user --no-docs --batch --deps fail ./cordis-lib ./dsh-core` worked for two local packages where the second depends on the first.
3. *No install at all.* `PLTCOLLECTS=":/abs/pkg-a:/abs/pkg-b" raco test path/to/file.rkt` resolves collections from the listed roots (the leading colon keeps the default collection paths). `racket -S dir` does the same for `racket`.

Tests must not reach the network: start servers on `127.0.0.1` with port `0` and read the real port back (shown in [HTTP client streaming and web-server](#http-client-streaming-and-web-server)), and gate live-API tests on an environment variable the way dsh gates on `DEEPSEEK_API_KEY`.

**State this recon left on the machine.** User scope now contains `yaml` only. `rfc6455` was installed and removed; `raco pkg` keeps the removed copy under `/root/.local/share/racket/9.3/pkgs/.trash/`. Nothing was installed in installation scope.

## Mechanism probes

### Custodians

```racket
#lang racket/base
(require racket/tcp ffi/unsafe/custodian)
(define parent (make-custodian))
(define child (make-custodian parent))
(define-values (t listener sp)
  (parameterize ([current-custodian child]
                 [current-subprocess-custodian-mode 'kill]   ; default #f leaves the process running
                 [subprocess-group-enabled #t])              ; kill the whole process group
    (define-values (sp out in err) (subprocess #f #f #f "/bin/sleep" "30"))
    (values (thread (lambda () (sleep 30))) (tcp-listen 0 4 #t "127.0.0.1") sp)))
(define cbox (make-custodian-box child 'alive))               ; value becomes #f, and the box is a ready evt
(define registry (make-hasheq))
(hash-set! registry 'my-tool 'registered)                     ; plain data: no custodian knows about it
(define order '())
(define keep (for/list ([i 12])                                ; shutdown callbacks: atomic mode, order unspecified
               (define v (vector i))
               (register-custodian-shutdown v (lambda (v) (set! order (cons (vector-ref v 0) order))) child)
               v))
(custodian-shutdown-all parent)                               ; shuts down child first, then parent's own items
(sleep 0.1)
(printf "thread dead: ~a\n" (thread-dead? t))
(printf "listener closed: ~a\n" (with-handlers ([exn:fail? (lambda (e) #t)]) (tcp-accept-ready? listener) #f))
(printf "subprocess status: ~a\n" (subprocess-status sp))
(printf "custodian box: ~a, ready as evt: ~a\n" (custodian-box-value cbox) (and (sync/timeout 0 cbox) #t))
(printf "registry entry still present: ~a\n" (hash-ref registry 'my-tool))
(printf "callbacks all ran: ~a, in registration order: ~a, in reverse order: ~a\n"
        (= (length order) 12) (equal? (reverse order) (sort order <)) (equal? order (sort order <)))
(printf "new thread under dead custodian: ~a\n"
        (with-handlers ([exn:fail? (lambda (e) "error: the custodian has been shut down")])
          (parameterize ([current-custodian child]) (thread void))))
;; a thread that shuts down its own custodian dies at that call
(define c2 (make-custodian))
(define reached #f)
(thread-wait (parameterize ([current-custodian c2]) (thread (lambda () (custodian-shutdown-all c2) (set! reached #t)))))
(printf "code after self-shutdown reached: ~a\n" reached)
```

**Observed:**

```text
thread dead: #t
listener closed: #t
subprocess status: 137
custodian box: #f, ready as evt: #t
registry entry still present: registered
callbacks all ran: #t, in registration order: #f, in reverse order: #f
new thread under dead custodian: error: the custodian has been shut down
code after self-shutdown reached: #f
```

Further observations from the longer probes:

- Shutting down a custodian shuts down its child custodians, kills its threads, closes its ports and TCP listeners, and kills places created under it. A subprocess is affected only according to `current-subprocess-custodian-mode` at creation: with the default `#f` the process keeps running; with `'kill` it is killed; with `'interrupt` it gets SIGINT. See [Subprocess management](#subprocess-management).
- Shutdown callbacks registered with `register-custodian-shutdown` ran in a different order on each of three trials with twelve registrations. The documentation says they run "in atomic mode and an unspecified Racket thread". They must not block or raise: a callback that raised made `custodian-shutdown-all` itself raise, while the custodian still ended up shut down.
- A killed thread runs no `dynamic-wind` post thunk and no exception handler. A semaphore it held stays held.
- Pipes made with `make-pipe` are not managed. After shutting down the custodian under which a pipe and its feeding thread were created, both pipe ports were still open, the feeder was dead, and a read blocked. This is what happens inside `net/http-client`; see [HTTP client streaming and web-server](#http-client-streaming-and-web-server).
- A thread can be kept alive by a second custodian: after `(thread-resume t other-custodian)`, shutting down the first custodian did not stop it.
- `(custodian-limit-memory c (* 64 1024 1024) c)` shut the custodian down when a thread under it kept allocating; `(custodian-memory-accounting-available?)` is `#t`. The limit is checked at garbage collections, so usage overshoots before the shutdown.
- Cost: creating and shutting down a custodian takes about 1.4 microseconds, also under a chain 50 deep.

**What this means for the port.** A custodian per fiber is cheap and reclaims threads, ports, listeners, places and (with the right parameters) subprocess groups. It does not undo registrations in ordinary data structures, it gives no ordering, and code that shuts down a custodian must not run on a thread that belongs to it. After a shutdown the custodian is unusable, so a fiber that activates again needs a new one.

### dynamic-wind and continuation barriers

```racket
#lang racket/base
(define trace '())
(define (note x) (set! trace (cons x trace)))
(define (show label) (printf "~a: ~a\n" label (reverse trace)) (set! trace '()))
(with-handlers ([exn:fail? (lambda (e) (note 'handler))])
  (dynamic-wind (lambda () (note 'pre)) (lambda () (error "x")) (lambda () (note 'post))))
(show "raise")                                   ; post runs before the with-handlers handler
(define (reenter)
  (define k #f) (define n 0)
  (dynamic-wind (lambda () (note 'pre)) (lambda () (let/cc c (set! k c)) (note 'body)) (lambda () (note 'post)))
  (set! n (add1 n))
  (when (< n 2) (k (void))))
(reenter)
(show "re-entry with call/cc")                   ; pre and post run again
(define k2 #f)
(printf "re-enter through a barrier: ~a\n"
        (with-handlers ([exn:fail:contract:continuation? (lambda (e) "refused")])
          (call-with-continuation-barrier (lambda () (let/cc c (set! k2 c)) 'in))
          (k2 'again)))
(printf "escape out through a barrier: ~a\n" (let/ec out (call-with-continuation-barrier (lambda () (out 'allowed)))))
;; a killed thread runs no post thunk; a broken thread does
(define t1 (thread (lambda () (dynamic-wind void (lambda () (sleep 10)) (lambda () (note 'post-after-kill))))))
(define t2 (thread (lambda () (with-handlers ([exn:break? void]) (dynamic-wind void (lambda () (sleep 10)) (lambda () (note 'post-after-break)))))))
(sleep 0.05) (kill-thread t1) (break-thread t2) (thread-wait t1) (thread-wait t2)
(show "kill vs break")
```

**Observed:**

```text
raise: (pre post handler)
re-entry with call/cc: (pre body post pre body post)
re-enter through a barrier: refused
escape out through a barrier: allowed
kill vs break: (post-after-break)
```

Also observed: jumping back into a `dynamic-wind` post thunk with a captured continuation is allowed (no barrier there), and so is re-entering a `with-handlers` handler. In these probes a barrier appeared only where `call-with-continuation-barrier` installed one.

**What this means for the port.** `dynamic-wind` protects a dynamic extent inside one thread and runs its post thunk on escape, exception and break, but not on kill. It is the tool for local resources inside one plugin step. It cannot represent a Cordis effect, whose inverse runs later and from somewhere else. If kernel code is ever resumed through a captured continuation (generators do this), pre and post thunks run again on every re-entry.

### Parameters and parameterizations

```racket
#lang racket/base
(define current-ctx (make-parameter 'root))
(define ch (make-channel))
;; 1. a thread inherits the parameterization in effect when it is created
(void (parameterize ([current-ctx 'plugin-a])
        (thread (lambda () (sleep 0.02) (channel-put ch (current-ctx))))))
(printf "thread created inside parameterize, running after it exited: ~a\n" (channel-get ch))
;; 2. a closure does not capture it
(define callback (parameterize ([current-ctx 'plugin-a]) (lambda () (current-ctx))))
(printf "closure created in plugin-a, called from plugin-b: ~a\n" (parameterize ([current-ctx 'plugin-b]) (callback)))
;; 3. capture explicitly when that is what you want
(define pz (parameterize ([current-ctx 'plugin-a]) (current-parameterization)))
(define (bound thunk) (lambda () (call-with-parameterization pz thunk)))
(printf "closure wrapped with its parameterization: ~a\n" (parameterize ([current-ctx 'plugin-b]) ((bound (lambda () (current-ctx))))))
;; 4. direct assignment mutates a thread cell; a child thread has its own copy
(parameterize ([current-ctx 'outer])
  (define t (thread (lambda () (sleep 0.02) (channel-put ch (current-ctx)))))
  (current-ctx 'mutated-in-parent)
  (printf "child after parent mutation: ~a\n" (channel-get ch)))
;; 5. guards reject bad values at parameterize time
(define level (make-parameter 0 (lambda (v) (if (exact-nonnegative-integer? v) v (raise-argument-error 'level "natural" v)))))
(printf "guard: ~a\n" (with-handlers ([exn:fail:contract? (lambda (e) "rejected")]) (parameterize ([level -1]) 'accepted)))
```

**Observed:**

```text
thread created inside parameterize, running after it exited: plugin-a
closure created in plugin-a, called from plugin-b: plugin-b
closure wrapped with its parameterization: plugin-a
child after parent mutation: outer
guard: rejected
```

Cost: a `parameterize` of one parameter plus a read takes about 0.12 microseconds.

**What this means for the port.** A parameter such as `current-context` is right for diagnostics and for "who is running" inside one call. It is wrong as the owner of a registration: a listener stored by plugin A and called during plugin B's dispatch sees B's value unless the closure was wrapped with A's parameterization. New threads inherit the creator's parameterization, including `current-custodian`, which is how a thread started by a plugin lands under that plugin's custodian.

### Continuation marks

```racket
#lang racket/base
(define key (make-continuation-mark-key 'cordis-fiber))
(define (fiber-chain) (continuation-mark-set->list (current-continuation-marks) key))
(define (call-as fiber thunk) (with-continuation-mark key fiber (let ([v (thunk)]) v)))   ; non-tail call keeps the frame
(printf "nested: ~a\n" (call-as 'loader (lambda () (call-as 'plugin-a (lambda () (fiber-chain))))))
(printf "tail position replaces: ~a\n" (with-continuation-mark key 'a (with-continuation-mark key 'b (fiber-chain))))
(printf "innermost only: ~a\n" (call-as 'loader (lambda () (call-as 'plugin-a (lambda () (continuation-mark-set-first #f key))))))
(printf "new thread starts with no marks: ~a\n"
        (call-as 'plugin-a (lambda () (let ([ch (make-channel)]) (thread (lambda () (channel-put ch (fiber-chain)))) (channel-get ch)))))
(define sema (make-semaphore 0))
(define t (thread (lambda () (call-as 'plugin-b (lambda () (semaphore-wait sema))))))
(sleep 0.02)
(printf "marks of another thread, read from outside: ~a\n" (continuation-mark-set->list (continuation-marks t) key))
(semaphore-post sema)
(printf "exn carries marks of the raise point: ~a\n"
        (with-handlers ([exn:fail? (lambda (e) (continuation-mark-set->list (exn-continuation-marks e) key))])
          (call-as 'plugin-c (lambda () (error "boom")))))
```

**Observed:**

```text
nested: (plugin-a loader)
tail position replaces: (b)
innermost only: plugin-a
new thread starts with no marks: ()
marks of another thread, read from outside: (plugin-b)
exn carries marks of the raise point: (plugin-c)
```

Cost: `with-continuation-mark` plus a lookup takes about 0.02 microseconds.

**What this means for the port.** Marks give a cheap dynamic chain of "which fiber's code is on the stack" that survives into exception objects, which is what an error report needs in place of the stack surgery the TypeScript kernel performs. Marks are per continuation: a new thread starts empty, so a task spawner must copy the mark it cares about.

### Continuations, a waterfall chain, generators

```racket
#lang racket/base
(require racket/control racket/generator)
;; shift/reset and tagged prompts
(printf "reset/shift: ~a\n" (reset (+ 1 (shift k (k (k 10))))))
(define tag (make-continuation-prompt-tag 'bail))
(printf "abort to a tagged prompt: ~a\n"
        (call-with-continuation-prompt (lambda () (+ 1 (abort-current-continuation tag 'veto))) tag (lambda (why) (list 'aborted why))))

;; Waterfall (around middleware) with plain closures. `next` runs the rest of the chain.
;; Returning without calling next short-circuits; calling it twice is an error, as in Cordis.
(define (waterfall listeners args final)
  (let loop ([ls listeners] [args args])
    (cond
      [(null? ls) (apply final args)]
      [else
       (define called? #f)
       (define (next . new-args)
         (when called? (error 'waterfall "next() called twice"))
         (set! called? #t)
         (loop (cdr ls) (if (null? new-args) args new-args)))
       (apply (car ls) (append args (list next)))])))
(define ((tagger name) text next) (string-append "<" name ">" (next (string-append text "+" name)) "</" name ">"))
(printf "chain: ~a\n" (waterfall (list (tagger "a") (tagger "b")) '("req") (lambda (t) (string-upcase t))))
(printf "short-circuit: ~a\n" (waterfall (list (tagger "a") (lambda (t next) "veto") (tagger "b")) '("req") values))
(printf "double next: ~a\n" (with-handlers ([exn:fail? exn-message]) (waterfall (list (lambda (t next) (next) (next))) '("req") values)))

;; Generators (racket/generator is built on continuations)
(define g (generator () (yield 'd1) (yield 'd2) 'last))
(printf "generator: ~a ~a ~a state=~a\n" (g) (g) (g) (generator-state g))
;; quirk 1: a body that ends in (yield x) returns zero values on its final resume
(define g2 (generator () (yield 'only)))
(printf "values per resume: ~a ~a\n" (call-with-values g2 list) (call-with-values g2 list))
;; quirk 2: the body keeps the parameterization of its FIRST resume
(define p (make-parameter 'none))
(define g3 (generator () (yield (p)) (yield (p))))
(printf "parameter seen: ~a then ~a\n" (parameterize ([p 'first]) (g3)) (parameterize ([p 'second]) (g3)))
;; quirk 3: after an exception the generator stays in state 'running and cannot be resumed
(define g4 (generator () (yield 1) (error "step failed")))
(void (g4))
(printf "after failure: ~a state=~a\n" (with-handlers ([exn:fail? exn-message]) (g4)) (generator-state g4))
;; a generator can be resumed from another thread
(define g5 (generator () (yield (current-thread)) (yield (current-thread))))
(define t1 (g5))
(define t2 (let ([ch (make-channel)]) (thread (lambda () (channel-put ch (g5)))) (channel-get ch)))
(printf "resumed on a different thread: ~a\n" (not (eq? t1 t2)))
```

**Observed:**

```text
reset/shift: 12
abort to a tagged prompt: (aborted veto)
chain: <a><b>REQ+A+B</b></a>
short-circuit: <a>veto</a>
double next: waterfall: next() called twice
generator: d1 d2 last state=done
values per resume: (only) ()
parameter seen: first then first
after failure: step failed state=running
resumed on a different thread: #t
```

Also observed: `control`/`prompt` differ from `shift`/`reset` only in whether the captured continuation reinstalls the delimiter (`(reset (let ([y (shift f (cons 'a (f '())))]) (shift g y)))` gives `(a)`, the `prompt`/`control` version gives `()`); a continuation captured in one thread can be applied in another inside a prompt; a generator resume costs about 0.3 microseconds; an escape with `let/ec` about 0.07.

**What this means for the port.** The waterfall dispatch mode needs nothing beyond closures: `next` is a procedure that runs the rest of the listener list, and the "called twice" check is one flag. Delimited continuations are not needed for events. Generators are the natural carrier for effect iterators, with four behaviors the kernel driver must handle: receive results with `call-with-values` (a body ending in `yield` returns zero values on its last resume), do not resume a generator after it raised (its state stays `running`), expect the body to see the parameterization of its first resume, and expect `dynamic-wind` thunks inside the body to run at every suspension and resumption.

### Exceptions, breaks, kill

```racket
#lang racket/base
;; A coded error, the counterpart of HarnessError
(struct exn:fail:harness exn:fail (code details) #:transparent)
(define (raise-harness code message [details (hasheq)])
  (raise (exn:fail:harness message (current-continuation-marks) code details)))
(printf "~a\n" (with-handlers ([exn:fail:harness? (lambda (e) (list (exn:fail:harness-code e) (exn-message e)))])
                 (raise-harness 'TOOL_NOT_FOUND "no such tool: x")))
;; exn:break is not exn:fail; a catch-all predicate swallows cancellation
(define (broken-by handler-pred)
  (with-handlers ([exn:break? (lambda (e) 'break-propagated)])
    (with-handlers ([handler-pred (lambda (e) 'swallowed)])
      (break-thread (current-thread)) (sleep 0) 'not-broken)))
(printf "exn:fail? handler: ~a ; (lambda (e) #t) handler: ~a\n" (broken-by exn:fail?) (broken-by (lambda (e) #t)))
;; handlers run with breaks disabled; with-handlers* does not disable them
(printf "break-enabled in handler: with-handlers ~a, with-handlers* ~a, dynamic-wind post ~a\n"
        (with-handlers ([symbol? (lambda (e) (break-enabled))]) (raise 'x))
        (with-handlers* ([symbol? (lambda (e) (break-enabled))]) (raise 'x))
        (let ([v #f]) (dynamic-wind void void (lambda () (set! v (break-enabled)))) v))
;; a break is deferred while breaks are disabled and delivered at the next enabled point
(define log '())
(define (note x) (set! log (cons x log)))
(define w (thread (lambda ()
                    (with-handlers ([exn:break? (lambda (e) (note 'cancelled))])
                      (parameterize-break #f (note 'critical-start) (sleep 0.1) (note 'critical-end))
                      (sleep 1) (note 'not-reached)))))
(sleep 0.02) (break-thread w) (thread-wait w)
(printf "deferred break: ~a\n" (reverse log))
;; a thread may ignore breaks; kill-thread and custodian shutdown cannot be ignored, and run no cleanup
(define stubborn (thread (lambda () (let loop () (with-handlers ([exn:break? void]) (sleep 10)) (loop)))))
(sleep 0.02) (break-thread stubborn) (sleep 0.02)
(printf "stubborn thread running after break: ~a ; after kill: ~a\n" (thread-running? stubborn) (begin (kill-thread stubborn) (thread-running? stubborn)))
;; an uncaught error in a thread only prints; carry the outcome to the waiter explicitly
(define (spawn/result thunk)
  (define result (box #f)) (define done (make-semaphore 0))
  (thread (lambda () (set-box! result (with-handlers ([(lambda (e) #t) (lambda (e) (cons 'raise e))]) (cons 'ok (thunk)))) (semaphore-post done)))
  (lambda () (semaphore-wait done) (semaphore-post done) (let ([r (unbox result)]) (if (eq? (car r) 'ok) (cdr r) (raise (cdr r))))))
(printf "error carried across threads: ~a\n" (with-handlers ([exn:fail? exn-message]) ((spawn/result (lambda () (error "from child"))))))
```

**Observed:**

```text
(TOOL_NOT_FOUND no such tool: x)
exn:fail? handler: break-propagated ; (lambda (e) #t) handler: swallowed
break-enabled in handler: with-handlers #f, with-handlers* #t, dynamic-wind post #f
deferred break: (critical-start critical-end cancelled)
stubborn thread running after break: #t ; after kill: #f
error carried across threads: from child
```

Also observed:

- Operating-system signals arrive as breaks in the main thread: SIGINT raises `exn:break`, SIGTERM raises `exn:break:terminate`, SIGHUP raises `exn:break:hang-up`. A command-line entry point can turn them into an orderly shutdown with one `with-handlers`.
- A break interrupts `sleep`, `sync`, `channel-get`, port reads and a CPU-bound loop.
- A `with-handlers` handler runs after the stack has been unwound to the `with-handlers` form (it sees the outer parameterization). A handler installed with `call-with-exception-handler` runs at the raise point.
- Raising a symbol and catching it costs about 0.4 microseconds; `error` plus `with-handlers` about 0.9.

**What this means for the port.** `HarnessError` maps to a struct under `exn:fail` with a `code` field. Catch-all handlers must use `exn:fail?`, never `(lambda (e) #t)`, or they swallow cancellation. A break is asynchronous: it can land between any two operations unless breaks are disabled, so code that must keep shared state consistent runs with breaks disabled and enables them only at explicit waiting points. Because handlers run with breaks disabled, cleanup in a handler cannot be interrupted by a second cancel; long cleanup there needs its own time limit. A thread can ignore breaks, so cancellation needs a second stage (kill through the custodian), and that stage runs no cleanup code in the victim.

### Threads, channels, events: an agent turn with cancellation

```racket
#lang racket/base
;; One agent turn: its own thread under its own custodian. The result is published through a
;; box and a semaphore, never a rendezvous channel (a worker blocked in channel-put would be
;; killed by the grace timeout). The turn struct is itself an event.
(struct turn (thread custodian done result)
  #:property prop:evt (lambda (self) (wrap-evt (semaphore-peek-evt (turn-done self)) (lambda (_) (unbox (turn-result self))))))
(define (start-turn steps emit)
  (define cust (make-custodian))
  (define done (make-semaphore 0))
  (define result (box 'killed))
  (define worker
    (parameterize ([current-custodian cust])
      (thread (lambda ()
                (define r (with-handlers ([exn:break? (lambda (e) 'cancelled)]
                                          [exn:fail? (lambda (e) (list 'failed (exn-message e)))])
                            (for ([step (in-list steps)]) (emit 'step) (step))
                            'completed))
                (set-box! result r)
                (semaphore-post done)))))
  (thread (lambda () (sync (thread-dead-evt worker)) (semaphore-post done)))   ; watcher lives outside cust
  (turn worker cust done result))
(define (cancel-turn! t #:grace [grace 0.2])
  (break-thread (turn-thread t))                                       ; cooperative first
  (unless (sync/timeout grace (thread-dead-evt (turn-thread t)))
    (custodian-shutdown-all (turn-custodian t))))                      ; then forced
(define (run label steps cancel-after)
  (define n 0)
  (define t (start-turn steps (lambda (e) (set! n (add1 n)))))
  (when cancel-after (sleep cancel-after) (cancel-turn! t))
  (printf "~a: ~a after ~a step event(s)\n" label (sync/timeout 2 t) n))
(define (nap s) (lambda () (sleep s)))
(run "completes" (list (nap 0.01) (nap 0.01)) #f)
(run "cancelled at a blocking point" (list (nap 0.01) (nap 5)) 0.05)
(run "ignores the break, killed after grace" (list (lambda () (let loop () (with-handlers ([exn:break? void]) (sleep 5)) (loop)))) 0.05)
(run "step fails" (list (lambda () (error "tool blew up"))) #f)
;; composing waits: first of result, timeout, external cancel signal
(define cancel-signal (make-semaphore 0))
(define t (start-turn (list (nap 5)) void))
(printf "choice: ~a\n" (sync (wrap-evt t (lambda (r) (list 'result r)))
                             (wrap-evt (alarm-evt (+ (current-inexact-milliseconds) 50)) (lambda (_) 'timeout))
                             (wrap-evt cancel-signal (lambda (_) 'user-cancel))))
(cancel-turn! t)
;; nack-guard-evt: a server learns that the client stopped waiting
(define requests (make-channel))
(define seen (box #f))
(void (thread (lambda ()
                (let loop ()
                  (define req (channel-get requests))
                  (sleep 0.05)
                  (sync (wrap-evt (channel-put-evt (car req) 'reply) (lambda (_) (set-box! seen 'delivered)))
                        (wrap-evt (cdr req) (lambda (_) (set-box! seen 'client-gave-up))))
                  (loop)))))
(define (request-evt) (nack-guard-evt (lambda (nack) (define reply (make-channel)) (channel-put requests (cons reply nack)) reply)))
(printf "request with 10 ms timeout: ~a ; " (sync/timeout 0.01 (request-evt)))
(sleep 0.1)
(printf "server saw: ~a\n" (unbox seen))
```

**Observed:**

```text
completes: completed after 2 step event(s)
cancelled at a blocking point: cancelled after 2 step event(s)
ignores the break, killed after grace: killed after 1 step event(s)
step fails: (failed tool blew up) after 1 step event(s)
choice: timeout
request with 10 ms timeout: #f ; server saw: client-gave-up
```

Also observed: 20,000 threads were created and joined in 131 ms (about 5 microseconds each); a channel rendezvous between two threads costs about 1 microsecond; `async-channel` gives a buffered mailbox with `async-channel-try-get`; each thread has a built-in mailbox (`thread-send`, `thread-receive`, and `thread-send` to a dead thread calls its failure thunk); `alarm-evt` accepts wall-clock milliseconds or, with a second argument `#t`, monotonic milliseconds; a struct can be an event through `prop:evt`; `replace-evt` and `guard-evt` build events lazily. A thread killed while holding a plain semaphore leaves it locked; `call-with-semaphore/enable-break` releases it when the holder is broken, not when it is killed.

**What this means for the port.** `sync` with `choice-evt` expresses "result, or timeout, or cancel" directly, which replaces `Promise.race` and `AbortSignal`. Results must be published in a way that cannot block the publisher. Any state that a killable thread mutates under a lock needs either a manager thread or a watcher on `thread-dead-evt`.

### Cooperative baton

This sketch tests the scheduling model that [cordis-analysis.md](../cordis-analysis.md) section 4.6 chooses: tasks are real threads, but only the holder of one baton runs harness code, and the baton changes hands only at `await`.

```racket
#lang racket/base
;; Run-to-completion between waits, on real threads. Only the baton holder runs harness code.
;; A manager thread owns the queue (FIFO) and watches the holder, so a killed holder cannot wedge it.
(define requests (make-channel))
(define (grant-next queue) (if (null? queue) (values #f '()) (begin (semaphore-post (cdar queue)) (values (caar queue) (cdr queue)))))
(define manager
  (thread (lambda ()
            (let loop ([holder #f] [queue '()])
              (sync (handle-evt requests
                                (lambda (m)
                                  (case (car m)
                                    [(acquire) (if holder
                                                   (loop holder (append queue (list (cdr m))))
                                                   (begin (semaphore-post (cddr m)) (loop (cadr m) queue)))]
                                    [(release) (let-values ([(h q) (grant-next queue)]) (loop h q))])))
                    (if holder
                        (handle-evt (thread-dead-evt holder) (lambda (_) (let-values ([(h q) (grant-next queue)]) (loop h q))))
                        never-evt))))))
(define (acquire!) (define granted (make-semaphore 0)) (channel-put requests (cons 'acquire (cons (current-thread) granted))) (semaphore-wait granted))
(define (release!) (channel-put requests '(release)))
(define (await evt)                                   ; the only point where another task may run or a break may land
  (release!)
  (dynamic-wind void (lambda () (sync/enable-break evt)) (lambda () (parameterize-break #f (acquire!)))))
(define (spawn-task thunk)
  (thread (lambda () (parameterize-break #f (acquire!) (dynamic-wind void thunk release!)))))
;; two tasks append to a shared log; steps between awaits never interleave
(define log '())
(define (task name) (lambda () (for ([i 3]) (set! log (cons (list name i 'a) log)) (set! log (cons (list name i 'b) log)) (await (alarm-evt (+ (current-inexact-milliseconds) 1))))))
(for-each thread-wait (list (spawn-task (task 'x)) (spawn-task (task 'y))))
(printf "pairs never split: ~a\n" (let loop ([l (reverse log)]) (or (null? l) (and (equal? (car (car l)) (car (cadr l))) (eq? (caddr (car l)) 'a) (eq? (caddr (cadr l)) 'b) (loop (cddr l))))))
;; cancellation lands only at an await, with the baton held again when the handler runs
(define outcome #f)
(define victim (spawn-task (lambda () (with-handlers ([exn:break? (lambda (e) (set! outcome 'cancelled-at-await))]) (await never-evt)))))
(sleep 0.02) (break-thread victim) (thread-wait victim)
(printf "~a\n" outcome)
;; a holder that is killed releases the baton through the manager
(define holder (thread (lambda () (acquire!) (sleep 10))))
(sleep 0.02) (kill-thread holder)
(printf "acquire after the holder was killed: ~a\n" (and (sync/timeout 1 (thread (lambda () (acquire!) (release!)))) #t))
(define t0 (current-inexact-milliseconds))
(for-each thread-wait (for/list ([k 4]) (thread (lambda () (for ([i 5000]) (acquire!) (release!))))))
(printf "20000 acquire/release pairs from 4 threads: ~a ms\n" (round (- (current-inexact-milliseconds) t0)))
```

**Observed:**

```text
pairs never split: #t
cancelled-at-await
acquire after the holder was killed: #t
20000 acquire/release pairs from 4 threads: 125.0 ms
```

**What this means for the port.** The model works as designed: steps between two awaits are not interleaved, a break is deferred to the await and its handler runs with the baton held, and a holder that is killed does not wedge the queue. One acquire and release through the manager costs about 5 to 8 microseconds, which bounds the overhead of an `await` that does not really wait. The sketch disables breaks for the whole task body and enables them only inside `await`; a design that leaves breaks enabled between awaits loses the run-to-completion property under cancellation.

### Weak boxes, will executors, ephemerons

```racket
#lang racket/base
;; Leak test for a registry: after the disposer runs, the registered object must be collectable.
(define registry (make-hasheq))
(define (register! key v) (hash-set! registry key v) (lambda () (hash-remove! registry key)))
(define (gc!) (for ([i 3]) (collect-garbage 'major)))
(define (probe dispose?)
  (define obj (make-vector 10 'payload))
  (define dispose (register! (gensym) obj))
  (when dispose? (dispose))
  (make-weak-box obj))                       ; obj is unreachable from here once probe returns
(define disposed (probe #t))
(define leaked (probe #f))
(gc!)
(printf "collected after dispose: ~a ; collected without dispose: ~a\n" (not (weak-box-value disposed #f)) (not (weak-box-value leaked #f)))
;; a retained disposer closure that captures the object keeps it alive
(define kept-disposer #f)
(define wb (let ([obj (make-vector 3 0)]) (set! kept-disposer (lambda () obj)) (make-weak-box obj)))
(gc!)
(printf "collected while its disposer is retained: ~a\n" (not (weak-box-value wb #f)))
;; wills run only when someone executes them
(define executor (make-will-executor))
(define finalized '())
(let ([resource (list 'handle)]) (will-register executor resource (lambda (v) (set! finalized (cons 'finalized finalized)))))
(gc!)
(printf "before will-try-execute: ~a ; after: ~a\n" finalized (begin (will-try-execute executor) finalized))
;; weak hash vs ephemeron hash when the value refers to its key
(define weak (make-weak-hasheq)) (define eph (make-ephemeron-hasheq))
(let ([k1 (list 1)] [k2 (list 2)]) (hash-set! weak k1 (list 'meta k1)) (hash-set! eph k2 (list 'meta k2)))
(gc!)
(printf "entries left: weak hash ~a, ephemeron hash ~a\n" (hash-count weak) (hash-count eph))
```

**Observed:**

```text
collected after dispose: #t ; collected without dispose: #f
collected while its disposer is retained: #f
before will-try-execute: () ; after: (finalized)
entries left: weak hash 1, ephemeron hash 0
```

Also observed: a thread blocked on a semaphore that nothing else can reach is itself collected; `(current-memory-use custodian)` reports memory per custodian.

**What this means for the port.** A registry leak test is three steps: register, dispose, `(collect-garbage 'major)` a few times, then check a weak box. The object under test must not be reachable from the test's own variables or from a disposer the test still holds. Side tables keyed by plugin objects should be ephemeron hashes, not weak hashes, when the value can refer to the key.

### Units and signatures

```racket
#lang racket/base
(require racket/unit)
(define-signature logger^ (log-msg))
(define-signature store^ (put! get))
(define-unit console-logger@ (import) (export logger^) (define (log-msg s) (printf "  [log] ~a\n" s)))
(define-unit null-logger@ (import) (export logger^) (define (log-msg s) (void)))
(define-unit mem-store@ (import logger^) (export store^)
  (define table (make-hash))                       ; body runs at each invocation: fresh state
  (define (put! k v) (log-msg (format "put ~a" k)) (hash-set! table k v))
  (define (get k) (hash-ref table k #f)))
;; units are values; linking can be decided at run time
(define (link-store logger@)
  (compound-unit (import) (export S)
    (link [((L : logger^)) logger@]
          [((S : store^)) mem-store@ L])))
(define (instantiate logger@)
  (define-values/invoke-unit (link-store logger@) (import) (export store^))
  (values put! get))
(define-values (put-a get-a) (instantiate console-logger@))
(define-values (put-b get-b) (instantiate null-logger@))
(put-a 'k 1)
(printf "two invocations are two instances: ~a ~a\n" (get-a 'k) (get-b 'k))
(printf "missing import detected when invoking: ~a\n"
        (with-handlers ([exn:fail? (lambda (e) (car (regexp-split #rx"\n" (exn-message e))))]) (invoke-unit mem-store@)))
;; There is no operation that replaces logger^ inside the instance behind put-a/get-a.
;; A different logger means a new invocation and therefore new store state.
```

**Observed:**

```text
  [log] put k
two invocations are two instances: 1 #f
missing import detected when invoking: invoke-unit: unit argument expects an untagged import with signature logger^, which this usage context does not supply
```

Also observed: `define-compound-unit/infer` links by signature name at compile time; mutually recursive units link (an `even@`/`odd@` pair ran).

**Can units be linked and unlinked dynamically?** Linked, yes: a unit is a first-class value and `compound-unit` is an expression, so the choice of provider can be made at run time. Unlinked or relinked, no: links are fixed when the compound unit is built, an invocation returns plain values, and there is no operation that withdraws or replaces an import of a running instance. Replacing a provider means invoking again, which creates fresh state for every unit in the compound.

**What this means for the port.** Units check that imports are satisfied before anything runs and allow cyclic links, but they have no notion of a dependency that appears, disappears or changes while dependents keep running, which is the core of Cordis. They fit as an optional adapter for statically wired groups, not as the kernel's model.

### Contracts

```racket
#lang racket/base
(module service racket/base
  (require racket/contract)
  (struct tool (name handler))
  (define (register-tool! table t) (hash-set! table (tool-name t) t) (lambda () (hash-remove! table (tool-name t))))
  (define (broken-register! table t) 'not-a-disposer)
  (define (slice lst from to) (for/list ([x (in-list lst)] [i (in-naturals)] #:when (and (>= i from) (< i to))) x))
  (define (add a b) (+ a b))
  (define (call-tool t arg) ((tool-handler t) arg))
  (provide (rename-out [add unchecked-add])
           (contract-out
            [struct tool ([name string?] [handler (-> hash? any/c)])]
            [register-tool! (-> (and/c hash? (not/c immutable?)) tool? (-> void?))]
            [broken-register! (-> hash? tool? (-> void?))]
            [add (-> fixnum? fixnum? fixnum?)]
            [call-tool (-> tool? hash? any/c)]
            [slice (->i ([lst list?] [from exact-nonnegative-integer?] [to (from) (and/c exact-nonnegative-integer? (>=/c from))])
                        #:pre (lst to) (<= to (length lst))
                        [result (from to) (lambda (r) (= (length r) (- to from)))])])))
(module consumer racket/base
  (require (submod ".." service) racket/contract)
  (define (blame thunk)
    (with-handlers ([exn:fail:contract:blame?
                     (lambda (e) (define b (exn:fail:contract:blame-object e))
                       (define who (blame-positive b))
                       (format "~a (blaming ~a)" (car (regexp-split #rx"\n" (exn-message e))) (if (pair? who) (cadr who) who)))])
      (thunk)))
  (printf "consumer passes a bad argument:\n  ~a\n" (blame (lambda () (register-tool! (make-hash) "not a tool"))))
  (printf "provider returns a bad result:\n  ~a\n" (blame (lambda () (broken-register! (make-hash) (tool "t" void)))))
  (printf "dependent range check:\n  ~a\n" (blame (lambda () (slice '(a b c d) 3 1))))
  (define t (tool "t" (lambda (h) (hash-ref h 'x #f))))
  (printf "higher-order: the handler is wrapped, so a bad call through the accessor is caught:\n  ~a\n" (blame (lambda () ((tool-handler t) 'not-a-hash))))
  (define/contract (safe-div a b) (-> number? (and/c number? (not/c zero?)) number?) (/ a b))
  (printf "define/contract inside one module:\n  ~a\n" (blame (lambda () (safe-div 1 0))))
  ;; cost
  (define-syntax-rule (ms e) (let ([t0 (current-inexact-milliseconds)]) e (round (- (current-inexact-milliseconds) t0))))
  (define N 2000000) (define h (hash))
  (printf "2e6 calls: uncontracted ~a ms ; (-> fixnum? fixnum? fixnum?) ~a ms ; call through contracted accessor of a procedure field ~a ms ; same call made inside the provider ~a ms\n"
          (ms (for ([i (in-range N)]) (unchecked-add i 1)))
          (ms (for ([i (in-range N)]) (add i 1)))
          (ms (for ([i (in-range N)]) ((tool-handler t) h)))
          (ms (for ([i (in-range N)]) (call-tool t h)))))
(require 'consumer)
```

**Observed:**

```text
consumer passes a bad argument:
  register-tool!: contract violation (blaming consumer)
provider returns a bad result:
  broken-register!: broke its own contract (blaming service)
dependent range check:
  slice: contract violation (blaming consumer)
higher-order: the handler is wrapped, so a bad call through the accessor is caught:
  tool-handler: contract violation (blaming consumer)
define/contract inside one module:
  safe-div: contract violation (blaming consumer)
2e6 calls: uncontracted 3.0 ms ; (-> fixnum? fixnum? fixnum?) 88.0 ms ; call through contracted accessor of a procedure field 2886.0 ms ; same call made inside the provider 285.0 ms
```

Also observed: the full message names the contract, the argument position, the module that owns the contract and the blamed party; `exn:fail:contract:blame` carries a blame object (`blame-positive`, `blame-negative`, `blame-contract`); a `(listof exact-integer?)` argument of 1,000 elements is traversed on every call (2,000 calls took 10 ms).

**Cost.** A first-order function contract adds about 45 nanoseconds per call. A contracted struct accessor whose field holds a procedure wraps that procedure in a new contract wrapper on every access: about 1.4 microseconds per access, 30 times the cost of the flat contract. The same call made inside the providing module, where the accessor is the raw one, pays only for the contract on the outer function.

**What this means for the port.** `contract-out` at a package boundary gives the provider/consumer blame that a dsh capability seam wants. Hot paths should not go through contracted accessors of procedure-valued fields; check a provided service value once when it is provided, or export an operation that calls the field from inside the module.

### Generics, structure type properties, classes

```racket
#lang racket/base
(require racket/generic racket/class racket/struct)
;; A Service Definition with several providers: a generic interface
(define-generics llm-adapter
  (adapter-name llm-adapter)
  (adapter-complete llm-adapter request)
  (adapter-stream llm-adapter request on-chunk)
  #:fallbacks [(define/generic complete adapter-complete)      ; inside #:fallbacks, call other methods through define/generic
               (define (adapter-stream a request on-chunk) (on-chunk (complete a request)) 'streamed-by-fallback)]
  #:defined-predicate adapter-implements?)
(struct echo-adapter (prefix)
  #:methods gen:llm-adapter
  [(define (adapter-name a) "echo")
   (define (adapter-complete a request) (string-append (echo-adapter-prefix a) request))])
(define a (echo-adapter "> "))
(printf "~a ~a ~a ; implements stream itself: ~a\n" (adapter-name a) (adapter-complete a "hi") (adapter-stream a "hi" void) (adapter-implements? a 'adapter-stream))

;; Structure type properties: a callable, printable, single-shot disposer that is also an event
(struct disposer (thunk [state #:mutable] done)
  #:property prop:procedure (lambda (self) (when (eq? (disposer-state self) 'live)
                                             (set-disposer-state! self 'disposed) ((disposer-thunk self)) (semaphore-post (disposer-done self))))
  #:property prop:evt (lambda (self) (semaphore-peek-evt (disposer-done self)))
  #:methods gen:custom-write [(define (write-proc self port mode) (fprintf port "#<disposer ~a>" (disposer-state self)))])
(define count 0)
(define d (disposer (lambda () (set! count (add1 count))) 'live (make-semaphore 0)))
(printf "~a ready? ~a | " d (and (sync/timeout 0 d) #t))
(d) (d)
(printf "~a ready? ~a ran ~a time(s) procedure? ~a\n" d (and (sync/timeout 0 d) #t) count (procedure? d))
;; A custom property with a guard: metadata readable from an instance or from the struct type
(define-values (prop:plugin-meta plugin-meta? plugin-meta-ref)
  (make-struct-type-property 'plugin-meta (lambda (v info) (if (hash? v) v (error 'prop:plugin-meta "expected a hash, got ~e" v)))))
(struct my-plugin () #:property prop:plugin-meta (hasheq 'name "demo" 'inject '(logger)))
(printf "meta from instance: ~a ; from type: ~a\n" (hash-ref (plugin-meta-ref (my-plugin)) 'name) (hash-ref (plugin-meta-ref struct:my-plugin) 'inject))

;; The same service as a class, with a mixin
(define service<%> (interface () start stop))
(define base% (class* object% (service<%>) (init-field name) (super-new)
                (define/public (start) (format "~a started" name)) (define/public (stop) (void))))
(define (logging-mixin %) (class % (super-new) (define/override (start) (string-append "[log] " (super start)))))
(define svc (new (logging-mixin base%) [name "db"]))
(printf "~a ; is-a? ~a ; unknown method: ~a\n" (send svc start) (is-a? svc service<%>)
        (with-handlers ([exn:fail:object? (lambda (e) "exn:fail:object")]) (dynamic-send svc 'nope)))
;; dispatch cost, 2e6 calls each
(define-syntax-rule (ms e) (let ([t0 (current-inexact-milliseconds)]) e (round (- (current-inexact-milliseconds) t0))))
(struct holder (f)) (define h (holder (lambda (x) x)))
(define-generics g (gm g x)) (struct gs () #:methods gen:g [(define (gm s x) x)]) (define gi (gs))
(define o (new (class object% (super-new) (define/public (m x) x))))
(define N 2000000)
(printf "closure in a struct field ~a ms ; generic method ~a ms ; send ~a ms ; dynamic-send ~a ms\n"
        (ms (for ([i (in-range N)]) ((holder-f h) i))) (ms (for ([i (in-range N)]) (gm gi i)))
        (ms (for ([i (in-range N)]) (send o m i))) (ms (for ([i (in-range N)]) (dynamic-send o 'm i))))
```

**Observed:**

```text
echo > hi streamed-by-fallback ; implements stream itself: #f
#<disposer live> ready? #f | #<disposer disposed> ready? #t ran 1 time(s) procedure? #t
meta from instance: demo ; from type: (logger)
[log] db started ; is-a? #t ; unknown method: exn:fail:object
closure in a struct field 3.0 ms ; generic method 42.0 ms ; send 83.0 ms ; dynamic-send 96.0 ms
```

Also observed: calling a method that a struct does not implement raises `<method>: not implemented for #<struct-name>`; `define-generics` also produces a contract combinator named `<interface>/c`; `gen:equal+hash` customizes equality; `impersonate-hash` and `impersonate-procedure` can intercept reads and calls (a proxy in the JavaScript sense) while staying `equal?` to the original; `make-constructor-style-printer` gives `#<pretty: 1 x>` for display and `(pretty 1 "x")` for print.

**Classes versus structs with generics.** Per 2 million calls, across runs: a closure stored in a struct field 3 to 4 ms, a generic method 40 to 60 ms, `send` 85 to 120 ms, `dynamic-send` 95 to 155 ms. Classes add inheritance, mixins, `super`, interfaces and method lookup by name at run time; `racket/class` adds about 135 ms to start-up. Structs with generics give a closed set of operations per interface, fall back methods, and static method names.

**What this means for the port.** Use a struct with properties for kernel values that must be callable, printable and waitable at once (disposers, fibers, plugins). Use `define-generics` for a Service Definition with several providers. Reserve classes for places where the TypeScript design depends on inheritance with `super` calls or on mixin layering.

### Namespaces and module reloading

```racket
#lang racket/base
;; Hot reload of a plugin module. The script writes its own files into a temporary directory.
(require racket/rerequire racket/file compiler/cm)
(define dir (make-temporary-file "reload~a" 'directory))
(define kernel (build-path dir "kernel.rkt"))
(define plugin (build-path dir "plugin.rkt"))
(define (write-file! path age . lines)      ; age: seconds in the past; change detection compares 1 s timestamps
  (call-with-output-file path #:exists 'truncate (lambda (o) (for-each (lambda (l) (displayln l o)) lines)))
  (file-or-directory-modify-seconds path (- (current-seconds) age)))
(write-file! kernel 30 "#lang racket/base" "(provide (struct-out plugin))" "(struct plugin (name apply))")
(define (write-plugin! version age)
  (write-file! plugin age "#lang racket/base" "(require \"kernel.rkt\")" "(provide the-plugin)"
               "(define calls 0)"
               (format "(define the-plugin (plugin \"demo\" (lambda () (set! calls (add1 calls)) (list '~a calls))))" version)))
(define (call p) (((dynamic-require kernel 'plugin-apply) p)))
(define (plugin? v) ((dynamic-require kernel 'plugin?) v))

;; A. same namespace, racket/rerequire. It tracks only modules that it loaded itself.
(write-plugin! 'v1 20)
(void (dynamic-rerequire plugin #:verbosity 'none))
(define p1 (dynamic-require plugin 'the-plugin))
(printf "A. v1: ~a ~a\n" (call p1) (call p1))
(write-plugin! 'v2 10)
(printf "A. files reloaded: ~a\n" (length (dynamic-rerequire plugin #:verbosity 'none)))
(define p2 (dynamic-require plugin 'the-plugin))
;; The module is re-declared IN PLACE: its top-level variables are re-initialised and shared.
;; A closure from before the reload keeps its old code but reads and writes the new variables.
(printf "A. new value: ~a ; old closure: ~a ; new value again: ~a\n" (call p2) (call p1) (call p2))
(printf "A. kernel.rkt unchanged, so both satisfy the same struct predicate: ~a ~a\n" (plugin? p1) (plugin? p2))

;; B. a fresh namespace per load, sharing the kernel instance with namespace-attach-module
(define host-ns (current-namespace))
(define (load-fresh #:attach-kernel? attach?)
  (define ns (make-base-empty-namespace))
  (when attach? (namespace-attach-module host-ns kernel ns))
  (parameterize ([current-namespace ns]) (dynamic-require plugin 'the-plugin)))
(define f1 (load-fresh #:attach-kernel? #t))
(define f2 (load-fresh #:attach-kernel? #t))
(printf "B. two namespaces, two instances: ~a ; independent state: ~a ~a ~a\n" (not (eq? f1 f2)) (call f1) (call f1) (call f2))
(printf "B. without attaching the kernel the struct type is a different one: plugin? => ~a\n" (plugin? (load-fresh #:attach-kernel? #f)))

;; C. bytecode cache for plugin files. Create the handler AFTER selecting the namespace:
;;    it records the module registry at creation and silently skips compilation in any other.
(define-syntax-rule (ms e) (let ([t0 (current-inexact-milliseconds)]) e (round (- (current-inexact-milliseconds) t0))))
(define source-ms (ms (parameterize ([current-namespace (make-base-empty-namespace)]) (dynamic-require plugin #f))))
(parameterize ([current-namespace (make-base-namespace)])
  (parameterize ([current-load/use-compiled (make-compilation-manager-load/use-compiled-handler)])
    (dynamic-require plugin #f)))
(define zo-ms (ms (parameterize ([current-namespace (make-base-empty-namespace)]) (dynamic-require plugin #f))))
(printf "C. compiled files written: ~a ; load from source ~a ms, from .zo ~a ms\n" (length (directory-list (build-path dir "compiled"))) source-ms zo-ms)
(delete-directory/files dir)
```

**Observed:**

```text
A. v1: (v1 1) (v1 2)
A. files reloaded: 2
A. new value: (v2 1) ; old closure: (v1 2) ; new value again: (v2 3)
A. kernel.rkt unchanged, so both satisfy the same struct predicate: #t #t
B. two namespaces, two instances: #t ; independent state: (v2 1) (v2 2) (v2 1)
B. without attaching the kernel the struct type is a different one: plugin? => #f
C. compiled files written: 4 ; load from source 32.0 ms, from .zo 1.0 ms
```

Also observed:

- `dynamic-require` instantiates a module once per namespace; a second call returns the same values.
- `dynamic-rerequire` reloads only modules that it loaded itself. If the first load was a plain `dynamic-require`, a later `dynamic-rerequire` after an edit reloaded nothing. It prints to the error port unless `#:verbosity 'none` is passed. It returns the list of files it reloaded, and reloads dependents of a changed file.
- Variant A re-declares the module in place. The module-level variable `calls` was reset and is then shared by the old closure and the new one: the old closure printed `(v1 2)` and the next call of the new one printed `(v2 3)`. A module-level registry would be replaced under the feet of closures created before the reload.
- If the shared kernel file itself changes, a reload re-creates its struct types, and values made before the reload no longer satisfy the new predicates.
- `module->namespace` gives a namespace in which `eval` can use a module's internal definitions (the probe read and mutated a box held in a module-level variable; the mutation was visible through the module's export). `racket/rerequire` compiles reloaded modules with `compile-enforce-module-constants` set to `#f`, which is what permits re-definition in place, and it reloads a file only when its modification time in whole seconds is greater than the recorded one. `module->exports` and `module->imports` list a declared module's interface.
- A module can be declared from data with `(eval '(module name lang body ...))` and then required as `''name`.
- Resources created while a plugin module is instantiated land under `current-custodian` at that time: a thread started by evaluated plugin code was dead after the custodian was shut down.
- `filesystem-change-evt` works here (`(system-type 'fs-change)` is `#(supported scalable #f file-level)`): it fired for a rewrite, for a new file in a watched directory and for an atomic replace by rename. It is one-shot and must be created again after it fires.

**How to hot-reload a plugin and get a fresh instance.** Two workable recipes:

1. *One namespace per plugin generation* (variant B). Create `(make-base-empty-namespace)`, attach the kernel modules from the host namespace with `namespace-attach-module` so struct types and service keys are shared, and `dynamic-require` the plugin there. The old generation keeps its own variables until nothing references it. Cost: every non-attached dependency is instantiated again per generation.
2. *In-place re-declaration* (variant A, `racket/rerequire`). Cheaper, and dependents see the new definitions, but the old fiber must be fully disposed **before** the reload, because the reload overwrites module-level state that old closures still use.

**Compiled-load handlers.** `(use-compiled-file-paths)` is `(compiled)`; the default handler loads `compiled/<name>_rkt.zo` when its timestamp is not older than the source. `current-load/use-compiled` can be wrapped to observe or redirect every module load. `make-compilation-manager-load/use-compiled-handler` compiles on demand and writes `.zo` and `.dep` files, but only when the current namespace's module registry is the one that was current when the handler was created; created in the wrong order it silently compiles nothing.

**What this means for the port.** Both recipes work and both need the kernel to dispose the old instance through its own effect inverses. The analysis document's hot-reload section must state the dispose-then-reload order for the in-place recipe. Plugin files loaded from user directories should go through the compilation manager so that the second start is fast.

### `#lang` creation

A module language is a module that exports `#%module-begin` (and whatever else the body may use). This one requires a declaration at the top, generates a `plugin-info` submodule holding the declaration as data, and provides `plugin`.

```racket
#lang racket/base
;; A module language in one file. `plugin-lang` re-exports racket/base with its own #%module-begin.
(module plugin-lang racket/base
  (require (for-syntax racket/base syntax/parse))
  (provide (except-out (all-from-out racket/base) #%module-begin)
           (rename-out [plugin-module-begin #%module-begin]))
  (define-syntax (plugin-module-begin stx)
    (syntax-parse stx
      #:datum-literals (plugin-name inject)
      [(_ (plugin-name nm:str) (~optional (inject svc:id ...) #:defaults ([(svc 1) '()])) body ...)
       ;; names shared with the user's code are given the user's lexical context on purpose
       #:with plugin-id (datum->syntax stx 'plugin)
       #:with main-id (datum->syntax stx 'main)
       #'(#%module-begin
          (module plugin-info racket/base            ; the declaration as data, readable without running the body
            (provide info)
            (define info (hasheq 'name 'nm 'inject '(svc ...))))   ; quote user literals: their #%datum binding does not exist here
          (provide plugin-id)
          body ...
          (define plugin-id (hasheq 'name nm 'apply main-id)))]
      [(_ other . _) (raise-syntax-error 'plugin-lang "a plugin module must start with (plugin-name \"...\")" stx #'other)])))

(module weather (submod ".." plugin-lang)              ; in a file this line is `#lang s-exp "plugin-lang.rkt"` or `#lang cordis/plugin`
  (plugin-name "weather")
  (inject http logger)
  (printf "  [plugin body runs]\n")
  (define (main ctx) (list 'applied-to ctx)))

(define this-file (path->string (variable-reference->module-source (#%variable-reference))))
(define (sub . names) `(submod (file ,this-file) ,@names))
(printf "declaration read from the submodule, body not run: ~a\n" (dynamic-require (sub 'weather 'plugin-info) 'info))
(define plugin (dynamic-require (sub 'weather) 'plugin))
(printf "apply: ~a\n" ((hash-ref plugin 'apply) 'ctx))
(printf "missing declaration is a syntax error: ~a\n"
        (with-handlers ([exn:fail:syntax? (lambda (e) (car (regexp-split #rx"\n" (exn-message e))))])
          (parameterize ([current-namespace (make-base-namespace)])
            (expand `(module bad (submod (file ,this-file) plugin-lang) (define x 1))))))
```

**Observed:**

```text
declaration read from the submodule, body not run: #hasheq((inject . (http logger)) (name . weather))
  [plugin body runs]
apply: (applied-to ctx)
missing declaration is a syntax error: /opt/racket/collects/racket/private/kw.rkt:1163:24: plugin-lang: a plugin module must start with (plugin-name "...")
```

**From module language to `#lang`.** Three forms select the same language; all three were run with a collection named `plugin-lang`:

- `(module weather plugin-lang ...)` or `#lang s-exp plugin-lang`: needs only `plugin-lang/main.rkt`. The body is read with the ordinary S-expression reader.
- `#lang plugin-lang`: needs a reader module at `plugin-lang/lang/reader.rkt`. With `syntax/module-reader` the whole file is two lines: `#lang s-exp syntax/module-reader` and `plugin-lang`.
- A custom surface syntax (`#lang plugin-lang/kv` reading `key = value` lines) needs `plugin-lang/kv/lang/reader.rkt` exporting `read`, `read-syntax` and `get-info`; `read-syntax` returns a syntax object for a whole `(module name lang body ...)` form. A 15-line reader of this kind produced a module exporting a hash, and reported a malformed line with its line number through `raise-syntax-error`.

The collection became visible in three ways: `racket -S <dir>`, `PLTCOLLECTS`, and `raco pkg install --link` (after which `raco make` and `raco expand` work on files in the language).

Traps met while writing it, each a real error before the fix:

- Pattern variables are substituted inside `quote`. A template `(hasheq 'name name ...)` with a pattern variable called `name` produces the plugin's name as the key. Do not give a pattern variable the name of a quoted key.
- Identifiers the macro introduces are hygienic. A `plugin` binding that importing modules must see, or a reference to the user's `main`, needs `(datum->syntax stx 'plugin)`.
- A literal copied from the user's module into a generated `(module ...)` submodule fails with `literal data is not allowed; no #%datum syntax transformer is bound` unless it is wrapped in `quote`.

**What this means for the port.** `#lang cordis/plugin` as planned is feasible with little code, and the `plugin-info` submodule can be read with `dynamic-require` without instantiating the plugin body. An S-expression `#lang` costs two lines of reader; a custom reader is only worth it for a non-Lisp surface syntax.

### syntax-parse

```racket
#lang racket/base
(module defs racket/base
  (require (for-syntax racket/base syntax/parse) racket/contract)
  (provide define-service define-plugin define-event emit-event)
  (begin-for-syntax
    ;; compile-time records, found again with syntax-local-value
    (struct service-info (key methods)
      #:property prop:procedure (lambda (self stx) (raise-syntax-error #f "a service name is only allowed in an #:inject clause" stx)))
    (struct event-info (name mode arity))
    (define-syntax-class service-ref
      #:description "a service declared with define-service"
      (pattern name:id
               #:do [(define v (syntax-local-value #'name (lambda () #f)))]
               #:fail-unless (service-info? v) "not declared with define-service"
               #:with key (datum->syntax #'name (service-info-key v))))
    (define-syntax-class config-field
      #:description "a config field [name contract] or [name contract default]"
      (pattern [name:id ctc:expr] #:with required? #'#t)
      (pattern [name:id ctc:expr default:expr] #:with required? #'#f))
    (define-syntax-class mode
      #:description "a dispatch mode"
      (pattern (~or* (~datum emit) (~datum parallel) (~datum serial) (~datum bail) (~datum waterfall))))
    (define-splicing-syntax-class plugin-options
      #:description "plugin options"
      ;; nested attributes such as svc.key are exported only when listed here
      #:attributes ([svc.key 1] [field.name 1] [field.ctc 1] [field.required? 1])
      (pattern (~seq (~alt (~optional (~seq #:inject (svc:service-ref ...)) #:name "#:inject option" #:defaults ([(svc.key 1) '()]))
                           (~optional (~seq #:config (field:config-field ...)) #:name "#:config option"
                                      #:defaults ([(field.name 1) '()] [(field.ctc 1) '()] [(field.required? 1) '()])))
                     ...)
               #:fail-when (check-duplicate-identifier (syntax->list #'(field.name ...))) "duplicate config field")))
  (define-syntax (define-service stx)
    (syntax-parse stx
      [(_ name:id (~optional (~seq #:key key:id) #:defaults ([key #'name])) (method:id ...))
       #'(define-syntax name (service-info 'key '(method ...)))]))
  (define-syntax (define-plugin stx)
    (syntax-parse stx
      ;; pattern variables are substituted inside quote too: do not name one `name`, `inject` or `config`
      [(_ pid:id opts:plugin-options (~describe "(apply (ctx config) body ...)" ((~datum apply) (ctx:id cfg:id) body:expr ...+)))
       #'(define pid (hasheq 'name 'pid
                             'inject '(opts.svc.key ...)
                             'config (list (list 'opts.field.name opts.field.ctc opts.field.required?) ...)
                             'apply (lambda (ctx cfg) body ...)))]))
  (define-syntax (define-event stx)
    (syntax-parse stx
      [(_ name:id #:mode m:mode (param:id ...))
       #`(define-syntax name (event-info 'name 'm #,(length (syntax->list #'(param ...)))))]))
  (define-syntax (emit-event stx)
    (syntax-parse stx
      [(_ ev:id arg:expr ...)
       #:do [(define info (syntax-local-value #'ev (lambda () #f)))]
       #:fail-unless (event-info? info) "not an event declared with define-event"
       #:fail-unless (= (length (syntax->list #'(arg ...))) (event-info-arity info))
       (format "event ~a takes ~a argument(s)" (event-info-name info) (event-info-arity info))
       #`(list '#,(event-info-mode info) '#,(event-info-name info) arg ...)])))

(require 'defs racket/contract)
(define-service logger (info warn))
(define-service session-store #:key session (append! read))
(define-plugin audit
  #:config ([path string?] [max-size exact-positive-integer? 1024])
  #:inject (logger session-store)
  (apply (ctx config) (list 'applied ctx)))
(printf "name ~a inject ~a config ~a\n" (hash-ref audit 'name) (hash-ref audit 'inject)
        (for/list ([f (hash-ref audit 'config)]) (list (car f) (contract-name (cadr f)) (if (caddr f) 'required 'optional))))
(define-event tool/before #:mode waterfall (call next))
(printf "~a\n" (emit-event tool/before 'the-call 'the-next))
;; error messages: expand bad programs in a namespace that shares this file's definitions
(define this-file (path->string (variable-reference->module-source (#%variable-reference))))
(define (try label body)
  (printf "~a:\n" label)
  (with-handlers ([exn:fail:syntax? (lambda (e) (printf "  ~a\n" (cadr (regexp-match #rx"^(?:[^\n]*: )?([^\n:]+: [^\n]+)" (exn-message e)))))])
    (parameterize ([current-namespace (make-base-namespace)])
      (expand `(module m racket/base (require (submod (file ,this-file) defs)) (define-service logger (info)) ,@body)))
    (printf "  expanded without error\n")))
(try "unknown service" '((define-plugin p #:inject (nosuch) (apply (c k) 1))))
(try "option given twice" '((define-plugin p #:inject (logger) #:inject (logger) (apply (c k) 1))))
(try "malformed config field" '((define-plugin p #:config ([a]) (apply (c k) 1))))
(try "missing apply clause" '((define-plugin p #:inject (logger))))
(try "unknown dispatch mode" '((define-event e #:mode sometimes (a))))
(try "wrong number of event arguments" '((define-event e #:mode emit (a b)) (emit-event e 1)))
(try "service used as an expression" '((logger 1)))
```

**Observed:**

```text
name audit inject (logger session) config ((path string? required) (max-size exact-positive-integer? optional))
(waterfall tool/before the-call the-next)
unknown service:
  define-plugin: not declared with define-service
option given twice:
  define-plugin: too many occurrences of #:inject option
malformed config field:
  define-plugin: expected more terms starting with expression
missing apply clause:
  define-plugin: expected more terms starting with (apply (ctx config) body ...), the literal #:inject, or the literal #:config
unknown dispatch mode:
  expected one of these literal symbols: `emit', `parallel', `serial', `bail', or `waterfall'
wrong number of event arguments:
  emit-event: event e takes 2 argument(s)
service used as an expression:
  logger: a service name is only allowed in an #:inject clause
```

Also observed: the full messages carry the source location and a "while parsing ..." context built from the `#:description` strings; at the top level (outside a module) a `define-syntax` in the same `begin` is not visible to `syntax-local-value` in a later form of that `begin`, so compile-time registries must be tested inside modules.

**What this means for the port.** Keyword options in any order (`~alt` with `~optional` and `~seq`), duplicate detection, named error messages and compile-time lookup of declarations all work as the design assumes. Nested attributes (`opts.svc.key`) must be listed in `#:attributes` or the template fails with `undefined nested attribute`. `syntax/parse` at run time costs about 170 ms of start-up, so require it `for-syntax` only.

### racket/sandbox

```racket
#lang racket/base
(require racket/sandbox racket/file racket/async-channel)
(define-syntax-rule (try e)
  (with-handlers ([exn:fail:resource? (lambda (x) (format "resource limit: ~a" (exn:fail:resource-resource x)))]
                  [exn:fail:sandbox-terminated? (lambda (x) (format "terminated: ~a" (exn:fail:sandbox-terminated-reason x)))]
                  [exn:fail? (lambda (x) (car (regexp-split #rx"\n" (exn-message x))))])
    e))
(define dir (make-temporary-file "sbx~a" 'directory))
(define readable (build-path dir "readable.txt"))
(call-with-output-file readable (lambda (o) (void (write-string "data" o))))
(make-directory (build-path dir "out"))
(define ev
  (parameterize ([sandbox-eval-limits '(0.5 10)]                 ; seconds and MB per evaluation; default (30 20)
                 [sandbox-memory-limit 100]                       ; MB for the whole evaluator; default 30
                 [sandbox-output 'string]
                 [sandbox-path-permissions (list* (list 'read readable) (list 'write (build-path dir "out")) (sandbox-path-permissions))]
                 [sandbox-namespace-specs (append (sandbox-namespace-specs) '(racket/async-channel))])   ; share this module INSTANCE
    (make-evaluator 'racket/base '(require racket/async-channel))))
(printf "state persists between calls: ~a\n" (begin (ev '(define x 41)) (ev '(add1 x))))
(printf "time limit: ~a ; evaluator alive afterwards: ~a\n" (try (ev '(let loop () (loop)))) (evaluator-alive? ev))
(printf "memory limit per call: ~a\n" (try (ev '(let loop ([acc '()]) (loop (cons (make-bytes 1000000) acc))))))
(printf "read granted file: ~a\n" (try (ev `(call-with-input-file ,(path->string readable) read-line))))
(printf "read elsewhere: ~a\n" (try (ev '(call-with-input-file "/etc/hostname" read-line))))
(printf "write in granted dir: ~a ; elsewhere: ~a\n"
        (try (ev `(begin (call-with-output-file ,(path->string (build-path dir "out" "f")) (lambda (o) (write 1 o))) 'ok)))
        (try (ev `(call-with-output-file ,(path->string (build-path dir "g")) void))))
(printf "network: ~a\n" (try (ev '(begin (require racket/tcp) (tcp-connect "127.0.0.1" 9)))))
(printf "subprocess: ~a\n" (try (ev '(subprocess #f #f #f "/bin/echo" "hi"))))
(printf "ffi: ~a\n" (try (ev '(begin (require ffi/unsafe) (malloc 8)))))
;; host procedures: install a closure as a variable in the sandbox namespace
(define host-events '())
(call-in-sandbox-context ev (lambda () (namespace-set-variable-value! 'emit! (lambda (topic) (set! host-events (cons topic host-events)) (length host-events)))))
(printf "sandbox calls host closure: ~a ; host saw ~a\n" (ev '(emit! 'tool-call)) host-events)
;; the host closure runs on the sandbox thread, so the sandbox security guard still applies inside it
(call-in-sandbox-context ev (lambda () (namespace-set-variable-value! 'host-read (lambda (p) (call-with-input-file p read-line)))))
(printf "host closure doing a denied read: ~a\n" (try (ev '(host-read "/etc/hostname"))))
(define host-pz (current-parameterization))                       ; privileged variant: reinstall the host parameterization
(call-in-sandbox-context ev (lambda () (namespace-set-variable-value! 'host-read! (lambda (p) (call-with-parameterization host-pz (lambda () (and (call-with-input-file p read-line) 'read-ok)))))))
(printf "privileged host closure: ~a\n" (try (ev '(host-read! "/etc/hostname"))))
;; values are not copied; a shared module instance keeps struct identity across the boundary
(define ch (ev '(let ([c (make-async-channel)]) (async-channel-put c 'from-sandbox) c)))
(printf "async-channel made inside, used outside: ~a ~a\n" (async-channel? ch) (async-channel-get ch))
(printf "exit inside: ~a ; alive: ~a\n" (try (ev '(exit 3))) (evaluator-alive? ev))
(delete-directory/files dir)
```

**Observed:**

```text
state persists between calls: 42
time limit: resource limit: time ; evaluator alive afterwards: #t
memory limit per call: resource limit: memory
read granted file: data
read elsewhere: open-input-file: `read' access denied for /etc/hostname
write in granted dir: ok ; elsewhere: open-output-file: `write' access denied for /var/tmp/sbx.../g
network: tcp-connect: network access denied: '("127.0.0.1" 9 client)
subprocess: subprocess: `execute' access denied for /bin/echo
ffi: eval:11:0: ?: access disallowed by code inspector to protected variable
sandbox calls host closure: 1 ; host saw (tool-call)
host closure doing a denied read: open-input-file: `read' access denied for /etc/hostname
privileged host closure: read-ok
async-channel made inside, used outside: #t from-sandbox
exit inside: terminated: exited ; alive: #f
```

Also observed:

- Defaults: `(sandbox-memory-limit)` 30 MB, `(sandbox-eval-limits)` `(30 20)` (seconds, MB), network denied, no path permissions beyond the library collections, `(sandbox-propagate-exceptions)` `#t`, output discarded unless `sandbox-output` is set.
- Creating an evaluator for `racket/base` takes about 11 ms; for `racket` about 150 ms.
- A time-limit violation leaves the evaluator usable. Exceeding the evaluator-wide memory limit terminates it for good (`terminated: out-of-memory`); every later call raises `exn:fail:sandbox-terminated`. Memory limits are enforced at garbage collections, so a per-call limit close to the total limit can trip the total one first.
- `file-exists?` on a path outside the permissions is itself an access error (`exists` access denied).
- `getenv` works inside; `putenv` inside does not change the host environment.
- Threads started inside belong to the evaluator's custodian and die with `kill-evaluator`.
- `break-evaluator` interrupts a running evaluation with `user break`.
- A procedure returned from the sandbox can be called directly by the host; that call runs on the host thread without the sandbox limits. To apply limits, call it inside `(call-in-sandbox-context ev (lambda () (call-with-limits secs mb thunk)))`.
- `racket/unsafe/ops` is refused the same way as `ffi/unsafe`.

**What this means for the port.** The sandbox limits memory, time, file paths, network and process creation for Racket code in the same process, and it can share kernel modules by instance so that kernel structs keep their identity across the boundary. Host procedures are exposed as namespace variables; they run with the sandbox's restrictions unless they reinstall the host parameterization, which is the explicit privilege gate. It confines Racket code only. Tools that run external programs need operating-system confinement, which this machine can provide only through `unshare` (no `bwrap`).

### Subprocess management

```racket
#lang racket/base
(require racket/port racket/file ffi/unsafe)
(define sh "/bin/sh")
(define (state pid)                      ; "S"/"R" alive, "Z" dead but not yet reaped, #f gone (Linux /proc)
  (define f (format "/proc/~a/stat" pid))
  (and (file-exists? f) (with-handlers ([exn:fail? (lambda (e) #f)]) (cadr (regexp-match #rx"\\) ([A-Za-z])" (file->string f))))))
(define (spawn-tree group? mode cust)    ; a shell with a background grandchild; returns the subprocess and the grandchild pid
  (parameterize ([subprocess-group-enabled group?] [current-subprocess-custodian-mode mode] [current-custodian cust])
    (define-values (p out in err) (subprocess #f #f #f sh "-c" "sleep 60 & echo $!; wait"))
    (values p (string->number (read-line out)))))
(define killpg (get-ffi-obj "killpg" #f (_fun _int _int -> _int)))
;; 0. a child that leaves its process group (setsid) is not noticed by sync or subprocess-wait
;;    unless it was created with subprocess-group-enabled; polling subprocess-status still works
(define-values (p4 o4 i4 e4) (subprocess #f #f #f (find-executable-path "setsid") sh "-c" "sleep 0.3"))
(printf "setsid child, group disabled: sync ready within 2 s: ~a ; polled status: ~a\n" (and (sync/timeout 2 p4) #t) (subprocess-status p4))
(define-values (p5 o5 i5 e5) (parameterize ([subprocess-group-enabled #t]) (subprocess #f #f #f (find-executable-path "setsid") "-w" sh "-c" "sleep 0.3; exit 7")))
(printf "setsid -w child, group enabled: sync ready within 2 s: ~a ; status: ~a\n" (and (sync/timeout 2 p5) #t) (subprocess-status p5))
;; 1. ports, exit code, environment and directory are per call
(define-values (p out in err)
  (parameterize ([current-directory "/tmp"] [current-environment-variables (environment-variables-copy (current-environment-variables))])
    (putenv "PROBE" "42")
    (subprocess #f #f #f sh "-c" "echo $PROBE; read line; echo got:$line 1>&2; exit 3")))
(void (write-string "hello\n" in)) (close-output-port in)
(printf "stdout ~s stderr ~s status ~a ; host env untouched: ~a\n" (port->string out) (port->string err) (begin (subprocess-wait p) (subprocess-status p)) (getenv "PROBE"))
;; 2. custodian shutdown: what happens to the child and to the grandchild
(for* ([mode '(#f kill)] [group? '(#f #t)])
  (define c (make-custodian))
  (define-values (p gc) (spawn-tree group? mode c))
  (custodian-shutdown-all c) (sleep 0.2)
  (printf "custodian mode ~a, group ~a: child ~a, grandchild ~a\n" mode group? (subprocess-status p) (if (member (state gc) '("S" "R")) 'alive 'dead))
  (killpg (subprocess-pid p) 9) ((get-ffi-obj "kill" #f (_fun _int _int -> _int)) gc 9))
;; 3. graceful stop: interrupt, wait, then kill
(define-values (p2 o2 i2 e2) (parameterize ([subprocess-group-enabled #t]) (subprocess #f #f #f sh "-c" "trap 'echo bye; exit 0' INT; while :; do sleep 0.05; done")))
(sleep 0.1)
(subprocess-kill p2 #f)                                               ; SIGINT to the group
(unless (sync/timeout 1 p2) (subprocess-kill p2 #t))                  ; SIGKILL after the grace period
(printf "graceful: output ~s status ~a\n" (read-line o2) (subprocess-status p2))
;; 4. other signals need ffi
(define-values (p3 gc3) (spawn-tree #t #f (current-custodian)))
(printf "killpg(SIGTERM) => ~a ; status ~a\n" (killpg (subprocess-pid p3) 15) (begin (subprocess-wait p3) (subprocess-status p3)))
;; 5. both output streams must be drained concurrently
(define-values (p6 o6 i6 e6) (subprocess #f #f #f sh "-c" "head -c 300000 /dev/zero; head -c 300000 /dev/zero 1>&2"))
(define so (open-output-bytes)) (define se (open-output-bytes))
(define pumps (list (thread (lambda () (copy-port o6 so))) (thread (lambda () (copy-port e6 se)))))
(subprocess-wait p6) (for-each thread-wait pumps)
(printf "large output: ~a + ~a bytes\n" (bytes-length (get-output-bytes so)) (bytes-length (get-output-bytes se)))
```

**Observed:**

```text
setsid child, group disabled: sync ready within 2 s: #f ; polled status: 0
setsid -w child, group enabled: sync ready within 2 s: #t ; status: 7
stdout "42\n" stderr "got:hello\n" status 3 ; host env untouched: #f
custodian mode #f, group #f: child running, grandchild alive
custodian mode #f, group #t: child running, grandchild alive
custodian mode kill, group #f: child 137, grandchild alive
custodian mode kill, group #t: child 137, grandchild dead
graceful: output "bye" status 0
killpg(SIGTERM) => 0 ; status 143
large output: 300000 + 300000 bytes
```

Also observed:

- Defaults: `(current-subprocess-custodian-mode)` is `#f` and `(subprocess-group-enabled)` is `#f`. With those defaults a custodian shutdown does not touch the process, and `subprocess-kill` kills only the direct child, leaving a grandchild running.
- With `subprocess-group-enabled` the child's pid equals its process-group id, and `subprocess-kill` signals the whole group.
- `'interrupt` mode sends SIGINT; a shell's background jobs ignore SIGINT, so a background grandchild survived it.
- A dead orphan stays visible as a zombie (`Z` in `/proc/<pid>/stat`) in this container until it is reaped; `kill -0` succeeds on a zombie, so liveness checks must read the state.
- A process that starts its own session with `setsid` leaves the group and survives a group kill. Containing it needs a pid namespace, a cgroup or a subreaper.
- `subprocess-kill p #f` is SIGINT and `#t` is SIGKILL; SIGTERM and others need `kill(2)` or `killpg(2)` through the FFI (`(get-ffi-obj "killpg" #f (_fun _int _int -> _int))`).
- A subprocess is an event: `(sync p)` waits for exit, and it composes with `read-line-evt` and `alarm-evt` for streaming with a deadline.
- A file-stream port can be passed directly as the child's stdout or stderr; `'stdout` as the stderr argument merges the two.
- When the parent's stdout is not a terminal, Racket block-buffers it. A JSON-RPC or NDJSON writer must call `flush-output` after each message or set `(file-stream-buffer-mode port 'line)`.

**Pseudo-terminals.** There is no `racket/pty`. A working PTY needs about 30 lines of FFI:

```racket
#lang racket/base
;; A pseudo-terminal without a pty library: openpty(3) through the FFI, descriptors turned into
;; ports, and setsid(1) to make the slave the child's controlling terminal. Linux values.
(require ffi/unsafe ffi/unsafe/port racket/port racket/file)
(define libc (ffi-lib #f))
(define openpty (get-ffi-obj "openpty" libc (_fun (m : (_ptr o _int)) (s : (_ptr o _int)) _pointer _pointer _pointer -> (r : _int) -> (values r m s))))
(define killpg (get-ffi-obj "killpg" libc (_fun _int _int -> _int)))
(define-cstruct _winsize ([row _ushort] [col _ushort] [xpixel _ushort] [ypixel _ushort]))
(define ioctl (get-ffi-obj "ioctl" libc (_fun _int _ulong _winsize-pointer -> _int)))
(define TIOCSWINSZ #x5414)                                        ; Linux; macOS uses #x80087467
(define (pty-spawn command)                                       ; -> subprocess, master in, master out, session leader pid
  (define-values (rc master slave) (openpty #f #f #f))
  (ioctl master TIOCSWINSZ (make-winsize 40 120 0 0))
  (define-values (m-in m-out) (unsafe-file-descriptor->port master 'pty-master '(read write)))
  (define-values (s-in s-out) (unsafe-file-descriptor->port slave 'pty-slave '(read write)))
  (define-values (p _o _i _e)
    (parameterize ([subprocess-group-enabled #t])                 ; needed for sync to see the exit; it makes setsid fork, hence -w
      (subprocess s-out s-in s-out (find-executable-path "setsid") "-w" "-c" "/bin/sh" "-c" command)))
  (close-input-port s-in) (close-output-port s-out)               ; the parent keeps only the master
  (define wrapper (subprocess-pid p))
  (define leader (let loop () (define m (regexp-match #rx"[0-9]+" (file->string (format "/proc/~a/task/~a/children" wrapper wrapper))))
                   (if m (string->number (car m)) (begin (sleep 0.01) (loop)))))
  (values p m-in m-out leader))
(define (drain m-in [wait 0.3])
  (let loop ([acc #""])
    (define buf (make-bytes 4096))
    (define n (with-handlers ([exn:fail:filesystem:errno? (lambda (e) eof)])   ; EIO after the slave side closes means EOF
                (sync/timeout wait (read-bytes-avail!-evt buf m-in))))
    (if (and n (not (eof-object? n))) (loop (bytes-append acc (subbytes buf 0 n))) acc)))
(define-values (p in out leader) (pty-spawn "stty size; test -t 0 && echo is-a-tty; printf 'prompt> '; read x; echo got:$x; sleep 30"))
(printf "~s\n" (drain in))
(void (write-bytes #"hello\n" out)) (flush-output out)
(printf "~s\n" (drain in))
(void (write-bytes #"\3" out)) (flush-output out)                 ; Ctrl-C travels through the terminal to the foreground group
(printf "Ctrl-C: exited ~a, status ~a\n" (and (sync/timeout 2 p) #t) (subprocess-status p))
;; teardown: the shell is a grandchild in its own session, so killing the wrapper's group does not reach it
(define-values (p2 in2 out2 leader2) (pty-spawn "sleep 30"))
(subprocess-kill p2 #t) (sleep 0.2)
(define (alive? pid)                                              ; a "Z" entry is a dead process that init has not reaped yet
  (define f (format "/proc/~a/stat" pid))
  (and (file-exists? f) (member (cadr (regexp-match #rx"\\) ([A-Za-z])" (file->string f))) '("S" "R")) #t))
(printf "wrapper killed: status ~a ; session leader still alive: ~a\n" (subprocess-status p2) (alive? leader2))
(printf "killpg(leader, SIGKILL) => ~a ; alive afterwards: ~a\n" (killpg leader2 9) (begin (sleep 0.2) (alive? leader2)))
```

**Observed:**

```text
#"40 120\r\nis-a-tty\r\nprompt> "
#"hello\r\ngot:hello\r\n"
Ctrl-C: exited #t, status 2
wrapper killed: status 137 ; session leader still alive: #t
killpg(leader, SIGKILL) => 0 ; alive afterwards: #f
```

Other PTY routes that exist here: `script -qfec "<command>" /dev/null` (the child printed `/dev/pts/2` and `is-a-tty`), and Python's `pty` module.

**What this means for the port.** Spawn every tool process with `subprocess-group-enabled` and `current-subprocess-custodian-mode 'kill` under a per-call custodian; stop it with interrupt, a grace period, then kill. Always create with a group: without one, `sync` and `subprocess-wait` never report the exit of a child that changed its own session. Persistent terminals are possible in pure Racket on Linux with the FFI recipe, at the price of platform constants and an explicit `killpg` on the session leader at teardown.

### Places

```racket
#lang racket/base
(require racket/place)
;; The place body is lifted into a submodule that the new place instantiates together with this
;; module. Create places from a function, never from a module body that runs on instantiation:
;; a `place` form placed directly in (module+ main ...) starts places recursively.
(define (start-worker)
  (place ch
    (let loop ([count 0])
      (define msg (place-channel-get ch))
      (case (car msg)
        [(inc) (place-channel-put ch (add1 count)) (loop (add1 count))]
        [(echo) (place-channel-put ch (cdr msg)) (loop count)]
        [(spin) (let spin () (spin))]))))
(define (start-idle) (place ch (place-channel-get ch)))
(module+ main
  (define p (start-worker))
  (place-channel-put p '(inc)) (place-channel-put p '(inc))
  (printf "state lives in the place: ~a ~a\n" (place-channel-get p) (place-channel-get p))
  (place-channel-put p (list 'echo "str" 'sym 1.5 #"bytes" (vector 1 2) (hasheq 'k 'v) '#s(point 1 2)))
  (printf "copied message: ~s\n" (place-channel-get p))
  (struct opaque (x))
  (printf "can cross: closure ~a, opaque struct ~a, semaphore ~a, prefab ~a, path ~a, place channel ~a\n"
          (place-message-allowed? (lambda () 1)) (place-message-allowed? (opaque 1)) (place-message-allowed? (make-semaphore))
          (place-message-allowed? '#s(point 1 2)) (place-message-allowed? (string->path "/tmp")) (let-values ([(a b) (place-channel)]) (place-message-allowed? a)))
  (define t0 (current-inexact-milliseconds))
  (for ([i 5000]) (place-channel-put p '(echo 1 2 3)) (place-channel-get p))
  (printf "5000 round trips: ~a ms\n" (round (- (current-inexact-milliseconds) t0)))
  (place-channel-put p '(spin))
  (printf "busy place is not ready: ~a ; place-kill then place-wait: ~a\n" (sync/timeout 0.1 (place-dead-evt p)) (begin (place-kill p) (place-wait p)))
  (define c (make-custodian))
  (define p2 (parameterize ([current-custodian c]) (start-idle)))
  (custodian-shutdown-all c)
  (printf "custodian shutdown ends a place: ~a\n" (and (sync/timeout 2 (place-dead-evt p2)) #t)))
```

**Observed:**

```text
state lives in the place: 1 2
copied message: ("str" sym 1.5 #"bytes" #(1 2) #hasheq((k . v)) #s(point 1 2))
can cross: closure #f, opaque struct #f, semaphore #f, prefab #t, path #t, place channel #t
5000 round trips: 276.0 ms
busy place is not ready: #f ; place-kill then place-wait: 1
custodian shutdown ends a place: #t
```

Also observed: starting a place and getting the first reply took about 110 ms (the place loads its own instances of the modules); four more places took 15 ms to create; an error in a place prints on the place's error port and `place-wait` returns a non-zero code; `(exit 7)` inside gives `place-wait` 7; `dynamic-place*` lets the creator capture the place's output ports.

**What this means for the port.** A place is a separate Racket instance in the same OS process with message passing by copy. Closures, opaque structs, parameters and semaphores cannot cross, so a place cannot host a plugin that registers callbacks with the kernel. Places suit CPU-bound work with plain-data inputs and outputs. They are not a security boundary and not a substitute for a subprocess.

### Logging, struct printing, prefab structs

```racket
#lang racket/base
(require racket/match racket/port racket/logging)
;; loggers form a tree; receivers choose level per topic
(define-logger dsh)
(define-logger dsh-tools #:parent dsh-logger)
(define receiver (make-log-receiver dsh-logger 'debug 'dsh-tools 'warning #f))   ; debug for topic dsh-tools, warning for the rest
(log-dsh-info "dropped: below warning for topic dsh")
(log-dsh-tools-debug "tool ~a started" "bash")
(log-message dsh-logger 'error 'session "write failed" (hasheq 'sessionId "s1") #f)   ; structured data rides along
(let loop ()
  (match (sync/timeout 0 receiver)
    [(vector level message data topic) (printf "~a ~a ~s data=~a\n" level topic message (if (hash? data) data '-)) (loop)]
    [#f (void)]))
(printf "level test avoids formatting work: ~a\n" (log-level? dsh-logger 'debug 'dsh))
(printf "captured: ~s\n" (with-output-to-string (lambda () (with-logging-to-port (current-output-port) (lambda () (log-dsh-warning "careful")) #:logger dsh-logger 'warning))))
;; struct printing and prefab round trip
(struct opaque (a)) (struct clear (a) #:transparent) (struct event (type payload) #:prefab)
(printf "~s ~s ~s\n" (opaque 1) (clear 1) (event 'message (list "x" 1)))
(define text (format "~s" (event 'message (list "x" (event 'nested #f)))))
(define back (read (open-input-string text)))
(printf "prefab read back: equal ~a, predicate ~a, key ~a\n" (equal? back (event 'message (list "x" (event 'nested #f)))) (event? back) (prefab-struct-key back))
(printf "one more field is another type: ~a\n" (event? (read (open-input-string "#s(event a b c)"))))
(printf "a transparent struct does not read back as a struct: ~a\n" (clear? (read (open-input-string (format "~s" (clear 1))))))
```

**Observed:**

```text
write failed
debug dsh-tools "dsh-tools: tool bash started" data=-
error session "write failed" data=#hasheq((sessionId . s1))
level test avoids formatting work: #f
captured: "dsh: careful\n"
#<opaque> #(struct:clear 1) #s(event message ("x" 1))
prefab read back: equal #t, predicate #t, key event
one more field is another type: #f
a transparent struct does not read back as a struct: #f
```

The first line of the output is the default behavior of the root logger: a message at level `error` or above that reaches it is printed on the error port. `PLTSTDERR` (for example `PLTSTDERR="debug@dsh-tools warning"`) changes the levels per topic without code. A log receiver is an event and its queue is unbounded until read. `racket/serialize` handles non-prefab structs but embeds the defining module's path in the output, so moving a module breaks old data; `racket/fasl` gives a compact binary encoding of plain values and prefab structs.

**What this means for the port.** `define-logger` plus receivers covers dsh's logger service; a receiver thread can forward records to a file or to the session log. Because `raco test --drdr` counts any output on the error port as a failure, library code must log through loggers and not `eprintf`. Prefab structs are a ready-made self-describing durable form for Racket-only data, but dsh's durable formats are JSON, so prefabs matter mainly for caches and inter-place messages.

### JSON

```racket
#lang racket/base
(require json (only-in (submod json for-extension) read-json*) racket/string racket/port)
;; stock conventions
(define v (string->jsexpr "{\"b\":1,\"a\":[true,null,1.0,1e3],\"big\":12345678901234567890}"))
(printf "parsed: ~s\n" v)
(printf "immutable hasheq with symbol keys: ~a ; null is ~s ; integers exact: ~a\n" (and (hash-eq? v) (immutable? v)) (cadr (hash-ref v 'a)) (exact-integer? (hash-ref v 'big)))
(printf "not jsexprs: string keys ~a, symbols ~a, 1/2 ~a, +inf.0 ~a, vectors ~a\n" (jsexpr? (hash "a" 1)) (jsexpr? 'x) (jsexpr? 1/2) (jsexpr? +inf.0) (jsexpr? (vector 1)))
(printf "stock writer sorts keys and prints flonums the Racket way: ~a\n" (jsexpr->string (hasheq 'zeta 10.0 'alpha 1e21 'mid -0.0)))
(printf "NDJSON: read-json reads one value per call: ~s\n" (let ([in (open-input-string "{\"a\":1}\n{\"a\":2}\n")]) (list (read-json in) (read-json in) (read-json in))))
;; order-preserving parse through the for-extension submodule
(struct ordered (pairs) #:transparent)                   ; (listof (cons string value)) in source order
(define (read-json/ordered in)
  (read-json* 'read-json/ordered in #:replace-malformed-surrogate? #f #:null 'null
              #:make-object ordered #:make-list values #:make-key values #:make-string values))
(define doc (read-json/ordered (open-input-string "{\"type\":\"function\",\"name\":\"bash\",\"parameters\":{\"z\":1,\"a\":2.50}}")))
(printf "ordered parse: ~s\n" doc)
;; a writer that matches JSON.stringify: insertion order, ECMAScript number layout, minimal escaping.
;; js-number->string agreed with Node 22 on 140,016 doubles (random magnitudes, random bit patterns, tie cases).
(define (shortest-digits x)                 ; positive flonum -> (values digit-string n) with x ~ 0.digits * 10^n
  (define m (regexp-match #rx"^([0-9]*)\\.?([0-9]*)(?:e([-+]?[0-9]+))?$" (number->string x)))
  (define int-part (cadr m))
  (define all (string-append int-part (caddr m)))
  (define lead (let loop ([i 0]) (if (and (< i (string-length all)) (char=? (string-ref all i) #\0)) (loop (add1 i)) i)))
  (define digits (string-trim (substring all lead) "0" #:left? #f #:repeat? #t))
  (values digits (+ (- (string-length int-part) lead) (if (cadddr m) (string->number (cadddr m)) 0))))
(define (fix-tie x digits n)
  (define k (string-length digits))
  (define unit (expt 10 (- n k)))
  (define d (* (string->number digits) unit))
  (define exact (inexact->exact x))
  (cond
    [(= d exact) digits]
    [else
     (define other (if (> d exact) (- d unit) (+ d unit)))
     (cond
       [(and (= (abs (- other exact)) (abs (- d exact)))                 ; exact tie
             (= (exact->inexact other) x)                                ; the other candidate also reads back as x
             (odd? (string->number (substring digits (sub1 k)))))       ; ours ends in an odd digit: take the even one
        (define s (number->string (/ other unit)))
        (if (= (string-length s) k) s digits)]                           ; same digit count only
       [else digits])]))
(define (js-number->string x)
  (cond
    [(exact-integer? x) (number->string x)]
    [(not (rational? x)) "null"]
    [(zero? x) "0"]
    [else
     (define-values (digits0 n) (shortest-digits (abs x)))
     (define digits (fix-tie (abs x) digits0 n))
     (define k (string-length digits))
     (string-append
      (if (< x 0) "-" "")
      (cond [(and (<= k n) (<= n 21)) (string-append digits (make-string (- n k) #\0))]
            [(and (< 0 n) (<= n 21)) (string-append (substring digits 0 n) "." (substring digits n))]
            [(and (< -6 n) (<= n 0)) (string-append "0." (make-string (- n) #\0) digits)]
            [else (string-append (substring digits 0 1) (if (= k 1) "" (string-append "." (substring digits 1)))
                                 "e" (if (< n 1) "-" "+") (number->string (abs (sub1 n))))]))]))
(define (write-js-string s out)
  (write-char #\" out)
  (for ([c (in-string s)])
    (case c
      [(#\") (write-string "\\\"" out)] [(#\\) (write-string "\\\\" out)] [(#\newline) (write-string "\\n" out)]
      [(#\return) (write-string "\\r" out)] [(#\tab) (write-string "\\t" out)] [(#\backspace) (write-string "\\b" out)] [(#\page) (write-string "\\f" out)]
      [else (if (< (char->integer c) 32)
                (let ([h (number->string (char->integer c) 16)]) (write-string "\\u" out) (write-string (make-string (- 4 (string-length h)) #\0) out) (write-string h out))
                (write-char c out))]))
  (write-char #\" out))
(define (write-json/js v [out (current-output-port)])
  (let loop ([v v])
    (define (items xs each) (for ([x (in-list xs)] [i (in-naturals)]) (unless (zero? i) (write-char #\, out)) (each x)))
    (cond [(ordered? v) (write-char #\{ out) (items (ordered-pairs v) (lambda (p) (write-js-string (car p) out) (write-char #\: out) (loop (cdr p)))) (write-char #\} out)]
          [(list? v) (write-char #\[ out) (items v loop) (write-char #\] out)]
          [(string? v) (write-js-string v out)]
          [(real? v) (write-string (js-number->string v) out)]
          [(eq? v #t) (write-string "true" out)] [(eq? v #f) (write-string "false" out)] [(eq? v 'null) (write-string "null" out)]
          [else (error 'write-json/js "not a JSON value: ~e" v)])))
(printf "round trip keeps order and JS number layout: ~a\n" (with-output-to-string (lambda () (write-json/js doc))))
(printf "numbers: ~a\n" (map js-number->string (list 10.0 1e21 1e-7 -0.0 123456789012345680000.0 0.1 5e-324 1.5 100 2118924120612493.25)))
(printf "the last one printed by Racket: ~a\n" (number->string 2118924120612493.25))
```

**Observed:**

```text
parsed: #hasheq((a . (#t null 1.0 1000.0)) (b . 1) (big . 12345678901234567890))
immutable hasheq with symbol keys: #t ; null is null ; integers exact: #t
not jsexprs: string keys #f, symbols #f, 1/2 #f, +inf.0 #f, vectors #f
stock writer sorts keys and prints flonums the Racket way: {"alpha":1e+21,"mid":-0.0,"zeta":10.0}
NDJSON: read-json reads one value per call: (#hasheq((a . 1)) #hasheq((a . 2)) #<eof>)
ordered parse: #(struct:ordered (("type" . "function") ("name" . "bash") ("parameters" . #(struct:ordered (("z" . 1) ("a" . 2.5))))))
round trip keeps order and JS number layout: {"type":"function","name":"bash","parameters":{"z":1,"a":2.5}}
numbers: (10 1e+21 1e-7 0 123456789012345680000 0.1 5e-324 1.5 100 2118924120612493.2)
the last one printed by Racket: 2118924120612493.3
```

Also observed:

- A JSON object is read as an immutable `hasheq` with symbol keys, `null` as the symbol `null` (the `json-null` parameter or the `#:null` argument changes it), integers as exact integers of any size, numbers with a fraction or exponent as flonums. Duplicate keys: the last wins.
- **Key order is not preserved.** The stock reader builds a hash; the stock writer emits keys in sorted order (the same data always serializes the same way, which is not insertion order).
- The stock writer differs from `JSON.stringify` in number layout (`10.0`, `-0.0`, `1.2345678901234568e+20` against `10`, `0`, `123456789012345680000`) and in escaping U+007F (it writes `\u007f`; JavaScript writes the character). With the default `#:encode 'control` other non-ASCII characters are written raw, as in JavaScript.
- Racket's flonum printer and V8 disagree on the last digit when two shortest decimal candidates are exactly equally close (for example `2118924120612493.25`). Without the tie rule in `fix-tie`, 29 to 35 of 25,000 random doubles differed from Node; with it, 0 of 140,016 did.
- Exact integers above 2^53 keep full precision in Racket and lose it in JavaScript.
- Racket strings cannot hold lone surrogates; `read-json` rejects `"\ud800"` unless `#:replace-malformed-surrogate? #t`.
- Throughput of the stock library: 1.29 MB encoded in 249 ms, decoded in 103 ms.
- `write-json #:indent 2` exists for human-readable output.

**What this means for the port.** Any format that must match bytes written by the TypeScript harness (session logs, recorded snapshots, request bodies compared with fixtures) needs an ordered object representation and the writer above, not the stock `jsexpr` conventions. For internal use where order does not matter, `hasheq` jsexprs are convenient and fast enough.

### Time, dates and cron-like scheduling

```racket
#lang racket/base
(require racket/match racket/list racket/string racket/date data/heap)
;; Date#toISOString and back; only UTC and the process-local zone are built in
(define (pad n w) (let ([s (number->string n)]) (string-append (make-string (max 0 (- w (string-length s))) #\0) s)))
(define (ms->iso ms)
  (define-values (secs millis) (quotient/remainder (inexact->exact (floor ms)) 1000))
  (define d (seconds->date secs #f))
  (format "~a-~a-~aT~a:~a:~a.~aZ" (pad (date-year d) 4) (pad (date-month d) 2) (pad (date-day d) 2) (pad (date-hour d) 2) (pad (date-minute d) 2) (pad (date-second d) 2) (pad millis 3)))
(define (iso->ms s)
  (match (regexp-match #px"^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.(\\d{1,3}))?Z$" s)
    [(list _ y mo d h mi sec frac)
     (+ (* 1000 (find-seconds (string->number sec) (string->number mi) (string->number h) (string->number d) (string->number mo) (string->number y) #f))
        (if frac (string->number (substring (string-append frac "00") 0 3)) 0))]
    [_ #f]))
(printf "~a ~a\n" (ms->iso 1794559000123.7) (iso->ms "2026-11-13T08:36:40.123Z"))
;; five-field cron in UTC: minute hour day-of-month month day-of-week
(define (parse-field s lo hi)
  (remove-duplicates
   (append* (for/list ([part (string-split s ",")])
              (match (regexp-match #px"^(\\*|(\\d+)(?:-(\\d+))?)(?:/(\\d+))?$" part)
                [(list _ star a b step)
                 (define from (if (equal? star "*") lo (string->number a)))
                 (define to (cond [(equal? star "*") hi] [b (string->number b)] [step hi] [else from]))
                 (range from (add1 to) (if step (string->number step) 1))]
                [_ (error 'cron "bad field ~s" part)])))))
(define (parse-cron s)
  (match (string-split s)
    [(list mi h dom mo dow) (list (parse-field mi 0 59) (parse-field h 0 23) (parse-field dom 1 31) (parse-field mo 1 12) (parse-field dow 0 6) (not (equal? dom "*")) (not (equal? dow "*")))]
    [_ (error 'cron "expected five fields")]))
(define (cron-match? c secs)
  (match-define (list mis hs doms mos dows dom? dow?) c)
  (define d (seconds->date secs #f))
  (and (memv (date-minute d) mis) (memv (date-hour d) hs) (memv (date-month d) mos)
       (if (and dom? dow?)                                            ; POSIX: when both day fields are restricted, either may match
           (or (memv (date-day d) doms) (memv (date-week-day d) dows))
           (and (memv (date-day d) doms) (memv (date-week-day d) dows)))
       #t))
(define (cron-next c after-secs)
  (for/first ([t (in-range (* 60 (add1 (quotient after-secs 60))) (+ after-secs (* 5 366 86400)) 60)] #:when (cron-match? c t)) t))
(for ([expr '("*/15 * * * *" "0 9 * * 1-5" "0 0 29 2 *")])
  (printf "~a -> ~a\n" expr (ms->iso (* 1000 (cron-next (parse-cron expr) 1794559000)))))
;; scheduler: one thread, a heap ordered by due time, sync on (new job) or (earliest alarm)
(define (make-scheduler on-fire)
  (define jobs (make-heap (lambda (a b) (<= (car a) (car b)))))
  (define inbox (make-channel))
  (define th (thread (lambda ()
                       (let loop ()
                         (define next (and (positive? (heap-count jobs)) (heap-min jobs)))
                         (sync (handle-evt inbox (lambda (job) (heap-add! jobs job) (loop)))
                               (if next
                                   (handle-evt (alarm-evt (car next))                       ; wall clock ms; pass #t as second argument for monotonic time
                                               (lambda (_) (heap-remove-min! jobs) (unless (unbox (caddr next)) (on-fire (cadr next))) (loop)))
                                   never-evt))))))
  (values (lambda (delay-ms name) (define cancelled (box #f)) (channel-put inbox (list (+ (current-inexact-milliseconds) delay-ms) name cancelled)) (lambda () (set-box! cancelled #t)))
          th))
(define fired '())
(define-values (schedule! scheduler-thread) (make-scheduler (lambda (name) (set! fired (cons name fired)))))
(void (schedule! 60 'c) (schedule! 20 'a))
(define cancel-b (schedule! 40 'b))
(cancel-b)
(sleep 0.12)
(printf "fired in due order, b cancelled: ~a\n" (reverse fired))
(kill-thread scheduler-thread)
```

**Observed:**

```text
2026-11-13T08:36:40.123Z 1794559000123
*/15 * * * * -> 2026-11-13T08:45:00.000Z
0 9 * * 1-5 -> 2026-11-13T09:00:00.000Z
0 0 29 2 * -> 2028-02-29T00:00:00.000Z
fired in due order, b cancelled: (a c)
```

Also observed: `(current-inexact-milliseconds)` is a flonum of wall-clock milliseconds, `(current-inexact-monotonic-milliseconds)` a monotonic clock starting near zero at process start, `(current-seconds)` an integer; `seconds->date` with `#f` gives UTC; `date->string` with `(date-display-format 'iso-8601)` prints `2026-11-13T08:36:40` without fraction or zone, so the `toISOString` form is hand-built; an alarm set 25 ms ahead fired after 25 ms; an alarm far in the future does not delay nearer ones; 100 calls of `(sleep 0.001)` took 112 ms. Only UTC and the process-local zone are available without a package; named IANA zones need `gregor` with `tzinfo` (not installed).

**What this means for the port.** A scheduler is one thread that syncs on its inbox and on the earliest `alarm-evt`. Cancellation is a flag checked at fire time or removal from the heap. Use the monotonic clock for delays and timeouts and the wall clock only for cron matching and timestamps.

### HTTP client streaming and web-server

```racket
#lang racket/base
(require web-server/web-server web-server/servlet web-server/dispatch (prefix-in lift: web-server/dispatchers/dispatch-lift)
         net/http-client racket/tcp racket/port racket/string racket/async-channel json)
;; ---- server: dispatch-rules + response/output streaming ----
(define handler-state (make-hash))                           ; id -> 'running | 'finished | 'write-error
(define (sse-handler req id)
  (response/output
   #:mime-type #"text/event-stream" #:headers (list (header #"Cache-Control" #"no-cache"))
   (lambda (out)
     (hash-set! handler-state id 'running)
     (hash-set! handler-state id
                (with-handlers ([exn:fail? (lambda (e) 'write-error)])
                  (for ([i 40]) (fprintf out "event: delta\ndata: ~a\n\n" (jsexpr->string (hasheq 'i i))) (flush-output out) (sleep 0.02))
                  (fprintf out "data: [DONE]\n\n")
                  'finished)))))
(define-values (dispatch url-for)
  (dispatch-rules [("v1" "stream" (string-arg)) sse-handler]
                  [("v1" "echo") #:method "post" (lambda (req) (response/jsexpr (hasheq 'got (bytes->jsexpr (request-post-data/raw req)))))]
                  [else (lambda (req) (response/jsexpr #:code 404 (hasheq 'error "not found")))]))
(define port-ch (make-async-channel))
(define stop (serve #:dispatch (lift:make dispatch) #:listen-ip "127.0.0.1" #:port 0 #:confirmation-channel port-ch))
(define port (async-channel-get port-ch))                     ; port 0 = ephemeral; the real port arrives on the channel
(printf "reverse route: ~a\n" (url-for sse-handler "abc"))
;; ---- plain request ----
(let-values ([(status headers in) (http-sendrecv "127.0.0.1" "/v1/echo" #:port port #:method #"POST"
                                                #:headers '("Content-Type: application/json") #:data (jsexpr->bytes (hasheq 'model "m")))])
  (printf "~a ~s\n" status (read-json in)))
;; ---- SSE reader over any input port ----
(define (read-sse-event in)                                   ; -> (cons event-name data) or eof
  (let loop ([event #f] [data '()])
    (define line (read-line in 'any))
    (cond [(eof-object? line) (if (null? data) eof (cons event (string-join (reverse data) "\n")))]
          [(string=? line "") (if (null? data) (loop #f '()) (cons event (string-join (reverse data) "\n")))]
          [(regexp-match #rx"^event: ?(.*)$" line) => (lambda (m) (loop (cadr m) data))]
          [(regexp-match #rx"^data: ?(.*)$" line) => (lambda (m) (loop event (cons (cadr m) data)))]
          [else (loop event data)])))
;; ---- a cancellable streaming request: own the socket, one custodian per request ----
(define (open-stream path)                                    ; -> custodian, body port (chunked framing left in place here)
  (define cust (make-custodian))
  (define-values (in out) (parameterize ([current-custodian cust]) (tcp-connect "127.0.0.1" port)))
  (fprintf out "GET ~a HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n" path)
  (flush-output out)
  (let loop () (define l (read-line in 'return-linefeed)) (unless (or (eof-object? l) (string=? l "")) (loop)))   ; skip status line and headers
  (values cust in))
(define-values (cust in) (open-stream "/v1/stream/a"))
(define t0 (current-inexact-milliseconds))
(define first-two (list (read-sse-event in) (read-sse-event in)))
(printf "events arrive as they are sent: ~s after ~a ms\n" first-two (round (- (current-inexact-milliseconds) t0)))
(define outcome (box #f))
(define reader (thread (lambda () (set-box! outcome (with-handlers ([exn:fail? (lambda (e) (car (regexp-split #rx"\n" (exn-message e))))])
                                                      (let loop () (if (eof-object? (read-sse-event in)) 'eof (loop))))))))
(custodian-shutdown-all cust)                                 ; cancel: closes the socket
(printf "blocked reader ends: ~a with ~s ; " (and (sync/timeout 1 (thread-dead-evt reader)) #t) (unbox outcome))
(sleep 0.3)
(printf "server handler saw: ~a\n" (hash-ref handler-state "a"))
;; ---- the convenience API does not cancel: closing its port leaves the request running ----
(let-values ([(status headers in2) (http-sendrecv "127.0.0.1" "/v1/stream/b" #:port port)])
  (read-sse-event in2)
  (close-input-port in2)
  (sleep 0.3)
  (printf "http-sendrecv + close-input-port, server handler state: ~a\n" (hash-ref handler-state "b")))
(stop)
```

**Observed:**

```text
reverse route: /v1/stream/abc
HTTP/1.1 200 OK #hasheq((got . #hasheq((model . "m"))))
events arrive as they are sent: (("delta" . "{\"i\":0}") ("delta" . "{\"i\":1}")) after 20.0 ms
blocked reader ends: #t with "read-line: input port is closed" ; server handler saw: write-error
http-sendrecv + close-input-port, server handler state: running
```

**Client side, which action really ends a streaming request. Observed** against the same kind of server, one case per process:

| Client action | Socket closed? | Reader of the body port afterwards |
|---|---|---|
| `http-sendrecv`, then `close-input-port` on the returned port | no; the server streamed to the end | n/a |
| `http-conn-open` + `send!`/`recv!`, then `http-conn-abandon!` | no | reads to end of stream |
| same, then `http-conn-close!` | yes | `input port is closed` error |
| `http-sendrecv` under a custodian, then `custodian-shutdown-all` | yes | **blocks forever** (the port is a pipe fed by a thread that was just killed) |
| raw `tcp-connect` under a custodian, then shutdown | yes | `input port is closed` error |
| `http-easy` `#:stream? #t`, then `response-close!` | no; it drains the body, and here raised `read-line: input port is closed` from its chunk thread | n/a |

`net/http-client` decodes chunked bodies and `Connection: close` bodies through a pipe and a copying thread, which is why closing the returned port or killing its custodian does not behave like closing a socket. `net/http-client` and `net/http-easy` are fine for non-streaming calls; `http-conn` with `#:close? #f` gives keep-alive.

**Server side, how a `response/output` handler learns that the client left. Observed:**

- Client asked for `Connection: close`: a later write raises `exn:fail` (`error writing to stream port`), the handler's `dynamic-wind` post thunk runs.
- Client used HTTP/1.1 keep-alive (the browser default; the response is chunked): the handler thread is killed silently when the connection's custodian shuts down. No exception, no post thunk. A watcher thread created under a longer-lived custodian that waits on `(thread-dead-evt handler-thread)`, or on a custodian box made from the handler's `(current-custodian)`, did observe it.

Also observed: `dispatch-rules` gives typed path arguments (`(integer-arg)`, `(string-arg)`), method filters and a reverse-routing function; `serve` with `#:port 0` and `#:confirmation-channel` reports the real port; `response/jsexpr` writes JSON; request data comes from `request-post-data/raw`, `request-headers/raw` and `request-bindings/raw`; static files are served by `files:make` with `make-url->path` (which rejects `..` by raising, dropping the connection instead of answering 404); dispatchers chain with `seq:make`, a dispatcher passing to the next by raising `next-dispatcher`; the server and all its connections stop when the custodian it was started under is shut down.

**What this means for the port.** The model adapters need their own small HTTP/1.1 client: one custodian per request, `tcp-connect` or `ssl-connect` with a secure context, hand-written request, direct reads from the socket port, chunked decoding inline. Cancel is `custodian-shutdown-all`, after which the blocked reader gets an error it can map to "cancelled". For server-sent events toward the browser, per-connection cleanup must hang on a watcher, not on the handler's own unwinding.

### WebSocket

```racket
#lang racket/base
;; Needs the rfc6455 package (not preinstalled, LGPL-3.0). Mount the dispatcher on web-server's
;; `serve`: ws-serve with #:confirmation-channel fails in this version (keyword-apply error).
(require net/rfc6455 net/rfc6455/dispatcher net/url net/http-client web-server/web-server web-server/servlet web-server/dispatch
         (prefix-in lift: web-server/dispatchers/dispatch-lift) (prefix-in seq: web-server/dispatchers/dispatch-sequencer) racket/async-channel json)
(define (on-connection conn state)
  (let loop ()
    (define msg (ws-recv conn #:payload-type 'text))
    (unless (eof-object? msg)
      (ws-send! conn (jsexpr->string (hasheq 'jsonrpc "2.0" 'id (hash-ref (string->jsexpr msg) 'id) 'result "pong")))
      (loop))))
(define-values (http _u) (dispatch-rules [("health") (lambda (req) (response/jsexpr (hasheq 'ok #t)))]))
(define port-ch (make-async-channel))
(define cust (make-custodian))
(void (parameterize ([current-custodian cust])
  (serve #:dispatch (seq:make (make-general-websockets-dispatcher on-connection) (lift:make http))   ; HTTP and WebSocket on one port
         #:listen-ip "127.0.0.1" #:port 0 #:confirmation-channel port-ch)))
(define port (async-channel-get port-ch))
(let-values ([(status headers in) (http-sendrecv "127.0.0.1" "/health" #:port port)]) (printf "http: ~a ~s\n" status (read-json in)))
(define c (ws-connect (string->url (format "ws://127.0.0.1:~a/rpc" port))))
(ws-send! c (jsexpr->string (hasheq 'jsonrpc "2.0" 'id 1 'method "ping")))
(printf "ws reply: ~a\n" (ws-recv c))
(printf "ws-recv-evt works with sync/timeout: ~a\n" (sync/timeout 0.05 (ws-recv-evt c)))
(custodian-shutdown-all cust)
(printf "after server custodian shutdown the client reads: ~a\n" (sync/timeout 2 (ws-recv-evt c)))
```

**Observed** (with `rfc6455` installed in an isolated add-on directory):

```text
http: HTTP/1.1 200 OK #hasheq((ok . #t))
ws reply: {"id":1,"jsonrpc":"2.0","result":"pong"}
ws-recv-evt works with sync/timeout: #f
after server custodian shutdown the client reads: #<eof>
```

Also observed: `ws-serve` with `#:confirmation-channel` raises `keyword-apply: contract violation` in this version of the package, so the dispatcher must be mounted on `web-server`'s `serve` as above; `ws-send!` sends a text frame by default even for bytes (pass `#:payload-type 'binary`); a 200,000-character frame round-trips; `ws-close!` takes `#:status` and `#:reason`, and the peer reads them with `ws-conn-close-status` and `ws-conn-close-reason`; the connection handler receives the request line through `ws-conn-line`.

**What this means for the port.** WebSocket service for the browser client and for a JSON-RPC SDK channel is available by vendoring one small package, on the same port as the HTTP routes. The LGPL-3.0 notice in its source needs a licensing decision before it is vendored; the alternative is a few hundred lines implementing RFC 6455 framing on `web-server`'s connection ports.

### raco test conventions

A two-package layout was built and linked; the commands below were run against it.

```text
multipkg/
  cordis-lib/                 package directory
    info.rkt                  (define collection 'multi) (define deps '("base")) (define build-deps '("rackunit-lib"))
    cordis/                   collection `cordis`
      info.rkt                (define test-omit-paths '("tests/slow-test.rkt" #rx"fixtures"))
      main.rkt                (require cordis) resolves here; has (module+ test ...)
      tests/kernel-test.rkt   rackunit suite run from (module+ test (run-tests suite))
      tests/slow-test.rkt     omitted by test-omit-paths
  dsh-core/
    info.rkt                  (define collection 'multi) (define deps '("base" "cordis-lib"))
    dsh/core/
      info.rkt                (define compile-omit-paths '("scratch")) (define test-omit-paths '("scratch"))
      main.rkt                (require cordis)
      scratch/broken.rkt      does not compile; skipped by both omit lists
```

**Observed:**

- `raco pkg install --link --scope user --no-docs --batch --deps fail ./cordis-lib ./dsh-core` links both; `dsh-core` finds `cordis-lib` because it is installed in the same command.
- `raco test -p cordis-lib` runs every module of the package; `raco test -c dsh/core` runs a collection path; `raco test dir ...` runs directories; `raco test file.rkt` runs one file. Exit code is 0 when all pass, 1 on failure, 2 when a test timed out.
- For each module, `raco test` runs the `test` submodule if there is one. **If there is none, it runs the module itself.** A helper file in a test directory therefore has its body executed, and `info.rkt` files appear in the run as zero-test modules. `-x` (`--no-run-if-absent`) skips modules without a `test` submodule; with it, a file that has its checks at module top level is skipped silently (2 tests reported instead of 3 in the trial).
- `(module+ test ...)` bodies can use bare checks (`check-equal?` and friends count as tests) or build a `test-suite` and call `run-tests` from `rackunit/text-ui`; a failing check inside `run-tests` is counted in the summary (`1/5 test failures`).
- A `main` submodule is not run by `raco test`.
- Several files run in separate processes by default (`--process`); a single file runs in the `raco` process (`--direct`). `-j N` runs N files in parallel; `--table` prints per-file counts.
- Timeouts are off unless requested. `(module config info (define timeout 1))` inside the `test` submodule had no effect until `--timeout <seconds>` (or `--timeout +inf.0`, or `--drdr`) was passed; then the test was stopped after 1 s and counted as a failure. The same `config` submodule accepts `lock-name` to serialize tests that share a resource.
- Output on the error port does not fail a test by default; it does with `-e` (`--check-stderr`) and with `--drdr` (the mode the package catalog's build service uses).
- **Stale bytecode gives wrong results.** With `compiled/*.zo` present for a test file and its dependency, editing the dependency (a constant, a macro, a struct's field count) and running `raco test` again still reported the old behavior. The default load handler checks each `.zo` only against its own source timestamp; constants and macro expansions from the dependency are already inside the dependent's `.zo`. `raco test --make` (`-y`), or `raco make` before the run, or deleting `compiled/`, fixed it. A `.zo` that is newer than an older checked-out source is also used.
- `raco make` writes `compiled/` directories next to sources (they must be ignored by git). `PLTCOMPILEDROOTS=/abs/zo-root:` redirects them out of the tree.
- Without installing anything, `PLTCOLLECTS=":/abs/cordis-lib:/abs/dsh-core" raco test dsh-core/dsh/core/main.rkt` ran the test.
- Module path rule that the layout must respect: `(require cordis)` means `cordis/main.rkt`, but `(require dsh/core)` means `dsh/core.rkt`, not `dsh/core/main.rkt`. `main.rkt` is implied only for a one-element path.

`info.rkt` fields that matter: at package level `collection` (a string for a single-collection package, `'multi` when the package directory contains collection directories), `deps`, `build-deps`, `version`, `license`, `pkg-desc`; at collection level `test-omit-paths` and `compile-omit-paths` (strings, regexps, or `'all`), `test-timeouts`, `test-lock-names`, `test-responsibles`.

**What this means for the port.** The repository gate should be a script that sets `PLTCOLLECTS` (or links into a private `PLTADDONDIR`), runs `raco make` on everything, then `raco test` without `-x`, with `--timeout`, and checks that the number of visited files and tests did not shrink. The Stone project reached the same rules independently; see [The Stone library](#the-stone-library).

### Typed Racket boundary costs

```racket
#lang racket/base
(module typed typed/racket/base
  (provide add1* sum-list apply-callback sum-hash)
  (: add1* (-> Integer Integer))
  (define (add1* x) (+ x 1))
  (: sum-list (-> (Listof Integer) Integer))
  (define (sum-list l) (for/sum : Integer ([x (in-list l)]) x))
  (: apply-callback (-> (-> Integer Integer) Integer Integer))
  (define (apply-callback f n) (for/fold ([acc : Integer 0]) ([i (in-range n)]) (f acc)))
  (: sum-hash (-> (HashTable Symbol Integer) Integer))
  (define (sum-hash h) (for/sum : Integer ([(k v) (in-hash h)]) v))
  (module+ inside                                    ; typed code calling typed code: no contract
    (provide run)
    (: run (-> Integer Integer))
    (define (run n) (for/fold ([acc : Integer 0]) ([i (in-range n)]) (add1* acc)))))
(require 'typed (submod 'typed inside))
(define-syntax-rule (ms e) (let ([t0 (current-inexact-milliseconds)]) e (round (- (current-inexact-milliseconds) t0))))
(define N 2000000)
(define big (for/list ([i 10000]) i))
(define table (for/hasheq ([i 1000]) (values (string->symbol (format "k~a" i)) i)))
(printf "untyped caller, typed add1*, 2e6 calls: ~a ms ; typed caller: ~a ms\n" (ms (for/fold ([a 0]) ([i (in-range N)]) (add1* a))) (ms (run N)))
(printf "(Listof Integer) of 10000 checked on each of 500 calls: ~a ms\n" (ms (for ([i 500]) (sum-list big))))
(printf "untyped callback called 2e6 times from typed code: ~a ms\n" (ms (apply-callback add1 N)))
(printf "(HashTable Symbol Integer) of 1000 entries, 2000 calls: ~a ms\n" (ms (for ([i 2000]) (sum-hash table))))
(printf "boundary error: ~a\n" (with-handlers ([exn:fail:contract? (lambda (e) (car (regexp-split #rx"\n" (exn-message e))))]) (add1* "x")))
```

**Observed:**

```text
untyped caller, typed add1*, 2e6 calls: 52.0 ms ; typed caller: 3.0 ms
(Listof Integer) of 10000 checked on each of 500 calls: 36.0 ms
untyped callback called 2e6 times from typed code: 69.0 ms
(HashTable Symbol Integer) of 1000 entries, 2000 calls: 272.0 ms
boundary error: add1*: contract violation
```

Also observed: compiling this small typed module and its client took about 2.5 s; loading a compiled typed module in a fresh process took 335 ms against 127 ms for the untyped equivalent; a typed closure returned to untyped code is wrapped, at about 5 ns per call; a mutable hash crossing the boundary is wrapped so every later access is checked.

**What this means for the port.** Every value crossing from untyped to typed code is checked by a generated contract: cheap for flat types, linear in size for lists and hashes on every crossing, and a wrapper for functions and mutable containers. Services are provided and replaced at run time by untyped plugin code, so a typed kernel would pay at every service call. Typed Racket fits self-contained leaf libraries with plain-data interfaces (the `yaml` package is one); it does not fit the kernel or the plugin interface.

### YAML

```racket
#lang racket/base
;; Needs the yaml package (pure Racket, MIT; a PyYAML port, so YAML 1.1 by default).
(require yaml yaml/composer yaml/nodes yaml/serializer racket/port racket/class racket/match)
(define text "- insert:\n    - id: timer\n      name: '@deepseek-ai/cordis-plugin-timer'\n      disabled: !!js \"!ctx.get('profileContext')\"\n      config: {root: [], on: yes, n: 010, f: 1.50, z: null}\n")
;; default construction: unordered mutable hashes, YAML 1.1 scalars, unknown tag is an error
(printf "default: ~a\n" (with-handlers ([exn:fail? (lambda (e) (car (regexp-split #rx"\n" (exn-message e))))]) (string->yaml text)))
(printf "YAML 1.1 scalars: ~s\n" (for/list ([(k v) (in-hash (string->yaml "a: yes\nb: 010\nc: 2001-12-14\nd: 1:30\n"))]) (cons k (if (date? v) 'date-struct v))))
;; own construction over the composer's node graph: source order kept, quoted scalars stay strings,
;; plain scalars resolved by a JSON-like rule, the !!js tag becomes a struct
(struct omap (pairs) #:transparent)
(struct js-expr (source) #:transparent)
(define (plain-scalar s)
  (cond [(member s '("null" "~" "")) 'null] [(equal? s "true") #t] [(equal? s "false") #f]
        [(regexp-match? #px"^-?(0|[1-9][0-9]*)$" s) (string->number s)]
        [(regexp-match? #px"^-?(0|[1-9][0-9]*)(\\.[0-9]*)?([eE][-+]?[0-9]+)?$" s) (exact->inexact (string->number s))]
        [else s]))
(define (node->value n)
  (match n
    [(scalar-node _ _ "tag:yaml.org,2002:js" value _) (js-expr value)]
    [(scalar-node _ _ _ value style) (if style value (plain-scalar value))]            ; style #f means a plain scalar
    [(sequence-node _ _ _ items _) (map node->value items)]
    [(mapping-node _ _ _ pairs _) (omap (for/list ([p (in-list pairs)]) (cons (scalar-node-value (car p)) (node->value (cdr p)))))]))
(define (string->ordered s) (node->value (with-input-from-string s (lambda () (compose (current-input-port))))))
(define parsed (string->ordered text))
(printf "ordered: ~s\n" parsed)
;; writing: build nodes to control order and tags, then serialize
(define (value->node v)
  (define (str s [style #f]) (scalar-node #f #f "tag:yaml.org,2002:str" s style))
  (match v
    [(omap pairs) (mapping-node #f #f "tag:yaml.org,2002:map" (for/list ([p (in-list pairs)]) (cons (str (car p)) (value->node (cdr p)))) #f)]
    [(js-expr source) (scalar-node #f #f "tag:yaml.org,2002:js" source #\")]
    [(? list?) (sequence-node #f #f "tag:yaml.org,2002:seq" (map value->node v) #f)]
    [(? string?) (str v (and (not (string? (plain-scalar v))) #\'))]                    ; quote strings that would resolve to another type
    ['null (scalar-node #f #f "tag:yaml.org,2002:null" "null" #f)]
    [(? boolean?) (scalar-node #f #f "tag:yaml.org,2002:bool" (if v "true" "false") #f)]
    [(? exact-integer?) (scalar-node #f #f "tag:yaml.org,2002:int" (number->string v) #f)]
    [(? real?) (scalar-node #f #f "tag:yaml.org,2002:float" (number->string v) #f)]))
(define serializer (new serializer% [out (current-output-port)] [indent 2] [width 80]))
(send serializer open) (send serializer serialize (value->node parsed)) (send serializer close)
```

**Observed:**

```text
default: string:3:16: could not determine a constructor for the tag tag:yaml.org,2002:js
YAML 1.1 scalars: (("c" . date-struct) ("a" . #t) ("d" . 90) ("b" . 8))
ordered: (#(struct:omap (("insert" #(struct:omap (("id" . "timer") ("name" . "@deepseek-ai/cordis-plugin-timer") ("disabled" . #(struct:js-expr "!ctx.get('profileContext')")) ("config" . #(struct:omap (("root") ("on" . "yes") ("n" . "010") ("f" . 1.5) ("z" . null))))))))))
- insert:
  - id: timer
    name: '@deepseek-ai/cordis-plugin-timer'
    disabled: !!js "!ctx.get('profileContext')"
    config:
      root: []
      'on': 'yes'
      n: '010'
      f: 1.5
      z: null
```

Also observed: the default constructor follows YAML 1.1 as PyYAML does (`yes`/`no`/`on`/`off` are booleans, `010` is 8, `1:30` is 90, dates become `date*` structs, merge keys `<<` are applied, anchors and aliases share structure, the last duplicate key wins); `(yaml-constructors)` accepts `(yaml-constructor pred tag proc)` for a custom tag such as `tag:yaml.org,2002:js`; composer nodes carry start marks with line and column for error messages; parsing the real `packages/bundle/base/cordis.patch.yml` (21 KB, one `insert` patch with 99 rows) through the node walk took 118 ms, `web-app/cordis.patch.yml` (24 KB, 26 patches) 87 ms, `headless/cordis.patch.yml` 8 ms; loading the library adds about 400 ms of start-up.

**What this means for the port.** The package's scanner, parser and composer can be reused; the constructor and the scalar resolution must be the port's own, written to match the `js-yaml` JSON schema plus `!!js` that dsh uses (the snippet's `plain-scalar` is a simplification: the exact `null`, boolean, integer and float patterns of js-yaml 4 must be taken from its source, which is not on this machine). Mapping order is preserved by walking nodes into an ordered map. Output with controlled order and tags works by building nodes and calling `serializer%`. Parse time is a visible part of command-line start-up, so parsed configuration is worth caching by file content hash.

### SQLite and other library checks

```racket
#lang racket/base
(require db racket/file)
(define path (make-temporary-file "probe~a.sqlite"))
(define c (sqlite3-connect #:database path #:mode 'create))
(printf "sqlite ~a ; journal_mode ~a\n" (query-value c "select sqlite_version()") (query-value c "pragma journal_mode = wal"))
(query-exec c "pragma user_version = 7")
(query-exec c "create table events (session text not null, seq integer not null, payload text not null, primary key (session, seq)) without rowid")
(define t0 (current-inexact-milliseconds))
(call-with-transaction c (lambda () (for ([i 10000]) (query-exec c "insert into events values (?, ?, ?)" "s1" i "{\"type\":\"message\"}"))))
(printf "10000 inserts in one transaction: ~a ms\n" (round (- (current-inexact-milliseconds) t0)))
(define reader (sqlite3-connect #:database path #:mode 'read-only))
(printf "second connection: count ~a, user_version ~a, json_extract ~a\n" (query-value reader "select count(*) from events") (query-value reader "pragma user_version")
        (query-value reader "select json_extract(payload, '$.type') from events where seq = 0"))
(printf "row values: ~s ; null is ~s\n" (query-row c "select 1, 1.5, x'00ff', 'text'") (query-value c "select null"))
(printf "constraint violation: ~a\n" (with-handlers ([exn:fail:sql? (lambda (e) (exn:fail:sql-sqlstate e))]) (query-exec c "insert into events values ('s1', 1, 'dup')")))
(define writer2 (sqlite3-connect #:database path #:busy-retry-limit 2 #:busy-retry-delay 0.05))
(start-transaction c) (query-exec c "insert into events values ('s2', 1, 'x')")
(printf "second writer while a write transaction is open: ~a\n" (with-handlers ([exn:fail? (lambda (e) (car (regexp-split #rx"\n" (exn-message e))))]) (query-exec writer2 "insert into events values ('s3', 1, 'x')")))
(rollback-transaction c)
(for-each disconnect (list c reader writer2))
(for ([suffix '("" "-wal" "-shm")]) (define f (string-append (path->string path) suffix)) (when (file-exists? f) (delete-file f)))
```

**Observed:**

```text
sqlite 3.45.1 ; journal_mode wal
10000 inserts in one transaction: 82.0 ms
second connection: count 10000, user_version 7, json_extract message
row values: #(1 1.5 #"\0\377" "text") ; null is #<sql-null>
constraint violation: constraint
second writer while a write transaction is open: query-exec: the database file is locked
```

Also observed for `db`: nested `call-with-transaction` uses savepoints; one connection can be used from several threads (the library serializes access); `in-query` with `#:fetch` streams rows; `prepare` gives prepared statements.

Smaller checks, each observed:

- **Hashing and ids.** `sha1-bytes`, `sha224-bytes` and `sha256-bytes` are built in and accept bytes or an input port. There is no HMAC function without a package; RFC 2104 in 8 lines over `sha256-bytes` gave the published test vector `f7bc83f4...2d1a3cd8`. `crypto-random-bytes` from `racket/random` is enough for UUID v4. `base64-encode` appends `\r\n` unless its second argument is `#""`.
- **Compression.** `file/gzip` and `file/gunzip` round-trip through ports (`gzip-through-ports`, `gunzip-through-ports`).
- **Globs.** `file/glob` differs from the JavaScript glob libraries: `**/*.rkt` did not match a file in the starting directory (it matched only files in subdirectories), `sub/**` lists directories as well as files, dotfiles need `#:capture-dotfiles? #t`. `glob-match?` tests a path string without touching the file system. A tool that must match dsh's glob semantics needs its own matcher.
- **Regular expressions.** `#px` patterns support lookahead, lookbehind, non-greedy quantifiers, backreferences, `\p{..}` classes and inline `(?i:` and `(?m:` modes. Named groups `(?<name>...)` are a syntax error. There is no sticky or global flag; `regexp-match-positions*` returns all matches.
- **Strings.** `string-length` counts code points; JavaScript's `.length` counts UTF-16 units (a three-character string with one astral character has length 3 here and 4 in JavaScript). Any dsh limit expressed in JavaScript string length needs a UTF-16 count. `bytes->string/utf-8` raises on invalid input unless given a replacement character.
- **Files.** `call-with-atomic-output-file` writes through a temporary file and renames; `#:exists 'append` appends; `port-try-file-lock?` gives advisory locks (a second port in the same process is refused); there is no `fsync` in the library, but `(fsync (unsafe-port->file-descriptor out))` through the FFI returned 0; `file-or-directory-modify-seconds` has 1-second resolution, `(file-or-directory-stat f)` has nanoseconds.
- **Ordered maps.** Racket has no insertion-ordered hash. The loader's entry model and every JSON object that must keep its order need an explicit ordered-map type.
- **Command line.** `racket/cmdline`'s `command-line` handles `--profile name`, repeated `--patch file` and positional arguments, and rejects unknown switches with a message.
- **Futures.** Four `fib 30` futures took 15 ms against 23 ms sequentially; futures help only pure numeric code and block on most primitives.

### Effect scope sketch

The shape of `ctx.effect` in plain Racket, to show that the kernel's effect bookkeeping needs only closures and a list.

```racket
#lang racket/base
;; The shape of ctx.effect: a callback returns its inverse (or a list, or a generator of inverses);
;; the scope keeps them last-in first-out; a failed installation reverts what it had installed.
(require racket/generator)
(struct scope ([inverses #:mutable]))
(define (scope-dispose! s)                       ; runs every inverse even if one raises; returns the error messages
  (let loop ([errors '()])
    (cond [(null? (scope-inverses s)) errors]
          [else (define inverse (car (scope-inverses s)))
                (set-scope-inverses! s (cdr (scope-inverses s)))    ; pop before running: an inverse may add effects
                (define result (with-handlers ([exn:fail? (lambda (e) (list (exn-message e)))]) (inverse)))
                (loop (if (list? result) (append errors result) errors))])))
(define (scope-effect! s thunk)
  (define local (scope '()))
  (define (collect v)
    (cond [(generator? v)
           (let loop ()
             (define vals (call-with-values v list))               ; zero values when the body ends in (yield ...)
             (for-each collect vals)
             (unless (eq? (generator-state v) 'done) (loop)))]
          [(list? v) (for-each collect v)]
          [(procedure? v) (set-scope-inverses! local (cons v (scope-inverses local)))]
          [else (void)]))
  (with-handlers ([exn:fail? (lambda (e) (scope-dispose! local) (raise e))])
    (collect (thunk)))
  (define disposed? #f)
  (define (dispose) (if disposed? '() (begin (set! disposed? #t) (scope-dispose! local))))   ; single-shot, safe to call early
  (set-scope-inverses! s (cons dispose (scope-inverses s)))
  dispose)
(define trace '())
(define (note x) (set! trace (cons x trace)))
(define (install name) (note (list '+ name)) (lambda () (note (list '- name))))
(define s (scope '()))
(void (scope-effect! s (lambda () (install 'a))))
(define early (scope-effect! s (lambda () (generator () (yield (install 'b1)) (yield (install 'b2))))))
(void (scope-effect! s (lambda () (list (install 'c1) (install 'c2)))))
(printf "failed effect: ~a\n" (with-handlers ([exn:fail? exn-message]) (scope-effect! s (lambda () (generator () (yield (install 'd1)) (error "d2 failed"))))))
(void (early) (early))                           ; early, out of order, twice
(void (scope-effect! s (lambda () (lambda () (error "inverse of e failed")))))
(printf "errors collected at dispose: ~a\n" (scope-dispose! s))
(printf "~a\n" (reverse trace))
```

**Observed:**

```text
failed effect: d2 failed
errors collected at dispose: (inverse of e failed)
((+ a) (+ b1) (+ b2) (+ c1) (+ c2) (+ d1) (- d1) (- b2) (- b1) (- c2) (- c1) (- a))
```

The trace shows: a failed installation reverted its own partial work (`d1`) and left earlier effects in place; the early disposer ran its inverses last-in first-out and was inert the second time; the scope then reverted the rest in reverse order of installation; an inverse that raised did not stop the others and its error was collected.

## The Stone library

**What the brief refers to.** There is a Racket package named `Stone` in the main catalog, and it is an agent harness. Confidence that this is the library the brief means: high. It is the only package of that name on pkgs.racket-lang.org, its catalog tags are `agentic-harness` and `llm`, and its subject is the same as this project's. The brief gives no link, so this is an identification by search, not by citation. Note the capital letter: `raco pkg catalog-show Stone` finds it and `raco pkg catalog-show stone` does not.

**Identity (from the catalog entry and the cloned source).**

| Field | Value |
|---|---|
| Catalog name | `Stone` |
| Description | "An elegant agentic harness for a more civilized age" |
| `info.rkt` | version `"0.3"`, `pkg-desc` "A DAG-based orchestration toolkit for building LLM agent harnesses.", author Aldric Giacomoni, license MIT |
| Source | `https://codeberg.org/Trevoke/stone.git#congruence`, checksum `27e013131d27ad8233b63de70c54cf5bf12ee889` (commit dated 2026-08-07) |
| Dependencies | `base`, `http-easy`, `rackunit-lib`, `tui-term`, `tui-ubuf`; build: `scribble-lib`, `racket-doc`, `rackunit-doc`, `web-server-lib` |
| Documentation | `https://docs.racket-lang.org/stone/` (Why Stone, Reading Racket, Tutorials, How-to guides, Reference, Explanation, Upgrading) |
| Size | about 30,600 lines of Racket including tests; largest modules `edge.rkt` 1,271, `llm-ashlar.rkt` 975, `mason.rkt` 694, `llm-client.rkt` 571, `tools.rkt` 527, `journal.rkt` 445, `dag.rkt` 405 |
| CI | Forgejo workflow on the `racket/racket:9.1-full` image, `raco pkg install --auto --batch --name stone`, `raco setup --check-pkg-deps stone`, then `bin/test` |

How it was studied: the documentation pages were read through a summarizing fetch tool, and the repository was cloned read-only into a scratch directory and read. It was not installed or run (`tui-term` and `tui-ubuf` are not on this machine).

**What Stone is.** Its unit is the *ashlar*: a struct (`ashlar-meta`) that is callable and maps a DAG to a DAG. Ashlars compose with `~>` (sequence, stopping at the first failure), `ashlar-loop`, `ashlar-match`, `ashlar-map`, `ashlar-parallel`, `ashlar-reduce` and `make-ask-human`. The shared state is a typed, append-only DAG whose node ids are SHA-1 digests of canonical JSON. `make-agent-ashlar` runs a multi-turn tool loop. Around that sit an OpenAI-compatible client with token streaming and an Anthropic client (`stone/llm-client`), built-in file and command tools with path scoping (`stone/tools`), a per-run channel to the outside called the threshold (`stone/threshold`), an append-only JSONL journal for durable, resumable runs (`stone/journal`, `stone/record`), static validation of a composed topology (`stone/validate`), a terminal UI and a trace CLI (`raco stone`), and test utilities (`stone/test`).

**What Stone is not.** It has no plugin system, no service container or dependency injection, no loading or unloading of components while running, no tracking or reversal of registrations, and no configuration-file composition. The grep of its non-test sources found no use of custodians, `racket/sandbox`, security guards, breaks for cancellation, places, units or Typed Racket. That matches the brief's sentence: Stone is a source of Racket techniques for the harness layer, and Cordis is the composition pattern.

**Techniques in Stone that bear on this port** (paths are inside the Stone repository):

1. *Streaming chat completion loop* (`stone/llm-client.rkt`, lines 200 to 335; `stone/streaming.rkt`). It posts with `http-easy` and `#:stream? #t`, reads `data: ` lines with `(read-line in 'any)`, stops at `data: [DONE]`, and accumulates three streams from each chunk's `choices[0].delta`: `reasoning` or `reasoning_content`, `content`, and `tool_calls` deltas keyed by `index` (id and name taken when present, `arguments` fragments concatenated, JSON-parsed at the end with an empty object as fallback). A non-2xx status is raised as `exn:fail:llm-http-error` carrying the status and body, because otherwise a rejected request looks like an empty stream. Timeouts: `(make-timeout-config #:lease 5 #:connect 10 #:request 400)`.
2. *The same HTTP cancellation trouble found here.* Comments in that loop record that `http-easy` registers a will on a streaming response that closes it when the response object becomes unreachable (which fired mid-stream once the compiler stopped keeping the variable alive), and that `response-close!` on an active stream races with the chunk-copying thread and raises `input port is closed`. `stone/tests/test-repro-port-closed.rkt` is a raw TCP server written to reproduce exactly the `http-pipe-chunk` error that the probe in [HTTP client streaming and web-server](#http-client-streaming-and-web-server) produced. Two independent observations of one problem support owning the socket.
3. *Cooperative cancellation* (`stone/threshold.rkt`). A cancel request sets a box; `threshold-check-cancel!` is polled between stream chunks and raises a plain struct `run-cancelled` (not an `exn`), so `exn:fail?` handlers along the way cannot swallow it and `dynamic-wind` post thunks still run. Human input is modelled the same way: `threshold-suspend!` raises `run-suspended`, the run ends, and the answer re-enters later as a DAG node, with no blocking rendezvous.
4. *Observation feed.* Each subscriber gets a bounded `async-channel` (`OBSERVATION-CAPACITY` 10000); emit is `(sync/timeout 0 (async-channel-put-evt ch c))`, which drops instead of blocking the run.
5. *Middleware chain* (`run-onion` in `stone/core.rkt`, lines 98 to 112): a list of structs with a `guard` and a `handler` that receives the context and the inner procedure. It is the closure form of the waterfall shown above.
6. *Journal* (`stone/journal.rkt`, `stone/canonical.rkt`): one canonical JSON object per line with a `"fact"` discriminator, written synchronously, replayed to rebuild a run; structs declare their canonical form through a struct type property (`prop:canonicalize`).
7. *Run-scoped ambient state as parameters*: `current-threshold`, `current-journal`, `current-test-call-llm`, trace and span ids. One test passes a mode to a server thread through a box, with the comment "parameters don't cross threads".
8. *Mocking the model* (`stone/test.rkt`): `current-test-call-llm` replaces the client; helpers build scripted replies (`llm-text`, `llm-tool-call`, `llm-multi`) and assert on tool calls. A `web-server`-based mock server exists for client tests, with empty `test` submodules in helper files so that `raco test` does not start it.
9. *Command tools* (`stone/tools.rkt`, lines 377 to 516): `/bin/sh -c`, a thread that calls `subprocess-wait` and signals a channel, `sync/timeout`, then `subprocess-kill proc #t`. No process group and no custodian, so a grandchild can outlive the timeout; [Subprocess management](#subprocess-management) shows the stronger recipe.
10. *Test discipline* (`bin/test`, and "Mechanical hazards" in its `CLAUDE.md`): never a bare `raco test`; point `PLTCOLLECTS` at the checkout so a linked package from another worktree is not what gets tested; `raco make` everything first because stale bytecode masks changes; do not pass `-x`, which made their CI run zero tests and exit 0; treat any output on the error port as a failure because the catalog's build runs `raco test --drdr`; assert that every test file was visited and that the test count did not drop. Three of these (stale bytecode, `-x`, error-port output) were reproduced here in [raco test conventions](#raco-test-conventions).

**cordispy (prior art for porting Cordis to another language).** PyPI has `cordispy`: version 0.1.0 released 2026-08-20 (0.0.1 on 2026-08-15), author `s2005`, MIT, source `github.com/s2005/cordispy`, Python 3.11 or later, built on `asyncio`, one runtime dependency (`pyyaml`). Its page calls it a Python realization of the runtime described in the same paper and names the TypeScript Cordis as the reference implementation. It warns that the PyPI name `cordis` is an unrelated placeholder. It was read through the PyPI page and two documentation files in its repository, fetched with a summarizing tool; the repository was not cloned, so the following is second-hand.

- API surface named on the page: `root.use(component)`, `ctx.set`, `ctx.get`, `ctx.key`, `ctx.optional`, `ctx.effect(callback)`, `fiber.dispose()`, `provider.retire()`, `root.registry.settle()`, `Loader`, `Entry`, a keyed group component, `Hmr`, a built-in `bus` service. Fiber states `PENDING`, `ACTIVE`, `INACTIVE`. It reports 139 passing tests.
- Its stated limitations (`docs/limitations.md`), the ones relevant here: (1) no receiver rebinding for service methods; components pass their context explicitly, for example `timer.interval(ctx, 60.0, callback)`. This is the same decision as the explicit context argument in [cordis-analysis.md](../cordis-analysis.md) section 4.1. (2) Hot reload evicts modules from `sys.modules`, but old module objects survive through direct references. (3) The loader is one-directional (no write-back from a running component to its entry). (4) File changes are found by polling. (6) Inverses are not verified. (7) It adds optional injections. (8) Cycle detection is diagnostic only. (9) It does not implement `waterfall` or `bail` event middleware, the schema DSL, or the logger. (10) "No thread or executor safety": the runtime relies on run-to-completion between `await` points and mutates fiber state without locks, and warns against moving runtime code onto threads. That is the hazard the baton design addresses in Racket.
- Its source review (`docs/source-review.md`) of `cordiverse/cordis` `packages/core` v4.0.0-rc.8 (HEAD `8cc9e33`) lists seven defects: an aborted generator effect is not closed (`fiber.ts:263`); the disposer array is emptied before its items run, so one throwing inverse loses the rest (`fiber.ts:281`); `fiber.error` is not cleared on recovery (`fiber.ts:482`); fiber teardown awaits its disposers concurrently through `Promise.all` instead of in sequence (`fiber.ts:438`); `ctx.set` on an existing binding mutates in place without notifying (`reflect.ts:162`); a sequence-number closure bug in the utility list's `push` (`packages/utils/src/index.ts:19`); and `notify` sweeps the whole registry once per changed key (`reflect.ts:205`). Those line numbers are for rc.8. The vendored kernel here is rc.11 with local modifications, so each item must be checked against [01-cordis-core.md](01-cordis-core.md) before it is treated as current; one is visibly still present (`vendor/cordis/src/fiber.ts:720` awaits `Promise.all` over the cleared disposables). The Racket kernel must reproduce the vendored behavior; these seven are candidates for explicit test cases and for decisions recorded in ADRs.

**Other Racket packages that touch the subject** (catalog entries only, not studied): `effect-racket` (effect handlers as a library and a language), `effection` (experimental library for custom side effects), `koyo` (web toolkit), `deta` and `north` (database mapper and migrations), `gregor` (dates and time zones), `rackcheck` (property-based testing). None is a plugin-composition kernel.

## Recommendations

### Mechanism for each Cordis concept

| Cordis concept | Mechanism | Evidence | Trade-off or limit |
|---|---|---|---|
| Context and derived contexts (`isolate`, `intercept`) | Immutable struct with persistent hashes, passed explicitly | `hash-set` on a 100-entry `hasheq` costs 0.08 microseconds | Callers must pass the context; no ambient ownership |
| "Who is running" for diagnostics | A parameter plus a continuation mark | Marks reach `exn-continuation-marks` and can be read from another thread | Neither is captured by a stored closure; never use them to decide ownership |
| Revertible effect and its inverse | A closure returned by the effect callback, kept in a LIFO list per fiber | [Effect scope sketch](#effect-scope-sketch) | The author must supply the inverse; nothing checks it |
| Effect iterator | `racket/generator`, driven with `call-with-values` | Generator section | Body keeps the parameterization of its first resume; unusable after an exception; `dynamic-wind` thunks rerun at each suspension |
| Disposer | Struct with `prop:procedure`, `prop:evt` and a custom printer | Generics section | none |
| Reclaiming what a plugin forgot | One custodian per fiber, child of the parent fiber's | Custodian section; 1.4 microseconds to create | No ordering, no unwinding of killed threads, nothing for plain data, pipes are unmanaged, a fresh custodian is needed after each shutdown |
| Unload sequence | Run inverses in LIFO order on a kernel thread that is outside the fiber's custodian, then shut the custodian down | A thread that shuts down its own custodian dies at that call | The kernel thread must not block forever on a plugin's inverse; give inverses a time limit |
| Service store, `provide`/`get`/`inject` | Mutable hash on the root; checked read; `define-plugin` binding injected services lexically | syntax-parse section | Compile-time checks cover only plugins written with the macro; string-keyed access stays for configuration-driven code |
| Service Definition with several providers | `define-generics` | 20 to 30 nanoseconds per call | Method set is fixed per interface |
| Service contract | `contract-out` at the defining module; check provided values once | Contract section | Do not put contracts on accessors of procedure fields used in hot paths (1.4 microseconds per access) |
| Events: `emit`, `parallel`, `serial`, `bail` | Listener lists and plain loops | none needed | `parallel` under the baton model is "start all, await all"; real parallelism is not available to harness code |
| Events: `waterfall` | Closure chain with a called-twice flag | Waterfall snippet | none |
| Event declarations | `define-event` with a compile-time record | syntax-parse section | Dynamic names still need the string-keyed API |
| Fiber lifecycle and asynchrony | Cooperative tasks on threads with a baton; `await` on any event | [Cooperative baton](#cooperative-baton); 5 to 8 microseconds per hand-over | Blocking work must leave the baton; every library call that can block is a hidden await unless wrapped |
| Cancellation | Break delivered at `await` only (breaks disabled elsewhere), then custodian shutdown after a grace period | Breaks section, turn section | The second stage runs no cleanup in the victim; state it shared must be owned by a manager thread or repaired by the kernel |
| Timeouts and races | `sync` over `choice-evt` with `alarm-evt` | Turn section | none |
| Plugin as data | Struct with a metadata property, or a module in `#lang cordis/plugin` with a `plugin-info` submodule | Module language section | Three macro traps listed there |
| Loading plugin code | `dynamic-require` in a namespace that has the kernel attached; compilation manager for caching | Reload section | Create the compilation-manager handler after selecting the namespace |
| Hot reload | Dispose the old fiber, then reload (`racket/rerequire`), then mount; or one namespace per generation | Reload section | In-place reload overwrites module-level state that old closures share; a changed kernel file changes struct identity |
| File watching | `filesystem-change-evt`, re-armed after each firing | Reload section | One-shot; 1-second timestamps in `rerequire`'s change test |
| Model-written or third-party Racket plugins | `racket/sandbox` evaluator with the kernel shared through `sandbox-namespace-specs` | Sandbox section | Same-process confinement of Racket code only; total memory limit kills the evaluator |
| Tool processes | `subprocess` with group, `'kill` custodian mode, per-call custodian | Subprocess section | Session-changing children escape; OS-level confinement needs external tools |
| Persistent terminals | FFI `openpty` + `setsid -w -c` + `killpg` | PTY snippet | Linux constants; teardown is manual |
| Logger service | `define-logger`, receivers, a forwarding thread | Logging section | Root logger prints `error` to the error port; keep test output clean |
| Configuration files | `yaml` package's composer plus the port's own constructor and emitter over an ordered map | YAML section | 400 ms load, about 100 ms per 20 KB file; exact js-yaml scalar rules still to be ported |
| Session and wire JSON | Ordered-object representation with the ECMAScript-compatible writer | JSON section | The stock `jsexpr` form loses order and prints numbers differently |
| Durable store | `db` with SQLite, WAL, `user_version` | SQLite snippet | A second writer fails fast with `database file is locked`; one writer connection per file |
| Model HTTP | Own HTTP/1.1 client on `tcp-connect`/`ssl-connect` with a secure context, one custodian per request | HTTP section | More code than `http-easy`, but it is the only variant that cancelled cleanly |
| Web and SDK server | `web-server` `serve` with `dispatch-rules`, `response/output` for SSE, `rfc6455` dispatcher for WebSocket | HTTP and WebSocket sections | Keep-alive handlers are killed without unwinding; `rfc6455` carries an LGPL-3.0 notice |
| Scheduling | One thread, a heap, `alarm-evt` | Time section | Named time zones need a package |
| Isolation of CPU-heavy pure work | Places | Places section | Plain data only; `place` inside `(module+ main ...)` starts places recursively |
| Static typing | Contracts at boundaries; Typed Racket only for leaf libraries | Typed section | Typed boundaries cost per crossing and add 200 ms of load time |
| Static wiring with signature checks | `racket/unit`, as an optional adapter | Units section | No withdrawal or replacement of an import |

### Where the findings change or sharpen the current design

These refer to [cordis-analysis.md](../cordis-analysis.md) as it stands.

1. **Section 4.8, hot reload.** The statement that old instances live as long as something references them is true for the namespace-per-generation recipe and false for `racket/rerequire`, which re-declares in place and resets module-level variables that old closures still read and write. Fix the order (dispose, reload, mount) or choose separate namespaces. `dynamic-rerequire` must also perform the first load, or it tracks nothing.
2. **Section 4.6, cancellation.** "A break delivered to the task's thread" is safe only if tasks run with breaks disabled and `await` is the single place that enables them (`sync/enable-break`), as in the baton sketch. With breaks enabled throughout, a break can land between two mutations of kernel state while the task holds the baton. Handlers of `with-handlers` already run with breaks disabled; `with-handlers*` does not.
3. **Section 4.3, custodian per fiber.** Confirmed as feasible and cheap, with four additions for the ADR: the unload must run on a thread outside the fiber's custodian; the custodian must be replaced after every shutdown; subprocesses are reclaimed only with `current-subprocess-custodian-mode 'kill` and `subprocess-group-enabled #t` set when plugin code runs (the kernel can parameterize both around plugin bodies); and shutdown callbacks registered through `ffi/unsafe/custodian` run in unspecified order in atomic mode, so they are not a place to run inverses.
4. **Section 4.6, blocking work.** `(blocking thunk)` covers known blocking calls. The risk is the unknown ones: any port read, `subprocess-wait`, `sleep` or `sync` in harness or plugin code blocks its thread while holding the baton and stalls every task. The kernel should offer baton-releasing wrappers for the common blocking operations and a watchdog that reports a holder that has not released for some configured time.
5. **Section 4.2, generators.** Keep them, and write the driver to the four behaviors listed under [Continuations, a waterfall chain, generators](#continuations-a-waterfall-chain-generators). If the kernel resumes an effect iterator from a task other than the one that started it, the body still sees the first task's parameterization, including `current-custodian`; set the parameters the kernel relies on inside the body's own wrapper.
6. **Section 4.4, contracts.** Check a service value against its contract when it is provided, and keep per-call contracts off the dispatch path. A contract on a struct accessor that returns a procedure re-wraps on every access.
7. **Section 4.5, parallel dispatch.** Under one baton, "parallel" listeners interleave only at awaits. This matches JavaScript and should be stated, because a Racket reader will otherwise expect preemptive parallelism.
8. **Durable formats (not in the analysis yet).** The JSON conventions of the stock library are incompatible with byte-exact session logs: object order and number layout. The ordered representation and writer in [JSON](#json) should become a `util` module early, because session, snapshot and model-request code all depend on it. The same module should carry a UTF-16 length function for limits defined in JavaScript string units.
9. **Model HTTP (not in the analysis yet).** Do not build provider adapters on `net/http-client`'s convenience functions or `http-easy` streaming; both leave a cancelled request running. Always pass a secure TLS context.
10. **Server-sent events to the browser.** A handler cannot rely on an exception or a post thunk to release its subscription when a keep-alive client disconnects. Register the subscription as an effect on a context whose disposer is triggered by a watcher on the connection's custodian box.
11. **Process handling.** Always create subprocesses with a process group; without one, the exit of a child that changed its session is never reported to `sync`.

### What is essential and what is Racket machinery

Essential product behavior that the mechanisms must reproduce exactly: listener and disposer ordering, the waterfall `next` rules, the fiber state machine, configuration file dialect and patch semantics, session and wire JSON bytes, tool process lifecycle (timeouts, tree kill), cancellation outcomes visible in the session log.

Racket-specific additions that go beyond dsh and therefore need an ADR each when used: custodian backstop, per-fiber memory limits, compile-time checking of injections and event modes, the sandbox for Racket plugins, contracts with blame.

### What can only be wrapped

- **JavaScript expressions in configuration.** The `!!js` tag carries JavaScript source. The repository's YAML files contain 107 distinct expressions, for example `process.env.DSH_PERMISSION_MODE ?? 'workspace-write'`, `"!ctx.get('profileContext')"`, `process.cwd() + '/office-skills'`, `dshHomePath('sessions')`, and a few that call `process.getBuiltinModule(...)`. Racket has no JavaScript engine. The choices are an interpreter for the expression subset actually used (member access, calls on a fixed set of host objects, `??`, `?.`, `?:`, `===`, `!==`, `!`, `+`, literals, arrays; `parser-tools` and `megaparsack` are installed for the parser) with a Node sidecar as fallback for anything outside it. The loader recon owns the exact semantics.
- **Existing TypeScript plugins.** Running them needs Node; the plan's porter and sidecar cover this. A subprocess with a JSON-RPC pipe is the available isolation (places cannot run JavaScript, and nothing embeds V8).
- **Operating-system sandboxing of tool processes.** `racket/sandbox` does not confine child processes. This machine has `unshare` but not `bwrap`; macOS would need `sandbox-exec`. The Racket side can only construct the command line and manage the process.
- **Named time zones, Brotli, an HMAC or TLS feature beyond what `openssl` exposes.** Each needs a package or a small FFI binding (`libcrypto`, `libbrotli*` and `libzstd` are present).

### Test and build conventions to adopt

- One package per directory with `info.rkt`; tests in `(module+ test ...)` and in `tests/` files that also use a `test` submodule, so that `-x` and plain runs agree.
- A single gate script: private `PLTADDONDIR` or `PLTCOLLECTS`, `raco make` on all sources, `raco test --timeout <n>` without `-x`, fail on error-port output (`-e`), compare visited-file and test counts with a recorded floor.
- Never trust a test result obtained with stale `compiled/` directories; rebuild or pass `--make`.
- Mock servers on `127.0.0.1` port 0; live-API tests only when a key is in the environment.
- Leak tests with weak boxes after `(collect-garbage 'major)`; kill-safety tests that kill a task while it holds the baton; cancellation tests for all three outcomes (cooperative, forced, already finished).
- Keep `racket/base` as the language of run-time modules and require `syntax/parse`, `racket/class`, `web-server`, `yaml` and `db` only where used (with `racket/lazy-require` for optional features), because each adds 150 to 500 ms to command-line start-up.

### Open items this recon did not settle

- The exact plain-scalar resolution of js-yaml 4's JSON schema (source not on this machine).
- `racket/sandbox` and custodian memory limits under real plugin workloads (only allocation loops were tried).
- PTY and `filesystem-change-evt` behavior on macOS and Windows (Linux only here).
- Whether `rfc6455`'s license is acceptable for vendoring.
- Stone and cordispy were read, not run; cordispy only through summaries of its PyPI page and two documentation files.
