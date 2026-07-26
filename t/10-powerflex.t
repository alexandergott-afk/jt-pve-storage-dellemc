#!/usr/bin/perl
# PowerFlex API, host-access and plugin tests.
#
# PowerFlex differs from the SAN families in ways that fail silently if got
# wrong: two authentication generations, an 8 GB allocation unit, a 31
# character name limit, and a data path with no SCSI LUN behind it.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use HTTP::Response;
use HTTP::Headers;
use JSON;
use URI;

use PVE::Storage::Custom::DellEMC::PowerFlex::API;
use PVE::Storage::Custom::DellEMC::PowerFlex::Naming;
use PVE::Storage::Custom::DellEMC::PowerFlex::Host;

my $API  = 'PVE::Storage::Custom::DellEMC::PowerFlex::API';
my $N    = 'PVE::Storage::Custom::DellEMC::PowerFlex::Naming';
my $HOST = 'PVE::Storage::Custom::DellEMC::PowerFlex::Host';

# ---------------------------------------------------------------------------
# Fake array
# ---------------------------------------------------------------------------

{
    package FakeFlex;

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
    sub body_of { return JSON::decode_json($_[0]{requests}[-1]->content) }
}

sub reply {
    my ($body, $code) = @_;
    my $h = HTTP::Headers->new('Content-Type' => 'application/json');
    return HTTP::Response->new($code // 200, undef, $h,
        ref($body) ? encode_json($body) : $body);
}

# A 4.x array: /rest/auth/login works.
sub make_v4 {
    my (%args) = @_;
    my $inner = delete $args{handler};

    my $ua = FakeFlex->new(handler => sub {
        my ($req, $path, $self) = @_;
        return reply({ access_token => 'tok-4x', refresh_token => 'refresh-4x' })
            if $path eq '/rest/auth/login';
        return $inner->($req, $path, $self) if $inner;
        return reply({});
    });

    my $api = $API->new(portal => '10.0.0.7', username => 'admin',
        password => 'secret', storeid => 'pf1', type => 'dellpowerflex',
        ua => $ua, %args);

    return ($api, $ua);
}

# A 3.x array: /rest/auth/login does not exist, /api/login returns a quoted
# token.
sub make_v3 {
    my (%args) = @_;
    my $inner = delete $args{handler};

    my $ua = FakeFlex->new(handler => sub {
        my ($req, $path, $self) = @_;
        return reply({ message => 'Not Found' }, 404) if $path eq '/rest/auth/login';
        return reply('"tok-3x-abcdef"') if $path eq '/api/login';
        return $inner->($req, $path, $self) if $inner;
        return reply({});
    });

    my $api = $API->new(portal => '10.0.0.7', username => 'admin',
        password => 'secret', storeid => 'pf1', type => 'dellpowerflex',
        ua => $ua, %args);

    return ($api, $ua);
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_v4(handler => sub {
        my ($req, $path) = @_;
        return reply([{ id => 'sys-1' }]) if $path eq '/api/types/System/instances';
        return reply({});
    });

    is($api->system_id(), 'sys-1', 'a 4.x array answers');
    is($api->generation, 4, 'detected as generation 4');

    is($ua->paths->[0], '/rest/auth/login', 'tried the 4.x login first');
    my $login_body = decode_json($ua->requests->[0]->content);
    is($login_body->{username}, 'admin', 'credentials sent as JSON');

    my $call = $ua->requests->[1];
    is($call->header('Authorization'), 'Bearer tok-4x',
        'later calls carry the bearer token');
}

{
    my ($api, $ua) = make_v3(handler => sub {
        my ($req, $path) = @_;
        return reply([{ id => 'sys-9' }]) if $path eq '/api/types/System/instances';
        return reply({});
    });

    is($api->system_id(), 'sys-9', 'a 3.x array answers');
    is($api->generation, 3, 'detected as generation 3');

    is($ua->paths->[0], '/rest/auth/login', 'the 4.x login is tried first');
    is($ua->paths->[1], '/api/login', 'then the 3.x one');

    my ($call) = grep { $_->uri->path =~ m{^/api/types} } @{ $ua->requests };
    like($call->header('Authorization'), qr/^Basic /,
        '3.x sends the token as HTTP Basic');
}

{
    # A wrong password on 4.x must NOT be retried as 3.x: that would double
    # the failed-login count against an account lockout policy.
    my $tries = 0;
    my $ua = FakeFlex->new(handler => sub {
        my ($req, $path) = @_;
        $tries++ if $path =~ m{login};
        return reply({ message => 'Unauthorized' }, 401);
    });
    my $api = $API->new(portal => 'x', username => 'u', password => 'bad',
        storeid => 'pf1', type => 'dellpowerflex', ua => $ua);

    eval { $api->system_id() };
    like($@, qr/HTTP 401/, 'a refused password fails');
    is($tries, 1, 'and is not replayed against the other login endpoint');
}

{
    # Neither generation answers: the message must name both attempts.
    my $ua = FakeFlex->new(handler => sub { reply({ message => 'nope' }, 500) });
    my $api = $API->new(portal => 'x', username => 'u', password => 'p',
        storeid => 'pf1', type => 'dellpowerflex', ua => $ua);

    eval { $api->system_id() };
    like($@, qr/authentication failed/i, 'total failure is reported');
    like($@, qr{/rest/auth/login}, 'naming the 4.x endpoint');
    like($@, qr{/api/login}, 'and the 3.x endpoint');
    like($@, qr/PowerFlex Manager or gateway/, 'and the likely cause');
}

{
    # The 4.x access token expires in five minutes, so the client must not
    # cache a session for longer than that.
    my ($api) = make_v4();
    $api->_login();
    cmp_ok($api->{session_ttl}, '<=', 300,
        'the session is renewed inside the five-minute token lifetime');
}

# ---------------------------------------------------------------------------
# Sizes
#
# PowerFlex allocates in 8 GB units and rounds a smaller request UP. Doing the
# same here keeps what PVE records and what the array created identical.
# ---------------------------------------------------------------------------

my $GB8 = 8 * 1024 ** 3;

is($API->align_size(1), $GB8, 'anything smaller becomes the 8 GB minimum');
is($API->align_size($GB8), $GB8, 'an exact multiple is unchanged');
is($API->align_size($GB8 + 1), $GB8 * 2, 'a larger request rounds up');
is($API->align_size(16 * 1024 ** 3), 16 * 1024 ** 3, '16 GB is a multiple');
is($API->align_size(20 * 1024 ** 3), 24 * 1024 ** 3, '20 GB becomes 24 GB');
ok($API->align_size(9 * 1024 ** 3) >= 9 * 1024 ** 3, 'never rounds down');

{
    my ($api, $ua) = make_v4(handler => sub {
        my ($req, $path) = @_;
        return reply({ id => 'vol-new' }) if $path eq '/api/types/Volume/instances';
        return reply({});
    });

    my $id = $api->volume_create('pve-pf1-100-d0', 20 * 1024 ** 3,
        storage_pool_id => 'pool-1');
    is($id, 'vol-new', 'the new volume id is returned');

    my $body = $ua->body_of;
    is($body->{name}, 'pve-pf1-100-d0', 'name');
    is($body->{volumeSizeInKb}, 24 * 1024 * 1024, 'size sent in KB, aligned up');
    is($body->{storagePoolId}, 'pool-1', 'storage pool');
    is($body->{volumeType}, 'ThinProvisioned', 'thin by default');

    $api->volume_create('v2', $GB8, storage_pool_id => 'pool-1', thick => 1);
    is($ua->body_of->{volumeType}, 'ThickProvisioned', 'thick when asked');
}

{
    my ($api) = make_v4();
    eval { $api->volume_create('x' x 40, $GB8, storage_pool_id => 'p') };
    like($@, qr/31/, 'an over-long name is refused with the limit named');
}

{
    my ($api) = make_v4();
    eval { $api->volume_create('v', $GB8) };
    like($@, qr/storage pool id is required/, 'a pool is required');
}

# ---------------------------------------------------------------------------
# Volume operations
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_v4(handler => sub {
        my ($req, $path) = @_;
        return reply('"vol-42"')
            if $path eq '/api/types/Volume/instances/action/queryIdByKey';
        return reply({ id => 'vol-42', name => 'pve-pf1-100-d0',
                       sizeInKb => 8 * 1024 * 1024 })
            if $path eq '/api/instances/Volume::vol-42';
        return reply({});
    });

    is($api->volume_id_by_name('pve-pf1-100-d0'), 'vol-42',
        'an exact name lookup uses queryIdByKey rather than listing everything');
    is($ua->requests->[1]->method, 'POST', 'which is a POST');

    my $volume = $api->volume_get_by_name('pve-pf1-100-d0');
    is($volume->{id}, 'vol-42', 'and the volume is then fetched by id');
    is($api->volume_size($volume), $GB8, 'size converts from KB to bytes');
}

{
    my ($api, $ua) = make_v4(handler => sub { reply({}) });

    $api->volume_delete('vol-42');
    is($ua->last_request->uri->path, '/api/instances/Volume::vol-42/action/removeVolume',
        'delete path');
    is($ua->body_of->{removeMode}, 'ONLY_ME',
        'ONLY_ME: deleting one disk must not take its snapshots and clones');

    $api->volume_resize('vol-42', 32 * 1024 ** 3);
    is($ua->last_request->uri->path, '/api/instances/Volume::vol-42/action/setVolumeSize',
        'resize path');
    is($ua->body_of->{sizeInGB}, '32', 'resize is expressed in whole GB');

    $api->volume_rename('vol-42', 'pve-pf1-101-d0');
    is($ua->body_of->{newName}, 'pve-pf1-101-d0', 'rename body');
}

# ---------------------------------------------------------------------------
# Mapping
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_v4(handler => sub { reply({}) });

    $api->volume_map('vol-42', 'sdc-7');
    is($ua->last_request->uri->path, '/api/instances/Volume::vol-42/action/addMappedSdc',
        'map path');
    my $body = $ua->body_of;
    is($body->{sdcId}, 'sdc-7', 'the SDC id is sent');
    is($body->{allowMultipleMappings}, 'TRUE',
        'multiple mappings are allowed: every node maps the same volume');

    $api->volume_map('vol-42', 'host-9', nvme => 1);
    is($ua->body_of->{hostId}, 'host-9', 'an NVMe host is sent as hostId');

    $api->volume_unmap('vol-42', 'sdc-7');
    is($ua->last_request->uri->path,
        '/api/instances/Volume::vol-42/action/removeMappedSdc', 'unmap path');
}

{
    my $volume = { id => 'vol-42', mappedSdcInfo => [
        { sdcId => 'sdc-1' }, { sdcId => 'sdc-2' },
    ]};
    my ($api) = make_v4();

    is_deeply($api->volume_mapped_hosts($volume), ['sdc-1', 'sdc-2'],
        'mapped hosts are read from the volume');
    is($api->is_mapped($volume, 'sdc-1'), 1, 'a mapped host is found');
    is($api->is_mapped($volume, 'sdc-9'), 0, 'an unmapped one is not');
    is($api->is_mapped($volume, undef), 0, 'undef is never mapped');
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_v4(handler => sub {
        my ($req, $path) = @_;
        return reply([{ id => 'sys-1' }]) if $path eq '/api/types/System/instances';
        return reply({ volumeIdList => ['snap-1'] })
            if $path =~ m{/action/snapshotVolumes$};
        return reply({});
    });

    my $id = $api->snapshot_create('vol-42', 'pve-pf1-100-d0-s-x');
    is($id, 'snap-1', 'the snapshot id is returned');
    is($ua->last_request->uri->path,
        '/api/instances/System::sys-1/action/snapshotVolumes',
        'snapshots are taken at system level, as the API requires');

    my $defs = $ua->body_of->{snapshotDefs};
    is($defs->[0]{volumeId}, 'vol-42', 'source volume');
    is($defs->[0]{snapshotName}, 'pve-pf1-100-d0-s-x', 'snapshot name');
}

{
    my ($api) = make_v4();
    eval { $api->snapshot_create('vol-1', 'y' x 40) };
    like($@, qr/31/, 'an over-long snapshot name is refused');
}

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

{
    my ($api) = make_v4(handler => sub {
        my ($req, $path) = @_;
        return reply([
            { id => 'sp-1', name => 'pool1', protectionDomainId => 'pd-1' },
            { id => 'sp-2', name => 'pool2', protectionDomainId => 'pd-1' },
        ]) if $path eq '/api/types/StoragePool/instances';
        return reply({ maxCapacityInKb => 1000000, thinCapacityInUseInKb => 250000 })
            if $path =~ m{/relationships/Statistics$};
        return reply({});
    });

    my ($total, $used, $avail) = $api->get_managed_capacity(pool => 'pool1');
    is($total, 1000000 * 1024, 'capacity for one pool');
    is($used, 250000 * 1024, 'used');
    is($avail, $total - $used, 'available is derived');

    eval { $api->get_managed_capacity(pool => 'nope') };
    like($@, qr/does not exist/, 'an unknown pool is reported');
    like($@, qr/pool1, pool2/, 'listing the ones that do');
}

{
    # The same pool name can exist in two protection domains, and guessing
    # would put volumes in the wrong place.
    my ($api) = make_v4(handler => sub {
        my ($req, $path) = @_;
        return reply([
            { id => 'sp-1', name => 'pool1', protectionDomainId => 'pd-1' },
            { id => 'sp-2', name => 'pool1', protectionDomainId => 'pd-2' },
        ]) if $path eq '/api/types/StoragePool/instances';
        return reply({});
    });

    eval { $api->storage_pool_by_name('pool1') };
    like($@, qr/more than one protection domain/, 'an ambiguous pool name is refused');
    like($@, qr/pflex-protection-domain/, 'naming the option that resolves it');

    my $pool = $api->storage_pool_by_name('pool1', 'pd-2');
    is($pool->{id}, 'sp-2', 'the domain picks the right pool');
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

is($N->max_volume_name_length, 31, 'PowerFlex allows 31 characters');
is($N->encode_volume_name('pf1', 100, 0), 'pve-pf1-100-d0', 'compact volume name');
is($N->encode_snapshot_name('pve-pf1-100-d0', 'x'), 'pve-pf1-100-d0-s-x', 'snapshot');
is($N->encode_base_snapshot_name('pve-pf1-100-d0'), 'pve-pf1-100-d0-base', 'template marker');

for my $name ($N->encode_volume_name('pf1', 100, 0),
              $N->encode_snapshot_name('pve-pf1-100-d0', 'before')) {
    ok(length($name) <= 31, "'$name' fits PowerFlex's limit");
}

is_deeply($N->decode_snapshot_name('pve-pf1-100-d0-s-before'),
    { volume => 'pve-pf1-100-d0', snapname => 'before', is_base => 0 },
    'a snapshot decodes back to its volume');
ok($N->is_pve_managed_volume('pve-pf1-100-d0', 'pf1'), 'ownership gate');
ok(!$N->is_pve_managed_volume('someone-elses-volume', 'pf1'), 'foreign volume rejected');

# ---------------------------------------------------------------------------
# Host access
#
# These run on a machine with neither the SDC nor an NVMe fabric, so what is
# checked is that absence is reported clearly rather than crashing.
# ---------------------------------------------------------------------------

like($HOST->sdc_status_message(), qr/SDC|scini/,
    'a missing SDC is explained rather than silently empty');
like($HOST->sdc_status_message(), qr/POWERFLEX_SDC/,
    'and points at the document that explains the choice');

is(PVE::Storage::Custom::DellEMC::PowerFlex::Host::sdc_device_for_volume('vol-1'),
    undef, 'no device for an unknown volume');
is(PVE::Storage::Custom::DellEMC::PowerFlex::Host::nvme_device_for_volume('vol-1'),
    undef, 'and none over NVMe either');

eval { PVE::Storage::Custom::DellEMC::PowerFlex::Host::sdc_device_for_volume() };
like($@, qr/volume_id is required/, 'the lookup validates its argument');

{
    # wait_for_device must return promptly when the device never appears,
    # rather than blocking a PVE worker for its full timeout on every call.
    my $calls = 0;
    my $start = time();
    my $device = PVE::Storage::Custom::DellEMC::PowerFlex::Host::wait_for_device(
        sub { $calls++; return undef }, timeout => 2, interval => 1);
    is($device, undef, 'gives up when the device does not appear');
    ok($calls >= 2, 'having looked more than once');
    ok((time() - $start) <= 5, 'and within the timeout it was given');
}

{
    my $device = PVE::Storage::Custom::DellEMC::PowerFlex::Host::wait_for_device(
        sub { return '/dev/scinia' }, timeout => 30);
    is($device, '/dev/scinia', 'an already-present device returns at once');
}

# ---------------------------------------------------------------------------
# NVMe/TCP multipathing
#
# Paths are ANA, not dm-multipath, but the failure mode is identical: without
# native multipathing each path is its own device, and with an infinite
# ctrl_loss_tmo a total path loss queues I/O until the node is power-cycled.
# ---------------------------------------------------------------------------

{
    my $state = PVE::Storage::Custom::DellEMC::PowerFlex::Host::nvme_multipath_enabled();
    like($state, qr/^-?[01]$/, 'multipath state is enabled, disabled or unknown');

    my $message = PVE::Storage::Custom::DellEMC::PowerFlex::Host::nvme_multipath_message();
    if ($state == 1) {
        is($message, '', 'nothing to report when native multipathing is on');
    } else {
        like($message, qr/multipath/i, 'and otherwise it is explained');
    }
}

is(PVE::Storage::Custom::DellEMC::PowerFlex::Host::NVME_CTRL_LOSS_TMO(), 60,
    'ctrl-loss-tmo is finite: the kernel default of 600s looks like a hang');
cmp_ok(PVE::Storage::Custom::DellEMC::PowerFlex::Host::NVME_CTRL_LOSS_TMO(),
    '<', 600, 'and well below the kernel default');
is(PVE::Storage::Custom::DellEMC::PowerFlex::Host::NVME_KEEP_ALIVE_TMO(), 5,
    'a dead controller is noticed quickly');

is_deeply(PVE::Storage::Custom::DellEMC::PowerFlex::Host::nvme_paths('nqn.none'), [],
    'no paths for an unknown subsystem, and no crash');

# ---------------------------------------------------------------------------
# Plugin
# ---------------------------------------------------------------------------

SKIP: {
    eval { require PVE::Storage::Plugin; 1 }
        or skip 'PVE::Storage::Plugin is not available', 16;

    require PVE::Storage::Custom::DellPowerFlexPlugin;
    my $P = 'PVE::Storage::Custom::DellPowerFlexPlugin';

    ok($P->isa('PVE::Storage::Plugin'), 'derived from PVE::Storage::Plugin');
    ok(!$P->isa('PVE::Storage::Custom::DellEMC::Common::BlockBase'),
        'and deliberately NOT from the block base: no SCSI LUN, no multipath');
    is($P->type, 'dellpowerflex', 'storage type');
    is($P->api, 13, 'storage API 13');

    my $props = $P->properties();
    my $opts = $P->options();
    my $base = PVE::Storage::Plugin->private()->{propertyList} // {};
    for my $opt (sort keys %$opts) {
        ok($props->{$opt} || $base->{$opt}, "option '$opt' resolves to a property");
    }
    ok(!$opts->{'pflex-storage-pool'}{optional}, 'the storage pool is required');

    # NVMe/TCP is the default because the SDC is a Dell kernel module that
    # must match the running kernel, and PVE 9 is not yet on Dell's list.
    is($P->_access_mode({}), 'nvme', 'NVMe/TCP is the default data path');
    is($P->_access_mode({ 'dell-protocol' => 'sdc' }), 'sdc', 'SDC can be chosen');
    eval { $P->_access_mode({ 'dell-protocol' => 'iscsi' }) };
    like($@, qr/SAN families/, 'a SAN protocol is rejected with a clear reason');

    like($P->get_identity({ 'dell-portal' => '10.0.0.7',
        'pflex-storage-pool' => 'pool1' }), qr/^dellpowerflex:10\.0\.0\.7:pool1$/,
        'identity pins the storage to one pool');

    is_deeply([$P->parse_volname('vm-100-disk-0')],
        ['images', 'vm-100-disk-0', 100, undef, undef, 0, 'raw'], 'volume name parsing');

    # The NVMe timeout is the ctrl-loss-tmo equivalent of no_path_retry, and
    # the schema must not allow it to be set to something unbounded.
    my $tmo = $props->{'pflex-nvme-ctrl-loss-tmo'};
    ok($tmo, 'the NVMe controller-loss timeout is configurable');
    is($tmo->{default}, 60, 'defaulting well below the kernel default of 600');
    cmp_ok($tmo->{maximum}, '<=', 600, 'and bounded');

    # All three Dell plugins declare no property in common; PVE would die.
    require PVE::Storage::Custom::DellPowerStorePlugin;
    require PVE::Storage::Custom::DellPowerVaultPlugin;
    my %seen;
    my @dup;
    for my $class (qw(DellPowerStorePlugin DellPowerVaultPlugin DellPowerFlexPlugin)) {
        my $full = "PVE::Storage::Custom::$class";
        for my $prop (keys %{ $full->properties }) {
            push @dup, $prop if $seen{$prop}++;
        }
    }
    is_deeply(\@dup, [], 'three Dell plugins, no duplicate property');
}

# ---------------------------------------------------------------------------
# Name limits
#
# PowerFlex allows 31 characters, one fewer than the PowerVault module it
# inherits the compact naming scheme from. The inherited methods must read the
# limit from the class, not from PowerVault's own constant, or every generated
# name is allowed to be one byte too long and the array rejects it.
# ---------------------------------------------------------------------------

{
    my $N = 'PVE::Storage::Custom::DellEMC::PowerFlex::Naming';

    is($N->max_volume_name_length, 31, 'the family limit is 31');

    my $volume = $N->encode_volume_name('pflexstor', 1234567, 0);
    my $snap   = $N->encode_snapshot_name($volume, 'abcdefghij');
    cmp_ok(length($snap), '<=', 31, 'a snapshot name stays within the limit');
    ok($N->is_valid_snapshot_name($snap), '... and validates');

    is($N->is_valid_volume_name('a' x 32), 0, '32 characters is refused');
    is($N->is_valid_volume_name('a' x 31), 1, '31 is accepted');
    is($N->is_valid_snapshot_name('a' x 32), 0, 'and the same for a snapshot');

    # PowerVault keeps its own 32, so the shared code really is per-class.
    my $V = 'PVE::Storage::Custom::DellEMC::PowerVault::Naming';
    is($V->is_valid_volume_name('a' x 32), 1, 'PowerVault still allows 32');
}

done_testing();
