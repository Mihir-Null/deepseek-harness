#lang racket/base
;; Tests for dsh-util/crypto. Mirrors packages/util/crypto/tests/uuid.spec.ts; the digest and
;; HMAC expectations are the published SHA and RFC 4231 test vectors.

(require rackunit
         racket/list
         dsh-util/crypto)

(define v4-shape #px"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

(test-case "emits RFC 9562 v4 ids"
  (for ([_ (in-range 64)])
    (define id (random-uuid))
    (check-regexp-match v4-shape id)
    (check-pred uuid-string? id)))

(test-case "emits distinct ids across calls"
  (check-equal? (length (remove-duplicates (for/list ([_ (in-range 64)]) (random-uuid)))) 64))

(test-case "uuid-string? accepts only the lowercase 8-4-4-4-12 form"
  (check-true (uuid-string? "123e4567-e89b-12d3-a456-426614174000"))
  (check-false (uuid-string? "123E4567-E89B-12D3-A456-426614174000"))
  (check-false (uuid-string? "123e4567e89b12d3a456426614174000"))
  (check-false (uuid-string? 5)))

(test-case "encodes empty, binary and multi-chunk byte strings as base64"
  (check-equal? (bytes->base64 #"") "")
  (check-equal? (bytes->base64 (bytes 0 127 128 255)) "AH+A/w==")
  (check-equal? (bytes->base64 (make-bytes #x8001 65))
                (apply string-append (for/list ([_ (in-range 10923)]) "QUFB")))
  (check-equal? (bytes->base64url (bytes 0 127 128 255)) "AH-A_w")
  (check-equal? (base64->bytes "AH+A/w==") (bytes 0 127 128 255))
  (check-equal? (base64->bytes "AH-A_w") (bytes 0 127 128 255)))

(test-case "digests"
  (check-equal? (sha256-hex "abc")
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  (check-equal? (sha256-hex #"") "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  (check-equal? (bytes-length (sha256 "abc")) 32)
  (check-equal? (sha1-hex "abc") "a9993e364706816aba3e25717850c26c9cd0d89d"))

(test-case "HMAC-SHA256 matches RFC 4231"
  (check-equal? (hmac-sha256-hex (make-bytes 20 #x0b) "Hi There")
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
  (check-equal? (hmac-sha256-hex "Jefe" "what do ya want for nothing?")
                "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  ;; a key longer than the block size is hashed first (test case 6)
  (check-equal? (hmac-sha256-hex (make-bytes 131 #xaa)
                                 "Test Using Larger Than Block-Size Key - Hash Key First")
                "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"))

(test-case "random bytes and constant-time comparison"
  (check-equal? (bytes-length (random-bytes 6)) 6)
  (check-regexp-match #px"^[0-9a-f]{12}$" (random-hex 6))
  (check-true (timing-safe-equal? #"abc" #"abc"))
  (check-false (timing-safe-equal? #"abc" #"abd"))
  (check-false (timing-safe-equal? #"abc" #"abcd")))
