#!/usr/bin/perl
# PowerStore plugin registration and mapping tests.
#
# The schema checks here mirror what PVE::SectionConfig::init does at boot. A
# mistake in either one does not break this storage — it dies while PVE is
# building the storage schema, which takes down every storage on the node.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage::Plugin is not available (not a Proxmox VE node)';
}

use PVE::Storage::Custom::DellPowerStorePlugin;

my $P = 'PVE::Storage::Custom::DellPowerStorePlugin';
my $BASE = 'PVE::Storage::Custom::DellEMC::Common::BlockBase';

# ---------------------------------------------------------------------------
# What PVE checks when it loads a third-party plugin
# ---------------------------------------------------------------------------

ok($P->isa('PVE::Storage::Plugin'), 'derived from PVE::Storage::Plugin');
ok($P->can('api'), 'provides api()');
is($P->api, 13, 'implements storage API 13');
ok($P->api <= PVE::Storage::APIVER(), 'not newer than the running PVE')
    if PVE::Storage->can('APIVER');
is($P->type, 'dellpowerstore', 'storage type');

ok(grep({ $_ eq 'dellpowerstore' } @PVE::Storage::Plugin::SHARED_STORAGE),
    'registered as shared-capable, which live migration needs');

# ---------------------------------------------------------------------------
# Schema, checked the way SectionConfig::init checks it
# ---------------------------------------------------------------------------

my $props = $P->properties();
my $opts  = $P->options();
my $base_props = PVE::Storage::Plugin->private()->{propertyList} // {};

# init() dies with "undefined property" if an option names something no
# plugin declared. That is a boot failure for the whole storage layer.
for my $opt (sort keys %$opts) {
    ok($props->{$opt} || $base_props->{$opt},
        "option '$opt' resolves to a declared property");
}

# init() dies with "duplicate property" if we redeclare something PVE already
# owns.
for my $prop (sort keys %$props) {
    ok(!$base_props->{$prop}, "property '$prop' does not collide with PVE's own");
    like($prop, qr/^(?:dell|pstore)-/, "property '$prop' is namespaced");
}

ok($props->{'dell-portal'}, 'the shared options are declared by this plugin');
ok($props->{'pstore-appliance'}, 'and the PowerStore ones too');

ok($opts->{'dell-portal'}{fixed}, 'the portal cannot be changed after creation');
ok(!$opts->{'dell-username'}{optional}, 'username is required');
ok(!$opts->{'dell-password'}{optional}, 'password is required');
ok($opts->{'pstore-appliance'}{optional}, 'appliance placement is optional');
ok($opts->{content}{optional}, 'content is optional');
ok($opts->{shared}{optional}, 'shared is optional');

ok(grep({ $_ eq 'dell-password' } $P->sensitive_properties()),
    'the password is marked sensitive so the API does not echo it back');

my $pd = $P->plugindata();
is_deeply($pd->{format}, [{ raw => 1 }, 'raw'], 'raw only: these are block volumes');
ok($pd->{content}[0]{images} && $pd->{content}[0]{rootdir},
    'VM disks and container root filesystems');

like($P->get_identity({ 'dell-portal' => '10.0.0.5' }, 'ps1'),
    qr/^dellpowerstore:10\.0\.0\.5:/, 'identity pins the storage to one array');
like($P->get_identity({ 'dell-portal' => '10.0.0.5', 'pstore-appliance' => 'A1' }, 'ps1'),
    qr/A1$/, 'and to one appliance when set');

# Enumerated options must not silently accept a typo.
is_deeply([sort @{ $props->{'pstore-performance-policy'}{enum} }],
    ['High', 'Low', 'Medium'], 'performance policy enum');
is($props->{'pstore-lun-id-base'}{minimum}, 1, 'LUN base cannot be zero');
is($props->{'pstore-lun-id-base'}{maximum}, 200, 'LUN base stays well under 255');

# ---------------------------------------------------------------------------
# Every abstract method is implemented
#
# An unimplemented one only shows up when that code path runs, which for
# something like _array_snapshot_rollback could be the first time an operator
# needs it in anger.
# ---------------------------------------------------------------------------

my @abstract = qw(
    _array_ping _array_get_capacity
    _array_get_volume _array_list_volumes _array_create_volume _array_delete_volume
    _array_resize_volume _array_rename_volume _array_get_wwid
    _array_snapshot_create _array_snapshot_get _array_snapshot_delete
    _array_snapshot_list _array_snapshot_rollback _array_clone
    _array_ensure_host _array_list_hosts _array_map_to_host _array_unmap_from_host
    _array_is_mapped _array_mapped_hosts _array_get_portals
    multipath_vendor multipath_product multipath_defaults type
);

for my $method (@abstract) {
    my $impl = $P->can($method);
    ok($impl, "$method exists");
    isnt($impl, $BASE->can($method), "$method is implemented, not inherited abstract");
}

# ---------------------------------------------------------------------------
# Multipath settings
#
# These two values are the difference between a failed path and a node that
# has to be power-cycled, so a regression here must fail the build.
# ---------------------------------------------------------------------------

my $mp = $P->multipath_defaults();

isnt($mp->{no_path_retry}, 'queue',
    'no_path_retry is never "queue": queued I/O with no path left is unkillable');
is($mp->{no_path_retry}, 30, 'no_path_retry has a finite value');
isnt($mp->{dev_loss_tmo}, 'infinity',
    'dev_loss_tmo is never "infinity": a dead device must eventually go away');
is($mp->{dev_loss_tmo}, 60, 'dev_loss_tmo is finite');
is($mp->{fast_io_fail_tmo}, 5, 'I/O fails fast on a lost path');
is($mp->{prio}, 'alua', 'ALUA path priority');
is($mp->{hardware_handler}, '1 alua', 'ALUA hardware handler');
is($mp->{failback}, 'immediate', 'failback');

is($P->multipath_vendor, 'DellEMC', 'vendor string');
is($P->multipath_product, 'PowerStore', 'product string');
like($P->_vendor_re, qr/DellEMC/, 'the vendor gate is built from the vendor string');
ok('DellEMC' =~ $P->_vendor_re, 'our devices match the gate');
ok('NETAPP' !~ $P->_vendor_re, 'another vendor does not');

# The generated drop-in must never carry the dangerous forms.
my $conf = $P->_multipath_config_content();
like($conf, qr/dellemc-multipath-config-version: 1/, 'carries a version marker');
like($conf, qr/vendor\s+"DellEMC"/, 'vendor block');
like($conf, qr/product\s+"PowerStore"/, 'product block');
like($conf, qr/path_selector\s+"queue-length 0"/, 'values with spaces are quoted');
unlike($conf, qr/no_path_retry\s+queue/, 'never writes queueing');
unlike($conf, qr/dev_loss_tmo\s+infinity/, 'never writes an infinite dev_loss_tmo');

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

is($P->naming, 'PVE::Storage::Custom::DellEMC::PowerStore::Naming',
    'uses the PowerStore naming limits');
is($P->naming->max_volume_name_length, 128, 'PowerStore name length');
is($P->_array_volname('ps1', 'vm-100-disk-0'), 'pve-ps1-100-disk0',
    'PVE volume name to array object name');

# ---------------------------------------------------------------------------
# Row mapping
# ---------------------------------------------------------------------------

my $row = $P->_volume_row({
    id                 => 'v-1',
    name               => 'pve-ps1-100-disk0',
    size               => 34359738368,
    logical_used       => 1073741824,
    wwn                => 'naa.68ccf09800a1b2c3d4e5f60718293a4b',
    creation_timestamp => '2026-07-26T09:00:00.000Z',
});

is($row->{name}, 'pve-ps1-100-disk0', 'name carried through');
is($row->{size}, 34359738368, 'size carried through');
is($row->{used}, 1073741824, 'logical_used becomes used');
is($row->{wwid}, '368ccf09800a1b2c3d4e5f60718293a4b',
    'the WWN is converted to the multipath WWID');
is($row->{ctime}, 1785056400, 'the ISO timestamp becomes epoch seconds');
is($P->_volume_row({}), undef, 'a row without a name is not a volume');
is($P->_volume_row(undef), undef, 'undef row');

# PVE renders a snapshot date from ctime; handing it the raw string or
# milliseconds puts the date tens of thousands of years out.
is($P->_to_epoch('2026-07-26T09:00:00.000Z'), 1785056400, 'ISO 8601 in UTC');
is($P->_to_epoch('1785056400'), 1785056400, 'an epoch value passes through');
is($P->_to_epoch('nonsense'), 0, 'garbage becomes 0, meaning unknown');
is($P->_to_epoch(undef), 0, 'undef becomes 0');
is($P->_to_epoch(''), 0, 'empty becomes 0');

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------

my $scfg = {
    'dell-portal' => '10.0.0.5',
    'dell-username' => 'pveadmin',
    'dell-password' => 'secret',
};

is($P->_host_mode($scfg), 'per-node', 'per-node host mode by default');
is($P->_protocol($scfg), 'iscsi', 'iSCSI by default');
is($P->capacity_scope($scfg), 'array', 'capacity is reported for the array');

# The VM config backup volume costs one extra volume per snapshot of a VM.
# PowerStore's ceilings are high enough to carry that, so it stays on by
# default — but an operator close to a limit must be able to switch it off.
is($P->supports_config_backup(), 1, 'the family offers the config backup');
is($P->_config_backup_enabled($scfg), 1, '... and it is on by default');
is($P->_config_backup_enabled({ %$scfg, 'dell-config-backup' => 0 }), 0,
    '... and can be turned off');
is($P->_config_backup_enabled({ %$scfg, 'dell-config-backup' => 1 }), 1,
    '... and explicitly on stays on');
ok($P->properties()->{'dell-config-backup'}, 'the option is declared');

# ---------------------------------------------------------------------------
# Linked clones are reported under the volid PVE stored for them
# ---------------------------------------------------------------------------

{
    # A thin clone carries protection_data.source_id; for a PVE linked clone
    # that is the id of the template's marker snapshot.
    my $row = $P->_volume_row({
        id => 'v-2', name => 'pve-ps1-101-disk0', size => 1024, wwn => 'naa.6000',
        protection_data => { source_id => 'snap-1' },
    });
    is($row->{source_id}, 'snap-1', 'the clone source id is carried through');

    my $plain = $P->_volume_row({ id => 'v-3', name => 'pve-ps1-102-disk0', size => 1 });
    is($plain->{source_id}, undef, 'a volume without protection data has none');

    # No source ids at all: no query, no map.
    is_deeply($P->_array_clone_parents({}, 'ps1', [$plain]), {},
        'a storage with no clones asks the array nothing');
}

# ---------------------------------------------------------------------------
# Storage API version negotiation
#
# PVE rejects a plugin that claims a version higher than its own — and the
# storage then disappears from the node, taking every guest on it with it.
# Claiming lower than PVE's is accepted but makes PVE warn on every single
# load of PVE::Storage, which is once per pvesm call. PVE 9 raised APIVER
# twice inside the 9.1 point releases, so a hardcoded number is wrong
# somewhere by construction.
# ---------------------------------------------------------------------------

SKIP: {
    skip 'PVE::Storage is not available', 4
        unless eval { require PVE::Storage; defined &PVE::Storage::APIVER };

    my $apiver = PVE::Storage::APIVER();
    my $apiage = PVE::Storage::APIAGE();
    my $claim  = $P->api();

    cmp_ok($claim, '<=', $apiver,
        'never claims a version newer than this PVE (which would be rejected)');
    cmp_ok($claim, '>=', $apiver - $apiage,
        'and never one this PVE considers too old');

    # Anything below PVE's own version means a warning on every load, so on a
    # PVE we have implemented up to, the claim should match exactly.
    my $max = PVE::Storage::Custom::DellEMC::Common::BlockBase::APIVERSION_MAX();
    if ($apiver <= $max) {
        is($claim, $apiver, 'claims exactly what this PVE asks for');
    } else {
        is($claim, $max, 'claims the newest version actually implemented');
    }

    is(PVE::Storage::Custom::DellPowerFlexPlugin->api(), $claim,
        'every family negotiates the same way')
        if eval { require PVE::Storage::Custom::DellPowerFlexPlugin; 1 };
}

done_testing();
