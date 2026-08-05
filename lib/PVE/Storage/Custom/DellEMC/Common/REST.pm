# Dell EMC storage plugins for Proxmox VE - REST client base
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::Common::REST;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON;
use URI;

# Transport shared by every Dell EMC family client. A family module
# subclasses this and supplies its own authentication:
#
#     package ...::DellEMC::PowerStore::API;
#     use base 'PVE::Storage::Custom::DellEMC::Common::REST';
#     sub _login        { ... }
#     sub _auth_headers { ... }
#
# Two client flavours are expected to exist per storage, and the difference
# matters more than it looks:
#
#   resilient  data path (alloc/free/clone) and the background reaper.
#              Default timeout, retries enabled.
#   health     activate_storage() and the foreground of status().
#              Short timeout, retries => 1, i.e. a single attempt.
#
# pvestatd polls storages sequentially on a ~10s cycle. A retrying client on
# the health path turns one slow array into a stalled cycle for every other
# storage on the node, which shows up as sibling storages flipping to
# 'inactive'. Losing the retry there costs nothing: the next poll is the
# retry.

use constant {
    DEFAULT_TIMEOUT     => 15,
    DEFAULT_RETRIES     => 2,
    DEFAULT_RETRY_DELAY => 2,
    DEFAULT_PORT        => 443,
    # Re-login before a cached session is likely to have expired server-side.
    DEFAULT_SESSION_TTL => 480,
    # Cap on the Retry-After a server can impose on us. Without it a
    # misbehaving array could park a pvedaemon worker for minutes.
    MAX_RETRY_AFTER     => 30,
};

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

# new(%args)
#
#   portal       required, management IP or FQDN
#   username     required
#   password     required
#   port         default 443
#   ssl_verify   default 0
#   timeout      seconds, default 15
#   retries      total attempts, default 2 (1 disables retrying)
#   retry_delay  base seconds between attempts, default 2
#   session_ttl  seconds a cached session is reused, default 480
#   storeid      used in message prefixes
#   type         storage type used in message prefixes, e.g. dellpowerstore
#   logger       coderef called with warning text; defaults to warn
#   ua           inject a prepared LWP::UserAgent (tests)
sub new {
    my ($class, %args) = @_;

    die "portal is required\n"   unless $args{portal};
    die "username is required\n" unless $args{username};
    die "password is required\n" unless defined $args{password};

    # 'portal' may name several management addresses, comma-separated. An ME
    # has one management IP per controller and no floating address, so when a
    # controller fails over, the address the storage was configured with goes
    # away WITH it. The data path survives on its own - dm-multipath and ALUA
    # are for exactly that - but every management operation would fail until
    # someone edited the storage. Listing both controllers is the fix.
    my @portals = grep { length }
        map { s/^\s+|\s+\z//gr } split /,/, $args{portal};
    die "portal is required\n" unless @portals;

    my $self = bless {
        portal      => $portals[0],
        _portals    => \@portals,
        _portal_idx => 0,
        username    => $args{username},
        password    => $args{password},
        port        => $args{port}        // DEFAULT_PORT,
        ssl_verify  => $args{ssl_verify}  // 0,
        timeout     => $args{timeout}     // DEFAULT_TIMEOUT,
        retries     => $args{retries}     // DEFAULT_RETRIES,
        retry_delay => $args{retry_delay} // DEFAULT_RETRY_DELAY,
        session_ttl => $args{session_ttl} // DEFAULT_SESSION_TTL,
        storeid     => $args{storeid},
        type        => $args{type} // 'dellemc',
        logger      => $args{logger},
        scheme      => $args{scheme} // 'https',

        _ua           => $args{ua},
        _session      => undef,   # family-defined session data
        _session_time => 0,
        _session_pid  => 0,
    }, $class;

    $self->{retries} = 1 if $self->{retries} < 1;
    $self->_init_ua() unless $self->{_ua};

    return $self;
}

sub _init_ua {
    my ($self) = @_;

    # LWP speaks HTTPS only when the protocol driver is installed, and on
    # Debian that is a package of its own. Without it every request to an
    # array fails with '501 Protocol scheme https is not supported', which
    # says nothing about what to install. It is a dependency of this package
    # and of pve-manager, so this should never fire — but a confusing failure
    # against a storage array is expensive enough to be worth one check.
    if ($self->{scheme} eq 'https' && !LWP::Protocol::implementor('https')) {
        die $self->_msg("this node cannot make HTTPS requests: LWP has no"
            . " https protocol driver. Install liblwp-protocol-https-perl.")
            . "\n";
    }

    # keep_alive reuses one TCP+TLS connection across calls. Every management
    # gateway pays a handshake per new connection, and under steady pvestatd
    # polling from every node that load is what tips a busy array into slow
    # responses. A socket that went stale during a controller failover costs
    # one failed request; LWP reconnects transparently, bounded by {timeout}.
    my $ua = LWP::UserAgent->new(
        timeout    => $self->{timeout},
        keep_alive => 1,
        agent      => 'jt-pve-storage-dellemc/1.0 ',
        ssl_opts   => {
            verify_hostname => $self->{ssl_verify} ? 1 : 0,
            SSL_verify_mode => $self->{ssl_verify} ? 1 : 0,
        },
    );
    $ua->default_header('Accept' => 'application/json');

    $self->{_ua} = $ua;
    return $ua;
}

sub ua { $_[0]->{_ua} }

# Switch an existing client between the health and data-path timeouts.
sub set_timeout {
    my ($self, $timeout) = @_;

    die "timeout is required\n" unless defined $timeout;
    $self->{timeout} = $timeout;
    $self->{_ua}->timeout($timeout) if $self->{_ua};

    return $self;
}

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

# Every operator-visible message carries '[<type>:<storeid>]' so a specific
# storage can be grepped out of a busy journal.
sub log_prefix {
    my ($self) = @_;

    # Never warn while building a warning. A client constructed without a type
    # — a subclass under test, or one built by hand — must still produce a
    # usable message rather than an uninitialised-value warning on top of
    # whatever went wrong.
    my $type = $self->{type} // 'dellemc';
    my $id   = defined $self->{storeid} ? ":$self->{storeid}" : '';

    return "[$type$id]";
}

sub _msg {
    my ($self, $text) = @_;
    return $self->log_prefix . " $text";
}

sub log_warn {
    my ($self, $text) = @_;

    my $line = $self->_msg($text);
    if (my $logger = $self->{logger}) {
        $logger->($line);
    } else {
        warn "$line\n";
    }
    return;
}

# ---------------------------------------------------------------------------
# Hooks a family client must or may override
# ---------------------------------------------------------------------------

# Authenticate and populate whatever _auth_headers() needs. Must die on
# failure. Called lazily and again after a 401.
sub _login {
    my ($self) = @_;
    die "_login must be implemented by " . ref($self) . "\n";
}

# Headers carrying the current session, as a plain list of key => value.
sub _auth_headers {
    my ($self) = @_;
    die "_auth_headers must be implemented by " . ref($self) . "\n";
}

# Optional: tear down a server-side session. Default is a no-op because most
# arrays expire sessions on their own.
sub _logout { return; }

# Base path prepended to every endpoint, e.g. '/api/rest'.
sub base_path { '' }

# Turn a decoded error body into one operator-friendly line. Families
# override to add their own error-code table; the default understands the
# shapes seen across Dell EMC APIs.
sub translate_error {
    my ($self, $code, $body, $data) = @_;

    my $detail = '';

    if (ref($data) eq 'HASH') {
        # PowerStore: { messages => [ { code, severity, message_l10n } ] }
        if (ref($data->{messages}) eq 'ARRAY' && @{$data->{messages}}) {
            my @parts;
            for my $m (@{$data->{messages}}) {
                next unless ref($m) eq 'HASH';
                my $text = $m->{message_l10n} // $m->{message} // '';
                my $mc   = $m->{code} // '';
                push @parts, length($mc) ? "$text ($mc)" : $text if length($text);
            }
            $detail = join('; ', @parts) if @parts;
        }
        $detail ||= $data->{message}       if defined $data->{message};
        $detail ||= $data->{error_message} if defined $data->{error_message};
        $detail ||= $data->{msg}           if defined $data->{msg};
    } elsif (ref($data) eq 'ARRAY' && ref($data->[0]) eq 'HASH') {
        $detail = $data->[0]{message} // $data->[0]{msg} // '';
    }

    # Fall back to the raw body, trimmed: an HTML error page from a proxy in
    # front of the array is still more useful than nothing.
    if (!length($detail) && defined $body && length($body)) {
        ($detail = $body) =~ s/\s+/ /g;
        # Perl appends "at <file> line <n>." to transport errors; the file is
        # LWP's, not ours, and it only distracts the operator.
        $detail =~ s/ at \S+ line \d+\.?//g;
        $detail =~ s/^\s+|\s+$//g;
        $detail = substr($detail, 0, 200);
    }

    return length($detail) ? "HTTP $code: $detail" : "HTTP $code";
}

# Hints appended to common status codes. Families extend by overriding.
sub error_hint {
    my ($self, $code) = @_;

    return 'authentication failed. Verify the username and password, and that'
         . ' the account is not locked out.' if $code == 401;
    return 'permission denied. The account lacks the role needed for this'
         . ' operation.' if $code == 403;
    return 'object not found. It may have been deleted on the array.'
        if $code == 404;
    return 'conflict. The object may already exist or still be in use.'
        if $code == 409;
    return 'the array is busy or rate limiting requests.' if $code == 429;
    return 'the array reported a service error; it may be in maintenance or'
         . ' overloaded.' if $code == 503;

    return undef;
}

# ---------------------------------------------------------------------------
# Session handling
# ---------------------------------------------------------------------------

sub session_valid {
    my ($self) = @_;

    return 0 unless $self->{_session};
    # A forked PVE worker inherits this object. Sessions are not safe to share
    # across processes, so treat an inherited one as absent.
    return 0 if $self->{_session_pid} != $$;
    return 0 if $self->{session_ttl}
        && (time() - $self->{_session_time}) >= $self->{session_ttl};

    return 1;
}

sub _mark_session {
    my ($self, $session) = @_;

    $self->{_session}      = $session;
    $self->{_session_time} = time();
    $self->{_session_pid}  = $$;

    return $session;
}

sub _clear_session {
    my ($self) = @_;

    $self->{_session}      = undef;
    $self->{_session_time} = 0;
    $self->{_session_pid}  = 0;

    return;
}

# Called on every response before its status code is interpreted. The default
# is to ignore it; a subclass whose array rotates a session token overrides
# this to keep the stored one current.
# Move to the next management address in the list.
#
# The SESSION GOES WITH THE CONTROLLER: an ME sessionKey or a Unity cookie
# issued by one controller means nothing to the other, so rotating without
# clearing it would replace a dead-address failure with an
# authentication-failure loop against the live one.
sub _rotate_portal {
    my ($self) = @_;

    my $portals = $self->{_portals} // [];
    return 0 unless @$portals > 1;

    my $from = $self->{portal};
    $self->{_portal_idx} = ($self->{_portal_idx} + 1) % scalar(@$portals);
    $self->{portal} = $portals->[ $self->{_portal_idx} ];
    $self->_clear_session();

    $self->log_warn("management address $from is not answering; trying"
        . " $self->{portal}");

    return 1;
}

# Did one request, just now, watch every configured address fail to connect?
# 'Just now' is deliberate: the state of a network is a fact with a shelf
# life, and a stale flag would refuse a login the array is ready to accept.
sub _portals_all_dead {
    my ($self) = @_;

    my $at = $self->{_portals_dead_at} // return 0;
    return (time() - $at) <= 10 ? 1 : 0;
}

sub _note_response { return }

sub ensure_session {
    my ($self) = @_;

    return 1 if $self->session_valid;
    $self->_login();

    return 1;
}

# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

sub _build_url {
    my ($self, $endpoint) = @_;

    my $base = $self->base_path;
    $base =~ s|/$||;
    $endpoint = "/$endpoint" unless $endpoint =~ m|^/|;

    # A portal may carry its own port - '192.168.1.11:8443' - and appending
    # the default on top of it produces an address nothing listens on. Found
    # by the adverse suite the first time a portal with a port met a real
    # socket. (An IPv6 literal would need brackets here; none of the
    # supported arrays documents one for management, so that is left until
    # an array asks for it.)
    my $authority = $self->{portal};
    $authority .= ":$self->{port}" unless $authority =~ /:\d+\z/;

    return "$self->{scheme}://${authority}${base}${endpoint}";
}

# Overridable so tests do not have to wait out the backoff.
sub _sleep {
    my ($self, $seconds) = @_;
    sleep($seconds) if $seconds > 0;
    return;
}

sub _retry_after {
    my ($self, $resp, $attempt) = @_;

    my $wait = $self->{retry_delay} * $attempt;

    if (my $hdr = $resp->header('Retry-After')) {
        # Only the delta-seconds form is worth honouring; an HTTP-date here
        # would need clock-skew handling for no practical gain.
        $wait = $hdr + 0 if $hdr =~ /^\s*\d+\s*$/;
    }

    $wait = MAX_RETRY_AFTER if $wait > MAX_RETRY_AFTER;
    return $wait;
}

# Core request path.
#
# opts:
#   timeout   per-call timeout override, restored on every exit path
#   no_auth   skip session handling (used by _login itself)
#   raw       return the HTTP::Response instead of decoded JSON
#   headers   extra headers as a hashref
#   allow_status  arrayref of status codes to hand back to the caller instead
#             of dying on. Only meaningful together with raw, because the
#             body of a rejected request is not what the caller expects to
#             decode. This exists so a caller who knows what a particular
#             refusal means can act on the code itself rather than reading
#             the message the array wrote - a message that is free to change
#             wording, and in some locales already has.
sub _request {
    my ($self, $method, $endpoint, $data, %opts) = @_;


    my $orig_timeout = $self->{_ua}->timeout();
    $self->{_ua}->timeout($opts{timeout}) if $opts{timeout};
    my $restore = sub { $self->{_ua}->timeout($orig_timeout) if $opts{timeout} };

    my $attempts = $self->{retries};

    # With several management addresses, every one of them deserves at least
    # one try before the request is declared failed - even on the health
    # client, whose retries are 1 on purpose. The worst case for status() is
    # therefore one short timeout per address, which is still bounded.
    my $portals = $self->{_portals} // [];
    $attempts = scalar(@$portals) if @$portals > $attempts;

    my $last_error;
    my $rotations = 0;

    for my $attempt (1 .. $attempts) {
        my $req;

        unless ($opts{no_auth}) {
            my $ok = eval { $self->ensure_session(); 1 };
            unless ($ok) {
                $last_error = $@ || "authentication failed\n";
                chomp $last_error;
                # Credentials that do not work will not start working on a
                # retry; only a transport failure is worth another attempt.
                last if $attempt >= $attempts || $last_error =~ /HTTP 40[13]/;

                # The login already cycled every address and found them all
                # dead; retrying the whole login against the same dead set
                # only multiplies the timeout.
                last if $self->_portals_all_dead();

                # A login that could not reach the array at all is the
                # controller-failover case; the next address gets the next
                # attempt, without the backoff - failing over fast is the
                # point of having a second address.
                if ($self->_rotate_portal()) {
                    next;
                }
                $self->_sleep($self->{retry_delay} * $attempt);
                next;
            }
        }

        # Built AFTER the login, from the CURRENT portal. The login is what
        # discovers a dead controller and rotates away from it; a URL built
        # before it would aim this request at the address the login just
        # abandoned. That was a real defect: the failover logged the
        # rotation, the login succeeded on the live controller, and the
        # request that followed still went to the dead one.
        $req = HTTP::Request->new($method => $self->_build_url($endpoint));

        unless ($opts{no_auth}) {
            my %auth = $self->_auth_headers();
            $req->header($_ => $auth{$_}) for keys %auth;
        }

        if (my $extra = $opts{headers}) {
            $req->header($_ => $extra->{$_}) for keys %$extra;
        }

        if (defined $data && $method =~ /^(?:POST|PUT|PATCH)$/) {
            $req->header('Content-Type' => 'application/json');
            $req->content(ref($data) ? encode_json($data) : $data);
        }

        my $resp = $self->{_ua}->request($req);

        # Arrays that rotate a CSRF token hand the new one back on the
        # response. Give the subclass a look at every response, success or
        # not, before anything decides what the status code means. A hook that
        # dies here would turn a working request into a failure, so it cannot.
        eval { $self->_note_response($resp, $method, $endpoint); 1 };

        if ($resp->is_success) {
            # The array answered: whatever was dead is not any more.
            delete $self->{_portals_dead_at};
            $restore->();
            return $resp if $opts{raw};
            return $self->_decode_success($resp, $method, $endpoint);
        }

        my $code = $resp->code;

        # LWP answers a connection it could not make with an internal 500 and
        # marks it 'Client-Warning: Internal response'. That is not the array
        # speaking - the array was never reached - so with another address
        # configured, this is the moment to use it, immediately and without
        # the backoff.
        if (($resp->header('Client-Warning') // '') eq 'Internal response') {
            # Once every address has answered with a connect failure inside
            # ONE request, the array is unreachable as a whole. The flag
            # stops the layers above - a login retry, a fallback login
            # method, an outer request loop - from each cycling the same
            # dead addresses again. Without it those layers multiply: a
            # 2-second status timeout became 21 seconds on a dead storage,
            # which is exactly what the bounded health path must not do.
            $rotations++;
            $self->{_portals_dead_at} = time()
                if $rotations >= scalar(@{ $self->{_portals} // [''] });

            if ($attempt < $attempts && !$self->{_portals_dead_at}
                && $self->_rotate_portal()) {
                $last_error = $self->translate_error($code,
                    $self->_response_bytes($resp) // '', undef);
                next;
            }
            if ($attempt < $attempts && $self->_rotate_portal()) {
                # Keep rotating so the NEXT logical operation starts from a
                # fresh address, but only one full cycle per request.
                $last_error = $self->translate_error($code,
                    $self->_response_bytes($resp) // '', undef);
                last if $rotations >= scalar(@{ $self->{_portals} // [''] });
                next;
            }
        }

        if ($opts{raw} && $opts{allow_status}
            && grep { $_ == $code } @{ $opts{allow_status} }) {
            $restore->();
            return $resp;
        }

        # Bytes, not characters: see _decode_success.
        my $body = $self->_response_bytes($resp) // '';
        my $parsed = eval { decode_json($body) };

        $last_error = $self->translate_error($code, $body, $parsed);
        if (my $hint = $self->error_hint($code)) {
            $last_error .= " - $hint";
        }

        # 401 means the session went away underneath us (idle expiry, array
        # restart). Drop it and try once more with a fresh login.
        if ($code == 401 && !$opts{no_auth} && $attempt < $attempts) {
            $self->log_warn("session rejected, re-authenticating (attempt $attempt/$attempts)");
            $self->_clear_session();
            $self->{_ua}->timeout($opts{timeout}) if $opts{timeout};
            next;
        }

        # 4xx other than 401/429 is a client error: retrying repeats it.
        last if $code >= 400 && $code < 500 && $code != 429;

        # A POST that reached the array may have taken effect even though the
        # response failed. Retrying could create a second volume, so do not.
        last if $method eq 'POST' && $code >= 500;

        if ($attempt < $attempts) {
            # A server-side failure may be one controller mid-failover; with
            # another address on the list, the retry goes there. Both serve
            # the same array, so flapping costs nothing but the login.
            $self->_rotate_portal();
            my $wait = $self->_retry_after($resp, $attempt);
            $self->_sleep($wait);
            next;
        }
    }

    $restore->();

    $last_error //= 'request failed';

    # A failure inside _login arrives already tagged. Two copies of the same
    # prefix in one line make the message harder to read, not easier.
    my $prefix = $self->log_prefix;
    $last_error =~ s/^\Q$prefix\E\s*//;
    chomp $last_error;

    die $self->_msg("$method $endpoint failed: $last_error") . "\n";
}

# JSON wants BYTES, and decoded_content returns CHARACTERS.
#
# HTTP::Message decodes the body according to the Content-Type charset, and
# for any text/* type with no charset it falls back to ISO-8859-1 — so every
# byte above 0x7F becomes a wide character. decode_json is then handed a
# character string and dies with "Wide character in subroutine entry", which
# is what a PowerVault ME4 did on the very first call of the first hardware
# run: /show/system carried one non-ASCII character and the storage could not
# be added at all.
#
# charset => 'none' undoes the Content-Encoding (gzip) but not the charset,
# which is exactly the pairing decode_json expects. It is correct for every
# Content-Type the three families send, including the text/* the ME CLI uses.
sub _decode_success {
    my ($self, $resp, $method, $endpoint) = @_;

    my $content = $self->_response_bytes($resp);
    # 204 No Content, and DELETE bodies in general, are legitimately empty.
    return {} unless defined $content && length($content);

    my $decoded = eval { decode_json($content) };
    if ($@) {
        my $why = $@;
        chomp $why;
        die $self->_msg("$method $endpoint returned a body that is not JSON:"
            . " $why\n  The first bytes of it were: "
            . $self->_body_excerpt($content)) . "\n";
    }

    return $decoded;
}

# The body as bytes, whatever the array said its Content-Type was.
sub _response_bytes {
    my ($self, $resp) = @_;

    return undef unless $resp;

    my $bytes = eval { $resp->decoded_content(charset => 'none') };
    # An LWP too old for the option, or a response it cannot decode at all.
    $bytes = $resp->content unless defined $bytes;

    return $bytes;
}

# A short, printable piece of a body for an error message. A first hardware
# run fails on bodies nobody here has ever seen, and "not JSON" without a
# sample says nothing about whether it was HTML, an empty string, or a CLI
# error page.
sub _body_excerpt {
    my ($self, $bytes, $limit) = @_;

    return '(empty)' unless defined $bytes && length $bytes;

    $limit //= 200;
    my $excerpt = substr($bytes, 0, $limit);
    $excerpt =~ s/[^\x20-\x7e]/./g;

    return "'" . $excerpt . "'"
         . (length($bytes) > $limit ? ' (truncated)' : '');
}

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------

sub _with_query {
    my ($self, $endpoint, $params) = @_;

    return $endpoint unless $params && %$params;

    my $uri = URI->new($endpoint);
    $uri->query_form(%$params);

    return $uri->as_string;
}

sub get {
    my ($self, $endpoint, $params, %opts) = @_;
    return $self->_request('GET', $self->_with_query($endpoint, $params), undef, %opts);
}

# GET an object that may not exist: undef for the status codes given, decoded
# JSON otherwise.
#
# The alternative is to catch the exception and read the message for '404' or
# 'not found', and that is the trap this project keeps falling into. An array
# is free to say "storage pool not found" about a request whose pool was
# wrong, and a caller matching /not found/ then reports the VOLUME as absent —
# so the next thing it does is create a second one. The status code says what
# the array meant; its prose says what a human should read.
sub get_or_undef {
    my ($self, $endpoint, $params, %opts) = @_;

    my $absent = delete $opts{absent} // [404];

    my $resp = $self->_request('GET', $self->_with_query($endpoint, $params),
        undef, %opts, raw => 1, allow_status => $absent);

    return undef if grep { $_ == $resp->code } @$absent;

    return $self->_decode_success($resp, 'GET', $endpoint);
}

sub post {
    my ($self, $endpoint, $data, %opts) = @_;
    return $self->_request('POST', $endpoint, $data, %opts);
}

sub put {
    my ($self, $endpoint, $data, %opts) = @_;
    return $self->_request('PUT', $endpoint, $data, %opts);
}

sub patch {
    my ($self, $endpoint, $data, %opts) = @_;
    return $self->_request('PATCH', $endpoint, $data, %opts);
}

sub delete {
    my ($self, $endpoint, $params, %opts) = @_;
    return $self->_request('DELETE', $self->_with_query($endpoint, $params), undef, %opts);
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Common::REST - HTTP transport shared by the
Dell EMC family API clients

=head1 SYNOPSIS

    package PVE::Storage::Custom::DellEMC::PowerStore::API;
    use base 'PVE::Storage::Custom::DellEMC::Common::REST';

    sub base_path { '/api/rest' }

    sub _login { ... }          # must die on failure
    sub _auth_headers { ... }   # returns a key => value list

=head1 DESCRIPTION

Retry policy:

=over 4

=item * 4xx other than 401 and 429 is final — a retry just repeats it.

=item * 401 clears the session and retries once with a fresh login.

=item * A POST that fails with 5xx is never retried: the request may have
taken effect on the array, and a retry would create a second object.

=item * 429 and 503 back off, honouring C<Retry-After> up to 30 seconds.

=back

Sessions are tied to the process that created them; a forked PVE worker that
inherits the object re-authenticates rather than reusing a session.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
