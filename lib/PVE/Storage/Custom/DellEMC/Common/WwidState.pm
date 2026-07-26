# Dell EMC storage plugins for Proxmox VE - WWID tracking state
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::WwidState;

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Path qw(make_path);
use JSON;

# Per-node record of which volumes this plugin has ever had devices for.
#
# The problem it solves: a volume deleted on the array from node A leaves
# every OTHER node with a multipath device pointing at storage that no longer
# answers. Nothing on those nodes is told. Later, anything that touches the
# stale device — a `vgs` during a migration, a backup scan — blocks in
# uninterruptible sleep, and the node needs a reboot.
#
# So each node keeps <state_dir>/<storeid>-wwids.json listing every WWID it
# has seen alive. status() periodically asks the array which WWIDs still
# exist, imports them (which is how a node learns about volumes created
# elsewhere), and cleans up devices for tracked WWIDs the array no longer
# reports.
#
# The plugin only ever acts on WWIDs in its own tracking file or imported
# from its own array. Devices belonging to another plugin, another vendor or
# to hand-managed storage are never touched.
#
# All methods are class methods so tests, and any future family with
# different placement needs, can subclass and override the directories.

use constant {
    # Reaper safety. The reaper acts on a point-in-time array snapshot, and
    # one incomplete or racy snapshot must never be enough to tear down a
    # live device. Both guards below have to pass.
    #
    # GRACE covers the window after a volume is mapped but before qemu opens
    # it, during which the device legitimately looks idle: no mount, no
    # holder, no open fd.
    ORPHAN_GRACE_SECONDS => 600,

    # MISS_THRESHOLD adds hysteresis, so a single truncated or failed array
    # listing cannot trigger teardown.
    ORPHAN_MISS_THRESHOLD => 3,

    # A temporary snapshot-access clone is short-lived, but the operation that
    # created it can legitimately take a while. Waiting this long before
    # considering an abandoned one for removal keeps a slow-but-live operation
    # out of the reaper's way.
    TEMP_CLONE_GRACE_SECONDS => 900,

    # Never block a storage daemon on a lock. See with_lock.
    LOCK_WAIT_SECONDS => 10,
};

sub state_dir { '/var/lib/pve-storage-dellemc' }

# Runtime state that should not survive a reboot.
sub lock_dir { '/var/run/pve-storage-dellemc' }

# A storeid reaches us from storage.cfg and ends up in a file name.
sub safe_storeid {
    my ($class, $storeid) = @_;

    $storeid = 'unknown' unless defined $storeid && length $storeid;
    $storeid =~ s/[^A-Za-z0-9_-]/_/g;

    return $storeid;
}

sub state_file {
    my ($class, $storeid) = @_;
    return $class->state_dir . '/' . $class->safe_storeid($storeid) . '-wwids.json';
}

sub lock_file {
    my ($class, $storeid) = @_;
    return $class->lock_dir . '/' . $class->safe_storeid($storeid) . '-wwids.lock';
}

# Separate lock, held for the duration of a cleanup pass so two nodes' passes
# on the same storage do not interleave.
sub cleanup_lock_file {
    my ($class, $storeid) = @_;
    return $class->lock_dir . '/' . $class->safe_storeid($storeid) . '-cleanup.lock';
}

sub ensure_dirs {
    my ($class) = @_;

    for my $dir ($class->state_dir, $class->lock_dir) {
        next if -d $dir;
        eval { make_path($dir, { mode => 0700 }) };
        warn "Cannot create $dir: $@" if $@;
    }

    return;
}

# Run $code under an exclusive lock, but never block on it.
#
# A plain flock(LOCK_EX) waits forever if another worker is stuck holding the
# lock — which is exactly the situation every timeout in this plugin exists to
# survive. After LOCK_WAIT_SECONDS we run anyway: a rare lost write to a
# tracking file costs one delayed cleanup pass, while a hung storage daemon
# costs the node.
sub with_lock {
    my ($class, $storeid, $code) = @_;

    $class->ensure_dirs();
    my $file = $class->lock_file($storeid);

    open(my $fh, '>', $file) or do {
        warn "Cannot open WWID lock file $file: $!\n";
        return $code->();
    };

    my $deadline = time() + LOCK_WAIT_SECONDS;
    my $locked = 0;
    while (time() < $deadline) {
        if (flock($fh, LOCK_EX | LOCK_NB)) {
            $locked = 1;
            last;
        }
        select(undef, undef, undef, 0.1);
    }

    unless ($locked) {
        warn "Cannot acquire WWID lock $file within " . LOCK_WAIT_SECONDS
           . "s, proceeding without it\n";
        close($fh);
        return $code->();
    }

    my @ret = eval { $code->() };
    my $err = $@;
    flock($fh, LOCK_UN);
    close($fh);
    die $err if $err;

    return wantarray ? @ret : $ret[0];
}

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------

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

    $class->ensure_dirs();
    my $file = $class->state_file($storeid);
    my $tmp  = "$file.tmp.$$";

    open(my $fh, '>', $tmp) or do {
        warn "Cannot open $tmp for writing: $!\n";
        return 0;
    };
    print $fh encode_json($state // {});
    close($fh);
    chmod(0600, $tmp);

    # Rename, so a reader never sees a half-written file.
    rename($tmp, $file) or do {
        warn "Cannot rename $tmp to $file: $!\n";
        unlink($tmp);
        return 0;
    };

    return 1;
}

# ---------------------------------------------------------------------------
# Temporary snapshot-access clones
#
# Reading a snapshot needs a short-lived clone of it on the array. The process
# that creates one normally deletes it again, but a worker that is killed
# between the two leaves an object nothing refers to: it is not a PVE volume
# name, so it never appears in list_images, and the orphan reaper will not
# touch an object the array still has. Without a record it is invisible and
# occupies array space until an operator finds it by hand.
#
# The record is per node, and so is the clone: it is only ever mapped to this
# node's host object, so another node must never reap it.
# ---------------------------------------------------------------------------

sub temp_clone_file {
    my ($class, $storeid) = @_;
    return $class->state_dir . '/' . $class->safe_storeid($storeid) . '-tmpclones.json';
}

sub _read_temp_clones {
    my ($class, $storeid) = @_;

    my $file = $class->temp_clone_file($storeid);
    return {} unless -f $file;

    open(my $fh, '<', $file) or return {};
    local $/;
    my $json = <$fh>;
    close($fh);

    my $data = eval { decode_json($json // '') } // {};

    return ref($data) eq 'HASH' ? $data : {};
}

sub _write_temp_clones {
    my ($class, $storeid, $state) = @_;

    $class->ensure_dirs();
    my $file = $class->temp_clone_file($storeid);
    my $tmp  = "$file.tmp.$$";

    open(my $fh, '>', $tmp) or do {
        warn "Cannot open $tmp for writing: $!\n";
        return 0;
    };
    print $fh encode_json($state // {});
    close($fh);
    chmod(0600, $tmp);

    rename($tmp, $file) or do {
        warn "Cannot rename $tmp to $file: $!\n";
        unlink($tmp);
        return 0;
    };

    return 1;
}

# $info records what the clone was made from, so a later caller can find the
# clones that belong to one snapshot. The name cannot carry that: PowerVault
# allows 32 bytes for a whole object name and PowerFlex 31.
sub track_temp_clone {
    my ($class, $storeid, $name, $info) = @_;

    return 0 unless defined $name && length $name;
    $info = {} unless ref($info) eq 'HASH';

    return $class->with_lock($storeid, sub {
        my $state = $class->_read_temp_clones($storeid);
        $state->{$name} = {
            pid      => $$,
            created  => time(),
            volume   => $info->{volume},
            snapshot => $info->{snapshot},
        };
        return $class->_write_temp_clones($storeid, $state);
    });
}

# Temporary clones taken from one snapshot, whichever process made them.
#
# A clone of a snapshot keeps the array from deleting that snapshot, so the
# names have to be findable by snapshot rather than only by the process that
# created them.
sub temp_clones_of_snapshot {
    my ($class, $storeid, $snapshot) = @_;

    return [] unless defined $snapshot && length $snapshot;

    my $state = $class->_read_temp_clones($storeid);

    my @names;
    for my $name (sort keys %$state) {
        my $entry = $state->{$name};
        next unless ref($entry) eq 'HASH';
        next unless defined $entry->{snapshot};
        push @names, $name if $entry->{snapshot} eq $snapshot;
    }

    return \@names;
}

sub untrack_temp_clone {
    my ($class, $storeid, $name) = @_;

    return 0 unless defined $name && length $name;

    return $class->with_lock($storeid, sub {
        my $state = $class->_read_temp_clones($storeid);
        return 1 unless exists $state->{$name};
        delete $state->{$name};
        return $class->_write_temp_clones($storeid, $state);
    });
}

# Temporary clones whose creating process is gone and that are old enough to
# be certain they are not part of an operation still starting up.
#
# kill(0) answers for a process this user may signal, which covers every PVE
# worker: they all run as root, as does this code. A pid that has been reused
# by an unrelated process only delays the reap to the next pass.
sub stale_temp_clones {
    my ($class, $storeid, %opts) = @_;

    my $grace = $opts{grace} // TEMP_CLONE_GRACE_SECONDS;
    my $now   = $opts{now}   // time();

    my $state = $class->_read_temp_clones($storeid);

    my @stale;
    for my $name (sort keys %$state) {
        my $entry = $state->{$name};
        $entry = {} unless ref($entry) eq 'HASH';

        my $age = $now - ($entry->{created} // $now);
        next if $age >= 0 && $age < $grace;

        my $pid = $entry->{pid};
        next if defined $pid && $pid > 0 && kill(0, $pid);

        push @stale, $name;
    }

    return \@stale;
}

# Normalise one entry to { first_seen, miss }.
sub entry {
    my ($class, $value) = @_;

    if (ref($value) eq 'HASH') {
        return {
            first_seen => $value->{first_seen} // time(),
            miss       => $value->{miss}       // 0,
        };
    }

    # Tolerate a bare epoch, which is what an older state file holds.
    return {
        first_seen => (defined($value) && $value) ? $value + 0 : time(),
        miss       => 0,
    };
}

# The whole tracking file with every entry normalised.
sub tracked_wwids {
    my ($class, $storeid) = @_;

    my $state = $class->read_state($storeid);

    return { map { $_ => $class->entry($state->{$_}) } keys %$state };
}

sub is_tracked {
    my ($class, $storeid, $wwid) = @_;

    return 0 unless defined $wwid;
    return exists $class->read_state($storeid)->{lc($wwid)} ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Tracking
# ---------------------------------------------------------------------------

sub track_wwid {
    my ($class, $storeid, $wwid) = @_;

    return 0 unless defined $wwid && length $wwid;

    return $class->with_lock($storeid, sub {
        my $state = $class->read_state($storeid);
        my $key = lc($wwid);
        # Keep the original first_seen: resetting it would restart the grace
        # period and delay reaping a device that has been stale for hours.
        return 0 if $state->{$key};
        $state->{$key} = { first_seen => time(), miss => 0 };
        return $class->write_state($storeid, $state);
    });
}

sub untrack_wwid {
    my ($class, $storeid, $wwid) = @_;

    return 0 unless defined $wwid && length $wwid;

    return $class->with_lock($storeid, sub {
        my $state = $class->read_state($storeid);
        return 0 unless delete $state->{lc($wwid)};
        return $class->write_state($storeid, $state);
    });
}

# Import the WWIDs the array currently reports and clear their miss counters.
#
# This is what lets node B clean up after a volume created and later deleted
# on node A: without the import, node B would have nothing tracked and would
# never look at the device it nonetheless has.
#
# Returns the number of WWIDs newly added.
sub import_alive {
    my ($class, $storeid, $wwids) = @_;

    return 0 unless ref($wwids) eq 'ARRAY' && @$wwids;

    return $class->with_lock($storeid, sub {
        my $state = $class->read_state($storeid);
        my $added = 0;
        my $changed = 0;

        for my $wwid (@$wwids) {
            next unless defined $wwid && length $wwid;
            my $key = lc($wwid);

            if (!$state->{$key}) {
                $state->{$key} = { first_seen => time(), miss => 0 };
                $added++;
                $changed++;
                next;
            }

            # Seen on the array again: any accumulated misses were transient.
            my $e = $class->entry($state->{$key});
            if ($e->{miss}) {
                $state->{$key} = { first_seen => $e->{first_seen}, miss => 0 };
                $changed++;
            }
        }

        $class->write_state($storeid, $state) if $changed;

        return $added;
    });
}

# Record that a tracked WWID was absent from the array this pass. Returns the
# updated entry.
sub record_miss {
    my ($class, $storeid, $wwid) = @_;

    return undef unless defined $wwid && length $wwid;

    return $class->with_lock($storeid, sub {
        my $state = $class->read_state($storeid);
        my $key = lc($wwid);
        return undef unless $state->{$key};

        my $e = $class->entry($state->{$key});
        $e->{miss}++;
        $state->{$key} = $e;
        $class->write_state($storeid, $state);

        return $e;
    });
}

# Both guards must pass before a device may be torn down.
sub is_reapable {
    my ($class, $entry, %opts) = @_;

    return 0 unless ref($entry) eq 'HASH';

    my $grace     = $opts{grace}     // ORPHAN_GRACE_SECONDS;
    my $threshold = $opts{threshold} // ORPHAN_MISS_THRESHOLD;
    my $now       = $opts{now}       // time();

    return 0 if ($now - ($entry->{first_seen} // $now)) < $grace;
    return 0 if ($entry->{miss} // 0) < $threshold;

    return 1;
}

# WWIDs tracked by the OTHER Dell EMC storages on this node.
#
# A cleanup pass warns about devices that are neither on this storage's array
# nor in its tracking file. On a node with several Dell storages — two
# PowerStore clusters, or a PowerStore and a PowerMax — a sibling's live
# device satisfies both conditions and would be reported to the operator as a
# stale orphan to remove by hand, on a disk that is actively in use. The state
# directory is private to this plugin, so every *-wwids.json in it belongs to
# one of our storages.
sub sibling_tracked_wwids {
    my ($class, $storeid) = @_;

    my %siblings;
    my $self_file = $class->state_file($storeid);

    for my $file (glob($class->state_dir . '/*-wwids.json')) {
        next if $file eq $self_file;

        my $data = eval {
            open(my $fh, '<', $file) or return undef;
            local $/;
            my $json = <$fh>;
            close($fh);
            decode_json($json // '');
        };
        next unless ref($data) eq 'HASH';

        $siblings{lc($_)} = 1 for keys %$data;
    }

    return \%siblings;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::WwidState - per-node WWID tracking for
the orphan reaper

=head1 SYNOPSIS

    use PVE::Storage::Custom::DellEMC::Common::WwidState;
    my $S = 'PVE::Storage::Custom::DellEMC::Common::WwidState';

    $S->track_wwid($storeid, $wwid);            # volume activated here
    $S->import_alive($storeid, $array_wwids);   # what the array still has

    for my $wwid (keys %{ $S->tracked_wwids($storeid) }) {
        next if $alive{$wwid};
        my $entry = $S->record_miss($storeid, $wwid);
        next unless $S->is_reapable($entry);
        # ... clean up the local device, then untrack_wwid
    }

=head1 SAFETY

A WWID is only reapable once it has been tracked for ORPHAN_GRACE_SECONDS and
has been missing from the array for ORPHAN_MISS_THRESHOLD consecutive passes.
Reaping a device that is actually in use destroys a running VM's disk, so the
caller must also confirm the device is idle and has no active path before
acting.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
