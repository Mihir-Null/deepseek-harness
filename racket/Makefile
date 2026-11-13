# Racket port: package management for every package directory under racket/.
#
#   make link    register each package with raco so its collections resolve (idempotent)
#   make test    compile each package and run its tests against current bytecode
#   make clean   remove compiled/ directories
#
# A package is a directory that contains info.rkt. `link` adds a collection link in the
# user scope with `raco link`; it fetches nothing and compiles nothing. A package whose
# info.rkt names one collection is linked under that name; any other package is linked as
# a collection root.
#
# `test` passes --make to `raco test`: without it a test module's stale .zo is loaded
# against changed dependencies and fails to link, or passes for the wrong code.

RACO ?= raco
RACKET ?= racket
PACKAGES := $(sort $(patsubst %/info.rkt,%,$(wildcard */info.rkt)))

# Prints the single collection name declared by the info.rkt in the directory given as the
# first command-line argument, or nothing.
COLLECTION_NAME = (let* ([dir (vector-ref (current-command-line-arguments) 0)] \
                         [info (get-info/full dir)] \
                         [name (and info (info (quote collection) (lambda () \#f)))]) \
                    (when (string? name) (display name)))

.PHONY: link test clean

link:
	@for pkg in $(PACKAGES); do \
	  name=$$($(RACKET) -l racket/base -l setup/getinfo -e '$(COLLECTION_NAME)' "$$pkg") || exit 1; \
	  if [ -n "$$name" ]; then \
	    $(RACO) link -n "$$name" "$$pkg" || exit 1; \
	  else \
	    $(RACO) link -d "$$pkg" || exit 1; \
	  fi; \
	done

test: link
	@for pkg in $(PACKAGES); do \
	  echo "raco test $$pkg"; \
	  $(RACO) make $$pkg/*.rkt || exit 1; \
	  $(RACO) test --make $$pkg || exit 1; \
	done

clean:
	@find . -type d -name compiled -prune -exec rm -r {} +
