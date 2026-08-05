# Dell EMC storage plugins for Proxmox VE - Unity XT naming limits
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Unity::Naming;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::Naming);

# Unity's own limits.
#
# 63, from Dell's own code rather than from prose: `gounity`, the client
# Dell's CSI driver uses against Unity, carries
#
#     LunNameMaxLength = 63
#     if len(name) > LunNameMaxLength {
#         return ..., fmt.Errorf("lun name %s should not exceed 63 characters")
#     }
#
# and refuses the request before it reaches the array. An earlier draft of
# this file said 85, read from a documentation page about Unisphere; the
# number that matters is the one Dell's own client enforces, because it is
# the one derived from what the array does. Filesystems have the same 63.
#
# This is also exactly the inherited default, so nothing here widens the
# shared limit — it records where the number comes from.
sub max_volume_name_length   { 63 }
sub max_snapshot_name_length { 63 }
sub max_host_name_length     { 63 }

# The storeid's share of a volume name. The whole name is 63, and the vmid,
# the object kind and a snapshot name all have to fit alongside it, so this
# stays at the shared default rather than being widened to match PowerStore's.
sub max_storeid_length { 24 }

# The inherited character rule stays narrower than what Unity accepts: '.'
# separates a volume from its snapshot suffix in this plugin's own naming
# (SNAPSHOT_INFIX is '.pve-snap-'), so it must never appear inside a generated
# name even though the array would take it. That is what PowerVault's separate
# Naming subclass exists for, in the other direction.

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Unity::Naming - Unity XT name limits

=head1 DESCRIPTION

Narrows L<PVE::Storage::Custom::DellEMC::Common::Naming> to what Unity
accepts. Everything else, including the C<pve-{storeid}-> ownership prefix and
the snapshot and template markers, is inherited unchanged.

Nothing in this file has been checked against a Unity array. See
F<docs/TESTING.md>.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
