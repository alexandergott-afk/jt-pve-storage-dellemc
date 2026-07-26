# Dell PowerVault ME storage plugin for Proxmox VE
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellPowerVaultPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::BlockBase);

use PVE::Storage::Custom::DellEMC::PowerVault::API;
use PVE::Storage::Custom::DellEMC::PowerVault::Naming;
use PVE::Storage::Custom::DellEMC::Common::FC qw(get_fc_wwpns_raw);
use PVE::Storage::Custom::DellEMC::Common::ISCSI qw(get_initiator_name);

# PowerVault ME4 and ME5. The host-side work is BlockBase's; this module
# translates between PVE's names and the array's CLI-over-HTTPS interface.
#
# Three things differ from PowerStore and shape the code below:
#
#   1. Objects are addressed by name, not by id, so there is no lookup step.
#   2. A snapshot is a first-class volume that can be mapped and written to.
#      A PVE linked clone is therefore a snapshot given a volume-shaped name,
#      with no copy involved.
#   3. Names are limited to 32 bytes and may not contain a dot, which is why
#      this family has its own Naming subclass.

push @PVE::Storage::Plugin::SHARED_STORAGE, 'dellpowervault';

sub type { 'dellpowervault' }

sub naming { 'PVE::Storage::Custom::DellEMC::PowerVault::Naming' }

# NOT YET VERIFIED against hardware. The product string is a regular
# expression on purpose: the family covers ME4012/ME4024/ME4084 and
# ME5012/ME5024/ME5084, which report different product strings. Confirm with
#   sg_inq /dev/sdX
# and narrow it before relying on it — this gate decides which devices the
# plugin will ever touch.
sub multipath_vendor  { 'DellEMC' }
sub multipath_product { 'ME[45][0-9]*' }

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

# Not offered on this family. An ME array allows on the order of a thousand
# volumes and snapshots in total, and every snapshot of a VM would spend a
# second object on a copy of its configuration — on a busy cluster that is
# the difference between running out of volumes and not. Check the Support
# Matrix for the exact limits of your model.
#
# The configuration can still be recovered the ordinary way: from a PVE
# backup, or from /etc/pve on another node of the cluster.
sub supports_config_backup { return 0 }

sub capacity_scope {
    my ($class, $scfg) = @_;
    return defined $scfg->{'pvault-pool'} ? 'pool' : 'array';
}

sub identity_suffix {
    my ($class, $scfg) = @_;
    return $scfg->{'pvault-pool'} // '';
}

# The vendor gate must also accept an array whose inquiry string is the older
# 'DELL EMC' spelling.
sub _vendor_re { qr/DellEMC|DELL\s*EMC/i }

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

sub family_properties {
    return {
        'pvault-pool' => {
            description => "Pool that new volumes are created in. Required on"
                . " an array with more than one pool; with a single pool the"
                . " array chooses it.",
            type => 'string',
            optional => 1,
        },
        'pvault-volume-group' => {
            description => "Place every volume of this storage in the named"
                . " volume group. The group must already exist on the array.",
            type => 'string',
            optional => 1,
        },
        'pvault-tier-affinity' => {
            description => "Tier affinity for new volumes on an array with"
                . " tiered storage.",
            type => 'string',
            enum => ['no-affinity', 'archive', 'performance'],
            default => 'no-affinity',
            optional => 1,
        },
        'pvault-lun-id-base' => {
            description => "Lowest LUN id this plugin assigns when mapping a"
                . " volume. The array requires a LUN whenever an initiator is"
                . " named, so the plugin picks the lowest free one rather than"
                . " letting the numbering drift upward over time.",
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
        'pvault-pool'          => { optional => 1 },
        'pvault-volume-group'  => { optional => 1 },
        'pvault-tier-affinity' => { optional => 1 },
        'pvault-lun-id-base'   => { optional => 1 },
    };
}

# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------

my %API_CACHE;
use constant API_CACHE_TTL => 300;

# How long to wait for an object the array has accepted but does not yet
# report. A successful create is not a promise that the next query can see it:
# an array's management database can lag its own write path, and every caller
# here maps or looks up the object immediately afterwards.
use constant AWAIT_OBJECT_TIMEOUT => 30;

sub _api {
    my ($class, $scfg, %opts) = @_;

    my $health = $opts{status} ? 1 : 0;

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

    my $api = PVE::Storage::Custom::DellEMC::PowerVault::API->new(%args);

    $API_CACHE{$key} = { api => $api, created => time(), pid => $$ };

    return $api;
}

# A row from `show volumes` in the shape BlockBase expects.
sub _volume_row {
    my ($class, $api, $row) = @_;

    return undef unless ref($row) eq 'HASH';

    my $name = $row->{'volume-name'} // $row->{name};
    return undef unless defined $name && length $name;

    return {
        name  => $name,
        size  => $api->volume_size($row),
        used  => $api->volume_used($row),
        wwid  => $api->volume_wwid($row),
        type  => $row->{'volume-type'} // $row->{type},
        ctime => $class->_to_epoch($row->{'creation-date-time-numeric'}
                                // $row->{'create-timestamp-numeric'}),
    };
}

# The CLI reports timestamps twice; the '-numeric' variant is epoch seconds.
sub _to_epoch {
    my ($class, $value) = @_;

    return 0 unless defined $value;
    return $value + 0 if $value =~ /^\d+$/;

    return 0;
}

# ---------------------------------------------------------------------------
# Array operations
# ---------------------------------------------------------------------------

sub _array_ping {
    my ($class, $scfg, %opts) = @_;

    my $system = $class->_api($scfg, %opts)->system_get(%opts);
    die "the array did not report a system object\n" unless $system;

    return 1;
}

sub _array_get_capacity {
    my ($class, $scfg, %opts) = @_;

    return $class->_api($scfg, %opts)->get_managed_capacity(
        pool => $scfg->{'pvault-pool'}, %opts);
}

sub _array_get_volume {
    my ($class, $scfg, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $row = $api->volume_get_by_name($name, %opts) or return undef;

    return $class->_volume_row($api, $row);
}

sub _array_list_volumes {
    my ($class, $scfg, $storeid, $prefix, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    # `pattern` takes shell-style wildcards and filters on the array.
    my $pattern = (defined $prefix && length $prefix) ? "${prefix}*" : undef;
    my $rows = $api->volume_list($pattern, %opts) // [];

    my @out;
    for my $row (@$rows) {
        my $volume = $class->_volume_row($api, $row) or next;

        # The array's pattern match is not case-sensitive and the ownership
        # boundary must be exact.
        next if defined $prefix && index($volume->{name}, $prefix) != 0;

        # Snapshots share the namespace. A snapshot with a volume-shaped name
        # is a linked clone and belongs in the list; one with a '-s-' or
        # '-base' tail does not.
        next if $class->naming->decode_snapshot_name($volume->{name});

        push @out, $volume;
    }

    return \@out;
}

sub _array_create_volume {
    my ($class, $scfg, $storeid, $name, $size, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my %args;
    $args{pool} = $scfg->{'pvault-pool'}
        if defined $scfg->{'pvault-pool'} && length $scfg->{'pvault-pool'};
    $args{volume_group} = $scfg->{'pvault-volume-group'}
        if defined $scfg->{'pvault-volume-group'} && length $scfg->{'pvault-volume-group'};
    $args{tier_affinity} = $scfg->{'pvault-tier-affinity'}
        if defined $scfg->{'pvault-tier-affinity'}
        && $scfg->{'pvault-tier-affinity'} ne 'no-affinity';

    $api->volume_create($name, $size, %args, %opts);

    # Every caller maps or queries the volume straight after this returns.
    $class->_await_volume($scfg, $name, %opts);

    return $name;
}

# Wait for a named object to become visible. Returns 1 as soon as it is;
# dies naming the object if it never appears.
sub _await_volume {
    my ($class, $scfg, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    my $deadline = time() + AWAIT_OBJECT_TIMEOUT;

    while (1) {
        return 1 if eval { $api->volume_get_by_name($name, %opts) };
        last if time() >= $deadline;
        sleep(1);
    }

    die "The array accepted the request but '$name' was still not listed after "
      . AWAIT_OBJECT_TIMEOUT . "s. Check in PowerVault Manager whether it"
      . " exists before retrying.\n";
}

sub _array_delete_volume {
    my ($class, $scfg, $storeid, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    # Deletion is idempotent: PVE retries, and a volume that is already gone
    # must not turn into an error.
    return 1 unless $api->volume_get_by_name($name, %opts);

    return $api->volume_delete($name, %opts);
}

sub _array_resize_volume {
    my ($class, $scfg, $storeid, $name, $size, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $row = $api->volume_get_by_name($name, %opts)
        or die "Volume '$name' does not exist on the array\n";

    return $api->volume_expand($name, $size,
        current_size => $api->volume_size($row), %opts);
}

sub _array_rename_volume {
    my ($class, $scfg, $storeid, $from, $to, %opts) = @_;

    return $class->_api($scfg, %opts)->volume_rename($from, $to, %opts);
}

sub _array_get_wwid {
    my ($class, $scfg, $name, %opts) = @_;

    my $volume = $class->_array_get_volume($scfg, $name, %opts);

    return $volume ? $volume->{wwid} : undef;
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

sub _array_snapshot_create {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    return $class->_api($scfg, %opts)->snapshot_create($volume, $snapshot, %opts);
}

sub _array_snapshot_get {
    my ($class, $scfg, $storeid, $snapshot, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    # A snapshot is a volume object, so the exact-name lookup finds it.
    my $row = $api->volume_get_by_name($snapshot, %opts) or return undef;

    return $class->_volume_row($api, $row);
}

sub _array_snapshot_delete {
    my ($class, $scfg, $storeid, $snapshot, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    return 1 unless $api->volume_get_by_name($snapshot, %opts);

    return $api->snapshot_delete($snapshot, %opts);
}

sub _array_snapshot_list {
    my ($class, $scfg, $storeid, $volume, $prefix, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my %query;
    $query{volume}  = $volume if defined $volume && length $volume;
    $query{pattern} = "${prefix}*" if defined $prefix && length $prefix;

    my $rows = eval { $api->snapshot_list(%query, %opts) } // [];

    my @out;
    for my $row (@$rows) {
        my $snapshot = $class->_volume_row($api, $row) or next;

        # Only names this plugin produced, and only when the request was
        # scoped to one volume or one prefix.
        if (defined $volume && length $volume) {
            my $decoded = $class->naming->decode_snapshot_name($snapshot->{name});
            next unless $decoded && $decoded->{volume} eq $volume;
        }

        push @out, $snapshot;
    }

    return \@out;
}

sub _array_snapshot_rollback {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    return $class->_api($scfg, %opts)->snapshot_rollback($volume, $snapshot, %opts);
}

# A clone here is a snapshot given a volume-shaped name. ME snapshots are
# writable and mappable, so this is the array's thin clone: no data is copied
# and the operation is instant.
sub _array_clone {
    my ($class, $scfg, $storeid, $source, $target, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    die "Clone source '$source' does not exist on the array\n"
        unless $api->volume_get_by_name($source, %opts);

    $api->snapshot_create($source, $target, %opts);

    # The caller maps it immediately; a snapshot the array has not published
    # yet would fail that map and take the clone down with it.
    $class->_await_volume($scfg, $target, %opts);

    return $target;
}

# ---------------------------------------------------------------------------
# Hosts and mappings
# ---------------------------------------------------------------------------

sub _initiator_ids {
    my ($class, $scfg) = @_;

    if ($class->_is_fc($scfg)) {
        my $wwpns = get_fc_wwpns_raw(online_only => 1);
        die "No online FC HBA ports found on this node.\n" unless @$wwpns;
        return $wwpns;
    }

    return [ get_initiator_name() ];
}

sub _array_ensure_host {
    my ($class, $scfg, $storeid, %opts) = @_;

    my $api  = $class->_api($scfg, %opts);
    my $name = $class->_host_name($scfg);
    my $want = $class->_initiator_ids($scfg);

    my $host = eval { $api->host_get_by_name($name, %opts) };

    unless ($host) {
        eval { $api->host_create($name, $want, %opts) };
        if ($@) {
            my $err = $@;
            die "Failed to create host '$name' on the array. This node's"
              . " initiator is most likely already attached to a different"
              . " host object; remove that one in PowerVault Manager, or set"
              . " 'dell-cluster-name' so the generated host name matches the"
              . " existing one.\n  Array error: $err"
                if $err =~ /already|exists|in use|duplicate/i;
            die "Failed to create host '$name' on the array: $err\n";
        }
        return $name;
    }

    # The host exists. A reinstalled node, or one that gained an HBA port,
    # has initiators the host object does not know about yet and would
    # otherwise see nothing at all.
    my $known = lc(join(',',
        $host->{'initiator-id'} // '',
        $host->{'member-id'}    // '',
        $host->{id}             // '',
    ));

    my @missing = grep { index($known, lc($_)) < 0 } @$want;
    return $name unless @missing;

    eval { $api->host_add_initiators($name, \@missing, %opts) };
    if ($@) {
        my $err = $@;
        die "Failed to attach this node's initiator(s) to host '$name': "
          . join(', ', @missing) . ". They are most likely attached to another"
          . " host on the array.\n  Array error: $err";
    }

    return $name;
}

sub _array_list_hosts {
    my ($class, $scfg, $prefix, %opts) = @_;

    my $hosts = eval { $class->_api($scfg, %opts)->host_list(%opts) } // [];

    my @out;
    for my $host (@$hosts) {
        my $name = $host->{name} // $host->{'host-name'} // next;
        next if defined $prefix && length $prefix && index($name, $prefix) != 0;
        push @out, { name => $name };
    }

    return \@out;
}

sub _array_map_to_host {
    my ($class, $scfg, $name, $host, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    return 1 if $api->is_mapped($name, $host, %opts);

    return $api->volume_map($name, $host,
        lun_base => $scfg->{'pvault-lun-id-base'} // 1, %opts);
}

sub _array_unmap_from_host {
    my ($class, $scfg, $name, $host, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    return 1 unless $api->volume_get_by_name($name, %opts);
    return 1 unless $api->is_mapped($name, $host, %opts);

    return $api->volume_unmap($name, $host, %opts);
}

sub _array_is_mapped {
    my ($class, $scfg, $name, $host, %opts) = @_;

    return $class->_api($scfg, %opts)->is_mapped($name, $host, %opts);
}

sub _array_mapped_hosts {
    my ($class, $scfg, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);
    return [] unless $api->volume_get_by_name($name, %opts);

    my %seen;
    my @hosts;
    for my $mapping (@{ $api->volume_mappings($name, %opts) }) {
        my $host = $mapping->{host} // next;
        push @hosts, $host unless $seen{$host}++;
    }

    return \@hosts;
}

sub _array_get_portals {
    my ($class, $scfg, %opts) = @_;

    return $class->_api($scfg, %opts)->iscsi_portals(%opts);
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellPowerVaultPlugin - Dell PowerVault ME storage plugin
for Proxmox VE

=head1 SYNOPSIS

    pvesm add dellpowervault me5 \
        --dell-portal 192.168.1.60 \
        --dell-username manage \
        --dell-password 'SecurePassword' \
        --dell-protocol iscsi \
        --pvault-pool A \
        --content images,rootdir \
        --shared 1

=head1 DESCRIPTION

Covers the PowerVault ME4 and ME5 series, which share one CLI-over-HTTPS
interface.

A linked clone on this family is a snapshot with a volume-shaped name: ME
snapshots are writable and mappable, so no data is copied.

Names are the binding constraint. The array accepts 32 bytes and no dot, so
the storage id has a small budget and a name that would not fit raises an
error rather than being truncated into a collision.

=head1 STATUS

Not verified against hardware. The login flow and the C<create volume>,
C<expand volume>, C<map volume>, C<show volumes> and C<create snapshots>
grammars come from the Dell PowerVault ME5 Series CLI Reference Guide;
everything marked C<NOT VERIFIED> in the API module still needs checking. See
docs/TESTING.md.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
