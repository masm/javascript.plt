#lang scheme/base

(require (planet schematics/schemeunit:3)
         (planet schematics/schemeunit:3/text-ui)
         "parse.ss"
         "pretty-print.ss"
         "eval.ss"
         "array.ss")

(provide all-tests)

(define all-tests
  (test-suite "JavaScript Test Suite"
    parse-tests
    pretty-print-tests
    eval-tests
    array-tests
    ))

(run-tests all-tests)