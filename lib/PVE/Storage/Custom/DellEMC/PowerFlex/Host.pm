# Dell EMC storage plugins for Proxmox VE - PowerFlex host-side access
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::PowerFlex::Host;

use strict;
use warnings;

use Carp qw(croak);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use POSIX ();
use JSON;

use Exporter qw(import);

our @EXPORT_OK = qw(
    sdc_available
    sdc_guid
    sdc_device_for_volume
    nvme_available
    nvme_host_nqn
    nvme_connect
    nvme_disconnect
    nvme_device_for_volume
    nvme_multipath_enabled
    nvme_paths
    nvme_connected_addresses
    wait_for_device
);

# PowerFlex volumes never reach the host as SCSI LUNs, so none of the
# multipath machinery the other families use applies. There are two access
# methods and they are mutually exclusive per volume:
#
#   SDC        Dell's proprietary kernel module. Volumes appear as
#              /dev/scini* with udev symlinks under
#              /dev/disk/by-id/emc-vol-<mdm>-<volume>. Multipathing is the
#              SDC's own job.
#
#   NVMe/TCP   PowerFlex 4.0 and later. An SDT on the storage side speaks
#              NVMe/TCP and the host uses the in-kernel initiator, so nothing
#              proprietary is installed. Paths are handled by NVMe native
#              multipathing (ANA).
#
# This plugin does NOT install or configure the SDC. Dell ships scini as a
# kernel module that must match the running kernel, and Proxmox VE kernels
# are not on Dell's support matrix; deciding to run it is the operator's
# call, and keeping it working across kernel upgrades is their job. See
# docs/POWERFLEX_SDC.md.

use constant {
    SDC_TOOL      => '/bin/emc/scaleio/drv_cfg',
    SDC_DEV_GLOB  => '/dev/disk/by-id/emc-vol-*',
    SCINI_MODULE  => 'scini',

    NVME_CLI      => '/usr/sbin/nvme',
    NVME_HOSTNQN  => '/etc/nvme/hostnqn',
    NVME_DEFAULT_PORT => 4420,

    # The NVMe equivalents of no_path_retry / fast_io_fail_tmo / dev_loss_tmo.
    # The kernel default ctrl_loss_tmo is 600s, which is indistinguishable
    # from a hang to anyone watching a VM.
    NVME_CTRL_LOSS_TMO   => 60,
    NVME_RECONNECT_DELAY => 10,
    NVME_KEEP_ALIVE_TMO  => 5,

    DEVICE_WAIT_TIMEOUT  => 60,
    DEVICE_WAIT_INTERVAL => 1,
};

# ---------------------------------------------------------------------------
# Bounded command execution
#
# Same rule as everywhere else in this plugin: nothing runs without a bound
# on how long it may block. A wedged NVMe controller or a half-loaded scini
# module can otherwise park a PVE worker indefinitely.
# ---------------------------------------------------------------------------

sub _reap {
    my ($pid) = @_;
    return unless $pid;

    for my $signal ('TERM', 'KILL') {
        kill($signal, $pid);
        my $deadline = time() + 2;
        while (time() < $deadline) {
            return if waitpid($pid, POSIX::WNOHANG()) != 0;
            select(undef, undef, undef, 0.1);
        }
    }

    return;
}

sub _run {
    my ($cmd, %opts) = @_;

    my $timeout = $opts{timeout} // 15;
    my ($stdout, $stderr) = ('', '');
    my $err = gensym;
    my $pid;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        $pid = open3(my $in, my $out, $err, @$cmd);
        close($in);

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
        _reap($pid);
        return (undef, "timed out after ${timeout}s", -1) if $@ eq "timeout\n";
        return (undef, $@, -1);
    }

    return ($stdout, $stderr, $? >> 8);
}

sub _untaint_device {
    my ($path) = @_;
    return undef unless defined $path;
    return $1 if $path =~ m|^(/dev/[A-Za-z0-9_\-/\.]+)$|;
    return undef;
}

# ---------------------------------------------------------------------------
# SDC
# ---------------------------------------------------------------------------

# Is the SDC actually usable on this node? Present-but-not-loaded is the
# common failure after a kernel upgrade, and it deserves its own answer
# rather than looking like "no volumes found".
sub sdc_available {
    return 0 unless -x SDC_TOOL;

    # /proc/modules is cheap and does not need the module to answer.
    if (open(my $fh, '<', '/proc/modules')) {
        while (my $line = <$fh>) {
            if ($line =~ /^@{[ SCINI_MODULE ]}\s/) {
                close($fh);
                return 1;
            }
        }
        close($fh);
    }

    return 0;
}

# Why the SDC is not usable, in words an operator can act on.
sub sdc_status_message {
    return "the SDC tool " . SDC_TOOL . " is not installed. PowerFlex SDC is"
         . " Dell software and this plugin does not install it; see"
         . " docs/POWERFLEX_SDC.md."
        unless -x SDC_TOOL;

    return "the scini kernel module is not loaded. After a kernel upgrade the"
         . " module has to be rebuilt or refetched for the running kernel;"
         . " check 'systemctl status scini' and see docs/POWERFLEX_SDC.md."
        unless sdc_available();

    return '';
}

# This node's SDC GUID, which is how the array identifies it.
sub sdc_guid {
    return undef unless -x SDC_TOOL;

    my ($out) = _run([SDC_TOOL, '--query_guid'], timeout => 10);
    return undef unless defined $out;

    return $1 if $out =~ /([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})/;

    return undef;
}

# The device for one PowerFlex volume id, via the SDC's udev symlinks.
#
# The symlink is /dev/disk/by-id/emc-vol-<mdm id>-<volume id>, so the volume
# id alone is enough to find it without knowing the MDM.
sub sdc_device_for_volume {
    my ($volume_id) = @_;

    croak "volume_id is required" unless defined $volume_id && length $volume_id;

    # The -b test runs inside the alarm with the glob: it resolves the symlink
    # and stats the device, and a stat on a block device whose backing paths
    # are gone can block in the kernel just as the glob can.
    my $found;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);

        for my $link (glob(SDC_DEV_GLOB)) {
            next unless $link =~ /\Q$volume_id\E$/i;
            my $device = _untaint_device($link) or next;
            next unless -b $device;
            $found = $device;
            last;
        }

        alarm(0);
    };
    alarm(0);

    return $found;
}

# ---------------------------------------------------------------------------
# NVMe/TCP
# ---------------------------------------------------------------------------

sub nvme_available {
    return 0 unless -x NVME_CLI;

    # nvme_tcp is a normal in-kernel module; on Proxmox VE it is present but
    # may not be loaded until first use.
    return 1 if -d '/sys/module/nvme_tcp';

    my (undef, undef, $rc) = _run(['/sbin/modprobe', 'nvme_tcp'], timeout => 10);

    return (defined $rc && $rc == 0) ? 1 : 0;
}

sub nvme_status_message {
    return "the nvme command is not installed. Install the nvme-cli package."
        unless -x NVME_CLI;

    return "the nvme_tcp kernel module could not be loaded."
        unless nvme_available();

    return '';
}

# This host's NQN, which the array must know before it will map anything.
sub nvme_host_nqn {
    my $existing = _read_host_nqn_file();
    return $existing if defined $existing;

    # nvme-cli can generate one, but a generated NQN is random and a new one
    # comes back on every call. Returning it unpersisted would register a fresh
    # host on the array each time, while 'nvme connect' — which reads this same
    # file — would present yet another. The volume is then mapped to an NQN no
    # connection uses and the namespace simply never appears. So write it once
    # and use the file from then on.
    my ($out) = _run([NVME_CLI, 'gen-hostnqn'], timeout => 10);
    return undef unless defined $out;

    chomp $out;
    $out =~ s/^\s+|\s+$//g;
    return undef unless length $out;

    my ($nqn) = $out =~ /^(nqn\.[\x21-\x7e]+)$/
        or return undef;

    my $persisted = _persist_host_nqn($nqn);
    return $persisted if defined $persisted;

    die "This node has no " . NVME_HOSTNQN . " and one could not be written."
      . " NVMe/TCP needs a stable host NQN: the array maps volumes to it and"
      . " 'nvme connect' presents it. Create it by hand with\n"
      . "  mkdir -p /etc/nvme && nvme gen-hostnqn > " . NVME_HOSTNQN . "\n";
}

# Write the host NQN atomically. Returns the NQN that is on disk afterwards —
# ours, or the one another process wrote first — or undef if nothing could be
# written.
sub _persist_host_nqn {
    my ($nqn) = @_;

    my $file = NVME_HOSTNQN;
    (my $dir = $file) =~ s|/[^/]+$||;

    unless (-d $dir) {
        mkdir($dir, 0755) or return undef;
    }

    my $tmp = "$file.tmp.$$";
    open(my $fh, '>', $tmp) or return undef;
    print $fh "$nqn\n";
    unless (close($fh)) {
        unlink($tmp);
        return undef;
    }

    # link() fails if the target exists, which makes this the atomic
    # create-if-absent that rename() is not. A file another process wrote
    # first is as good as ours, and replacing it under a live connection
    # would be worse than keeping it.
    my $created = link($tmp, $file);
    unlink($tmp);

    if ($created) {
        warn "Wrote a host NQN to $file for NVMe/TCP: $nqn\n";
        return $nqn;
    }

    return _read_host_nqn_file();
}

# The NQN in NVME_HOSTNQN, or undef when the file is missing or empty.
sub _read_host_nqn_file {
    open(my $fh, '<', NVME_HOSTNQN) or return undef;
    my $value = <$fh>;
    close($fh);

    return undef unless defined $value;
    chomp $value;
    $value =~ s/^\s+|\s+$//g;

    return length($value) ? $value : undef;
}

# Is NVMe native multipath enabled in the kernel?
#
# This is what makes several SDT connections behave as paths to one namespace
# rather than as several separate block devices. Without it, PVE would see
# one device per path and could write through two of them at once.
sub nvme_multipath_enabled {
    open(my $fh, '<', '/sys/module/nvme_core/parameters/multipath') or return -1;
    my $value = <$fh>;
    close($fh);

    return -1 unless defined $value;
    chomp $value;

    return $value =~ /^[Yy1]/ ? 1 : 0;
}

sub nvme_multipath_message {
    my $state = nvme_multipath_enabled();

    return "the kernel does not expose nvme_core.multipath, so NVMe native"
         . " multipathing could not be confirmed." if $state < 0;

    return "NVMe native multipathing is DISABLED (nvme_core.multipath=N)."
         . " Each path to the array would appear as its own block device"
         . " instead of one multipathed namespace. Enable it with the kernel"
         . " parameter nvme_core.multipath=Y and reboot." if $state == 0;

    return '';
}

# Connect to one SDT. Already-connected is success, not an error.
#
# The timeouts matter as much here as no_path_retry does on the SAN families,
# and for the same reason: with every path down, I/O that is queued forever
# puts processes into uninterruptible sleep.
#
#   ctrl-loss-tmo    how long the kernel keeps retrying a lost controller
#                    before it gives up and fails the I/O. The kernel default
#                    is 600 seconds, which is long enough to look like a hang.
#   reconnect-delay  seconds between reconnection attempts.
#   keep-alive-tmo   how quickly a dead controller is noticed.
sub nvme_connect {
    my ($target, %opts) = @_;

    croak "target ip is required" unless $target->{ip};
    croak "target nqn is required" unless $target->{nqn};

    my $port = $target->{port} // NVME_DEFAULT_PORT;

    my @cmd = (
        NVME_CLI, 'connect',
        '--transport', 'tcp',
        '--traddr', $target->{ip},
        '--trsvcid', $port,
        '--nqn', $target->{nqn},
        '--ctrl-loss-tmo', $opts{ctrl_loss_tmo} // NVME_CTRL_LOSS_TMO,
        '--reconnect-delay', $opts{reconnect_delay} // NVME_RECONNECT_DELAY,
        '--keep-alive-tmo', $opts{keep_alive_tmo} // NVME_KEEP_ALIVE_TMO,
    );

    push @cmd, '--nr-io-queues', $opts{io_queues} if $opts{io_queues};
    push @cmd, '--hostnqn', $opts{host_nqn} if $opts{host_nqn};

    my ($out, $err, $rc) = _run(\@cmd, timeout => $opts{timeout} // 30);

    return 1 if defined $rc && $rc == 0;

    my $message = ($err // '') . ($out // '');
    return 1 if $message =~ /already connected|operation already in progress/i;

    return 0;
}

# The paths of one subsystem and their ANA states, for diagnostics.
sub nvme_paths {
    my ($nqn) = @_;

    my ($out) = _run([NVME_CLI, 'list-subsys', '-o', 'json'], timeout => 10);
    return [] unless defined $out && length $out;

    my $data = eval { JSON::decode_json($out) };
    return [] unless ref($data);

    my @paths;
    my $subsystems = ref($data) eq 'ARRAY' ? $data : [$data];
    for my $entry (@$subsystems) {
        for my $subsys (@{ $entry->{Subsystems} // [] }) {
            next if defined $nqn && length $nqn
                 && ($subsys->{NQN} // '') ne $nqn;
            for my $path (@{ $subsys->{Paths} // [] }) {
                push @paths, {
                    name    => $path->{Name},
                    state   => $path->{State},
                    ana     => $path->{ANAState},
                    address => $path->{Address},
                };
            }
        }
    }

    return \@paths;
}

# The transport addresses this node already has a path to, as 'ip:port'.
#
# 'nvme connect' to an address that is already connected is harmless, but it
# is still a process per address, and activate_storage runs on every pvestatd
# poll — six times a minute per node. One list-subsys instead of N connects is
# the difference between a check and a load.
sub nvme_connected_addresses {
    my ($nqn) = @_;

    my %connected;

    for my $path (@{ nvme_paths($nqn) }) {
        my $address = $path->{address} // next;

        # 'traddr=10.0.0.1,trsvcid=4420' in any order, with or without spaces.
        my ($ip)   = $address =~ /traddr=([^, ]+)/;
        my ($port) = $address =~ /trsvcid=([^, ]+)/;
        next unless defined $ip;

        $connected{ $ip . ':' . ($port // NVME_DEFAULT_PORT) } = $path->{state};
    }

    return \%connected;
}

sub nvme_disconnect {
    my ($nqn, %opts) = @_;

    croak "nqn is required" unless defined $nqn && length $nqn;

    my (undef, undef, $rc) = _run([NVME_CLI, 'disconnect', '--nqn', $nqn],
        timeout => $opts{timeout} // 30);

    return (defined $rc && $rc == 0) ? 1 : 0;
}

# Find the namespace that carries a PowerFlex volume.
#
# The volume id appears in the namespace's identifier, which udev exposes
# under /dev/disk/by-id. Matching there avoids parsing `nvme list` output,
# whose shape has changed between nvme-cli releases.
#
# NOT VERIFIED against hardware: confirm how the volume id appears in the
# NGUID or UUID before relying on this.
sub nvme_device_for_volume {
    my ($volume_id) = @_;

    croak "volume_id is required" unless defined $volume_id && length $volume_id;

    # PowerFlex volume ids are hex; udev renders identifiers in lower case.
    my $needle = lc($volume_id);
    $needle =~ s/^0x//;

    # glob and stat together under one alarm; see sdc_device_for_volume. The
    # -b below is a stat that can block on a dead device, which is why it is
    # inside the alarm rather than after it.
    my $found;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);

        for my $link (glob('/dev/disk/by-id/nvme-*')) {
            next unless lc($link) =~ /\Q$needle\E/;
            # Skip partition links; PVE wants the whole namespace.
            next if $link =~ /-part\d+$/;
            my $device = _untaint_device($link) or next;
            next unless -b $device;
            $found = $device;
            last;
        }

        alarm(0);
    };
    alarm(0);

    return $found;
}

# ---------------------------------------------------------------------------
# Waiting
# ---------------------------------------------------------------------------

# Wait for a volume's device to appear, whichever access method is in use.
#
# $lookup is a coderef returning the device path or undef; passing it in
# keeps this loop identical for SDC and NVMe.
sub wait_for_device {
    my ($lookup, %opts) = @_;

    croak "lookup coderef is required" unless ref($lookup) eq 'CODE';

    my $timeout  = $opts{timeout}  // DEVICE_WAIT_TIMEOUT;
    my $interval = $opts{interval} // DEVICE_WAIT_INTERVAL;
    my $deadline = time() + $timeout;

    # It is usually already there.
    my $device = $lookup->();
    return $device if $device;

    my $rescanned = 0;

    while (time() < $deadline) {
        # A rescan hook exists for NVMe, where a newly mapped namespace may
        # need the controller to be told to look again.
        if (!$rescanned && $opts{rescan} && ref($opts{rescan}) eq 'CODE') {
            eval { $opts{rescan}->() };
            $rescanned = 1;
        }

        sleep($interval);

        $device = $lookup->();
        return $device if $device;
    }

    return undef;
}

# Ask every NVMe controller to re-read its namespace list.
sub nvme_rescan {
    my @controllers;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        @controllers = glob('/dev/nvme[0-9]*');
        alarm(0);
    };
    alarm(0);

    for my $controller (@controllers) {
        next if $controller =~ /n\d+/;   # namespaces, not controllers
        my $device = _untaint_device($controller) or next;
        eval { _run([NVME_CLI, 'ns-rescan', $device], timeout => 10) };
    }

    return 1;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::PowerFlex::Host - host-side access for
PowerFlex volumes

=head1 DESCRIPTION

PowerFlex volumes do not arrive as SCSI LUNs, so none of the dm-multipath
machinery the other Dell families use applies here. Two access methods exist:

=over 4

=item * B<SDC> — Dell's proprietary kernel module. Volumes appear under
C</dev/disk/by-id/emc-vol-*>. This plugin never installs or configures it.

=item * B<NVMe/TCP> — PowerFlex 4.0 and later, using the in-kernel initiator
against the array's SDT components. Nothing proprietary on the host.

=back

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
