#!/usr/bin/perl
# PowerStore REST client tests.
#
# The array is replaced by a fake user agent that routes on method and path
# and answers from t/fixtures/powerstore/. That covers request shape — filter
# syntax, paging, bodies, headers — which is what this client gets wrong when
# it is wrong. It cannot validate the endpoints themselves; that needs
# hardware and is tracked in docs/TESTING.md.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use HTTP::Response;
use HTTP::Headers;
use JSON;
use URI;

BEGIN {
    eval { require LWP::UserAgent; require JSON; require URI; 1 }
        or plan skip_all => 'libwww-perl, libjson-perl or liburi-perl is missing';
}

use PVE::Storage::Custom::DellEMC::PowerStore::API;
use PVE::Storage::Custom::DellEMC::PowerStore::Naming;

my $API = 'PVE::Storage::Custom::DellEMC::PowerStore::API';

my $FIXTURE_DIR = -d 't/fixtures/powerstore' ? 't/fixtures/powerstore'
                : 'fixtures/powerstore';

sub fixture {
    my ($name) = @_;
    my $path = "$FIXTURE_DIR/$name.json";
    open(my $fh, '<', $path) or die "cannot read fixture $path: $!";
    local $/;
    return decode_json(<$fh>);
}

# ---------------------------------------------------------------------------
# Fake array
# ---------------------------------------------------------------------------

{
    package FakeArray;

    sub new {
        my ($class, %args) = @_;
        return bless {
            timeout   => 15,
            requests  => [],
            responses => $args{responses} // {},
            handler   => $args{handler},
        }, $class;
    }

    sub timeout {
        my ($self, $value) = @_;
        $self->{timeout} = $value if defined $value;
        return $self->{timeout};
    }

    sub default_header { return }
    sub cookie_jar { return }
    sub can { my ($self, $m) = @_; return $m eq 'cookie_jar' ? 0 : UNIVERSAL::can($self, $m) }

    sub request {
        my ($self, $req) = @_;

        my $uri = $req->uri;
        my $key = $req->method . ' ' . $uri->path;
        push @{ $self->{requests} }, $req;

        return $self->{handler}->($req, $key, $self) if $self->{handler};

        my $body = $self->{responses}{$key};
        $body = [] unless defined $body;

        my $headers = HTTP::Headers->new('Content-Type' => 'application/json');
        return HTTP::Response->new(200, undef, $headers, JSON::encode_json($body));
    }

    sub requests { return $_[0]{requests} }
    sub last_request { return $_[0]{requests}[-1] }

    sub query_of {
        my ($self, $index) = @_;
        my $req = $self->{requests}[$index // -1] or return {};
        my %q = URI->new($req->uri)->query_form;
        return \%q;
    }
}

sub json_response {
    my ($code, $data, %headers) = @_;
    my $h = HTTP::Headers->new(%headers);
    $h->header('Content-Type' => 'application/json');
    return HTTP::Response->new($code, undef, $h, encode_json($data));
}

# A user agent that answers the login and then defers to $handler.
sub make_api {
    my (%args) = @_;

    my $inner = delete $args{handler};
    my $ua = FakeArray->new(handler => sub {
        my ($req, $key, $self) = @_;

        if ($key eq 'GET /api/rest/login_session') {
            my $h = HTTP::Headers->new('DELL-EMC-TOKEN' => 'tok-123');
            $h->header('Content-Type' => 'application/json');
            return HTTP::Response->new(200, undef, $h, '[]');
        }

        return $inner->($req, $key, $self) if $inner;
        return json_response(200, []);
    });

    my $api = $API->new(
        portal   => '10.0.0.5',
        username => 'pveadmin',
        password => 'secret',
        storeid  => 'ps1',
        type     => 'dellpowerstore',
        ua       => $ua,
        %args,
    );

    return ($api, $ua);
}

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

# PowerStore refuses a size that is not a multiple of 8 KiB. Rounding DOWN
# would silently hand back a volume smaller than PVE asked for.
is($API->align_size(8192), 8192, 'an aligned size is unchanged');
is($API->align_size(1), 8192, 'a tiny size rounds up to one granule');
is($API->align_size(8193), 16384, 'an unaligned size rounds up');
is($API->align_size(34359738368), 34359738368, '32 GiB is already aligned');
is($API->align_size(1024 * 1024), 1048576, '1 MiB is already aligned');
ok($API->align_size(12345) >= 12345, 'alignment never shrinks a request');

# The multipath map name is '3' plus the NAA designator.
is($API->wwn_to_wwid('naa.68ccf09800a1b2c3d4e5f60718293a4b'),
    '368ccf09800a1b2c3d4e5f60718293a4b', 'naa. form');
is($API->wwn_to_wwid('68CCF09800A1B2C3D4E5F60718293A4B'),
    '368ccf09800a1b2c3d4e5f60718293a4b', 'bare uppercase form');
is($API->wwn_to_wwid('0x68ccf09800a1b2c3d4e5f60718293a4b'),
    '368ccf09800a1b2c3d4e5f60718293a4b', '0x form');
is($API->wwn_to_wwid('naa.68:cc:f0:98:00:a1:b2:c3:d4:e5:f6:07:18:29:3a:4b'),
    '368ccf09800a1b2c3d4e5f60718293a4b', 'colon form');
is($API->wwn_to_wwid('short'), undef, 'a too-short WWN yields nothing');
is($API->wwn_to_wwid(''), undef, 'empty WWN');
is($API->wwn_to_wwid(undef), undef, 'undef WWN');

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api();
    $api->cluster_get();

    my $login = $ua->requests->[0];
    is($login->method . ' ' . $login->uri->path, 'GET /api/rest/login_session',
        'authenticates against login_session');
    like($login->header('Authorization'), qr/^Basic /, 'with HTTP Basic');

    my $call = $ua->requests->[1];
    is($call->header('DELL-EMC-TOKEN'), 'tok-123',
        'subsequent calls carry the DELL-EMC-TOKEN header');

    $api->cluster_get();
    is(scalar @{ $ua->requests }, 3, 'the session is reused, not re-established');
}

{
    # Dell documents the CSRF token as something to fetch with a GET before
    # each write, which leaves open whether the array reissues it during a
    # session. If it does and this client keeps presenting the login-time one,
    # every write eventually fails while every read still works — a failure
    # that would look like a permissions problem.
    my $n = 0;
    my ($api, $ua) = make_api(handler => sub {
        my $h = HTTP::Headers->new('DELL-EMC-TOKEN' => 'rotated-' . ++$n);
        $h->header('Content-Type' => 'application/json');
        return HTTP::Response->new(200, undef, $h, '[]');
    });

    $api->cluster_get();
    $api->cluster_get();

    is($ua->requests->[-1]->header('DELL-EMC-TOKEN'), 'rotated-1',
        'a token offered on a response is used on the next request');

    $api->cluster_get();
    is($ua->requests->[-1]->header('DELL-EMC-TOKEN'), 'rotated-2',
        'and keeps tracking it as the array rotates');
}

{
    # An array that never rotates must not be disturbed by the tracking.
    my ($api, $ua) = make_api();
    $api->cluster_get();
    $api->cluster_get();
    is($ua->requests->[-1]->header('DELL-EMC-TOKEN'), 'tok-123',
        'a token that never changes stays put');
}

{
    # The session cookie is as much of the credential as the token. Leaving a
    # rejected one in the jar means the re-login presents a stale cookie
    # alongside fresh Basic credentials.
    # Built without an injected user agent, so this exercises the real one the
    # plugin constructs — the only place the cookie jar actually exists.
    my $api = $API->new(portal => '10.0.0.5', username => 'u', password => 'p',
        storeid => 'ps1', type => 'dellpowerstore');

    my $jar = $api->ua->cookie_jar;
    ok($jar, 'the real user agent carries a cookie jar');

    $jar->set_cookie(0, 'auth_cookie', 'stale', '/', '10.0.0.5');
    my $before = 0;
    $jar->scan(sub { $before++ });
    is($before, 1, 'with the session cookie in it');

    $api->_mark_session({ token => 'tok' });
    $api->_clear_session();

    my $left = 0;
    $jar->scan(sub { $left++ });
    is($left, 0, 'clearing the session empties the cookie jar');
}

{
    # A login that returns no token must fail with something diagnosable
    # rather than proceeding unauthenticated.
    my $ua = FakeArray->new(handler => sub { json_response(200, []) });
    my $api = $API->new(portal => 'x', username => 'u', password => 'p', ua => $ua);
    eval { $api->cluster_get() };
    like($@, qr/no DELL-EMC-TOKEN/, 'a missing token is reported');
    like($@, qr/PowerStore management address/, 'and hints at the likely cause');
}

# ---------------------------------------------------------------------------
# Volume listing
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, fixture('volume')) if $key eq 'GET /api/rest/volume';
        return json_response(200, []);
    });

    my $volumes = $api->volume_list('pve-ps1-');
    is(scalar @$volumes, 2, 'volumes returned');
    is($volumes->[0]{name}, 'pve-ps1-100-disk0', 'first volume');

    my $query = $ua->query_of(-1);
    is($query->{name}, 'ilike.pve-ps1-*', 'filtered server-side by name prefix');
    is($query->{type}, 'eq.Primary', 'snapshots excluded by default');
    like($query->{select}, qr/\bwwn\b/, 'the WWN is requested explicitly');
    like($query->{select}, qr/\bsize\b/, 'and the size');
    is($query->{limit}, 200, 'a page size is set');
    is($query->{offset}, 0, 'starting at the first page');

    # Dell's own examples spell the ilike wildcard '*', not '%'. A wildcard
    # this array reads as an ordinary character matches nothing, and every
    # volume silently disappears from PVE while the array still holds them.
    like($ua->last_request->uri->as_string, qr/name=ilike\.pve-ps1-(?:\*|%2A)/i,
        'the documented wildcard reaches the array');
}

{
    # Dell documents an offset past the end of a collection as 416 Range Not
    # Satisfiable. Paging can reach one legitimately: the total comes from the
    # first page, and a volume deleted on another node between pages makes the
    # collection shorter than that total. Dying there would turn an ordinary
    # concurrent delete into a storage that reports itself broken.
    my $page = [ map { { id => "v$_", name => "pve-ps1-1$_-disk0" } } (1 .. 200) ];
    my $calls = 0;
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, []) unless $key eq 'GET /api/rest/volume';
        return json_response(206, $page, 'Content-Range' => '0-199/400')
            if $calls++ == 0;
        return HTTP::Response->new(416, undef,
            HTTP::Headers->new('Content-Type' => 'application/json'),
            '{"messages":[{"code":"0xE0101001","message_l10n":"bad range"}]}');
    });

    my $volumes = eval { $api->volume_list() };
    ok($volumes, 'a 416 while paging is not fatal')
        or diag("died with: $@");
    is(scalar @$volumes, 200, 'and the pages already read are kept');
}

{
    # A 416 that is not part of paging must still be an error.
    my ($api) = make_api(handler => sub {
        return HTTP::Response->new(416, undef,
            HTTP::Headers->new('Content-Type' => 'application/json'), '{}');
    });

    ok(!eval { $api->volume_get('vol-1'); 1 },
        'a 416 on an ordinary request still fails');
}

{
    # An array that reads the wildcard as an ordinary character. The filtered
    # query matches nothing, which is indistinguishable from "this storage is
    # empty" — so the client must look again without the filter rather than
    # report every volume as gone.
    my @warned;
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, []) unless $key eq 'GET /api/rest/volume';
        my %q = URI->new($req->uri)->query_form;
        return json_response(200, []) if defined $q{name};   # the filter misses
        return json_response(200, fixture('volume'));
    });
    no warnings 'redefine';
    local *PVE::Storage::Custom::DellEMC::PowerStore::API::log_warn =
        sub { push @warned, $_[1] };

    my $volumes = $api->volume_list('pve-ps1-');
    is(scalar @$volumes, 2, 'the volumes are found anyway');
    is($volumes->[0]{name}, 'pve-ps1-100-disk0', 'and are the right ones');

    is(scalar @warned, 1, 'and it says so exactly once');
    like($warned[0], qr/ilike wildcard/, '... naming what is wrong');
    like($warned[0], qr/filtering locally/, '... and what it did instead');

    # A second call must not repeat the warning into the journal every poll.
    $api->volume_list('pve-ps1-');
    is(scalar @warned, 1, 'and not once per poll thereafter');
}

{
    # A filter the array applies too broadly is the other direction of the
    # same mistake: another storage's volumes must not arrive in this one's
    # listing just because the array matched a substring.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, []) unless $key eq 'GET /api/rest/volume';
        return json_response(200, [
            { id => 'v1', name => 'pve-ps1-100-disk0' },
            { id => 'v2', name => 'other-pve-ps1-999-disk0' },
            { id => 'v3', name => 'unrelated' },
        ]);
    });

    my $volumes = $api->volume_list('pve-ps1-');
    is_deeply([map { $_->{name} } @$volumes], ['pve-ps1-100-disk0'],
        'only names that really start with the prefix are kept');
}

{
    # An empty storage stays empty — the fallback must not invent rows, and
    # must not warn about a filter that was working correctly.
    my @warned;
    my ($api) = make_api(handler => sub { json_response(200, []) });
    no warnings 'redefine';
    local *PVE::Storage::Custom::DellEMC::PowerStore::API::log_warn =
        sub { push @warned, $_[1] };

    is_deeply($api->volume_list('pve-ps1-'), [], 'no volumes, no rows');
    is_deeply(\@warned, [], 'and nothing to complain about');
}

{
    # More rows than one page: the client must follow the pages rather than
    # silently returning the first 200 volumes.
    my $page = [ map { { id => "v$_", name => "pve-ps1-1$_-disk0" } } (1 .. 200) ];
    my $rest = [ map { { id => "w$_", name => "pve-ps1-9$_-disk0" } } (1 .. 5) ];

    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, []) unless $key eq 'GET /api/rest/volume';
        my %q = URI->new($req->uri)->query_form;
        return json_response(200, $q{offset} ? $rest : $page);
    });

    my $volumes = $api->volume_list('pve-ps1-');
    is(scalar @$volumes, 205, 'every page is collected');
    is($ua->query_of(-1)->{offset}, 200, 'the second page asked for an offset');
}

{
    # The array is free to answer with fewer rows than the page size asked
    # for. Stopping on a short page then truncates the result silently: disks
    # disappear from the list AND the orphan reaper stops seeing live volumes,
    # which is how it starts treating them as deleted. The array reports the
    # true total in Content-Range with its 206, and that is what must decide.
    my @all = map { { id => "v$_", name => "pve-ps1-1$_-disk0" } } (1 .. 250);

    my $total = scalar(@all);

    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, []) unless $key eq 'GET /api/rest/volume';

        my %q = URI->new($req->uri)->query_form;
        my $offset = $q{offset} // 0;

        # A cap well below the requested limit of 200. The end index is
        # clamped: a slice that runs past the end would be aliased by grep and
        # grow the array, which would make this fake, not the client, decide
        # how many rows exist.
        my $end = $offset + 99;
        $end = $total - 1 if $end > $total - 1;
        my @slice = $offset <= $end ? @all[$offset .. $end] : ();
        my $last  = $offset + scalar(@slice) - 1;

        return json_response(206, \@slice,
            'Content-Range' => "items $offset-$last/$total");
    });

    my $volumes = $api->volume_list('pve-ps1-');
    is(scalar @$volumes, 250,
        'a page shorter than requested does not end the walk');
    is($ua->query_of(-1)->{offset}, 200,
        'the offset advances by what actually arrived');
}

{
    # No Content-Range at all: fall back to treating a short page as the end,
    # which is the only thing left to go on.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, []) unless $key eq 'GET /api/rest/volume';
        return json_response(200, [ { id => 'v1', name => 'pve-ps1-100-disk0' } ]);
    });

    my $volumes = $api->volume_list('pve-ps1-');
    is(scalar @$volumes, 1, 'a single short page without a header ends the walk');
    is(scalar @{ $ua->requests }, 2, 'and costs one login plus one request');
}

{
    # Content-Range that says '*' (the array will not count) must not stop the
    # walk early or loop forever.
    my $calls = 0;
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, []) unless $key eq 'GET /api/rest/volume';
        $calls++;
        my @rows = map { { id => "v$_", name => "pve-ps1-1$_-disk0" } } (1 .. 200);
        return json_response(206, $calls > 1 ? [] : \@rows,
            'Content-Range' => 'items 0-199/*');
    });

    my $volumes = $api->volume_list('pve-ps1-');
    is(scalar @$volumes, 200, 'an uncounted range walks until a page is empty');
}

{
    # An exact-name lookup must use eq., not a prefix match: 'pve-ps1-10' is a
    # prefix of 'pve-ps1-100-disk0'.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, [fixture('volume')->[0]]);
    });

    my $vol = $api->volume_get_by_name('pve-ps1-100-disk0');
    is($vol->{name}, 'pve-ps1-100-disk0', 'volume found by exact name');
    is($ua->query_of(-1)->{name}, 'eq.pve-ps1-100-disk0', 'exact filter used');
}

# ---------------------------------------------------------------------------
# Volume lifecycle
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(201, { id => 'new-volume-id' })
            if $key eq 'POST /api/rest/volume';
        return json_response(200, []);
    });

    my $id = $api->volume_create('pve-ps1-100-disk0', 34359738368,
        appliance_id => 'A1', volume_group_id => 'vg-1');
    is($id, 'new-volume-id', 'the new volume id is returned');

    my $body = decode_json($ua->last_request->content);
    is($body->{name}, 'pve-ps1-100-disk0', 'name sent');
    is($body->{size}, 34359738368, 'size sent in bytes');
    is($body->{appliance_id}, 'A1', 'appliance placement sent');
    is($body->{volume_group_id}, 'vg-1', 'volume group sent');
    ok(!exists $body->{protection_policy_id}, 'unset options are omitted entirely');
}

{
    # An unaligned request must be rounded up before it reaches the array.
    my ($api, $ua) = make_api(handler => sub { json_response(201, { id => 'x' }) });
    $api->volume_create('pve-ps1-100-disk1', 1000);
    is(decode_json($ua->last_request->content)->{size}, 8192,
        'the size is aligned on the way out');
}

{
    my ($api, $ua) = make_api(handler => sub { json_response(200, {}) });

    $api->volume_resize('vol-1', 64 * 1024 ** 3);
    is($ua->last_request->method, 'PATCH', 'resize is a PATCH');
    is(decode_json($ua->last_request->content)->{size}, 64 * 1024 ** 3, 'new size');

    $api->volume_rename('vol-1', 'pve-ps1-101-disk5');
    is(decode_json($ua->last_request->content)->{name}, 'pve-ps1-101-disk5', 'rename body');

    $api->volume_delete('vol-1');
    is($ua->last_request->method, 'DELETE', 'delete verb');
    is($ua->last_request->uri->path, '/api/rest/volume/vol-1', 'delete path');
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(201, { id => 'snap-id' })
            if $key =~ m{^POST /api/rest/volume/[^/]+/snapshot$};
        return json_response(200, fixture('snapshot'))
            if $key eq 'GET /api/rest/volume';
        return json_response(200, {});
    });

    my $id = $api->snapshot_create('vol-1', 'pve-ps1-100-disk0.pve-snap-x');
    is($id, 'snap-id', 'snapshot id returned');
    is($ua->last_request->uri->path, '/api/rest/volume/vol-1/snapshot',
        'snapshots are created on the volume');

    my $snaps = $api->snapshot_list(source_id => 'vol-1');
    is(scalar @$snaps, 1, 'snapshots listed');
    my $query = $ua->query_of(-1);
    is($query->{type}, 'eq.Snapshot', 'filtered to snapshot objects');
    is($query->{'protection_data->>source_id'}, 'eq.vol-1',
        'and to the snapshots of this volume');

    $api->snapshot_list(prefix => 'pve-ps1-');
    is($ua->query_of(-1)->{name}, 'ilike.pve-ps1-*', 'prefix listing filter');

    $api->volume_restore('vol-1', 'snap-1');
    is($ua->last_request->uri->path, '/api/rest/volume/vol-1/restore', 'restore path');
    my $body = decode_json($ua->last_request->content);
    is($body->{from_snap_id}, 'snap-1', 'restores from the given snapshot');
    is($body->{create_backup_snap}, JSON::false,
        'no extra backup snapshot: PVE does not expect one to appear');

    $api->volume_clone('vol-1', 'pve-ps1-200-disk0');
    is($ua->last_request->uri->path, '/api/rest/volume/vol-1/clone', 'clone path');
    is(decode_json($ua->last_request->content)->{name}, 'pve-ps1-200-disk0', 'clone name');
}

# ---------------------------------------------------------------------------
# LUN id assignment
#
# PowerStore's REST-side automatic LUN id sequence starts at 200 and never
# reuses an id, so a cluster that repeatedly attaches and detaches walks it
# past what the host scans and new disks stop appearing. The client assigns
# the id itself to keep it dense.
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, fixture('host_volume_mapping'))
            if $key eq 'GET /api/rest/host_volume_mapping';
        return json_response(200, {});
    });

    # The fixture host holds LUN 1 and LUN 3.
    is($api->next_free_lun('h-0000-0001'), 2, 'the gap is filled before growing');
    is($api->next_free_lun('h-0000-0001', base => 4), 4, 'a base can be raised');
    is($api->next_free_lun('h-0000-0001', base => 0), 2,
        'a base below the minimum is clamped');

    my $query = $ua->query_of(-1);
    is($query->{host_id}, 'eq.h-0000-0001', 'mappings are queried per host');
}

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, fixture('host_volume_mapping'))
            if $key eq 'GET /api/rest/host_volume_mapping';
        return json_response(200, {});
    });

    $api->volume_attach('vol-9', host_id => 'h-0000-0001');
    my $body = decode_json($ua->last_request->content);
    is($ua->last_request->uri->path, '/api/rest/volume/vol-9/attach', 'attach path');
    is($body->{host_id}, 'h-0000-0001', 'host in the body');
    is($body->{logical_unit_number}, 2,
        'the LUN id is assigned explicitly, never left to the array');

    $api->volume_attach('vol-9', host_id => 'h-0000-0001', lun => 42);
    is(decode_json($ua->last_request->content)->{logical_unit_number}, 42,
        'an explicit LUN id wins');

    $api->volume_detach('vol-9', host_id => 'h-0000-0001');
    is($ua->last_request->uri->path, '/api/rest/volume/vol-9/detach', 'detach path');

    eval { $api->volume_attach('vol-9') };
    like($@, qr/needs a host_id/, 'attaching to nothing is refused');
    eval { $api->volume_detach('vol-9') };
    like($@, qr/needs a host_id/, 'detaching from nothing is refused');
}

{
    # Every LUN id taken must fail with something actionable.
    my @full = map { { host_id => 'h1', logical_unit_number => $_ } } (1 .. 255);
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;
        if ($key eq 'GET /api/rest/host_volume_mapping') {
            my %q = URI->new($req->uri)->query_form;
            # Only the first page has rows, as a real array would answer.
            return json_response(200, $q{offset} ? [] : \@full);
        }
        return json_response(200, {});
    });

    eval { $api->next_free_lun('h1') };
    like($@, qr/every LUN id/, 'exhaustion is reported');
    like($@, qr/Detach volumes|lower pstore-lun-id-base/, 'with a way out');
}

# The ceiling is 255 on purpose, and raising it is not a free win. Dell's
# KB 000199943 says a Linux host with the Emulex FC driver scans LUN ids
# 0-255 by default; a volume mapped above what the host scans is a volume
# PVE never sees, and nothing at either end reports an error.
cmp_ok($API->MAX_LUN_ID, '<=', 255,
    'LUN ids stay inside what a default Linux FC driver scans');
cmp_ok($API->MIN_LUN_ID, '>=', 1,
    'and start at 1, because some initiators refuse LUN 0');

# ---------------------------------------------------------------------------
# Mappings
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, fixture('host_volume_mapping'))
            if $key eq 'GET /api/rest/host_volume_mapping';
        return json_response(200, []);
    });

    is($api->is_mapped('1f3e5c88-0000-4000-8000-000000000001', 'h-0000-0001'), 1,
        'an existing mapping is found');
    is($api->is_mapped('1f3e5c88-0000-4000-8000-000000000001', 'h-0000-0009'), 0,
        'another host is not confused for it');
}

{
    # A host that belongs to a host group can be reached by a mapping made to
    # the group, and such a row carries host_group_id with no host_id.
    # Reading only host_id calls the volume unmapped, so the plugin attaches
    # it again and the array refuses a thing it is already doing.
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, [
            { id => 'm1', host_id => undef, host_group_id => 'hg-1',
              volume_id => 'v1', logical_unit_number => 7 },
        ]) if $key eq 'GET /api/rest/host_volume_mapping';
        return json_response(200, []);
    });

    is($api->is_mapped('v1', 'h-1'), 0,
        'without a group, only a host-level mapping counts');
    is($api->is_mapped('v1', 'h-1', group_id => 'hg-1'), 1,
        "a mapping to the host's group counts as mapped");
    is($api->is_mapped('v1', 'h-1', group_id => 'hg-2'), 0,
        "another group's mapping does not");
}

{
    # A LUN id is unique per host, and a group mapping occupies one on every
    # host in the group. Ignoring those hands out an id already in use.
    my @seen;
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, []) unless $key eq 'GET /api/rest/host_volume_mapping';
        my %q = URI->new($req->uri)->query_form;
        push @seen, $q{host_id} // $q{host_group_id} // '?';
        return json_response(200, [
            { id => 'm1', host_id => 'h-1', logical_unit_number => 1 },
        ]) if defined $q{host_id};
        return json_response(200, [
            { id => 'm2', host_group_id => 'hg-1', logical_unit_number => 2 },
        ]);
    });

    is($api->next_free_lun('h-1', group_id => 'hg-1'), 3,
        'a LUN held by a group mapping is not handed out to a host in it');
    is_deeply(\@seen, ['eq.h-1', 'eq.hg-1'],
        'and both listings were asked for');

    is($api->next_free_lun('h-1'), 2,
        'with no group, only the host-level mappings are considered');
}

# ---------------------------------------------------------------------------
# Hosts
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, fixture('host')) if $key eq 'GET /api/rest/host';
        return json_response(201, { id => 'h-new' }) if $key eq 'POST /api/rest/host';
        return json_response(200, {});
    });

    my $hosts = $api->host_list('pve-mycluster-');
    is(scalar @$hosts, 2, 'hosts listed');
    is($ua->query_of(-1)->{name}, 'ilike.pve-mycluster-*', 'host prefix filter');

    my $id = $api->host_create('pve-mycluster-node3',
        [{ port_name => 'iqn.1993-08.org.debian:01:node3', port_type => 'iSCSI' }]);
    is($id, 'h-new', 'host id returned');

    my $body = decode_json($ua->last_request->content);
    is($body->{os_type}, 'Linux', 'os_type defaults to Linux');
    is($body->{initiators}[0]{port_type}, 'iSCSI', 'initiator carried through');

    $api->host_add_initiators('h-1', [{ port_name => 'iqn.x', port_type => 'iSCSI' }]);
    ok(decode_json($ua->last_request->content)->{add_initiators},
        'initiators are added with add_initiators');
}

# ---------------------------------------------------------------------------
# Transport endpoints
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, fixture('ip_pool_address'))
            if $key eq 'GET /api/rest/ip_pool_address';
        return json_response(200, fixture('ip_port'))
            if $key eq 'GET /api/rest/ip_port';
        return json_response(200, []);
    });

    my $portals = $api->iscsi_portals();
    is(scalar @$portals, 2, 'both target addresses become portals');
    is($portals->[0]{portal}, '10.10.10.11:3260', 'address and default port');
    like($portals->[0]{iqn}, qr/^iqn\.2015-10\.com\.dell:/, 'paired with the target IQN');

    my ($addr_req) = grep { $_->uri->path eq '/api/rest/ip_pool_address' } @{ $ua->requests };
    my %q = URI->new($addr_req->uri)->query_form;
    is($q{purposes}, 'cs.{Storage_Iscsi_Target}',
        'only addresses published for iSCSI targets are asked for');
}

{
    # An array with no iSCSI configured must yield an empty list, not a crash.
    my ($api) = make_api(handler => sub { json_response(200, []) });
    is_deeply($api->iscsi_portals(), [], 'no addresses, no portals');
}

{
    # 'cs' and its brace-literal argument have never been seen answered by a
    # real appliance. An operator the array rejects or reads differently
    # returns nothing, which here means no portals, no iSCSI login and no
    # devices at all — so the filter must not be what decides the answer.
    my @warned;
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;

        if ($key eq 'GET /api/rest/ip_pool_address') {
            my %q = URI->new($req->uri)->query_form;
            return json_response(200, []) if defined $q{purposes};
            return json_response(200, [
                { id => 'a1', address => '10.10.10.11', appliance_id => 'A1',
                  purposes => ['Storage_Iscsi_Target'] },
                { id => 'a2', address => '10.10.10.99', appliance_id => 'A1',
                  purposes => ['Management'] },
                { id => 'a3', address => '10.10.10.12', appliance_id => 'A1',
                  purposes => 'Storage_Iscsi_Target' },   # a bare string
            ]);
        }
        return json_response(200, [
            { id => 'p1', target_iqn => 'iqn.2015-10.com.dell:x', appliance_id => 'A1' },
        ]) if $key eq 'GET /api/rest/ip_port';

        return json_response(200, []);
    });
    no warnings 'redefine';
    local *PVE::Storage::Custom::DellEMC::PowerStore::API::log_warn =
        sub { push @warned, $_[1] };

    my $portals = $api->iscsi_portals();
    is_deeply([map { $_->{portal} } @$portals],
        ['10.10.10.11:3260', '10.10.10.12:3260'],
        'the iSCSI target addresses are found without the filter');
    like($warned[0] // '', qr/Storage_Iscsi_Target/,
        'and it says the filter is what failed');
}

{
    # The fallback must not turn a management address into a portal.
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, [
            { id => 'a2', address => '10.10.10.99', purposes => ['Management'] },
        ]) if $key eq 'GET /api/rest/ip_pool_address';
        return json_response(200, []);
    });

    is_deeply($api->iscsi_portals(), [],
        'an address with no iSCSI purpose is not a portal');
}

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, fixture('space_metrics_by_cluster'))
            if $key eq 'GET /api/rest/space_metrics_by_cluster';
        return json_response(200, []);
    });

    my ($total, $used, $avail) = $api->get_managed_capacity();
    is($total, 21990232555520, 'total capacity');
    is($used, 4398046511104, 'used capacity');
    is($avail, $total - $used, 'available is derived');
}

{
    # space_metrics_by_cluster is an ENTITY NAME for the metrics service, not
    # a REST collection. POST /metrics/generate is the documented way to read
    # one and is what Dell's own SDK sends. An array that does not expose the
    # series as a collection would otherwise have reported no capacity at all,
    # which makes status() return undef and the storage show as inactive with
    # nothing else wrong with it.
    my @posted;
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;

        return json_response(200, [{ id => 'cl-1', name => 'Cluster' }])
            if $key eq 'GET /api/rest/cluster';

        if ($key eq 'POST /api/rest/metrics/generate') {
            push @posted, decode_json($req->content // '{}');
            # PowerStore returns these oldest first.
            return json_response(200, [
                { timestamp => '2026-07-01T00:00:00Z',
                  physical_total => 1000, physical_used => 100 },
                { timestamp => '2026-07-27T00:00:00Z',
                  physical_total => 21990232555520,
                  physical_used  => 4398046511104 },
            ]);
        }

        # The collection form does not exist on this array.
        return HTTP::Response->new(404, undef,
            HTTP::Headers->new('Content-Type' => 'application/json'), '{}')
            if $key =~ m{space_metrics};

        return json_response(200, []);
    });

    my ($total, $used, $avail) = $api->get_managed_capacity();
    is($total, 21990232555520, 'the capacity comes from the metrics service');
    is($used, 4398046511104, 'and so does the used figure');
    is($avail, $total - $used, 'available is derived');

    is($posted[0]{entity}, 'space_metrics_by_cluster', 'the entity is named');
    is($posted[0]{entity_id}, 'cl-1', 'with the cluster it belongs to');
    ok(defined $posted[0]{interval}, 'and an interval, which the API requires');
}

{
    # The newest record is the current one. PowerStore returns them oldest
    # first, so taking the first row reports the capacity of whenever the
    # window started rather than of now.
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(200, [{ id => 'cl-1' }])
            if $key eq 'GET /api/rest/cluster';
        return json_response(200, [
            { physical_total => 500, physical_used => 50 },
            { physical_total => 900, physical_used => 90 },
        ]) if $key eq 'POST /api/rest/metrics/generate';
        return json_response(200, []);
    });

    my ($total) = $api->get_managed_capacity();
    is($total, 900, 'the newest record is the one reported');
}

{
    # Neither metric source usable: fail loudly. Reporting zero would make PVE
    # believe the array is empty and let allocations proceed into a full one.
    my ($api) = make_api(handler => sub { json_response(200, []) });
    eval { $api->get_managed_capacity() };
    like($@, qr/could not determine the array's capacity/, 'unknown capacity dies');
    like($@, qr/metrics/, 'and the message says what was tried');
}

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub {
        my ($req, $key) = @_;
        return json_response(422, fixture('error_422'))
            if $key eq 'POST /api/rest/volume';
        return json_response(200, []);
    });

    eval { $api->volume_create('pve-ps1-100-disk0', 8192) };
    like($@, qr/HTTP 422/, 'the status code is kept');
    like($@, qr/name is already in use/, 'the array message is surfaced');
    like($@, qr/0xE0201001000B/, 'and its code, for support cases');
    like($@, qr/already exist|still be attached/, 'with a hint about the cause');
    like($@, qr/\[dellpowerstore:ps1\]/, 'tagged with the storage');
}

{
    my ($api) = make_api();
    like($api->error_hint(401), qr/dell-username and dell-password/,
        '401 names the options to check');
    like($api->error_hint(403), qr/Storage Operator/, '403 names the required role');
    like($api->error_hint(404), qr/PowerStore Manager/, '404 suggests where to look');
    like($api->error_hint(422), qr/thin clones/, '422 mentions dependent objects');
}

# ---------------------------------------------------------------------------
# Naming limits
# ---------------------------------------------------------------------------

my $N = 'PVE::Storage::Custom::DellEMC::PowerStore::Naming';

is($N->max_volume_name_length, 128, 'PowerStore allows longer volume names');
is($N->max_storeid_length, 32, 'and a longer storeid share');
ok($N->max_volume_name_length
    > PVE::Storage::Custom::DellEMC::Common::Naming->max_volume_name_length,
    'wider than the conservative default');

is($N->encode_volume_name('ps1', 100, 0), 'pve-ps1-100-disk0',
    'names are unchanged by the wider limits');
ok($N->is_pve_managed_volume('pve-ps1-100-disk0', 'ps1'), 'ownership gate is inherited');
ok(!$N->is_pve_managed_volume('production-lun-7', 'ps1'), 'foreign volumes still rejected');

# A long snapshot name may use the extra room, but never more than PowerStore
# accepts.
my $long = $N->encode_snapshot_name('pve-ps1-100-disk0', 'x' x 300);
ok(length($long) <= 128, 'snapshot names stay within the PowerStore limit');
ok(length($long) > 63, 'and do use the room PowerStore allows');

# ---------------------------------------------------------------------------
# JSON types: PowerStore validates them, and Perl loses them
#
# A customer's first PowerStore run failed at every attach with
#   Validation failed: [Path '/logical_unit_number'] Instance type (string)
#   does not match any allowed primitive type (allowed: ["integer"])
# The LUN id was an integer when it was computed and a STRING by the time it
# was encoded, because next_free_lun uses it as a hash key on the way out —
# which stringifies the scalar in place, and Perl's JSON encoder writes the
# string when a scalar carries one. The same is true of anything that reached
# the plugin from storage.cfg or a command line, where every value is a
# string.
#
# This drives the real client and reads the bytes it would put on the wire.
# ---------------------------------------------------------------------------

{
    my @bodies;
    my $ua = FakeArray->new(handler => sub {
        my ($req, $key) = @_;

        if ($key eq 'GET /api/rest/login_session') {
            my $h = HTTP::Headers->new('DELL-EMC-TOKEN' => 'tok');
            $h->header('Content-Type' => 'application/json');
            return HTTP::Response->new(200, undef, $h, '[]');
        }

        push @bodies, $req->content if $req->method ne 'GET';

        # The mapping listing next_free_lun reads.
        return json_response(200, [ { logical_unit_number => 1 } ])
            if $key =~ m{/host_volume_mapping};

        return json_response(200, { id => 'v1' });
    });

    my $api = $API->new(portal => '10.0.0.5', username => 'u', password => 'p',
        ua => $ua);

    # Sizes as they arrive from PVE: a string, because storage.cfg and the
    # command line have nothing else.
    eval { $api->volume_create('vol1', "8192", pool_id => 'p1') };
    eval { $api->volume_resize('v1', "10000") };
    eval { $api->volume_attach('v1', host_id => 'h1', lun_base => "1") };

    my $all = join("\n", @bodies);

    unlike($all, qr/"size"\s*:\s*"/,
        'a volume size is encoded as a number even when PVE handed it in as'
      . ' a string');
    unlike($all, qr/"logical_unit_number"\s*:\s*"/,
        'and so is the LUN id, which next_free_lun has just used as a hash'
      . ' key — the defect that stopped every attach on the first PowerStore');

    like($all, qr/"logical_unit_number"\s*:\s*\d/,
        'the LUN id is still sent');
}

done_testing();
