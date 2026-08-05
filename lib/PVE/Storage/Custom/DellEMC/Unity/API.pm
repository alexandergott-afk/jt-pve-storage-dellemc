# Dell EMC storage plugins for Proxmox VE - Unity XT REST client
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License
#
# NOTHING IN THIS FILE HAS BEEN RUN AGAINST A UNITY ARRAY.
#
# But very little of it is guessed. Every URI, request body and field list
# below is read from `github.com/dell/gounity` — the client Dell's own CSI
# driver uses against Unity — rather than from prose about Unisphere. Where
# the two disagreed, the code won: a documentation page gives the LUN name
# limit as 85 and Dell's client refuses anything over 63 before it reaches
# the array.
#
# The handful of calls gounity does not make, because a CSI driver does not
# need them, are marked NOT VERIFIED individually. docs/TESTING.md is the
# register; keep it honest.

package PVE::Storage::Custom::DellEMC::Unity::API;

use strict;
use warnings;

use JSON;
use MIME::Base64 qw(encode_base64);
use HTTP::Cookies;

use base qw(PVE::Storage::Custom::DellEMC::Common::REST);

use constant {
    BASE_PATH => '/api',

    # Unity takes and reports LUN sizes in BYTES — not blocks, unlike
    # PowerVault. A pool's smallest allocation unit is 8 KiB, so a request is
    # rounded UP to it: a volume smaller than PVE asked for gets filled and
    # then fails. NOT VERIFIED that the array itself rounds up rather than
    # down; rounding here first makes that question harmless either way.
    SIZE_GRANULARITY => 8 * 1024,

    MAX_VOLUME_SIZE => 256 * 1024 ** 4,

    # Collections are paged from 1.
    PAGE_SIZE => 500,
    MAX_PAGES => 200,

    SESSION_TTL => 900,

    # accessMask on a hostAccess entry, and it is a STRING in the JSON, not a
    # number. '1' is production access, which is what a VM disk wants; Dell's
    # own client hardcodes the same value for the same reason.
    ACCESS_PRODUCTION => '1',
};

# Dell's own field lists, verbatim. Unity returns almost nothing without
# them, so a request that forgets one comes back looking like an empty object
# rather than an absent one — and those are different answers.
use constant {
    FIELDS_LUN  => 'id,name,description,type,wwn,sizeTotal,sizeUsed,'
                 . 'sizeAllocated,hostAccess,pool,isThinEnabled,'
                 . 'isDataReductionEnabled,isThinClone,parentSnap,health',
    FIELDS_SNAP => 'id,name,description,storageResource,lun,creationTime,'
                 . 'expirationTime,state,size,isAutoDelete,accessType,'
                 . 'parentSnap',
    FIELDS_POOL => 'id,name,description,sizeFree,sizeTotal,sizeUsed,'
                 . 'sizeSubscribed,isAllFlash,health',
    FIELDS_HOST => 'id,name,description,type,osType,fcHostInitiators,'
                 . 'iscsiHostInitiators',
    FIELDS_INIT => 'id,health,type,initiatorId,isIgnored,parentHost',
};

sub base_path { BASE_PATH }

sub new {
    my ($class, %args) = @_;

    $args{session_ttl} //= SESSION_TTL;

    return $class->SUPER::new(%args);
}

# ---------------------------------------------------------------------------
# Authentication
#
# Unity has no login endpoint that hands back a credential. Instead:
#
#   - 'X-EMC-REST-CLIENT: true' on EVERY request. Without it the array
#     answers with its web UI rather than JSON, which decodes as "not JSON"
#     and reads like the wrong host entirely.
#   - HTTP Basic authenticates and the response sets a session cookie.
#   - a GET returns an 'EMC-CSRF-TOKEN' header that every POST and DELETE has
#     to echo back.
# ---------------------------------------------------------------------------

sub _init_ua {
    my ($self) = @_;

    my $ua = $self->SUPER::_init_ua();
    $ua->cookie_jar(HTTP::Cookies->new) if $ua->can('cookie_jar');

    return $ua;
}

sub _rest_client_headers {
    return (
        'X-EMC-REST-CLIENT' => 'true',
        'Accept'            => 'application/json',
    );
}

sub _login {
    my ($self) = @_;

    my $auth = encode_base64("$self->{username}:$self->{password}", '');

    # Any authenticated GET yields the token. This one is cheap, and its
    # answer is worth having in a log when a first run does not work.
    my $resp = $self->_request('GET', '/types/system/instances', undef,
        no_auth => 1,
        raw     => 1,
        query   => { fields => 'name,model,serialNumber', compact => 'true' },
        headers => {
            _rest_client_headers(),
            Authorization => "Basic $auth",
        },
    );

    my $token = $resp->header('EMC-CSRF-TOKEN');

    # A missing token breaks writes, not reads. Refusing to come up over it
    # would take the storage offline for something that only matters at the
    # first write, so it is recorded and said once instead.
    $self->log_warn("the array returned no EMC-CSRF-TOKEN header; writes will"
        . " be refused. Check that this address is a Unity management"
        . " interface.") unless defined $token && length $token;

    return $self->_mark_session({ csrf => $token, basic => $auth });
}

sub _auth_headers {
    my ($self) = @_;

    my $session = $self->{_session} // {};
    my %headers = _rest_client_headers();

    # Basic as well as the cookie: Unity accepts it, and it means a cookie the
    # array dropped costs one 401 rather than a storage that stays inactive
    # until the session ages out.
    $headers{Authorization} = "Basic $session->{basic}"
        if defined $session->{basic};

    $headers{'EMC-CSRF-TOKEN'} = $session->{csrf}
        if defined $session->{csrf} && length $session->{csrf};

    return %headers;
}

# The newest token any response carries is the one used from then on.
sub _note_response {
    my ($self, $resp) = @_;

    return unless $self->{_session};

    my $token = $resp->header('EMC-CSRF-TOKEN');
    return unless defined $token && length $token;

    $self->{_session}{csrf} = $token;

    return;
}

sub error_hint {
    my ($self, $code, $body) = @_;

    return "\n  Unity needs 'X-EMC-REST-CLIENT: true' on every request."
        if defined $code && $code == 401;

    return "\n  A POST or DELETE needs the EMC-CSRF-TOKEN header, which comes"
         . " from a preceding GET."
        if defined $code && $code == 403;

    return '';
}

# ---------------------------------------------------------------------------
# The two response shapes
#
# A collection answers { entries: [ { content: {...} }, ... ] }; one instance
# answers { content: {...} }. Anything else is not an answer this client
# understands, and it returns nothing rather than guessing — a row of the
# wrong kind is worse than no row.
# ---------------------------------------------------------------------------

sub _entries {
    my ($self, $data) = @_;

    return [] unless ref($data) eq 'HASH';
    my $entries = $data->{entries};
    return [] unless ref($entries) eq 'ARRAY';

    my @rows;
    for my $entry (@$entries) {
        next unless ref($entry) eq 'HASH';
        my $content = $entry->{content};
        push @rows, $content if ref($content) eq 'HASH';
    }

    return \@rows;
}

sub _content {
    my ($self, $data) = @_;

    return undef unless ref($data) eq 'HASH';
    my $content = $data->{content};

    return ref($content) eq 'HASH' ? $content : undef;
}

# An id out of a nested reference: Unity writes them as { id => '...' }.
sub _ref_id {
    my ($self, $value) = @_;

    return undef unless defined $value;
    return $value unless ref($value);
    return undef unless ref($value) eq 'HASH';

    my $id = $value->{id};

    return (defined $id && !ref $id) ? $id : undef;
}

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

sub _collection {
    my ($self, $type, $fields, %opts) = @_;

    my $filter = delete $opts{filter};

    my @rows;
    for my $page (1 .. MAX_PAGES) {
        my %query = (
            fields   => $fields,
            compact  => 'true',
            page     => $page,
            per_page => PAGE_SIZE,
        );
        $query{filter} = $filter if defined $filter && length $filter;

        my $data  = $self->get("/types/$type/instances", \%query, %opts);
        my $batch = $self->_entries($data);

        push @rows, @$batch;

        # A short page ends it. Unity reports no total the way PowerStore's
        # Content-Range does, which is why the page size is asked for
        # explicitly rather than left to the array's default — a page shorter
        # than a size this client did not choose proves nothing.
        last if scalar(@$batch) < PAGE_SIZE;
    }

    return \@rows;
}

sub _instance {
    my ($self, $type, $id, $fields, %opts) = @_;

    return undef unless defined $id && length $id;

    # get_or_undef keeps "the array said 404" apart from "the array did not
    # answer". Only the first means the object is absent, and only the first
    # may be reported to a caller as a successful delete.
    my $data = $self->get_or_undef("/instances/$type/$id",
        { fields => $fields, compact => 'true' }, %opts);

    return defined $data ? $self->_content($data) : undef;
}

# By NAME, which Unity answers directly.
#
# This is the reason this family carries none of the wildcard and
# empty-listing defences the others need. Every other array here has to be
# asked with a server-side filter, and an unverified filter that returns
# nothing is indistinguishable from "there is nothing there" — that mistake
# hid every PowerStore volume once, and cost PowerVault a release. Unity has
# a first-class URI for the question, so the question is asked directly.
sub _instance_by_name {
    my ($self, $type, $name, $fields, %opts) = @_;

    return undef unless defined $name && length $name;

    my $data = $self->get_or_undef("/instances/$type/name:$name",
        { fields => $fields, compact => 'true' }, %opts);

    return defined $data ? $self->_content($data) : undef;
}

# ---------------------------------------------------------------------------
# Pools and capacity
# ---------------------------------------------------------------------------

sub pool_list {
    my ($self, %opts) = @_;

    return $self->_collection('pool', FIELDS_POOL, %opts);
}

sub pool_get_by_name {
    my ($self, $name, %opts) = @_;

    return $self->_instance_by_name('pool', $name, FIELDS_POOL, %opts);
}

# Bytes, not blocks. PowerVault reports 512-byte blocks and this does not;
# reading one as the other is off by 512 in the direction that makes a full
# pool look empty.
sub get_managed_capacity {
    my ($self, %opts) = @_;

    my $want  = delete $opts{pool};
    my $pools = $self->pool_list(%opts);

    die $self->_msg("the array reported no pools. Create a pool before using"
        . " this storage.") . "\n" unless @$pools;

    my ($total, $available, $matched) = (0, 0, 0);

    for my $pool (@$pools) {
        my $name = $pool->{name} // '';
        next if defined $want && length $want && lc($name) ne lc($want);
        $matched++;

        $total     += $self->_bytes($pool, 'sizeTotal');
        $available += $self->_bytes($pool, 'sizeFree');
    }

    if (defined $want && length $want && !$matched) {
        my @names = map { $_->{name} // '?' } @$pools;
        die $self->_msg("pool '$want' does not exist on this array. Available"
            . " pools: " . join(', ', @names)) . "\n";
    }

    return ($total, $total - $available, $available);
}

sub _bytes {
    my ($self, $row, $field) = @_;

    my $value = $row->{$field};
    return 0 unless defined $value && !ref($value) && $value =~ /^\d+\z/;

    return $value + 0;
}

sub align_size {
    my ($class, $bytes) = @_;

    my $unit = SIZE_GRANULARITY;
    my $aligned = int(($bytes + $unit - 1) / $unit) * $unit;

    return $aligned;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::Unity::API - Unity XT REST client

=head1 DESCRIPTION

Transport, authentication, collection handling, pools and capacity for Unity
XT. Volumes, snapshots, hosts and mapping build on this.

B<Nothing here has been run against a Unity array.> Every URI and field list
is read from Dell's own C<gounity> client rather than from documentation
prose. See F<docs/TESTING.md>.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
