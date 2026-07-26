# Dell EMC storage plugins for Proxmox VE - PowerVault ME REST client
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellEMC::PowerVault::API;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::REST);

use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use URI::Escape qw(uri_escape);

# PowerVault ME4 and ME5 do not expose a REST object model. They expose the
# CLI over HTTPS: the command and its arguments are the URL path, and the
# reply is the CLI's own output rendered as JSON.
#
# Everything in the "documented" list below is taken from the Dell PowerVault
# ME5 Series Storage System CLI Reference Guide:
#
#   Login          GET https://<ip>/api/login/<sha256("user_password")>
#                  or GET https://<ip>/api/login with HTTP Basic.
#                  SHA-256 is not compatible with LDAP accounts, so this
#                  client falls back to Basic when the hash login is refused.
#   Headers        sessionKey: <key>   dataType: json
#   Session        30 minute inactivity timeout
#   Commands       GET https://<ip>/api/<verb>/<object>/<args...>
#   Response       { "status": [ { response-type, response, return-code } ],
#                    "<basetype>": [ ... ] }
#
#   create volume [access ...] [initiator ...] [lun <n>] [pool <pool>]
#                 [ports ...] size <n>[B|KiB|...] [volume-group <g>] <name>
#   expand volume size <amount> <volume>        -- the amount is ADDITIVE
#   map volume [access rw] initiator <hosts> [lun <n>] [ports ...] <volumes>
#   show volumes [details] [pattern <string>] [pool <pool>] [type ...]
#   create snapshots volumes <volumes> <snap-names>
#
#   Volume names   <= 32 bytes, may not contain " , . < \
#   Snapshot names <= 32 bytes, unique system-wide, may not contain " , < \
#   Sizes align to 4 MiB and are rounded DOWN by the array
#
# Commands marked NOT VERIFIED below could not be read from the official
# guide during development (Dell's documentation site refused several
# requests). They follow the same CLI grammar and are listed in
# docs/TESTING.md as the first things to check against hardware.

use constant {
    BASE_PATH => '/api',

    # "Volume sizes are aligned to 4.2 MB (4 MiB) boundaries. [...] if the
    # resulting size would be greater than 4.2 MB it will be decreased to the
    # nearest 4.2 MB boundary." The array rounds DOWN, so this client rounds
    # UP before asking: a volume smaller than PVE asked for would be filled
    # and then fail.
    SIZE_GRANULARITY => 4 * 1024 * 1024,

    # ME5 virtual storage, per the CLI guide.
    MAX_VOLUME_SIZE => 128 * 1024 ** 4,

    # The array's own session lifetime is 30 minutes of inactivity; re-login
    # well before that rather than discovering it mid-operation.
    SESSION_TTL => 900,

    # A mapping needs a LUN, and the array increments from the given one when
    # several volumes are mapped at once.
    MIN_LUN_ID => 1,
    MAX_LUN_ID => 255,
};

sub base_path { BASE_PATH }

sub new {
    my ($class, %args) = @_;

    $args{session_ttl} //= SESSION_TTL;

    return $class->SUPER::new(%args);
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

sub _login {
    my ($self) = @_;

    # Documented form first: SHA-256 of "username_password", lowercase hex.
    my $hash = sha256_hex("$self->{username}_$self->{password}");

    my $key = eval { $self->_login_with("/login/$hash") };
    return $self->_mark_session({ key => $key }) if $key;

    my $hash_error = $@ || "the array did not return a session key\n";

    # The guide notes SHA-256 is not compatible with LDAP accounts, and Basic
    # authentication is the documented alternative. Try it before giving up,
    # so an LDAP-backed account is not a hard failure.
    my $auth = encode_base64("$self->{username}:$self->{password}", '');
    $key = eval {
        $self->_login_with('/login', { Authorization => "Basic $auth" });
    };
    return $self->_mark_session({ key => $key }) if $key;

    chomp(my $basic_error = $@ || 'no session key returned');
    chomp $hash_error;

    die $self->_msg("authentication failed. The hashed login was refused"
        . " ($hash_error) and so was HTTP Basic ($basic_error). Verify"
        . " dell-username and dell-password, and that the account is not"
        . " locked out.") . "\n";
}

sub _login_with {
    my ($self, $endpoint, $headers) = @_;

    my $data = $self->_request('GET', $endpoint, undef,
        no_auth => 1,
        headers => { dataType => 'json', %{ $headers // {} } },
    );

    my $status = $self->_status_of($data);
    my $key = $status->{response};

    # A failed login still answers 200 with an error status object.
    if (!$self->_status_ok($status) || !defined $key || $key !~ /^[0-9a-f]{8,}$/i) {
        my $why = $status->{response} // 'no response field';
        $why = 'no session key in the response' if $self->_status_ok($status);
        die "$why\n";
    }

    return $key;
}

sub _auth_headers {
    my ($self) = @_;

    return (
        sessionKey => $self->{_session}{key},
        dataType   => 'json',
    );
}

sub _logout {
    my ($self) = @_;

    return unless $self->session_valid;
    eval { $self->_request('GET', '/exit', undef) };
    $self->_clear_session();

    return;
}

# ---------------------------------------------------------------------------
# Command execution
#
# The CLI's own status object decides success, NOT the HTTP status: a rejected
# command answers 200 with return-code set. Treating 200 as success would make
# a failed volume create look like it worked.
# ---------------------------------------------------------------------------

sub _status_of {
    my ($self, $data) = @_;

    return {} unless ref($data) eq 'HASH';
    my $status = $data->{status};
    return {} unless ref($status) eq 'ARRAY' && @$status;

    # The array appends one status object per command; the last one is the
    # verdict for the command as a whole.
    my $last = $status->[-1];

    return ref($last) eq 'HASH' ? $last : {};
}

sub _status_ok {
    my ($self, $status) = @_;

    my $type = lc($status->{'response-type'} // '');
    return 0 if $type eq 'error';

    # 0 is success for a command; login answers 1. Anything else is a failure
    # even when response-type is missing.
    my $code = $status->{'return-code'};
    return 1 unless defined $code;
    return ($code == 0 || $code == 1) ? 1 : 0;
}

# Does this status mean "your session is no longer valid"?
sub _status_is_auth_failure {
    my ($self, $status) = @_;

    my $text = lc($status->{response} // '');

    return 1 if $text =~ /session\s*key/;
    return 1 if $text =~ /not\s+(?:logged|authenticated)/;
    return 1 if $text =~ /authentication\s+(?:failed|required)/;

    return 0;
}

# Build a command URL from CLI tokens and run it.
#
# Tokens are escaped individually: a volume name never contains anything
# exotic, but a pool name or a host name comes from the operator and may.
sub _cmd {
    my ($self, $tokens, %opts) = @_;

    my $path = '/' . join('/', map { uri_escape($_, '^A-Za-z0-9\-_.~*?\[\]') } @$tokens);

    my $data = $self->get($path, undef, %opts);
    my $status = $self->_status_of($data);

    if (!$self->_status_ok($status)) {
        # An expired session looks like an ordinary command failure here, so
        # retry once with a fresh login before surfacing it.
        if ($self->_status_is_auth_failure($status) && !$opts{_retried}) {
            $self->log_warn("session rejected by the array, re-authenticating");
            $self->_clear_session();
            return $self->_cmd($tokens, %opts, _retried => 1);
        }

        my $command = join(' ', @$tokens);
        my $message = $status->{response} // 'the array reported a failure';

        # A refusal the caller expects and can live with. Matched against the
        # array's own words ONLY: the rendered message also carries the
        # command, and a command named 'add host-members' would match a
        # pattern looking for the word 'member'.
        return undef
            if $opts{tolerate} && $message =~ $opts{tolerate};
        my $code    = $status->{'return-code'};
        $message .= " (return code $code)" if defined $code;

        die $self->_msg("command '$command' failed: $message"
            . $self->_hint_for($status)) . "\n";
    }

    return $data;
}

# Turn the array's wording into something the operator can act on.
sub _hint_for {
    my ($self, $status) = @_;

    my $text = lc($status->{response} // '');

    return "\n  The name is already taken. Volume and snapshot names share one"
         . " namespace on this array and must be unique system-wide."
        if $text =~ /already (?:exists|in use)|duplicate/;

    return "\n  The pool has no room, or the requested size exceeds what the"
         . " pool can provide. Free space or choose another pool with"
         . " pvault-pool."
        if $text =~ /not enough|insufficient|space/;

    return "\n  The volume is still mapped. Unmap it from every host before"
         . " deleting it."
        if $text =~ /mapped|in use by/;

    return "\n  The account lacks the role this command needs. Volume"
         . " operations need at least the 'standard' role."
        if $text =~ /permission|not authorized|role/;

    return "\n  This system has no licence for that feature. Snapshots and"
         . " thin provisioning require the virtual storage licence."
        if $text =~ /licen[cs]e/;

    return '';
}

# Pull one basetype array out of a response, e.g. 'volumes' or 'pools'.
sub _objects {
    my ($self, $data, $basetype) = @_;

    return [] unless ref($data) eq 'HASH';
    my $rows = $data->{$basetype};

    return ref($rows) eq 'ARRAY' ? $rows : [];
}

# ---------------------------------------------------------------------------
# Sizes
# ---------------------------------------------------------------------------

# Round UP to the array's 4 MiB granularity. The array itself rounds down.
sub align_size {
    my ($class, $bytes) = @_;

    my $granularity = SIZE_GRANULARITY;
    my $remainder = $bytes % $granularity;

    my $size = $remainder ? $bytes + ($granularity - $remainder) : $bytes;

    die "Requested size ${bytes} bytes exceeds the maximum volume size this"
      . " array supports (128 TiB).\n" if $size > MAX_VOLUME_SIZE;

    return $size;
}

# The CLI takes a unit suffix; 'B' avoids any ambiguity about decimal versus
# binary multipliers.
sub _size_arg {
    my ($class, $bytes) = @_;
    return $class->align_size($bytes) . 'B';
}

# ---------------------------------------------------------------------------
# System and capacity
# ---------------------------------------------------------------------------

sub system_get {
    my ($self, %opts) = @_;

    my $data = $self->_cmd(['show', 'system'], %opts);

    return $self->_objects($data, 'system')->[0];
}

sub pool_list {
    my ($self, %opts) = @_;

    my $data = $self->_cmd(['show', 'pools'], %opts);

    return $self->_objects($data, 'pools');
}

# ($total, $used, $available) in bytes, over one pool or all of them.
#
# NOT VERIFIED: the numeric field names below follow the CLI's convention of
# a '-numeric' suffix carrying the value in 512-byte blocks. Confirm against
# `show pools` on hardware before trusting the figures.
sub get_managed_capacity {
    my ($self, %opts) = @_;

    my $want = delete $opts{pool};
    my $pools = $self->pool_list(%opts);

    die $self->_msg("the array reported no pools. Create a pool before using"
        . " this storage.") . "\n" unless @$pools;

    my ($total, $available) = (0, 0);
    my $matched = 0;

    for my $pool (@$pools) {
        my $name = $pool->{name} // $pool->{'name-numeric'} // '';
        next if defined $want && length $want && lc($name) ne lc($want);
        $matched++;

        $total     += $self->_blocks_to_bytes($pool, 'total-size');
        $available += $self->_blocks_to_bytes($pool, 'avail-size', 'available-size');
    }

    if (defined $want && length $want && !$matched) {
        my @names = map { $_->{name} // '?' } @$pools;
        die $self->_msg("pool '$want' does not exist on this array. Available"
            . " pools: " . join(', ', @names)) . "\n";
    }

    die $self->_msg("could not read usable capacity figures from `show pools`."
        . " This is one of the fields still unverified against hardware; see"
        . " docs/TESTING.md.") . "\n" unless $total > 0;

    my $used = $total - $available;
    $used = 0 if $used < 0;

    return ($total, $used, $available);
}

# The CLI reports sizes twice: a human string ('1996.7GB') and a numeric field
# in 512-byte blocks. Only the numeric one is safe to compute with.
sub _blocks_to_bytes {
    my ($self, $row, @fields) = @_;

    for my $field (@fields) {
        my $value = $row->{"${field}-numeric"};
        return $value * 512 if defined $value && $value =~ /^\d+$/;
    }

    # Fall back to the formatted string ('1996.7GB'). Returning 0 here would be
    # worse than an approximation: volume_resize compares against the current
    # size, so a zero makes every request look like growth, and PVE would show
    # the volume as empty.
    for my $field (@fields) {
        my $bytes = $self->_parse_size_string($row->{$field});
        return $bytes if defined $bytes;
    }

    return 0;
}

# '1996.7GB', '4.2MB', '1.5TiB' -> bytes. The CLI prints decimal units without
# a suffix letter for base-2, so 'GB' means 10**9 here; the '-numeric' field is
# always preferred and this only runs when it is missing.
sub _parse_size_string {
    my ($self, $value) = @_;

    return undef unless defined $value;
    return $value + 0 if $value =~ /^\d+$/;

    return undef unless $value =~ /^\s*([\d.]+)\s*([KMGTP]?)(i?)B\s*$/i;

    my ($number, $unit, $binary) = ($1, uc($2), $3);

    my $base = $binary ? 1024 : 1000;
    my %power = ('' => 0, K => 1, M => 2, G => 3, T => 4, P => 5);

    return int($number * ($base ** $power{$unit}));
}

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------

# From the CLI Reference:
#     show volumes [details] [pattern <string>] [pool <pool>]
#                  [type all|base|standard|snapshot|primary-volume|secondary-volume]
#                  [vdisk <vdisks>] [volumes]
#
# The parameters are given in the documented order. `pattern` filters on the
# array — listing the whole inventory and filtering here would put it on the
# wire on every poll.
sub volume_list {
    my ($self, $pattern, %opts) = @_;

    my @tokens = ('show', 'volumes', 'details');

    push @tokens, 'pattern', $pattern
        if defined $pattern && length $pattern;

    push @tokens, 'pool', $opts{pool}
        if defined $opts{pool} && length $opts{pool};

    push @tokens, 'type', ($opts{type} // 'all');

    my $data = $self->_cmd(\@tokens, %opts);

    return $self->_objects($data, 'volumes');
}

sub volume_get_by_name {
    my ($self, $name, %opts) = @_;

    # An exact name, not a pattern: 'pve-ps1-100-d1' must not match
    # 'pve-ps1-100-d10'. The trailing positional argument is the documented
    # place for a comma-separated list of volume names.
    my $data = eval { $self->_cmd(['show', 'volumes', 'details', $name], %opts) };
    if ($@) {
        # A missing volume is an error to the CLI, not an empty list.
        return undef if $@ =~ /not (?:found|exist)|does not exist|invalid/i;
        die $@;
    }

    my $rows = $self->_objects($data, 'volumes');
    for my $row (@$rows) {
        return $row if ($row->{'volume-name'} // $row->{name} // '') eq $name;
    }

    return undef;
}

sub volume_create {
    my ($self, $name, $size, %opts) = @_;

    my @tokens = ('create', 'volume');

    push @tokens, 'pool', $opts{pool} if defined $opts{pool} && length $opts{pool};
    push @tokens, 'volume-group', $opts{volume_group}
        if defined $opts{volume_group} && length $opts{volume_group};
    push @tokens, 'tier-affinity', $opts{tier_affinity}
        if defined $opts{tier_affinity} && length $opts{tier_affinity};

    push @tokens, 'size', $self->_size_arg($size);
    push @tokens, $name;

    $self->_cmd(\@tokens, %opts);

    return $name;
}

sub volume_delete {
    my ($self, $name, %opts) = @_;

    # NOT VERIFIED: `delete volumes <name>`.
    $self->_cmd(['delete', 'volumes', $name], %opts);

    return 1;
}

# PVE asks for an absolute size; the array takes the amount to ADD. Getting
# this backwards would grow a 32 GB volume to 64 GB when the user asked for
# 33 GB.
sub volume_expand {
    my ($self, $name, $new_size, %opts) = @_;

    my $current = $opts{current_size};
    unless (defined $current) {
        my $row = $self->volume_get_by_name($name, %opts)
            or die $self->_msg("volume '$name' does not exist") . "\n";
        $current = $self->volume_size($row);
    }

    my $target = $self->align_size($new_size);

    return 0 if $target <= $current;

    my $delta = $target - $current;
    $self->_cmd(['expand', 'volume', 'size', $self->_size_arg($delta), $name], %opts);

    return 1;
}

sub volume_rename {
    my ($self, $name, $new_name, %opts) = @_;

    # NOT VERIFIED: `set volume name <new> <volume>`.
    $self->_cmd(['set', 'volume', 'name', $new_name, $name], %opts);

    return 1;
}

# Bytes, from the numeric field. 'size' alone is a formatted string.
sub volume_size {
    my ($self, $row) = @_;
    return $self->_blocks_to_bytes($row, 'size', 'total-size');
}

sub volume_used {
    my ($self, $row) = @_;
    return $self->_blocks_to_bytes($row, 'allocated-size', 'storage-size');
}

# The multipath WWID is '3' + the volume's WWN.
#
# NOT VERIFIED against hardware: confirm with
#   /lib/udev/scsi_id -g -u /dev/sdX
# before relying on it.
sub wwn_to_wwid {
    my ($class, $wwn) = @_;

    return undef unless defined $wwn && length $wwn;

    my $naa = lc($wwn);
    $naa =~ s/^naa\.//;
    $naa =~ s/^0x//;
    $naa =~ s/[^0-9a-f]//g;

    return undef unless length($naa) >= 16;
    # A WWID that already carries the NAA type prefix must not gain a second.
    return $naa if length($naa) == 33 && $naa =~ /^3/;

    return '3' . $naa;
}

sub volume_wwid {
    my ($self, $row) = @_;

    my $wwn = $row->{wwn} // $row->{'volume-wwn'} // $row->{'serial-number'};

    return $self->wwn_to_wwid($wwn);
}

# ---------------------------------------------------------------------------
# Snapshots
#
# An ME snapshot is a first-class volume: it can be mapped, written to, and
# snapshotted again. That is what makes a PVE linked clone possible here
# without a full copy.
# ---------------------------------------------------------------------------

sub snapshot_create {
    my ($self, $volume, $snapshot, %opts) = @_;

    $self->_cmd(['create', 'snapshots', 'volumes', $volume, $snapshot], %opts);

    return $snapshot;
}

sub snapshot_list {
    my ($self, %opts) = @_;

    my @tokens = ('show', 'snapshots');
    push @tokens, 'pattern', $opts{pattern}
        if defined $opts{pattern} && length $opts{pattern};
    push @tokens, 'volume', $opts{volume}
        if defined $opts{volume} && length $opts{volume};

    # NOT VERIFIED: the `volume` and `pattern` filters of `show snapshots`.
    my $data = $self->_cmd(\@tokens, %opts);

    return $self->_objects($data, 'snapshots');
}

sub snapshot_delete {
    my ($self, $snapshot, %opts) = @_;

    # NOT VERIFIED: `delete snapshot [cleanup] <snapshot>`.
    $self->_cmd(['delete', 'snapshot', $snapshot], %opts);

    return 1;
}

# Replace a volume's contents with one of its snapshots.
#
# The CLI Reference gives the syntax as
#     rollback volume [prompt yes|no] snapshot <snapshot> <volume>
# and the command "will prompt you to unmount the volume and the snapshot from
# all initiators before starting the rollback operation". This client is a
# script, not a person at a terminal: without 'prompt yes' the array is left
# waiting for an answer that never comes. PVE has already established that the
# guest is stopped by the time it asks for a rollback.
sub snapshot_rollback {
    my ($self, $volume, $snapshot, %opts) = @_;

    $self->_cmd(['rollback', 'volume', 'prompt', 'yes',
                 'snapshot', $snapshot, $volume], %opts);

    return 1;
}

# ---------------------------------------------------------------------------
# Hosts and mappings
# ---------------------------------------------------------------------------

sub initiator_list {
    my ($self, %opts) = @_;

    my $data = $self->_cmd(['show', 'initiators'], %opts);

    return $self->_objects($data, 'initiator');
}

# From the CLI Reference:
#     show host-groups [hosts <hosts>] [groups <host-groups>]
#
# The output nests: host groups contain hosts, and each host contains its
# initiators, reported with Nickname, Discovered, Mapped, Profile, Host Type
# and ID (a WWPN for FC and SAS, an IQN for iSCSI).
sub host_list {
    my ($self, %opts) = @_;

    my $data = $self->_cmd(['show', 'host-groups'], %opts);

    # `show host-groups` reports groups, the hosts in them and their
    # initiators; the host rows are what this plugin works with.
    my $hosts = $self->_objects($data, 'hosts');
    return $hosts if @$hosts;

    return $self->_objects($data, 'host-group');
}

sub host_get_by_name {
    my ($self, $name, %opts) = @_;

    for my $host (@{ $self->host_list(%opts) }) {
        my $host_name = $host->{name} // $host->{'host-name'} // '';
        return $host if $host_name eq $name;
    }

    return undef;
}

# Does this host already contain this initiator?
#
# The initiators are nested inside the host object and the exact JSON shape is
# firmware-dependent, so rather than guessing at field names this walks the
# structure and looks for the id itself. An initiator id — an IQN or a WWPN —
# is distinctive enough that finding it anywhere under the host means the host
# has it. Answering "no" when the answer is yes would mean re-adding a member
# on every host check, and a refusal there fails activate_storage.
sub host_has_initiator {
    my ($self, $host, $initiator) = @_;

    return 0 unless defined $initiator && length $initiator;

    my $want  = lc($initiator);
    my @queue = ($host);
    my $seen  = 0;

    while (@queue) {
        my $node = shift @queue;
        next unless defined $node;

        # A structure deep or circular enough to spin here is not a host.
        last if ++$seen > 10_000;

        if (ref($node) eq 'HASH') {
            push @queue, values %$node;
        } elsif (ref($node) eq 'ARRAY') {
            push @queue, @$node;
        } elsif (!ref($node)) {
            return 1 if lc($node) eq $want;
        }
    }

    return 0;
}

# From the CLI Reference:
#     create host [host-group <g>] [initiators <initiators>] [profile standard] <name>
#     # create host initiators 10000090fa13870e,10000090fa13870f Host1
#
# The keyword is 'initiators', and the host name comes LAST, after every
# optional parameter. A host holds at most 128 initiators, and its name is
# limited to 32 bytes without " , . < \ — which is why encode_host_name
# sanitises to alphanumerics, '-' and '_'.
sub host_create {
    my ($self, $name, $initiators, %opts) = @_;

    die $self->_msg("creating a host needs at least one initiator") . "\n"
        unless ref($initiators) eq 'ARRAY' && @$initiators;

    $self->_cmd(['create', 'host', 'initiators', join(',', @$initiators), $name],
        %opts);

    return $name;
}

# From the CLI Reference:
#     add host-members initiators <initiators> <host-name>
#     # add host-members initiators Init3,Init4 Host1
#
# 'set initiator' is a different command: it names an initiator and sets its
# profile, and does not attach it to anything. The list is comma-separated, so
# every missing initiator goes in one command rather than one each.
sub host_add_initiators {
    my ($self, $name, $initiators, %opts) = @_;

    return 1 unless ref($initiators) eq 'ARRAY' && @$initiators;

    # An initiator that is already a member is the state we wanted. This path
    # runs on activation, so a refusal that means "it is already how you want
    # it" must not turn a healthy storage into a failing one.
    $self->_cmd(['add', 'host-members', 'initiators',
                 join(',', @$initiators), $name],
        %opts, tolerate => qr/already|is a member|duplicate/i);

    return 1;
}

sub mapping_list {
    my ($self, %opts) = @_;

    my @tokens = ('show', 'maps');
    push @tokens, $opts{volume} if defined $opts{volume} && length $opts{volume};

    my $data = $self->_cmd(\@tokens, %opts);

    # Depending on firmware the rows come back under 'volume-view-mappings'
    # or 'host-view-mappings'; accept either.
    my $rows = $self->_objects($data, 'volume-view-mappings');
    push @$rows, @{ $self->_objects($data, 'host-view-mappings') };

    return $rows;
}

# Mappings of one volume.
#
# 'show maps' without the initiator parameter reports one row per INITIATOR,
# with the columns Serial Number, Name, Ports, LUN, Access, Identifier,
# Nickname and Profile — there is no host-name column. So a row identifies
# who it is mapped to by initiator id (Identifier) or by nickname, and asking
# "is this volume mapped to host X" cannot be answered by comparing against a
# host name alone.
#
# Every candidate is therefore returned, and the caller decides: a host name,
# an initiator nickname and an initiator id are all things 'unmap volume
# initiator ...' accepts, which is what these are used for.
sub volume_mappings {
    my ($self, $volume, %opts) = @_;

    my $rows = $self->mapping_list(volume => $volume, %opts);

    my @out;
    for my $row (@$rows) {
        my @names = grep { defined && length }
            $row->{'nickname'}, $row->{'identifier'},
            $row->{'host-id'},  $row->{'host'}, $row->{'name'};

        next unless @names;

        push @out, {
            host    => $names[0],   # the friendliest name available
            names   => \@names,     # everything this row could be matched by
            lun     => $row->{lun},
            access  => $row->{access},
        };
    }

    return \@out;
}

# Is $volume mapped to anything in @$identities?
#
# The caller passes the host name AND this node's initiator ids, because a
# mapping row may name any of them and only the caller knows which initiators
# belong to this node.
sub is_mapped_to_any {
    my ($self, $volume, $identities, %opts) = @_;

    return 0 unless ref($identities) eq 'ARRAY' && @$identities;

    my %want = map { lc($_) => 1 } grep { defined && length } @$identities;

    for my $mapping (@{ $self->volume_mappings($volume, %opts) }) {
        for my $name (@{ $mapping->{names} }) {
            return 1 if $want{ lc($name) };
        }
    }

    return 0;
}

sub is_mapped {
    my ($self, $volume, $host, %opts) = @_;

    return $self->is_mapped_to_any($volume, [$host], %opts);
}

# The lowest LUN this host does not already use.
#
# The CLI requires a LUN whenever an initiator is named, and increments from
# it when several volumes are mapped at once. Choosing it here keeps the
# numbering dense and predictable rather than letting it drift upward.
sub next_free_lun {
    my ($self, $host, %opts) = @_;

    my $base = $opts{base} // MIN_LUN_ID;
    $base = MIN_LUN_ID if $base < MIN_LUN_ID;

    my %used;
    for my $row (@{ $self->mapping_list(%opts) }) {
        my $mapped_host = $row->{'identifier'} // $row->{'host-id'}
                       // $row->{'nickname'} // $row->{'host'} // '';
        next unless $mapped_host eq $host;
        my $lun = $row->{lun};
        $used{$lun} = 1 if defined $lun && $lun =~ /^\d+$/;
    }

    for my $lun ($base .. MAX_LUN_ID) {
        return $lun unless $used{$lun};
    }

    die $self->_msg("host '$host' already uses every LUN from $base to "
        . MAX_LUN_ID . ". Unmap volumes it no longer needs, or lower"
        . " pvault-lun-id-base.") . "\n";
}

# ME4 and ME5 document DIFFERENT argument orders for this one command, and
# both were read from Dell's own CLI Reference:
#
#   ME5:  map volume [access ...] initiator <initiators> [lun <LUN>]
#                    [ports <ports>] <volumes>          <- volume LAST
#   ME4:  map volume <volumes> [access ...] [host <hosts>] initiator
#                    <initiators> [lun <LUN>] [ports <ports>]
#                                                        <- volume FIRST
#
# This plugin targets both, so it sends the ME5 form and falls back to the
# ME4 one if the array rejects it. The fallback costs a round trip only on a
# system that wants the other order, and mapping is the one operation no
# volume can be used without.
sub volume_map {
    my ($self, $volume, $host, %opts) = @_;

    my $lun = $opts{lun} // $self->next_free_lun($host, base => $opts{lun_base}, %opts);

    my @me5 = ('map', 'volume', 'access', 'rw', 'initiator', $host,
               'lun', $lun, $volume);
    my @me4 = ('map', 'volume', $volume, 'access', 'rw', 'initiator', $host,
               'lun', $lun);

    my $ok = eval { $self->_cmd(\@me5, %opts); 1 };
    return $lun if $ok;

    my $me5_error = $@;

    $ok = eval { $self->_cmd(\@me4, %opts); 1 };
    if ($ok) {
        $self->log_warn("this array wants the ME4 argument order for"
            . " 'map volume'; using it from here on");
        return $lun;
    }

    chomp(my $me4_error = $@);
    chomp($me5_error);

    die $self->_msg("could not map volume '$volume' to '$host'. Both"
        . " documented argument orders were refused.\n  ME5 form: $me5_error"
        . "\n  ME4 form: $me4_error") . "\n";
}

sub volume_unmap {
    my ($self, $volume, $host, %opts) = @_;

    # NOT VERIFIED: `unmap volume initiator <host> <volume>`.
    $self->_cmd(['unmap', 'volume', 'initiator', $host, $volume], %opts);

    return 1;
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

# [ { portal => 'ip:3260', iqn => '...' }, ... ]
#
# From the CLI Reference, `show ports` reports per port: Ports, Media (FC(P),
# FC(L), SAS or iSCSI), Target ID (a WWPN for FC and SAS, the node name — the
# IQN — for iSCSI), Status (Up, Warning, Error, Not Present, Disconnected),
# IP Address and IP Version for iSCSI, MAC, and Health.
#
# A port the array itself calls Not Present or Disconnected is not worth
# offering to the login loop: this node would pay a TCP probe for it, and
# without the probe a discovery and a login timeout. When the field is absent
# the port is kept — an unfamiliar firmware should not make the storage
# unusable.
sub _port_is_usable {
    my ($self, $port) = @_;

    my $status = $port->{status} // $port->{'status-numeric'};
    return 1 unless defined $status && length $status;

    return 0 if lc($status) =~ /not\s*present|disconnected|error/;

    my $health = $port->{health};
    return 0 if defined $health && lc($health) eq 'fault';

    return 1;
}

sub _port_media {
    my ($self, $port) = @_;
    return lc($port->{media} // $port->{'port-type'} // '');
}

sub iscsi_portals {
    my ($self, %opts) = @_;

    my $data = $self->_cmd(['show', 'ports'], %opts);
    my $ports = $self->_objects($data, 'port');

    my (@portals, @skipped);
    for my $port (@$ports) {
        next unless $self->_port_media($port) =~ /iscsi/;

        my $ip = $port->{'ip-address'} // $port->{'primary-ip-address'};
        next unless defined $ip && length $ip;
        next if $ip =~ /^0\.0\.0\.0$/;

        # 'Target ID' is the node name for an iSCSI port.
        my $target = $port->{'target-id'} // $port->{'iqn'} // next;

        unless ($self->_port_is_usable($port)) {
            push @skipped, $ip;
            next;
        }

        push @portals, { portal => "$ip:3260", iqn => $target };
    }

    $self->log_warn("skipping " . scalar(@skipped) . " iSCSI port(s) the array"
        . " reports as not usable: " . join(', ', @skipped)) if @skipped;

    return \@portals;
}

sub fc_ports {
    my ($self, %opts) = @_;

    my $data = $self->_cmd(['show', 'ports'], %opts);

    # Media is 'FC(P)' or 'FC(L)' on this family.
    return [ grep { $self->_port_media($_) =~ /fc/ }
             @{ $self->_objects($data, 'port') } ];
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellEMC::PowerVault::API - PowerVault ME4/ME5 client

=head1 DESCRIPTION

PowerVault ME exposes its CLI over HTTPS rather than a REST object model: the
command is the URL path and the reply is the CLI's output as JSON.

Two things follow from that and are easy to get wrong:

=over 4

=item * B<HTTP 200 does not mean success.> A rejected command answers 200 with
an error in the C<status> object. Every command here is checked against that
status, not the HTTP code.

=item * B<Sizes are additive on expand.> C<expand volume size> takes the amount
to add, while PVE asks for the new total, so the delta is computed here.

=back

Sizes are rounded B<up> to the array's 4 MiB granularity before being sent,
because the array itself rounds down and would hand back a volume smaller than
the caller asked for.

=head1 STATUS

The login flow, the header names, and the C<create volume>, C<expand volume>,
C<map volume>, C<show volumes> and C<create snapshots> grammars are taken from
the Dell PowerVault ME5 Series CLI Reference Guide. Commands marked
C<NOT VERIFIED> in the source could not be read from the official guide during
development and are listed in docs/TESTING.md as the first things to check
against hardware.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
