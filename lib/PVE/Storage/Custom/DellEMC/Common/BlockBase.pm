# Dell EMC storage plugins for Proxmox VE - abstract block plugin base
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::BlockBase;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use Fcntl qw(:flock);
use POSIX ();

use PVE::Tools;
use PVE::INotify;

use PVE::Storage::Custom::DellEMC::Common::Naming;
use PVE::Storage::Custom::DellEMC::Common::Schema;
use PVE::Storage::Custom::DellEMC::Common::WwidState;
use PVE::Storage::Custom::DellEMC::Common::Health;
use PVE::Storage::Custom::DellEMC::Common::ISCSI qw(
    get_initiator_name
    probe_portal
    discover_targets
    login_target
    logout_target
    get_sessions
    get_session_states
    rescan_sessions
    is_portal_logged_in
);
use PVE::Storage::Custom::DellEMC::Common::FC qw(
    is_fc_available
    get_fc_targets
    rescan_fc_hosts
    normalize_wwn
);
use PVE::Storage::Custom::DellEMC::Common::Multipath qw(
    rescan_scsi_hosts
    rescan_scsi_device
    remove_scsi_device
    udev_refresh
    multipath_reload
    device_matches_wwid
    device_size_bytes
    multipath_resize_map
    get_multipath_device
    get_device_by_wwid
    wait_for_multipath_device
    get_multipath_slaves
    cleanup_lun_devices
    is_block_device
    is_device_in_use
    get_device_usage_details
    list_vendor_multipath_devices
    describe_wwid_state
    multipath_path_health
);

# Everything a Dell EMC block family plugin does that is not specific to one
# array's API. A family plugin subclasses this, implements the abstract
# _array_* methods, and is left with little more than its REST calls.
#
# See docs/ARCHITECTURE.md. The abstract methods are listed under
# "Abstract interface" below; each dies with the name of the class that failed
# to implement it.

# The storage API version this plugin claims.
#
# It has to be negotiated rather than hardcoded, because PVE treats the two
# directions very differently:
#
#   api() > PVE::Storage::APIVER          the plugin is REJECTED and every
#                                         storage of this type disappears from
#                                         the node
#   api() < APIVER - APIAGE               rejected as too old
#   api() != APIVER (but in range)        loads, and PVE warns "implementing an
#                                         older storage API" on every single
#                                         load of PVE::Storage — that is once
#                                         per pvesm call and per daemon start
#
# Proxmox VE 9 raised APIVER twice within the 9.1 point releases (13 -> 14 ->
# 15), so no single number is right everywhere. Claiming what the running PVE
# asks for, capped at the highest version whose changes are actually
# implemented here, is both quiet and safe: api() is only a load-time gate,
# and PVE calls plugin methods with its own current signatures regardless.
#
# Raise APIVERSION_MAX only after implementing that version's delta:
#   14  volume_resize gained a $snapname parameter (rejected here — this
#       plugin does not do snapshot-as-volume-chain)
#   15  get_identity()
use constant APIVERSION_MAX => 15;
use constant APIVERSION_MIN => 9;

# What to claim when PVE::Storage is not loaded at all, i.e. perl -c and the
# unit tests. Any value in range does; this is the version the plugin was
# first written against.
use constant APIVERSION_FALLBACK => 13;

use constant MIN_APIVERSION => APIVERSION_MIN;

# How many times a disk-id collision is worked around before giving up. Each
# attempt re-reads the array, so a worker only needs another round when it
# loses the race again; ten is far past what concurrent allocation for a
# single VM produces in practice.
use constant ALLOC_MAX_ATTEMPTS => 10;

# How long to wait for an array to report a resize it has accepted, before
# refreshing the host side regardless.
use constant RESIZE_SETTLE_TIMEOUT => 30;

# The VM-configuration backup volume, and the ceiling a device has to be under
# before this plugin will format it. The margin is generous on purpose: the
# check is there to catch "this is a 2 TB VM disk", not to police alignment.
use constant CONFIG_VOLUME_SIZE      => 1024 * 1024;
use constant CONFIG_VOLUME_MAX_BYTES => 64 * 1024 * 1024;

use constant MULTIPATH_CONF_DIR    => '/etc/multipath/conf.d';
use constant MULTIPATH_CONF_MARKER => 'dellemc-multipath-config-version: ';

my $NAMING     = 'PVE::Storage::Custom::DellEMC::Common::Naming';
my $WWID_STATE = 'PVE::Storage::Custom::DellEMC::Common::WwidState';
my $HEALTH     = 'PVE::Storage::Custom::DellEMC::Common::Health';

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

sub api {
    my $pve = eval {
        PVE::Storage->can('APIVER') ? PVE::Storage::APIVER() : undef;
    };

    return APIVERSION_FALLBACK unless defined $pve && $pve =~ /^\d+\z/;

    my $claim = $pve < APIVERSION_MAX ? $pve : APIVERSION_MAX;
    $claim = APIVERSION_MIN if $claim < APIVERSION_MIN;

    return $claim;
}

# The shared dell-* options live in Common::Schema, which also owns the rule
# that exactly one registered class may declare them: PVE dies with
# "duplicate property" otherwise, and that takes down every storage on the
# node. PowerFlex needs the same options without being a block plugin, which
# is why the registry is not in this class.
my $SCHEMA = 'PVE::Storage::Custom::DellEMC::Common::Schema';

sub properties {
    my ($class) = @_;
    return $SCHEMA->properties($class, $class->family_properties());
}

sub options {
    my ($class) = @_;
    return $SCHEMA->options($class->family_options());
}

sub common_properties { return $SCHEMA->common_properties() }
sub common_options    { return $SCHEMA->common_options() }

# Block families are raw-only and hold VM disks and container root
# filesystems. A family that is not block-based must not inherit this class.
sub plugindata {
    return {
        content => [ { images => 1, rootdir => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],

        # THIS is what PVE reads. Not the sensitive_properties method this
        # module used to define: PVE calls
        # PVE::Storage::Plugin::sensitive_properties($type) as a FUNCTION
        # with a type string, and it looks the answer up in plugindata. The
        # method was never called, so 'dell-password' never made the list,
        # and the array's password was written to /etc/pve/storage.cfg in
        # clear text - group-readable by www-data, replicated to every node,
        # and returned verbatim by GET /storage/<id>.
        #
        # Declared here, the password never reaches the config file: PVE
        # strips it from the parameters and hands it to on_add_hook, which
        # writes it to /etc/pve/priv/storage/<storeid>.pw at mode 0600 -
        # where PBS keeps its own.
        'sensitive-properties' => { 'dell-password' => 1 },
    };
}

# ---------------------------------------------------------------------------
# The array's password
#
# It lives in /etc/pve/priv, not in storage.cfg. /etc/pve/priv is 0700
# root:www-data - the web server cannot even enter it - while storage.cfg is
# readable by the www-data group and travels to every node.
# ---------------------------------------------------------------------------

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

# The storeid of the storage currently being worked on.
#
# $scfg does not carry it - PVE's storage config hash never has - and the
# _array_* contract passes it positionally in some methods and not at all in
# others, so the seventy _api($scfg, %opts) call sites in the families
# cannot all be given one. Rather than edit seventy call sites and hope,
# every entry point that HAS the storeid announces it here, and _password
# reads it back. One place to set, one place to read.
#
# Localised per operation, not stored: a forked PVE worker must not inherit
# a stale one, and nothing here is long-lived enough to cache.
our $CURRENT_STOREID;

sub _with_storeid {
    my ($class, $storeid, $code) = @_;

    local $CURRENT_STOREID = $storeid;

    return $code->();
}

# The password for a storage, wherever it is.
#
# The priv file first, then the config - because a storage created before
# this changed still carries it in storage.cfg, and refusing those would
# take working storages offline on upgrade. Such a storage is told, once an
# hour, how to move its password out of the config file.
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
      . " replicated to every node. Storages created before this version"
      . " keep working, but to move it into /etc/pve/priv run:\n"
      . "    pvesm set " . ($storeid // '<storeid>')
      . " --dell-password '<the password>'")
        if defined $storeid && length $storeid;

    return $legacy;
}

sub get_identity {
    my ($class, $scfg, $storeid) = @_;
    local $CURRENT_STOREID = $storeid;
    return join(':', $class->type(), _identity_portal($scfg),
        $class->identity_suffix($scfg));
}

# The management addresses, as a SET rather than as the string someone typed.
#
# 'dell-portal' became a comma-separated list in 0.7.75, for the arrays whose
# controllers each have their own management IP. The same array can then be
# written several ways — the two controllers in either order, with or without
# spaces, and one storage listing both where another lists one — and an
# identity built from the string verbatim calls those different storages.
# What get_identity answers is whether two storages are the same thing, so it
# has to be the thing and not its spelling.
sub _identity_portal {
    my ($scfg) = @_;

    my @portals = grep { length }
                  map  { lc(s/^\s+|\s+\z//gr) }
                  split /,/, $scfg->{'dell-portal'} // '';

    return join(',', sort @portals);
}

# Families add whatever else pins a storage to one array, e.g. the appliance.
sub identity_suffix { return '' }

# ---------------------------------------------------------------------------
# Abstract interface
#
# A family plugin must implement each of these. They receive plain arguments
# rather than an API handle so the family decides how to reach its array.
# ---------------------------------------------------------------------------

sub _abstract {
    my ($class, $method) = @_;
    $class = ref($class) || $class;
    die "$class must implement $method()\n";
}

sub type                { $_[0]->_abstract('type') }
sub family_properties   { return {} }
sub family_options      { return {} }

# Naming class for this family; override to narrow the name limits.
sub naming              { return $NAMING }

# Vendor and product strings for the multipath device block, and the
# family's recommended multipath settings.
sub multipath_vendor    { $_[0]->_abstract('multipath_vendor') }
sub multipath_product   { $_[0]->_abstract('multipath_product') }
sub multipath_defaults  { $_[0]->_abstract('multipath_defaults') }

# Bumped by a family whenever its multipath block changes, so an existing
# plugin-written drop-in is rewritten.
sub multipath_config_version { return 1 }

# May this family spend one extra volume per snapshot on a copy of the VM
# configuration?
#
# It is a real cost, not a rounding error: every snapshot of a VM creates an
# additional small volume, so a family whose volume or snapshot count is the
# binding limit cannot afford it. Such a family returns 0 here and the
# feature is never offered, whatever dell-config-backup says.
sub supports_config_backup { return 1 }

# Is the config backup actually in use for this storage?
sub _config_backup_enabled {
    my ($class, $scfg) = @_;

    return 0 unless $class->supports_config_backup();

    my $value = $scfg->{'dell-config-backup'};

    return defined $value ? ($value ? 1 : 0) : 1;
}

# Cheap reachability check for the health path. Must die on failure.
sub _array_ping         { $_[0]->_abstract('_array_ping') }

# ($total, $used, $avail) in bytes.
sub _array_get_capacity { $_[0]->_abstract('_array_get_capacity') }

sub _array_get_volume    { $_[0]->_abstract('_array_get_volume') }
sub _array_list_volumes  { $_[0]->_abstract('_array_list_volumes') }
sub _array_create_volume { $_[0]->_abstract('_array_create_volume') }
sub _array_delete_volume { $_[0]->_abstract('_array_delete_volume') }
sub _array_resize_volume { $_[0]->_abstract('_array_resize_volume') }
sub _array_rename_volume { $_[0]->_abstract('_array_rename_volume') }
sub _array_get_wwid      { $_[0]->_abstract('_array_get_wwid') }

sub _array_snapshot_create   { $_[0]->_abstract('_array_snapshot_create') }
sub _array_snapshot_delete   { $_[0]->_abstract('_array_snapshot_delete') }
sub _array_snapshot_list     { $_[0]->_abstract('_array_snapshot_list') }
sub _array_snapshot_get      { $_[0]->_abstract('_array_snapshot_get') }
sub _array_snapshot_rollback { $_[0]->_abstract('_array_snapshot_rollback') }
sub _array_clone             { $_[0]->_abstract('_array_clone') }

sub _array_ensure_host   { $_[0]->_abstract('_array_ensure_host') }
sub _array_list_hosts    { $_[0]->_abstract('_array_list_hosts') }
sub _array_map_to_host   { $_[0]->_abstract('_array_map_to_host') }
sub _array_unmap_from_host { $_[0]->_abstract('_array_unmap_from_host') }
sub _array_is_mapped     { $_[0]->_abstract('_array_is_mapped') }
sub _array_mapped_hosts  { $_[0]->_abstract('_array_mapped_hosts') }

# [ { portal => 'ip:port', iqn => '...' }, ... ]
sub _array_get_portals   { $_[0]->_abstract('_array_get_portals') }

# ---------------------------------------------------------------------------
# Configuration accessors
# ---------------------------------------------------------------------------

sub _opt {
    my ($class, $scfg, $name, $default) = @_;
    my $value = $scfg->{"dell-$name"};
    return defined $value ? $value : $default;
}

sub _protocol         { $_[0]->_opt($_[1], 'protocol', 'iscsi') }
sub _host_mode        { $_[0]->_opt($_[1], 'host-mode', 'per-node') }
sub _cluster_name     { $_[0]->_opt($_[1], 'cluster-name', 'pve') }
sub _device_timeout   { $_[0]->_opt($_[1], 'device-timeout', 60) }
sub _probe_timeout    { $_[0]->_opt($_[1], 'portal-probe-timeout', 2) }
sub _status_timeout   { $_[0]->_opt($_[1], 'status-timeout', 5) }
sub _activate_deadline { $_[0]->_opt($_[1], 'activate-deadline', 30) }
sub _config_backup_timeout { $_[0]->_opt($_[1], 'config-backup-timeout', 15) }
sub _rescan_interval  { $_[0]->_opt($_[1], 'rescan-interval', 300) }

sub _is_fc { my ($class, $scfg) = @_; return $class->_protocol($scfg) eq 'fc' ? 1 : 0 }

# The name this plugin GENERATES for this node's host object.
sub _generated_host_name {
    my ($class, $scfg) = @_;

    my $cluster = $class->_cluster_name($scfg);

    return $class->naming->encode_host_name($cluster, undef)
        if $class->_host_mode($scfg) eq 'shared';

    return $class->naming->encode_host_name($cluster, PVE::INotify::nodename());
}

# Where this node records the host object it resolved to, when that is not the
# generated name.
#
# Node-local on purpose: a host object represents ONE node, so this is not
# cluster state and must not be replicated. It is written only after the array
# has confirmed the object holds this node's initiators and nothing else's.
sub _resolved_host_file {
    my ($class, $storeid) = @_;
    return $WWID_STATE->state_dir . '/'
         . $WWID_STATE->safe_storeid($storeid) . '-host';
}

sub _record_resolved_host {
    my ($class, $storeid, $name) = @_;

    return 0 unless defined $storeid && length $storeid;
    return 0 unless defined $name && length $name;

    eval { $WWID_STATE->ensure_dirs };
    my $file = $class->_resolved_host_file($storeid);
    my $tmp  = "$file.tmp.$$";

    open(my $fh, '>', $tmp) or return 0;
    print {$fh} "$name\n";
    close($fh);

    rename($tmp, $file) or do { unlink($tmp); return 0 };

    return 1;
}

sub _forget_resolved_host {
    my ($class, $storeid) = @_;
    return unless defined $storeid && length $storeid;
    unlink($class->_resolved_host_file($storeid));
    return;
}

# The recorded name, or undef. Validated on the way out: this ends up in a
# request to the array, and a state file is something an operator can edit.
sub _resolved_host_name {
    my ($class, $storeid) = @_;

    return undef unless defined $storeid && length $storeid;

    open(my $fh, '<', $class->_resolved_host_file($storeid)) or return undef;
    my $name = <$fh>;
    close($fh);

    return undef unless defined $name;
    chomp $name;

    # The match returns the value, so a wrong file fails as "nothing recorded"
    # rather than travelling into a request (rule 36).
    return undef unless $name =~ /\A([A-Za-z0-9][A-Za-z0-9._\-]{0,126})\z/;

    return $1;
}

# Where every node publishes the host object it resolved to.
#
# _map_to_all_hosts pre-maps a new volume to the other nodes' hosts so that a
# migration does not have to wait for a mapping, and it finds them by the
# 'pve-<cluster>-' prefix this plugin's own names carry. A node whose host was
# ADOPTED — because the array already had one for it under another name — is
# invisible to that search, and a customer saw exactly that: a new disk mapped
# to the node that created it and to nothing else.
#
# So each node writes the name it resolved to where the others can read it.
# One file per node, in the cluster filesystem: a node only ever writes its
# own, so there is no lock and no race. It is not a secret, but /etc/pve/priv
# is where this plugin already keeps per-storage files and it is root-only,
# which is the safer default.
sub _published_host_file {
    my ($class, $storeid, $node) = @_;

    $node //= eval { PVE::INotify::nodename() } // 'unknown';
    $node =~ s/[^A-Za-z0-9._-]/_/g;

    return '/etc/pve/priv/storage/dellemc-'
         . $WWID_STATE->safe_storeid($storeid) . "-host-$node";
}

sub _publish_resolved_host {
    my ($class, $storeid, $name) = @_;

    return 0 unless defined $storeid && length $storeid;
    return 0 unless defined $name && length $name;

    my $file = $class->_published_host_file($storeid);

    # Unchanged is the common case, by a long way: this runs on the throttled
    # host-ensure path. Reading first keeps a cluster-filesystem write off it.
    my $current = eval { PVE::Tools::file_get_contents($file) };
    if (defined $current) {
        chomp $current;
        return 1 if $current eq $name;
    }

    eval { File::Path::make_path('/etc/pve/priv/storage') };
    eval { PVE::Tools::file_set_contents($file, "$name\n") };

    return $@ ? 0 : 1;
}

# Every node's resolved host name, this one included.
sub _published_hosts {
    my ($class, $storeid) = @_;

    return [] unless defined $storeid && length $storeid;

    my $pattern = '/etc/pve/priv/storage/dellemc-'
                . $WWID_STATE->safe_storeid($storeid) . '-host-*';

    my @names;
    for my $file (glob($pattern)) {
        my $value = eval { PVE::Tools::file_get_contents($file) };
        next unless defined $value;
        chomp $value;
        # The match returns the name, so a file someone edited fails as
        # "nothing published" rather than travelling into a request.
        next unless $value =~ /\A([A-Za-z0-9][A-Za-z0-9._\-]{0,126})\z/;
        push @names, $1;
    }

    my %seen;
    return [ grep { !$seen{$_}++ } @names ];
}

sub _unpublish_resolved_host {
    my ($class, $storeid) = @_;
    return unless defined $storeid && length $storeid;
    unlink($class->_published_host_file($storeid));
    return;
}

# Host object name for this node, or the cluster-wide one in shared mode.
#
# An array often already has a host object for this node, built by whatever
# tool set the fabric up, holding exactly this node's initiators under a name
# of its own. The initiators cannot be registered twice — PowerStore refuses
# outright — so the choice is to use that object or to have the operator take
# it apart. _array_ensure_host resolves which object this node really is and
# records it here; everything that maps, unmaps or asks about a mapping goes
# through this method, so the answer follows.
sub _host_name {
    my ($class, $scfg, $storeid) = @_;

    $storeid = $CURRENT_STOREID unless defined $storeid && length $storeid;

    my $recorded = $class->_resolved_host_name($storeid);
    return $recorded if defined $recorded;

    return $class->_generated_host_name($scfg);
}

# Array object name for a PVE volume name.
sub _array_volname {
    my ($class, $storeid, $volname) = @_;
    return $class->naming->pve_volname_to_array($storeid, $volname);
}

# ---------------------------------------------------------------------------
# Volume name parsing
# ---------------------------------------------------------------------------

sub _parse_volname {
    my ($class, $volname) = @_;

    return undef unless defined $volname;
    $volname =~ s|^images/||;

    # Linked clone: base-100-disk-0/vm-101-disk-0
    if ($volname =~ m|^(base-(\d+)-disk-(\d+))/(vm-(\d+)-disk-(\d+))\z|) {
        return {
            vmid => $5, diskid => $6, format => 'raw', type => 'disk',
            isBase => 0, basename => $1, basevmid => $2, leafname => $4,
        };
    }
    if ($volname =~ /^vm-(\d+)-disk-(\d+)\z/) {
        return { vmid => $1, diskid => $2, format => 'raw', type => 'disk', isBase => 0 };
    }
    if ($volname =~ /^base-(\d+)-disk-(\d+)\z/) {
        return { vmid => $1, diskid => $2, format => 'raw', type => 'disk', isBase => 1 };
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-cloudinit\z/) {
        return { vmid => $1, format => 'raw', type => 'cloudinit', isBase => 0 };
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-efi-enroll\z/) {
        return { vmid => $1, format => 'raw', type => 'efienroll', isBase => 0 };
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-fleece-(\d+)\z/) {
        return { vmid => $1, diskid => $2, format => 'raw', type => 'fleece', isBase => 0 };
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-state-(.+)\z/) {
        return { vmid => $1, snapname => $2, format => 'raw', type => 'state', isBase => 0 };
    }

    return undef;
}

# ('images', $name, $vmid, $basename, $basevmid, $isBase, $format)
#
# $name is the LEAF name, not the volname. For a linked clone the volname is
# 'base-100-disk-0/vm-101-disk-0' and $name is 'vm-101-disk-0', which is what
# RBD and every other plugin using this two-part form return. PVE builds a
# target volume name out of $name when a disk moves to a storage of another
# type: 'base-100-disk-0/vm-101-disk-0' as a name there would name a base
# image that does not exist on the target, so moving a linked clone off this
# storage would fail with a message about the wrong volume.
# The ownership gate, in front of every destructive array call.
#
# Nothing should reach a delete with a name this storage did not generate:
# array names are built by pve_volname_to_array from the storage's own
# prefix, so a foreign one cannot normally be produced. This is the check
# that says so out loud, on the argument actually being passed, at the moment
# it is about to be acted on.
#
# The storeid is not optional. The two-argument form only proves the name
# looks like SOME PVE plugin's, which does not authorise deleting it — a
# second storage on the same array, or another cluster, produces names of
# exactly that shape.
#
# It is called on $class->naming, so each family's own separators and limits
# apply rather than the base class's.
sub _assert_own_object {
    my ($class, $storeid, $name, $what) = @_;

    return 1 if $class->naming->is_pve_managed_volume($name, $storeid);

    die "Refusing to $what '" . (defined $name ? $name : '(undef)')
      . "': it is not an object storage '" . (defined $storeid ? $storeid : '?')
      . "' created. This plugin only ever deletes objects whose names it"
      . " generated itself; something has gone wrong upstream of here.\n";
}

sub parse_volname {
    my ($class, $volname) = @_;

    my $parsed = $class->_parse_volname($volname);
    die "unable to parse volume name '$volname'\n" unless $parsed;

    my $name = $parsed->{leafname} // $volname;

    if ($parsed->{type} eq 'disk') {
        return (
            'images', $name, $parsed->{vmid},
            $parsed->{basename}, $parsed->{basevmid},
            $parsed->{isBase} ? 1 : 0, 'raw',
        );
    }

    return ('images', $name, $parsed->{vmid}, undef, undef, 0, 'raw');
}

# Lowest disk id not already used by this VM on this storage.
sub _find_free_diskid {
    my ($class, $scfg, $storeid, $vmid) = @_;

    my $prefix = $class->naming->volume_prefix($storeid) . "${vmid}-";
    my $volumes = eval { $class->_array_list_volumes($scfg, $storeid, $prefix) } // [];

    my %used;
    for my $vol (@$volumes) {
        next unless $vol->{name};
        my $decoded = $class->naming->decode_volume_name($vol->{name});
        next unless $decoded && defined $decoded->{diskid};
        next unless $decoded->{vmid} == $vmid;
        next unless $decoded->{type} eq 'disk';
        $used{$decoded->{diskid}} = 1;
    }

    for my $id (0 .. 999) {
        return $id unless $used{$id};
    }

    die "No free disk id for VM $vmid on storage '$storeid'\n";
}

sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;

    my $diskid = $class->_find_free_diskid($scfg, $storeid, $vmid);

    return "vm-${vmid}-disk-${diskid}";
}

# ---------------------------------------------------------------------------
# Multipath configuration
#
# The drop-in carries a version marker. A file we wrote and that is out of
# date gets rewritten; a file WITHOUT the marker was written by the operator
# or another tool and is never touched, whatever it contains.
# ---------------------------------------------------------------------------

sub _multipath_config_file {
    my ($class) = @_;
    my $name = lc($class->type());
    return MULTIPATH_CONF_DIR . "/${name}.conf";
}

sub _multipath_config_content {
    my ($class) = @_;

    my $defaults = $class->multipath_defaults();
    my $body = '';
    for my $key (sort keys %$defaults) {
        my $value = $defaults->{$key};
        # Quote anything with whitespace, as multipath.conf requires.
        $value = "\"$value\"" if $value =~ /\s/ && $value !~ /^"/;
        $body .= sprintf("        %-20s %s\n", $key, $value);
    }

    my $vendor  = $class->multipath_vendor();
    my $product = $class->multipath_product();

    return "# " . MULTIPATH_CONF_MARKER . $class->multipath_config_version() . "\n"
        . "# Written by jt-pve-storage-dellemc. Remove the version marker above\n"
        . "# to take ownership of this file; the plugin then leaves it alone.\n"
        . "devices {\n"
        . "    device {\n"
        . sprintf("        %-20s \"%s\"\n", 'vendor', $vendor)
        . sprintf("        %-20s \"%s\"\n", 'product', $product)
        . $body
        . "    }\n"
        . "}\n";
}

sub _ensure_multipath_config {
    my ($class) = @_;

    my $file = $class->_multipath_config_file();
    my $dir  = MULTIPATH_CONF_DIR;

    unless (-d $dir) {
        # No conf.d means a multipath-tools too old to have it, or a system
        # where the operator manages one monolithic file. Either way, do not
        # start editing /etc/multipath.conf behind their back.
        return 0;
    }

    my $wanted = $class->_multipath_config_content();

    if (-f $file) {
        my $existing = '';
        if (open(my $fh, '<', $file)) {
            local $/;
            $existing = <$fh> // '';
            close($fh);
        }

        # No marker: operator-owned, leave it exactly as it is.
        return 0 unless $existing =~ /\Q@{[ MULTIPATH_CONF_MARKER ]}\E(\d+)/;

        my $have = $1;
        return 1 if $have == $class->multipath_config_version();
        return 1 if $existing eq $wanted;

        warn "Upgrading plugin-managed multipath configuration $file from"
           . " version $have to version " . $class->multipath_config_version() . "\n";
    }

    my $tmp = "$file.tmp.$$";
    my $ok = eval {
        open(my $fh, '>', $tmp) or die "Cannot write $tmp: $!\n";
        print $fh $wanted;
        close($fh) or die "Cannot close $tmp: $!\n";
        rename($tmp, $file) or die "Cannot rename $tmp to $file: $!\n";
        1;
    };
    unless ($ok) {
        warn "Failed to write multipath configuration $file: $@";
        unlink($tmp);
        return 0;
    }

    warn "Wrote multipath configuration $file\n";

    # The one place a host-wide reconfigure is justified: multipathd has no
    # per-file reload, so a drop-in it has not read is a drop-in that does
    # nothing. This runs only when the file's content actually changed —
    # install, upgrade, a version bump — and never on a poll. Say so, because
    # a reconfigure reapplies configuration to every map on the node,
    # including storage this plugin has nothing to do with.
    warn "Asking multipathd to re-read its configuration. This is node-wide;"
       . " it is the only way to make a new drop-in take effect, and it"
       . " happens only when $file changes.\n";
    eval { multipath_reload() };

    return 1;
}

# ---------------------------------------------------------------------------
# Storage activation
# ---------------------------------------------------------------------------

# Wall clock of the last periodic rescan, per storeid. Process-wide on
# purpose: pvestatd is long-lived, so this is what actually bounds the rate.
my %LAST_RESCAN;

sub _should_rescan {
    my ($class, $storeid, $scfg, $forced) = @_;

    return 1 if $forced;

    my $interval = $class->_rescan_interval($scfg);
    return 1 if $interval <= 0;

    my $last = $LAST_RESCAN{$storeid};
    my $now  = time();

    # Never rescanned, or the clock stepped backwards (NTP correction): due.
    # Otherwise a single backwards jump would suppress every rescan until the
    # skew had been lived through.
    return 1 unless defined $last;
    return 1 if $now < $last;

    return ($now - $last) >= $interval ? 1 : 0;
}

# $when exists so a test can place the timestamp; callers pass the default.
sub _mark_rescan {
    my ($class, $storeid, $when) = @_;
    $LAST_RESCAN{$storeid} = $when // time();
    return;
}

sub _rescan_transport {
    my ($class, $scfg, %opts) = @_;

    if ($class->_is_fc($scfg)) {
        eval { rescan_fc_hosts(delay => $opts{delay} // 1) };
        warn "FC rescan failed: $@" if $@;
    } else {
        eval { rescan_sessions() };
        warn "iSCSI session rescan failed: $@" if $@;
    }

    return;
}

# Rescan hooks handed to wait_for_multipath_device, so its escalation ladder
# can retry the transport between probes.
sub _wait_opts {
    my ($class, $scfg, %opts) = @_;

    my %wait = (timeout => $opts{timeout} // $class->_device_timeout($scfg));

    if ($class->_is_fc($scfg)) {
        $wait{fc_rescan} = sub { rescan_fc_hosts(delay => 1) };
    } else {
        $wait{iscsi_rescan} = sub { rescan_sessions() };
    }

    return %wait;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

    # dell-protocol is shared with PowerFlex, whose values mean nothing to a
    # SAN family. Rejecting it here beats letting it fall through to the
    # iSCSI path and failing with something unrelated.
    my $protocol = $class->_protocol($scfg);
    die "Storage '$storeid' is a " . $class->type() . " storage, which speaks"
      . " iSCSI or Fibre Channel. 'dell-protocol $protocol' belongs to the"
      . " PowerFlex family; use 'iscsi' or 'fc'.\n"
        unless $protocol eq 'iscsi' || $protocol eq 'fc';

    # This runs on the pvestatd health path: single attempt, short timeout.
    eval { $class->_array_ping($scfg, status => 1, storeid => $storeid) };
    if ($@) {
        my $err = $@;
        # PVE calls activate_storage before status() and never reaches
        # status() if this dies — which is precisely what an unreachable array
        # does. Recording only in status() would mean recording nothing at all
        # for the outages that matter most.
        my $already_down = eval { $HEALTH->is_down($storeid) } ? 1 : 0;
        eval { $HEALTH->record_status_failure($storeid, $err) };

        # PVE logs whatever this dies with, on every poll — about every ten
        # seconds, per node, for as long as the outage lasts. The first
        # failures carry the array's own answer, because that is the
        # diagnosis; once the outage is on record the message is one line, so
        # a long outage does not bury everything else in the journal. Measured
        # on this node: 297 characters, six times in a minute, against one
        # throttled OUTAGE line carrying the same facts.
        #
        # Rule 35 applies to a warn on this path. A die is PVE's to log, so
        # the only lever is how much it is handed.
        die "Storage '$storeid' is unreachable at "
          . ($scfg->{'dell-portal'} // '?')
          . "; see the OUTAGE record in this log for the array's answer.\n"
            if $already_down;

        die "Cannot reach the array at " . ($scfg->{'dell-portal'} // '?')
          . " for storage '$storeid': $err";
    }

    if ($class->_is_fc($scfg)) {
        $class->_activate_fc($storeid, $scfg);
    } else {
        $class->_activate_iscsi($storeid, $scfg);
    }

    # The multipath drop-in is written only AFTER the protocol activation
    # succeeded. Writing it triggers the one permitted node-wide 'multipathd
    # reconfigure', and doing that first meant a storage about to be REFUSED
    # — an FC storage on a node with no HBA, an iSCSI storage whose portals
    # this node cannot reach — had already reconfigured every vendor's maps
    # on a shared node and left this plugin's drop-in behind, for a storage
    # that never came to exist. Found by running 'pvesm add' end-to-end
    # against an API emulator on a node that could not serve either
    # protocol.
    #
    # Nothing in the activation NEEDS the drop-in. On iSCSI a login can
    # surface previously-mapped LUNs a moment before this line runs, but the
    # reconfigure that follows the first write reapplies the settings to
    # maps that already formed, and the kernel's own built-in table covers
    # these vendors' devices meanwhile - so the late write costs nothing.
    $class->_ensure_multipath_config();

    $class->_ensure_host_throttled($storeid, $scfg);

    return 1;
}

# Host registration, at most once per HOST_CHECK_INTERVAL per storage.
#
# activate_storage runs on every pvestatd poll, roughly every ten seconds per
# node. Re-checking the host object that often is one extra array round trip
# per poll on PowerStore and a full `show host-groups` on PowerVault, and any
# family whose "is this initiator already attached" check is imprecise would
# reissue the attach six times a minute. A failure is not cached: the next
# activation retries immediately.
my %LAST_HOST_CHECK;
use constant HOST_CHECK_INTERVAL => 300;

sub _ensure_host_throttled {
    my ($class, $storeid, $scfg) = @_;

    my $now  = time();
    my $last = $LAST_HOST_CHECK{$storeid};

    my $due = !defined($last) || $now < $last
        || ($now - $last) >= HOST_CHECK_INTERVAL;

    return 1 unless $due;

    $class->_array_ensure_host($scfg, $storeid);
    $LAST_HOST_CHECK{$storeid} = $now;

    return 1;
}

sub _activate_fc {
    my ($class, $storeid, $scfg) = @_;

    die "Protocol 'fc' is configured but this node has no FC HBA. Install an"
      . " HBA, or set 'dell-protocol iscsi' on storage '$storeid'.\n"
        unless is_fc_available();

    # There is no login step on FC, so the interval is the only gate on the
    # periodic safety-net rescan.
    if ($class->_should_rescan($storeid, $scfg, 0)) {
        $class->_mark_rescan($storeid);
        eval { rescan_fc_hosts(delay => 1) };
        eval { rescan_scsi_hosts(delay => 1) };
        # No 'multipathd reconfigure' here. It is host-wide — it reapplies
        # configuration to every map on the node, another vendor's storage
        # included — and this runs on a timer whether or not anything changed.
        # udev claims new paths on its own; a device that still has not
        # appeared is dealt with, by name, in wait_for_multipath_device.
        udev_refresh();
    }

    # activate_storage runs every ~10s per node per storage, so an
    # unconditional warn on a condition that persists is a line every ten
    # seconds in the journal — which buries whatever else is being logged.
    # Once an hour says the same thing and can still be found.
    my $targets = eval { get_fc_targets() } // [];
    my @online = grep { $_->{is_target} && ($_->{port_state} // '') =~ /online/i } @$targets;

    unless (@online) {
        # Say what was seen, not just what was not. "No target ports" with
        # nothing visible at all points at zoning; the same words with ports
        # visible but offline or in the wrong role point somewhere else
        # entirely, and an operator should not have to guess which they have.
        my $seen = scalar(@$targets)
            ? scalar(@$targets) . " remote port(s) are visible but none is an"
              . " online target"
            : "no remote ports are visible at all";

        $class->_warn_once($storeid, 'fc-no-targets',
            "No FC target ports are visible from this node for storage"
          . " '$storeid': $seen. Check fabric zoning between this host and"
          . " the array, and 'cat /sys/class/fc_host/host*/port_state'.");
    }

    return 1;
}

sub _activate_iscsi {
    my ($class, $storeid, $scfg) = @_;

    my $portals = eval {
        $class->_array_get_portals($scfg, status => 1, storeid => $storeid)
    } // [];
    unless (@$portals) {
        die "The array returned no iSCSI target portals for storage"
          . " '$storeid'. Verify that iSCSI is configured on the appliance and"
          . " that at least one target IP is published.\n";
    }

    my $probe_timeout = $class->_probe_timeout($scfg);
    my $deadline      = $class->_activate_deadline($scfg);
    my $loop_start    = time();

    my (@logged_in, @unreachable, @failed, @deferred);
    my $forced_rescan = 0;

    # One snapshot of the session list for the whole loop. Checking per portal
    # would be one unbounded external command per portal, none of them covered
    # by the wall-clock budget below.
    my $sessions = eval { get_sessions() } // [];

    for my $portal (@$portals) {
        my $address = $portal->{portal} or next;
        my $target  = $portal->{iqn} or next;

        my ($ip, $port) = split(/:/, $address);
        $port //= 3260;
        my $addr = "$ip:$port";

        # Already logged in: skip discovery and login entirely. Discovery
        # alone can take 30s per portal and this runs on every activation.
        if (is_portal_logged_in($addr, $target, $sessions)) {
            push @logged_in, $addr;
            next;
        }

        # Per-portal timeouts bound each portal but not the loop. Once the
        # budget is spent and at least one path is up, defer the rest. Checked
        # at the top of the iteration so it never interrupts a login in
        # progress, and never applied while zero paths are up — with no path
        # the storage must fail honestly rather than report success.
        if ($deadline > 0 && @logged_in && (time() - $loop_start) >= $deadline) {
            push @deferred, $addr;
            next;
        }

        if ($probe_timeout > 0 && !probe_portal($ip, $port, timeout => $probe_timeout)) {
            push @unreachable, $addr;
            next;
        }

        eval {
            discover_targets($ip, port => $port);
            login_target($ip, $target, port => $port, sessions => $sessions);
        };
        if ($@) {
            push @failed, "$addr ($@)";
            warn "Failed to log in to iSCSI portal $addr: $@";
        } else {
            push @logged_in, $addr;
            $forced_rescan = 1;
        }
    }

    warn "Skipped " . scalar(@unreachable) . " unreachable iSCSI portal(s) for"
       . " storage '$storeid': " . join(', ', @unreachable)
       . " (no TCP response within ${probe_timeout}s). Check network paths and"
       . " switch zoning, or disable unused iSCSI ports on the array.\n"
        if @unreachable;

    warn "Deferred login to " . scalar(@deferred) . " iSCSI portal(s) for"
       . " storage '$storeid': " . join(', ', @deferred) . ". The"
       . " activate_storage budget of ${deadline}s was spent with "
       . scalar(@logged_in) . " path(s) already up; they will be retried on a"
       . " later activation. Raise 'dell-activate-deadline' if they should"
       . " already be reachable.\n"
        if @deferred;

    unless (@logged_in) {
        my $msg = "No iSCSI portal of storage '$storeid' is reachable from this node.";
        $msg .= " Unreachable: " . join(', ', @unreachable) if @unreachable;
        $msg .= " Failed: " . join('; ', @failed) if @failed;
        $msg .= "\n  Verify network connectivity to the array's iSCSI ports, or"
              . " restrict the storage with 'pvesm set $storeid --nodes <list>'"
              . " to the nodes that can reach it.";
        die "$msg\n";
    }

    if ($class->_should_rescan($storeid, $scfg, $forced_rescan)) {
        $class->_mark_rescan($storeid);
        eval { rescan_sessions() };
        eval { rescan_scsi_hosts(delay => 1) };
        # Host-wide reconfigure deliberately absent; see _activate_fc.
        udev_refresh();
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

    my $prefix  = $class->naming->volume_prefix($storeid);
    my $volumes = eval { $class->_array_list_volumes($scfg, $storeid, $prefix) } // [];

    my $host = $class->_host_name($scfg);
    my @in_use;

    for my $vol (@$volumes) {
        next unless $vol->{name};

        my $wwid = $vol->{wwid} // eval { $class->_array_get_wwid($scfg, $vol->{name}) };
        next unless $wwid;

        # Never tear down a device a running VM is still using — and treat
        # "could not tell" the same way. This unmaps the volume as well as
        # removing the local devices, so a wrong "free" takes the disk away
        # from a guest that is still writing to it.
        # The in-use answer is only worth as much as the device it was asked
        # about. A device the kernel will not confirm is one we cannot ask —
        # and this is a loop over every volume, so it is skipped rather than
        # dying and taking the rest of the deactivation with it.
        my $device = eval { get_device_by_wwid($wwid) };
        $device = undef unless $device && is_block_device($device);

        if ($device && !device_matches_wwid($device, $wwid)) {
            push @in_use, $vol->{name} . ' (device could not be confirmed)';
            next;
        }

        if ($device) {
            my $in_use = is_device_in_use($device);
            if (!defined($in_use) || $in_use) {
                push @in_use, $vol->{name}
                    . (defined($in_use) ? '' : ' (in-use state unknown)');
                next;
            }
        }

        eval { cleanup_lun_devices($wwid) };
        warn "Failed to clean up devices for $vol->{name}: $@" if $@;

        eval { $class->_array_unmap_from_host($scfg, $vol->{name}, $host) };
    }

    warn "Left " . scalar(@in_use) . " in-use volume(s) mapped on storage"
       . " '$storeid': " . join(', ', @in_use) . ". Stop the VMs using them"
       . " before deactivating the storage.\n" if @in_use;

    # No global multipath flush here, ever: that would remove maps belonging
    # to other storages on this node. The per-volume cleanup above already
    # removed ours.

    return 1;
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

    my ($total, $used, $avail);

    eval {
        # Health path: short timeout, single attempt.
        ($total, $used, $avail) =
            $class->_array_get_capacity($scfg, status => 1, storeid => $storeid);
    };
    if ($@) {
        my $err = $@;
        $HEALTH->record_status_failure($storeid, $err);
        return (0, 0, 0, 0);
    }

    $avail //= ($total // 0) - ($used // 0);
    $HEALTH->record_status_ok($storeid, $total, $used, scope => $class->capacity_scope($scfg));

    $class->_spawn_background_reaper($storeid, $scfg);

    return ($total, $avail, $used, 1);
}

# What the capacity figures describe, for the operator-facing message.
sub capacity_scope { return 'array' }

# Run the orphan reaper detached, so status() never waits for it.
#
# Double fork: the intermediate child forks the worker and exits at once, so
# the worker is reparented to init and reaped there. status() waits only for
# the intermediate.
sub _spawn_background_reaper {
    my ($class, $storeid, $scfg) = @_;

    my $intermediate = fork();
    return unless defined $intermediate;

    if ($intermediate == 0) {
        my $worker = fork();
        if (defined $worker && $worker == 0) {
            # One pass per storage at a time. status() forks a pass on every
            # poll (~10s) and a pass over a large array can take longer than
            # that, so without this guard passes would stack and multiply both
            # REST load and block-layer work. A non-blocking lock makes the
            # overlapping poll skip instead. It is released when this process
            # exits, including on a crash, so it cannot wedge.
            my $lock_fh;
            my $locked = 0;
            if (open($lock_fh, '>', $WWID_STATE->cleanup_lock_file($storeid))) {
                $locked = flock($lock_fh, LOCK_EX | LOCK_NB);
            }
            if ($locked) {
                # Detached from the pvestatd critical path, so this uses the
                # resilient client rather than the health one.
                eval { $class->_cleanup_orphaned_devices($storeid, $scfg) };
            }
            POSIX::_exit(0);
        }
        POSIX::_exit(0);
    }

    waitpid($intermediate, 0);

    return;
}

# Remove local devices for volumes that no longer exist on the array.
#
# Phase 1 imports the WWIDs the array still has, which is how this node learns
# about volumes created on another node. Phase 2 tears down tracked WWIDs the
# array no longer reports, but only once the grace period and the miss
# threshold both agree and the device is idle. Phase 3 reports — never
# removes — our-vendor devices that are neither tracked nor on the array.
sub _cleanup_orphaned_devices {
    my ($class, $storeid, $scfg) = @_;

    my $prefix = $class->naming->volume_prefix($storeid);

    my $volumes = eval { $class->_array_list_volumes($scfg, $storeid, $prefix) };
    if ($@) {
        # Acting on a failed listing would treat every volume as deleted.
        warn "orphan cleanup: array query failed, skipping this pass: $@";
        return;
    }
    $volumes //= [];

    # Built ONLY from what the list call already returned. This runs in the
    # background of every status() poll on every node, so a per-volume query
    # here would be (volumes x nodes) requests every ten seconds against the
    # array's management interface — the shape that collapses a management
    # gateway once an array is big enough or its firmware less forgiving.
    my %alive;
    my $without_wwid = 0;
    for my $vol (@$volumes) {
        next unless $vol->{name};
        if (my $wwid = $vol->{wwid}) {
            $alive{lc($wwid)} = 1;
        } else {
            $without_wwid++;
        }
    }

    # An empty alive set with volumes present means the listing did not carry
    # WWIDs, not that every volume vanished. Acting on it would count every
    # tracked device as missing and eventually tear down devices a running VM
    # is using, so the pass is abandoned instead.
    if (@$volumes && !%alive) {
        $class->_warn_once($storeid, 'no-wwids',
            "orphan cleanup: the array listed " . scalar(@$volumes) . " volume(s)"
          . " for storage '$storeid' but none carried a WWID, so stale devices"
          . " cannot be identified. Skipping cleanup rather than guessing."
          . " This means the volume listing is not returning the field the"
          . " plugin reads the WWID from; see docs/TESTING.md.");
        return;
    }

    $class->_warn_once($storeid, 'partial-wwids',
        "orphan cleanup: $without_wwid of " . scalar(@$volumes) . " volume(s) on"
      . " storage '$storeid' were listed without a WWID and are treated as"
      . " absent. A device belonging to one of them could be removed once it"
      . " has been missing long enough.") if $without_wwid;

    # Reconcile in one locked pass: reset the miss counter for what is still
    # there, register what is new, count a miss for what is gone.
    my $tracked = {};
    $WWID_STATE->with_lock($storeid, sub {
        my $state = $WWID_STATE->read_state($storeid);

        for my $wwid (keys %$state) {
            my $entry = $WWID_STATE->entry($state->{$wwid});
            $entry->{miss} = $alive{$wwid} ? 0 : $entry->{miss} + 1;
            $state->{$wwid} = $entry;
        }
        for my $wwid (keys %alive) {
            $state->{$wwid} //= { first_seen => time(), miss => 0 };
        }

        $WWID_STATE->write_state($storeid, $state);
        %$tracked = %$state;
    });

    for my $wwid (keys %$tracked) {
        next if $alive{$wwid};

        my $entry = $WWID_STATE->entry($tracked->{$wwid});
        next unless $WWID_STATE->is_reapable($entry);

        my $mpath = eval { get_multipath_device($wwid) };
        if ($mpath && is_block_device($mpath)) {
            my $in_use = eval { is_device_in_use($mpath) };

            # Undef is "the checks could not prove anything", which is not a
            # licence to remove a device. This pass runs unattended in the
            # background of a poll; leaving one device for a human is free,
            # removing one that was in use is not.
            unless (defined $in_use) {
                warn "orphan cleanup: could not establish whether $mpath"
                   . " (WWID $wwid) is in use; leaving it alone\n";
                next;
            }

            if ($in_use) {
                warn "orphan cleanup: $mpath (WWID $wwid) is still in use,"
                   . " leaving it for manual review\n";
                next;
            }

            # A device with a working path is not an orphan, whatever the
            # array's listing said. The listing can lag a create — a disk
            # hot-added to a running VM is exactly the case — and a guest
            # holding the device open is not visible as a holder or a mount.
            # Getting this wrong means dmsetup pulling the map out from under
            # a running guest, which it sees as I/O errors on a brand-new
            # disk. Anything other than "every path has failed" is left alone.
            my $health = eval { multipath_path_health($wwid) };
            $health = -1 unless defined $health;
            if ($health != 0) {
                $class->_warn_once($storeid, "live-$wwid",
                    "orphan cleanup: $mpath (WWID $wwid) is not on the array"
                  . " but still has " . ($health > 0 ? "a working path"
                    : "an unreadable path state") . ", so it is left alone."
                  . " A device with a live path is in use by something.");
                next;
            }

            warn "orphan cleanup: removing stale device $mpath (WWID $wwid);"
               . " the array has not reported this volume for $entry->{miss}"
               . " consecutive passes\n";

            eval { cleanup_lun_devices($wwid) };
            warn "orphan cleanup: cleanup of $wwid failed: $@" if $@;

            # Only untrack once the device is verifiably gone. A partial
            # cleanup that untracked would leave a stale device no later pass
            # could find, because phase 1 cannot re-import a WWID whose volume
            # no longer exists on the array.
            if (eval { get_multipath_device($wwid) }) {
                warn "orphan cleanup: device for WWID $wwid is still present,"
                   . " keeping it tracked for the next pass\n";
                next;
            }
        }

        eval { $WWID_STATE->untrack_wwid($storeid, $wwid) };
    }

    $class->_report_untracked_devices($storeid, $scfg, \%alive, $tracked);

    eval { $class->_reap_temp_clones($storeid, $scfg) };
    warn "Temporary clone cleanup failed: $@" if $@;

    return;
}

# One warning per storage per topic per hour. status() runs every ten seconds,
# so an unconditional warn on a persistent condition is journal noise that
# hides everything else.
sub _warn_once {
    my ($class, $storeid, $topic, $message, %opts) = @_;

    my $interval = $opts{interval} // 3600;
    my $dir  = $WWID_STATE->lock_dir;
    my $flag = "$dir/warned-" . $WWID_STATE->safe_storeid($storeid) . "-$topic";

    if (-f $flag) {
        my $age = time() - ((stat($flag))[9] // 0);
        return 0 if $age >= 0 && $age < $interval;
    }

    warn "$message\n";
    eval { open(my $fh, '>', $flag) or return; close($fh) };

    return 1;
}

# Devices from our vendor that are neither on the array nor tracked. They are
# reported, never removed: they may belong to a hand-attached LUN, another
# tool, or a storage this plugin does not manage.
sub _report_untracked_devices {
    my ($class, $storeid, $scfg, $alive, $tracked) = @_;

    my $local = eval { list_vendor_multipath_devices(vendor => $class->_vendor_re) } // [];
    return unless @$local;

    my $siblings = $WWID_STATE->sibling_tracked_wwids($storeid);
    my $dir = $WWID_STATE->lock_dir;

    for my $dev (@$local) {
        my $wwid = lc($dev->{wwid} // '');
        next unless $wwid;
        next if $alive->{$wwid};
        next if $tracked->{$wwid};
        next if $siblings->{$wwid};   # another Dell storage on this node owns it

        # One warning per WWID per hour: status() runs every ~10 seconds.
        my $flag = "$dir/orphan-warned-$wwid";
        if (-f $flag) {
            next if (time() - (stat($flag))[9]) < 3600;
        }

        warn "orphan cleanup: /dev/mapper/$dev->{name} (WWID $wwid) is not on"
           . " this storage's array and is not tracked by any Dell storage on"
           . " this node. It may be a hand-attached LUN or a leftover. It will"
           . " NOT be removed automatically. To remove it by hand:\n"
           . "  multipathd disablequeueing map $dev->{name}\n"
           . "  dmsetup message $dev->{name} 0 fail_if_no_path\n"
           . "  multipath -f /dev/mapper/$dev->{name}\n";

        eval { open(my $fh, '>', $flag); close($fh) };
    }

    return;
}

# Vendor regexp for device gating; families narrow it once verified.
sub _vendor_re {
    my ($class) = @_;
    my $vendor = $class->multipath_vendor();
    return qr/\Q$vendor\E/i;
}

# ---------------------------------------------------------------------------
# Volume allocation
# ---------------------------------------------------------------------------

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    local $CURRENT_STOREID = $storeid;

    die "unsupported format '$fmt' - this storage only holds raw volumes\n"
        if defined $fmt && $fmt ne 'raw';

    my $size_bytes = $size * 1024;   # PVE passes KiB
    my ($array_name, $pve_volname);

    if ($name && $name =~ /^vm-\d+-(?:state-.+|cloudinit|efi-enroll|fleece-\d+)\z/) {
        # PVE dictates these names and uses the device immediately after this
        # call returns.
        $array_name  = $class->_array_volname($storeid, $name);
        $pve_volname = $name;
    } else {
        my $diskid;
        if ($name) {
            my $parsed = $class->_parse_volname($name);
            $diskid = $parsed->{diskid} if $parsed;
        }
        $diskid //= $class->_find_free_diskid($scfg, $storeid, $vmid);
        $array_name  = $class->naming->encode_volume_name($storeid, $vmid, $diskid);
        $pve_volname = "vm-${vmid}-disk-${diskid}";
    }

    # A state or cloud-init volume left behind by a failed attempt is
    # reclaimable: PVE dictates its name, which is derived from the snapshot,
    # so it cannot belong to anything else and cannot be moved out of the way.
    my $dictated = ($name && $name =~ /^vm-\d+-(?:state-.+|cloudinit|efi-enroll|fleece-\d+)\z/) ? 1 : 0;

    if ($dictated && eval { $class->_array_get_volume($scfg, $array_name) }) {
        warn "Reclaiming orphaned volume '$array_name' from a previous"
           . " failed attempt\n";
        eval { $class->_release_volume($scfg, $storeid, $array_name) };
        die "Volume '$array_name' already exists on the array and could not"
          . " be reclaimed: $@\n" if $@;
    }

    # Choosing a disk id and creating it are two steps, and PVE runs
    # allocations in parallel across the cluster. Between them, another worker
    # can take the id — so the existence check belongs INSIDE this loop
    # together with the create. Outside it, the worker that lost the race
    # would die on a name it was still free to change.
    my $attempt = 0;
    while (1) {
        $attempt++;

        my $taken = eval { $class->_array_get_volume($scfg, $array_name) } ? 1 : 0;
        my $error;

        unless ($taken) {
            eval { $class->_array_create_volume($scfg, $storeid, $array_name, $size_bytes) };
            last unless $@;

            $error = $@;
            $taken = $error =~ /already exists|duplicate|conflict|409/i ? 1 : 0;

            die "Failed to create volume '$array_name': $error" unless $taken;
        }

        # The name is taken by something else. A name this plugin chose can be
        # moved along to the next free id; one PVE dictated cannot.
        die "Volume '$array_name' already exists on the array. This indicates"
          . " a naming conflict or an orphaned volume from a previous failed"
          . " operation.\n"
            unless !$dictated && $pve_volname =~ /^vm-\d+-disk-\d+\z/;

        die "Could not find a free disk id for VM $vmid on storage '$storeid'"
          . " after $attempt attempts; allocations from other nodes kept"
          . " taking it first. Retry the operation.\n"
            if $attempt >= ALLOC_MAX_ATTEMPTS;

        my $diskid = $class->_find_free_diskid($scfg, $storeid, $vmid);
        $array_name  = $class->naming->encode_volume_name($storeid, $vmid, $diskid);
        $pve_volname = "vm-${vmid}-disk-${diskid}";
        warn "alloc_image: disk id collision, retrying as '$pve_volname'\n";
    }

    # Map to every node, so live migration works without a remap.
    my ($mapped, $failed) = eval { $class->_map_to_all_hosts($scfg, $storeid, $array_name) };
    if ($@) {
        my $err = $@;
        # The mapping may have partly succeeded. Leaving those mappings behind
        # while deleting the volume gives other nodes ghost LUNs that become
        # stale devices.
        warn "Mapping failed, removing volume '$array_name' again\n";
        eval { $class->_release_volume($scfg, $storeid, $array_name) };
        die "Failed to map volume '$array_name' to this node: $err\n";
    }

    warn "Volume '$array_name' could not be mapped to: " . join(', ', @$failed)
       . ". Live migration to those nodes will fail until this is fixed.\n"
        if $failed && @$failed;

    # PVE uses state and cloud-init volumes the moment this returns, so the
    # device has to be there before we hand the name back.
    if ($name && $name =~ /^vm-\d+-(?:state-.+|cloudinit|efi-enroll|fleece-\d+)\z/) {
        my $wwid = eval { $class->_array_get_wwid($scfg, $array_name) };
        unless ($wwid) {
            eval { $class->_release_volume($scfg, $storeid, $array_name) };
            die "Could not determine the WWID of volume '$array_name'\n";
        }

        $class->_rescan_transport($scfg);
        my %wait = $class->_wait_opts($scfg);
        my $device = wait_for_multipath_device($wwid, %wait);

        unless ($device) {
            my $diag = $class->_device_diagnostics($scfg, $wwid);
            eval { $class->_release_volume($scfg, $storeid, $array_name) };
            die "The device for volume '$pve_volname' (WWID $wwid) did not"
              . " appear within " . $class->_device_timeout($scfg) . "s.\n$diag";
        }

        eval { $WWID_STATE->track_wwid($storeid, $wwid) };
    }

    return $pve_volname;
}

# Delete the snapshots of one volume that this plugin created, including the
# template marker. Only names that decode back to this exact volume are
# touched; anything else on the array is left alone.
# opts:
#   keep_base   leave the template marker snapshot in place
#   base_only   remove nothing but the template marker
#   errors      arrayref that collects the reason for each one that would not
#               go. The array's refusal here is usually the real explanation
#               for the delete that follows — "this snapshot has dependent
#               clones" rather than the volume's own "it still has snapshots".
sub _purge_own_snapshots {
    my ($class, $scfg, $storeid, $array_name, %opts) = @_;

    my $snaps = eval { $class->_array_snapshot_list($scfg, $storeid, $array_name) };
    if ($@) {
        warn "Could not list the snapshots of '$array_name' before deleting"
           . " it: $@";
        return 0;
    }

    my $removed = 0;
    for my $snap (@{ $snaps // [] }) {
        my $name = $snap->{name} or next;

        my $decoded = $class->naming->decode_snapshot_name($name) or next;
        next unless ($decoded->{volume} // '') eq $array_name;

        next if $opts{keep_base} && $decoded->{is_base};
        next if $opts{base_only} && !$decoded->{is_base};

        # A snapshot that something was cloned from cannot be deleted, and
        # Dell's own guidance for PowerVault is explicit: a volume with child
        # snapshots, or a snapshot with child snapshots, needs the children
        # removed first.
        $class->_release_snapshot_clones($scfg, $storeid, $name);

        $class->_assert_own_object($storeid, $name, 'delete snapshot');
        eval { $class->_array_snapshot_delete($scfg, $storeid, $name) };
        if ($@) {
            my $err = $@;
            chomp $err;
            warn "Could not delete snapshot '$name' of '$array_name': $err\n";
            push @{ $opts{errors} }, $err if ref($opts{errors}) eq 'ARRAY';
            next;
        }
        $removed++;
    }

    return $removed;
}

# Unmap from everywhere, then delete. Used by every rollback path: deleting a
# volume that is still mapped leaves other nodes with ghost LUNs.
sub _release_volume {
    my ($class, $scfg, $storeid, $array_name) = @_;

    my $hosts = eval { $class->_array_mapped_hosts($scfg, $array_name) } // [];
    for my $host (@$hosts) {
        eval { $class->_array_unmap_from_host($scfg, $array_name, $host) };
        warn "Failed to unmap '$array_name' from host '$host': $@" if $@;
    }

    $class->_assert_own_object($storeid, $array_name, 'delete volume');
    $class->_array_delete_volume($scfg, $storeid, $array_name);

    return 1;
}

# Map a volume to this node and, in per-node mode, to every other node of the
# cluster that is registered on the array.
sub _map_to_all_hosts {
    my ($class, $scfg, $storeid, $array_name) = @_;

    my $current = $class->_host_name($scfg);

    if ($class->_host_mode($scfg) eq 'shared') {
        unless ($class->_array_is_mapped($scfg, $array_name, $current)) {
            $class->_array_map_to_host($scfg, $array_name, $current);
        }
        return ([$current], []);
    }

    # This node must succeed; the others are best effort.
    eval {
        unless ($class->_array_is_mapped($scfg, $array_name, $current)) {
            $class->_array_map_to_host($scfg, $array_name, $current);
        }
    };
    die "Failed to map volume to this node's host '$current': $@" if $@;

    my @mapped = ($current);
    my @failed;

    my $prefix = 'pve-' . $class->naming->sanitize($class->_cluster_name($scfg), 20) . '-';
    my $hosts = eval { $class->_array_list_hosts($scfg, $prefix) } // [];

    # The prefix finds the hosts this plugin named. It cannot find one that
    # was ADOPTED under the array's own naming, so the other nodes publish
    # theirs and this reads them: without it, a new disk is mapped to the node
    # that created it and to nothing else, and every migration waits for a
    # mapping it could have had already.
    my @names = map { ref($_) ? $_->{name} : $_ } @$hosts;
    push @names, @{ $class->_published_hosts($storeid) };

    my %seen;
    for my $name (grep { defined && length && !$seen{$_}++ } @names) {
        next if $name eq $current;

        eval {
            unless ($class->_array_is_mapped($scfg, $array_name, $name)) {
                $class->_array_map_to_host($scfg, $array_name, $name);
            }
            push @mapped, $name;
        };
        push @failed, $name if $@;
    }

    return (\@mapped, \@failed);
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;
    local $CURRENT_STOREID = $storeid;

    my $array_name = $class->_array_volname($storeid, $volname);

    my $vol = eval { $class->_array_get_volume($scfg, $array_name) };
    my $lookup_error = $@;

    # "The array says it is not there" and "the array did not answer" are not
    # the same fact, and only the first one may be reported as a successful
    # delete. PVE removes the disk from the VM configuration when free_image
    # returns, so answering success here for an unreachable array loses the
    # only reference anyone had to a volume that is still on it.
    #
    # Every family's lookup returns undef for "not found" and dies for
    # anything else, so the error is what separates them.
    unless ($vol) {
        die "Cannot delete volume '$volname': the array did not answer whether"
          . " it still exists, so this cannot be reported as deleted. PVE would"
          . " drop the disk from the VM configuration while the volume is still"
          . " on the array. Retry once the array is reachable.\n"
          . "  Array error: $lookup_error"
            if $lookup_error;

        warn "Volume '$array_name' is not on the array; it may already have"
           . " been deleted\n";
        return undef;
    }

    my $wwid = $vol->{wwid} // eval { $class->_array_get_wwid($scfg, $array_name) };

    # Refuse while anything is using the device, AND refuse when that cannot
    # be established. This path unmaps before it deletes, so acting on a wrong
    # "not in use" takes the disk out from under whatever is using it.
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && is_block_device($device)) {
            my $in_use = is_device_in_use($device);

            die "Cannot delete volume '$volname': whether device $device is"
              . " still in use could not be determined. Refusing rather than"
              . " assuming it is free. Check it by hand, or retry once the"
              . " node is responsive.\n" unless defined $in_use;

            if ($in_use) {
            my $details = eval { get_device_usage_details($device) } // '';
            my $msg = "Cannot delete volume '$volname': device $device is still"
                    . " in use (mounted, has holders, or open by a process).\n";
            $msg .= "\n$details\n" if $details;
            $msg .= "Stop the VM and unmount the device, then retry.\n" unless $details;
            die $msg;
            }
        }
    }

    # Capture the paths before unmapping: once the array drops the volume, the
    # map can disappear and with it the ability to enumerate them.
    my @slaves;
    if ($wwid) {
        my $mpath = eval { get_multipath_device($wwid) };
        if ($mpath) {
            my $list = eval { get_multipath_slaves($mpath) } // [];
            @slaves = @$list;
        }
    }

    # Unmap everywhere BEFORE local cleanup. The other order lets an in-flight
    # rescan on any node re-import the LUN and rebuild the device behind us.
    #
    # A failed query is fatal here rather than best-effort: carrying on would
    # delete a volume that is still mapped, and every node it is mapped to
    # keeps a device that answers nothing. Anything touching one of those
    # hangs in uninterruptible sleep, which is a node-wide storage freeze.
    # Failing the delete is retryable; ghost LUNs are not.
    my $hosts = eval { $class->_array_mapped_hosts($scfg, $array_name) };
    die "Cannot delete volume '$volname': the array did not answer which"
      . " hosts it is mapped to, and deleting a mapped volume would leave"
      . " every one of them with a device that answers nothing. Retry once"
      . " the array is reachable.\n  Array error: $@" if $@;
    $hosts //= [];

    for my $host (@$hosts) {
        eval { $class->_array_unmap_from_host($scfg, $array_name, $host) };
        warn "Failed to unmap '$array_name' from host '$host': $@" if $@;
    }

    if ($wwid) {
        eval { cleanup_lun_devices($wwid) };
        warn "Local device cleanup for '$volname' failed: $@" if $@;

        # cleanup_lun_devices removes the paths only after its flush succeeds;
        # when it had to fall back to dmsetup, the slave list it walks is
        # already gone. Use the list captured above.
        for my $slave (@slaves) {
            eval { remove_scsi_device($slave) } if is_block_device($slave);
        }
    }

    # An array refuses to delete a volume that still has snapshots, and PVE
    # does not remove them first: 'qm destroy' calls vdisk_free straight away.
    # The template marker is deliberately left for now — see below.
    my @snapshot_errors;
    $class->_purge_own_snapshots($scfg, $storeid, $array_name,
        keep_base => 1, errors => \@snapshot_errors);

    $class->_assert_own_object($storeid, $array_name, 'delete volume');
    eval { $class->_array_delete_volume($scfg, $storeid, $array_name) };

    # Captured immediately, and everything below works on the copy. $@ is
    # global and every eval in between resets it, so reading it again after
    # the marker handling would report a refused delete as success — and PVE
    # would drop the disk from the VM configuration while the volume is still
    # on the array.
    my $delete_error = $@;

    # The template marker is handled last and separately, and the array is
    # what decides whether it may go: a linked clone is a clone OF THE MARKER,
    # so an array that still has one refuses to delete it. Trying and being
    # refused is therefore safe, and it is the only reliable test — reading the
    # refusal text is not. Both PowerStore and PowerFlex use the same wording
    # for "this volume still has a snapshot" and "something was cloned from
    # it", and on PowerStore the hint this plugin appends to a 422 contains
    # the word "clones" itself, so any message-matching rule matches both.
    if ($isBase || $volname =~ /^base-/) {
        if ($delete_error) {
            if ($class->_purge_own_snapshots($scfg, $storeid, $array_name,
                    base_only => 1, errors => \@snapshot_errors)) {
                $class->_assert_own_object($storeid, $array_name, 'delete volume');
                eval { $class->_array_delete_volume($scfg, $storeid, $array_name) };
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

        # A snapshot that would not go usually explains the volume that would
        # not go, and in more useful terms: the array tells you a snapshot has
        # dependent clones, while the volume only says it still has snapshots.
        $err .= "\n  While clearing its snapshots: "
              . join('; ', @snapshot_errors) if @snapshot_errors;

        if ($err =~ /clone|dependent|child|in use/i) {
            die "Cannot delete volume '$volname': the array reports dependent"
              . " objects, which usually means thin clones were made from it."
              . " Delete those first.\n  Array error: $err\n";
        }
        die "Failed to delete volume '$array_name': $err\n";
    }

    # Keep the WWID tracked if a stale device survived, so the reaper retries.
    if ($wwid) {
        if (eval { get_multipath_device($wwid) }) {
            warn "free_image: a device for WWID $wwid is still present after"
               . " cleanup; keeping it tracked so the orphan reaper retries\n";
        } else {
            eval { $WWID_STATE->untrack_wwid($storeid, $wwid) };
        }
    }

    # The last disk of a VM takes its config backup volumes with it.
    if ($volname =~ /^(?:vm|base)-(\d+)-disk-\d+\z/) {
        my $vmid = $1;
        my $prefix = $class->naming->volume_prefix($storeid) . "${vmid}-disk";
        my $remaining = eval { $class->_array_list_volumes($scfg, $storeid, $prefix) } // [];
        if (!@$remaining && $class->supports_config_backup()) {
            eval { $class->_cleanup_config_volumes($scfg, $storeid, $vmid) };
            warn "Config volume cleanup failed (not fatal): $@" if $@;
        }
    }

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

    my $prefix = $class->naming->volume_prefix($storeid);
    $prefix .= "${vmid}-" if $vmid;

    my $volumes = $class->_array_list_volumes($scfg, $storeid, $prefix) // [];

    # One query for the template markers instead of one per volume.
    my %is_template;
    my $bases = eval { $class->_array_list_base_snapshots($scfg, $storeid, $prefix) } // [];
    $is_template{$_} = 1 for @$bases;

    # Linked clones must be reported under the same volid PVE stored in the VM
    # configuration, 'base-.../vm-...', or 'qm rescan' sees a volume no config
    # references and adds it a second time as an unused disk. Families that
    # cannot work out the parent return nothing here and the clone is listed
    # under its own name, which is what the LVM-thin plugin does.
    my $parents = eval { $class->_array_clone_parents($scfg, $storeid, $volumes) } // {};

    my @res;
    for my $vol (@$volumes) {
        my $name = $vol->{name} or next;

        my $decoded = $class->naming->decode_volume_name($name);
        next unless $decoded;

        # Config backup volumes are plugin bookkeeping, not VM disks.
        next if $decoded->{type} eq 'vmconf';

        my $pve_volname;
        if ($decoded->{type} eq 'disk') {
            my $kind = $is_template{$name} ? 'base' : 'vm';
            $pve_volname = "$kind-$decoded->{vmid}-disk-$decoded->{diskid}";

            if ($kind eq 'vm' && defined(my $base = $parents->{$name})) {
                my $bd = $class->naming->decode_volume_name($base);
                $pve_volname = "base-$bd->{vmid}-disk-$bd->{diskid}/$pve_volname"
                    if $bd && $bd->{type} eq 'disk';
            }
        } else {
            $pve_volname = $class->naming->array_to_pve_volname($name);
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
            size   => $vol->{size} // 0,
            used   => $vol->{used} // 0,
            vmid   => $decoded->{vmid},
        };
    }

    return \@res;
}

# { clone_volume_name => base_volume_name } for the linked clones on this
# storage, from data the family has already fetched.
#
# The default is an empty map: a family that cannot identify the parent from
# its array's own metadata must not guess, and reporting the clone under its
# plain name is a supported shape rather than a wrong one.
sub _array_clone_parents { return {} }

# Volumes that carry a .pve-base marker snapshot. Families may override with
# a cheaper query.
sub _array_list_base_snapshots {
    my ($class, $scfg, $storeid, $prefix) = @_;

    my $snaps = eval { $class->_array_snapshot_list($scfg, $storeid, undef, $prefix) } // [];

    my @bases;
    for my $snap (@$snaps) {
        my $name = $snap->{name} or next;
        my $decoded = $class->naming->decode_snapshot_name($name);
        push @bases, $decoded->{volume} if $decoded && $decoded->{is_base};
    }

    return \@bases;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    local $CURRENT_STOREID = $storeid;

    my $array_name = $class->_array_volname($storeid, $volname);
    my $vol = $class->_array_get_volume($scfg, $array_name);
    die "Volume '$array_name' not found on the array\n" unless $vol;

    my $size = $vol->{size} // 0;
    my $used = $vol->{used} // 0;

    return wantarray ? ($size, 'raw', $used, undef) : $size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;
    local $CURRENT_STOREID = $storeid;

    # Storage API 14 added $snapname, for storages that keep snapshots as a
    # chain of volumes. Here a snapshot is an object on the array and has no
    # size of its own to change, so this has to be refused rather than
    # silently resizing the volume the snapshot was taken from.
    die "Resizing a snapshot is not supported by " . $class->type() . ": a"
      . " snapshot on this array is a point-in-time copy, not a writable"
      . " layer. Resize the volume '$volname' instead.\n" if $snapname;

    my $array_name = $class->_array_volname($storeid, $volname);

    my $vol = $class->_array_get_volume($scfg, $array_name);
    die "Volume '$array_name' not found on the array\n" unless $vol;

    my $current = $vol->{size} // 0;

    if ($size < $current) {
        die sprintf(
            "Cannot shrink volume '%s': current size %.2f GB, requested %.2f GB."
          . " Shrinking would truncate the guest filesystem and lose data.\n",
            $volname, $current / (1024 ** 3), $size / (1024 ** 3));
    }
    return 1 if $size == $current;

    $class->_array_resize_volume($scfg, $storeid, $array_name, $size);

    # Wait for the array to actually report the new size before touching the
    # host side. A resize that is still running when the SCSI rescan happens
    # leaves the kernel with the old capacity, and QEMU's block_resize then
    # fails with "Cannot grow device files" on a volume that did in fact grow.
    # Best effort: if the array never reports it, the rescan below is still
    # worth doing.
    $class->_await_volume_size($scfg, $array_name, $size);

    # Two different SCSI operations, and they are not interchangeable:
    #   host scan  (/sys/class/scsi_host/hostN/scan) finds NEW devices
    #   dev rescan (/sys/block/sdX/device/rescan)    re-reads an existing
    #                                                device's capacity
    # A resize needs the second. And even then the multipath map above the
    # paths keeps reporting the old size until multipathd is told, which is
    # what makes QEMU's block_resize fail with "Cannot grow device files".
    my $wwid = eval { $class->_array_get_wwid($scfg, $array_name) };
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && is_block_device($device)) {
            my $slaves = eval { get_multipath_slaves($device) } // [];
            eval { rescan_scsi_device($_) } for @$slaves;
            # expect: the map has to actually reach the new size, not just be
            # told about it. See multipath_resize_map.
            eval { multipath_resize_map($device, expect => $size) };
            udev_refresh();
        }
    }

    return 1;
}

# Poll until the array reports at least $wanted bytes for $array_name.
# Returns 1 if it did, 0 if the wait ran out. Never dies: the caller has
# already asked for the resize and the host-side refresh is worth attempting
# either way.
sub _await_volume_size {
    my ($class, $scfg, $array_name, $wanted, %opts) = @_;

    my $timeout  = $opts{timeout} // RESIZE_SETTLE_TIMEOUT;
    my $deadline = time() + $timeout;

    while (1) {
        my $vol = eval { $class->_array_get_volume($scfg, $array_name) };
        my $size = ($vol && $vol->{size}) ? $vol->{size} : 0;

        # Arrays round up to their own granularity, so the reported size can
        # legitimately be larger than what was asked for; smaller means the
        # resize has not landed.
        return 1 if $size >= $wanted;

        last if time() >= $deadline;
        sleep(1);
    }

    warn "The array has not yet reported the new size for '$array_name' after"
       . " ${timeout}s. Refreshing the host side anyway; if the guest still"
       . " sees the old capacity, rescan once the array has caught up.\n";

    return 0;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;
    local $CURRENT_STOREID = $storeid;

    my $source = $class->_array_volname($storeid, $source_volname);

    $target_volname //= $class->find_free_diskname($storeid, $scfg, $target_vmid, 'raw');
    my $target = $class->_array_volname($storeid, $target_volname);

    die "Volume '$target' already exists on the array\n"
        if eval { $class->_array_get_volume($scfg, $target) };

    $class->_array_rename_volume($scfg, $storeid, $source, $target);

    return "$storeid:$target_volname";
}

# ---------------------------------------------------------------------------
# Volume activation
# ---------------------------------------------------------------------------

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

    if ($snapname) {
        my ($device) = $class->path($scfg, $volname, $storeid, $snapname);
        die "Could not activate snapshot '$snapname' of volume '$volname'\n"
            unless $device && is_block_device($device);
        return 1;
    }

    my $array_name = $class->_array_volname($storeid, $volname);

    my $vol = eval { $class->_array_get_volume($scfg, $array_name) };
    die "Cannot activate volume '$volname': '$array_name' is not on the array."
      . " It may have been deleted outside PVE.\n" unless $vol;

    my $host = $class->_host_name($scfg, $storeid);
    my $was_mapped = eval { $class->_array_is_mapped($scfg, $array_name, $host) };

    unless ($was_mapped) {
        # Resolve the host object before mapping to it, not after.
        #
        # This is the first thing a migration target does with a volume, and
        # on a node that has not yet worked out WHICH host object it is, the
        # name above is the generated one — which does not exist on an array
        # whose hosts were built by someone else. The map then fails with
        # "Host ... is not registered on the array", activate_volume dies, and
        # the VM arrives on a node that cannot see its disk. A customer's
        # first migration did exactly that.
        #
        # _array_ensure_host resolves and records it; it is throttled, and
        # this path is only reached when the volume is not mapped yet, so it
        # costs nothing on the ordinary poll.
        eval { $class->_array_ensure_host($scfg, $storeid) };
        my $resolved = $class->_host_name($scfg, $storeid);

        if ($resolved ne $host) {
            $host = $resolved;
            $was_mapped = eval { $class->_array_is_mapped($scfg, $array_name, $host) };
        }

        unless ($was_mapped) {
            eval { $class->_array_map_to_host($scfg, $array_name, $host) };
            die "Failed to map volume '$array_name' to host '$host': $@" if $@;
        }
    }

    my $wwid = $vol->{wwid} // eval { $class->_array_get_wwid($scfg, $array_name) };
    die "Could not determine the WWID of volume '$array_name'\n" unless $wwid;

    # Usually the device is already here. Check before doing anything
    # expensive: activate_volume is on the VM start and backup paths, where a
    # host-wide reconfigure churns maps other operations are trying to use.
    {
        my $existing = eval { get_device_by_wwid($wwid) };
        if ($existing && is_block_device($existing)) {
            eval { $WWID_STATE->track_wwid($storeid, $wwid) };
            $class->_reconcile_device_size($scfg, $storeid, $volname,
                $existing, $vol);
            return 1;
        }
    }

    $class->_rescan_transport($scfg);
    eval { rescan_scsi_hosts() };

    my %wait = $class->_wait_opts($scfg);
    my $device = wait_for_multipath_device($wwid, %wait);

    unless ($device) {
        my $timeout = $class->_device_timeout($scfg);
        my $diag = $class->_device_diagnostics($scfg, $wwid);
        die "The device for volume '$volname' (WWID $wwid) did not appear"
          . " within ${timeout}s.\n"
          . "  Volume mapping: " . ($was_mapped ? 'pre-existing' : 'just created') . "\n"
          . "$diag"
          . "  If the device shows up healthy moments later, raise"
          . " 'dell-device-timeout' (currently ${timeout}s).\n";
    }

    eval { $WWID_STATE->track_wwid($storeid, $wwid) };

    return 1;
}

# Host-side state at the moment discovery failed. By the time an operator runs
# these commands by hand the transient is gone, which is what makes this class
# of report otherwise unanswerable.
sub _device_diagnostics {
    my ($class, $scfg, $wwid) = @_;

    my $out = "Diagnostics:\n";
    $out .= "  Protocol: " . $class->_protocol($scfg) . "\n";

    my $state = eval { describe_wwid_state($wwid, vendor => $class->_vendor_re) } // '';
    $out .= "$state\n" if $state;

    if ($class->_is_fc($scfg)) {
        my $targets = eval { get_fc_targets() } // [];
        my @online = grep { $_->{is_target} && ($_->{port_state} // '') =~ /online/i } @$targets;
        $out .= "  FC targets: " . scalar(@online) . " online of "
              . scalar(@$targets) . " visible\n";
        $out .= "  Check HBA port state, fabric zoning and cabling:\n"
              . "    cat /sys/class/fc_host/host*/port_state\n";
    } else {
        # rescan only touches LOGGED_IN sessions, so a session stuck in
        # FAILED or REOPEN is silently skipped and no amount of waiting will
        # surface a LUN reachable only through it.
        my $sessions = eval { get_session_states() } // [];
        if (@$sessions) {
            $out .= "  iSCSI sessions (" . scalar(@$sessions) . "):\n";
            for my $s (@$sessions) {
                $out .= "    $s->{session}: state=" . ($s->{state} // 'unreadable')
                      . " portal=" . ($s->{portal} // '?') . "\n";
            }
            my @bad = grep { ($_->{state} // '') ne 'LOGGED_IN' } @$sessions;
            $out .= "    NOTE: " . scalar(@bad) . " session(s) are not LOGGED_IN."
                  . " LUN rescans are only issued on LOGGED_IN sessions, so a"
                  . " volume reachable only through those cannot be discovered"
                  . " until they recover.\n" if @bad;
        } else {
            $out .= "  iSCSI sessions: NONE. Without a session no LUN can"
                  . " appear. Check network reachability to the array's iSCSI"
                  . " portals.\n";
        }
    }

    $out .= "  Also useful: 'multipath -ll'\n";

    return $out;
}

# A map smaller than the volume the array reports.
#
# Only the node running the guest resizes: PVE calls volume_resize there and
# nowhere else. Every other node that has this volume mapped keeps the old
# capacity in its multipath map until something makes it re-read, and a
# migration to such a node hands the guest a device SMALLER than its
# configuration says it is — which the guest discovers by writing past the
# end. This is the first thing every node does with a volume, so it is where
# the two are compared.
#
# Only ever grows the local view, never shrinks it, and only acts when the
# array's number is larger — an unreadable size does nothing.
sub _reconcile_device_size {
    my ($class, $scfg, $storeid, $volname, $device, $vol) = @_;

    my $want = $vol->{size} or return;
    my $have = device_size_bytes($device);
    return unless defined $have && $have > 0;
    return if $have >= $want;

    warn "Storage '$storeid': the device for '$volname' is $have bytes but"
       . " the array reports $want. Another node resized it; refreshing this"
       . " node's view.\n";

    my $slaves = eval { get_multipath_slaves($device) } // [];
    eval { rescan_scsi_device($_) } for @$slaves;
    eval { multipath_resize_map($device, expect => $want) };
    eval { udev_refresh() };

    return;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    local $CURRENT_STOREID = $storeid;

    if ($snapname) {
        $class->_cleanup_snapshot_access($scfg, $storeid, $volname, $snapname);
        return 1;
    }

    # Volumes stay mapped on purpose: unmapping here would break live
    # migration, which needs the volume present on the target node before the
    # source releases it.
    my $array_name = $class->_array_volname($storeid, $volname);
    my $wwid = eval { $class->_array_get_wwid($scfg, $array_name) };

    if ($wwid) {
        my $device = eval { get_device_by_wwid($wwid) };
        if ($device && is_block_device($device)) {
            eval { PVE::Tools::run_command(['/bin/sync'], timeout => 10) };
            eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device],
                timeout => 10) };
        }
    }

    return 1;
}

# Temporary clones created so a snapshot can be read, keyed by
# storeid:volname:snapname.
my %SNAPSHOT_ACCESS;

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    local $CURRENT_STOREID = $storeid;

    my $parsed = $class->_parse_volname($volname);
    die "unable to parse volume name '$volname'\n" unless $parsed;

    my $array_name = $class->_array_volname($storeid, $volname);
    my $target = $array_name;
    my $fresh = 0;

    if ($snapname) {
        ($target, $fresh) = $class->_prepare_snapshot_access($scfg, $storeid, $volname, $snapname);
    }

    my $wwid = eval { $class->_array_get_wwid($scfg, $target) };

    unless ($wwid) {
        # path() is called in contexts where the array may be unreachable and
        # a die would take out more than this one volume. Hand back the
        # canonical path; whoever opens it gets a clear ENOENT instead.
        return wantarray ? ("/dev/mapper/unknown-$target", $parsed->{vmid}, 'images')
                         : "/dev/mapper/unknown-$target";
    }

    my $device = get_device_by_wwid($wwid);

    if ((!$device || !is_block_device($device)) && $fresh) {
        $class->_rescan_transport($scfg);
        my %wait = $class->_wait_opts($scfg);
        $device = wait_for_multipath_device($wwid, %wait);
    }

    $device //= "/dev/mapper/$wwid";

    return wantarray ? ($device, $parsed->{vmid}, 'images') : $device;
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    # PVE's storage config hash does not carry the storage id, and every array
    # object name is derived from it, so this method cannot be implemented.
    # Nothing in PVE reaches it for this plugin: the base-class methods that
    # use it are overridden here, and PVE::Storage::abs_filesystem_path goes
    # through PVE::Storage::path, which does pass the storeid.
    die "filesystem_path is not supported by " . $class->type() . " (volume"
      . " '$volname'): volume names are derived from the storage id, which is"
      . " not available here. Use PVE::Storage::path() instead.\n";
}

# QEMU's blockdev options for this volume.
#
# The base class handles a '/dev/...' path correctly — and reaches it with
# File::stat::stat($path), an UNBOUNDED stat on a path under /dev. That is the
# call rule 9 exists for: on a dm-multipath device whose paths have all failed
# while queueing is still on, a stat lands in uninterruptible sleep, and here
# it would take the pvedaemon worker starting the VM with it. Every stat this
# plugin makes goes through Multipath::is_block_device, which bounds it; the
# one PVE makes on this plugin's behalf could not, so the method that makes it
# is overridden instead.
#
# LVMPlugin and RBDPlugin (with krbd) both answer 'host_device' with the path
# and no stat at all, which is the same conclusion by a shorter route: a
# volume here is always a block device or it is nothing.
sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;
    local $CURRENT_STOREID = $storeid;

    my ($path) = $class->path($scfg, $volname, $storeid,
        $options->{'snapshot-name'});

    # path() hands back '/dev/mapper/unknown-<name>' when the array cannot be
    # asked, because a die there would take out more than one volume on the
    # status paths. This is not one of those paths: QEMU is about to be given
    # this filename, and a placeholder would become an I/O error inside the
    # guest rather than a failure to start.
    die "Cannot start with volume '$volname': its device could not be"
      . " resolved. The array did not answer, or the volume is not mapped to"
      . " this node.\n" if $path =~ m{/unknown-};

    die "Cannot start with volume '$volname': '$path' is not a block device"
      . " on this node.\n" unless is_block_device($path);

    return { driver => 'host_device', filename => $path };
}

# A compact, mostly-unique token for a temporary object name. Base 36 keeps it
# inside the few characters PowerVault and PowerFlex have to spare.
sub _short_token {
    my ($pid, $now) = @_;

    my $encode = sub {
        my ($n) = @_;
        my @digits = (0 .. 9, 'a' .. 'z');
        my $out = '';
        do { $out = $digits[$n % 36] . $out; $n = int($n / 36) } while ($n > 0);
        return $out;
    };

    return $encode->($pid % (36 ** 3)) . $encode->($now % (36 ** 4));
}

# A snapshot is made readable through a temporary thin clone. Returns
# ($object_name, $is_new).
sub _prepare_snapshot_access {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    local $CURRENT_STOREID = $storeid;

    my $array_name = $class->_array_volname($storeid, $volname);
    my $snap_name  = $class->naming->encode_snapshot_name($array_name, $snapname);

    die "Snapshot '$snapname' of volume '$volname' is not on the array\n"
        unless eval { $class->_array_snapshot_get($scfg, $storeid, $snap_name) };

    my $key = "$storeid:$volname:$snapname";
    if (my $existing = $SNAPSHOT_ACCESS{$key}) {
        return ($existing, 0) if eval { $class->_array_get_volume($scfg, $existing) };
        delete $SNAPSHOT_ACCESS{$key};
    }

    my $temp = $class->naming->encode_temp_clone_name($array_name,
        _short_token($$, time()));

    # Recorded before the clone exists rather than after: a worker killed
    # between the create and the record would otherwise leave an object with
    # nothing pointing at it. A record for a clone that was never created is
    # harmless — the reaper finds no such object and drops the entry.
    eval {
        $WWID_STATE->track_temp_clone($storeid, $temp,
            { volume => $array_name, snapshot => $snap_name });
    };

    eval { $class->_array_clone($scfg, $storeid, $snap_name, $temp) };
    if ($@) {
        my $err = $@;
        eval { $WWID_STATE->untrack_temp_clone($storeid, $temp) };
        die "Failed to create a temporary clone for snapshot access: $err\n";
    }

    my $host = $class->_host_name($scfg);
    eval { $class->_array_map_to_host($scfg, $temp, $host) };
    if ($@) {
        my $err = $@;
        # The map may have taken effect even though the response failed.
        eval { $class->_release_volume($scfg, $storeid, $temp) };
        eval { $WWID_STATE->untrack_temp_clone($storeid, $temp) };
        die "Failed to map the temporary snapshot clone: $err\n";
    }

    $SNAPSHOT_ACCESS{$key} = $temp;

    return ($temp, 1);
}

sub _cleanup_snapshot_access {
    my ($class, $scfg, $storeid, $volname, $snapname) = @_;
    local $CURRENT_STOREID = $storeid;

    my $key = "$storeid:$volname:$snapname";
    my $temp = delete $SNAPSHOT_ACCESS{$key} or return;

    $class->_remove_temp_clone($scfg, $storeid, $temp);

    return;
}

# Remove one temporary clone, host side first, in the same order free_image
# uses.
#
# Removing it only on the array leaves this node with a multipath map and its
# sd* paths pointing at a volume that no longer answers, which multipathd then
# reports as failed paths every couple of seconds forever. The slave list has
# to be captured before the unmap, because after it the map can lose sight of
# the paths that made it up.
sub _remove_temp_clone {
    my ($class, $scfg, $storeid, $name) = @_;

    return 0 unless defined $name && length $name;

    # Checked here as well as in the reaper, because this is also reached from
    # the snapshot-access path and it deletes an array volume either way. The
    # infix is what makes a temporary clone identifiable as one; a VM disk
    # shares the prefix and nothing else.
    my $infix = $class->naming->temp_clone_infix;
    unless (index($name, $class->naming->volume_prefix($storeid)) == 0
            && index($name, $infix) > 0) {
        warn "Refusing to remove '$name' as a temporary clone: the name is not"
           . " one this storage would have given to one.\n";
        return 0;
    }

    # Drop any in-process reference first, so nothing hands out a path to a
    # clone that is being torn down.
    for my $key (keys %SNAPSHOT_ACCESS) {
        delete $SNAPSHOT_ACCESS{$key}
            if ($SNAPSHOT_ACCESS{$key} // '') eq $name;
    }

    my $wwid = eval { $class->_array_get_wwid($scfg, $name) };

    my @slaves;
    if ($wwid) {
        my $mpath = eval { get_multipath_device($wwid) };
        if ($mpath) {
            my $list = eval { get_multipath_slaves($mpath) } // [];
            @slaves = @$list;
        }
    }

    my $released = eval { $class->_release_volume($scfg, $storeid, $name); 1 };
    my $error = $@;

    if ($wwid) {
        eval { cleanup_lun_devices($wwid) };
        warn "Device cleanup for the temporary clone '$name' failed: $@" if $@;

        for my $slave (@slaves) {
            eval { remove_scsi_device($slave) } if is_block_device($slave);
        }
    }

    unless ($released) {
        warn "Could not remove the temporary clone '$name': $error";
        return 0;
    }

    eval { $WWID_STATE->untrack_temp_clone($storeid, $name) };

    return 1;
}

# Remove every temporary clone taken from one snapshot.
#
# The array will not delete a snapshot that something was cloned from, and PVE
# asks for exactly that: vzdump in snapshot mode takes a snapshot, reads it
# through path(), and deletes it the moment the backup finishes. Without this
# the delete fails every time and the clone is left behind on both sides.
sub _release_snapshot_clones {
    my ($class, $scfg, $storeid, $snap_name) = @_;

    my $clones = eval { $WWID_STATE->temp_clones_of_snapshot($storeid, $snap_name) } // [];
    return 0 unless @$clones;

    my $removed = 0;
    for my $name (@$clones) {
        # Ownership gate, as everywhere else.
        next unless index($name, $class->naming->volume_prefix($storeid)) == 0;

        unless (eval { $class->_array_get_volume($scfg, $name) }) {
            eval { $WWID_STATE->untrack_temp_clone($storeid, $name) };
            next;
        }

        $removed += $class->_remove_temp_clone($scfg, $storeid, $name);
    }

    return $removed;
}

# Remove temporary snapshot-access clones whose creating process is gone.
#
# Runs in the background of status(), where the resilient client is fine. It
# only ever touches objects this node recorded, so a clone another node is
# using is not reachable from here.
sub _reap_temp_clones {
    my ($class, $storeid, $scfg) = @_;

    my $stale = eval { $WWID_STATE->stale_temp_clones($storeid) } // [];
    return 0 unless @$stale;

    my $removed = 0;
    my $prefix = $class->naming->volume_prefix($storeid);
    my $infix  = $class->naming->temp_clone_infix;

    for my $name (@$stale) {
        # This runs unattended, in the background of a poll, and it deletes
        # volumes. So the gate is not "does the name start with our prefix" —
        # every VM disk on this storage does that too, and a temp-clone record
        # naming a real disk would be enough to delete it with nobody
        # watching.
        #
        # A temporary clone is the only object whose name carries the temp
        # clone infix. Requiring it means the worst a corrupt record can do is
        # name something that is not there.
        unless (index($name, $prefix) == 0 && index($name, $infix) > 0) {
            warn "Ignoring temporary-clone record '$name': it is not a name"
               . " this storage would have given a temporary clone. Removing"
               . " the record; the object itself is left alone.\n"
                if index($name, $prefix) == 0;
            eval { $WWID_STATE->untrack_temp_clone($storeid, $name) };
            next;
        }

        unless (eval { $class->_array_get_volume($scfg, $name) }) {
            # Already gone, or never created.
            eval { $WWID_STATE->untrack_temp_clone($storeid, $name) };
            next;
        }

        warn "Removing the temporary snapshot clone '$name': the process that"
           . " created it is gone. It was used to read a snapshot and nothing"
           . " refers to it now.\n";

        $removed += $class->_remove_temp_clone($scfg, $storeid, $name);
    }

    return $removed;
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    local $CURRENT_STOREID = $storeid;

    my $array_name = $class->_array_volname($storeid, $volname);
    my $snap_name  = $class->naming->encode_snapshot_name($array_name, $snap);

    die "Cannot snapshot volume '$volname': it is not on the array\n"
        unless eval { $class->_array_get_volume($scfg, $array_name) };

    die "Snapshot '$snap' already exists for volume '$volname'\n"
        if eval { $class->_array_snapshot_get($scfg, $storeid, $snap_name) };

    # Best-effort flush of host-side dirty pages. For a running VM, QEMU's own
    # freeze handles filesystem consistency; this only covers writes made
    # outside QEMU. Skipped when the device is busy so it cannot block a live
    # migration.
    #
    # is_device_in_use as a bare boolean is deliberate and harmless here, and
    # this is the only place that is true. Undef reads as "not busy", so an
    # undetermined device gets flushed rather than skipped — flushing is safe
    # in itself, both commands carry their own timeout inside an eval, and the
    # worst case is work that was not needed. Everywhere else undef decides
    # whether to destroy something, and there it has to mean "do not".
    my $wwid = eval { $class->_array_get_wwid($scfg, $array_name) };
    if ($wwid) {
        my $device = eval { get_device_by_wwid($wwid) };
        if ($device && is_block_device($device) && !is_device_in_use($device)) {
            eval { PVE::Tools::run_command(['/bin/sync'], timeout => 10) };
            eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device],
                timeout => 10) };
        }
    }

    eval { $class->_array_snapshot_create($scfg, $storeid, $array_name, $snap_name) };
    die "Failed to create snapshot '$snap' of volume '$volname': $@" if $@;

    if ($class->_config_backup_enabled($scfg)
        && $volname =~ /^(?:vm|base)-(\d+)-disk-\d+\z/) {
        my $vmid = $1;
        eval { $class->_backup_vm_config($scfg, $storeid, $vmid, $snap) };
        warn "VM config backup failed (not fatal): $@" if $@;
    }

    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    local $CURRENT_STOREID = $storeid;

    my $array_name = $class->_array_volname($storeid, $volname);
    my $snap_name  = $class->naming->encode_snapshot_name($array_name, $snap);

    unless (eval { $class->_array_snapshot_get($scfg, $storeid, $snap_name) }) {
        warn "Snapshot '$snap' of volume '$volname' is not on the array; it may"
           . " already have been deleted\n";
        return 1;
    }

    # A clone taken from this snapshot holds it on the array. PVE reads a
    # snapshot through such a clone and then deletes the snapshot straight
    # away, so this is the normal path, not an edge case.
    $class->_release_snapshot_clones($scfg, $storeid, $snap_name);

    $class->_assert_own_object($storeid, $snap_name, 'delete snapshot');
    eval { $class->_array_snapshot_delete($scfg, $storeid, $snap_name) };
    if ($@) {
        my $err = $@;
        die "Cannot delete snapshot '$snap' of volume '$volname': the array"
          . " reports it is still the source of one or more thin clones."
          . " Delete those volumes first.\n  Array error: $err\n"
            if $err =~ /dependent|in use|clone|cannot be deleted/i;
        die "Failed to delete snapshot '$snap' of volume '$volname': $err\n";
    }

    # Clean up even when the feature is now switched off: a storage that had
    # it enabled before still has the volumes.
    if ($class->supports_config_backup()
        && $volname =~ /^(?:vm|base)-(\d+)-disk-\d+\z/) {
        my $vmid = $1;
        eval { $class->_delete_config_volume($scfg, $storeid, $vmid, $snap) };
        warn "Config volume cleanup failed (not fatal): $@" if $@;
    }

    return 1;
}

# May PVE roll this volume back to this snapshot?
#
# PVE's own default is "always yes", which is right for a storage whose
# rollback leaves other snapshots alone. Whether that holds on these arrays is
# not documented: Dell's PowerStore and PowerVault manuals both describe what
# a restore does to the volume and say nothing about the snapshots taken after
# the one being restored. On an array that discards them, PVE would carry on
# listing restore points that no longer exist — and nobody finds out until the
# day they are needed.
#
# So the unknown is treated as dangerous, the way the built-in plugins whose
# rollback IS destructive treat it: only the most recent snapshot may be
# rolled back to, and everything newer is reported to PVE as a blocker so the
# operator sees exactly what is in the way. An operator who has verified their
# own array can lift this with 'dell-rollback-any-snapshot 1'.
#
# A snapshot whose creation time cannot be read counts as blocking. Being
# wrong in that direction costs an inconvenience; being wrong in the other
# direction destroys a restore point silently.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;
    local $CURRENT_STOREID = $storeid;

    $blockers //= [];   # not guaranteed to be set by the caller

    my $snapshots = $class->volume_snapshot_list($scfg, $storeid, $volname);

    my ($target) = grep { ($_->{name} // '') eq $snap } @$snapshots;
    die "can't rollback, snapshot '$snap' does not exist on"
      . " '$storeid:$volname'\n" unless $target;

    return 1 if $class->_opt($scfg, 'rollback-any-snapshot', 0);

    my $target_time = $target->{ctime} // 0;

    for my $other (@$snapshots) {
        my $name = $other->{name} // next;
        next if $name eq $snap;

        my $time = $other->{ctime} // 0;

        # Newer, the same second, or unreadable on either side: cannot be
        # shown to be older, so it counts against the rollback.
        push @$blockers, $name
            if !$time || !$target_time || $time >= $target_time;
    }

    die "Cannot roll back '$storeid:$volname' to '$snap': it is not the most"
      . " recent snapshot, and these would be at risk: "
      . join(', ', @$blockers) . ".\n"
      . "  Dell does not document what a restore does to snapshots taken"
      . " after the one being restored, so this plugin refuses rather than"
      . " let PVE keep listing restore points the array may have discarded.\n"
      . "  Roll back to the most recent snapshot, or delete the newer ones"
      . " first. If you have verified the behaviour on your array, set"
      . " 'dell-rollback-any-snapshot 1' on storage '$storeid'.\n"
        if @$blockers;

    return 1;
}

# The device for a WWID, or undef — refusing an answer the kernel does not
# confirm.
#
# Every device here is resolved fresh on each use, from a WWID the storage
# server just gave. That indirection is what makes a volid survive a reboot
# and a migration, and it is also where a wrong answer is silent: the lookup
# has fallbacks, a mapper entry can be stale, and a mapping index gets reused.
# Where the answer is only READ (a size, a health) a wrong device is a wrong
# number. Where it is written to, flushed or invalidated, a wrong device is
# the operation quietly not happening to the volume it was meant for.
#
# Returns undef when there is no device at all — which is an ordinary state,
# not an error — and dies when there is one the kernel will not vouch for.
sub _confirmed_device {
    my ($class, $wwid, $what) = @_;

    return undef unless defined $wwid && length $wwid;

    my $device = eval { get_device_by_wwid($wwid) };
    return undef unless $device && is_block_device($device);

    return $device if device_matches_wwid($device, $wwid);

    die "Refusing to $what through '$device': the kernel does not confirm it"
      . " is the device for WWID $wwid. It was resolved by a lookup that has"
      . " fallbacks, and acting on the wrong device here is not something"
      . " that reports itself.\n";
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    local $CURRENT_STOREID = $storeid;

    my $array_name = $class->_array_volname($storeid, $volname);
    my $snap_name  = $class->naming->encode_snapshot_name($array_name, $snap);

    die "Cannot roll back: volume '$array_name' is not on the array\n"
        unless eval { $class->_array_get_volume($scfg, $array_name) };
    die "Cannot roll back: snapshot '$snap' of volume '$volname' is not on the array\n"
        unless eval { $class->_array_snapshot_get($scfg, $storeid, $snap_name) };

    # A rollback replaces the volume's contents underneath whoever has it
    # open, so refuse while it is in use.
    my $wwid = eval { $class->_array_get_wwid($scfg, $array_name) };

    # A rollback overwrites the whole volume, and the damage is not visible
    # until the guest next reads. So the question is whether anything on this
    # node is using it, and an unknown answer must not be read as "no".
    #
    # No WWID is not an unknown, though: every device this plugin discovers is
    # found BY its WWID, so a volume that never had one cannot have a device
    # here, and nothing local can be holding it. It does mean the array is not
    # reporting the field this plugin reads the WWN from — the array answered
    # for the volume itself a few lines above — which is worth saying once,
    # because it breaks device discovery everywhere else.
    unless ($wwid) {
        $class->_warn_once($storeid, 'rollback-no-wwid',
            "Rolling back '$volname' without checking local use: the array"
          . " reported no WWID for it. Nothing on this node can have a device"
          . " for a volume with no WWID, so the rollback is safe — but device"
          . " discovery cannot work for this storage either. See"
          . " docs/TESTING.md on the WWN field name.");
    }

    my $device = $class->_confirmed_device($wwid, 'roll back');
    if ($device) {
        my $in_use = is_device_in_use($device);

        die "Cannot roll back volume '$volname': whether device $device is in"
          . " use could not be determined. Refusing rather than assuming it is"
          . " free.\n" unless defined $in_use;

        die "Cannot roll back volume '$volname': device $device is still in"
          . " use. Stop the VM first.\n" if $in_use;

        # Flush before, invalidate after. Dirty pages written back AFTER the
        # array has restored the snapshot would put pre-rollback content on
        # top of it — a corruption that looks like the rollback half worked.
        eval { PVE::Tools::run_command(['/bin/sync'], timeout => 10) };
        eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device],
            timeout => 10) };
    }

    eval { $class->_array_snapshot_rollback($scfg, $storeid, $array_name, $snap_name) };
    die "Failed to roll back volume '$volname' to snapshot '$snap': $@" if $@;

    if ($wwid) {
        my $device = $class->_confirmed_device($wwid,
            'invalidate the cache of');
        if ($device) {
            # The snapshot may have a different size than the current volume,
            # and the kernel does not pick that up from a host scan.
            my $slaves = eval { get_multipath_slaves($device) } // [];
            eval { rescan_scsi_device($_) } for @$slaves;
            eval { multipath_resize_map($device) };

            # Invalidate the buffer cache: without this, reads can still be
            # served from pages holding the post-snapshot content.
            eval { PVE::Tools::run_command(['/sbin/blockdev', '--flushbufs', $device],
                timeout => 10) };
            udev_refresh();
        }
    }

    return 1;
}

# PVE's base implementation reads the snapshot list out of a qcow2 file via
# filesystem_path(), which this plugin cannot provide. Left alone it would
# fail with a message about filesystem_path, which says nothing about what the
# caller was trying to do. The array knows the answer, so give it.
#
# The shape is the one PVE expects from a storage that does not keep snapshots
# as a chain of volumes: a hash keyed by snapshot name. 'current' is the live
# volume and deliberately has no parent — there is no backing chain here.
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

# Also base-implemented through filesystem_path, and also unreachable here.
# PVE only calls it for storages that keep snapshots as a chain of volumes.
sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source_snap, $target_snap) = @_;

    die "Renaming a snapshot is not supported by " . $class->type() . ": the"
      . " snapshot's name on the array is derived from the volume it belongs"
      . " to, and PVE only renames snapshots for storages that keep them as a"
      . " chain of volumes. Create a new snapshot and delete the old one"
      . " instead.\n";
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;
    local $CURRENT_STOREID = $storeid;

    my $array_name = $class->_array_volname($storeid, $volname);
    my $snaps = $class->_array_snapshot_list($scfg, $storeid, $array_name) // [];

    my @res;
    for my $snap (@$snaps) {
        my $name = $snap->{name} or next;
        my $decoded = $class->naming->decode_snapshot_name($name);
        next unless $decoded && !$decoded->{is_base};
        next unless defined $decoded->{snapname};

        push @res, {
            name  => $decoded->{snapname},
            ctime => $snap->{ctime} // 0,
        };
    }

    return \@res;
}

# ---------------------------------------------------------------------------
# Templates and clones
# ---------------------------------------------------------------------------

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    local $CURRENT_STOREID = $storeid;

    my ($vtype, undef, $vmid, undef, undef, $isBase, $format) =
        $class->parse_volname($volname);

    die "create_base is not possible for content type '$vtype'\n" if $vtype ne 'images';
    die "volume '$volname' is already a base image\n" if $isBase;

    my $array_name = $class->_array_volname($storeid, $volname);
    die "Cannot create a template from '$volname': it is not on the array\n"
        unless eval { $class->_array_get_volume($scfg, $array_name) };

    # A template must not change afterwards, so refuse while it is in use.
    my $wwid = eval { $class->_array_get_wwid($scfg, $array_name) };
    if ($wwid) {
        my $device = eval { get_device_by_wwid($wwid) };
        if ($device && is_block_device($device)) {
            my $in_use = is_device_in_use($device);

            # Every linked clone made later reads from the marker snapshot
            # taken here. A template captured mid-write is a filesystem that
            # was never consistent, copied into every clone of it.
            die "Cannot convert volume '$volname' to a template: whether"
              . " device $device is in use could not be determined, and a"
              . " template captured while it is being written to is"
              . " inconsistent in every clone made from it.\n"
                unless defined $in_use;

            die "Cannot convert volume '$volname' to a template: device $device"
              . " is still in use. Stop the VM first.\n" if $in_use;
        }
    }

    my $base_snap = $class->naming->encode_base_snapshot_name($array_name);
    unless (eval { $class->_array_snapshot_get($scfg, $storeid, $base_snap) }) {
        eval { $class->_array_snapshot_create($scfg, $storeid, $array_name, $base_snap) };
        die "Failed to create the template marker snapshot for '$volname': $@" if $@;
    }

    my $parsed = $class->_parse_volname($volname);

    return "base-$parsed->{vmid}-disk-$parsed->{diskid}";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;
    local $CURRENT_STOREID = $storeid;

    my $parsed = $class->_parse_volname($volname);
    die "unable to parse volume name '$volname'\n" unless $parsed;

    my $source_vol = $class->_array_volname($storeid, $volname);
    die "Cannot clone: source volume '$source_vol' is not on the array\n"
        unless eval { $class->_array_get_volume($scfg, $source_vol) };

    my ($source, $linked_to_base);

    if ($snap) {
        $source = $class->naming->encode_snapshot_name($source_vol, $snap);
        die "Cannot clone: snapshot '$snap' of volume '$volname' is not on the array\n"
            unless eval { $class->_array_snapshot_get($scfg, $storeid, $source) };
    } else {
        my $base_snap = $class->naming->encode_base_snapshot_name($source_vol);
        if (eval { $class->_array_snapshot_get($scfg, $storeid, $base_snap) }) {
            $source = $base_snap;
            $linked_to_base = 1;
        } elsif ($parsed->{isBase}) {
            eval { $class->_array_snapshot_create($scfg, $storeid, $source_vol, $base_snap) };
            die "Failed to create the template marker snapshot for '$volname': $@" if $@;
            $source = $base_snap;
            $linked_to_base = 1;
        } else {
            # Clone straight from the volume.
            $source = $source_vol;
        }
    }

    my $diskid = $class->_find_free_diskid($scfg, $storeid, $vmid);
    my $target_volname = "vm-${vmid}-disk-${diskid}";
    my $target = $class->naming->encode_volume_name($storeid, $vmid, $diskid);

    # Same non-atomic id selection as alloc_image.
    my $attempt = 0;
    while (1) {
        $attempt++;

        if (eval { $class->_array_get_volume($scfg, $target) }) {
            die "Clone target '$target' already exists on the array\n" if $attempt >= 5;
            $diskid = $class->_find_free_diskid($scfg, $storeid, $vmid);
            $target_volname = "vm-${vmid}-disk-${diskid}";
            $target = $class->naming->encode_volume_name($storeid, $vmid, $diskid);
            next;
        }

        eval { $class->_array_clone($scfg, $storeid, $source, $target) };
        last unless $@;

        my $err = $@;
        if ($attempt < 5 && $err =~ /already exists|duplicate|conflict|409/i) {
            $diskid = $class->_find_free_diskid($scfg, $storeid, $vmid);
            $target_volname = "vm-${vmid}-disk-${diskid}";
            $target = $class->naming->encode_volume_name($storeid, $vmid, $diskid);
            warn "clone_image: disk id collision, retrying as '$target_volname'\n";
            next;
        }

        die "Failed to clone '$source' to '$target': $err\n";
    }

    my ($mapped, $failed) = eval { $class->_map_to_all_hosts($scfg, $storeid, $target) };
    if ($@) {
        my $err = $@;
        warn "Mapping failed, removing clone '$target' again\n";
        eval { $class->_release_volume($scfg, $storeid, $target) };
        die "Failed to map the cloned volume: $err\n";
    }

    warn "Clone '$target' could not be mapped to: " . join(', ', @$failed)
       . ". Live migration to those nodes will fail until this is fixed.\n"
        if $failed && @$failed;

    return $linked_to_base ? "$volname/$target_volname" : $target_volname;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    my $features = {
        snapshot   => { current => 1, snap => 1 },
        # 'current' is deliberate and differs from RBD: clone_image can clone
        # straight from a volume that is not a template, so PVE may offer a
        # linked clone of an ordinary disk.
        clone      => { base => 1, current => 1, snap => 1 },
        template   => { current => 1 },
        copy       => { base => 1, current => 1, snap => 1 },
        # sparseinit is answered below rather than here: it is a claim about
        # the ARRAY's provisioning, not about the volume's kind.
        rename     => { current => 1 },
    };

    # 'sparseinit' tells PVE the target volume reads as zeroes where nothing
    # has been written to it, and PVE acts on that by NOT writing the zeroes:
    # drive-mirror is told 'zero-initialized', pbs-restore gets --skip-zero,
    # and a clone of a running VM copies only the non-zero regions. On a thin
    # volume that is correct — an unmapped LBA reads as zeroes. On a THICK one
    # it is not: those extents hold whatever the array last had there, so the
    # guest would find another volume's old contents where its source had
    # zeroes.
    #
    # This is the same claim 0.7.90 removed from the import path's
    # `dd conv=sparse`, reached through QEMU instead of through dd, and it was
    # missed then because the two look nothing alike. RBD answers yes because
    # an RBD image is always sparse; LVMPlugin does not answer at all, because
    # an LV holds whatever was on the disk before it.
    if ($feature eq 'sparseinit') {
        return 0 if $snapname;
        return $class->new_volumes_read_as_zeroes($scfg) ? 1 : 0;
    }

    # Whether this is a base image comes from parse_volname, not from the
    # spelling of the volname. A linked clone is named
    # 'base-100-disk-0/vm-101-disk-0', which starts with 'base-' while being
    # the least base-like volume there is — and calling it one would answer
    # 'no' to snapshot and rename for every linked clone on the storage.
    # eval: parse_volname dies on a name it does not recognise, and this is
    # called in a loop over a VM's configuration. A name this plugin cannot
    # read is not this question's problem — answer for an ordinary volume and
    # let whatever actually touches it report the real error.
    my $isBase = eval { ($class->parse_volname($volname))[5] };

    my $key = $snapname ? 'snap' : ($isBase ? 'base' : 'current');

    return 1 if $features->{$feature} && $features->{$feature}{$key};
    return 0;
}

# Does a volume this plugin has just created read as zeroes where nothing has
# been written to it?
#
# Only a thin volume promises that. The default is NO, because being wrong the
# safe way costs a full copy and being wrong the other way puts the array's
# previous contents inside a guest's disk. A family overrides it where its own
# provisioning answers the question.
sub new_volumes_read_as_zeroes { return 0 }

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
# to the base class: volume_export and volume_import are implemented right
# below, because the base class cannot do it for a storage without a 'path'
# either. Declaring the format without implementing the transfer moves the
# refusal one call later and makes it incomprehensible — see the comment on
# volume_export.
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

# Declaring a transfer format is half of it, and the half that is visible.
#
# PVE::Storage::Plugin::volume_export opens with "if ($scfg->{path} && ...)"
# and falls through to a die for a storage that has no path — which this one
# has not, and cannot have (rule 24). So between 0.7.x and 0.7.88 every
# transfer was advertised as available and then refused one call later, by
# the base class, naming the very format this plugin had just offered:
# "volume export format raw+size not available for ...Custom::DellUnityPlugin".
# LVMPlugin, RBDPlugin and ZFSPoolPlugin all implement BOTH halves; only the
# formats half was read when the override was written, and the comment above
# recorded the wrong conclusion for four months.
#
# The transfer itself is a dd across a pipe PVE owns. It is deliberately NOT
# wrapped in an alarm: it is a foreground, user-initiated bulk copy that
# legitimately runs for hours, and rule 5's bound exists for the poll paths
# that must never hang pvestatd. Everything AROUND the copy — resolving the
# device, sizing it, confirming it — is bounded as usual.
sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot,
        $base_snapshot, $with_snapshots) = @_;
    local $CURRENT_STOREID = $storeid;

    die "volume export format '$format' is not available for $class\n"
        if !defined($format) || $format ne 'raw+size';
    die "cannot export a volume together with its snapshots here: the"
      . " snapshots live on the array, not in the volume\n" if $with_snapshots;
    die "cannot export the snapshot '$snapshot' here: reading a snapshot needs"
      . " a temporary clone on the array\n" if defined $snapshot;
    die "cannot export an incremental stream here\n" if defined $base_snapshot;

    # Nothing activates the volume for us: PVE::Storage::volume_export goes
    # straight from the storage config to the plugin. On a node that has never
    # opened this volume there is no mapping and no device at all.
    $class->activate_volume($storeid, $scfg, $volname);

    my ($device, $wwid) = $class->_transfer_device($scfg, $storeid, $volname);

    my $size = _device_size_bytes($device);
    die "Cannot export volume '$volname': the size of device $device could"
      . " not be read. Refusing rather than sending a stream with a size"
      . " nobody checked.\n" unless defined $size && $size > 0;

    PVE::Storage::Plugin::write_common_header($fh, $size);
    PVE::Tools::run_command(
        ['/bin/dd', "if=$device", 'bs=64k', 'status=progress'],
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

    # "Already there" and "could not ask" are different answers (rule 21a).
    # _array_get_volume dies when the array cannot be reached, and that die is
    # deliberately not caught: importing over an unreachable array would mean
    # allocating a second volume on top of one that may already hold data.
    my $array_name = $class->_array_volname($storeid, $name);
    if ($class->_array_get_volume($scfg, $array_name)) {
        die "Volume '$name' already exists on storage '$storeid'\n"
            unless $allow_rename;
        warn "Volume '$name' already exists on storage '$storeid' —"
           . " importing under a different name\n";
    }

    my ($bytes) = PVE::Storage::Plugin::read_common_header($fh);
    die "Cannot import volume '$name': the stream carries no size\n"
        unless defined $bytes && $bytes > 0;
    # alloc_image takes KiB, and the stream's size is bytes. Round UP: a
    # volume one byte short of the stream is filled and then fails.
    my $size_kb = int(($bytes + 1023) / 1024);

    # alloc_image moves to the next free disk id when the name is taken, which
    # is the rename this contract allows — but only when the caller allows it.
    my $allocname = $class->alloc_image($storeid, $scfg, $vmid, 'raw', $name,
        $size_kb);

    eval {
        if ($allocname ne $name && !$allow_rename) {
            die "internal error: the volume was allocated as '$allocname'"
              . " rather than '$name', and the caller cannot follow a"
              . " rename\n";
        }

        $class->activate_volume($storeid, $scfg, $allocname);

        my ($device) = $class->_transfer_device($scfg, $storeid, $allocname);

        # No conv=sparse. Skipping a run of zeroes instead of writing it is
        # only correct if the region it skips already reads as zeroes, and
        # that holds for a thin volume — an unmapped LBA reads as zeroes —
        # but NOT for a thick one, whose extents are whatever the array last
        # had there. Thin is an operator's choice on two families
        # ('unity-thin', 'pflex-thick') and a property of the pool on
        # PowerVault, so the guarantee is one a storage's configuration can
        # withdraw. Writing every byte costs the volume's thinness on an
        # import and nothing else; the other way round leaves another
        # tenant's old data readable inside the imported disk. LVMPlugin
        # writes every byte too.
        PVE::Tools::run_command(
            ['/bin/dd', "of=$device", 'bs=64k'],
            input => '<&' . fileno($fh),
        );
    };
    if (my $err = $@) {
        # A half-written volume with no VM configuration pointing at it is an
        # orphan on the array; free_image unmaps before it deletes.
        eval { $class->free_image($storeid, $scfg, $allocname, 0) };
        warn "Cleaning up the partly imported volume '$allocname' failed: $@"
            if $@;
        die $err;
    }

    return "$storeid:$allocname";
}

# The device for a transfer, confirmed by the kernel rather than by the lookup
# that produced it.
#
# path() has a documented fallback: when the WWID cannot be read it hands back
# '/dev/mapper/unknown-<name>' so that callers on the status paths get an
# ENOENT instead of a die. An import would then dd a whole disk image into
# whatever that resolved to, and an export would send whatever it read. Both
# are the case _write_config_volume already refuses by name, so both get the
# same guard: the kernel's own identification of the device has to agree with
# the WWID the array gave for this volume.
sub _transfer_device {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $array_name = $class->_array_volname($storeid, $volname);
    my $wwid = eval { $class->_array_get_wwid($scfg, $array_name) };
    die "Cannot transfer volume '$volname': the array did not give a WWID for"
      . " '$array_name', so the device cannot be confirmed.\n"
        unless defined $wwid && length $wwid;

    my $device = get_device_by_wwid($wwid);
    die "Cannot transfer volume '$volname': no device for WWID $wwid is"
      . " present on this node.\n"
        unless $device && is_block_device($device);

    die "Refusing to transfer volume '$volname' through '$device': the kernel"
      . " does not confirm it is the device for WWID $wwid. A transfer reads"
      . " or writes the whole volume, so an unconfirmed answer is treated as"
      . " a wrong one.\n"
        unless device_matches_wwid($device, $wwid);

    return ($device, $wwid);
}

# The protocols this storage type actually speaks.
#
# 'dell-protocol' is declared once, in Common::Schema, for all three types —
# PVE::SectionConfig::init dies on a duplicate property name and takes every
# storage on the node down with it, so a per-family enum is not available.
# The enum therefore lists every protocol any family supports, and this is
# what narrows it.
sub supported_protocols { return ['iscsi', 'fc'] }

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
      . "; 'dell-protocol $protocol' belongs to PowerFlex.\n";
}

# The naming class, exposed under a stable name so one family's hook can ask
# another family's plugin the same question.
sub naming_class_for_check { return $_[0]->naming }

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

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    $class->_check_protocol($storeid, $scfg);
    $class->_check_prefix_collision($storeid, $scfg);

    # PVE strips the sensitive properties out of the config and passes them
    # here instead.
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

# Local bookkeeping for a storage that is being removed.
#
# Health::forget existed from the start and nothing ever called it (the same
# shape as lesson 36). The files are small, so the cost of leaving them is not
# disk: it is that a storage id RE-created later inherits them. An inherited
# health state makes the new storage report "RECOVERED after 4 days" on its
# first successful poll, and inherited warn flags silence the first hour of
# warnings about a storage nobody has ever seen before.
#
# The WWID and temp-clone tracking is treated differently, and deliberately:
# each entry names a device this node actually has or an object this plugin
# created on the array. If any remain, the files stay and the operator is told
# what is in them — deleting the only record of a device that is still on the
# node would leave nothing to clean it up with.
sub _forget_local_state {
    my ($class, $storeid) = @_;

    return unless defined $storeid && length $storeid;

    eval { $HEALTH->forget($storeid) };
    $class->_forget_resolved_host($storeid);
    $class->_unpublish_resolved_host($storeid);

    my $safe = $WWID_STATE->safe_storeid($storeid);
    my $run  = $WWID_STATE->lock_dir;

    # The _warn_once flags, which are named warned-<storeid>-<topic>.
    if (opendir(my $dh, $run)) {
        for my $entry (readdir($dh)) {
            next unless $entry =~ /^(warned-\Q$safe\E-.+)\z/;
            unlink("$run/$1");
        }
        closedir($dh);
    }
    eval { $WWID_STATE->cleanup_lock_file($storeid) };

    my @kept;
    my $wwids = eval { $WWID_STATE->tracked_wwids($storeid) } // {};
    if (ref($wwids) eq 'HASH' && keys %$wwids) {
        push @kept, scalar(keys %$wwids) . " device(s) still tracked in "
                  . $WWID_STATE->state_file($storeid);
    } else {
        unlink($WWID_STATE->state_file($storeid));
    }

    # grace => 0: every recorded clone counts here, not only the ones old
    # enough to reap. Passing a bare 0 made it a key of %opts with no
    # value — 'Odd number of elements in hash assignment', and the grace
    # stayed at its 15-minute default, so a clone created minutes ago was
    # not counted and its record was deleted as if there were none.
    my $clones = eval { $WWID_STATE->stale_temp_clones($storeid, grace => 0) } // [];
    if (ref($clones) eq 'ARRAY' && @$clones) {
        push @kept, scalar(@$clones) . " temporary clone(s) recorded in "
                  . $WWID_STATE->temp_clone_file($storeid);
    } else {
        unlink($WWID_STATE->temp_clone_file($storeid));
    }

    warn "Storage '$storeid' has been removed, but this node still has "
       . join(' and ', @kept) . ". Those files are left in place: they are the"
       . " only record of what is still here.\n" if @kept;

    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    $class->_delete_password($storeid);
    $class->_forget_local_state($storeid);

    return;
}

sub on_update_hook {
    my ($class, $storeid, $update, %param) = @_;

    $class->_check_protocol($storeid, $update);

    # A password given on an update replaces the stored one. An update that
    # does not mention it leaves the file alone - 'pvesm set --content ...'
    # must not log the storage out.
    if (defined(my $password = $param{'dell-password'})) {
        $class->_set_password($storeid, $password);
    }

    return undef;
}

sub storage_can_replicate { return 0 }

# ---------------------------------------------------------------------------
# VM configuration backup volumes
#
# A snapshot of a disk restores the disk. The VM's configuration lives in
# /etc/pve, which a storage snapshot does not cover, so a 1 MB volume
# alongside each snapshot carries a copy. bin/pve-dell-config-get reads it
# back when /etc/pve itself is gone.
# ---------------------------------------------------------------------------

sub _vm_config_path {
    my ($class, $vmid) = @_;

    for my $path ("/etc/pve/qemu-server/${vmid}.conf", "/etc/pve/lxc/${vmid}.conf") {
        return $path if -f $path;
    }

    return undef;
}

sub _backup_vm_config {
    my ($class, $scfg, $storeid, $vmid, $snap) = @_;

    my $path = $class->_vm_config_path($vmid);
    unless ($path) {
        warn "No configuration file found for VM $vmid; skipping config backup\n";
        return 0;
    }

    my $content = do {
        open(my $fh, '<', $path) or do {
            warn "Cannot read $path: $!\n";
            return 0;
        };
        local $/;
        <$fh>;
    };

    my $name = $class->naming->encode_config_volume_name($storeid, $vmid, $snap);

    # Another disk of the same VM may already have created it for this
    # snapshot.
    return 1 if eval { $class->_array_get_volume($scfg, $name) };

    eval { $class->_array_create_volume($scfg, $storeid, $name, CONFIG_VOLUME_SIZE) };
    if ($@) {
        warn "Failed to create the config backup volume: $@";
        return 0;
    }

    my $host = $class->_host_name($scfg);
    my $device;

    my $ok = eval {
        $class->_array_map_to_host($scfg, $name, $host);

        my $wwid = $class->_array_get_wwid($scfg, $name)
            or die "no WWID for the config backup volume\n";

        $class->_rescan_transport($scfg);
        my %wait = $class->_wait_opts($scfg,
            timeout => $class->_config_backup_timeout($scfg));
        $device = wait_for_multipath_device($wwid, %wait)
            or die "the device did not appear\n";

        $class->_write_config_volume($device, $vmid, $snap, $content, $path,
            wwid => $wwid);
        eval { cleanup_lun_devices($wwid) };
        1;
    };

    unless ($ok) {
        my $err = $@;
        warn "Config backup for snapshot '$snap' of VM $vmid was skipped: $err"
           . "  This is not fatal; the backup is only read by"
           . " pve-dell-config-get during disaster recovery. Raise"
           . " 'dell-config-backup-timeout' if the fabric is consistently"
           . " slow.\n";
        eval { $class->_release_volume($scfg, $storeid, $name) };
        return 0;
    }

    eval { $class->_array_unmap_from_host($scfg, $name, $host) };

    return 1;
}

# The only place this plugin writes to a block device, so the only place a
# wrong device costs data rather than an error message.
#
# Two independent checks before mkfs, because the device was resolved from a
# WWID by a lookup that has fallbacks — multipathd may be unreachable, and the
# /dev/disk/by-id glob behind it matches a substring. Both checks have to pass
# and neither trusts the other's evidence:
#
#   1. The kernel's own opinion of what this device is: a dm uuid of
#      'mpath-<wwid>', or the NAA in an sd device's wwid attribute / VPD 0x83.
#   2. Its size. A config volume is 1 MB. A VM's disk is not.
#
# Anything that cannot be confirmed is refused. The caller already treats a
# failed config backup as non-fatal and says so, so refusing costs a skipped
# backup — against formatting a running VM's disk.
# Size in bytes, bounded, or undef when it cannot be read. The implementation
# is in Common::Multipath so PowerFlex, which inherits nothing from here, uses
# the same one.
sub _device_size_bytes {
    my ($device) = @_;
    return device_size_bytes($device);
}

sub _write_config_volume {
    my ($class, $device, $vmid, $snap, $content, $source, %opts) = @_;

    my $mount = "/tmp/pve-dellemc-config-$$";
    my $mounted = 0;

    my $wwid = $opts{wwid};
    die "refusing to format '$device': no WWID was given to check it against."
      . " This is a bug; the config backup is skipped rather than guessed at.\n"
        unless defined $wwid && length $wwid;

    unless (device_matches_wwid($device, $wwid)) {
        die "refusing to format '$device': the kernel does not confirm it is"
          . " the device for WWID $wwid. It was resolved by a lookup that has"
          . " fallbacks, and this is the one operation here that destroys what"
          . " it writes over, so an unconfirmed answer is treated as a wrong"
          . " one.\n";
    }

    my $bytes = _device_size_bytes($device);
    if (defined $bytes && $bytes > CONFIG_VOLUME_MAX_BYTES) {
        die "refusing to format '$device': it is $bytes bytes. The config"
          . " backup volume is " . CONFIG_VOLUME_SIZE . " bytes, so this is"
          . " not it, whatever the WWID lookup said.\n";
    }

    my $ok = eval {
        # 1 MB is too small for a journal.
        PVE::Tools::run_command(
            ['/sbin/mkfs.ext4', '-q', '-F', '-O', '^has_journal', $device], timeout => 30);

        mkdir($mount) or die "mkdir $mount failed: $!\n";
        PVE::Tools::run_command(['/bin/mount', $device, $mount], timeout => 30);
        $mounted = 1;

        open(my $fh, '>', "$mount/${vmid}.conf") or die "cannot write the config: $!\n";
        print $fh $content;
        close($fh);

        open(my $mfh, '>', "$mount/metadata.txt") or die "cannot write metadata: $!\n";
        print $mfh "vmid=$vmid\n";
        print $mfh "snapname=$snap\n";
        print $mfh "timestamp=" . time() . "\n";
        print $mfh "source_file=" . ($source // 'unknown') . "\n";
        close($mfh);

        PVE::Tools::run_command(['/bin/sync'], timeout => 10);
        PVE::Tools::run_command(['/bin/umount', $mount], timeout => 30);
        $mounted = 0;
        rmdir($mount);
        1;
    };

    unless ($ok) {
        my $err = $@;
        if ($mounted) {
            eval { PVE::Tools::run_command(['/bin/umount', $mount], timeout => 30) };
            rmdir($mount);
        }
        die $err;
    }

    return 1;
}

sub _delete_config_volume {
    my ($class, $scfg, $storeid, $vmid, $snap) = @_;

    my $name = $class->naming->encode_config_volume_name($storeid, $vmid, $snap);
    return unless eval { $class->_array_get_volume($scfg, $name) };

    $class->_release_volume($scfg, $storeid, $name);

    return 1;
}

sub _cleanup_config_volumes {
    my ($class, $scfg, $storeid, $vmid) = @_;

    my $prefix = $class->naming->volume_prefix($storeid) . "${vmid}-vmconf-";
    my $volumes = eval { $class->_array_list_volumes($scfg, $storeid, $prefix) } // [];

    for my $vol (@$volumes) {
        next unless $vol->{name};
        eval { $class->_release_volume($scfg, $storeid, $vol->{name}) };
        warn "Failed to remove config volume $vol->{name}: $@" if $@;
    }

    return 1;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::BlockBase - abstract PVE storage plugin
base for Dell EMC block families

=head1 SYNOPSIS

    package PVE::Storage::Custom::DellPowerStorePlugin;
    use base 'PVE::Storage::Custom::DellEMC::Common::BlockBase';

    sub type { 'dellpowerstore' }
    sub multipath_vendor { 'DellEMC' }
    sub multipath_product { 'PowerStore' }
    sub multipath_defaults { { ... } }

    # plus the _array_* methods

    __PACKAGE__->register();
    __PACKAGE__->init();

=head1 DESCRIPTION

Implements everything a Dell EMC block plugin does that does not depend on a
particular array's API: PVE schema registration, SAN activation, device
discovery and teardown, snapshots, templates, clones, the multipath drop-in,
and the background orphan reaper.

=head2 Property declaration

PVE merges every registered plugin's C<properties()> into one schema and dies
on a duplicate name. The shared C<dell-*> options are therefore declared by
whichever family class is asked first, and the rest declare only their own.
Adding a family requires no change here.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
