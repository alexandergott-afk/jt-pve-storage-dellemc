# Dell EMC storage plugins for Proxmox VE - Unity XT naming limits
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Unity::Naming;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::Naming);

# Unity's own limits.
#
# NOT VERIFIED ON HARDWARE: Dell documents a LUN name as up to 85 characters.
# The value is read from documentation, not from an array, and a name the
# array quietly truncates is worse than one it rejects — a truncated name
# still looks like it worked until two volumes collide. Confirm on the first
# run against a Unity 480 and record the result in docs/TESTING.md.
#
# 85 is used rather than the inherited 63 because the storeid, the vmid, the
# object kind and a snapshot name all have to fit alongside each other, and
# this project has already had to shorten a snapshot name on PowerVault's 32.
sub max_volume_name_length   { 85 }
sub max_snapshot_name_length { 85 }
sub max_host_name_length     { 85 }

# The storeid's share of a volume name. Wider than the default because the
# names are longer here, but still bounded.
sub max_storeid_length { 32 }

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
