# Dell EMC storage plugins for Proxmox VE - shared storage.cfg schema
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::Schema;

use strict;
use warnings;

# The dell-* options every Dell EMC family shares, and the rule that decides
# which plugin declares them.
#
# PVE merges every registered plugin's properties() into ONE schema and dies
# with "duplicate property" if two plugins declare the same name — see
# PVE::SectionConfig::init. That failure is not scoped to the offending
# plugin: it happens while PVE builds the storage schema, so every storage on
# the node stops working.
#
# So exactly one registered class may declare the shared options. Whichever
# family PVE asks first takes the job; the rest declare only their own. This
# lives here rather than in BlockBase because PowerFlex needs the same shared
# options while having nothing else in common with a block plugin.

my $OWNER;

sub common_properties {
    return {
        'dell-portal' => {
            description => "Management IP address or hostname of the array.",
            type => 'string',
        },
        'dell-username' => {
            description => "Username for the array's management API.",
            type => 'string',
        },
        'dell-password' => {
            description => "Password for the array's management API.",
            type => 'string',
        },
        'dell-ssl-verify' => {
            description => "Verify the array's SSL certificate.",
            type => 'boolean',
            default => 0,
        },
        'dell-protocol' => {
            description => "Data path: 'iscsi' or 'fc' on the SAN families,"
                . " 'sdc' or 'nvme' on PowerFlex.",
            type => 'string',
            enum => ['iscsi', 'fc', 'sdc', 'nvme'],
            default => 'iscsi',
        },
        'dell-host-mode' => {
            description => "How host objects are created on the array."
                . " 'per-node' registers one host per PVE node, which is what"
                . " lets the array report per-node connectivity. 'shared'"
                . " registers a single host group for the whole cluster.",
            type => 'string',
            enum => ['per-node', 'shared'],
            default => 'per-node',
        },
        'dell-cluster-name' => {
            description => "Cluster name used when naming host objects on the"
                . " array. Distinguishes several PVE clusters sharing one array.",
            type => 'string',
            default => 'pve',
            optional => 1,
        },
        'dell-device-timeout' => {
            description => "Seconds to wait for a volume's device to appear"
                . " after it has been mapped.",
            type => 'integer',
            minimum => 10,
            maximum => 300,
            default => 60,
        },
        'dell-portal-probe-timeout' => {
            description => "Seconds for the TCP pre-check that skips iSCSI"
                . " portals this node cannot reach, before iscsiadm discovery"
                . " and login are attempted. Arrays routinely publish more"
                . " portal addresses than a given node is cabled for, and each"
                . " unreachable one otherwise costs 30s discovery plus 60s"
                . " login. Set to 0 to disable the pre-check.",
            type => 'integer',
            minimum => 0,
            maximum => 30,
            default => 2,
        },
        'dell-status-timeout' => {
            description => "API timeout in seconds on the pvestatd health path"
                . " (activate_storage and the foreground of status). That path"
                . " is polled roughly every 10 seconds and PVE processes"
                . " storages sequentially, so a slow array would otherwise back"
                . " up the whole cycle and starve sibling storages on the node"
                . " into 'inactive'. The health client makes a single attempt:"
                . " the next poll is the retry.",
            type => 'integer',
            minimum => 2,
            maximum => 60,
            default => 5,
        },
        'dell-activate-deadline' => {
            description => "Cumulative wall-clock budget in seconds for the"
                . " iSCSI portal discovery and login loop in activate_storage."
                . " Once the budget is spent AND at least one portal is logged"
                . " in, the rest are deferred to a later activation. Never"
                . " enforced while zero paths are up. Set to 0 to disable.",
            type => 'integer',
            minimum => 0,
            maximum => 300,
            default => 30,
        },
        'dell-rollback-any-snapshot' => {
            description => "Allow rolling back to a snapshot that is not the"
                . " most recent one. Off by default: Dell does not document"
                . " what a restore does to the snapshots taken after the one"
                . " being restored, and on an array that discards them PVE"
                . " would go on listing restore points that no longer exist."
                . " Turn this on only if you have verified the behaviour on"
                . " your own array and model.",
            type => 'boolean',
            default => 0,
            optional => 1,
        },
        'dell-config-backup' => {
            description => "Write the VM configuration to a small volume"
                . " beside each snapshot, so it can be recovered when"
                . " /etc/pve is gone. Each snapshot of a VM costs one extra"
                . " volume on the array, so turn this off on an array whose"
                . " volume count is the binding limit. Families whose limits"
                . " are too low do not offer it at all.",
            type => 'boolean',
            default => 1,
            optional => 1,
        },
        'dell-config-backup-timeout' => {
            description => "Seconds to wait for the auxiliary 1 MB config"
                . " backup volume's device during a snapshot. That volume is"
                . " only read by pve-dell-config-get for disaster recovery, so"
                . " a shorter separate timeout keeps a slow fabric from"
                . " stalling every snapshot.",
            type => 'integer',
            minimum => 5,
            maximum => 60,
            default => 15,
        },
        'dell-rescan-interval' => {
            description => "Minimum seconds between the periodic SAN rescans"
                . " activate_storage performs. PVE calls activate_storage on"
                . " every pvestatd poll, so running a host-wide multipath"
                . " reconfigure and udev trigger unconditionally means doing it"
                . " six times a minute on every node, which keeps device-mapper"
                . " in flux while other operations are trying to discover"
                . " devices. A rescan always happens immediately when this node"
                . " logs in to a new portal. Set to 0 to rescan on every"
                . " activation.",
            type => 'integer',
            minimum => 0,
            maximum => 3600,
            default => 300,
            optional => 1,
        },
    };
}

sub common_options {
    return {
        'dell-portal'                => { fixed => 1 },
        'dell-username'              => {},
        'dell-password'              => {},
        'dell-ssl-verify'            => { optional => 1 },
        'dell-protocol'              => { optional => 1 },
        'dell-host-mode'             => { optional => 1 },
        'dell-cluster-name'          => { optional => 1 },
        'dell-device-timeout'        => { optional => 1 },
        'dell-portal-probe-timeout'  => { optional => 1 },
        'dell-status-timeout'        => { optional => 1 },
        'dell-activate-deadline'     => { optional => 1 },
        'dell-rollback-any-snapshot' => { optional => 1 },
        'dell-config-backup'         => { optional => 1 },
        'dell-config-backup-timeout' => { optional => 1 },
        'dell-rescan-interval'       => { optional => 1 },
        nodes   => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        shared  => { optional => 1 },
    };
}

# What a family plugin's properties() should return: its own, plus the shared
# ones if it is the family that got asked first.
sub properties {
    my ($class, $family_class, $family_properties) = @_;

    my $props = { %{ $family_properties // {} } };

    $OWNER = $family_class unless defined $OWNER;
    if ($OWNER eq $family_class) {
        my $common = $class->common_properties();
        $props->{$_} //= $common->{$_} for keys %$common;
    }

    return $props;
}

# Options are safe to repeat: PVE looks each one up in the merged property
# list and only complains when nothing declared it.
sub options {
    my ($class, $family_options) = @_;

    return {
        %{ $class->common_options() },
        %{ $family_options // {} },
    };
}

# Which class declared the shared options. Tests use this; nothing else
# should need it.
sub owner { return $OWNER }

# Test seam only.
sub _reset_owner { $OWNER = undef; return }

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::Schema - the shared storage.cfg
options and the rule for declaring them once

=head1 DESCRIPTION

PVE merges every plugin's C<properties()> into one schema and dies on a
duplicate name, which takes down every storage on the node rather than just
the offending plugin. The shared C<dell-*> options are therefore declared by
whichever family class PVE asks first.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
