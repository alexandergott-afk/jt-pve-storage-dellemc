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

done_testing();
