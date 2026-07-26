#!/usr/bin/perl
# Naming round-trip and ownership tests.
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

use PVE::Storage::Custom::DellEMC::Common::Naming;
my $N = 'PVE::Storage::Custom::DellEMC::Common::Naming';

# A family subclass with wider limits, used to check that the limits really
# are overridable per family (PowerStore allows longer names than the
# conservative default).
{
    package Test::WideNaming;
    use base 'PVE::Storage::Custom::DellEMC::Common::Naming';
    sub max_volume_name_length   { 128 }
    sub max_snapshot_name_length { 128 }
}

# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

is($N->encode_volume_name('ps1', 100, 0), 'pve-ps1-100-disk0', 'volume name');
is($N->encode_cloudinit_name('ps1', 100), 'pve-ps1-100-cloudinit', 'cloudinit name');
is($N->encode_efidisk_name('ps1', 100, 0), 'pve-ps1-100-efidisk0', 'efidisk name');
is($N->encode_tpmstate_name('ps1', 100, 0), 'pve-ps1-100-tpmstate0', 'tpmstate name');
is($N->encode_state_name('ps1', 100, 'snap1'), 'pve-ps1-100-state-snap1', 'state name');
is($N->encode_config_volume_name('ps1', 100, 'snap1'), 'pve-ps1-100-vmconf-snap1', 'vmconf name');
is($N->encode_snapshot_name('pve-ps1-100-disk0', 'snap1'),
    'pve-ps1-100-disk0.pve-snap-snap1', 'snapshot name');
is($N->encode_base_snapshot_name('pve-ps1-100-disk0'),
    'pve-ps1-100-disk0.pve-base', 'base snapshot name');
is($N->encode_host_name('mycluster', 'node1'), 'pve-mycluster-node1', 'host name');
is($N->encode_host_name('mycluster'), 'pve-mycluster-shared', 'shared host name');
is($N->encode_host_group_name('mycluster'), 'pve-mycluster-shared', 'host group name');
is($N->encode_host_name(undef, 'node1'), 'pve-pve-node1', 'host name defaults cluster to pve');

# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------

is_deeply($N->decode_volume_name('pve-ps1-100-disk0'),
    { storage => 'ps1', vmid => 100, diskid => 0, type => 'disk' }, 'decode disk');
is_deeply($N->decode_volume_name('pve-ps1-100-cloudinit'),
    { storage => 'ps1', vmid => 100, type => 'cloudinit' }, 'decode cloudinit');
is_deeply($N->decode_volume_name('pve-ps1-100-efidisk0'),
    { storage => 'ps1', vmid => 100, diskid => 0, type => 'efidisk' }, 'decode efidisk');
is_deeply($N->decode_volume_name('pve-ps1-100-tpmstate0'),
    { storage => 'ps1', vmid => 100, diskid => 0, type => 'tpmstate' }, 'decode tpmstate');
is_deeply($N->decode_volume_name('pve-ps1-100-state-snap1'),
    { storage => 'ps1', vmid => 100, snapname => 'snap1', type => 'state' }, 'decode state');
is_deeply($N->decode_volume_name('pve-ps1-100-vmconf-snap1'),
    { storage => 'ps1', vmid => 100, snapname => 'snap1', type => 'vmconf' }, 'decode vmconf');

is($N->decode_volume_name(undef), undef, 'decode undef');
is($N->decode_volume_name('production-lun-7'), undef, 'decode foreign name');
is($N->decode_volume_name('pve-ps1-100-disk0.pve-snap-x'), undef,
    'decode ignores snapshot names');

is_deeply($N->decode_snapshot_name('pve-ps1-100-disk0.pve-snap-snap1'),
    { volume => 'pve-ps1-100-disk0', snapname => 'snap1', is_base => 0 },
    'decode snapshot');
is_deeply($N->decode_snapshot_name('pve-ps1-100-disk0.pve-base'),
    { volume => 'pve-ps1-100-disk0', snapname => undef, is_base => 1 },
    'decode base snapshot');
is($N->decode_snapshot_name('pve-ps1-100-disk0'), undef, 'plain volume is not a snapshot');

ok($N->is_snapshot_name('pve-ps1-100-disk0.pve-snap-x'), 'is_snapshot_name true');
ok(!$N->is_snapshot_name('pve-ps1-100-disk0'), 'is_snapshot_name false');
ok($N->is_config_volume('pve-ps1-100-vmconf-snap1'), 'is_config_volume true');
ok(!$N->is_config_volume('pve-ps1-100-disk0'), 'is_config_volume false');
ok($N->is_state_volume('pve-ps1-100-state-snap1'), 'is_state_volume true');
ok(!$N->is_state_volume('pve-ps1-100-disk0'), 'is_state_volume false');

# ---------------------------------------------------------------------------
# Round trips: array name -> decoded -> array name
# ---------------------------------------------------------------------------

for my $case (
    [ 'ps1',            100,   0 ],
    [ 'ps1',              1,   0 ],
    [ 'dell-store-01', 99999, 137 ],
    [ 'a',                 7,   3 ],
) {
    my ($storeid, $vmid, $diskid) = @$case;
    my $name = $N->encode_volume_name($storeid, $vmid, $diskid);
    my $d = $N->decode_volume_name($name);
    ok($d, "round trip decodes: $name");
    is($d->{vmid}, $vmid, "round trip vmid: $name");
    is($d->{diskid}, $diskid, "round trip diskid: $name");
    is($N->encode_volume_name($storeid, $d->{vmid}, $d->{diskid}), $name,
        "round trip re-encodes: $name");
}

# ---------------------------------------------------------------------------
# Round trips: PVE volname <-> array name
# ---------------------------------------------------------------------------

for my $volname (
    'vm-100-disk-0',
    'vm-100-disk-15',
    'base-100-disk-0',
    'vm-100-cloudinit',
    'vm-100-efidisk0',
    'vm-100-tpmstate0',
    'vm-100-state-snap1',
) {
    my $array = $N->pve_volname_to_array('ps1', $volname);
    ok($N->is_pve_managed_volume($array, 'ps1'), "owned: $volname -> $array");

    my $back = $N->array_to_pve_volname($array);
    # A base disk maps onto the same array object as the running disk; the
    # base/vm distinction lives in PVE, not on the array.
    (my $expect = $volname) =~ s/^base-/vm-/;
    is($back, $expect, "PVE round trip: $volname");
}

is($N->pve_volname_to_array('ps1', 'images/vm-100-disk-0'), 'pve-ps1-100-disk0',
    'images/ prefix is stripped');

# Linked clone: PVE passes 'base-<vmid>-disk-<n>/vm-<vmid>-disk-<n>' and only
# the clone half has an object of its own.
is($N->pve_volname_to_array('ps1', 'base-100-disk-0/vm-101-disk-0'),
    'pve-ps1-101-disk0', 'linked clone maps to the clone volume');

eval { $N->pve_volname_to_array('ps1', 'nonsense-name') };
like($@, qr/Unrecognized PVE volume name/, 'unknown PVE volname dies');

is($N->array_to_pve_volname('pve-ps1-100-vmconf-snap1'), undef,
    'config volumes have no PVE volume name');
is($N->array_to_pve_volname('production-lun-7'), undef, 'foreign name has no PVE name');

# ---------------------------------------------------------------------------
# storeid sanitizing
# ---------------------------------------------------------------------------

is($N->storeid_to_prefix('ps1'), 'ps1', 'plain storeid');
is($N->storeid_to_prefix('dell-store-01'), 'dell_store_01', 'hyphens become underscores');
is($N->storeid_to_prefix('store.5.111'), 'store_5_111', 'dots become underscores');
unlike($N->storeid_to_prefix('any-thing.here'), qr/[.-]/,
    'prefix contains neither dot nor hyphen');

# A storeid must not be able to collide with a different storeid by having
# characters silently deleted (Pure upstream issue #6).
isnt($N->storeid_to_prefix('pve.1'), $N->storeid_to_prefix('pve1'),
    'dot is replaced, not deleted');

# One storage's prefix must never be a prefix of another's, or it would claim
# the other's volumes.
my $p_short = $N->volume_prefix('ps');
my $p_long  = $N->volume_prefix('ps-1');
isnt(index($p_long, $p_short), 0, "prefix '$p_short' does not contain '$p_long'");
ok(!$N->is_pve_managed_volume($N->encode_volume_name('ps-1', 100, 0), 'ps'),
    'storage ps does not claim a volume of storage ps-1');

is($N->volume_prefix('ps1'), 'pve-ps1-', 'volume prefix for server-side filters');

# Long storeids are truncated to the storeid budget, not the volume budget.
my $long = 'a' x 60;
is(length($N->storeid_to_prefix($long)), $N->max_storeid_length,
    'long storeid truncated to max_storeid_length');

eval { $N->storeid_to_prefix(undef) };
like($@, qr/storeid is required/, 'undef storeid dies');

# ---------------------------------------------------------------------------
# Ownership gate
# ---------------------------------------------------------------------------

ok($N->is_pve_managed_volume('pve-ps1-100-disk0', 'ps1'), 'own volume');
ok($N->is_pve_managed_volume('pve-ps1-100-disk0.pve-snap-x', 'ps1'), 'own snapshot');
ok($N->is_pve_managed_volume('pve-ps1-100-disk0.pve-base', 'ps1'), 'own base snapshot');
ok($N->is_pve_managed_volume('pve-ps1-100-disk0'), 'own volume without storeid');

ok(!$N->is_pve_managed_volume('production-lun-7', 'ps1'), 'foreign volume');
ok(!$N->is_pve_managed_volume('pve-ps2-100-disk0', 'ps1'), 'volume of another storage');
ok(!$N->is_pve_managed_volume('pve-ps1-oracle-data', 'ps1'),
    'right prefix but not a name we produce');
ok(!$N->is_pve_managed_volume(undef, 'ps1'), 'undef name');
ok(!$N->is_pve_managed_volume('', 'ps1'), 'empty name');

# ---------------------------------------------------------------------------
# Length limits and truncation
# ---------------------------------------------------------------------------

my $long_snap = 'x' x 200;

my $state = $N->encode_state_name('ps1', 100, $long_snap);
ok(length($state) <= $N->max_volume_name_length, 'state name fits the volume budget');
like($state, qr/^pve-ps1-100-state-x+$/, 'state name shape after truncation');

my $conf = $N->encode_config_volume_name('ps1', 100, $long_snap);
ok(length($conf) <= $N->max_volume_name_length, 'vmconf name fits the volume budget');

my $snap = $N->encode_snapshot_name('pve-ps1-100-disk0', $long_snap);
ok(length($snap) <= $N->max_snapshot_name_length, 'snapshot name fits the snapshot budget');
is_deeply($N->decode_snapshot_name($snap)->{volume}, 'pve-ps1-100-disk0',
    'truncated snapshot still decodes to its volume');

# The wider family limits must actually take effect.
my $wide = Test::WideNaming->encode_snapshot_name('pve-ps1-100-disk0', $long_snap);
ok(length($wide) > length($snap), 'family subclass gets the wider budget');
ok(length($wide) <= Test::WideNaming->max_snapshot_name_length, 'wide budget respected');

# Names that leave no room must fail loudly rather than produce a truncated
# name that collides with another volume's.
eval { $N->encode_state_name('a' x 24, 999999999, 'snap') };
my $tight = $@;
ok(!$tight || $tight =~ /no room/, 'tight budget either fits or dies with a clear message');

# ---------------------------------------------------------------------------
# Sanitizing and validation
# ---------------------------------------------------------------------------

is($N->sanitize('hello world'), 'hello_world', 'spaces become underscores');
is($N->sanitize('a//b'), 'a_b', 'runs of invalid characters collapse');
is($N->sanitize('---abc'), 'abc', 'leading separators removed');
is($N->sanitize('abc---'), 'abc', 'trailing separators removed');
is($N->sanitize('...'), 'pve', 'nothing left falls back to pve');
is($N->sanitize(undef), '', 'undef sanitizes to empty');
is($N->sanitize(''), '', 'empty sanitizes to empty');
unlike($N->sanitize('a.b.c'), qr/\./, 'dots never survive sanitizing');

ok($N->is_valid_volume_name('pve-ps1-100-disk0'), 'valid volume name');
ok(!$N->is_valid_volume_name('-leading-hyphen'), 'must start alphanumeric');
ok(!$N->is_valid_volume_name('has.dot'), 'dot invalid in volume name');
ok(!$N->is_valid_volume_name('x' x 200), 'too long');
ok(!$N->is_valid_volume_name(''), 'empty invalid');
ok(!$N->is_valid_volume_name(undef), 'undef invalid');

ok($N->is_valid_snapshot_name('pve-ps1-100-disk0.pve-snap-x'), 'valid snapshot name');
ok(!$N->is_valid_snapshot_name('.leading-dot'), 'snapshot must start alphanumeric');

# ---------------------------------------------------------------------------
# Anchors and vmids
#
# Perl's $ also matches immediately before a trailing newline, so a name with
# one attached would pass a pattern meant to be exact. And a run of digits
# longer than a vmid becomes a float the moment it is used as a number: '1e+30'
# would then travel inside a volid.
# ---------------------------------------------------------------------------

{
    is($N->decode_volume_name("pve-ps1-100-disk0\n"), undef,
        'a name with a trailing newline is not one of ours');
    is($N->decode_snapshot_name("pve-ps1-100-disk0.pve-snap-x\n"), undef,
        'and neither is a snapshot name with one');
    is($N->is_pve_managed_volume("pve-ps1-100-disk0\n", 'ps1'), 0,
        'so the ownership gate refuses it');

    is(eval { $N->pve_volname_to_array('ps1', "vm-100-disk-0\n") }, undef,
        'a PVE volume name with a trailing newline does not translate');

    is($N->decode_volume_name('pve-ps1-' . ('9' x 30) . '-disk0'), undef,
        'a vmid too long to be one is refused');
    is($N->decode_volume_name('pve-ps1-0-disk0'), undef,
        'and so is a vmid of zero');

    my $max = $N->decode_volume_name('pve-ps1-999999999-disk0');
    ok($max, 'the largest real vmid still decodes');
    is($max->{vmid}, 999999999, '... as an integer');
    ok($max->{vmid} !~ /e/i, '... not in scientific notation');
}

done_testing();
