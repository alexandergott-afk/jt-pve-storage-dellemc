# Dell EMC storage plugins for Proxmox VE - PowerFlex naming
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::PowerFlex::Naming;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::PowerVault::Naming);

# PowerFlex limits volume and snapshot names to 31 characters — one fewer
# than PowerVault, and for the same practical reason the short name shapes
# from that family are reused here rather than PowerStore's longer ones.
#
#     volume            pve-{prefix}-{vmid}-d{n}
#     snapshot          {volume}-s-{snapname}
#     template marker   {volume}-base
#
# Inheriting PowerVault::Naming keeps one implementation of the compact
# scheme; only the limit differs.

use constant MAX_NAME => 31;

sub max_volume_name_length   { MAX_NAME }
sub max_snapshot_name_length { MAX_NAME }
sub max_host_name_length     { MAX_NAME }

# 'pve-' + prefix + '-' + vmid + '-d' + n leaves room for '-s-' plus a few
# characters of snapshot name.
sub max_storeid_length { 9 }

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::PowerFlex::Naming - PowerFlex name limits

=head1 DESCRIPTION

PowerFlex accepts at most 31 characters for a volume or snapshot name. The
compact naming scheme is inherited from
L<PVE::Storage::Custom::DellEMC::PowerVault::Naming>, which solves the same
problem one character higher.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
