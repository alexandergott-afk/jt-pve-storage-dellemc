#!/usr/bin/perl
# Fibre Channel WWN handling tests. The sysfs-reading parts need real HBAs
# and belong to the on-hardware matrix; only their safe-when-absent behaviour
# is checked here.
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

use PVE::Storage::Custom::DellEMC::Common::FC qw(
    format_wwn
    parse_wwn
    normalize_wwn
    wwn_equal
    is_fc_available
    get_fc_hosts
    get_fc_wwpns
    get_fc_wwpns_raw
    get_fc_wwnns
    get_fc_targets
    rport_name
    get_fc_host_info
);

# ---------------------------------------------------------------------------
# WWN parsing
#
# The same WWN reaches us in three spellings: sysfs writes '0x5001...', the
# array API returns bare hex, and operators type the colon form. Comparing
# them without normalising is how a host object ends up created twice with
# the same initiator.
# ---------------------------------------------------------------------------

is(parse_wwn('0x5001438032a5b6c7'), '5001438032a5b6c7', 'sysfs 0x form');
is(parse_wwn('5001438032a5b6c7'), '5001438032a5b6c7', 'bare hex');
is(parse_wwn('50:01:43:80:32:a5:b6:c7'), '5001438032a5b6c7', 'colon form');
is(parse_wwn('50-01-43-80-32-a5-b6-c7'), '5001438032a5b6c7', 'dash form');
is(parse_wwn('50 01 43 80 32 a5 b6 c7'), '5001438032a5b6c7', 'space form');
is(parse_wwn('0X5001438032A5B6C7'), '5001438032a5b6c7', 'uppercase normalises');

is(parse_wwn('5001438032a5b6'), undef, 'too short is rejected');
is(parse_wwn('5001438032a5b6c7ff'), undef, 'too long is rejected');
is(parse_wwn('5001438032a5b6cg'), undef, 'non-hex is rejected');
is(parse_wwn(''), undef, 'empty is rejected');
is(parse_wwn(undef), undef, 'undef is rejected');

is(format_wwn('0x5001438032a5b6c7'), '50:01:43:80:32:a5:b6:c7', 'format from sysfs');
is(format_wwn('5001438032a5b6c7'), '50:01:43:80:32:a5:b6:c7', 'format from bare hex');
is(format_wwn('50:01:43:80:32:A5:B6:C7'), '50:01:43:80:32:a5:b6:c7',
    'format is idempotent and lowercases');
is(format_wwn('nonsense'), undef, 'format rejects nonsense');
is(format_wwn(undef), undef, 'format rejects undef');

is(normalize_wwn('50:01:43:80:32:a5:b6:c7'), parse_wwn('0x5001438032a5b6c7'),
    'normalize agrees with parse');

ok(wwn_equal('0x5001438032a5b6c7', '50:01:43:80:32:a5:b6:c7'),
    'the same WWN in two spellings compares equal');
ok(wwn_equal('5001438032A5B6C7', '5001438032a5b6c7'), 'case-insensitive compare');
ok(!wwn_equal('5001438032a5b6c7', '5001438032a5b6c8'), 'different WWNs differ');
ok(!wwn_equal('5001438032a5b6c7', undef), 'undef never equals a WWN');
ok(!wwn_equal(undef, undef), 'two undefs are not equal');
ok(!wwn_equal('garbage', 'garbage'), 'unparseable values are never equal');

# ---------------------------------------------------------------------------
# Absent hardware must be reported, not crashed on. These run on build hosts
# and in CI, where there are no FC HBAs.
# ---------------------------------------------------------------------------

my $available = is_fc_available();
ok(defined $available, 'is_fc_available returns a defined value');
like($available, qr/^[01]$/, 'is_fc_available returns a boolean');

is(ref(get_fc_hosts()), 'ARRAY', 'get_fc_hosts returns an arrayref');
is(ref(get_fc_wwpns()), 'ARRAY', 'get_fc_wwpns returns an arrayref');
is(ref(get_fc_wwpns_raw()), 'ARRAY', 'get_fc_wwpns_raw returns an arrayref');
is(ref(get_fc_wwnns()), 'ARRAY', 'get_fc_wwnns returns an arrayref');
is(ref(get_fc_targets()), 'ARRAY', 'get_fc_targets returns an arrayref');

# ---------------------------------------------------------------------------
# The kernel's own name for a remote port
#
# 'rport-<host>:<channel>-<remote>' — a COLON after the host number. This
# filter once asked for three hyphen-separated numbers, which matches no entry
# the kernel has ever created, so get_fc_targets always came back empty and
# every FC node was told on every poll that no targets were visible. Reported
# from an ME4024 whose fabric was fine.
#
# The names below are the shapes /sys/class/fc_remote_ports actually holds.
# ---------------------------------------------------------------------------

for my $name (qw(rport-0:0-0 rport-5:0-3 rport-11:0-12 rport-7:0-345)) {
    is(rport_name($name), $name, "'$name' is a remote port");
}

for my $name (qw(rport-5-0-3 rport-5:0 rport rport-a:0-1 rport-5:0-3x
                 . .. fc_remote_ports)) {
    is(rport_name($name), undef, "'$name' is not");
}
is(rport_name(undef), undef, 'and neither is nothing');

# What comes back is what was matched, not what was read: the name is used to
# build a path under /sys.
{
    my $tainted = "rport-5:0-3";
    my $clean = rport_name($tainted);
    is($clean, 'rport-5:0-3', 'the returned name is the matched one');
    unlike($clean, qr{[/.]}, 'and carries nothing that could leave the directory');
}
is(ref(get_fc_host_info()), 'ARRAY', 'get_fc_host_info returns an arrayref');

unless ($available) {
    is_deeply(get_fc_hosts(), [], 'no hosts without FC hardware');
    is_deeply(get_fc_wwpns(), [], 'no WWPNs without FC hardware');
}

# Whatever the host has, the two WWPN spellings must describe the same ports.
{
    my $formatted = get_fc_wwpns();
    my $raw = get_fc_wwpns_raw();
    is(scalar(@$formatted), scalar(@$raw), 'both WWPN forms list the same ports');
    for my $i (0 .. $#$formatted) {
        ok(wwn_equal($formatted->[$i], $raw->[$i]), "WWPN $i agrees across forms");
    }
}

done_testing();
