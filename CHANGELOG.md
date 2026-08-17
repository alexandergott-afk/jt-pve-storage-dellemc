# Changelog

All notable changes to this project are documented here.
繁體中文版本：[CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md)

Versioning: the patch number increments per release and runs to .99 before
the minor number moves — 0.7.0, 0.7.1, … 0.7.99, then 0.8.0. Every 0.x
release is a prerelease; 1.0.0 is the on-hardware test pass.

## [0.8.15~beta1] - 2026-08-17

### Fixed
- **The logout was sent without the session key, so the array ended nothing.**
  Every logout since 0.8.9 was a no-op. `_release_request` passes
  `no_auth => 1` — necessary, because `_request` calls `ensure_session` and
  `ensure_session` releases the session it is about to replace, which is a
  loop — but `no_auth` also skips `_auth_headers`, and that is where the
  session key lives. `GET /api/exit` went out with no `sessionKey`; an ME
  answers it happily, ends nothing, and holds the slot until its own idle
  timeout.

  `no_auth` means *do not go and get a session*. It does not mean *this
  request needs no credential*. The logout now carries the credential
  explicitly, for every family.

  This is why 0.8.14 made things worse rather than better, exactly as the
  customer read it: that release stopped a forked child from caching its
  client, which was right, so a poll went from one client to three — and with
  the logout ineffective, from one leaked session per poll to three. Measured
  on their ME4024 at 3.1 seconds per session against 0.8.13's 9.5.

  The fixture in the tests is the reason this survived five releases: it
  counted the logout and answered success without looking at the headers, so
  it confirmed a logout that never worked. It refuses one without a valid key
  now, as the array does.

## [0.8.14~beta1] - 2026-08-17

### Fixed
- **A forked process still leaked its management session.** Measured by a
  customer on an ME4024: one session per `pvestatd` poll, none returned, about
  180 in steady state against the array's ceiling — and at the same rate as
  0.8.8, so none of the session work had reached it.

  0.8.10 stopped caching the client when `PVE::RESTEnvironment->is_worker` is
  true. That flag is set only in `fork_worker`'s child, and it is PVE's label
  for one kind of fork. Any other forked child — `run_fork`, a timeout
  wrapper, a change to how a daemon runs its poll — inherits the parent's
  cache, misses on the process-id check, builds a client, caches it **in the
  child**, and ends with `POSIX::_exit`: no `DESTROY`, no `END`, and the
  session is gone for good.

  The rule is the process now, not PVE's label for it. Only the process that
  loaded the plugin caches a client; anything reached through `fork` builds
  one per call and gives its session back when the call returns. Demonstrated
  by forking three children that each do one call and exit: before, four
  logins and no logouts; after, four and three — the parent keeps its cached
  client, which is what a cache is for.

### Added
- **A dedicated ME account with a short session timeout**, in
  `docs/CONFIGURATION`. An ME can set the session timeout per user (120
  seconds minimum), so the plugin's sessions expire quickly while the
  operator's account keeps the default 1800. A customer measured about 180
  concurrent sessions before and about 16 after. It also makes `show sessions`
  name the source.

  With the trap that goes with it: the ME CLI does not use shell quoting, so
  `password 'secret'` puts the quotes in the password, `'` is a forbidden
  character, and the array answers *Invalid character(s) were entered.* with
  no hint that the quotes are the cause.

- `docs/TROUBLESHOOTING` gains the session-accumulation entry, including the
  one measurement that separates the remaining causes: whether the poll runs
  in a forked child.

## [0.8.13~beta1] - 2026-08-13

### Changed
- **A Related projects section at the foot of the documentation site**, in the
  shape the related synology project uses: a card each for the NetApp, Pure
  Storage and Synology plugins, with what each one talks to. They share the
  host-side layer and the operational rules this plugin inherits, and several
  of the defects fixed here were found by reading their incident records —
  which is worth saying where a reader can act on it.

  The links were a bare list inside Acknowledgments before, where nobody
  looking for a sibling project would think to find them.

## [0.8.12~beta1] - 2026-08-12

### Fixed
- **A snapshot rollback flushed and invalidated whatever the lookup handed
  it.** Every device here is resolved fresh from a WWID on each use — that
  indirection is what lets a volid survive a reboot, a remap and a migration
  — and the lookup has fallbacks: a stale mapper entry, a reused mapping
  index, a link that has not caught up. Where the answer is only read, a wrong
  device is a wrong number. A rollback writes to it: the flush before lands on
  another volume, this one keeps its dirty pages, and they are written back on
  top of the restored snapshot. That is rule 14's failure reached by a
  different road, and it looks like the rollback half worked.

  The rollback now refuses a device the kernel will not confirm, before it
  flushes anything — the same confirmation the config-backup and transfer
  paths have had.

  `deactivate_storage` gets the opposite answer on purpose: it is a loop over
  every volume, and one device that cannot be confirmed is reported and
  skipped rather than taking the rest of the deactivation with it.

## [0.8.11~beta1] - 2026-08-12

### Changed
- **The lines inside a table are visible now.** They were `--border-light`,
  which is the right tone for a divider under a heading — where the eye
  already knows the boundary is there — and the wrong one inside a table,
  where the line is what a reader follows across four family columns to find
  the cell that belongs to theirs. At `#f1f5f9` it was not there to follow.
  Table rules have their own token now, so changing them again is one place.

## [0.8.10~beta1] - 2026-08-12

### Fixed
- **The session release added in 0.8.9 could not run in a PVE worker.**
  Verified on the customer's ME and reported precisely: `GET /api/exit`
  works, and the `END` block never ran.
  `PVE::RESTEnvironment::fork_worker` ends the child with `POSIX::_exit`,
  which skips END blocks, global destruction, and even the flushing of
  buffered output. Nothing at exit can run in a worker — and a worker is what
  runs `qm create`, `qm destroy` and every other task that touches a volume.

  What does run is `DESTROY`, when the client is freed normally, which in a
  worker is the moment the plugin method returns. The only thing keeping the
  client alive past that was the per-process client cache. So a worker is not
  given a cached client any more: it gets one for the call, and the session
  goes back when the call returns, well before the `_exit`. A long-lived
  process — pvestatd — still reuses one client, because there the session is
  reused rather than abandoned.

  `PVE::RESTEnvironment->is_worker` is PVE's own flag for the difference.

## [0.8.9~beta1] - 2026-08-11

### Fixed
- **Management sessions were opened and never given back.** Reported from a
  customer's PowerVault ME, where they accumulate on the array. An ME
  management session occupies one of a small number of slots and lives out its
  idle timeout, and the ME CLI has no command to clear one — `show sessions`
  shows them, nothing removes them — so a session this plugin abandons is a
  slot nobody can recover until the array times it out.

  `_logout` was written for all four families at the start and nothing called
  it. It is called from two places now:

  - **When a process exits.** A pvedaemon worker runs one task and exits, and
    a `pvesm` command is a process per invocation; each of them logged in and
    left the session behind. `DESTROY` cannot do this — at global destruction
    the user agent is already going away — so the release happens in an `END`
    block, which can still speak to the array. Both are guarded on the process
    id: a forked worker inherits the object and must not end its parent's
    session.
  - **When the TTL replaces a session.** Every `_logout` began with *return
    unless the session is valid*, and a session past this plugin's own TTL is
    not valid — so the one that most needed releasing was the one that never
    was. That TTL is a local policy; the array's session is still there.

  `GET /exit` is the ME's own command for it and is NOT 0.8.9~beta1IFIED against
  hardware. `show sessions` on the array is how to see whether it works.

## [0.8.8~beta1] - 2026-08-09

### Fixed
- **A long outage buried the journal.** PVE logs whatever `activate_storage`
  dies with, on every poll — about every ten seconds, per node, for as long as
  the outage lasts. Measured against an unroutable address: 297 characters,
  six times a minute, beside the single throttled OUTAGE line carrying the
  same facts.

  The first failures still carry the array's own answer, because that is the
  diagnosis. Once the outage is on record the line is one sentence naming the
  storage and the address, and pointing at the OUTAGE record for the rest.

### Verified
- **The host-side layer, against real SAN devices.** This node carries four
  NetApp LUNs over iSCSI with live multipath maps — the first time anything
  but a customer's ME4024 has exercised this code against real devices.
  Everything read-only: those maps belong to another storage.

  The property that matters most is the vendor gate, and it holds:
  `list_vendor_multipath_devices` returns nothing here, and neither family's
  vendor pattern matches `NETAPP,LUN C-Mode`. That is what keeps the orphan
  reaper off another vendor's storage, and it had never been checked against a
  foreign device.

  Every device helper answered correctly and within its bound: the size exact
  to the byte, the paths matching `multipath -ll`, the WWID confirmed by the
  kernel and a wrong one refused, all under 0.15s. `probe_portal` against an
  unroutable address returned at exactly its timeout, and `get_fc_targets` on
  a node with no HBA returned empty without erroring.

  The configuration refusals fire as written — protocol per family, prefix
  collision, the password at `/etc/pve/priv/storage/<id>.pw` in mode 0600 with
  nothing in `storage.cfg`, both removed on `pvesm remove` — and an
  unreachable storage goes inactive while every other storage stays active.

## [0.8.7~beta1] - 2026-08-09

### Changed
- **Chinese now says 儲存伺服器 for an array, never 陣列.** The same term the
  related synology project uses, and the one that does not read as a
  programming array on a page that also talks about JSON listings. 463
  occurrences across every Chinese document, checked first for the
  programming sense — there was none. The English keeps *array*: that is what
  Dell calls a PowerStore.

  `t/11-imports.t` keeps it that way. Its first version could not: it matched
  a literal Chinese term against text read through an encoding layer, so the
  pattern was bytes and the content was characters, and 152 assertions passed
  against a file with the forbidden term appended on purpose.

## [0.8.6~beta1] - 2026-08-09

### Fixed
- **Two of the four volume names Proxmox VE builds itself were not
  recognised.** Most names come back from `find_free_diskname`, so the plugin
  chooses them; four do not, and PVE hands those to `alloc_image` already
  named: `cloudinit`, `state-<snapshot>`, `efi-enroll` and `fleece-<n>`. The
  first two were handled from the start. The other two were not, and the
  failure was not a refusal — allocation fell through to "pick a free disk
  id", so the volume would have been created under a name that says it is an
  ordinary VM disk.

  **Fleecing is the one that matters.** `vzdump --fleecing` allocates one
  fleecing image per disk on the fleecing storage, so this goes wrong during a
  backup rather than during a create, and what it leaves behind looks like a
  disk nobody can account for. Both names now round-trip: the array object
  carries the name PVE gave, `list_images` reports it back, and the ownership
  gate recognises it.

  Read out of PVE's own source rather than from a list: the related synology
  project's list also carries `tpmstate<n>` and `efidisk<n>`, and PVE does not
  construct those — they come through `find_free_diskname` like any other
  disk.

- **The documentation site lost its side padding on a narrow window.** Section
  padding was `calc((100% - 920px) / 2)`, which goes negative below that width
  and invalidates the whole shorthand, so text ran to both edges. Found in the
  same reading, in the same place.

## [0.8.5~beta1] - 2026-08-08

### Fixed
- **The three navigation entries added in 0.8.4 rendered as bare inline text.**
  They were missing the class every other sidebar link carries, so instead of
  three items they appeared as one run of unstyled words in the middle of the
  menu. Caught from a screenshot, which is not a check.

  `t/16-docs.t` now reads the site's navigation: every sidebar link must carry
  the class, must point at a section that exists, and every section must be
  reachable from the sidebar. A link that scrolls nowhere and a section nobody
  can find are the same defect from opposite ends.

## [0.8.4~beta1] - 2026-08-08

### Changed
- **The documentation site now leads with what an operator needs to decide
  whether to trust it**, following the shape of the related synology project's
  page:

  - **Which Proxmox VE operations work** — a table of the operations
    themselves, for virtual machines and for containers, with a column saying
    where each row has actually been driven. Most rows say "Code": implemented,
    covered by tests, and no array has run it. That is the honest state of a
    beta plugin and it belongs above the feature list, not below it.
  - **Why this plugin has to be verified on hardware** — Dell publishes
    documentation for all four families and it is not enough; every
    array-facing fact here was cross-checked against Dell's own client code,
    and the first run on each of two real arrays still found defects that no
    amount of reading would have.
  - **How to help this project** — what it needs is not code. It is time on
    other people's arrays, and the three questions only an array can answer.

- The related-projects list now includes `jt-pve-storage-synology`.

- `make release-check` compares the number of unit tests the site claims
  against the number the run reported. That number had said 2,756 for eleven
  releases while the suite grew past 3,000 — a figure in prose goes stale
  silently, which is the one kind of documentation error nobody notices.

## [0.8.3~beta1] - 2026-08-08

### Fixed
- **A `waitpid` with no bound, on the path where nothing went wrong.**
  `sysfs_read_with_timeout` ended by waiting for its child with the alarm
  already cleared. The child has closed its end — that is why the read
  returned — so it normally exits at once; one that has been STOPPED rather
  than killed (a debugger attached, a cgroup freezer) is not dead and never
  will be, and pvestatd waits there forever. The rule about reaping with
  `WNOHANG` covered the path that kills a child; nobody had looked at the one
  where everything went well.

- **A resized volume whose multipath map never grew.** `multipathd resize
  map` resizes from udev's view of the paths, and when that view is still the
  old capacity it resizes the map to the size it already had and reports
  success. The map stayed small and QEMU's `block_resize` failed with *Cannot
  grow device files* on a volume that had in fact grown. The resize is
  re-issued now until the map reports the new size, and says so plainly if it
  never does.

- **Every other node kept the old size after a resize.** Only the node running
  the guest resizes — PVE calls `volume_resize` there and nowhere else — so
  every other node with the volume mapped kept the old capacity in its
  multipath map, and a migration handed the guest a device SMALLER than its
  configuration claimed. `activate_volume` compares the array's size against
  the local map, which it already has both of, and refreshes when the array's
  is larger. Never the other way round.

### Changed
- `path()` returns `images` as its third value, which is the vtype PVE reads
  there; it was returning `raw`, which is the format. Nothing consumed it —
  every caller either returns early for a shared storage or only tests for
  `backup` — but "harmless" was a property of PVE's current code rather than
  of ours.
- The `dd` used by volume export and import is called by absolute path, like
  every other command here.

## [0.8.2~beta1] - 2026-08-07

### Fixed
- **A host inside a host group is now mapped through the group.** PowerStore's
  own Map dialog offers host groups and not the hosts inside them: once a host
  joins a group, the group is the mapping target. The plugin was attaching the
  member host, which left every other node in the group without the volume —
  a new disk was mapped to the node that created it and to nothing else, and a
  migrated VM arrived on a node that could not see its disk.

  One group mapping reaches every member, which is what a cluster wants and
  what makes a migration find its disk without a mapping of its own. The
  operator is told once, by name, that the group is what volumes are mapped to
  — every member can see them, and that is worth knowing rather than
  discovering.

  The same mapping is what gets removed: a group mapping this plugin made is
  detached through the group, because leaving it behind is how a deleted
  volume keeps a live path on every member.

## [0.8.1~beta1] - 2026-08-07

### Fixed
- **A migrated VM could arrive on a node that could not see its disk.**
  `activate_volume` is the first thing a migration target does with a volume,
  and it took the host name as final. On a node that had not yet worked out
  WHICH host object it is — because the array's hosts were built by someone
  else and adopted rather than created — that name is the generated one,
  which does not exist on the array. The map failed with *Host … is not
  registered on the array*, `activate_volume` died, and the guest was left
  without its disk.

  The volume's host object is now resolved before it is mapped to, and only
  on the path where the volume is not mapped yet — so it costs nothing on an
  ordinary poll.

- **A new volume was mapped only to the node that created it.** Volumes are
  pre-mapped to the other nodes' hosts so a migration does not have to wait
  for a mapping, and the other nodes are found by the `pve-<cluster>-` prefix
  this plugin's own names carry. A host adopted under the array's own naming
  is invisible to that search.

  Each node now publishes the host object it resolved to, in the cluster
  filesystem, one file per node — a node only ever writes its own, so there is
  no lock and no race — and the pre-mapping reads them. The file is removed
  when the storage is removed.

## [0.8.0~beta1] - 2026-08-07

### Fixed
- **Every volume attach on PowerStore failed: the LUN id was sent as a
  string.** Found on a customer's first PowerStore run, immediately after the
  host object was resolved:

  > `Validation failed: [Path '/logical_unit_number'] Instance type (string)
  > does not match any allowed primitive type (allowed: ["integer"])`

  The id is an integer when it is computed. `next_free_lun` returns it from a
  loop whose body reads `$used{$lun}` — and using a scalar as a hash key
  stringifies it in place, so it carries both an integer and a string, and
  Perl's JSON encoder writes the string. Nothing in the code looks wrong;
  the value simply remembers having been a key.

  Every number in a request body is now coerced where it goes in. `align_size`
  got the same treatment: it returns its argument unchanged when the size is
  already aligned, which passed a size that arrived from `storage.cfg` — where
  every value is a string — straight through to the array.

  The new guard drives the real client through a capturing transport and reads
  the bytes it would put on the wire. Nothing short of that sees a JSON type.

## [0.7.99~beta1] - 2026-08-07

### Changed
- Documentation for the host-object behaviour added in 0.7.98, in both
  languages: `docs/FIRST_RUN` gains a section on the array already having a
  host for this node, `docs/TROUBLESHOOTING` covers both refusals and how to
  see which object a node settled on, `docs/NAMING_CONVENTIONS` says the
  generated name is not always the name used and why the prefix still matters
  to the cluster, `docs/CONFIGURATION` has the full rule, and the
  documentation site has a section of its own. `docs/TESTING` gains two matrix
  rows for it.

- The full-width punctuation check no longer trips over HTML entities: the
  semicolon in `&lt;` is markup, not a half-width mark before the Han
  character that follows it. Entities are blanked before the check rather than
  the line being skipped, so real marks elsewhere on it are still caught.

## [0.7.98~beta1] - 2026-08-07

### Added
- **The host object the array already has for this node is used, rather than
  a second one being created.** An array usually has one before this plugin
  runs — built by whoever zoned the fabric — holding this node's WWPNs under a
  name of its own, and an initiator can belong to only one host object. On
  PowerStore, when there is no host under the name this plugin uses, it now
  looks for one that already holds this node's initiators and uses that,
  recording the name locally so every later mapping goes to the same object.
  Nothing is renamed, nothing is removed, no initiator is moved.

  It adopts only a host whose initiators are a **subset of this node's**. One
  that also carries another host's ports is a shared or foreign object, and a
  volume mapped to it would be visible to whatever else is in it — so the
  plugin refuses, and names the port that made it refuse. Ports split across
  two host objects are refused too: a node is one host object.

  The recorded name is validated on the way back out, because a state file is
  something an operator can edit and the value ends up in a request to the
  array. A record naming a host the array no longer has is dropped, and the
  plugin falls back to its own name.

  Volumes are still pre-mapped to other nodes by searching for the
  `pve-<cluster>-` prefix, so a node whose host was adopted under another name
  is not pre-mapped from elsewhere; it maps itself when it activates the
  storage, which happens before a migration completes.

## [0.7.97~beta1] - 2026-08-07

### Fixed
- **"The initiator is already registered" now says which host has it.**
  PowerStore allows an initiator on exactly one host object, and its refusal
  names neither the initiator nor the host that holds it. The plugin now asks
  the array who owns each of this node's ports and says so, with the two ways
  out: rename that host to the name the plugin uses — which keeps its
  initiators and its mappings — or remove it.

  The message also says why the name matters beyond the one node: volumes are
  mapped to the other nodes' hosts by looking for the `pve-<cluster>-` prefix,
  so a host outside that convention is not found when another node needs the
  volume, and live migration to it fails.

- **Initiators are compared by identity, not by spelling.** The same port is
  written `21:00:f4:c7:aa:a0:a2:50` by PowerStore, `0x2100f4c7aaa0a250` by
  sysfs and `2100f4c7aaa0a250` by an ME. The check for "is this node's port
  already on the host" compared the strings, so a difference in spelling would
  have re-added an initiator the host already had — which the array refuses,
  taking the storage inactive.

## [0.7.96~beta1] - 2026-08-07

### Fixed
- **PowerStore refused to create a host: the FC WWPN was sent without
  colons.** Found on a customer's first PowerStore run, where it stopped
  `pvesm add` outright:

  > The operation on host pve-pve-&lt;node&gt; (id: null) cannot be completed,
  > because the format of the port name pve-pve-&lt;node&gt; is incorrect. Please
  > use a valid IQN for iSCSI, WWN for FC, or NQN for NVMe. (0xE0A01001002F)

  The array quotes the HOST name back where the port name belongs, which is
  why this reads as a host-naming problem. What it disliked was the WWPN:
  `2100000e1e1d2b3c` where PowerStore requires `21:00:00:0e:1e:1d:2b:3c`, the
  form Dell's own `ansible-powerstore` module documents.

  `Common::FC` has always had both spellings, and every caller had picked the
  run-together one — the formatted function was called nowhere at all. The
  three families need three different things, so they now send three:
  PowerStore the colon form, PowerVault the run-together form (the only one an
  array has actually accepted — an ME4024 creates hosts and maps volumes
  through it), and Unity the node WWN and the port WWN joined, which is what
  Unisphere shows. `bin/pve-dell-config-get` speaks PowerStore and got the
  same fix.

- **Unity's FC initiator was missing half of its identity.** Unity names an FC
  initiator by the node WWN and the port WWN together
  (`20:00:…:3c:21:00:…:3c`); the plugin sent the port WWN alone, without
  colons. Reading the node WWN from the existing node-name list would have
  been wrong in its own way — two ports of one adapter share a node name and
  both lists deduplicate, so pairing by position attaches the wrong node WWN
  to the second port. The pair is read from one sysfs directory. Still NOT
  0.7.96~beta1IFIED: no Unity has run this.

- **`Odd number of elements in hash assignment` on a failed `pvesm add`.**
  Introduced in 0.7.94: the local-state cleanup called `stale_temp_clones`
  with a bare `0` where the function takes named options, so the 15-minute
  grace stayed in force and a temporary clone recorded minutes earlier was not
  counted — its record was then deleted as if there were none.

## [0.7.95~beta1] - 2026-08-07

### Fixed
- **`sparseinit` promised something a thick volume does not do.** The feature
  tells PVE that a new volume reads as zeroes where nothing has been written,
  and PVE acts on it by not writing the zeroes at all: a clone of a running VM
  is mirrored with `zero-initialized`, and `pbs-restore` is given
  `--skip-zero`. That holds for a thin volume, whose unmapped blocks read as
  zeroes, and not for a thick one, whose extents are whatever the array last
  had there — so a clone or a restore onto a thick volume would leave the
  array's previous contents inside the guest's disk, where its source had
  zeroes.

  It is answered per family now: PowerStore always (its volumes are thin),
  Unity and PowerFlex according to `unity-thin` and `pflex-thick`, and
  PowerVault not at all — whether an ME volume is thin depends on the pool it
  lives in, and the plugin cannot know that without asking the array on a path
  that runs per volume.

  This is the same claim 0.7.90 removed from the import path's
  `dd conv=sparse`, reached through QEMU instead of through dd.

### Changed
- Chinese text now uses full-width punctuation throughout. 219 half-width
  commas and colons had accumulated in the zh-TW changelog, the documentation
  site and the testing document; `t/11-imports.t` fails on them from now on,
  in both directions — a Han character before the mark, and a Han character
  after it, which is the case that hides behind a code span.

- The 0.7.88 entry named `qm move_disk` among the operations it had fixed.
  That was wrong and the entry now says so: a move between two storages on one
  node goes through `qemu-img convert` and `path()`, and never asked for a
  transfer format. What that release fixed is `pvesm export`, `pvesm import`
  and cluster-to-cluster migration.

## [0.7.94~beta1] - 2026-08-07

### Fixed
- **The test suite wrote over this node's own tracking files.** The lifecycle
  tests use storage ids a real installation would also use — `u480`, `me5` —
  and the plugin names its state files after the storage, under
  `/var/lib/pve-storage-dellemc`. Running `make test` on a node therefore
  wrote `{}` over the WWID tracking of a storage with the same name, and the
  orphan reaper reads exactly those files to decide which devices belong to
  this node. `docs/RELEASE_TESTING.md` asks a tester to run the suite on the
  node being tested, so this was reachable by following the project's own
  instructions. The state directories now honour `PVE_DELLEMC_STATE_DIR` and
  `PVE_DELLEMC_RUN_DIR`, and every test target points them at a throwaway
  directory. Nothing in production sets either.

- **A removed storage left its local bookkeeping behind forever.**
  `on_delete_hook` deleted the password and nothing else, so a storage id
  created again later inherited the previous one's outage state and warning
  throttles: a first successful poll reporting *RECO0.7.94~beta1ED after four days*,
  and an hour of silence on warnings about a storage nobody had ever seen.
  Both are cleared now, in all four families.

  The WWID and temporary-clone tracking is treated differently on purpose: if
  it still names a device on this node or an object on the array, the file is
  KEPT and the operator is told what is in it. Deleting the only record of
  something that is still there leaves nothing to clean it up with.

## [0.7.93~beta1] - 2026-08-07

### Fixed
- **The recovery tool could not find the array password.**
  `pve-dell-config-get` parses `/etc/pve/storage.cfg` itself rather than going
  through PVE, because the situation it exists for is the one where PVE will
  not start. 0.7.86 moved the password out of `storage.cfg` and into
  `/etc/pve/priv/storage/<storeid>.pw`, and the tool was not told: for four
  releases it answered *no credentials configured* for every storage
  following the current convention, at the moment someone was trying to
  recover a VM configuration. It reads the priv file now, with the same
  precedence the plugin uses, and when it still finds nothing it names the
  directory it looked in.

- **The recovery tool ignored `dell-host-mode`.** That option decides whether
  the plugin registers one host object per node or a single shared one for
  the cluster, and the tool always built the per-node name. Against a storage
  using the shared mode it looked for a host that does not exist and then
  registered a NEW one carrying this node's initiators — and an initiator
  belongs to one host object on these arrays, so that is refused at best and
  at worst moves the initiator off the shared host every node's volumes are
  mapped to. A recovery tool taking a cluster's storage down while someone is
  recovering a VM. It reads the mode from `storage.cfg` now, accepts
  `--host-mode` for recover mode, and prints which host object it will use
  before it does anything with it.

### Added
- `t/22-config-get.t`, which drives the real script as a subprocess against a
  temporary `/etc/pve`. Nothing tested this tool before.

## [0.7.92~beta1] - 2026-08-06

### Fixed
- **Every upgraded PowerFlex storage was broken, on the upgrade path itself.**
  0.7.86 moved the array password into `/etc/pve/priv` and left a warning in
  place for storages whose password is still in `storage.cfg`. The warning
  was written as `$class->_warn_once(...)`, which is defined in `BlockBase` —
  and PowerFlex is not a BlockBase subclass. So any `dellpowerflex` storage
  carrying a password in `storage.cfg`, which is every one upgraded from
  before 0.7.86, died with *Can't locate object method "_warn_once"* on
  `activate_storage`, on `status`, and on every array call. The storage went
  inactive and stayed there.

  Perl resolves a method at the moment the line runs, and `perl -c` compiles
  the call without a word, so nothing before this saw it. `t/11-imports.t`
  now resolves every private method call a class makes on itself against that
  class's own `package` and `use base` chain — statically, so it runs in CI
  where there is no PVE. One hit in the whole tree, which was this.

  **Anyone running `dellpowerflex` on 0.7.86 to 0.7.91 should upgrade.** The
  workaround without upgrading is to move the password into `/etc/pve/priv`,
  which the warning was asking for anyway: `pvesm set <storeid>
  --dell-password '<the password>'`.

- **Three warnings on PowerFlex's activation path had no throttle.** A
  missing SDT, native NVMe multipathing switched off, and a discovery port
  that does not answer are all conditions that persist — and
  `activate_storage` runs about every ten seconds per node per storage, so
  each wrote six lines a minute and buried everything else in the journal.
  They go through `_warn_once` now, one per storage per topic per hour, which
  is the rule the SAN families have followed since 0.7.63.

## [0.7.91~beta1] - 2026-08-06

### Fixed
- **Two storages on one array shared a client, and with it a password.** The
  API client was cached under a key of management address, username, TLS
  setting and health flag — and the object it caches carries the storeid it
  names in every message, and the password, which since 0.7.86 is read per
  storage from `/etc/pve/priv/storage/<storeid>.pw`. Two storages on one
  array with the same username is an ordinary setup — two pools — and the key
  without the storeid handed the second one the first one's client. Its
  failures were logged under the other storage's name and throttled under the
  other storage's `_warn_once` key, and it authenticated with the other
  storage's password.

  The credential is the half that bites. A password rotated on one storage
  and not the other means repeated failed logins with a stale one, and an
  array management account that locks out takes every storage on that array
  with it. The storeid is part of the key now, in all four families.

- **`get_identity` called the same array two different things.** It answers
  whether two storages are the same storage, and it was built from
  `dell-portal` verbatim — which has been a comma-separated list since
  0.7.75, for the arrays whose controllers each have their own management IP.
  The two controllers in the other order, a space after the comma, or one
  storage listing both where another lists one, all answered "different
  array". The addresses are treated as a set now: split, trimmed, folded to
  lower case and sorted.

## [0.7.90~beta1] - 2026-08-06

### Verified on hardware
- **The PowerVault ME4024 has run the six lifecycle items beyond the
  first-run test, and all six passed.** On firmware `GT280R011-01` over
  Fibre Channel, at 0.7.66: a guest OS booting off an array volume, growing
  a disk (`expand volume`'s add-this-much arithmetic and the resize that
  follows it — the one main path nothing had ever exercised),
  `vzdump --mode snapshot` with a restore and no `-tmp-`/`-vc-` object left
  behind, an LXC container including the fsfreeze its snapshot needs, and a
  node reboot. `docs/TESTING.md` records which matrix rows that covers, on
  what hardware and at which version — and says plainly that it is a
  point-in-time result: shared code has changed in every release since, and
  one of those changes is on the VM-start path.

### Fixed
- **The import wrote zeroes by skipping them, on a guarantee an operator can
  withdraw.** `volume_import` used `dd conv=sparse`, which skips a run of
  zeroes instead of writing it. That is only correct where the region it
  skips already reads as zeroes — true of a thin volume, whose unmapped LBAs
  read as zeroes, and not true of a thick one, whose extents are whatever the
  array last had there. Thin is an operator's choice on two families
  (`unity-thin`, `pflex-thick`) and a property of the pool on PowerVault, so
  the correctness of the copy rested on a storage's configuration. Writing
  every byte costs the volume's thinness on an import and nothing else; the
  other way round leaves whatever the array had in those extents readable
  inside the imported disk. `LVMPlugin` writes every byte too.

  Found by re-reading the previous release's own new code.

### Added
- Tests driving `volume_import` end to end with the copy stubbed — the size
  rounding, the argv of the copy, and the cleanup of a half-written volume
  when it fails — and `qemu_blockdev_options` against the placeholder path
  and an unconfirmed device.

## [0.7.89~beta1] - 2026-08-06

### Fixed
- **Starting a VM stat'ed its disk without a time limit.**
  `qemu_blockdev_options` was inherited from PVE's base class because it does
  the right thing with a `/dev/...` path — and it gets there through
  `File::stat::stat($path)`, an unbounded stat on a path under `/dev`. On a
  dm-multipath device whose paths have all failed while queueing is still on,
  a stat is uninterruptible sleep that no signal clears: the pvedaemon worker
  starting the VM would hang there, unkillable, with every later caller
  queued behind it. Every stat this plugin makes of its own is bounded; this
  one was made by PVE on its behalf, so the method that makes it is now
  overridden in all four families. `LVMPlugin` and `RBDPlugin` both answer
  `host_device` with the path and no stat at all, which is the same
  conclusion by a shorter route.

  The override also refuses to start on the placeholder path `path()` returns
  when the array cannot be asked. Handing that to QEMU turns a storage outage
  into I/O errors inside the guest, several minutes later, with nothing
  pointing at the cause.

### Added
- **A test that asks what the other two path-less block plugins found
  necessary.** `LVMPlugin` and `RBDPlugin` are the two PVE plugins that are
  also block storage with no filesystem path, so a base method BOTH of them
  override is one whose default does not fit that shape — and inheriting it
  here is a question to answer rather than a default to accept. Run against
  the tree as it was two releases ago, it names `volume_export`,
  `volume_import` and `qemu_blockdev_options`: the last three defects of this
  kind, all of which it would have found first.

## [0.7.88~beta1] - 2026-08-06

### Fixed
- **Moving a disk off this storage was advertised and then refused.**
  `volume_export_formats` said `raw+size` was available, and that was the
  whole of it: the transfer itself was left to
  `PVE::Storage::Plugin::volume_export`, which opens with
  `if ($scfg->{path} && ...)` and dies for a storage that has no path — which
  this one has not, and cannot have. So `pvesm export`, `pvesm import` and
  remote migration all failed one call after the plugin had offered them, with
  a message naming the format the plugin itself had just advertised. All four
  families, since the override was written.

  *Corrected in 0.7.95: this entry also named `qm move_disk` to another
  storage, which was wrong. A move between two storages on the same node goes
  through `PVE::QemuServer::clone_disk`, which copies with `qemu-img convert`
  or drive-mirror through `path()`, and never asked for a transfer format. It
  worked before this release and after it. What this release fixed is
  everything that goes through `PVE::Storage::storage_migrate`:
  `pvesm export`, `pvesm import`, and cluster-to-cluster migration.* `LVMPlugin`, `RBDPlugin` and `ZFSPoolPlugin` all implement both
  halves; only the formats half had been read.

  `volume_export` and `volume_import` are now implemented, for the SAN
  families and for PowerFlex separately. Around the copy: the volume is
  activated first, because nothing does it for the plugin here; the export
  header's size is read from the kernel rather than guessed; and the device is
  refused unless the kernel's own identification of it agrees with the volume
  the array named. That last one is the guard that matters — an import writes
  a whole disk image, `path()` has a documented fallback to a placeholder
  device when the array cannot be reached, and writing an image into whatever
  that resolves to is the worst thing in this release's reach.

  `t/11-imports.t` now fails any plugin that declares a transfer format
  without implementing the transfer.

## [0.7.87~beta1] - 2026-08-06

### Security
- **The login hash was written to the journal in full.** PowerVault's
  documented login puts `sha256("user_password")` **in the URL**, so every
  failed login wrote that hash into the node's journal verbatim — and it is
  unsalted, uniterated SHA-256 over a string whose first half is usually the
  known username, which a dictionary attack chews through at millions of
  guesses a second. The journal is readable by more people than
  `/etc/pve/priv` is, and it travels in every support bundle.

  Every message this client emits now passes through a redactor: a long hex
  run in a path segment after a login-ish word, and any `Basic` blob, are
  cut to a six-character prefix plus `[redacted]` — enough to correlate two
  log lines, not enough to crack. Redaction is by **shape**, so it covers
  the other families' login forms without each having to remember.

  Diagnostics survive deliberately: a WWID is a long hex run too, and losing
  it would trade one problem for another. The tests assert both halves —
  hashes and Basic blobs gone, WWIDs, volume names and array return codes
  intact — and the fix was confirmed by driving a real failed login and
  reading the journal.

  Found by re-examining yesterday's password fix for the leaks it did not
  cover.

## [0.7.86~beta1] - 2026-08-06

### Security
- **The array password was stored in clear text in
  `/etc/pve/storage.cfg`.** This plugin declared a `sensitive_properties`
  *method* — but PVE never calls one. It calls
  `PVE::Storage::Plugin::sensitive_properties($type)` as a **function** and
  looks the answer up in `plugindata`. Ours said nothing there, so PVE fell
  back to its built-in list, `dell-password` was not on it, and the password
  went into the config file: readable by the **www-data** group, replicated
  to **every node** by pmxcfs, returned verbatim by **`GET /storage/<id>`**,
  and carried into any `/etc/pve` backup.

  All four families now declare it in `plugindata`, and the password is
  written to `/etc/pve/priv/storage/<storeid>.pw` at mode 0600 — the
  directory PBS uses, which is `0700 root:www-data`, so the web server
  cannot even enter it.

  **Upgrading does not break anything.** A storage created before this keeps
  working: the password is read from the priv file if it exists and from the
  config otherwise, and a reminder is logged once an hour. To finish the
  move, run this once per storage:

  ```bash
  pvesm set <storeid> --dell-password '<the password>'
  ```

  That writes the priv file **and removes the clear-text line from
  `storage.cfg`** in the same operation. An unrelated `pvesm set` never
  touches the password.

  This is the fourth appearance of lesson 36 — a rule documented, tested,
  and never called. The test now asserts what PVE actually reads.

## [0.7.85~beta1] - 2026-08-06

### Fixed
- **PowerFlex: the 4.x-only mapping action no longer carries 3.x baggage.**
  `addMappedHost` — an action that exists only on 4.x — was sent
  `allowMultipleMappings: 'TRUE'`, the ScaleIO 3.x reference's *string*
  spelling of a boolean. Dell's gen2 client sends a JSON boolean there. The
  4.x path now does too; the SDC path keeps the documented string form,
  since gen1 arrays are the ones that documented it.
- **The readback question a 4.x array must answer is now registered:**
  after the first NVMe map, which field of the volume carries the host
  mapping? Dell's public code never reads it back, so `mappedHostInfo`
  remains this plugin's registered guess (read at no cost when absent); if
  the real field is named otherwise, the symptom is a volume that maps
  again on every activation — the ME lesson-21 symptom, pre-registered.

### Changed
- The multipath built-in comparison now spans all families, in code
  comments where the next reader needs it: Unity follows the kernel's DGC
  entry (0.7.84); PowerStore's and ME's deviations from their built-ins are
  same-category tuning choices, ME's block hardware-proven on the ME4024.
  The 0.7.84 mechanism wording is corrected: conf.d attributes override the
  built-in *per attribute* — verified on this node by reading the merged
  `multipath -t` — rather than replacing the entry wholesale.

## [0.7.84~beta1] - 2026-08-06

### Fixed
- **Unity: the multipath settings would have replaced thirty years of
  CLARiiON tuning with a generic guess.** A `conf.d` device section's
  attributes *override* the built-in entry's for matching devices,
  and Unity's drop-in carried the generic ALUA block copied from
  PowerVault. The built-in for `^DGC` is deliberately different, and every
  difference matters:

  - `path_checker emc_clariion`, with `detect_checker no` pinned — the
    family checker recognises a passive SP and an inactive snapshot LU;
    TUR does not, and upstream pins it precisely so detection cannot swap
    it out.
  - `prio emc`, not `alua` — a Unity can run ALUA or PNR, and `emc` judges
    both. `alua` on a PNR array scores both SPs equally, I/O lands on the
    non-owning SP, and the LUN *trespasses* back and forth between
    controllers: a performance collapse that looks like a fabric problem.
  - **no** `hardware_handler` — the built-in sets none for DGC, and
    forcing `1 alua` onto a PNR-mode array breaks its failover handling.

  The drop-in now follows the built-in and adds only the bounded-recovery
  settings on top (`no_path_retry 60` — the built-in's own number —
  `fast_io_fail_tmo`, `dev_loss_tmo`). The product pattern widens to the
  built-in's `^(RAID|DISK|VRAID)`. Config version 2: nodes with the old
  drop-in upgrade it automatically on the next activation.

## [0.7.83~beta1] - 2026-08-06

### Fixed
- **PowerFlex: an NVMe host could never have been mapped.** An NVMe host
  and an SDC are mapped by different *actions*, not by different parameters
  to one action: Dell's gen2 client has `addMappedHost`
  (`{hostId, nqn, allowMultipleMappings}`) alongside `addMappedSdc`
  (`{sdcId, guid, allowMultipleMappings}`), with `removeMappedHost`
  mirroring it. This plugin sent `hostId` to `addMappedSdc`, marked NOT
  0.7.83~beta1IFIED — on **NVMe/TCP, which is this family's default protocol**, so
  the default path's map call rested on a guess when Dell's own code shows
  the action that exists for it. Both directions now choose the action by
  what is being mapped.

  Same audit, same day, same family as the rollback fix: the two calls that
  would have failed first on a real 4.x array were the two resting on the
  weakest evidence.

## [0.7.82~beta1] - 2026-08-06

### Fixed
- **PowerFlex: the rollback now speaks the generation the array actually
  runs.** The family's most destructive call — overwriting a volume with a
  snapshot — sent `overwriteVolumeContent` to every array: the ScaleIO 3.x
  reference's form, which Dell's own client never implemented, marked NOT
  0.7.82~beta1IFIED since the day it was written. Dell's gen2 client shows that 4.x
  — the only generation anyone deploys today — uses **`restore`** with
  `{srcVolumeId}` at the same URL shape.

  The rollback now follows the generation the login detected: `restore` on
  4.x (read from Dell's own code), `overwriteVolumeContent` kept for 3.x
  (still unverified, but only ever sent to an array that answered the 3.x
  login). Writing the test caught a second bug in the first draft: the
  action was chosen before any login had run, so a fresh client picked the
  default generation — the session is now ensured before the choice.

  Found by turning the key-for-key audit on PowerFlex, the last family the
  technique had not visited. The rest of the audit was clean: create's
  dual size spelling already has its documented fallback, the mapping
  actions and `snapshotDefs` match Dell's client exactly.

## [0.7.81~beta1] - 2026-08-06

### Fixed
- **Unity: the array's error number never reached the operator.**
  `error_code_of` was added in 0.7.70, tested, and called by nothing —
  lesson 36's exact shape, found by grepping for its callers. It is now
  wired into the error translation, so every Unity refusal carries
  `(errorCode NNNN)` the way PowerVault's messages carry
  `(return code -10389)`. The ME4024's first hardware run proved what that
  is worth: every one of the customer's reports quoted the number, and the
  numbers are what turned symptoms into diagnoses.

### Added
- `make critic`: perlcritic severity 4, clean by policy. 340 findings were
  audited class by class down to zero; every suppression in `.perlcriticrc`
  carries the audit that earned it, including the list-context audit of all
  143 `return undef` sites (zero list-context receivers exist in `lib/`).
- The `_array_*` calling convention is guarded in the suite: each family's
  signatures are compared position-by-position against BlockBase's actual
  call sites, by the KIND of name — an arity-only draft provably missed the
  0.7.80 bug, and the kind-of-name version names it precisely.

## [0.7.80~beta1] - 2026-08-06

### Fixed
- **Unity: every WWID lookup answered `undef` — device discovery was dead on
  arrival.** BlockBase calls `_array_get_wwid` with two arguments,
  `($scfg, $array_name)`, at ten call sites; Unity's implementation declared
  three, so the volume name landed in a parameter nothing reads and the name
  itself was `undef`. `path()` would have handed QEMU
  `/dev/mapper/unknown-*`, activation could not find the disk it had just
  mapped, and `free_image` would have taken the no-WWID branch — for every
  volume, from the first minute on hardware.

  The lifecycle tests missed it because they stub the device layer. Two
  guards now exist: a systematic arity comparison of all 22 `_array_*`
  methods against BlockBase's actual call sites (this was the only
  mismatch), and a test that calls `_array_get_wwid` exactly as BlockBase
  does and asserts `path()` resolves to `/dev/mapper/<wwid>`, never a
  placeholder. Reverting the fix fails four tests.

## [0.7.79~beta1] - 2026-08-06

### Fixed
- **A refused `pvesm add` had already reconfigured every vendor's multipath
  maps.** Found by running the whole `pvesm add` path end-to-end against a
  Unity API emulator on a node that could serve neither protocol.
  `activate_storage` wrote the multipath drop-in — and issued the one
  permitted node-wide `multipathd reconfigure` — *before* the protocol
  prerequisites were checked. An FC storage on a node with no HBA, or an
  iSCSI storage whose portals the node cannot reach, was refused as it
  should be; but the reconfigure had already touched every vendor's maps on
  a shared node, and this plugin's drop-in stayed behind, for a storage
  that never came to exist.

  The drop-in is now written only after the protocol activation succeeded.
  Nothing in the activation needs it — it tunes devices, and devices appear
  at `activate_volume`, not here. All three BlockBase families are covered
  by the same reorder; both refusal paths were re-run against the emulator
  and leave zero files and zero reconfigures behind.

## [0.7.78~beta1] - 2026-08-06

### Fixed
- **PowerFlex: a dead array was billed twice for being dead.** The
  multi-address failover shipped in 0.7.75 capped the timeout multiplication
  for PowerVault's two login methods — and PowerFlex's two login
  *generations* (4.x, then 3.x) have exactly the same shape, and did not get
  the cap. On a dead array with two addresses, the 4.x login cycled both,
  the 3.x login cycled both again, and the outer retry repeated it all —
  inside the bounded `status()` budget. Once the 4.x attempt has watched
  every address fail to connect, the 3.x attempt is no longer made: TCP that
  does not answer does not care which login it is refusing.

  Lesson 40a in the transport dimension: a guard added for one family is not
  applied to another until someone applies it. The test asserts `/api/login`
  is never requested after both addresses failed to connect.

## [0.7.77~beta1] - 2026-08-06

### Fixed
- **Unity: a listing that contradicted itself was read as empty.** An array
  that reports `entryCount: 9999` and hands back an empty page was treated
  as an empty collection — which, on the orphan reaper's path, reads as
  "every volume was deleted". The contradiction is now an error after
  exactly one request, and the page-cap backstop (100,000 rows) now dies
  naming the incomplete listing instead of silently truncating: a silent cap
  reads as completeness, and the callers of this include the paths that
  decide what may be deleted.

### Changed
- **Unity: the health ping no longer duplicates the capacity query.** Every
  status cycle listed the pools twice — once as the ping, once for capacity.
  The ping now asks for `basicSystemInfo`, the cheapest thing a Unity
  serves, whose answer (name, model, software version) is also what a first
  run's log needs when nothing else works.

## [0.7.76~beta1] - 2026-08-06

### Fixed
- **The failover from 0.7.75 rotated the portal and then sent the request to
  the address it had just abandoned.** The request URL was built at the top
  of the attempt, before the login — and the login is exactly where a dead
  controller is discovered and rotated away from. So the login would fail
  over to the live controller, succeed, and the request that followed would
  still go to the dead one; with two addresses the client ping-ponged until
  its attempts ran out. The URL is now built after the login, from the
  address the login proved alive.

  Caught by driving the Unity client against real sockets — a dead port and
  a live miniature Unity — where the fake user agents in the unit tests
  could not see it: their logins do not cross the wire, so their rotations
  happen at a different moment than a real login's.

- **A portal carrying its own port broke the URL.** `1.2.3.4:8443` became
  `1.2.3.4:8443:443`. Latent since the beginning; surfaced by the same real
  sockets, whose test servers live on high ports.

### Added
- **The adverse suite now attacks Unity too**: a server that accepts and
  never answers, HTML from an intercepting proxy, a real 302 over a real
  socket — refused, not followed, and explained as what it means on this
  API — and a controller failover end-to-end across two real sockets.

## [0.7.75~beta1] - 2026-08-06

### Added
- **`dell-portal` takes several addresses, and the client fails over between
  them.** Asked by the ME4024's tester: their array has one management IP
  per controller — active on `.11`, standby on `.12` — and no floating
  address, so a controller failover takes the configured address away with
  it. The data path was never the problem: dm-multipath and ALUA handle that
  on their own, and running guests never notice. What broke was management —
  status, allocation, snapshots, deletion — until someone edited the storage
  by hand.

  Now: `--dell-portal 192.168.1.11,192.168.1.12`. A connection failure the
  array never saw (LWP's own `Client-Warning: Internal response`) moves to
  the next address immediately, without backoff — failing over fast is the
  point of a second address. The address that answers becomes sticky. The
  session is dropped on every rotation, because **a session belongs to the
  controller that issued it**: carrying it across would swap a dead-address
  failure for an authentication loop against the live controller. Every
  address gets at least one try even on the health client, so `pvesm
  status`'s worst case is one short timeout per address — still bounded.

  One address configured behaves exactly as before. All four families
  inherit the feature, since it lives in the shared transport.

  The bound is enforced, not just promised. The first draft let nested
  request layers — an outer call, a login retry, PowerVault's two login
  methods — each cycle the address list, and a 2-second status timeout
  became 21 seconds on a dead array. Once one request has watched every
  address fail to connect, a flag stops the layers above from cycling the
  same dead set again. Measured on this node: two dead addresses at
  `dell-status-timeout 2` cost `pvesm status` 4.0 seconds — one timeout per
  address, exactly the documented worst case.

  Found while testing it: the request URL was built once, outside the retry
  loop — so a rotated portal would still have sent every retry to the dead
  address. It is now built per attempt.

## [0.7.74~beta1] - 2026-08-06

### Fixed
- **Unity: the rollback backup snapshot from 0.7.71 carried two traps of its
  own.** Found by continuing to hunt, three releases after the feature
  shipped.

  First, the backup is always the newest snapshot on the volume, and it was
  visible to PVE — so `volume_rollback_is_possible` refused every **second**
  rollback with "not the most recent snapshot", blocking the very operation
  the backup exists to protect. The backups are now filtered from what PVE
  sees; the purge that runs before a volume delete does not come through
  that path, so hiding them orphans nothing.

  Second, the backup's snapshot name was `rollback` — a name a PVE user can
  type. A user snapshot called `rollback` would have collided with it, and
  the cleanup would have deleted the user's snapshot. The name is now
  `pve.rollback`, with a dot: **PVE forbids dots in snapshot names**, so no
  user snapshot can ever be named this. The test creates a user snapshot
  actually called `rollback`, rolls back twice, and asserts it survives.

  And the backups no longer accumulate: the previous one is removed before
  each restore, so one safety net exists instead of one per rollback holding
  space forever, invisible to PVE.

## [0.7.73~beta1] - 2026-08-06

### Fixed
- **Unity: "absent" on a delete is now confirmed by a listing, not believed
  from one 404.** The manual gives three causes for 404, and one of them is
  an invalid **URI pattern** — which is what the by-name lookup is. A
  firmware without `/instances/<type>/name:` support would answer 404 to
  every lookup, every volume would read as absent, and `free_image` would
  report success for deletes that never happened: PVE drops the disk from
  the VM configuration while the data sits on the array.

  On the destructive paths — volume delete and snapshot delete — an absent
  answer from the lookup now gets the listing's second opinion. A listing
  that succeeds without the name proves absence; one that carries the name
  proves the lookup is broken, and that is a loud error naming the firmware,
  not a quiet success. One listing per delete-of-absent, which is rare.

- **Unity: `qm rescan` would have duplicated every linked clone.** A linked
  clone must be listed under the volid PVE stored for it —
  `base-.../vm-...` — or rescan sees a volume no configuration references
  and adds it a second time as an unused disk. A Unity thin clone reports
  the snapshot it reads from in `parentSnap`; that snapshot's name decodes
  back to the template, so the mapping costs one snapshot listing for every
  volume at once, never a per-volume call.

## [0.7.72~beta1] - 2026-08-06

### Fixed
- **Unity: the pool key on a create was wrong, again in the shape of lesson
  28.** Dell's `LunParameters` struct names its field `StoragePool`, and its
  JSON tag — the thing that actually goes on the wire — is **`pool`**. An
  earlier release read the field name and sent `storagePool`; every create
  would have been refused, or worse, accepted with the pool silently
  ignored. In Go code the `json:"..."` tag is the property name and the
  field name is a printed one. The emulator did not catch it because it
  accepts any body; the struct tags did.

- **Unity: a concurrent mapping change could silently unmap a node.**
  `hostAccess` is read-modify-write with no compare-and-swap, so two nodes
  writing at once — a migration target attaching while the source detaches,
  or two parallel activations — each read the list, each write their
  version, and the second write discards the first. The node whose entry was
  lost believes it is mapped and its device never appears; on a migration
  that is the running guest's disk.

  A lost update is visible after the fact — this host's id is missing from a
  list it was just written into — so both attach and detach now verify the
  write and retry with a fresh read, carrying whatever the competing writer
  added. A write that never survives is an error naming the likely cause,
  not an infinite loop and not a quiet success.

### Verified
- Resize double-checked key-for-key against Dell's own client: same URI,
  same `{lunParameters: {size}}` wrapper, new total rather than a delta.
  Rename's bare `{name}` body matches Dell's client too.

## [0.7.71~beta1] - 2026-08-06

### Fixed
- **Unity: every rollback would eventually have made the volume
  undeletable.** Dell's own white paper is explicit that a restore
  *automatically creates a backup snapshot* — whether or not one was asked
  for. Left to the array it gets a name of the array's choosing, which the
  snapshot purge that runs before a volume can be deleted does not recognise
  and the ownership gate would refuse to touch. Unity refuses to delete a
  LUN that still has snapshots, so from the first `qm rollback` on, `qm
  destroy` fails — days later, with nothing pointing back at the rollback
  that caused it.

  The restore now passes `copyName`, naming the backup snapshot in this
  plugin's own scheme, pointed at the volume it belongs to, with room for
  the counter Unity appends when the name is taken on the second rollback.
  The lifecycle fake now creates a backup snapshot on every restore the way
  the array does, and the test proves the volume can still be deleted after
  one rollback and after two.

- **Unity: an EFI disk could not have been created.** PVE asks for genuinely
  tiny volumes — an EFI disk and a TPM state are 4 MiB each — and Unisphere
  refuses a LUN below its minimum, taking the whole `qm create` with it. A
  request below 1 GiB is now rounded up to it: too generous wastes space on
  a handful of tiny volumes, too small breaks the feature outright.

### Verified in the test suite
- The whole feature matrix PVE asks about, per volume kind: snapshot and
  rename of a linked clone (whose volname starts with `base-` and is not
  one), clone from a template, clone from a snapshot, template conversion,
  copy, export as `raw+size`, and fsfreeze for containers. A wrong 'no' in
  that table is invisible — the button simply is not there.

## [0.7.70~beta1] - 2026-08-05

### Fixed
- **Unity: a 302 would have been followed, and it is not a redirect.** Dell's
  own status-code table gives 302 as *Unauthorized* — "authorization error or
  timeout when the `X-EMC-REST-CLIENT` header field is missing or not set to
  true". LWP follows up to seven redirects by default, so the client would
  have fetched the array's web UI, got HTML, and reported *"the body is not
  JSON"* — naming the symptom and hiding the cause, which is a header that
  did not arrive.

  Redirects are now refused outright on this API. That is also the safer
  default on its own terms: every request carries an `Authorization` header,
  and following a redirect is how one reaches a host nobody chose.

  401 is the same error with the header present, so it is now explained as
  the ordinary bad-credentials case rather than as a missing header.

- **Unity: paging rested on a guess.** A collection was walked until a page
  came back shorter than the size asked for. The manual documents
  `with_entrycount=true`, which makes the array report how many instances are
  in the **complete** list — and the array is free to return fewer rows than
  requested, so the short-page rule was never sound. It is now the fallback
  for a firmware that reports no count, not the primary. A silently truncated
  listing is how the orphan reaper comes to treat live volumes as deleted.

### Changed
- An error body is `{error: {errorCode, httpStatusCode, messages}}`, and
  `errorCode` is a **number** — the stable thing to key a decision on, as
  PowerVault's return code is. It is now read out and available; the messages
  beside it are localised into nine languages and are for a human to read.
- 409 and 422 now carry an explanation of what the array meant by them.

## [0.7.69~beta1] - 2026-08-05

### Fixed
- **Unity: a create that returned no id returned `undef`, in silence.** Found
  by driving the client against a Unity REST API emulator, which answers
  `createLun` with **204 and no body**. A real array may do the same under
  some firmware, or answer asynchronously with a job.

  Returning `undef` there is the worst of both outcomes: the volume exists,
  and the caller has no handle to it — so the next thing it does is create a
  second one on top of the first. Every create, clone and snapshot now falls
  back to a lookup by the name it just used, and fails loudly if even that
  cannot answer, saying that the object may exist and to check the array
  before retrying.

### Added
- **A way to exercise a family's client over real HTTP before hardware.**
  `github.com/mackayd/Unity-API-Emulator` is one Python file that speaks
  Unity's envelope, enforces `X-EMC-REST-CLIENT` with a 302 and
  `EMC-CSRF-TOKEN` with a 403, and answers `name:` lookups. It is not a Dell
  product and does not emulate storage behaviour — it proves nothing about
  whether a delete deletes — but it independently confirmed three things this
  client was written to expect, and found the defect above.

  `docs/TESTING.md` says how to run it and, as importantly, what it cannot
  tell you.

## [0.7.68~beta1] - 2026-08-05

### Added
- **Unity XT, as a fourth storage type: `dellunity`.** A customer has a Unity
  480 on Fibre Channel, so this family is written against hardware that
  exists. One VM disk is one Unity LUN, with the array's own snapshots and
  thin clones; dm-multipath, device discovery and every safety check are the
  shared layer's, already exercised on an ME4024 over the same protocol.

  **Nothing here has been run against a Unity array** — but very little of it
  is guessed. Every URI, request body and field list comes from
  `github.com/dell/gounity`, the client Dell's own CSI driver uses, rather
  than from documentation prose. Where the two disagreed the code won: a
  Unisphere page gives the LUN name limit as 85 characters and Dell's client
  refuses anything over 63 before the request reaches the array.

  What that settled, and what shapes the code:

  - **Unity answers a lookup by name directly**, at
    `/instances/lun/name:<name>`. Every other family here needs a server-side
    filter, and an unverified filter that returns nothing is
    indistinguishable from "there is nothing there" — the mistake that hid
    every PowerStore volume once. This family carries none of those defences
    because it does not need them.
  - **`hostAccess` replaces the host list rather than adding to it.** Mapping
    reads the current list and sends the union; unmapping sends the
    difference; both read inside the caller's retry loop, because a list read
    before another node's write and sent after it puts back exactly the state
    that write removed. Sending only this node's host is how a volume gets
    unmapped from every other node in the cluster.
  - **A LUN is read as `lun` and acted on as `storageResource`**, and the
    pool key on a create is `storagePool` — `pool` is only what a LUN reports
    back.
  - **A linked clone is a thin clone of a snapshot**, so a template's marker
    outlives its clones and the array refuses to delete a template while one
    exists.
  - Sizes are bytes, not the 512-byte blocks PowerVault reports.

  120 tests, none of which need an array: 85 against a fake Unity for the
  client, and 35 walking a whole VM's life against a fake that refuses what a
  real one refuses — a LUN with snapshots, a snapshot with a clone reading
  from it, a LUN still mapped, a name over 63 characters. That shape is what
  caught three shipped defects on PowerVault.

  Writing those tests found one: fields are opt-in on this API, so a pool
  that comes back as an empty shell looks exactly like one that was found,
  and the create would have sent a null where the pool id goes.

  `docs/TESTING.md` records every field with where it came from, and the five
  questions only an array can answer — including the SCSI vendor and product
  strings, which decide whether the plugin recognises a device at all.

## [0.7.67~beta1] - 2026-08-05

### Changed
- **The newest release is now the one people find.** GitHub will not call a
  prerelease "Latest", so marking every 0.x one left the green badge on
  whatever old release happened not to be marked — for a while that was
  v0.7.49, three weeks and twenty releases behind, and that is what a first
  visitor saw as current. A stale build presented as the newest is a worse
  signal than a missing badge. Releases are no longer marked prerelease and
  the newest is set as latest explicitly.

  Nothing is lost by this: the release body opens with the beta warning, the
  README opens with it, and the version number says beta on its own.

- **The install URL no longer goes stale.** Every release now carries a copy
  of the package under a name that does not change, so the documented command
  is right forever and never has to be edited:

  ```bash
  curl -LO https://github.com/jasoncheng7115/jt-pve-storage-dellemc/releases/latest/download/jt-pve-storage-dellemc_all.deb
  ```

  GitHub resolves `latest` but not the file name, and every real file name has
  the version in it — so without this, every document naming a download URL
  went stale the moment a release was cut and somebody would follow it to an
  old build. The version is inside the package where `apt` and `dpkg` read it;
  `dpkg-deb -f ... Version` says which one was fetched.

  The versioned copy stays, because that is the name a bug report should
  quote. `SHA256SUMS` lists both, which is why the verify step now passes
  `--ignore-missing`.

## [0.7.66~beta1] - 2026-08-05

### Fixed
- **Every successful delete printed a multipath failure.** Seen twice per
  `qm destroy` on the ME4024:

  ```
  multipath -f /dev/mapper/3600c0ff... failed or timed out,
  trying dmsetup remove --force
  ```

  Nothing had failed and nothing had timed out. `cleanup_lun_devices` removes
  the map by name — `multipathd remove map` — and then calls the flush as the
  belt to that pair of braces; `multipath -f` on a map that is already gone
  exits non-zero, and that was reported as a fault. The flush now checks
  whether the device is still there before saying anything: gone is what was
  being asked for. Anything else, **including not being able to tell**, still
  gets the `dmsetup` fallback — a stat that times out on a dead map is
  exactly the state that fallback exists for.

  A line that appears on every normal operation is worse than no line: it
  reads like a fault, and it buries the case where the flush really did time
  out.

### Changed
- **The project no longer claims that no hardware has run it.** A PowerVault
  ME4024 has, over Fibre Channel, and as of 0.7.65 it passes the whole
  first-run test. The README, the docs site, the phase table and the release
  notes said otherwise in five places. What is *still* unverified is now
  stated instead, because it is most of it: PowerStore and PowerFlex
  entirely, and PowerVault's iSCSI and SAS paths.
- **The release notes explain why no release carries GitHub's "Latest"
  badge.** Every 0.x is a prerelease and GitHub will not mark a prerelease
  latest, so `/releases/latest` does not resolve at all. Deliberate, but not
  obvious to somebody looking for the file to download — so the notes now say
  to take the top of the list, and give a command that resolves the newest
  release with prereleases included.

## [0.7.65~beta1] - 2026-08-05

**The first end-to-end run on real hardware.** A customer took 0.7.64 to a
PowerVault ME4024 (`MIL-ME4024`, firmware `GT280R011-01`, Fibre Channel) and
walked the whole of `docs/FIRST_RUN`. Three defects sat between the storage
coming up and a working disk, each hidden by the one before it.

### Fixed
- **No volume could be mapped: `-10386`.** `map` and `unmap` take an
  *identifier*, and the ME grammar distinguishes three kinds of object by a
  suffix: `<name>` is an initiator, `<name>.*` a host, `<name>.*.*` a host
  group. This plugin sent the bare host name, so the array looked for an
  initiator by that name and, correctly, did not find one — with both
  documented argument orders refused for the same reason.

  Both directions had to change together. The array reports the same grammar
  back in `show maps`, so a nickname arrives as `pve-pve-host15.*`; a
  comparison that does not drop the suffix never matches, and fixing only the
  sending side would have turned "cannot map" into "LUN collision".

- **The second volume collided: `-3177`.** `show maps` answers with a tree
  grouped by volume — the top level is `volume-view`, one entry per volume,
  each carrying its rows under `volume-view-mappings`. There is no top-level
  array of mappings. Indexing straight into one returned nothing, so every
  LUN looked free and the second volume mapped to a host was given an id the
  first already held. Each row now carries down the volume it belongs to,
  which the rows themselves name only by `durable-id`.

  This is the same mistake as the host listing in 0.7.63, in a different
  listing of the same array.

- **Every delete tried to unmap `all other initiators`: `-10007`.** Every
  volume carries one row describing its default mapping, present even when
  there is none: `lun ""`, `access "not-mapped"`, `access-numeric 0`,
  `identifier "all other initiators"`, `nickname ""`. It does not appear in
  the CLI's own table, only in the JSON, and the empty nickname is what
  promoted that display string into the name list. It is now recognised by
  its *access* rather than by the string, which a display layer chose and may
  translate. This plugin never creates a default mapping.

### Changed
- **A mapping recorded at host-group level now counts as using its LUN.** The
  array records one there even when `map` named a host, if that host is the
  group's only member — and such a row holds the LUN against every host in
  the group. PowerStore has handled this since it learned about host groups;
  PowerVault had not. Being wrong this way costs one id out of 255.
- **`show maps <volume>` is checked to have filtered.** The rows now carry
  their volume, so the check is free. On the unmap path an unchecked answer
  means reporting a volume mapped when it is not, and leaving a real mapping
  in place.

### Verified
- `unmap volume initiator <host>.* <volume>`, which the source had marked
  `NOT 0.7.65~beta1IFIED`.
- The WWID rule: `3` + `6` (NAA) + OUI `00c0ff` + `000` + the volume serial's
  characters 7–12 + its last 16. The plugin's computed WWID matched
  `multipath -ll` and `/dev/mapper` on four volumes.
- The WWPN spelling a host object wants: bare hex, comma-separated.
- That a percent-encoded `*` is decoded before the array's CLI sees it, which
  is why the URL escaping needs no exception for the new suffix.
- The whole of `docs/FIRST_RUN`: capacity agreeing with the GUI, several
  allocations with LUNs in sequence, dm-multipath with two paths, `dd` read
  and write through `/dev/mapper` verified by checksum, snapshot, rollback,
  snapshot delete, template, a linked clone in seconds, the array correctly
  refusing to delete a template with a live clone, and unmap, delete and
  local device cleanup.

  This does not make the other two families verified, and it does not make
  iSCSI or SAS verified. That array ran Fibre Channel.

## [0.7.64~beta1] - 2026-08-04

### Verified
- **The ME4024 payloads behind 0.7.63 are now on file.** A customer supplied
  the array's actual `show host-groups` and `show pools` responses
  (PowerVault ME4024, `MIL-ME4024`, firmware `GT280R011-01`, Fibre Channel).
  Both fixes released in 0.7.63 were written from Dell's documentation and
  match what the array sends: the top level carries only `host-group`, hosts
  nest under `host` (singular) and initiators under `initiator`; free space
  is `total-avail` and there is no `avail`.

  The responses are kept verbatim in `t/fixtures/powervault/` and the suite
  now reads them from disk, including the customer's measured 98.56% for the
  pool that previously read as 100% full. `docs/TESTING.md` gained a section
  recording what that array established and what it did not.

### Fixed
- **A host belonging to no host group might still not have been found.** The
  one shape nobody has captured: the ME CLI prints ungrouped hosts in a
  separate block, and which key that becomes in JSON is unknown — which for a
  single-node install is the default case, not an edge case. So the list of
  keys is no longer what decides. Every object in an ME answer names its own
  type in `object-name`, and a row saying `"object-name": "host"` is now
  collected whichever key it arrived under. The converse holds too: a row
  reached through a host key that names itself something else is that other
  thing, never a host.

## [0.7.63~beta1] - 2026-08-04

### Fixed
- **PowerVault: the plugin could not find the host it had just created.**
  Reported from an ME4024. Every activation created the host object, failed
  to find it, asked for it again, and the array refused:

  ```
  command 'create host initiators ... ' failed:
  The specified host name is already in use. (return code -10389)
  ```

  The storage went inactive and stayed there. `show host-groups` answers with
  a tree — host groups at the top, the hosts nested inside them, initiators
  nested again — and this plugin read a top-level `hosts` array that is not
  there. The fallback then returned the host *groups*, whose names are group
  names, so no lookup could ever match.

  The answer is now walked rather than indexed, a group is never handed back
  as a host, and a name differing only in case resolves to the same host the
  array's own uniqueness check would find.

  Because another firmware may answer in a shape nobody has seen yet, there
  is now a second line of defence: the array's own `-10389` is taken as proof
  that the host exists — read from the return code, never from the wording —
  and the question that actually matters for data safety, *are this node's
  initiators on that host*, is settled by asking the array to attach them
  rather than by assuming. If that cannot be established either, the storage
  still refuses: mapping a volume to a host that might belong to another node
  is how two nodes come to write to one disk.

- **PowerVault: every pool reported itself 100% full.** Reported from the
  same array. `pvesm status` showed the storage fully used with nothing
  available, and PVE refuses to allocate into a full pool. The free-space
  field was read as `avail`, which is the column heading `show pools`
  *prints*; the pools basetype documents **`total-avail`**, and the ME4024
  carries no field by the printed name. A field the array does not have reads
  as zero, which is indistinguishable from a genuinely full pool. Older
  spellings are still read, after the documented one.

- **FC: "No FC target ports are visible from this node" on a healthy fabric.**
  Reported from the same node, on every `pvesm status`. The kernel names a
  remote port `rport-<host>:<channel>-<remote>` — a colon after the host
  number, `rport-5:0-3`. The scan asked for three hyphen-separated numbers,
  which matches no entry the kernel has ever created, so the target list was
  always empty and every FC node was told its zoning was wrong.

  The warning also went through a bare `warn` on a path that runs every ten
  seconds per storage per node. It now goes through the once-an-hour path and
  says what was seen, not only what was missing: no remote ports at all
  points at zoning, ports visible but none an online target points somewhere
  else entirely.

### Changed
- `_cmd` gained `allow_codes`: an expected refusal is recognised by the
  array's own return code rather than by its wording. The wording is
  localised, is reworded between firmware revisions, and — twice in this
  project's history — has been text the plugin composed itself.

## [0.7.62~beta1] - 2026-08-04

### Fixed
- **The first defect found on real hardware.** A PowerVault ME4024 could not
  be added at all:

  ```
  GET /show/system returned a body that is not JSON:
  Wide character in subroutine entry at .../Common/REST.pm line 483
  ```

  JSON expects **bytes**; `HTTP::Response::decoded_content` returns
  **characters**. It decodes the body by the Content-Type charset, and for any
  `text/*` without one `HTTP::Message` falls back to ISO-8859-1 — so every byte
  above 0x7F becomes a wide character and `decode_json` dies. The ME CLI
  answers `text/*`, and this array's `/show/system` carried one non-ASCII
  character, which was enough to make the storage impossible to create.

  Every response body is read as bytes now — `decoded_content(charset =>
  'none')`, which undoes gzip but not the charset — in all three families, not
  only the one that failed.

### Added
- **A body that is not JSON is quoted in the error**, up to 200 printable
  characters. On a first hardware run the difference between an HTML error
  page, an empty body and a CLI banner is the whole diagnosis, and "not JSON"
  alone gives none of it.
- `t/02-rest.t` drives every Content-Type these arrays have been seen to
  answer with, including the `text/*` that caused this, and fails on the old
  pairing.

## [0.7.61~beta1] - 2026-08-04

### Fixed
- **`SHA256SUMS` now names the file as it is actually served.** GitHub will not
  serve an asset whose name contains `~` and rewrites it to `.`, so a
  `SHA256SUMS` generated from the Debian file name listed a file that does not
  exist after download — `sha256sum -c` answered *"No such file or directory"*.
  That is precisely what someone following the install instructions would hit,
  and it was found by following them rather than by reading them. The rename
  happens before hashing now, so the asset and the checksum file agree.

## [0.7.60~beta1] - 2026-08-04

### Fixed
- **The release pipeline works again.** Every release since v0.7.36 failed at
  the syntax check and published nothing; half those tags have no release at
  all, and v0.7.53 to v0.7.59 were never created.

  On perl 5.38 — what an `ubuntu-24.04` runner has — `use base` on an absent
  class reports `Base class package "PVE::Storage::Plugin" is empty`, not
  `Can't locate PVE/...`. The latter was the only failure `make syntax`
  tolerated, so the check failed on every module. It tolerates both forms now.

- **`make unit-nopve` runs the syntax check as well as the tests**, with a stub
  that reproduces the real message. The earlier stub appended a newline, which
  changed `base.pm`'s behaviour into a form the check already tolerated — so
  the simulation masked the failure it existed to reproduce, and reported
  success on the exact code CI was rejecting.

## [0.7.59~beta1] - 2026-08-04

### Added
- **The release workflow echoes a failing syntax check as a GitHub
  annotation.** A job's annotations are readable through the public API while
  its logs are not, so a red step was a red step with no visible reason to
  anyone who could not sign in. That is why a CI failure blocking every
  release since v0.7.36 took a customer report to surface.

## [0.7.58~beta1] - 2026-08-04

### Fixed
- **`build-deb.yml` ran its checks with no dependency install step at all.**
  `perl -c` then failed at `Can't locate JSON.pm` — which is not
  `Can't locate PVE/`, the only failure the syntax target tolerates — so the
  job failed on every run, for months. It now installs the plugin's runtime
  Perl modules, as the release workflow already did.
- **`make syntax` names the missing module** when a runtime dependency is
  absent, and says that this is a failure rather than a skip, instead of
  printing a raw compile error and exiting.

### Added
- **`release.yml` runs one check per step.** A job's step list is readable
  through the public API while its logs are not, so a combined *Run checks*
  told nobody outside which of the three had failed — and that was the state
  for twenty releases. It also prints the Perl version and the versions of the
  modules it depends on, so an environment difference is visible without logs.

## [0.7.57~beta1] - 2026-08-04

### Fixed
- **The release workflow has been failing and publishing nothing.** Half the
  tags from v0.7.36 onward have no release at all, and v0.7.53 to v0.7.56 were
  never created — the workflow failed at *Run checks* and every later step was
  skipped.

  A CI runner has no Proxmox VE, so a test that reaches into a plugin has to
  skip rather than die. A block added in 0.7.37 did not, so `make unit` failed
  there while staying green on a PVE node. Nothing local noticed, because
  nothing local ran the suite the way CI runs it.

### Added
- **`make unit-nopve`** runs the whole suite as it runs on a machine without
  Proxmox VE, and `make release-check` now includes it. A green suite that only
  proves the developer's machine works is worth very little.

### Note
`SHA256SUMS` is still absent from published releases. It is a checksum file and
nothing else: **it does not affect installing or running the package.** Its
absence is tracked separately.

## [0.7.56~beta1] - 2026-07-27

### Changed
- **Documentation site: the three family columns of the feature table are
  centred**, headings and values together. Centring the headings alone would
  have left `dm-multipath` sitting at the left of a column whose title is in
  the middle, and centring the values alone is what the spanning rows already
  do — so both, or neither.

  The feature-name column stays left-aligned: that is the column the eye reads
  down. Scoped to this table with a class; the other twelve on the page are
  unchanged.

## [0.7.55~beta1] - 2026-07-27

### Changed
- **Documentation site: the tables have column separators as well as row
  ones.** A value can now be read against its heading instead of by counting
  across, which matters most in the four-column feature table. Applies to all
  thirteen tables on the page.

  The outer edge is left to the wrapper rather than drawn again on the last
  cell of each row, and a cell spanning the whole width takes no separator —
  it has no column to be separated from. Header separators use the stronger
  border colour and body separators the lighter one, so the head still reads
  as the head.

## [0.7.54~beta1] - 2026-07-27

### Changed
- **Documentation site: a value that is the same for every family spans the
  three columns and is centred.** Left-aligned in a spanning cell it read as
  though it belonged to PowerStore — the opposite of what it means. The five
  rows that were three identical ticks are merged as well.

  Rows where the families genuinely differ keep their separate cells, so the
  table now says at a glance which is which: a merged row is the same
  everywhere, a split row is not.

## [0.7.53~beta1] - 2026-07-27

### Changed
- **The documentation installs from the release package first.** Building from
  source is now presented as what it is — something you do to work on the
  plugin or to run the suite against your own PVE version — rather than as the
  first thing an installer reads. The release `.deb` is the build that version
  was tested with. Changed in the docs site, both READMEs and both QUICKSTARTs
  so all four agree.

### Fixed
Checking the live release page found two things the documentation had wrong.

- **`SHA256SUMS` is on no release.** It is listed for upload in the workflow
  and has been since the first one, yet every published release carries only
  the `.deb` — so the verification step the docs asked for could not be
  carried out at all. The workflow now checks the file exists and is non-empty
  before publishing, and sets `fail_on_unmatched_files`, so a release either
  has it or fails loudly.
- **GitHub replaces `~` with `.` in an asset name.** The file is
  `..._0.7.52.beta1-1_all.deb` while the package version is `0.7.52~beta1-1`,
  so any command built from the version number 404s — which is what the
  documented `curl` did. The docs now say to copy the name from the release
  page, and say why.

## [0.7.52~beta1] - 2026-07-27

### Fixed
- **A snapshot named `before-s-after` decoded as a snapshot of a volume that
  does not exist.** PVE validates a snapshot name as `pve-configid`, which
  permits `-`, so that name is one a user can type. On PowerVault and
  PowerFlex, whose snapshot separator is `-s-`, the separator was matched
  greedily and took the **last** one. The snapshot was then invisible to
  `volume_snapshot_list` and missed by the purge that has to run before a
  volume can be deleted — so deleting that volume would have failed with "it
  still has snapshots" and nothing to show which.

  Matching lazily is not the fix: it takes the **first** `-s-`, which breaks a
  storage whose id sanitises to `s`, because then the volume name itself
  contains `-s-`. The volume half is matched by its actual shape now, which is
  the only unambiguous reading.
- **A snapshot name the array would alter is refused rather than silently
  renamed.** PVE keeps the name the user typed and encodes it again on every
  later lookup, so a snapshot stored as `trailing` when `trailing-` was asked
  for is listed under a name that does not match the VM configuration, and a
  later `trailing` collides with it. `trailing-` is a name PVE accepts.

### Changed
- A snapshot name that merely does not **fit** is still shortened, and
  deliberately so: PVE allows 40 characters and a whole PowerVault volume name
  is 32, so refusing that would reject `before-upgrade` on a realistic storage
  id. Shortening is deterministic, so every later lookup still finds it.
- `t/01-naming.t` fuzzes every family's naming with names verified against
  PVE's own `pve-configid` check, and asserts the volume half is always exact
  while the snapshot half is only ever a prefix of what was asked for.

## [0.7.51~beta1] - 2026-07-27

### Fixed
- **Two storage ids that differ only in punctuation produced the same volume
  names.** The storeid is folded into the prefix with `-` becoming `_`, because
  `-` is the separator inside a volume name and an id containing one would make
  decoding ambiguous. That folding is lossy: `ps-1`, `ps.1`, `ps+1`, `ps@1` and
  `ps__1` all become `ps_1`, and `ps1_`, `_ps1`, `ps1!` all become `ps1`.

  Two such storages on one array shared **every** volume name. Each listed the
  other's disks, the ownership gate passed for both, and a `qm destroy` on one
  deleted a volume PVE believed belonged to the other — with nothing visible
  until it happened. `docs/NAMING_CONVENTIONS.md` had described this as
  protection against a related case while this one went unmentioned.

  It cannot be fixed inside the name: a whole PowerVault volume name is 32
  characters and PowerFlex's is 31, and there is nothing to spend. So
  `on_add_hook` refuses to create a storage whose prefix matches one that
  already exists, naming the other storage and what to change — the storage id
  is free at that moment, and a storage that already holds volumes is not.
  Verified through a real `pvesm add` on this node.

### Added
- `t/13-hostile.t` asserts the colliding pairs really do collide, and that one
  storage's ownership gate really does accept the other's volume — so the
  reason for the hook cannot be forgotten and quietly removed.
- `CLAUDE.md` lesson 43: a guard that cannot be expressed in the data can still
  be expressed at the moment the data is created.

## [0.7.50~beta1] - 2026-07-27

### Fixed
- **A protocol a storage type cannot speak is now refused when it is
  configured.** `dell-protocol` is declared once for all three types —
  `PVE::SectionConfig` dies on a duplicate property name and takes every
  storage on the node with it — so its enum lists every protocol any family
  supports. PowerStore accepted `sdc`, PowerFlex accepted `fc`. PowerFlex then
  died on first use with the storage already added and every operation
  failing; the SAN families were worse and simply treated the unknown protocol
  as iSCSI, so a node asked for one data path and silently got another,
  permanently. `on_add_hook` and `on_update_hook` check it now — the only
  place a per-family constraint on a shared property can live — and it was
  verified through a real `pvesm add` on this node.
- **PowerVault: a command with an empty argument is refused by the
  transport.** The ME CLI is positional, so an empty argument is not an empty
  argument: it is a command with one fewer and everything after it shifted up.
  `unmap volume initiator <host> <volume>` with an empty host becomes
  `unmap volume initiator <volume>`, which Dell documents as removing the
  **DEFAULT mapping** — from every host on the array, not just this node.

### Changed
- Confirmed by inspection that neither SAN plugin overrides any PVE-facing
  destructive method: they implement only the `_array_*` methods that
  `BlockBase` calls after its guards, so the guards do apply to them. That is
  the difference from PowerFlex, which inherits nothing and needed each guard
  added by hand in 0.7.48.

## [0.7.49~beta1] - 2026-07-27

### Fixed
- **LXC container snapshots were taken of a live filesystem.**
  `PVE::LXC::Config` freezes a container's mountpoints before a snapshot only
  when the storage answers `volume_snapshot_needs_fsfreeze`. The base class
  answers 0 and this plugin never overrode it — while a container's root is
  mounted *on this host* and being written to as the array snapshots it. The
  result was crash-consistent at best: a journal replay on restore, and writes
  the container believed were committed possibly gone. All three types answer
  1 now, as `ZFSPlugin` does for the same reason.
- **Moving a disk to a storage of another type was refused before any code
  here ran**, along with `pvesm export`/`import` and remote migration.
  `storage_migrate` asks both storages for their common transfer formats, and
  the base class answers "none" for a storage without a `path`. LVM and RBD are
  raw block storage without a `path` too, and both declare `raw+size`; so does
  this now. Transferring snapshots with the volume, and a linked clone on its
  own, are still refused — neither has standalone content to send.

### Added
- `t/15-pve-contract.t` checks both against the installed PVE, including that
  the transfer format matches what `LVMPlugin` offers for a raw volume.
- `CLAUDE.md`: a base method can be wrong here by being *useless* rather than
  by dying. Several return `()` or 0 when `$scfg->{path}` is unset, which
  silently refuses a whole feature. Compare against `LVMPlugin` and
  `RBDPlugin` — the two that are also block storage without a path.

## [0.7.48~beta1] - 2026-07-27

### Fixed
- **PowerFlex had no in-use check anywhere.** It does not inherit `BlockBase`,
  so none of the guards the SAN families have reached it: `free_image` unmapped
  and deleted a volume, `create_base` captured a template, and
  `volume_snapshot_rollback` overwrote a volume — none of them testing whether
  a guest was using it. All three now refuse both when the device is in use and
  when that cannot be established.
- **PowerFlex rollback now flushes the host cache before** the array restores
  the snapshot, and invalidates it after, matching the SAN families.
- **The ownership gate runs in front of PowerFlex's deletes** — the volume, its
  snapshots, and the purge pass.

### Added
- `CLAUDE.md` records every defect this audit found, and a data-safety
  checklist made of the questions that found them: does "could not determine"
  reach a destructive action as "safe"; is "the array did not answer"
  distinguished from "the array said no"; does the guard identify the object or
  only the storage; can an argument change what a command *means*; is the
  operation scoped to one map; is a device confirmed by the kernel before
  being written to; and what can a corrupt state file make an unattended pass
  do.
- `40a`: PowerFlex inherits nothing from `BlockBase`, so a safety rule added
  there has to be added here too. Grep `DellPowerFlexPlugin.pm` before calling
  such a change done.

## [0.7.47~beta1] - 2026-07-27

### Fixed
- **A PowerVault volume name could act as a shell wildcard.** The URL escaping
  left `*`, `?` and `[]` unescaped in *every* argument, because
  `show volumes pattern` legitimately needs them in one. `delete volumes` takes
  its target positionally — so a name of `pve-me5-*` would have asked the array
  to delete every volume of the storage. Only the argument following the
  literal `pattern` token keeps its wildcards now. Nothing generates such a
  name and the ownership gate would refuse it, but the transport should not be
  able to express it either.
- **The temporary-clone reaper could have deleted a real disk.** Its gate was
  "does the name start with this storage's prefix", which every VM disk on the
  storage also satisfies. A corrupt record naming a real disk was enough to
  delete it — unattended, in the background of a poll, with nobody watching.
  A temporary clone is now identified by the infix its name carries, which no
  VM disk has, and the check is applied at both places that remove one.

## [0.7.46~beta1] - 2026-07-27

### Fixed
The three remaining callers of the in-use check now refuse on "could not tell",
finishing what 0.7.45 started:

- **`deactivate_storage`** removed the local devices *and* unmapped the volume.
  A wrong "free" there takes the disk away from a guest still writing to it,
  and disabling a storage is something an operator does while VMs are running.
- **`create_base`**: every linked clone made later reads from the marker
  snapshot taken there. A template captured mid-write is a filesystem that was
  never consistent, copied into every clone of it.
- **The orphan reaper** leaves a device alone rather than removing one it could
  not clear. It runs unattended in the background of a poll: leaving one for a
  human is free, removing one that was in use is not.

### Added
- `t/11-imports.t` fails on `is_device_in_use` used as a bare boolean, because
  `undef` reads as false there and that is the whole bug. The one place where
  the fail-open is harmless — deciding whether to flush before a snapshot —
  now says why at the call site, which is what the guard is for.

## [0.7.45~beta1] - 2026-07-27

### Fixed
- **A safety check that could not answer was answering "safe".**
  `is_device_in_use` returned 0 — not in use — for every way of failing to find
  out: a stat that timed out, unreadable sysfs, a `fuser` killed by its own
  timeout. `fuser` is the only check there that sees a running QEMU, which
  holds the device open with no mount and no holder, so a `fuser` that did not
  run left nothing ruling that out. It now returns 1 / 0 / **undef**, and the
  two destructive paths refuse on undef: `free_image` unmaps before it deletes,
  and a rollback overwrites the whole volume.
- **A rollback now flushes the host cache before the array restores the
  snapshot**, not only after. Dirty pages written back afterwards land on top
  of the restored volume, and the result looks like the rollback half worked.
  `CLAUDE.md` rule 14 has required "flush before, invalidate after" from the
  start; only the second half was implemented.

### Changed
- A rollback of a volume the array reports no WWID for proceeds, and says so
  once. Devices are discovered *by* WWID, so a volume that never had one cannot
  have a device on this node and nothing local can be holding it — but it does
  mean device discovery is broken for that storage, which is worth a line in
  the log rather than silence.

## [0.7.44~beta1] - 2026-07-27

### Fixed
- **An unreachable array made a delete report success.** `free_image` checked
  whether the volume existed inside an `eval` and read *any* failure — including
  a connection timeout — as "it may already have been deleted", then returned
  success. PVE removes the disk from the VM configuration as soon as
  `free_image` returns. So a momentary outage would have left the volume on the
  array with nothing in PVE pointing at it: the data intact, and unreachable.
  "The array says it is not there" and "the array could not be asked" are now
  different answers, and only the first is a successful delete.
- **PowerFlex had the same hole one level deeper.** Its fallback volume listing
  swallowed its own error and returned an empty list, which the caller reads as
  "absent". A fallback that cannot answer must say so, not answer no.

### Added
- **The one device this plugin writes to is now checked twice before `mkfs`.**
  The config-backup volume is resolved from a WWID by a lookup with fallbacks —
  multipathd may be unreachable, and the `/dev/disk/by-id` glob behind it
  matches a substring. Before formatting, the kernel's own identification of
  the device must confirm the WWID (a dm uuid of `mpath-<wwid>`, or the NAA in
  an sd device's `wwid` attribute or VPD page 0x83), **and** the device must be
  small enough to be a 1 MB config volume. Anything that cannot be confirmed is
  refused — a skipped config backup is already treated as non-fatal, which is
  the right price against formatting a running VM's disk.

## [0.7.43~beta1] - 2026-07-27

### Fixed
- **The ownership gate is now actually a gate.** `is_pve_managed_volume` was
  defined, documented as guarding every destructive path, and tested
  directly — and called from nowhere at all. It now runs in front of every
  array-side delete of a volume or a snapshot, with the storeid, on the
  family's own naming class so each family's separators apply. Wiring it in
  immediately showed its own definition was incomplete: it refused temporary
  snapshot-access clones, which this plugin generates and must be able to
  delete again.
- **The documentation site defaults to English on every visit.** The language
  choice was kept in `localStorage`, so one click months ago decided what every
  later visitor using that browser saw. It now follows the visit rather than
  the browser, the stale preference is cleared on load, and `?lang=` still
  works for sharing a specific language.
- **PowerFlex SDC support on Proxmox VE is stated accurately.** Dell ships the
  packages and documents the procedure — KB 000462918 names Proxmox VE and the
  SDC tarball carries a `Debian13_SDC` variant — but Proxmox VE is **not** in
  the OS support matrix, KB 000272738, at any PowerFlex version. The docs
  reported the first as though it were the second. Both KBs are now linked so
  a reader can check rather than trust.

### Added
- `t/11-imports.t` fails on a subroutine defined twice in one file.
- The reasoning behind the bare `-b` tests in `PowerFlex/Host.pm` is written
  down: they are bounded by an alarm the function owns, covering the glob and
  every test in the loop, and `is_block_device` would replace that single
  budget with an unbounded number of bounded steps.

## [0.7.42~beta1] - 2026-07-27

### Fixed
- **No multipath operation touches a map this plugin does not own**, except
  one that cannot be narrowed. `multipathd reconfigure` re-reads every
  configuration file and reapplies it to every map on the node — other
  vendors' storage and an operator's own hand-built maps included — and it was
  being used to make a newly-mapped LUN appear: **on a timer** in
  `activate_storage`, and on every device wait. Both are gone. A new LUN is
  claimed with `multipathd add path <sdX>`, for the paths of that one WWID.
- The one remaining node-wide reconfigure runs only after this plugin's own
  `conf.d` drop-in changes — multipathd has no per-file reload — and it now
  says in the log that it is node-wide, and why it is unavoidable there.

### Added
- `make check-multipath-flush` also fails the build on the `multipathd` form
  of a node-wide flush, which this plugin must **never** generate. It removes
  every unused map on the node — other vendors' storage included — under a
  name the old guard did not recognise.
- `t/03-multipath.t` asserts that exactly one node-wide reconfigure remains in
  `BlockBase`, and that claiming a WWID's paths issues no reconfigure at all.
- `t/11-imports.t` fails on a subroutine defined twice in one file. Perl keeps
  the last definition and warns on every load — once per `pvesm` call — while
  the first becomes dead code that still reads like the live one. A helper
  added during this work hit exactly that; it is gone, and the module's
  existing one is used instead, which is vendor-gated and strictly better.

## [0.7.41~beta1] - 2026-07-27

### Added
- The "device did not appear" diagnostic names `find_multipaths` when that is
  what happened. Debian defaults it to `strict`, and with that setting
  multipathd builds no map for a LUN it can only see one path to — which is
  exactly what a first hardware test with one iSCSI session or one HBA port
  looks like. The message reported "by-id links yes, map no" and left the
  operator to connect the two; it now says so, with the setting's actual value
  read from multipathd's own merged configuration.

## [0.7.40~beta1] - 2026-07-27

### Fixed
- **PowerStore snapshot dates could have been hours out.** A
  `creation_timestamp` carries an explicit zone offset — Dell's own sample
  response ends `+00:00` — and the offset was parsed off and discarded rather
  than applied. On an array reporting anything other than UTC, a node in UTC+8
  would have seen every snapshot dated eight hours wrong: the kind of wrong
  that looks like a bug in PVE and is not one. Fractional seconds, `Z`, a bare
  timestamp and both offset spellings are all handled now.

### Changed
- `docs/TESTING.md` marks which PowerStore **response** fields Dell's own
  sample payloads corroborate, and leaves the rest explicitly unverified. The
  volume sample settles `id`, `name`, `size` (bytes), `wwn` (in `naa.` form),
  `state`, `type`, `appliance_id`, `logical_used`, and `protection_data` with
  its `source_id`. The WWN still needs comparing against a host's own
  `scsi_id`, which is the one thing a sample payload cannot answer.

## [0.7.39~beta1] - 2026-07-27

### Changed
- **The whole PowerStore request surface is confirmed against Dell's own code.**
  `python-powerstore` lists every endpoint path verbatim and sends exactly the
  request bodies this plugin sends; `ansible-powerstore` documents the
  `port_type` and `os_type` enums. All of them already matched. That is now
  written down in `docs/TESTING.md`, so a first tester knows which failures
  cannot be a wrong request shape — and what remains unverified is the
  **response** field set, which is what the field-name table is for.

### Fixed
- `volume_create` passed no options through to the transport, so a per-call
  timeout had no effect on it.

## [0.7.38~beta1] - 2026-07-27

### Fixed
- **PowerStore could not have reported its capacity.**
  `space_metrics_by_cluster` was read as a REST collection. It is an *entity
  name* for the metrics service, which is reached with
  `POST /metrics/generate` and `{entity, entity_id, interval}` — that is the
  documented form and what Dell's own SDK sends. On an array that does not
  also expose the series as a collection, `status()` returned undef and the
  storage showed as **inactive** with nothing else wrong with it. The
  documented form is tried first, the collection form second, per-appliance
  third, and the failure message names all three.
- **The newest metrics record is the current one.** PowerStore returns them
  oldest first, so taking the first row reported the capacity of whenever the
  window started.

### Changed
- Every REST endpoint this plugin uses is confirmed against Dell's own
  `python-powerstore` SDK, which lists them verbatim in
  `PyPowerStore/utils/constants.py`. `docs/TESTING.md` records that, and
  records where to look when Dell's documentation site refuses: Dell's code.

## [0.7.37~beta1] - 2026-07-27

### Fixed
- **PowerFlex NVMe/TCP could not have connected at all** — and NVMe/TCP is this
  family's default data path. Two reasons, both settled by reading Dell's own
  `ansible-powerflex` module, which shows a real SDT object:
  - **The host connected to `storagePort`.** An SDT publishes `nvmePort` 4420,
    `storagePort` 12200 and `discoveryPort` 8009. `storagePort` carries
    SDS-to-SDT traffic; the port a host connects to is `nvmePort`. Every
    `nvme connect` would have been refused, and no namespace would ever have
    appeared.
  - **The subsystem NQN was read from the SDT, which has no NQN field.**
    `nvme_connect` croaks without one, so `activate_storage` would have died
    before connecting anything. It comes from `nvme discover` against the
    discovery port now — once per storage, then cached — and the discovery
    subsystem's own NQN is skipped.
- A host no longer connects to an SDT address whose role is `StorageOnly`. An
  address with no role at all is still used, so an unfamiliar firmware does not
  leave a node with no paths.

### Changed
- `docs/TESTING.md` records the SDT field names, the three ports and the
  address roles, each with what Dell's module actually shows.

## [0.7.36~beta1] - 2026-07-27

### Fixed
- **PowerFlex volume creation now survives either spelling of the size
  parameter.** The ScaleIO REST reference documents `volumeSizeInKb`; Dell's
  own `python-powerflex` SDK sends `volumeSizeInGb`. Creating a volume is the
  very first thing anyone does with this plugin, so an array that accepts only
  the other spelling would have stopped the first `pvesm alloc`. The documented
  form goes first and the SDK's form is the fallback, with a line in the log
  saying which one the array took.
- The fallback is taken **only on a 4xx**, which means the array rejected the
  request and created nothing. A 5xx may have taken effect, and a second
  attempt there would be a second volume — so those are not retried, the same
  rule the transport already applies to every POST.

### Changed
- Several PowerFlex field names are no longer marked unverified.
  Dell's own `ansible-powerflex` collection documents `ancestorVolumeId`,
  `creationTime`, `protectionDomainId`/`protectionDomainName`, and the contents
  of `mappedSdcInfo` (`sdcId`, `sdcName`, `sdcIp`, `accessMode`, `limitIops`).
  The same source confirms the 8 GB allocation unit and that the array rounds
  **up**, which is what this plugin already does.
- `setVolumeSize` with `sizeInGB` and `removeVolume` with `removeMode` are
  confirmed against the same SDK and are now recorded in the module header.

## [0.7.35~beta1] - 2026-07-27

### Fixed
- **Every command this plugin runs now runs in the C locale.** util-linux
  ships translations, so on a node running `zh_TW` — exactly the kind of node
  this plugin is written for — `fuser -v` answers in Chinese and every parser
  written against its English output silently matches nothing. Nothing fails
  and nothing is logged; the information simply stops arriving, which is how
  the "which process holds this device" line was blank for a different reason
  two releases ago.
- `pve-dell-config-get` pins it too, so a mount failure during recovery reads
  the same on every node.

### Added
- A test asserts the locale is pinned in each of the three modules that run
  commands.

## [0.7.34~beta1] - 2026-07-27

### Fixed
- **A node with no iSCSI configured would have warned on every rescan, in any
  locale but English.** Whether `/sys/class/iscsi_session` was simply absent
  was decided by matching `$!` against `No such file or directory`. `strerror`
  is rendered in the node's locale, so with a non-English `LC_MESSAGES` the
  match finds nothing and "there is no iSCSI here" is reported as "cannot
  enumerate iSCSI sessions". The errno decides now, through `%!`.

### Added
- A test asserts that nothing in the iSCSI code matches `strerror` text.
  Comments may name the string; code may not.

## [0.7.33~beta1] - 2026-07-27

### Fixed
- **No existence check decides its answer by reading the words an array
  chose.** Three did: PowerFlex `volume_get` and `volume_id_by_name`, and
  PowerVault `volume_get_by_name`, all matching `/not found/` against the
  error. An array saying "storage pool not found" about a wrong pool would
  have been read as "this volume is gone", and what a caller does next with
  that answer is create a second one.
- They read the status code now, or ask a question that cannot be
  misunderstood. On PowerVault, where the CLI reports a missing volume as an
  error rather than an empty list, a pattern listing that succeeds without the
  name in it is the proof — and if the listing fails too, the array's original
  error is raised rather than guessed at.

### Added
- `get_or_undef` in the REST layer: undef for the status codes that mean
  absent, decoded JSON otherwise, and no message read anywhere.
- `t/11-imports.t` fails on any new decision made by matching an array's error
  text. This is the third time the project has made that mistake — after a 422
  hint containing the word "clones", and `add host-members` containing
  "member" — so it is now a rule with a test behind it rather than a lesson.

## [0.7.32~beta1] - 2026-07-27

### Fixed
- `volume_has_feature` no longer dies on a volume name it cannot read. It is
  called in a loop over a VM's configuration, so a die there aborts the whole
  operation over a question that was never what failed.
- `pve-dell-config-get` detaches only the volume it attached itself. A volume
  already mapped to this node was mapped by something else, for a reason the
  tool does not know, and unmapping it on the way out was a change nobody
  asked for.

## [0.7.31~beta1] - 2026-07-27

### Fixed
- **A linked clone could not have been snapshotted or renamed.**
  `volume_has_feature` decided whether a volume was a base image by whether
  its name starts with `base-`. A linked clone is named
  `base-100-disk-0/vm-101-disk-0`: it starts with `base-` while being the
  least base-like volume on the storage. Every linked clone was therefore
  answered as a base image, and PVE refuses `qm snapshot` and a rename
  outright when the plugin says no — with "the feature is not available on
  this storage" and nothing to debug. It comes from `parse_volname` now, which
  is how `RBDPlugin` does it.

### Added
- `t/15-pve-contract.t` checks what each plugin answers for a linked clone,
  alongside the `parse_volname` comparison added in 0.7.30. Both failures had
  the same root: a volname form that two things disagreed about.

## [0.7.30~beta1] - 2026-07-27

### Fixed
- **Moving a linked clone's disk to a storage of another type would have
  failed.** `parse_volname` returned the whole volname as its name element for
  a linked clone. `PVE::Storage::storage_migrate` builds the target volume name
  out of that element, so the target storage would have been asked for a volume
  named `base-100-disk-0/vm-101-disk-0` — naming a base image it has never
  heard of. It returns the leaf name now, which is what `RBDPlugin` returns for
  the same two-part volname form.

### Added
- `t/15-pve-contract.t` compares this plugin's `parse_volname` against
  `RBDPlugin`'s directly, on the installed PVE. The contract cannot drift back
  without a test saying so, and it names the plugin it is being measured
  against rather than a value someone once wrote down.

## [0.7.29~beta1] - 2026-07-27

### Fixed
- **A PowerStore host that belongs to a host group would have been given a LUN
  id already in use.** A `host_volume_mapping` made to a group carries
  `host_group_id` and no `host_id`, and such a mapping occupies a LUN id on
  every host in the group. The LUN search looked only at host-level mappings,
  so it handed out an id the group already held; the mapping check called the
  volume unmapped and attached it again. This plugin never creates a host
  group, but nothing stops an operator putting its host into one.
- An unmap that finds only a group-level mapping now says so, naming the
  group, instead of returning as though there were nothing to remove.

### Added
- `docs/TROUBLESHOOTING.md` carries the numbers from
  [Dell KB 000199943](https://www.dell.com/support/kbdoc/en-us/000199943/):
  ESXi scans LUN ids 0–1023 by default, **Linux with the Emulex FC driver only
  0–255**. That is why this plugin stops at 255 rather than at whatever the
  array allows, and a test now pins the ceiling with the reason attached.

## [0.7.28~beta1] - 2026-07-27

### Fixed
- **A PowerFlex volume mapped to an NVMe host could have looked unmapped
  forever.** A mapping entry names its target as an SDC id or a host id, and
  an entry may carry both; the code read `sdcId // hostId` and dropped the
  other. A node that goes by its host id would have found the volume unmapped
  on every activation, mapped it again, and later unmapped it by an id that
  was not the one holding it. Every id an entry names is now collected, and
  `mappedHostInfo` is read alongside `mappedSdcInfo`.
- PowerVault host lookup by name matches both spellings a row may carry
  instead of whichever is defined first. The same shape, for the same reason:
  it is the fourth time this project has had it.

### Changed
- `t/16-docs.t` now also sees fields read through a variable. A `qw()` list of
  field names was invisible to it, which is exactly how `mappedHostInfo` could
  have reached a release with no line in the table it is supposed to be in.

## [0.7.27~beta1] - 2026-07-27

### Fixed
- **The PowerVault field order from 0.7.26 was wrong about which name is
  documented.** `show volumes` *prints* the columns Total Size and Alloc Size,
  but the volumes basetype — the property names the JSON actually carries —
  documents `size`, `total-size` and `allocated-size`, each with a `-numeric`
  twin in 512-byte blocks. Those lead again; the column headings stay as later
  fallbacks. Nothing broke in 0.7.26, because the fallback chain covered it,
  but the ordering said the opposite of what Dell documents.

### Changed
- `creation-date-time-numeric` is no longer marked unverified: the volumes
  basetype documents it as an unformatted creation timestamp.
- `docs/TESTING.md` states the distinction that made the guess wrong in the
  first place: **a printed column heading is not a property name.** It was for
  `Avail`; it is not for `Alloc Size`.

## [0.7.26~beta1] - 2026-07-27

### Fixed
- **The second volume mapped to a PowerVault host would have collided with the
  first.** `next_free_lun` took whichever identity field a mapping row defined
  first and compared it against the host — and a real row defines both
  `identifier` (the initiator's IQN or WWPN) and `nickname` (the host name).
  An IQN never equals a host name, so no row ever matched, every LUN looked
  free, and the next mapping was handed a LUN already in use. It now matches
  any identity the row carries, without regard to case.
- **PowerVault used space read as zero.** `show volumes` documents its columns
  as **Total Size** and **Alloc Size**; the code looked for `size` and
  `allocated-size` first. The older spellings are still accepted, behind the
  documented ones.

### Changed
- The comment saying `show maps` has no host-name column was wrong. The
  `volume-view-mappings` basetype documents `nickname` as the host or host
  group name — blank when unset, which is why the initiator id is still
  matched alongside it.
- `docs/TESTING.md` records the `show volumes` output columns, the
  `volume-view-mappings` and `initiator-view` properties, and that `pattern`
  takes shell-style wildcards and matches names *containing* the string.

## [0.7.25~beta1] - 2026-07-27

### Fixed
- **A volume deleted on another node during a listing would have failed the
  listing.** The total number of rows comes from the first page, so paging can
  legitimately ask for an offset past the end of a collection that shrank
  underneath it. Dell documents that as `416 Range Not Satisfiable`, and the
  client treated it as it treats any other 4xx: fatal. Paging now ends there
  and keeps the pages already read.
- **The iSCSI portal lookup no longer rests on an unverified filter
  operator.** It asked for addresses with `purposes=cs.{Storage_Iscsi_Target}`;
  `cs` and its brace literal have never been seen answered by a real
  appliance. An operator the array rejects or reads differently returns
  nothing, which here means no portals, no iSCSI login, and no devices —
  without anything in the logs saying why. When the filtered query finds
  nothing, every address is now fetched and the purpose matched locally, with
  one warning naming the cause.

### Added
- `allow_status` in the REST layer: a caller that knows what a particular
  refusal means can act on the status code itself, rather than on the wording
  of the message the array wrote.
- `docs/TESTING.md` records the pagination rules read from the developers
  guide — `limit` 1 to 2000 (100 by default), `offset`, the `Range` header,
  `206` with `Content-Range`, and `416` for an offset past the end.

## [0.7.24~beta1] - 2026-07-27

### Fixed
- **PowerStore volumes would have been invisible to PVE.** The name-prefix
  filter used `%` as the `ilike` wildcard. Every example in the Dell PowerStore
  REST API Developers Guide spells that wildcard `*` — and a wildcard the array
  reads as an ordinary character matches nothing, so the volume listing would
  have come back empty while the array still held every volume. Nothing would
  have failed: an empty listing is exactly what a storage with no volumes
  looks like.
- **The DELL-EMC-TOKEN is now refreshed from any response that carries one.**
  Dell documents the CSRF token as something to obtain with a GET before each
  write, which leaves open whether the array reissues it as a session goes on.
  If it does, holding the login-time token would have failed every write while
  every read kept working — a failure that reads as a permissions problem.
- Clearing a PowerStore session now empties the cookie jar, so a re-login
  after a 401 does not present the rejected `auth_cookie` alongside fresh
  credentials.

### Changed
- A PowerStore name-prefix listing that comes back empty is retried once
  without the filter and matched locally, with a single warning naming the
  cause. Whichever wildcard form an appliance accepts, the plugin can no
  longer lose volumes over it.
- A name filter the array applies more broadly than a prefix can no longer
  pull another storage's volumes into this one's listing: the prefix is
  rechecked on every row that arrives.
- `docs/TESTING.md` now records what has been read from the PowerStore
  developers guide — the session and CSRF rules, the filter form, the operator
  list, the wildcard — so a first tester can tell it apart from what is still
  inferred.

## [0.7.23~beta1] - 2026-07-27

### Added
- **A table of every field name the API clients read**, in
  `docs/TESTING.md`: what each is used for, and whether it has been read from
  Dell's documentation or only inferred. The two worst defects found before
  the first hardware run were both field names that do not exist, and neither
  failed loudly — one made every PowerVault pool look full, the other made the
  mapping check always answer no. The table exists so that one pass over a
  real response can settle all of them at once.
- `t/16-docs.t` fails when a field the code reads is missing from that table,
  so it cannot quietly fall out of date.

## [0.7.22~beta1] - 2026-07-27

### Fixed
- **Every PowerVault pool would have looked completely full.** `show pools`
  reports Total Size, Avail and Snap Size. The code looked for a field named
  `avail-size`, which does not exist, so available space read as zero and used
  space as the entire pool — PVE would have refused to allocate anything and
  the capacity alert would have fired on the first poll. It reads `avail` now,
  with the other spellings kept as fallbacks.

## [0.7.21~beta1] - 2026-07-27

### Fixed
- **The "device is still in use" message could never name the process.**
  `fuser -v` prints its table to stderr and only the bare PID list to stdout,
  and only stdout was being read. The rest of that message does real work —
  it names the holders, works out which LVM volume group the host activated
  from inside the guest disk, and gives the `vgchange -an` to undo it — but
  the one line saying *which process* has the device open was silently empty.

## [0.7.20~beta1] - 2026-07-27

### Fixed
- **The package did not depend on LWP's HTTPS driver.** `libwww-perl` speaks
  HTTPS only when `liblwp-protocol-https-perl` is installed — on Debian it is
  a package of its own — and it was present on every PVE node only because
  `pve-manager` happens to depend on it. Nothing guaranteed that. Without it
  every request to an array fails with `501 Protocol scheme https is not
  supported`, which says nothing about what to install. It is now a declared
  dependency, and the REST client checks for it and names the package.

## [0.7.19~beta1] - 2026-07-27

### Fixed
- **The release workflow could not have run the tests it claims to run.** It
  installed `build-essential`, `debhelper` and `fakeroot` and nothing else, so
  every test that loads an API client would have died at compile time on a
  runner without `libwww-perl`. The plugin's own runtime dependencies are
  installed there now, and those tests skip with a stated reason rather than
  failing if the modules are absent — a green run that tested nothing is worse
  than a red one.

## [0.7.18~beta1] - 2026-07-27

### Added
- `docs/FIRST_RUN.md` and its Traditional Chinese counterpart: what to do on
  the first run against a real array. The order to work through, what to look
  at after each step, and what each failure most likely means — written around
  the four things everything else depends on and which were inferred rather
  than read from Dell's documentation: the SCSI vendor and product strings
  that gate every device, the WWN-to-WWID conversion, the portals the array
  publishes, and the multipath drop-in. It also says plainly which refusals
  are deliberate, so a correct refusal is not mistaken for a defect.

## [0.7.17~beta1] - 2026-07-27

### Fixed
- **PowerVault would have re-added an initiator on every host check.** Whether
  a host already had this node's initiator was decided by reading flat fields
  on the host object, but `show host-groups` nests initiators inside hosts —
  each with Nickname, Discovered, Mapped, Profile, Host Type and ID. The check
  therefore always said no, and the array refuses to add a member it already
  has; that refusal fails `activate_storage`, so a working storage would have
  gone inactive. The id is now looked for anywhere within the host structure,
  whatever shape the firmware uses, and a refusal meaning "it is already how
  you want it" is accepted rather than fatal.
- **iSCSI ports the array calls unusable are no longer offered to the login
  loop.** `show ports` reports Media, Target ID — the node name for an iSCSI
  port — Status (Up, Warning, Error, Not Present, Disconnected), IP Address
  and Health. Only Media and the address were being read, so a disconnected
  port cost this node a probe at best and a discovery plus login timeout at
  worst.
- **A tolerated refusal is matched against the array's own words only.** The
  rendered error also carries the command that failed, and a command named
  `add host-members` matches any pattern looking for the word "member" — the
  same trap that made template deletion impossible until 0.7.12.

## [0.7.16~beta1] - 2026-07-27

### Fixed
- **PowerVault could not tell whether a volume was already mapped to this
  node.** `show maps` reports one row per initiator, with the columns Serial
  Number, Name, Ports, LUN, Access, Identifier, Nickname and Profile — there
  is no host-name column, so comparing a row against a host name always
  answered no. Every activation would have mapped the volume again and taken
  another LUN, which on this family is exactly the churn that makes new disks
  stop appearing. A row is now matched by the host name *or* by any of this
  node's own initiator ids, and the same identities are used when unmapping,
  since `unmap volume initiator` accepts an initiator, a host or a host group
  alike.

### Changed
- Four more commands were read from the ME5 CLI Reference Guide and found
  correct as written: `create snapshots volumes <volumes> <snap-names>`,
  `delete snapshot <snapshots>`, `expand volume size <size> <volume>` — where
  the guide confirms the size is "the amount of space to add to the volume",
  not the new total — and `show maps`.

## [0.7.15~beta1] - 2026-07-27

### Fixed
- **`map volume` differs between ME4 and ME5**, and both orders are from
  Dell's own CLI Reference: ME5 documents the volume last, ME4 documents it
  first. This plugin targets both families, so it sends the ME5 form and falls
  back to the ME4 one if the array refuses it — mapping is the operation no
  volume can be used without. An array that wants the other order says so in
  the journal once.
- `show volumes` sends its parameters in the order the guide gives them.
- `docs/ARCHITECTURE.md` named the wrong tests for the abstract interface and
  the property-declaration rule, and was missing the overrides added since it
  was written.

### Changed
- The host commands corrected in 0.7.14 were re-checked against the ME5 guide
  as well as the ME4 one. Both families document them identically, so that
  fix is right for both — worth confirming, since `map volume` proves the two
  guides do not always agree.

## [0.7.14~beta1] - 2026-07-27

### Fixed
- **PowerVault would not have come up at all.** Two commands on the first
  activation of a storage were written from inference rather than from Dell's
  CLI Reference Guide, and both were wrong:
  - creating a host is `create host initiators <list> <name>`; it was sending
    `create host id <list> <name>`.
  - attaching an initiator to an existing host is
    `add host-members initiators <list> <host>`. It was sending
    `set initiator host <host> <initiator>`, which is a different command —
    `set initiator` names an initiator and sets its profile, and attaches it
    to nothing — and was not valid syntax either.

  Both now match the guide, and every missing initiator is added in one
  command rather than one per initiator.

### Changed
- Four other PowerVault commands were read from the same guide and found
  correct as written: `delete volumes`, `set volume name <new> <volume>`,
  `unmap volume initiator <hosts> <volumes>`, and the 32-byte name limit.
  Two useful details came with them: `delete volumes` only prompts in
  interactive console mode, so a script needs no confirmation flag; and
  omitting the initiator from `unmap volume` deletes the *default* mapping
  rather than an explicit one, which is why this plugin always names the host.
- `docs/TESTING.md` now separates what has been read from Dell's documentation
  from what is still inferred.

## [0.7.13~beta1] - 2026-07-27

### Added
- `t/19-powervault-lifecycle.t` completes the set: each of the three families
  now has a whole VM's life tested against a fake array that enforces that
  family's own rules. PowerVault's model is the strangest of the three — a
  snapshot is a first-class volume in the same namespace, so a linked clone is
  a snapshot wearing a volume name — and the fake enforces what Dell's
  Administrator's Guide states: a volume or snapshot with child snapshots
  cannot be deleted until the children are.
- The lifecycle tests assert the order of the four values `status()` returns.
  PVE wants total, available, used, active; the arrays report total, used,
  available. Swapping two of them is invisible except as wrong numbers in the
  GUI.

## [0.7.12~beta1] - 2026-07-27

### Fixed
- **Deleting a template could never succeed on PowerStore or PowerFlex.**
  Whether to remove the template marker was decided by reading the array's
  refusal text, and both families use the same wording for "this volume still
  has a snapshot" and "something was cloned from it". On PowerStore it was
  worse: the hint this plugin appends to a 422 contains the word `clones`, so
  the rule matched its own text and the marker was never removed — leaving the
  volume undeletable for good. The array decides now. A linked clone is a
  clone *of the marker*, so an array that still has one refuses to delete it;
  trying and being refused is both safe and the only reliable test.
- **Operator-facing messages end at a newline.** Without one Perl appends
  ` at /usr/share/perl5/PVE/Storage/Custom/... line 1234.`, which in a PVE
  task log is noise in front of the person trying to work out what to do.

### Added
- `t/18-powerflex-lifecycle.t`: a whole VM's life on PowerFlex, which has its
  own allocation, cloning, snapshot and delete paths and so was untouched by
  the lifecycle test added in 0.7.11. The fake array behaves as PowerFlex
  does — volumes addressed by id, a snapshot is a volume with an ancestor,
  and a volume with descendants cannot be removed — which is what exposed the
  template deletion above.
- `t/11-imports.t` also fails on a `die` whose message does not end at a
  newline.

## [0.7.11~beta1] - 2026-07-27

### Fixed
- **Deleting a template with a linked clone blamed the wrong thing.** The
  message said the volume still had snapshots, which was the array's answer
  about the volume; the array's answer about the snapshot said what actually
  mattered — it has dependent clones. The snapshot's refusal is now carried
  into the message, so the operator is told which object is in the way rather
  than being sent to look for snapshots to delete.

### Added
- `t/17-lifecycle.t`: a whole VM's life against an array that refuses what a
  real one refuses. Create two disks, resize, snapshot, roll back, refuse a
  rollback past a newer snapshot, make a template, take a linked clone, refuse
  to delete the template while the clone exists, delete both, destroy a VM
  whose disks still have snapshots, and read a snapshot through a clone and
  then delete it — checking after every step that the array holds exactly what
  it should and that nothing is left mapped.

## [0.7.10~beta1] - 2026-07-27

### Fixed
- **PowerFlex connected to every NVMe/TCP target on every poll.** PVE calls
  `activate_storage` on every pvestatd cycle, and it ran `nvme connect` once
  per target published by the array. Connecting to an address that is already
  connected succeeds, so nothing looked wrong — but that is one process per
  address six times a minute per node, each carrying a 30 second timeout when
  the network is degraded. It now reads the existing paths once and connects
  only what is missing; with everything connected it forks nothing. A target
  that stays unreachable is retried on the rescan interval instead of every
  poll — unless no path is up at all, when it is retried immediately, because
  the storage is unusable until one comes up.
- **The storage pool was validated twice per poll.** `activate_storage`
  listed every pool on the array to check the configured one exists, and
  `status()` listed them again on the same poll to report capacity. The check
  in `activate_storage` is now rate-limited; a pool that disappears is still
  caught by `status()` on the next poll.

## [0.7.9~beta1] - 2026-07-27

### Fixed
- **`pve-dell-config-get --insecure` did nothing.** Both branches of the
  expression behind it produced the same value, so certificate verification
  was off whether or not the flag was given. It stays off by default in
  recover mode — that matches the plugin's own `dell-ssl-verify` default, and
  a certificate error while recovering from an outage is an obstacle rather
  than a protection — and `--verify-ssl` turns it on. Both flags now also
  apply when the array details come from `storage.cfg`.
- **`pflex-protection-domain` was only a tie-breaker.** It was consulted when
  a pool name was ambiguous and ignored when it was not, so a storage
  configured with a domain could still be pointed at a pool in a different
  one. It is a requirement now, and a pool that is not in the named domain is
  refused with the domains it was found in.
- An endpoint that manages more than one PowerFlex system says so instead of
  silently using whichever appeared first.
- A REST client built without a type no longer adds an uninitialised-value
  warning on top of the error it was reporting.

### Added
- `docs/TESTING.md` says where each unverified endpoint can be checked:
  PowerStore publishes Swagger UI on the array itself at
  `https://<mgmt-ip>/swaggerui`, and the PowerVault commands can be tried over
  SSH before the plugin sends them over HTTPS.
- `t/16-docs.t` runs the recovery tool's `--help`. Getopt::Long validates its
  option table when it is called rather than when the file compiles, and an
  outage is the worst moment to discover a broken one.

## [0.7.8~beta1] - 2026-07-27

### Fixed
- **The PowerFlex options were undocumented.** All five, including
  `pflex-storage-pool`, which is required and which PowerFlex has no default
  for. `docs/CONFIGURATION.md` and its Traditional Chinese counterpart now
  describe them, together with the family's 8 GiB allocation unit, its
  31-character name limit, and what choosing between NVMe/TCP and the SDC
  actually commits you to.

### Added
- `t/15-pve-contract.t`: reads the installed `PVE::Storage::Plugin` and fails
  if this plugin would inherit a base method that reaches for
  `filesystem_path` or that dies by default, if its API version claim falls
  outside what the running PVE accepts, or if two of the three plugins declare
  the same property name — which makes PVE die while building the storage
  schema and takes every storage on the node with it. A PVE upgrade that
  changes any of this now fails here rather than in production.
- `t/16-docs.t`: fails when an option exists but is not documented, when the
  documentation names an option that does not exist — an operator who copies
  that into `storage.cfg` has the whole storage refused — or when a document
  has no counterpart in the other language.
- `make release-check` also checks the READMEs and the documentation site now,
  including the version badge and whether the site has a changelog entry for
  the release being made.

## [0.7.7~beta1] - 2026-07-27

### Fixed
- **Names are anchored exactly.** Perl's `$` also matches immediately before a
  trailing newline, so `"vm-100-disk-0\n"` passed a pattern meant to be exact
  and resolved to the same array object as the clean name. Every name pattern
  in the plugin now ends at `\z`.
- **A run of digits too long to be a vmid is refused.** Perl turns it into a
  float on first numeric use, so a volume named with thirty nines decoded to a
  vmid of `1e+30` — which would then travel inside a volid.
- **A listing row that is not a hash no longer kills the caller.** Dereferencing
  it raised a Perl type error rather than skipping the row, so one unexpected
  response shape would have taken out the whole listing.

### Added
- `t/14-parsing.t`: missing, renamed and wrongly typed fields thrown at every
  parser — WWN conversion, the PowerVault CLI status object, size fields,
  volume rows, array object names, and PVE volume names. Every field name in
  these clients comes from documentation rather than from an array, so some
  will be wrong; the test asserts that a wrong one fails safe rather than
  being acted on.

## [0.7.6~beta1] - 2026-07-27

### Fixed
- **A file test on a device path can block.** `-b` is a stat, and on a
  multipath device whose paths have all failed while queueing is still on,
  that stat lands in the same uninterruptible sleep that hangs `vgs`. Every
  such test now goes through `Multipath::is_block_device`, which bounds it —
  and restores any alarm the caller had running, since nesting `alarm()`
  without that silently cancels the caller's own timeout, which is worse than
  the hang it guards against.
- **`volume_resize` waits for the array to report the new size** before
  touching the host side. A per-device rescan issued while the resize is
  still running leaves the kernel with the old capacity, and QEMU's
  `block_resize` then fails with "Cannot grow device files" on a volume that
  grew. The wait is bounded and the host-side refresh happens either way.

### Changed
- The package removal script names the storages that will stop working, read
  directly from `storage.cfg`. Asking `pvesm` would mean reaching every array
  to answer, and a removal that hangs leaves dpkg half-configured.

## [0.7.5~beta1] - 2026-07-27

Testing under conditions an array is actually found in.

### Fixed
- **Concurrent allocation could fail instead of retrying.** Choosing a disk id
  and creating the volume are two steps and PVE runs allocations in parallel,
  but the check for whether the id was already taken sat outside the retry
  loop. A worker that lost the race died on a name it was still free to
  change. Found by a test that allocates from sixteen processes at once
  against one shared array.

### Added
- `t/12-adverse.t`: a real HTTP server that misbehaves on purpose — accepts
  the connection and never answers, stops mid-body, replies 200 with HTML,
  closes without a response, refuses credentials, completes a login without a
  token. Every case must fail quickly, name the storage, and never hang. It
  also proves a create that fails with 5xx is sent exactly once: the request
  may have reached the array, and a retry would turn one PVE disk into two
  volumes.
- `t/13-hostile.t`: corrupt state files (empty, truncated, binary, JSON of the
  wrong shape), the ownership gate that guards every destructive path,
  storage ids with path traversal and shell metacharacters and non-ASCII
  text, size alignment at each family's granularity boundary, PowerVault's
  additive expand, and sixteen-way concurrent allocation.
- `docs/TROUBLESHOOTING.md`: what to do about residual `sd` paths after a LUN
  is removed on the array by hand. Nothing removes an sd device
  automatically, and they stay silent until the next `multipathd` reload
  fills the journal with EBUSY.

## [0.7.4~beta1] - 2026-07-27

Continues the cross-check against the related projects' incident records, and
against Dell's own PowerStore and PowerVault manuals.

### Fixed
- **The storage API version is negotiated, not hardcoded.** PVE rejects a
  plugin claiming a version newer than its own — and every storage of that
  type then disappears from the node — while claiming an older one makes PVE
  print `implementing an older storage API` on every load of `PVE::Storage`,
  which is once per `pvesm` call and per daemon start. PVE 9 raised `APIVER`
  twice within the 9.1 point releases, so no fixed number is right everywhere.
  The plugin now claims what the running PVE asks for, capped at the newest
  version whose changes are actually implemented here.
- **`volume_resize` handles the `$snapname` parameter** added in storage API
  14. It was being ignored, so a request to resize a snapshot would have
  resized the volume it was taken from. It is refused with an explanation.
- **Deleting a snapshot now releases the clone that was reading it.** This is
  the `vzdump` snapshot-mode path: PVE takes a snapshot, reads it through
  `path()` — which needs a clone of the snapshot on the array — and deletes
  the snapshot as soon as the backup finishes. An array will not delete a
  snapshot something was cloned from, so every such backup would have failed
  at cleanup, leaving the clone on the array and its device on this node.
  Dell's PowerVault guide states the rule plainly: a volume or snapshot with
  child snapshots cannot be deleted until the children are.
- **The orphan reaper leaves alone any device that still has a working path.**
  A disk hot-added to a running VM is briefly missing from the array's
  listing while the guest already has it open, and a guest's open file
  descriptor is neither a holder nor a mount, so the in-use check cannot see
  it. Removing the map under a running guest shows up as I/O errors on a
  brand-new disk.
- **Outages are measured in time, not polls.** Once PVE marks a storage
  inactive it stops asking for a while, so a real outage may produce one or
  two calls into the plugin — a counter waiting for three consecutive
  failures would stay silent through exactly the outages worth reporting.
  `activate_storage` also records the failure it dies on: PVE calls it before
  `status()` and never reaches `status()` if it dies, which is what an
  unreachable array does.
- **`volume_snapshot_info` and `rename_snapshot` are implemented.** The base
  class versions read a qcow2 file through `filesystem_path`, which this
  plugin cannot provide, so they failed with a message about a method the
  caller never asked for.
- **PowerVault answers the confirmation prompt on rollback.** The CLI
  Reference documents `rollback volume [prompt yes|no] snapshot <snap> <vol>`;
  without it the array waits for an answer a script will never give.
- **PowerFlex reports real snapshot timestamps** instead of showing every
  snapshot as 1970.
- **`pve-dell-config-get` bounds its `mount` and `umount`.** It runs during an
  outage against storage that may be half dead, where an unbounded mount
  never returns.

### Changed
- **Rolling back to anything but the most recent snapshot is refused.** Dell's
  manuals describe what restoring a volume from a snapshot does to the volume
  and say nothing about the snapshots taken after the restore point. On an
  array that discards them, PVE would carry on listing restore points that no
  longer exist. PVE is told which snapshots are in the way, as the built-in
  plugins with destructive rollbacks do.

### Added
- `dell-rollback-any-snapshot` (boolean, default off): lifts the restriction
  above for an operator who has verified the behaviour on their own array.

## [0.7.3~beta1] - 2026-07-27

Cross-checked against the production incident records of the two related
projects, [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp)
and [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage).
Every documented failure class was traced through this codebase; nine were
present here.

### Fixed
- **A refused delete could be reported as success.** `free_image` read `$@`
  after other `eval`s had run in between, and an `eval` resets it. An array
  that refused the delete produced the same return as a successful one, so
  PVE dropped the disk from the VM configuration while the volume was still
  there. The error is now captured the moment the delete returns.
- **A volume could be deleted while still mapped.** If the array failed to
  answer which hosts a volume was mapped to, `free_image` carried on and
  deleted it anyway. Every node it was mapped to would keep a device that
  answers nothing, and anything touching one hangs in uninterruptible sleep.
  That query failing is now fatal, which is retryable; ghost devices are not.
- **The orphan reaper made one array call per volume** whenever a listing did
  not carry WWIDs. That runs in the background of every `status()` poll on
  every node, so it scales as volumes × nodes every ten seconds — the shape
  that collapses an array's management gateway. It now uses only what the
  listing returned, and a listing that carries no WWIDs at all abandons the
  pass instead of concluding that every volume was deleted.
- **Temporary snapshot-access clones could leak.** A worker killed between
  creating one and deleting it left an object with no PVE volume name: it
  appears in no listing and the reaper does not touch objects the array still
  has. They are now recorded per node and removed once the creating process is
  gone.
- **PowerStore collection listings could truncate silently.** The pager
  stopped on a page shorter than the one it asked for, but an array may cap a
  page below the requested size. Volumes past the cut disappeared from the
  disk list and the reaper treated them as deleted. It now follows the
  `Content-Range` the array returns.
- **PowerVault and PowerFlex now wait for an object to become visible after
  creating it**, as PowerStore already did. A successful create is not a
  promise that the next query can see it, and every caller maps or looks up
  the object immediately afterwards.
- **PowerFlex unmaps before deleting in every rollback path**, and a clone
  this node cannot map is rolled back instead of left behind as a disk whose
  device never appears.
- **The block-device test that follows a device glob runs inside the same
  timeout as the glob**, rather than after it.
- `decode_json` was called in `PowerStore/API.pm` without importing `JSON`.

### Added
- `t/11-imports.t`: `perl -c` compiles a call to an undefined subroutine
  without complaint, so a helper used without its `use` line fails only at
  runtime — on the array-facing path, which cannot be exercised without
  hardware. The missing `JSON` import above was found this way.

## [0.7.2~beta1] - 2026-07-26

A review pass over every plugin entry point against the Proxmox VE 9.2.5
storage API source, and over each family's API client. Nine defects, all of
which would have surfaced in the first hours against real hardware.

### Fixed
- **PowerFlex applied the wrong name limit.** `PowerFlex::Naming` overrides
  the limit to 31 characters, but the inherited PowerVault methods read that
  family's constant of 32 directly, so every generated name was allowed to be
  one byte too long. A snapshot or linked clone on a storage with a longer id
  was refused by the array. The shared methods now take the limit from the
  class.
- **Deleting a volume left its snapshots behind.** PVE removes a VM's disks
  without touching storage snapshots — `qm destroy` calls `vdisk_free`
  directly — and a template always carries its marker snapshot, so both
  failed on the array. The snapshots this plugin created are now removed
  first, as the Ceph and ZFS plugins do. The template marker is handled last
  and only when the array's refusal was not about dependents, so a template
  whose linked clones still exist keeps the marker it is identified by.
- **The temporary clone used to read a snapshot ignored the family name
  limits.** It was built by string concatenation and came out at 39 bytes,
  which PowerVault (32) and PowerFlex (31) both refuse, so reading a snapshot
  could not work on those families. It now goes through the naming class.
- **A generated NVMe host NQN was never persisted.** `nvme gen-hostnqn`
  returns a new random NQN on every call, so the array was told one NQN while
  `nvme connect` presented another and the namespace never appeared. It is
  now written to `/etc/nvme/hostnqn`, atomically and without overwriting an
  existing file.
- **Linked clones were listed under the wrong volid.** `clone_image` returns
  `base-100-disk-0/vm-101-disk-0`, which is what PVE stores, but
  `list_images` reported `vm-101-disk-0`. `qm rescan` would see a volume no
  configuration references and add it again as an unused disk. The parent is
  now derived from the array's own metadata; a family that cannot determine
  it reports the clone under its plain name, as the LVM-thin plugin does.
- **A `vollist` filter matched by prefix**, so a request for `vm-1-disk-1`
  also returned `vm-1-disk-10`. It matches exactly now, as the built-in
  plugins do.
- **PowerStore could fail on an operation the array had accepted.** Some
  requests answer 202 with a job id rather than the finished object, and the
  volume was looked up by name immediately afterwards. Creation and cloning
  now wait for the object to appear.
- **PowerVault reported a volume as zero bytes** when `show volumes` returned
  only the formatted size and not the `-numeric` field. Zero also made every
  resize look like growth. The formatted string is parsed as a fallback.
- **The periodic SAN rescan stopped after a backwards clock step**, the same
  defect already fixed in the health cooldown.

### Changed
- Host registration is checked at most once every five minutes per storage
  instead of on every `activate_storage`, which PVE calls on every pvestatd
  poll. On PowerVault that check is a full `show host-groups`.
- `pve-dell-config-get` refuses a storage that is not `dellpowerstore`
  instead of speaking PowerStore REST to another family's array, and says why
  the config backup does not exist on PowerVault.

## [0.7.1~beta1] - 2026-07-26

### Changed
- The VM config backup volume is no longer offered on the `dellpowervault`
  family. Every snapshot of a VM would spend one additional volume on a copy
  of its configuration, and a PowerVault ME array's volume and snapshot
  ceiling is roughly an order of magnitude below PowerStore's — low enough
  that the cost decides whether an array runs out of volumes. Snapshots,
  rollback and linked clones are unaffected, and the configuration remains
  recoverable from a PVE backup or from `/etc/pve` on another node.
- `Common::BlockBase` gained `supports_config_backup()`, the family-level
  switch that decides this, and it now gates every config-volume path.

### Added
- `dell-config-backup` (boolean, default on): turns the config backup off on
  a family that does offer it, for a PowerStore close to its volume limit.
  Setting it on a family that does not offer the feature has no effect.

### Fixed
- Deleting a snapshot or a disk still cleans up any config volumes an earlier
  version wrote, even once the feature is switched off — otherwise they would
  be stranded on the array.

## [0.7.0~beta1] - 2026-07-26

Adds the `dellpowerflex` storage type for PowerFlex 3.x and 4.x.

### Added
- `PowerFlex/API.pm`, `PowerFlex/Naming.pm`, `PowerFlex/Host.pm` and
  `DellPowerFlexPlugin.pm`.
- `Common/Schema.pm`: the shared `dell-*` options, extracted so a family that
  is not a block plugin can use them without inheriting `BlockBase`.
- `docs/POWERFLEX_SDC.md`: the SDC and NVMe/TCP comparison, Dell's support
  matrix and where it lives, and how to check whether a kernel is supported —
  as links to the official sources rather than a copy that would go stale.
- Setup instructions for all three families in the README, and a link to the
  documentation site under the title.
- 991 unit tests in total.

### PowerFlex specifics
- **It does not inherit the block base class.** Volumes arrive through Dell's
  SDC kernel module or the in-kernel NVMe/TCP initiator; there is no SCSI LUN
  and no dm-multipath, so everything `BlockBase` does for devices would be
  wrong.
- **NVMe/TCP is the default.** Dell's Proxmox VE guidance lists SDC support
  for PVE 8.x and only *planned* support for PVE 9.x, and `scini` must be
  compiled for each kernel — so a kernel upgrade can leave a node with no
  storage until it rebuilds. NVMe/TCP uses the kernel Proxmox already ships.
- **NVMe paths are ANA, and the timeouts matter.** Connections are made with
  `ctrl-loss-tmo` 60s rather than the kernel's 600s: it is the NVMe
  equivalent of `no_path_retry`, and an unbounded value turns a total path
  loss into what looks like a hang. Activation warns when
  `nvme_core.multipath` is disabled, and when only some of the array's
  targets could be reached.
- **Both authentication generations are detected**, not configured: the 4.x
  bearer token from `/rest/auth/login` (which expires in five minutes) and
  the 3.x token from `/api/login` that is then used as a password. A refused
  password is never replayed against the other endpoint, which would double
  the failed-login count against a lockout policy.
- Sizes round up to the 8 GB allocation unit; names are limited to 31
  characters.

### Removed
- The internal development specification is no longer in the repository.

## [0.6.0~beta1] - 2026-07-26

Adds the `dellpowervault` storage type for the PowerVault ME4 and ME5 series.

Still beta, and still unverified against hardware. What is different this time
is that the array-facing details were read from the *Dell PowerVault ME5
Series CLI Reference Guide* rather than written from memory, and
[docs/TESTING.md](docs/TESTING.md) now separates what came from the official
documentation from what did not.

### Added
- `PowerVault/API.pm`, `PowerVault/Naming.pm` and `DellPowerVaultPlugin.pm`.
- 154 further unit tests, 867 in total.

### Things this family does differently, and why they matter
- **HTTP 200 does not mean success.** ME exposes its CLI over HTTPS; a
  rejected command answers 200 with the verdict in a `status` object. Judging
  by the HTTP code would let a failed volume create look like it worked, and
  PVE would then record a disk that does not exist.
- **`expand volume` takes a delta, not a total.** PVE asks for the new
  absolute size. Passing it through would grow a 32 GiB volume to 64 GiB when
  the user asked for 33.
- **Sizes round up here.** The array aligns to 4 MiB and rounds *down*, so the
  client rounds up first; otherwise the volume is smaller than PVE believes.
- **Names are limited to 32 bytes and may not contain a dot.** This family
  therefore has its own naming module: short object names, a snapshot
  separator of `-s-` rather than a dot, and a 10-character budget for the
  storage id. A name that will not fit raises an error rather than being
  truncated into a collision with another VM's volume.
- **A linked clone is a snapshot.** ME snapshots are writable and mappable, so
  a clone is a snapshot given a volume-shaped name — instant, and no copy.

### Changed
- Roadmap: PowerStore, then PowerVault ME, then PowerFlex, then PowerMax.
  PowerScale is not scheduled.
- The type string is `dellpowervault`, not `dellme5`: every other family is
  named for its product line rather than a model number, and ME4 and ME5 share
  one API.

## [0.5.0~beta1] - 2026-07-26

Phases 2 to 4. The `dellpowerstore` storage type now exists.

> It has **not** been run against a PowerStore array. Every array-facing
> detail is still listed as unverified in [docs/TESTING.md](docs/TESTING.md).
> 1.0.0 is the on-hardware test pass, not more code.

### Added
- `Common/BlockBase.pm`: the abstract PVE plugin base. SAN activation,
  allocation, device discovery and teardown, snapshots, templates, clones,
  the multipath drop-in and the background orphan reaper — all independent of
  which array is behind them. A family plugin implements the `_array_*`
  methods and inherits the rest.
- `PowerStore/API.pm`: REST client for volumes, snapshots, thin clones, hosts,
  mappings and the transport endpoints, with fixtures and 96 request-shape
  tests.
- `PowerStore/Naming.pm`: PowerStore's wider name limits.
- `DellPowerStorePlugin.pm`: the storage type, plus the schema PVE registers.
- `bin/pve-dell-config-get`: reads a VM configuration back out of the config
  backup volume written beside each snapshot. In recover mode it parses
  `storage.cfg` itself, or takes the array details on the command line, and
  never goes through pvesm — the situation it exists for is the one where
  `/etc/pve` is gone or pvedaemon will not start.
- Documentation: quick start, configuration reference, architecture,
  troubleshooting, naming conventions and the hardware test matrix, in English
  and Traditional Chinese, plus the project page under `docs/`.

### Notes on behaviour worth knowing
- Volumes are mapped to every node at creation, so live migration does not
  have to remap first, and unmapping always precedes deletion — the other
  order lets an in-flight rescan on any node re-import the LUN and rebuild the
  device behind the delete.
- LUN ids are assigned by the plugin, filling gaps from `pstore-lun-id-base`.
  PowerStore's own REST-side sequence starts at 200 and never reuses an id, so
  a cluster that attaches and detaches constantly eventually walks it past
  what the host scans, and new disks stop appearing.
- Volume sizes round up to PowerStore's 8 KiB granularity. Rounding down would
  hand back a volume smaller than PVE asked for.
- `make syntax` reports modules that need Proxmox VE as skipped rather than
  failing, so CI on a plain runner stays honest instead of green by accident.

## [0.2.0] - 2026-07-26

Phase 1 — the shared Common layer. Still no storage type: these are the
modules the family plugins will be built on.

### Added
- `Common/Naming.pm`: object naming, PVE volume name translation, and
  `is_pve_managed_volume`, the `pve-<storeid>-` ownership gate that every
  list, delete and cleanup path has to pass. Class methods, so a family can
  widen the name limits by subclassing without introducing shared mutable
  state — one PVE process loads every Dell plugin at once.
- `Common/REST.pm`: HTTP transport. A POST is never retried on 5xx, because
  the request may have taken effect and a retry would create a second volume.
  A 401 clears the session and retries once. 429/503 back off, honouring
  `Retry-After` up to 30s. Sessions carry the creating pid so a forked PVE
  worker re-authenticates instead of reusing one that is not its own.
  Constructing with `retries => 1` and a short timeout gives the health
  client `activate_storage` and `status()` need.
- `Common/Multipath.pm`: device lifecycle ported from the NetApp and Pure
  plugins with the vendor gate parameterised. `multipath -F` is never
  generated: `multipath_flush` requires a device. Every sysfs access runs in a
  forked, timeout-bounded child, because a plain read of a dead LUN lands in
  uninterruptible sleep that no signal clears.
- `Common/ISCSI.pm`: initiator identity, portal probing, session lifecycle,
  and a per-session rescan that skips sessions which are not `LOGGED_IN`.
- `Common/FC.pm`: HBA discovery and WWN normalisation across the three
  spellings the same WWN arrives in. No LIP by default.
- `Common/WwidState.pm`: per-node WWID tracking, with the grace period and
  miss threshold that must both pass before the orphan reaper may tear a
  device down, and sibling detection so one Dell storage never reports
  another's live device as a stale orphan.
- `Common/Health.pm`: outage detection and capacity alerting for `status()`,
  rate limited so a ~10 second poll cannot flood the journal.
- 342 unit tests (`t/01-naming.t` .. `t/05-state.t`), covering the retry
  policy, the reap guards, the ownership gate and the taint helpers without
  needing an array or a device.

### Fixed
- Rate-limited health messages now treat "never emitted" explicitly and
  treat a timestamp in the future as due. Previously both leaned on epoch
  arithmetic against 0, so a backwards clock step could silence a real
  outage for as long as the skew lasted.

## [0.1.0] - 2026-07-26

Phase 0 — project skeleton. No storage type is registered by this release.

### Added
- MIT license, bilingual README skeleton with the multipath safety rules and
  the hardware-verification disclaimer.
- `Makefile` with `install`, `uninstall`, `test`, `syntax`, `unit`,
  `check-multipath-flush`, `deb` and `clean` targets. The module list is
  discovered from `lib/**/*.pm` instead of being hand-maintained, so packaging
  does not have to change as modules are added.
- Debian packaging: `control`, `rules`, `compat`, `changelog`, `copyright`,
  `docs`, `postinst`, `prerm`, `postrm`. Installation is driven by the
  Makefile through `override_dh_auto_install`.
- `postinst` checks: required binaries present (catches `dpkg -i` without
  dependency resolution), dangerous multipath settings in `/etc/multipath.conf`
  and `/etc/multipath/conf.d/*.conf`, stale all-paths-failed Dell maps, missing
  LVM `global_filter`, in-flight storage operations, and a cluster-wide
  installation reminder.
- GitHub Actions workflow: safety guard, `perl -c` and unit tests gate the
  `.deb` build.
- CI guard `make check-multipath-flush`: the build fails if the system-wide
  flush `multipath -F` — which must never be used — appears in shipped code or
  documentation. Prose that explicitly forbids the command is allowed through.
- Directory skeleton for the multi-family layout (`lib/PVE/Storage/Custom/`,
  `DellEMC/Common/`, per-family subdirectories, `t/`, `docs/`, `bin/`).
