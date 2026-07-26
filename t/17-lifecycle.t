#!/usr/bin/perl
# A whole VM's life, against an array that keeps score.
#
# The other files test one method at a time. This one walks the sequence an
# operator actually performs on day one — create a disk, snapshot it, roll
# back, make a template, take a linked clone, resize, delete — and after every
# step asks the same two questions: does the array hold exactly what it should,
# and has anything been left behind.
#
# The fake array enforces the rules the real ones do, which is where the value
# is: it refuses to delete a volume that still has snapshots, refuses to delete
# a snapshot something was cloned from, and refuses to create a name that
# already exists. Those are the refusals that turned into the defects fixed in
# 0.7.2 and 0.7.4.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage::Plugin is not available (not a Proxmox VE node)';
}

use PVE::Storage::Custom::DellEMC::Common::BlockBase;

my $TMP = tempdir(CLEANUP => 1);

# ---------------------------------------------------------------------------
# An array that says no when a real one would
# ---------------------------------------------------------------------------

{
    package Test::Array;
    use base 'PVE::Storage::Custom::DellEMC::Common::BlockBase';

    our %VOL;      # name => { size, snapshots => { name => ctime }, parent }
    our %MAP;      # name => { host => 1 }
    our @LOG;
    our $CLOCK;    # snapshots taken later have later timestamps

    sub reset_array { %VOL = (); %MAP = (); @LOG = (); $CLOCK = 1000; return }
    sub log_of { return \@LOG }

    sub type { 'delltest' }
    sub multipath_vendor  { 'DellEMC' }
    sub multipath_product { 'TestArray' }
    sub multipath_defaults { { no_path_retry => 30 } }

    sub _note { push @LOG, join(' ', @_[1 .. $#_]); return 1 }

    sub _array_ping { 1 }
    sub _array_get_capacity { return (1000, 400, 600) }
    sub _array_get_portals { [{ portal => '10.0.0.1:3260', iqn => 'iqn.test' }] }
    sub _array_get_wwid { return undef }   # keeps the device layer out of this
    sub _array_ensure_host { 'pve-test-node1' }
    sub _array_list_hosts { [{ name => 'pve-test-node1' }] }

    sub _array_get_volume {
        my ($class, $scfg, $name) = @_;
        return undef unless $VOL{$name};
        return { name => $name, size => $VOL{$name}{size}, used => 0 };
    }

    sub _array_list_volumes {
        my ($class, $scfg, $storeid, $prefix) = @_;
        my @out;
        for my $name (sort keys %VOL) {
            next if defined $prefix && index($name, $prefix) != 0;
            push @out, { name => $name, size => $VOL{$name}{size}, used => 0 };
        }
        return \@out;
    }

    sub _array_create_volume {
        my ($class, $scfg, $storeid, $name, $size) = @_;
        $class->_note('create', $name);
        die "a volume named '$name' already exists\n" if $VOL{$name};
        $VOL{$name} = { size => $size, snapshots => {} };
        return $name;
    }

    sub _array_delete_volume {
        my ($class, $scfg, $storeid, $name) = @_;
        $class->_note('delete', $name);
        return 1 unless $VOL{$name};

        # What a real array refuses.
        die "volume '$name' still has snapshots\n"
            if keys %{ $VOL{$name}{snapshots} };
        die "volume '$name' is still mapped\n" if keys %{ $MAP{$name} // {} };

        my @children = grep { ($VOL{$_}{parent} // '') eq $name } keys %VOL;
        die "volume '$name' has dependent clones: @children\n" if @children;

        delete $VOL{$name};
        return 1;
    }

    sub _array_resize_volume {
        my ($class, $scfg, $storeid, $name, $size) = @_;
        $class->_note('resize', $name, $size);
        die "no such volume '$name'\n" unless $VOL{$name};
        $VOL{$name}{size} = $size;
        return 1;
    }

    sub _array_rename_volume {
        my ($class, $scfg, $storeid, $from, $to) = @_;
        $class->_note('rename', $from, $to);
        $VOL{$to} = delete $VOL{$from};
        return 1;
    }

    # A snapshot is an object of its own, as it is on all three families.
    sub _array_snapshot_create {
        my ($class, $scfg, $storeid, $volume, $snap) = @_;
        $class->_note('snapshot_create', $snap);
        die "no such volume '$volume'\n" unless $VOL{$volume};
        die "a snapshot named '$snap' already exists\n" if $VOL{$volume}{snapshots}{$snap};
        $VOL{$volume}{snapshots}{$snap} = ++$CLOCK;
        return 1;
    }

    sub _array_snapshot_get {
        my ($class, $scfg, $storeid, $snap) = @_;
        for my $volume (keys %VOL) {
            return { name => $snap, ctime => $VOL{$volume}{snapshots}{$snap} }
                if $VOL{$volume}{snapshots}{$snap};
        }
        return undef;
    }

    sub _array_snapshot_delete {
        my ($class, $scfg, $storeid, $snap) = @_;
        $class->_note('snapshot_delete', $snap);

        my @clones = grep { ($VOL{$_}{parent} // '') eq $snap } keys %VOL;
        die "snapshot '$snap' has dependent clones: @clones\n" if @clones;

        delete $VOL{$_}{snapshots}{$snap} for keys %VOL;
        return 1;
    }

    sub _array_snapshot_list {
        my ($class, $scfg, $storeid, $volume, $prefix) = @_;
        my @out;
        for my $name (sort keys %VOL) {
            next if defined $volume && $name ne $volume;
            for my $snap (sort keys %{ $VOL{$name}{snapshots} }) {
                next if defined $prefix && index($snap, $prefix) != 0;
                push @out, { name => $snap, ctime => $VOL{$name}{snapshots}{$snap} };
            }
        }
        return \@out;
    }

    sub _array_snapshot_rollback {
        my ($class, $scfg, $storeid, $volume, $snap) = @_;
        $class->_note('rollback', $volume, $snap);
        die "no such snapshot '$snap'\n" unless $VOL{$volume}{snapshots}{$snap};
        return 1;
    }

    sub _array_clone {
        my ($class, $scfg, $storeid, $source, $target) = @_;
        $class->_note('clone', $source, $target);
        die "a volume named '$target' already exists\n" if $VOL{$target};
        $VOL{$target} = { size => 1024, snapshots => {}, parent => $source };
        $CLOCK++;
        return $target;
    }

    sub _array_map_to_host {
        my ($class, $scfg, $name, $host) = @_;
        $class->_note('map', $name, $host);
        die "no such volume '$name'\n" unless $VOL{$name};
        $MAP{$name}{$host} = 1;
        return 1;
    }

    sub _array_unmap_from_host {
        my ($class, $scfg, $name, $host) = @_;
        $class->_note('unmap', $name, $host);
        delete $MAP{$name}{$host};
        return 1;
    }

    sub _array_is_mapped {
        my ($class, $scfg, $name, $host) = @_;
        return $MAP{$name}{$host} ? 1 : 0;
    }

    sub _array_mapped_hosts {
        my ($class, $scfg, $name) = @_;
        return [ sort keys %{ $MAP{$name} // {} } ];
    }
}

# Nothing in this file may touch a device.
no warnings 'redefine', 'once';
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::cleanup_lun_devices = sub { 1 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_device = sub { undef };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_slaves = sub { [] };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_block_device = sub { 0 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_device_in_use = sub { 0 };
local *PVE::Storage::Custom::DellEMC::Common::WwidState::state_dir = sub { $TMP };
local *PVE::Storage::Custom::DellEMC::Common::WwidState::lock_dir  = sub { $TMP };

my $A = 'Test::Array';
my $scfg = { 'dell-portal' => '10.0.0.1' };
my $store = 'ps1';

sub volumes_on_array {
    return [ sort keys %Test::Array::VOL ];
}

sub snapshots_of {
    my ($name) = @_;
    return [ sort keys %{ $Test::Array::VOL{$name}{snapshots} // {} } ];
}

# ---------------------------------------------------------------------------
# Day one
# ---------------------------------------------------------------------------

$A->reset_array();

# 1. Create a disk for VM 100.
#
# PVE passes alloc_image a size in KiB and volume_resize a size in BYTES.
# Mixing them up turns a grow into a shrink, so the two units are spelled out
# here rather than left to the reader.
my $GIB = 1024 ** 3;

my $disk = $A->alloc_image($store, $scfg, 100, 'raw', undef, 8 * 1024 * 1024);
is($disk, 'vm-100-disk-0', 'the first disk of a VM is disk-0');
is_deeply(volumes_on_array(), ['pve-ps1-100-disk0'],
    'and one volume exists on the array');
ok($Test::Array::MAP{'pve-ps1-100-disk0'}{'pve-test-node1'},
    'mapped to this node so the VM can start');

# 2. A second disk gets the next id.
my $disk2 = $A->alloc_image($store, $scfg, 100, 'raw', undef, 1024);
is($disk2, 'vm-100-disk-1', 'the second disk of the same VM is disk-1');

# 3. Both show up in the disk list, with their sizes.
my $images = $A->list_images($store, $scfg, 100);
is(scalar(@$images), 2, 'both disks are listed for the VM');
is_deeply([sort map { $_->{volid} } @$images],
    ['ps1:vm-100-disk-0', 'ps1:vm-100-disk-1'],
    'under the volids PVE will use');

# 4. Resize the first one. 8 GiB was allocated (8 * 1024 * 1024 KiB).
is($Test::Array::VOL{'pve-ps1-100-disk0'}{size}, 8 * $GIB,
    'a size in KiB reached the array as the same size in bytes');

$A->volume_resize($scfg, $store, $disk, 16 * $GIB);
is($Test::Array::VOL{'pve-ps1-100-disk0'}{size}, 16 * $GIB,
    'the array has the new size');

my ($size) = $A->volume_size_info($scfg, $store, $disk);
is($size, 16 * $GIB, 'and reports it back');

# Shrinking is refused rather than truncating a guest filesystem.
ok(!eval { $A->volume_resize($scfg, $store, $disk, 1024); 1 },
    'shrinking is refused');
like($@, qr/[Ss]hrink/, '... saying so');

# 5. Snapshot it.
$A->volume_snapshot($scfg, $store, $disk, 'before-change');
is_deeply(snapshots_of('pve-ps1-100-disk0'), ['pve-ps1-100-disk0.pve-snap-before-change'],
    'the snapshot is on the array under its encoded name');

my $snaps = $A->volume_snapshot_list($scfg, $store, $disk);
is_deeply([map { $_->{name} } @$snaps], ['before-change'],
    'and PVE sees it under the name it asked for');

# The same name twice is refused, not silently ignored.
ok(!eval { $A->volume_snapshot($scfg, $store, $disk, 'before-change'); 1 },
    'the same snapshot name twice is refused');

# 6. Roll back to it.
$A->volume_snapshot_rollback($scfg, $store, $disk, 'before-change');
ok(grep({ /^rollback / } @{ $A->log_of }), 'the rollback reached the array');

# 7. Take a second snapshot, then try to roll back to the first.
$A->volume_snapshot($scfg, $store, $disk, 'later');

my $blockers = [];
ok(!eval { $A->volume_rollback_is_possible($scfg, $store, $disk, 'before-change', $blockers) },
    'rolling back past a newer snapshot is refused');
is_deeply($blockers, ['later'], '... naming what is in the way');

# The newest one is fine.
ok($A->volume_rollback_is_possible($scfg, $store, $disk, 'later', []),
    'rolling back to the newest snapshot is allowed');

# 8. Delete the newer snapshot again.
$A->volume_snapshot_delete($scfg, $store, $disk, 'later');
is_deeply(snapshots_of('pve-ps1-100-disk0'),
    ['pve-ps1-100-disk0.pve-snap-before-change'],
    'only the older snapshot is left');

# ---------------------------------------------------------------------------
# Templates and linked clones
# ---------------------------------------------------------------------------

# 9. Turn the disk into a template.
my $base = $A->create_base($store, $scfg, $disk);
is($base, 'base-100-disk-0', 'the volume becomes a base image');
ok($Test::Array::VOL{'pve-ps1-100-disk0'}{snapshots}{'pve-ps1-100-disk0.pve-base'},
    'and carries the template marker on the array');

# 10. list_images now reports it as a base.
$images = $A->list_images($store, $scfg, 100);
my ($base_row) = grep { $_->{volid} =~ /base-100-disk-0/ } @$images;
ok($base_row, 'the template is listed as a base image');

# 11. Clone it for VM 101.
my $clone = $A->clone_image($scfg, $store, $base, 101);
is($clone, 'base-100-disk-0/vm-101-disk-0',
    'a linked clone carries its base in the volid, as PVE stores it');
ok($Test::Array::VOL{'pve-ps1-101-disk0'}, 'and the clone exists on the array');
is($Test::Array::VOL{'pve-ps1-101-disk0'}{parent}, 'pve-ps1-100-disk0.pve-base',
    'cloned from the template marker, not from the live volume');

# 12. The template cannot be deleted while the clone depends on it.
ok(!eval { $A->free_image($store, $scfg, $base, 1, 'raw'); 1 },
    'deleting a template with a linked clone is refused');
like($@, qr/dependent|clone/i, '... explaining why');
ok($Test::Array::VOL{'pve-ps1-100-disk0'}, 'and the template survives');
ok($Test::Array::VOL{'pve-ps1-100-disk0'}{snapshots}{'pve-ps1-100-disk0.pve-base'},
    'still carrying its marker, so PVE still sees a template');

# 13. Delete the clone, then the template.
$A->free_image($store, $scfg, 'base-100-disk-0/vm-101-disk-0', 0, 'raw');
ok(!$Test::Array::VOL{'pve-ps1-101-disk0'}, 'the clone is gone');

$A->free_image($store, $scfg, $base, 1, 'raw');
ok(!$Test::Array::VOL{'pve-ps1-100-disk0'},
    'and now the template can be deleted, marker and snapshot with it');

# ---------------------------------------------------------------------------
# What PVE does when a VM is destroyed
# ---------------------------------------------------------------------------

$A->reset_array();

# A VM with two disks, one of which has two snapshots. PVE deletes the disks
# and never touches the snapshots.
$A->alloc_image($store, $scfg, 200, 'raw', undef, 1024);
$A->alloc_image($store, $scfg, 200, 'raw', undef, 1024);
$A->volume_snapshot($scfg, $store, 'vm-200-disk-0', 'one');
$A->volume_snapshot($scfg, $store, 'vm-200-disk-0', 'two');

$A->free_image($store, $scfg, 'vm-200-disk-0', 0, 'raw');
$A->free_image($store, $scfg, 'vm-200-disk-1', 0, 'raw');

is_deeply(volumes_on_array(), [],
    'destroying a VM with snapshots leaves nothing on the array');

# ---------------------------------------------------------------------------
# Reading a snapshot, and deleting it afterwards
# ---------------------------------------------------------------------------

$A->reset_array();
$A->alloc_image($store, $scfg, 300, 'raw', undef, 1024);
$A->volume_snapshot($scfg, $store, 'vm-300-disk-0', 'vzdump');

# path() with a snapshot name makes a clone of the snapshot to read through.
my ($temp) = $A->_prepare_snapshot_access($scfg, $store, 'vm-300-disk-0', 'vzdump');
ok($Test::Array::VOL{$temp}, 'reading a snapshot creates a clone of it');

# vzdump deletes the snapshot the moment the backup finishes.
$A->volume_snapshot_delete($scfg, $store, 'vm-300-disk-0', 'vzdump');

ok(!$Test::Array::VOL{$temp}, 'the clone is removed with it');
is_deeply(snapshots_of('pve-ps1-300-disk0'), [],
    'and the snapshot is gone');
is_deeply(volumes_on_array(), ['pve-ps1-300-disk0'],
    'leaving only the disk itself');

# And the disk still deletes cleanly afterwards.
$A->free_image($store, $scfg, 'vm-300-disk-0', 0, 'raw');
is_deeply(volumes_on_array(), [], 'which then deletes cleanly');

# ---------------------------------------------------------------------------
# Nothing is left mapped
# ---------------------------------------------------------------------------

{
    my @still_mapped = grep { keys %{ $Test::Array::MAP{$_} } }
        keys %Test::Array::MAP;

    is_deeply([sort @still_mapped], [],
        'no volume is left mapped to a host after all of that');
}

done_testing();
