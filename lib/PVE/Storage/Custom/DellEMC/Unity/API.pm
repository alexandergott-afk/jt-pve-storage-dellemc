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

    # Unisphere refuses a LUN smaller than this. NOT VERIFIED on hardware,
    # and deliberately rounded UP from what any reference suggests: the cost
    # of being too big is wasted space on a tiny volume, the cost of being
    # too small is that every EFI disk (4 MiB) and TPM state (4 MiB) fails to
    # create at all - and with them the whole 'qm create' that asked.
    MIN_VOLUME_SIZE => 1024 * 1024 * 1024,

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

    # Never follow a redirect on this API.
    #
    # Unity documents 302 as UNAUTHORIZED - "authorization error or timeout
    # when the X-EMC-REST-CLIENT header field is missing or not set to true" -
    # not as "the resource moved". LWP's default is to follow up to seven,
    # which would fetch the array's web UI and hand back HTML; this client
    # would then report "the body is not JSON" and the real cause, a header
    # that did not arrive, would never be named.
    #
    # It is also the safer default on its own terms: every request here
    # carries an Authorization header, and following a redirect is how that
    # reaches a host nobody chose.
    #
    # Not done in the shared REST layer, where it would change behaviour for
    # three families this cannot be tested against - but the same question is
    # worth asking of them.
    $ua->max_redirect(0) if $ua->can('max_redirect');

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

# The codes, from the manual's own table rather than from HTTP convention.
# Two of them do not mean here what they mean elsewhere.
sub error_hint {
    my ($self, $code, $body) = @_;

    return '' unless defined $code;

    # 302 is not a redirect on this API. Dell documents it as "authorization
    # error or timeout when the X-EMC-REST-CLIENT header field is missing or
    # not set to true", which is also what a proxy stripping headers looks
    # like.
    return "\n  On Unity a 302 is an AUTHORIZATION error, not a redirect: the"
         . " 'X-EMC-REST-CLIENT: true' header did not arrive. Check for a"
         . " proxy between this node and the array."
        if $code == 302;

    # 401 is the same error with the header present, which makes it the
    # ordinary bad-credentials case.
    return "\n  The array received the REST-client header and refused the"
         . " credentials. Check dell-username and dell-password."
        if $code == 401;

    return "\n  A POST or DELETE needs the EMC-CSRF-TOKEN header, which comes"
         . " from a preceding GET."
        if $code == 403;

    return "\n  The request conflicts with the current state of the object;"
         . " it may already be in the state asked for."
        if $code == 409;

    return "\n  The array understood the request and rejected its contents."
         . " A size, a name or a reference is out of range."
        if $code == 422;

    return '';
}

# An error body is { error: { errorCode, httpStatusCode, messages: [...] } },
# and errorCode is a NUMBER - the stable thing to key a decision on, the way
# PowerVault's return-code is. The messages are localised (the manual lists
# nine locales), so they are for a human to read and never for this plugin to
# match on.
sub error_code_of {
    my ($self, $body) = @_;

    return undef unless ref($body) eq 'HASH';
    my $error = $body->{error};
    return undef unless ref($error) eq 'HASH';

    my $code = $error->{errorCode};

    return (defined $code && !ref($code) && $code =~ /^-?\d+\z/) ? $code : undef;
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
    my $expected;

    for my $page (1 .. MAX_PAGES) {
        my %query = (
            fields   => $fields,
            compact  => 'true',
            page     => $page,
            per_page => PAGE_SIZE,
            # Without this the answer carries no total at all. With it,
            # entryCount is the number of instances in the complete list.
            with_entrycount => 'true',
        );
        $query{filter} = $filter if defined $filter && length $filter;

        my $data  = $self->get("/types/$type/instances", \%query, %opts);
        my $batch = $self->_entries($data);

        push @rows, @$batch;

        my $count = ref($data) eq 'HASH' ? $data->{entryCount} : undef;
        $expected = $count
            if defined $count && !ref($count) && $count =~ /^\d+\z/;

        # An empty page always ends it, whatever anything else said.
        last unless @$batch;

        # The array said how many there are in the COMPLETE list, so stop
        # when they have all arrived. Stopping on a short page instead is a
        # guess - the array is free to return fewer rows than asked for - and
        # a silently truncated listing is how the orphan reaper comes to
        # treat live volumes as deleted.
        if (defined $expected) {
            last if scalar(@rows) >= $expected;
            next;
        }

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

    # A LUN below the array's minimum is refused outright, and PVE asks for
    # genuinely tiny volumes: an EFI disk and a TPM state are 4 MiB each. The
    # guest sees the size it asked for regardless - PVE reads the image size
    # from its own metadata, and raw data at the start of a bigger device is
    # still raw data.
    $aligned = MIN_VOLUME_SIZE if $aligned < MIN_VOLUME_SIZE;

    return $aligned;
}

# ---------------------------------------------------------------------------
# Volumes
#
# A LUN is READ as 'lun' and ACTED ON as 'storageResource'. They share an id,
# so the same string addresses both — which is exactly why getting the type
# wrong fails in a way that reads like a permissions problem rather than a
# wrong URL.
# ---------------------------------------------------------------------------

sub volume_get {
    my ($self, $id, %opts) = @_;

    return $self->_instance('lun', $id, FIELDS_LUN, %opts);
}

sub volume_get_by_name {
    my ($self, $name, %opts) = @_;

    return $self->_instance_by_name('lun', $name, FIELDS_LUN, %opts);
}

sub volume_list {
    my ($self, %opts) = @_;

    return $self->_collection('lun', FIELDS_LUN, %opts);
}

sub volume_create {
    my ($self, $name, $size, %opts) = @_;

    die $self->_msg("a volume needs a name") . "\n"
        unless defined $name && length $name;

    my $pool = delete $opts{pool};
    my $pool_id = delete $opts{pool_id};

    unless (defined $pool_id && length $pool_id) {
        my $row = defined($pool) && length($pool)
            ? $self->pool_get_by_name($pool, %opts)
            : ($self->pool_list(%opts))->[0];

        die $self->_msg(defined($pool) && length($pool)
            ? "pool '$pool' does not exist on this array"
            : "the array reported no pools. Create a pool before using this"
              . " storage.") . "\n" unless $row;

        $pool_id = $row->{id};
    }

    # An object that came back without the field that was asked for is the
    # failure mode this API makes easy: fields are opt-in, so a lookup that
    # succeeded and a lookup that returned an empty shell look the same to
    # anything that only checks the row is there. Sending the create anyway
    # would put a null where the pool goes, and the array's refusal would not
    # say which of the two happened.
    die $self->_msg("the array returned a pool with no id"
        . (defined($pool) && length($pool) ? " for '$pool'" : '')
        . ". This usually means the query did not ask for the fields it"
        . " needed.") . "\n" unless defined $pool_id && length $pool_id;

    my $aligned = $self->align_size($size);

    # 'storagePool' is the key a create takes. 'pool' is what a LUN reports
    # back afterwards; they are not interchangeable, and the array's refusal
    # for the wrong one does not say which.
    my $body = {
        name          => $name,
        description   => 'Managed by Proxmox VE (jt-pve-storage-dellemc)',
        lunParameters => {
            storagePool   => { id => $pool_id },
            size          => $aligned + 0,
            # Sent as a STRING, as Dell's own client does.
            isThinEnabled => (delete $opts{thin} // 1) ? 'true' : 'false',
        },
    };

    my $data = $self->post('/types/storageResource/action/createLun',
        $body, %opts);

    # The answer normally carries the storageResource id, which is the LUN's.
    my $content = $self->_content($data) // {};
    my $id = $self->_ref_id($content->{storageResource}) // $content->{id};
    return $id if defined $id && length $id;

    # It did not. Found by driving this client against a Unity API emulator,
    # which answers the create with 204 and no body at all - and a real array
    # under some firmware may do the same, or answer asynchronously with a
    # job. Returning undef here would be the worst of both: the volume exists
    # and the caller has no handle to it, so the next thing it does is create
    # a second one.
    #
    # The name is known, and a lookup by it answers the question directly.
    my $row = $self->volume_get_by_name($name, %opts);
    return $row->{id} if $row && defined $row->{id} && length $row->{id};

    die $self->_msg("the array accepted the create for volume '$name' but"
        . " neither returned its id nor reports it by name. The volume may"
        . " exist; check the array before retrying.") . "\n";
}

sub volume_delete {
    my ($self, $id, %opts) = @_;

    die $self->_msg("deleting a volume needs its id") . "\n"
        unless defined $id && length $id;

    return $self->delete("/instances/storageResource/$id", %opts);
}

# Unity takes the NEW TOTAL, not a delta — unlike PowerVault's
# 'expand volume size', which takes the amount to add.
sub volume_resize {
    my ($self, $id, $size, %opts) = @_;

    my $aligned = $self->align_size($size);

    $self->post("/instances/storageResource/$id/action/modifyLun",
        { lunParameters => { size => $aligned + 0 } }, %opts);

    return $aligned;
}

sub volume_rename {
    my ($self, $id, $name, %opts) = @_;

    $self->post("/instances/storageResource/$id/action/modifyLun",
        { name => $name }, %opts);

    return 1;
}

# The WWID dm-multipath will know the device by.
#
# Unity reports a LUN's wwn colon-separated and upper case,
# '60:06:01:60:...'. Linux forms the WWID as '3' + the bare hex, lower case.
# NOT VERIFIED against a device: confirm on the first run by comparing this
# against `multipath -ll`, which is how the PowerVault rule was confirmed.
sub wwn_to_wwid {
    my ($class, $wwn) = @_;

    return undef unless defined $wwn && !ref($wwn);

    (my $hex = $wwn) =~ s/[^0-9A-Fa-f]//g;
    return undef unless length($hex) == 32;

    return '3' . lc($hex);
}

sub volume_get_wwid {
    my ($self, $name, %opts) = @_;

    my $lun = $self->volume_get_by_name($name, %opts) // return undef;

    return $self->wwn_to_wwid($lun->{wwn});
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

sub snapshot_create {
    my ($self, $resource_id, $name, %opts) = @_;

    my $data = $self->post('/types/snap/instances', {
        name            => $name,
        storageResource => { id => $resource_id },
        description     => 'Managed by Proxmox VE',
        isAutoDelete    => JSON::false,
    }, %opts);

    my $content = $self->_content($data) // {};
    my $id = $content->{id};
    return $id if defined $id && length $id;

    my $row = $self->snapshot_get_by_name($name, %opts);
    return $row->{id} if $row && defined $row->{id} && length $row->{id};

    die $self->_msg("the array accepted the snapshot '$name' but neither"
        . " returned its id nor reports it by name") . "\n";
}

sub snapshot_get_by_name {
    my ($self, $name, %opts) = @_;

    return $self->_instance_by_name('snap', $name, FIELDS_SNAP, %opts);
}

sub snapshot_list {
    my ($self, %opts) = @_;

    return $self->_collection('snap', FIELDS_SNAP, %opts);
}

sub snapshot_delete {
    my ($self, $id, %opts) = @_;

    die $self->_msg("deleting a snapshot needs its id") . "\n"
        unless defined $id && length $id;

    return $self->delete("/instances/snap/$id", %opts);
}

# Restore a LUN to a snapshot.
#
# The endpoint is NOT VERIFIED: gounity does not restore a snapshot, because a
# CSI driver has no reason to, so this is the documented action form and
# nothing more. It is also the most destructive call here, which is why the
# plugin's rollback path proves nothing on this node is using the device
# before it can be reached.
#
# 'copyName' is not optional in any way that matters. Dell's own white paper:
#
#   "When restoring LUNs, the system automatically creates a backup snapshot
#    associated with the current point-in-time which allows administrators to
#    reverse this operation..."
#
# So every rollback leaves a snapshot behind whether or not one was asked
# for. Left to the array, it gets a name of the array's choosing - which this
# plugin's own snapshot purge does not recognise, and which the ownership
# gate would refuse to delete even if it did. Unity then refuses to delete a
# LUN that still has snapshots, and the volume becomes undeletable: `qm
# destroy` fails from then on, days after the rollback that caused it, with
# nothing pointing back at it.
#
# Naming it ourselves is what makes it ours to clean up.
sub volume_restore {
    my ($self, $snap_id, %opts) = @_;

    die $self->_msg("restoring needs a snapshot id") . "\n"
        unless defined $snap_id && length $snap_id;

    my $copy_name = delete $opts{copy_name};

    my $body = {};
    $body->{copyName} = $copy_name
        if defined $copy_name && length $copy_name;

    return $self->post("/instances/snap/$snap_id/action/restore", $body, %opts);
}

# A thin clone is taken FROM A SNAPSHOT, and it is the linked-clone
# primitive. So a template's marker snapshot has to outlive its clones,
# exactly as on PowerVault: deleting it while a clone reads from it is what
# the array refuses.
sub volume_clone {
    my ($self, $resource_id, $snap_id, $name, %opts) = @_;

    my $data = $self->post(
        "/instances/storageResource/$resource_id/action/createLunThinClone",
        { snap => { id => $snap_id }, name => $name }, %opts);

    my $content = $self->_content($data) // {};
    my $id = $self->_ref_id($content->{storageResource}) // $content->{id};
    return $id if defined $id && length $id;

    # Same as volume_create: an answer with no id is not a failure, but it is
    # not a handle either.
    my $row = $self->volume_get_by_name($name, %opts);
    return $row->{id} if $row && defined $row->{id} && length $row->{id};

    die $self->_msg("the array accepted the clone into '$name' but neither"
        . " returned its id nor reports it by name") . "\n";
}

# ---------------------------------------------------------------------------
# Hosts
# ---------------------------------------------------------------------------

sub host_get_by_name {
    my ($self, $name, %opts) = @_;

    return $self->_instance_by_name('host', $name, FIELDS_HOST, %opts);
}

sub host_list {
    my ($self, %opts) = @_;

    return $self->_collection('host', FIELDS_HOST, %opts);
}

sub host_create {
    my ($self, $name, %opts) = @_;

    my $data = $self->post('/types/host/instances', {
        type        => '1',          # a manually created host
        name        => $name,
        description => 'Proxmox VE node (jt-pve-storage-dellemc)',
        osType      => 'Linux',
    }, %opts);

    my $content = $self->_content($data) // {};

    return $content->{id};
}

# initiatorType is a STRING: '1' is FC, '2' is iSCSI.
sub host_add_initiator {
    my ($self, $host_id, $wwn_or_iqn, $type, %opts) = @_;

    $self->post('/types/hostInitiator/instances', {
        host              => { id => $host_id },
        initiatorType     => "$type",
        initiatorWWNorIqn => $wwn_or_iqn,
    }, %opts);

    return 1;
}

sub host_initiators {
    my ($self, %opts) = @_;

    return $self->_collection('hostInitiator', FIELDS_INIT, %opts);
}

# ---------------------------------------------------------------------------
# Mapping
#
# THE DANGEROUS ONE.
#
# hostAccess REPLACES the list; it does not add to it. Sending only this
# node's host unmaps the volume from every other node in the cluster, and a
# guest on one of them is then writing to a device that has gone. Dell's own
# client shipping both ExportVolume (one host) and ModifyVolumeExport (a
# list) is the tell.
#
# So both directions here read the current list first and send the union or
# the difference. The read has to happen inside whatever retry loop wraps the
# write, because PVE runs these in parallel: a list read before another node's
# write and sent after it puts back exactly the state that write removed.
# ---------------------------------------------------------------------------

sub _host_access_ids {
    my ($self, $lun) = @_;

    my $access = $lun->{hostAccess};
    return [] unless ref($access) eq 'ARRAY';

    my @ids;
    for my $entry (@$access) {
        next unless ref($entry) eq 'HASH';
        my $id = $self->_ref_id($entry->{host});
        push @ids, $id if defined $id && length $id;
    }

    return \@ids;
}

sub volume_mapped_hosts {
    my ($self, $name, %opts) = @_;

    my $lun = $self->volume_get_by_name($name, %opts) // return [];

    return $self->_host_access_ids($lun);
}

sub is_mapped_to {
    my ($self, $name, $host_id, %opts) = @_;

    return 0 unless defined $host_id && length $host_id;

    return (grep { $_ eq $host_id }
        @{ $self->volume_mapped_hosts($name, %opts) }) ? 1 : 0;
}

sub _write_host_access {
    my ($self, $resource_id, $ids, %opts) = @_;

    my @entries = map { { host => { id => $_ },
                          accessMask => ACCESS_PRODUCTION } } @$ids;

    $self->post("/instances/storageResource/$resource_id/action/modifyLun",
        { lunHostAccessParameters => { hostAccess => \@entries } }, %opts);

    return 1;
}

# Add this node's host WITHOUT removing anyone else's.
sub volume_attach {
    my ($self, $name, $host_id, %opts) = @_;

    die $self->_msg("mapping a volume needs a host id") . "\n"
        unless defined $host_id && length $host_id;

    # Read now, inside the caller's retry loop, not before it.
    my $lun = $self->volume_get_by_name($name, %opts);
    die $self->_msg("volume '$name' is not on the array, so it cannot be"
        . " mapped") . "\n" unless $lun;

    my $current = $self->_host_access_ids($lun);
    return 1 if grep { $_ eq $host_id } @$current;

    $self->_write_host_access($lun->{id}, [ @$current, $host_id ], %opts);

    return 1;
}

# Remove this node's host and leave every other one in place.
sub volume_detach {
    my ($self, $name, $host_id, %opts) = @_;

    die $self->_msg("unmapping a volume needs a host id") . "\n"
        unless defined $host_id && length $host_id;

    my $lun = $self->volume_get_by_name($name, %opts);

    # Absent is not a failure to unmap: there is nothing to unmap from. This
    # is get_or_undef's distinction doing its job — an array that could not
    # be reached dies inside volume_get_by_name rather than arriving here.
    return 1 unless $lun;

    my $current = $self->_host_access_ids($lun);
    my @remaining = grep { $_ ne $host_id } @$current;

    return 1 if scalar(@remaining) == scalar(@$current);

    $self->_write_host_access($lun->{id}, \@remaining, %opts);

    return 1;
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
