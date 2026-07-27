# Dell EMC storage plugins for Proxmox VE - naming conventions
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::Naming;

use strict;
use warnings;

# Naming is family-agnostic here; the per-family length and character limits
# are class methods so that a family module can override them:
#
#     package ...::DellEMC::PowerStore::Naming;
#     use base 'PVE::Storage::Custom::DellEMC::Common::Naming';
#     sub max_volume_name_length { 128 }
#
# Everything is a class method rather than an exported function on purpose:
# one PVE process (pvedaemon, pvestatd) loads every Dell plugin at once, so
# limits must never live in package-global mutable state.
#
# Name shapes produced here (see docs/NAMING_CONVENTIONS.md):
#
#     volume            pve-{prefix}-{vmid}-disk{n}
#     cloud-init        pve-{prefix}-{vmid}-cloudinit
#     EFI disk          pve-{prefix}-{vmid}-efidisk{n}
#     TPM state         pve-{prefix}-{vmid}-tpmstate{n}
#     RAM state         pve-{prefix}-{vmid}-state-{snapname}
#     VM config backup  pve-{prefix}-{vmid}-vmconf-{snapname}
#     snapshot          {volume}.pve-snap-{snapname}
#     template marker   {volume}.pve-base
#     host              pve-{cluster}-{node}
#     shared host group pve-{cluster}-shared
#
# {prefix} is the sanitized storeid. It never contains a hyphen (hyphens
# become underscores), which is what keeps the patterns above unambiguous:
# the field after the last hyphen-delimited numeric group is always the
# object kind.

# ---------------------------------------------------------------------------
# Per-family limits. Conservative defaults; families widen them.
# ---------------------------------------------------------------------------

sub max_volume_name_length   { 63 }
sub max_snapshot_name_length { 63 }
sub max_host_name_length     { 63 }

# How much of the storeid may appear inside an object name. Keeping this
# short leaves room for the vmid and the object kind within the volume name
# budget.
sub max_storeid_length       { 24 }

# Characters kept verbatim by sanitize(). Anything else becomes '_'.
# '.' is deliberately excluded: it separates a volume from its snapshot
# suffix, so allowing it inside a volume name would make snapshot names
# ambiguous.
sub name_charclass_re        { qr/[^A-Za-z0-9_-]/ }

# ---------------------------------------------------------------------------
# Patterns. The storage portion cannot contain '-', so these are unambiguous.
# ---------------------------------------------------------------------------

my $PFX = qr/[A-Za-z0-9_]+/;

my $RE_DISK      = qr/^pve-($PFX)-(\d+)-disk(\d+)\z/;
my $RE_CLOUDINIT = qr/^pve-($PFX)-(\d+)-cloudinit\z/;
my $RE_EFIDISK   = qr/^pve-($PFX)-(\d+)-efidisk(\d+)\z/;
my $RE_TPMSTATE  = qr/^pve-($PFX)-(\d+)-tpmstate(\d+)\z/;
my $RE_STATE     = qr/^pve-($PFX)-(\d+)-state-(.+)\z/;
my $RE_VMCONF    = qr/^pve-($PFX)-(\d+)-vmconf-(.+)\z/;

my $RE_SNAPSHOT  = qr/^(.+)\.pve-snap-(.+)\z/;
my $RE_BASESNAP  = qr/^(.+)\.pve-base\z/;

use constant SNAPSHOT_INFIX => '.pve-snap-';
use constant BASE_SUFFIX    => '.pve-base';

# ---------------------------------------------------------------------------
# Sanitizing
# ---------------------------------------------------------------------------

# Make an arbitrary string safe to embed in an array object name.
#
# Invalid characters are replaced with '_' rather than deleted. Deleting
# them silently merges distinct inputs — a storeid of 'pve.1' and one of
# 'pve1' would produce the same prefix and the two storages would then see
# each other's volumes.
sub sanitize {
    my ($class, $str, $max_len) = @_;

    return '' unless defined $str && length($str);
    $max_len //= $class->max_volume_name_length;

    my $re = $class->name_charclass_re;
    my $out = $str;
    $out =~ s/$re/_/g;
    # Collapse runs of separators introduced by the substitution above.
    $out =~ s/_{2,}/_/g;
    # Array names must start with an alphanumeric.
    $out =~ s/^[^A-Za-z0-9]+//;
    $out = substr($out, 0, $max_len) if $max_len && length($out) > $max_len;
    # Truncation can leave a trailing separator behind.
    $out =~ s/[-_]+$//;

    return length($out) ? $out : 'pve';
}

# The storeid as it appears inside object names.
#
# Hyphens become underscores so that the hyphen stays available as the field
# separator in the name patterns. Every caller that builds a name or a
# server-side filter MUST go through this one function: in the Pure plugin
# the same transformation existed in two places, drifted apart, and storages
# whose id contained a '.' listed zero disks in the UI (upstream issue #6).
#
# The underscore conversion also stops one storage's prefix from containing
# another's, which would let it claim the other's volumes: storeids 'ps' and
# 'ps-1' would otherwise yield the prefixes 'pve-ps-' and 'pve-ps-1-'. They
# become 'pve-ps-' and 'pve-ps_1-' instead.
#
# Residual caveat: two storeids that differ only in a character this maps to
# '_' (for example 'ps-1' and 'ps_1') share a prefix and would see each
# other's volumes. Avoid that pairing when naming storages.
sub storeid_to_prefix {
    my ($class, $storeid) = @_;

    die "storeid is required\n" unless defined $storeid;

    my $prefix = $class->sanitize($storeid, $class->max_storeid_length);
    $prefix =~ s/-/_/g;

    return $prefix;
}

# Name prefix shared by every object this storage owns. Use it for
# server-side filters (`name=ilike.<prefix>%`) and for ownership checks.
sub volume_prefix {
    my ($class, $storeid) = @_;
    return 'pve-' . $class->storeid_to_prefix($storeid) . '-';
}

# ---------------------------------------------------------------------------
# Encoding: PVE identifiers -> array object names
# ---------------------------------------------------------------------------

sub encode_volume_name {
    my ($class, $storeid, $vmid, $diskid) = @_;

    die "storeid is required\n" unless defined $storeid;
    die "vmid is required\n"    unless defined $vmid;
    die "diskid is required\n"  unless defined $diskid;

    return $class->volume_prefix($storeid) . "${vmid}-disk${diskid}";
}

sub encode_cloudinit_name {
    my ($class, $storeid, $vmid) = @_;

    die "vmid is required\n" unless defined $vmid;
    return $class->volume_prefix($storeid) . "${vmid}-cloudinit";
}

sub encode_efidisk_name {
    my ($class, $storeid, $vmid, $diskid) = @_;

    die "vmid is required\n"   unless defined $vmid;
    die "diskid is required\n" unless defined $diskid;
    return $class->volume_prefix($storeid) . "${vmid}-efidisk${diskid}";
}

sub encode_tpmstate_name {
    my ($class, $storeid, $vmid, $diskid) = @_;

    die "vmid is required\n"   unless defined $vmid;
    die "diskid is required\n" unless defined $diskid;
    return $class->volume_prefix($storeid) . "${vmid}-tpmstate${diskid}";
}

# RAM state volume written by `qm snapshot --vmstate`.
sub encode_state_name {
    my ($class, $storeid, $vmid, $snapname) = @_;

    die "vmid is required\n"     unless defined $vmid;
    die "snapname is required\n" unless defined $snapname;

    my $prefix = $class->volume_prefix($storeid) . "${vmid}-state-";
    my $snap   = $class->_fit_suffix($prefix, $snapname);

    return "${prefix}${snap}";
}

# Small volume holding the VM config as it was at snapshot time, so that a
# rollback can restore the configuration together with the disk.
sub encode_config_volume_name {
    my ($class, $storeid, $vmid, $snapname) = @_;

    die "vmid is required\n"     unless defined $vmid;
    die "snapname is required\n" unless defined $snapname;

    my $prefix = $class->volume_prefix($storeid) . "${vmid}-vmconf-";
    my $snap   = $class->_fit_suffix($prefix, $snapname);

    return "${prefix}${snap}";
}

# Sanitize a trailing name component and shorten it so that prefix+component
# fits the volume name budget.
sub _fit_suffix {
    my ($class, $prefix, $suffix) = @_;

    my $budget = $class->max_volume_name_length - length($prefix);
    die "name prefix '$prefix' leaves no room for a suffix\n" if $budget < 1;

    my $out = $class->sanitize($suffix, $budget);
    # sanitize() falls back to 'pve' when nothing survives; that fallback can
    # itself exceed a very tight budget.
    $out = substr($out, 0, $budget);
    $out =~ s/[-_]+$//;

    return length($out) ? $out : 'x';
}

# Snapshot names are '{volume}.pve-snap-{snapname}'. The volume part is
# already sanitized, so only the suffix needs work here.
# Refuse a snapshot name the array cannot hold under that name.
#
# The sanitiser exists so a name always reaches the array in a form it will
# accept, and for a storeid that is right — the operator sees the storage id
# they chose, and the array name is an implementation detail. For a SNAPSHOT
# name it is not: PVE keeps the name the user typed, and every later lookup
# encodes it again. As long as encoding is deterministic that still works,
# but the snapshot is listed under a different name than the one in the VM
# configuration, and two names that sanitise alike collide.
#
# PVE validates a snapshot name as 'pve-configid', which permits a trailing
# '-'; the sanitiser strips it. Rather than quietly storing 'trailing' when
# the user asked for 'trailing-', say so and let them choose a name that
# survives.
#
# Truncation is not covered here: a name too long for the array is a
# different problem with a different message, and the caller checks the
# budget before this.
sub _assert_snapname_survives {
    my ($class, $snapname, $encoded, $budget) = @_;

    return 1 unless defined $snapname && length $snapname;
    return 1 if $encoded eq $snapname;

    # Truncation is NOT refused, and the difference matters. PVE allows a
    # 40-character snapshot name; a whole PowerVault volume name is 32 bytes.
    # Refusing everything that does not fit would reject 'before-upgrade' on
    # a realistic storage id, which is not a defect to fix but a limit to
    # live with — and the plugin already makes such names fit deterministically,
    # so lookups, deletes and rollbacks all still find the snapshot.
    #
    # What is refused is the avoidable case: a name the array would ALTER
    # rather than shorten. The operator can simply choose another.
    return 1 if defined $budget && length($snapname) > $budget;

    die "Snapshot name '$snapname' cannot be stored on this array under that"
      . " name: it would become '$encoded'. The snapshot would then be listed"
      . " under a name that does not match the one in the VM configuration,"
      . " and a second snapshot whose name reduces to the same thing would"
      . " collide with it. Use '$encoded', or a name without leading or"
      . " trailing punctuation.\n";
}

sub encode_snapshot_name {
    my ($class, $volume, $snapname) = @_;

    die "volume is required\n"   unless defined $volume;
    die "snapname is required\n" unless defined $snapname;

    my $prefix = $volume . SNAPSHOT_INFIX;
    my $budget = $class->max_snapshot_name_length - length($prefix);
    die "volume name '$volume' leaves no room for a snapshot suffix\n"
        if $budget < 1;

    my $snap = $class->sanitize($snapname, $budget);
    $snap = substr($snap, 0, $budget);
    $snap =~ s/[-_]+$//;
    $snap = 'snap' unless length($snap);

    $class->_assert_snapname_survives($snapname, $snap, $budget);

    return "${prefix}${snap}";
}

# Short-lived clone created so a snapshot can be read through a device.
#
# It has to go through the naming class like everything else: built by hand it
# would ignore the family's length limit, and PowerVault (32 bytes) and
# PowerFlex (31) both reject what PowerStore accepts. The token only has to
# distinguish concurrent attempts, so it is shortened from the front, keeping
# the least significant digits.
sub temp_clone_infix { '-tmpsnap-' }

sub encode_temp_clone_name {
    my ($class, $volume, $token) = @_;

    die "volume is required\n" unless defined $volume;
    $token = 'x' unless defined $token && length $token;

    my $prefix = $volume . $class->temp_clone_infix;
    my $budget = $class->max_volume_name_length - length($prefix);

    die "Volume name '$volume' leaves no room for a temporary snapshot clone"
      . " name, which this family needs in order to read a snapshot. Use a"
      . " shorter storage id.\n" if $budget < 2;

    my $suffix = $class->sanitize($token, length($token));
    $suffix = substr($suffix, -$budget) if length($suffix) > $budget;
    $suffix =~ s/^[-_]+//;
    $suffix = 'x' unless length $suffix;

    return $prefix . $suffix;
}

# Marker snapshot that turns a volume into a template base.
sub encode_base_snapshot_name {
    my ($class, $volume) = @_;

    die "volume is required\n" unless defined $volume;
    return $volume . BASE_SUFFIX;
}

sub encode_host_name {
    my ($class, $cluster, $node) = @_;

    $cluster = 'pve' unless defined $cluster && length($cluster);
    my $max = int(($class->max_host_name_length - 5) / 2);
    my $c   = $class->sanitize($cluster, $max);

    return "pve-${c}-shared" unless defined $node && length($node);

    my $n = $class->sanitize($node, $max);
    return "pve-${c}-${n}";
}

# Host group used when several nodes share one mapping
# (dell-host-mode shared).
sub encode_host_group_name {
    my ($class, $cluster) = @_;
    return $class->encode_host_name($cluster, undef);
}

# ---------------------------------------------------------------------------
# Decoding: array object names -> PVE identifiers
# ---------------------------------------------------------------------------

# Returns a hashref describing the object, or undef when the name is not one
# this plugin created. Snapshots decode to undef here; use
# decode_snapshot_name() for those.
# A vmid, or 0 if the digits are not one.
#
# PVE vmids are integers from 1 to 999999999. A longer run of digits is not a
# name this plugin wrote, and passing it on would hand the caller something
# Perl has already turned into a float: '1e+30' would reach PVE inside a
# volid, where nothing expects it. 0 is not a vmid either, which is what lets
# every caller write `my $vmid = _valid_vmid($2) or return undef`.
sub _valid_vmid {
    my ($digits) = @_;

    return 0 unless defined $digits && $digits =~ /\A\d{1,9}\z/;

    my $vmid = $digits + 0;

    return $vmid >= 1 ? $vmid : 0;
}

sub decode_volume_name {
    my ($class, $name) = @_;

    return undef unless defined $name;
    # A dot only ever appears in a snapshot name.
    return undef if $name =~ /\./;

    if ($name =~ $RE_DISK) {
        my $vmid = _valid_vmid($2) or return undef;
        return { storage => $1, vmid => $vmid, diskid => int($3), type => 'disk' };
    }
    if ($name =~ $RE_CLOUDINIT) {
        my $vmid = _valid_vmid($2) or return undef;
        return { storage => $1, vmid => $vmid, type => 'cloudinit' };
    }
    if ($name =~ $RE_EFIDISK) {
        my $vmid = _valid_vmid($2) or return undef;
        return { storage => $1, vmid => $vmid, diskid => int($3), type => 'efidisk' };
    }
    if ($name =~ $RE_TPMSTATE) {
        my $vmid = _valid_vmid($2) or return undef;
        return { storage => $1, vmid => $vmid, diskid => int($3), type => 'tpmstate' };
    }
    if ($name =~ $RE_STATE) {
        my $vmid = _valid_vmid($2) or return undef;
        return { storage => $1, vmid => $vmid, snapname => $3, type => 'state' };
    }
    if ($name =~ $RE_VMCONF) {
        my $vmid = _valid_vmid($2) or return undef;
        return { storage => $1, vmid => $vmid, snapname => $3, type => 'vmconf' };
    }

    return undef;
}

# '{volume}.pve-snap-{snapname}' -> { volume, snapname }
# '{volume}.pve-base'            -> { volume, is_base }
sub decode_snapshot_name {
    my ($class, $name) = @_;

    return undef unless defined $name;

    if ($name =~ $RE_SNAPSHOT) {
        return { volume => $1, snapname => $2, is_base => 0 };
    }
    if ($name =~ $RE_BASESNAP) {
        return { volume => $1, snapname => undef, is_base => 1 };
    }

    return undef;
}

sub is_snapshot_name {
    my ($class, $name) = @_;
    return defined($class->decode_snapshot_name($name)) ? 1 : 0;
}

sub is_config_volume {
    my ($class, $name) = @_;
    return 0 unless defined $name;
    return $name =~ $RE_VMCONF ? 1 : 0;
}

sub is_state_volume {
    my ($class, $name) = @_;
    return 0 unless defined $name;
    return $name =~ $RE_STATE ? 1 : 0;
}

# The safety boundary for every list, delete and cleanup path: an object is
# only ever touched when this returns true.
#
# Pass $storeid whenever it is known. Without it the check only proves the
# name was produced by some PVE plugin, which is not enough to authorize a
# delete on an array shared with other storages.
sub is_pve_managed_volume {
    my ($class, $name, $storeid) = @_;

    return 0 unless defined $name;

    if (defined $storeid) {
        my $prefix = $class->volume_prefix($storeid);
        return 0 unless index($name, $prefix) == 0;
    }

    # Strip a snapshot suffix before matching the volume shape.
    my $base = $name;
    if (my $snap = $class->decode_snapshot_name($name)) {
        $base = $snap->{volume};
    }

    # A temporary snapshot-access clone is one of ours too. It is generated by
    # encode_temp_clone_name from a volume name this storage owns, and it is
    # deleted again by the same code — so a gate that refuses it would refuse
    # the cleanup of the very thing it is guarding. Its name is
    # '<volume><infix><token>' and the volume in front of the infix is what
    # decides ownership.
    my $infix = $class->temp_clone_infix;
    if (index($base, $infix) > 0) {
        my ($owner) = split /\Q$infix\E/, $base, 2;
        $base = $owner if defined $owner && length $owner;
    }

    return defined($class->decode_volume_name($base)) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# PVE volume names <-> array object names
# ---------------------------------------------------------------------------

# PVE hands the plugin names like 'vm-100-disk-0', 'base-100-disk-0',
# 'vm-100-cloudinit', 'vm-100-state-snap1', or, for a linked clone,
# 'base-100-disk-0/vm-101-disk-0'.
sub pve_volname_to_array {
    my ($class, $storeid, $volname) = @_;

    die "storeid is required\n" unless defined $storeid;
    die "volname is required\n" unless defined $volname;

    $volname =~ s|^images/||;

    # Linked clone: only the clone half has its own array object.
    if ($volname =~ m|^base-\d+-disk-\d+/(.+)\z|) {
        $volname = $1;
    }

    if ($volname =~ /^(?:vm|base)-(\d+)-disk-(\d+)\z/) {
        return $class->encode_volume_name($storeid, $1, $2);
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-cloudinit\z/) {
        return $class->encode_cloudinit_name($storeid, $1);
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-efidisk(\d+)\z/) {
        return $class->encode_efidisk_name($storeid, $1, $2);
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-tpmstate(\d+)\z/) {
        return $class->encode_tpmstate_name($storeid, $1, $2);
    }
    if ($volname =~ /^(?:vm|base)-(\d+)-state-(.+)\z/) {
        return $class->encode_state_name($storeid, $1, $2);
    }

    die "Unrecognized PVE volume name format: $volname\n";
}

# Inverse of pve_volname_to_array for the plain (non-clone) forms.
# Returns undef for names this plugin does not own.
sub array_to_pve_volname {
    my ($class, $name) = @_;

    my $d = $class->decode_volume_name($name);
    return undef unless $d;

    my $vmid = $d->{vmid};
    my $type = $d->{type};

    return "vm-${vmid}-disk-$d->{diskid}"     if $type eq 'disk';
    return "vm-${vmid}-cloudinit"             if $type eq 'cloudinit';
    return "vm-${vmid}-efidisk$d->{diskid}"   if $type eq 'efidisk';
    return "vm-${vmid}-tpmstate$d->{diskid}"  if $type eq 'tpmstate';
    return "vm-${vmid}-state-$d->{snapname}"  if $type eq 'state';

    # vmconf volumes are plugin bookkeeping and have no PVE volume name.
    return undef;
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

sub is_valid_volume_name {
    my ($class, $name) = @_;

    return 0 unless defined $name && length($name);
    return 0 if length($name) > $class->max_volume_name_length;
    return 0 unless $name =~ /^[A-Za-z0-9][A-Za-z0-9_-]*\z/;

    return 1;
}

sub is_valid_snapshot_name {
    my ($class, $name) = @_;

    return 0 unless defined $name && length($name);
    return 0 if length($name) > $class->max_snapshot_name_length;
    return 0 unless $name =~ /^[A-Za-z0-9][A-Za-z0-9_.-]*\z/;

    return 1;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::Naming - object naming shared by the
Dell EMC storage plugins

=head1 SYNOPSIS

    use PVE::Storage::Custom::DellEMC::Common::Naming;
    my $N = 'PVE::Storage::Custom::DellEMC::Common::Naming';

    $N->encode_volume_name('ps1', 100, 0);   # pve-ps1-100-disk0
    $N->decode_volume_name('pve-ps1-100-disk0');
    # { storage => 'ps1', vmid => 100, diskid => 0, type => 'disk' }

    $N->pve_volname_to_array('ps1', 'vm-100-disk-0');  # pve-ps1-100-disk0
    $N->array_to_pve_volname('pve-ps1-100-disk0');     # vm-100-disk-0

    $N->is_pve_managed_volume('pve-ps1-100-disk0', 'ps1');  # 1
    $N->is_pve_managed_volume('production-lun-7', 'ps1');   # 0

=head1 DESCRIPTION

All methods are class methods so a family module can subclass this one and
override the length limits without introducing shared mutable state — a
single PVE process loads every Dell plugin at once.

=head1 SAFETY

C<is_pve_managed_volume> is the ownership gate for every destructive path.
Call it with the storeid; the two-argument form only proves that the name
looks like some PVE plugin's, which does not authorize deleting it.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
