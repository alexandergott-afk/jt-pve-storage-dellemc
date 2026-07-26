#!/usr/bin/perl
# Adverse conditions, against a real socket.
#
# The fake user agent in t/07 checks request shape. It cannot tell you what
# happens when the thing on the other end is not a working array: a management
# interface that accepts the connection and then says nothing, one that closes
# mid-body, one that answers 200 with HTML because a proxy intercepted the
# request. Those are the states a storage array is actually found in, and the
# only outcome that matters for each is the same: fail, quickly, with
# something the operator can act on. Never hang.
#
# So this starts a real HTTP server that behaves badly on purpose.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(time);

use PVE::Storage::Custom::DellEMC::PowerStore::API;
use PVE::Storage::Custom::DellEMC::PowerVault::API;

my $PS = 'PVE::Storage::Custom::DellEMC::PowerStore::API';
my $PV = 'PVE::Storage::Custom::DellEMC::PowerVault::API';

# ---------------------------------------------------------------------------
# A server that misbehaves in a chosen way
# ---------------------------------------------------------------------------

# Returns ($port, $pid). The child serves one connection per accept and then
# does whatever $mode says.
sub start_server {
    my ($mode) = @_;

    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 16,
        ReuseAddr => 1,
    ) or return (undef, undef);

    my $port = $listener->sockport;

    my $pid = fork();
    return (undef, undef) unless defined $pid;

    if ($pid == 0) {
        # Child: never return to the test file.
        $SIG{ALRM} = sub { POSIX::_exit(0) };
        alarm(60);

        while (my $client = $listener->accept()) {
            $client->autoflush(1);

            # Read the request line and headers so the client is not blocked
            # writing while we decide what to do.
            while (my $line = <$client>) {
                last if $line =~ /^\r?\n$/;
            }

            if ($mode eq 'silent') {
                # Accept and say nothing at all, keeping the socket open.
                sleep 60;
            } elsif ($mode eq 'truncated') {
                print $client "HTTP/1.0 200 OK\r\n"
                    . "Content-Type: application/json\r\n"
                    . "Content-Length: 400\r\n\r\n"
                    . '[{"id":"v1","name":"pve-';
                # ...and stop, mid-object.
            } elsif ($mode eq 'html') {
                my $body = "<html><body>Authentication portal</body></html>";
                print $client "HTTP/1.0 200 OK\r\n"
                    . "Content-Type: text/html\r\n"
                    . "Content-Length: " . length($body) . "\r\n\r\n$body";
            } elsif ($mode eq 'empty') {
                # Close immediately without writing a byte.
            } elsif ($mode eq 'server_error') {
                my $body = '{"messages":[{"code":"0xE0","severity":"Error",'
                    . '"message_l10n":"internal error"}]}';
                print $client "HTTP/1.0 500 Internal Server Error\r\n"
                    . "Content-Type: application/json\r\n"
                    . "Content-Length: " . length($body) . "\r\n\r\n$body";
            } elsif ($mode eq 'unauthorized') {
                my $body = '{"messages":[{"message_l10n":"invalid credentials"}]}';
                print $client "HTTP/1.0 401 Unauthorized\r\n"
                    . "Content-Type: application/json\r\n"
                    . "Content-Length: " . length($body) . "\r\n\r\n$body";
            } elsif ($mode eq 'giant_header') {
                # A login that answers 200 but without the token header.
                print $client "HTTP/1.0 200 OK\r\n"
                    . "Content-Type: application/json\r\n"
                    . "Content-Length: 2\r\n\r\n[]";
            }

            close($client);
        }

        POSIX::_exit(0);
    }

    close($listener);
    return ($port, $pid);
}

sub stop_server {
    my ($pid) = @_;
    return unless $pid;
    kill('KILL', $pid);
    waitpid($pid, 0);
    return;
}

sub powerstore_on {
    my ($port, %args) = @_;
    return $PS->new(
        portal   => '127.0.0.1',
        port     => $port,
        scheme   => 'http',
        username => 'pveadmin',
        password => 'secret',
        storeid  => 'ps1',
        type     => 'dellpowerstore',
        timeout  => $args{timeout} // 3,
        retries  => $args{retries} // 1,
        %args,
    );
}

# Run $code and return (elapsed_seconds, error_or_undef). Fails the test if it
# takes longer than $limit — a hang is the one outcome that is never
# acceptable, whatever the array is doing.
sub timed_failure {
    my ($code, $limit, $name) = @_;

    my $started = time();
    my $ok = eval { $code->(); 1 };
    my $err = $@;
    my $elapsed = time() - $started;

    ok(!$ok, "$name: fails rather than returning something made up");
    cmp_ok($elapsed, '<', $limit, "$name: gives up within ${limit}s (took "
        . sprintf('%.1f', $elapsed) . "s)");

    return ($elapsed, $err);
}

# ---------------------------------------------------------------------------
# The array accepts the connection and then says nothing
#
# This is what a management gateway looks like when it is overloaded rather
# than down, and it is the case a plain TCP check cannot detect. The health
# path exists to bound exactly this.
# ---------------------------------------------------------------------------

{
    my ($port, $pid) = start_server('silent');

    SKIP: {
        skip 'cannot start a local server', 4 unless $port;

        my $api = powerstore_on($port, timeout => 3, retries => 1);

        my ($elapsed, $err) = timed_failure(
            sub { $api->cluster_get() }, 10, 'a silent array');

        like($err // '', qr/ps1|dellpowerstore/,
            'the error names the storage it belongs to');
        unlike($err // '', qr/at \S+ line \d+/,
            'and does not carry a Perl file and line number');

        stop_server($pid);
    }
}

# ---------------------------------------------------------------------------
# The response stops mid-body
# ---------------------------------------------------------------------------

{
    my ($port, $pid) = start_server('truncated');

    SKIP: {
        skip 'cannot start a local server', 3 unless $port;

        my $api = powerstore_on($port, timeout => 3, retries => 1);
        my ($elapsed, $err) = timed_failure(
            sub { $api->volume_list('pve-ps1-') }, 15, 'a truncated response');

        # Half a JSON array must never be read as "no volumes": the orphan
        # reaper would take that as every volume having been deleted.
        ok(defined $err && length $err, 'the failure is reported, not swallowed');

        stop_server($pid);
    }
}

# ---------------------------------------------------------------------------
# Something answers 200 with HTML
#
# A captive portal, a proxy, or the wrong port. The body parses as neither
# JSON nor an error, and the client must not treat it as an empty collection.
# ---------------------------------------------------------------------------

{
    my ($port, $pid) = start_server('html');

    SKIP: {
        skip 'cannot start a local server', 3 unless $port;

        my $api = powerstore_on($port, timeout => 3, retries => 1);
        my ($elapsed, $err) = timed_failure(
            sub { $api->cluster_get() }, 15, 'an HTML response');

        like($err // '', qr/JSON|token|PowerStore/i,
            'and says what was wrong with it');

        stop_server($pid);
    }
}

# ---------------------------------------------------------------------------
# The connection is closed without a response at all
# ---------------------------------------------------------------------------

{
    my ($port, $pid) = start_server('empty');

    SKIP: {
        skip 'cannot start a local server', 2 unless $port;

        my $api = powerstore_on($port, timeout => 3, retries => 1);
        timed_failure(sub { $api->cluster_get() }, 15, 'a closed connection');

        stop_server($pid);
    }
}

# ---------------------------------------------------------------------------
# Credentials the array keeps refusing
#
# A retry cannot fix a wrong password, and hammering an array with logins is
# how an account gets locked out. One extra attempt at most.
# ---------------------------------------------------------------------------

{
    my ($port, $pid) = start_server('unauthorized');

    SKIP: {
        skip 'cannot start a local server', 3 unless $port;

        my $api = powerstore_on($port, timeout => 3, retries => 3);
        my ($elapsed, $err) = timed_failure(
            sub { $api->cluster_get() }, 20, 'refused credentials');

        like($err // '', qr/401|authentication|credential/i,
            'the message points at the credentials');

        stop_server($pid);
    }
}

# ---------------------------------------------------------------------------
# A login that succeeds but hands back no token
# ---------------------------------------------------------------------------

{
    my ($port, $pid) = start_server('giant_header');

    SKIP: {
        skip 'cannot start a local server', 3 unless $port;

        my $api = powerstore_on($port, timeout => 3, retries => 1);
        my ($elapsed, $err) = timed_failure(
            sub { $api->cluster_get() }, 15, 'a login with no token');

        like($err // '', qr/DELL-EMC-TOKEN|management address/i,
            'and says the endpoint may not be a PowerStore');

        stop_server($pid);
    }
}

# ---------------------------------------------------------------------------
# A POST that fails with 5xx must never be retried
#
# The request may have reached the array and taken effect even though the
# response did not come back. Retrying a create is how one PVE disk becomes
# two volumes on the array, one of which nothing will ever delete.
# ---------------------------------------------------------------------------

{
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
        Listen => 16, ReuseAddr => 1,
    );

    SKIP: {
        skip 'cannot start a local server', 4 unless $listener;

        my $port = $listener->sockport;
        pipe(my $count_r, my $count_w) or die "pipe: $!";

        my $pid = fork();
        die 'fork failed' unless defined $pid;

        if ($pid == 0) {
            close($count_r);
            $count_w->autoflush(1);   # or the count dies with the child
            $SIG{ALRM} = sub { POSIX::_exit(0) };
            alarm(60);

            my $posts = 0;
            while (my $client = $listener->accept()) {
                $client->autoflush(1);

                my $request_line = <$client> // '';
                while (my $line = <$client>) { last if $line =~ /^\r?\n$/ }

                if ($request_line =~ /^GET \S*login_session/) {
                    print $client "HTTP/1.0 200 OK\r\n"
                        . "DELL-EMC-TOKEN: tok\r\n"
                        . "Content-Type: application/json\r\n"
                        . "Content-Length: 2\r\n\r\n[]";
                } elsif ($request_line =~ /^POST/) {
                    $posts++;
                    print $count_w "$posts\n";
                    print $client "HTTP/1.0 500 Internal Server Error\r\n"
                        . "Content-Length: 0\r\n\r\n";
                } else {
                    print $client "HTTP/1.0 200 OK\r\n"
                        . "Content-Type: application/json\r\n"
                        . "Content-Length: 2\r\n\r\n[]";
                }

                close($client);
            }

            POSIX::_exit(0);
        }

        close($count_w);
        close($listener);

        my $api = powerstore_on($port, timeout => 3, retries => 3);

        my $ok = eval { $api->volume_create('pve-ps1-100-disk0', 1024 * 1024); 1 };
        my $create_error = $@;
        ok(!$ok, 'a create that fails with 5xx is reported as a failure');

        # Read what the server counted before stopping it. Non-blocking, so a
        # server that wrote nothing cannot wedge the test.
        my $seen = 0;
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm(3);
            my $line = <$count_r>;
            $seen = $line + 0 if defined $line;
            alarm(0);
        };
        alarm(0);

        kill('KILL', $pid);
        waitpid($pid, 0);
        close($count_r);

        is($seen, 1, 'and the POST is sent exactly once, never retried');
        like($create_error, qr/500|internal/i, 'the message carries the array status');

        # A GET is safe to retry, so the same client must still do so.
        my ($gport, $gpid) = start_server('server_error');
        SKIP: {
            skip 'cannot start a second server', 1 unless $gport;
            my $get_api = powerstore_on($gport, timeout => 2, retries => 2);
            eval { $get_api->get('/cluster') };
            ok($@, 'a GET that keeps failing still ends in an error');
            stop_server($gpid);
        }
    }
}

# ---------------------------------------------------------------------------
# PowerVault: HTTP 200 is not success
#
# This family answers 200 with an error in the status object. A client that
# reads the HTTP code would call a failed volume create a success.
# ---------------------------------------------------------------------------

{
    my $api = $PV->new(
        portal => '127.0.0.1', username => 'u', password => 'p',
        storeid => 'me5', type => 'dellpowervault',
    );

    is($api->_status_ok({ 'response-type' => 'Error', 'return-code' => -10058 }), 0,
        'an error status is a failure however the HTTP code looked');
    is($api->_status_ok({ 'response-type' => 'Success', 'return-code' => 0 }), 1,
        'and a success status is a success');
    is($api->_status_ok({ 'return-code' => 1 }), 1,
        'return code 1 is what login answers with');
    is($api->_status_ok({ 'return-code' => 2 }), 0,
        'anything else is a failure even without a response type');
    is($api->_status_ok({}), 1,
        'a reply with no status object at all is not treated as an error');
}

# ---------------------------------------------------------------------------
# A portal that is simply not there
#
# The TCP pre-check exists so that a node cabled to only half the array's
# ports does not spend 30s discovery plus 60s login on each unreachable one.
# ---------------------------------------------------------------------------

{
    require PVE::Storage::Custom::DellEMC::Common::ISCSI;

    my $probe = \&PVE::Storage::Custom::DellEMC::Common::ISCSI::probe_portal;

    # RFC 5737 documentation address: routed nowhere.
    my $started = time();
    my $reachable = $probe->('192.0.2.1', 3260, timeout => 2);
    my $elapsed = time() - $started;

    is($reachable, 0, 'an unreachable portal is reported unreachable');
    cmp_ok($elapsed, '<', 5,
        'within the probe timeout, not the iscsiadm one (took '
        . sprintf('%.1f', $elapsed) . 's)');

    is($probe->('192.0.2.1', 3260, timeout => 0), 1,
        'a timeout of 0 disables the pre-check, as documented');
}

done_testing();
