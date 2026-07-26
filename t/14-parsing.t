#!/usr/bin/perl
# What the parsers do with input they were not promised.
#
# Every field name in these clients is written from documentation, not read
# off an array. Some of them will be wrong. The question this file asks is not
# "does the happy path work" — t/07 and t/09 cover that — but "when a field is
# missing, renamed, or a different type than expected, does the plugin fail
# safe or does it act on nonsense".
#
# Failing safe means: return nothing, or die. Never return a value that a
# destructive path would then use — a size of 0, a WWID built from garbage, an
# empty volume list that reads as "everything was deleted".
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

use PVE::Storage::Custom::DellEMC::Common::Naming;
use PVE::Storage::Custom::DellEMC::PowerStore::API;
use PVE::Storage::Custom::DellEMC::PowerVault::API;

my $N  = 'PVE::Storage::Custom::DellEMC::Common::Naming';
my $PS = 'PVE::Storage::Custom::DellEMC::PowerStore::API';
my $PV = 'PVE::Storage::Custom::DellEMC::PowerVault::API';

# Values that turn up when a field is absent, renamed, or of another type.
my @JUNK = (
    undef, '', ' ', 0, '0', -1, 'null', 'undefined', 'N/A', '-',
    [], {}, [1], { a => 1 }, \'scalar ref', sub { 1 },
    "\n", "\0", 'x' x 10_000, '0 but true', '1e10', 'NaN', 'Infinity',
);

sub describe {
    my ($value) = @_;
    return 'undef' unless defined $value;
    return ref($value) . ' ref' if ref($value);
    return "'" . substr($value, 0, 12) . "'" . (length($value) > 12 ? '...' : '');
}

# ---------------------------------------------------------------------------
# WWN to WWID
#
# The WWID decides which device on this host is which volume. A wrong one
# means acting on someone else's device, so anything that is not clearly a
# WWN has to come back undef.
# ---------------------------------------------------------------------------

for my $class ($PS, $PV) {
    (my $short = $class) =~ s/.*:://;

    for my $junk (@JUNK) {
        next if ref($junk);   # the callers only ever pass a scalar

        my $wwid = eval { $class->wwn_to_wwid($junk) };
        is($@, '', "$short: wwn_to_wwid survives " . describe($junk));

        next unless defined $wwid;
        like($wwid, qr/^3[0-9a-f]{16,}$/,
            "$short: anything it does return is a plausible WWID ("
            . describe($junk) . ')');
    }

    # A real one, and near misses of it.
    is($class->wwn_to_wwid('naa.68ccf09800a1b2c3d4e5f60718293a4b'),
        '368ccf09800a1b2c3d4e5f60718293a4b',
        "$short: a documented WWN converts as documented");

    is($class->wwn_to_wwid('naa.68cc'), undef,
        "$short: a WWN too short to be one is refused");
    is($class->wwn_to_wwid('naa.zzzzzzzzzzzzzzzz'), undef,
        "$short: a WWN that is not hex is refused");
}

# ---------------------------------------------------------------------------
# PowerVault: the CLI's status object
# ---------------------------------------------------------------------------

{
    my $api = bless {}, $PV;

    for my $junk (@JUNK) {
        my $status = eval { $api->_status_of($junk) };
        is($@, '', 'PowerVault: _status_of survives ' . describe($junk));
        is(ref($status), 'HASH', '... and always returns a hash');
    }

    # A status array whose last element is not a hash.
    is_deeply($api->_status_of({ status => ['a string'] }), {},
        'a status entry that is not an object yields an empty status');

    # The verdict is the LAST status object: the array appends one per command.
    my $data = {
        status => [
            { 'response-type' => 'Success', 'return-code' => 0 },
            { 'response-type' => 'Error',   'return-code' => -10058,
              response => 'The volume was not found.' },
        ],
    };
    is($api->_status_of($data)->{'return-code'}, -10058,
        'the last status object is the verdict, not the first');
    is($api->_status_ok($api->_status_of($data)), 0,
        '... so the command counts as failed');

    # Object extraction.
    for my $junk (@JUNK) {
        my $rows = eval { $api->_objects($junk, 'volumes') };
        is($@, '', 'PowerVault: _objects survives ' . describe($junk));
        is(ref($rows), 'ARRAY', '... and always returns a list');
    }

    is_deeply($api->_objects({ volumes => 'not a list' }, 'volumes'), [],
        'a basetype that is not a list yields no rows');
}

# ---------------------------------------------------------------------------
# PowerVault: sizes
#
# A size of 0 is the dangerous answer: volume_resize compares against the
# current size, so a zero makes every request look like growth.
# ---------------------------------------------------------------------------

{
    my $api = bless {}, $PV;

    for my $junk (@JUNK) {
        next if ref($junk);

        my $bytes = eval { $api->_blocks_to_bytes({ size => $junk }, 'size') };
        is($@, '', 'PowerVault: size parsing survives ' . describe($junk));
        ok(defined $bytes && $bytes =~ /^\d+$/,
            '... and returns a whole number of bytes (' . describe($junk) . ')');
    }

    # The numeric field is in 512-byte blocks and is preferred over anything
    # else, including a formatted string that disagrees with it.
    is($api->_blocks_to_bytes({ 'size-numeric' => 2048, size => '99GB' }, 'size'),
        1024 * 1024, 'the numeric field wins over the formatted one');

    # A negative or absurd numeric field is not a size.
    is($api->_blocks_to_bytes({ 'size-numeric' => -5 }, 'size'), 0,
        'a negative block count is not a size');

    # Formatted strings, when that is all there is.
    my %expected = (
        '1996.7GB' => 1996700000000,
        '4.2MB'    => 4200000,
        '1.5TiB'   => int(1.5 * 1024 ** 4),
        '512B'     => 512,
        '0B'       => 0,
    );
    while (my ($text, $want) = each %expected) {
        is($api->_parse_size_string($text), $want, "'$text' parses as $want");
    }

    for my $bad ('lots', '12 GB extra', 'GB', '--5GB', '') {
        is($api->_parse_size_string($bad), undef, "'$bad' is not a size");
    }
}

# ---------------------------------------------------------------------------
# Volume rows
#
# _volume_row is what every array listing passes through. A row it cannot make
# sense of must become undef, not a half-built object that later code treats
# as a real volume.
# ---------------------------------------------------------------------------

SKIP: {
    # _volume_row lives on the plugin, which needs PVE to load.
    skip 'PVE::Storage::Plugin is not available', 2 * scalar(@JUNK) + 4
        unless eval { require PVE::Storage::Custom::DellPowerStorePlugin; 1 };

    my $P = 'PVE::Storage::Custom::DellPowerStorePlugin';

    for my $junk (@JUNK) {
        my $row = eval { $P->_volume_row($junk) };
        is($@, '', 'PowerStore: _volume_row survives ' . describe($junk));
        ok(!defined($row) || (ref($row) eq 'HASH' && defined $row->{name}),
            '... and yields either nothing or a named volume ('
            . describe($junk) . ')');
    }

    # A row with a name but nothing else must still be usable, with zeroes
    # rather than undef, because the caller does arithmetic on these.
    my $sparse = $P->_volume_row({ name => 'pve-ps1-100-disk0' });
    ok($sparse, 'a row with only a name is still a volume');
    is($sparse->{size}, 0, '... with a size of 0 rather than undef');
    is($sparse->{used}, 0, '... and a used of 0');
    is($sparse->{wwid}, undef, '... and no WWID at all, rather than a made-up one');
}

# ---------------------------------------------------------------------------
# Names from the array
#
# decode_volume_name is the other half of the ownership gate. Anything it
# accepts, destructive paths will act on.
# ---------------------------------------------------------------------------

{
    for my $junk (@JUNK) {
        next if ref($junk);

        my $decoded = eval { $N->decode_volume_name($junk) };
        is($@, '', 'decode_volume_name survives ' . describe($junk));
        ok(!defined($decoded) || ref($decoded) eq 'HASH',
            '... and returns a hash or nothing (' . describe($junk) . ')');

        my $snap = eval { $N->decode_snapshot_name($junk) };
        is($@, '', 'decode_snapshot_name survives ' . describe($junk));
    }

    # A name that is our shape with an enormous vmid must not become a vmid
    # PVE would choke on later.
    my $huge = $N->decode_volume_name('pve-ps1-' . ('9' x 30) . '-disk0');
    ok(!defined($huge) || $huge->{vmid} =~ /^\d+$/,
        'an absurd vmid is either refused or still a number');

    # Round trip: everything this plugin generates must decode back.
    for my $case ([100, 0], [999999, 999], [1, 1]) {
        my ($vmid, $diskid) = @$case;
        my $name = $N->encode_volume_name('ps1', $vmid, $diskid);
        my $back = $N->decode_volume_name($name);
        ok($back, "'$name' decodes");
        is($back->{vmid}, $vmid, '... to the right vmid');
        is($back->{diskid}, $diskid, '... and the right disk id');
        is($N->is_pve_managed_volume($name, 'ps1'), 1, '... and is ours');
    }
}

# ---------------------------------------------------------------------------
# PVE volume names
#
# These come from PVE, but PVE is not the only thing that can put a string
# here: a hand-edited VM configuration reaches the plugin unchanged.
# ---------------------------------------------------------------------------

{
    my @bad = (
        'vm-100-disk-0/../../etc/passwd',
        '../vm-100-disk-0',
        'vm-100-disk-0; rm -rf /',
        'vm--100-disk-0',
        'vm-100-disk-',
        'vm-abc-disk-0',
        'base-100-disk-0/base-101-disk-0/vm-102-disk-0',
        'vm-100-disk-0 ',
        ' vm-100-disk-0',
        "vm-100-disk-0\n",
        '',
    );

    for my $volname (@bad) {
        (my $shown = $volname) =~ s/\s+/ /g;

        my $array_name = eval { $N->pve_volname_to_array('ps1', $volname) };
        ok(!defined($array_name),
            "'$shown' does not translate to an array object name");
        like($@, qr/Unrecognized|required/,
            "... and says so rather than dying obscurely ('$shown')");
    }

    # And the shapes PVE really does produce.
    for my $volname (qw(
        vm-100-disk-0 base-100-disk-0 vm-100-cloudinit
        vm-100-state-snap1 vm-100-efidisk0 vm-100-tpmstate0
    )) {
        my $array_name = eval { $N->pve_volname_to_array('ps1', $volname) };
        ok(defined $array_name, "'$volname' translates");
        is($N->is_pve_managed_volume($array_name, 'ps1'), 1,
            "... to something this storage owns ('$volname')");
    }

    # A linked clone translates to the clone half only.
    is($N->pve_volname_to_array('ps1', 'base-100-disk-0/vm-101-disk-0'),
        $N->encode_volume_name('ps1', 101, 0),
        'a linked clone names the clone, not the base');
}

done_testing();
