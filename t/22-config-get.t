#!/usr/bin/perl
# The recovery tool's credential lookup.
#
# pve-dell-config-get is the thing someone runs when PVE itself will not, so
# it parses storage.cfg by hand rather than going through the storage layer.
# 0.7.86 moved the array password OUT of storage.cfg and into
# /etc/pve/priv/storage/<storeid>.pw, and this tool was not told — for four
# releases it answered "no credentials configured" for every storage that
# followed the new convention, at the moment someone was trying to recover a
# VM configuration.
#
# The script is driven as a real subprocess here, against a temporary tree.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $SCRIPT = 'bin/pve-dell-config-get';
plan skip_all => "$SCRIPT not found" unless -f $SCRIPT;

my $root = tempdir(CLEANUP => 1);
make_path("$root/priv/storage");

# A storage as 0.7.86 and later write it: no password in storage.cfg. The
# portal is a closed port on this host, so the run fails at the array in
# about a second instead of hanging on an unroutable address.
open(my $cfg, '>', "$root/storage.cfg") or die $!;
print {$cfg} <<'CFG';
dir: local
	path /var/lib/vz
	content iso

dellpowerstore: ps-recovery
	dell-portal 127.0.0.1:1
	dell-username pveadmin
	dell-protocol iscsi
	content images
CFG
close($cfg);

sub run_tool {
    my (@args) = @_;
    local $ENV{PVE_DELL_CONFIG_ROOT} = $root;
    my $out = qx{$^X -Ilib $SCRIPT @args 2>&1};
    return $out // '';
}

{
    my $out = run_tool('-l', 'ps-recovery');

    like($out, qr/no credentials configured/,
        'with no password anywhere, the tool says so');
    like($out, qr/\Q$root\E\/priv\/storage/,
        '... and names the place it looked, which is where the plugin puts it');
}

{
    open(my $pw, '>', "$root/priv/storage/ps-recovery.pw") or die $!;
    print {$pw} "the-array-password\n";
    close($pw);
    chmod 0600, "$root/priv/storage/ps-recovery.pw";

    my $out = run_tool('-l', 'ps-recovery');

    unlike($out, qr/no credentials configured/,
        'the password in /etc/pve/priv is found — this is where every storage'
      . ' created on 0.7.86 or later keeps it');
    like($out, qr/127\.0\.0\.1|refused|reach|connect|array/i,
        '... and the run gets as far as the array');
}

{
    # storage.cfg still carrying a password: a storage not yet updated.
    open(my $c2, '>', "$root/storage.cfg") or die $!;
    print {$c2} <<'CFG';
dellpowerstore: ps-legacy
	dell-portal 127.0.0.1:1
	dell-username pveadmin
	dell-password still-in-the-config
	content images
CFG
    close($c2);

    my $out = run_tool('-l', 'ps-legacy');
    unlike($out, qr/no credentials configured/,
        'a storage whose password is still in storage.cfg keeps working');
}

{
    my $out = run_tool('-l', 'no-such-storage');
    like($out, qr/was not found/, 'an unknown storage is named as such');
    like($out, qr/recover mode/, '... with the way out');
}

{
    # dell-host-mode decides which host object on the array this node's
    # volumes are mapped to. The tool read neither the option nor the mode
    # and always built the per-node name; against a storage in shared mode it
    # would then have registered a SECOND host carrying this node's
    # initiators, which on these arrays belong to one host object at a time.
    open(my $c3, '>', "$root/storage.cfg") or die $!;
    print {$c3} <<'CFG';
dellpowerstore: ps-shared
	dell-portal 127.0.0.1:1
	dell-username pveadmin
	dell-password p
	dell-host-mode shared
	dell-cluster-name prod
	content images
CFG
    close($c3);

    my $out = run_tool('-l', 'ps-shared');
    unlike($out, qr/no credentials configured/, 'the shared-mode storage parses');

    like($out, qr/Host object for this node: 'pve-prod-shared' \(shared\)/,
        "dell-host-mode shared is read from storage.cfg and produces the"
      . " SHARED host object — building the per-node name here is how the"
      . " tool would register a second host and move this node's initiator"
      . " off the one every volume is mapped to");

    my $per = run_tool('--host-mode', 'per-node', '-l', 'ps-shared');
    like($per, qr/Host object for this node: 'pve-prod-[^']+' \(per-node\)/,
        '... and the option overrides it for a storage.cfg that is wrong');
    unlike($per, qr/'pve-prod-shared'/,
        '... to something that is not the shared name');

    my $bad = run_tool('--host-mode', 'nonsense', '-l', 'ps-shared');
    like($bad, qr/must be 'per-node' or 'shared'/,
        'a host mode the plugin does not have is refused, not guessed at');
}

done_testing();
