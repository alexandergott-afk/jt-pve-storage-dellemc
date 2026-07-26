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

done_testing();
