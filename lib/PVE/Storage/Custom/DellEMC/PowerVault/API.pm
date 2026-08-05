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

    # "The specified host name is already in use." Recognised by its code and
    # never by its wording — the wording is localised and the rendered message
    # also carries the command this plugin sent.
    RC_HOST_NAME_IN_USE => -10389,
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

    # The hashed attempt just watched every management address fail to
    # connect. Basic authentication cannot succeed against addresses that do
    # not answer TCP; trying it anyway doubles the timeout on a dead array,
    # and this path runs inside the bounded status() budget.
    if ($self->_portals_all_dead()) {
        chomp $hash_error;
        die $self->_msg("authentication failed: no management address is"
            . " answering ($hash_error)") . "\n";
    }

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
# Shell wildcards are legal in exactly one argument: the one after the
# literal token 'pattern', which `show volumes` documents as taking `*`, `?`
# and `[]`. Everywhere else they are ordinary characters that must be escaped.
#
# Leaving them unescaped in every token means a NAME could act as a wildcard,
# and `delete volumes` takes a name positionally — so 'pve-ps1-*' would ask
# the array to delete every volume of the storage. Nothing generates such a
# name, and the ownership gate would refuse it, but neither of those is a
# reason for the transport to be able to express it.
sub _escape_token {
    my ($token, $is_pattern) = @_;

    my $safe = $is_pattern ? '^A-Za-z0-9\-_.~*?\[\]' : '^A-Za-z0-9\-_.~';

    return uri_escape($token, $safe);
}

sub _cmd {
    my ($self, $tokens, %opts) = @_;

    # An empty argument does not produce an empty argument — it produces a
    # command with one fewer, and every positional parameter after it shifts
    # up. 'unmap volume initiator <host> <volume>' with an empty host becomes
    # 'unmap volume initiator <volume>', and Dell's guide is explicit that
    # omitting the initiator removes the DEFAULT mapping — from every host on
    # the array, not just this node.
    #
    # This is the transport, so it refuses rather than trying to work out
    # which caller was careless.
    for my $i (0 .. $#$tokens) {
        my $token = $tokens->[$i];
        next if defined($token) && length($token);

        die $self->_msg("refusing to send '"
            . join(' ', map { defined($_) && length($_) ? $_ : '<EMPTY>' } @$tokens)
            . "': argument " . ($i + 1) . " is empty, which would shift every"
            . " argument after it into the wrong position") . "\n";
    }

    my $pattern_next = 0;
    my @escaped;
    for my $token (@$tokens) {
        push @escaped, _escape_token($token, $pattern_next);
        $pattern_next = (defined $token && $token eq 'pattern') ? 1 : 0;
    }

    my $path = '/' . join('/', @escaped);

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

        my $code = $status->{'return-code'};

        # A refusal the caller expects, recognised by the array's own return
        # code. This is the form to reach for: a code is a fact, where the
        # words around it are localised, reworded between firmware revisions,
        # and — as this project has twice paid for — sometimes text this
        # plugin composed itself.
        if (defined $code && ref($opts{allow_codes}) eq 'ARRAY') {
            return undef if grep { $_ == $code } @{ $opts{allow_codes} };
        }

        # The same thing recognised by the array's words, for the refusals
        # whose code is not documented. Matched against the array's own text
        # ONLY: the rendered message also carries the command, and a command
        # named 'add host-members' would match a pattern looking for the word
        # 'member'.
        return undef
            if $opts{tolerate} && $message =~ $opts{tolerate};
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

        # The pools basetype documents 'total-avail'. 'Avail' is the heading
        # 'show pools' PRINTS, and reading a printed heading as a property
        # name is a mistake this file has now made twice. An ME4024 carries no
        # such field: available came out 0, every pool looked 100% full, and
        # PVE refuses to allocate into a full pool.
        $total     += $self->_blocks_to_bytes($pool, 'total-size', 'total');
        $available += $self->_blocks_to_bytes($pool, 'total-avail', 'avail',
                                              'avail-size', 'available-size',
                                              'available');
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
    my $error = $@;

    # A missing volume is an error to the CLI, not an empty list — and the
    # only thing separating that error from a real one is the wording the
    # array chose. Reading it would mean deciding "this volume does not
    # exist" from a sentence that may have been about something else, and the
    # caller's next move is to create one.
    #
    # So the wording is not read. A pattern listing answers the same question
    # without ambiguity: if the array can list volumes and this name is not
    # among them, it is not there. If the listing fails too, the original
    # error was real and is what gets reported.
    if ($error) {
        my $rows = eval { $self->volume_list($name, %opts) };
        die $error if $@ || !defined $rows;

        return $self->_exact_volume($rows, $name);
    }

    return $self->_exact_volume($self->_objects($data, 'volumes'), $name);
}

sub _exact_volume {
    my ($self, $rows, $name) = @_;

    for my $row (@{ $rows // [] }) {
        next unless ref($row) eq 'HASH';
        # Both spellings are compared, not just whichever is defined first.
        my @names = grep { defined && length }
            $row->{'volume-name'}, $row->{name};
        return $row if grep { $_ eq $name } @names;
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

# Bytes, from the numeric field. The bare field is a formatted string.
#
# The column headings 'show volumes' prints are NOT the property names the
# JSON carries. It prints Total Size and Alloc Size; the volumes basetype
# documents 'size' ("volume capacity"), 'total-size' and 'allocated-size',
# each with a '-numeric' twin in 512-byte blocks. So the property names are
# what these look for, and the headings are only kept as later fallbacks.
#
# 'size' leads for the capacity because that is the one the basetype defines
# as the volume's capacity, which is what PVE means by a disk's size. A zero
# here is worse than an approximation: volume_resize compares against the
# current size, so every request would look like growth, and PVE would show
# the disk as empty.
sub volume_size {
    my ($self, $row) = @_;
    return $self->_blocks_to_bytes($row, 'size', 'total-size');
}

sub volume_used {
    my ($self, $row) = @_;
    return $self->_blocks_to_bytes($row, 'allocated-size', 'alloc-size',
        'storage-size');
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
# Host rows out of a 'show host-groups' answer, wherever the firmware put
# them.
#
# The reply is a tree: host groups at the top, the hosts NESTED inside them
# under their own key, and each host's initiators nested again. Reading only a
# top-level 'hosts' array found nothing on an ME4024, so the fallback returned
# the GROUPS instead — whose names are group names. Every lookup for a host
# then answered "no", the plugin asked for the host it had just created, and
# the array refused with -10389 while the storage went inactive.
#
# Confirmed on an ME4024 running GT280R011-01: the top level carries only
# 'host-group', and each group carries its hosts under 'host' (singular),
# each host its initiators under 'initiator'.
#
# So collect from every key a host row is known to arrive under, at any depth
# — but do not let that list be what decides. Every object in an ME answer
# names its own type in 'object-name', and a row that says it is a host is a
# host whichever key it arrived under. That is what covers the shape nobody
# has captured yet: a host belonging to no group at all, which the CLI prints
# in a separate block and which may well not sit under 'host'.
my @HOST_KEYS = qw(hosts host host-view);

# What the array calls a host row, in its own words about its own type. Not a
# message and not a heading: 'object-name' is a basetype name.
my %HOST_OBJECT_NAME = map { $_ => 1 } qw(host hosts host-view);

# The host basetype documents 'name'; the host-view basetype spells it
# 'host-name'. Both are read, and a row carrying neither is not a host.
sub _host_name_of {
    my ($row) = @_;

    return undef unless ref($row) eq 'HASH';
    for my $field (qw(name host-name)) {
        my $value = $row->{$field};
        next if ref($value);
        return $value if defined $value && length $value;
    }

    return undef;
}

# The public form, so callers read a host's name the one way rather than
# each keeping its own list of spellings.
sub host_name {
    my ($self, $row) = @_;

    return _host_name_of($row);
}

sub _collect_hosts {
    my ($self, $data) = @_;

    my @found;
    my @queue = ($data);
    my $seen  = 0;

    while (@queue) {
        my $node = shift @queue;
        next unless ref($node);

        # A structure deep or circular enough to spin here is not an answer
        # from an array.
        last if ++$seen > 10_000;

        if (ref($node) eq 'ARRAY') {
            push @queue, @$node;
            next;
        }
        next unless ref($node) eq 'HASH';

        # The row saying what it is outranks the key it arrived under.
        my $type = $node->{'object-name'};
        push @found, $node
            if defined $type && !ref($type) && $HOST_OBJECT_NAME{lc $type};

        for my $key (@HOST_KEYS) {
            my $rows = $node->{$key};
            next unless defined $rows;
            for my $row (ref($rows) eq 'ARRAY' ? @$rows : ($rows)) {
                push @found, $row if ref($row) eq 'HASH';
            }
        }

        push @queue, values %$node;
    }

    # The same host reached down two branches of the tree is still one host.
    my %seen_id;
    my @hosts;
    for my $row (@found) {
        next unless defined _host_name_of($row);

        # A row reached through one of the keys above, but which names itself
        # something else, is that other thing. This is what keeps a group from
        # being handed back as a host: returning nothing is always better than
        # returning a neighbouring object type.
        my $type = $row->{'object-name'};
        next if defined $type && !ref($type) && !$HOST_OBJECT_NAME{lc $type};

        my $id = $row->{'durable-id'} // $row->{'serial-number'};
        next if defined $id && !ref($id) && $seen_id{$id}++;
        push @hosts, $row;
    }

    return \@hosts;
}

sub host_list {
    my ($self, %opts) = @_;

    my $data  = $self->_cmd(['show', 'host-groups'], %opts);
    my $hosts = $self->_collect_hosts($data);

    return $hosts if @$hosts;

    # No host anywhere in the tree. Returning the groups instead would be
    # worse than returning nothing: a group name is not a host name, and a
    # caller comparing against one either misses its host or matches an
    # object it must not map a volume to.
    return [];
}

sub host_get_by_name {
    my ($self, $name, %opts) = @_;

    return undef unless defined $name && length $name;

    my $hosts = $self->host_list(%opts);

    for my $host (@$hosts) {
        my $have = _host_name_of($host) // next;
        return $host if $have eq $name;
    }

    # The array's own uniqueness check on a host name ignores case, so a name
    # differing only in case is the same host to it and a different one to an
    # exact comparison. Answering "no" there is how the plugin ends up asking
    # for a host the array already has.
    for my $host (@$hosts) {
        my $have = _host_name_of($host) // next;
        return $host if lc($have) eq lc($name);
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

    my $data = $self->_cmd(
        ['create', 'host', 'initiators', join(',', @$initiators), $name],
        %opts);

    # An expected refusal the caller listed in allow_codes.
    return undef unless defined $data;

    return $name;
}

# Create the host, or report that the array already has one under that name.
#
# Returns 1 when it created it and 0 when the array refused because the name
# is taken; anything else dies. The array's refusal is the one piece of
# evidence that does not depend on this plugin being able to read the host
# back, which is exactly what failed on the ME4024 — so a caller that cannot
# find a host still learns whether it exists.
sub host_create_or_exists {
    my ($self, $name, $initiators, %opts) = @_;

    my $created = $self->host_create($name, $initiators, %opts,
        allow_codes => [ RC_HOST_NAME_IN_USE ]);

    return defined $created ? 1 : 0;
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

# The identifier grammar 'map' and 'unmap' use, which is not the same as a
# name:
#
#   <name>       an initiator, by nickname or by WWPN/IQN
#   <name>.*     a HOST
#   <name>.*.*   a host GROUP
#
# This plugin always addresses a host, so the suffix is not decoration — it is
# what says which kind of object is meant. A bare host name is looked up as an
# initiator and refused with -10386, "The specified initiator nickname or
# identifier was not found in the system". Confirmed on an ME4024 running
# GT280R011-01, where the bare form failed and '<name>.*' succeeded against
# the same host in the same session.
#
# The '*' is percent-encoded on the way out; the array decodes it before its
# CLI sees it. That was confirmed on the same array, and it is why the URL
# escaping does not need to make an exception for this argument.
sub _host_arg {
    my ($self, $host) = @_;

    return $host if !defined($host) || !length($host);
    return $host if $host =~ /\.\*\z/;

    return "$host.*";
}

# The array reports that same grammar back in 'show maps', so a mapping row's
# nickname carries the suffix too. A comparison that does not drop it never
# matches, and this plugin has already paid for that once: a host whose LUNs
# all look free is handed one it is using, and the array refuses the mapping
# with -3177.
sub _strip_map_suffix {
    my ($self, $name) = @_;

    return $name unless defined $name;
    $name =~ s/(?:\.\*)+\z//;

    return $name;
}

# Is this row a mapping at all?
#
# Every volume carries one placeholder row describing its DEFAULT mapping,
# present even when there is none: lun "", access "not-mapped",
# access-numeric 0, identifier "all other initiators", nickname "". The CLI's
# own table does not show it; only the JSON has it.
#
# 'all other initiators' is a display string and not an identifier the CLI
# accepts, so trying to unmap it fails with -10007 — which is what happened on
# every 'qm destroy'. It is recognised by its ACCESS and not by that string:
# the string is what a display layer chose and may be translated or reworded,
# while "no access" is the thing that makes the row not a mapping.
sub _is_real_mapping {
    my ($self, $row) = @_;

    return 0 unless ref($row) eq 'HASH';

    my $numeric = $row->{'access-numeric'};
    return 0 if defined $numeric && !ref($numeric) && "$numeric" eq '0';

    my $access = $row->{access};
    return 0 if defined $access && !ref($access) && lc($access) eq 'not-mapped';

    return 1;
}

sub mapping_list {
    my ($self, %opts) = @_;

    my @tokens = ('show', 'maps');
    push @tokens, $opts{volume} if defined $opts{volume} && length $opts{volume};

    my $data = $self->_cmd(\@tokens, %opts);

    # 'show maps' answers with a tree, grouped by volume: the top level is
    # 'volume-view' (and 'volume-group-view'), one entry per volume, each
    # carrying its rows under 'volume-view-mappings'. There is no top-level
    # array of mappings, so indexing straight into one returns nothing —
    # every LUN then looks free, and the second volume mapped to a host is
    # refused with -3177, "The specified LUN overlaps a previously defined
    # LUN". Confirmed on an ME4024 running GT280R011-01.
    #
    # The nested rows call themselves 'host-view' in 'object-name', so unlike
    # the host listing this one cannot be driven by the type the row claims;
    # it is walked by key.
    my @rows;
    for my $key ('volume-view', 'volume-group-view') {
        for my $view (@{ $self->_objects($data, $key) }) {
            next unless ref($view) eq 'HASH';

            for my $nested ('volume-view-mappings', 'host-view-mappings') {
                my $inner = $view->{$nested};
                next unless ref($inner) eq 'ARRAY';

                # Carry the volume's identity down. A nested row names its
                # parent only by durable-id, which is of no use to a caller
                # that asked about a volume by name.
                for my $row (@$inner) {
                    next unless ref($row) eq 'HASH';
                    push @rows, {
                        %$row,
                        'volume-name'   => $view->{'volume-name'},
                        'volume-serial' => $view->{'volume-serial'},
                    };
                }
            }
        }
    }

    return \@rows if @rows;

    # Firmware that does put the rows at the top level after all.
    my $flat = $self->_objects($data, 'volume-view-mappings');
    push @$flat, @{ $self->_objects($data, 'host-view-mappings') };

    return $flat;
}

# Mappings of one volume.
#
# 'show maps' reports one row per INITIATOR. The volume-view-mappings basetype
# gives each row a 'nickname', documented as the host or host group name and
# "blank if unset", and an 'identifier', the initiator's WWPN or IQN. So the
# host name is there — but only when the initiator has been given one, which
# a manually registered initiator on someone else's array may not have been.
#
# Asking "is this volume mapped to host X" therefore cannot rest on either
# field alone. Every candidate is returned and the caller decides: a host
# name, a host group name and an initiator id are all things
# 'unmap volume initiator ...' accepts, which is what these are used for.
# 'host-id' and 'host' are not in the documented basetype; they are kept for
# a firmware that spells it differently, and cost nothing when absent.
sub volume_mappings {
    my ($self, $volume, %opts) = @_;

    my $rows = $self->mapping_list(volume => $volume, %opts);

    my @out;
    for my $row (@$rows) {
        # 'show maps <volume>' is asked to filter, and this checks that it
        # did. The rows now carry the volume they were nested under, so the
        # check costs nothing — and the caller of this is the unmap path,
        # where acting on another volume's rows would mean reporting a volume
        # mapped when it is not, and leaving a real mapping in place. A row
        # that does not say which volume it belongs to is kept: refusing it
        # would turn a firmware answering in a flatter shape into "nothing is
        # mapped", which is the answer that leaves a ghost LUN behind.
        my $named = $row->{'volume-name'};
        next if defined $named && !ref $named && length $named
             && defined $volume && length $volume
             && $named ne $volume;

        # The default-mapping placeholder is not something to unmap. Its
        # nickname is empty, which is what promotes 'all other initiators'
        # into the name list at all — and that string is not an identifier
        # the CLI accepts, so unmapping it fails with -10007 on every delete.
        # This plugin never creates a default mapping: every 'map volume' it
        # sends names an initiator.
        next unless $self->_is_real_mapping($row);

        my @names = grep { defined && length }
            map { $self->_strip_map_suffix($_) }
            grep { defined && !ref }
            ($row->{'nickname'}, $row->{'identifier'},
             $row->{'host-id'},  $row->{'host'});

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
#
# $host may be a host name, a host-group name or an initiator id, and a
# mapping row carries the first two in 'nickname' and the last in
# 'identifier'. Comparing against whichever field happens to be defined first
# would answer 'no' for every row on a system where both are — the LUNs
# already in use would look free, and the second volume mapped to a host
# would collide with the first.
sub next_free_lun {
    my ($self, $host, %opts) = @_;

    my $base = $opts{base} // MIN_LUN_ID;
    $base = MIN_LUN_ID if $base < MIN_LUN_ID;

    my $want = lc($host // '');

    my %used;
    for my $row (@{ $self->mapping_list(%opts) }) {
        my @raw = grep { defined && !ref && length }
            ($row->{'nickname'},  $row->{'identifier'},
             $row->{'host-id'},   $row->{'host'});

        # A mapping recorded against a host GROUP occupies that LUN on every
        # host in the group, and this plugin cannot tell from here whether
        # this node's host is one of them. So it counts as used. Being wrong
        # that way costs a LUN id out of 255; being wrong the other way hands
        # out an id the array then refuses, which is what -3177 is. The same
        # trap is why the PowerStore client reads group mappings too.
        my $group_level = grep { /\.\*\.\*\z/ } @raw;

        my $mine = grep { lc($self->_strip_map_suffix($_)) eq $want } @raw;
        next unless $mine || $group_level;

        my $lun = $row->{lun};
        $used{$lun} = 1 if defined $lun && !ref $lun && $lun =~ /^\d+\z/;
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

    # '<host>.*', never the bare name: see _host_arg. A bare name asks the
    # array about an INITIATOR by that name, and there is none.
    my $harg = $self->_host_arg($host);

    my @me5 = ('map', 'volume', 'access', 'rw', 'initiator', $harg,
               'lun', $lun, $volume);
    my @me4 = ('map', 'volume', $volume, 'access', 'rw', 'initiator', $harg,
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

    # Verified on an ME4024 running GT280R011-01, together with the '<host>.*'
    # form the identifier has to take. Without the suffix this addresses an
    # initiator that does not exist; with an EMPTY host it would become
    # 'unmap volume <volume>', which Dell documents as removing the DEFAULT
    # mapping — _cmd refuses an empty argument for exactly that reason.
    $self->_cmd(['unmap', 'volume', 'initiator', $self->_host_arg($host),
                 $volume], %opts);

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
