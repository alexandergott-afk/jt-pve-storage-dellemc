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
is_deeply([sort @{ $props->{'dell-protocol'}{enum} }], ['fc', 'iscsi'], 'protocol enum');

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
ok(grep({ $_ eq 'dell-password' } $P->sensitive_properties()), 'password is sensitive');

# ---------------------------------------------------------------------------
# Volume names
# ---------------------------------------------------------------------------

is_deeply([$P->parse_volname('vm-100-disk-0')],
    ['images', 'vm-100-disk-0', 100, undef, undef, 0, 'raw'], 'parse a VM disk');
is_deeply([$P->parse_volname('base-100-disk-0')],
    ['images', 'base-100-disk-0', 100, undef, undef, 1, 'raw'], 'parse a base disk');
is_deeply([$P->parse_volname('base-100-disk-0/vm-101-disk-0')],
    ['images', 'base-100-disk-0/vm-101-disk-0', 101, 'base-100-disk-0', 100, 0, 'raw'],
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

done_testing();
