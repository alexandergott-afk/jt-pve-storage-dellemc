PACKAGE = jt-pve-storage-dellemc

# Versioning: the patch number increments per release and runs to .99 before
# the minor number moves — 0.7.0, 0.7.1, ... 0.7.99, then 0.8.0. Keep this in
# step with debian/changelog; the release workflow refuses to publish when
# the git tag and debian/changelog disagree.
VERSION = 0.7.42~beta1

DESTDIR =
PREFIX   = /usr
PERL5DIR = $(DESTDIR)$(PREFIX)/share/perl5
BINDIR   = $(DESTDIR)$(PREFIX)/bin

# Discovered rather than hard-coded: a hand-maintained module list would
# drift out of sync with debian/ and the syntax-check target.
PERL_MODULES = $(shell find lib -type f -name '*.pm' 2>/dev/null | sort)
BIN_SCRIPTS  = $(shell find bin -type f ! -name '.gitkeep' 2>/dev/null | sort)
UNIT_TESTS   = $(wildcard t/*.t)

# Paths scanned by the capital-F flush guard.
GUARD_PATHS = lib bin debian docs t .github Makefile \
              README.md README_zh-TW.md CHANGELOG.md CHANGELOG_zh-TW.md

.PHONY: all install uninstall test syntax unit check-multipath-flush \
        release-check deb deb-clean clean

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
	rm -f  $(PERL5DIR)/PVE/Storage/Custom/DellPowerVaultPlugin.pm
	rm -rf $(PERL5DIR)/PVE/Storage/Custom/DellEMC/
	@for f in $(BIN_SCRIPTS); do rm -f $(BINDIR)/$$(basename $$f); done

test: syntax unit check-multipath-flush
	@echo "All checks passed."

# Modules that subclass PVE::Storage::Plugin cannot be compiled without a
# Proxmox VE installation. On a build host or CI runner that is expected, and
# reporting it as a failure would train everyone to ignore this target — so
# only that specific cause is tolerated, and it is named in the output.
syntax:
	@echo "Running Perl syntax checks..."
	@if [ -z "$(strip $(PERL_MODULES))$(strip $(BIN_SCRIPTS))" ]; then \
		echo "  (no Perl sources yet — skeleton stage)"; \
	fi
	@set -e; skipped=0; for f in $(PERL_MODULES) $(BIN_SCRIPTS); do \
		out=$$(perl -Ilib -c $$f 2>&1) || { \
			if echo "$$out" | grep -q "Can't locate PVE/"; then \
				echo "  skipped $$f (needs Proxmox VE)"; \
				skipped=1; \
				continue; \
			fi; \
			echo "$$out"; \
			exit 1; \
		}; \
		echo "  checking $$f ... OK"; \
	done; \
	if [ "$$skipped" = "1" ]; then \
		echo "  NOTE: some modules were skipped. Run 'make syntax' on a"; \
		echo "        Proxmox VE node to check them."; \
	fi

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
	@echo "Checking for forbidden system-wide multipath operations..."
	@hits=$$(grep -rnE "multipath[[:space:]]+(-[A-Za-z]*F|--flush)|(multipathd|MULTIPATHD)['\", ]*(remove|del)['\", ]+(maps|multipaths)" \
		$(GUARD_PATHS) --exclude-dir=.git --binary-files=without-match 2>/dev/null \
		| grep -viE 'never|不得|不要|不會|絕不|禁止' || true); \
	if [ -n "$$hits" ]; then \
		echo "ERROR: forbidden node-wide multipath operation found:"; \
		echo "$$hits" | sed 's/^/  /'; \
		echo ""; \
		echo "These remove EVERY unused map on the node, including other"; \
		echo "vendors' storage. Act on one named map instead:"; \
		echo "  multipath -f /dev/mapper/<wwid>"; \
		echo "  multipathd remove map <name>"; \
		exit 1; \
	fi; \
	echo "  OK: no node-wide multipath flush found."

# Everything that must pass before a release, including the checks that catch
# a half-finished version bump. See docs/RELEASE_TESTING.md; this target is
# stage 1 of that plan.
release-check: check-multipath-flush syntax unit
	@echo "Checking version consistency..."
	@deb_version=$$(dpkg-parsechangelog --show-field Version 2>/dev/null \
		| sed 's/-[0-9]*$$//'); \
	tool_version=$$(sed -n "s/^my \$$VERSION = '\(.*\)';/\1/p" \
		bin/pve-dell-config-get); \
	fail=0; \
	echo "  Makefile:        $(VERSION)"; \
	echo "  debian/changelog: $$deb_version"; \
	echo "  config tool:      $$tool_version"; \
	if [ "$(VERSION)" != "$$deb_version" ]; then \
		echo "  ERROR: Makefile and debian/changelog disagree"; fail=1; \
	fi; \
	if [ "$(VERSION)" != "$$tool_version" ]; then \
		echo "  ERROR: Makefile and bin/pve-dell-config-get disagree"; fail=1; \
	fi; \
	for f in CHANGELOG.md CHANGELOG_zh-TW.md; do \
		if ! grep -q "\[$(VERSION)\]" $$f; then \
			echo "  ERROR: $$f has no entry for $(VERSION)"; fail=1; \
		fi; \
	done; \
	for f in README.md README_zh-TW.md docs/index.html; do \
		if ! grep -q "$(VERSION)" $$f; then \
			echo "  ERROR: $$f still names an older version"; fail=1; \
		fi; \
	done; \
	stale=$$(grep -ohE '0\.[0-9]+\.[0-9]+~beta[0-9]+' README.md README_zh-TW.md \
		| sort -u | grep -v '^$(VERSION)$$' || true); \
	if [ -n "$$stale" ]; then \
		echo "  ERROR: the READMEs also mention $$stale"; fail=1; \
	fi; \
	badge=$$(sed -n 's/.*hero__badge">v\([^ <]*\).*/\1/p' docs/index.html | head -1); \
	if [ "$$badge" != "$(VERSION)" ]; then \
		echo "  ERROR: the docs site badge says $$badge"; fail=1; \
	fi; \
	if ! grep -q 'changelog-version">v$(VERSION)<' docs/index.html; then \
		echo "  ERROR: the docs site has no changelog entry for $(VERSION)"; fail=1; \
	fi; \
	if [ "$$fail" = "1" ]; then \
		echo ""; \
		echo "A release whose files disagree about its own version is worse"; \
		echo "than no release. Fix the above, then run this again."; \
		exit 1; \
	fi; \
	echo "  OK: every file agrees on $(VERSION), including the docs site"
	@echo ""
	@echo "Stage 1 passed. Stages 2 to 5 are in docs/RELEASE_TESTING.md."

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
