#!/usr/bin/perl
# Multipath helper tests. Only the parts that do not touch the kernel are
# exercised here; device behaviour belongs to the on-hardware test matrix.
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

use PVE::Storage::Custom::DellEMC::Common::Multipath qw(
    multipath_flush
    get_multipath_device
    get_device_by_wwid
    wait_for_multipath_device
    multipath_path_health
    get_multipath_slaves
    get_scsi_paths_for_wwid
    cleanup_lun_devices
    rescan_scsi_device
    remove_scsi_device
    multipath_resize_map
    is_device_in_use
    get_device_usage_details
    describe_wwid_state
    default_vendor_re
);

my $P = "PVE::Storage::Custom::DellEMC::Common::Multipath";
no strict "refs";
my $untaint_name = \&{"${P}::_untaint_device_name"};
my $untaint_path_dev = \&{"${P}::_untaint_device_path"};
my $untaint_path = \&{"${P}::_untaint_path"};
my $is_partition = \&{"${P}::_is_partition_dm_name"};
my $vg_from = \&{"${P}::_vg_from_dm_name"};
my $resolve_name = \&{"${P}::_resolve_block_device_name"};
use strict "refs";

# ---------------------------------------------------------------------------
# The flush guard is the single most important check in this module. A
# device-less flush is the capital-F form, which must never run: it removes
# every unused map on the node, including storage this plugin does not own.
# ---------------------------------------------------------------------------

eval { multipath_flush() };
like($@, qr/requires a device/, 'flush without a device is refused');
eval { multipath_flush('') };
like($@, qr/requires a device/, 'flush with an empty device is refused');
eval { multipath_flush(undef) };
like($@, qr/requires a device/, 'flush with undef is refused');

# The module must not contain the system-wide flush in any form.
{
    my $file = 'lib/PVE/Storage/Custom/DellEMC/Common/Multipath.pm';
    open(my $fh, '<', $file) or die "cannot read $file: $!";
    my @bad = grep { /multipath\s+-[A-Za-z]*F\b/ && !/never|NEVER|not/ } <$fh>;
    close($fh);
    is(scalar(@bad), 0, 'no system-wide flush anywhere in the module')
        or diag(join('', @bad));
}

# ---------------------------------------------------------------------------
# Required arguments
# ---------------------------------------------------------------------------

for my $case (
    [ 'get_multipath_device',      sub { get_multipath_device() },      qr/wwid is required/ ],
    [ 'get_device_by_wwid',        sub { get_device_by_wwid() },        qr/wwid is required/ ],
    [ 'wait_for_multipath_device', sub { wait_for_multipath_device() }, qr/wwid is required/ ],
    [ 'multipath_path_health',     sub { multipath_path_health() },     qr/wwid is required/ ],
    [ 'get_scsi_paths_for_wwid',   sub { get_scsi_paths_for_wwid() },   qr/wwid is required/ ],
    [ 'cleanup_lun_devices',       sub { cleanup_lun_devices() },       qr/wwid is required/ ],
    [ 'get_multipath_slaves',      sub { get_multipath_slaves() },      qr/mpath_device is required/ ],
    [ 'rescan_scsi_device',        sub { rescan_scsi_device() },        qr/device is required/ ],
    [ 'remove_scsi_device',        sub { remove_scsi_device() },        qr/device is required/ ],
    [ 'multipath_resize_map',      sub { multipath_resize_map() },      qr/device is required/ ],
) {
    my ($name, $code, $re) = @$case;
    eval { $code->() };
    like($@, $re, "$name validates its argument");
}

# ---------------------------------------------------------------------------
# Vendor gate
# ---------------------------------------------------------------------------

my $vendor = default_vendor_re();
like('DellEMC', $vendor, 'DellEMC matches the vendor gate');
like('DELL    ', $vendor, 'DELL matches');
like('DGC     ', $vendor, 'DGC (CLARiiON lineage) matches');
unlike('NETAPP  ', $vendor, 'NetApp does not match');
unlike('PURE    ', $vendor, 'Pure does not match');
unlike('IBM     ', $vendor, 'IBM does not match');
unlike('HITACHI ', $vendor, 'Hitachi does not match');

# ---------------------------------------------------------------------------
# Taint helpers
# ---------------------------------------------------------------------------

is($untaint_name->('sda'), 'sda', 'plain device name');
is($untaint_name->('dm-3'), 'dm-3', 'dm name');
is($untaint_name->('368ccf09800a1b2c3'), '368ccf09800a1b2c3', 'wwid map name');
is($untaint_name->('sda; rm -rf /'), undef, 'shell metacharacters rejected');
is($untaint_name->('../../etc/passwd'), undef, 'traversal rejected');
is($untaint_name->(undef), undef, 'undef rejected');

is($untaint_path_dev->('/dev/sda'), '/dev/sda', 'device path');
is($untaint_path_dev->('/dev/mapper/368ccf098'), '/dev/mapper/368ccf098', 'mapper path');
is($untaint_path_dev->('/etc/passwd'), undef, 'non-/dev path rejected');
is($untaint_path_dev->('/dev/sda; reboot'), undef, 'metacharacters rejected');

is($untaint_path->('/sys/block/sda/device/delete'), '/sys/block/sda/device/delete',
    'sysfs path accepted');
is($untaint_path->('/sys/block/`id`/delete'), undef, 'command substitution rejected');

# ---------------------------------------------------------------------------
# Partition and LVM name classification
#
# Getting this wrong in either direction is expensive: treating an LVM LV as a
# partition lets free_image delete a volume the host is using, while treating
# a partition as a real holder blocks deletion of every VM disk that has an OS
# installed on it.
# ---------------------------------------------------------------------------

for my $name (
    '368ccf09800a1b2c3d4e5f60718293a4b-part1',
    '368ccf09800a1b2c3d4e5f60718293a4bp1',
    '368ccf09800a1b2c3d4e5f60718293a4b1',
    'mystore-part3',
    'sdf1',
) {
    ok($is_partition->($name), "partition: $name");
}

for my $name (
    'pve-root',
    'checktc--vg-root',
    'vg0-lv_data',
    'crypt_data',
    '',
) {
    ok(!$is_partition->($name), "not a partition: $name");
}
ok(!$is_partition->(undef), 'undef is not a partition');

is($vg_from->('pve-root'), 'pve', 'plain VG name');
is($vg_from->('checktc--vg-root'), 'checktc-vg',
    'doubled hyphens decode to a literal hyphen in the VG name');
is($vg_from->('vg0-lv_data'), 'vg0', 'VG with underscore in the LV');
is($vg_from->('nolv'), undef, 'name without a separator has no VG');
is($vg_from->(''), undef, 'empty name has no VG');
is($vg_from->(undef), undef, 'undef has no VG');

# ---------------------------------------------------------------------------
# Device name resolution
# ---------------------------------------------------------------------------

is($resolve_name->('/dev/sda'), 'sda', 'plain path resolves');
is($resolve_name->('/dev/dm-3'), 'dm-3', 'dm path resolves');
is($resolve_name->(undef), undef, 'undef resolves to undef');

# ---------------------------------------------------------------------------
# Safe behaviour when the device does not exist
# ---------------------------------------------------------------------------

is(is_device_in_use('/dev/does-not-exist-12345'), 0,
    'a device that does not exist is not in use');
is(is_device_in_use(undef), 0, 'undef device is not in use');
like(get_device_usage_details('/dev/does-not-exist-12345'), qr/does not exist/,
    'usage details reports a missing device');
like(get_device_usage_details(undef), qr/not specified/,
    'usage details reports a missing argument');

is(describe_wwid_state(undef), '', 'diagnostics with no WWID returns empty');

# get_multipath_slaves on a path with no sysfs entry must return an empty
# list, not die: cleanup runs on half-removed devices by definition.
is_deeply(get_multipath_slaves('/dev/does-not-exist-12345'), [],
    'no slaves for a device that is gone');

# A WWID that cannot be a real one short-circuits before any sysfs scan.
is_deeply(get_scsi_paths_for_wwid('not-a-wwid'), [],
    'implausible WWID yields no paths');

# ---------------------------------------------------------------------------
# A file test on a device path is a kernel call
#
# -b stats the target, and on a multipath device whose paths have all failed
# while queueing is still on, that stat lands in the same uninterruptible
# sleep that hangs vgs. Every device path here is that kind of path.
# ---------------------------------------------------------------------------

{
    my $is_block = \&{"${P}::is_block_device"};

    is($is_block->(undef), 0, 'undef is not a block device');
    is($is_block->(''), 0, 'the empty string is not a block device');
    is($is_block->('/dev/definitely/not/here'), 0, 'nor is a path that does not exist');
    is($is_block->('/etc/hostname'), 0, 'nor is a regular file');

    my ($real) = grep { -b $_ }
        map { "/dev/$_" }
        do { opendir(my $dh, '/sys/block') or last; sort grep { !/^\./ } readdir($dh) };

    SKIP: {
        skip 'no block device on this host', 1 unless defined $real;
        is($is_block->($real), 1, "a real block device is recognised ($real)");
    }

    # The caller's own timeout must survive: nesting alarm() without putting
    # back what was left cancels it, which is worse than the hang it guards.
    my $left;
    eval {
        local $SIG{ALRM} = sub { die "outer\n" };
        alarm(5);
        $is_block->('/etc/hostname');
        $left = alarm(0);
    };
    alarm(0);

    ok(defined $left && $left > 0,
        'an alarm the caller had running is still running afterwards');
}

# ---------------------------------------------------------------------------
# The process list comes from stderr
#
# 'fuser -v' prints its table to stderr; only the bare PID list goes to
# stdout. Reading stdout alone means the operator is told a device is in use
# and never told by what.
# ---------------------------------------------------------------------------

{
    my $details = \&{"${P}::get_device_usage_details"};

    no strict 'refs';
    no warnings 'redefine';
    local *{"${P}::_run_cmd"} = sub {
        my ($cmd) = @_;
        return ('', "                     USER        PID ACCESS COMMAND\n"
                  . "/dev/mapper/x:       root      12345 F.... qemu-system-x86_64\n", 0)
            if $cmd->[0] =~ /fuser/;
        return ('', '', 0);
    };
    local *{"${P}::is_block_device"} = sub { 1 };
    local *{"${P}::_resolve_block_device_name"} = sub { 'dm-99' };

    my $text = $details->('/dev/mapper/x');

    like($text, qr/\[PROCESS\]/, 'the process section appears at all');
    like($text, qr/qemu-system-x86_64/,
        'and names the process holding the device, which fuser put on stderr');
}

# ---------------------------------------------------------------------------
# Reading a setting out of multipathd's merged configuration
#
# Debian defaults find_multipaths to 'strict', and with that setting a LUN
# with a single path never gets a map. A first hardware test with one session
# or one HBA port is exactly that case, and the operator sees "by-id links
# yes, map no" with no reason to connect the two.
# ---------------------------------------------------------------------------

{
    no warnings 'redefine', 'once';

    local *PVE::Storage::Custom::DellEMC::Common::Multipath::_run_cmd = sub {
        return (<<'CONF', '', 0);
defaults {
	verbosity 2
	user_friendly_names "yes"
	find_multipaths "strict"
}
devices {
	device {
		vendor "DellEMC"
		user_friendly_names "no"
	}
}
CONF
    };

    is(PVE::Storage::Custom::DellEMC::Common::Multipath::_multipath_setting(
        'find_multipaths'), 'strict', 'a global setting is read');

    # The per-device override is indented further and must not win: the
    # question being asked is what the node does by default.
    is(PVE::Storage::Custom::DellEMC::Common::Multipath::_multipath_setting(
        'user_friendly_names'), 'yes',
        'the defaults section answers, not a per-device override');

    is(PVE::Storage::Custom::DellEMC::Common::Multipath::_multipath_setting(
        'not_a_real_setting'), undef, 'an absent setting reads as undef');
}

{
    # multipathd that cannot be asked must answer undef, not die: this runs
    # inside a diagnostic that is already reporting a failure.
    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellEMC::Common::Multipath::_run_cmd =
        sub { die "timeout\n" };

    my $answer = eval {
        PVE::Storage::Custom::DellEMC::Common::Multipath::_multipath_setting(
            'find_multipaths');
    };
    ok(!$@, 'an unreachable multipathd does not take the diagnostic down')
        or diag("died with: $@");
    is($answer, undef, 'and the setting reads as unknown');
}

# ---------------------------------------------------------------------------
# Nothing this plugin does may disturb another storage's multipath maps
#
# 'multipathd reconfigure' re-reads every configuration file and reapplies it
# to every map on the node — another vendor's storage included. It used to be
# how a newly-mapped LUN was made to appear, on a timer and on every device
# wait. Claiming the paths for one WWID by name does the same job and touches
# nothing else.
# ---------------------------------------------------------------------------

{
    no warnings 'redefine', 'once';

    my @commands;
    local *PVE::Storage::Custom::DellEMC::Common::Multipath::_run_cmd = sub {
        my ($cmd) = @_;
        push @commands, join(' ', @$cmd);
        return ('', '', 0);
    };
    local *PVE::Storage::Custom::DellEMC::Common::Multipath::get_scsi_paths_for_wwid =
        sub { ['/dev/sdb', '/dev/sdc'] };

    my $n = PVE::Storage::Custom::DellEMC::Common::Multipath::multipath_claim_wwid(
        '3600abc0000000001');

    is($n, 2, 'every path found for the WWID is offered to multipathd');
    is_deeply(\@commands, [
        '/sbin/multipathd add path sdb',
        '/sbin/multipathd add path sdc',
    ], 'by name, one at a time');

    unlike(join(' ', @commands), qr/reconfigure/,
        'and never with a node-wide reconfigure')
        or diag('a reconfigure reapplies configuration to every map on the'
              . ' node, including storage this plugin does not manage');
}

{
    # No paths for the WWID: nothing to claim, and nothing node-wide as a
    # consolation prize.
    no warnings 'redefine', 'once';

    my @commands;
    local *PVE::Storage::Custom::DellEMC::Common::Multipath::_run_cmd =
        sub { push @commands, join(' ', @{ $_[0] }); return ('', '', 0) };
    local *PVE::Storage::Custom::DellEMC::Common::Multipath::get_scsi_paths_for_wwid =
        sub { [] };

    is(PVE::Storage::Custom::DellEMC::Common::Multipath::multipath_claim_wwid('3600x'),
        0, 'no paths means nothing claimed');
    is_deeply(\@commands, [], 'and no command at all is run');
}

# The periodic rescan in activate_storage must not reconfigure the node. It
# runs on a timer whether or not anything changed, so a node-wide operation
# there is a node-wide operation every few minutes, forever.
{
    my $source = '';
    for my $path ('lib/PVE/Storage/Custom/DellEMC/Common/BlockBase.pm',
                  '../lib/PVE/Storage/Custom/DellEMC/Common/BlockBase.pm') {
        next unless open(my $fh, '<', $path);
        local $/;
        $source = <$fh>;
        close($fh);
        last;
    }

  SKIP: {
        skip 'BlockBase.pm is not readable from here', 2 unless length $source;

        # One call site only: the drop-in writer, where there is no
        # alternative because multipathd has no per-file reload.
        my $calls = () = $source =~ /^\s*(?:eval \{\s*)?multipath_reload\(/mg;
        is($calls, 1, 'exactly one node-wide reconfigure remains in BlockBase')
            or diag("found $calls; the only justified one is after writing"
                  . " this plugin's own multipath drop-in");

        unlike($source, qr/multipath_reload_throttled\(/,
            'and the periodic rescan paths do not reconfigure the node');
    }
}

done_testing();
