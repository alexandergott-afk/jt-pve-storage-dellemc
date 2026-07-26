#!/usr/bin/perl
# A whole VM's life on PowerVault ME.
#
# This family's model is the odd one: a snapshot is a first-class volume that
# can be mapped and written to, so a linked clone is a snapshot given a
# volume-shaped name — and the array's namespace is shared between the two.
# Names are limited to 32 bytes and may not contain a dot.
#
# The fake array enforces what Dell's Administrator's Guide states: "You can
# delete a volume that has no child snapshots... To delete a volume with one
# or more snapshots, or a snapshot with child snapshots, you must delete the
# snapshots or child snapshots first."
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage::Plugin is not available (not a Proxmox VE node)';
}

use PVE::Storage::Custom::DellPowerVaultPlugin;
use PVE::Storage::Custom::DellEMC::PowerVault::Naming;

my $P = 'PVE::Storage::Custom::DellPowerVaultPlugin';
my $N = 'PVE::Storage::Custom::DellEMC::PowerVault::Naming';

# ---------------------------------------------------------------------------
# An array with ME's rules
# ---------------------------------------------------------------------------

my %OBJ;    # name => { size, parent, mapped => { host => lun } }
my $CLOCK;

sub reset_array { %OBJ = (); $CLOCK = 1_700_000_000; return }
sub names_on_array { return [ sort keys %OBJ ] }
sub children_of { my ($n) = @_; return [ sort grep { ($OBJ{$_}{parent} // '') eq $n } keys %OBJ ] }

{
    package Test::MeApi;

    sub new { return bless {}, shift }

    sub _row {
        my ($name) = @_;
        return {
            'volume-name'  => $name,
            'size-numeric' => $OBJ{$name}{size} / 512,
            'allocated-size-numeric' => 0,
            'wwn' => sprintf('600c0ff000%022x', length($name)),
            'creation-date-time-numeric' => $OBJ{$name}{ctime},
        };
    }

    sub volume_get_by_name {
        my ($self, $name) = @_;
        return $OBJ{$name} ? _row($name) : undef;
    }

    sub volume_list {
        my ($self, $pattern) = @_;
        my $prefix = $pattern;
        $prefix =~ s/\*$// if defined $prefix;
        return [ map { _row($_) }
                 grep { !defined $prefix || index($_, $prefix) == 0 }
                 sort keys %OBJ ];
    }

    sub volume_create {
        my ($self, $name, $size, %opts) = @_;

        # The array's own limits, which is the point of this fake.
        die "name '$name' is longer than 32 bytes\n" if length($name) > 32;
        die "a volume name may not contain a dot\n" if $name =~ /\./;
        die "the name '$name' is already in use\n" if $OBJ{$name};

        $OBJ{$name} = { size => $size, mapped => {}, ctime => $CLOCK++ };
        return $name;
    }

    sub volume_delete {
        my ($self, $name, %opts) = @_;
        return 1 unless $OBJ{$name};

        my $children = main::children_of($name);
        die "volume '$name' has child snapshots: @$children\n" if @$children;
        die "volume '$name' is still mapped\n" if keys %{ $OBJ{$name}{mapped} };

        delete $OBJ{$name};
        return 1;
    }

    sub volume_expand {
        my ($self, $name, $new_size, %opts) = @_;
        my $current = $opts{current_size} // $OBJ{$name}{size};
        return 0 if $new_size <= $current;
        $OBJ{$name}{size} = $new_size;
        return 1;
    }

    sub volume_rename {
        my ($self, $from, $to, %opts) = @_;
        $OBJ{$to} = delete $OBJ{$from};
        return 1;
    }

    sub volume_size { my ($self, $row) = @_; return ($row->{'size-numeric'} // 0) * 512 }
    sub volume_used { return 0 }
    sub volume_wwid {
        my ($self, $row) = @_;
        return '3' . ($row->{wwn} // '');
    }

    # A snapshot is a volume in the same namespace, with a parent.
    sub snapshot_create {
        my ($self, $source, $name, %opts) = @_;

        die "name '$name' is longer than 32 bytes\n" if length($name) > 32;
        die "the name '$name' is already in use\n" if $OBJ{$name};
        die "no such volume '$source'\n" unless $OBJ{$source};

        $OBJ{$name} = {
            size   => $OBJ{$source}{size},
            parent => $source,
            mapped => {},
            ctime  => $CLOCK++,
        };
        return $name;
    }

    sub snapshot_delete {
        my ($self, $name, %opts) = @_;
        return 1 unless $OBJ{$name};

        my $children = main::children_of($name);
        die "snapshot '$name' has child snapshots: @$children\n" if @$children;

        delete $OBJ{$name};
        return 1;
    }

    sub snapshot_list {
        my ($self, %opts) = @_;
        my $prefix = $opts{pattern};
        $prefix =~ s/\*$// if defined $prefix;

        my @out;
        for my $name (sort keys %OBJ) {
            next unless defined $OBJ{$name}{parent};
            next if defined $opts{volume} && $OBJ{$name}{parent} ne $opts{volume};
            next if defined $prefix && index($name, $prefix) != 0;
            push @out, _row($name);
        }
        return \@out;
    }

    sub snapshot_rollback { return 1 }

    sub volume_map {
        my ($self, $name, $host, %opts) = @_;
        die "no such volume '$name'\n" unless $OBJ{$name};
        $OBJ{$name}{mapped}{$host} = 1;
        return 1;
    }

    sub volume_unmap {
        my ($self, $name, $host, %opts) = @_;
        delete $OBJ{$name}{mapped}{$host} if $OBJ{$name};
        return 1;
    }

    sub is_mapped {
        my ($self, $name, $host, %opts) = @_;
        return $OBJ{$name}{mapped}{$host} ? 1 : 0;
    }

    # 'show maps' names an initiator, not a host, so the plugin asks about
    # several identities at once: the host name and this node's own initiator
    # ids. The fake maps by whichever one it was given.
    sub is_mapped_to_any {
        my ($self, $name, $identities, %opts) = @_;
        return 0 unless ref($identities) eq 'ARRAY';
        for my $id (@$identities) {
            next unless defined $id;
            return 1 if $OBJ{$name}{mapped}{$id};
        }
        return 0;
    }

    sub volume_mappings {
        my ($self, $name, %opts) = @_;
        return [ map { { host => $_ } } sort keys %{ $OBJ{$name}{mapped} // {} } ];
    }

    sub host_list { return [{ name => 'pve-pve-node1' }] }
    sub host_get_by_name { return { name => $_[1] } }
    sub system_get { return { 'system-name' => 'me5' } }
    sub get_managed_capacity { return (1000, 400, 600) }
    sub iscsi_portals { return [{ portal => '10.0.0.1:3260', iqn => 'iqn.me5' }] }
}

my $api = Test::MeApi->new;

no warnings 'redefine', 'once';
local *PVE::Storage::Custom::DellPowerVaultPlugin::_api = sub { $api };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::cleanup_lun_devices = sub { 1 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_device = sub { undef };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_slaves = sub { [] };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_block_device = sub { 0 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_device_in_use = sub { 0 };

my $scfg  = { 'dell-portal' => '10.0.0.5', 'dell-cluster-name' => 'pve' };
my $store = 'me5';

# ---------------------------------------------------------------------------

reset_array();

# 1. A disk. The array name has to be short, because this family has 32 bytes
#    for everything including the snapshot suffix.
my $disk = $P->alloc_image($store, $scfg, 100, 'raw', undef, 1024);
is($disk, 'vm-100-disk-0', 'the first disk is disk-0');
is_deeply(names_on_array(), ['pve-me5-100-d0'],
    'and the array name uses the compact form this family needs');
cmp_ok(length('pve-me5-100-d0'), '<=', 32, 'well inside the 32-byte limit');
unlike('pve-me5-100-d0', qr/\./, 'and with no dot, which a volume name may not have');

# 2. Snapshot. On this family the separator is '-s-', not a dot.
$P->volume_snapshot($scfg, $store, $disk, 'before');
my $snap = $N->encode_snapshot_name('pve-me5-100-d0', 'before');
is($snap, 'pve-me5-100-d0-s-before', 'the snapshot name uses the -s- separator');
ok($OBJ{$snap}, 'and exists on the array');
is($OBJ{$snap}{parent}, 'pve-me5-100-d0', 'as a child of the volume');

# The snapshot is a volume in the same namespace, but must not be listed as a
# VM disk.
my $images = $P->list_images($store, $scfg, 100);
is_deeply([map { $_->{volid} } @$images], ['me5:vm-100-disk-0'],
    'a snapshot is not listed as a disk, though it is a volume on the array');

# PVE sees the snapshot under the name it asked for.
my $snaps = $P->volume_snapshot_list($scfg, $store, $disk);
is_deeply([map { $_->{name} } @$snaps], ['before'], 'and the snapshot list is right');

# 3. The array refuses to delete a volume with a child snapshot, and the
#    plugin removes the child first rather than failing.
$P->free_image($store, $scfg, $disk, 0, 'raw');
is_deeply(names_on_array(), [],
    'deleting the disk removes its snapshot with it');

# ---------------------------------------------------------------------------
# A linked clone here is a snapshot wearing a volume name
# ---------------------------------------------------------------------------

reset_array();
$P->alloc_image($store, $scfg, 200, 'raw', undef, 1024);

my $base = $P->create_base($store, $scfg, 'vm-200-disk-0');
is($base, 'base-200-disk-0', 'the volume becomes a base image');

my $marker = $N->encode_base_snapshot_name('pve-me5-200-d0');
is($marker, 'pve-me5-200-d0-base', 'the template marker uses the -base suffix');
ok($OBJ{$marker}, 'and exists on the array');

my $clone = $P->clone_image($scfg, $store, $base, 201);
is($clone, 'base-200-disk-0/vm-201-disk-0', 'the clone carries its base');
ok($OBJ{'pve-me5-201-d0'}, 'and exists on the array');
is($OBJ{'pve-me5-201-d0'}{parent}, $marker,
    'as a child of the template marker — on this family a clone IS a snapshot');

# A clone has a volume-shaped name, so it must be listed as a disk even though
# the array considers it a snapshot.
$images = $P->list_images($store, $scfg, 201);
is(scalar(@$images), 1, 'the clone is listed as a disk');

# The template cannot go while the clone hangs off its marker.
ok(!eval { $P->free_image($store, $scfg, $base, 1, 'raw'); 1 },
    'deleting the template is refused while the clone exists');
ok($OBJ{'pve-me5-200-d0'}, 'and the template survives');
ok($OBJ{$marker}, 'still carrying its marker');

$P->free_image($store, $scfg, 'base-200-disk-0/vm-201-disk-0', 0, 'raw');
ok(!$OBJ{'pve-me5-201-d0'}, 'the clone is gone');

$P->free_image($store, $scfg, $base, 1, 'raw');
is_deeply(names_on_array(), [], 'and the template deletes cleanly after it');

# ---------------------------------------------------------------------------
# Names are the binding constraint
# ---------------------------------------------------------------------------

{
    reset_array();

    # A storage id that leaves no room must fail at creation with a message
    # about the storage id, not produce a truncated name that could collide
    # with another VM's volume.
    my $long = 'a-storage-id-that-is-far-too-long';

    my $name = eval { $N->encode_volume_name($long, 100, 0) };
    if (defined $name) {
        cmp_ok(length($name), '<=', 32, 'a generated name always fits');
    } else {
        like($@, qr/shorter storage id/, 'or the error names the storage id');
    }

    # And a snapshot of a volume whose name uses the whole budget.
    my $tight = $N->encode_volume_name('storeid10x', 999999, 99);
    cmp_ok(length($tight), '<=', 32, 'a long but legal name fits');

    my $tight_snap = eval { $N->encode_snapshot_name($tight, 'a-long-snapshot-name') };
    if (defined $tight_snap) {
        cmp_ok(length($tight_snap), '<=', 32, 'and so does its snapshot name');
        unlike($tight_snap, qr/\./, 'with no dot anywhere in it');
    } else {
        like($@, qr/no room|shorter storage id/, 'or it says there is no room');
    }
}

# ---------------------------------------------------------------------------
# Reading a snapshot, then deleting it
# ---------------------------------------------------------------------------

reset_array();
$P->alloc_image($store, $scfg, 300, 'raw', undef, 1024);
$P->volume_snapshot($scfg, $store, 'vm-300-disk-0', 'vzdump');

my ($temp) = $P->_prepare_snapshot_access($scfg, $store, 'vm-300-disk-0', 'vzdump');
ok($OBJ{$temp}, 'reading a snapshot creates a clone of it');
cmp_ok(length($temp), '<=', 32,
    'and the temporary name fits the array limit too');

$P->volume_snapshot_delete($scfg, $store, 'vm-300-disk-0', 'vzdump');
ok(!$OBJ{$temp}, 'deleting the snapshot removes that clone');
is_deeply(names_on_array(), ['pve-me5-300-d0'], 'leaving only the disk');

done_testing();
