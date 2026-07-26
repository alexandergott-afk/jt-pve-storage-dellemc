# Dell PowerFlex storage plugin for Proxmox VE
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellPowerFlexPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use PVE::Tools;
use PVE::INotify;

use PVE::Storage::Custom::DellEMC::Common::Schema;
use PVE::Storage::Custom::DellEMC::Common::Health;
use PVE::Storage::Custom::DellEMC::PowerFlex::API;
use PVE::Storage::Custom::DellEMC::PowerFlex::Naming;
use PVE::Storage::Custom::DellEMC::PowerFlex::Host qw(
    sdc_available sdc_guid sdc_device_for_volume
    nvme_available nvme_host_nqn nvme_connect nvme_device_for_volume
    nvme_multipath_enabled nvme_paths
    wait_for_device
);

# PowerFlex does not inherit Common::BlockBase, and the reason is the data
# path rather than tidiness: there is no SAN login, no SCSI LUN and no
# dm-multipath here. Volumes arrive either through Dell's SDC kernel module
# or, on PowerFlex 4.x, through the in-kernel NVMe/TCP initiator talking to
# an SDT. Everything BlockBase does for devices would be wrong.
#
# What is shared: the storage.cfg schema (Common::Schema), the REST
# transport, the naming rules and the health reporting.

use constant APIVERSION => 13;

push @PVE::Storage::Plugin::SHARED_STORAGE, 'dellpowerflex';

my $SCHEMA = 'PVE::Storage::Custom::DellEMC::Common::Schema';
my $HEALTH = 'PVE::Storage::Custom::DellEMC::Common::Health';
my $NAMING = 'PVE::Storage::Custom::DellEMC::PowerFlex::Naming';
my $HOST   = 'PVE::Storage::Custom::DellEMC::PowerFlex::Host';

sub api { return APIVERSION }
sub type { return 'dellpowerflex' }

sub plugindata {
    return {
        content => [ { images => 1, rootdir => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
    };
}

sub properties {
    my ($class) = @_;
    return $SCHEMA->properties($class, family_properties());
}

sub options {
    my ($class) = @_;
    return $SCHEMA->options(family_options());
}

sub family_properties {
    return {
        'pflex-storage-pool' => {
            description => "Storage pool that volumes are created in."
                . " Required: PowerFlex has no default pool.",
            type => 'string',
        },
        'pflex-protection-domain' => {
            description => "Protection domain of the storage pool. Only needed"
                . " when the same pool name exists in more than one domain.",
            type => 'string',
            optional => 1,
        },
        'pflex-nvme-ctrl-loss-tmo' => {
            description => "Seconds the kernel keeps retrying a lost NVMe"
                . " controller before it fails the I/O. This is the NVMe"
                . " equivalent of no_path_retry on the SAN families: the"
                . " kernel default of 600 is long enough to be"
                . " indistinguishable from a hang. Raise it only if brief"
                . " total path loss is expected and queuing is preferable to"
                . " an I/O error.",
            type => 'integer',
            minimum => 0,
            maximum => 600,
            default => 60,
            optional => 1,
        },
        'pflex-nvme-io-queues' => {
            description => "Number of NVMe/TCP I/O queues per controller."
                . " Leave unset to let the kernel decide, which is normally"
                . " one queue per CPU.",
            type => 'integer',
            minimum => 1,
            maximum => 128,
            optional => 1,
        },
        'pflex-thick' => {
            description => "Create thick-provisioned volumes. Thin is the"
                . " default and is what makes snapshots and clones cheap.",
            type => 'boolean',
            default => 0,
            optional => 1,
        },
    };
}

sub family_options {
    return {
        'pflex-storage-pool'      => {},
        'pflex-protection-domain' => { optional => 1 },
        'pflex-nvme-ctrl-loss-tmo' => { optional => 1 },
        'pflex-nvme-io-queues'     => { optional => 1 },
        'pflex-thick'             => { optional => 1 },
    };
}

sub sensitive_properties {
    my ($class) = @_;
    return ('dell-password', $class->SUPER::sensitive_properties());
}

sub get_identity {
    my ($class, $scfg, $storeid) = @_;

    return join(':', 'dellpowerflex',
        $scfg->{'dell-portal'} // '',
        $scfg->{'pflex-storage-pool'} // '');
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

sub _opt {
    my ($class, $scfg, $name, $default) = @_;
    my $value = $scfg->{"dell-$name"};
    return defined $value ? $value : $default;
}

sub _device_timeout { $_[0]->_opt($_[1], 'device-timeout', 60) }
sub _status_timeout { $_[0]->_opt($_[1], 'status-timeout', 5) }
sub _cluster_name   { $_[0]->_opt($_[1], 'cluster-name', 'pve') }

# 'sdc' or 'nvme'. NVMe/TCP is the default because it needs nothing
# proprietary on the host: the SDC is a Dell kernel module that must match
# the running kernel, and Proxmox VE kernels are not on Dell's support
# matrix. See docs/POWERFLEX_SDC.md.
sub _access_mode {
    my ($class, $scfg) = @_;

    my $protocol = $scfg->{'dell-protocol'} // 'nvme';

    return 'sdc' if $protocol eq 'sdc';
    return 'nvme' if $protocol eq 'nvme';

    die "Storage type dellpowerflex speaks 'sdc' or 'nvme'; 'dell-protocol"
      . " $protocol' belongs to the SAN families.\n";
}

sub _is_sdc { my ($class, $scfg) = @_; return $class->_access_mode($scfg) eq 'sdc' }

# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------

my %API_CACHE;
use constant API_CACHE_TTL => 300;

sub _api {
    my ($class, $scfg, %opts) = @_;

    my $health = $opts{status} ? 1 : 0;

    my $key = join("\0",
        $scfg->{'dell-portal'} // '',
        $scfg->{'dell-username'} // '',
        $scfg->{'dell-ssl-verify'} // 0,
        $health,
    );

    if (my $cached = $API_CACHE{$key}) {
        if ((time() - $cached->{created}) < API_CACHE_TTL && $cached->{pid} == $$) {
            return $cached->{api};
        }
    }

    my %args = (
        portal     => $scfg->{'dell-portal'},
        username   => $scfg->{'dell-username'},
        password   => $scfg->{'dell-password'},
        ssl_verify => $scfg->{'dell-ssl-verify'} // 0,
        type       => 'dellpowerflex',
        storeid    => $opts{storeid},
    );

    if ($health) {
        $args{timeout} = $class->_status_timeout($scfg);
        $args{retries} = 1;
    }

    my $api = PVE::Storage::Custom::DellEMC::PowerFlex::API->new(%args);

    $API_CACHE{$key} = { api => $api, created => time(), pid => $$ };

    return $api;
}

# The storage pool this storage writes to, resolved once per call.
sub _storage_pool {
    my ($class, $scfg, %opts) = @_;

    my $name = $scfg->{'pflex-storage-pool'}
        or die "This storage has no pflex-storage-pool configured.\n";

    my $pool = $class->_api($scfg, %opts)->storage_pool_by_name(
        $name, $scfg->{'pflex-protection-domain'}, %opts);

    die "Storage pool '$name' does not exist on the array"
      . ($scfg->{'pflex-protection-domain'}
         ? " in protection domain '$scfg->{'pflex-protection-domain'}'" : '')
      . ".\n" unless $pool;

    return $pool;
}

# ---------------------------------------------------------------------------
# Volume names
# ---------------------------------------------------------------------------

sub _parse_volname {
    my ($class, $volname) = @_;

    return undef unless defined $volname;
    $volname =~ s|^images/||;

    if ($volname =~ m|^(base-(\d+)-disk-(\d+))/vm-(\d+)-disk-(\d+)$|) {
        return { vmid => $4, diskid => $5, type => 'disk', isBase => 0,
                 basename => $1, basevmid => $2 };
    }
    if ($volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        return { vmid => $1, diskid => $2, type => 'disk', isBase => 0 };
    }
    if ($volname =~ /^base-(\d+)-disk-(\d+)$/) {
        return { vmid => $1, diskid => $2, type => 'disk', isBase => 1 };
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-cloudinit$/) {
        return { vmid => $1, type => 'cloudinit', isBase => 0 };
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-state-(.+)$/) {
        return { vmid => $1, snapname => $2, type => 'state', isBase => 0 };
    }

    return undef;
}

sub parse_volname {
    my ($class, $volname) = @_;

    my $parsed = $class->_parse_volname($volname);
    die "unable to parse volume name '$volname'\n" unless $parsed;

    return ('images', $volname, $parsed->{vmid}, $parsed->{basename},
        $parsed->{basevmid}, $parsed->{isBase} ? 1 : 0, 'raw');
}

sub _array_name {
    my ($class, $storeid, $volname) = @_;
    return $NAMING->pve_volname_to_array($storeid, $volname);
}

sub _find_free_diskid {
    my ($class, $scfg, $storeid, $vmid) = @_;

    my $prefix = $NAMING->volume_prefix($storeid) . "${vmid}-";
    my $volumes = eval { $class->_list_own_volumes($scfg, $storeid, $prefix) } // [];

    my %used;
    for my $volume (@$volumes) {
        my $decoded = $NAMING->decode_volume_name($volume->{name}) or next;
        next unless $decoded->{type} eq 'disk' && defined $decoded->{diskid};
        next unless $decoded->{vmid} == $vmid;
        $used{$decoded->{diskid}} = 1;
    }

    for my $id (0 .. 999) {
        return $id unless $used{$id};
    }

    die "No free disk id for VM $vmid on storage '$storeid'\n";
}

sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;

    return "vm-${vmid}-disk-" . $class->_find_free_diskid($scfg, $storeid, $vmid);
}

# PowerFlex has no server-side name filter, only an exact-name lookup, so a
# prefix listing pulls the volume list and filters here. The result is cached
# for a few seconds because status() and list_images() often run back to back.
my %LIST_CACHE;
use constant LIST_CACHE_TTL => 5;

sub _list_own_volumes {
    my ($class, $scfg, $storeid, $prefix, %opts) = @_;

    $prefix //= $NAMING->volume_prefix($storeid);

    my $key = ($scfg->{'dell-portal'} // '') . "\0$storeid";
    my $cached = $LIST_CACHE{$key};

    my $rows;
    if ($cached && (time() - $cached->{time}) < LIST_CACHE_TTL && $cached->{pid} == $$) {
        $rows = $cached->{rows};
    } else {
        $rows = $class->_api($scfg, %opts)->volume_list(%opts) // [];
        $LIST_CACHE{$key} = { rows => $rows, time => time(), pid => $$ };
    }

    my @out;
    for my $row (@$rows) {
        my $name = $row->{name} // next;
        next unless index($name, $prefix) == 0;

        push @out, {
            id   => $row->{id},
            name => $name,
            size => $class->_api($scfg, %opts)->volume_size($row),
            used => 0,
            row  => $row,
        };
    }

    return \@out;
}

sub _invalidate_list_cache {
    my ($class, $scfg, $storeid) = @_;
    delete $LIST_CACHE{($scfg->{'dell-portal'} // '') . "\0$storeid"};
    return;
}

# ---------------------------------------------------------------------------
# Host registration
# ---------------------------------------------------------------------------

# The id the array knows this node by, in whichever access mode is in use.
sub _host_id {
    my ($class, $scfg, $storeid, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    if ($class->_is_sdc($scfg)) {
        my $guid = sdc_guid();
        die "Could not read this node's SDC GUID. "
          . $HOST->sdc_status_message() . "\n" unless $guid;

        my $sdc = $api->sdc_find(guid => $guid, %opts);
        die "This node's SDC (GUID $guid) is not registered on the array."
          . " Register it in PowerFlex Manager, or check that the SDC is"
          . " connected to the MDM.\n" unless $sdc;

        my $state = $sdc->{mdmConnectionState} // '';
        warn "This node's SDC reports MDM connection state '$state'.\n"
            if length $state && $state ne 'Connected';

        return $sdc->{id};
    }

    my $nqn = nvme_host_nqn()
        or die "Could not determine this node's NVMe host NQN. Install"
             . " nvme-cli and ensure /etc/nvme/hostnqn exists.\n";

    my $host = $api->nvme_host_find($nqn, %opts);
    return $host->{id} if $host;

    # Register this node so the array can map volumes to it.
    my $name = $NAMING->encode_host_name(
        $class->_cluster_name($scfg), PVE::INotify::nodename());

    my $id = eval { $api->nvme_host_create($name, $nqn, %opts) };
    die "This node is not registered as an NVMe host on the array and could"
      . " not be registered automatically (NQN $nqn). Add it in PowerFlex"
      . " Manager.\n  Array error: $@" if $@ || !$id;

    return $id;
}

# ---------------------------------------------------------------------------
# Storage lifecycle
# ---------------------------------------------------------------------------

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $mode = $class->_access_mode($scfg);

    # Check the host side first: a missing SDC module or nvme-cli is a much
    # more likely cause than the array being unreachable, and the message
    # should say so rather than blaming the network.
    if ($mode eq 'sdc') {
        die "Storage '$storeid' uses the SDC data path, but "
          . $HOST->sdc_status_message() . "\n" unless sdc_available();
    } else {
        die "Storage '$storeid' uses NVMe/TCP, but "
          . $HOST->nvme_status_message() . "\n" unless nvme_available();
    }

    my $api = $class->_api($scfg, status => 1, storeid => $storeid);

    eval { $api->system_id(status => 1) };
    die "Cannot reach the PowerFlex API at " . ($scfg->{'dell-portal'} // '?')
      . " for storage '$storeid': $@" if $@;

    # Fail early if the configured pool is not there; every later operation
    # would fail with something less obvious.
    $class->_storage_pool($scfg, status => 1, storeid => $storeid);

    # NVMe/TCP needs a session to each SDT before any namespace can appear.
    if ($mode eq 'nvme') {
        # Without native multipathing each path shows up as its own block
        # device, and two of them can be written through at once.
        my $mp_warning = $HOST->nvme_multipath_message();
        warn "Storage '$storeid': $mp_warning\n" if $mp_warning;

        my $targets = eval { $api->nvme_targets(status => 1) } // [];
        unless (@$targets) {
            die "The array published no NVMe/TCP targets (SDT). PowerFlex 4.0"
              . " or later is required for NVMe/TCP; on an older system use"
              . " 'dell-protocol sdc'.\n";
        }

        my %connect_opts = (
            ctrl_loss_tmo => $scfg->{'pflex-nvme-ctrl-loss-tmo'} // 60,
        );
        $connect_opts{io_queues} = $scfg->{'pflex-nvme-io-queues'}
            if $scfg->{'pflex-nvme-io-queues'};

        my $connected = 0;
        my @failed;
        for my $target (@$targets) {
            if (nvme_connect($target, %connect_opts)) {
                $connected++;
            } else {
                push @failed, "$target->{ip}:" . ($target->{port} // 4420);
            }
        }

        die "Could not connect to any of the " . scalar(@$targets)
          . " NVMe/TCP target(s) the array published. Check network"
          . " reachability to the SDT addresses: " . join(', ', @failed)
          . "\n" unless $connected;

        # One path is not multipathing. Say so, because the array published
        # more targets than this node could reach.
        warn "Storage '$storeid' connected to $connected of "
           . scalar(@$targets) . " NVMe/TCP targets; could not reach: "
           . join(', ', @failed) . ". The volumes will work but with reduced"
           . " path redundancy.\n" if @failed;
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Deliberately does not disconnect NVMe sessions or unmap volumes: other
    # storages may share the same subsystem, and unmapping would break a
    # migration that is still in flight.
    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my ($total, $used, $available);

    eval {
        ($total, $used, $available) = $class->_api($scfg, status => 1,
            storeid => $storeid)->get_managed_capacity(
                pool   => $scfg->{'pflex-storage-pool'},
                domain => $scfg->{'pflex-protection-domain'},
                status => 1);
    };
    if ($@) {
        $HEALTH->record_status_failure($storeid, $@);
        return (0, 0, 0, 0);
    }

    $HEALTH->record_status_ok($storeid, $total, $used, scope => 'storage pool');

    return ($total, $available, $used, 1);
}

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt' - this storage only holds raw volumes\n"
        if defined $fmt && $fmt ne 'raw';

    my $api = $class->_api($scfg, storeid => $storeid);
    my $pool = $class->_storage_pool($scfg, storeid => $storeid);

    my ($array_name, $pve_volname);
    if ($name && $name =~ /^vm-\d+-(?:state-.+|cloudinit)$/) {
        $array_name  = $class->_array_name($storeid, $name);
        $pve_volname = $name;
    } else {
        my $diskid = $class->_find_free_diskid($scfg, $storeid, $vmid);
        $array_name  = $NAMING->encode_volume_name($storeid, $vmid, $diskid);
        $pve_volname = "vm-${vmid}-disk-${diskid}";
    }

    die "Volume '$array_name' already exists on the array.\n"
        if $api->volume_id_by_name($array_name, storeid => $storeid);

    my $id = $api->volume_create($array_name, $size * 1024,
        storage_pool_id => $pool->{id},
        thick           => $scfg->{'pflex-thick'},
        storeid         => $storeid);

    die "The array did not return an id for the new volume '$array_name'.\n"
        unless $id;

    $class->_invalidate_list_cache($scfg, $storeid);

    # Map to this node now; PVE expects the device to be usable immediately
    # for state and cloud-init volumes, and mapping is idempotent anyway.
    my $host_id = eval { $class->_host_id($scfg, $storeid) };
    if ($@) {
        my $err = $@;
        eval { $api->volume_delete($id) };
        die "Volume created but this node could not be identified to the"
          . " array, so it was removed again: $err";
    }

    eval { $api->volume_map($id, $host_id, nvme => !$class->_is_sdc($scfg)) };
    if ($@) {
        my $err = $@;
        eval { $api->volume_delete($id) };
        $class->_invalidate_list_cache($scfg, $storeid);
        die "Failed to map the new volume to this node; it was removed"
          . " again: $err";
    }

    return $pve_volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);

    my $id = $api->volume_id_by_name($array_name, storeid => $storeid);
    unless ($id) {
        warn "Volume '$array_name' is not on the array; it may already have"
           . " been deleted\n";
        return undef;
    }

    # Unmap everywhere before deleting, for the same reason as the SAN
    # families: a volume deleted while still mapped leaves other nodes with a
    # device that answers nothing.
    my $volume = $api->volume_get($id, storeid => $storeid);
    for my $host_id (@{ $api->volume_mapped_hosts($volume, storeid => $storeid) }) {
        eval { $api->volume_unmap($id, $host_id, nvme => !$class->_is_sdc($scfg)) };
        warn "Failed to unmap '$array_name' from host $host_id: $@" if $@;
    }

    eval { $api->volume_delete($id, storeid => $storeid) };
    if ($@) {
        my $err = $@;
        die "Cannot delete volume '$volname': the array reports dependent"
          . " objects, which on PowerFlex means snapshots or clones made from"
          . " it. Delete those first.\n  Array error: $err"
            if $err =~ /descendant|snapshot|child|depend/i;
        die "Failed to delete volume '$array_name': $err";
    }

    $class->_invalidate_list_cache($scfg, $storeid);

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $prefix = $NAMING->volume_prefix($storeid);
    $prefix .= "${vmid}-" if $vmid;

    my $volumes = $class->_list_own_volumes($scfg, $storeid, $prefix);

    # Volumes that carry a template marker snapshot are base images.
    my %is_template;
    for my $volume (@{ $class->_list_own_volumes($scfg, $storeid,
        $NAMING->volume_prefix($storeid)) }) {
        my $decoded = $NAMING->decode_snapshot_name($volume->{name}) or next;
        $is_template{$decoded->{volume}} = 1 if $decoded->{is_base};
    }

    my @res;
    for my $volume (@$volumes) {
        my $decoded = $NAMING->decode_volume_name($volume->{name}) or next;
        next if $decoded->{type} eq 'vmconf';
        next if $NAMING->decode_snapshot_name($volume->{name});

        my $pve_volname;
        if ($decoded->{type} eq 'disk') {
            my $kind = $is_template{$volume->{name}} ? 'base' : 'vm';
            $pve_volname = "$kind-$decoded->{vmid}-disk-$decoded->{diskid}";
        } else {
            $pve_volname = $NAMING->array_to_pve_volname($volume->{name});
        }
        next unless $pve_volname;

        my $volid = "$storeid:$pve_volname";
        if ($vollist) {
            next unless grep { $volid =~ /^\Q$_\E/ } @$vollist;
        }

        push @res, {
            volid  => $volid,
            format => 'raw',
            size   => $volume->{size},
            used   => $volume->{used},
            vmid   => $decoded->{vmid},
        };
    }

    return \@res;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);

    my $volume = $api->volume_get_by_name($array_name, storeid => $storeid)
        or die "Volume '$array_name' not found on the array\n";

    my $size = $api->volume_size($volume);

    return wantarray ? ($size, 'raw', 0, undef) : $size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);

    my $volume = $api->volume_get_by_name($array_name, storeid => $storeid)
        or die "Volume '$array_name' not found on the array\n";

    my $current = $api->volume_size($volume);

    if ($size < $current) {
        die sprintf(
            "Cannot shrink volume '%s': current size %.2f GB, requested %.2f GB."
          . " PowerFlex does not support shrinking, and doing so would lose"
          . " data.\n", $volname, $current / (1024 ** 3), $size / (1024 ** 3));
    }
    return 1 if $size == $current;

    $api->volume_resize($volume->{id}, $size, storeid => $storeid);
    $class->_invalidate_list_cache($scfg, $storeid);

    # The host has to re-read the capacity. With NVMe the namespace change
    # notification usually handles it; a rescan makes it deterministic.
    $HOST->nvme_rescan() unless $class->_is_sdc($scfg);

    return 1;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);

    my $source = $class->_array_name($storeid, $source_volname);
    $target_volname //= $class->find_free_diskname($storeid, $scfg, $target_vmid, 'raw');
    my $target = $class->_array_name($storeid, $target_volname);

    my $id = $api->volume_id_by_name($source, storeid => $storeid)
        or die "Volume '$source' not found on the array\n";

    die "Volume '$target' already exists on the array\n"
        if $api->volume_id_by_name($target, storeid => $storeid);

    $api->volume_rename($id, $target, storeid => $storeid);
    $class->_invalidate_list_cache($scfg, $storeid);

    return "$storeid:$target_volname";
}

# ---------------------------------------------------------------------------
# Devices
# ---------------------------------------------------------------------------

sub _device_lookup {
    my ($class, $scfg, $volume_id) = @_;

    return $class->_is_sdc($scfg)
        ? sub { sdc_device_for_volume($volume_id) }
        : sub { nvme_device_for_volume($volume_id) };
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $parsed = $class->_parse_volname($volname);
    die "unable to parse volume name '$volname'\n" unless $parsed;

    my $array_name = $class->_array_name($storeid, $volname);
    $array_name = $NAMING->encode_snapshot_name($array_name, $snapname) if $snapname;

    my $id = eval {
        $class->_api($scfg, storeid => $storeid)
              ->volume_id_by_name($array_name, storeid => $storeid);
    };

    # path() is called in contexts where the array may be unreachable, and a
    # die here takes out more than this one volume.
    unless ($id) {
        my $placeholder = "/dev/disk/by-id/emc-vol-unknown-$array_name";
        return wantarray ? ($placeholder, $parsed->{vmid}, 'raw') : $placeholder;
    }

    my $device = $class->_device_lookup($scfg, $id)->()
        // "/dev/disk/by-id/emc-vol-unknown-$id";

    return wantarray ? ($device, $parsed->{vmid}, 'raw') : $device;
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "filesystem_path is not supported by dellpowerflex (volume"
      . " '$volname'): volume names are derived from the storage id, which is"
      . " not available here. Use PVE::Storage::path() instead.\n";
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);

    my $array_name = $class->_array_name($storeid, $volname);
    $array_name = $NAMING->encode_snapshot_name($array_name, $snapname) if $snapname;

    my $id = $api->volume_id_by_name($array_name, storeid => $storeid)
        or die "Cannot activate '$volname': '$array_name' is not on the array."
             . " It may have been deleted outside PVE.\n";

    my $host_id = $class->_host_id($scfg, $storeid);
    my $nvme = !$class->_is_sdc($scfg);

    unless ($api->is_mapped($id, $host_id, storeid => $storeid)) {
        eval { $api->volume_map($id, $host_id, nvme => $nvme, storeid => $storeid) };
        die "Failed to map volume '$array_name' to this node: $@" if $@;
    }

    my $timeout = $class->_device_timeout($scfg);
    my $device = wait_for_device($class->_device_lookup($scfg, $id),
        timeout => $timeout,
        rescan  => $nvme ? sub { $HOST->nvme_rescan() } : undef,
    );

    unless ($device) {
        my $how = $nvme ? "NVMe/TCP" : "the SDC";
        die "The device for volume '$volname' (array id $id) did not appear"
          . " within ${timeout}s over $how.\n"
          . ($nvme
             ? "  Check 'nvme list-subsys' for a session to the SDT, and that\n"
             . "  the array mapped the volume to this host's NQN.\n"
             : "  Check 'systemctl status scini' and\n"
             . "  '/bin/emc/scaleio/drv_cfg --query_vols'.\n")
          . "  Raise 'dell-device-timeout' if the device appears moments"
          . " later.\n";
    }

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    # Volumes stay mapped: unmapping here would break live migration, which
    # needs the volume present on the target before the source releases it.
    return 1;
}

# ---------------------------------------------------------------------------
# Snapshots, templates and clones
#
# A PowerFlex snapshot is a volume in its own right, so a linked clone is a
# snapshot given a volume-shaped name and costs nothing.
# ---------------------------------------------------------------------------

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);
    my $snap_name = $NAMING->encode_snapshot_name($array_name, $snap);

    my $id = $api->volume_id_by_name($array_name, storeid => $storeid)
        or die "Cannot snapshot '$volname': it is not on the array\n";

    die "Snapshot '$snap' already exists for volume '$volname'\n"
        if $api->volume_id_by_name($snap_name, storeid => $storeid);

    $api->snapshot_create($id, $snap_name, storeid => $storeid);
    $class->_invalidate_list_cache($scfg, $storeid);

    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);
    my $snap_name = $NAMING->encode_snapshot_name($array_name, $snap);

    my $id = $api->volume_id_by_name($snap_name, storeid => $storeid);
    unless ($id) {
        warn "Snapshot '$snap' of volume '$volname' is not on the array\n";
        return 1;
    }

    eval { $api->volume_delete($id, storeid => $storeid) };
    if ($@) {
        my $err = $@;
        die "Cannot delete snapshot '$snap': the array reports objects that"
          . " depend on it, which means clones were made from it. Delete"
          . " those first.\n  Array error: $err"
            if $err =~ /descendant|child|depend/i;
        die "Failed to delete snapshot '$snap' of volume '$volname': $err";
    }

    $class->_invalidate_list_cache($scfg, $storeid);

    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);
    my $snap_name = $NAMING->encode_snapshot_name($array_name, $snap);

    my $volume_id = $api->volume_id_by_name($array_name, storeid => $storeid)
        or die "Cannot roll back: volume '$array_name' is not on the array\n";
    my $snap_id = $api->volume_id_by_name($snap_name, storeid => $storeid)
        or die "Cannot roll back: snapshot '$snap' is not on the array\n";

    $api->snapshot_rollback($volume_id, $snap_id, storeid => $storeid);

    return 1;
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $array_name = $class->_array_name($storeid, $volname);
    my $volumes = $class->_list_own_volumes($scfg, $storeid,
        $NAMING->volume_prefix($storeid));

    my @res;
    for my $volume (@$volumes) {
        my $decoded = $NAMING->decode_snapshot_name($volume->{name}) or next;
        next if $decoded->{is_base};
        next unless $decoded->{volume} eq $array_name;

        push @res, { name => $decoded->{snapname}, ctime => 0 };
    }

    return \@res;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, undef, $vmid, undef, undef, $isBase) = $class->parse_volname($volname);

    die "create_base is not possible for content type '$vtype'\n" if $vtype ne 'images';
    die "volume '$volname' is already a base image\n" if $isBase;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);

    my $id = $api->volume_id_by_name($array_name, storeid => $storeid)
        or die "Cannot create a template from '$volname': it is not on the array\n";

    my $base = $NAMING->encode_base_snapshot_name($array_name);
    unless ($api->volume_id_by_name($base, storeid => $storeid)) {
        $api->snapshot_create($id, $base, storeid => $storeid);
    }

    $class->_invalidate_list_cache($scfg, $storeid);

    my $parsed = $class->_parse_volname($volname);

    return "base-$parsed->{vmid}-disk-$parsed->{diskid}";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $parsed = $class->_parse_volname($volname)
        or die "unable to parse volume name '$volname'\n";

    my $source_name = $class->_array_name($storeid, $volname);
    my ($source, $linked_to_base);

    if ($snap) {
        $source = $NAMING->encode_snapshot_name($source_name, $snap);
    } else {
        my $base = $NAMING->encode_base_snapshot_name($source_name);
        if ($api->volume_id_by_name($base, storeid => $storeid)) {
            $source = $base;
            $linked_to_base = 1;
        } elsif ($parsed->{isBase}) {
            my $id = $api->volume_id_by_name($source_name, storeid => $storeid)
                or die "Template '$source_name' is not on the array\n";
            $api->snapshot_create($id, $base, storeid => $storeid);
            $source = $base;
            $linked_to_base = 1;
        } else {
            $source = $source_name;
        }
    }

    my $source_id = $api->volume_id_by_name($source, storeid => $storeid)
        or die "Clone source '$source' is not on the array\n";

    my $diskid = $class->_find_free_diskid($scfg, $storeid, $vmid);
    my $target_volname = "vm-${vmid}-disk-${diskid}";
    my $target = $NAMING->encode_volume_name($storeid, $vmid, $diskid);

    # A snapshot of the source IS the clone: PowerFlex snapshots are writable
    # volumes, so nothing is copied.
    $api->snapshot_create($source_id, $target, storeid => $storeid);
    $class->_invalidate_list_cache($scfg, $storeid);

    my $target_id = $api->volume_id_by_name($target, storeid => $storeid);
    if ($target_id) {
        my $host_id = eval { $class->_host_id($scfg, $storeid) };
        eval {
            $api->volume_map($target_id, $host_id,
                nvme => !$class->_is_sdc($scfg), storeid => $storeid);
        } if $host_id;
    }

    return $linked_to_base ? "$volname/$target_volname" : $target_volname;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    my $features = {
        snapshot   => { current => 1, snap => 1 },
        clone      => { base => 1, current => 1, snap => 1 },
        template   => { current => 1 },
        copy       => { base => 1, current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },
        rename     => { current => 1 },
    };

    my $key = $snapname ? 'snap' : 'current';
    $key = 'base' if !$snapname && $volname && $volname =~ /^base-/;

    return 1 if $features->{$feature} && $features->{$feature}{$key};
    return 0;
}

sub storage_can_replicate { return 0 }

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellPowerFlexPlugin - Dell PowerFlex storage plugin for
Proxmox VE

=head1 SYNOPSIS

    pvesm add dellpowerflex pflex1 \
        --dell-portal 192.168.1.70 \
        --dell-username admin \
        --dell-password 'SecurePassword' \
        --dell-protocol nvme \
        --pflex-storage-pool pool1 \
        --content images,rootdir \
        --shared 1

=head1 DESCRIPTION

PowerFlex volumes do not arrive as SCSI LUNs, so this plugin does not inherit
the block base class the SAN families share. Two data paths exist:

=over 4

=item * B<nvme> (default) — NVMe/TCP against the array's SDT components,
using the in-kernel initiator. Nothing proprietary is installed on the host.

=item * B<sdc> — Dell's SDC kernel module, which the operator must install
and connect to the MDM themselves. See docs/POWERFLEX_SDC.md before choosing
it on Proxmox VE.

=back

A snapshot here is a writable volume, so a linked clone is a snapshot with a
volume-shaped name and costs nothing.

=head1 STATUS

Not verified against hardware. See docs/TESTING.md.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
