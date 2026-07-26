PACKAGE = jt-pve-storage-dellemc
VERSION = 0.2.0

DESTDIR =
PREFIX   = /usr
PERL5DIR = $(DESTDIR)$(PREFIX)/share/perl5
BINDIR   = $(DESTDIR)$(PREFIX)/bin

# Discovered rather than hard-coded: modules are added phase by phase
# (see jt-pve-storage-dellemc.md ch.13) and a hand-maintained list would
# drift out of sync with debian/ and the syntax-check target.
PERL_MODULES = $(shell find lib -type f -name '*.pm' 2>/dev/null | sort)
BIN_SCRIPTS  = $(shell find bin -type f ! -name '.gitkeep' 2>/dev/null | sort)
UNIT_TESTS   = $(wildcard t/*.t)

# Paths scanned by the capital-F flush guard. Deliberately excludes the design
# document at the repo root, which quotes the forbidden command at length.
GUARD_PATHS = lib bin debian docs t .github Makefile \
              README.md README_zh-TW.md CHANGELOG.md CHANGELOG_zh-TW.md

.PHONY: all install uninstall test syntax unit check-multipath-flush deb deb-clean clean

all:
	@echo "Nothing to build. Run 'make install', 'make test' or 'make deb'."

install:
	@set -e; for f in $(PERL_MODULES); do \
		rel=$${f#lib/}; \
		install -d $(PERL5DIR)/$$(dirname $$rel); \
		install -m 0644 $$f $(PERL5DIR)/$$rel; \
		echo "  installed $(PERL5DIR)/$$rel"; \
	done
	@set -e; for f in $(BIN_SCRIPTS); do \
		install -d $(BINDIR); \
		install -m 0755 $$f $(BINDIR)/; \
		echo "  installed $(BINDIR)/$$(basename $$f)"; \
	done

uninstall:
	rm -f  $(PERL5DIR)/PVE/Storage/Custom/DellPowerStorePlugin.pm
	rm -f  $(PERL5DIR)/PVE/Storage/Custom/DellPowerMaxPlugin.pm
	rm -f  $(PERL5DIR)/PVE/Storage/Custom/DellPowerFlexPlugin.pm
	rm -f  $(PERL5DIR)/PVE/Storage/Custom/DellPowerScalePlugin.pm
	rm -rf $(PERL5DIR)/PVE/Storage/Custom/DellEMC/
	@for f in $(BIN_SCRIPTS); do rm -f $(BINDIR)/$$(basename $$f); done

test: syntax unit check-multipath-flush
	@echo "All checks passed."

syntax:
	@echo "Running Perl syntax checks..."
	@if [ -z "$(strip $(PERL_MODULES))$(strip $(BIN_SCRIPTS))" ]; then \
		echo "  (no Perl sources yet — skeleton stage)"; \
	fi
	@set -e; for f in $(PERL_MODULES) $(BIN_SCRIPTS); do \
		echo "  checking $$f"; \
		perl -Ilib -c $$f || exit 1; \
	done

unit:
	@if [ -n "$(strip $(UNIT_TESTS))" ]; then \
		echo "Running unit tests..."; \
		prove -Ilib $(UNIT_TESTS); \
	else \
		echo "No unit tests yet (t/*.t)."; \
	fi

# `multipath -F` (capital F) must NEVER be used: it flushes EVERY unused
# multipath map on the node, including maps belonging to other storages and
# other vendors. Only ever flush one map at a time, with lowercase
# `multipath -f /dev/mapper/<wwid>`. Prose that forbids the command is allowed
# through: such a line must carry never (any case) / 不得 / 不要 / 禁止.
check-multipath-flush:
	@echo "Checking for forbidden system-wide multipath flush..."
	@hits=$$(grep -rnE 'multipath[[:space:]]+(-[A-Za-z]*F|--flush)' \
		$(GUARD_PATHS) --exclude-dir=.git --binary-files=without-match 2>/dev/null \
		| grep -viE 'never|不得|不要|不會|絕不|禁止' || true); \
	if [ -n "$$hits" ]; then \
		echo "ERROR: forbidden system-wide multipath flush found:"; \
		echo "$$hits" | sed 's/^/  /'; \
		echo ""; \
		echo "Flush a single map instead: multipath -f /dev/mapper/<wwid>"; \
		exit 1; \
	fi; \
	echo "  OK: no system-wide multipath flush found."

deb:
	dpkg-buildpackage -us -uc -b

clean:
	rm -rf debian/$(PACKAGE)/
	rm -rf debian/.debhelper/
	rm -f  debian/debhelper-build-stamp
	rm -f  debian/files
	rm -f  debian/*.substvars
	rm -f  debian/*.log

deb-clean: clean
	rm -f ../$(PACKAGE)_*.deb
	rm -f ../$(PACKAGE)_*.changes
	rm -f ../$(PACKAGE)_*.buildinfo
