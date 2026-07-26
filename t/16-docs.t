#!/usr/bin/perl
# Documentation that has drifted from the code.
#
# Every one of these storages is configured by hand from
# docs/CONFIGURATION.md. An option that exists but is not documented cannot be
# found; an option that is documented but does not exist is worse, because the
# operator writes it into storage.cfg and PVE refuses the whole storage.
#
# The bilingual rule is the other half: both languages exist, and both are
# reachable from each other.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage::Plugin is not available (not a Proxmox VE node)';
}

use PVE::Storage::Custom::DellPowerStorePlugin;
use PVE::Storage::Custom::DellPowerVaultPlugin;
use PVE::Storage::Custom::DellPowerFlexPlugin;

my @PLUGINS = qw(
    PVE::Storage::Custom::DellPowerStorePlugin
    PVE::Storage::Custom::DellPowerVaultPlugin
    PVE::Storage::Custom::DellPowerFlexPlugin
);

my $DOCS = -d 'docs' ? 'docs' : '../docs';

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

# ---------------------------------------------------------------------------
# Every option this plugin accepts is documented, in both languages
# ---------------------------------------------------------------------------

my %declared;
for my $plugin (@PLUGINS) {
    my $props = $plugin->properties();
    $declared{$_} = 1 for grep { /^(?:dell|pstore|pvault|pflex)-/ } keys %$props;
}

ok(scalar(keys %declared) > 15, 'the plugins declare a set of options')
    or BAIL_OUT('no options found; the rest of this file is void');

for my $language ('', '_zh-TW') {
    my $file = "$DOCS/CONFIGURATION$language.md";
    my $text = slurp($file);

    ok(defined $text, "$file exists") or next;

    my @missing = grep { $text !~ /\Q`$_`\E/ } sort keys %declared;

    is_deeply(\@missing, [], "$file documents every option")
        or diag("undocumented: @missing");

    # And nothing documented that does not exist. An operator who copies one
    # of these into storage.cfg gets the whole storage refused.
    my %mentioned;
    while ($text =~ /^\|\s*`((?:dell|pstore|pvault|pflex)-[a-z0-9-]+)`/gm) {
        $mentioned{$1} = 1;
    }

    my @phantom = grep { !$declared{$_} } sort keys %mentioned;
    is_deeply(\@phantom, [], "$file documents no option that does not exist")
        or diag("documented but not declared: @phantom");
}

# ---------------------------------------------------------------------------
# Both languages exist and point at each other
# ---------------------------------------------------------------------------

{
    opendir(my $dh, $DOCS) or BAIL_OUT("cannot read $DOCS");
    my @docs = sort grep { /\.md$/ } readdir($dh);
    closedir($dh);

    my @english = grep { !/_zh-TW\.md$/ } @docs;

    ok(scalar(@english) > 5, 'there is a documentation set to check');

    for my $doc (@english) {
        (my $chinese = $doc) =~ s/\.md$/_zh-TW.md/;

        ok(-f "$DOCS/$chinese", "$doc has a Traditional Chinese counterpart");

        my $en = slurp("$DOCS/$doc")     // '';
        my $zh = slurp("$DOCS/$chinese") // '';

        like($en, qr/\Q$chinese\E/, "$doc links to $chinese");
        like($zh, qr/\Q$doc\E/, "$chinese links back to $doc") if length $zh;
    }

    # The top-level pair too.
    for my $pair (['README.md', 'README_zh-TW.md'],
                  ['CHANGELOG.md', 'CHANGELOG_zh-TW.md']) {
        my ($en_file, $zh_file) = @$pair;
        ok(-f $en_file && -f $zh_file, "$en_file and $zh_file both exist");
    }
}

# ---------------------------------------------------------------------------
# The documentation must not promise what the code refuses
# ---------------------------------------------------------------------------

{
    # Every family that does not offer the config backup has to be named as
    # such wherever the feature is described, or an operator will look for a
    # volume that is never created.
    my $vault = 'PVE::Storage::Custom::DellPowerVaultPlugin';
    is($vault->supports_config_backup(), 0,
        'PowerVault does not offer the config backup volume');

    for my $file ("$DOCS/../README.md", "$DOCS/../README_zh-TW.md",
                  "$DOCS/index.html") {
        my $text = slurp($file) // '';
        next unless length $text;

        like($text, qr/PowerVault/, "$file mentions PowerVault at all");
        like($text, qr/dell-config-backup/,
            "$file names the option that controls the config backup");
    }
}

# ---------------------------------------------------------------------------
# Claims about the multipath rules stay in the documentation
# ---------------------------------------------------------------------------

{
    # The README must keep telling operators to never run the system-wide
    # flush. Naming the command here is what the flush guard's never-rule
    # allowance is for.
    for my $file ("$DOCS/../README.md", "$DOCS/../README_zh-TW.md") {
        my $text = slurp($file) // '';
        next unless length $text;

        like($text, qr/multipath\s+-F/,   # never run this; see check-multipath-flush
            "$file still carries the rule about the system-wide flush");
    }

    my $trouble = slurp("$DOCS/TROUBLESHOOTING.md") // '';
    like($trouble, qr/disablequeueing/,
        'troubleshooting still gives the safe flush sequence');
}

# ---------------------------------------------------------------------------
# The recovery tool's own surface
#
# It is operator-facing code that runs during an outage. A broken option table
# only fails at runtime — Getopt::Long validates its specification when it is
# called, not when the file compiles — and that is the worst possible moment
# to find out.
# ---------------------------------------------------------------------------

SKIP: {
    my $tool = -f 'bin/pve-dell-config-get' ? 'bin/pve-dell-config-get'
             : '../bin/pve-dell-config-get';
    skip 'the recovery tool is not in this tree', 4 unless -f $tool;

    my $help = `perl -Ilib $tool --help 2>&1`;
    my $status = $? >> 8;

    is($status, 0, '--help exits cleanly');
    like($help, qr/pve-dell-config-get \S+ - recover VM configurations/,
        '... and names itself and its version');
    like($help, qr/--recover/, '... and documents recover mode');

    # The version has to match the package being built, or an operator
    # reporting a problem reports the wrong one.
    my $makefile = slurp('Makefile') // slurp('../Makefile') // '';
    my ($version) = $makefile =~ /^VERSION\s*=\s*(\S+)/m;

    SKIP: {
        skip 'cannot read the version from the Makefile', 1 unless $version;
        like($help, qr/\Q$version\E/,
            "... and reports the version being built ($version)");
    }
}

# ---------------------------------------------------------------------------
# The field-name table in TESTING.md must not drift
#
# Two of the worst defects found before the first hardware run were field
# names that did not exist. The table exists so an operator can compare it
# against one real response; a field the code reads but the table omits is a
# field nobody will check.
# ---------------------------------------------------------------------------

{
    my $testing = slurp("$DOCS/TESTING.md") // '';

    ok(length $testing, 'docs/TESTING.md is readable') or skip 'no doc', 1;

    my @sources = (
        'lib/PVE/Storage/Custom/DellEMC/PowerVault/API.pm',
        'lib/PVE/Storage/Custom/DellEMC/PowerStore/API.pm',
        'lib/PVE/Storage/Custom/DellEMC/PowerFlex/API.pm',
    );

    # Names this plugin writes rather than reads: request bodies it composes
    # and its own internal state. Only what comes BACK from an array belongs
    # in the table.
    my %not_a_response_field = map { $_ => 1 } qw(
        compressionMethod description expiration_timestamp
        force_internal_snapshots generation session_ttl token
        volumeSizeInKb storagePoolId volumeType removeMode
        snapshotDefs sizeInGB allowMultipleMappings
    );

    my %seen;
    for my $file (@sources) {
        my $text = slurp($file) // slurp("../$file") // '';
        next unless length $text;

        while ($text =~ /->\{'?([a-zA-Z][a-zA-Z0-9_.-]{3,})'?\}/g) {
            my $field = $1;
            next if $not_a_response_field{$field};
            # Keys this plugin puts into its own hashes.
            next if $field =~ /^(?:portal|iqn|wwid|ctime|used|size|volume|
                                  snapname|storage|diskid|type|first_seen|
                                  miss|created|pid|snapshot|ancestor|row|
                                  parent|basename|basevmid|isBase|vmid|
                                  source_id|nqn|state|ana|address|scheme|
                                  timeout|retries|storeid|logger|port|
                                  username|password|portal_probe|health)$/x;
            $seen{$field}++;
        }
    }

    my @undocumented = grep { $testing !~ /\Q$_\E/ } sort keys %seen;

    is_deeply(\@undocumented, [],
        'every array field the clients read appears in the field-name table')
        or diag("missing from docs/TESTING.md: @undocumented");
}

done_testing();
