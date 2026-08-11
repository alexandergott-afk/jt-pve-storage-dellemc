# Dell EMC Unity XT storage plugin for Proxmox VE
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellUnityPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::BlockBase);

use PVE::Storage::Custom::DellEMC::Unity::API;
use PVE::Storage::Custom::DellEMC::Unity::Naming;
use PVE::Storage::Custom::DellEMC::Common::FC qw(get_fc_wwn_pairs);
use PVE::Storage::Custom::DellEMC::Common::ISCSI qw(get_initiator_name);

# Unity XT. The host-side work is BlockBase's; this module translates between
# PVE's names and Unity's typed REST API.
#
# Four things differ from the other families and shape the code below:
#
#   1. An object is addressed by ID, but Unity also answers a lookup BY NAME
#      directly - /instances/<type>/name:<name>. So there is no filter here,
#      and none of the "an empty answer means two things" defences the other
#      families need.
#   2. A LUN is READ as 'lun' and ACTED ON as 'storageResource'. They share
#      an id.
#   3. A snapshot is its own type, not a volume. Unlike PowerVault it cannot
#      be mapped or written to, so a linked clone is a THIN CLONE taken from
#      a snapshot - which means a template's marker snapshot has to outlive
#      its clones, exactly as on PowerVault but for a different reason.
#   4. hostAccess REPLACES the list of hosts rather than adding to it. Every
#      write of it in Unity::API reads the current list first and sends the
#      union or the difference; nothing here may bypass that.
#
# NOT VERIFIED AGAINST HARDWARE. See docs/TESTING.md.

push @PVE::Storage::Plugin::SHARED_STORAGE, 'dellunity';

sub type { 'dellunity' }

sub naming { 'PVE::Storage::Custom::DellEMC::Unity::Naming' }

# NOT VERIFIED against a device, but no longer guessed either: the vendor
# is 'DGC' - the inquiry string Unity inherited from CLARiiON - and the
# product pattern below is multipath-tools' own for that family. Confirm on
# the first run with 'sg_inq /dev/sdX'.
sub multipath_vendor  { 'DGC' }
sub multipath_product { '^(RAID|DISK|VRAID)' }

# These FOLLOW multipath-tools' built-in entry for "^DGC" instead of the
# generic ALUA settings the other families use. A conf.d device section's
# attributes override the built-in's per attribute for matching devices -
# verified on this node by installing the drop-in and reading the merged
# `multipath -t`: the final DGC entry came out as the built-in plus our
# additions, with the LUNZ blacklist intact. The built-in encodes
# CLARiiON-family behaviour that generic ALUA gets dangerously wrong:
#
#   - path_checker emc_clariion, with detect_checker explicitly 'no': the
#     family checker knows a passive SP and an inactive snapshot LU when it
#     sees one; TUR does not, and upstream pins the checker precisely so
#     autodetection cannot swap it out.
#   - prio 'emc', not 'alua': a Unity can run ALUA (failover mode 4) or
#     PNR, and 'emc' judges both. 'alua' on a PNR array scores both SPs
#     equally, I/O lands on the non-owning SP, and the LUN trespasses back
#     and forth between controllers - a performance collapse that looks
#     like a fabric problem.
#   - NO hardware_handler: the built-in deliberately sets none for DGC, and
#     forcing '1 alua' onto a PNR-mode array breaks its failover handling.
#
# What this plugin adds on top are only the bounded-recovery settings the
# built-in leaves at defaults, and they are additive, not corrective.
sub multipath_defaults {
    return {
        path_grouping_policy => 'group_by_prio',
        path_checker         => 'emc_clariion',
        detect_checker       => 'no',
        prio                 => 'emc',
        failback             => 'immediate',
        # Never 'queue': with every path down, queued I/O that can never
        # complete puts processes into uninterruptible sleep. 60 matches
        # the built-in's own bounded value.
        no_path_retry        => 60,
        fast_io_fail_tmo     => 5,
        dev_loss_tmo         => 60,
    };
}

sub multipath_config_version { 2 }

# Off until an array has run this. The config backup writes a small
# filesystem onto a volume of its own, and a family whose device discovery
# has never been confirmed should not be creating volumes nobody asked for.
sub supports_config_backup { return 0 }

sub capacity_scope {
    my ($class, $scfg) = @_;
    return defined $scfg->{'unity-pool'} ? 'pool' : 'array';
}

# 'unity-thin' defaults to on, and createLun is sent isThinEnabled 'true'
# unless it is turned off. A thick LUN's extents are whatever the pool last
# had there, so the answer follows the option rather than the default.
sub new_volumes_read_as_zeroes {
    my ($class, $scfg) = @_;
    my $thin = $scfg->{'unity-thin'};
    return 1 unless defined $thin;      # the schema default is 1
    return $thin ? 1 : 0;
}

sub identity_suffix {
    my ($class, $scfg) = @_;
    return $scfg->{'unity-pool'} // '';
}

sub _vendor_re { qr/DGC|DellEMC|DELL\s*EMC/i }

# FC first, because that is the path a customer's Unity 480 actually runs and
# the only one this family will have seen when it is first used.
sub supported_protocols { ['fc', 'iscsi'] }

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

sub family_properties {
    return {
        'unity-pool' => {
            description => "Pool that new LUNs are created in. Required on an"
                . " array with more than one pool; with a single pool the"
                . " plugin uses it.",
            type => 'string',
            optional => 1,
        },
        'unity-thin' => {
            description => "Create thin LUNs. Thin provisioning must be"
                . " licensed on the array.",
            type => 'boolean',
            default => 1,
            optional => 1,
        },
    };
}

sub family_options {
    return {
        'unity-pool' => { optional => 1 },
        'unity-thin' => { optional => 1 },
    };
}

# ---------------------------------------------------------------------------
# The client
# ---------------------------------------------------------------------------

my %API_CACHE;
use constant API_CACHE_TTL => 300;

sub _api {
    my ($class, $scfg, %opts) = @_;

    my $health = $opts{status} ? 1 : 0;

    # A PVE worker runs one task and ends with POSIX::_exit, which skips END
    # blocks and global destruction alike — so nothing at exit can give the
    # session back, which is what a customer measured on 0.8.9. Keeping the
    # client in a package hash is what holds it to that moment. Uncached, the
    # client is freed when the method returns and DESTROY releases the
    # session, which happens well before the _exit.
    #
    # PVE::RESTEnvironment->is_worker is PVE's own flag for this, set in the
    # forked child; eval because the unit tests run without PVE.
    my $worker = eval { PVE::RESTEnvironment->is_worker() } ? 1 : 0;

    # The storeid is part of the key, not only of the object.
    #
    # The client carries the storeid — every message it writes names it — and
    # the PASSWORD, which since 0.7.86 is read per storage out of
    # /etc/pve/priv/storage/<storeid>.pw. A key without the storeid therefore
    # hands storage B the client built for storage A: B's failures are logged
    # under A's name, _warn_once throttles them under A's key, and B
    # authenticates with A's password. The last one is the one that bites —
    # two storages on one array with the same username and a password that
    # has been rotated on only one of them means repeated failed logins with
    # a stale credential, and an array account that locks out takes every
    # storage on that array with it.
    my $key = join("\0",
        $opts{storeid} // '',
        $scfg->{'dell-portal'}     // '',
        $scfg->{'dell-username'}   // '',
        $scfg->{'dell-ssl-verify'} // 0,
        $health,
        $health ? $class->_status_timeout($scfg) : '',
    );

    if (!$worker && (my $cached = $API_CACHE{$key})) {
        # A forked worker must not reuse the parent's session.
        if ((time() - $cached->{created}) < API_CACHE_TTL && $cached->{pid} == $$) {
            return $cached->{api};
        }
    }

    my %args = (
        portal     => $scfg->{'dell-portal'},
        username   => $scfg->{'dell-username'},
        password   => $class->_password($scfg, $opts{storeid}),
        ssl_verify => $scfg->{'dell-ssl-verify'} // 0,
        type       => $class->type(),
        storeid    => $opts{storeid},
    );

    if ($health) {
        $args{timeout} = $class->_status_timeout($scfg);
        $args{retries} = 1;
    }

    my $api = PVE::Storage::Custom::DellEMC::Unity::API->new(%args);

    $API_CACHE{$key} = { api => $api, created => time(), pid => $$ }
        unless $worker;

    return $api;
}

# A LUN row in the shape BlockBase expects. Sizes are bytes here, not the
# 512-byte blocks PowerVault reports.
sub _volume_row {
    my ($class, $api, $row) = @_;

    return undef unless ref($row) eq 'HASH';

    my $name = $row->{name};
    return undef unless defined $name && length $name;

    return {
        name  => $name,
        id    => $row->{id},
        size  => $class->_num($row->{sizeTotal}),
        used  => $class->_num($row->{sizeAllocated} // $row->{sizeUsed}),
        wwid  => $api->wwn_to_wwid($row->{wwn}),
        # A thin clone names the snapshot it reads from. This is what lets a
        # linked clone be listed under the volid PVE stored for it.
        source_id => $api->_ref_id($row->{parentSnap}),
        ctime => 0,
    };
}

# Which volumes are linked clones, and of which template.
#
# Without this a linked clone is listed under its own name, and 'qm rescan'
# sees a volume no configuration references — so it adds the clone a SECOND
# time, as an unused disk of the VM that owns it. A Unity thin clone reports
# the snapshot it was taken from in parentSnap; a clone this plugin made was
# taken from a template's marker snapshot, whose name decodes back to the
# template. One snapshot listing answers for every volume at once — never a
# per-volume call, this runs inside list_images.
sub _array_clone_parents {
    my ($class, $scfg, $storeid, $volumes, %opts) = @_;

    return {} unless ref($volumes) eq 'ARRAY' && @$volumes;
    return {} unless grep { $_->{source_id} } @$volumes;

    my $api   = $class->_api($scfg, %opts);
    my $snaps = eval { $api->snapshot_list(%opts) } // [];

    my %base_of;
    for my $snap (@$snaps) {
        my $name = $snap->{name} or next;
        my $id   = $snap->{id}   or next;
        my $decoded = $class->naming->decode_snapshot_name($name) or next;
        $base_of{$id} = $decoded->{volume} if $decoded->{is_base};
    }

    return {} unless %base_of;

    my %parents;
    for my $volume (@$volumes) {
        my $source = $volume->{source_id} // next;
        my $base   = $base_of{$source}    // next;
        $parents{ $volume->{name} } = $base;
    }

    return \%parents;
}

sub _num {
    my ($class, $value) = @_;

    return 0 unless defined $value && !ref($value) && $value =~ /^\d+\z/;

    return $value + 0;
}

# Unity timestamps are ISO 8601 with a zone offset. Reading the offset and
# discarding it dates every snapshot wrong by the node's distance from UTC,
# which reads as a bug in PVE because nothing about it points at the storage.
sub _to_epoch {
    my ($class, $value) = @_;

    return 0 unless defined $value && !ref($value);

    my ($y, $mo, $d, $h, $mi, $s, $zone) = $value =~
        /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?/
        or return 0;

    require Time::Local;
    my $epoch = eval {
        Time::Local::timegm($s + 0, $mi + 0, $h + 0, $d + 0, $mo - 1, $y + 0)
    };
    return 0 unless defined $epoch;

    if (defined $zone && $zone ne 'Z') {
        my ($sign, $zh, $zm) = $zone =~ /^([+-])(\d{2}):?(\d{2})$/ or return $epoch;
        my $offset = ($zh * 3600) + ($zm * 60);
        $epoch += ($sign eq '+') ? -$offset : $offset;
    }

    return $epoch;
}

# ---------------------------------------------------------------------------
# Array operations
# ---------------------------------------------------------------------------

sub _array_ping {
    my ($class, $scfg, %opts) = @_;

    # basicSystemInfo, not a pool listing: the health path already lists the
    # pools for capacity in the same cycle, and pinging with a second copy of
    # the same request doubled the array's cost of every poll for nothing.
    # This endpoint is also the cheapest thing a Unity serves, and its answer
    # names the model - which is what a first run's log needs.
    my $system = $class->_api($scfg, %opts)->system_info(%opts);
    die "the array did not report a system object\n" unless $system;

    return 1;
}

sub _array_get_capacity {
    my ($class, $scfg, %opts) = @_;

    return $class->_api($scfg, %opts)->get_managed_capacity(
        pool => $scfg->{'unity-pool'}, %opts);
}

sub _array_get_volume {
    my ($class, $scfg, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $row = $api->volume_get_by_name($name, %opts) or return undef;

    return $class->_volume_row($api, $row);
}

sub _array_list_volumes {
    my ($class, $scfg, $storeid, $prefix, %opts) = @_;

    my $api  = $class->_api($scfg, %opts);
    my $rows = $api->volume_list(%opts) // [];

    my @out;
    for my $row (@$rows) {
        my $volume = $class->_volume_row($api, $row) or next;
        next if defined $prefix && length $prefix
             && index($volume->{name}, $prefix) != 0;
        push @out, $volume;
    }

    return \@out;
}

sub _array_create_volume {
    my ($class, $scfg, $storeid, $name, $size, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $id = $api->volume_create($name, $size,
        pool => $scfg->{'unity-pool'},
        thin => $scfg->{'unity-thin'} // 1,
        %opts);

    # After a create the object may not be queryable yet, and the caller maps
    # it next.
    $class->_await_volume($api, $name, %opts);

    return $id;
}

sub _await_volume {
    my ($class, $api, $name, %opts) = @_;

    for my $attempt (1 .. 10) {
        my $row = eval { $api->volume_get_by_name($name, %opts) };
        return $row if $row;
        select(undef, undef, undef, 0.5);
    }

    die "the array created volume '$name' but did not report it back within"
      . " five seconds\n";
}

# "Absent" on a DESTRUCTIVE path is confirmed by a listing, not believed
# from a single 404.
#
# The manual gives three causes for 404: an invalid id, an invalid resource
# type name, and an invalid URI PATTERN. The by-name lookup is a URI pattern
# — /instances/lun/name:<name> — and whether this firmware supports it is
# exactly the kind of thing nothing here has run against. If it does not,
# every lookup answers 404, every volume reads as absent, and free_image
# reports success for deletes that never happened: PVE drops the disk from
# the VM configuration while the data sits on the array. Lesson 37's shape,
# arriving through a new door.
#
# So when the by-name lookup says absent and the next step is to NOT delete
# something, the listing gets the last word: a listing that succeeds without
# the name in it proves absence; a listing that carries the name proves the
# lookup is broken, and that is a loud error naming the firmware, not a
# quiet success. The cost is one listing per delete-of-absent, which is
# rare.
sub _absence_confirmed {
    my ($class, $api, $kind, $name, %opts) = @_;

    my $rows = $kind eq 'snap' ? $api->snapshot_list(%opts)
                               : $api->volume_list(%opts);

    my ($ghost) = grep { ($_->{name} // '') eq $name } @$rows;
    return 1 unless $ghost;

    die "the by-name lookup reports '$name' absent, but the $kind listing"
      . " carries it (id $ghost->{id}). This firmware may not support"
      . " /instances/<type>/name: lookups; please report its version."
      . " Refusing to treat the volume as deleted.\n";
}

sub _array_delete_volume {
    my ($class, $scfg, $storeid, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    # Absent is a completed delete; unreachable is not, and
    # volume_get_by_name dies rather than returning undef for that. A 404,
    # though, is only believed after the listing agrees — see above.
    my $row = $api->volume_get_by_name($name, %opts);
    return $class->_absence_confirmed($api, 'lun', $name, %opts) unless $row;

    return $api->volume_delete($row->{id}, %opts);
}

sub _array_resize_volume {
    my ($class, $scfg, $storeid, $name, $size, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $row = $api->volume_get_by_name($name, %opts)
        or die "volume '$name' is not on the array\n";

    # Unity takes the new TOTAL, not a delta.
    return $api->volume_resize($row->{id}, $size, %opts);
}

sub _array_rename_volume {
    my ($class, $scfg, $storeid, $from, $to, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $row = $api->volume_get_by_name($from, %opts)
        or die "volume '$from' is not on the array\n";

    return $api->volume_rename($row->{id}, $to, %opts);
}

# Two arguments after the class, NOT three. BlockBase calls every
# _array_get_wwid as ($scfg, $array_name) - ten call sites, no storeid - and
# an extra parameter here meant the volume NAME landed in it while $name
# stayed undef. Every WWID lookup then answered undef, which is device
# discovery dead on arrival: path() hands back /dev/mapper/unknown-*,
# activation cannot find the disk it just mapped, and free_image takes the
# no-WWID branch. The lifecycle tests missed it because they stub the device
# layer; the signature test below does not.
sub _array_get_wwid {
    my ($class, $scfg, $name, %opts) = @_;

    return $class->_api($scfg, %opts)->volume_get_wwid($name, %opts);
}

# ---------------------------------------------------------------------------
# Snapshots
#
# Their own type here, not volumes. A snapshot cannot be mapped, so nothing
# in this family hands one to a host.
# ---------------------------------------------------------------------------

sub _array_snapshot_create {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $row = $api->volume_get_by_name($volume, %opts)
        or die "volume '$volume' is not on the array\n";

    return $api->snapshot_create($row->{id}, $snapshot, %opts);
}

sub _array_snapshot_get {
    my ($class, $scfg, $storeid, $snapshot, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $row = $api->snapshot_get_by_name($snapshot, %opts) or return undef;

    return {
        name  => $row->{name},
        id    => $row->{id},
        size  => $class->_num($row->{size}),
        used  => 0,
        wwid  => undef,
        ctime => $class->_to_epoch($row->{creationTime}),
    };
}

sub _array_snapshot_delete {
    my ($class, $scfg, $storeid, $snapshot, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    # Same confirmation as a volume delete: a snapshot wrongly read as
    # absent stays on the array, and Unity then refuses to delete the LUN it
    # belongs to — the volume becomes undeletable with nothing pointing at
    # the cause.
    my $row = $api->snapshot_get_by_name($snapshot, %opts);
    return $class->_absence_confirmed($api, 'snap', $snapshot, %opts) unless $row;

    return $api->snapshot_delete($row->{id}, %opts);
}

sub _array_snapshot_list {
    my ($class, $scfg, $storeid, $volume, $prefix, %opts) = @_;

    my $api  = $class->_api($scfg, %opts);
    my $rows = eval { $api->snapshot_list(%opts) } // [];

    my @out;
    for my $row (@$rows) {
        my $name = $row->{name};
        next unless defined $name && length $name;
        next if defined $prefix && length $prefix && index($name, $prefix) != 0;

        # Only names this plugin produced, and only for the volume asked
        # about. Deciding by the snapshot's parent id would be a per-object
        # call in a loop; the name already says which volume it belongs to.
        if (defined $volume && length $volume) {
            my $decoded = $class->naming->decode_snapshot_name($name);
            next unless $decoded && $decoded->{volume} eq $volume;
        }

        push @out, {
            name  => $name,
            id    => $row->{id},
            size  => $class->_num($row->{size}),
            used  => 0,
            wwid  => undef,
            ctime => $class->_to_epoch($row->{creationTime}),
        };
    }

    return \@out;
}

# The backup snapshot a restore leaves behind gets OUR name — and a name no
# user can collide with.
#
# Unity creates one on every restore whether or not it was asked for. With a
# name of the array's choosing it is invisible to the snapshot purge that has
# to run before a volume can be deleted - and Unity refuses to delete a LUN
# that still has snapshots, so the volume becomes undeletable from then on.
#
# The name has to satisfy three parties at once:
#   - the PURGE: it must decode back to this volume, or a volume delete
#     leaves it behind;
#   - the USER: it must be a snapname no PVE user can ever have chosen. PVE
#     forbids '.' in a snapshot name, so 'pve.rollback' is out of their
#     reach - an earlier draft used 'rollback', which a user can type, and
#     the cleanup below would then have deleted their snapshot;
#   - the ROLLBACK GUARD: volume_snapshot_list filters it out (below), or
#     the backup - always the newest snapshot - would make every SECOND
#     rollback refuse with "not the most recent snapshot".
#
# Room is left for the counter Unity appends when the name is taken.
use constant ROLLBACK_SNAPNAME => 'pve.rollback';

sub _rollback_copy_name {
    my ($class, $volume) = @_;

    my $naming = $class->naming;
    my $name = $volume
        . PVE::Storage::Custom::DellEMC::Common::Naming::SNAPSHOT_INFIX
        . ROLLBACK_SNAPNAME;

    my $room = $naming->max_snapshot_name_length - 4;
    $name = substr($name, 0, $room) if length($name) > $room;

    return $name;
}

sub _is_rollback_backup {
    my ($class, $snapname) = @_;

    return 0 unless defined $snapname;
    return index($snapname, ROLLBACK_SNAPNAME) == 0 ? 1 : 0;
}

sub _array_snapshot_rollback {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $row = $api->snapshot_get_by_name($snapshot, %opts)
        or die "snapshot '$snapshot' is not on the array\n";

    # One safety-net backup is enough. Without this they accumulate one per
    # rollback, each holding space, none visible to PVE, all of them only
    # ever cleaned when the volume itself is deleted. The dot in the name is
    # what makes this delete safe: no user snapshot can be named this.
    my $existing = eval { $api->snapshot_list(%opts) } // [];
    for my $old (@$existing) {
        my $name = $old->{name} // next;
        my $decoded = $class->naming->decode_snapshot_name($name) or next;
        next unless ($decoded->{volume} // '') eq $volume;
        next unless $class->_is_rollback_backup($decoded->{snapname});

        eval { $api->snapshot_delete($old->{id}, %opts) };
        warn "Could not remove the previous rollback backup '$name': $@" if $@;
    }

    return $api->volume_restore($row->{id},
        copy_name => $class->_rollback_copy_name($volume), %opts);
}

# The rollback backups stay out of PVE's sight. They are not restore points
# PVE knows about, and being the newest snapshot on the volume they would
# otherwise make volume_rollback_is_possible refuse every second rollback.
# The PURGE does not come through here - it walks _array_snapshot_list
# directly - so hiding them from PVE does not orphan them.
sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $snapshots = $class->SUPER::volume_snapshot_list($scfg, $storeid, $volname);

    return [ grep { !$class->_is_rollback_backup($_->{name}) } @$snapshots ];
}

# A linked clone is a THIN CLONE of a snapshot. The snapshot has to exist
# first, which is why the caller creates the marker before cloning it - and
# why deleting a template with live clones is refused by the array.
# A linked clone is a THIN CLONE, and Unity takes one only from a SNAPSHOT.
#
# BlockBase names the source in both of its clone paths, and the two differ:
# the temporary-clone path for reading a snapshot names a SNAPSHOT, while
# clone_image names whatever the template's marker is. So this resolves what
# it was given rather than assuming, and creates a snapshot to clone from
# when it was handed a LUN — the array has no other way to do it.
#
# The snapshot it creates in that case belongs to the clone: it is what the
# clone reads from, so deleting it while the clone lives is refused, exactly
# as for a template's marker.
sub _array_clone {
    my ($class, $scfg, $storeid, $source, $target, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $snap = $api->snapshot_get_by_name($source, %opts);
    my $parent;

    if ($snap) {
        # Cloning a snapshot: its storage resource is the LUN underneath.
        my $resource = $snap->{storageResource};
        $parent = $api->_ref_id($resource);

        # Older firmware may report the LUN instead, or nothing at all; fall
        # back to the name this plugin encoded the snapshot from rather than
        # guessing an id.
        unless (defined $parent && length $parent) {
            my $decoded = $class->naming->decode_snapshot_name($source);
            my $volume = $decoded && $decoded->{volume};
            my $row = $volume ? $api->volume_get_by_name($volume, %opts) : undef;
            $parent = $row ? $row->{id} : undef;
        }

        die "the array reports snapshot '$source' but not which LUN it"
          . " belongs to, so it cannot be cloned\n"
            unless defined $parent && length $parent;
    } else {
        my $row = $api->volume_get_by_name($source, %opts)
            or die "Clone source '$source' does not exist on the array\n";
        $parent = $row->{id};

        # Unity clones from a snapshot and nothing else, so make one.
        my $marker = $class->naming->encode_base_snapshot_name($source);
        my $existing = $api->snapshot_get_by_name($marker, %opts);
        my $snap_id = $existing ? $existing->{id}
                                : $api->snapshot_create($parent, $marker, %opts);
        $snap = { id => $snap_id };
    }

    my $id = $api->volume_clone($parent, $snap->{id}, $target, %opts);

    $class->_await_volume($api, $target, %opts);

    return $id;
}

# ---------------------------------------------------------------------------
# Hosts
# ---------------------------------------------------------------------------

sub _initiator_records {
    my ($class, $scfg) = @_;

    if ($class->_is_fc($scfg)) {
        # Unity identifies an FC initiator by the NODE WWN and the PORT WWN
        # together, colon-separated:
        #   20:00:00:00:c9:29:0f:fd:10:00:00:00:c9:29:0f:fd
        # which is what Unisphere and uemcli show. Sending the port WWN alone,
        # and without colons, is what this did until 0.7.96 — the same defect
        # a PowerStore rejected outright on its first hardware run. NOT
        # VERIFIED against a Unity: no array has run this.
        my $wwns = get_fc_wwn_pairs(online_only => 1);
        die "No online FC HBA ports found on this node.\n" unless @$wwns;
        # '1' is the FC initiator type, as a string.
        return [ map { { id => $_, type => '1' } } @$wwns ];
    }

    return [ { id => get_initiator_name(), type => '2' } ];
}

sub _array_ensure_host {
    my ($class, $scfg, $storeid, %opts) = @_;

    my $api  = $class->_api($scfg, %opts);
    my $name = $class->_host_name($scfg);
    my $want = $class->_initiator_records($scfg);

    my $host = eval { $api->host_get_by_name($name, %opts) };

    unless ($host) {
        my $id = eval { $api->host_create($name, %opts) };
        if ($@) {
            chomp(my $why = $@);
            die "Failed to create host '$name' on the array. This node's"
              . " initiator is most likely already registered to a different"
              . " host object; remove that one in Unisphere, or set"
              . " 'dell-cluster-name' so the generated host name matches the"
              . " existing one.\n  Array error: $why\n"
                if $why =~ /already|exists|in use|duplicate/i;
            die "Failed to create host '$name' on the array: $why\n";
        }

        $host = eval { $api->host_get_by_name($name, %opts) }
            or die "The array accepted 'create host' for '$name' but does not"
                 . " report it back. Please report this array's firmware"
                 . " version.\n";
    }

    # The host exists. A reinstalled node, or one that gained an HBA port, has
    # initiators the host object does not know about yet and would otherwise
    # see nothing at all.
    my %present;
    for my $field (qw(fcHostInitiators iscsiHostInitiators)) {
        my $list = $host->{$field};
        next unless ref($list) eq 'ARRAY';
        for my $entry (@$list) {
            my $id = ref($entry) eq 'HASH' ? $entry->{id} : $entry;
            $present{lc($id)} = 1 if defined $id && !ref($id);
        }
    }

    # An initiator is listed by its own object id, not by its WWPN, so this
    # cannot match on the WWPN alone. Ask the array which initiator ids carry
    # this node's WWPNs, once, rather than per initiator.
    my $known = eval { $api->host_initiators(%opts) } // [];
    my %id_of;
    for my $row (@$known) {
        my $wwn = $row->{initiatorId} // next;
        $id_of{ lc($wwn) } = $row;
    }

    my @missing;
    for my $want_one (@$want) {
        my $row = $id_of{ lc($want_one->{id}) };

        # Registered somewhere already: on this host is fine, on another one
        # is not something to paper over by adding it again.
        if ($row) {
            my $parent = $row->{parentHost};
            $parent = $parent->{id} if ref($parent) eq 'HASH';
            next if defined $parent && $parent eq ($host->{id} // '');
            next if $present{ lc($row->{id} // '') };

            die "This node's initiator $want_one->{id} is registered to"
              . " another host object on the array. Remove that registration"
              . " in Unisphere, or set 'dell-cluster-name' so this storage"
              . " uses the existing host.\n"
                if defined $parent && length $parent;
        }

        push @missing, $want_one;
    }

    return $name unless @missing;

    for my $one (@missing) {
        eval { $api->host_add_initiator($host->{id}, $one->{id}, $one->{type}, %opts) };
        if ($@) {
            chomp(my $why = $@);
            die "Failed to register this node's initiator $one->{id} with host"
              . " '$name'.\n  Array error: $why\n";
        }
    }

    return $name;
}

sub _array_list_hosts {
    my ($class, $scfg, $prefix, %opts) = @_;

    my $hosts = eval { $class->_api($scfg, %opts)->host_list(%opts) } // [];

    my @out;
    for my $host (@$hosts) {
        my $name = $host->{name} // next;
        next if defined $prefix && length $prefix && index($name, $prefix) != 0;
        push @out, { name => $name, id => $host->{id} };
    }

    return \@out;
}

sub _host_id {
    my ($class, $scfg, $host_name, %opts) = @_;

    my $host = eval { $class->_api($scfg, %opts)->host_get_by_name($host_name, %opts) };

    return $host ? $host->{id} : undef;
}

# ---------------------------------------------------------------------------
# Mapping
#
# Both directions go through Unity::API, which reads the current hostAccess
# list and sends the union or the difference. Nothing here may write that
# list directly: sending only this node's host is how a volume gets unmapped
# from every other node in the cluster.
# ---------------------------------------------------------------------------

sub _array_map_to_host {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $host_id = $class->_host_id($scfg, $host_name, %opts);
    die "Host '$host_name' is not registered on the array\n" unless $host_id;

    return $class->_api($scfg, %opts)->volume_attach($name, $host_id, %opts);
}

sub _array_unmap_from_host {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $host_id = $class->_host_id($scfg, $host_name, %opts);
    return 1 unless $host_id;

    return $class->_api($scfg, %opts)->volume_detach($name, $host_id, %opts);
}

sub _array_is_mapped {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $host_id = $class->_host_id($scfg, $host_name, %opts) or return 0;

    return $class->_api($scfg, %opts)->is_mapped_to($name, $host_id, %opts);
}

sub _array_mapped_hosts {
    my ($class, $scfg, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $ids = eval { $api->volume_mapped_hosts($name, %opts) } // [];
    return [] unless @$ids;

    # One host listing, then a lookup. A per-mapping host query would be N
    # round trips on a path that runs during every delete.
    my $hosts = eval { $api->host_list(%opts) } // [];
    my %name_of = map { ($_->{id} // '') => $_->{name} } @$hosts;

    my %seen;
    my @names;
    for my $id (@$ids) {
        my $host_name = $name_of{$id} // next;
        push @names, $host_name unless $seen{$host_name}++;
    }

    return \@names;
}

# ---------------------------------------------------------------------------
# iSCSI portals
#
# NOT VERIFIED. The FC path is what a customer's Unity 480 runs and is what
# this family will have been exercised on first; this is here so an iSCSI
# storage fails with something legible rather than with nothing at all.
# ---------------------------------------------------------------------------

sub _array_get_portals {
    my ($class, $scfg, %opts) = @_;

    my $api  = $class->_api($scfg, %opts);
    my $rows = eval { $api->_collection('iscsiPortal',
        'id,ipAddress,iscsiNode,ethernetPort', %opts) } // [];

    my @portals;
    for my $row (@$rows) {
        my $address = $row->{ipAddress} // next;
        my $node = $row->{iscsiNode};
        my $iqn  = ref($node) eq 'HASH' ? $node->{name} : undef;

        push @portals, {
            portal => "$address:3260",
            iqn    => $iqn,
        };
    }

    return \@portals;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellUnityPlugin - Dell EMC Unity XT storage plugin

=head1 DESCRIPTION

One VM disk is one Unity LUN. Snapshots, thin clones and capacity come from
the array; dm-multipath, device discovery and the safety checks are
L<PVE::Storage::Custom::DellEMC::Common::BlockBase>'s.

B<Nothing here has been run against a Unity array.> See F<docs/TESTING.md>.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
