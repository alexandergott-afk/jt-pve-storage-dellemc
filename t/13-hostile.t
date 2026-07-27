#!/usr/bin/perl
# Hostile and degraded inputs.
#
# Three things that are not exotic in production and that a plugin has to
# survive without doing damage:
#
#   1. Its own state files are corrupt. They live in /var/run and /var/lib,
#      and a node that lost power mid-write leaves half a file behind.
#   2. The array holds objects this storage does not own — another storage's,
#      another cluster's, a human's. Every destructive path is gated on the
#      name, so the gate is the thing to attack.
#   3. Several PVE workers allocate at the same time. The disk id is chosen by
#      reading the array and then creating, which is not atomic.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use POSIX ();

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage::Plugin is not available (not a Proxmox VE node)';
}

use PVE::Storage::Custom::DellEMC::Common::WwidState;
use PVE::Storage::Custom::DellEMC::Common::Health;
use PVE::Storage::Custom::DellEMC::Common::Naming;
use PVE::Storage::Custom::DellEMC::PowerVault::Naming;
use PVE::Storage::Custom::DellEMC::Common::BlockBase;

my $W = 'PVE::Storage::Custom::DellEMC::Common::WwidState';
my $H = 'PVE::Storage::Custom::DellEMC::Common::Health';
my $N = 'PVE::Storage::Custom::DellEMC::Common::Naming';

my $TMP = tempdir(CLEANUP => 1);

# ---------------------------------------------------------------------------
# Corrupt state files
#
# Every one of these must read as "no state yet" rather than take the process
# down. A tracking file that cannot be parsed is a lost cleanup pass; a
# tracking file that kills pvestatd is a lost node.
# ---------------------------------------------------------------------------

{
    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::state_dir = sub { $TMP };
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::lock_dir  = sub { $TMP };

    my @corruptions = (
        ['empty file',            ''],
        ['whitespace',            "   \n\n"],
        ['truncated object',      '{"3600abc":{"first_seen":17850'],
        ['not JSON at all',       "\x00\x01\x02binary garbage"],
        ['JSON but an array',     '[1,2,3]'],
        ['JSON but a string',     '"hello"'],
        ['a very deep structure', '{"a":' . ('[' x 200) . (']' x 200) . '}'],
    );

    for my $case (@corruptions) {
        my ($what, $content) = @$case;
        my $storeid = 'corrupt';

        open(my $fh, '>', $W->state_file($storeid)) or die $!;
        print $fh $content;
        close($fh);

        my $state = eval { $W->read_state($storeid) };
        is(ref($state), 'HASH', "WWID state survives $what");
        is($@, '', "... without dying on $what");

        # And it must still be usable afterwards.
        ok(eval { $W->track_wwid($storeid, '3600abc0000000001'); 1 },
            "... and can be written again after $what");
    }

    # The same for the health file, which is read on every poll.
    for my $case (@corruptions) {
        my ($what, $content) = @$case;

        open(my $fh, '>', $H->state_file('corrupt2')) or die $!;
        print $fh $content;
        close($fh);

        my $state = eval { $H->read_state('corrupt2') };
        is(ref($state), 'HASH', "health state survives $what");
    }

    # And for the temporary-clone record.
    open(my $fh, '>', $W->temp_clone_file('corrupt3')) or die $!;
    print $fh '{"broken":';
    close($fh);

    is_deeply($W->stale_temp_clones('corrupt3'), [],
        'a corrupt temporary-clone record yields no reap candidates');
}

# ---------------------------------------------------------------------------
# A state directory that cannot be written
# ---------------------------------------------------------------------------

{
    my $readonly = "$TMP/readonly";
    mkdir $readonly;
    chmod 0500, $readonly;

    no warnings 'redefine', 'once';
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::state_dir = sub { $readonly };
    local *PVE::Storage::Custom::DellEMC::Common::WwidState::lock_dir  = sub { $readonly };

    SKIP: {
        skip 'running as root, permissions do not apply', 2 if $> == 0;

        my $ok = eval { $W->track_wwid('ro', '3600abc0000000002'); 1 };
        ok($ok, 'a state directory that cannot be written does not raise');
        is_deeply($W->tracked_wwids('ro'), {},
            'and reads back as empty rather than as garbage');
    }

    chmod 0700, $readonly;
}

# ---------------------------------------------------------------------------
# The ownership gate
#
# is_pve_managed_volume decides whether a destructive path may touch an
# object. Everything here is a name that must NOT be accepted for storage
# 'ps1' — a near miss is the dangerous case, not an obviously foreign one.
# ---------------------------------------------------------------------------

{
    my @foreign = (
        'production-lun-7',              # a human's volume
        'pve-ps2-100-disk0',             # another storage on the same array
        'pve-ps1x-100-disk0',            # prefix that merely starts the same
        'PVE-PS1-100-disk0',             # our shape, wrong case
        'xpve-ps1-100-disk0',            # our name with something in front
        ' pve-ps1-100-disk0',            # leading space
        'pve-ps1-100-disk0-extra',       # our name with something appended
        'pve-ps1-abc-disk0',             # vmid that is not a number
        'pve-ps1--100-disk0',            # empty storage component
        '',                              # empty
    );

    for my $name (@foreign) {
        my $shown = length($name) ? $name : '(empty)';
        is($N->is_pve_managed_volume($name, 'ps1'), 0,
            "ownership gate refuses '$shown'");
    }

    is($N->is_pve_managed_volume(undef, 'ps1'), 0, 'ownership gate refuses undef');

    # And the ones it must accept.
    for my $name ('pve-ps1-100-disk0', 'pve-ps1-100-cloudinit',
                  'pve-ps1-100-disk0.pve-snap-x', 'pve-ps1-100-disk0.pve-base') {
        is($N->is_pve_managed_volume($name, 'ps1'), 1,
            "ownership gate accepts our own '$name'");
    }

    isnt($N->volume_prefix('ps-1'), $N->volume_prefix('ps'),
        "a storage id that is a prefix of another does not share its namespace");
    isnt($N->volume_prefix('ps1'), $N->volume_prefix('ps10'),
        'nor does one that is a numeric prefix of another');

    # The folding IS lossy, and these pairs really do collide. That is not a
    # bug in the prefix — '-' is the separator inside a volume name, so a
    # storage id containing one has to be folded — it is why on_add_hook
    # refuses a second storage that would land on an existing prefix.
    for my $pair (['ps-1', 'ps_1'], ['ps.1', 'ps_1'], ['ps+1', 'ps_1'],
                  ['ps1_', 'ps1'],  ['_ps1', 'ps1']) {
        my ($a, $b) = @$pair;
        is($N->volume_prefix($a), $N->volume_prefix($b),
            "'$a' and '$b' fold to one prefix, which is what the hook catches");
    }

    # And the consequence, stated once so it cannot be forgotten: the two
    # produce the same volume name, and each passes the other's ownership gate.
    is($N->encode_volume_name('ps-1', 100, 0),
       $N->encode_volume_name('ps_1', 100, 0),
       'two colliding ids name the same volume');
    is($N->is_pve_managed_volume($N->encode_volume_name('ps_1', 100, 0), 'ps-1'), 1,
        "... and one storage's gate accepts the other's volume");
}

# ---------------------------------------------------------------------------
# Hostile storage ids
#
# The storage id comes from the operator and ends up inside array object
# names, inside server-side filters, and inside file names in /var/lib.
# ---------------------------------------------------------------------------

{
    my @ids = (
        'a',                        # shortest possible
        'x' x 200,                  # far longer than any array allows
        'has.dots',
        'has-hyphens',
        'has_underscores',
        'MiXeDcAsE',
        '../../etc/passwd',         # path traversal
        "tab\there",
        'quote"and\'quote',
        'semi;colon',
        'dollar$sign',
        'star*glob?question',
        'percent%25',
        'newline' . "\n" . 'after',
        '中文儲存',                   # non-ASCII
    );

    for my $id (@ids) {
        (my $shown = $id) =~ s/\s+/ /g;
        $shown = substr($shown, 0, 30);

        my $prefix = eval { $N->volume_prefix($id) };
        ok(defined $prefix, "a prefix can be built for '$shown'");
        like($prefix, qr/^pve-[A-Za-z0-9_]+-$/,
            "... and it contains nothing but safe characters ('$shown')");

        # It also has to be usable as part of a file name.
        my $safe = $W->safe_storeid($id);
        unlike($safe, qr{[/\\\s\0]}, "... and the state file name is safe ('$shown')");

        # And the whole volume name has to survive the family limits.
        my $volume = eval { $N->encode_volume_name($id, 100, 0) };
        ok(defined $volume, "... and a volume name can be built ('$shown')");
    }

    # PowerVault has 32 bytes for everything. A storage id that does not fit
    # must be refused with a message about the storage id, not truncated into
    # a name that could collide with another VM's.
    my $PVN = 'PVE::Storage::Custom::DellEMC::PowerVault::Naming';
    my $long = 'averyverylongstorageid';
    my $name = eval { $PVN->encode_volume_name($long, 1234567, 10) };
    if (defined $name) {
        cmp_ok(length($name), '<=', 32, 'a PowerVault name is within the limit');
    } else {
        like($@, qr/shorter storage id/,
            'or the error names the storage id as the thing to shorten');
    }

    # The snapshot suffix has to fit too, and the failure has to be the same
    # kind of message rather than a silently truncated snapshot name.
    my $vol = $PVN->encode_volume_name('storeid10x', 1234567, 999);
    my $snap = eval { $PVN->encode_snapshot_name($vol, 'a-long-snapshot-name') };
    if (defined $snap) {
        cmp_ok(length($snap), '<=', 32, 'and so is a snapshot name');
    } else {
        like($@, qr/shorter storage id|no room/, 'or it says why not');
    }
}

# ---------------------------------------------------------------------------
# Concurrent allocation
#
# Disk ids are chosen by listing the array and taking the lowest free one,
# then creating. That is not atomic, and PVE runs workers in parallel. Real
# processes, a real shared array, no cooperation between them.
# ---------------------------------------------------------------------------

{
    my $array_file = "$TMP/array.json";

    {
        package Test::SharedPlugin;
        use base 'PVE::Storage::Custom::DellEMC::Common::BlockBase';
        use Fcntl qw(:flock O_RDWR O_CREAT);
        use JSON;

        our $FILE;

        sub type { 'delltest' }
        sub multipath_vendor { 'DellEMC' }
        sub multipath_product { 'TestArray' }
        sub multipath_defaults { { no_path_retry => 30 } }

        # The array's whole state, under an exclusive lock. A real array
        # serialises creates; this stands in for that.
        sub _with_array {
            my ($class, $code) = @_;

            sysopen(my $fh, $FILE, O_RDWR | O_CREAT) or die "open: $!";
            flock($fh, LOCK_EX) or die "flock: $!";

            local $/;
            seek($fh, 0, 0);
            my $raw = <$fh> // '';
            my $state = length($raw) ? (eval { decode_json($raw) } // {}) : {};

            my @ret = $code->($state);

            seek($fh, 0, 0);
            truncate($fh, 0);
            print $fh encode_json($state);
            close($fh);

            return wantarray ? @ret : $ret[0];
        }

        sub _array_list_volumes {
            my ($class, $scfg, $storeid, $prefix) = @_;
            return $class->_with_array(sub {
                my ($state) = @_;
                my @out;
                for my $name (sort keys %$state) {
                    next if defined $prefix && index($name, $prefix) != 0;
                    push @out, { name => $name, size => 1024, used => 0 };
                }
                return \@out;
            });
        }

        sub _array_get_volume {
            my ($class, $scfg, $name) = @_;
            return $class->_with_array(sub {
                my ($state) = @_;
                return $state->{$name} ? { name => $name, size => 1024 } : undef;
            });
        }

        sub _array_create_volume {
            my ($class, $scfg, $storeid, $name, $size) = @_;
            return $class->_with_array(sub {
                my ($state) = @_;
                die "already exists\n" if $state->{$name};
                $state->{$name} = 1;
                return $name;
            });
        }

        sub _array_get_wwid { return undef }
        sub _array_ensure_host { return 'pve-test-node1' }
        sub _array_list_hosts { return [] }
        sub _array_is_mapped { return 1 }
        sub _array_map_to_host { return 1 }
        sub _array_unmap_from_host { return 1 }
        sub _array_mapped_hosts { return [] }
        sub _array_delete_volume { return 1 }
        sub _array_ping { return 1 }
        sub _array_get_capacity { return (1000, 0, 1000) }
        sub _array_get_portals { return [] }
        sub _array_snapshot_list { return [] }
    }

    $Test::SharedPlugin::FILE = $array_file;

    my $workers = 16;
    my $scfg = { 'dell-portal' => '10.0.0.1' };

    my @pids;
    my %result_pipe;

    for my $i (1 .. $workers) {
        pipe(my $r, my $w) or die "pipe: $!";
        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ($pid == 0) {
            close($r);
            my $name = eval {
                Test::SharedPlugin->alloc_image('t1', $scfg, 100, 'raw', undef, 1024);
            };
            my $err = $@;
            my $out = defined($name) && length($name) ? $name
                    : 'ERROR: ' . ($err || 'returned nothing');
            $out =~ s/\s+/ /g;
            print $w $out;
            close($w);
            POSIX::_exit(0);
        }

        close($w);
        push @pids, $pid;
        $result_pipe{$pid} = $r;
    }

    my @names;
    for my $pid (@pids) {
        my $fh = $result_pipe{$pid};
        my $line = do { local $/; <$fh> } // '';
        close($fh);
        waitpid($pid, 0);
        push @names, $line;
    }

    my @errors = grep { /^ERROR/ } @names;
    my @ok     = grep { !/^ERROR/ && length } @names;

    is(scalar(@errors), 0, 'every concurrent allocation succeeds')
        or diag("  $_") for @errors ? ($errors[0]) : ();

    my %seen;
    $seen{$_}++ for @ok;
    my @duplicates = grep { $seen{$_} > 1 } keys %seen;

    is(scalar(@duplicates), 0, 'and no two of them get the same disk id')
        or diag("duplicated: @duplicates");

    is(scalar(@ok), $workers, "all $workers workers got a volume");

    for my $name (@ok) {
        like($name, qr/^vm-100-disk-\d+$/, "'$name' is a well-formed disk name");
    }
}

# ---------------------------------------------------------------------------
# Size alignment
#
# Each family rounds volume sizes to its own granularity. Rounding the wrong
# way is silent: PVE believes the disk is the size it asked for, the guest
# fills it, and the write past the end is the first anyone hears of it. So the
# only rule that matters is that the result is never smaller than the request.
# ---------------------------------------------------------------------------

{
    require PVE::Storage::Custom::DellEMC::PowerStore::API;
    require PVE::Storage::Custom::DellEMC::PowerVault::API;
    require PVE::Storage::Custom::DellEMC::PowerFlex::API;

    my @families = (
        ['PowerStore', 'PVE::Storage::Custom::DellEMC::PowerStore::API', 8 * 1024],
        ['PowerVault', 'PVE::Storage::Custom::DellEMC::PowerVault::API', 4 * 1024 * 1024],
        ['PowerFlex',  'PVE::Storage::Custom::DellEMC::PowerFlex::API',  8 * 1024 ** 3],
    );

    for my $family (@families) {
        my ($name, $class, $unit) = @$family;

        for my $request ($unit - 1, $unit, $unit + 1, 1, 1024, 32 * 1024 ** 3) {
            my $aligned = eval { $class->align_size($request) };
            next unless defined $aligned;   # a family may refuse a size outright

            cmp_ok($aligned, '>=', $request,
                "$name: $request bytes never rounds DOWN");
            is($aligned % $unit, 0,
                "$name: $request bytes lands on the granularity");
            cmp_ok($aligned - $request, '<', $unit,
                "$name: $request bytes is not over-allocated by a whole unit");
        }
    }

    # PowerVault documents a 128 TiB ceiling. Asking for more has to be an
    # error naming the limit, not a silently truncated volume.
    my $pv = 'PVE::Storage::Custom::DellEMC::PowerVault::API';
    ok(!eval { $pv->align_size(200 * 1024 ** 4); 1 },
        'PowerVault refuses a size beyond what the array supports');
    like($@, qr/maximum volume size/i, '... naming the limit');
}

# ---------------------------------------------------------------------------
# PowerVault expand takes a delta, not a total
#
# The CLI's 'expand volume size <n>' ADDS n. PVE asks for the new total. Get
# this backwards and asking for 33 GB on a 32 GB volume produces 65 GB.
# ---------------------------------------------------------------------------

{
    my $pv = 'PVE::Storage::Custom::DellEMC::PowerVault::API';

    my @sent;
    my $api = bless {}, $pv;
    {
        no warnings 'redefine';
        local *PVE::Storage::Custom::DellEMC::PowerVault::API::_cmd = sub {
            my ($self, $tokens) = @_;
            push @sent, join(' ', @$tokens);
            return {};
        };

        my $gib = 1024 ** 3;

        # 32 GiB volume, grown to 33 GiB: the array must be told 1 GiB.
        $api->volume_expand('vol', 33 * $gib, current_size => 32 * $gib);
        like($sent[-1], qr/expand volume size (\d+)B vol/,
            'expand names the size and the volume');

        my ($delta) = $sent[-1] =~ /size (\d+)B/;
        is($delta, $gib, 'and the size it sends is the difference, not the total');

        # Same size: nothing to do, and nothing sent.
        @sent = ();
        is($api->volume_expand('vol', 32 * $gib, current_size => 32 * $gib), 0,
            'growing to the size it already is does nothing');
        is(scalar(@sent), 0, 'and sends no command at all');

        # Smaller: also nothing. Shrinking is refused a layer up, but this
        # must not turn into a negative delta if it ever gets here.
        @sent = ();
        is($api->volume_expand('vol', 16 * $gib, current_size => 32 * $gib), 0,
            'a smaller size is a no-op, never a negative delta');
        is(scalar(@sent), 0, 'and sends nothing');
    }
}

# ---------------------------------------------------------------------------
# Locale
# ---------------------------------------------------------------------------

# strerror is rendered in the node's locale. Code that asks "does this path
# exist" by matching $! against English text finds nothing on a node running
# with a non-English LC_MESSAGES, and then reports a missing directory as a
# failure to read it — on every poll.
{
    require PVE::Storage::Custom::DellEMC::Common::ISCSI;

    my ($sessions, $err, $absent) =
        PVE::Storage::Custom::DellEMC::Common::ISCSI::_session_dirs();

    ok(ref($sessions) eq 'ARRAY', 'session enumeration returns a list');
    ok(defined($absent), 'and says whether iSCSI is configured at all')
        or diag('the absent flag is what the caller uses instead of reading $!');

    # Whatever this node has, the two answers must agree with each other.
    ok(!($absent && !$err), 'absent is only ever set alongside the error');

    # And the errno, not its text: this is what makes it locale-independent.
    my $source = '';
    for my $path ('lib/PVE/Storage/Custom/DellEMC/Common/ISCSI.pm',
                  '../lib/PVE/Storage/Custom/DellEMC/Common/ISCSI.pm') {
        next unless open(my $fh, '<', $path);
        local $/;
        $source = <$fh>;
        close($fh);
        last;
    }
    # Comments are allowed to name the string; code is not.
    (my $code = $source) =~ s/^\s*#.*$//mg;
    unlike($code, qr/No such file or directory/,
        'nothing decides anything by matching strerror text');
}

# Every command whose output this plugin parses must run in the C locale.
# util-linux ships translations, so 'fuser -v' on a zh_TW node answers in
# Chinese — and the nodes this plugin is written for are as likely to run
# zh_TW as en_US. A parser that silently matches nothing is the failure.
for my $file (qw(
    lib/PVE/Storage/Custom/DellEMC/Common/Multipath.pm
    lib/PVE/Storage/Custom/DellEMC/Common/ISCSI.pm
    lib/PVE/Storage/Custom/DellEMC/PowerFlex/Host.pm
)) {
    my $source = '';
    for my $path ($file, "../$file") {
        next unless open(my $fh, '<', $path);
        local $/;
        $source = <$fh>;
        close($fh);
        last;
    }

  SKIP: {
        skip "$file is not readable from here", 1 unless length $source;
        like($source, qr/local\s+\$ENV\{LC_ALL\}\s*=\s*'C'/,
            "$file pins the C locale before running a command")
            or diag('a translated tool answers in the node\'s language and'
                  . ' every parser here silently matches nothing');
    }
}

# ---------------------------------------------------------------------------
# A corrupt temporary-clone record must not delete a real disk
#
# The reaper runs unattended in the background of a poll and deletes array
# volumes. Its gate used to be "does the name start with this storage's
# prefix" — which every VM disk on the storage also satisfies. A record
# naming a real disk was therefore enough to delete it with nobody watching.
# ---------------------------------------------------------------------------

{
    require PVE::Storage::Custom::DellEMC::Common::Naming;
    my $N = 'PVE::Storage::Custom::DellEMC::Common::Naming';

    my $prefix = $N->volume_prefix('ps1');
    my $infix  = $N->temp_clone_infix;

    # What the reaper is for.
    my $temp = $N->encode_temp_clone_name($prefix . '100-disk0', 'abc');
    ok(index($temp, $prefix) == 0, 'a temporary clone carries the prefix');
    ok(index($temp, $infix) > 0, 'and the infix that identifies it as one');

    # What must never be mistaken for one, however the record got there.
    for my $real ("${prefix}100-disk0", "${prefix}101-disk3",
                  "${prefix}100-cloudinit") {
        ok(index($real, $prefix) == 0,
            "'$real' shares the prefix, which is why the prefix is not enough");
        is(index($real, $infix), -1,
            "'$real' carries no temp-clone infix, so the reaper leaves it")
            or diag('this name would be deleted unattended');
    }
}

done_testing();
