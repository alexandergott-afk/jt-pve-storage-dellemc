#!/usr/bin/perl
# BlockBase orchestration tests.
#
# A fake family plugin backs every _array_* method with an in-memory array and
# records the calls, so the ordering rules that matter (unmap before delete,
# rollback after a failed map) are checked without hardware. The device-layer
# helpers are stubbed out in the fake: nothing here may touch multipathd,
# iscsiadm or a real device.
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
# Fake family plugin
# ---------------------------------------------------------------------------

{
    package Test::Plugin;
    use base 'PVE::Storage::Custom::DellEMC::Common::BlockBase';

    our %VOLUMES;    # name => { size, used, wwid }
    our %SNAPSHOTS;  # name => { volume, ctime }
    our %MAPPINGS;   # name => { host => 1 }
    our @CALLS;      # ordered log
    our @HOSTS;
    our $FAIL_MAP;
    our $CAPACITY = [1000, 400, 600];

    sub reset_state {
        %VOLUMES = ();
        %SNAPSHOTS = ();
        %MAPPINGS = ();
        @CALLS = ();
        @HOSTS = ({ name => 'pve-test-node1' }, { name => 'pve-test-node2' });
        $FAIL_MAP = 0;
        return;
    }

    sub log_call { push @CALLS, join(' ', @_[1 .. $#_]); return }
    sub calls { return \@CALLS }

    sub type { 'delltest' }
    sub multipath_vendor { 'DellEMC' }
    sub multipath_product { 'TestArray' }
    sub multipath_defaults { { path_selector => 'queue-length 0', no_path_retry => 30 } }

    # This node, deterministically.
    sub _host_name { 'pve-test-node1' }

    # The device layer must never be reached from these tests.
    sub _rescan_transport { $_[0]->log_call('rescan_transport'); return }
    sub _wait_opts { return (timeout => 0) }
    sub _ensure_multipath_config { return 1 }

    sub _array_ping { $_[0]->log_call('ping'); return 1 }
    sub _array_get_capacity { return @$CAPACITY }
    sub _array_get_portals { return [{ portal => '10.0.0.1:3260', iqn => 'iqn.test' }] }

    sub _array_get_volume {
        my ($class, $scfg, $name) = @_;
        return $VOLUMES{$name} ? { name => $name, %{ $VOLUMES{$name} } } : undef;
    }

    sub _array_list_volumes {
        my ($class, $scfg, $storeid, $prefix) = @_;
        $class->log_call('list_volumes', $prefix // '');
        my @out;
        for my $name (sort keys %VOLUMES) {
            next if defined $prefix && index($name, $prefix) != 0;
            push @out, { name => $name, %{ $VOLUMES{$name} } };
        }
        return \@out;
    }

    sub _array_create_volume {
        my ($class, $scfg, $storeid, $name, $size) = @_;
        $class->log_call('create', $name);
        die "already exists\n" if $VOLUMES{$name};
        $VOLUMES{$name} = { size => $size, used => 0, wwid => undef };
        return $name;
    }

    sub _array_delete_volume {
        my ($class, $scfg, $storeid, $name) = @_;
        $class->log_call('delete', $name);
        die "volume not found\n" unless $VOLUMES{$name};
        delete $VOLUMES{$name};
        delete $MAPPINGS{$name};
        return 1;
    }

    sub _array_resize_volume {
        my ($class, $scfg, $storeid, $name, $size) = @_;
        $class->log_call('resize', $name, $size);
        $VOLUMES{$name}{size} = $size;
        return 1;
    }

    sub _array_rename_volume {
        my ($class, $scfg, $storeid, $from, $to) = @_;
        $class->log_call('rename', $from, $to);
        $VOLUMES{$to} = delete $VOLUMES{$from};
        return 1;
    }

    # undef keeps every device-layer branch out of these tests.
    sub _array_get_wwid { return undef }

    sub _array_snapshot_create {
        my ($class, $scfg, $storeid, $volume, $snap) = @_;
        $class->log_call('snapshot_create', $snap);
        $SNAPSHOTS{$snap} = { volume => $volume, ctime => 1000 };
        return 1;
    }

    sub _array_snapshot_get {
        my ($class, $scfg, $storeid, $snap) = @_;
        return $SNAPSHOTS{$snap} ? { name => $snap, %{ $SNAPSHOTS{$snap} } } : undef;
    }

    sub _array_snapshot_delete {
        my ($class, $scfg, $storeid, $snap) = @_;
        $class->log_call('snapshot_delete', $snap);
        delete $SNAPSHOTS{$snap};
        return 1;
    }

    sub _array_snapshot_list {
        my ($class, $scfg, $storeid, $volume, $prefix) = @_;
        my @out;
        for my $name (sort keys %SNAPSHOTS) {
            next if defined $volume && $SNAPSHOTS{$name}{volume} ne $volume;
            next if defined $prefix && index($name, $prefix) != 0;
            push @out, { name => $name, ctime => $SNAPSHOTS{$name}{ctime} };
        }
        return \@out;
    }

    sub _array_snapshot_rollback {
        my ($class, $scfg, $storeid, $volume, $snap) = @_;
        $class->log_call('rollback', $volume, $snap);
        return 1;
    }

    sub _array_clone {
        my ($class, $scfg, $storeid, $source, $target) = @_;
        $class->log_call('clone', $source, $target);
        die "already exists\n" if $VOLUMES{$target};
        $VOLUMES{$target} = { size => 1024, used => 0 };
        return 1;
    }

    sub _array_ensure_host { $_[0]->log_call('ensure_host'); return 'pve-test-node1' }
    sub _array_list_hosts { return [@HOSTS] }

    sub _array_map_to_host {
        my ($class, $scfg, $name, $host) = @_;
        $class->log_call('map', $name, $host);
        die "mapping refused\n" if $FAIL_MAP && $host ne 'pve-test-node1';
        $MAPPINGS{$name}{$host} = 1;
        return 1;
    }

    sub _array_unmap_from_host {
        my ($class, $scfg, $name, $host) = @_;
        $class->log_call('unmap', $name, $host);
        delete $MAPPINGS{$name}{$host};
        return 1;
    }

    sub _array_is_mapped {
        my ($class, $scfg, $name, $host) = @_;
        return $MAPPINGS{$name}{$host} ? 1 : 0;
    }

    sub _array_mapped_hosts {
        my ($class, $scfg, $name) = @_;
        return [sort keys %{ $MAPPINGS{$name} // {} }];
    }
}

my $P = 'Test::Plugin';
my $scfg = {
    'dell-portal'   => '10.0.0.5',
    'dell-username' => 'pveadmin',
    'dell-password' => 'secret',
};
my $storeid = 'ps1';

Test::Plugin::reset_state();

# ---------------------------------------------------------------------------
# Registration data
# ---------------------------------------------------------------------------

is($P->api, 13, 'storage API version');
is($P->type, 'delltest', 'storage type');

my $pd = $P->plugindata();
is_deeply($pd->{format}, [{ raw => 1 }, 'raw'], 'raw only');
ok($pd->{content}[0]{images}, 'holds VM disks');
ok($pd->{content}[0]{rootdir}, 'holds container root filesystems');

my $props = $P->properties();
ok($props->{'dell-portal'}, 'common properties are declared');
is($props->{'dell-protocol'}{default}, 'iscsi', 'iSCSI is the default protocol');
# The protocol option is shared with PowerFlex, whose values mean nothing
# here, so the enum is broad and each family rejects what it cannot serve.
is_deeply([sort @{ $props->{'dell-protocol'}{enum} }], ['fc', 'iscsi', 'nvme', 'sdc'],
    'the shared protocol enum covers every family');

{
    my $err;
    eval { $P->activate_storage('ps1', { %$scfg, 'dell-protocol' => 'sdc' }) };
    $err = $@;
    like($err, qr/PowerFlex family/, 'a SAN family rejects a PowerFlex protocol');
    like($err, qr/use 'iscsi' or 'fc'/, 'and says what to use instead');
}

my $opts = $P->options();
ok($opts->{'dell-portal'}{fixed}, 'the portal is fixed once set');
ok(!$opts->{'dell-username'}{optional}, 'username is required');
ok($opts->{'dell-ssl-verify'}{optional}, 'SSL verification is optional');
ok($opts->{shared}{optional}, 'standard PVE options are present');

# PVE dies with "duplicate property" if two plugins declare the same name, so
# only the first family may declare the shared ones.
{
    package Test::Plugin2;
    use base 'Test::Plugin';
    sub type { 'delltest2' }
    sub family_properties { return { 'ptest-thing' => { type => 'string' } } }
}
my $props2 = Test::Plugin2->properties();
ok($props2->{'ptest-thing'}, 'a second family declares its own properties');
ok(!$props2->{'dell-portal'},
    'and does NOT redeclare the shared ones, which PVE would reject');

like($P->get_identity($scfg, $storeid), qr/^delltest:10\.0\.0\.5:/, 'identity string');
ok($P->plugindata()->{'sensitive-properties'}{'dell-password'},
    'plugindata declares the password sensitive - which is where PVE looks');

# ---------------------------------------------------------------------------
# Volume names
# ---------------------------------------------------------------------------

is_deeply([$P->parse_volname('vm-100-disk-0')],
    ['images', 'vm-100-disk-0', 100, undef, undef, 0, 'raw'], 'parse a VM disk');
is_deeply([$P->parse_volname('base-100-disk-0')],
    ['images', 'base-100-disk-0', 100, undef, undef, 1, 'raw'], 'parse a base disk');
# The second element is the LEAF name, as RBD and every other plugin using
# this two-part form returns. PVE builds a target volume name out of it when a
# disk moves to a storage of another type, and 'base-.../vm-...' there would
# name a base image the target storage has never heard of.
is_deeply([$P->parse_volname('base-100-disk-0/vm-101-disk-0')],
    ['images', 'vm-101-disk-0', 101, 'base-100-disk-0', 100, 0, 'raw'],
    'parse a linked clone');
is_deeply([$P->parse_volname('vm-100-cloudinit')],
    ['images', 'vm-100-cloudinit', 100, undef, undef, 0, 'raw'], 'parse cloud-init');
is_deeply([$P->parse_volname('vm-100-state-snap1')],
    ['images', 'vm-100-state-snap1', 100, undef, undef, 0, 'raw'], 'parse a state volume');
eval { $P->parse_volname('nonsense') };
like($@, qr/unable to parse/, 'an unparseable name dies');

# ---------------------------------------------------------------------------
# Allocation
# ---------------------------------------------------------------------------

Test::Plugin::reset_state();

my $volname = $P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);
is($volname, 'vm-100-disk-0', 'first disk of a VM');
ok($Test::Plugin::VOLUMES{'pve-ps1-100-disk0'}, 'created on the array under its own name');
is($Test::Plugin::VOLUMES{'pve-ps1-100-disk0'}{size}, 1024 * 1024,
    'PVE passes KiB and the array is given bytes');

is($P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024), 'vm-100-disk-1',
    'the next disk takes the next free id');

# Mapped to every node, so a live migration does not have to remap first.
is_deeply($P->_array_mapped_hosts($scfg, 'pve-ps1-100-disk0'),
    ['pve-test-node1', 'pve-test-node2'], 'mapped to every cluster node');

eval { $P->alloc_image($storeid, $scfg, 100, 'qcow2', undef, 1024) };
like($@, qr/unsupported format/, 'only raw is accepted');

# A failed mapping must not leave a volume behind.
{
    Test::Plugin::reset_state();
    local $Test::Plugin::FAIL_MAP = 1;

    # Only the other node fails, which is survivable: it is reported, not fatal.
    my $warned = '';
    {
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        $P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);
    }
    like($warned, qr/could not be mapped/, 'a partial mapping is reported');
    like($warned, qr/migration/, 'and says what it costs');
    ok($Test::Plugin::VOLUMES{'pve-ps1-100-disk0'}, 'the volume survives a partial mapping');
}

# ---------------------------------------------------------------------------
# Deletion ordering
#
# Unmapping has to happen before the delete. The other order lets an in-flight
# rescan on any node re-import the LUN and rebuild the device behind us.
# ---------------------------------------------------------------------------

Test::Plugin::reset_state();
$P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);
@Test::Plugin::CALLS = ();

$P->free_image($storeid, $scfg, 'vm-100-disk-0', 0, 'raw');

my $calls = join("\n", @{ $P->calls });
like($calls, qr/unmap pve-ps1-100-disk0 pve-test-node1.*delete pve-ps1-100-disk0/s,
    'unmapped before deletion');
ok(!$Test::Plugin::VOLUMES{'pve-ps1-100-disk0'}, 'volume gone from the array');

# Deleting something that is already gone is not an error: PVE retries.
{
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    is($P->free_image($storeid, $scfg, 'vm-100-disk-0', 0, 'raw'), undef,
        'deleting an absent volume is a no-op');
    like($warned, qr/not on the array/, 'and says so');
}

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------

Test::Plugin::reset_state();
$P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);
$P->alloc_image($storeid, $scfg, 101, 'raw', undef, 2048);

my $images = $P->list_images($storeid, $scfg);
is(scalar @$images, 2, 'both disks are listed');
is_deeply([sort map { $_->{volid} } @$images],
    ['ps1:vm-100-disk-0', 'ps1:vm-101-disk-0'], 'volume ids');
is($images->[0]{format}, 'raw', 'format');

my $for_vm = $P->list_images($storeid, $scfg, 100);
is(scalar @$for_vm, 1, 'listing can be restricted to one VM');

# The vmid filter must reach the array as a prefix rather than being applied
# after fetching everything.
like(join("\n", @{ $P->calls }), qr/list_volumes pve-ps1-100-/,
    'the VM filter is pushed down to the array query');

# A config backup volume is plugin bookkeeping and must not appear as a disk.
$Test::Plugin::VOLUMES{'pve-ps1-100-vmconf-snap1'} = { size => 1048576, used => 0 };
is(scalar @{ $P->list_images($storeid, $scfg) }, 2, 'config volumes are not listed');

# A volume carrying the template marker is reported as a base image.
$Test::Plugin::SNAPSHOTS{'pve-ps1-100-disk0.pve-base'} =
    { volume => 'pve-ps1-100-disk0', ctime => 1 };
my ($base) = grep { $_->{vmid} == 100 } @{ $P->list_images($storeid, $scfg) };
is($base->{volid}, 'ps1:base-100-disk-0', 'a template shows up as a base image');

# ---------------------------------------------------------------------------
# Resize
# ---------------------------------------------------------------------------

Test::Plugin::reset_state();
$P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);   # 1 MiB

is($P->volume_resize($scfg, $storeid, 'vm-100-disk-0', 32 * 1024 ** 3, 0), 1, 'grow');
is($Test::Plugin::VOLUMES{'pve-ps1-100-disk0'}{size}, 32 * 1024 ** 3, 'new size stored');

eval { $P->volume_resize($scfg, $storeid, 'vm-100-disk-0', 16 * 1024 ** 3, 0) };
like($@, qr/Cannot shrink/, 'shrinking is refused');
like($@, qr/32\.00 GB.*16\.00 GB/, 'both sizes are named');
like($@, qr/lose data/, 'and the consequence is stated');
is($Test::Plugin::VOLUMES{'pve-ps1-100-disk0'}{size}, 32 * 1024 ** 3, 'size unchanged');

is($P->volume_resize($scfg, $storeid, 'vm-100-disk-0', 32 * 1024 ** 3, 0), 1,
    'resizing to the current size is a no-op');

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

Test::Plugin::reset_state();
$P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);

{
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    $P->volume_snapshot($scfg, $storeid, 'vm-100-disk-0', 'before-upgrade');
}
ok($Test::Plugin::SNAPSHOTS{'pve-ps1-100-disk0.pve-snap-before-upgrade'},
    'snapshot created under the encoded name');

my $snaps = $P->volume_snapshot_list($scfg, $storeid, 'vm-100-disk-0');
is_deeply([map { $_->{name} } @$snaps], ['before-upgrade'],
    'listed back under the PVE name');

eval { $P->volume_snapshot($scfg, $storeid, 'vm-100-disk-0', 'before-upgrade') };
like($@, qr/already exists/, 'a duplicate snapshot name is refused');

# The template marker must not show up as a user snapshot.
$Test::Plugin::SNAPSHOTS{'pve-ps1-100-disk0.pve-base'} =
    { volume => 'pve-ps1-100-disk0', ctime => 1 };
is(scalar @{ $P->volume_snapshot_list($scfg, $storeid, 'vm-100-disk-0') }, 1,
    'the template marker is not a snapshot');
delete $Test::Plugin::SNAPSHOTS{'pve-ps1-100-disk0.pve-base'};

{
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    $P->volume_snapshot_delete($scfg, $storeid, 'vm-100-disk-0', 'before-upgrade');
}
ok(!$Test::Plugin::SNAPSHOTS{'pve-ps1-100-disk0.pve-snap-before-upgrade'}, 'snapshot deleted');

{
    # Deleting a snapshot that is gone is not an error.
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    is($P->volume_snapshot_delete($scfg, $storeid, 'vm-100-disk-0', 'gone'), 1,
        'deleting an absent snapshot succeeds');
    like($warned, qr/not on the array/, 'and says so');
}

# A snapshot still backing a thin clone must fail with something actionable.
{
    Test::Plugin::reset_state();
    $P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);
    {
        local $SIG{__WARN__} = sub { };
        $P->volume_snapshot($scfg, $storeid, 'vm-100-disk-0', 'snap1');
    }

    no warnings 'redefine';
    local *Test::Plugin::_array_snapshot_delete = sub { die "has dependent volumes\n" };
    eval { $P->volume_snapshot_delete($scfg, $storeid, 'vm-100-disk-0', 'snap1') };
    like($@, qr/thin clones/, 'the cause is explained');
    like($@, qr/Delete those volumes first/, 'and the fix is stated');
}

# ---------------------------------------------------------------------------
# Templates and clones
# ---------------------------------------------------------------------------

Test::Plugin::reset_state();
$P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);

is($P->create_base($storeid, $scfg, 'vm-100-disk-0'), 'base-100-disk-0',
    'converting to a template renames it for PVE');
ok($Test::Plugin::SNAPSHOTS{'pve-ps1-100-disk0.pve-base'}, 'marker snapshot created');

eval { $P->create_base($storeid, $scfg, 'base-100-disk-0') };
like($@, qr/already a base image/, 'converting a template again is refused');

# A linked clone of a template returns the base/clone pair PVE expects.
my $clone = $P->clone_image($scfg, $storeid, 'base-100-disk-0', 200);
is($clone, 'base-100-disk-0/vm-200-disk-0', 'linked clone volume name');
ok($Test::Plugin::VOLUMES{'pve-ps1-200-disk0'}, 'clone created on the array');
like(join("\n", @{ $P->calls }), qr/clone pve-ps1-100-disk0\.pve-base pve-ps1-200-disk0/,
    'cloned from the template marker, not the live volume');

# Cloning a plain volume is a plain clone.
Test::Plugin::reset_state();
$P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);
is($P->clone_image($scfg, $storeid, 'vm-100-disk-0', 300), 'vm-300-disk-0',
    'clone of a non-template');

# Cloning from a named snapshot uses that snapshot.
Test::Plugin::reset_state();
$P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);
{
    local $SIG{__WARN__} = sub { };
    $P->volume_snapshot($scfg, $storeid, 'vm-100-disk-0', 'snap1');
}
@Test::Plugin::CALLS = ();
$P->clone_image($scfg, $storeid, 'vm-100-disk-0', 400, 'snap1');
like(join("\n", @{ $P->calls }), qr/clone pve-ps1-100-disk0\.pve-snap-snap1/,
    'cloned from the named snapshot');

# ---------------------------------------------------------------------------
# Rename
# ---------------------------------------------------------------------------

Test::Plugin::reset_state();
$P->alloc_image($storeid, $scfg, 100, 'raw', undef, 1024);
is($P->rename_volume($scfg, $storeid, 'vm-100-disk-0', 101, 'vm-101-disk-5'),
    'ps1:vm-101-disk-5', 'rename returns the new volume id');
ok($Test::Plugin::VOLUMES{'pve-ps1-101-disk5'}, 'renamed on the array');
ok(!$Test::Plugin::VOLUMES{'pve-ps1-100-disk0'}, 'old name gone');

# ---------------------------------------------------------------------------
# Features
# ---------------------------------------------------------------------------

ok($P->volume_has_feature($scfg, 'snapshot', $storeid, 'vm-100-disk-0'), 'snapshot');
ok($P->volume_has_feature($scfg, 'clone', $storeid, 'vm-100-disk-0'), 'clone');
ok($P->volume_has_feature($scfg, 'template', $storeid, 'vm-100-disk-0'), 'template');
ok($P->volume_has_feature($scfg, 'copy', $storeid, 'vm-100-disk-0'), 'copy');
ok($P->volume_has_feature($scfg, 'sparseinit', $storeid, 'vm-100-disk-0'), 'sparseinit');
ok($P->volume_has_feature($scfg, 'rename', $storeid, 'vm-100-disk-0'), 'rename');
ok($P->volume_has_feature($scfg, 'clone', $storeid, 'base-100-disk-0'), 'clone of a base');
ok(!$P->volume_has_feature($scfg, 'template', $storeid, 'vm-100-disk-0', 'snap1'),
    'a snapshot cannot become a template');
# A linked clone is named 'base-100-disk-0/vm-101-disk-0'. Deciding what it
# is by the spelling of the name calls it a base image — the least base-like
# volume on the storage — and PVE then refuses to snapshot or rename any
# linked clone, saying the feature is not available on this storage.
{
    my $clone = 'base-100-disk-0/vm-101-disk-0';

    ok($P->volume_has_feature($scfg, 'snapshot', $storeid, $clone),
        'a linked clone can be snapshotted');
    ok($P->volume_has_feature($scfg, 'rename', $storeid, $clone),
        'and renamed');
    ok($P->volume_has_feature($scfg, 'copy', $storeid, $clone),
        'and copied');
    ok($P->volume_has_feature($scfg, 'template', $storeid, $clone),
        'and turned into a template of its own');

    # A real base image is still a base image.
    ok(!$P->volume_has_feature($scfg, 'snapshot', $storeid, 'base-100-disk-0'),
        'a base image is not snapshotted directly');
    ok(!$P->volume_has_feature($scfg, 'rename', $storeid, 'base-100-disk-0'),
        'nor renamed');
}

# volume_has_feature is called in a loop over a VM's configuration, so a
# volname it cannot read must not abort the whole operation.
{
    my $answer = eval { $P->volume_has_feature($scfg, 'snapshot', $storeid,
        'something-else-entirely') };
    ok(defined $answer, 'an unreadable volname is answered, not died on')
        or diag("died with: $@");
}

ok(!$P->volume_has_feature($scfg, 'nonsense', $storeid, 'vm-100-disk-0'),
    'unknown features are not claimed');
is($P->storage_can_replicate($scfg, $storeid, 'raw'), 0, 'no storage replication');

# ---------------------------------------------------------------------------
# Configuration accessors
# ---------------------------------------------------------------------------

is($P->_protocol($scfg), 'iscsi', 'protocol default');
is($P->_protocol({ %$scfg, 'dell-protocol' => 'fc' }), 'fc', 'protocol override');
is($P->_is_fc($scfg), 0, 'iSCSI is not FC');
is($P->_is_fc({ %$scfg, 'dell-protocol' => 'fc' }), 1, 'FC detected');
is($P->_device_timeout($scfg), 60, 'device timeout default');
is($P->_device_timeout({ %$scfg, 'dell-device-timeout' => 120 }), 120, 'override');
is($P->_status_timeout($scfg), 5, 'health timeout default');
is($P->_activate_deadline($scfg), 30, 'activate deadline default');
is($P->_rescan_interval($scfg), 300, 'rescan interval default');
is($P->_cluster_name($scfg), 'pve', 'cluster name default');
is($P->_host_mode($scfg), 'per-node', 'host mode default');

# The periodic rescan must be rate limited: PVE calls activate_storage on
# every poll, and a host-wide reconfigure six times a minute keeps
# device-mapper in flux while other operations need it stable.
{
    my $sid = 'rescan-test';
    ok($P->_should_rescan($sid, $scfg, 0), 'the first activation rescans');
    $P->_mark_rescan($sid);
    ok(!$P->_should_rescan($sid, $scfg, 0), 'the next one is suppressed');
    ok($P->_should_rescan($sid, $scfg, 1), 'a new portal login forces one anyway');
    ok($P->_should_rescan($sid, { %$scfg, 'dell-rescan-interval' => 0 }, 0),
        'an interval of 0 restores rescanning every time');
}

# ---------------------------------------------------------------------------
# Multipath drop-in
# ---------------------------------------------------------------------------

{
    package Test::MPPlugin;
    use base 'Test::Plugin';
    our $FILE;
    sub _multipath_config_file { return $FILE }
    sub _ensure_multipath_config {
        return PVE::Storage::Custom::DellEMC::Common::BlockBase::_ensure_multipath_config(@_);
    }
    sub multipath_config_version { return 1 }
}

SKIP: {
    skip 'no /etc/multipath/conf.d on this host', 8 unless -d '/etc/multipath/conf.d';

    local $Test::MPPlugin::FILE = "$TMP/dellemc-test.conf";

    my $warned = '';
    {
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        Test::MPPlugin->_ensure_multipath_config();
    }
    ok(-f $Test::MPPlugin::FILE, 'drop-in written');

    my $content = do { open(my $fh, '<', $Test::MPPlugin::FILE); local $/; <$fh> };
    like($content, qr/dellemc-multipath-config-version: 1/, 'carries a version marker');
    like($content, qr/vendor\s+"DellEMC"/, 'vendor block');
    like($content, qr/product\s+"TestArray"/, 'product block');
    like($content, qr/no_path_retry\s+30/, 'family defaults are written');
    unlike($content, qr/no_path_retry\s+queue/, 'never writes the queueing form');

    # An operator-owned file has no marker and must be left exactly as it is.
    open(my $fh, '>', $Test::MPPlugin::FILE) or die $!;
    print $fh "# hand written by the admin\ndevices { }\n";
    close($fh);

    Test::MPPlugin->_ensure_multipath_config();
    my $after = do { open(my $r, '<', $Test::MPPlugin::FILE); local $/; <$r> };
    like($after, qr/hand written by the admin/,
        'a file without the marker is never rewritten');
}

# ---------------------------------------------------------------------------
# Deleting a volume takes this plugin's own snapshots with it
#
# PVE does not remove storage snapshots before deleting a disk: 'qm destroy'
# calls vdisk_free straight away, and a template always carries its marker
# snapshot. Without this the very first "delete a VM that has a snapshot" fails
# on the array.
# ---------------------------------------------------------------------------

{
    Test::Plugin->reset_state();

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    my $vol  = 'pve-t1-100-disk0';

    $Test::Plugin::VOLUMES{$vol} = { size => 1024, used => 0 };
    $Test::Plugin::SNAPSHOTS{"$vol.pve-snap-before"} = { volume => $vol, ctime => 1 };
    $Test::Plugin::SNAPSHOTS{"$vol.pve-base"}        = { volume => $vol, ctime => 1 };
    # Another volume's snapshot, and a foreign object: neither may be touched.
    $Test::Plugin::SNAPSHOTS{'pve-t1-101-disk0.pve-snap-x'} =
        { volume => 'pve-t1-101-disk0', ctime => 1 };
    $Test::Plugin::SNAPSHOTS{'someone-elses-snap'} = { volume => $vol, ctime => 1 };

    Test::Plugin->free_image('t1', $scfg, 'base-100-disk-0', 1, 'raw');

    my $calls = join(' | ', @{ Test::Plugin->calls() });
    like($calls, qr/snapshot_delete \Q$vol\E\.pve-snap-before/,
        'the volume\'s own snapshot is removed');
    like($calls, qr/snapshot_delete \Q$vol\E\.pve-base/,
        'the template marker is removed too');
    unlike($calls, qr/snapshot_delete pve-t1-101-disk0/,
        'another volume\'s snapshot is left alone');
    unlike($calls, qr/snapshot_delete someone-elses-snap/,
        'an object that does not decode as ours is left alone');

    ok(!$Test::Plugin::VOLUMES{$vol}, 'and the volume itself is gone');

    my @order = @{ Test::Plugin->calls() };
    my ($snap_idx) = grep { $order[$_] =~ /^snapshot_delete/ } 0 .. $#order;
    my ($del_idx)  = grep { $order[$_] eq "delete $vol" } 0 .. $#order;
    ok($snap_idx < $del_idx, 'snapshots are removed before the volume');

    # The template marker goes last: while a linked clone still depends on it
    # the delete fails either way, and removing the marker first would leave a
    # template PVE no longer recognises as one.
    my ($base_idx) = grep { $order[$_] eq "snapshot_delete $vol.pve-base" } 0 .. $#order;
    my ($first_del) = grep { $order[$_] eq "delete $vol" } 0 .. $#order;
    ok($base_idx > $first_del,
        'the template marker is only removed after a delete has been tried');
    ok(!$Test::Plugin::SNAPSHOTS{"$vol.pve-base"},
        'and it does not outlive the volume it marked');
}

# A template whose delete keeps failing must keep its marker snapshot: the
# volume survives, so it has to survive as a template.
#
# The array is what decides. A linked clone is a clone OF THE MARKER, so an
# array that still has one refuses to delete the marker — trying and being
# refused is the reliable test. Reading the refusal text is not: PowerStore
# and PowerFlex use the same wording for "this volume still has a snapshot"
# and "something was cloned from it".
{
    Test::Plugin->reset_state();

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    my $vol  = 'pve-t1-100-disk0';

    $Test::Plugin::VOLUMES{$vol} = { size => 1024, used => 0 };
    $Test::Plugin::SNAPSHOTS{"$vol.pve-base"} = { volume => $vol, ctime => 1 };

    no warnings 'redefine';

    # The volume cannot go: something was cloned from it.
    local *Test::Plugin::_array_delete_volume = sub {
        my ($class, $scfg, $storeid, $name) = @_;
        $class->log_call('delete', $name);
        die "cannot delete: dependent clone exists\n";
    };

    # And neither can the marker, for the same reason — which is what a real
    # array says when the clone was taken from it.
    local *Test::Plugin::_array_snapshot_delete = sub {
        my ($class, $scfg, $storeid, $snap) = @_;
        $class->log_call('snapshot_delete', $snap);
        die "cannot delete: a clone was made from this snapshot\n";
    };

    my $err;
    eval { Test::Plugin->free_image('t1', $scfg, 'base-100-disk-0', 1, 'raw') };
    $err = $@;

    like($err, qr/dependent objects/, 'the refusal is reported to the operator');
    like($err, qr/clone was made from this snapshot/,
        '... including what the array said about the marker itself');
    ok($Test::Plugin::SNAPSHOTS{"$vol.pve-base"},
        'and the template keeps its marker snapshot');
}

# A failed delete must never be reported as success. Everything between the
# delete and the check has to keep its hands off $@ — an eval anywhere in
# between resets it, and free_image would return undef exactly as it does on
# success. PVE would then drop the disk from the VM configuration while the
# volume is still on the array.
{
    Test::Plugin->reset_state();

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    my $vol  = 'pve-t1-100-disk0';

    $Test::Plugin::VOLUMES{$vol} = { size => 1024, used => 0 };

    no warnings 'redefine';
    local *Test::Plugin::_array_delete_volume = sub {
        my ($class, $scfg, $storeid, $name) = @_;
        $class->log_call('delete', $name);
        die "the array is busy, try again later\n";
    };

    my $ok = eval { Test::Plugin->free_image('t1', $scfg, 'base-100-disk-0', 1, 'raw'); 1 };

    ok(!$ok, 'a delete the array refused is reported as a failure');
    like($@ // '', qr/busy|Failed to delete/,
        '... with the array error in the message');
    ok($Test::Plugin::VOLUMES{$vol}, 'and the volume is still on the array');
}

# ---------------------------------------------------------------------------
# Temporary snapshot-access clone names
# ---------------------------------------------------------------------------

{
    my $token = PVE::Storage::Custom::DellEMC::Common::BlockBase::_short_token(
        12345, 1785056400);
    like($token, qr/^[0-9a-z]+$/, 'the token is base 36 and needs no escaping');
    cmp_ok(length($token), '<=', 8, 'and is short enough for a 32-byte name');

    isnt(PVE::Storage::Custom::DellEMC::Common::BlockBase::_short_token(1, 1785056400),
        PVE::Storage::Custom::DellEMC::Common::BlockBase::_short_token(2, 1785056400),
        'two processes at the same instant get different tokens');

    # The name has to come from the naming class: built by hand it would ignore
    # the family limit and PowerVault would reject it.
    for my $case (
        ['PVE::Storage::Custom::DellEMC::Common::Naming',     'pve-ps1-100-disk0', 63],
        ['PVE::Storage::Custom::DellEMC::PowerVault::Naming', 'pve-pv1-100-d0',    32],
        ['PVE::Storage::Custom::DellEMC::PowerFlex::Naming',  'pve-pf1-100-d0',    31],
    ) {
        my ($naming, $volume, $limit) = @$case;
        eval "require $naming" or die $@;
        my $name = $naming->encode_temp_clone_name($volume, $token);
        cmp_ok(length($name), '<=', $limit,
            "$naming keeps the temporary clone name within $limit bytes");
        ok($naming->is_valid_volume_name($name),
            "$naming produces a name the array would accept");
        like($name, qr/^\Q$volume\E/, '... derived from the volume it clones');
    }
}

# ---------------------------------------------------------------------------
# Periodic rescan gating
# ---------------------------------------------------------------------------

{
    my $scfg = { 'dell-rescan-interval' => 300 };

    ok(Test::Plugin->_should_rescan('never', $scfg, 0),
        'a storage that has never rescanned is due');

    Test::Plugin->_mark_rescan('r1');
    ok(!Test::Plugin->_should_rescan('r1', $scfg, 0), 'and not again straight away');
    ok(Test::Plugin->_should_rescan('r1', $scfg, 1), 'unless forced');

    # An NTP correction that steps the clock backwards must not suppress
    # rescans for as long as the skew lasts.
    Test::Plugin->_mark_rescan('r1', time() + 3600);
    ok(Test::Plugin->_should_rescan('r1', $scfg, 0),
        'a timestamp in the future counts as due');

    ok(Test::Plugin->_should_rescan('r1', { 'dell-rescan-interval' => 0 }, 0),
        'an interval of 0 rescans every time');
}

# ---------------------------------------------------------------------------
# Host registration is not repeated on every poll
# ---------------------------------------------------------------------------

{
    Test::Plugin->reset_state();
    my $scfg = { 'dell-portal' => '10.0.0.1' };

    Test::Plugin->_ensure_host_throttled('h1', $scfg);
    Test::Plugin->_ensure_host_throttled('h1', $scfg);
    Test::Plugin->_ensure_host_throttled('h1', $scfg);

    my @checks = grep { $_ eq 'ensure_host' } @{ Test::Plugin->calls() };
    is(scalar(@checks), 1,
        'activate_storage checks the host object once, not on every poll');

    Test::Plugin->_ensure_host_throttled('h2', $scfg);
    @checks = grep { $_ eq 'ensure_host' } @{ Test::Plugin->calls() };
    is(scalar(@checks), 2, 'a different storage is checked on its own');
}

# ---------------------------------------------------------------------------
# list_images
# ---------------------------------------------------------------------------

{
    Test::Plugin->reset_state();
    my $scfg = { 'dell-portal' => '10.0.0.1' };

    $Test::Plugin::VOLUMES{'pve-t1-100-disk1'}  = { size => 1024, used => 0 };
    $Test::Plugin::VOLUMES{'pve-t1-100-disk10'} = { size => 2048, used => 0 };

    my $all = Test::Plugin->list_images('t1', $scfg);
    is(scalar(@$all), 2, 'both disks are listed without a filter');

    # A prefix match would also return vm-100-disk-10 here.
    my $one = Test::Plugin->list_images('t1', $scfg, undef, ['t1:vm-100-disk-1']);
    is(scalar(@$one), 1, 'a vollist filter matches exactly one volume');
    is($one->[0]{volid}, 't1:vm-100-disk-1', '... and it is the right one');
}

# ---------------------------------------------------------------------------
# Orphan reaper: no per-volume array calls, and never act on a listing that
# carries no WWIDs
#
# This runs in the background of every status() poll on every node. One array
# call per volume here is (volumes x nodes) requests every ten seconds, which
# is what takes an array's management interface down. And an alive set that
# came back empty because the listing lacked WWIDs must never be read as
# "every volume was deleted" — that would reap devices a running VM is using.
# ---------------------------------------------------------------------------

{
    my $state_dir = "$TMP/reaper";
    mkdir $state_dir;

    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::state_dir = sub { $state_dir };
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::lock_dir  = sub { $state_dir };

    # Nothing in this test may touch multipathd or a real device.
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_device = sub { undef };
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_device_in_use = sub { 0 };
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::cleanup_lun_devices = sub { 1 };
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::list_vendor_multipath_devices = sub { [] };

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    my $W = 'PVE::Storage::Custom::DellEMC::Common::WwidState';

    # 1. A listing that carries WWIDs: they become the alive set, and no
    #    per-volume lookup is made.
    Test::Plugin->reset_state();
    $Test::Plugin::VOLUMES{'pve-t1-100-disk0'} =
        { size => 1024, used => 0, wwid => '3600abc0000000001' };

    my $per_volume_calls = 0;
    {
        no warnings 'redefine';
        local *Test::Plugin::_array_get_wwid = sub { $per_volume_calls++; return undef };
        Test::Plugin->_cleanup_orphaned_devices('t1', $scfg);
    }

    is($per_volume_calls, 0,
        'the reaper makes no per-volume array call — it uses the listing');
    ok($W->is_tracked('t1', '3600abc0000000001'),
        'a WWID the array reported is imported into the tracking state');

    # 2. A listing with volumes but no WWIDs: the pass must be abandoned, and
    #    the WWID tracked from the earlier pass must survive it.
    Test::Plugin->reset_state();
    $Test::Plugin::VOLUMES{'pve-t1-100-disk0'} = { size => 1024, used => 0 };

    Test::Plugin->_cleanup_orphaned_devices('t1', $scfg);

    ok($W->is_tracked('t1', '3600abc0000000001'),
        'a listing without WWIDs does not count every device as missing');

    # 3. A volume that really is gone accumulates misses rather than being
    #    reaped on the first pass.
    Test::Plugin->reset_state();
    $Test::Plugin::VOLUMES{'pve-t1-101-disk0'} =
        { size => 1024, used => 0, wwid => '3600abc0000000002' };

    Test::Plugin->_cleanup_orphaned_devices('t1', $scfg);

    my $state = $W->read_state('t1');
    my $entry = $W->entry($state->{'3600abc0000000001'});
    is($entry->{miss}, 1, 'a volume the array no longer reports counts one miss');
    ok(!$W->is_reapable($entry), '... and is not reapable yet');
    ok($W->is_reapable({ first_seen => time() - 7200, miss => 3 }),
        'only after the grace period and the miss threshold both agree');
}

# ---------------------------------------------------------------------------
# Temporary snapshot-access clones are recorded and reaped
#
# Reading a snapshot creates a clone on the array. A worker killed before it
# can delete that clone leaves an object with no PVE volume name, so nothing
# lists it and the orphan reaper will not touch an object the array still has.
# ---------------------------------------------------------------------------

{
    my $state_dir = "$TMP/tmpclones";
    mkdir $state_dir;

    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::state_dir = sub { $state_dir };
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::lock_dir  = sub { $state_dir };
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::cleanup_lun_devices = sub { 1 };

    my $W = 'PVE::Storage::Custom::DellEMC::Common::WwidState';
    my $scfg = { 'dell-portal' => '10.0.0.1' };

    Test::Plugin->reset_state();

    my $live      = 'pve-t1-100-disk0-tmpsnap-live';
    my $abandoned = 'pve-t1-100-disk0-tmpsnap-dead';
    my $foreign   = 'someone-elses-object';

    $Test::Plugin::VOLUMES{$_} = { size => 1024, used => 0 }
        for ($live, $abandoned, $foreign);

    $W->track_temp_clone('t1', $live);
    $W->track_temp_clone('t1', $abandoned);
    $W->track_temp_clone('t1', $foreign);

    # Age one of them past the grace period and point it at a pid that is gone.
    # Pid 2 is kthreadd, which is alive, so it stands in for a live worker.
    my $state = $W->_read_temp_clones('t1');
    $state->{$abandoned} = { pid => 0x7FFFFFF, created => time() - 7200 };
    $state->{$foreign}   = { pid => 0x7FFFFFF, created => time() - 7200 };
    $W->_write_temp_clones('t1', $state);

    my $stale = $W->stale_temp_clones('t1');
    is_deeply([sort @$stale], [sort ($abandoned, $foreign)],
        'only clones past the grace period whose process is gone are stale');
    ok(!grep({ $_ eq $live } @$stale),
        'a clone created by a live process is never stale');

    Test::Plugin->_reap_temp_clones('t1', $scfg);

    ok(!$Test::Plugin::VOLUMES{$abandoned}, 'the abandoned clone is removed');
    ok($Test::Plugin::VOLUMES{$live}, 'the live one is left alone');
    ok($Test::Plugin::VOLUMES{$foreign},
        'an object outside this storage prefix is never touched');

    ok(!exists $W->_read_temp_clones('t1')->{$abandoned},
        'and its record is dropped');
    ok(!exists $W->_read_temp_clones('t1')->{$foreign},
        'as is the record of an object this storage does not own');

    # An entry for a clone that was never created must not keep coming back.
    $W->track_temp_clone('t1', 'pve-t1-100-disk0-tmpsnap-never');
    my $s2 = $W->_read_temp_clones('t1');
    $s2->{'pve-t1-100-disk0-tmpsnap-never'} = { pid => 0x7FFFFFF, created => time() - 7200 };
    $W->_write_temp_clones('t1', $s2);

    Test::Plugin->_reap_temp_clones('t1', $scfg);
    ok(!exists $W->_read_temp_clones('t1')->{'pve-t1-100-disk0-tmpsnap-never'},
        'a record for an object the array does not have is dropped');
}

# ---------------------------------------------------------------------------
# Deleting a snapshot releases the clone that was reading it
#
# This is the vzdump-in-snapshot-mode path, not an edge case: PVE takes a
# snapshot, reads it through path($volname, $snap) — which needs a clone of
# the snapshot on the array — and deletes the snapshot the moment the backup
# finishes. An array will not delete a snapshot something was cloned from, so
# without this every such backup fails at cleanup and leaves the clone behind
# on the array and its device on the host.
# ---------------------------------------------------------------------------

{
    my $state_dir = "$TMP/snapclones";
    mkdir $state_dir;

    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::state_dir = sub { $state_dir };
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::lock_dir  = sub { $state_dir };
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::cleanup_lun_devices = sub { 1 };
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_device = sub { undef };
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_slaves = sub { [] };

    my $W = 'PVE::Storage::Custom::DellEMC::Common::WwidState';
    my $scfg = { 'dell-portal' => '10.0.0.1' };

    Test::Plugin->reset_state();

    my $vol  = 'pve-t1-1699-disk0';
    my $snap = "$vol.pve-snap-vzdump";

    $Test::Plugin::VOLUMES{$vol} = { size => 1024, used => 0 };
    $Test::Plugin::SNAPSHOTS{$snap} = { volume => $vol, ctime => 1 };

    # path($volname, $snap) makes the clone.
    my ($temp, $fresh) = Test::Plugin->_prepare_snapshot_access(
        $scfg, 't1', 'vm-1699-disk-0', 'vzdump');

    ok($fresh, 'reading a snapshot creates a clone of it');
    ok($Test::Plugin::VOLUMES{$temp}, '... which exists on the array');
    is_deeply($W->temp_clones_of_snapshot('t1', $snap), [$temp],
        '... and is recorded against the snapshot it came from');

    # vzdump now deletes the snapshot.
    Test::Plugin->volume_snapshot_delete($scfg, 't1', 'vm-1699-disk-0', 'vzdump');

    ok(!$Test::Plugin::VOLUMES{$temp},
        'deleting the snapshot removes the clone that was reading it');
    ok(!$Test::Plugin::SNAPSHOTS{$snap}, '... and the snapshot itself is gone');
    is_deeply($W->temp_clones_of_snapshot('t1', $snap), [],
        '... leaving no record behind');

    # The clone is unmapped before it is deleted, as everywhere else.
    my $calls = join(' | ', @{ Test::Plugin->calls() });
    my @order = @{ Test::Plugin->calls() };
    my ($unmap_idx) = grep { $order[$_] =~ /^unmap \Q$temp\E/ } 0 .. $#order;
    my ($del_idx)   = grep { $order[$_] eq "delete $temp" } 0 .. $#order;
    ok(defined $unmap_idx && defined $del_idx && $unmap_idx < $del_idx,
        'the clone is unmapped before it is deleted');

    # A second delete of the same snapshot must stay quiet, not fail.
    my $again = eval { Test::Plugin->volume_snapshot_delete(
        $scfg, 't1', 'vm-1699-disk-0', 'vzdump'); 1 };
    ok($again, 'deleting a snapshot that is already gone is not an error');
}

# ---------------------------------------------------------------------------
# The reaper never touches a device that still has a working path
#
# A disk hot-added to a running VM is briefly absent from the array's bulk
# listing while the guest already has it open. QEMU's open file descriptor is
# not a holder and not a mount, so the in-use check does not see it. Pulling
# the map out from under the guest gives it I/O errors on a brand-new disk.
# ---------------------------------------------------------------------------

{
    my $state_dir = "$TMP/pathhealth";
    mkdir $state_dir;

    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::state_dir = sub { $state_dir };
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::lock_dir  = sub { $state_dir };
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::list_vendor_multipath_devices = sub { [] };
    # A real block device node, because the reaper only reaches the health
    # gate for a device that exists. Nothing here touches it: every call that
    # would is replaced below.
    my ($real_block) = grep { -b $_ }
        map { "/dev/$_" }
        do { opendir(my $dh, '/sys/block') or last; sort grep { !/^\./ } readdir($dh) };

    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::get_multipath_device =
        sub { $real_block };
    # Not a holder, not a mount: exactly what a running guest looks like.
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_device_in_use = sub { 0 };

    my $W = 'PVE::Storage::Custom::DellEMC::Common::WwidState';
    my $scfg = { 'dell-portal' => '10.0.0.1' };
    my $gone = '3600abc000000dead';

    my @flushed;
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::cleanup_lun_devices =
        sub { push @flushed, $_[0]; 1 };

    # -b on a path that does not exist is false, so the health gate is only
    # reached when the device looks real. Pretend it does.
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::multipath_path_health = sub { 1 };

    Test::Plugin->reset_state();

    SKIP: {
        skip 'no block device available to stand in for a multipath map', 3
            unless defined $real_block;

    # Tracked, long past the grace period, and missing from the array.
    $W->track_wwid('t1', $gone);
    my $state = $W->read_state('t1');
    $state->{$gone} = { first_seen => time() - 7200, miss => 5 };
    $W->write_state('t1', $state);

    Test::Plugin->_cleanup_orphaned_devices('t1', $scfg);

    is_deeply(\@flushed, [],
        'a device that still has a path is never flushed');
    ok($W->is_tracked('t1', $gone),
        'and it stays tracked so a later pass can reconsider it');

    # An unreadable path state is treated the same way as a live one.
    {
        local *PVE::Storage::Custom::DellEMC::Common::BlockBase::multipath_path_health = sub { -1 };
        Test::Plugin->_cleanup_orphaned_devices('t1', $scfg);
        is_deeply(\@flushed, [],
            'nor is one whose path state could not be read');
    }
    }
}

# ---------------------------------------------------------------------------
# Rolling back to anything but the most recent snapshot
#
# Dell documents what a restore does to the volume and says nothing about the
# snapshots taken after the one being restored. PVE's default is to allow any
# rollback, so on an array that discards them PVE would go on listing restore
# points that are gone. The unknown is treated as dangerous, and the operator
# who has verified their own array can lift it.
# ---------------------------------------------------------------------------

{
    Test::Plugin->reset_state();

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    my $vol  = 'pve-t1-100-disk0';

    $Test::Plugin::VOLUMES{$vol} = { size => 1024, used => 0 };
    $Test::Plugin::SNAPSHOTS{"$vol.pve-snap-old"} = { volume => $vol, ctime => 1000 };
    $Test::Plugin::SNAPSHOTS{"$vol.pve-snap-mid"} = { volume => $vol, ctime => 2000 };
    $Test::Plugin::SNAPSHOTS{"$vol.pve-snap-new"} = { volume => $vol, ctime => 3000 };

    my $blockers = [];
    my $ok = eval {
        Test::Plugin->volume_rollback_is_possible($scfg, 't1', 'vm-100-disk-0',
            'new', $blockers);
    };
    is($ok, 1, 'rolling back to the most recent snapshot is allowed');
    is_deeply($blockers, [], 'with nothing in the way');

    $blockers = [];
    $ok = eval {
        Test::Plugin->volume_rollback_is_possible($scfg, 't1', 'vm-100-disk-0',
            'old', $blockers);
    };
    ok(!$ok, 'rolling back past newer snapshots is refused');
    is_deeply([sort @$blockers], ['mid', 'new'],
        'and PVE is told exactly which snapshots are in the way');
    like($@, qr/dell-rollback-any-snapshot/,
        'the message says how to lift it after verifying the array');

    # The escape hatch.
    $blockers = [];
    $ok = eval {
        Test::Plugin->volume_rollback_is_possible(
            { %$scfg, 'dell-rollback-any-snapshot' => 1 },
            't1', 'vm-100-disk-0', 'old', $blockers);
    };
    is($ok, 1, 'an operator who has verified their array can allow it');

    # A snapshot the array does not have.
    ok(!eval {
        Test::Plugin->volume_rollback_is_possible($scfg, 't1', 'vm-100-disk-0',
            'nosuch', []);
    }, 'a snapshot that does not exist is refused');
    like($@, qr/does not exist/, '... saying so');

    # Unreadable timestamps must block, not be assumed to be old.
    Test::Plugin->reset_state();
    $Test::Plugin::VOLUMES{$vol} = { size => 1024, used => 0 };
    $Test::Plugin::SNAPSHOTS{"$vol.pve-snap-a"} = { volume => $vol, ctime => 0 };
    $Test::Plugin::SNAPSHOTS{"$vol.pve-snap-b"} = { volume => $vol, ctime => 0 };

    $blockers = [];
    ok(!eval {
        Test::Plugin->volume_rollback_is_possible($scfg, 't1', 'vm-100-disk-0',
            'a', $blockers);
    }, 'a snapshot whose age cannot be read counts against the rollback');
    is_deeply($blockers, ['b'], 'and is reported as the blocker');
}

# ---------------------------------------------------------------------------
# A resize is not finished when the array says it accepted it
#
# Refreshing the host side before the array reports the new capacity leaves
# the kernel with the old size, and QEMU then refuses to grow a volume that
# did in fact grow.
# ---------------------------------------------------------------------------

{
    Test::Plugin->reset_state();

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    my $vol  = 'pve-t1-100-disk0';
    $Test::Plugin::VOLUMES{$vol} = { size => 1024, used => 0 };

    ok(Test::Plugin->_await_volume_size($scfg, $vol, 1024),
        'a volume already at the requested size needs no waiting');
    ok(Test::Plugin->_await_volume_size($scfg, $vol, 512),
        'nor does one the array rounded up beyond the request');

    # An array that never reports the new size must not hang the caller.
    my $started = time();
    my $result = Test::Plugin->_await_volume_size($scfg, $vol, 4096, timeout => 2);
    my $elapsed = time() - $started;

    is($result, 0, 'a resize that never lands is reported as not landed');
    cmp_ok($elapsed, '<', 8, 'and the wait is bounded');

    # A volume that vanished mid-resize must not spin either.
    delete $Test::Plugin::VOLUMES{$vol};
    is(Test::Plugin->_await_volume_size($scfg, $vol, 4096, timeout => 1), 0,
        'a volume that is no longer there ends the wait');
}

# ---------------------------------------------------------------------------
# A refused activation leaves no node state behind
#
# Writing the multipath drop-in triggers the one permitted node-wide
# 'multipathd reconfigure'. A storage about to be REFUSED - FC with no HBA,
# iSCSI with no reachable portal - must refuse BEFORE that write: the
# reconfigure touches every vendor's maps on a shared node, and it was being
# paid for a storage that never came to exist.
# ---------------------------------------------------------------------------

SKIP: {
    skip 'PVE::Storage::Plugin is not available', 3
        unless eval { require PVE::Storage::Plugin; 1 };

    my $conf_written = 0;
    my $scfg = { 'dell-portal' => '10.0.0.1', 'dell-protocol' => 'fc' };

    no warnings 'redefine', 'once';
    local *Test::Plugin::_ensure_multipath_config = sub { $conf_written++; return 1 };
    # The node has no HBA, as far as this activation can tell.
    local *PVE::Storage::Custom::DellEMC::Common::BlockBase::is_fc_available = sub { 0 };

    my $ok = eval { Test::Plugin->activate_storage('t1', $scfg, {}); 1 };

    ok(!$ok, 'an FC storage on a node with no HBA is refused');
    like($@, qr/no FC HBA/, '... saying why');
    is($conf_written, 0,
        'and the multipath drop-in was never written for it - no node-wide'
      . ' reconfigure was paid for a storage that never came to exist');
}

# ---------------------------------------------------------------------------
# The array password never reaches storage.cfg
#
# PVE reads the sensitive list out of plugindata, by calling
# sensitive_properties($type) as a FUNCTION. A sensitive_properties METHOD on
# the class is never called - one shipped here for months, and the password
# went to /etc/pve/storage.cfg in clear text: group-readable by www-data,
# replicated to every node, and returned verbatim by GET /storage/<id>.
# ---------------------------------------------------------------------------

{
    my $sensitive = Test::Plugin->plugindata()->{'sensitive-properties'} // {};
    ok($sensitive->{'dell-password'},
        'plugindata declares the password sensitive - where PVE looks');

    my $opts = Test::Plugin->options();
    ok($opts->{'dell-password'}{optional},
        'and the option is optional, or PVE fails every add on the value it'
      . ' just stripped out');
}

{
    # The priv file wins; the config is the fallback that keeps a storage
    # created before this change working after an upgrade.
    my $dir = "/tmp/dellemc-pw-$$";
    mkdir $dir;

    no warnings 'redefine', 'once';
    local *Test::Plugin::_password_file = sub { "$dir/$_[1].pw" };

    my $scfg = { 'dell-password' => 'from-the-config' };

    is(Test::Plugin->_password($scfg, 'st1'), 'from-the-config',
        'a storage whose password is still in storage.cfg keeps working');

    Test::Plugin->_set_password('st1', 'from-the-priv-file');
    is(Test::Plugin->_password($scfg, 'st1'), 'from-the-priv-file',
        '... and the priv file takes over once it exists');

    my $mode = (stat("$dir/st1.pw"))[2] & 07777;
    is($mode, 0600, 'the priv file is readable only by root');

    Test::Plugin->_delete_password('st1');
    ok(!-e "$dir/st1.pw", 'deleting a storage removes its password file');
    is(Test::Plugin->_password($scfg, 'st1'), 'from-the-config',
        '... and the config fallback is what is left');

    is(Test::Plugin->_password({}, 'st1'), undef,
        'no file and no config value is undef, not an empty password');

    rmdir $dir;
}

# ---------------------------------------------------------------------------
# volume_export / volume_import
#
# The refusals, and the guard in front of the one operation here that writes
# over a whole volume. The copy itself needs a real device and is not driven
# from here; what is driven is everything that decides whether the copy runs.
# ---------------------------------------------------------------------------

{
    Test::Plugin->reset_state();

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    my $fh;   # never reached by any of these

    my @refusals = (
        ['qcow2+size', undef, undef, 0, qr/not available/,
            'a format this storage does not speak'],
        ['raw+size',   undef, undef, 1, qr/together with its snapshots/,
            'a stream carrying snapshots'],
        ['raw+size',   'snap1', undef, 0, qr/snapshot 'snap1'/,
            'exporting a snapshot'],
        ['raw+size',   undef, 'base', 0, qr/incremental/,
            'an incremental stream'],
    );

    for my $case (@refusals) {
        my ($format, $snap, $base, $withsnaps, $re, $what) = @$case;

        eval { Test::Plugin->volume_export($scfg, 't1', $fh, 'vm-100-disk-0',
            $format, $snap, $base, $withsnaps) };
        like($@, $re, "volume_export refuses $what");

        eval { Test::Plugin->volume_import($scfg, 't1', $fh, 'vm-100-disk-0',
            $format, $snap, $base, $withsnaps, 1) };
        like($@, $re, "volume_import refuses $what")
            unless $what =~ /exporting/;
    }

    is_deeply(Test::Plugin->calls(), [],
        'a refused transfer never reaches the array at all');
}

{
    Test::Plugin->reset_state();

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    $Test::Plugin::VOLUMES{'pve-t1-100-disk0'} = { size => 1024, used => 0 };

    eval { Test::Plugin->volume_import($scfg, 't1', undef, 'vm-100-disk-0',
        'raw+size', undef, undef, 0, 0) };
    like($@, qr/already exists on storage 't1'/,
        'importing onto an existing volume is refused when the caller cannot'
      . ' follow a rename');

    my $calls = join(' | ', @{ Test::Plugin->calls() });
    unlike($calls, qr/\bcreate\b/,
        '... and nothing was created before the refusal');
}

{
    Test::Plugin->reset_state();

    my $scfg = { 'dell-portal' => '10.0.0.1' };
    $Test::Plugin::VOLUMES{'pve-t1-100-disk0'} = { size => 1024, used => 0 };

    # The array cannot say which device this is.
    eval { Test::Plugin->_transfer_device($scfg, 't1', 'vm-100-disk-0') };
    like($@, qr/did not give a WWID/,
        'a transfer refuses a volume whose WWID the array will not give');

    no warnings 'redefine', 'once';
    no strict 'refs';
    local *Test::Plugin::_array_get_wwid = sub { '3600a0980deadbeef' };

    my $BB = 'PVE::Storage::Custom::DellEMC::Common::BlockBase';
    local *{"${BB}::get_device_by_wwid"}  = sub { undef };
    local *{"${BB}::is_block_device"}     = sub { 1 };
    local *{"${BB}::device_matches_wwid"} = sub { 1 };

    eval { Test::Plugin->_transfer_device($scfg, 't1', 'vm-100-disk-0') };
    like($@, qr/no device for WWID/,
        '... and one the kernel does not have at all');

    local *{"${BB}::get_device_by_wwid"}  = sub { '/dev/mapper/3600a0980deadbeef' };
    local *{"${BB}::device_matches_wwid"} = sub { 0 };

    eval { Test::Plugin->_transfer_device($scfg, 't1', 'vm-100-disk-0') };
    like($@, qr/kernel does not confirm/,
        '... and one the kernel does not confirm is the volume asked for —'
      . ' which is the case that would dd an image over the wrong disk');

    local *{"${BB}::device_matches_wwid"} = sub { 1 };

    my ($device, $wwid) = Test::Plugin->_transfer_device($scfg, 't1', 'vm-100-disk-0');
    is($device, '/dev/mapper/3600a0980deadbeef',
        'a confirmed device is handed back');
    is($wwid, '3600a0980deadbeef', '... with the WWID it was confirmed against');
}

done_testing();
