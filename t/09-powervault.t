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

BEGIN {
    eval { require LWP::UserAgent; require JSON; require URI; 1 }
        or plan skip_all => 'libwww-perl, libjson-perl or liburi-perl is missing';
}

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
        # The columns 'show volumes' documents are Total Size and Alloc
        # Size, so those are the field names a real array answers with.
        return reply({ %{ ok_status() }, volumes => [
            { 'volume-name' => 'pve-me5-100-d0',
              'total-size-numeric' => 67108864,
              'alloc-size-numeric' => 2048,
              wwn => '600c0ff0001234560000000000000001' },
        ]}) if $path =~ m{/show/volumes};
        return reply(ok_status());
    });

    my $volumes = $api->volume_list('pve-me5-');
    is(scalar @$volumes, 1, 'volumes returned');

    my $path = $ua->last_request->uri->path;
    # 'show volumes [details] [pattern <string>] [pool <pool>] [type ...]',
    # in the order the CLI Reference gives them.
    like($path, qr{/show/volumes/details/pattern/pve-me5-},
        'filtered on the array by pattern, in the documented argument order');
    like($path, qr{/show/volumes/details/},
        'details requested, which is where the WWN lives');
    like($path, qr{/type/all$}, 'and every type, so snapshots are visible too');

    my $row = $volumes->[0];
    is($api->volume_size($row), 67108864 * 512,
        'the size comes from the documented Total Size field, in 512-byte blocks');
    is($api->volume_used($row), 2048 * 512,
        'and the used space from Alloc Size');

    # A zero here is the damaging answer, not an error: volume_resize compares
    # against the current size, so every request would look like growth, and
    # PVE would show the disk as empty.
    cmp_ok($api->volume_size($row), '>', 0, 'a size never silently reads as zero');

    # Older spellings stay behind the documented ones rather than being
    # dropped: a firmware that answers with them still works.
    is($api->volume_size({ 'size-numeric' => 100 }), 100 * 512,
        'the older Size spelling is still understood');
    is($api->volume_used({ 'allocated-size-numeric' => 8 }), 8 * 512,
        'and the older Allocated Size spelling');
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
    # A realistic row. The volume-view-mappings basetype gives 'nickname' as
    # the host or host group name and 'identifier' as the initiator's IQN or
    # WWPN, and a real array fills in both. Picking whichever field is defined
    # first then answers with the IQN for every row, so no LUN ever looks
    # used and the second volume mapped to a host collides with the first.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ %{ ok_status() }, 'volume-view-mappings' => [
            { nickname => 'pve-c1-node1', lun => 1,
              identifier => 'iqn.1993-08.org.debian:01:node1' },
            { nickname => 'pve-c1-node1', lun => 3,
              identifier => 'iqn.1993-08.org.debian:01:node1' },
            { nickname => 'pve-c1-node2', lun => 2,
              identifier => 'iqn.1993-08.org.debian:01:node2' },
        ]}) if $path =~ m{/show/maps};
        return reply(ok_status());
    });

    is($api->next_free_lun('pve-c1-node1'), 2,
        'a LUN in use by this host is not handed out again');
    is($api->next_free_lun('PVE-C1-NODE1'), 2,
        'and the name is matched without regard to case');
    is($api->next_free_lun('iqn.1993-08.org.debian:01:node1'), 2,
        'the initiator id identifies the same host');
    is($api->next_free_lun('pve-c1-node2'), 1,
        "another host's LUNs are its own");

    is($api->is_mapped('pve-me5-100-d0', 'pve-c1-node1'), 1,
        'the host name in nickname is a mapping');
    is($api->is_mapped('pve-me5-100-d0', 'iqn.1993-08.org.debian:01:node2'), 1,
        'and so is an initiator id in identifier');
    is($api->is_mapped('pve-me5-100-d0', 'pve-c1-node9'), 0,
        'a host that is not there is not');
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

    # 'rollback volume [prompt yes|no] snapshot <snapshot> <volume>', per the
    # CLI Reference. Without 'prompt yes' the array waits for a confirmation
    # that a script is never going to give it.
    $api->snapshot_rollback('pve-me5-100-d0', 'pve-me5-100-d0-s-x');
    like($ua->last_request->uri->path,
        qr{/api/rollback/volume/prompt/yes/snapshot/pve-me5-100-d0-s-x/pve-me5-100-d0$},
        'rollback answers the confirmation prompt and names snapshot then volume');
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

# ---------------------------------------------------------------------------
# Host commands, as the CLI Reference documents them
#
# These run on the first activation of the storage, so getting them wrong
# means the storage never comes up at all. Both were guessed before being
# checked against Dell's guide, and both guesses were wrong: the keyword is
# 'initiators', not 'id', and attaching an initiator to an existing host is
# 'add host-members', not 'set initiator' — which is a different command that
# names an initiator and does not attach it to anything.
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api();

    $api->host_create('pve-pve-node1',
        ['iqn.1993-08.org.debian:01:aaaa', 'iqn.1993-08.org.debian:01:bbbb']);

    my $path = $ua->last_request->uri->path;
    like($path, qr{/api/create/host/initiators/},
        "create host uses the 'initiators' keyword");
    like($path, qr{/pve-pve-node1$},
        '... and the host name comes last, after every parameter');
    like($path, qr{aaaa%2Ciqn|aaaa,iqn},
        '... with the initiators as one comma-separated list');

    $api->host_add_initiators('pve-pve-node1',
        ['iqn.1993-08.org.debian:01:cccc']);

    $path = $ua->last_request->uri->path;
    like($path, qr{/api/add/host-members/initiators/},
        'adding an initiator to an existing host uses add host-members');
    like($path, qr{/pve-pve-node1$}, '... with the host name last');
    unlike($path, qr{set/initiator},
        '... and never set initiator, which does something else entirely');

    # Nothing to add is not a command.
    my $before = scalar @{ $ua->requests };
    $api->host_add_initiators('pve-pve-node1', []);
    is(scalar @{ $ua->requests }, $before,
        'an empty initiator list sends nothing at all');
}

# ---------------------------------------------------------------------------
# map volume: the one command whose argument order differs between ME4 and ME5
#
# Both orders come from Dell's own CLI Reference. This plugin targets both
# families, so it sends the ME5 form and falls back to the ME4 one — mapping
# is the operation no volume can be used without.
# ---------------------------------------------------------------------------

{
    my @paths;
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        push @paths, $path;
        return reply({ status => [{ 'response-type' => 'Success',
                                    'return-code' => 0 }],
                       'volume-view-mappings' => [] })
            if $path =~ m{/show/maps};
        return reply(ok_status());
    });

    my $lun = $api->volume_map('pve-me5-100-d0', 'pve-pve-node1', lun => 7);
    is($lun, 7, 'the LUN chosen is the one reported back');

    my ($map_path) = grep { m{/map/volume/} } @paths;
    like($map_path, qr{/map/volume/access/rw/initiator/pve-pve-node1/lun/7/pve-me5-100-d0$},
        'the ME5 order is sent first: the volume comes last');

    is(scalar(grep { m{/map/volume/} } @paths), 1,
        'and one command is enough when the array accepts it');
}

{
    # An array that refuses the ME5 order must still get its volume mapped.
    my @map_paths;
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;

        if ($path =~ m{/map/volume/}) {
            push @map_paths, $path;
            # Refuse the ME5 form, accept the ME4 one.
            return reply(err_status('Invalid parameter', -10001))
                if $path =~ m{/lun/\d+/pve-me5-100-d0$};
            return reply(ok_status());
        }

        return reply(ok_status());
    });

    my $lun = eval { $api->volume_map('pve-me5-100-d0', 'pve-pve-node1', lun => 3) };

    is($lun, 3, 'the volume is mapped even so');
    is(scalar(@map_paths), 2, 'by trying the other documented order');
    like($map_paths[1], qr{/map/volume/pve-me5-100-d0/access/rw/},
        '... which puts the volume first, as the ME4 guide has it');
}

{
    # Both refused: one message, carrying both refusals.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(err_status('Invalid parameter', -10001))
            if $path =~ m{/map/volume/};
        return reply(ok_status());
    });

    ok(!eval { $api->volume_map('pve-me5-100-d0', 'pve-pve-node1', lun => 1); 1 },
        'an array that refuses both orders is a failure');
    like($@, qr/ME5 form.*ME4 form/s, '... reported with both refusals');
}

# ---------------------------------------------------------------------------
# A mapping row names an initiator, not a host
#
# 'show maps' reports Serial Number, Name, Ports, LUN, Access, Identifier,
# Nickname and Profile — there is no host-name column. Asking "is this volume
# mapped to host X" by comparing against a host name alone therefore always
# answers no, and the plugin would remap on every activation, taking a new LUN
# each time.
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({
            status => [{ 'response-type' => 'Success', 'return-code' => 0 }],
            'volume-view-mappings' => [
                { identifier => 'iqn.1993-08.org.debian:01:node1',
                  nickname   => 'pve-pve-node1',
                  lun => '3', access => 'read-write' },
            ],
        }) if $path =~ m{/show/maps};
        return reply(ok_status());
    });

    ok($api->is_mapped_to_any('pve-me5-100-d0', ['pve-pve-node1']),
        'a row is matched by the nickname, which is the host name here');

    ok($api->is_mapped_to_any('pve-me5-100-d0',
            ['iqn.1993-08.org.debian:01:node1']),
        'and by the initiator id, which is what Identifier holds');

    ok($api->is_mapped_to_any('pve-me5-100-d0',
            ['pve-other-node', 'iqn.1993-08.org.debian:01:node1']),
        'any one of the identities is enough');

    ok(!$api->is_mapped_to_any('pve-me5-100-d0', ['pve-some-other-node']),
        'and a node that is not there is not matched');

    ok(!$api->is_mapped_to_any('pve-me5-100-d0', []),
        'an empty identity list matches nothing');

    # Case: initiator ids are compared without regard to it.
    ok($api->is_mapped_to_any('pve-me5-100-d0',
            ['IQN.1993-08.ORG.DEBIAN:01:NODE1']),
        'initiator ids match regardless of case');

    my $mappings = $api->volume_mappings('pve-me5-100-d0');
    is($mappings->[0]{host}, 'pve-pve-node1',
        'the friendliest name is what is reported back for unmapping');
    is($mappings->[0]{lun}, '3', 'and the LUN comes with it');
}

# ---------------------------------------------------------------------------
# show ports: the array says which ports are usable
#
# The documented fields are Media (FC(P), FC(L), SAS, iSCSI), Target ID — the
# node name for an iSCSI port — Status (Up, Warning, Error, Not Present,
# Disconnected), IP Address and Health. Offering a port the array calls Not
# Present to the login loop costs this node a probe at best, and a discovery
# plus a login timeout at worst.
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({
            status => [{ 'response-type' => 'Success', 'return-code' => 0 }],
            port => [
                { media => 'iSCSI', 'target-id' => 'iqn.1988-11.com.dell:01.me5',
                  'ip-address' => '10.0.0.11', status => 'Up', health => 'OK' },
                { media => 'iSCSI', 'target-id' => 'iqn.1988-11.com.dell:01.me5',
                  'ip-address' => '10.0.0.12', status => 'Disconnected' },
                { media => 'iSCSI', 'target-id' => 'iqn.1988-11.com.dell:01.me5',
                  'ip-address' => '10.0.0.13', status => 'Not Present' },
                { media => 'iSCSI', 'target-id' => 'iqn.1988-11.com.dell:01.me5',
                  'ip-address' => '0.0.0.0', status => 'Up' },
                { media => 'FC(P)', 'target-id' => '207000c0ff1a2b3c',
                  status => 'Up' },
                { media => 'SAS', 'target-id' => '500c0ff1a2b3c000', status => 'Up' },
                # An unfamiliar firmware that reports no status at all must
                # not make the storage unusable.
                { media => 'iSCSI', 'target-id' => 'iqn.1988-11.com.dell:01.me5',
                  'ip-address' => '10.0.0.14' },
            ],
        }) if $path =~ m{/show/ports};
        return reply(ok_status());
    });

    my $portals = $api->iscsi_portals();

    is_deeply([map { $_->{portal} } @$portals],
        ['10.0.0.11:3260', '10.0.0.14:3260'],
        'only usable iSCSI ports with a real address are offered');

    is($portals->[0]{iqn}, 'iqn.1988-11.com.dell:01.me5',
        "the target IQN comes from 'Target ID', as documented");

    my $fc = $api->fc_ports();
    is(scalar(@$fc), 1, 'FC ports are picked out by media, which reads FC(P)');
    isnt($fc->[0]{media}, 'SAS', 'and SAS is not mistaken for one');
}

# ---------------------------------------------------------------------------
# Is this initiator already on this host?
#
# 'show host-groups' nests initiators inside hosts, and the JSON shape varies
# by firmware. Answering "no" when the answer is yes means re-adding a member
# on every host check, which the array refuses — and a refusal there fails
# activate_storage, so a working storage would go inactive.
# ---------------------------------------------------------------------------

{
    my ($api) = make_api();

    my $iqn = 'iqn.1993-08.org.debian:01:node1';

    # Whatever the firmware nests it in, the id is findable.
    my @shapes = (
        { name => 'h1', initiator => [{ id => $iqn, nickname => 'node1' }] },
        { name => 'h1', initiators => { initiator => [{ 'initiator-id' => $iqn }] } },
        { name => 'h1', 'host-members' => [{ id => uc($iqn) }] },
        { name => 'h1', id => $iqn },
    );

    for my $i (0 .. $#shapes) {
        ok($api->host_has_initiator($shapes[$i], $iqn),
            "the initiator is found however the firmware nests it (shape $i)");
    }

    ok(!$api->host_has_initiator({ name => 'h1', initiator => [{ id => 'iqn.other' }] },
            $iqn),
        'and a host without it says so');

    ok(!$api->host_has_initiator({ name => 'h1' }, $iqn),
        'as does a host with no initiators at all');

    ok(!$api->host_has_initiator({ name => 'h1', id => $iqn }, ''),
        'an empty initiator id matches nothing');

    # A structure that refers to itself must not spin.
    my $loop = { name => 'h1' };
    $loop->{self} = $loop;
    my $done = eval { $api->host_has_initiator($loop, $iqn); 1 };
    ok($done, 'a self-referential structure terminates');
}

{
    # Adding an initiator that is already a member is the state we wanted.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(err_status('The initiator is already a member of the host', -1))
            if $path =~ m{/add/host-members};
        return reply(ok_status());
    });

    ok(eval { $api->host_add_initiators('pve-pve-node1', ['iqn.test']); 1 },
        'an initiator that is already a member is not an error');

    my ($api2, $ua2) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(err_status('No such host', -10058))
            if $path =~ m{/add/host-members};
        return reply(ok_status());
    });

    ok(!eval { $api2->host_add_initiators('pve-pve-node1', ['iqn.test']); 1 },
        'but a real failure still is one');
}

# ---------------------------------------------------------------------------
# Pool capacity
#
# 'show pools' reports Total Size, Avail and Snap Size. Reading the wrong
# spelling of Avail leaves available at 0, which makes every pool look full:
# PVE then refuses to allocate and the capacity alert fires on the first poll.
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({
            status => [{ 'response-type' => 'Success', 'return-code' => 0 }],
            pools => [
                { name => 'A', 'total-size-numeric' => 2_000_000,
                  'avail-numeric' => 1_500_000, 'snap-size-numeric' => 100_000 },
            ],
        }) if $path =~ m{/show/pools};
        return reply(ok_status());
    });

    my ($total, $used, $avail) = $api->get_managed_capacity();

    is($total, 2_000_000 * 512, 'the total comes from Total Size');
    is($avail, 1_500_000 * 512, 'the available comes from Avail');
    is($used,  500_000 * 512,   'and used is what is left over');
    cmp_ok($avail, '>', 0, 'a healthy pool never reads as full');
}

{
    # Two pools, and only one of them asked for.
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({
            status => [{ 'response-type' => 'Success', 'return-code' => 0 }],
            pools => [
                { name => 'A', 'total-size-numeric' => 1000, 'avail-numeric' => 400 },
                { name => 'B', 'total-size-numeric' => 3000, 'avail-numeric' => 3000 },
            ],
        }) if $path =~ m{/show/pools};
        return reply(ok_status());
    });

    my ($total, $used, $avail) = $api->get_managed_capacity(pool => 'B');
    is($total, 3000 * 512, 'only the named pool is counted');

    ($total, $used, $avail) = $api->get_managed_capacity();
    is($total, 4000 * 512, 'and without a name, all of them are');

    ok(!eval { $api->get_managed_capacity(pool => 'nosuch'); 1 },
        'a pool that does not exist is an error');
    like($@, qr/does not exist.*A, B|Available pools/s,
        '... listing the pools that do');
}

done_testing();
