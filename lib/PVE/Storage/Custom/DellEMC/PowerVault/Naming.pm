# Dell EMC storage plugins for Proxmox VE - PowerVault ME naming
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::PowerVault::Naming;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::Naming);

# PowerVault ME names are severely constrained, and the constraints are
# documented rather than guessed:
#
#   "The value can have a maximum of 32 bytes. [...] can include spaces and
#    printable UTF-8 characters except: " , . < \"
#       -- ME5 Series CLI Reference Guide, `create volume`
#
#   Snapshot names have the same 32-byte limit, must be unique system-wide,
#   and exclude " , < \  (a dot is accepted there, but not in a volume name).
#       -- ME5 Series CLI Reference Guide, `create snapshots`
#
# Two consequences drive everything below.
#
# 1. A dot cannot be the volume/snapshot separator the way it is on
#    PowerStore, because a volume name may not contain one. This family uses
#    '-s-' for a snapshot and '-base' for the template marker instead.
#
# 2. 32 bytes is not much. 'pve-' plus a storeid plus a vmid plus a disk id
#    already spends most of it, so the disk component is abbreviated to 'd0'
#    rather than 'disk0', and the storeid gets a hard, small budget.
#
# The names this produces:
#
#     volume            pve-{prefix}-{vmid}-d{n}
#     cloud-init        pve-{prefix}-{vmid}-ci
#     EFI disk          pve-{prefix}-{vmid}-e{n}
#     TPM state         pve-{prefix}-{vmid}-t{n}
#     RAM state         pve-{prefix}-{vmid}-st-{snapname}
#     VM config backup  pve-{prefix}-{vmid}-vc-{snapname}
#     snapshot          {volume}-s-{snapname}
#     template marker   {volume}-base
#
# A snapshot name is decodable back to its volume by dropping the '-s-' tail,
# so the parent is never ambiguous even though the array also reports it.

use constant {
    MAX_NAME  => 32,
    SNAP_SEP  => '-s-',
    BASE_SUFFIX_ME => '-base',
};

sub max_volume_name_length   { MAX_NAME }
sub max_snapshot_name_length { MAX_NAME }

# Host names are limited too, but far less tightly than volumes.
sub max_host_name_length     { 32 }

# 'pve-' + storeid + '-' + vmid(<=8) + '-d' + n(<=3) has to fit in 32, and a
# snapshot then needs '-s-' plus something meaningful after it. Ten characters
# of storeid leaves room for a six-character snapshot name.
sub max_storeid_length { 10 }

# A dot is not permitted in a PowerVault volume name at all.
sub name_charclass_re { qr/[^A-Za-z0-9_-]/ }

my $PFX = qr/[A-Za-z0-9_]+/;

my $RE_DISK      = qr/^pve-($PFX)-(\d+)-d(\d+)$/;
my $RE_CLOUDINIT = qr/^pve-($PFX)-(\d+)-ci$/;
my $RE_EFIDISK   = qr/^pve-($PFX)-(\d+)-e(\d+)$/;
my $RE_TPMSTATE  = qr/^pve-($PFX)-(\d+)-t(\d+)$/;
my $RE_STATE     = qr/^pve-($PFX)-(\d+)-st-(.+)$/;
my $RE_VMCONF    = qr/^pve-($PFX)-(\d+)-vc-(.+)$/;

my $RE_SNAPSHOT  = qr/^(.+)-s-(.+)$/;
my $RE_BASESNAP  = qr/^(.+)-base$/;

# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

sub encode_volume_name {
    my ($class, $storeid, $vmid, $diskid) = @_;

    die "storeid is required\n" unless defined $storeid;
    die "vmid is required\n"    unless defined $vmid;
    die "diskid is required\n"  unless defined $diskid;

    return $class->_fit_name($class->volume_prefix($storeid) . "${vmid}-d${diskid}");
}

sub encode_cloudinit_name {
    my ($class, $storeid, $vmid) = @_;
    die "vmid is required\n" unless defined $vmid;
    return $class->_fit_name($class->volume_prefix($storeid) . "${vmid}-ci");
}

sub encode_efidisk_name {
    my ($class, $storeid, $vmid, $diskid) = @_;
    die "vmid is required\n"   unless defined $vmid;
    die "diskid is required\n" unless defined $diskid;
    return $class->_fit_name($class->volume_prefix($storeid) . "${vmid}-e${diskid}");
}

sub encode_tpmstate_name {
    my ($class, $storeid, $vmid, $diskid) = @_;
    die "vmid is required\n"   unless defined $vmid;
    die "diskid is required\n" unless defined $diskid;
    return $class->_fit_name($class->volume_prefix($storeid) . "${vmid}-t${diskid}");
}

sub encode_state_name {
    my ($class, $storeid, $vmid, $snapname) = @_;

    die "vmid is required\n"     unless defined $vmid;
    die "snapname is required\n" unless defined $snapname;

    my $prefix = $class->volume_prefix($storeid) . "${vmid}-st-";
    return $prefix . $class->_fit_suffix($prefix, $snapname);
}

sub encode_config_volume_name {
    my ($class, $storeid, $vmid, $snapname) = @_;

    die "vmid is required\n"     unless defined $vmid;
    die "snapname is required\n" unless defined $snapname;

    my $prefix = $class->volume_prefix($storeid) . "${vmid}-vc-";
    return $prefix . $class->_fit_suffix($prefix, $snapname);
}

# A generated name that does not fit is a bug, not something to paper over: a
# silently truncated volume name can collide with another VM's.
sub _fit_name {
    my ($class, $name) = @_;

    # The limit comes from the class, never from the constant: PowerFlex
    # subclasses this module with a limit of 31, and reading MAX_NAME here
    # would silently apply PowerVault's 32 to it.
    my $max = $class->max_volume_name_length;

    return $name if length($name) <= $max;

    die "Generated name '$name' is " . length($name) . " bytes, but this array"
      . " accepts at most $max. Use a shorter storage id: this family has far"
      . " less room for names than PowerStore does.\n";
}

sub encode_snapshot_name {
    my ($class, $volume, $snapname) = @_;

    die "volume is required\n"   unless defined $volume;
    die "snapname is required\n" unless defined $snapname;

    my $max    = $class->max_snapshot_name_length;
    my $prefix = $volume . SNAP_SEP;
    my $budget = $max - length($prefix);

    die "Volume name '$volume' leaves no room for a snapshot name on this"
      . " array, which allows $max bytes in total. Use a shorter storage"
      . " id.\n" if $budget < 1;

    my $snap = $class->sanitize($snapname, $budget);
    $snap = substr($snap, 0, $budget);
    $snap =~ s/[-_]+$//;
    $snap = 's' unless length $snap;

    return $prefix . $snap;
}

# Two characters, not nine: on a 32-byte name the infix is most of the budget.
sub temp_clone_infix { '-t' }

sub encode_base_snapshot_name {
    my ($class, $volume) = @_;

    die "volume is required\n" unless defined $volume;

    my $name = $volume . BASE_SUFFIX_ME;

    die "Volume name '$volume' leaves no room for the template marker"
      . " snapshot, which would be " . length($name) . " bytes against a limit"
      . " of " . $class->max_snapshot_name_length . ". Use a shorter storage"
      . " id.\n" if length($name) > $class->max_snapshot_name_length;

    return $name;
}

# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------

sub decode_volume_name {
    my ($class, $name) = @_;

    return undef unless defined $name;

    # A snapshot is a name with a '-s-' or '-base' tail; decode those with
    # decode_snapshot_name instead.
    return undef if $name =~ $RE_SNAPSHOT;
    return undef if $name =~ $RE_BASESNAP;

    if ($name =~ $RE_DISK) {
        return { storage => $1, vmid => int($2), diskid => int($3), type => 'disk' };
    }
    if ($name =~ $RE_CLOUDINIT) {
        return { storage => $1, vmid => int($2), type => 'cloudinit' };
    }
    if ($name =~ $RE_EFIDISK) {
        return { storage => $1, vmid => int($2), diskid => int($3), type => 'efidisk' };
    }
    if ($name =~ $RE_TPMSTATE) {
        return { storage => $1, vmid => int($2), diskid => int($3), type => 'tpmstate' };
    }
    if ($name =~ $RE_STATE) {
        return { storage => $1, vmid => int($2), snapname => $3, type => 'state' };
    }
    if ($name =~ $RE_VMCONF) {
        return { storage => $1, vmid => int($2), snapname => $3, type => 'vmconf' };
    }

    return undef;
}

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

sub array_to_pve_volname {
    my ($class, $name) = @_;

    my $d = $class->decode_volume_name($name);
    return undef unless $d;

    my $vmid = $d->{vmid};
    my $type = $d->{type};

    return "vm-${vmid}-disk-$d->{diskid}"    if $type eq 'disk';
    return "vm-${vmid}-cloudinit"            if $type eq 'cloudinit';
    return "vm-${vmid}-efidisk$d->{diskid}"  if $type eq 'efidisk';
    return "vm-${vmid}-tpmstate$d->{diskid}" if $type eq 'tpmstate';
    return "vm-${vmid}-state-$d->{snapname}" if $type eq 'state';

    return undef;
}

sub is_valid_volume_name {
    my ($class, $name) = @_;

    return 0 unless defined $name && length($name);
    return 0 if length($name) > $class->max_volume_name_length;
    # The array forbids " , . < \ ; this plugin never generates anything but
    # alphanumerics, '-' and '_' anyway.
    return 0 unless $name =~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/;

    return 1;
}

sub is_valid_snapshot_name {
    my ($class, $name) = @_;

    return 0 unless defined $name && length($name);
    return 0 if length($name) > $class->max_snapshot_name_length;
    return 0 unless $name =~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/;

    return 1;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::PowerVault::Naming - name limits for PowerVault
ME series arrays

=head1 DESCRIPTION

PowerVault ME accepts at most 32 bytes for a volume or snapshot name, and a
volume name may not contain a dot. Both are documented in the ME5 Series CLI
Reference Guide under C<create volume> and C<create snapshots>.

That is far tighter than PowerStore, so this family shortens the object names
(C<d0> rather than C<disk0>) and separates a snapshot from its volume with
C<-s-> rather than a dot.

A generated name that would exceed 32 bytes raises an error naming the storage
id as the thing to shorten. Silently truncating would let two VMs' volumes
collide on one name.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
