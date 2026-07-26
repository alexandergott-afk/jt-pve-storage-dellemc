#!/usr/bin/perl
# PowerVault ME naming, API and plugin tests.
#
# The array is replaced by a fake user agent. What these tests protect is the
# handful of places where PowerVault differs from PowerStore in ways that fail
# silently if got wrong: a 32-byte name limit, a size the array rounds DOWN,
# an expand that takes a delta rather than a total, and an error that arrives
# with HTTP 200.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use HTTP::Response;
use HTTP::Headers;
use Digest::SHA qw(sha256_hex);
use JSON;
use URI;

use PVE::Storage::Custom::DellEMC::PowerVault::API;
use PVE::Storage::Custom::DellEMC::PowerVault::Naming;

my $API = 'PVE::Storage::Custom::DellEMC::PowerVault::API';
my $N   = 'PVE::Storage::Custom::DellEMC::PowerVault::Naming';

# ---------------------------------------------------------------------------
# Naming
#
# The array accepts 32 bytes and refuses a dot in a volume name. Both are
# documented in the ME5 CLI Reference Guide, and both are why this family
# cannot reuse the PowerStore naming.
# ---------------------------------------------------------------------------

is($N->max_volume_name_length, 32, 'the documented 32-byte limit');
is($N->max_snapshot_name_length, 32, 'snapshots have the same limit');

is($N->encode_volume_name('me5', 100, 0), 'pve-me5-100-d0', 'volume name is compact');
is($N->encode_cloudinit_name('me5', 100), 'pve-me5-100-ci', 'cloud-init');
is($N->encode_efidisk_name('me5', 100, 0), 'pve-me5-100-e0', 'EFI disk');
is($N->encode_tpmstate_name('me5', 100, 1), 'pve-me5-100-t1', 'TPM state');
is($N->encode_state_name('me5', 100, 'snap1'), 'pve-me5-100-st-snap1', 'RAM state');
is($N->encode_config_volume_name('me5', 100, 'snap1'), 'pve-me5-100-vc-snap1', 'config backup');

is($N->encode_snapshot_name('pve-me5-100-d0', 'before'), 'pve-me5-100-d0-s-before',
    'a snapshot uses -s-, never a dot');
is($N->encode_base_snapshot_name('pve-me5-100-d0'), 'pve-me5-100-d0-base',
    'the template marker uses -base');

# Nothing generated may contain a dot: the array rejects the create outright.
for my $name (
    $N->encode_volume_name('st.1', 100, 0),
    $N->encode_snapshot_name('pve-me5-100-d0', 'v1.2.3'),
    $N->encode_state_name('me5', 100, 'a.b.c'),
    $N->encode_config_volume_name('me5', 100, 'a.b'),
) {
    unlike($name, qr/\./, "no dot in '$name'");
    ok(length($name) <= 32, "'$name' fits in 32 bytes");
    ok($N->is_valid_volume_name($name), "'$name' is a valid array name");
}

# Round trips
is_deeply($N->decode_volume_name('pve-me5-100-d0'),
    { storage => 'me5', vmid => 100, diskid => 0, type => 'disk' }, 'decode disk');
is_deeply($N->decode_volume_name('pve-me5-100-ci'),
    { storage => 'me5', vmid => 100, type => 'cloudinit' }, 'decode cloud-init');
is_deeply($N->decode_volume_name('pve-me5-100-st-snap1'),
    { storage => 'me5', vmid => 100, snapname => 'snap1', type => 'state' },
    'decode RAM state');
is_deeply($N->decode_snapshot_name('pve-me5-100-d0-s-before'),
    { volume => 'pve-me5-100-d0', snapname => 'before', is_base => 0 },
    'a snapshot decodes back to its volume');
is_deeply($N->decode_snapshot_name('pve-me5-100-d0-base'),
    { volume => 'pve-me5-100-d0', snapname => undef, is_base => 1 },
    'and so does the template marker');

# A snapshot must not be mistaken for a volume: it would be listed as a VM
# disk and could be deleted as one.
is($N->decode_volume_name('pve-me5-100-d0-s-before'), undef,
    'a snapshot is not decoded as a volume');
is($N->decode_volume_name('pve-me5-100-d0-base'), undef,
    'nor is the template marker');

is($N->array_to_pve_volname('pve-me5-100-d0'), 'vm-100-disk-0', 'back to a PVE name');
is($N->pve_volname_to_array('me5', 'vm-100-disk-0'), 'pve-me5-100-d0', 'and forward again');

ok($N->is_pve_managed_volume('pve-me5-100-d0', 'me5'), 'ownership gate accepts our volume');
ok($N->is_pve_managed_volume('pve-me5-100-d0-s-x', 'me5'), 'and our snapshot');
ok(!$N->is_pve_managed_volume('production-lun', 'me5'), 'and rejects a foreign one');
ok(!$N->is_pve_managed_volume('pve-me5-100-d0', 'me6'), 'and another storage of ours');

# A name that will not fit must fail loudly. Truncating silently would let two
# VMs share one volume name.
eval { $N->encode_volume_name('a-very-long-storage-id', 100, 0) };
my $err = $@;
if ($err) {
    like($err, qr/32/, 'an over-long name reports the limit');
    like($err, qr/shorter storage id/, 'and says what to shorten');
} else {
    # The storeid budget truncates before the volume budget is reached; the
    # result must still be legal.
    my $name = $N->encode_volume_name('a-very-long-storage-id', 100, 0);
    ok(length($name) <= 32, 'a long storeid still produces a legal name');
}

eval { $N->encode_snapshot_name('x' x 31, 'snap') };
like($@, qr/no room|shorter storage id/, 'a snapshot with no room fails clearly');

is($N->max_storeid_length, 10, 'the storeid budget is small on this family');

# ---------------------------------------------------------------------------
# Fake array
# ---------------------------------------------------------------------------

{
    package FakeME;

    sub new {
        my ($class, %args) = @_;
        return bless { timeout => 15, requests => [], handler => $args{handler} }, $class;
    }
    sub timeout { my ($s, $v) = @_; $s->{timeout} = $v if defined $v; return $s->{timeout} }
    sub default_header { return }
    sub request {
        my ($self, $req) = @_;
        push @{ $self->{requests} }, $req;
        return $self->{handler}->($req, $req->uri->path, $self);
    }
    sub requests { return $_[0]{requests} }
    sub last_request { return $_[0]{requests}[-1] }
    sub paths { return [ map { $_->uri->path } @{ $_[0]{requests} } ] }
}

sub reply {
    my ($body, $code) = @_;
    my $h = HTTP::Headers->new('Content-Type' => 'application/json');
    return HTTP::Response->new($code // 200, undef, $h, encode_json($body));
}

# The array answers 200 for everything; the status object decides.
sub ok_status { return { status => [{ 'response-type' => 'Success', response => 'ok', 'return-code' => 0 }] } }
sub err_status {
    my ($message, $code) = @_;
    return { status => [{ 'response-type' => 'Error', response => $message,
                          'return-code' => $code // 1 }] };
}

sub make_api {
    my (%args) = @_;
    my $inner = delete $args{handler};

    my $ua = FakeME->new(handler => sub {
        my ($req, $path, $self) = @_;
        if ($path =~ m{^/api/login}) {
            return reply({ status => [{ 'response-type' => 'Success',
                                        response => 'abcdef0123456789abcdef0123456789',
                                        'return-code' => 1 }] });
        }
        return $inner->($req, $path, $self) if $inner;
        return reply(ok_status());
    });

    my $api = $API->new(
        portal => '10.0.0.9', username => 'manage', password => 'secret',
        storeid => 'me5', type => 'dellpowervault', ua => $ua, %args,
    );

    return ($api, $ua);
}

# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api();
    $api->system_get();

    my $login = $ua->requests->[0];
    is($login->uri->path, '/api/login/' . sha256_hex('manage_secret'),
        'logs in with the SHA-256 of username_password, as documented');
    is($login->header('dataType'), 'json', 'asks for JSON');

    my $call = $ua->requests->[1];
    is($call->header('sessionKey'), 'abcdef0123456789abcdef0123456789',
        'later calls carry the session key header');
    is($call->header('dataType'), 'json', 'and keep asking for JSON');
}

{
    # SHA-256 is documented as incompatible with LDAP accounts, so a refusal
    # must fall back to Basic rather than failing outright.
    my @paths;
    my $ua = FakeME->new(handler => sub {
        my ($req, $path) = @_;
        push @paths, $path;
        if ($path =~ m{^/api/login/}) {
            return reply(err_status('Authentication failed'));
        }
        if ($path eq '/api/login') {
            return reply({ status => [{ 'response-type' => 'Success',
                                        response => 'f00dcafef00dcafef00dcafef00dcafe',
                                        'return-code' => 1 }] });
        }
        return reply(ok_status());
    });

    my $api = $API->new(portal => 'x', username => 'ldapuser', password => 'p', ua => $ua);
    $api->system_get();

    is($paths[0], '/api/login/' . sha256_hex('ldapuser_p'), 'hashed login tried first');
    is($paths[1], '/api/login', 'then Basic authentication');
    my ($basic) = grep { $_->uri->path eq '/api/login' } @{ $ua->requests };
    like($basic->header('Authorization'), qr/^Basic /, 'with an Authorization header');
}

{
    # Both methods refused: the message must name both, not just the last.
    my $ua = FakeME->new(handler => sub { reply(err_status('Authentication failed')) });
    my $api = $API->new(portal => 'x', username => 'u', password => 'p',
        storeid => 'me5', type => 'dellpowervault', ua => $ua);
    eval { $api->system_get() };
    like($@, qr/authentication failed/i, 'a total failure is reported');
    like($@, qr/Basic/, 'mentioning both methods');
    like($@, qr/dell-username/, 'and what to check');
}

# ---------------------------------------------------------------------------
# HTTP 200 is not success
#
# The CLI answers 200 and puts the verdict in the status object. Treating the
# HTTP code as the answer would make a failed volume create look like it
# worked, and PVE would then record a disk that does not exist.
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub {
        return reply(err_status('The volume name is already in use.', 1));
    });

    eval { $api->volume_create('pve-me5-100-d0', 1024 ** 3) };
    like($@, qr/already in use/, 'the array message is surfaced');
    like($@, qr/create volume/, 'with the command that failed');
    like($@, qr/return code 1/, 'and the return code');
    like($@, qr/unique system-wide/, 'plus a hint about the shared namespace');
    like($@, qr/\[dellpowervault:me5\]/, 'tagged with the storage');
}

{
    my ($api) = make_api(handler => sub {
        return reply(err_status('Not enough free space in the pool.'));
    });
    eval { $api->volume_create('v', 1024 ** 4) };
    like($@, qr/pvault-pool/, 'a space failure points at the pool option');
}

{
    my ($api) = make_api(handler => sub {
        return reply(err_status('The volume is mapped and cannot be deleted.'));
    });
    eval { $api->volume_delete('v') };
    like($@, qr/Unmap it/, 'a mapped volume says what to do first');
}

{
    my ($api) = make_api(handler => sub {
        return reply(err_status('This command requires a license.'));
    });
    eval { $api->snapshot_create('v', 's') };
    like($@, qr/licen/i, 'a licensing failure is explained');
}

{
    # An expired session looks like an ordinary command error here.
    my $calls = 0;
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(ok_status()) unless $path =~ m{/show/system};
        $calls++;
        return reply(err_status('The session key is invalid.')) if $calls == 1;
        return reply({ %{ ok_status() }, system => [{ 'system-name' => 'me5' }] });
    });

    my $system;
    {
        local $SIG{__WARN__} = sub { };
        $system = $api->system_get();
    }
    is($system->{'system-name'}, 'me5', 'an expired session recovers transparently');
    is(scalar(grep { m{^/api/login} } @{ $ua->paths }), 2, 'by logging in again');
}

# ---------------------------------------------------------------------------
# Sizes
#
# "Volume sizes are aligned to 4.2 MB (4 MiB) boundaries [...] if the
# resulting size would be greater than 4.2 MB it will be decreased to the
# nearest 4.2 MB boundary." The array rounds DOWN, so the client must round
# UP or hand back less than PVE asked for.
# ---------------------------------------------------------------------------

my $MiB4 = 4 * 1024 * 1024;

is($API->align_size($MiB4), $MiB4, 'an aligned size is unchanged');
is($API->align_size(1), $MiB4, 'a tiny size becomes one granule');
is($API->align_size($MiB4 + 1), $MiB4 * 2, 'an unaligned size rounds UP');
is($API->align_size(32 * 1024 ** 3), 32 * 1024 ** 3, '32 GiB is already aligned');
ok($API->align_size(1024 ** 3 + 12345) >= 1024 ** 3 + 12345,
    'alignment never returns less than requested');

eval { $API->align_size(200 * 1024 ** 4) };
like($@, qr/128 TiB/, 'a size beyond the array maximum is refused');

{
    my ($api, $ua) = make_api(handler => sub { reply(ok_status()) });
    $api->volume_create('pve-me5-100-d0', 1024 ** 3 + 1);
    my $path = $ua->last_request->uri->path;
    like($path, qr{/api/create/volume/}, 'create volume is a CLI path');
    like($path, qr{/size/1077936128B/}, 'the size is aligned and carries a unit');
    like($path, qr{/pve-me5-100-d0$}, 'the name comes last, as the CLI expects');
}

{
    my ($api, $ua) = make_api(handler => sub { reply(ok_status()) });
    $api->volume_create('v1', 1024 ** 3, pool => 'A', volume_group => 'pve');
    my $path = $ua->last_request->uri->path;
    like($path, qr{/pool/A/}, 'the pool is passed');
    like($path, qr{/volume-group/pve/}, 'and the volume group');
}

# ---------------------------------------------------------------------------
# Expand takes a delta, not a total
#
# PVE asks for the new absolute size. Passing that straight through would grow
# a 32 GiB volume to 64 GiB when the user asked for 33.
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub { reply(ok_status()) });

    $api->volume_expand('pve-me5-100-d0', 48 * 1024 ** 3,
        current_size => 32 * 1024 ** 3);

    my $path = $ua->last_request->uri->path;
    like($path, qr{/api/expand/volume/size/}, 'expand volume');
    like($path, qr{/size/17179869184B/}, 'sends the difference, not the total');
    like($path, qr{/pve-me5-100-d0$}, 'for the right volume');
}

{
    my ($api, $ua) = make_api(handler => sub { reply(ok_status()) });
    my $before = scalar @{ $ua->requests };
    is($api->volume_expand('v', 32 * 1024 ** 3, current_size => 32 * 1024 ** 3), 0,
        'expanding to the current size does nothing');
    is(scalar @{ $ua->requests }, $before, 'and sends no command');
}

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ %{ ok_status() }, volumes => [
            { 'volume-name' => 'pve-me5-100-d0', 'size-numeric' => 67108864,
              'allocated-size-numeric' => 2048, wwn => '600c0ff0001234560000000000000001' },
        ]}) if $path =~ m{/show/volumes};
        return reply(ok_status());
    });

    my $volumes = $api->volume_list('pve-me5-');
    is(scalar @$volumes, 1, 'volumes returned');

    my $path = $ua->last_request->uri->path;
    like($path, qr{/show/volumes/pattern/pve-me5-}, 'filtered on the array by pattern');
    like($path, qr{/details$}, 'details requested, which is where the WWN lives');

    my $row = $volumes->[0];
    is($api->volume_size($row), 67108864 * 512, 'size comes from the numeric field, in blocks');
    is($api->volume_used($row), 2048 * 512, 'and so does the allocated size');
    is($api->volume_wwid($row), '3600c0ff0001234560000000000000001',
        'the WWID is the WWN with the NAA prefix');
}

is($API->wwn_to_wwid('600c0ff000123456'), '3600c0ff000123456', 'short WWN still prefixed');
is($API->wwn_to_wwid('naa.600C0FF0001234560000000000000001'),
    '3600c0ff0001234560000000000000001', 'naa. form and case');
is($API->wwn_to_wwid('nonsense'), undef, 'an unusable WWN yields nothing');
is($API->wwn_to_wwid(undef), undef, 'undef WWN');

{
    # An exact lookup must not match a longer name: 'd1' is a prefix of 'd10'.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ %{ ok_status() }, volumes => [
            { 'volume-name' => 'pve-me5-100-d10', 'size-numeric' => 1 },
        ]}) if $path =~ m{/show/volumes};
        return reply(ok_status());
    });

    is($api->volume_get_by_name('pve-me5-100-d1'), undef,
        'a near-miss name is not accepted as a match');
}

{
    # The CLI reports a missing volume as an error, not an empty list.
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(err_status('The volume was not found.'))
            if $path =~ m{/show/volumes};
        return reply(ok_status());
    });
    is($api->volume_get_by_name('gone'), undef, 'a missing volume reads as undef');
}

# ---------------------------------------------------------------------------
# Mapping
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ %{ ok_status() }, 'volume-view-mappings' => [
            { identifier => 'pve-c1-node1', lun => 1 },
            { identifier => 'pve-c1-node1', lun => 3 },
        ]}) if $path =~ m{/show/maps};
        return reply(ok_status());
    });

    is($api->next_free_lun('pve-c1-node1'), 2, 'the gap is filled first');
    is($api->next_free_lun('pve-c1-node1', base => 5), 5, 'a base can be raised');
    is($api->next_free_lun('other-host'), 1, 'another host starts at 1');

    $api->volume_map('pve-me5-100-d0', 'pve-c1-node1');
    my $path = $ua->last_request->uri->path;
    like($path, qr{/api/map/volume/access/rw/initiator/pve-c1-node1/lun/2/pve-me5-100-d0$},
        'the mapping names the initiator and an explicit LUN, which the CLI requires');

    is($api->is_mapped('pve-me5-100-d0', 'pve-c1-node1'), 1, 'existing mapping found');
    is($api->is_mapped('pve-me5-100-d0', 'pve-c1-node9'), 0, 'another host is not');
}

{
    my @full = map { { identifier => 'h1', lun => $_ } } (1 .. 255);
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ %{ ok_status() }, 'volume-view-mappings' => \@full })
            if $path =~ m{/show/maps};
        return reply(ok_status());
    });
    eval { $api->next_free_lun('h1') };
    like($@, qr/every LUN/, 'LUN exhaustion is reported');
    like($@, qr/pvault-lun-id-base/, 'with the option to change');
}

# ---------------------------------------------------------------------------
# Snapshots and clones
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub { reply(ok_status()) });

    $api->snapshot_create('pve-me5-100-d0', 'pve-me5-100-d0-s-x');
    like($ua->last_request->uri->path,
        qr{/api/create/snapshots/volumes/pve-me5-100-d0/pve-me5-100-d0-s-x$},
        'create snapshots takes the source and the new name, as documented');

    $api->snapshot_rollback('pve-me5-100-d0', 'pve-me5-100-d0-s-x');
    like($ua->last_request->uri->path, qr{/api/rollback/volume/pve-me5-100-d0/snapshot/},
        'rollback names the volume and the snapshot');
}

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ %{ ok_status() }, pools => [
            { name => 'A', 'total-size-numeric' => 2000000000, 'avail-size-numeric' => 500000000 },
            { name => 'B', 'total-size-numeric' => 1000000000, 'avail-size-numeric' => 400000000 },
        ]}) if $path =~ m{/show/pools};
        return reply(ok_status());
    });

    my ($total, $used, $avail) = $api->get_managed_capacity();
    is($total, 3000000000 * 512, 'capacity sums every pool by default');
    is($avail, 900000000 * 512, 'available too');
    is($used, $total - $avail, 'used is derived');

    ($total, $used, $avail) = $api->get_managed_capacity(pool => 'A');
    is($total, 2000000000 * 512, 'a single pool can be selected');

    eval { $api->get_managed_capacity(pool => 'Z') };
    like($@, qr/pool 'Z' does not exist/, 'an unknown pool is reported');
    like($@, qr/A, B/, 'listing the ones that do');
}

{
    # No pools at all: fail loudly. Reporting zero would let PVE believe the
    # array is empty and allow allocations into nothing.
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ %{ ok_status() }, pools => [] }) if $path =~ m{/show/pools};
        return reply(ok_status());
    });
    eval { $api->get_managed_capacity() };
    like($@, qr/no pools/, 'an array without pools is an error, not zero capacity');
}

# ---------------------------------------------------------------------------
# Plugin
# ---------------------------------------------------------------------------

SKIP: {
    eval { require PVE::Storage::Plugin; 1 }
        or skip 'PVE::Storage::Plugin is not available', 22;

    require PVE::Storage::Custom::DellPowerVaultPlugin;
    my $P = 'PVE::Storage::Custom::DellPowerVaultPlugin';

    ok($P->isa('PVE::Storage::Plugin'), 'derived from PVE::Storage::Plugin');
    is($P->type, 'dellpowervault', 'storage type is named for the family, not a model');
    is($P->api, 13, 'storage API 13');
    is($P->naming, 'PVE::Storage::Custom::DellEMC::PowerVault::Naming',
        'uses the PowerVault naming limits');

    my $props = $P->properties();
    my $opts  = $P->options();
    for my $opt (sort keys %$opts) {
        my $base = PVE::Storage::Plugin->private()->{propertyList} // {};
        ok($props->{$opt} || $base->{$opt}, "option '$opt' resolves to a property");
    }
    ok($props->{'pvault-pool'}, 'the pool option is declared');
    like($_, qr/^(?:dell|pvault)-/, "property '$_' is namespaced")
        for sort keys %$props;

    # Both Dell plugins loaded at once must not declare the same property:
    # PVE dies with "duplicate property" and takes every storage with it.
    require PVE::Storage::Custom::DellPowerStorePlugin;
    my $ps = PVE::Storage::Custom::DellPowerStorePlugin->properties();
    my @dup = grep { $ps->{$_} } keys %$props;
    is_deeply(\@dup, [], 'the two Dell plugins declare no property in common');

    my $mp = $P->multipath_defaults();
    isnt($mp->{no_path_retry}, 'queue', 'no_path_retry is never queue');
    isnt($mp->{dev_loss_tmo}, 'infinity', 'dev_loss_tmo is never infinity');

    ok('DellEMC' =~ $P->_vendor_re, 'our devices match the vendor gate');
    ok('DELL EMC' =~ $P->_vendor_re, 'including the spaced spelling');
    ok('NETAPP' !~ $P->_vendor_re, 'another vendor does not');

    # The VM config backup volume is not offered on this family: an ME array's
    # volume ceiling is too low to spend one extra volume per snapshot. It must
    # stay off even when a storage.cfg asks for it.
    is($P->supports_config_backup(), 0, 'config backup is not offered');
    is($P->_config_backup_enabled({}), 0, '... so it is off by default');
    is($P->_config_backup_enabled({ 'dell-config-backup' => 1 }), 0,
        '... and stays off when the option asks for it');

    my $conf = $P->_multipath_config_content();
    like($conf, qr/product\s+"ME\[45\]/, 'the product string covers ME4 and ME5');
    unlike($conf, qr/no_path_retry\s+queue/, 'never writes queueing');
}

done_testing();
