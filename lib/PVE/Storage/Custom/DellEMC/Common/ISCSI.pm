# Dell EMC storage plugins for Proxmox VE - iSCSI initiator handling
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::ISCSI;

use strict;
use warnings;

use Carp qw(croak);
use IO::Select;
use IO::Socket::INET;
use IPC::Open3;
use Errno ();
use POSIX ();
use Symbol qw(gensym);

use Exporter qw(import);

our @EXPORT_OK = qw(
    get_initiator_name
    probe_portal
    discover_targets
    login_target
    logout_target
    delete_node
    get_sessions
    get_session_states
    is_target_logged_in
    is_portal_logged_in
    rescan_sessions
    rescan_target
);

# iscsiadm wrapper, ported from the Pure Storage plugin.
#
# Device lookup deliberately lives in Multipath.pm, not here: once a session
# exists, finding the device is the same problem for iSCSI and for FC.
#
# Setting the node's initiator IQN is deliberately not offered. The IQN is
# node-wide state shared with every other iSCSI storage on the host, and
# rewriting it from a storage plugin would break them.

use constant {
    INITIATOR_NAME_FILE => '/etc/iscsi/initiatorname.iscsi',
    ISCSIADM            => '/usr/bin/iscsiadm',
    ISCSI_SESSION_PATH  => '/sys/class/iscsi_session',

    DEFAULT_PORT      => 3260,
    DISCOVERY_TIMEOUT => 30,
    LOGIN_TIMEOUT     => 60,
    RESCAN_TIMEOUT    => 10,

    # iscsiadm exit codes worth treating as success.
    EXIT_ALREADY_LOGGED_IN => 15,
    EXIT_NO_OBJECTS_FOUND  => 21,
};

# ---------------------------------------------------------------------------
# Bounded execution
# ---------------------------------------------------------------------------

# Reap a child that blew through its timeout without ever blocking on it.
#
# waitpid($pid, 0) after kill() blocks forever when the child sits in
# uninterruptible sleep, which is exactly the iscsiadm-against-a-dead-path
# case these timeouts exist for. The alarm has already fired and been cleared
# by then, so nothing would break us out a second time. Escalate TERM to KILL,
# poll with WNOHANG, and leave a truly unreapable child to init rather than
# joining it in D state.
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

# Bounded read of one sysfs attribute. Used for session state, which must stay
# readable exactly when iscsiadm is the thing that is wedged.
sub _read_sysfs_attr {
    my ($path, $timeout) = @_;
    $timeout //= 2;

    my $value;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);
        open(my $fh, '<', $path) or die "open: $!\n";
        $value = <$fh>;
        close($fh);
        alarm(0);
    };
    alarm(0);

    return undef if $@;
    return undef unless defined $value;
    chomp $value;

    return $value;
}

# Returns ($sessions, $error, $absent).
#
# $absent is the answer to "is iSCSI configured on this node at all", and it
# comes from the errno rather than from the text of $!. strerror is rendered
# in the node's locale: on a node running with a non-English LC_MESSAGES,
# matching /No such file or directory/ finds nothing, and a node with no iSCSI
# then warns on every rescan that it cannot enumerate its sessions.
sub _session_dirs {
    my @sessions;
    my $absent = 0;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        unless (opendir(my $dh, ISCSI_SESSION_PATH)) {
            $absent = $!{ENOENT} ? 1 : 0;
            die "opendir: $!\n";
        } else {
            @sessions = sort grep { /^session\d+$/ } readdir($dh);
            closedir($dh);
        }
        alarm(0);
    };
    alarm(0);

    return (\@sessions, $@, $absent);
}

sub _portal_addr {
    my ($portal, $port) = @_;
    return "$portal:" . ($port // DEFAULT_PORT);
}

# ---------------------------------------------------------------------------
# Initiator identity
# ---------------------------------------------------------------------------

sub get_initiator_name {
    my $file = INITIATOR_NAME_FILE;

    open(my $fh, '<', $file)
        or croak "Cannot read $file: $!. Is open-iscsi installed and configured?";
    local $/;
    my $content = <$fh>;
    close($fh);

    return $1 if defined $content && $content =~ /InitiatorName\s*=\s*(\S+)/;

    croak "Failed to parse an initiator IQN from $file";
}

# ---------------------------------------------------------------------------
# Portals and targets
# ---------------------------------------------------------------------------

# Cheap TCP reachability check for a portal.
#
# Worth doing before iscsiadm touches it: discovery and login carry 30s and
# 60s timeouts, and arrays routinely publish more portal addresses than a
# given host can reach (asymmetric cabling, controller ports on another
# segment, a partial fabric outage). Probing first turns minutes of blocked
# activate_storage into a couple of seconds.
sub probe_portal {
    my ($ip, $port, %opts) = @_;

    croak "ip is required" unless $ip;
    $port //= DEFAULT_PORT;
    my $timeout = $opts{timeout} // 2;

    # A timeout of 0 disables probing; the caller wants every portal tried.
    return 1 if $timeout <= 0;

    my $reachable = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        my $sock = IO::Socket::INET->new(
            PeerAddr => $ip,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => $timeout,
        );
        if ($sock) {
            $reachable = 1;
            $sock->close();
        }
        alarm(0);
    };
    alarm(0);

    return $reachable;
}

# Returns arrayref of { portal, target }.
sub discover_targets {
    my ($portal, %opts) = @_;

    croak "portal is required" unless $portal;

    my $addr = _portal_addr($portal, $opts{port});

    my ($stdout) = _run_cmd(
        [ISCSIADM, '-m', 'discovery', '-t', 'sendtargets', '-p', $addr],
        timeout       => $opts{timeout} // DISCOVERY_TIMEOUT,
        allow_nonzero => 1,
    );

    my @targets;
    for my $line (split /\n/, $stdout) {
        # "<ip>:<port>,<tpgt> <target iqn>"
        next unless $line =~ /^(\S+),\d+\s+(\S+)/;
        push @targets, { portal => $1, target => $2 };
    }

    return \@targets;
}

sub login_target {
    my ($portal, $target, %opts) = @_;

    croak "portal is required" unless $portal;
    croak "target is required" unless $target;

    my $addr = _portal_addr($portal, $opts{port});

    # Check the (portal, target) pair, never the target alone. An array's
    # iSCSI ports share one target IQN across controllers, so a target-only
    # check reports "already logged in" after the first portal succeeds and
    # the host ends up with one path where it should have several.
    return 1 if is_portal_logged_in($addr, $target, $opts{sessions});

    if ($opts{chap_username}) {
        for my $setting (
            ['node.session.auth.authmethod' => 'CHAP'],
            ['node.session.auth.username'   => $opts{chap_username}],
            ['node.session.auth.password'   => $opts{chap_password}],
        ) {
            my ($name, $value) = @$setting;
            next unless defined $value;
            _run_cmd([ISCSIADM, '-m', 'node', '-T', $target, '-p', $addr,
                      '-o', 'update', '-n', $name, '-v', $value]);
        }
    }

    # Log back in automatically after a reboot.
    _run_cmd([ISCSIADM, '-m', 'node', '-T', $target, '-p', $addr,
              '-o', 'update', '-n', 'node.startup', '-v', 'automatic'],
        allow_nonzero => 1);

    # Recover the session after a transient outage such as a controller
    # failover or a switch reload. iscsid.conf defaults to 120s, but a node
    # whose iscsid was reconfigured later may carry a different per-node
    # value, so set it explicitly.
    _run_cmd([ISCSIADM, '-m', 'node', '-T', $target, '-p', $addr,
              '-o', 'update', '-n', 'node.session.timeo.replacement_timeout',
              '-v', $opts{replacement_timeout} // '120'],
        allow_nonzero => 1);

    my (undef, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'node', '-T', $target, '-p', $addr, '-l'],
        timeout       => $opts{timeout} // LOGIN_TIMEOUT,
        allow_nonzero => 1,
    );

    if ($exit != 0 && $exit != EXIT_ALREADY_LOGGED_IN) {
        croak "Failed to log in to target $target at $addr: $stderr";
    }

    return 1;
}

sub logout_target {
    my ($portal, $target, %opts) = @_;

    croak "portal is required" unless $portal;
    croak "target is required" unless $target;

    my $addr = _portal_addr($portal, $opts{port});

    my (undef, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'node', '-T', $target, '-p', $addr, '-u'],
        allow_nonzero => 1,
        timeout       => $opts{timeout} // LOGIN_TIMEOUT,
    );

    if ($exit != 0 && $exit != EXIT_NO_OBJECTS_FOUND) {
        croak "Failed to log out of target $target at $addr: $stderr";
    }

    return 1;
}

# Forget a node record, so the host stops trying to log in to a portal the
# array no longer serves.
sub delete_node {
    my ($portal, $target, %opts) = @_;

    croak "portal is required" unless $portal;
    croak "target is required" unless $target;

    my $addr = _portal_addr($portal, $opts{port});

    _run_cmd([ISCSIADM, '-m', 'node', '-T', $target, '-p', $addr, '-o', 'delete'],
        allow_nonzero => 1, ignore_errors => 1, timeout => $opts{timeout} // 30);

    return 1;
}

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

# Sessions as iscsiadm reports them: arrayref of
# { protocol, session_id, portal, target }.
sub get_sessions {
    my (%opts) = @_;

    my ($stdout, undef, $exit) = _run_cmd([ISCSIADM, '-m', 'session'],
        allow_nonzero => 1, timeout => $opts{timeout} // 15);

    return [] if $exit == EXIT_NO_OBJECTS_FOUND;

    my @sessions;
    for my $line (split /\n/, $stdout) {
        # "tcp: [3] 10.0.0.1:3260,1 iqn.2015-10.com.dell:..."
        next unless $line =~ /^(\w+):\s+\[(\d+)\]\s+(\S+)\s+(\S+)/;
        push @sessions, {
            protocol   => $1,
            session_id => $2,
            portal     => $3,
            target     => $4,
        };
    }

    return \@sessions;
}

# Sessions as the kernel sees them, read straight from sysfs. Unlike
# get_sessions this does not shell out, so it keeps working when iscsiadm is
# the thing that is stuck — which is when a diagnostic matters most.
#
# Returns arrayref of { session, state, target, portal }.
sub get_session_states {
    my ($sessions, $err) = _session_dirs();
    return [] if $err;

    my @out;
    for my $s (@$sessions) {
        my $base = ISCSI_SESSION_PATH . "/$s";
        push @out, {
            session => $s,
            state   => _read_sysfs_attr("$base/state", 2),
            target  => _read_sysfs_attr("$base/targetname", 2),
            portal  => _read_sysfs_attr("$base/persistent_address", 2),
        };
    }

    return \@out;
}

# Coarse check: is there a session to this target anywhere?
sub is_target_logged_in {
    my ($target, $sessions) = @_;

    return 0 unless defined $target;
    $sessions //= get_sessions();

    for my $session (@$sessions) {
        return 1 if $session->{target} eq $target;
    }

    return 0;
}

# The check to make before logging in: is there a session to this specific
# (portal, target) pair?
#
# Callers iterating many portals should snapshot the session list once and
# pass it in; each get_sessions() call is another external command.
sub is_portal_logged_in {
    my ($portal_addr, $target, $sessions) = @_;

    return 0 unless defined $portal_addr && defined $target;
    $sessions //= get_sessions();

    for my $session (@$sessions) {
        next unless $session->{target} eq $target;
        # iscsiadm reports "ip:port,tpgt"; drop the portal-group tag.
        (my $portal = $session->{portal}) =~ s/,\d+$//;
        return 1 if $portal eq $portal_addr;
    }

    return 0;
}

# Rescan sessions for newly mapped volumes. Returns the number rescanned.
#
# Sessions are enumerated from sysfs and rescanned ONE AT A TIME, and only
# while their kernel state is LOGGED_IN.
#
# `iscsiadm -m session --rescan` instead rescans every session in a single
# invocation. With some paths dead — an ordinary state on a multi-portal array
# during a fabric fault — that issues SCSI commands down the dead sessions and
# the kernel waits out the bus timeout on each, which outlasts the iscsiadm
# timeout. Killing the parent then leaves D-state children behind, and since
# every pvestatd poll fires another rescan, they accumulate until the node's
# management plane is wedged and every storage shows as unknown in the UI.
# Per-session rescans bound the damage to one stuck child per stuck session.
#
# Per-session failures never croak: the caller's wait-for-device loop already
# handles "the device did not appear".
sub rescan_sessions {
    my (%opts) = @_;

    my $per_session_timeout = $opts{per_session_timeout} // $opts{timeout} // RESCAN_TIMEOUT;

    my ($sessions, $err, $absent) = _session_dirs();
    if ($err) {
        # No iSCSI configured at all is not an error worth reporting.
        return 0 if $absent;
        warn "rescan_sessions: cannot enumerate iSCSI sessions: $err";
        return 0;
    }
    return 0 unless @$sessions;

    my ($rescanned, $failed, @skipped) = (0, 0);

    for my $session (@$sessions) {
        my ($sid) = $session =~ /^session(\d+)$/ or next;

        my $state = _read_sysfs_attr(ISCSI_SESSION_PATH . "/$session/state", 2);
        if (!defined $state) {
            # State unreadable: skip rather than rescan a session whose kernel
            # state is unknown.
            push @skipped, "$session=unreadable";
            next;
        }
        if ($state ne 'LOGGED_IN') {
            push @skipped, "$session=$state";
            next;
        }

        my (undef, undef, $exit) = _run_cmd(
            [ISCSIADM, '-m', 'session', '-r', $sid, '--rescan'],
            allow_nonzero => 1,
            timeout       => $per_session_timeout,
        );
        if ($exit == 0) { $rescanned++ } else { $failed++ }
    }

    warn "rescan_sessions: skipped " . scalar(@skipped) . " session(s) not in"
       . " LOGGED_IN state [" . join(', ', @skipped) . "], rescanned $rescanned,"
       . " failed $failed\n" if @skipped;

    return $rescanned;
}

sub rescan_target {
    my ($target, %opts) = @_;

    croak "target is required" unless $target;

    my (undef, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'node', '-T', $target, '--rescan'],
        allow_nonzero => 1,
        timeout       => $opts{timeout} // 60,
    );

    return 1 if $exit == 0;
    croak "Failed to rescan target $target: $stderr";
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::ISCSI - iSCSI initiator handling for
the Dell EMC plugins

=head1 SYNOPSIS

    use PVE::Storage::Custom::DellEMC::Common::ISCSI qw(
        get_initiator_name probe_portal discover_targets login_target
    );

    my $iqn = get_initiator_name();

    for my $portal (@portals) {
        next unless probe_portal($portal, 3260, timeout => 2);
        my $targets = discover_targets($portal);
        login_target($portal, $_->{target}) for @$targets;
    }

=head1 NOTES

Device lookup is not here; it is protocol-independent and lives in
Multipath.pm.

Writing the node's initiator IQN is deliberately not offered: it is
node-wide state shared with every other iSCSI storage on the host.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
