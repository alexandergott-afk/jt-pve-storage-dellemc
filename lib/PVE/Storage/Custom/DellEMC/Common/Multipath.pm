# Dell EMC storage plugins for Proxmox VE - dm-multipath and SCSI devices
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::Multipath;

use strict;
use warnings;

use Carp qw(croak);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use File::Basename qw(basename dirname);
use POSIX ();

use Exporter qw(import);

our @EXPORT_OK = qw(
    sysfs_write_with_timeout
    sysfs_read_with_timeout
    rescan_scsi_hosts
    rescan_scsi_device
    remove_scsi_device
    udev_refresh
    multipath_reload
    multipath_reload_throttled
    multipath_resize_map
    multipath_flush
    multipath_path_health
    get_multipath_device
    get_device_by_wwid
    wait_for_multipath_device
    get_multipath_slaves
    get_scsi_paths_for_wwid
    list_vendor_multipath_devices
    list_vendor_scsi_paths
    cleanup_lun_devices
    is_block_device
    is_device_in_use
    get_device_usage_details
    describe_wwid_state
    default_vendor_re
);

# Host-side device handling shared by the Dell EMC block plugins. Ported from
# the Pure Storage and NetApp ONTAP plugins, with the vendor gate turned into
# a parameter.
#
# Two rules run through the whole module and must survive any edit:
#
#   1. `multipath -F` (capital F) is never generated. It flushes every unused
#      map on the node, including storage this plugin does not own. Only
#      `multipath -f <device>` appears here, and multipath_flush() refuses to
#      run without a device argument.
#
#   2. Nothing touches the kernel without a bound on how long it may block.
#      Storage that stops answering puts a plain open()/read() into
#      uninterruptible sleep (D state), which no signal clears; the process
#      is then unkillable and every later caller queues behind it, which is
#      how a single dead LUN takes down pvestatd and pvedaemon on a node.
#      Every sysfs access goes through a forked, timeout-bounded helper and
#      every external command through _run_cmd's alarm.

use constant {
    MULTIPATHD => '/sbin/multipathd',
    MULTIPATH  => '/sbin/multipath',
    DMSETUP    => '/sbin/dmsetup',
    KPARTX     => '/sbin/kpartx',
    BLOCKDEV   => '/sbin/blockdev',
    UDEVADM    => '/sbin/udevadm',
    SYNC       => '/bin/sync',
    FUSER      => '/bin/fuser',

    SCSI_HOST_PATH    => '/sys/class/scsi_host',
    ISCSI_HOST_PATH   => '/sys/class/iscsi_host',
    BLOCK_DEVICE_PATH => '/sys/class/block',

    DEVICE_WAIT_TIMEOUT  => 60,
    DEVICE_WAIT_INTERVAL => 1,

    # A host-wide `multipathd reconfigure` is expensive and global. Several
    # long-lived callers (pvedaemon workers, pvestatd) would otherwise issue
    # it independently and turn device discovery into a reconfigure storm.
    RECONFIGURE_MIN_INTERVAL => 30,

    # Wall-clock budget for sweeps over every sd device on the node. A per-read
    # timeout does not bound a loop: on a host with hundreds of paths, during a
    # teardown when reads are slow, the sum is what hurts.
    SCAN_BUDGET_SECONDS => 30,
    SCAN_READ_TIMEOUT   => 3,
};

# Process-wide, deliberately: see RECONFIGURE_MIN_INTERVAL.
my $LAST_RECONFIGURE = 0;

# Which SCSI vendor strings belong to us. 'DellEMC' is what PowerStore is
# expected to report; DGC and EMC cover the older CLARiiON/VNX lineage that
# Unity and PowerStore inherited from. NOT YET VERIFIED against hardware —
# confirm with `sg_inq /dev/sdX` and narrow this before relying on it.
sub default_vendor_re { qr/DellEMC|DELL\s*EMC|DELL|EMC|DGC/i }

sub _vendor_re {
    my ($opts) = @_;
    return $opts->{vendor} if $opts && $opts->{vendor};
    return default_vendor_re();
}

# ---------------------------------------------------------------------------
# Taint handling
#
# PVE runs plugin code under taint mode. Anything read from sysfs, from
# multipathd output or from a device path is tainted and cannot be passed to
# a command until it has been matched by a regexp.
# ---------------------------------------------------------------------------

sub _untaint_device_name {
    my ($name) = @_;
    return undef unless defined $name;
    return $1 if $name =~ /^([a-zA-Z0-9_\-]+)$/;
    return undef;
}

sub _untaint_device_path {
    my ($path) = @_;
    return undef unless defined $path;
    return $1 if $path =~ m|^(/dev/[a-zA-Z0-9_\-/\.]+)$|;
    return undef;
}

sub _untaint_path {
    my ($path) = @_;
    return undef unless defined $path;
    return $1 if $path =~ m|^([a-zA-Z0-9_\-/\.]+)$|;
    return undef;
}

# Resolve any of /dev/sdX, /dev/dm-N, /dev/mapper/<name> to the kernel name
# used under /sys/block.
sub _resolve_block_device_name {
    my ($device) = @_;
    return undef unless defined $device;

    if (-l $device) {
        my $target = readlink($device);
        if (defined $target) {
            if ($target !~ m|^/|) {
                $target = dirname($device) . "/$target";
            }
            while ($target =~ s|/[^/]+/\.\./|/|g) { }
            $device = $target;
        }
    }

    return _untaint_device_name(basename($device));
}

# ---------------------------------------------------------------------------
# Bounded file tests
# ---------------------------------------------------------------------------

# -b, bounded.
#
# A Perl file test is a stat(2), and stat on a path under /dev is not free:
# for a symlink it resolves the target first, and on a multipath device whose
# paths have all failed while queueing is still on, that lands in the same
# uninterruptible sleep that hangs vgs. Every device path this plugin touches
# is exactly that kind of path, so none of them may be tested unguarded.
#
# An outer alarm is preserved: alarm(0) returns what was left of it, and that
# is put back afterwards. Nesting alarms without doing this silently cancels
# the caller's own timeout, which is worse than the problem being solved.
sub is_block_device {
    my ($path, %opts) = @_;

    return 0 unless defined $path && length $path;

    my $timeout   = $opts{timeout} // 3;
    my $remaining = alarm(0);

    my $result = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);
        $result = (-b $path) ? 1 : 0;
        alarm(0);
    };
    alarm(0);

    if ($@) {
        warn "stat of $path did not return within ${timeout}s; treating it as"
           . " unusable\n";
        $result = 0;
    }

    alarm($remaining) if $remaining;

    return $result;
}

# ---------------------------------------------------------------------------
# Bounded sysfs access
# ---------------------------------------------------------------------------

# Write to sysfs in a child process. Returns 1 on success, 0 on failure or
# timeout. The child is what may end up stuck in D state; the parent stays
# responsive either way.
sub sysfs_write_with_timeout {
    my ($path, $data, $timeout) = @_;
    $timeout //= 10;

    my $pid = fork();
    if (!defined $pid) {
        warn "fork failed for sysfs write to $path: $!\n";
        return 0;
    }

    if ($pid == 0) {
        eval {
            open(my $fh, '>', $path) or die "open: $!";
            print $fh $data;
            close($fh) or die "close: $!";
        };
        POSIX::_exit($@ ? 1 : 0);
    }

    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $res = waitpid($pid, POSIX::WNOHANG());
        return ($? >> 8) == 0 ? 1 : 0 if $res > 0;
        return 1 if $res < 0;
        select(undef, undef, undef, 0.1);
    }

    warn "sysfs write to $path timed out after ${timeout}s, killing child pid $pid\n";
    kill('KILL', $pid);
    my $reaped = waitpid($pid, POSIX::WNOHANG());
    warn "child pid $pid is in uninterruptible sleep and cannot be reaped\n"
        if $reaped == 0;

    return 0;
}

# Read a sysfs/proc file in a child process. Returns the content, or undef on
# timeout or failure.
sub sysfs_read_with_timeout {
    my ($path, $timeout) = @_;
    $timeout //= 5;

    pipe(my $read_fh, my $write_fh) or do {
        warn "pipe failed for sysfs read of $path: $!\n";
        return undef;
    };

    my $pid = fork();
    if (!defined $pid) {
        warn "fork failed for sysfs read of $path: $!\n";
        close($read_fh);
        close($write_fh);
        return undef;
    }

    if ($pid == 0) {
        close($read_fh);
        eval {
            open(my $fh, '<', $path) or die "open: $!";
            local $/;
            my $data = <$fh>;
            close($fh);
            print $write_fh ($data // '');
        };
        close($write_fh);
        POSIX::_exit($@ ? 1 : 0);
    }

    close($write_fh);
    my $content = '';

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);
        while (1) {
            my $buf;
            my $bytes = sysread($read_fh, $buf, 65536);
            last if !defined($bytes) || $bytes == 0;
            $content .= $buf;
        }
        alarm(0);
    };
    my $timed_out = $@;
    alarm(0);
    close($read_fh);

    if ($timed_out) {
        warn "sysfs read of $path timed out after ${timeout}s, killing child pid $pid\n";
        kill('KILL', $pid);
        waitpid($pid, POSIX::WNOHANG());
        return undef;
    }

    waitpid($pid, 0);
    return length($content) ? $content : undef;
}

# ---------------------------------------------------------------------------
# External commands
# ---------------------------------------------------------------------------

sub _reap_timed_out_child {
    my ($pid, $cmd) = @_;
    return unless $pid;

    for my $sig ('TERM', 'KILL') {
        kill($sig, $pid);
        my $deadline = time() + 2;
        while (time() < $deadline) {
            my $res = waitpid($pid, POSIX::WNOHANG());
            return if $res != 0;
            select(undef, undef, undef, 0.1);
        }
    }

    warn "child pid $pid for '@{$cmd // []}' did not die after TERM+KILL"
       . " (likely uninterruptible sleep in the kernel); leaving it to init\n";
}

sub _run_cmd {
    my ($cmd, %opts) = @_;

    my $timeout = $opts{timeout} // 30;
    my ($stdout, $stderr) = ('', '');
    my $err = gensym;
    my $pid;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        # The output of some of these is parsed, and util-linux tools ship
        # translations: a node running in another language answers with
        # another language. Pin the child to C so what comes back is what the
        # parsers were written against. This is not hypothetical here — the
        # nodes this plugin is written for are as likely to run zh_TW as en_US.
        local $ENV{LC_ALL} = 'C';
        local $ENV{LANG}   = 'C';

        $pid = open3(my $in, my $out, $err, @$cmd);
        close($in);

        # Read both streams: a full stderr pipe would otherwise deadlock the
        # child while we wait on stdout.
        my $sel = IO::Select->new($out, $err);
        while (my @ready = $sel->can_read()) {
            for my $fh (@ready) {
                my $buf;
                my $bytes = sysread($fh, $buf, 8192);
                if (!defined($bytes) || $bytes == 0) {
                    $sel->remove($fh);
                    next;
                }
                if ($fh == $out) { $stdout .= $buf } else { $stderr .= $buf }
            }
        }

        waitpid($pid, 0);
        alarm(0);
    };

    if ($@) {
        alarm(0);
        my $error = $@;
        _reap_timed_out_child($pid, $cmd);
        croak "Command timed out after ${timeout}s: @$cmd" if $error eq "timeout\n";
        croak "Command failed: $error";
    }

    my $exit_code = $? >> 8;

    if ($exit_code != 0 && !$opts{ignore_errors} && !$opts{allow_nonzero}) {
        croak "Command failed (exit $exit_code): @$cmd\nstderr: $stderr";
    }

    return wantarray ? ($stdout, $stderr, $exit_code) : $stdout;
}

# ---------------------------------------------------------------------------
# SCSI scanning
# ---------------------------------------------------------------------------

# Rescan iSCSI hosts for newly mapped LUNs.
#
# The host list comes from /sys/class/iscsi_host, never from
# /sys/class/scsi_host. Writing "- - -" to a non-iSCSI host's scan file asks
# that driver for a full target rescan, which on some HBA drivers blocks in
# the kernel for hundreds of seconds (observed on HPE ProLiant smartpqi:
# 600+ seconds in sas_user_scan). Everything that later touches that host
# directory queues behind it, so one such write stalls VM operations and the
# pvestatd poll across the node. Every iSCSI transport driver registers into
# /sys/class/iscsi_host, and no SAS/RAID/USB/NVMe controller appears there,
# which makes iterating it both complete and safe. FC has its own path in
# FC.pm using /sys/class/fc_host.
sub rescan_scsi_hosts {
    my (%opts) = @_;

    my $class = ISCSI_HOST_PATH;
    return 1 unless -d $class;

    opendir(my $dh, $class) or return 1;
    my @hosts = grep { /^host\d+$/ } readdir($dh);
    closedir($dh);

    return 1 unless @hosts;

    for my $host (@hosts) {
        ($host) = $host =~ /^(host\d+)$/;
        next unless $host;

        my $scan_file = SCSI_HOST_PATH . "/$host/scan";
        sysfs_write_with_timeout($scan_file, "- - -\n", 10) if -w $scan_file;
    }

    sleep($opts{delay} // 2);

    return 1;
}

# Re-read the capacity of one SCSI device, after the array grew the volume.
sub rescan_scsi_device {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    my $name = _untaint_device_name(basename($device));
    croak "Invalid device name" unless $name;

    my $rescan_file = BLOCK_DEVICE_PATH . "/$name/device/rescan";
    if (-w $rescan_file) {
        sysfs_write_with_timeout($rescan_file, "1\n", 10)
            or croak "Failed to write to $rescan_file (timed out or error)";
        return 1;
    }

    croak "Cannot find rescan file for device $device";
}

sub remove_scsi_device {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    my $name = _untaint_device_name(basename($device));
    croak "Invalid device name" unless $name;

    my $safe_device = _untaint_path($device);
    my $delete_file = BLOCK_DEVICE_PATH . "/$name/device/delete";

    croak "Cannot find delete file for device $device" unless -w $delete_file;

    eval { _run_cmd([SYNC], timeout => 10, allow_nonzero => 1, ignore_errors => 1) };
    if ($safe_device && is_block_device($safe_device)) {
        eval { _run_cmd([BLOCKDEV, '--flushbufs', $safe_device],
            timeout => 10, allow_nonzero => 1, ignore_errors => 1) };
    }

    sysfs_write_with_timeout($delete_file, "1\n", 10)
        or croak "Failed to write to $delete_file (timed out or error)";

    return 1;
}

# Ask udev to create the /dev nodes and by-id symlinks for devices the kernel
# already knows about.
sub udev_refresh {
    my (%opts) = @_;

    eval { _run_cmd([UDEVADM, 'trigger', '--subsystem-match=block'],
        timeout => 10, allow_nonzero => 1, ignore_errors => 1) };
    eval { _run_cmd([UDEVADM, 'settle', '--timeout=' . ($opts{settle} // 5)],
        timeout => 15, allow_nonzero => 1, ignore_errors => 1) };

    return 1;
}

# ---------------------------------------------------------------------------
# multipathd
# ---------------------------------------------------------------------------

sub multipath_reload {
    my (%opts) = @_;

    $LAST_RECONFIGURE = time();
    _run_cmd([MULTIPATHD, 'reconfigure'],
        allow_nonzero => 1, ignore_errors => 1, timeout => $opts{timeout} // 30);

    return 1;
}

# Rate-limited reconfigure for discovery and polling paths. Returns 1 when a
# reconfigure was issued, 0 when the cooldown suppressed it.
sub multipath_reload_throttled {
    my (%opts) = @_;

    my $interval = $opts{min_interval} // RECONFIGURE_MIN_INTERVAL;
    return 0 if (time() - $LAST_RECONFIGURE) < $interval;

    eval { multipath_reload(%opts) };
    warn "multipath reconfigure failed: $@" if $@;

    return 1;
}

# Make multipathd re-read the size of an existing map, after the array grew
# the volume and the SCSI paths were rescanned. Without this the map keeps
# reporting the old size and QEMU's block_resize fails with "Cannot grow
# device files" even though everything below it already grew.
sub multipath_resize_map {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    my $name = _untaint_device_name(basename($device));
    return 0 unless $name;

    eval {
        _run_cmd([MULTIPATHD, 'resize', 'map', $name],
            allow_nonzero => 1, ignore_errors => 1, timeout => $opts{timeout} // 15);
    };

    return $@ ? 0 : 1;
}

# Flush ONE map, named by device path, map name or WWID.
#
# The device argument is mandatory and there is deliberately no flush-all
# mode. `multipath -F` is never issued here: it would remove every unused map
# on the node, including maps belonging to storage this plugin does not
# manage. Callers that think they want flush-all want a loop over their own
# WWIDs instead.
#
# `multipath -f` itself can block forever on a map with queued I/O and no
# working path, so the call is bounded and falls back to dmsetup, which does
# not wait for that I/O.
sub multipath_flush {
    my ($device, %opts) = @_;

    croak "multipath_flush requires a device; refusing to flush every map on"
        . " the node" unless defined $device && length $device;

    my $timeout = $opts{timeout} // 10;

    my (undef, undef, $exit) = eval {
        _run_cmd([MULTIPATH, '-f', $device],
            allow_nonzero => 1, ignore_errors => 1, timeout => $timeout);
    };
    my $err = $@;

    if ($err || (defined $exit && $exit != 0)) {
        warn "multipath -f $device failed or timed out, trying dmsetup remove --force\n";
        my $name = _untaint_device_name(basename($device));
        if ($name) {
            eval {
                _run_cmd([DMSETUP, 'remove', '--force', '--retry', $name],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 10);
            };
            warn "dmsetup remove also failed for $name: $@" if $@;
        }
    }

    return 1;
}

# Does the map for $wwid still have a usable path?
#
#   1  at least one active path — the device is live, do NOT reap it
#   0  the map exists and every path has failed — orphan candidate
#  -1  undeterminable (multipathd unreachable or output unparseable)
#
# Callers must treat -1 exactly like 1. A wrong "it is dead" tears down a
# device that a running VM is using; a wrong "it is alive" only leaves a
# stale map for the next pass to reconsider.
sub multipath_path_health {
    my ($wwid) = @_;

    croak "wwid is required" unless $wwid;

    my ($maps) = eval {
        _run_cmd([MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w'],
            allow_nonzero => 1, ignore_errors => 1, timeout => 10);
    };
    return -1 unless defined $maps;

    my $want = lc($wwid);
    my $map_name;
    for my $line (split /\n/, $maps) {
        $line =~ s/^\s+|\s+$//g;
        my ($name, $map_wwid) = split /\s+/, $line, 2;
        next unless $name && $map_wwid;
        if (lc($map_wwid) eq $want) {
            $map_name = $name;
            last;
        }
    }
    # No map at all: nothing live to protect, and the caller's cleanup is
    # idempotent.
    return 0 unless defined $map_name;

    #   %m map the path belongs to, %t device-mapper path state,
    #   %o device state
    my ($paths) = eval {
        _run_cmd([MULTIPATHD, 'show', 'paths', 'raw', 'format', '%m %t %o'],
            allow_nonzero => 1, ignore_errors => 1, timeout => 10);
    };
    return -1 unless defined $paths;

    my $saw_path = 0;
    for my $line (split /\n/, $paths) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        my ($m, $dm_state, $dev_state) = split /\s+/, $line;
        next unless defined $m && $m eq $map_name;
        $saw_path = 1;
        my $dev_ok = !defined $dev_state || $dev_state ne 'offline';
        return 1 if defined $dm_state && $dm_state eq 'active' && $dev_ok;
    }

    return $saw_path ? 0 : -1;
}

sub get_multipath_device {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my ($stdout) = eval {
        _run_cmd([MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w'],
            allow_nonzero => 1, ignore_errors => 1, timeout => $opts{timeout} // 10);
    };
    return undef unless defined $stdout;

    my $want = lc($wwid);
    for my $line (split /\n/, $stdout) {
        $line =~ s/^\s+|\s+$//g;
        my ($name, $map_wwid) = split /\s+/, $line, 2;
        next unless $name && $map_wwid;
        next unless lc($map_wwid) eq $want;

        my $safe_name = _untaint_device_name($name);
        return undef unless $safe_name;
        return _untaint_device_path("/dev/mapper/$safe_name");
    }

    return undef;
}

sub get_device_by_wwid {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my $mpath = get_multipath_device($wwid);
    return $mpath if $mpath && is_block_device($mpath);

    # Fall back to udev's by-id links: the map may exist without multipathd
    # answering, or the LUN may have a single path.
    #
    # The -b test belongs INSIDE the alarm with the glob. It resolves the
    # symlink to /dev/sd* or /dev/dm-*, and stat() on a multipath device whose
    # paths are all down while queueing is still on hits the same block-layer
    # wait that hangs vgs. A timeout around the glob alone leaves the stat
    # unbounded, which is the half that actually blocks.
    (my $safe_wwid = $wwid) =~ s/([\[\]{}*?\\])/\\$1/g;
    my $found;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($opts{glob_timeout} // 5);

        my @devices = glob("/dev/disk/by-id/wwn-*$safe_wwid*");
        push @devices, glob("/dev/disk/by-id/scsi-*$safe_wwid*");

        for my $device (@devices) {
            next unless is_block_device($device);
            $found = $device;
            last;
        }

        alarm(0);
    };
    alarm(0);

    return _untaint_device_path($found) if defined $found;

    return undef;
}

# Wait for the multipath device of a freshly mapped volume to appear,
# escalating only as far as needed. Each step is more expensive and more
# global than the last, so the cheap ones run first and the host-wide
# reconfigure is a last resort.
#
# opts:
#   timeout       overall budget, default 60s
#   interval      poll interval between escalations, default 1s
#   iscsi_rescan  coderef, transport-level rescan (ISCSI.pm)
#   fc_rescan     coderef, transport-level rescan (FC.pm)
sub wait_for_multipath_device {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my $timeout  = $opts{timeout}  // DEVICE_WAIT_TIMEOUT;
    my $interval = $opts{interval} // DEVICE_WAIT_INTERVAL;
    my $deadline = time() + $timeout;

    my $probe = sub {
        my $device = get_device_by_wwid($wwid);
        return ($device && is_block_device($device)) ? $device : undef;
    };

    # It may already be here; that costs one multipathd query to find out.
    my $device = $probe->();
    return $device if $device;

    my $round = 0;
    while (time() < $deadline) {
        $round++;

        # Step 1: ask the transport to look for new LUNs.
        for my $hook (qw(iscsi_rescan fc_rescan)) {
            my $code = $opts{$hook};
            eval { $code->() } if $code && ref($code) eq 'CODE';
        }
        $device = $probe->();
        return $device if $device;
        last if time() >= $deadline;

        # Step 2: make the kernel enumerate new LUNs.
        eval { rescan_scsi_hosts(delay => 1) };
        $device = $probe->();
        return $device if $device;
        last if time() >= $deadline;

        # Step 3: udev, which creates the /dev/mapper node. Usually the only
        # thing still missing.
        udev_refresh();
        $device = $probe->();
        return $device if $device;
        last if time() >= $deadline;

        # Step 4: host-wide reconfigure. Skipped on the first round and rate
        # limited process-wide so concurrent callers cannot storm it.
        if ($round >= 2) {
            multipath_reload_throttled();
            $device = $probe->();
            return $device if $device;
        }

        # Step 5: poll cheaply until the next escalation round.
        my $next_round = time() + 5;
        while (time() < $next_round && time() < $deadline) {
            sleep($interval);
            $device = $probe->();
            return $device if $device;
        }
    }

    return undef;
}

sub get_multipath_slaves {
    my ($mpath_device, %opts) = @_;

    croak "mpath_device is required" unless $mpath_device;

    my $name = _resolve_block_device_name($mpath_device);
    return [] unless $name;

    my $slaves_dir = "/sys/block/$name/slaves";
    return [] unless -d $slaves_dir;

    opendir(my $dh, $slaves_dir) or return [];
    my @slaves;
    for my $slave (readdir($dh)) {
        next if $slave =~ /^\./;
        my $safe = _untaint_device_name($slave);
        push @slaves, "/dev/$safe" if $safe;
    }
    closedir($dh);

    return \@slaves;
}

# ---------------------------------------------------------------------------
# Enumeration
# ---------------------------------------------------------------------------

# Every multipath map whose vendor/product string is ours.
# Returns arrayref of { name, wwid, vps }.
sub list_vendor_multipath_devices {
    my (%opts) = @_;

    my $vendor_re = _vendor_re(\%opts);

    my ($stdout) = eval {
        _run_cmd([MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w %s'],
            allow_nonzero => 1, ignore_errors => 1, timeout => 10);
    };
    return [] unless defined $stdout;

    my @devices;
    for my $line (split /\n/, $stdout) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        my ($name, $wwid, $vps) = split /\s+/, $line, 3;
        next unless $name && $wwid && $vps;
        next unless $vps =~ $vendor_re;
        push @devices, { name => $name, wwid => $wwid, vps => $vps };
    }

    return \@devices;
}

# Every local sd* path that belongs to $wwid, including stale ones that are no
# longer part of the map.
#
# Those stale paths matter: once a volume is unmapped, an sd left bound to the
# freed H:C:T:L blocks the array from reusing that SCSI LUN-ID for a different
# volume. The kernel then logs "LUN assignments on this target have changed"
# and the new volume is unusable on that path. get_multipath_slaves() cannot
# find them because they already dropped out of the map.
#
# Vendor-gated, so it never removes another vendor's device.
sub get_scsi_paths_for_wwid {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my $vendor_re = _vendor_re(\%opts);

    # The multipath WWID is '3' + the NAA designator; sysfs reports the NAA.
    (my $naa = lc($wwid)) =~ s/^3//;
    return [] unless $naa =~ /^[0-9a-f]{8,}$/;

    my $deadline = time() + ($opts{budget} // SCAN_BUDGET_SECONDS);
    my $read_to  = $opts{read_timeout} // SCAN_READ_TIMEOUT;

    opendir(my $dh, '/sys/block') or return [];
    my @blocks = grep { /^sd[a-z]+$/ } readdir($dh);
    closedir($dh);

    my @devs;
    my $bailed = 0;
    for my $b (@blocks) {
        if (time() >= $deadline) { $bailed = 1; last }

        ($b) = $b =~ /^(sd[a-z]+)$/;
        next unless $b;

        my $vendor = sysfs_read_with_timeout("/sys/block/$b/device/vendor", $read_to) // '';
        next unless $vendor =~ $vendor_re;

        my $match = 0;

        my $wwid_attr = sysfs_read_with_timeout("/sys/block/$b/device/wwid", $read_to) // '';
        $match = 1 if length($wwid_attr) && lc($wwid_attr) =~ /\Q$naa\E/;

        # Older kernels may not expose the wwid attribute; fall back to the
        # raw VPD page 0x83.
        if (!$match) {
            my $pg83 = sysfs_read_with_timeout("/sys/block/$b/device/vpd_pg83", $read_to);
            if (defined $pg83 && length $pg83) {
                $match = 1 if unpack("H*", $pg83) =~ /\Q$naa\E/i;
            }
        }

        push @devs, "/dev/$b" if $match;
    }

    warn "get_scsi_paths_for_wwid: scan budget exceeded for WWID $wwid;"
       . " some stale paths were not swept this pass\n" if $bailed;

    return \@devs;
}

# Every local sd* path of ours, with the topology facts needed to decide
# whether a path is a leftover.
#
# Unlike get_scsi_paths_for_wwid(), which matches a known WWID, this also
# finds paths whose backing volume is gone and which therefore report no
# usable WWID at all. Those are what make device-mapper refuse a new map with
# "error getting device (-EBUSY)" after the array reuses a freed LUN-ID.
#
# Returns arrayref of hashrefs:
#   dev, hctl, lun, target_id, wwid, has_holders, mounted
sub list_vendor_scsi_paths {
    my (%opts) = @_;

    my $vendor_re = _vendor_re(\%opts);
    my $deadline  = time() + ($opts{budget} // SCAN_BUDGET_SECONDS);
    my $read_to   = $opts{read_timeout} // SCAN_READ_TIMEOUT;

    # Read the mount and swap tables once instead of per device.
    my %in_use_src;
    for my $file ('/proc/mounts', '/proc/swaps') {
        my $content = sysfs_read_with_timeout($file, 5) or next;
        for my $line (split /\n/, $content) {
            my ($src) = split /\s+/, $line;
            $in_use_src{$src} = 1 if defined $src && $src =~ m|^/dev/|;
        }
    }

    opendir(my $dh, '/sys/block') or return [];
    my @blocks = grep { /^sd[a-z]+$/ } readdir($dh);
    closedir($dh);

    my @paths;
    my $bailed = 0;
    for my $b (@blocks) {
        if (time() >= $deadline) { $bailed = 1; last }

        ($b) = $b =~ /^(sd[a-z]+)$/;
        next unless $b;

        # Vendor gate first: never inspect, let alone touch, other storage.
        my $vendor = sysfs_read_with_timeout("/sys/block/$b/device/vendor", $read_to) // '';
        next unless $vendor =~ $vendor_re;

        my $devlink = readlink("/sys/block/$b/device");
        my ($hctl) = (defined $devlink && $devlink =~ m{(\d+:\d+:\d+:\d+)/?$}) ? ($1) : ('');
        my $lun;
        $lun = $1 if $hctl =~ /:(\d+)$/;

        # The iSCSI target IQN groups paths for LUN-ID reuse detection. FC
        # paths have no session and keep target_id undef.
        my $target_id;
        if (defined $devlink && $devlink =~ m{/session(\d+)/}) {
            my $name = sysfs_read_with_timeout(
                "/sys/class/iscsi_session/session$1/targetname", $read_to);
            if (defined $name) {
                $name =~ s/^\s+|\s+$//g;
                $target_id = $name if length $name;
            }
        }

        my $wwid = '';
        my $raw = sysfs_read_with_timeout("/sys/block/$b/device/wwid", $read_to);
        if (defined $raw) {
            $raw =~ s/^\s+|\s+$//g;
            $wwid = '3' . lc($1) if $raw =~ /^(?:naa\.|0x)?([0-9a-f]{16,})$/i;
        }

        # Any entry under holders/ means something is stacked on this path: a
        # multipath map, an LVM PV, dm-crypt, a kpartx partition. A path in
        # use always holds something, which makes this the load-bearing
        # "never touch an in-use path" gate.
        my $has_holders = 0;
        if (opendir(my $hh, "/sys/block/$b/holders")) {
            my @h = grep { !/^\./ } readdir($hh);
            closedir($hh);
            $has_holders = 1 if @h;
        }

        push @paths, {
            dev         => $b,
            hctl        => $hctl,
            lun         => $lun,
            target_id   => $target_id,
            wwid        => $wwid,
            has_holders => $has_holders,
            mounted     => ($in_use_src{"/dev/$b"} ? 1 : 0),
        };
    }

    warn "list_vendor_scsi_paths: scan budget exceeded; some paths were not"
       . " evaluated this pass\n" if $bailed;

    return \@paths;
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

# Remove every host-side trace of a volume.
#
# MUST run BEFORE the volume is deleted on the array. Once the array drops the
# volume the paths stop answering, and anything still holding them (queued
# I/O, a sync, a flush) turns into D state that the node cannot recover from
# without a reboot.
sub cleanup_lun_devices {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my $mpath = get_multipath_device($wwid);

    if ($mpath && is_block_device($mpath)) {
        my $slaves     = get_multipath_slaves($mpath);
        my $safe_name  = _untaint_device_name(basename($mpath));
        my $safe_mpath = _untaint_device_path($mpath);

        # Before anything that touches the device: stop it from queueing.
        # With queue_if_no_path still set and every path down, the sync and
        # flush below would block forever instead of failing.
        if ($safe_name) {
            eval { _run_cmd([MULTIPATHD, 'disablequeueing', 'map', $safe_name],
                allow_nonzero => 1, ignore_errors => 1, timeout => 5) };
            eval { _run_cmd([DMSETUP, 'message', $safe_name, '0', 'fail_if_no_path'],
                allow_nonzero => 1, ignore_errors => 1, timeout => 5) };
        }

        eval { _run_cmd([SYNC], timeout => 10, allow_nonzero => 1, ignore_errors => 1) };

        if ($safe_mpath) {
            eval { _run_cmd([BLOCKDEV, '--flushbufs', $safe_mpath],
                timeout => 10, allow_nonzero => 1, ignore_errors => 1) };

            # Partition devices the kernel created for the guest's partition
            # table (<wwid>-part1, ...) are holders of the map, and the flush
            # fails while they exist. Every VM disk with an OS installed has
            # them.
            eval { _run_cmd([KPARTX, '-d', $safe_mpath],
                allow_nonzero => 1, ignore_errors => 1, timeout => 10) };
        }

        if ($safe_name) {
            eval { _run_cmd([MULTIPATHD, 'remove', 'map', $safe_name],
                allow_nonzero => 1, ignore_errors => 1, timeout => 10) };
        }

        multipath_flush($mpath);
        sleep(1);

        for my $slave (@$slaves) {
            eval { remove_scsi_device($slave) };
        }
        sleep(1);
    }

    # Sweep sd paths that were never in the map, or that outlived a map which
    # was already flushed. Leaving them is what triggers the kernel's "LUN
    # assignments on this target have changed" once the array reuses the
    # freed LUN-ID.
    my $stale = eval { get_scsi_paths_for_wwid($wwid, %opts) } // [];
    for my $dev (@$stale) {
        eval { remove_scsi_device($dev) };
    }

    return 1;
}

# ---------------------------------------------------------------------------
# In-use detection
# ---------------------------------------------------------------------------

sub _read_tables {
    my $mounts = sysfs_read_with_timeout('/proc/mounts', 5);
    my $swaps  = sysfs_read_with_timeout('/proc/swaps', 5);
    return ($mounts, $swaps);
}

# A dm name that belongs to a partition of a multipath map rather than to
# something stacked on it. Kernel and kpartx spell these several ways
# depending on configuration:
#   <wwid>-part1, <wwid>p1, <wwid>1, <alias>-part1, sdf1
sub _is_partition_dm_name {
    my ($dm_name) = @_;
    return 0 unless defined $dm_name && length $dm_name;
    return 1 if $dm_name =~ /part\d+$/;
    return 1 if $dm_name =~ /^[0-9a-f]{20,}p?\d+$/;
    return 1 if $dm_name =~ /^sd[a-z]+\d+$/;
    return 0;
}

sub _dm_name_of {
    my ($kernel_name) = @_;
    my $file = "/sys/block/$kernel_name/dm/name";
    return '' unless -r $file;
    my $name = sysfs_read_with_timeout($file, 3) // '';
    chomp $name;
    return $name;
}

# Is the device mounted, used as swap, held by something, or open by a
# process?
#
# Partition devices created from the guest's own partition table are the one
# exception: they exist on every VM disk that has an OS installed, nothing on
# the host uses them, and cleanup_lun_devices removes them. They only count as
# in-use when they have holders of their own (host LVM having auto-activated a
# VG from inside the guest disk) or are themselves mounted or in use as swap.
sub is_device_in_use {
    my ($device, %opts) = @_;

    return 0 unless $device && is_block_device($device);

    my $dev_name = _resolve_block_device_name($device);
    return 0 unless $dev_name;

    my ($mounts, $swaps) = _read_tables();

    for my $table ($mounts, $swaps) {
        next unless $table;
        for my $line (split /\n/, $table) {
            return 1 if $line =~ /^\Q$device\E\s/;
            return 1 if $line =~ m|^/dev/\Q$dev_name\E\s|;
        }
    }

    # Holders must be checked on the resolved kernel name (dm-N). Checking the
    # /dev/mapper name instead silently finds nothing, and free_image would
    # then delete a volume that host LVM is actively using.
    my $holders_dir = "/sys/block/$dev_name/holders";
    if (-d $holders_dir) {
        opendir(my $dh, $holders_dir) or return 0;
        my @holders = grep { !/^\./ } readdir($dh);
        closedir($dh);

        for my $h (@holders) {
            my $dm_name = _dm_name_of($h);

            # Anything that is not a partition (LVM LV, dm-crypt, MD) means
            # the device is genuinely in use.
            return 1 unless _is_partition_dm_name($dm_name);

            # A partition with its own holders means something is stacked on
            # it, e.g. a VG activated from inside the guest disk.
            if (opendir(my $sdh, "/sys/block/$h/holders")) {
                my @sub = grep { !/^\./ } readdir($sdh);
                closedir($sdh);
                return 1 if @sub;
            }

            # /proc/mounts records whichever path was used to mount, so check
            # both spellings.
            my $part_dev    = "/dev/$h";
            my $part_mapper = length($dm_name) ? "/dev/mapper/$dm_name" : '';
            for my $table ($mounts, $swaps) {
                next unless $table;
                return 1 if $table =~ /^\Q$part_dev\E\s/m;
                return 1 if $part_mapper && $table =~ /^\Q$part_mapper\E\s/m;
            }
        }
    }

    my $safe_device = _untaint_device_path($device);
    return 0 unless $safe_device;

    my (undef, undef, $exit) = eval {
        _run_cmd([FUSER, '-s', $safe_device],
            timeout => 10, allow_nonzero => 1, ignore_errors => 1);
    };
    return 1 if !$@ && defined $exit && $exit == 0;

    return 0;
}

# Explain WHY a device is in use, for the error message free_image raises.
# "Device is still in use" on its own leaves the operator with nowhere to go;
# in practice the cause is usually host LVM having auto-activated a volume
# group that lives inside the guest disk, which is fixable but not guessable.
sub get_device_usage_details {
    my ($device) = @_;

    return "device not specified" unless $device;
    return "device $device does not exist" unless is_block_device($device);

    my $dev_name = _resolve_block_device_name($device);
    return "cannot resolve device $device to a kernel name" unless $dev_name;

    my ($mounts, $swaps) = _read_tables();
    my @reasons;

    if ($mounts) {
        for my $line (split /\n/, $mounts) {
            if ($line =~ /^\Q$device\E\s+(\S+)/ || $line =~ m|^/dev/\Q$dev_name\E\s+(\S+)|) {
                push @reasons, "[MOUNTED] Device is mounted on $1";
            }
        }
    }

    if ($swaps) {
        for my $line (split /\n/, $swaps) {
            if ($line =~ /^\Q$device\E\s/ || $line =~ m|^/dev/\Q$dev_name\E\s|) {
                push @reasons, "[SWAP] Device is in use as swap";
            }
        }
    }

    my $holders_dir = "/sys/block/$dev_name/holders";
    if (-d $holders_dir) {
        opendir(my $dh, $holders_dir);
        my @holders = grep { !/^\./ } readdir($dh);
        closedir($dh);

        if (@holders) {
            my (@lines, @vgs);
            my $has_partition = 0;

            for my $h (sort @holders) {
                my $detail  = "/dev/$h";
                my $dm_name = _dm_name_of($h);
                $detail .= " (dm-name: $dm_name)" if length $dm_name;

                if (_is_partition_dm_name($dm_name)) {
                    $has_partition = 1;

                    if (opendir(my $sdh, "/sys/block/$h/holders")) {
                        my @subs = grep { !/^\./ } readdir($sdh);
                        closedir($sdh);
                        for my $sub (@subs) {
                            my $sub_dm = _dm_name_of($sub);
                            $detail .= "\n      sub-holder: /dev/$sub ($sub_dm)";
                            push @vgs, _vg_from_dm_name($sub_dm);
                        }
                    }

                    my $part_mapper = length($dm_name) ? "/dev/mapper/$dm_name" : '';
                    if ($mounts && ($mounts =~ m|^/dev/\Q$h\E\s+(\S+)|m
                        || ($part_mapper && $mounts =~ /^\Q$part_mapper\E\s+(\S+)/m))) {
                        $detail .= "\n      mounted on: $1";
                    }
                    if ($swaps && ($swaps =~ m|^/dev/\Q$h\E\s|m
                        || ($part_mapper && $swaps =~ /^\Q$part_mapper\E\s/m))) {
                        $detail .= "\n      in use as swap";
                    }
                } else {
                    push @vgs, _vg_from_dm_name($dm_name);
                }

                push @lines, "    $detail";
            }

            my %seen;
            @vgs = grep { defined $_ && length $_ && !$seen{$_}++ } @vgs;

            my $msg = "[HOLDERS] Device has " . scalar(@holders)
                . " holder(s) in /sys/block/$dev_name/holders/:\n" . join("\n", @lines);

            if (@vgs) {
                $msg .= "\n\n  Detected LVM volume group(s): " . join(', ', @vgs);
                $msg .= "\n  The host has activated volume group(s) that live inside"
                     .  "\n  this disk. Deletion is blocked to prevent data loss.";
                $msg .= "\n\n  To resolve, once the data is confirmed unneeded:";
                $msg .= "\n    vgchange -an $_" for @vgs;
                $msg .= "\n  Then retry the delete.";
                $msg .= "\n\n  If two volume groups share a name, select by UUID:";
                $msg .= "\n    vgs -o vg_name,vg_uuid,pv_name";
                $msg .= "\n    vgchange -an --select 'vg_uuid=<UUID>'";
                $msg .= "\n\n  To stop this recurring, add to the devices section of"
                     .  "\n  /etc/lvm/lvm.conf:";
                $msg .= "\n    global_filter = [ \"r|/dev/mapper/36.*|\", \"a|.*|\" ]";
            } elsif ($has_partition) {
                $msg .= "\n\n  A partition table was found on this device.";
                $msg .= "\n  Run 'lsblk /dev/$dev_name' to see what is using it.";
            }

            push @reasons, $msg;
        }
    }

    my $safe_device = _untaint_device_path($device);
    if ($safe_device) {
        # fuser -v writes its table to STDERR, not stdout; only the bare PID
        # list goes to stdout. Reading stdout alone means this section never
        # appears, which is the difference between telling the operator which
        # process holds the device and telling them nothing.
        my ($out, $err, $exit) = eval {
            _run_cmd([FUSER, '-v', $safe_device],
                timeout => 10, allow_nonzero => 1, ignore_errors => 1);
        };

        if (!$@ && defined $exit && $exit == 0) {
            my $text = join("\n",
                grep { defined && /\S/ } ($err // '', $out // ''));
            $text =~ s/\s+\z//;
            $text =~ s/^/    /mg;

            push @reasons, "[PROCESS] Device is open by process(es):\n$text"
                if length $text;
        }
    }

    return join("\n\n", @reasons) if @reasons;

    return "No usage detected (the device may have been freed since the check).";
}

# device-mapper doubles literal hyphens in the VG part of an LV's dm name:
# 'my--vg-root' is VG 'my-vg', LV 'root'.
sub _vg_from_dm_name {
    my ($dm_name) = @_;

    return undef unless defined $dm_name && length $dm_name;
    return undef unless $dm_name =~ /^(.*?[^-])-[^-]/;

    my $vg = $1;
    $vg =~ s/--/-/g;

    return $vg;
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

# Everything the host knows about a WWID, for the "device did not appear"
# error. An operator should be able to tell from this alone whether multipathd
# never saw the volume, saw it under a different WWID, or built the map while
# udev failed to create the node — without being asked to reproduce it.
#
# Best-effort and bounded throughout: this runs on an already-failing path and
# must not add a new way to hang.
sub describe_wwid_state {
    my ($wwid, %opts) = @_;

    return '' unless $wwid;

    my $vendor_re = _vendor_re(\%opts);
    my $want = lc($wwid);
    my @out;

    my ($stdout) = eval {
        _run_cmd([MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w %s'],
            allow_nonzero => 1, ignore_errors => 1, timeout => 10);
    };

    if ($@) {
        push @out, "  multipathd: NOT RESPONDING ($@)";
        push @out, "    This alone explains the failure: device lookup goes through"
                 . " 'multipathd show maps'. Check 'systemctl status multipathd'.";
    } else {
        my @maps;
        for my $line (split /\n/, ($stdout // '')) {
            $line =~ s/^\s+|\s+$//g;
            my ($name, $map_wwid, $vps) = split /\s+/, $line, 3;
            next unless $name && $map_wwid;
            push @maps, { name => $name, wwid => lc($map_wwid), vps => $vps // '' };
        }

        my @ours = grep { $_->{vps} =~ $vendor_re } @maps;
        push @out, "  multipathd maps: " . scalar(@maps) . " total, "
            . scalar(@ours) . " from this vendor";

        my ($match) = grep { $_->{wwid} eq $want } @maps;
        if ($match) {
            my $node = "/dev/mapper/$match->{name}";
            push @out, "  map for this WWID: $match->{name} -> $node"
                . (is_block_device($node) ? " (block device present)"
                                          : " (NODE MISSING - udev did not create it)");
        } else {
            push @out, "  map for this WWID: NONE - multipathd has not built a map"
                . " for $wwid";
            if (@ours) {
                push @out, "  other WWIDs from this vendor that multipathd does see:";
                my $limit = $#ours > 4 ? 4 : $#ours;
                push @out, "    $_->{wwid} ($_->{name})" for @ours[0 .. $limit];
                push @out, "    ... and " . (scalar(@ours) - 5) . " more" if @ours > 5;
            }
        }
    }

    # by-id links present while multipathd shows nothing means the paths
    # arrived and multipath did not claim them, commonly find_multipaths
    # waiting for a second path.
    my @links;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        @links = grep { lc($_) =~ /\Q$want\E$/ }
            glob("/dev/disk/by-id/scsi-*"), glob("/dev/disk/by-id/dm-uuid-mpath-*");
        alarm(0);
    };
    alarm(0);

    push @out, "  /dev/disk/by-id links for this WWID: "
        . (@links ? join(', ', map { my $b = $_; $b =~ s|.*/||; $b } @links) : 'none');

    return join("\n", @out);
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::Multipath - dm-multipath and SCSI
device handling for the Dell EMC plugins

=head1 SYNOPSIS

    use PVE::Storage::Custom::DellEMC::Common::Multipath qw(
        wait_for_multipath_device
        cleanup_lun_devices
        is_device_in_use
    );

    my $device = wait_for_multipath_device($wwid, timeout => 60);
    cleanup_lun_devices($wwid);          # BEFORE deleting on the array

=head1 SAFETY

C<multipath -F> is never generated. C<multipath_flush> requires a device and
refuses to run without one; a CI check fails the build if the capital-F form
appears anywhere in the tree.

Every sysfs access is a forked, timeout-bounded child and every command runs
under an alarm, because a plain read of an unresponsive device puts the
process into uninterruptible sleep that no signal clears.

Destructive sweeps are vendor-gated. See C<default_vendor_re>, whose value is
NOT yet verified against hardware.

C<cleanup_lun_devices> must run before the volume is deleted on the array,
never after.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
