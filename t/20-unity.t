#!/usr/bin/perl
# Unity XT naming.
#
# The API client is not written yet. What this file protects is the part that
# can be checked without an array at all: that Unity's wider name limit does
# not weaken the ownership gate, and that the limit is read from the subclass
# rather than resolved in the parent package.
#
# That second one is not hypothetical. PowerFlex inherited PowerVault's naming
# and enforced PowerVault's 31-character limit, because the inherited methods
# read a `use constant` that Perl resolved at compile time in the parent. The
# family limits are plain methods for that reason, and this asserts it for
# Unity before any code depends on it.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

use PVE::Storage::Custom::DellEMC::Unity::Naming;
use PVE::Storage::Custom::DellEMC::PowerVault::Naming;

my $U = 'PVE::Storage::Custom::DellEMC::Unity::Naming';
my $V = 'PVE::Storage::Custom::DellEMC::PowerVault::Naming';

# ---------------------------------------------------------------------------
# The limit belongs to this class
# ---------------------------------------------------------------------------

is($U->max_volume_name_length, 85, 'Unity documents 85 characters');
isnt($U->max_volume_name_length, $V->max_volume_name_length,
    '... which is not the limit another family happens to have');

ok($U->isa('PVE::Storage::Custom::DellEMC::Common::Naming'),
    'the shared naming is inherited, not reimplemented');

# ---------------------------------------------------------------------------
# Generated names
# ---------------------------------------------------------------------------

my $vol = $U->encode_volume_name('u480', 100, 0);
is($vol, 'pve-u480-100-disk0', 'a volume name carries the storage it belongs to');

is($U->encode_snapshot_name($vol, 'before'), "$vol.pve-snap-before",
    'a snapshot hangs off the volume name');
is($U->encode_base_snapshot_name($vol), "$vol.pve-base",
    'the template marker is its own suffix');
is($U->encode_host_name('u480', 'pve1'), 'pve-u480-pve1',
    'a host object names the storage and the node');

# Unity accepts '.' in a name, but this plugin's own naming uses it as the
# separator before a snapshot suffix. A generated name that contained one
# would decode as a snapshot of a volume that does not exist.
unlike($vol, qr/\./, 'a generated volume name carries no dot of its own');

for my $name ($U->encode_cloudinit_name('u480', 100),
              $U->encode_efidisk_name('u480', 100, 0),
              $U->encode_tpmstate_name('u480', 100, 1)) {
    cmp_ok(length($name), '<=', $U->max_volume_name_length,
        "'$name' fits the array's limit");
    unlike($name, qr/\./, "'$name' carries no dot either");
}

# ---------------------------------------------------------------------------
# The ownership gate
#
# This is what stands between the plugin and deleting somebody's production
# LUN, so a wider name limit must not widen what it accepts. The two-argument
# form with the storeid is the only one that authorises anything.
# ---------------------------------------------------------------------------

ok($U->is_pve_managed_volume($vol, 'u480'),
    'a volume this storage created is its own');
ok($U->is_pve_managed_volume($U->encode_snapshot_name($vol, 'x'), 'u480'),
    '... and so is a snapshot of it');
ok($U->is_pve_managed_volume($U->encode_base_snapshot_name($vol), 'u480'),
    '... and its template marker');

ok(!$U->is_pve_managed_volume($vol, 'somewhere-else'),
    "another storage's volume is not this one's to touch");

for my $foreign ('Finance-DB-LUN', 'lun_0', 'pve', 'pve-', '',
                 'pve-u480', 'PVE-U480-100-disk0') {
    ok(!$U->is_pve_managed_volume($foreign, 'u480'),
        "'$foreign' is not a volume this storage manages");
}

# A name that merely starts with the prefix is not proof of anything: the
# prefix identifies the STORAGE, never the kind of object. This has been a
# real defect here before, in the temporary-clone reaper.
ok(!$U->is_pve_managed_volume('pve-u480-not-a-real-name', 'u480'),
    'the prefix alone does not make something ours');

# ---------------------------------------------------------------------------
# A name the array would alter
# ---------------------------------------------------------------------------

{
    # PVE allows a 40-character snapshot name; a whole Unity name is 85, so
    # unlike PowerVault this should never need shortening. If it ever does,
    # the volume half must still be exact — an approximate volume name points
    # at the wrong object.
    my $long = 'a' x 40;
    my $snap = eval { $U->encode_snapshot_name($vol, $long) };
    ok(defined $snap, 'a 40-character snapshot name is accepted') or diag($@);
    like($snap, qr/^\Q$vol\E\./, '... with the volume half exact');
    cmp_ok(length($snap), '<=', $U->max_snapshot_name_length,
        '... and the whole thing within the limit');
}

done_testing();
