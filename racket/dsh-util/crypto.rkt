#lang racket/base
;; dsh-util/crypto: UUID minting and base64 from dsh util/crypto, plus the digest, HMAC and
;; random-id primitives that dsh takes from node:crypto.
;;
;; source: packages/util/crypto/src/index.ts (randomUUID, bytesToBase64)
;;
;; Random bytes come from the operating system's generator (racket/random). Digests use
;; file/sha1, which is part of the base distribution; nothing here needs OpenSSL.

(require racket/contract/base
         racket/random
         file/sha1
         "private/js.rkt")

(provide (contract-out
          [random-uuid (-> uuid-string?)]
          [uuid-string? (-> any/c boolean?)]
          [bytes->base64 (-> bytes? string?)]
          [bytes->base64url (-> bytes? string?)]
          [base64->bytes (-> string? bytes?)]
          [random-bytes (-> exact-nonnegative-integer? bytes?)]
          [random-hex (-> exact-nonnegative-integer? string?)]
          [sha256 (-> (or/c bytes? string?) bytes?)]
          [sha256-hex (-> (or/c bytes? string?) string?)]
          [sha1-hex (-> (or/c bytes? string?) string?)]
          [hmac-sha256 (-> (or/c bytes? string?) (or/c bytes? string?) bytes?)]
          [hmac-sha256-hex (-> (or/c bytes? string?) (or/c bytes? string?) string?)]
          [timing-safe-equal? (-> bytes? bytes? boolean?)]))

(define (->bytes v) (if (string? v) (string->bytes/utf-8 v) v))

(define (hex bs) (bytes->hex-string bs))

;; A random RFC 9562 version 4 UUID in lowercase: version 4 in the high nibble of byte 6 and
;; variant 10 in the top bits of byte 8.
(define (random-uuid)
  (define bs (bytes-copy (crypto-random-bytes 16)))
  (bytes-set! bs 6 (bitwise-ior (bitwise-and (bytes-ref bs 6) #x0f) #x40))
  (bytes-set! bs 8 (bitwise-ior (bitwise-and (bytes-ref bs 8) #x3f) #x80))
  (define h (hex bs))
  (string-append (substring h 0 8) "-" (substring h 8 12) "-" (substring h 12 16) "-"
                 (substring h 16 20) "-" (substring h 20)))

;; Whether v has the 8-4-4-4-12 lowercase hexadecimal form of a UUID (any version).
(define (uuid-string? v)
  (and (string? v)
       (regexp-match? #px"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" v)))

;; Canonical base64 with padding and no line breaks (dsh bytesToBase64).
(define (bytes->base64 bs) (bytes->base64-string bs))

;; Buffer.toString('base64url'): URL-safe alphabet, no padding.
(define (bytes->base64url bs)
  (define s (bytes->base64-string bs))
  (define trimmed (regexp-replace #rx"=+$" s ""))
  (list->string
   (for/list ([c (in-string trimmed)])
     (case c [(#\+) #\-] [(#\/) #\_] [else c]))))

;; Decodes standard or URL-safe base64, with or without padding.
(define (base64->bytes s)
  (base64-string->bytes
   (list->string
    (for/list ([c (in-string s)])
      (case c [(#\-) #\+] [(#\_) #\/] [else c])))))

;; n bytes from the operating system's random source (node randomBytes).
(define (random-bytes n) (crypto-random-bytes n))

;; 2n lowercase hexadecimal digits from n random bytes (randomBytes(n).toString('hex')).
(define (random-hex n) (hex (crypto-random-bytes n)))

;; SHA-256 of bytes, or of a string's UTF-8 encoding.
(define (sha256 data) (sha256-bytes (->bytes data)))
(define (sha256-hex data) (hex (sha256-bytes (->bytes data))))
(define (sha1-hex data) (hex (sha1-bytes (->bytes data))))

;; HMAC-SHA256 (RFC 2104), as createHmac('sha256', key).update(data).digest().
(define (hmac-sha256 key data)
  (define block-size 64)
  (define key-bytes
    (let ([k (->bytes key)])
      (if (> (bytes-length k) block-size) (sha256-bytes k) k)))
  (define padded (make-bytes block-size 0))
  (bytes-copy! padded 0 key-bytes)
  (define (xor-pad byte)
    (define out (make-bytes block-size))
    (for ([i (in-range block-size)])
      (bytes-set! out i (bitwise-xor (bytes-ref padded i) byte)))
    out)
  (sha256-bytes (bytes-append (xor-pad #x5c)
                              (sha256-bytes (bytes-append (xor-pad #x36) (->bytes data))))))

(define (hmac-sha256-hex key data) (hex (hmac-sha256 key data)))

;; Compares two byte strings in time that depends only on their lengths. Unlike node's
;; timingSafeEqual it returns #f for different lengths instead of raising.
(define (timing-safe-equal? a b)
  (and (= (bytes-length a) (bytes-length b))
       (zero? (for/fold ([acc 0]) ([x (in-bytes a)] [y (in-bytes b)])
                (bitwise-ior acc (bitwise-xor x y))))))
