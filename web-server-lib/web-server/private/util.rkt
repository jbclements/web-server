#lang racket/base
(require racket/contract/base
         racket/exn
         racket/list
         racket/serialize
         racket/tcp
         net/url-structs)
(provide list-prefix?
         port-number?
         listen-port-number?)

;; --

(define (byte-upcase b)
  (if (<= 97 b 122)
      (- b (- 97 65))
      b))
(define (bytes-ci=? b0 b1)
  (and (= (bytes-length b0)
          (bytes-length b1))
       (for/and ([b0 (in-bytes b0)]
                 [b1 (in-bytes b1)])
         (= (byte-upcase b0) (byte-upcase b1)))))
;; Eli: If this ever gets in, it should say that the memory requirements
;;   are 4 times the input size, especially since bytes are often used to save
;;   space.  Also, fails on (bytes-ci=? #"\277" #"\277"), and a trivial fix
;;   would still fail on (bytes-ci=? #"\276\277" #"\277\276")

(provide/contract
 [bytes-ci=? (bytes? bytes? . -> . boolean?)])

(module+ test
  (require rackunit)
  (check-true (bytes-ci=? #"FBCR/M\351ditel" #"fbCR/M\351ditel")))

;; --

(define path-piece?
  (or/c path-string? (symbols 'up 'same)))

(provide/contract
 [path-piece? predicate/c])

;; --

;; network-error: symbol string . values -> void
;; throws a formatted exn:fail:network
(define (network-error src fmt . args)
  (raise (make-exn:fail:network (format "~a: ~a" src (apply format fmt args))
                                (current-continuation-marks))))

(provide/contract
 [network-error (->* [symbol? string?] [] #:rest list? void?)]
 [exn->string (-> any/c string?)])

;; --

; explode-path* : path? -> (listof path?)
(define (explode-path* p)
  (let loop ([p p] [r null])
    (cond 
      [(eq? 'relative p) r]
      [(not p) r]
      [else
       (let-values ([(base name dir?) (split-path p)])
         (loop base (list* name r)))])))
;; Eli: We already have `explode-path', this looks like it's doing the
;;   same thing, except a little less useful.

; path-without-base : path? path? -> (listof path-piece?)
(define (path-without-base base path)
  (define b (explode-path* base))
  (define p (explode-path* path))
  (if (list-prefix? b p)
      (list-tail p (length b))
      (error 'path-without-base "~a is not a prefix of ~a" base path)))
;; Eli: see my comment on `list-prefix?' -- it would make this trivial.
;;   Also, if you want to look for a useful utility to add, search the code for
;;   `relativize', which is a popular thing that gets written multiple times
;;   and would be nice to have as a library.  (But there are some differences
;;   between them, I think.)

;; build-path-unless-absolute : path-string? path-string? -> path?
(define (build-path-unless-absolute base path)
  (if (absolute-path? path)
      (build-path path)
      (build-path base path)))
;; Eli: This looks completely unnecessary.  I find the code much easier to
;;   understand than the long name.

(define (directory-part path)
  (let-values ([(base name must-be-dir) (split-path path)])
    (cond
      [(eq? 'relative base) (current-directory)]
      [(not base) (error 'directory-part "~a is a top-level directory" path)]
      [(path? base) base])))
;; Eli: There is now a `file-name-from-path', which suggests that the name for
;;   this should be `directory-name-from-path', but perhaps a new name is
;;   better for both.  Also, I find it questionable to return the current
;;   directory in the first case.

(provide/contract
 [explode-path* (path-string? . -> . (listof path-piece?))]
 [path-without-base (path-string? path-string? . -> . (listof path-piece?))]
 [directory-part (path-string? . -> . path?)]
 [build-path-unless-absolute (path-string? path-string? . -> . path?)])

;; --

(define (read/bytes bs)
  (read (open-input-bytes bs)))
;; Eli: This is a really bad name for something that is often called
;;   `read-from-string', or `read-from-bytes' in this case.  I first read it as
;;   "read with bytes".  Regardless, I see little point in composing two
;;   functions where the two names are clear enough -- you might consider
;;   looking at the version in CL.
;; Ryan: I agree. More useful would be a version that checked that the
;; bytes contains only one S-expr and errors otherwise.

(define (write/bytes v)
  (define by (open-output-bytes))
  (write v by)
  (get-output-bytes by))
;; Eli: Same bad name as above.  Also, is there any point in this given
;;   (format "~s" v), and the fact that using the resulting string for printout
;;   will get the same result.

(provide/contract
 [read/bytes (bytes? . -> . printable/c)]
 [write/bytes (printable/c . -> . bytes?)])

;; --

(define (read/string str)
  (define r (read (open-input-string str)))
  (cond [(eof-object? r) (raise-type-error 'read/string "nonempty string" str)]
        [else r]))

;; Eli: Same comments as `read/bytes'.

(define (write/string v)
  (define str (open-output-string))
  (write v str)
  (get-output-string str))
;; Eli: Same comments as `write/string', and worse -- this is the same as
;;   (format "~s" v)

; lowercase-symbol! : (or/c string bytes) -> symbol
(define (lowercase-symbol! s)
  (string->symbol
   (string-downcase
    (if (bytes? s)
        (bytes->string/utf-8 s)
        s))))
;; Eli: This doesn't make any sense at all.  Why is the `!' in the name?  Why
;;   does it accept bytes?  Why does a function in a "string" library accept
;;   bytes?  How can I guess that this creates a new symbol from that name?
;;   (Which makes me think that this is (compose string->symbol string-downcase
;;   symbol->string))

(provide/contract
 [lowercase-symbol! ((or/c string? bytes?) . -> . symbol?)]
 [read/string (string? . -> . serializable?)]
 [write/string (serializable? . -> . string?)])

;; --

(provide/contract
 [url-replace-path (((listof path/param?) . -> . (listof path/param?)) url? . -> . url?)]
 [url-path->string ((listof path/param?) . -> . string?)])

;; replace-path: (url-path -> url-path) url -> url
;; make a new url by replacing the path part of a url with a function
;; of the url's old path
;; also remove the query
(define (url-replace-path proc in-url)
  (let ([new-path (proc (url-path in-url))])
    (make-url
     (url-scheme in-url)
     (url-user in-url)
     (url-host in-url)
     (url-port in-url)
     (url-path-absolute? in-url)
     new-path
     empty
     (url-fragment in-url))))
;; Eli: if it also removes the query, this it's a bad name, and it's
;;   questionable whether it is general enough.  Why not make it into a
;;   keyworded function that can change any part, which sounds like a much more
;;   useful utility?  Some `foo' that would allow:
;;     (define (url-replace-path proc in-url)
;;       (foo in-url #:path (proc (url-path in-url)) #:query '()))
;;   or even accept a changing function for all keywords:
;;     (define (url-replace-path proc in-url)
;;       (foo in-url #:path proc #:query '()))

;; ripped this off from url-unit.rkt
(define (url-path->string strs)
  (apply string-append
         (apply append
                (map (lambda (s) (list "/" (maybe-join-params s)))
                     strs))))

;; needs to unquote things!
(define (maybe-join-params s)
  (if (string? s)
      s
      (let ([s (path/param-path s)])
        (if (string? s)
            s
            (case s
              [(same) "."]
              [(up)   ".."]
              [else (error 'maybe-join-params
                           "bad value from path/param-path: ~e" s)])))))
;; Eli: I don't know what this is supposed to be doing -- I don't see any
;;   "maybe"ness), it throws away the `path/param-param's, and it accepts
;;   strings too (which makes me wonder how is this related to the url
;;   library).
