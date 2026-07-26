# Dell EMC storage plugins for Proxmox VE - PowerStore REST client
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::PowerStore::API;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::REST);

use HTTP::Cookies;
use JSON qw(decode_json);
use MIME::Base64 qw(encode_base64);

# PowerStore Manager REST client.
#
# EVERY endpoint, field name and filter form in this module still needs to be
# checked against a real appliance with its own Swagger UI at
# https://<mgmt-ip>/swaggerui — see docs/TESTING.md. They are written from the
# PowerStore 4.x REST API documentation and the field set differs from 3.x in
# places.
#
# Filtering follows PostgREST conventions, which PowerStore adopted:
#   name=eq.<value>            exact match
#   name=ilike.<prefix>*       case-insensitive match, '*' the documented
#                              wildcard (see _prefix_filter)
#   type=eq.Snapshot           enum match
# Filters are applied server-side, always. Listing every volume and filtering
# locally turns each poll into a full inventory transfer, and this plugin
# polls every ten seconds per node.

use constant {
    BASE_PATH => '/api/rest',

    # PowerStore requires volume sizes to be a multiple of 8 KiB.
    SIZE_GRANULARITY => 8192,

    # The developers guide documents the pagination limit as 1 to 2000, 100
    # by default, and answers 206 Partial Content with a Content-Range header
    # when the collection is larger. 200 keeps a poll's response small while
    # still costing one round trip for any storage of a realistic size.
    PAGE_SIZE => 200,

    # Guard against an endless paging loop if the array keeps returning full
    # pages (a filter it ignored, a bug). 100k volumes is far past any
    # plausible PVE storage.
    MAX_PAGES => 500,

    # LUN ids the array accepts for a host mapping.
    MIN_LUN_ID => 1,
    MAX_LUN_ID => 255,

    JOB_POLL_INTERVAL => 2,
    JOB_POLL_TIMEOUT  => 300,
};

sub base_path { BASE_PATH }

# ---------------------------------------------------------------------------
# Authentication
#
# GET /login_session with HTTP Basic returns a DELL-EMC-TOKEN header and a
# session cookie. Both are required on writes; reads accept the cookie alone.
# ---------------------------------------------------------------------------

sub _init_ua {
    my ($self) = @_;

    my $ua = $self->SUPER::_init_ua();
    # The session cookie is half of the credential pair.
    $ua->cookie_jar(HTTP::Cookies->new) if $ua->can('cookie_jar');

    return $ua;
}

sub _login {
    my ($self) = @_;

    my $auth = encode_base64("$self->{username}:$self->{password}", '');

    my $resp = $self->_request('GET', '/login_session', undef,
        no_auth => 1,
        raw     => 1,
        headers => { Authorization => "Basic $auth" },
    );

    my $token = $resp->header('DELL-EMC-TOKEN');
    unless ($token) {
        die $self->_msg(
            "login succeeded but the array returned no DELL-EMC-TOKEN header."
          . " Verify that this endpoint is a PowerStore management address.")
          . "\n";
    }

    return $self->_mark_session({ token => $token });
}

sub _auth_headers {
    my ($self) = @_;

    # The cookie jar on the user agent carries the session cookie; the token
    # is what the array checks on writes.
    return ('DELL-EMC-TOKEN' => $self->{_session}{token});
}

# Dell documents the CSRF token as something to fetch with a GET before each
# write, which leaves it open whether the array reissues it as the session
# goes on. Rather than depend on the answer, take the newest one the array
# has offered: if it never rotates, this writes back the same string.
sub _note_response {
    my ($self, $resp) = @_;

    return unless $self->{_session};

    my $token = $resp->header('DELL-EMC-TOKEN');
    return unless defined $token && length $token;

    $self->{_session}{token} = $token;

    return;
}

# The session cookie is as much of the credential as the token is, so a
# cleared session must not leave the old one in the jar for the next login to
# present alongside fresh Basic credentials.
sub _clear_session {
    my ($self) = @_;

    if (my $ua = $self->{_ua}) {
        my $jar = $ua->can('cookie_jar') ? $ua->cookie_jar : undef;
        $jar->clear() if $jar && $jar->can('clear');
    }

    return $self->SUPER::_clear_session();
}

sub _logout {
    my ($self) = @_;

    return unless $self->session_valid;
    eval { $self->post('/logout', {}) };
    $self->_clear_session();

    return;
}

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

# PowerStore returns { messages => [ { code, severity, message_l10n } ] },
# which the base class already renders. What it cannot know is which codes
# mean something the operator can act on.
sub error_hint {
    my ($self, $code) = @_;

    return 'authentication failed. Verify dell-username and dell-password,'
         . ' and that the account is not locked out in PowerStore Manager.'
        if $code == 401;

    return 'permission denied. The account needs at least the Storage'
         . ' Operator role for volume operations.'
        if $code == 403;

    return 'the object was not found. It may have been deleted in PowerStore'
         . ' Manager, or the appliance may have been failed over.'
        if $code == 404;

    return 'the request conflicts with the array state: the object may'
         . ' already exist, still be attached, or still have snapshots or'
         . ' thin clones depending on it.'
        if $code == 422;

    return $self->SUPER::error_hint($code);
}

# ---------------------------------------------------------------------------
# Collections
# ---------------------------------------------------------------------------

# GET a collection, following pages. $params are filter/select parameters.
#
# The page size the array uses is NOT necessarily the one we asked for: a
# server-side cap, or a large row, can make it answer with fewer. Stopping on
# a short page would then silently truncate the result — which does not fail
# anywhere visible, it just hides volumes from the disk list AND leaves the
# orphan reaper with an incomplete alive set, so live volumes past the cut are
# treated as deleted. The array says what it did in the Content-Range header
# that comes with 206 Partial Content ('items 0-99/1234'), so the total is
# what decides, and the short-page heuristic is only the fallback for a
# response that carries no such header.
sub _collection {
    my ($self, $endpoint, $params, %opts) = @_;

    my @rows;
    my $offset = 0;
    my $total;

    for my $page (1 .. MAX_PAGES) {
        my %query = (%{ $params // {} }, limit => PAGE_SIZE, offset => $offset);

        my $resp = $self->get($endpoint, \%query, %opts,
            raw => 1, allow_status => [416]);

        # 416 Range Not Satisfiable is what the array answers for an offset
        # past the end of the collection. Reaching one is not an error here:
        # it means the collection shrank while it was being paged, which is
        # what a volume deleted on another node during a listing looks like.
        # Dying on it would turn an ordinary concurrent delete into a storage
        # that reports itself broken.
        last if $resp->code == 416;

        my $body  = $resp->decoded_content // '';
        my $batch = length($body) ? eval { decode_json($body) } : [];
        if ($@) {
            die $self->_msg("GET $endpoint returned a body that is not JSON:"
                . " $@") . "\n";
        }
        $batch = [] unless ref($batch) eq 'ARRAY';

        push @rows, @$batch;

        # An empty page always ends it, whatever the headers say.
        last unless @$batch;

        # 'Content-Range: 0-99/1000' — the figure after the slash is how many
        # rows match in total. '*' means the array will not say. Some
        # implementations prefix the unit ('items 0-99/1000'), which is why
        # only the tail is matched.
        if (my $range = $resp->header('Content-Range')) {
            my ($reported) = $range =~ m{/\s*(\d+)\s*$};
            $total = $reported if defined $reported;
        }

        # Advance by what actually arrived, not by what was requested.
        $offset += scalar(@$batch);

        if (defined $total) {
            last if $offset >= $total;
        } else {
            last if scalar(@$batch) < PAGE_SIZE;
        }

        if ($page == MAX_PAGES) {
            $self->log_warn("stopped paging $endpoint after " . MAX_PAGES
                . " pages (" . scalar(@rows) . " rows"
                . (defined $total ? " of $total" : '') . "); the result is"
                . " incomplete and volumes past this point are not visible to"
                . " this plugin");
        }
    }

    return \@rows;
}

# A prefix match, done in the way Dell's own examples write it.
#
# The developers guide documents ilike as a case-insensitive match "with
# wildcard support" and every example it gives spells the wildcard '*'
# (?name=ilike.User*). PostgREST, which this filter syntax comes from, accepts
# '%' as well — but only the '*' form is documented, so that is the one to
# send.
#
# Getting this wrong is not a visible failure. A wildcard the array treats as
# an ordinary character matches nothing, the collection comes back empty, and
# every volume on the storage disappears from PVE while the array still holds
# them. So the wildcard is never trusted on its own: see _collection_prefixed.
sub _prefix_filter {
    my ($self, $prefix) = @_;

    return 'ilike.' . $prefix . '*';
}

# A collection filtered by name prefix, that cannot silently come back empty
# because the array read the wildcard differently than documented.
#
# The server-side filter is what keeps a poll from transferring the whole
# array's inventory every ten seconds, so it stays. But an empty result is
# also exactly what a misread wildcard produces, and that answer is
# indistinguishable from "this storage has no volumes yet". When the filtered
# query finds nothing, ask once more without the name filter and match the
# prefix here. On a storage that genuinely holds nothing this costs one listing
# of volumes that are not ours; if it ever finds rows the filter missed, the
# wildcard is wrong for this array and the log says so in as many words.
sub _collection_prefixed {
    my ($self, $endpoint, $prefix, $params, %opts) = @_;

    my $filtered = $self->_collection($endpoint,
        { %{ $params // {} }, name => $self->_prefix_filter($prefix) }, %opts);

    # Trust the prefix, not the filter: a match that is broader than a prefix
    # would otherwise pull in another storage's volumes.
    my @kept = grep { defined $_->{name} && index($_->{name}, $prefix) == 0 }
        @$filtered;

    return \@kept if @kept;

    my $all = $self->_collection($endpoint, $params, %opts);
    my @local = grep { defined $_->{name} && index($_->{name}, $prefix) == 0 }
        @$all;

    if (@local) {
        $self->_warn_wildcard($endpoint, $prefix, scalar @local);
    }

    return \@local;
}

sub _warn_wildcard {
    my ($self, $endpoint, $prefix, $found) = @_;

    return if $self->{_wildcard_warned};
    $self->{_wildcard_warned} = 1;

    $self->log_warn("the array's name filter matched nothing on $endpoint for"
        . " prefix '$prefix', but $found row(s) match it here. This appliance"
        . " reads the ilike wildcard differently than the developers guide"
        . " documents; the plugin is filtering locally instead, which is"
        . " correct but slower. Please report it.");

    return;
}

# The fields worth asking for on a volume. Selecting explicitly keeps the
# response small and stable; PowerStore returns a large object otherwise.
sub _volume_select {
    return 'id,name,size,wwn,type,state,appliance_id,creation_timestamp,'
         . 'protection_data,logical_used';
}

# ---------------------------------------------------------------------------
# Cluster and capacity
# ---------------------------------------------------------------------------

sub cluster_get {
    my ($self, %opts) = @_;

    my $rows = $self->get('/cluster', { select => 'id,name,state,system_time' }, %opts);

    return ref($rows) eq 'ARRAY' ? $rows->[0] : $rows;
}

sub appliance_list {
    my ($self, %opts) = @_;
    return $self->_collection('/appliance', { select => 'id,name,model' }, %opts);
}

# ($total, $used, $available) in bytes.
#
# Two sources, because which one exists depends on the PowerStore version:
# the cluster-wide space metrics, and failing that the sum over appliances.
# NOT YET VERIFIED against hardware — the field names in particular.
sub get_managed_capacity {
    my ($self, %opts) = @_;

    my $metrics = eval {
        $self->get('/space_metrics_by_cluster',
            { limit => 1, order => 'timestamp.desc' }, %opts);
    };

    if (ref($metrics) eq 'ARRAY' && @$metrics) {
        my $row = $metrics->[0];
        my $total = $row->{physical_total} // $row->{total_physical} // 0;
        my $used  = $row->{physical_used}  // $row->{total_used}     // 0;
        if ($total > 0) {
            return ($total, $used, $total - $used);
        }
    }

    # Fallback: sum the appliances.
    my $appliances = eval {
        $self->_collection('/appliance',
            { select => 'id,name' }, %opts);
    } // [];

    my ($total, $used) = (0, 0);
    for my $appliance (@$appliances) {
        my $space = eval {
            $self->get('/space_metrics_by_appliance',
                { appliance_id => 'eq.' . $appliance->{id}, limit => 1,
                  order => 'timestamp.desc' }, %opts);
        };
        next unless ref($space) eq 'ARRAY' && @$space;
        my $row = $space->[0];
        $total += $row->{physical_total} // $row->{total_physical} // 0;
        $used  += $row->{physical_used}  // $row->{total_used}     // 0;
    }

    die $self->_msg("could not determine the array's capacity: neither"
        . " space_metrics_by_cluster nor the per-appliance metrics returned"
        . " usable figures.") . "\n" unless $total > 0;

    return ($total, $used, $total - $used);
}

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------

# PowerStore rejects a size that is not a multiple of 8 KiB. Round up: a
# volume slightly larger than requested is harmless, one slightly smaller
# would silently truncate whatever PVE intends to put in it.
sub align_size {
    my ($class, $bytes) = @_;

    my $granularity = SIZE_GRANULARITY;
    my $remainder = $bytes % $granularity;

    return $bytes unless $remainder;
    return $bytes + ($granularity - $remainder);
}

sub volume_create {
    my ($self, $name, $size, %opts) = @_;

    my $body = {
        name => $name,
        size => $self->align_size($size),
    };

    for my $key (qw(appliance_id volume_group_id performance_policy_id
                    protection_policy_id description)) {
        $body->{$key} = $opts{$key} if defined $opts{$key};
    }

    my $res = $self->post('/volume', $body);

    return ref($res) eq 'HASH' ? $res->{id} : undef;
}

sub volume_get {
    my ($self, $id, %opts) = @_;
    return $self->get("/volume/$id", { select => $self->_volume_select }, %opts);
}

sub volume_get_by_name {
    my ($self, $name, %opts) = @_;

    my $rows = $self->get('/volume',
        { name => "eq.$name", select => $self->_volume_select }, %opts);

    return (ref($rows) eq 'ARRAY' && @$rows) ? $rows->[0] : undef;
}

# Every volume whose name starts with $prefix. Server-side filter, paged.
sub volume_list {
    my ($self, $prefix, %opts) = @_;

    my $params = { select => $self->_volume_select };
    $params->{type} = 'eq.Primary' unless $opts{include_snapshots};

    return $self->_collection('/volume', $params, %opts)
        unless defined $prefix && length $prefix;

    return $self->_collection_prefixed('/volume', $prefix, $params, %opts);
}

sub volume_delete {
    my ($self, $id, %opts) = @_;

    my $body = {};
    # A volume with snapshots needs them removed too; PowerStore refuses
    # otherwise.
    $body->{force_internal_snapshots} = JSON::true if $opts{force};

    return $self->_request('DELETE', "/volume/$id", (%$body ? $body : undef), %opts);
}

sub volume_resize {
    my ($self, $id, $size, %opts) = @_;
    return $self->patch("/volume/$id", { size => $self->align_size($size) }, %opts);
}

sub volume_rename {
    my ($self, $id, $name, %opts) = @_;
    return $self->patch("/volume/$id", { name => $name }, %opts);
}

# PowerStore reports 'naa.68ccf098...'; Linux multipath names the map
# '3' + the NAA registered designator.
#
# NOT YET VERIFIED against hardware. Confirm with
#   /lib/udev/scsi_id -g -u /dev/sdX
# before relying on it; see docs/TESTING.md.
sub wwn_to_wwid {
    my ($class, $wwn) = @_;

    return undef unless defined $wwn && length $wwn;

    my $naa = lc($wwn);
    $naa =~ s/^naa\.//;
    $naa =~ s/^0x//;
    $naa =~ s/[^0-9a-f]//g;

    return undef unless length($naa) >= 16;

    return '3' . $naa;
}

sub volume_get_wwid {
    my ($self, $id, %opts) = @_;

    my $vol = eval { $self->volume_get($id, %opts) } or return undef;

    return $self->wwn_to_wwid($vol->{wwn});
}

# ---------------------------------------------------------------------------
# Snapshots
#
# A PowerStore snapshot is itself a volume object, of type Snapshot, whose
# protection_data.source_id points at its parent.
# ---------------------------------------------------------------------------

sub snapshot_create {
    my ($self, $volume_id, $name, %opts) = @_;

    my $body = { name => $name };
    $body->{description} = $opts{description} if defined $opts{description};
    $body->{expiration_timestamp} = $opts{expires} if defined $opts{expires};

    my $res = $self->post("/volume/$volume_id/snapshot", $body, %opts);

    return ref($res) eq 'HASH' ? $res->{id} : undef;
}

sub snapshot_get_by_name {
    my ($self, $name, %opts) = @_;

    my $rows = $self->get('/volume',
        { name => "eq.$name", type => 'eq.Snapshot',
          select => $self->_volume_select }, %opts);

    return (ref($rows) eq 'ARRAY' && @$rows) ? $rows->[0] : undef;
}

# Snapshots of one volume, or every snapshot whose name starts with $prefix.
sub snapshot_list {
    my ($self, %opts) = @_;

    my $params = { type => 'eq.Snapshot', select => $self->_volume_select };

    if (defined $opts{source_id}) {
        # The source id lives inside a JSON column, hence the ->> operator.
        $params->{'protection_data->>source_id'} = 'eq.' . $opts{source_id};
    }
    return $self->_collection_prefixed('/volume', $opts{prefix}, $params, %opts)
        if defined $opts{prefix} && length $opts{prefix};

    return $self->_collection('/volume', $params, %opts);
}

sub snapshot_delete {
    my ($self, $id, %opts) = @_;
    return $self->_request('DELETE', "/volume/$id", undef, %opts);
}

# Restore a volume from one of its snapshots. create_backup_snap leaves a
# safety snapshot of the pre-restore content behind; it defaults off because
# PVE's own rollback semantics do not expect an extra snapshot to appear, and
# the array would keep accumulating them.
sub volume_restore {
    my ($self, $volume_id, $snapshot_id, %opts) = @_;

    my $body = {
        from_snap_id       => $snapshot_id,
        create_backup_snap => $opts{backup} ? JSON::true : JSON::false,
    };

    return $self->post("/volume/$volume_id/restore", $body, %opts);
}

# Thin clone of a volume or of a snapshot. Instant and space-efficient; this
# is what a PVE linked clone becomes.
sub volume_clone {
    my ($self, $source_id, $name, %opts) = @_;

    my $body = { name => $name };
    $body->{description}          = $opts{description} if defined $opts{description};
    $body->{host_id}              = $opts{host_id} if defined $opts{host_id};
    $body->{logical_unit_number}  = $opts{lun} if defined $opts{lun};

    my $res = $self->post("/volume/$source_id/clone", $body, %opts);

    return ref($res) eq 'HASH' ? $res->{id} : undef;
}

# ---------------------------------------------------------------------------
# Hosts
# ---------------------------------------------------------------------------

sub host_list {
    my ($self, $prefix, %opts) = @_;

    my $params = { select => 'id,name,os_type,host_initiators,host_group_id' };

    return $self->_collection_prefixed('/host', $prefix, $params, %opts)
        if defined $prefix && length $prefix;

    return $self->_collection('/host', $params, %opts);
}

sub host_get_by_name {
    my ($self, $name, %opts) = @_;

    my $rows = $self->get('/host',
        { name => "eq.$name",
          select => 'id,name,os_type,host_initiators,host_group_id' }, %opts);

    return (ref($rows) eq 'ARRAY' && @$rows) ? $rows->[0] : undef;
}

# $initiators is [ { port_name => 'iqn...', port_type => 'iSCSI' }, ... ]
sub host_create {
    my ($self, $name, $initiators, %opts) = @_;

    my $body = {
        name       => $name,
        os_type    => $opts{os_type} // 'Linux',
        initiators => $initiators,
    };
    $body->{description} = $opts{description} if defined $opts{description};

    my $res = $self->post('/host', $body, %opts);

    return ref($res) eq 'HASH' ? $res->{id} : undef;
}

sub host_add_initiators {
    my ($self, $host_id, $initiators, %opts) = @_;
    return $self->patch("/host/$host_id", { add_initiators => $initiators }, %opts);
}

sub host_remove_initiators {
    my ($self, $host_id, $port_names, %opts) = @_;
    return $self->patch("/host/$host_id", { remove_initiators => $port_names }, %opts);
}

sub host_delete {
    my ($self, $host_id, %opts) = @_;
    return $self->_request('DELETE', "/host/$host_id", undef, %opts);
}

sub host_group_get_by_name {
    my ($self, $name, %opts) = @_;

    my $rows = $self->get('/host_group',
        { name => "eq.$name", select => 'id,name,hosts' }, %opts);

    return (ref($rows) eq 'ARRAY' && @$rows) ? $rows->[0] : undef;
}

sub host_group_create {
    my ($self, $name, $host_ids, %opts) = @_;

    my $res = $self->post('/host_group', { name => $name, host_ids => $host_ids }, %opts);

    return ref($res) eq 'HASH' ? $res->{id} : undef;
}

# ---------------------------------------------------------------------------
# Mappings
# ---------------------------------------------------------------------------

sub mapping_list {
    my ($self, %opts) = @_;

    my $params = { select => 'id,host_id,host_group_id,volume_id,logical_unit_number' };
    $params->{host_id}       = 'eq.' . $opts{host_id}   if defined $opts{host_id};
    $params->{volume_id}     = 'eq.' . $opts{volume_id} if defined $opts{volume_id};
    $params->{host_group_id} = 'eq.' . $opts{host_group_id}
        if defined $opts{host_group_id};

    return $self->_collection('/host_volume_mapping', $params, %opts);
}

sub is_mapped {
    my ($self, $volume_id, $host_id, %opts) = @_;

    my $mappings = $self->mapping_list(volume_id => $volume_id, %opts);

    # A host that belongs to a host group can be reached by a mapping made to
    # the group, and such a row carries host_group_id with no host_id at all.
    # Reading only host_id would call the volume unmapped, attach it again,
    # and be refused by an array that is already doing what was asked.
    my $group_id = $opts{group_id};

    for my $mapping (@$mappings) {
        return 1 if ($mapping->{host_id} // '') eq $host_id;
        return 1 if defined $group_id && length $group_id
                 && ($mapping->{host_group_id} // '') eq $group_id;
    }

    return 0;
}

# The lowest LUN id this host does not already use.
#
# PowerStore keeps SEPARATE automatic LUN id sequences for its UI and for
# REST/PSTCLI, and the REST sequence starts at 200 and only ever climbs. A
# workload that repeatedly attaches and detaches — which is exactly what a PVE
# cluster does — walks that counter past what the host OS scans, and new disks
# then simply never appear. Assigning the id ourselves keeps it dense and
# bounded. See docs/TROUBLESHOOTING.md.
sub next_free_lun {
    my ($self, $host_id, %opts) = @_;

    my $base = $opts{base} // MIN_LUN_ID;
    $base = MIN_LUN_ID if $base < MIN_LUN_ID;

    my $mappings = $self->mapping_list(host_id => $host_id, %opts);

    # A LUN id is unique per host, and a mapping made to a host GROUP occupies
    # one on every host in it. Those rows carry host_group_id instead of
    # host_id, so a host in a group would otherwise be handed a LUN id one of
    # its group mappings already holds.
    if (defined $opts{group_id} && length $opts{group_id}) {
        push @$mappings,
            @{ $self->mapping_list(host_group_id => $opts{group_id}, %opts) };
    }

    my %used;
    for my $mapping (@$mappings) {
        my $lun = $mapping->{logical_unit_number};
        $used{$lun} = 1 if defined $lun;
    }

    for my $lun ($base .. MAX_LUN_ID) {
        return $lun unless $used{$lun};
    }

    die $self->_msg("host $host_id already uses every LUN id from $base to "
        . MAX_LUN_ID . ". Detach volumes it no longer needs, or lower"
        . " pstore-lun-id-base.") . "\n";
}

sub volume_attach {
    my ($self, $volume_id, %opts) = @_;

    my $body = {};
    $body->{host_id}       = $opts{host_id}       if defined $opts{host_id};
    $body->{host_group_id} = $opts{host_group_id} if defined $opts{host_group_id};

    die $self->_msg("volume_attach needs a host_id or a host_group_id") . "\n"
        unless %$body;

    # Always pass the LUN id explicitly; see next_free_lun.
    if (defined $opts{lun}) {
        $body->{logical_unit_number} = $opts{lun};
    } elsif (defined $opts{host_id}) {
        $body->{logical_unit_number} = $self->next_free_lun($opts{host_id},
            base => $opts{lun_base}, group_id => $opts{group_id});
    }

    return $self->post("/volume/$volume_id/attach", $body, %opts);
}

sub volume_detach {
    my ($self, $volume_id, %opts) = @_;

    my $body = {};
    $body->{host_id}       = $opts{host_id}       if defined $opts{host_id};
    $body->{host_group_id} = $opts{host_group_id} if defined $opts{host_group_id};

    die $self->_msg("volume_detach needs a host_id or a host_group_id") . "\n"
        unless %$body;

    return $self->post("/volume/$volume_id/detach", $body, %opts);
}

# ---------------------------------------------------------------------------
# Transport endpoints
# ---------------------------------------------------------------------------

# [ { portal => 'ip:3260', iqn => '...' }, ... ]
#
# The addresses and the target IQN come from different objects, so they are
# paired here by appliance where possible.
sub iscsi_portals {
    my ($self, %opts) = @_;

    my $select = 'id,address,appliance_id,purposes';

    # 'cs' is the contains operator for a list attribute, and the braces are
    # the array literal it takes. Neither has been seen answered by a real
    # appliance, and an operator the array rejects or reads differently gives
    # an empty result — which here means no portals, so no iSCSI login, so no
    # devices at all. The filter stays, because asking for every address on
    # the array is wasteful; but it is not what decides the answer.
    my $addresses = eval {
        $self->_collection('/ip_pool_address',
            { purposes => 'cs.{Storage_Iscsi_Target}', select => $select },
            %opts);
    } // [];

    unless (@$addresses) {
        my $all = eval {
            $self->_collection('/ip_pool_address', { select => $select }, %opts);
        } // [];

        $addresses = [ grep { _has_iscsi_purpose($_) } @$all ];

        $self->log_warn("the array returned no iSCSI target address for the"
            . " 'cs' filter, but " . scalar(@$addresses) . " of its addresses"
            . " carry the Storage_Iscsi_Target purpose. Using those. Please"
            . " report it.") if @$addresses;
    }

    return [] unless @$addresses;

    my $targets = eval {
        $self->_collection('/ip_port',
            { select => 'id,target_iqn,appliance_id' }, %opts);
    } // [];

    my $default_iqn;
    my %iqn_by_appliance;
    for my $target (@$targets) {
        my $iqn = $target->{target_iqn} or next;
        $default_iqn //= $iqn;
        my $appliance = $target->{appliance_id};
        $iqn_by_appliance{$appliance} //= $iqn if defined $appliance;
    }

    my @portals;
    for my $address (@$addresses) {
        my $ip = $address->{address} or next;
        my $iqn = $iqn_by_appliance{ $address->{appliance_id} // '' } // $default_iqn;
        next unless $iqn;
        push @portals, { portal => "$ip:3260", iqn => $iqn };
    }

    return \@portals;
}

# 'purposes' is a list. Whether it arrives as an arrayref or as one string
# depends on the appliance, so accept either rather than pick one.
sub _has_iscsi_purpose {
    my ($row) = @_;

    my $purposes = $row->{purposes} // return 0;
    my @values = ref($purposes) eq 'ARRAY' ? @$purposes : ($purposes);

    return (grep { defined && /Storage_Iscsi_Target/i } @values) ? 1 : 0;
}

# Target WWPNs, for checking that zoning reaches this array at all.
sub fc_ports {
    my ($self, %opts) = @_;

    return $self->_collection('/fc_port',
        { select => 'id,name,wwn,is_link_up,appliance_id' }, %opts);
}

# ---------------------------------------------------------------------------
# Jobs
#
# Some operations answer 202 with a job id instead of completing inline.
# ---------------------------------------------------------------------------

sub job_get {
    my ($self, $id, %opts) = @_;
    return $self->get("/job/$id", { select => 'id,state,phase,response_body,response_status' }, %opts);
}

sub wait_for_job {
    my ($self, $id, %opts) = @_;

    my $timeout  = $opts{timeout}  // JOB_POLL_TIMEOUT;
    my $interval = $opts{interval} // JOB_POLL_INTERVAL;
    my $deadline = time() + $timeout;

    while (time() < $deadline) {
        my $job = eval { $self->job_get($id) };
        if ($job) {
            my $state = $job->{state} // '';
            return $job if $state =~ /^(?:COMPLETED|COMPLETED_WITH_ERRORS)$/i;
            die $self->_msg("array job $id ended in state '$state'") . "\n"
                if $state =~ /^(?:FAILED|ABORTED)$/i;
        }
        sleep($interval);
    }

    die $self->_msg("array job $id did not finish within ${timeout}s") . "\n";
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::PowerStore::API - PowerStore REST client

=head1 SYNOPSIS

    my $api = PVE::Storage::Custom::DellEMC::PowerStore::API->new(
        portal   => '10.0.0.5',
        username => 'pveadmin',
        password => 'secret',
        storeid  => 'ps1',
        type     => 'dellpowerstore',
    );

    my $id = $api->volume_create('pve-ps1-100-disk0', 32 * 1024**3);
    $api->volume_attach($id, host_id => $host_id);

=head1 STATUS

The endpoint paths, field names and filter syntax here follow the PowerStore
4.x REST documentation and are B<not yet verified against hardware>. Check
them against the appliance's own Swagger UI at C<https://<mgmt-ip>/swaggerui>
before relying on them. See docs/TESTING.md.

=head1 NOTES

Listing always filters server-side. This plugin polls every ten seconds per
node; fetching the whole volume inventory to filter locally would put that
load on the array's management gateway continuously.

LUN ids are assigned by this client rather than by the array. PowerStore's
REST-side automatic sequence starts at 200 and never reuses an id, so a
cluster that repeatedly attaches and detaches volumes eventually exceeds what
the host scans and new disks stop appearing.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
