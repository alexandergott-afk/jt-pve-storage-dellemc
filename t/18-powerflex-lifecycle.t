#!/usr/bin/perl
# A whole VM's life on PowerFlex.
#
# PowerFlex is not a BlockBase subclass — it has its own alloc, clone,
# snapshot and delete — so t/17 does not cover any of it. The array here
# behaves the way PowerFlex does: volumes are addressed by id, a snapshot is a
# volume in its own right with an ancestor, and removeVolume with ONLY_ME
# refuses a volume that still has descendants.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage::Plugin is not available (not a Proxmox VE node)';
}

use PVE::Storage::Custom::DellPowerFlexPlugin;
use PVE::Storage::Custom::DellEMC::PowerFlex::Naming;

my $P = 'PVE::Storage::Custom::DellPowerFlexPlugin';
my $N = 'PVE::Storage::Custom::DellEMC::PowerFlex::Naming';

# ---------------------------------------------------------------------------
# An array that behaves like PowerFlex
# ---------------------------------------------------------------------------

my %VOL;        # id => { name, size, ancestor, mapped => { host => 1 } }
my $NEXT_ID = 1;
my $CLOCK   = 1_700_000_000;
my @LOG;

sub reset_array { %VOL = (); $NEXT_ID = 1; $CLOCK = 1_700_000_000; @LOG = (); return }

sub by_name {
    my ($name) = @_;
    my ($id) = grep { $VOL{$_}{name} eq $name } sort keys %VOL;
    return $id;
}

sub names_on_array { return [ sort map { $_->{name} } values %VOL ] }

{
    package Test::PflexApi;

    sub new { return bless {}, shift }

    sub volume_list {
        my ($self) = @_;
        return [ map { {
            id           => $_,
            name         => $VOL{$_}{name},
            sizeInKb     => $VOL{$_}{size} / 1024,
            creationTime => $VOL{$_}{ctime},
            ancestorVolumeId => $VOL{$_}{ancestor},
        } } sort keys %VOL ];
    }

    sub volume_size { my ($self, $row) = @_; return ($row->{sizeInKb} // 0) * 1024 }

    sub volume_id_by_name {
        my ($self, $name) = @_;
        return main::by_name($name);
    }

    sub volume_get_by_name {
        my ($self, $name) = @_;
        my $id = main::by_name($name) or return undef;
        return { id => $id, name => $name, sizeInKb => $VOL{$id}{size} / 1024 };
    }

    sub volume_get {
        my ($self, $id) = @_;
        return undef unless $VOL{$id};
        return { id => $id, name => $VOL{$id}{name},
                 mappedSdcInfo => [ map { { sdcId => $_ } }
                                    sort keys %{ $VOL{$id}{mapped} } ] };
    }

    sub volume_create {
        my ($self, $name, $size, %opts) = @_;
        push @LOG, "create $name";
        die "a volume named '$name' already exists\n" if main::by_name($name);
        my $id = 'v' . $NEXT_ID++;
        $VOL{$id} = { name => $name, size => $size, mapped => {},
                      ctime => $CLOCK++ };
        return $id;
    }

    sub volume_delete {
        my ($self, $id, %opts) = @_;
        push @LOG, "delete " . ($VOL{$id}{name} // $id);
        return 1 unless $VOL{$id};

        die "volume is still mapped\n" if keys %{ $VOL{$id}{mapped} };

        my @descendants = grep { ($VOL{$_}{ancestor} // '') eq $id } keys %VOL;
        die "volume has descendants: @descendants\n" if @descendants;

        delete $VOL{$id};
        return 1;
    }

    sub volume_resize {
        my ($self, $id, $size, %opts) = @_;
        push @LOG, "resize";
        $VOL{$id}{size} = $size;
        return 1;
    }

    sub volume_rename {
        my ($self, $id, $name, %opts) = @_;
        $VOL{$id}{name} = $name;
        return 1;
    }

    sub snapshot_create {
        my ($self, $volume_id, $name, %opts) = @_;
        push @LOG, "snapshot $name";
        die "a volume named '$name' already exists\n" if main::by_name($name);
        my $id = 'v' . $NEXT_ID++;
        $VOL{$id} = { name => $name, size => $VOL{$volume_id}{size},
                      ancestor => $volume_id, mapped => {}, ctime => $CLOCK++ };
        return $id;
    }

    sub snapshot_rollback {
        my ($self, $volume_id, $snap_id, %opts) = @_;
        push @LOG, "rollback";
        return 1;
    }

    sub volume_map {
        my ($self, $id, $host, %opts) = @_;
        die "no such volume\n" unless $VOL{$id};
        $VOL{$id}{mapped}{$host} = 1;
        return 1;
    }

    sub volume_unmap {
        my ($self, $id, $host, %opts) = @_;
        delete $VOL{$id}{mapped}{$host} if $VOL{$id};
        return 1;
    }

    sub is_mapped {
        my ($self, $id, $host, %opts) = @_;
        return $VOL{$id}{mapped}{$host} ? 1 : 0;
    }

    sub volume_mapped_hosts {
        my ($self, $volume, %opts) = @_;
        my $id = ref($volume) eq 'HASH' ? $volume->{id} : $volume;
        return [ sort keys %{ $VOL{$id}{mapped} // {} } ];
    }

    sub storage_pool_by_name { return { id => 'pool1', name => 'pool1' } }
}

my $api = Test::PflexApi->new;

no warnings 'redefine', 'once';
local *PVE::Storage::Custom::DellPowerFlexPlugin::_api = sub { $api };
local *PVE::Storage::Custom::DellPowerFlexPlugin::_host_id = sub { 'sdc-1' };
local *PVE::Storage::Custom::DellPowerFlexPlugin::_storage_pool =
    sub { { id => 'pool1', name => 'pool1' } };

my $scfg = {
    'dell-portal'        => '10.0.0.5',
    'pflex-storage-pool' => 'pool1',
};
my $store = 'pf1';

# ---------------------------------------------------------------------------

reset_array();

# 0. PVE wants (total, available, used, active) and the array reports
#    (total, used, available). Getting the order wrong is invisible except as
#    wrong numbers in the GUI.
{
    no warnings 'redefine';
    local *Test::PflexApi::get_managed_capacity = sub { return (1000, 400, 600) };

    my ($total, $avail, $used, $active) = $P->status($store, $scfg);

    is($total,  1000, 'status reports the total first');
    is($avail,   600, '... then what is available');
    is($used,    400, '... then what is used');
    is($active,    1, '... then whether the storage is usable');
}

# 1. A disk, mapped to this node.
my $disk = $P->alloc_image($store, $scfg, 100, 'raw', undef, 8 * 1024 * 1024);
is($disk, 'vm-100-disk-0', 'the first disk is disk-0');
is_deeply(names_on_array(), ['pve-pf1-100-d0'],
    'and exists on the array under the short name this family needs');

my $id = by_name('pve-pf1-100-d0');
ok($VOL{$id}{mapped}{'sdc-1'}, 'mapped to this node');

# 2. A second disk.
my $disk2 = $P->alloc_image($store, $scfg, 100, 'raw', undef, 1024);
is($disk2, 'vm-100-disk-1', 'the second disk is disk-1');

# 3. Both listed.
my $images = $P->list_images($store, $scfg, 100);
is_deeply([sort map { $_->{volid} } @$images],
    ['pf1:vm-100-disk-0', 'pf1:vm-100-disk-1'], 'both disks are listed');

# 4. Snapshot, and its name is within the family's 31-character limit.
$P->volume_snapshot($scfg, $store, $disk, 'before');
my $snap_name = $N->encode_snapshot_name('pve-pf1-100-d0', 'before');
cmp_ok(length($snap_name), '<=', 31, 'the snapshot name fits the array limit');
ok(by_name($snap_name), 'and the snapshot exists on the array');

my $snaps = $P->volume_snapshot_list($scfg, $store, $disk);
is_deeply([map { $_->{name} } @$snaps], ['before'],
    'PVE sees it under the name it asked for');
cmp_ok($snaps->[0]{ctime}, '>', 0, 'with a real timestamp, not 1970');

# 5. The disk cannot be deleted while the snapshot hangs off it — and the
#    plugin removes the snapshot itself rather than failing.
$P->free_image($store, $scfg, $disk, 0, 'raw');
ok(!by_name('pve-pf1-100-d0'), 'the disk is gone');
ok(!by_name($snap_name), 'and so is its snapshot');

# ---------------------------------------------------------------------------
# Templates and linked clones
# ---------------------------------------------------------------------------

reset_array();
$P->alloc_image($store, $scfg, 200, 'raw', undef, 1024);

my $base = $P->create_base($store, $scfg, 'vm-200-disk-0');
is($base, 'base-200-disk-0', 'the volume becomes a base image');

my $marker = $N->encode_base_snapshot_name('pve-pf1-200-d0');
ok(by_name($marker), 'the template marker exists on the array');
cmp_ok(length($marker), '<=', 31, 'and fits the name limit');

my $clone = $P->clone_image($scfg, $store, $base, 201);
is($clone, 'base-200-disk-0/vm-201-disk-0',
    'a linked clone carries its base in the volid');
ok(by_name('pve-pf1-201-d0'), 'and exists on the array');

is($VOL{by_name('pve-pf1-201-d0')}{ancestor}, by_name($marker),
    'cloned from the template marker');

# list_images reports the clone under the volid PVE stored.
$images = $P->list_images($store, $scfg);
my ($clone_row) = grep { $_->{volid} =~ /201/ } @$images;
is($clone_row->{volid}, 'pf1:base-200-disk-0/vm-201-disk-0',
    'and is listed under that same volid');

# The template cannot go while the clone depends on it.
ok(!eval { $P->free_image($store, $scfg, $base, 1, 'raw'); 1 },
    'deleting the template is refused while the clone exists');
ok(by_name('pve-pf1-200-d0'), 'and the template survives');
ok(by_name($marker), 'still carrying its marker');

# Clone first, then template.
$P->free_image($store, $scfg, 'base-200-disk-0/vm-201-disk-0', 0, 'raw');
ok(!by_name('pve-pf1-201-d0'), 'the clone is gone');

$P->free_image($store, $scfg, $base, 1, 'raw');
is_deeply(names_on_array(), [], 'and the template deletes cleanly after it');

# ---------------------------------------------------------------------------
# Rollback safety
# ---------------------------------------------------------------------------

reset_array();
$P->alloc_image($store, $scfg, 300, 'raw', undef, 1024);
$P->volume_snapshot($scfg, $store, 'vm-300-disk-0', 'first');
$P->volume_snapshot($scfg, $store, 'vm-300-disk-0', 'second');

my $blockers = [];
ok(!eval { $P->volume_rollback_is_possible($scfg, $store, 'vm-300-disk-0',
        'first', $blockers) },
    'rolling back past a newer snapshot is refused on this family too');
is_deeply($blockers, ['second'], '... naming what is in the way');

ok($P->volume_rollback_is_possible($scfg, $store, 'vm-300-disk-0', 'second', []),
    'and the newest one is allowed');

# ---------------------------------------------------------------------------
# A resize is a grow, never a shrink
# ---------------------------------------------------------------------------

{
    my $gib = 1024 ** 3;
    reset_array();
    $P->alloc_image($store, $scfg, 400, 'raw', undef, 8 * 1024 * 1024);

    $P->volume_resize($scfg, $store, 'vm-400-disk-0', 16 * $gib);
    is($VOL{by_name('pve-pf1-400-d0')}{size}, 16 * $gib, 'the array grew it');

    ok(!eval { $P->volume_resize($scfg, $store, 'vm-400-disk-0', 1024); 1 },
        'shrinking is refused');

    ok(!eval { $P->volume_resize($scfg, $store, 'vm-400-disk-0', 32 * $gib,
            0, 'snapname'); 1 },
        'and resizing a snapshot is refused rather than resizing the volume');
}

# ---------------------------------------------------------------------------
# PowerFlex does not inherit BlockBase, so every guard the SAN families get
# has to exist here too. It did not, which is the point of these.
# ---------------------------------------------------------------------------

{
    # A delete must refuse when the in-use state cannot be established. This
    # path unmaps before it deletes, so a wrong "free" takes the disk from a
    # guest that is still writing to it.
    reset_array();
    $P->alloc_image($store, $scfg, 900, 'raw', undef, 1024);

    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellPowerFlexPlugin::_device_lookup =
        sub { sub { '/dev/nvme0n42' } };
    local *PVE::Storage::Custom::DellPowerFlexPlugin::is_block_device =
        sub { 1 };
    local *PVE::Storage::Custom::DellPowerFlexPlugin::is_device_in_use =
        sub { undef };

    ok(!eval { $P->free_image($store, $scfg, 'vm-900-disk-0', 0, 'raw'); 1 },
        'a delete refuses when in-use cannot be established');
    like($@ // '', qr/could not be determined/, 'and says so');
    ok(by_name('pve-pf1-900-d0'), 'the volume is untouched');
}

{
    # And refuses outright when something is using it.
    reset_array();
    $P->alloc_image($store, $scfg, 901, 'raw', undef, 1024);

    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellPowerFlexPlugin::_device_lookup =
        sub { sub { '/dev/nvme0n43' } };
    local *PVE::Storage::Custom::DellPowerFlexPlugin::is_block_device =
        sub { 1 };
    local *PVE::Storage::Custom::DellPowerFlexPlugin::is_device_in_use =
        sub { 1 };

    ok(!eval { $P->free_image($store, $scfg, 'vm-901-disk-0', 0, 'raw'); 1 },
        'a delete refuses while the device is in use');
    like($@ // '', qr/still in use/, 'naming the reason');
    ok(by_name('pve-pf1-901-d0'), 'and the volume survives');
}

{
    # A rollback overwrites the whole volume; the damage is not visible until
    # the guest next reads.
    reset_array();
    $P->alloc_image($store, $scfg, 902, 'raw', undef, 1024);
    $P->volume_snapshot($scfg, $store, 'vm-902-disk-0', 'before');

    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellPowerFlexPlugin::_device_lookup =
        sub { sub { '/dev/nvme0n44' } };
    local *PVE::Storage::Custom::DellPowerFlexPlugin::is_block_device =
        sub { 1 };
    local *PVE::Storage::Custom::DellPowerFlexPlugin::is_device_in_use =
        sub { undef };

    ok(!eval { $P->volume_snapshot_rollback($scfg, $store, 'vm-902-disk-0',
            'before'); 1 },
        'a rollback refuses when in-use cannot be established');
    like($@ // '', qr/could not be determined/, 'and says so');
}

{
    # The ownership gate refuses a name this storage did not generate.
    reset_array();
    ok(!eval { $P->_assert_own_object('pf1', 'someone-elses-volume',
            'delete volume'); 1 },
        'the ownership gate refuses a foreign name');
    like($@ // '', qr/not an object storage/, 'and says whose it is not');

    ok(eval { $P->_assert_own_object('pf1', 'pve-pf1-100-d0',
            'delete volume'); 1 },
        'and accepts one of this storage\'s own');
}

done_testing();
