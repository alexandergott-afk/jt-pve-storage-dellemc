# Dell PowerStore storage plugin for Proxmox VE
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellPowerStorePlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::BlockBase);

use Time::Local ();

use PVE::Storage::Custom::DellEMC::PowerStore::API;
use PVE::Storage::Custom::DellEMC::PowerStore::Naming;
use PVE::Storage::Custom::DellEMC::Common::FC qw(get_fc_wwpns_raw);
use PVE::Storage::Custom::DellEMC::Common::ISCSI qw(get_initiator_name);

# The PowerStore half of the plugin: everything here is about translating
# between the array's REST objects and what BlockBase asks for. The host-side
# work — device discovery, multipath, orphan reaping — lives in BlockBase and
# the Common modules.
#
# PowerStore addresses objects by id while PVE and BlockBase work in names,
# so most methods here start by resolving a name to an id.

# PVE marks a storage type as shared-capable through this list. Without it the
# GUI refuses to set 'shared 1', which live migration needs.
push @PVE::Storage::Plugin::SHARED_STORAGE, 'dellpowerstore';

sub type { 'dellpowerstore' }

sub naming { 'PVE::Storage::Custom::DellEMC::PowerStore::Naming' }

# NOT YET VERIFIED against hardware. Confirm the exact strings with
#   sg_inq /dev/sdX
# or `multipathd show config`, and narrow this before relying on it; the
# vendor gate decides which devices the plugin will ever touch.
sub multipath_vendor  { 'DellEMC' }
sub multipath_product { 'PowerStore' }

# Dell's Linux host connectivity guidance for PowerStore. Every value here
# still needs checking against the current guide for the firmware in use.
sub multipath_defaults {
    return {
        path_selector        => 'queue-length 0',
        path_grouping_policy => 'group_by_prio',
        prio                 => 'alua',
        hardware_handler     => '1 alua',
        failback             => 'immediate',
        # Never 'queue': with every path down, queued I/O that can never
        # complete puts processes into uninterruptible sleep and the node
        # needs a reboot.
        no_path_retry        => 30,
        fast_io_fail_tmo     => 5,
        dev_loss_tmo         => 60,
        detect_prio          => 'yes',
        rr_min_io_rq         => 1,
        max_sectors_kb       => 1024,
    };
}

sub multipath_config_version { 1 }

sub capacity_scope { 'array' }

sub identity_suffix {
    my ($class, $scfg) = @_;
    return $scfg->{'pstore-appliance'} // '';
}

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

sub family_properties {
    return {
        'pstore-appliance' => {
            description => "Name or id of the appliance new volumes are placed"
                . " on, in a multi-appliance cluster. Leave unset to let"
                . " PowerStore choose.",
            type => 'string',
            optional => 1,
        },
        'pstore-volume-group' => {
            description => "Place every volume of this storage in the named"
                . " volume group, which gives them a namespace on the array"
                . " and lets protection policies apply to them as a unit. The"
                . " group must already exist.",
            type => 'string',
            optional => 1,
        },
        'pstore-performance-policy' => {
            description => "Performance policy applied to new volumes.",
            type => 'string',
            enum => ['High', 'Medium', 'Low'],
            default => 'Medium',
            optional => 1,
        },
        'pstore-protection-policy' => {
            description => "Protection policy (snapshot and replication rules)"
                . " applied to new volumes. The policy must already exist on"
                . " the array.",
            type => 'string',
            optional => 1,
        },
        'pstore-lun-id-base' => {
            description => "Lowest LUN id this plugin assigns when attaching a"
                . " volume. The plugin assigns LUN ids itself because"
                . " PowerStore's automatic REST-side sequence starts at 200 and"
                . " never reuses an id, which eventually exceeds what the host"
                . " scans. Raise this only if something else on the array"
                . " already uses the low ids on these hosts.",
            type => 'integer',
            minimum => 1,
            maximum => 200,
            default => 1,
            optional => 1,
        },
    };
}

sub family_options {
    return {
        'pstore-appliance'          => { optional => 1 },
        'pstore-volume-group'       => { optional => 1 },
        'pstore-performance-policy' => { optional => 1 },
        'pstore-protection-policy'  => { optional => 1 },
        'pstore-lun-id-base'        => { optional => 1 },
    };
}

# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------

my %API_CACHE;
use constant API_CACHE_TTL => 300;

# How long to wait for an object the array has accepted but not yet published.
use constant AWAIT_OBJECT_TIMEOUT => 30;

# The health path (activate_storage and the foreground of status) gets a
# short-timeout, single-attempt client; everything else gets the resilient
# one. They are cached separately so neither replaces the other.
sub _api {
    my ($class, $scfg, %opts) = @_;

    my $health = $opts{status} ? 1 : 0;

    # $scfg carries no storage id, so key on everything that actually
    # distinguishes one client from another. Two storages pointing at the same
    # array with different credentials must not share a session.
    my $key = join("\0",
        $scfg->{'dell-portal'}   // '',
        $scfg->{'dell-username'} // '',
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

    my $api = PVE::Storage::Custom::DellEMC::PowerStore::API->new(%args);

    $API_CACHE{$key} = { api => $api, created => time(), pid => $$ };

    return $api;
}

# PowerStore timestamps are ISO 8601 in UTC. PVE wants epoch seconds; handing
# the string through renders snapshot dates in the GUI as nonsense.
sub _to_epoch {
    my ($class, $value) = @_;

    return 0 unless defined $value && length $value;
    return $value + 0 if $value =~ /^\d+$/;

    if ($value =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        return eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) } // 0;
    }

    return 0;
}

# ---------------------------------------------------------------------------
# Name to id resolution
# ---------------------------------------------------------------------------

sub _volume_id {
    my ($class, $scfg, $name, %opts) = @_;

    my $vol = $class->_api($scfg, %opts)->volume_get_by_name($name, %opts);

    return $vol ? $vol->{id} : undef;
}

sub _require_volume_id {
    my ($class, $scfg, $name, %opts) = @_;

    my $id = $class->_volume_id($scfg, $name, %opts);
    die "Volume '$name' does not exist on the array\n" unless $id;

    return $id;
}

sub _snapshot_id {
    my ($class, $scfg, $name, %opts) = @_;

    my $snap = $class->_api($scfg, %opts)->snapshot_get_by_name($name, %opts);

    return $snap ? $snap->{id} : undef;
}

sub _host_id {
    my ($class, $scfg, $host_name, %opts) = @_;

    my $host = $class->_api($scfg, %opts)->host_get_by_name($host_name, %opts);

    return $host ? $host->{id} : undef;
}

# A row from the array turned into what BlockBase expects.
sub _volume_row {
    my ($class, $row) = @_;

    return undef unless $row && $row->{name};

    my $protection = $row->{protection_data};

    return {
        id    => $row->{id},
        name  => $row->{name},
        size  => $row->{size} // 0,
        used  => $row->{logical_used} // 0,
        wwid  => PVE::Storage::Custom::DellEMC::PowerStore::API->wwn_to_wwid($row->{wwn}),
        ctime => $class->_to_epoch($row->{creation_timestamp}),
        # The object a thin clone or snapshot was created from. Used to report
        # a linked clone under the volid PVE stored for it.
        source_id => ref($protection) eq 'HASH' ? $protection->{source_id} : undef,
    };
}

# ---------------------------------------------------------------------------
# Array operations
# ---------------------------------------------------------------------------

sub _array_ping {
    my ($class, $scfg, %opts) = @_;

    my $cluster = $class->_api($scfg, %opts)->cluster_get(%opts);
    die "the array did not report a cluster object\n" unless $cluster;

    return 1;
}

sub _array_get_capacity {
    my ($class, $scfg, %opts) = @_;
    return $class->_api($scfg, %opts)->get_managed_capacity(%opts);
}

sub _array_get_volume {
    my ($class, $scfg, $name, %opts) = @_;

    my $row = $class->_api($scfg, %opts)->volume_get_by_name($name, %opts);

    return $class->_volume_row($row);
}

sub _array_list_volumes {
    my ($class, $scfg, $storeid, $prefix, %opts) = @_;

    my $rows = $class->_api($scfg, %opts)->volume_list($prefix, %opts) // [];

    my @out;
    for my $row (@$rows) {
        # The array's prefix filter is case-insensitive; ours is not, and the
        # ownership boundary has to be exact.
        next unless defined $row->{name};
        next if defined $prefix && index($row->{name}, $prefix) != 0;
        push @out, $class->_volume_row($row);
    }

    return \@out;
}

sub _array_create_volume {
    my ($class, $scfg, $storeid, $name, $size, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my %args;
    $args{appliance_id} = $scfg->{'pstore-appliance'}
        if defined $scfg->{'pstore-appliance'} && length $scfg->{'pstore-appliance'};

    for my $pair (
        ['pstore-volume-group'       => 'volume_group_id'],
        ['pstore-performance-policy' => 'performance_policy_id'],
        ['pstore-protection-policy'  => 'protection_policy_id'],
    ) {
        my ($option, $field) = @$pair;
        my $value = $scfg->{$option};
        $args{$field} = $value if defined $value && length $value;
    }

    $args{description} = "Proxmox VE storage $storeid" if defined $storeid;

    my $id = $api->volume_create($name, $size, %args);

    # PowerStore answers some requests with 202 and a job id instead of the
    # finished object. The caller looks the volume up by name immediately
    # afterwards, so wait for it to actually be there rather than failing with
    # "does not exist" on a volume that is merely still being created.
    $class->_await_volume($scfg, $name, %opts);

    return $id;
}

# Wait for a named volume to become visible, bounded. Returns 1 as soon as it
# is there; dies with a message that names the volume if it never appears.
sub _await_volume {
    my ($class, $scfg, $name, %opts) = @_;

    my $deadline = time() + ($opts{await_timeout} // AWAIT_OBJECT_TIMEOUT);

    while (1) {
        return 1 if eval { $class->_volume_id($scfg, $name, %opts) };
        last if time() >= $deadline;
        sleep(1);
    }

    die "The array accepted the request but volume '$name' had not appeared"
      . " after " . AWAIT_OBJECT_TIMEOUT . "s. The operation may still be"
      . " running as a background job; check PowerStore Manager before"
      . " retrying.\n";
}

sub _array_delete_volume {
    my ($class, $scfg, $storeid, $name, %opts) = @_;

    my $id = $class->_volume_id($scfg, $name, %opts);
    return 1 unless $id;   # already gone; deletion is idempotent

    return $class->_api($scfg, %opts)->volume_delete($id, %opts);
}

sub _array_resize_volume {
    my ($class, $scfg, $storeid, $name, $size, %opts) = @_;

    my $id = $class->_require_volume_id($scfg, $name, %opts);

    return $class->_api($scfg, %opts)->volume_resize($id, $size, %opts);
}

sub _array_rename_volume {
    my ($class, $scfg, $storeid, $from, $to, %opts) = @_;

    my $id = $class->_require_volume_id($scfg, $from, %opts);

    return $class->_api($scfg, %opts)->volume_rename($id, $to, %opts);
}

sub _array_get_wwid {
    my ($class, $scfg, $name, %opts) = @_;

    my $vol = $class->_array_get_volume($scfg, $name, %opts);

    return $vol ? $vol->{wwid} : undef;
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

sub _array_snapshot_create {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    my $id = $class->_require_volume_id($scfg, $volume, %opts);

    return $class->_api($scfg, %opts)->snapshot_create($id, $snapshot, %opts);
}

sub _array_snapshot_get {
    my ($class, $scfg, $storeid, $snapshot, %opts) = @_;

    my $row = $class->_api($scfg, %opts)->snapshot_get_by_name($snapshot, %opts);

    return $class->_volume_row($row);
}

sub _array_snapshot_delete {
    my ($class, $scfg, $storeid, $snapshot, %opts) = @_;

    my $id = $class->_snapshot_id($scfg, $snapshot, %opts);
    return 1 unless $id;

    return $class->_api($scfg, %opts)->snapshot_delete($id, %opts);
}

sub _array_snapshot_list {
    my ($class, $scfg, $storeid, $volume, $prefix, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my %query;
    if (defined $volume && length $volume) {
        my $id = $class->_volume_id($scfg, $volume, %opts);
        return [] unless $id;
        $query{source_id} = $id;
    }
    $query{prefix} = $prefix if defined $prefix && length $prefix;

    my $rows = $api->snapshot_list(%query, %opts) // [];

    return [ map { $class->_volume_row($_) } grep { $_->{name} } @$rows ];
}

sub _array_snapshot_rollback {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    my $volume_id = $class->_require_volume_id($scfg, $volume, %opts);
    my $snap_id   = $class->_snapshot_id($scfg, $snapshot, %opts);
    die "Snapshot '$snapshot' does not exist on the array\n" unless $snap_id;

    return $class->_api($scfg, %opts)->volume_restore($volume_id, $snap_id, %opts);
}

# The source may be a volume or one of its snapshots; both are volume objects
# on PowerStore, so one lookup covers either.
sub _array_clone {
    my ($class, $scfg, $storeid, $source, $target, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $source_id = $class->_volume_id($scfg, $source, %opts)
        // $class->_snapshot_id($scfg, $source, %opts);
    die "Clone source '$source' does not exist on the array\n" unless $source_id;

    my $id = $api->volume_clone($source_id, $target, %opts);

    $class->_await_volume($scfg, $target, %opts);

    return $id;
}

# A thin clone carries protection_data.source_id, which for a PVE linked clone
# is the id of a template marker snapshot. Mapping those ids back to the volume
# each one marks gives the clone's base without another query per volume.
sub _array_clone_parents {
    my ($class, $scfg, $storeid, $volumes, %opts) = @_;

    return {} unless ref($volumes) eq 'ARRAY' && @$volumes;
    return {} unless grep { $_->{source_id} } @$volumes;

    my $prefix = $class->naming->volume_prefix($storeid);
    my $snaps = eval {
        $class->_api($scfg, %opts)->snapshot_list(prefix => $prefix, %opts);
    } // [];

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

# ---------------------------------------------------------------------------
# Hosts and mappings
# ---------------------------------------------------------------------------

# Initiators of this node, in the shape PowerStore's host object wants.
sub _initiator_records {
    my ($class, $scfg) = @_;

    if ($class->_is_fc($scfg)) {
        my $wwpns = get_fc_wwpns_raw(online_only => 1);
        die "No online FC HBA ports found on this node.\n" unless @$wwpns;
        return [ map { { port_name => $_, port_type => 'FC' } } @$wwpns ];
    }

    return [ { port_name => get_initiator_name(), port_type => 'iSCSI' } ];
}

sub _array_ensure_host {
    my ($class, $scfg, $storeid, %opts) = @_;

    my $api  = $class->_api($scfg, %opts);
    my $name = $class->_host_name($scfg);
    my $want = $class->_initiator_records($scfg);

    my $host = eval { $api->host_get_by_name($name, %opts) };

    unless ($host) {
        my $id = eval { $api->host_create($name, $want, %opts) };
        if ($@) {
            my $err = $@;
            die "Failed to create host '$name' on the array: this node's"
              . " initiator is already registered to a different host. Remove"
              . " the conflicting host in PowerStore Manager, or point this"
              . " storage at the existing host by setting"
              . " 'dell-cluster-name' to match it.\n  Array error: $err"
                if $err =~ /already|conflict|in use/i;
            die "Failed to create host '$name' on the array: $err";
        }
        return $name;
    }

    # The host exists: make sure this node's initiators are on it. A node that
    # was reinstalled, or that gained an HBA port, otherwise silently sees
    # nothing.
    my %present;
    for my $initiator (@{ $host->{host_initiators} // [] }) {
        my $port = $initiator->{port_name} // next;
        $present{lc($port)} = 1;
    }

    my @missing = grep { !$present{ lc($_->{port_name}) } } @$want;
    return $name unless @missing;

    eval { $api->host_add_initiators($host->{id}, \@missing, %opts) };
    if ($@) {
        my $err = $@;
        my $names = join(', ', map { $_->{port_name} } @missing);
        die "Failed to add this node's initiator(s) to host '$name': $names."
          . " They are most likely registered to another host object on the"
          . " array; remove that registration in PowerStore Manager.\n"
          . "  Array error: $err";
    }

    return $name;
}

sub _array_list_hosts {
    my ($class, $scfg, $prefix, %opts) = @_;

    my $hosts = $class->_api($scfg, %opts)->host_list($prefix, %opts) // [];

    return [ map { { name => $_->{name}, id => $_->{id} } }
             grep { $_->{name} } @$hosts ];
}

sub _array_map_to_host {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $volume_id = $class->_require_volume_id($scfg, $name, %opts);
    my $host_id   = $class->_host_id($scfg, $host_name, %opts);
    die "Host '$host_name' is not registered on the array\n" unless $host_id;

    return $api->volume_attach($volume_id,
        host_id  => $host_id,
        lun_base => $scfg->{'pstore-lun-id-base'} // 1,
        %opts,
    );
}

sub _array_unmap_from_host {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $volume_id = $class->_volume_id($scfg, $name, %opts);
    return 1 unless $volume_id;

    my $host_id = $class->_host_id($scfg, $host_name, %opts);
    return 1 unless $host_id;

    return 1 unless $api->is_mapped($volume_id, $host_id, %opts);

    return $api->volume_detach($volume_id, host_id => $host_id, %opts);
}

sub _array_is_mapped {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $volume_id = $class->_volume_id($scfg, $name, %opts) or return 0;
    my $host_id   = $class->_host_id($scfg, $host_name, %opts) or return 0;

    return $class->_api($scfg, %opts)->is_mapped($volume_id, $host_id, %opts);
}

sub _array_mapped_hosts {
    my ($class, $scfg, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $volume_id = $class->_volume_id($scfg, $name, %opts) or return [];
    my $mappings = $api->mapping_list(volume_id => $volume_id, %opts) // [];
    return [] unless @$mappings;

    # One host listing, then a lookup: a per-mapping host query would be N
    # round trips on a path that runs during every delete.
    my $hosts = eval { $api->host_list(undef, %opts) } // [];
    my %name_of = map { $_->{id} => $_->{name} } grep { $_->{id} } @$hosts;

    my %seen;
    my @names;
    for my $mapping (@$mappings) {
        my $host_name = $name_of{ $mapping->{host_id} // '' } // next;
        push @names, $host_name unless $seen{$host_name}++;
    }

    return \@names;
}

sub _array_get_portals {
    my ($class, $scfg, %opts) = @_;
    return $class->_api($scfg, %opts)->iscsi_portals(%opts);
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellPowerStorePlugin - Dell PowerStore storage plugin
for Proxmox VE

=head1 SYNOPSIS

In /etc/pve/storage.cfg:

    dellpowerstore: ps1
        dell-portal 192.168.1.50
        dell-username pveadmin
        dell-password SecurePassword
        dell-protocol iscsi
        pstore-volume-group pve-vg
        content images,rootdir
        shared 1

or:

    pvesm add dellpowerstore ps1 \
        --dell-portal 192.168.1.50 \
        --dell-username pveadmin \
        --dell-password 'SecurePassword' \
        --content images,rootdir \
        --shared 1

=head1 DESCRIPTION

One VM disk is one PowerStore volume, so the array's snapshots, thin clones,
compression and replication all act on a single VM disk as their natural unit.

The host-side work — iSCSI and FC login, device discovery, dm-multipath,
orphan reaping — is implemented once in
L<PVE::Storage::Custom::DellEMC::Common::BlockBase>. This module only
translates between PVE's names and PowerStore's REST objects.

=head1 STATUS

Not yet verified against physical hardware. The REST paths and field names,
the SCSI vendor and product strings, and the WWN to WWID conversion are all
still marked unverified in docs/TESTING.md.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
