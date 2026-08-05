# Dell EMC Unity XT storage plugin for Proxmox VE
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellUnityPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::BlockBase);

use PVE::Storage::Custom::DellEMC::Unity::API;
use PVE::Storage::Custom::DellEMC::Unity::Naming;
use PVE::Storage::Custom::DellEMC::Common::FC qw(get_fc_wwpns_raw);
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

# NOT VERIFIED. Unity reports SCSI vendor 'DGC' - the inquiry string it
# inherited from CLARiiON - rather than 'DellEMC'. This gate decides which
# devices the plugin will ever touch, so confirm it on the first run with
#   sg_inq /dev/sdX
# and narrow the product string before relying on it.
sub multipath_vendor  { 'DGC' }
sub multipath_product { 'VRAID' }

sub multipath_defaults {
    return {
        path_selector        => 'queue-length 0',
        path_grouping_policy => 'group_by_prio',
        prio                 => 'alua',
        hardware_handler     => '1 alua',
        failback             => 'immediate',
        # Never 'queue': with every path down, queued I/O that can never
        # complete puts processes into uninterruptible sleep.
        no_path_retry        => 30,
        fast_io_fail_tmo     => 5,
        dev_loss_tmo         => 60,
        detect_prio          => 'yes',
        rr_min_io_rq         => 1,
        max_sectors_kb       => 1024,
    };
}

sub multipath_config_version { 1 }

# Off until an array has run this. The config backup writes a small
# filesystem onto a volume of its own, and a family whose device discovery
# has never been confirmed should not be creating volumes nobody asked for.
sub supports_config_backup { return 0 }

sub capacity_scope {
    my ($class, $scfg) = @_;
    return defined $scfg->{'unity-pool'} ? 'pool' : 'array';
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

    my $key = join("\0",
        $scfg->{'dell-portal'}     // '',
        $scfg->{'dell-username'}   // '',
        $scfg->{'dell-ssl-verify'} // 0,
        $health,
        $health ? $class->_status_timeout($scfg) : '',
    );

    if (my $cached = $API_CACHE{$key}) {
        # A forked worker must not reuse the parent's session.
        if ((time() - $cached->{created}) < API_CACHE_TTL && $cached->{pid} == $$) {
            return $cached->{api};
        }
    }

    my %args = (
        portal     => $scfg->{'dell-portal'},
        username   => $scfg->{'dell-username'},
        password   => $scfg->{'dell-password'},
        ssl_verify => $scfg->{'dell-ssl-verify'} // 0,
        type       => $class->type(),
        storeid    => $opts{storeid},
    );

    if ($health) {
        $args{timeout} = $class->_status_timeout($scfg);
        $args{retries} = 1;
    }

    my $api = PVE::Storage::Custom::DellEMC::Unity::API->new(%args);

    $API_CACHE{$key} = { api => $api, created => time(), pid => $$ };

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
        ctime => 0,
    };
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

    # Any authenticated read proves the array is there and the credentials
    # work. A pool listing is also the thing most likely to be misconfigured,
    # so its failure is worth surfacing here rather than at the first alloc.
    my $pools = $class->_api($scfg, %opts)->pool_list(%opts);
    die "the array reported no pools\n" unless ref($pools) eq 'ARRAY' && @$pools;

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

sub _array_delete_volume {
    my ($class, $scfg, $storeid, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    # Absent is a completed delete; unreachable is not, and
    # volume_get_by_name dies rather than returning undef for that.
    my $row = $api->volume_get_by_name($name, %opts) or return 1;

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

sub _array_get_wwid {
    my ($class, $scfg, $storeid, $name, %opts) = @_;

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
    my $row = $api->snapshot_get_by_name($snapshot, %opts) or return 1;

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

sub _array_snapshot_rollback {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $row = $api->snapshot_get_by_name($snapshot, %opts)
        or die "snapshot '$snapshot' is not on the array\n";

    return $api->volume_restore($row->{id}, %opts);
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
        my $wwpns = get_fc_wwpns_raw(online_only => 1);
        die "No online FC HBA ports found on this node.\n" unless @$wwpns;
        # '1' is the FC initiator type, as a string.
        return [ map { { id => $_, type => '1' } } @$wwpns ];
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
