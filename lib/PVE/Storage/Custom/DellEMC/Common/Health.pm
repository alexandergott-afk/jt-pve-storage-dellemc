# Dell EMC storage plugins for Proxmox VE - storage health reporting
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::Health;

use strict;
use warnings;

use File::Path ();
use JSON;

use PVE::Storage::Custom::DellEMC::Common::WwidState;

# Outage and capacity reporting for status().
#
# status() runs every ~10 seconds per storage per node, so anything it emits
# unconditionally becomes journal noise that hides the events that matter.
# Two pieces of state make the difference:
#
#   - a failure counter, so a single missed poll (a controller failover, one
#     dropped packet) stays silent and only a sustained outage is reported;
#   - emit timestamps, so a condition that persists for hours is reported
#     periodically rather than on every poll.
#
# State lives in the runtime directory, which is cleared on reboot: after a
# reboot every counter should legitimately start again.
#
# Events go through warn() so pvestatd routes them to the journal, with the
# severity in the text for monitoring to pick up:
#   journalctl -t pvestatd | grep dellemc

use constant {
    # How long the array has to have been failing before an outage is
    # declared, in seconds.
    #
    # Deliberately a duration and not a count of consecutive failed polls.
    # Once PVE has marked a storage inactive it stops asking for a while, so a
    # real outage may produce only one or two calls into this plugin — a
    # counter that needs three would never fire, and the quieter the outage
    # the less likely it is to be reported. Wall-clock time is what the
    # operator experiences and what this can actually observe.
    STATUS_FAIL_SECONDS => 30,

    # While still down, repeat the outage line at most this often.
    OUTAGE_REEMIT_SECONDS => 30,

    CAPACITY_WARN_PCT => 90,
    CAPACITY_CRIT_PCT => 95,

    # One capacity message per hour per severity. Capacity moves slowly and
    # the operator can only act on it once.
    CAPACITY_COOLDOWN_SEC => 3600,
};

my $WWID_STATE = 'PVE::Storage::Custom::DellEMC::Common::WwidState';

# Same runtime directory as the WWID tracking state; both are per-node
# scratch that must not survive a reboot.
sub state_dir { $WWID_STATE->lock_dir }

sub safe_storeid {
    my ($class, $storeid) = @_;
    return $WWID_STATE->safe_storeid($storeid);
}

sub state_file {
    my ($class, $storeid) = @_;
    return $class->state_dir . '/' . $class->safe_storeid($storeid) . '-health.json';
}

# Overridable so tests can capture what would be emitted.
sub log_event {
    my ($class, $message) = @_;
    warn "$message\n";
    return;
}

# Is a rate-limited message due?
#
# Never-emitted is checked explicitly rather than leaning on 0 being far
# enough in the past, and a $last in the future — which is what a clock
# correction or an NTP step leaves behind — counts as due. Otherwise a single
# backwards jump could silence a real outage for as long as the skew lasts.
sub _due {
    my ($class, $last, $now, $interval) = @_;

    return 1 unless defined $last;
    return 1 if $now < $last;
    return ($now - $last) >= $interval ? 1 : 0;
}

sub read_state {
    my ($class, $storeid) = @_;

    my $file = $class->state_file($storeid);
    return {} unless -f $file;

    open(my $fh, '<', $file) or return {};
    local $/;
    my $json = <$fh>;
    close($fh);

    my $data = eval { decode_json($json // '') } // {};

    return ref($data) eq 'HASH' ? $data : {};
}

sub write_state {
    my ($class, $storeid, $state) = @_;

    my $dir = $class->state_dir;
    unless (-d $dir) {
        eval { File::Path::make_path($dir, { mode => 0700 }) };
        return 0 unless -d $dir;
    }

    my $file = $class->state_file($storeid);
    my $tmp  = "$file.tmp.$$";

    open(my $fh, '>', $tmp) or return 0;
    print $fh encode_json($state // {});
    close($fh);
    chmod(0600, $tmp);

    rename($tmp, $file) or do {
        unlink($tmp);
        return 0;
    };

    return 1;
}

# Record that the array could not be reached.
#
# Called from both the status path and activate_storage: PVE calls
# activate_storage first and does not reach status() if it dies, which is
# exactly what happens when the array is unreachable. Recording only in
# status() means recording nothing at all during the outages that matter.
#
# An outage is declared once the failures have been going on for
# STATUS_FAIL_SECONDS, then repeated at most every OUTAGE_REEMIT_SECONDS.
#
# Returns 1 if the storage is currently considered down.
sub record_status_failure {
    my ($class, $storeid, $reason, %opts) = @_;

    $reason = 'unknown error' unless defined $reason && length $reason;
    chomp $reason;

    my $now   = $opts{now} // time();
    my $state = $class->read_state($storeid);

    $state->{fail_count} = ($state->{fail_count} // 0) + 1;

    # A clock that went backwards must not push the start of the outage into
    # the future, where it would never be old enough to report.
    my $first = $state->{first_failure};
    $first = $now if !defined($first) || $first > $now;
    $state->{first_failure} = $first;

    my $duration = $now - $first;

    if ($duration >= STATUS_FAIL_SECONDS) {
        if (!$state->{down}
            || $class->_due($state->{last_outage_emit}, $now, OUTAGE_REEMIT_SECONDS)) {
            $class->log_event(sprintf(
                "dellemc: [ERROR] storage '%s' OUTAGE - the array API has been"
              . " unreachable for %ds (%d failed attempt(s)). Last error: %s",
                $storeid, $duration, $state->{fail_count}, $reason));
            $state->{last_outage_emit} = $now;
        }
        $state->{down} = 1;
    }

    $class->write_state($storeid, $state);

    return $state->{down} ? 1 : 0;
}

# Record a successful status poll: report recovery if the storage was down,
# reset the counter, and check capacity.
#
# $total and $used are bytes. $opts{scope} names what is filling up in the
# message, e.g. 'array' or 'volume group'.
sub record_status_ok {
    my ($class, $storeid, $total, $used, %opts) = @_;

    my $now   = $opts{now} // time();
    my $scope = $opts{scope} // 'array';
    my $state = $class->read_state($storeid);

    if ($state->{down}) {
        my $outage = defined $state->{first_failure}
            ? $now - $state->{first_failure} : 0;
        $class->log_event(sprintf(
            "dellemc: [INFO] storage '%s' RECOVERED - the array API is reachable"
          . " again after %ds.", $storeid, $outage > 0 ? $outage : 0));
    }

    $state->{fail_count}    = 0;
    $state->{down}          = 0;
    delete $state->{first_failure};

    if ($total && $total > 0) {
        my $pct = ($used // 0) / $total * 100;

        if ($pct >= CAPACITY_CRIT_PCT) {
            if ($class->_due($state->{cap_crit_emit}, $now, CAPACITY_COOLDOWN_SEC)) {
                $class->log_event(sprintf(
                    "dellemc: [ERROR] storage '%s' capacity CRITICAL - %.1f%% used"
                  . " (>= %d%%). New allocations may fail; free space or expand"
                  . " the %s.", $storeid, $pct, CAPACITY_CRIT_PCT, $scope));
                $state->{cap_crit_emit} = $now;
            }
        } elsif ($pct >= CAPACITY_WARN_PCT) {
            if ($class->_due($state->{cap_warn_emit}, $now, CAPACITY_COOLDOWN_SEC)) {
                $class->log_event(sprintf(
                    "dellemc: [WARNING] storage '%s' capacity high - %.1f%% used"
                  . " (>= %d%% of the %s).",
                    $storeid, $pct, CAPACITY_WARN_PCT, $scope));
                $state->{cap_warn_emit} = $now;
            }
        } else {
            # Back under the thresholds: clear the cooldowns so the next time
            # it climbs, the operator is told immediately rather than up to an
            # hour later.
            delete $state->{cap_warn_emit};
            delete $state->{cap_crit_emit};
        }
    }

    $class->write_state($storeid, $state);

    return 1;
}

# Is the storage currently considered down? Used to decide whether to attempt
# work that only makes sense against a reachable array.
sub is_down {
    my ($class, $storeid) = @_;
    return $class->read_state($storeid)->{down} ? 1 : 0;
}

sub fail_count {
    my ($class, $storeid) = @_;
    return $class->read_state($storeid)->{fail_count} // 0;
}

# Forget everything about a storage, e.g. when it is removed.
sub forget {
    my ($class, $storeid) = @_;

    my $file = $class->state_file($storeid);
    unlink($file) if -f $file;

    return 1;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::Health - outage and capacity reporting
for status()

=head1 SYNOPSIS

    use PVE::Storage::Custom::DellEMC::Common::Health;
    my $H = 'PVE::Storage::Custom::DellEMC::Common::Health';

    my $info = eval { $api->get_capacity() };
    if ($@) {
        $H->record_status_failure($storeid, $@);
        return undef;                       # storage shows as inactive
    }
    $H->record_status_ok($storeid, $info->{total}, $info->{used});

=head1 DESCRIPTION

status() runs every ~10 seconds per storage per node. Reporting every failed
poll would bury the real events, and reporting none would hide an outage, so
a failure counter suppresses transient failures and emit timestamps keep a
persistent condition from repeating on every poll.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
