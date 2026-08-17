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

# ---------------------------------------------------------------------------
# HTTPS needs a protocol driver LWP does not ship with
#
# On Debian it is a package of its own. Without it every request to an array
# fails with '501 Protocol scheme https is not supported', which says nothing
# about what to install.
# ---------------------------------------------------------------------------

{
    ok(LWP::Protocol::implementor('https'),
        'this machine has the https driver, so the client can be built');

    my $api = eval {
        PVE::Storage::Custom::DellEMC::Common::REST->new(portal => '10.0.0.1', username => 'u', password => 'p',
            type => 'dellemc', storeid => 'ps1');
    };
    ok($api, 'an https client is constructed');

    # Pretend it is missing and check the message names the package.
    {
        no warnings 'redefine';
        my $real = \&LWP::Protocol::implementor;
        local *LWP::Protocol::implementor = sub {
            return undef if ($_[0] // '') eq 'https';
            return $real->(@_);
        };

        my $ok = eval {
            PVE::Storage::Custom::DellEMC::Common::REST->new(portal => '10.0.0.1', username => 'u', password => 'p',
                type => 'dellemc', storeid => 'ps1');
            1;
        };

        ok(!$ok, 'without the driver the client refuses to be built');
        like($@, qr/liblwp-protocol-https-perl/,
            '... naming the package to install');
        like($@, qr/ps1/, '... and the storage it belongs to');
    }
}

# ---------------------------------------------------------------------------
# A body with a non-ASCII character in it
#
# JSON wants bytes; HTTP::Response::decoded_content returns characters. For
# any text/* Content-Type without a charset, HTTP::Message falls back to
# ISO-8859-1, so every byte above 0x7F becomes a wide character and
# decode_json dies with "Wide character in subroutine entry".
#
# A PowerVault ME4 did exactly that on the first call of the first hardware
# run this project has ever had: `pvesm add` failed on GET /show/system,
# because the response carried one non-ASCII character. The storage could not
# be created at all.
# ---------------------------------------------------------------------------

{
    require Encode;

    # A real client: the error path uses the object's own storeid and type to
    # build its message, so a class-method call would not exercise it.
    my $api = TestAPI->new(portal => '10.0.0.1', username => 'u',
        password => 'p', storeid => 'me4', type => 'dellpowervault');

    my $json = qq({"system":[{"system-name":"ME4-\x{6a5f}\x{623f}","health":"OK"}]});
    my $bytes = Encode::encode_utf8($json);

    # Every Content-Type the three families have been seen to answer with,
    # including the text/* the ME CLI uses.
    for my $ct ('text/plain', 'text/html', 'application/json',
                'text/plain; charset=utf-8', 'application/json; charset=utf-8') {

        my $resp = HTTP::Response->new(200, undef,
            HTTP::Headers->new('Content-Type' => $ct), $bytes);

        my $out = eval { $api->_decode_success($resp, 'GET', '/show/system') };

        ok($out, "a non-ASCII body parses with Content-Type '$ct'")
            or diag("died with: $@");
        is(eval { $out->{system}[0]{health} }, 'OK',
            "... and the data survives ('$ct')");
    }
}

{
    # A body that really is not JSON must say what it was, not only that it
    # was not JSON. On a first hardware run the difference between an HTML
    # error page, an empty body and a CLI banner is the whole diagnosis.
    my $api = TestAPI->new(portal => '10.0.0.1', username => 'u',
        password => 'p', storeid => 'me4', type => 'dellpowervault');

    my $resp = HTTP::Response->new(200, undef,
        HTTP::Headers->new('Content-Type' => 'text/html'),
        '<html><head><title>401 Unauthorized</title></head>');

    eval { $api->_decode_success($resp, 'GET', '/show/system') };

    like($@, qr/not JSON/, 'a non-JSON body is reported as such');
    like($@, qr/401 Unauthorized/, '... quoting enough of it to identify it');
}

{
    # And an empty body is still an empty result, not an error: a DELETE
    # answers 204 with nothing.
    my $api = TestAPI->new(portal => '10.0.0.1', username => 'u',
        password => 'p', storeid => 'me4', type => 'dellpowervault');

    my $resp = HTTP::Response->new(204, undef, HTTP::Headers->new(), '');
    is_deeply($api->_decode_success($resp, 'DELETE', '/volume/x'),
        {}, 'an empty body is an empty result');
}

# ---------------------------------------------------------------------------
# Controller failover: several management addresses
#
# An ME has one management IP per controller and no floating address, so a
# controller failover takes the configured address away with it. The data
# path survives on dm-multipath; what this protects is management - status,
# allocation, snapshots - which would otherwise fail until somebody edited
# the storage by hand.
# ---------------------------------------------------------------------------

{
    # The request object knows which portal it was aimed at, so the fake can
    # play a dead .11 and a live .12.
    my $dead_calls = 0;
    my ($api, $ua) = make_api(
        portal  => ' 10.0.0.11 , 10.0.0.12 ',
        retries => 3,
        handler => sub {
            my ($req) = @_;
            my $host = $req->uri->host;
            if ($host eq '10.0.0.11') {
                $dead_calls++;
                # What LWP hands back when the TCP connection fails: an
                # internal 500 it generated itself, so marked.
                return json_response(500, { error => "Can't connect" },
                    'Client-Warning' => 'Internal response');
            }
            return json_response(200, { id => 'v1' });
        });

    is($api->{portal}, '10.0.0.11', 'the first address is used first, whitespace trimmed');

    my $data = $api->get('/volume/v1');
    is($data->{id}, 'v1', 'the request succeeds through the second controller');
    is($api->{portal}, '10.0.0.12', '... which is now the sticky current address');
    is($dead_calls, 1, 'the dead address was tried exactly once, with no backoff loop');

    # Later requests go straight to the live controller.
    $api->get('/volume/v1');
    is($dead_calls, 1, 'subsequent requests do not revisit the dead address');
}

{
    # The session belongs to the controller that issued it. Rotating without
    # clearing it would swap a dead-address failure for an authentication
    # loop against the live controller.
    my ($api, $ua) = make_api(
        portal  => '10.0.0.11,10.0.0.12',
        retries => 2,
        handler => sub {
            my ($req) = @_;
            return json_response(500, {},
                'Client-Warning' => 'Internal response')
                if $req->uri->host eq '10.0.0.11';
            return json_response(200, { id => 'v1' });
        });

    $api->_mark_session({ token => 'issued-by-controller-A' });
    $api->get('/volume/v1');
    my $session = $api->{_session} // {};
    isnt($session->{token} // '', 'issued-by-controller-A',
        "controller A's session did not travel to controller B");
}

{
    # Both dead: the failure must come back bounded, and having tried both.
    my %tried;
    my ($api) = make_api(
        portal  => '10.0.0.11,10.0.0.12',
        retries => 1,          # the health client's setting
        handler => sub {
            my ($req) = @_;
            $tried{ $req->uri->host }++;
            return json_response(500, {},
                'Client-Warning' => 'Internal response');
        });

    ok(!eval { $api->get('/x'); 1 }, 'both controllers dead is still a failure');
    ok($tried{'10.0.0.11'} && $tried{'10.0.0.12'},
        '... but both addresses were given their chance, even at retries=1');
}

{
    # One address configured: exactly the old behaviour, nothing rotates.
    my ($api) = make_api(retries => 1, handler => sub {
        return json_response(500, {}, 'Client-Warning' => 'Internal response');
    });
    ok(!eval { $api->get('/x'); 1 }, 'a single dead portal still fails');
    is($api->{portal}, '10.0.0.5', '... without inventing a second address');
}

# ---------------------------------------------------------------------------
# A credential never reaches the journal
#
# PowerVault's documented login puts sha256("user_password") IN THE URL, so
# a failed login wrote that hash into the node's journal verbatim - unsalted,
# uniterated SHA-256 over a string whose first half is usually the known
# username, which a dictionary attack chews through at millions of guesses a
# second. The journal is read by more people than /etc/pve/priv is, and it
# travels in every support bundle.
#
# Redaction is by SHAPE rather than by remembering every call site: a long
# hex run in a path segment after a login-ish word is a credential whatever
# produced it. Diagnostics must survive it - a WWID is also a long hex run,
# and losing it would trade one problem for another.
# ---------------------------------------------------------------------------

{
    my $R = 'PVE::Storage::Custom::DellEMC::Common::REST';

    my $hash = 'a' x 64;
    my $out = $R->_redact("GET /login/$hash failed: timeout");
    unlike($out, qr/\Q$hash\E/, 'a login hash never appears in full');
    like($out, qr/redacted/, '... it is named as redacted, not silently dropped');
    like($out, qr/^GET \/login\/a{4,8}/,
        '... with a prefix left, so two log lines can still be correlated');

    unlike($R->_redact('Authorization: Basic bWFuYWdlOnNlY3JldA=='),
        qr/bWFuYWdlOnNlY3JldA/, 'a Basic blob is redacted');
    like($R->_redact('Authorization: Basic bWFuYWdlOnNlY3JldA=='),
        qr/Basic \[redacted\]/, '... and says so');

    # What must NOT be redacted, because it is the diagnosis.
    my $wwid = '3600c0ff000446ebe2901736a01000000';
    like($R->_redact("wwid $wwid not found"), qr/\Q$wwid\E/,
        'a WWID survives - it is a long hex run too, and it is the evidence');
    like($R->_redact('GET /api/instances/lun/name:pve-u480-100-disk0 failed'),
        qr/pve-u480-100-disk0/, 'a volume name survives');
    like($R->_redact('command failed: (return code -10389)'),
        qr/-10389/, "the array's own return code survives");

    is($R->_redact(undef), undef, 'nothing stays nothing');
}

{
    # And it applies to what the client actually emits, not just to the
    # helper: every message goes out through _msg.
    my ($api) = make_api(handler => sub {
        return json_response(500, { error => 'nope' });
    }, retries => 0);

    my $msg = $api->_msg('GET /login/' . ('f' x 64) . ' failed');
    unlike($msg, qr/f{20}/, 'the message builder redacts too');
}

# ---------------------------------------------------------------------------
# A session is given back
#
# A management session on a PowerVault ME occupies one of a small number of
# slots and lives out its idle timeout, and the ME CLI has no command to clear
# one — so a session this plugin abandons is a slot nobody can recover. A
# pvedaemon worker is created for one task and exits; a `pvesm` command is a
# process per invocation. Every one of them logged in and left the session
# behind, which is what a customer saw on a real ME.
#
# _logout existed from the start and had no caller anywhere in the tree.
# ---------------------------------------------------------------------------

{
    my @logged_out;

    {
        package Test::SessionApi;
        use parent -norequire, 'PVE::Storage::Custom::DellEMC::Common::REST';

        sub _login {
            my ($self) = @_;
            $self->_mark_session({ key => 'k' . ++$main::LOGIN_COUNT });
            return 1;
        }
        sub _logout {
            my ($self) = @_;
            return unless $self->{_session};
            push @logged_out, $self->{_session}{key};
            $self->_clear_session();
            return;
        }
    }

    our $LOGIN_COUNT = 0;

    my $api = Test::SessionApi->new(portal => '10.0.0.1', username => 'u',
        password => 'p', session_ttl => 1);

    $api->ensure_session;
    is($LOGIN_COUNT, 1, 'one login');
    is_deeply(\@logged_out, [], 'and nothing given back yet');

    # The session ages out and is replaced: the old one has to go back, or the
    # array holds a slot for a session nobody will use again. This is the case
    # every _logout got wrong — each opened with `return unless
    # session_valid`, and a session past the TTL is not valid, so the one that
    # most needed releasing was the one that never was.
    sleep 2;
    $api->ensure_session;
    is($LOGIN_COUNT, 2, 'an expired session is replaced');
    is_deeply(\@logged_out, ['k1'],
        '... and the one it replaced was given back, not abandoned: this is'
      . ' the session a long-lived pvestatd sheds every TTL, and an ME has no'
      . ' command to clear one');

    # The client goes away: so does its session.
    undef $api;
    is_deeply(\@logged_out, ['k1', 'k2'],
        'a client that goes out of scope gives its session back — a worker'
      . ' that ran one task and exited used to leave one behind');
}

{
    # The logout request must not ask for a session.
    #
    # _request calls ensure_session; ensure_session releases the session it is
    # about to replace; if the release goes through _request without no_auth,
    # that is a loop. Every family's logout sends a real request, so this is
    # checked against the transport rather than against each of them.
    my @sent;

    {
        package Test::LoopApi;
        use parent -norequire, 'PVE::Storage::Custom::DellEMC::Common::REST';

        sub _login {
            my ($self) = @_;
            $self->_mark_session({ key => 'k' });
            return 1;
        }
        sub _logout {
            my ($self) = @_;
            return unless $self->_session_to_release;
            $self->_release_request('GET', '/exit', undef);
            return;
        }
        sub _request {
            my ($self, $method, $endpoint, $body, %opts) = @_;
            push @sent, { endpoint => $endpoint, no_auth => $opts{no_auth} };
            # What the real one does, and the loop this test exists for.
            $self->ensure_session unless $opts{no_auth};
            return {};
        }
    }

    my $api = Test::LoopApi->new(portal => '10.0.0.1', username => 'u',
        password => 'p', session_ttl => 1);

    $api->ensure_session;
    sleep 2;

    my $ok = eval {
        local $SIG{ALRM} = sub { die "recursion\n" };
        alarm 5;
        $api->ensure_session;
        alarm 0;
        1;
    };
    alarm 0;

    ok($ok, 'replacing an expired session does not recurse')
        or diag($@);

    my ($logout) = grep { $_->{endpoint} eq '/exit' } @sent;
    ok($logout, 'the logout was sent');
    ok($logout && $logout->{no_auth},
        '... with no_auth, which is what keeps it out of the loop');
}

# ---------------------------------------------------------------------------
# The logout carries the credential
#
# no_auth means "do not go and get a session", not "this request needs no
# credential" — it skips _auth_headers, and _auth_headers is where the session
# key lives. A logout without it asks the array to end a session it was never
# told the name of: an ME answers GET /api/exit happily, ends nothing, and the
# slot is held until its own idle timeout.
#
# That shipped in 0.8.9 and was not caught for five releases, because the fake
# array in these tests counted the request without looking at its headers. So
# this one reads the headers, and the fixture refuses a logout that does not
# carry the key — which is what the real ME does.
# ---------------------------------------------------------------------------

{
    my @live;      # session keys the array considers open
    my @refused;

    {
        package Test::StrictArray;
        sub new { bless {}, shift }
        sub timeout { 1 }
        sub default_header { }
        sub cookie_jar { }
        sub can { my ($s, $m) = @_; return $m eq 'cookie_jar' ? 0 : UNIVERSAL::can($s, $m) }

        sub request {
            my ($self, $req) = @_;

            my $path = $req->uri->path;
            my $key  = $req->header('sessionKey');
            my $body;

            if ($path =~ m{/login}) {
                my $new = 'abcdef' . sprintf('%010d', scalar(@live) + 1);
                push @live, $new;
                $body = { status => [{ response => $new,
                    'response-type-numeric' => 0, 'return-code' => 1 }] };
            } elsif ($path =~ m{/exit}) {
                if (defined $key && grep { $_ eq $key } @live) {
                    @live = grep { $_ ne $key } @live;
                    $body = { status => [{ response => 'Logged out',
                        'response-type-numeric' => 0, 'return-code' => 3 }] };
                } else {
                    push @refused, $key;
                    $body = { status => [{ response => 'Invalid session key',
                        'response-type-numeric' => 1, 'return-code' => 2 }] };
                }
            } else {
                $body = { status => [{ 'response-type-numeric' => 0,
                    'return-code' => 0 }], system => [{ 'system-name' => 'FAKE' }] };
            }

            return HTTP::Response->new(200, 'OK',
                HTTP::Headers->new('Content-Type' => 'application/json'),
                JSON::encode_json($body));
        }
    }

    require PVE::Storage::Custom::DellEMC::PowerVault::API;

    {
        my $api = PVE::Storage::Custom::DellEMC::PowerVault::API->new(
            portal => '10.0.0.1', username => 'u', password => 'p');
        $api->{_ua} = Test::StrictArray->new;

        eval { $api->system_get() };
        is(scalar(@live), 1, 'the client logged in');
    }
    # $api is out of scope: DESTROY logs out.

    is_deeply(\@refused, [],
        'the logout was accepted — it carried the session key, which is the'
      . ' only way the array knows which session to end');
    is(scalar(@live), 0,
        'and the array no longer holds the session: an ME has no command to'
      . ' clear one, so a refused logout is a slot lost until it times out');
}

done_testing();
