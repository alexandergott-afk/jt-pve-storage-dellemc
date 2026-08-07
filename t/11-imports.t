#!/usr/bin/perl
# Source rules that nothing else enforces.
#
# Two of them, both about things Perl accepts happily and an operator pays for
# later: a helper called without its `use` line, and a die whose message does
# not end at a newline.
#
# `perl -c` compiles a call to an undefined subroutine without a word of
# complaint, so a helper used without its `use` line only fails at runtime —
# and on this plugin the runtime path in question is the one that needs an
# array, which is exactly where it cannot be exercised here. One such slip
# (decode_json in PowerStore/API.pm, added while fixing collection paging)
# reached a commit and was found by hand. This makes it fail in the suite.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use File::Find;

# helper => the module that has to be imported for it
my %NEEDS = (
    decode_json   => 'JSON',
    encode_json   => 'JSON',
    sha256_hex    => 'Digest::SHA',
    uri_escape    => 'URI::Escape',
    encode_base64 => 'MIME::Base64',
    decode_base64 => 'MIME::Base64',
    make_path     => 'File::Path',
    basename      => 'File::Basename',
    dirname       => 'File::Basename',
    croak         => 'Carp',
    confess       => 'Carp',
    gensym        => 'Symbol',
    open3         => 'IPC::Open3',
    timegm        => 'Time::Local',
    timelocal     => 'Time::Local',
);

my @files;
find(sub { push @files, $File::Find::name if /\.pm$/ }, 'lib');
push @files, 'bin/pve-dell-config-get' if -f 'bin/pve-dell-config-get';

plan skip_all => 'no sources found' unless @files;

for my $file (sort @files) {
    open(my $fh, '<', $file) or do {
        fail("cannot read $file");
        next;
    };
    my $source = do { local $/; <$fh> };
    close($fh);

    # Documentation after __END__ is prose, not code.
    $source =~ s/^__END__.*//ms;

    my @missing;
    for my $sub (sort keys %NEEDS) {
        my $module = $NEEDS{$sub};

        # A call, not a definition, a method, or a mention in a comment.
        next unless $source =~ /(?<![\w:>])\Q$sub\E\s*\(/;
        next if $source =~ /^\s*sub\s+\Q$sub\E\b/m;

        # Fully qualified is fine; so is any use of the right module, whether
        # it imports a list or takes the default exports.
        next if $source =~ /\Q$module\E::\Q$sub\E\s*\(/;
        next if $source =~ /^\s*use\s+\Q$module\E\b/m;

        push @missing, "$sub() needs 'use $module'";
    }

    is_deeply(\@missing, [], "$file imports every helper it calls")
        or diag(join("\n  ", @missing));
}

# ---------------------------------------------------------------------------
# An operator-facing die must end at a newline
#
# Without one, Perl appends " at /usr/share/perl5/PVE/Storage/Custom/... line
# 1234." to the message. In a PVE task log that is noise in front of the
# person trying to work out what to do, and it leaks a path they cannot act
# on. Messages raised inside a forked helper are exempt: the parent reports,
# the child's text never reaches anyone.
# ---------------------------------------------------------------------------

for my $file (sort @files) {
    open(my $fh, '<', $file) or next;
    my $source = do { local $/; <$fh> };
    close($fh);

    $source =~ s/^__END__.*//ms;

    my @bare;
    while ($source =~ /die\s+((?:"(?:[^"\\]|\\.)*"\s*\.?\s*)+);/g) {
        my $statement = $1;

        next if $statement =~ /\\n"\s*\z/;          # ends at a newline
        next if $statement =~ /\A"\w+: \$!"\z/;      # 'open: $!' inside a child

        (my $shown = $statement) =~ s/\s+/ /g;
        push @bare, substr($shown, 0, 60);
    }

    is_deeply(\@bare, [], "$file: every die message ends at a newline")
        or diag(join("\n  ", '', @bare));

    # Deciding what an array meant by reading the words it chose.
    #
    # Twice now this has shipped a defect that only shows up on a real array:
    # a 422 hint this plugin appends contains "clones", and 'add
    # host-members' contains "member". Reading /not found/ out of an error is
    # the same mistake pointed at existence — an array saying "storage pool
    # not found" would be taken to mean the VOLUME is absent, and the caller
    # then creates a second one.
    #
    # Use the status code (REST: allow_status, get_or_undef) or ask a
    # question that answers itself, such as listing and looking.
    my @prose;
    while ($source =~ /^(.*\$\@\s*=~.*)$/mg) {
        my $line = $1;
        next if $line =~ m{^\s*#};
        # A tolerated duplicate on a write is a different thing: it says the
        # state is already what was asked for, and that is what 'tolerate' is
        # declared for at the call site.
        next if $line =~ /already|exists|duplicate|in use/i;
        push @prose, $line =~ s/^\s+|\s+$//gr;
    }

    is_deeply(\@prose, [],
        "$file: no decision is made by matching an array's error text")
        or diag(join("\n  ", '', @prose));
}

# A subroutine defined twice in one file.
#
# Perl takes the last definition and warns "Subroutine ... redefined" — on
# every load, which for a storage plugin is every pvesm call. Worse, the
# earlier definition becomes dead code that still reads like the live one, so
# the next person to edit it edits the wrong copy. This shipped once, when a
# helper was added without noticing the module already had one by that name.
for my $file (sort @files) {
    open(my $fh, '<', $file) or next;
    my $source = do { local $/; <$fh> };
    close($fh);

    $source =~ s/^__END__.*//ms;

    my %seen;
    my @duplicates;
    while ($source =~ /^sub\s+(\w+)\s*\{/mg) {
        my $name = $1;
        push @duplicates, $name if $seen{$name}++ == 1;
    }

    is_deeply(\@duplicates, [], "$file: no subroutine is defined twice")
        or diag('Perl keeps the LAST one and warns on every load; the first'
              . " becomes dead code that still looks live: @duplicates");
}

# is_device_in_use returns 1 / 0 / undef, and undef means "the checks could
# not prove anything". Writing it as a bare boolean throws that away:
#
#     if (is_device_in_use($d)) { refuse }        # undef falls through
#
# On a destructive path that reads as "nothing is using it", which is how a
# volume gets unmapped and deleted under a running VM. Every call has to
# either check defined() or be somewhere a wrong "no" is harmless — and the
# harmless ones say so at the call site.
for my $file (sort @files) {
    open(my $fh, '<', $file) or next;
    my $source = do { local $/; <$fh> };
    close($fh);

    $source =~ s/^__END__.*//ms;
    next unless $source =~ /is_device_in_use\s*\(/;

    my @bare;
    my @lines = split /\n/, $source;
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*(?:sub|our|use)\s/;
        next unless $line =~ /is_device_in_use\s*\(/;

        # Assigned to a variable: the caller can then check defined().
        next if $line =~ /=\s*(?:eval\s*\{\s*)?is_device_in_use/;

        # A nearby comment saying the fail-open is deliberate.
        # Wide enough for the comment block that has to justify it, tight
        # enough that the justification is still at the call site.
        my $from = $i - 14 < 0 ? 0 : $i - 14;
        my $context = join "\n", @lines[$from .. $i];
        next if $context =~ /harmless|deliberate|best-effort|only decides/i;

        push @bare, ($i + 1) . ": " . ($line =~ s/^\s+//r);
    }

    is_deeply(\@bare, [],
        "$file: is_device_in_use is never used as a bare boolean")
        or diag(join("\n  ", '',
            'undef means "could not tell" and reads as false here:', @bare));
}

# ---------------------------------------------------------------------------
# A family's _array_* signature must fit the way BlockBase actually calls it
#
# Perl checks none of this. A subclass that inserts one parameter shifts
# every argument after it - the volume name lands in a slot nothing reads,
# $name stays undef, and the failure is silent because the method still
# runs. That shipped once: Unity's _array_get_wwid took ($scfg, $storeid,
# $name) where BlockBase passes ($scfg, $name), and every WWID lookup
# answered undef - device discovery dead on arrival, invisible to the
# lifecycle tests because they stub the device layer.
#
# Counting arguments cannot catch that bug: three declared covers two
# passed. What catches it is the KIND of name at each position. BlockBase's
# call sites name their arguments meaningfully - $scfg, $storeid, and data
# ($array_name, $snap_name, $prefix...) - so a declaration whose position 2
# says 'storeid' where the call passes a volume name is the shipped bug,
# recognisable by name. The call sites are read out of BlockBase itself,
# never remembered.
# ---------------------------------------------------------------------------

{
    my $base = do {
        open(my $fh, '<', 'lib/PVE/Storage/Custom/DellEMC/Common/BlockBase.pm')
            or die "cannot read BlockBase: $!";
        local $/; <$fh>;
    };

    # scfg and storeid are the structural parameters; everything else is
    # data. An 'undef' placeholder in a call says "data, absent".
    my $kind = sub {
        my ($token) = @_;
        return 'scfg'    if $token =~ /scfg/;
        return 'storeid' if $token =~ /storeid/;
        return 'data';
    };

    # The longest plain-positional call per method, with its argument names.
    my %calls;
    while ($base =~ /\$class->(_array_\w+)\(([^()]*)\)/g) {
        my ($method, $args) = ($1, $2);
        my @args = grep { length } map { s/^\s+|\s+\z//gr } split /,/, $args;
        next if grep { !/^(?:\$\w+(?:->\{'?[\w-]+'?\})?|undef)\z/ } @args;
        $calls{$method} = \@args
            if !exists $calls{$method} || @args > @{ $calls{$method} };
    }

    ok(scalar(keys %calls) >= 15,
        'the call sites were actually found in BlockBase')
        or diag('the extraction regex no longer matches; fix the TEST');

    for my $file (glob('lib/PVE/Storage/Custom/Dell*Plugin.pm')) {
        next if $file =~ /PowerFlex/;   # not a BlockBase subclass

        open(my $fh, '<', $file) or next;
        my $source = do { local $/; <$fh> };
        close($fh);

        my @wrong;
        while ($source =~ /^sub (_array_\w+) \{\n\s*my \(([^)]*)\)/mg) {
            my ($method, $params) = ($1, $2);
            my $call = $calls{$method} // next;

            my @params = grep { !/^\%/ }             # %opts is not positional
                         grep { length }
                         map { s/^\s+|\s+\z//gr } split /,/, $params;
            shift @params if @params && $params[0] eq '$class';

            # Never shorter than the longest call...
            if (@params < @$call) {
                push @wrong, "$method: BlockBase passes " . scalar(@$call)
                    . " positional argument(s), the declaration takes only "
                    . scalar(@params);
                next;
            }

            # ...and at every position the caller fills, the same KIND of
            # thing. 'storeid' where the caller sends a name is the shipped
            # bug; extra TRAILING parameters beyond the call are fine.
            for my $i (0 .. $#$call) {
                my $want = $kind->($call->[$i]);
                my $have = $kind->($params[$i]);
                next if $want eq $have;

                push @wrong, "$method: position " . ($i + 1)
                    . " receives '$call->[$i]' from BlockBase but the"
                    . " declaration names it '$params[$i]'";
            }
        }

        is_deeply(\@wrong, [], "$file: every _array_* signature fits how"
            . " BlockBase calls it")
            or diag(join("\n  ", '', @wrong));
    }
}

# ---------------------------------------------------------------------------
# A declared transfer format has to have a transfer behind it
#
# PVE::Storage::Plugin::volume_export begins "if ($scfg->{path} && ...)" and
# falls through to a die for a storage without a path, which every storage
# here is (rule 24). So a plugin that overrides volume_export_formats to
# advertise 'raw+size' and stops there has not enabled the disk move, the
# `pvesm export` or the remote migration it appears to have enabled: it has
# moved the refusal one call later, into a message that names the format the
# plugin itself had just offered. That is what shipped from the first
# override until 0.7.88, in all four families at once, because the override
# was written from the base class's FORMATS method and LVMPlugin's - which
# implement both halves - were not read to the end.
#
# The pairing is the rule: declare the format, implement the transfer.
# ---------------------------------------------------------------------------

{
    my @plugins;
    find({ no_chdir => 1, wanted => sub {
        push @plugins, $File::Find::name if /\.pm\z/;
    } }, 'lib');

    for my $file (sort @plugins) {
        my $src = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

        next unless $src =~ /^sub \s*volume_(?:ex|im)port_formats\b/m;

        for my $half (qw(volume_export volume_import)) {
            ok($src =~ /^sub \s*\Q$half\E\s*\{/m,
                "$file declares transfer formats, so it implements $half")
                or diag("  $file advertises a transfer format but leaves"
                      . " $half to the base class, which refuses it for a"
                      . " storage with no 'path'");
        }
    }
}

# ---------------------------------------------------------------------------
# A method called on $class has to exist on that class
#
# perl -c compiles $class->_warn_once(...) without a word, and the method is
# looked up at runtime — so a call to something the class does not inherit
# fails only when that line runs. It shipped exactly that way in 0.7.86:
# DellPowerFlexPlugin's _password called _warn_once, which is defined in
# BlockBase, which PowerFlex does not inherit (it is a PVE::Storage::Plugin
# subclass in its own right). Every PowerFlex storage whose password was
# still in storage.cfg — i.e. every one upgraded from before 0.7.86 — died
# with "Can't locate object method" on activate, status and every array call,
# and the code path was the upgrade-compatibility path itself.
#
# The check is static so it runs where PVE is not installed: parse each
# file's package, its `use base`, and the subs it defines, then resolve every
# $class->_private(...) call against that chain. Only underscore-prefixed
# names are checked — those are this project's own, so a miss is a bug rather
# than a method PVE's base class provides.
# ---------------------------------------------------------------------------

{
    my (%pkg_of, %defined, %bases, @sources);
    find({ no_chdir => 1, wanted => sub {
        push @sources, $File::Find::name if /\.pm\z/;
    } }, 'lib');

    for my $file (sort @sources) {
        my $src = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };
        my ($pkg) = $src =~ /^package\s+([\w:]+);/m or next;

        $pkg_of{$file} = $pkg;
        $defined{$pkg} = { map { $_ => 1 } $src =~ /^sub\s+(\w+)/mg };
        $bases{$pkg}   = [ map { split ' ' }
                           $src =~ /^use\s+(?:base|parent)\s+qw\(([^)]*)\)/mg ];
    }

    my $resolves;
    $resolves = sub {
        my ($pkg, $method, $seen) = @_;
        $seen //= {};
        return 0 if $seen->{$pkg}++;
        return 1 if $defined{$pkg} && $defined{$pkg}{$method};
        for my $base (@{ $bases{$pkg} // [] }) {
            return 1 if $resolves->($base, $method, $seen);
        }
        return 0;
    };

    for my $file (sort @sources) {
        my $pkg = $pkg_of{$file} or next;
        my $src = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

        my @missing;
        while ($src =~ /\$(?:class|self|_\[0\])->(_\w+)\s*\(/g) {
            my $method = $1;
            next if $resolves->($pkg, $method);
            my $line = 1 + (substr($src, 0, pos($src)) =~ tr/\n//);
            push @missing, "$method (line $line)";
        }

        is_deeply(\@missing, [],
            "$file: every private method it calls on itself exists on its"
          . " own class or a class it inherits")
            or diag("These resolve at runtime only, and this class does not"
                  . " inherit whatever defines them:\n  "
                  . join("\n  ", @missing));
    }
}

# ---------------------------------------------------------------------------
# A declared option has to be read by something
#
# An option that PVE accepts and no code reads is a silent misconfiguration:
# the operator sets it, `pvesm add` takes it, and the behaviour it names never
# changes. Nothing fails, so nothing gets reported. This is the same shape as
# lesson 41, where a shared option was accepted by a family that could not
# honour it.
#
# The read may be literal ($scfg->{'dell-portal'}) or through BlockBase's
# _opt helper, which prepends 'dell-' to a bare suffix — so both spellings
# count. Checking this statically keeps it in CI.
# ---------------------------------------------------------------------------

{
    my (%declared, %text);
    my @sources;
    find({ no_chdir => 1, wanted => sub {
        push @sources, $File::Find::name if /\.pm\z/;
    } }, 'lib');

    for my $file (sort @sources) {
        my $src = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };
        $text{$file} = $src;

        while ($src =~ /'((?:dell|pstore|pvault|unity|pflex)-[a-z0-9-]+)'\s*=>\s*\{\s*\n\s*description\s*=>/g) {
            $declared{$1} //= $file;
        }
    }

    ok(scalar(keys %declared) > 10, 'the option declarations were found')
        or diag('nothing was parsed, so this test is not testing anything');

    my @dead;
    for my $option (sort keys %declared) {
        my ($suffix) = $option =~ /^(?:dell|pstore|pvault|unity|pflex)-(.*)\z/;

        # A READ, not a mention. The declaration and the options list are
        # exactly two subs, and neither of them reads anything; everywhere
        # else that names the option is a use of it. Matching the name rather
        # than a hash access matters because several options are read through
        # a table — ['pstore-protection-policy' => 'protection_policy_id']
        # and then $scfg->{$option} — which no pattern for '{' . $option
        # would ever find.
        my $read = 0;
        for my $file (sort keys %text) {
            my $src = $text{$file};
            $src =~ s/^sub \s*(?:family_)?(?:properties|options)\s*\{.*?^\}//msg;

            $read = 1 if index($src, "'$option'") >= 0;
            $read = 1 if $src =~ /_opt\(\s*\$\w+(?:\[\d\])?\s*,\s*'\Q$suffix\E'/;
            last if $read;
        }

        push @dead, $option unless $read;
    }

    is_deeply(\@dead, [],
        'every declared option is read by something')
        or diag("These are accepted by pvesm add and change nothing:\n  "
              . join("\n  ", @dead));
}

# ---------------------------------------------------------------------------
# Chinese text uses full-width punctuation
#
# CLAUDE.md has said so from the start, and it is the rule most easily lost
# when writing quickly: a half-width comma between two Chinese characters
# reads as wrong to a Taiwanese reader in the way a missing space between
# English words reads to an English one. 219 of them accumulated across the
# zh-TW changelog, the docs site and the testing document before somebody
# pointed at a screenshot.
#
# Anything inside backticks is left alone: a code span, a path or a command
# keeps the punctuation the machine needs. Both directions are checked — a
# Chinese character before the mark, and a Chinese character after it, which
# is the case that hides behind a code span (`--host-mode`,並且).
# ---------------------------------------------------------------------------

{
    my @docs = grep { -f $_ } (
        glob('*_zh-TW.md'), glob('docs/*_zh-TW.md'), 'docs/index.html',
    );

    ok(scalar(@docs) > 3, 'the Chinese documents were found')
        or diag('nothing was scanned, so this test is not testing anything');

    for my $file (@docs) {
        # DECODED, not bytes. \p{Han} against a UTF-8 byte string matches
        # nothing at all, so the first version of this test passed on every
        # file including one with a half-width comma appended on purpose —
        # lesson 48's bytes-versus-characters, in the test rather than the
        # client.
        my $src = do {
            open my $fh, '<:encoding(UTF-8)', $file or die "$file: $!";
            local $/;
            <$fh>;
        };

        my @bad;
        my $lineno = 0;
        for my $line (split /\n/, $src, -1) {
            $lineno++;
            for my $seg (split /(`[^`]*`)/, $line) {
                next if $seg =~ /\A`.*`\z/s;

                # An HTML entity ends in a semicolon that is markup, not
                # punctuation: '&lt;叢集' is not a half-width mark before a
                # Han character. Blank them out rather than skipping the
                # line, so real marks elsewhere on it are still caught.
                $seg =~ s/&(?:[a-zA-Z][a-zA-Z0-9]{1,9}|\#[0-9]{1,6});/ /g;
                next unless $seg =~ /\p{Han}[,;:!?]|[,;:!?](?=\p{Han})/;
                my ($excerpt) = $seg =~ /(.{0,12}(?:\p{Han}[,;:!?]|[,;:!?]\p{Han}).{0,12})/;
                push @bad, "line $lineno: $excerpt";
            }
        }

        is(scalar(@bad), 0, "$file uses full-width punctuation in Chinese text")
            or diag("  " . join("\n  ", @bad[0 .. ($#bad > 9 ? 9 : $#bad)])
                  . ($#bad > 9 ? "\n  ... and " . ($#bad - 9) . " more" : ''));
    }
}

done_testing();
