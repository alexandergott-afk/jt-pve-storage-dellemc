#!/usr/bin/perl
# REST transport tests: retry policy, session handling, error translation.
# Runs against an injected user agent, so no network and no sleeping.
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use HTTP::Response;
use HTTP::Headers;
use JSON;

use PVE::Storage::Custom::DellEMC::Common::REST;

# ---------------------------------------------------------------------------
# Test doubles
# ---------------------------------------------------------------------------

{
    package FakeUA;

    sub new {
        my ($class, %args) = @_;
        return bless { timeout => 15, handler => $args{handler}, sent => [] }, $class;
    }

    sub timeout {
        my ($self, $value) = @_;
        $self->{timeout} = $value if defined $value;
        return $self->{timeout};
    }

    sub default_header { return }

    sub request {
        my ($self, $req) = @_;
        push @{ $self->{sent} }, { req => $req, timeout => $self->{timeout} };
        return $self->{handler}->($req, scalar @{ $self->{sent} });
    }

    sub count { return scalar @{ $_[0]{sent} } }
    sub last_req { return $_[0]{sent}[-1]{req} }
}

{
    package TestAPI;
    use base 'PVE::Storage::Custom::DellEMC::Common::REST';

    sub base_path { '/api/rest' }

    sub _login {
        my ($self) = @_;
        $self->{login_calls}++;
        die "login refused\n" if $self->{login_fails};
        $self->_mark_session({ token => 'tok' . $self->{login_calls} });
        return 1;
    }

    sub _auth_headers {
        my ($self) = @_;
        return ('DELL-EMC-TOKEN' => $self->{_session}{token});
    }

    # Never actually sleep in tests; record what the backoff wanted.
    sub _sleep {
        my ($self, $seconds) = @_;
        push @{ $self->{slept} ||= [] }, $seconds;
        return;
    }
}

sub json_response {
    my ($code, $data, %headers) = @_;
    my $h = HTTP::Headers->new(%headers);
    $h->header('Content-Type' => 'application/json');
    return HTTP::Response->new($code, undef, $h, encode_json($data));
}

sub make_api {
    my (%args) = @_;
    my $handler = delete $args{handler};
    my $ua = FakeUA->new(handler => $handler);
    my $api = TestAPI->new(
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
# Construction
# ---------------------------------------------------------------------------

eval { TestAPI->new(username => 'u', password => 'p') };
like($@, qr/portal is required/, 'portal is mandatory');
eval { TestAPI->new(portal => 'p', password => 'p') };
like($@, qr/username is required/, 'username is mandatory');
eval { TestAPI->new(portal => 'p', username => 'u') };
like($@, qr/password is required/, 'password is mandatory');

{
    my ($api, $ua) = make_api(handler => sub { json_response(200, {}) });
    is($api->log_prefix, '[dellpowerstore:ps1]', 'message prefix identifies the storage');
    $api->set_timeout(5);
    is($ua->timeout, 5, 'set_timeout reaches the user agent');
    is($api->{timeout}, 5, 'set_timeout is recorded');
}

# retries can be turned off entirely for the health path
{
    my ($api) = make_api(retries => 0);
    is($api->{retries}, 1, 'retries floors at a single attempt');
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub { json_response(200, { id => 'v1' }) });

    my $out = $api->get('/volume/v1');
    is_deeply($out, { id => 'v1' }, 'GET decodes the JSON body');
    is($ua->count, 1, 'one request');
    is($ua->last_req->uri->as_string, 'https://10.0.0.5:443/api/rest/volume/v1',
        'URL built from portal, port and base path');
    is($ua->last_req->header('DELL-EMC-TOKEN'), 'tok1', 'auth header applied');
    is($api->{login_calls}, 1, 'logged in once');

    $api->get('/volume/v2');
    is($api->{login_calls}, 1, 'session reused for the next call');
    is($ua->count, 2, 'second request sent');
}

# Endpoints may be given with or without a leading slash.
{
    my ($api, $ua) = make_api(handler => sub { json_response(200, {}) });
    $api->get('volume');
    is($ua->last_req->uri->path, '/api/rest/volume', 'leading slash optional');
}

# Query parameters
{
    my ($api, $ua) = make_api(handler => sub { json_response(200, []) });
    $api->get('/volume', { name => 'eq.pve-ps1-100-disk0' });
    like($ua->last_req->uri->as_string, qr/\?name=eq\.pve-ps1-100-disk0$/,
        'query parameters are encoded onto the URL');
}

# Bodies
{
    my ($api, $ua) = make_api(handler => sub { json_response(201, { id => 'new' }) });
    $api->post('/volume', { name => 'pve-ps1-100-disk0', size => 1024 });
    my $req = $ua->last_req;
    is($req->method, 'POST', 'method');
    is($req->header('Content-Type'), 'application/json', 'JSON content type on POST');
    is_deeply(decode_json($req->content), { name => 'pve-ps1-100-disk0', size => 1024 },
        'body encoded as JSON');
}

# Empty body (204 No Content on DELETE) is not an error.
{
    my ($api) = make_api(handler => sub { HTTP::Response->new(204) });
    is_deeply($api->delete('/volume/v1'), {}, 'empty body decodes to an empty hash');
}

# A success with a body that is not JSON must say so plainly.
{
    my ($api) = make_api(handler => sub {
        HTTP::Response->new(200, undef, undef, '<html>proxy error</html>');
    });
    eval { $api->get('/volume') };
    like($@, qr/not JSON/, 'non-JSON success body is reported');
    like($@, qr/\[dellpowerstore:ps1\]/, 'message carries the storage prefix');
}

# ---------------------------------------------------------------------------
# Session expiry
# ---------------------------------------------------------------------------

{
    # First call 401 (session died on the array), second succeeds.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $n) = @_;
        return json_response(401, { messages => [{ code => 'A1', message_l10n => 'Unauthorized' }] })
            if $n == 1;
        return json_response(200, { id => 'v1' });
    });

    my $out;
    {
        local $SIG{__WARN__} = sub { };   # the re-auth notice is expected
        $out = $api->get('/volume/v1');
    }
    is_deeply($out, { id => 'v1' }, '401 recovers on the retry');
    is($api->{login_calls}, 2, 're-authenticated after 401');
    is($ua->last_req->header('DELL-EMC-TOKEN'), 'tok2', 'retry carries the new token');
}

{
    # 401 on every attempt must surface as an authentication error.
    my ($api) = make_api(handler => sub { json_response(401, { message => 'bad creds' }) });
    eval {
        local $SIG{__WARN__} = sub { };
        $api->get('/volume');
    };
    like($@, qr/HTTP 401/, 'persistent 401 dies');
    like($@, qr/authentication failed/, 'with an actionable hint');
    like($@, qr/not be locked out|locked out/, 'mentioning account lockout');
}

{
    # A session belonging to another process must not be reused.
    my ($api) = make_api(handler => sub { json_response(200, {}) });
    $api->get('/volume');
    is($api->session_valid, 1, 'session valid in this process');
    $api->{_session_pid} = $$ + 1;
    is($api->session_valid, 0, 'session from another process is not reused');
    $api->get('/volume');
    is($api->{login_calls}, 2, 'inherited session triggers a fresh login');
}

{
    # Expired by TTL.
    my ($api) = make_api(handler => sub { json_response(200, {}) }, session_ttl => 60);
    $api->get('/volume');
    $api->{_session_time} = time() - 61;
    is($api->session_valid, 0, 'session past its TTL is not reused');
}

{
    # Credentials that do not work must fail fast, not burn every retry.
    my ($api, $ua) = make_api(handler => sub { json_response(200, {}) });
    $api->{login_fails} = 1;
    eval { $api->get('/volume') };
    like($@, qr/login refused|failed/, 'login failure propagates');
    is($ua->count, 0, 'no request sent without a session');
}

# ---------------------------------------------------------------------------
# Retry policy
# ---------------------------------------------------------------------------

{
    # 4xx that is not 401/429 is final.
    my ($api, $ua) = make_api(handler => sub { json_response(404, { message => 'not found' }) });
    eval { $api->get('/volume/gone') };
    like($@, qr/HTTP 404/, '404 dies');
    like($@, qr/object not found/, 'with a hint');
    is($ua->count, 1, '404 is not retried');
}

{
    my ($api, $ua) = make_api(handler => sub { json_response(400, { message => 'bad size' }) });
    eval { $api->post('/volume', { size => -1 }) };
    is($ua->count, 1, '400 is not retried');
    like($@, qr/bad size/, 'array message is preserved');
}

{
    # A POST may have taken effect even when the response failed; retrying it
    # would create a second volume.
    my ($api, $ua) = make_api(handler => sub { json_response(500, { message => 'boom' }) });
    eval { $api->post('/volume', { name => 'x' }) };
    is($ua->count, 1, 'POST is never retried on 5xx');
}

{
    # A GET is safe to repeat.
    my ($api, $ua) = make_api(handler => sub { json_response(500, { message => 'boom' }) });
    eval { $api->get('/volume') };
    is($ua->count, 2, 'GET retried up to the attempt budget');
    is_deeply($api->{slept}, [2], 'backed off once between attempts');
}

{
    # The health path takes a single attempt so a slow array cannot stall the
    # whole pvestatd cycle.
    my ($api, $ua) = make_api(
        handler => sub { json_response(500, { message => 'boom' }) },
        retries => 1,
        timeout => 5,
    );
    eval { $api->get('/cluster') };
    is($ua->count, 1, 'health client does not retry');
    ok(!$api->{slept}, 'health client never sleeps');
}

{
    # 429 is retried and honours Retry-After.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $n) = @_;
        return json_response(429, { message => 'slow down' }, 'Retry-After' => 5) if $n == 1;
        return json_response(200, { ok => 1 });
    });
    my $out = $api->get('/volume');
    is_deeply($out, { ok => 1 }, '429 recovers on the retry');
    is_deeply($api->{slept}, [5], 'Retry-After respected');
}

{
    # An absurd Retry-After must not park a PVE worker for minutes.
    my ($api) = make_api(handler => sub { json_response(503, {}, 'Retry-After' => 9999) });
    eval { $api->get('/volume') };
    is_deeply($api->{slept}, [30], 'Retry-After capped at 30s');
}

{
    # A non-numeric Retry-After falls back to the normal backoff.
    my ($api) = make_api(handler => sub {
        json_response(503, {}, 'Retry-After' => 'Wed, 21 Oct 2026 07:28:00 GMT');
    });
    eval { $api->get('/volume') };
    is_deeply($api->{slept}, [2], 'HTTP-date Retry-After ignored');
}

# ---------------------------------------------------------------------------
# Per-call timeout override
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub { json_response(200, {}) });
    is($ua->timeout, 15, 'default timeout');
    $api->get('/volume', undef, timeout => 60);
    is($ua->{sent}[0]{timeout}, 60, 'override applied to the request');
    is($ua->timeout, 15, 'timeout restored after success');
}

{
    my ($api, $ua) = make_api(handler => sub { json_response(404, {}) });
    eval { $api->get('/volume', undef, timeout => 60) };
    is($ua->timeout, 15, 'timeout restored after failure too');
}

# ---------------------------------------------------------------------------
# Error translation
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub { json_response(200, {}) });

    is($api->translate_error(422, '', { messages => [
        { code => '0xE0201001', severity => 'Error', message_l10n => 'Volume name in use' },
    ]}), 'HTTP 422: Volume name in use (0xE0201001)', 'PowerStore message array');

    is($api->translate_error(400, '', { message => 'plain message' }),
        'HTTP 400: plain message', 'single message field');

    is($api->translate_error(400, '', [{ msg => 'from a list' }]),
        'HTTP 400: from a list', 'list-shaped error body');

    is($api->translate_error(502, "<html>\n  <body>gateway</body>\n</html>", undef),
        'HTTP 502: <html> <body>gateway</body> </html>',
        'unparseable body is trimmed rather than dropped');

    is($api->translate_error(500, '', undef), 'HTTP 500', 'no detail available');

    my $long = 'x' x 500;
    my $out = $api->translate_error(500, $long, undef);
    ok(length($out) < 250, 'oversized bodies are truncated');
}

# ---------------------------------------------------------------------------
# Abstract methods
# ---------------------------------------------------------------------------

{
    my $base = PVE::Storage::Custom::DellEMC::Common::REST->new(
        portal => 'x', username => 'u', password => 'p', ua => FakeUA->new(handler => sub { }),
    );
    eval { $base->_login };
    like($@, qr/_login must be implemented/, 'login is abstract');
    eval { $base->_auth_headers };
    like($@, qr/_auth_headers must be implemented/, 'auth headers are abstract');
    is($base->base_path, '', 'base path defaults to empty');
    is($base->_logout, undef, 'logout defaults to a no-op');
}

done_testing();
