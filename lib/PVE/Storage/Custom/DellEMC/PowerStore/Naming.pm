# Dell EMC storage plugins for Proxmox VE - PowerStore naming limits
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::PowerStore::Naming;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::Naming);

# PowerStore's own limits, which are wider than the conservative defaults in
# Common::Naming.
#
# NOT YET VERIFIED against hardware: PowerStore Manager is documented as
# accepting up to 128 characters for a volume name, with letters, digits and
# '_ - .' allowed. Confirm before relying on the full length; a name the array
# rejects surfaces as a failed volume create at the worst moment. See
# docs/TESTING.md.
#
# The inherited character rule stays deliberately narrower than PowerStore's:
# '.' separates a volume from its snapshot suffix in this plugin's own naming,
# so it must never appear inside a generated name even though the array would
# accept it.

sub max_volume_name_length   { 128 }
sub max_snapshot_name_length { 128 }
sub max_host_name_length     { 128 }

# The storeid's share of a volume name. Wider than the default because the
# names are longer here, but still bounded: the vmid, the object kind and a
# snapshot name all have to fit alongside it.
sub max_storeid_length { 32 }

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::PowerStore::Naming - PowerStore name limits

=head1 DESCRIPTION

Narrows L<PVE::Storage::Custom::DellEMC::Common::Naming> to what PowerStore
accepts. Everything else, including the C<pve-{storeid}-> ownership prefix, is
inherited unchanged.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
