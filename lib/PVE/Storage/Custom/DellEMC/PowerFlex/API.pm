# Dell EMC storage plugins for Proxmox VE - PowerFlex REST client
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::PowerFlex::API;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::REST);

use JSON;
use MIME::Base64 qw(encode_base64);

# PowerFlex (formerly ScaleIO / VxFlex OS).
#
# Two authentication generations exist and this client speaks both, detected
# on first login rather than configured:
#
#   4.x   POST /rest/auth/login  {username, password}
#         -> { access_token, refresh_token }, Authorization: Bearer <token>
#         The access token is valid for FIVE MINUTES by default, which is
#         shorter than any sensible cache lifetime, so the session TTL below
#         is deliberately tighter than the other families use.
#
#   3.x   GET /api/login with HTTP Basic
#         -> a quoted token string, valid 8 hours, then sent as the PASSWORD
#         in Basic authentication on every later call.
#
# Facts taken from the Dell PowerFlex REST API documentation:
#
#   POST /api/types/Volume/instances  { volumeSizeInKb, storagePoolId, name,
#                                       volumeType }   (volumeSizeInGb is
#                                       what Dell's own SDK sends; both are
#                                       tried, see volume_create)
#   POST /api/instances/Volume::<id>/action/setVolumeSize { sizeInGB }
#   POST /api/instances/Volume::<id>/action/removeVolume  { removeMode }
#   POST /api/instances/System::<id>/action/snapshotVolumes
#                                     { snapshotDefs: [ { volumeId,
#                                                          snapshotName } ] }
#   POST /api/instances/Volume::<id>/action/addMappedSdc { sdcId }
#   Volume and snapshot names may not exceed 31 characters.
#   Volume sizes are multiples of 8 GB; a smaller request is rounded UP to
#   the 8 GB boundary by the array.
#
# Anything marked NOT VERIFIED could not be read from Dell's documentation
# during development and is listed in docs/TESTING.md.

use constant {
    # 8 GB, and the minimum volume size as well.
    SIZE_GRANULARITY => 8 * 1024 ** 3,

    # An SDT's NVMe port for host connections, and its discovery port. Dell's
    # ansible-powerflex module shows both on a real SDT; storagePort (12200)
    # is a different thing and is not what a host connects to.
    NVME_PORT           => 4420,
    NVME_DISCOVERY_PORT => 8009,

    # Names are limited to 31 characters.
    MAX_NAME_LENGTH => 31,

    # The 4.x access token expires in five minutes. Renew at four so a long
    # operation does not fail halfway through.
    SESSION_TTL_V4 => 240,

    # The 3.x token is good for eight hours; an hour is a safe reuse window.
    SESSION_TTL_V3 => 3600,
};

sub base_path { '' }   # endpoints here are absolute: /api/... or /rest/...

sub new {
    my ($class, %args) = @_;

    $args{session_ttl} //= SESSION_TTL_V4;

    my $self = $class->SUPER::new(%args);
    $self->{_generation} = $args{generation};   # 3, 4, or undef to detect

    return $self;
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

sub _login {
    my ($self) = @_;

    # 4.x first: on a 3.x system the endpoint simply does not exist, which is
    # a cheap and unambiguous answer.
    if (!defined $self->{_generation} || $self->{_generation} == 4) {
        my $session = eval { $self->_login_v4() };
        if ($session) {
            $self->{_generation} = 4;
            $self->{session_ttl} = SESSION_TTL_V4;
            return $self->_mark_session($session);
        }
        my $v4_error = $@;

        # A refused password is not a reason to try the other generation.
        die $v4_error if $v4_error && $v4_error =~ /HTTP 401|HTTP 403/;

        # The 4.x attempt just watched every management address fail to
        # connect. The 3.x login cannot succeed against addresses that do
        # not answer TCP, and trying it anyway doubles the timeout on a dead
        # array - inside the bounded status() budget. The same rule as
        # PowerVault's two login methods, which is the point: a guard added
        # for one family is not applied to another until someone applies it.
        if ($self->_portals_all_dead()) {
            chomp(my $why = $v4_error // 'no address is answering');
            die $self->_msg("authentication failed: no management address is"
                . " answering ($why)") . "\n";
        }

        $self->{_v4_error} = $v4_error;
    }

    my $session = eval { $self->_login_v3() };
    if ($session) {
        $self->{_generation} = 3;
        $self->{session_ttl} = SESSION_TTL_V3;
        return $self->_mark_session($session);
    }

    my $v3_error = $@ || "no token returned\n";
    chomp $v3_error;
    my $v4_error = $self->{_v4_error} // '';
    chomp $v4_error;

    die $self->_msg("authentication failed. The 4.x login (/rest/auth/login)"
        . ($v4_error ? " reported: $v4_error;" : " was not available;")
        . " the 3.x login (/api/login) reported: $v3_error. Verify"
        . " dell-username and dell-password, and that this address is the"
        . " PowerFlex Manager or gateway rather than an SDS node.") . "\n";
}

sub _login_v4 {
    my ($self) = @_;

    my $data = $self->_request('POST', '/rest/auth/login',
        { username => $self->{username}, password => $self->{password} },
        no_auth => 1,
        headers => { 'Content-Type' => 'application/json' },
    );

    my $token = ref($data) eq 'HASH' ? $data->{access_token} : undef;
    die "no access_token in the response\n" unless $token;

    return {
        generation    => 4,
        token         => $token,
        refresh_token => $data->{refresh_token},
    };
}

sub _login_v3 {
    my ($self) = @_;

    my $auth = encode_base64("$self->{username}:$self->{password}", '');

    my $resp = $self->_request('GET', '/api/login', undef,
        no_auth => 1,
        raw     => 1,
        headers => { Authorization => "Basic $auth" },
    );

    # Bytes, not characters: see REST::_decode_success.
    my $body = $self->_response_bytes($resp) // '';
    # The token comes back as a JSON string, quotes included.
    $body =~ s/^\s*"//;
    $body =~ s/"\s*$//;
    chomp $body;

    die "no token returned\n" unless length $body && $body !~ /\s/;

    return { generation => 3, token => $body };
}

sub _auth_headers {
    my ($self) = @_;

    my $session = $self->{_session};

    return ('Authorization' => "Bearer $session->{token}")
        if ($session->{generation} // 0) == 4;

    # 3.x: the token is used as the password, with any username.
    my $auth = encode_base64("$self->{username}:$session->{token}", '');

    return ('Authorization' => "Basic $auth");
}

sub _logout {
    my ($self) = @_;

    return unless $self->session_valid;

    my $generation = $self->{_session}{generation} // 0;
    eval {
        $generation == 4 ? $self->post('/rest/auth/logout', {})
                         : $self->get('/api/logout');
    };
    $self->_clear_session();

    return;
}

sub generation { return $_[0]->{_generation} }

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

sub translate_error {
    my ($self, $code, $body, $data) = @_;

    if (ref($data) eq 'HASH') {
        # PowerFlex answers { message, httpStatusCode, errorCode }.
        my $message = $data->{message};
        if (defined $message && length $message) {
            my $error_code = $data->{errorCode};
            return defined $error_code && $error_code
                ? "HTTP $code: $message (error code $error_code)"
                : "HTTP $code: $message";
        }
    }

    return $self->SUPER::translate_error($code, $body, $data);
}

sub error_hint {
    my ($self, $code) = @_;

    return 'authentication failed. Verify dell-username and dell-password.'
         . ' On PowerFlex 4.x these are the PowerFlex Manager credentials,'
         . ' not the MDM ones.'
        if $code == 401;

    return 'the object was not found. On PowerFlex a volume is addressed by'
         . ' id rather than by name, so this can also mean the name lookup'
         . ' returned a stale id.'
        if $code == 404;

    return $self->SUPER::error_hint($code);
}

# ---------------------------------------------------------------------------
# Sizes
# ---------------------------------------------------------------------------

# PowerFlex allocates in 8 GB units and rounds a smaller request up. Doing the
# rounding here keeps what PVE records and what the array created identical;
# otherwise every volume silently differs from its configured size.
sub align_size {
    my ($class, $bytes) = @_;

    my $granularity = SIZE_GRANULARITY;
    return $granularity if $bytes < $granularity;

    my $remainder = $bytes % $granularity;

    return $remainder ? $bytes + ($granularity - $remainder) : $bytes;
}

sub _size_in_kb {
    my ($class, $bytes) = @_;
    return int($class->align_size($bytes) / 1024);
}

sub _size_in_gb {
    my ($class, $bytes) = @_;
    return int($class->align_size($bytes) / (1024 ** 3));
}

# ---------------------------------------------------------------------------
# System, pools and capacity
# ---------------------------------------------------------------------------

sub system_list {
    my ($self, %opts) = @_;

    my $data = $self->get('/api/types/System/instances', undef, %opts);

    return ref($data) eq 'ARRAY' ? $data : [];
}

# The system id is needed for snapshots and is stable, so it is cached.
sub system_id {
    my ($self, %opts) = @_;

    return $self->{_system_id} if defined $self->{_system_id};

    my $systems = $self->system_list(%opts);
    die $self->_msg("the array reported no PowerFlex system. Check that this"
        . " address is the PowerFlex Manager or gateway.") . "\n" unless @$systems;

    # More than one system behind a single manager is possible, and picking
    # the first silently would put volumes on whichever one happened to be
    # listed first.
    $self->log_warn("this endpoint manages " . scalar(@$systems)
        . " PowerFlex systems; using '" . ($systems->[0]{name}
        // $systems->[0]{id} // '?') . "'. Point the storage at a manager that"
        . " serves one system if that is not the intended one.")
        if @$systems > 1;

    return $self->{_system_id} = $systems->[0]{id};
}

sub storage_pool_list {
    my ($self, %opts) = @_;

    my $data = $self->get('/api/types/StoragePool/instances', undef, %opts);

    return ref($data) eq 'ARRAY' ? $data : [];
}

sub storage_pool_by_name {
    my ($self, $name, $domain, %opts) = @_;

    my @matches;
    for my $pool (@{ $self->storage_pool_list(%opts) }) {
        next unless ($pool->{name} // '') eq $name;
        push @matches, $pool;
    }

    return undef unless @matches;

    # A protection domain the operator named is a requirement, not a
    # tie-breaker. Ignoring it when the pool name happens to be unique would
    # quietly point the storage at a pool in a different domain — which is
    # exactly what the operator was trying to prevent by naming one.
    if (defined $domain && length $domain) {
        for my $pool (@matches) {
            return $pool if ($pool->{protectionDomainId} // '') eq $domain
                         || ($pool->{protectionDomainName} // '') eq $domain;
        }

        die $self->_msg("storage pool '$name' exists on this system, but not"
            . " in protection domain '$domain'. Found in: "
            . join(', ', map { $_->{protectionDomainName}
                            // $_->{protectionDomainId} // '?' } @matches)) . "\n";
    }

    return $matches[0] if @matches == 1;

    # A pool name is only unique within a protection domain, so an ambiguous
    # name must be resolved rather than guessed at.
    die $self->_msg("storage pool '$name' exists in more than one protection"
        . " domain. Set pflex-protection-domain to say which one.") . "\n";
}

# ($total, $used, $available) in bytes for one pool, or the whole system.
#
# NOT VERIFIED: the statistics field names below.
sub get_managed_capacity {
    my ($self, %opts) = @_;

    my $want_pool = delete $opts{pool};
    my $domain    = delete $opts{domain};

    my @pools = @{ $self->storage_pool_list(%opts) };
    die $self->_msg("the array reported no storage pools.") . "\n" unless @pools;

    if (defined $want_pool && length $want_pool) {
        my $pool = $self->storage_pool_by_name($want_pool, $domain, %opts)
            or die $self->_msg("storage pool '$want_pool' does not exist."
                . " Available: " . join(', ', map { $_->{name} // '?' } @pools))
                . "\n";
        @pools = ($pool);
    }

    my ($total, $used) = (0, 0);

    for my $pool (@pools) {
        my $stats = eval {
            $self->get("/api/instances/StoragePool::$pool->{id}/relationships/Statistics",
                undef, %opts);
        } // {};

        # Capacity is reported in KB throughout the statistics objects.
        my $capacity = $stats->{maxCapacityInKb}
                    // $stats->{capacityAvailableForVolumeAllocationInKb};
        my $in_use = $stats->{thinCapacityInUseInKb}
                  // $stats->{capacityInUseInKb} // 0;

        next unless defined $capacity;

        $total += $capacity * 1024;
        $used  += $in_use * 1024;
    }

    die $self->_msg("could not read capacity statistics from the storage"
        . " pool(s). The field names are among those still unverified against"
        . " hardware; see docs/TESTING.md.") . "\n" unless $total > 0;

    my $available = $total - $used;
    $available = 0 if $available < 0;

    return ($total, $used, $available);
}

# ---------------------------------------------------------------------------
# Volumes
#
# PowerFlex addresses volumes by id. There is no server-side name filter for
# a prefix, so a prefix listing fetches the volume list and filters here —
# unlike the other families, where the array does it. The list is therefore
# cached briefly, because status() polls often.
# ---------------------------------------------------------------------------

sub volume_list {
    my ($self, %opts) = @_;

    my $data = $self->get('/api/types/Volume/instances', undef, %opts);

    return ref($data) eq 'ARRAY' ? $data : [];
}

sub volume_get {
    my ($self, $id, %opts) = @_;

    # The status code decides, not the message. An array is free to say
    # "not found" about something other than this volume, and reading that
    # as "the volume is gone" is how a second one gets created.
    my $data = $self->get_or_undef("/api/instances/Volume::$id", undef, %opts);

    return ref($data) eq 'HASH' ? $data : undef;
}

# Exact name lookup. PowerFlex offers queryIdByKey for this, which avoids
# pulling the whole volume list.
#
# This endpoint reports a name it does not know as an ERROR, which puts the
# whole weight of "does this volume exist?" on telling that error apart from
# a real one. The old answer was to match the message for 'not found' — and
# an array that says "storage pool not found" about a bad pool would then be
# read as "the volume is gone", so the caller creates a second one.
#
# 404 is answered as absent, on the status code alone. Anything else is not
# guessed at: the volume list settles it. That costs a listing only when the
# lookup failed, and it can be wrong in neither direction.
sub volume_id_by_name {
    my ($self, $name, %opts) = @_;

    my $resp = $self->_request('POST',
        '/api/types/Volume/instances/action/queryIdByKey',
        { name => $name }, %opts, raw => 1, allow_status => [404]);

    return undef if $resp->code == 404;

    unless ($resp->is_success) {
        return $self->_volume_id_by_name_from_list($name, %opts);
    }

    my $id = $self->_decode_success($resp, 'POST', 'queryIdByKey');

    # The reply is a bare quoted id.
    $id = $id->{id} if ref($id) eq 'HASH';
    return undef unless defined $id;
    $id =~ s/^"|"$//g if !ref($id);

    return (defined $id && length $id) ? $id : undef;
}

sub _volume_id_by_name_from_list {
    my ($self, $name, %opts) = @_;

    # If this listing fails too, the answer is unknown — not "absent".
    # free_image reads undef here as "already deleted" and reports the delete
    # as done, which makes PVE drop the disk from the VM configuration while
    # the volume is still on the array. Swallowing the error would turn an
    # unreachable array into exactly that.
    my $rows = $self->volume_list(%opts);

    for my $row (@{ ref($rows) eq 'ARRAY' ? $rows : [] }) {
        next unless ref($row) eq 'HASH';
        next unless defined $row->{name} && $row->{name} eq $name;
        return $row->{id};
    }

    return undef;
}

sub volume_get_by_name {
    my ($self, $name, %opts) = @_;

    my $id = $self->volume_id_by_name($name, %opts) or return undef;

    return $self->volume_get($id, %opts);
}

sub volume_create {
    my ($self, $name, $size, %opts) = @_;

    die $self->_msg("volume name '$name' is " . length($name) . " characters;"
        . " PowerFlex accepts at most " . MAX_NAME_LENGTH . ".") . "\n"
        if length($name) > MAX_NAME_LENGTH;

    my $pool_id = $opts{storage_pool_id}
        or die $self->_msg("a storage pool id is required to create a volume")
        . "\n";

    my $body = {
        name            => $name,
        storagePoolId   => $pool_id,
        volumeType      => $opts{thick} ? 'ThickProvisioned' : 'ThinProvisioned',
    };
    $body->{compressionMethod} = $opts{compression} if defined $opts{compression};

    # Two spellings of the size, from two Dell sources. The ScaleIO 3.x REST
    # reference documents volumeSizeInKb; Dell's own python-powerflex SDK
    # sends volumeSizeInGb. Both are plausible and creating a volume is the
    # very first thing anyone does with this plugin, so the documented form
    # goes first and the SDK's form is the fallback.
    #
    # The fallback is only taken on a 4xx, which means the array REJECTED the
    # request and created nothing. A 5xx may have taken effect, and a second
    # attempt there would be a second volume — so those are not retried, the
    # same rule the transport applies to every POST.
    my $res = $self->_create_volume_with_size($body,
        volumeSizeInKb => $self->_size_in_kb($size), %opts);

    return ref($res) eq 'HASH' ? $res->{id} : undef;
}

sub _create_volume_with_size {
    my ($self, $body, $field, $value, %opts) = @_;

    my $endpoint = '/api/types/Volume/instances';

    my $resp = $self->_request('POST', $endpoint, { %$body, $field => $value },
        %opts, raw => 1, allow_status => [400, 422]);

    if ($resp->is_success) {
        $self->{_volume_size_field} //= $field;
        return $self->_decode_success($resp, 'POST', $endpoint);
    }

    # Only the size spelling gets a second try, and only once.
    if ($field eq 'volumeSizeInKb') {
        my $gb = int($value / (1024 * 1024));
        $gb = 1 if $gb < 1;

        my $retry = $self->_request('POST', $endpoint,
            { %$body, volumeSizeInGb => $gb }, %opts);

        $self->log_warn("this array rejected 'volumeSizeInKb' on a volume"
            . " create and accepted 'volumeSizeInGb'; using that from here on")
            unless $self->{_volume_size_field};
        $self->{_volume_size_field} = 'volumeSizeInGb';

        return $retry;
    }

    # Nothing left to try: report the array's own refusal.
    my $body_text = $self->_response_bytes($resp) // '';
    die $self->_msg("POST $endpoint failed: HTTP " . $resp->code
        . ($body_text =~ /\S/ ? " - $body_text" : '')) . "\n";
}

# removeMode ONLY_ME deletes this volume alone. INCLUDING_DESCENDANTS would
# take every snapshot and clone made from it, which is never what PVE means
# by deleting one disk.
sub volume_delete {
    my ($self, $id, %opts) = @_;

    my $mode = $opts{remove_mode} // 'ONLY_ME';

    return $self->post("/api/instances/Volume::$id/action/removeVolume",
        { removeMode => $mode }, %opts);
}

sub volume_resize {
    my ($self, $id, $size, %opts) = @_;

    # This endpoint takes whole GB, and only accepts growth.
    return $self->post("/api/instances/Volume::$id/action/setVolumeSize",
        { sizeInGB => "" . $self->_size_in_gb($size) }, %opts);
}

sub volume_rename {
    my ($self, $id, $name, %opts) = @_;

    die $self->_msg("volume name '$name' is longer than the "
        . MAX_NAME_LENGTH . " characters PowerFlex accepts") . "\n"
        if length($name) > MAX_NAME_LENGTH;

    return $self->post("/api/instances/Volume::$id/action/setVolumeName",
        { newName => $name }, %opts);
}

sub volume_size {
    my ($self, $row) = @_;

    my $kb = $row->{sizeInKb} // $row->{volumeSizeInKb} // 0;

    return $kb * 1024;
}

# ---------------------------------------------------------------------------
# Snapshots
#
# A PowerFlex snapshot is a volume in its own right: mappable, writable and
# itself snapshottable. That is what makes a PVE linked clone free here.
# ---------------------------------------------------------------------------

sub snapshot_create {
    my ($self, $volume_id, $name, %opts) = @_;

    die $self->_msg("snapshot name '$name' is longer than the "
        . MAX_NAME_LENGTH . " characters PowerFlex accepts") . "\n"
        if length($name) > MAX_NAME_LENGTH;

    my $system_id = $self->system_id(%opts);

    my $res = $self->post(
        "/api/instances/System::$system_id/action/snapshotVolumes",
        { snapshotDefs => [ { volumeId => $volume_id, snapshotName => $name } ] },
        %opts);

    # The reply carries the new volume ids and the consistency group.
    my $ids = ref($res) eq 'HASH' ? $res->{volumeIdList} : undef;

    return (ref($ids) eq 'ARRAY' && @$ids) ? $ids->[0] : undef;
}

# Overwrite a volume with the contents of one of its snapshots.
#
# The action name is GENERATION-SPECIFIC, and the login has already
# determined which generation this array speaks:
#
#   - 4.x: 'restore' with { srcVolumeId } — read from Dell's own gen2
#     client (PyPowerFlex/objects/gen2/volume.py), same URL shape.
#   - 3.x: 'overwriteVolumeContent' — the ScaleIO REST reference's form,
#     which Dell's gen1 client never implemented, so it remains NOT
#     VERIFIED. It is only ever sent to an array that answered the 3.x
#     login.
#
# This is the most destructive call in the family, which is why the split
# matters: on the 4.x arrays anyone deploys today, the rollback now runs a
# form read out of Dell's own code instead of a guess.
sub snapshot_rollback {
    my ($self, $volume_id, $snapshot_id, %opts) = @_;

    # The generation is only known after a login, and the action name is
    # chosen from it BEFORE post() would trigger one - a fresh client would
    # pick the default and send a 4.x action to a 3.x array. The test that
    # drives a cold client against a 3.x fake is what caught this.
    $self->ensure_session();

    if (($self->{_generation} // 4) == 4) {
        return $self->post(
            "/api/instances/Volume::$volume_id/action/restore",
            { srcVolumeId => $snapshot_id }, %opts);
    }

    return $self->post(
        "/api/instances/Volume::$volume_id/action/overwriteVolumeContent",
        { srcVolumeId => $snapshot_id, allowOnExtManagedVol => JSON::true },
        %opts);
}

# ---------------------------------------------------------------------------
# Hosts: SDC and NVMe
# ---------------------------------------------------------------------------

sub sdc_list {
    my ($self, %opts) = @_;

    my $data = $self->get('/api/types/Sdc/instances', undef, %opts);

    return ref($data) eq 'ARRAY' ? $data : [];
}

# The SDC entry for this node, found by GUID or by IP.
sub sdc_find {
    my ($self, %opts) = @_;

    my $guid = $opts{guid};
    my $ips  = $opts{ips} // [];

    for my $sdc (@{ $self->sdc_list(%opts) }) {
        if (defined $guid && length $guid) {
            return $sdc if lc($sdc->{sdcGuid} // '') eq lc($guid);
        }
    }

    for my $sdc (@{ $self->sdc_list(%opts) }) {
        my $sdc_ip = $sdc->{sdcIp} // '';
        return $sdc if grep { $_ eq $sdc_ip } @$ips;
    }

    return undef;
}

# NVMe hosts, for the NVMe/TCP data path.
#
# NOT VERIFIED: the endpoint and field names for NVMe host objects.
sub nvme_host_list {
    my ($self, %opts) = @_;

    my $data = eval { $self->get('/api/types/Host/instances', undef, %opts) };
    return [] if $@;

    return ref($data) eq 'ARRAY' ? $data : [];
}

sub nvme_host_find {
    my ($self, $nqn, %opts) = @_;

    return undef unless defined $nqn && length $nqn;

    for my $host (@{ $self->nvme_host_list(%opts) }) {
        return $host if lc($host->{nqn} // '') eq lc($nqn);
    }

    return undef;
}

# NOT VERIFIED: creating an NVMe host object.
sub nvme_host_create {
    my ($self, $name, $nqn, %opts) = @_;

    my $res = $self->post('/api/types/Host/instances',
        { name => $name, nqn => $nqn }, %opts);

    return ref($res) eq 'HASH' ? $res->{id} : undef;
}

# The SDT endpoints an NVMe initiator connects to.
#
# NOT VERIFIED: the endpoint and field names.
sub sdt_list {
    my ($self, %opts) = @_;

    my $data = eval { $self->get('/api/types/Sdt/instances', undef, %opts) };
    return [] if $@;

    return ref($data) eq 'ARRAY' ? $data : [];
}

# [ { ip => '10.0.0.1', port => 4420, discovery_port => 8009, nqn => undef } ]
#
# An SDT carries THREE ports and they are not interchangeable. Dell's own
# ansible-powerflex module shows a real one: nvmePort 4420, storagePort 12200,
# discoveryPort 8009. storagePort is SDS-to-SDT traffic; the port a host
# connects to is nvmePort. Sending a host at storagePort means every
# 'nvme connect' fails and no namespace ever appears — on the data path this
# family uses by default.
#
# The same object has no NQN field of any kind, so the subsystem NQN is not
# something the array hands over here. It comes from discovery against
# discoveryPort, which is why that port is carried along.
#
# Each IP has a role: StorageOnly, HostOnly or StorageAndHost. A host has no
# business connecting to a StorageOnly address. A row with no role at all is
# kept — an unfamiliar firmware should not leave a node with no paths.
sub nvme_targets {
    my ($self, %opts) = @_;

    my @targets;
    for my $sdt (@{ $self->sdt_list(%opts) }) {
        my $port      = $sdt->{nvmePort}      // NVME_PORT;
        my $discovery = $sdt->{discoveryPort} // NVME_DISCOVERY_PORT;

        # 'ipList' is what an SDT instance carries; 'ips' is what its create
        # call takes, and some firmware echoes that back instead.
        my $ips = $sdt->{ipList} // $sdt->{ips} // [];

        for my $ip (ref($ips) eq 'ARRAY' ? @$ips : ()) {
            my $address = ref($ip) eq 'HASH' ? $ip->{ip} : $ip;
            next unless defined $address && length $address;

            my $role = ref($ip) eq 'HASH' ? $ip->{role} : undef;
            next if defined($role) && length($role) && $role !~ /host/i;

            push @targets, {
                ip             => $address,
                port           => $port,
                discovery_port => $discovery,
                nqn            => $sdt->{systemNqn} // $sdt->{nqn},
            };
        }
    }

    return \@targets;
}

# ---------------------------------------------------------------------------
# Mapping
# ---------------------------------------------------------------------------

# allowMultipleMappings is required for a cluster: every node maps the same
# volume, and PVE relies on that for live migration.
#
# An NVMe host and an SDC are mapped by DIFFERENT actions, not by different
# parameters to one action. Dell's gen2 client has addMappedHost
# ({hostId, nqn, allowMultipleMappings}) alongside addMappedSdc
# ({sdcId, guid, allowMultipleMappings}), and an earlier draft here sent
# hostId to addMappedSdc with a NOT VERIFIED note - on NVMe/TCP, which is
# this family's DEFAULT protocol, so the default path's map call rested on
# a guess when Dell's own code shows the action that exists for it.
sub volume_map {
    my ($self, $volume_id, $host_id, %opts) = @_;

    my $body = {};
    my $action;
    if ($opts{nvme}) {
        # A 4.x-only action gets 4.x conventions: Dell's gen2 client sends a
        # JSON boolean here. The 'TRUE' string below is the ScaleIO 3.x
        # reference's spelling, and a 4.x-only path has no reason to carry
        # 3.x baggage into a body nothing has ever tested.
        $action = 'addMappedHost';
        $body->{hostId} = $host_id;
        $body->{allowMultipleMappings} = JSON::true;
    } else {
        # The 3.x-documented string form, kept for the SDC path that both
        # generations serve: the ScaleIO reference spells booleans as 'TRUE'
        # strings, and gen1 arrays are the ones most likely to mean it.
        $action = 'addMappedSdc';
        $body->{sdcId} = $host_id;
        $body->{allowMultipleMappings} = 'TRUE';
    }

    return $self->post("/api/instances/Volume::$volume_id/action/$action",
        $body, %opts);
}

sub volume_unmap {
    my ($self, $volume_id, $host_id, %opts) = @_;

    my $body = {};
    my $action;
    if ($opts{nvme}) {
        $action = 'removeMappedHost';
        $body->{hostId} = $host_id;
    } else {
        $action = 'removeMappedSdc';
        $body->{sdcId} = $host_id;
    }

    return $self->post("/api/instances/Volume::$volume_id/action/$action",
        $body, %opts);
}

# The hosts a volume is mapped to, as ids.
#
# A mapping entry names its target as an SDC id or, for an NVMe host, a host
# id. Taking whichever is defined first would drop the other, and a row that
# carries both would then never match the id this node actually goes by: the
# volume would look unmapped on every activation, be mapped again, and be
# unmapped by an id that is not the one holding it.
sub volume_mapped_hosts {
    my ($self, $volume, %opts) = @_;

    my $row = ref($volume) eq 'HASH' ? $volume : $self->volume_get($volume, %opts);
    return [] unless $row;

    my @ids;
    my %seen;
    for my $list (qw(mappedSdcInfo mappedHostInfo)) {
        for my $mapping (@{ $row->{$list} // [] }) {
            next unless ref($mapping) eq 'HASH';
            for my $key (qw(sdcId hostId)) {
                my $id = $mapping->{$key};
                next unless defined $id && length $id;
                push @ids, $id unless $seen{$id}++;
            }
        }
    }

    return \@ids;
}

sub is_mapped {
    my ($self, $volume, $host_id, %opts) = @_;

    return 0 unless defined $host_id;

    for my $id (@{ $self->volume_mapped_hosts($volume, %opts) }) {
        return 1 if $id eq $host_id;
    }

    return 0;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::PowerFlex::API - PowerFlex REST client

=head1 DESCRIPTION

Speaks both authentication generations, detected on first login: PowerFlex
4.x issues a Bearer token from C</rest/auth/login> that expires in five
minutes, while 3.x issues an eight-hour token from C</api/login> that is then
used as the password in HTTP Basic.

Volume sizes are rounded up to PowerFlex's 8 GB allocation unit here, so that
what PVE records and what the array created are the same number.

Unlike the other families, a prefix listing cannot be pushed to the array:
PowerFlex has no server-side name filter, only an exact-name lookup
(C<queryIdByKey>), so the caller filters.

=head1 STATUS

Not verified against hardware. Endpoints marked C<NOT VERIFIED> in the source
could not be read from Dell's documentation during development; see
docs/TESTING.md.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
