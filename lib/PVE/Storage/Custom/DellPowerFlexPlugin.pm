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
use PVE::Storage::Custom::DellEMC::Common::Multipath qw(
    is_block_device is_device_in_use device_size_bytes
);
use PVE::Storage::Custom::DellEMC::PowerFlex::Host qw(
    sdc_available sdc_guid sdc_device_for_volume
    nvme_available nvme_host_nqn nvme_connect nvme_device_for_volume
    nvme_multipath_enabled nvme_paths nvme_connected_addresses
    nvme_discover_nqn
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

# Negotiated, not hardcoded: PVE rejects a plugin claiming more than its own
# APIVER (the storage then vanishes from the node) and warns on every load
# when the claim is lower. PVE 9 raised APIVER twice inside the 9.1 point
# releases. See the long note in Common::BlockBase.
use constant APIVERSION_MAX      => 15;
use constant APIVERSION_MIN      => 9;
use constant APIVERSION_FALLBACK => 13;

push @PVE::Storage::Plugin::SHARED_STORAGE, 'dellpowerflex';

my $SCHEMA = 'PVE::Storage::Custom::DellEMC::Common::Schema';
my $HEALTH = 'PVE::Storage::Custom::DellEMC::Common::Health';
my $NAMING = 'PVE::Storage::Custom::DellEMC::PowerFlex::Naming';
my $HOST   = 'PVE::Storage::Custom::DellEMC::PowerFlex::Host';

sub api {
    my $pve = eval {
        PVE::Storage->can('APIVER') ? PVE::Storage::APIVER() : undef;
    };

    return APIVERSION_FALLBACK unless defined $pve && $pve =~ /^\d+\z/;

    my $claim = $pve < APIVERSION_MAX ? $pve : APIVERSION_MAX;
    $claim = APIVERSION_MIN if $claim < APIVERSION_MIN;

    return $claim;
}
sub type { return 'dellpowerflex' }

# The storeid of the storage being worked on: $scfg never carries it, and
# the _api call sites cannot all be given one. Every entry point that has it
# announces it here. Localised per operation so a forked worker cannot
# inherit a stale one.
our $CURRENT_STOREID;

sub plugindata {
    return {
        content => [ { images => 1, rootdir => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],

        # PVE reads the sensitive list from HERE, not from the
        # sensitive_properties method that used to sit below - it calls
        # PVE::Storage::Plugin::sensitive_properties($type) as a function
        # and looks the answer up in plugindata. Without this the array
        # password is written to /etc/pve/storage.cfg in clear text.
        'sensitive-properties' => { 'dell-password' => 1 },
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

sub get_identity {
    my ($class, $scfg, $storeid) = @_;
    local $CURRENT_STOREID = $storeid;

    # The addresses as a SET, not as the string someone typed: the same
    # array can be written several ways once 'dell-portal' is a list. See
    # BlockBase::_identity_portal, which this plugin does not inherit.
    my @portals = grep { length }
                  map  { lc(s/^\s+|\s+\z//gr) }
                  split /,/, $scfg->{'dell-portal'} // '';

    return join(':', 'dellpowerflex',
        join(',', sort @portals),
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

# A successful create is not a promise that the next query can see the object.
use constant AWAIT_OBJECT_TIMEOUT => 30;

sub _api {
    my ($class, $scfg, %opts) = @_;

    my $health = $opts{status} ? 1 : 0;

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
        password   => $class->_password($scfg, $opts{storeid}),
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

    if ($volname =~ m|^(base-(\d+)-disk-(\d+))/(vm-(\d+)-disk-(\d+))\z|) {
        return { vmid => $5, diskid => $6, type => 'disk', isBase => 0,
                 basename => $1, basevmid => $2, leafname => $4 };
    }
    if ($volname =~ /^vm-(\d+)-disk-(\d+)\z/) {
        return { vmid => $1, diskid => $2, type => 'disk', isBase => 0 };
    }
    if ($volname =~ /^base-(\d+)-disk-(\d+)\z/) {
        return { vmid => $1, diskid => $2, type => 'disk', isBase => 1 };
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-cloudinit\z/) {
        return { vmid => $1, type => 'cloudinit', isBase => 0 };
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-state-(.+)\z/) {
        return { vmid => $1, snapname => $2, type => 'state', isBase => 0 };
    }

    return undef;
}

# See BlockBase::parse_volname: the second element is the LEAF name, so a
# linked clone reports 'vm-101-disk-0' and not the whole volname.
sub parse_volname {
    my ($class, $volname) = @_;

    my $parsed = $class->_parse_volname($volname);
    die "unable to parse volume name '$volname'\n" unless $parsed;

    return ('images', $parsed->{leafname} // $volname, $parsed->{vmid},
        $parsed->{basename}, $parsed->{basevmid},
        $parsed->{isBase} ? 1 : 0, 'raw');
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
        next unless ref($row) eq 'HASH';
        my $name = $row->{name} // next;
        next unless index($name, $prefix) == 0;

        push @out, {
            id   => $row->{id},
            name => $name,
            size => $class->_api($scfg, %opts)->volume_size($row),
            used => 0,
            # Epoch seconds. PVE renders this as the snapshot's date, so a
            # missing value shows every snapshot as 1970.
            ctime => $row->{creationTime} // 0,
            # The volume a snapshot was taken from. For a PVE linked clone
            # that is the template marker snapshot.
            ancestor => $row->{ancestorVolumeId},
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
    local $CURRENT_STOREID = $storeid;

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
    if ($@) {
        my $err = $@;
        # PVE never reaches status() if this dies, so the outage has to be
        # recorded here or it is not recorded at all.
        eval { $HEALTH->record_status_failure($storeid, $err) };
        die "Cannot reach the PowerFlex API at " . ($scfg->{'dell-portal'} // '?')
          . " for storage '$storeid': $err";
    }

    # Fail early if the configured pool is not there; every later operation
    # would fail with something less obvious. Rate-limited: this is a
    # configuration check, not a health check, and status() looks the pool up
    # again on the same poll to report capacity — so doing it here on every
    # poll as well is one duplicated listing of every pool on the array, six
    # times a minute per node.
    if ($class->_check_due("$storeid/pool", $scfg)) {
        $class->_storage_pool($scfg, status => 1, storeid => $storeid);
        $class->_mark_check("$storeid/pool");
    }

    # NVMe/TCP needs a session to each SDT before any namespace can appear.
    $class->_ensure_nvme_sessions($storeid, $scfg, $api) if $mode eq 'nvme';

    return 1;
}

# Connect to the SDTs this node is not already connected to.
#
# activate_storage runs on every pvestatd poll, so this must cost one cheap
# check when nothing has changed. 'nvme connect' to an address that is already
# connected succeeds, but it is a process per address six times a minute per
# node — and on a degraded network each one carries a 30s timeout. Reading the
# existing paths once and connecting only what is missing costs a single
# command instead.
sub _ensure_nvme_sessions {
    my ($class, $storeid, $scfg, $api) = @_;

    # Without native multipathing each path shows up as its own block device,
    # and two of them can be written through at once.
    my $mp_warning = $HOST->nvme_multipath_message();
    $class->_warn_once($storeid, 'nvme-multipath',
        "Storage '$storeid': $mp_warning") if $mp_warning;

    my $targets = eval { $api->nvme_targets(status => 1) } // [];
    unless (@$targets) {
        die "The array published no NVMe/TCP targets (SDT). PowerFlex 4.0"
          . " or later is required for NVMe/TCP; on an older system use"
          . " 'dell-protocol sdc'.\n";
    }

    my $connected = eval { nvme_connected_addresses() } // {};

    my @missing = grep {
        !exists $connected->{ $_->{ip} . ':' . ($_->{port} // 4420) }
    } @$targets;

    # Everything the array published is already connected: nothing to do, and
    # nothing forked.
    unless (@missing) {
        $class->_mark_check($storeid);
        return 1;
    }

    # Some are missing. Retrying every poll would fork a connect per missing
    # target six times a minute against a target this node may simply not be
    # cabled to, so the retry is rate-limited once at least one path is up.
    my $have_any = scalar(keys %$connected) > 0;
    return 1 if $have_any && !$class->_check_due($storeid, $scfg);

    $class->_mark_check($storeid);

    my %connect_opts = (
        ctrl_loss_tmo => $scfg->{'pflex-nvme-ctrl-loss-tmo'} // 60,
    );
    $connect_opts{io_queues} = $scfg->{'pflex-nvme-io-queues'}
        if $scfg->{'pflex-nvme-io-queues'};

    # An SDT publishes no NQN — Dell's own field list for the object has none
    # — so for most arrays the subsystem NQN has to be discovered. One
    # discovery answers for every SDT of the same system, so the first one
    # that succeeds is reused rather than asking each target in turn.
    my $nqn = $class->_nvme_subsystem_nqn($storeid, \@missing);

    my @failed;
    for my $target (@missing) {
        my $address = "$target->{ip}:" . ($target->{port} // 4420);

        my $use = { %$target, nqn => $target->{nqn} // $nqn };
        unless (defined $use->{nqn} && length $use->{nqn}) {
            push @failed, $address;
            next;
        }

        push @failed, $address unless nvme_connect($use, %connect_opts);
    }

    my $now_up = scalar(@$targets) - scalar(@failed);

    die "Could not connect to any of the " . scalar(@$targets)
      . " NVMe/TCP target(s) the array published. Check network"
      . " reachability to the SDT addresses: " . join(', ', @failed)
      . "\n" if $now_up < 1;

    # One path is not multipathing. Say so, because the array published more
    # targets than this node could reach.
    $class->_warn_once($storeid, 'nvme-targets',
        "Storage '$storeid' has $now_up of " . scalar(@$targets)
      . " NVMe/TCP targets connected; could not reach: "
      . join(', ', @failed) . ". The volumes will work but with reduced"
      . " path redundancy.") if @failed;

    return 1;
}

# The subsystem NQN to connect to, discovered once per storage.
#
# Cached for the life of the process: pvestatd is long-lived, and the NQN of a
# PowerFlex system does not change while it is running. A target that already
# carries one is believed without asking.
my %NVME_NQN;

sub _nvme_subsystem_nqn {
    my ($class, $storeid, $targets) = @_;

    for my $target (@$targets) {
        return $target->{nqn}
            if defined $target->{nqn} && length $target->{nqn};
    }

    return $NVME_NQN{$storeid} if defined $NVME_NQN{$storeid};

    for my $target (@$targets) {
        my $nqn = eval {
            nvme_discover_nqn($target->{ip}, $target->{discovery_port})
        };
        next unless defined $nqn && length $nqn;

        $NVME_NQN{$storeid} = $nqn;
        return $nqn;
    }

    $class->_warn_once($storeid, 'nvme-discovery',
        "Storage '$storeid': none of the array's SDT addresses answered NVMe"
      . " discovery, so there is no subsystem NQN to connect to. Check that"
      . " the discovery port (8009 by default) is reachable from this node.");

    return undef;
}

# Wall clock of the last time a periodic check ran, per storage and topic.
# One warning per storage per topic per hour.
#
# activate_storage runs every ~10s per node per storage, and the conditions
# warned about on that path — a missing SDT, native multipathing off — persist
# until someone fixes them. Unthrottled, each writes six lines a minute per
# storage and buries everything else in the journal (rule 35).
#
# BlockBase keeps its flags in WwidState's lock directory. There is none here:
# PowerFlex has no dm-multipath and no WWID state, so the throttle is
# process-wide instead — which is what actually bounds the rate, because the
# process that polls is pvestatd and it is long-lived. A short-lived `pvesm`
# invocation warning once is the right answer anyway.
#
# Until 0.7.92 this method did not exist here at all, and _password called it:
# every PowerFlex storage whose password was still in storage.cfg died on
# "Can't locate object method". See lesson 65.
my %WARNED;

sub _warn_once {
    my ($class, $storeid, $topic, $message, %opts) = @_;

    my $interval = $opts{interval} // 3600;
    my $key = ($storeid // '?') . "\0$topic";
    my $now = time();

    my $last = $WARNED{$key};
    return 0 if defined $last && $now >= $last && ($now - $last) < $interval;

    $WARNED{$key} = $now;
    warn "$message\n";

    return 1;
}

#
# activate_storage runs on every pvestatd poll, so anything in it that is not
# strictly a health check has to be rate-limited. Process-wide on purpose:
# pvestatd is long-lived, so this is what actually bounds the rate.
my %LAST_CHECK;

sub _check_due {
    my ($class, $storeid, $scfg) = @_;

    my $interval = $scfg->{'dell-rescan-interval'} // 300;
    return 1 if $interval <= 0;

    my $last = $LAST_CHECK{$storeid};
    my $now  = time();

    return 1 unless defined $last;
    return 1 if $now < $last;          # the clock stepped backwards

    return ($now - $last) >= $interval ? 1 : 0;
}

sub _mark_check {
    my ($class, $storeid, $when) = @_;
    $LAST_CHECK{$storeid} = $when // time();
    return;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

    # Deliberately does not disconnect NVMe sessions or unmap volumes: other
    # storages may share the same subsystem, and unmapping would break a
    # migration that is still in flight.
    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

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
    local $CURRENT_STOREID = $storeid;

    die "unsupported format '$fmt' - this storage only holds raw volumes\n"
        if defined $fmt && $fmt ne 'raw';

    my $api = $class->_api($scfg, storeid => $storeid);
    my $pool = $class->_storage_pool($scfg, storeid => $storeid);

    my ($array_name, $pve_volname);
    if ($name && $name =~ /^vm-\d+-(?:state-.+|cloudinit)\z/) {
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
        eval { $api->volume_delete($id, storeid => $storeid) };
        $class->_invalidate_list_cache($scfg, $storeid);
        die "Volume created but this node could not be identified to the"
          . " array, so it was removed again: $err\n";
    }

    eval { $api->volume_map($id, $host_id, nvme => !$class->_is_sdc($scfg)) };
    if ($@) {
        my $err = $@;
        # Unmap before deleting. The map may have partly taken effect even
        # though the call reported failure, and PowerFlex refuses to remove a
        # volume that is still mapped — which would leave an orphan volume
        # plus a mapping no one owns.
        eval { $api->volume_unmap($id, $host_id,
            nvme => !$class->_is_sdc($scfg), storeid => $storeid) };
        eval { $api->volume_delete($id, storeid => $storeid) };
        $class->_invalidate_list_cache($scfg, $storeid);
        die "Failed to map the new volume to this node; it was removed"
          . " again: $err\n";
    }

    return $pve_volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;
    local $CURRENT_STOREID = $storeid;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);

    # Deliberately not wrapped in eval: a lookup that cannot reach the array
    # must fail the delete, not be read as "already gone". PVE removes the
    # disk from the VM configuration when free_image returns, so a wrong
    # "deleted" here loses the only reference to a volume still on the array.
    my $id = $api->volume_id_by_name($array_name, storeid => $storeid);
    unless ($id) {
        warn "Volume '$array_name' is not on the array; it may already have"
           . " been deleted\n";
        return undef;
    }

    $class->_assert_own_object($storeid, $array_name, 'delete volume');

    # Nothing may be using it here. This unmaps before it deletes, so acting
    # on a wrong "free" takes the disk from a guest that is still writing.
    $class->_assert_not_in_use($scfg, $id, 'delete volume', $volname);

    # Unmap everywhere before deleting, for the same reason as the SAN
    # families: a volume deleted while still mapped leaves other nodes with a
    # device that answers nothing.
    my $volume = $api->volume_get($id, storeid => $storeid);
    for my $host_id (@{ $api->volume_mapped_hosts($volume, storeid => $storeid) }) {
        eval { $api->volume_unmap($id, $host_id, nvme => !$class->_is_sdc($scfg)) };
        warn "Failed to unmap '$array_name' from host $host_id: $@" if $@;
    }

    # PowerFlex refuses to remove a volume that still has snapshots, and PVE
    # does not delete them first: 'qm destroy' calls vdisk_free straight away.
    # removeMode stays ONLY_ME so a linked clone is never taken with it, and
    # the template marker is left until the delete has been tried, so a
    # template whose clones still depend on it is not stripped of its identity
    # by a delete that fails anyway.
    my @snapshot_errors;
    $class->_purge_own_snapshots($scfg, $storeid, $array_name,
        keep_base => 1, errors => \@snapshot_errors);

    eval { $api->volume_delete($id, storeid => $storeid) };

    # Captured immediately: $@ is global and every eval below resets it, so
    # reading it again later would report a refused delete as success.
    my $delete_error = $@;

    # The array decides whether the template marker may go: a linked clone is
    # a snapshot OF THE MARKER, so PowerFlex refuses to remove it while one
    # exists. Trying and being refused is safe, and it is the only reliable
    # test — the refusal text is the same for "it still has a snapshot" and
    # "something was cloned from it". See the same passage in Common::BlockBase.
    if ($isBase || $volname =~ /^base-/) {
        if ($delete_error) {
            if ($class->_purge_own_snapshots($scfg, $storeid, $array_name,
                    base_only => 1, errors => \@snapshot_errors)) {
                eval { $api->volume_delete($id, storeid => $storeid) };
                $delete_error = $@;
            }
        } else {
            eval { $class->_purge_own_snapshots($scfg, $storeid, $array_name,
                base_only => 1) };
        }
    }

    if ($delete_error) {
        my $err = $delete_error;
        chomp $err;

        $err .= "\n  While clearing its snapshots: "
              . join('; ', @snapshot_errors) if @snapshot_errors;

        die "Cannot delete volume '$volname': the array reports dependent"
          . " objects, which on PowerFlex means snapshots or clones made from"
          . " it. Delete those first.\n  Array error: $err\n"
            if $err =~ /descendant|snapshot|child|depend/i;
        die "Failed to delete volume '$array_name': $err\n";
    }

    $class->_invalidate_list_cache($scfg, $storeid);

    return undef;
}

# Delete the snapshots this plugin created for one volume, including the
# template marker. A linked clone is a snapshot with a volume-shaped name, so
# it does not decode here and is never removed.
# $opts{errors} collects the reason each snapshot would not go; see the same
# method in Common::BlockBase.
sub _purge_own_snapshots {
    my ($class, $scfg, $storeid, $array_name, %opts) = @_;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $volumes = eval {
        $class->_list_own_volumes($scfg, $storeid, $NAMING->volume_prefix($storeid));
    } // [];

    my $removed = 0;
    for my $volume (@$volumes) {
        my $decoded = $NAMING->decode_snapshot_name($volume->{name}) or next;
        next unless ($decoded->{volume} // '') eq $array_name;

        next if $opts{keep_base} && $decoded->{is_base};
        next if $opts{base_only} && !$decoded->{is_base};

        $class->_assert_own_object($storeid, $volume->{name}, 'delete snapshot');
        eval { $api->volume_delete($volume->{id}, storeid => $storeid) };
        if ($@) {
            my $err = $@;
            chomp $err;
            warn "Could not delete snapshot '$volume->{name}' of"
               . " '$array_name': $err\n";
            push @{ $opts{errors} }, $err if ref($opts{errors}) eq 'ARRAY';
            next;
        }
        $removed++;
    }

    $class->_invalidate_list_cache($scfg, $storeid) if $removed;

    return $removed;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

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

    # Linked clones must carry the same 'base-.../vm-...' volid PVE stored in
    # the VM configuration; otherwise 'qm rescan' sees a volume no config
    # references and adds it again as an unused disk. A clone is a snapshot of
    # a template marker, so the marker's id identifies its base.
    my %base_of;
    for my $volume (@{ $class->_list_own_volumes($scfg, $storeid,
        $NAMING->volume_prefix($storeid)) }) {
        my $decoded = $NAMING->decode_snapshot_name($volume->{name}) or next;
        next unless $decoded->{is_base};
        $base_of{ $volume->{id} } = $decoded->{volume} if defined $volume->{id};
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

            my $base = defined $volume->{ancestor}
                ? $base_of{ $volume->{ancestor} } : undef;
            if ($kind eq 'vm' && defined $base) {
                my $bd = $NAMING->decode_volume_name($base);
                $pve_volname = "base-$bd->{vmid}-disk-$bd->{diskid}/$pve_volname"
                    if $bd && $bd->{type} eq 'disk';
            }
        } else {
            $pve_volname = $NAMING->array_to_pve_volname($volume->{name});
        }
        next unless $pve_volname;

        my $volid = "$storeid:$pve_volname";
        # Exact match, as the built-in plugins do: a prefix match would let a
        # request for vm-1-disk-1 also return vm-1-disk-10.
        if ($vollist) {
            next unless grep { $_ eq $volid } @$vollist;
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
    local $CURRENT_STOREID = $storeid;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);

    my $volume = $api->volume_get_by_name($array_name, storeid => $storeid)
        or die "Volume '$array_name' not found on the array\n";

    my $size = $api->volume_size($volume);

    return wantarray ? ($size, 'raw', 0, undef) : $size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;
    local $CURRENT_STOREID = $storeid;

    # Storage API 14 added $snapname; a PowerFlex snapshot is a volume in its
    # own right and resizing one is not what the caller means here.
    die "Resizing a snapshot is not supported by dellpowerflex. Resize the"
      . " volume '$volname' instead.\n" if $snapname;

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
    local $CURRENT_STOREID = $storeid;

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

# Wait for a named volume to become resolvable to an id. Returns the id, or
# dies naming the volume.
sub _await_volume_id {
    my ($class, $api, $storeid, $name) = @_;

    my $deadline = time() + AWAIT_OBJECT_TIMEOUT;

    while (1) {
        my $id = eval { $api->volume_id_by_name($name, storeid => $storeid) };
        return $id if $id;
        last if time() >= $deadline;
        sleep(1);
    }

    die "The array accepted the request but volume '$name' was still not"
      . " resolvable after " . AWAIT_OBJECT_TIMEOUT . "s. Check in PowerFlex"
      . " Manager whether it exists before retrying.\n";
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

# The ownership gate, in front of every array-side delete.
#
# Same rule as BlockBase::_assert_own_object, spelled out here because this
# plugin does not inherit it. The storeid is not optional: without it the
# check only proves the name looks like SOME PVE plugin's, which does not
# authorise deleting it — a second storage on the same system produces names
# of exactly that shape.
sub _assert_own_object {
    my ($class, $storeid, $name, $what) = @_;

    return 1 if $NAMING->is_pve_managed_volume($name, $storeid);

    die "Refusing to $what '" . (defined $name ? $name : '(undef)')
      . "': it is not an object storage '" . (defined $storeid ? $storeid : '?')
      . "' created. This plugin only deletes objects whose names it generated"
      . " itself; something has gone wrong upstream of here.\n";
}

# Refuse a destructive operation while this node is using the volume, and
# refuse it just as firmly when that cannot be established.
#
# The SAN families get this from BlockBase. PowerFlex does not inherit it —
# the data path is an NVMe namespace or an SDC device, not a dm-multipath map
# — so it is spelled out here rather than being absent, which is what it was.
#
# is_device_in_use answers 1 / 0 / undef, and undef means the checks could not
# prove anything: a stat that timed out, unreadable sysfs, a fuser that could
# not run. fuser is the only one of them that sees a running QEMU, which holds
# the device open with no mount and no holder.
sub _assert_not_in_use {
    my ($class, $scfg, $volume_id, $what, $volname) = @_;

    my $device = eval { $class->_device_lookup($scfg, $volume_id)->() };
    return 1 unless $device;

    return 1 unless is_block_device($device);

    my $in_use = is_device_in_use($device);

    die "Cannot $what '$volname': whether device $device is still in use could"
      . " not be determined. Refusing rather than assuming it is free.\n"
        unless defined $in_use;

    die "Cannot $what '$volname': device $device is still in use. Stop the VM"
      . " first.\n" if $in_use;

    return 1;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    local $CURRENT_STOREID = $storeid;

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

# QEMU's blockdev options for this volume. Same reasoning as BlockBase's, and
# spelled out here because this plugin inherits none of it (lesson 40a): the
# base class reaches the path through an unbounded File::stat::stat, which on
# a device whose paths are gone is the uninterruptible sleep rule 9 exists
# for — here in the pvedaemon worker that is starting the VM.
sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;
    local $CURRENT_STOREID = $storeid;

    my ($path) = $class->path($scfg, $volname, $storeid,
        $options->{'snapshot-name'});

    die "Cannot start with volume '$volname': its device could not be"
      . " resolved. The array did not answer, or the volume is not mapped to"
      . " this node.\n" if $path =~ m{-unknown-};

    die "Cannot start with volume '$volname': '$path' is not a block device"
      . " on this node.\n" unless is_block_device($path);

    return { driver => 'host_device', filename => $path };
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "filesystem_path is not supported by dellpowerflex (volume"
      . " '$volname'): volume names are derived from the storage id, which is"
      . " not available here. Use PVE::Storage::path() instead.\n";
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

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
    local $CURRENT_STOREID = $storeid;

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
    local $CURRENT_STOREID = $storeid;

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
    local $CURRENT_STOREID = $storeid;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);
    my $snap_name = $NAMING->encode_snapshot_name($array_name, $snap);

    my $id = $api->volume_id_by_name($snap_name, storeid => $storeid);
    unless ($id) {
        warn "Snapshot '$snap' of volume '$volname' is not on the array\n";
        return 1;
    }

    $class->_assert_own_object($storeid, $snap_name, 'delete snapshot');
    eval { $api->volume_delete($id, storeid => $storeid) };
    if ($@) {
        my $err = $@;
        die "Cannot delete snapshot '$snap': the array reports objects that"
          . " depend on it, which means clones were made from it. Delete"
          . " those first.\n  Array error: $err"
            if $err =~ /descendant|child|depend/i;
        die "Failed to delete snapshot '$snap' of volume '$volname': $err\n";
    }

    $class->_invalidate_list_cache($scfg, $storeid);

    return 1;
}

# See the long note on the same method in Common::BlockBase: what PowerFlex's
# overwrite-volume-content does to snapshots taken after the source is not
# documented, so the unknown is treated as dangerous and only the most recent
# snapshot may be rolled back to.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;
    local $CURRENT_STOREID = $storeid;

    $blockers //= [];

    my $snapshots = $class->volume_snapshot_list($scfg, $storeid, $volname);

    my ($target) = grep { ($_->{name} // '') eq $snap } @$snapshots;
    die "can't rollback, snapshot '$snap' does not exist on"
      . " '$storeid:$volname'\n" unless $target;

    return 1 if $scfg->{'dell-rollback-any-snapshot'};

    my $target_time = $target->{ctime} // 0;

    for my $other (@$snapshots) {
        my $name = $other->{name} // next;
        next if $name eq $snap;

        my $time = $other->{ctime} // 0;
        push @$blockers, $name
            if !$time || !$target_time || $time >= $target_time;
    }

    die "Cannot roll back '$storeid:$volname' to '$snap': it is not the most"
      . " recent snapshot, and these would be at risk: "
      . join(', ', @$blockers) . ".\n"
      . "  Dell does not document what overwriting a volume from a snapshot"
      . " does to the snapshots taken after it, so this plugin refuses rather"
      . " than let PVE keep listing restore points the array may have"
      . " discarded.\n"
      . "  Roll back to the most recent snapshot, or delete the newer ones"
      . " first. If you have verified the behaviour on your array, set"
      . " 'dell-rollback-any-snapshot 1' on storage '$storeid'.\n"
        if @$blockers;

    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    local $CURRENT_STOREID = $storeid;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);
    my $snap_name = $NAMING->encode_snapshot_name($array_name, $snap);

    my $volume_id = $api->volume_id_by_name($array_name, storeid => $storeid)
        or die "Cannot roll back: volume '$array_name' is not on the array\n";
    my $snap_id = $api->volume_id_by_name($snap_name, storeid => $storeid)
        or die "Cannot roll back: snapshot '$snap' is not on the array\n";

    # A rollback overwrites the whole volume, and the damage is not visible
    # until the guest next reads.
    $class->_assert_not_in_use($scfg, $volume_id, 'roll back volume', $volname);

    # Flush before, invalidate after. Dirty pages written back after the array
    # has restored the snapshot land on top of it, and the result reads as a
    # rollback that half worked.
    my $device = eval { $class->_device_lookup($scfg, $volume_id)->() };
    if ($device && is_block_device($device)) {
        eval { PVE::Tools::run_command(['/bin/sync'], timeout => 10) };
        eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device],
            timeout => 10) };
    }

    $api->snapshot_rollback($volume_id, $snap_id, storeid => $storeid);

    if ($device && is_block_device($device)) {
        # Without this, reads can still be served from pages holding the
        # post-snapshot content.
        eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device],
            timeout => 10) };
    }

    return 1;
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;
    local $CURRENT_STOREID = $storeid;

    my $array_name = $class->_array_name($storeid, $volname);
    my $volumes = $class->_list_own_volumes($scfg, $storeid,
        $NAMING->volume_prefix($storeid));

    my @res;
    for my $volume (@$volumes) {
        my $decoded = $NAMING->decode_snapshot_name($volume->{name}) or next;
        next if $decoded->{is_base};
        next unless $decoded->{volume} eq $array_name;

        push @res, {
            name  => $decoded->{snapname},
            ctime => $volume->{ctime} // 0,
        };
    }

    return \@res;
}

# The base implementations of both of these read a qcow2 file through
# filesystem_path(), which this plugin cannot provide. Answering from the
# array beats failing with a message about a method the caller never asked
# for.
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;
    local $CURRENT_STOREID = $storeid;

    my $info = { current => {} };

    my $snaps = eval { $class->volume_snapshot_list($scfg, $storeid, $volname) } // [];
    for my $snap (@$snaps) {
        my $name = $snap->{name} // next;
        $info->{$name} = { timestamp => $snap->{ctime} // 0 };
    }

    return $info;
}

sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source_snap, $target_snap) = @_;

    die "Renaming a snapshot is not supported by dellpowerflex. Create a new"
      . " snapshot and delete the old one instead.\n";
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    local $CURRENT_STOREID = $storeid;

    my ($vtype, undef, $vmid, undef, undef, $isBase) = $class->parse_volname($volname);

    die "create_base is not possible for content type '$vtype'\n" if $vtype ne 'images';
    die "volume '$volname' is already a base image\n" if $isBase;

    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $volname);

    my $id = $api->volume_id_by_name($array_name, storeid => $storeid)
        or die "Cannot create a template from '$volname': it is not on the array\n";

    # Every linked clone made later reads from this marker snapshot, so a
    # template captured mid-write is a filesystem that was never consistent,
    # duplicated into every clone of it.
    $class->_assert_not_in_use($scfg, $id, 'convert volume to a template',
        $volname);

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
    local $CURRENT_STOREID = $storeid;

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

    my $target_id = $class->_await_volume_id($api, $storeid, $target);

    my $host_id = eval { $class->_host_id($scfg, $storeid) };
    my $host_error = $@;

    unless ($host_error) {
        eval {
            $api->volume_map($target_id, $host_id,
                nvme => !$class->_is_sdc($scfg), storeid => $storeid);
        };
        $host_error = $@;
    }

    # A clone this node cannot reach is worse than no clone: PVE would record
    # a disk whose device never appears. Roll it back, unmapping first.
    if ($host_error) {
        eval { $api->volume_unmap($target_id, $host_id,
            nvme => !$class->_is_sdc($scfg), storeid => $storeid) } if $host_id;
        eval { $api->volume_delete($target_id, storeid => $storeid) };
        $class->_invalidate_list_cache($scfg, $storeid);
        die "The clone was created but could not be mapped to this node, so"
          . " it was removed again: $host_error\n";
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
        # sparseinit is answered below: it is a claim about the array's
        # provisioning, not about the volume's kind.
        rename     => { current => 1 },
    };

    # 'sparseinit' tells PVE the volume reads as zeroes where nothing has been
    # written, and PVE acts on it by not writing the zeroes at all — a clone
    # of a running VM is mirrored with 'zero-initialized', pbs-restore gets
    # --skip-zero. True of a ThinProvisioned volume; not true of a
    # ThickProvisioned one, whose blocks are whatever the pool last had there.
    # 'pflex-thick' is an operator's choice, so the answer follows it.
    # Same claim as the import path's dd (0.7.90), reached through QEMU; this
    # family inherits none of BlockBase's, so it is spelled out (lesson 40a).
    if ($feature eq 'sparseinit') {
        return 0 if $snapname;
        return $scfg->{'pflex-thick'} ? 0 : 1;
    }

    # From parse_volname, not from the spelling: a linked clone is named
    # 'base-100-disk-0/vm-101-disk-0', which starts with 'base-' while being
    # the least base-like volume there is. See BlockBase::volume_has_feature.
    # eval: parse_volname dies on a name it does not recognise, and this is
    # called in a loop over a VM's configuration. A name this plugin cannot
    # read is not this question's problem — answer for an ordinary volume and
    # let whatever actually touches it report the real error.
    my $isBase = eval { ($class->parse_volname($volname))[5] };

    my $key = $snapname ? 'snap' : ($isBase ? 'base' : 'current');

    return 1 if $features->{$feature} && $features->{$feature}{$key};
    return 0;
}

# LXC freezes a container's filesystem before a snapshot only when the storage
# says it needs it. PVE::LXC::Config asks this, and nothing else does — a VM's
# consistency is QEMU's business, a container's is the host's.
#
# A container's root filesystem is mounted ON THIS HOST and is being written
# to while the array takes its snapshot. Without a freeze the snapshot is
# crash-consistent at best: it needs a journal replay on restore and can still
# have lost writes the container believed were committed.
#
# ZFSPlugin — the other plugin where an external appliance takes the snapshot
# — answers the same way, for the same reason.
sub volume_snapshot_needs_fsfreeze { return 1 }

# Moving a volume to a storage of another type, `pvesm export`/`import`, and
# remote migration all go through PVE::Storage::storage_migrate, which asks
# both storages what transfer formats they have in common. The base class
# answers "none" for a storage without a 'path', so every one of those was
# refused before reaching any code here.
#
# A volume here is a raw block device, exactly as it is for LVM and RBD, and
# both of those declare 'raw+size'. What they do NOT do is leave the transfer
# to the base class, whose volume_export opens with "if ($scfg->{path} && ...)"
# and falls through to a die for a storage that has no path. Declaring the
# format without implementing the transfer only moves the refusal one call
# later; volume_export and volume_import are below.
sub volume_import_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot,
        $with_snapshots) = @_;

    # Snapshots do not travel with the volume: they live on the array and this
    # plugin does not keep them as a chain of files.
    return () if $with_snapshots;

    # A linked clone has no standalone content to send — its base lives on the
    # array it is being moved away from.
    return () if defined($base_snapshot);

    return ('raw+size');
}

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot,
        $with_snapshots) = @_;

    # Exporting a snapshot would mean handing out a device for it, which needs
    # a temporary clone on the array. LVM refuses the same case; so does this.
    return () if defined($snapshot);

    return $class->volume_import_formats($scfg, $storeid, $volname, $snapshot,
        $base_snapshot, $with_snapshots);
}

# The same two methods BlockBase gained in 0.7.88, spelled out here because
# this plugin inherits none of it (lesson 40a). The differences are the data
# path: the device is an NVMe namespace or an SDC device rather than a
# dm-multipath map, and the kernel's own identification of it is the by-id
# link that carries the PowerFlex volume id — which is what _device_lookup
# resolves, and why the placeholder path() falls back to must be refused here
# rather than written to.
#
# The dd is deliberately not wrapped in an alarm: a bulk copy of a whole disk
# legitimately runs for hours, and rule 5's bound is for the poll paths.
sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot,
        $base_snapshot, $with_snapshots) = @_;
    local $CURRENT_STOREID = $storeid;

    die "volume export format '$format' is not available for $class\n"
        if !defined($format) || $format ne 'raw+size';
    die "cannot export a volume together with its snapshots here: the"
      . " snapshots live on the array, not in the volume\n" if $with_snapshots;
    die "cannot export the snapshot '$snapshot' here\n" if defined $snapshot;
    die "cannot export an incremental stream here\n" if defined $base_snapshot;

    # Nothing activates the volume for us: PVE::Storage::volume_export goes
    # straight from the storage config to the plugin.
    $class->activate_volume($storeid, $scfg, $volname);

    my $device = $class->_transfer_device($scfg, $storeid, $volname);

    my $size = device_size_bytes($device);
    die "Cannot export volume '$volname': the size of device $device could"
      . " not be read. Refusing rather than sending a stream with a size"
      . " nobody checked.\n" unless defined $size && $size > 0;

    PVE::Storage::Plugin::write_common_header($fh, $size);
    PVE::Tools::run_command(
        ['dd', "if=$device", 'bs=64k', 'status=progress'],
        output => '>&' . fileno($fh),
    );

    return;
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot,
        $base_snapshot, $with_snapshots, $allow_rename) = @_;
    local $CURRENT_STOREID = $storeid;

    die "volume import format '$format' is not available for $class\n"
        if !defined($format) || $format ne 'raw+size';
    die "cannot import a volume together with its snapshots here\n"
        if $with_snapshots;
    die "cannot import into the snapshot '$snapshot'\n" if defined $snapshot;
    die "cannot import an incremental stream here\n" if defined $base_snapshot;

    my ($vtype, $name, $vmid, undef, undef, undef, $file_format) =
        $class->parse_volname($volname);

    die "cannot import a volume of type '$vtype' here: this storage holds"
      . " images only\n" if $vtype ne 'images';
    die "cannot import format '$format' into a volume of format"
      . " '$file_format'\n" if $file_format ne 'raw';

    # "Already there" and "could not ask" are different answers (rule 21a):
    # volume_id_by_name dies when the array cannot be reached, and that die is
    # deliberately not caught here.
    my $api = $class->_api($scfg, storeid => $storeid);
    my $array_name = $class->_array_name($storeid, $name);
    if ($api->volume_id_by_name($array_name, storeid => $storeid)) {
        die "Volume '$name' already exists on storage '$storeid'\n"
            unless $allow_rename;
        warn "Volume '$name' already exists on storage '$storeid' —"
           . " importing under a different name\n";
    }

    my ($bytes) = PVE::Storage::Plugin::read_common_header($fh);
    die "Cannot import volume '$name': the stream carries no size\n"
        unless defined $bytes && $bytes > 0;
    # alloc_image takes KiB. Round UP: a volume one byte short of the stream
    # is filled and then fails. PowerFlex rounds further, to 8 GiB.
    my $size_kb = int(($bytes + 1023) / 1024);

    my $allocname = $class->alloc_image($storeid, $scfg, $vmid, 'raw', $name,
        $size_kb);

    eval {
        if ($allocname ne $name && !$allow_rename) {
            die "internal error: the volume was allocated as '$allocname'"
              . " rather than '$name', and the caller cannot follow a"
              . " rename\n";
        }

        $class->activate_volume($storeid, $scfg, $allocname);

        my $device = $class->_transfer_device($scfg, $storeid, $allocname);

        # No conv=sparse: skipping a run of zeroes is only correct where the
        # region already reads as zeroes, which a thin volume guarantees and
        # a thick one does not — and 'pflex-thick' is an operator's choice.
        # See the same comment in BlockBase.
        PVE::Tools::run_command(
            ['dd', "of=$device", 'bs=64k'],
            input => '<&' . fileno($fh),
        );
    };
    if (my $err = $@) {
        eval { $class->free_image($storeid, $scfg, $allocname, 0) };
        warn "Cleaning up the partly imported volume '$allocname' failed: $@"
            if $@;
        die $err;
    }

    return "$storeid:$allocname";
}

# The device for a transfer, resolved from the volume id the array gave and
# refused unless the kernel actually has it. path() falls back to a
# '/dev/disk/by-id/emc-vol-unknown-*' placeholder when the array cannot be
# reached, and an import would otherwise dd a whole disk image into it.
sub _transfer_device {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $array_name = $class->_array_name($storeid, $volname);
    my $id = $class->_api($scfg, storeid => $storeid)
                   ->volume_id_by_name($array_name, storeid => $storeid);
    die "Cannot transfer volume '$volname': '$array_name' is not on the"
      . " array.\n" unless $id;

    my $device = $class->_device_lookup($scfg, $id)->();
    die "Cannot transfer volume '$volname': the kernel has no device for"
      . " PowerFlex volume $id on this node. A transfer reads or writes the"
      . " whole volume, so a path that was not resolved from the volume id"
      . " is treated as a wrong one.\n"
        unless $device && is_block_device($device);

    return $device;
}

# The protocols this storage type actually speaks.
#
# 'dell-protocol' is declared once, in Common::Schema, for all three types —
# PVE::SectionConfig::init dies on a duplicate property name and takes every
# storage on the node down with it, so a per-family enum is not available.
# The enum therefore lists every protocol any family supports, and this is
# what narrows it.
sub supported_protocols { return ['sdc', 'nvme'] }

# Refuse a protocol this type cannot speak, at the moment it is configured.
#
# Without this the mistake survives: PowerFlex died on first use, with the
# storage already added and every operation failing; the SAN families were
# worse and simply treated an unknown protocol as iSCSI, so a node asked for
# one data path and silently got another, permanently.
#
# On an update PVE passes only the properties being changed, so an update
# that does not touch the protocol has nothing to check.
sub _check_protocol {
    my ($class, $storeid, $config) = @_;

    my $protocol = $config->{'dell-protocol'};
    return 1 unless defined $protocol && length $protocol;

    my $allowed = $class->supported_protocols;
    return 1 if grep { $_ eq $protocol } @$allowed;

    die "Storage type '" . $class->type() . "' speaks "
      . join(' or ', map { "'$_'" } @$allowed)
      . "; 'dell-protocol $protocol' belongs to the SAN families.\n";
}

sub naming_class_for_check { return $NAMING }

# Two different storage ids must not produce the same volume names.
#
# The prefix is the storage id sanitised and with '-' folded to '_', because
# '-' is the separator inside a volume name and a storage id containing one
# would make decode_volume_name ambiguous. The folding is lossy: 'ps-1',
# 'ps.1', 'ps+1', 'ps@1' and 'ps__1' all become 'ps_1'.
#
# Two such storages on one array share a namespace completely. They list each
# other's disks, and the ownership gate passes for both — so a `qm destroy` on
# one deletes a volume PVE believes belongs to the other. Nothing about that
# is visible until it happens.
#
# It cannot be fixed in the name without spending characters this plugin does
# not have: PowerVault allows 32 and PowerFlex 31 for a whole volume name. So
# it is refused here instead, where the storage id is still free to change.
#
# The portal is deliberately not part of the comparison. Two arrays today can
# be one array tomorrow — a portal is an editable property — and renaming a
# storage that has volumes on it is not.
sub _check_prefix_collision {
    my ($class, $storeid, $scfg) = @_;

    return 1 unless defined $storeid && length $storeid;

    my $mine = eval { $class->naming_class_for_check->volume_prefix($storeid) };
    return 1 unless defined $mine;

    my $cfg = eval { PVE::Storage::config() } or return 1;
    my $ids = $cfg->{ids} || {};

    for my $other (sort keys %$ids) {
        next if $other eq $storeid;

        my $type = $ids->{$other}{type} // '';
        next unless $type =~ /^dell/;

        my $plugin = eval { PVE::Storage::Plugin->lookup($type) } or next;
        next unless $plugin->can('naming_class_for_check');

        my $theirs = eval { $plugin->naming_class_for_check->volume_prefix($other) };
        next unless defined $theirs && $theirs eq $mine;

        die "Storage '$storeid' would use the same volume-name prefix as the"
          . " existing storage '$other' ('$mine'). Volume names are built from"
          . " it, so on one array the two storages would share every name:"
          . " each would list the other's disks, and deleting a disk from one"
          . " would delete it from the other. The prefix folds '-', '.', '+'"
          . " and other punctuation to '_', which is why two ids that look"
          . " different can produce one. Choose a storage id that differs by"
          . " more than punctuation.\n";
    }

    return 1;
}

# The array's password lives in /etc/pve/priv, not in storage.cfg. This
# family does not inherit BlockBase, so it carries its own copy of the four
# helpers - deliberately duplicated rather than moved to a shared module the
# BlockBase families would then reach into sideways.
sub _password_file {
    my ($class, $storeid) = @_;
    return "/etc/pve/priv/storage/${storeid}.pw";
}

sub _set_password {
    my ($class, $storeid, $password) = @_;

    mkdir '/etc/pve/priv/storage';
    PVE::Tools::file_set_contents($class->_password_file($storeid),
        "$password\n", 0600, 1);

    return;
}

sub _delete_password {
    my ($class, $storeid) = @_;

    unlink $class->_password_file($storeid);

    return;
}

# The priv file first, then the config: a storage created before this
# changed still carries the password in storage.cfg, and refusing those
# would take working storages offline on upgrade.
sub _password {
    my ($class, $scfg, $storeid) = @_;

    $storeid = $CURRENT_STOREID unless defined $storeid && length $storeid;

    if (defined $storeid && length $storeid) {
        my $file = $class->_password_file($storeid);
        if (-f $file) {
            my $password = eval { PVE::Tools::file_get_contents($file) };
            if (defined $password) {
                chomp $password;
                return $password if length $password;
            }
        }
    }

    my $legacy = $scfg->{'dell-password'};
    return undef unless defined $legacy && length $legacy;

    $class->_warn_once($storeid // '?', 'password-in-config',
        "Storage '" . ($storeid // '?') . "': the array password is stored in"
      . " /etc/pve/storage.cfg, which is readable by the www-data group and"
      . " replicated to every node. To move it into /etc/pve/priv run:\n"
      . "    pvesm set " . ($storeid // '<storeid>')
      . " --dell-password '<the password>'")
        if defined $storeid && length $storeid;

    return $legacy;
}

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    $class->_check_protocol($storeid, $scfg);
    $class->_check_prefix_collision($storeid, $scfg);

    if (defined(my $password = $param{'dell-password'})) {
        $class->_set_password($storeid, $password);
    }

    return undef;
}

sub on_update_hook {
    my ($class, $storeid, $update, %param) = @_;

    $class->_check_protocol($storeid, $update);

    if (defined(my $password = $param{'dell-password'})) {
        $class->_set_password($storeid, $password);
    }

    return undef;
}

# The one place the legacy plaintext password can be removed from the config.
#
# PVE hands the EXISTING $scfg here, and writes it back after this returns -
# so deleting the key completes the migration a 'pvesm set --dell-password'
# starts. Without it a migrating storage ends up with the password in both
# places: the priv file wins, but the clear-text copy lingers in a
# group-readable, cluster-replicated file, which is the whole problem.
#
# Only ever when the priv file actually holds something. An unrelated
# 'pvesm set --content images' on a storage that never migrated must not
# take its only copy of the password away.
sub on_update_hook_full {
    my ($class, $storeid, $scfg, $update, $delete, $sensitive) = @_;

    my $res = $class->on_update_hook($storeid, $update, %{ $sensitive // {} });

    if (defined $scfg->{'dell-password'}) {
        my $stored = eval {
            PVE::Tools::file_get_contents($class->_password_file($storeid));
        };
        chomp $stored if defined $stored;

        if (defined $stored && length $stored) {
            delete $scfg->{'dell-password'};
            warn "Storage '$storeid': the array password has moved to"
               . " /etc/pve/priv/storage/${storeid}.pw and the clear-text"
               . " copy has been removed from /etc/pve/storage.cfg.\n";
        }
    }

    return $res;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    $class->_delete_password($storeid);

    # The outage state, so a storage id re-created later does not inherit it
    # and report "RECOVERED after four days" on its first successful poll.
    # There is nothing else to clear here: this family keeps no WWID tracking
    # (no dm-multipath) and its _warn_once throttle is process-wide rather
    # than file-backed. BlockBase's equivalent has more to do; grepped for
    # rather than assumed (lesson 40a).
    eval { $HEALTH->forget($storeid) };

    return;
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
