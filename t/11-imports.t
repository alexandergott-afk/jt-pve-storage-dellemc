#!/usr/bin/perl
# Helpers must be imported, not merely called.
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

done_testing();
