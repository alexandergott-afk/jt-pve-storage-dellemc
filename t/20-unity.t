#!/usr/bin/perl
# Unity XT naming.
#
# What this file protects is the part that can be checked without an array at
# all: that the ownership gate holds, and that the name limit is read from the
# subclass rather than resolved in the parent package.
#
# That second one is not hypothetical. PowerFlex inherited PowerVault's naming
# and enforced PowerVault's 31-character limit, because the inherited methods
# read a `use constant` that Perl resolved at compile time in the parent. The
# family limits are plain methods for that reason, and this asserts it for
# Unity before any code depends on it.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;
use HTTP::Response;
use HTTP::Headers;
use JSON;

BEGIN {
    eval { require LWP::UserAgent; require JSON; require URI; 1 }
        or plan skip_all => 'libwww-perl, libjson-perl or liburi-perl is missing';
}

use PVE::Storage::Custom::DellEMC::Unity::API;
use PVE::Storage::Custom::DellEMC::Unity::Naming;
use PVE::Storage::Custom::DellEMC::PowerVault::Naming;

my $U = 'PVE::Storage::Custom::DellEMC::Unity::Naming';
my $V = 'PVE::Storage::Custom::DellEMC::PowerVault::Naming';
my $A = 'PVE::Storage::Custom::DellEMC::Unity::API';

# ---------------------------------------------------------------------------
# A fake Unity
# ---------------------------------------------------------------------------

{
    package FakeUnity;

    sub new {
        my ($class, %args) = @_;
        return bless { timeout => 15, requests => [],
                       handler => $args{handler} }, $class;
    }
    sub timeout { my ($s, $v) = @_; $s->{timeout} = $v if defined $v; return $s->{timeout} }
    sub default_header { return }
    sub cookie_jar { return }
    sub request {
        my ($self, $req) = @_;
        push @{ $self->{requests} }, $req;
        return $self->{handler}->($req, $req->uri->path, $self);
    }
    sub requests     { return $_[0]{requests} }
    sub last_request { return $_[0]{requests}[-1] }
    sub writes {
        return [ grep { $_->method ne 'GET' } @{ $_[0]{requests} } ];
    }
}

sub reply {
    my ($body, $code) = @_;
    my $h = HTTP::Headers->new('Content-Type'   => 'application/json',
                               'EMC-CSRF-TOKEN' => 'csrf-token-here');
    return HTTP::Response->new($code // 200, undef, $h, encode_json($body));
}

sub entries { return { entries => [ map { { content => $_ } } @_ ] } }
sub content { return { content => $_[0] } }

sub make_api {
    my (%args) = @_;
    my $inner = delete $args{handler};

    my $ua = FakeUnity->new(handler => sub {
        my ($req, $path, $self) = @_;
        return $inner->($req, $path, $self) if $inner;
        return reply(content({}));
    });

    my $api = $A->new(
        portal => '10.0.0.9', username => 'admin', password => 'secret',
        storeid => 'u480', type => 'dellunity', ua => $ua, %args,
    );

    return ($api, $ua);
}

sub body_of {
    my ($req) = @_;
    return {} unless $req && length($req->content // '');
    return decode_json($req->content);
}

# ---------------------------------------------------------------------------
# The limit belongs to this class
# ---------------------------------------------------------------------------

# 63 comes from Dell's own gounity client, which refuses a longer name before
# it reaches the array. An earlier draft of this file said 85, read off a
# Unisphere documentation page; the number that matters is the one Dell's own
# code enforces.
is($U->max_volume_name_length, 63, "Dell's own client enforces 63");
isnt($U->max_volume_name_length, $V->max_volume_name_length,
    '... which is not the limit another family happens to have');

ok($U->isa('PVE::Storage::Custom::DellEMC::Common::Naming'),
    'the shared naming is inherited, not reimplemented');

# ---------------------------------------------------------------------------
# Generated names
# ---------------------------------------------------------------------------

my $vol = $U->encode_volume_name('u480', 100, 0);
is($vol, 'pve-u480-100-disk0', 'a volume name carries the storage it belongs to');

is($U->encode_snapshot_name($vol, 'before'), "$vol.pve-snap-before",
    'a snapshot hangs off the volume name');
is($U->encode_base_snapshot_name($vol), "$vol.pve-base",
    'the template marker is its own suffix');
is($U->encode_host_name('u480', 'pve1'), 'pve-u480-pve1',
    'a host object names the storage and the node');

# Unity accepts '.' in a name, but this plugin's own naming uses it as the
# separator before a snapshot suffix. A generated name that contained one
# would decode as a snapshot of a volume that does not exist.
unlike($vol, qr/\./, 'a generated volume name carries no dot of its own');

for my $name ($U->encode_cloudinit_name('u480', 100),
              $U->encode_efidisk_name('u480', 100, 0),
              $U->encode_tpmstate_name('u480', 100, 1)) {
    cmp_ok(length($name), '<=', $U->max_volume_name_length,
        "'$name' fits the array's limit");
    unlike($name, qr/\./, "'$name' carries no dot either");
}

# ---------------------------------------------------------------------------
# The ownership gate
#
# This is what stands between the plugin and deleting somebody's production
# LUN. The two-argument form with the storeid is the only one that authorises
# anything: the one-argument form proves only that a name looks like some PVE
# plugin's, which does not make it this storage's to delete.
# ---------------------------------------------------------------------------

ok($U->is_pve_managed_volume($vol, 'u480'),
    'a volume this storage created is its own');
ok($U->is_pve_managed_volume($U->encode_snapshot_name($vol, 'x'), 'u480'),
    '... and so is a snapshot of it');
ok($U->is_pve_managed_volume($U->encode_base_snapshot_name($vol), 'u480'),
    '... and its template marker');

ok(!$U->is_pve_managed_volume($vol, 'somewhere-else'),
    "another storage's volume is not this one's to touch");

for my $foreign ('Finance-DB-LUN', 'lun_0', 'pve', 'pve-', '',
                 'pve-u480', 'PVE-U480-100-disk0') {
    ok(!$U->is_pve_managed_volume($foreign, 'u480'),
        "'$foreign' is not a volume this storage manages");
}

# A name that merely starts with the prefix is not proof of anything: the
# prefix identifies the STORAGE, never the kind of object. This has been a
# real defect here before, in the temporary-clone reaper.
ok(!$U->is_pve_managed_volume('pve-u480-not-a-real-name', 'u480'),
    'the prefix alone does not make something ours');

# ---------------------------------------------------------------------------
# A name the array would alter
# ---------------------------------------------------------------------------

{
    # PVE allows a 40-character snapshot name and a whole Unity name is 63, so
    # a long one has to be shortened. When that happens the VOLUME half must
    # still be exact — an approximate volume name points at the wrong object,
    # and only the snapshot half may ever be a prefix.
    my $long = 'a' x 40;   # PVE's own maximum for a snapshot name
    my $snap = eval { $U->encode_snapshot_name($vol, $long) };
    ok(defined $snap, 'a 40-character snapshot name is accepted') or diag($@);
    like($snap, qr/^\Q$vol\E\./, '... with the volume half exact');
    cmp_ok(length($snap), '<=', $U->max_snapshot_name_length,
        '... and the whole thing within the limit');
}

# ---------------------------------------------------------------------------
# Every request says it is an API client
#
# Without 'X-EMC-REST-CLIENT: true' Unity answers with its web UI instead of
# JSON, which decodes as "not JSON" and reads like the wrong host entirely.
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(entries({ id => 'pool_1', name => 'A',
                               sizeTotal => 1000, sizeFree => 400 }))
            if $path =~ m{/types/pool/instances};
        return reply(entries({ id => '0', name => 'unity480' }));
    });

    $api->pool_list();

    ok(scalar(@{ $ua->requests }), 'a request was made');
    for my $req (@{ $ua->requests }) {
        is($req->header('X-EMC-REST-CLIENT'), 'true',
            $req->method . ' ' . $req->uri->path . ' identifies itself as an API client');
    }

    like($ua->last_request->uri->query, qr/fields=/,
        'and asks for fields explicitly, because Unity returns almost nothing without them');
}

# ---------------------------------------------------------------------------
# Paging is driven by the array's own count, not by a short page
#
# 'with_entrycount=true' makes a collection report entryCount: the number of
# instances in the COMPLETE list. Stopping on a short page instead is a guess
# - the array is free to return fewer rows than asked for - and a silently
# truncated listing is how the orphan reaper comes to treat live volumes as
# deleted.
# ---------------------------------------------------------------------------

{
    my @pages;
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(entries({ id => '0' })) unless $path =~ m{/types/lun/instances};

        my %q = $req->uri->query_form;
        push @pages, $q{page};

        # Three rows in total, handed out one page at a time and always
        # SHORTER than the page size asked for. A client that stopped on a
        # short page would see one row and call it the whole collection.
        my @all = map { { id => "sv_$_", name => "vol$_" } } (1 .. 3);
        my $i = ($q{page} // 1) - 1;
        my @batch = defined $all[$i] ? ($all[$i]) : ();

        return reply({ entryCount => 3, %{ entries(@batch) } });
    });

    my $rows = $api->volume_list();
    is(scalar(@$rows), 3, 'every row arrives, though each page was short');
    is_deeply([map { $_->{name} } @$rows], ['vol1','vol2','vol3'], '... in order');
    is_deeply(\@pages, [1, 2, 3], 'and the pages were walked one at a time');

    like($ua->last_request->uri->query, qr/with_entrycount=true/,
        'the count is asked for, or the array reports none at all');
}

{
    # No entryCount - an older firmware, or a collection that does not carry
    # one. The short-page rule is the fallback, not the primary.
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(entries({ id => '0' })) unless $path =~ m{/types/lun/instances};
        my %q = $req->uri->query_form;
        return reply(entries()) if ($q{page} // 1) > 1;
        return reply(entries({ id => 'sv_1', name => 'only' }));
    });

    my $rows = $api->volume_list();
    is(scalar(@$rows), 1, 'without a count, a short page still ends the listing');
}

{
    # An empty page ends it whatever the count claims. A count that never
    # arrives would otherwise spin to MAX_PAGES.
    my $requests = 0;
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(entries({ id => '0' })) unless $path =~ m{/types/lun/instances};
        $requests++;
        return reply({ entryCount => 9999, %{ entries() } });
    });

    is_deeply($api->volume_list(), [], 'an empty first page is an empty collection');
    is($requests, 1, '... asked for exactly once, not until the count is met');
}

# ---------------------------------------------------------------------------
# 302 is an authorization error here, not a redirect
#
# Dell documents it as "authorization error or timeout when the
# X-EMC-REST-CLIENT header field is missing or not set to true". Following it
# would fetch the array's web UI and hand back HTML, and this client would
# then report "the body is not JSON" - naming the symptom and hiding the
# cause.
# ---------------------------------------------------------------------------

{
    my ($api) = make_api();
    my $hint = $api->error_hint(302, {});
    like($hint, qr/AUTHORIZATION error, not a redirect/,
        'a 302 is explained as what it is on this API');
    like($hint, qr/X-EMC-REST-CLIENT/, '... and names the header that did not arrive');

    like($api->error_hint(401, {}), qr/credentials/,
        'a 401 is the credentials, because the header did arrive');
    like($api->error_hint(403, {}), qr/EMC-CSRF-TOKEN/, 'a 403 is the CSRF token');
    is($api->error_hint(200, {}), '', 'and a success is not explained');
}

{
    my ($api, $ua) = make_api();
    my $inner = $api->ua;
    is($inner->max_redirect, 0, 'the user agent never follows a redirect')
        if $inner && $inner->can('max_redirect');
}

# ---------------------------------------------------------------------------
# The array's own error code
#
# errorCode is a number and the stable thing to key on; the messages beside it
# are localised into nine languages and are for a human to read.
# ---------------------------------------------------------------------------

{
    my ($api) = make_api();

    is($api->error_code_of({ error => { errorCode => 131149829,
        httpStatusCode => 404,
        messages => [ { 'en-US' => 'The requested resource does not exist.' } ] } }),
        131149829, 'the numeric code is read out of the error body');

    is($api->error_code_of({ error => { messages => ['x'] } }), undef,
        'an error without a code yields undef, not a guess');
    is($api->error_code_of({}), undef, 'and neither does a body with no error');
    is($api->error_code_of(undef), undef, 'nor nothing at all');
}

# ---------------------------------------------------------------------------
# Capacity is bytes, not blocks
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(entries(
            { id => 'pool_1', name => 'A', sizeTotal => 4000, sizeFree => 3000 },
            { id => 'pool_2', name => 'B', sizeTotal => 1000, sizeFree =>  100 },
        )) if $path =~ m{/types/pool/instances};
        return reply(entries({ id => '0' }));
    });

    my ($total, $used, $avail) = $api->get_managed_capacity();
    is($total, 5000, 'both pools are summed, in bytes');
    is($avail, 3100, 'sizeFree is what is available');
    is($used,  1900, 'used is the remainder');

    ($total, undef, $avail) = $api->get_managed_capacity(pool => 'B');
    is($total, 1000, 'one pool can be selected');
    isnt($avail, 0, 'and a pool with room does not read as full');

    ok(!eval { $api->get_managed_capacity(pool => 'nosuch'); 1 },
        'an unknown pool is an error, not silently the whole array');
    like($@, qr/A, B/, '... and it lists the ones that exist');
}

# ---------------------------------------------------------------------------
# A volume is looked up BY NAME, not by a filter
#
# Every other family here has to ask with a server-side filter, and an
# unverified filter that returns nothing is indistinguishable from "there is
# nothing there" - that is what hid every PowerStore volume once. Unity
# answers the question directly, so this asserts the question is asked
# directly.
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(content({ id => 'sv_1', name => 'pve-u480-100-disk0',
                               wwn => '60:06:01:60:12:34:56:78:9A:BC:DE:F0:11:22:33:44' }))
            if $path =~ m{/instances/lun/name:};
        return reply(content({}));
    });

    my $lun = $api->volume_get_by_name('pve-u480-100-disk0');
    ok($lun, 'the volume is found');
    is($lun->{id}, 'sv_1', '... and it is the right object');

    like($ua->last_request->uri->path, qr{/instances/lun/name:pve-u480-100-disk0\z},
        'the lookup uses the by-name URI');
    unlike($ua->last_request->uri->query // '', qr/filter=/,
        '... and never a filter, whose empty answer would mean two things');
}

# ---------------------------------------------------------------------------
# A missing volume is absent; an unreachable array is not
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ error => { messages => ['not found'] } }, 404)
            if $path =~ m{/instances/lun/name:};
        return reply(content({}));
    });

    is($api->volume_get_by_name('pve-u480-999-disk0'), undef,
        'a 404 means the volume is absent');
}

{
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ error => { messages => ['boom'] } }, 500)
            if $path =~ m{/instances/lun/name:};
        return reply(content({}));
    }, retries => 0);

    ok(!eval { $api->volume_get_by_name('pve-u480-100-disk0'); 1 },
        'an array that could not answer is NOT reported as "absent"');
}

# ---------------------------------------------------------------------------
# Creating a volume
# ---------------------------------------------------------------------------

{
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(content({ id => 'pool_1', name => 'A',
                               sizeTotal => 10**12, sizeFree => 10**12 }))
            if $path =~ m{/instances/pool/name:};
        return reply(content({ storageResource => { id => 'sv_7' } }))
            if $path =~ m{/types/storageResource/action/createLun};
        return reply(content({}));
    });

    my $id = $api->volume_create('pve-u480-100-disk0', 4 * 1024**3, pool => 'A');
    is($id, 'sv_7', 'the new volume id comes back');

    my ($create) = grep { $_->uri->path =~ m{action/createLun} } @{ $ua->requests };
    my $body = body_of($create);

    is($body->{name}, 'pve-u480-100-disk0', 'the name is sent');
    ok($body->{lunParameters}{storagePool}{id},
        "the pool is sent as 'storagePool', which is the key a create takes");
    ok(!exists $body->{lunParameters}{pool},
        "... and never as 'pool', which is only what a LUN reports back");
    is($body->{lunParameters}{size}, 4 * 1024**3, 'the size is in bytes');
    is($body->{lunParameters}{isThinEnabled}, 'true',
        'isThinEnabled is a string, as Dell\'s own client sends it');
}

{
    # An emulator answers createLun with 204 and no body, and a real array
    # under some firmware may do the same or answer with a job. Returning
    # undef would be the worst of both: the volume exists and the caller has
    # no handle to it, so the next thing it does is create a second one.
    my $created = 0;
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(content({ id => 'pool_1', name => 'A',
                               sizeTotal => 10**12, sizeFree => 10**12 }))
            if $path =~ m{/instances/pool/name:};
        if ($path =~ m{action/createLun}) { $created = 1; return reply({}, 204) }
        return reply(content({ id => 'sv_9', name => 'pve-u480-100-disk0' }))
            if $created && $path =~ m{/instances/lun/name:};
        return reply(content({}));
    });

    my $id = $api->volume_create('pve-u480-100-disk0', 4 * 1024**3, pool => 'A');
    is($id, 'sv_9', 'a create that returns no id is resolved by looking the name up');
}

{
    # And when even that cannot answer, it dies rather than handing back
    # undef - the volume may exist, and a silent undef is how a second one
    # gets created on top of it.
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(content({ id => 'pool_1', name => 'A',
                               sizeTotal => 10**12, sizeFree => 10**12 }))
            if $path =~ m{/instances/pool/name:};
        return reply({}, 204) if $path =~ m{action/createLun};
        return reply({ error => { messages => ['not found'] } }, 404)
            if $path =~ m{/instances/lun/name:};
        return reply(content({}));
    });

    ok(!eval { $api->volume_create('pve-u480-100-disk0', 4 * 1024**3, pool => 'A'); 1 },
        'a create whose result cannot be established is an error, not undef');
    like($@, qr/may exist/, '... and says the volume may be there');
}

{
    # Fields are opt-in on this API, so a pool that comes back as an empty
    # shell looks exactly like one that was found. Sending the create anyway
    # would put a null where the pool goes, and the array's refusal would not
    # say which of the two happened.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(content({}))  if $path =~ m{/instances/pool/name:};
        return reply(content({}));
    });

    ok(!eval { $api->volume_create('pve-u480-100-disk0', 4 * 1024**3, pool => 'A'); 1 },
        'a pool row with no id is refused rather than sent as null');
    like($@, qr/no id/, '... and says what happened');
    is_deeply($ua->writes, [], '... without creating anything');
}

{
    # A size the array cannot allocate exactly is rounded UP. Rounding down
    # gives a volume smaller than PVE asked for, which fills and then fails.
    my ($api) = make_api();

    is($A->align_size(1), 8 * 1024, 'a byte becomes one allocation unit');
    is($A->align_size(8 * 1024), 8 * 1024, 'an exact multiple is left alone');
    is($A->align_size(8 * 1024 + 1), 16 * 1024, 'anything over rounds up');
    is($A->align_size(4 * 1024**3), 4 * 1024**3, 'a whole number of GiB is already aligned');
}

# ---------------------------------------------------------------------------
# The WWID the kernel will know the device by
# ---------------------------------------------------------------------------

is($A->wwn_to_wwid('60:06:01:60:12:34:56:78:9A:BC:DE:F0:11:22:33:44'),
    '360060160123456789abcdef011223344',
    "a Unity wwn becomes '3' plus the bare hex, lower case");
is($A->wwn_to_wwid('60060160123456789ABCDEF011223344'),
    '360060160123456789abcdef011223344',
    '... whether or not the array separated it');
is($A->wwn_to_wwid('60:06:01'), undef, 'a short wwn is refused, not padded');
is($A->wwn_to_wwid(undef), undef, 'and nothing stays nothing');
is($A->wwn_to_wwid({ id => 'x' }), undef, 'a structure where a string was expected is refused');

# ---------------------------------------------------------------------------
# Mapping: the dangerous one
#
# hostAccess REPLACES the list rather than adding to it. Sending only this
# node's host would unmap the volume from every other node in the cluster,
# and a guest on one of them is then writing to a device that has gone.
# Dell's own client shipping both ExportVolume (one host) and
# ModifyVolumeExport (a list) is the tell.
# ---------------------------------------------------------------------------

sub mapping_api {
    my (@host_ids) = @_;

    my $ua;
    my $api;
    ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(content({
            id          => 'sv_1',
            name        => 'pve-u480-100-disk0',
            hostAccess  => [ map { { host => { id => $_ }, accessMask => '1' } } @host_ids ],
        })) if $path =~ m{/instances/lun/name:};
        return reply(content({}));
    });

    return ($api, $ua);
}

{
    # Two other nodes already hold it. Attaching this one must keep them.
    my ($api, $ua) = mapping_api('Host_1', 'Host_2');

    $api->volume_attach('pve-u480-100-disk0', 'Host_9');

    my ($write) = @{ $ua->writes };
    ok($write, 'a write was made');
    like($write->uri->path, qr{/instances/storageResource/sv_1/action/modifyLun\z},
        'through modifyLun on the storageResource');

    my $sent = body_of($write)->{lunHostAccessParameters}{hostAccess};
    is(ref($sent), 'ARRAY', 'hostAccess is a list');

    my @ids = sort map { $_->{host}{id} } @$sent;
    is_deeply(\@ids, ['Host_1', 'Host_2', 'Host_9'],
        'the list sent is the UNION - the other two nodes keep their access');

    is($sent->[0]{accessMask}, '1',
        "accessMask is the string '1', which is production access");
}

{
    # Already mapped: nothing is written at all. A rewrite that happens to
    # produce the same list is still a window in which it could not.
    my ($api, $ua) = mapping_api('Host_1', 'Host_9');

    $api->volume_attach('pve-u480-100-disk0', 'Host_9');

    is_deeply($ua->writes, [], 'a host that already has access is left alone');
    ok($api->is_mapped_to('pve-u480-100-disk0', 'Host_9'), '... and reports as mapped');
    ok(!$api->is_mapped_to('pve-u480-100-disk0', 'Host_5'), 'a host without access does not');
}

{
    # Detaching removes ONE host and leaves the rest.
    my ($api, $ua) = mapping_api('Host_1', 'Host_2', 'Host_9');

    $api->volume_detach('pve-u480-100-disk0', 'Host_9');

    my ($write) = @{ $ua->writes };
    my $sent = body_of($write)->{lunHostAccessParameters}{hostAccess};
    my @ids = sort map { $_->{host}{id} } @$sent;

    is_deeply(\@ids, ['Host_1', 'Host_2'],
        'the other nodes keep their access when this one gives it up');
    ok(scalar(@ids), 'and the list is not emptied, which would unmap everyone');
}

{
    # The last host giving it up empties the list, which is correct - and is
    # also how Unity expresses "unmapped", since it has no unexport call.
    my ($api, $ua) = mapping_api('Host_9');

    $api->volume_detach('pve-u480-100-disk0', 'Host_9');

    my $sent = body_of(${ $ua->writes }[0])->{lunHostAccessParameters}{hostAccess};
    is_deeply($sent, [], 'the last host leaving empties the list');
}

{
    # A host that does not hold it: nothing is written.
    my ($api, $ua) = mapping_api('Host_1');

    $api->volume_detach('pve-u480-100-disk0', 'Host_9');
    is_deeply($ua->writes, [], 'detaching a host that never had access writes nothing');
}

{
    # A volume that is not there cannot be unmapped from, and that is not a
    # failure. An array that could not be REACHED is a different thing, and
    # volume_get_by_name dies rather than arriving here.
    my ($api, $ua) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ error => { messages => ['not found'] } }, 404)
            if $path =~ m{/instances/lun/name:};
        return reply(content({}));
    });

    ok($api->volume_detach('pve-u480-999-disk0', 'Host_9'),
        'unmapping an absent volume succeeds');
    is_deeply($ua->writes, [], '... without writing anything');
}

{
    # Attaching to a volume that is not there must NOT quietly succeed: PVE
    # would then start a guest against a device that never appears.
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply({ error => { messages => ['not found'] } }, 404)
            if $path =~ m{/instances/lun/name:};
        return reply(content({}));
    });

    ok(!eval { $api->volume_attach('pve-u480-999-disk0', 'Host_9'); 1 },
        'mapping a volume that is not on the array is refused');
    like($@, qr/not on the array/, '... and says so');
}

{
    my ($api) = mapping_api('Host_1');

    ok(!eval { $api->volume_attach('pve-u480-100-disk0', ''); 1 },
        'an empty host id is refused rather than sent');
    ok(!eval { $api->volume_detach('pve-u480-100-disk0', undef); 1 },
        '... in both directions');
}

# ---------------------------------------------------------------------------
# A malformed answer returns nothing rather than something of the wrong kind
# ---------------------------------------------------------------------------

{
    my ($api) = make_api(handler => sub { return reply({ entries => 'nonsense' }) });
    is_deeply($api->pool_list(), [], 'entries that are not a list yield no rows');
}

{
    my ($api) = make_api(handler => sub { return reply({ entries => [ 'a', { }, { content => 'b' } ] }) });
    is_deeply($api->volume_list(), [], 'entries without a content hash are skipped');
}

{
    my ($api) = make_api(handler => sub {
        my ($req, $path) = @_;
        return reply(content({ id => 'sv_1', hostAccess => 'not-a-list' }))
            if $path =~ m{/instances/lun/name:};
        return reply(content({}));
    });
    is_deeply($api->volume_mapped_hosts('pve-u480-100-disk0'), [],
        'a hostAccess that is not a list reads as no hosts, not as a crash');
}

done_testing();
