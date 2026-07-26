# Changelog

All notable changes to this project are documented here.
繁體中文版本：[CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md)

Versioning: the patch number increments per release and runs to .99 before
the minor number moves — 0.7.0, 0.7.1, … 0.7.99, then 0.8.0. Every 0.x
release is a prerelease; 1.0.0 is the on-hardware test pass.

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
