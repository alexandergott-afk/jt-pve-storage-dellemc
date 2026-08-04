# Dell EMC storage plugins for Proxmox VE - Fibre Channel HBA handling
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::FC;

use strict;
use warnings;

use Carp qw(croak);

use PVE::Storage::Custom::DellEMC::Common::Multipath qw(sysfs_write_with_timeout);

use Exporter qw(import);

our @EXPORT_OK = qw(
    is_fc_available
    get_fc_hosts
    get_fc_host_info
    get_fc_wwpns
    get_fc_wwpns_raw
    get_fc_wwnns
    get_fc_targets
    rport_name
    rescan_fc_hosts
    format_wwn
    parse_wwn
    normalize_wwn
    wwn_equal
);

# FC HBA facts, read from /sys/class/fc_host, ported from the Pure Storage
# plugin. The array-side half (target WWPNs, host objects) belongs to the
# family API client; this module only knows about the local HBAs.

use constant {
    FC_HOST_PATH   => '/sys/class/fc_host',
    FC_REMOTE_PATH => '/sys/class/fc_remote_ports',
    SCSI_HOST_PATH => '/sys/class/scsi_host',
    READ_TIMEOUT   => 3,
};

# Bounded read of one sysfs attribute. A wedged HBA can block a plain read
# indefinitely, and an unkillable reader in a PVE worker is how one bad HBA
# takes the node's management plane down.
sub _read_attr {
    my ($path, $timeout) = @_;

    return undef unless -r $path;
    $timeout //= READ_TIMEOUT;

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
    $value =~ s/^\s+|\s+$//g;

    return length($value) ? $value : undef;
}

# ---------------------------------------------------------------------------
# WWN formatting
# ---------------------------------------------------------------------------

# 0x5001438032a5b6c7 or 5001438032a5b6c7 -> 50:01:43:80:32:a5:b6:c7
sub format_wwn {
    my ($wwn) = @_;

    my $raw = parse_wwn($wwn);
    return undef unless defined $raw;

    $raw =~ s/(..)(?=.)/$1:/g;

    return $raw;
}

# Any accepted spelling -> 16 lowercase hex digits, no separators. This is the
# form array APIs generally want.
sub parse_wwn {
    my ($wwn) = @_;

    return undef unless defined $wwn;

    $wwn =~ s/^0x//i;
    $wwn =~ s/[:\-\s]//g;

    return undef unless $wwn =~ /^[0-9a-fA-F]{16}$/;

    return lc($wwn);
}

sub normalize_wwn { return parse_wwn($_[0]) }

# Compare two WWNs regardless of how each was spelled.
sub wwn_equal {
    my ($a, $b) = @_;

    my $na = normalize_wwn($a);
    my $nb = normalize_wwn($b);

    return 0 unless defined $na && defined $nb;
    return $na eq $nb ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Local HBAs
# ---------------------------------------------------------------------------

sub is_fc_available {
    return 0 unless -d FC_HOST_PATH;
    return scalar(@{ get_fc_hosts() }) > 0 ? 1 : 0;
}

# FC host adapters, e.g. ['host0', 'host1'], numerically sorted.
sub get_fc_hosts {
    return [] unless -d FC_HOST_PATH;

    opendir(my $dh, FC_HOST_PATH) or return [];
    my @hosts;
    for my $entry (readdir($dh)) {
        next unless $entry =~ /^(host\d+)$/;
        $entry = $1;
        # port_name is what makes it a usable FC host.
        push @hosts, $entry if -r FC_HOST_PATH . "/$entry/port_name";
    }
    closedir($dh);

    @hosts = sort {
        my ($na) = $a =~ /(\d+)/;
        my ($nb) = $b =~ /(\d+)/;
        $na <=> $nb;
    } @hosts;

    return \@hosts;
}

sub get_fc_host_info {
    my @info;

    for my $host (@{ get_fc_hosts() }) {
        my $base = FC_HOST_PATH . "/$host";

        push @info, {
            host        => $host,
            wwpn        => format_wwn(_read_attr("$base/port_name")),
            wwnn        => format_wwn(_read_attr("$base/node_name")),
            port_state  => _read_attr("$base/port_state") // 'unknown',
            port_type   => _read_attr("$base/port_type")  // 'unknown',
            speed       => _read_attr("$base/speed")      // 'unknown',
            fabric_name => format_wwn(_read_attr("$base/fabric_name")),
        };
    }

    return \@info;
}

sub _wwpns {
    my ($formatter, %opts) = @_;

    my @out;
    for my $host (@{ get_fc_hosts() }) {
        my $base = FC_HOST_PATH . "/$host";

        my $raw = _read_attr("$base/port_name");
        next unless defined $raw;

        if ($opts{online_only}) {
            my $state = _read_attr("$base/port_state") // '';
            next unless $state =~ /online/i;
        }

        my $wwpn = $formatter->($raw);
        push @out, $wwpn if defined $wwpn;
    }

    my %seen;
    return [ grep { !$seen{$_}++ } @out ];
}

# ['50:01:43:80:32:a5:b6:c7', ...]
sub get_fc_wwpns {
    my (%opts) = @_;
    return _wwpns(\&format_wwn, %opts);
}

# ['5001438032a5b6c7', ...]
sub get_fc_wwpns_raw {
    my (%opts) = @_;
    return _wwpns(\&parse_wwn, %opts);
}

# Node names. Several ports of the same adapter share one, so the list is
# deduplicated.
sub get_fc_wwnns {
    my (%opts) = @_;

    my @out;
    for my $host (@{ get_fc_hosts() }) {
        my $wwnn = format_wwn(_read_attr(FC_HOST_PATH . "/$host/node_name"));
        push @out, $wwnn if defined $wwnn;
    }

    my %seen;
    return [ grep { !$seen{$_}++ } @out ];
}

# Remote ports the fabric has presented to this host. The array's ports are
# the entries with is_target set.
# The kernel names a remote port rport-<host>:<channel>-<remote>, with a
# COLON after the host number: 'rport-5:0-3'. This filter once asked for three
# hyphen-separated numbers, which matches no entry the kernel has ever
# created, so get_fc_targets always came back empty — and every FC node was
# told on every poll that no target ports were visible, however well the
# fabric was zoned. Reported from an ME4024 that was working.
#
# It doubles as the taint check: the name that comes back is the one matched,
# never the one read from the directory.
sub rport_name {
    my ($entry) = @_;

    return undef unless defined $entry;
    my ($name) = $entry =~ /^(rport-\d+:\d+-\d+)\z/;

    return $name;
}

sub get_fc_targets {
    return [] unless -d FC_REMOTE_PATH;

    opendir(my $dh, FC_REMOTE_PATH) or return [];
    my @entries = grep { defined rport_name($_) } readdir($dh);
    closedir($dh);

    my @targets;
    for my $entry (@entries) {
        $entry = rport_name($entry) // next;

        my $base = FC_REMOTE_PATH . "/$entry";
        my $roles = _read_attr("$base/roles") // '';

        push @targets, {
            rport      => $entry,
            wwpn       => format_wwn(_read_attr("$base/port_name")),
            wwnn       => format_wwn(_read_attr("$base/node_name")),
            port_state => _read_attr("$base/port_state") // 'unknown',
            roles      => $roles,
            is_target  => ($roles =~ /target/i) ? 1 : 0,
        };
    }

    return \@targets;
}

# Rescan FC hosts for newly mapped volumes. Returns the number of hosts
# scanned.
#
# The host list comes from /sys/class/fc_host, so a non-FC HBA is never
# touched — the same categorical rule as rescan_scsi_hosts() in Multipath.pm.
# The writes still go through the timeout-bounded helper: filtering to FC
# hosts does not stop a wedged HBA from blocking the write itself.
#
# A LIP is NOT issued by default. On a loop topology it forces reinitialization
# and is sometimes the only way to see a new device, but it briefly disrupts
# every LUN behind that port, including other vendors' storage sharing the
# HBA. On the fabric topologies this plugin targets, writing the SCSI scan
# file is enough. Pass issue_lip => 1 for the loop case.
sub rescan_fc_hosts {
    my (%opts) = @_;

    my $hosts = get_fc_hosts();
    return 0 unless @$hosts;

    my $scanned = 0;

    if ($opts{issue_lip}) {
        for my $host (@$hosts) {
            my $file = FC_HOST_PATH . "/$host/issue_lip";
            next unless -w $file;
            warn "Failed to issue LIP on $host (timeout or error)\n"
                unless sysfs_write_with_timeout($file, "1\n", 10);
        }
    }

    for my $host (@$hosts) {
        my $file = SCSI_HOST_PATH . "/$host/scan";
        next unless -w $file;
        $scanned++ if sysfs_write_with_timeout($file, "- - -\n", 10);
    }

    sleep($opts{delay} // 2);

    return $scanned;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::FC - Fibre Channel HBA handling for
the Dell EMC plugins

=head1 SYNOPSIS

    use PVE::Storage::Custom::DellEMC::Common::FC qw(
        is_fc_available get_fc_wwpns_raw rescan_fc_hosts
    );

    if (is_fc_available()) {
        my $wwpns = get_fc_wwpns_raw(online_only => 1);
        rescan_fc_hosts();
    }

=head1 NOTES

C<rescan_fc_hosts> does not issue a LIP unless asked to: a LIP disrupts every
LUN behind the port, including storage this plugin does not own.

The FC data path is NOT yet verified on hardware. See docs/TESTING.md.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
