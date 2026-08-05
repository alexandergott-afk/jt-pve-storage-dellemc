#!/usr/bin/perl
# A whole VM's life on Unity, against a fake array that refuses what a real
# one refuses.
#
# The value of this file is in the refusals, not the successes. On PowerVault
# the same shape caught three defects that had shipped — deleting a volume
# left its snapshots behind, the vzdump snapshot-mode path could not work,
# and a failed delete blamed the wrong object — and every one of them was a
# case where the array says no and the plugin had not been written to expect
# it.
#
# So this fake enforces, at minimum:
#
#   - a LUN with snapshots cannot be deleted until they are gone
#   - a snapshot with a thin clone reading from it cannot be deleted
#   - a LUN that is still mapped to a host cannot be deleted
#   - hostAccess REPLACES the host list, so a plugin that sends one host
#     silently unmaps every other node — and this fake records that faithfully
#   - a name longer than 63 characters is refused
#   - a name that already exists is refused
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage::Plugin is not available (not a Proxmox VE node)';
}

use PVE::Storage::Custom::DellUnityPlugin;

my $P = 'PVE::Storage::Custom::DellUnityPlugin';

# ---------------------------------------------------------------------------
# The fake array
# ---------------------------------------------------------------------------

our %LUN;      # name => { id, size, hosts => {id=>1}, wwn }
our %SNAP;     # name => { id, resource, clones => {name=>1} }
our $NEXT_ID = 0;

sub reset_array {
    %LUN = ();
    %SNAP = ();
    $NEXT_ID = 0;
}

sub next_id { return 'sv_' . ++$NEXT_ID }

sub lun_by_id {
    my ($id) = @_;
    for my $name (keys %LUN) {
        return $name if $LUN{$name}{id} eq $id;
    }
    return undef;
}

{
    package Test::UnityApi;

    sub new { return bless {}, shift }

    sub _die { my (undef, $why) = @_; die "[dellunity] $why\n" }

    # -- pools ------------------------------------------------------------
    sub pool_list { return [ { id => 'pool_1', name => 'A',
                               sizeTotal => 10**13, sizeFree => 9 * 10**12 } ] }
    sub pool_get_by_name {
        my ($self, $name) = @_;
        return $name eq 'A' ? $self->pool_list->[0] : undef;
    }
    sub get_managed_capacity { return (10**13, 10**12, 9 * 10**12) }

    # -- volumes ----------------------------------------------------------
    sub volume_get_by_name {
        my ($self, $name) = @_;
        return undef unless defined $name && length $name;
        my $row = $LUN{$name} or return undef;
        return { id => $row->{id}, name => $name, wwn => $row->{wwn},
                 sizeTotal => $row->{size}, sizeAllocated => 0,
                 hostAccess => [ map { { host => { id => $_ }, accessMask => '1' } }
                                 sort keys %{ $row->{hosts} } ] };
    }

    sub volume_list {
        my ($self) = @_;
        return [ map { $self->volume_get_by_name($_) } sort keys %LUN ];
    }

    sub volume_create {
        my ($self, $name, $size, %opts) = @_;

        $self->_die("lun name $name should not exceed 63 characters")
            if length($name) > 63;
        $self->_die("the name $name is already in use") if $LUN{$name};

        $LUN{$name} = {
            id    => main::next_id(),
            size  => $size,
            hosts => {},
            wwn   => sprintf('60:06:01:60:%028X', $NEXT_ID) =~ s/(..)(?=.)/$1:/gr,
        };
        # A believable WWN: 32 hex digits.
        $LUN{$name}{wwn} = sprintf('600601601234567800000000%08X', $NEXT_ID);

        return $LUN{$name}{id};
    }

    sub volume_delete {
        my ($self, $id) = @_;
        my $name = main::lun_by_id($id) or return 1;

        # A real array refuses each of these.
        my @snaps = grep { $SNAP{$_}{resource} eq $id } keys %SNAP;
        $self->_die("The LUN cannot be deleted because it has snapshots")
            if @snaps;

        $self->_die("The LUN cannot be deleted because it is still mapped")
            if %{ $LUN{$name}{hosts} };

        delete $LUN{$name};

        # Deleting a thin clone releases the snapshot it read from, which is
        # what makes the template deletable again.
        delete $SNAP{$_}{clones}{$name} for keys %SNAP;

        return 1;
    }

    sub volume_resize {
        my ($self, $id, $size) = @_;
        my $name = main::lun_by_id($id) or $self->_die("no such LUN");
        $self->_die("a LUN cannot be shrunk") if $size < $LUN{$name}{size};
        $LUN{$name}{size} = $size;
        return $size;
    }

    sub volume_rename {
        my ($self, $id, $to) = @_;
        my $from = main::lun_by_id($id) or $self->_die("no such LUN");
        $self->_die("the name $to is already in use") if $LUN{$to};
        $LUN{$to} = delete $LUN{$from};
        return 1;
    }

    sub wwn_to_wwid {
        my ($self, $wwn) = @_;
        return PVE::Storage::Custom::DellEMC::Unity::API->wwn_to_wwid($wwn);
    }
    sub volume_get_wwid {
        my ($self, $name) = @_;
        return undef unless defined $name && length $name;
        my $row = $LUN{$name} or return undef;
        return $self->wwn_to_wwid($row->{wwn});
    }

    # -- snapshots --------------------------------------------------------
    sub snapshot_create {
        my ($self, $resource_id, $name) = @_;
        $self->_die("the name $name is already in use") if $SNAP{$name};
        $SNAP{$name} = { id => main::next_id(), resource => $resource_id,
                         clones => {} };
        return $SNAP{$name}{id};
    }

    sub snapshot_get_by_name {
        my ($self, $name) = @_;
        my $row = $SNAP{$name} or return undef;
        return { id => $row->{id}, name => $name, size => 0,
                 storageResource => { id => $row->{resource} },
                 creationTime => '2026-08-05T10:00:00.000Z' };
    }

    sub _ref_id {
        my ($self, $value) = @_;
        return ref($value) eq 'HASH' ? $value->{id} : $value;
    }

    sub snapshot_list {
        my ($self) = @_;
        return [ map { $self->snapshot_get_by_name($_) } sort keys %SNAP ];
    }

    sub snapshot_delete {
        my ($self, $id) = @_;
        my ($name) = grep { $SNAP{$_}{id} eq $id } keys %SNAP;
        return 1 unless defined $name;

        # The vzdump path: a thin clone reads from the snapshot, and the
        # array refuses while it exists.
        my @clones = sort keys %{ $SNAP{$name}{clones} };
        $self->_die("The snapshot cannot be deleted because it has derived"
            . " storage resources: @clones") if @clones;

        delete $SNAP{$name};
        return 1;
    }

    # Unity creates a backup snapshot on EVERY restore, whether or not one
    # was asked for. This fake does the same, and honours copyName - which is
    # the whole point: with a name of the array's choosing the snapshot is
    # invisible to the purge, and the volume can never be deleted again.
    sub volume_restore {
        my ($self, $snap_id, %opts) = @_;

        my $name = $opts{copy_name};
        $name = "SNAP_" . main::next_id() unless defined $name && length $name;

        # The array appends a counter when the name is taken.
        my $unique = $name;
        my $n = 1;
        $unique = $name . $n++ while $SNAP{$unique};

        my ($of) = grep { $SNAP{$_}{id} eq $snap_id } keys %SNAP;
        $SNAP{$unique} = { id => main::next_id(),
                           resource => $of ? $SNAP{$of}{resource} : undef,
                           clones => {} };
        return 1;
    }

    sub volume_clone {
        my ($self, $resource_id, $snap_id, $name) = @_;
        my ($snap) = grep { $SNAP{$_}{id} eq $snap_id } keys %SNAP;
        $self->_die("no such snapshot") unless defined $snap;

        $self->volume_create($name, 4 * 1024**3);
        $SNAP{$snap}{clones}{$name} = 1;

        return $LUN{$name}{id};
    }

    # -- hosts and mapping ------------------------------------------------
    sub host_get_by_name {
        my ($self, $name) = @_;
        return { id => 'Host_1', name => $name,
                 fcHostInitiators => [ { id => 'HostInitiator_1' } ] };
    }
    sub host_list { return [ { id => 'Host_1', name => 'pve-u480-node1' },
                             { id => 'Host_2', name => 'pve-u480-node2' } ] }
    sub host_create { return 'Host_1' }
    sub host_add_initiator { return 1 }
    sub host_initiators {
        return [ { id => 'HostInitiator_1', initiatorId => '10000000c9000001',
                   parentHost => { id => 'Host_1' } } ];
    }

    # hostAccess REPLACES the list. This fake records exactly that, so a
    # plugin that sends one host loses the others here too.
    sub _write_host_access {
        my ($self, $resource_id, $ids) = @_;
        my $name = main::lun_by_id($resource_id) or $self->_die("no such LUN");
        $LUN{$name}{hosts} = { map { $_ => 1 } @$ids };
        return 1;
    }

    sub volume_mapped_hosts {
        my ($self, $name) = @_;
        my $row = $LUN{$name} or return [];
        return [ sort keys %{ $row->{hosts} } ];
    }

    sub is_mapped_to {
        my ($self, $name, $host_id) = @_;
        return $LUN{$name} && $LUN{$name}{hosts}{$host_id} ? 1 : 0;
    }

    sub volume_attach {
        my ($self, $name, $host_id) = @_;
        my $row = $LUN{$name} or $self->_die("volume '$name' is not on the array");
        $row->{hosts}{$host_id} = 1;
        return 1;
    }

    sub volume_detach {
        my ($self, $name, $host_id) = @_;
        my $row = $LUN{$name} or return 1;
        delete $row->{hosts}{$host_id};
        return 1;
    }
}

my $api = Test::UnityApi->new;

no warnings 'redefine', 'once';
local *PVE::Storage::Custom::DellUnityPlugin::_api = sub { $api };
local *PVE::Storage::Custom::DellUnityPlugin::_initiator_records =
    sub { [ { id => '10000000c9000001', type => '1' } ] };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::cleanup_lun_devices = sub { 1 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_device = sub { undef };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_slaves = sub { [] };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_block_device = sub { 0 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_device_in_use = sub { 0 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::wait_for_multipath_device = sub { '/dev/mapper/fake' };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::rescan_scsi_hosts = sub { 1 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::rescan_fc_hosts = sub { 1 };
local *PVE::Storage::Custom::DellEMC::Common::BlockBase::udev_refresh = sub { 1 };

my $store = 'u480';
my $scfg  = {
    'dell-portal'   => '10.0.0.10',
    'dell-username' => 'admin',
    'dell-password' => 'secret',
    'dell-protocol' => 'fc',
    'unity-pool'    => 'A',
    content         => { images => 1 },
};

sub names_on_array { return [ sort keys %LUN ] }
sub snaps_on_array { return [ sort keys %SNAP ] }

# ---------------------------------------------------------------------------
# One disk, from allocation to deletion
# ---------------------------------------------------------------------------

reset_array();

{
    my $volname = $P->alloc_image($store, $scfg, 100, 'raw', undef, 4 * 1024 * 1024);
    is($volname, 'vm-100-disk-0', 'PVE gets the name it expects back');
    is_deeply(names_on_array(), ['pve-u480-100-disk0'],
        'and the array has one LUN, named for this storage');

    my ($size) = $P->volume_size_info($scfg, $store, $volname);
    cmp_ok($size, '>=', 4 * 1024 * 1024 * 1024, 'the size is reported in bytes');

    # Resize takes the new total, not a delta.
    $P->volume_resize($scfg, $store, $volname, 8 * 1024**3);
    ($size) = $P->volume_size_info($scfg, $store, $volname);
    is($size, 8 * 1024**3, 'a resize sets the new total');

    ok(!eval { $P->volume_resize($scfg, $store, $volname, 1024); 1 },
        'shrinking is refused, as the array refuses it');

    $P->free_image($store, $scfg, $volname);
    is_deeply(names_on_array(), [], 'and the LUN is gone afterwards');
}

# ---------------------------------------------------------------------------
# Deleting a volume deletes its snapshots first
#
# PVE does not: `qm destroy` calls vdisk_free directly. A real array refuses
# to delete a LUN that still has snapshots, so a plugin that does not purge
# them first cannot delete anything a user has ever snapshotted.
# ---------------------------------------------------------------------------

reset_array();

{
    my $volname = $P->alloc_image($store, $scfg, 200, 'raw', undef, 4 * 1024 * 1024);

    $P->volume_snapshot($scfg, $store, $volname, 'before');
    $P->volume_snapshot($scfg, $store, $volname, 'after');
    is(scalar(@{ snaps_on_array() }), 2, 'two snapshots exist');

    my $list = $P->volume_snapshot_list($scfg, $store, $volname);
    is(scalar(@$list), 2, 'and both are listed for that volume');

    $P->free_image($store, $scfg, $volname);

    is_deeply(names_on_array(), [], 'the LUN is deleted');
    is_deeply(snaps_on_array(), [], '... and so are its snapshots');
}

# ---------------------------------------------------------------------------
# A volume that is still mapped
# ---------------------------------------------------------------------------

reset_array();

{
    my $volname = $P->alloc_image($store, $scfg, 300, 'raw', undef, 4 * 1024 * 1024);
    my $name = 'pve-u480-300-disk0';

    $P->activate_volume($store, $scfg, $volname);
    ok(scalar(@{ $api->volume_mapped_hosts($name) }),
        'activating maps the LUN to this node');

    $P->free_image($store, $scfg, $volname);
    is_deeply(names_on_array(), [],
        'a delete unmaps before it deletes, as the array refuses otherwise');
}

# ---------------------------------------------------------------------------
# Mapping does not disturb another node
#
# Unity's hostAccess replaces the list. If the plugin sends only this node's
# host, the other node loses access and its guest is writing to a device that
# has gone. This fake records the replacement faithfully, so the assertion is
# real rather than a restatement of the implementation.
# ---------------------------------------------------------------------------

reset_array();

{
    my $volname = $P->alloc_image($store, $scfg, 400, 'raw', undef, 4 * 1024 * 1024);
    my $name = 'pve-u480-400-disk0';

    # Another node already holds it.
    $LUN{$name}{hosts}{Host_2} = 1;

    $P->activate_volume($store, $scfg, $volname);

    is_deeply($api->volume_mapped_hosts($name), ['Host_1', 'Host_2'],
        'this node is added and the other one keeps its access');

    # Deactivating deliberately does NOT unmap: live migration needs the
    # volume present on the target node before the source releases it.
    $P->deactivate_volume($store, $scfg, $volname);

    is_deeply($api->volume_mapped_hosts($name), ['Host_1', 'Host_2'],
        'deactivating leaves the mapping in place, as live migration needs');

    # Giving it up for real happens on delete, and must not take the other
    # node's access with it.
    $P->_array_unmap_from_host($scfg, $name, 'pve-u480-node1');

    is_deeply($api->volume_mapped_hosts($name), ['Host_2'],
        'and unmapping this node leaves the other one alone');
}

# ---------------------------------------------------------------------------
# Templates and linked clones
#
# A linked clone is a thin clone of a snapshot, so the marker snapshot has to
# outlive its clones. Deleting the template while one exists is refused by
# the array, and the plugin must report that as a failure rather than as a
# completed delete — PVE removes the disk from the VM configuration on a
# success.
# ---------------------------------------------------------------------------

reset_array();

{
    my $volname = $P->alloc_image($store, $scfg, 500, 'raw', undef, 4 * 1024 * 1024);

    my $base = $P->create_base($store, $scfg, $volname);
    like($base, qr/^base-500/, 'a template gets a base- name');

    my $clone = $P->clone_image($scfg, $store, $base, 501);
    # PVE's own convention for a linked clone: the template's volname, a
    # slash, then the clone's. RBDPlugin does the same, and parse_volname
    # must return the LEAF at element 1 - that has been a real defect here.
    is($clone, 'base-500-disk-0/vm-501-disk-0',
        'a linked clone carries its template in the volname, as PVE expects');
    my (undef, $leaf) = $P->parse_volname($clone);
    is($leaf, 'vm-501-disk-0', '... and parse_volname returns the LEAF name');

    ok(scalar(@{ names_on_array() }) >= 2, 'both LUNs are on the array');

    ok(!eval { $P->free_image($store, $scfg, $base); 1 },
        'deleting the template while a clone reads from it is REFUSED');
    ok(grep({ /^pve-u480-500/ } @{ names_on_array() }),
        '... and the template is still there, which is what PVE must be told');

    $P->free_image($store, $scfg, $clone);
    ok(!grep({ /^pve-u480-501/ } @{ names_on_array() }), 'the clone is deleted');

    # Deleting the clone released the marker snapshot, so the template can go.
    ok(eval { $P->free_image($store, $scfg, $base); 1 },
        'once the clone is gone the template can be deleted') or diag($@);
    is_deeply(names_on_array(), [], 'and nothing is left on the array');
    is_deeply(snaps_on_array(), [], '... including the marker snapshot');
}

# ---------------------------------------------------------------------------
# Reading a snapshot, then deleting it
#
# The vzdump snapshot-mode path: snapshot, read through a temporary clone,
# delete the snapshot immediately. The array refuses while the clone exists,
# so the plugin has to remove the clone first.
# ---------------------------------------------------------------------------

reset_array();

{
    my $volname = $P->alloc_image($store, $scfg, 600, 'raw', undef, 4 * 1024 * 1024);
    $P->volume_snapshot($scfg, $store, $volname, 'vzdump');

    my ($temp) = $P->_prepare_snapshot_access($scfg, $store, $volname, 'vzdump');
    ok($LUN{$temp}, 'reading a snapshot creates a clone of it');
    cmp_ok(length($temp), '<=', 63, 'and the temporary name fits the array limit');

    $P->volume_snapshot_delete($scfg, $store, $volname, 'vzdump');
    ok(!$LUN{$temp}, 'deleting the snapshot removes that clone first');
    is_deeply(snaps_on_array(), [], '... and then the snapshot itself');
    is_deeply(names_on_array(), ['pve-u480-600-disk0'], 'leaving only the disk');
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------

reset_array();

{
    my $volname = $P->alloc_image($store, $scfg, 700, 'raw', undef, 4 * 1024 * 1024);
    $P->volume_snapshot($scfg, $store, $volname, 'good');

    ok($P->volume_snapshot_rollback($scfg, $store, $volname, 'good'),
        'a rollback to an existing snapshot succeeds');

    ok(!eval { $P->volume_snapshot_rollback($scfg, $store, $volname, 'nosuch'); 1 },
        'and one to a snapshot that is not there fails rather than doing nothing');

    # The array left a backup snapshot behind, as it always does.
    my @extra = grep { /rollback/ } @{ snaps_on_array() };
    is(scalar(@extra), 1, 'a restore leaves the array\'s backup snapshot behind');
    like($extra[0], qr/^pve-u480-700-disk0\./,
        '... under a name that points back at this volume, not the array\'s own');

    # Which is the point: it has to be deletable, or the volume never is.
    ok(eval { $P->free_image($store, $scfg, $volname); 1 },
        'so the volume can still be deleted afterwards') or diag($@);
    is_deeply(names_on_array(), [], 'and nothing is left behind');
    is_deeply(snaps_on_array(), [], '... including the backup snapshot');
}

{
    # Roll back twice. The array appends a counter the second time, and the
    # name still has to decode back to this volume or the second backup
    # snapshot is the one that makes the volume undeletable.
    reset_array();

    my $volname = $P->alloc_image($store, $scfg, 701, 'raw', undef, 4 * 1024 * 1024);
    $P->volume_snapshot($scfg, $store, $volname, 'good');

    $P->volume_snapshot_rollback($scfg, $store, $volname, 'good');
    $P->volume_snapshot_rollback($scfg, $store, $volname, 'good');

    my @extra = sort grep { /rollback/ } @{ snaps_on_array() };
    is(scalar(@extra), 2, 'two rollbacks leave two backup snapshots');
    isnt($extra[0], $extra[1], '... with different names');

    ok(eval { $P->free_image($store, $scfg, $volname); 1 },
        'and the volume is still deletable') or diag($@);
    is_deeply(snaps_on_array(), [], 'with every snapshot gone');
}

# ---------------------------------------------------------------------------
# A name the array would refuse
# ---------------------------------------------------------------------------

reset_array();

{
    # Every generated name has to fit 63 characters, including the longest
    # thing this plugin generates: a snapshot of a config volume.
    my $N = $P->naming;
    for my $name ($N->encode_volume_name('u480', 999999999, 15),
                  $N->encode_cloudinit_name('u480', 999999999),
                  $N->encode_snapshot_name(
                      $N->encode_volume_name('u480', 999999999, 15), 'a' x 40)) {
        cmp_ok(length($name), '<=', 63, "'$name' fits");
    }
}

# ---------------------------------------------------------------------------
# The whole feature matrix PVE will ask about
#
# A feature this table answers 'no' to simply disappears from the UI, so a
# wrong 'no' is invisible: nothing fails, the button is just not there.
# ---------------------------------------------------------------------------

{
    my $scfg2 = { %$scfg };
    for my $case (
        ['snapshot', 'vm-100-disk-0', undef,  1, 'snapshot of a disk'],
        ['snapshot', 'base-100-disk-0/vm-101-disk-0', undef, 1,
            'snapshot of a LINKED CLONE - the volname starts with base- and is not one'],
        ['clone',    'base-100-disk-0', undef, 1, 'linked clone of a template'],
        ['clone',    'vm-100-disk-0', 'snap1', 1, 'clone from a snapshot'],
        ['template', 'vm-100-disk-0', undef,  1, 'converting to a template'],
        ['rename',   'vm-100-disk-0', undef,  1, 'reassigning a disk'],
        ['copy',     'vm-100-disk-0', undef,  1, 'full copy'],
    ) {
        my ($feature, $volname, $snap, $want, $why) = @$case;
        is($P->volume_has_feature($scfg2, $feature, $store, $volname, $snap, 0) ? 1 : 0,
            $want, $why);
    }

    is($P->volume_snapshot_needs_fsfreeze(), 1,
        'a container filesystem is frozen while the array snapshots under it');
    is_deeply([$P->volume_export_formats($scfg2, $store, 'vm-100-disk-0', undef, undef, 0)],
        ['raw+size'], 'disks can leave for another storage type');
}

# ---------------------------------------------------------------------------
# A tiny volume is still a volume
#
# An EFI disk is 4 MiB. The array refuses a LUN below its minimum, so the
# create rounds up - and the whole 'qm create --efidisk0' lives or dies on it.
# ---------------------------------------------------------------------------

{
    reset_array();

    my $volname = $P->alloc_image($store, $scfg, 800, 'raw', undef, 4 * 1024);  # 4 MiB in KiB
    ok($volname, 'an EFI-disk-sized allocation succeeds');
    my ($size) = $P->volume_size_info($scfg, $store, $volname);
    cmp_ok($size, '>=', 4 * 1024 * 1024, '... and the guest gets at least what it asked for');

    $P->free_image($store, $scfg, $volname);
    is_deeply(names_on_array(), [], 'and it deletes like any other volume');
}

done_testing();
