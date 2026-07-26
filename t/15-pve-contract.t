#!/usr/bin/perl
# The contract with the PVE version installed on this machine.
#
# Everything here is read off `/usr/share/perl5/PVE/` rather than remembered.
# The point is to fail when a PVE upgrade changes something underneath the
# plugin — a raised API version, a new base method that dies, a base method
# that reaches for a path this plugin cannot provide — instead of finding out
# from a customer.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

BEGIN {
    eval { require PVE::Storage; require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage is not available (not a Proxmox VE node)';
}

use PVE::Storage::Custom::DellPowerStorePlugin;
use PVE::Storage::Custom::DellPowerVaultPlugin;
use PVE::Storage::Custom::DellPowerFlexPlugin;

my @PLUGINS = qw(
    PVE::Storage::Custom::DellPowerStorePlugin
    PVE::Storage::Custom::DellPowerVaultPlugin
    PVE::Storage::Custom::DellPowerFlexPlugin
);

# ---------------------------------------------------------------------------
# API version
# ---------------------------------------------------------------------------

my $APIVER = PVE::Storage::APIVER();
my $APIAGE = PVE::Storage::APIAGE();

diag("PVE::Storage APIVER=$APIVER APIAGE=$APIAGE (accepts "
    . ($APIVER - $APIAGE) . "..$APIVER)");

for my $plugin (@PLUGINS) {
    my $claim = $plugin->api();

    cmp_ok($claim, '<=', $APIVER,
        "$plugin claims no more than this PVE offers")
        or diag("A plugin claiming more is REJECTED and every storage of this"
              . " type disappears from the node");

    cmp_ok($claim, '>=', $APIVER - $APIAGE,
        "$plugin claims no less than this PVE accepts");

    is($claim, $APIVER, "$plugin matches exactly, so PVE stays quiet")
        or diag("Anything lower makes PVE warn on every load of PVE::Storage,"
              . " which is once per pvesm call. If this fails because PVE is"
              . " newer than APIVERSION_MAX, implement that version's delta"
              . " and raise it.");
}

# ---------------------------------------------------------------------------
# Base methods this plugin must not inherit
#
# Read out of the installed Plugin.pm: any method whose body reaches for
# filesystem_path (which needs a storeid PVE never provides here) or that
# simply dies. Inheriting one of those means an operation fails with a message
# about a method the caller never asked for.
# ---------------------------------------------------------------------------

my $plugin_source = do {
    my $file = $INC{'PVE/Storage/Plugin.pm'};
    open(my $fh, '<', $file) or die "cannot read $file: $!";
    local $/;
    <$fh>;
};

# Split into subs. Good enough for a source that indents its closing braces at
# column zero, which this one does.
my %body;
for my $chunk (split /^sub /m, $plugin_source) {
    next unless $chunk =~ /\A(\w+)\s*(?:\([^)]*\))?\s*\{/;
    $body{$1} = $chunk;
}

ok(scalar(keys %body) > 50, 'the installed Plugin.pm parsed into subs')
    or BAIL_OUT('cannot read the base plugin; the rest of this file is void');

# Methods PVE only calls for a content type this plugin does not declare.
# Each one is paired with the content type that would make it reachable, and
# that pairing is asserted below — so declaring the content type later forces
# the override rather than silently inheriting a broken implementation.
my %ONLY_FOR_CONTENT = (
    prune_backups => 'backup',
);

my @dangerous;
for my $method (sort keys %body) {
    next if $method eq 'filesystem_path';       # the one we already refuse
    next if $method =~ /^(?:parse|verify|encode|decode)_/;   # pure helpers
    next if $ONLY_FOR_CONTENT{$method};

    my $text = $body{$method};
    push @dangerous, [$method, 'reaches filesystem_path']
        if $text =~ /\$class->filesystem_path\(/;
    push @dangerous, [$method, 'dies by default']
        if $text =~ /die\s+["'][^"']*not implemented/;
}

diag("base methods that must be overridden: "
    . join(', ', map { $_->[0] } @dangerous));

for my $entry (@dangerous) {
    my ($method, $why) = @$entry;

    for my $plugin (@PLUGINS) {
        my $ours = $plugin->can($method);
        my $base = PVE::Storage::Plugin->can($method);

        isnt($ours, $base, "$plugin overrides $method (base $why)")
            or diag("PVE would call the base implementation, which $why."
                  . " Implement it, or die with a message that says what the"
                  . " operation was.");
    }
}

# The exceptions above hold only while the content type stays undeclared.
for my $method (sort keys %ONLY_FOR_CONTENT) {
    my $content = $ONLY_FOR_CONTENT{$method};

    for my $plugin (@PLUGINS) {
        my $declared = $plugin->plugindata()->{content}[0] // {};

        ok(!$declared->{$content},
            "$plugin does not declare '$content' content, which is the only"
          . " way PVE would call the inherited $method")
            or diag("Declaring '$content' makes PVE call the base $method,"
                  . " which reaches filesystem_path. Override it first.");
    }
}

# ---------------------------------------------------------------------------
# Property declaration
#
# PVE::SectionConfig::init dies on a duplicate property name, and the failure
# is not scoped to the plugin that caused it: it happens while PVE builds the
# storage schema, so every storage on the node stops working.
# ---------------------------------------------------------------------------

{
    my %seen;
    my @duplicates;

    for my $plugin (@PLUGINS) {
        my $props = $plugin->properties();
        for my $name (sort keys %$props) {
            push @duplicates, "$name (also in $seen{$name})" if $seen{$name};
            $seen{$name} = $plugin;
        }
    }

    is_deeply(\@duplicates, [],
        'no property name is declared by two of our plugins')
        or diag('PVE dies with "duplicate property" while building the schema,'
              . ' and every storage on the node stops working');

    # Every option must resolve to a declared property, or PVE complains about
    # an unknown one at parse time.
    for my $plugin (@PLUGINS) {
        my $options = $plugin->options();
        my @undeclared = grep { !$seen{$_} && !PVE::Storage::Plugin->can('') }
            grep { !exists $seen{$_} } sort keys %$options;

        # PVE's own generic options are declared by the base class.
        my $base_props = PVE::Storage::Plugin->private()->{propertyList} // {};
        @undeclared = grep { !exists $base_props->{$_} } @undeclared;

        is_deeply(\@undeclared, [],
            "$plugin declares every option it uses");
    }
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

{
    my $registered = PVE::Storage::Plugin->private()->{plugins} // {};

    for my $plugin (@PLUGINS) {
        my $type = $plugin->type();
        ok($registered->{$type}, "$type is registered with PVE")
            or diag('PVE registers custom plugins itself; the module must not'
                  . ' call register() on its own');
    }

    # Shared storage: PVE forces `shared 1` for these types in parse_config,
    # which is what makes live migration possible.
    no warnings 'once';
    for my $plugin (@PLUGINS) {
        my $type = $plugin->type();
        ok(scalar(grep { $_ eq $type } @PVE::Storage::Plugin::SHARED_STORAGE),
            "$type is marked as shared storage");
    }
}

# ---------------------------------------------------------------------------
# The abstract interface between BlockBase and its families
#
# BlockBase dies with "must implement" when a family is missing one of these,
# and that only happens when the operation is first tried — which for several
# of them means the first time anyone deletes a disk or reads a snapshot.
# ---------------------------------------------------------------------------

{
    my $base = 'PVE::Storage::Custom::DellEMC::Common::BlockBase';

    # Every _array_* method the base class declares abstract.
    my $file = $INC{'PVE/Storage/Custom/DellEMC/Common/BlockBase.pm'};
    my $source = do {
        open(my $fh, '<', $file) or die "cannot read $file: $!";
        local $/;
        <$fh>;
    };

    my @abstract;
    while ($source =~ /^sub (_array_\w+)\s*\{\s*\$_\[0\]->_abstract/gm) {
        push @abstract, $1;
    }

    cmp_ok(scalar(@abstract), '>=', 15,
        'the abstract interface was found in the base class');

    for my $family (qw(
        PVE::Storage::Custom::DellPowerStorePlugin
        PVE::Storage::Custom::DellPowerVaultPlugin
    )) {
        my @missing = grep {
            ($family->can($_) // 0) == ($base->can($_) // 1)
        } @abstract;

        is_deeply(\@missing, [], "$family implements every abstract method")
            or diag("still abstract: @missing — these die with 'must implement'"
                  . " the first time the operation is tried, which for some of"
                  . " them is the first delete or the first snapshot read");
    }
}

# ---------------------------------------------------------------------------
# plugindata
# ---------------------------------------------------------------------------

for my $plugin (@PLUGINS) {
    my $data = $plugin->plugindata();

    ok(ref($data->{content}) eq 'ARRAY', "$plugin declares content types");
    ok($data->{content}[0]{images}, "$plugin holds VM disks");
    ok($data->{format}[0]{raw}, "$plugin holds raw volumes");
    is($data->{format}[1], 'raw', "$plugin defaults to raw");

    # A format this plugin cannot produce must not be offered.
    ok(!$data->{format}[0]{qcow2}, "$plugin does not claim qcow2");
    ok(!$data->{format}[0]{subvol}, "$plugin does not claim subvol");
}

done_testing();
