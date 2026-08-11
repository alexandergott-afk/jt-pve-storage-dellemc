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
use PVE::Storage::Custom::DellUnityPlugin;

my @PLUGINS = qw(
    PVE::Storage::Custom::DellPowerStorePlugin
    PVE::Storage::Custom::DellPowerVaultPlugin
    PVE::Storage::Custom::DellPowerFlexPlugin
    PVE::Storage::Custom::DellUnityPlugin
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

# ---------------------------------------------------------------------------
# parse_volname, against how PVE actually consumes it
# ---------------------------------------------------------------------------

# PVE::Storage::storage_migrate builds the target volume name for a move to a
# storage of another type out of element 1, and for a storage without a
# 'path' it uses that string as the whole volume name. RBDPlugin — the plugin
# whose 'base-X/vm-Y' volname form this one copies — returns the LEAF there.
# Returning the whole volname instead would make the target name refer to a
# base image the target storage has never heard of, and the failure would
# name the wrong volume.
{
    my $rbd = 'PVE::Storage::RBDPlugin';

  SKIP: {
        skip 'RBDPlugin is not installed', 1 + scalar(@PLUGINS)
            unless eval { require PVE::Storage::RBDPlugin; 1 };

        my @rbd = $rbd->parse_volname('base-100-disk-0/vm-101-disk-0');
        is($rbd[1], 'vm-101-disk-0',
            'RBD, the reference for this volname form, returns the leaf name');

        for my $plugin (@PLUGINS) {
            my @ours = $plugin->parse_volname('base-100-disk-0/vm-101-disk-0');

            # isBase is compared as a truth value: RBD leaves it undef for a
            # clone where this plugin returns 0, and every consumer asks
            # `if ($isBase)`.
            is_deeply(
                [@ours[0 .. 4], ($ours[5] ? 1 : 0), $ours[6]],
                [@rbd[0 .. 4],  ($rbd[5]  ? 1 : 0), $rbd[6]],
                "$plugin parses a linked clone the way RBDPlugin does")
                or diag("ours: @{[ map { $_ // 'undef' } @ours ]}\n"
                      . " rbd: @{[ map { $_ // 'undef' } @rbd  ]}");
        }
    }
}

# ---------------------------------------------------------------------------
# volume_has_feature, against how PVE actually consumes it
# ---------------------------------------------------------------------------

# PVE::API2::Qemu refuses a snapshot, a rename or a clone outright when the
# plugin answers no, so a feature table that misreads its own volname turns
# into "the feature is not available on this storage" with nothing to debug.
for my $plugin (@PLUGINS) {
    my $scfg = {};
    my $clone = 'base-100-disk-0/vm-101-disk-0';

    ok($plugin->volume_has_feature($scfg, 'snapshot', 'st', $clone),
        "$plugin allows a snapshot of a linked clone");
    ok(!$plugin->volume_has_feature($scfg, 'snapshot', 'st', 'base-100-disk-0'),
        "$plugin does not offer to snapshot a base image itself");
}

# ---------------------------------------------------------------------------
# Methods PVE calls that the base class answers uselessly for a storage
# without a 'path'
# ---------------------------------------------------------------------------

for my $plugin (@PLUGINS) {
    my $scfg = {};

    # LXC freezes a container's filesystem before a snapshot only if the
    # storage asks it to. A container's root is mounted on THIS host and is
    # being written to while the array snapshots it; without the freeze the
    # snapshot is crash-consistent at best. ZFSPlugin, the other plugin where
    # an external appliance takes the snapshot, answers 1.
    ok($plugin->volume_snapshot_needs_fsfreeze(),
        "$plugin asks LXC to freeze a container before a snapshot")
        or diag('PVE::LXC::Config only freezes mountpoints when this is true;'
              . ' 0 means container snapshots are taken of a live filesystem');

    # storage_migrate asks both storages for their common transfer formats.
    # The base class answers "none" for a storage without a 'path', which
    # refuses every disk move to another storage type, pvesm export/import,
    # and remote migration before any code here is reached.
    my @export = $plugin->volume_export_formats($scfg, 'st', 'vm-100-disk-0',
        undef, undef, 0);
    is_deeply(\@export, ['raw+size'],
        "$plugin offers a transfer format, as LVM and RBD do");

    my @import = $plugin->volume_import_formats($scfg, 'st', 'vm-100-disk-0',
        undef, undef, 0);
    is_deeply(\@import, ['raw+size'], "$plugin accepts the same one");

    # What must still be refused.
    is_deeply([$plugin->volume_export_formats($scfg, 'st', 'vm-100-disk-0',
        undef, undef, 1)], [],
        "$plugin does not claim to transfer snapshots with the volume");
    is_deeply([$plugin->volume_export_formats($scfg, 'st',
        'base-100-disk-0/vm-101-disk-0', undef, 'base-100-disk-0', 0)], [],
        "$plugin does not claim to transfer a linked clone on its own");
    is_deeply([$plugin->volume_export_formats($scfg, 'st', 'vm-100-disk-0',
        'snap1', undef, 0)], [],
        "$plugin does not claim to export a snapshot directly");
}

# And the same answers as the plugins PVE ships for raw block volumes, read
# off the installed source rather than remembered.
SKIP: {
    skip 'LVMPlugin is not installed', 1
        unless eval { require PVE::Storage::LVMPlugin; 1 };

    my @lvm = PVE::Storage::LVMPlugin->volume_import_formats(
        {}, 'st', 'vm-100-disk-0', undef, undef, 0);
    is_deeply([$PLUGINS[0]->volume_import_formats({}, 'st', 'vm-100-disk-0',
        undef, undef, 0)], \@lvm,
        'the transfer format matches what LVMPlugin offers for a raw volume');
}

# ---------------------------------------------------------------------------
# A protocol a storage type cannot speak must be refused when it is configured
#
# 'dell-protocol' is declared once for all three types — PVE::SectionConfig
# dies on a duplicate property name — so its enum lists every protocol any
# family supports. Without a per-type check the mistake survived: PowerFlex
# died on first use with the storage already added, and the SAN families were
# worse, silently treating an unknown protocol as iSCSI.
# ---------------------------------------------------------------------------

{
    my %speaks = (
        'PVE::Storage::Custom::DellPowerStorePlugin' => [qw(iscsi fc)],
        'PVE::Storage::Custom::DellPowerVaultPlugin' => [qw(iscsi fc)],
        'PVE::Storage::Custom::DellPowerFlexPlugin'  => [qw(sdc nvme)],
        'PVE::Storage::Custom::DellUnityPlugin'      => [qw(fc iscsi)],
    );

    for my $plugin (@PLUGINS) {
        my %ok = map { $_ => 1 } @{ $speaks{$plugin} };

        for my $protocol (qw(iscsi fc sdc nvme)) {
            my $accepted = eval {
                $plugin->on_add_hook('st', { 'dell-protocol' => $protocol });
                1;
            };

            if ($ok{$protocol}) {
                ok($accepted, "$plugin accepts '$protocol'")
                    or diag("refused with: $@");
            } else {
                ok(!$accepted, "$plugin refuses '$protocol' when it is added")
                    or diag('the storage would be created and then either fail'
                          . ' on every operation or silently use another path');
                like($@ // '', qr/\Q$protocol\E/,
                    "... naming the protocol that was asked for");
            }
        }

        # An update that does not mention the protocol has nothing to check.
        ok(eval { $plugin->on_update_hook('st', { 'dell-portal' => '10.0.0.5' }); 1 },
            "$plugin allows an update that does not touch the protocol");

        # One that does is checked.
        my $bad = $ok{iscsi} ? 'sdc' : 'iscsi';
        ok(!eval { $plugin->on_update_hook('st', { 'dell-protocol' => $bad }); 1 },
            "$plugin refuses '$bad' on an update too");
    }
}

# Two storage ids that fold to one prefix must be refused at creation. Volume
# names are built from the prefix, so on one array the two storages would list
# each other's disks and either could delete the other's.
{
    no warnings 'redefine', 'once';

    local *PVE::Storage::config = sub {
        return { ids => {
            'dell-1' => { type => 'dellpowerstore' },
            'other'  => { type => 'dir', path => '/tmp' },
        } };
    };

    for my $plugin (@PLUGINS) {
        ok(!eval { $plugin->_check_prefix_collision('dell_1', {}); 1 },
            "$plugin refuses a storage id that folds onto an existing prefix");
        like($@ // '', qr/same volume-name prefix/, '... saying why');
        like($@ // '', qr/dell-1/, '... and naming the storage it collides with');

        ok(eval { $plugin->_check_prefix_collision('dell2', {}); 1 },
            "$plugin allows one that does not collide");

        # Re-adding the same id is an update, not a collision with itself.
        ok(eval { $plugin->_check_prefix_collision('dell-1', {}); 1 },
            "$plugin does not collide a storage with itself");
    }
}

# ---------------------------------------------------------------------------
# What the other two path-less block plugins both found necessary
#
# LVMPlugin and RBDPlugin are the two PVE plugins that are also block storage
# with no filesystem path, so a base method that BOTH of them override is a
# base method whose default does not fit that shape. Inheriting it here is
# therefore a question to answer, not a default to accept.
#
# It is the general form of two defects. volume_export/volume_import (0.7.88):
# the FORMATS methods were overridden to advertise a transfer and the
# transfer itself left to a base class that refuses it for a storage with no
# path, so every disk move was offered and then refused one call later — and
# LVM and RBD both override all four. qemu_blockdev_options (0.7.89): the
# base implementation works, but reaches the device through an unbounded
# File::stat::stat on a path under /dev, which is the uninterruptible sleep
# rule 9 exists for, in the worker starting a VM. LVM and RBD both answer
# 'host_device' without stat'ing anything.
#
# An entry in %BASE_DEFAULT_IS_RIGHT is a decision that has been made and can
# be read back. Anything else is a question nobody has asked yet.
# ---------------------------------------------------------------------------

my %BASE_DEFAULT_IS_RIGHT = (
    # Returns 'qemu' for qcow2 and 'storage' otherwise. Every volume here is
    # raw, so the base always answers 'storage', which is what this plugin
    # wants: the array takes the snapshot, not QEMU. LVM overrides it for
    # qcow2-on-LVM and RBD for the non-krbd case; neither exists here.
    volume_qemu_snapshot_method => 'always raw, so the base answers "storage"',
);

{
    require PVE::Storage::LVMPlugin;
    require PVE::Storage::RBDPlugin;

    my $base = 'PVE::Storage::Plugin';
    my @both;

    for my $method (sort keys %body) {
        my $bc = $base->can($method) or next;
        next if ($method =~ /^_/);
        next if (PVE::Storage::LVMPlugin->can($method) // 0) == $bc;
        next if (PVE::Storage::RBDPlugin->can($method) // 0) == $bc;
        push @both, $method;
    }

    ok(scalar(@both) > 0, 'LVMPlugin and RBDPlugin were both readable')
        or diag('the comparison found nothing to compare, which means it is'
              . ' not testing anything');

    for my $method (@both) {
        for my $plugin (@PLUGINS) {
            my $inherited = ($plugin->can($method) // 0) == $base->can($method);

            if (my $why = $BASE_DEFAULT_IS_RIGHT{$method}) {
                ok(1, "$plugin: $method inherits the base on purpose — $why");
                next;
            }

            ok(!$inherited,
                "$plugin overrides $method, which LVMPlugin and RBDPlugin"
              . " both found necessary")
                or diag("Both of the other path-less block plugins override"
                      . " $method. Either this one needs it too, or the"
                      . " reason it does not belongs in"
                      . " %BASE_DEFAULT_IS_RIGHT, where the next person can"
                      . " read it.");
        }
    }
}

# ---------------------------------------------------------------------------
# get_identity answers whether two storages are the same thing
# ---------------------------------------------------------------------------

{
    for my $plugin (@PLUGINS) {
        my $scfg = { 'dell-portal' => '10.0.0.1,10.0.0.2' };
        my $swapped = { 'dell-portal' => '10.0.0.2, 10.0.0.1 ' };

        is($plugin->get_identity($swapped, 's1'),
           $plugin->get_identity($scfg, 's1'),
            "$plugin: the same array written the other way round is the same"
          . " identity — 'dell-portal' is a list, and a list has no order");

        my $one = { 'dell-portal' => '10.0.0.1' };
        isnt($plugin->get_identity($one, 's1'),
             $plugin->get_identity($scfg, 's1'),
            "$plugin: a different set of addresses is a different identity");

    }
}

# ---------------------------------------------------------------------------
# The API client cache is keyed on the storage, not only on the array
#
# The client carries the storeid it names in every message, and the password
# read out of /etc/pve/priv/storage/<storeid>.pw. Two storages on one array
# with the same username are an ordinary setup — two pools — and a key
# without the storeid hands the second one the first one's client.
# ---------------------------------------------------------------------------

{
    for my $plugin (@PLUGINS) {
        my $scfg = {
            'dell-portal'   => '10.0.0.1',
            'dell-username' => 'admin',
            'dell-password' => 'x',
            'pvault-pool'   => 'A',
            'unity-pool'    => 'A',
            'pflex-storage-pool' => 'A',
        };

        my $a = eval { $plugin->_api($scfg, storeid => 'dell-a') };
        my $b = eval { $plugin->_api($scfg, storeid => 'dell-b') };

      SKIP: {
            skip "$plugin: no client could be built here", 2 unless $a && $b;

            isnt($a, $b, "$plugin: two storages on one array get their own"
                       . " client");
            like($b->log_prefix, qr/dell-b/,
                "$plugin: and the second one names ITSELF in its messages,"
              . " not the storage that happened to ask first");
        }
    }
}

# ---------------------------------------------------------------------------
# sparseinit is a claim about the array's provisioning
#
# PVE acts on it by NOT writing zeroes — drive-mirror is told the target is
# zero-initialized, pbs-restore gets --skip-zero. That holds for a thin
# volume, whose unmapped LBAs read as zeroes, and not for a thick one, whose
# extents are whatever the array last had there. Answering yes for a thick
# volume puts the array's previous contents inside a guest's disk where its
# source had zeroes. Same claim 0.7.90 removed from the import path's
# dd conv=sparse, reached through QEMU instead.
# ---------------------------------------------------------------------------

{
    my %thick = (
        'PVE::Storage::Custom::DellUnityPlugin'     => { 'unity-thin'  => 0 },
        'PVE::Storage::Custom::DellPowerFlexPlugin' => { 'pflex-thick' => 1 },
    );

    for my $plugin (@PLUGINS) {
        my $ask = sub {
            my ($scfg) = @_;
            return $plugin->volume_has_feature($scfg, 'sparseinit', 's1',
                'vm-100-disk-0', undef, 0, {});
        };

        if (my $cfg = $thick{$plugin}) {
            ok(!$ask->($cfg),
                "$plugin refuses sparseinit when the storage is configured"
              . " thick — those extents are whatever the array last had"
              . " there, and PVE would skip writing over them");
            ok($ask->({}),
                "$plugin still offers it for the thin default, which is"
              . " where the copy is worth skipping");
        } else {
            ok(defined $ask->({}),
                "$plugin answers sparseinit one way or the other");
        }

        ok(!$plugin->volume_has_feature({}, 'sparseinit', 's1',
                'vm-100-disk-0', 'a-snapshot', 0, {}),
            "$plugin never claims it for a snapshot");
    }
}

# ---------------------------------------------------------------------------
# The FC identifier each array actually accepts
#
# A customer's first PowerStore run was refused at POST /host:
#   "the format of the port name pve-pve-<node> is incorrect. Please use a
#    valid IQN for iSCSI, WWN for FC, or NQN for NVMe. (0xE0A01001002F)"
# The array quoted the HOST name back instead of the port, which is why it
# read as a host-naming problem. The cause was the WWPN spelling: everything
# used the run-together form, because that is the function every call site had
# picked, while the one that formats with colons was called nowhere.
#
# The three arrays genuinely differ, so this asserts three different answers
# rather than one shared one:
#   PowerStore  21:00:00:0e:1e:1d:2b:3c              (Dell's ansible module)
#   Unity       20:00:...:3c:21:00:...:3c            (node WWN and port WWN)
#   PowerVault  2100000e1e1d2b3c                     (accepted by an ME4024)
# ---------------------------------------------------------------------------

{
    no warnings 'redefine', 'once';
    no strict 'refs';

    my $PS = 'PVE::Storage::Custom::DellPowerStorePlugin';
    my $UN = 'PVE::Storage::Custom::DellUnityPlugin';
    my $PV = 'PVE::Storage::Custom::DellPowerVaultPlugin';

    local *{"${PS}::get_fc_wwpns"} = sub { ['21:00:00:0e:1e:1d:2b:3c'] };
    local *{"${UN}::get_fc_wwn_pairs"} =
        sub { ['20:00:00:0e:1e:1d:2b:3c:21:00:00:0e:1e:1d:2b:3c'] };
    local *{"${PV}::get_fc_wwpns_raw"} = sub { ['2100000e1e1d2b3c'] };

    my $fc = { 'dell-protocol' => 'fc' };

    is_deeply($PS->_initiator_records($fc),
        [ { port_name => '21:00:00:0e:1e:1d:2b:3c', port_type => 'FC' } ],
        'PowerStore sends the colon-separated WWPN it refuses to do without');

    is_deeply($UN->_initiator_records($fc),
        [ { id => '20:00:00:0e:1e:1d:2b:3c:21:00:00:0e:1e:1d:2b:3c',
            type => '1' } ],
        'Unity sends the node WWN and the port WWN together');

    is_deeply($PV->_initiator_ids($fc), ['2100000e1e1d2b3c'],
        'PowerVault keeps the run-together form, which is the only one an'
      . ' array has actually accepted');
}

# ---------------------------------------------------------------------------
# A worker's client is not cached, because a worker cannot clean up
#
# PVE::RESTEnvironment::fork_worker ends the child with POSIX::_exit, which
# skips END blocks and global destruction alike — measured on a customer's ME
# at 0.8.9, where the END block added for exactly this never ran. So nothing
# at exit can give the session back, and the only moment left is when the
# client is freed. Keeping it in a package hash is what prevents that.
# ---------------------------------------------------------------------------

{
    for my $plugin (@PLUGINS) {
        my $scfg = {
            'dell-portal'   => '10.0.0.1',
            'dell-username' => 'u',
            'dell-password' => 'p',
            'pvault-pool'   => 'A',
            'unity-pool'    => 'A',
            'pflex-storage-pool' => 'A',
        };

        no warnings 'redefine', 'once';

        my $is_worker = 0;
        local *PVE::RESTEnvironment::is_worker = sub { $is_worker };

        my $a = eval { $plugin->_api($scfg, storeid => 'w1') };
        my $b = eval { $plugin->_api($scfg, storeid => 'w1') };

      SKIP: {
            skip "$plugin: no client could be built here", 2 unless $a && $b;

            is($a, $b, "$plugin reuses one client in a long-lived process");

            $is_worker = 1;
            my $c = eval { $plugin->_api($scfg, storeid => 'w1') };
            my $d = eval { $plugin->_api($scfg, storeid => 'w1') };

            isnt($c, $d,
                "$plugin gives a worker its own client each time — a cached"
              . " one lives until POSIX::_exit, and its session is never"
              . " given back");
        }
    }
}

done_testing();
