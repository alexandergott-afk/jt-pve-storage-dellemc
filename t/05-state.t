#!/usr/bin/perl
# WWID tracking and health reporting tests. Both classes are subclassed onto
# a temporary directory so nothing writes to the real node state.
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use JSON;

use PVE::Storage::Custom::DellEMC::Common::WwidState;
use PVE::Storage::Custom::DellEMC::Common::Health;

my $TMP = tempdir(CLEANUP => 1);

{
    package Test::WwidState;
    use base 'PVE::Storage::Custom::DellEMC::Common::WwidState';
    sub state_dir { "$TMP/lib" }
    sub lock_dir  { "$TMP/run" }
}

{
    package Test::Health;
    use base 'PVE::Storage::Custom::DellEMC::Common::Health';
    our @EVENTS;
    sub state_dir { "$TMP/run" }
    sub log_event { push @EVENTS, $_[1]; return }
}

my $S = 'Test::WwidState';
my $H = 'Test::Health';

sub events { return \@Test::Health::EVENTS }
sub reset_events { @Test::Health::EVENTS = (); return }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

is($S->safe_storeid('ps1'), 'ps1', 'plain storeid');
is($S->safe_storeid('dell/../etc'), 'dell____etc', 'path characters neutralised');
is($S->safe_storeid(''), 'unknown', 'empty storeid');
is($S->safe_storeid(undef), 'unknown', 'undef storeid');

like($S->state_file('ps1'), qr{^\Q$TMP\E/lib/ps1-wwids\.json$}, 'state file path');
like($S->lock_file('ps1'), qr{^\Q$TMP\E/run/ps1-wwids\.lock$}, 'lock file path');
like($S->cleanup_lock_file('ps1'), qr{-cleanup\.lock$}, 'cleanup lock is separate');

# A storeid that tries to escape the directory must not be able to.
unlike($S->state_file('../../etc/passwd'), qr{\.\.}, 'traversal cannot escape state dir');

# ---------------------------------------------------------------------------
# Tracking
# ---------------------------------------------------------------------------

is_deeply($S->read_state('ps1'), {}, 'no state file yet');
is($S->is_tracked('ps1', '368ccf0980000001'), 0, 'nothing tracked yet');

ok($S->track_wwid('ps1', '368ccf0980000001'), 'track a WWID');
is($S->is_tracked('ps1', '368ccf0980000001'), 1, 'now tracked');
is($S->is_tracked('ps1', '368CCF0980000001'), 1, 'lookup is case-insensitive');

# Re-tracking must not restart the grace period; that would keep postponing
# the reaping of a device that has been stale for hours.
{
    my $before = $S->tracked_wwids('ps1')->{'368ccf0980000001'}{first_seen};
    $S->with_lock('ps1', sub {
        my $state = $S->read_state('ps1');
        $state->{'368ccf0980000001'}{first_seen} = time() - 5000;
        $S->write_state('ps1', $state);
    });
    $S->track_wwid('ps1', '368ccf0980000001');
    my $after = $S->tracked_wwids('ps1')->{'368ccf0980000001'}{first_seen};
    is($after, time() - 5000, 'tracking an already-tracked WWID keeps first_seen');
    isnt($after, $before, 'and does not reset it to now');
}

ok($S->untrack_wwid('ps1', '368ccf0980000001'), 'untrack a WWID');
is($S->is_tracked('ps1', '368ccf0980000001'), 0, 'gone after untrack');
is($S->untrack_wwid('ps1', '368ccf0980000001'), 0, 'untracking twice is a no-op');
is($S->track_wwid('ps1', undef), 0, 'undef WWID is ignored');
is($S->track_wwid('ps1', ''), 0, 'empty WWID is ignored');

# ---------------------------------------------------------------------------
# Import from the array
# ---------------------------------------------------------------------------

is($S->import_alive('ps1', ['368ccf0980000001', '368ccf0980000002']), 2,
    'importing two new WWIDs');
is($S->import_alive('ps1', ['368ccf0980000001']), 0, 'already-known WWID is not re-added');
is($S->import_alive('ps1', []), 0, 'empty list');
is($S->import_alive('ps1', undef), 0, 'undef list');

# Misses accumulate, and seeing the volume again clears them: the array
# listing that missed it was transient.
{
    my $e = $S->record_miss('ps1', '368ccf0980000001');
    is($e->{miss}, 1, 'first miss recorded');
    $e = $S->record_miss('ps1', '368ccf0980000001');
    is($e->{miss}, 2, 'second miss recorded');

    $S->import_alive('ps1', ['368ccf0980000001']);
    is($S->tracked_wwids('ps1')->{'368ccf0980000001'}{miss}, 0,
        'seeing the volume again clears the miss counter');
}

is($S->record_miss('ps1', 'not-tracked-at-all'), undef,
    'missing an untracked WWID records nothing');

# ---------------------------------------------------------------------------
# Reap guards
#
# Both must pass. A device torn down while a VM is using it is an immediate
# I/O error on a running guest, so every uncertain case must answer "no".
# ---------------------------------------------------------------------------

my $now = 1_000_000;
my $old = $now - 100_000;

ok(!$S->is_reapable({ first_seen => $now - 10, miss => 99 }, now => $now),
    'inside the grace period, never reapable');
ok(!$S->is_reapable({ first_seen => $old, miss => 0 }, now => $now),
    'no misses, not reapable');
ok(!$S->is_reapable({ first_seen => $old, miss => 2 }, now => $now),
    'below the miss threshold, not reapable');
ok($S->is_reapable({ first_seen => $old, miss => 3 }, now => $now),
    'old enough and missed enough times');
ok(!$S->is_reapable(undef, now => $now), 'undef entry is not reapable');
ok(!$S->is_reapable('garbage', now => $now), 'non-entry is not reapable');
ok(!$S->is_reapable({}, now => $now), 'empty entry is not reapable');

# The thresholds are configurable for callers that need a tighter pass.
ok($S->is_reapable({ first_seen => $now - 10, miss => 1 },
    now => $now, grace => 5, threshold => 1), 'thresholds can be overridden');

# ---------------------------------------------------------------------------
# Siblings
#
# Another Dell storage's live device must never be reported as this
# storage's stale orphan.
# ---------------------------------------------------------------------------

$S->import_alive('ps2', ['368ccf0980000009']);

my $siblings = $S->sibling_tracked_wwids('ps1');
ok($siblings->{'368ccf0980000009'}, "ps1 sees ps2's WWID as a sibling");
ok(!$siblings->{'368ccf0980000001'}, 'own WWIDs are not siblings');

my $siblings2 = $S->sibling_tracked_wwids('ps2');
ok($siblings2->{'368ccf0980000001'}, 'and the reverse holds');

# ---------------------------------------------------------------------------
# State file robustness
# ---------------------------------------------------------------------------

{
    # A truncated or corrupted file must not take the storage down.
    my $file = $S->state_file('corrupt');
    open(my $fh, '>', $file) or die $!;
    print $fh '{"broken": ';
    close($fh);
    is_deeply($S->read_state('corrupt'), {}, 'corrupt state file reads as empty');
    ok($S->track_wwid('corrupt', '368ccf0980000003'), 'and can be written over');
}

{
    # JSON that is valid but not an object.
    my $file = $S->state_file('wrongtype');
    open(my $fh, '>', $file) or die $!;
    print $fh '["a","b"]';
    close($fh);
    is_deeply($S->read_state('wrongtype'), {}, 'non-object state file reads as empty');
}

is($S->with_lock('ps1', sub { return 'value' }), 'value', 'with_lock returns the value');
{
    my $err;
    eval { $S->with_lock('ps1', sub { die "inner failure\n" }) };
    $err = $@;
    like($err, qr/inner failure/, 'with_lock propagates exceptions');
    is($S->with_lock('ps1', sub { 'still works' }), 'still works',
        'and releases the lock even after one');
}

# ---------------------------------------------------------------------------
# Health: outage detection
# ---------------------------------------------------------------------------

reset_events();

# An outage is a duration, not a number of polls. Once PVE has marked a
# storage inactive it stops asking for a while, so a real outage can produce
# only one or two calls into the plugin — a counter that waits for three
# consecutive failures would stay silent through exactly the outages that
# matter, and the quieter the outage the less likely it is to be reported.

is($H->record_status_failure('ps1', 'connection refused', now => 1000), 0,
    'the first failure is not yet an outage');
is(scalar @{ events() }, 0, 'and says nothing');

is($H->record_status_failure('ps1', 'connection refused', now => 1010), 0,
    'nor is one ten seconds in');
is(scalar @{ events() }, 0, 'still silent');

# PVE goes quiet here and comes back a minute later. Two calls in total, and
# the outage must still be reported.
is($H->record_status_failure('ps1', 'connection refused', now => 1070), 1,
    'an outage is declared once it has lasted long enough, however few polls');
is(scalar @{ events() }, 1, 'which is reported once');
like(events()->[0], qr/\[ERROR\].*OUTAGE/, 'reported at ERROR severity');
like(events()->[0], qr/connection refused/, 'including the underlying error');
like(events()->[0], qr/'ps1'/, 'and naming the storage');
like(events()->[0], qr/\b70s\b/, 'and how long it has been going on');
is($H->is_down('ps1'), 1, 'storage is marked down');
is($H->fail_count('ps1'), 3, 'failure count kept');

# While still down, the message must not repeat on every poll.
reset_events();
$H->record_status_failure('ps1', 'connection refused', now => 1080);
is(scalar @{ events() }, 0, 'no repeat within the re-emit window');

$H->record_status_failure('ps1', 'connection refused', now => 1120);
is(scalar @{ events() }, 1, 'repeated once the window has passed');

# A single failure that is never followed up must not be reported: one dropped
# packet is not an outage.
{
    $H->record_status_ok('quiet1', 1000, 100, now => 2000);
    reset_events();
    is($H->record_status_failure('quiet1', 'timeout', now => 2001), 0,
        'a lone failure is not an outage');
    is(scalar @{ events() }, 0, 'and is not reported');
    $H->record_status_ok('quiet1', 1000, 100, now => 2005);
    is(scalar @{ events() }, 0, 'recovering from it is not reported either');
}

# A clock correction that moves time backwards must not park the start of the
# outage in the future, where it could never become old enough to report.
{
    reset_events();
    $H->record_status_failure('skew1', 'timeout', now => 5000);
    $H->record_status_failure('skew1', 'timeout', now => 4000);
    is(scalar @{ events() }, 0, 'the backwards step itself reports nothing');
    is($H->record_status_failure('skew1', 'timeout', now => 4100), 1,
        'and the outage is still declared from the corrected clock');
}

# Recovery
reset_events();
$H->record_status_ok('ps1', 1000, 100, now => 1100);
is(scalar @{ events() }, 1, 'recovery is reported');
like(events()->[0], qr/\[INFO\].*RECOVERED/, 'at INFO severity');
is($H->is_down('ps1'), 0, 'no longer down');
is($H->fail_count('ps1'), 0, 'counter reset');

reset_events();
$H->record_status_ok('ps1', 1000, 100, now => 1101);
is(scalar @{ events() }, 0, 'a healthy poll after recovery says nothing');

# ---------------------------------------------------------------------------
# Health: capacity
# ---------------------------------------------------------------------------

reset_events();

$H->record_status_ok('cap', 1000, 899, now => 2000);
is(scalar @{ events() }, 0, 'below 90% is quiet');

$H->record_status_ok('cap', 1000, 900, now => 2001);
is(scalar @{ events() }, 1, '90% used warns');
like(events()->[0], qr/\[WARNING\].*capacity high/, 'at WARNING severity');

reset_events();
$H->record_status_ok('cap', 1000, 910, now => 2002);
is(scalar @{ events() }, 0, 'the warning does not repeat every poll');

reset_events();
$H->record_status_ok('cap', 1000, 960, now => 2003);
is(scalar @{ events() }, 1, '95% used escalates');
like(events()->[0], qr/\[ERROR\].*capacity CRITICAL/, 'at ERROR severity');
like(events()->[0], qr/free space or expand/, 'and says what to do');

reset_events();
$H->record_status_ok('cap', 1000, 970, now => 2004);
is(scalar @{ events() }, 0, 'critical is rate limited too');

# An hour later it may speak again.
reset_events();
$H->record_status_ok('cap', 1000, 970, now => 2003 + 3600);
is(scalar @{ events() }, 1, 'reported again after the cooldown');

# Dropping back under the thresholds must clear the cooldown, so the next
# climb is reported immediately rather than up to an hour later.
reset_events();
$H->record_status_ok('cap', 1000, 500, now => 9000);
is(scalar @{ events() }, 0, 'back to normal is quiet');
$H->record_status_ok('cap', 1000, 960, now => 9001);
is(scalar @{ events() }, 1, 'a fresh climb past critical is reported at once');

# Unknown capacity must not divide by zero or invent a percentage.
reset_events();
$H->record_status_ok('nocap', 0, 0, now => 3000);
$H->record_status_ok('nocap', undef, undef, now => 3001);
is(scalar @{ events() }, 0, 'unknown capacity reports nothing');

# The scope name appears in the message so the operator knows what is full.
reset_events();
$H->record_status_ok('scoped', 1000, 960, now => 4000, scope => 'volume group');
like(events()->[0], qr/volume group/, 'scope is named in the message');

ok($H->forget('ps1'), 'forget removes the health state');
is($H->fail_count('ps1'), 0, 'and it reads as fresh afterwards');

done_testing();
