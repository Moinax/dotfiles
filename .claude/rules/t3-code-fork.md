---
description: Why T3 Code is built from our fork and deliberately untracked by dots apps, and why the single launcher entry with its exact --name is load-bearing.
paths:
  - home/dot_local/bin/executable_t3fork
  - tools/t3-host.sh
  - tests/test_t3fork_sync.sh
  - tests/test_t3fork_rollback.sh
  - tools/manage-external-apps.py
  - packages/groups/development.yaml
---

# The fork is untracked by `dots apps`, on purpose

The AppImage at `~/.local/share/AppImages/t3-code.AppImage` carries our patches on
top of upstream, and `t3fork update` / `t3fork install` are what maintain it
(`t3fork restart` relaunches an already-installed one).

It used to be tracked as a `pingdotgg/t3code` pre-release, so `dots update`
offered that row and accepting it downloaded the upstream nightly *over* the fork
build, silently dropping every patch. The source record was removed — **never
re-add it with `dots apps install-github`**.

**The droplet is the second road onto the same rake.** `phase_fork` in
`tools/t3-host.sh` builds this fork there too, and its systemd drop-in
deliberately bypasses `service-launcher.mjs` — the self-update supervisor, which
would `npm install` upstream over our build exactly as `dots apps` did. Restoring
the launcher "so t3 can manage itself" is the same mistake in a second file; see
`t3-host.md`.

Upstream movement is reported instead by the fork check at the end of
`dots update` (`fork_drift`, see `sync-machine.md`), which needs no declaration to
pick up the next fork.

# One launcher entry, written by `t3fork install`

Install goes through `dots apps import-appimage "$built" --name "T3 Code"`, never
a bare copy, because the copy leaves no `.desktop` and no icon behind.

Removing that record only half-worked once: a second registration under the slug
`t3-code-alpha` kept pulling the upstream nightly, and every `.desktop` entry and
the `t3code://` handler pointed at *it* while the fork build sat unreferenced.
Nothing reported it — `t3fork restart` execs the target directly.

Two rules fall out:

- **The `--name` is load-bearing.** electron-builder stamps `productName`, which
  carries upstream's stage label — `T3 Code (Beta)` since 2026-10-15, `T3 Code
  (Alpha)` before it — and slugs straight back to `t3-code-beta` and reinstalls
  the split. The label moves with upstream's releases; the `--name` is what keeps
  the slug from moving with it.
- **There must only ever be one T3 Code in `dots apps list`.** A second row is the
  bug, not a fallback.

# `t3fork` internals, as `fork_drift` sees them

`t3fork` refuses on the same state from both ends (`refuse_if_rebasing`). `install`
is the one that matters: the `&&` in `t3fork update && t3fork install` only guards
the chained form, and a hand-run `install` mid-rebase builds the partially replayed
tree, stamps it `…-moinax.<sha>` — the branch name is the script's variable, not
something git was asked — and installs it over the working AppImage.

**`update` takes in origin before rebasing** (`sync_with_origin`) — `dots backup
create`'s rule applied to a fork: it may only move forward. Rebasing from a checkout
that is behind produces a branch missing another machine's commits, and the
force-push that follows deletes them while the push succeeds and the branch looks
healthy. Behind or level fast-forwards; anything else is judged by **`git cherry`,
not by divergence**, and that is the whole feature — a branch rebased here and not
yet pushed has already diverged by construction, so refusing on divergence would
block every update for anyone who does not push each time. `git cherry` asks the
question that matters, by patch-id: a locally rewritten commit counts as present, a
genuinely foreign one comes back `+`.

**Patch-id alone still cannot say WHICH side wins**, and that is a second question
the first one hides. Two situations give the identical shape — origin holds patches
we lack, we hold patches it lacks: another machine rebased and force-pushed, or
*this* machine rebased and declined the push, leaving on origin the pre-rebase form
of every commit the replay re-resolved. Answering "origin wins" to both reverted the
newer rebase and each conflict resolution in it, then replayed the older form onto
upstream — the reset only moves a ref, so the loss went to the reflog and the next
build shipped the superseded patch. It also read the upstream commits the rebase had
taken in as "our stale iterations" and offered to drop them.

**The rebase base is the discriminator**, because it is the thing a rebase changes:
`merge-base` against `upstream/main` is the upstream commit each side sits on, and
whichever sits on the newer one is the later rebase. That is why `update` fetches
`upstream main` *before* calling `sync_with_origin` rather than after — the
comparison is meaningless against a stale `upstream/main`. Equal bases fall through
to the old rule, where origin genuinely does carry work of its own.
`tests/test_t3fork_sync.sh` holds both directions.

The fetch uses an explicit refspec so `refs/remotes/origin/<branch>` really is
updated. When it fails, one `ls-remote --heads --exit-code` sorts the three reasons
by exit status (0 there, 2 reachable-but-absent, else unreachable) and **only status
2 may claim origin was observed** — saying so anywhere else makes the comparison run
against a stale tracking ref and has `offer_push` announce a published branch as
never pushed.

**Publishing is offered, never done on its own** (`offer_push`). The force-push is
safe *here specifically*: `sync_with_origin` fetched seconds earlier and either took
origin in — leaving what we overwrite patch-equivalent to what we hold — or
established that this checkout is the later rebase and **named on screen** the
commits origin carries that it supersedes. That second arm is a weaker guarantee
than the first and is stated as one: a subject in that list you do not recognise is
another machine's work, and the run says to stop. The lease pins the observed sha
(`--force-with-lease=<branch>:<sha>`) rather than the bare form, which leases against
the local tracking ref — a ref any later fetch in the same process would move
underneath it.

**The droplet rebuild is offered right after a successful push**, not printed as a
next step. The host builds `origin/<branch>` (`t3-host.md`), which makes it a consumer of `origin/<branch>`, so the
push is the moment it becomes reachable-and-stale, and a command to remember at the
end of a maintenance run is a command remembered once — a declined push left the
host a day behind with the desktop looking healthy throughout. `dots update`'s fork
report carries the other half: it now counts commits absent from `origin` off the
tracking ref, no fetch, because this machine is the only thing that pushes there.

**A local rewrite nobody has pushed makes `sync_with_origin` choose origin.**
Squashing, reordering or amending the series here gives every commit a new
patch-id, so `git cherry` reports origin's commits as foreign — the shape that
means "another machine has work we lack". The rebase bases are the discriminator
and they are *equal* at that point, because no rebase has happened yet, so the
tie falls through to the old rule and origin wins: the next `t3fork update`
offers to reset the rewrite away. Rewriting and *then* rebasing is what makes
this machine the later base and the winner; the sequence to avoid is rewrite,
leave unpushed, run `update`. Publishing straight after the rewrite closes it
too, and is what the rewrite was heading for anyway.

**The fork follows upstream's newest built nightly, never the tip of `main`.**
Upstream's release job runs after the checks and all six desktop builds and
creates the tag and the release together, so a nightly tag with no release is one
whose release was *deleted* — GitHub keeps the tag — which is how a nightly found
to be broken is withdrawn; `v0.1.1-nightly.20261020.3399` is one. A release
carrying an uploaded AppImage asset is therefore what proves a commit was built
and still stands, and
its `target_commitish` is what both update paths rebase onto. Rebasing onto
main's tip took commits no build had exercised: upstream broke the build, this
machine had it before upstream had fixed it, and the next update existed only to
carry the fix. `scripts/fork-update.mjs` in the checkout owns the criterion;
`t3fork target` prints its answer, and `register_fork_config` points
`dotfiles.forkTargetCommand` at it so the drift report counts to the same place
(`sync-machine.md`). Never add a second copy of the rule — two answers to "which
commit is current" is two commands undoing each other's rebase.

**A prepared update does not hold the next nightly back; only a rollback copy
does.** Preparing chains: hours can pass before a restart, and waiting for one
would make every one of them an hour of nightlies not taken, for no gain — the
build being replaced was never run. What that costs is the backup, so
`installArtifact` writes `<AppImage>.previous` only when the installed build is
the one running. Overwriting it on every install would, after two preparations,
offer a rollback onto a build nothing ever started. A prepared *local* build is
different and is never discarded: it was asked for by hand.

**`t3fork install` keeps a rollback copy too, under the same rule.** Only a
build this machine has *run* is worth rolling back onto, and the shell can tell:
an installed AppImage newer than the running process was put there and never
started, so the existing backup stays. It records no version — unlike the
updater it does not know what it is replacing, and the app reads a nameless
backup as "the previous build" rather than inventing one.

**`t3fork install` tells the updater what it installed, rather than erasing its
records.** Clearing them was the only other option available: the app recognises
a prepared build by the installed AppImage's size and mtime, so a newer file put
there by hand reads to it as "the installed AppImage changed or is missing" — an
error about the build that had just succeeded. But the record is also what the
sidebar's **Local build ready · Restart** pill is made of, and what the change
list on the fork page reads, so clearing it meant a hand build announced itself
nowhere and the restart had to be remembered. The record is written by
`record-installed` in the runner, never by the shell: size, mtime and sha256 are
a contract with the running app, and a second writer of them is a second answer
to "is a build waiting". Two consequences, both of them the existing rule for a
prepared local build rather than new: the automatic upstream update refuses to
prepare over it until the restart happens, and a second hand install keeps the
rollback copy rather than pointing it at a build nothing ever ran.

**The rollback exists twice because its premise is an app that will not start.**
`t3fork rollback` is shell, depends on nothing built, and only moves files; the
in-app button goes through the runner's `rollback` action. That is not the
duplicated-rule trap the nightly criterion is — it is `mv`, not a decision — but
the two still have to stay in step, and both clear `prepared.json` and
`status.json`, which otherwise describe a file that is no longer installed and
park the sidebar on "needs attention".

**`t3fork update` never pushes on its own.** It is the command the fork report
*names*, so auto-pushing there would turn a line of a routine maintenance report
into rewriting a published branch nobody agreed to. It offers the push and waits.

**An agent that rewrites the fork branch publishes it, though** — standing
instruction, 2026-10-20, `--force-with-lease` pinned to the sha just observed,
never the bare form. Squashing a fixup into a fork patch changes every sha after
it, which leaves origin and local *diverged* rather than merely behind: eight
commits each side, no ancestor either way. `prepareUpdate` rejects exactly that
shape ("The local and published fork have diverged"), and its `published.json`
escape hatch only covers a publication the runner itself performed. So a rewrite
left unpushed does not merely lag — it stops the fork from updating at all,
automatically and manually, until the two sides are reconciled. Verify with
`git rev-list --count origin/<branch>..HEAD` and its mirror: two non-zero counts
is the broken state.

**The keys are written by every `t3fork` invocation, not just `update`.** They lived
in the `update` branch first, which made them unreachable in practice — they exist
to tell you which command to run *before* you have run it, so the command they name
cannot be the only thing that writes them. The first `dots update` after they landed
printed a bare `git rebase` for exactly that reason. The write is non-fatal: losing
it costs a degraded report line, never the run the user asked for.

Both the `upstream` remote and the key live in the fork's `.git/config`, which
a restore used to drop on the floor — see the sidecar manifests under
`dots backup` (`backup-projects.md`), which is what now carries them back.

# `t3fork mobile` — the phone half

Same checkout, same branch, a second artifact: `expo prebuild` into
`apps/mobile/android` (gitignored, generated every run), then `gradlew
assembleRelease`, then `adb install`. Android only — an iOS build needs Xcode,
which is not a thing this machine has.

**The signing key is ours, and it lives outside the checkout.** Expo's generated
release buildType is wired to `signingConfigs.debug`, i.e. the React Native
template's `debug.keystore` — a private key that ships in every RN repo on
GitHub, so anything signed with it can be silently upgraded by anything else
signed with it. This app holds a paired session to the desktop. `ensure_keystore`
generates one at `~/.local/share/t3fork/t3code-mobile.keystore` with its password
beside it, and overrides the build through AGP's `android.injected.signing.*`
properties rather than patching a file `prebuild` owns and would regenerate.
Outside the checkout because `--clean` deletes `android/` wholesale, and **a key
that moves is an uninstall on the next install** — see below for what that costs.
Back up both halves: losing either is unrecoverable in the only sense that
matters, which is that the phone has to be wiped of the app to take a new key.

**Replacing the store build costs its data, exactly once.** Android cannot
upgrade across signing keys, so the first install over the Play Store
`com.t3tools.t3code` fails `INSTALL_FAILED_UPDATE_INCOMPATIBLE` and the only way
in is `adb uninstall` — which erases the pairing with the desktop. The script
detects that specific failure, says what it will destroy, and asks. Every later
build carries the same key and installs straight over. `--preview` builds
`com.t3tools.t3code.preview` instead, which sits beside the store app and needs
no uninstall; that is the escape hatch, not the default.

**The phone is read before the build, not after.** The build is twenty minutes of
NDK work and every device-side failure — debugging off, `unauthorized`, two
phones plugged in — is something only somebody holding the phone can clear, so
finding out at the end spends twenty minutes to learn something that cost a
second at the start. `unauthorized` is the one that matters: it looks like a
present device to anything that only checks whether `adb devices` listed
something, and it means an "Allow USB debugging?" dialog is sitting on a locked
screen.

**`android-udev` is what makes adb reach the phone, and it needs no re-login.**
Its rules tag the device `uaccess`, so logind grants the seat user an ACL —
membership in the `adbusers` group it also creates is not required, which is the
one thing every guide gets wrong about it.

**`--clean` is deliberately not the default**, though `apps/mobile`'s own npm
scripts all pass it. It deletes `android/` entire, and with it `.cxx` and
`app/build` — the NDK and CMake output for reanimated, nitro-modules and
shiki-engine, which *is* the twenty minutes. Regenerating in place turns a
JS-only change into a short rebuild, which is the whole point of this being a
command you run after every `t3fork update`. The gradle failure path names
`--clean` as the first thing to try, so staleness costs one re-run rather than a
mystery.

**No SDK component is pinned in the dotfiles, on purpose.** `packages/groups/development.yaml`'s `android-sdk`
entry installs the command-line tools and `platform-tools` and stops there. The
platform, build-tools, NDK and CMake versions are declared by the checkout's
Expo config (`expo-modules-autolinking`'s `ExpoRootProjectPlugin` holds the
defaults), so a pin here would rot into a 2 GB download of the wrong NDK. AGP
fetches what the project asks for — which is why the install accepts the licence
with `yes |`: that writes `$SDK/licenses/android-sdk-license`, the file AGP
checks before it will download anything unattended.

**Three AGP properties that look right and are not.** All three were reached
for, all three cost a build, and none of them failed loudly:

- `android.injected.version.name` / `.version.code` — the ones Android Studio
  sets. Accepted, ignored, `BUILD SUCCESSFUL`, APK stamped `2.0.0`. What works
  is a `sed` on the `versionName`/`versionCode` lines of the `app/build.gradle`
  that `prebuild` just wrote — safe precisely because prebuild rewrites that
  file every run, so the edit never stacks and `--clean` is not needed to undo
  it.
- `android.injected.build.abi` — same provenance, and on AGP 9 it takes the
  build down an IDE-deploy path that **assembles no APK at all**: BUILD
  SUCCESSFUL, an empty `outputs/apk/release`, and the previous build's APK
  deleted on the way through. React Native's own
  `-PreactNativeArchitectures=<abi>` is the lever, documented in the
  `gradle.properties` prebuild writes, one line above its default.

Which is why the APK is **read back** rather than trusted: the "built …" line
reports the `versionName` and ABI list out of `aapt2 dump badging`, not what was
asked for, and the path is a glob over a cleared output directory rather than a
predicted `app-release.apk`. Every one of the three was caught by one of those
two habits.

**`versionCode` has to clear what is already installed, and keep clearing it.**
Prebuild writes `1`, every time, and Android refuses a downgrade *before* it
looks at the signature — so the first install over the store build (code 74)
failed `INSTALL_FAILED_VERSION_DOWNGRADE` and never reached the signature
mismatch the script was watching for. Both refusals share one remedy, the
uninstall, so they share one branch; matching only the signature left the
downgrade on the generic failure path with nothing offered. The number stamped
in is `git rev-list --count HEAD`, which only grows because what grows it is
upstream.

**`react-native-shiki-engine` cannot be built on a host that has oniguruma**
without `patches/react-native-shiki-engine@0.3.12.patch`. Its CMakeLists passes
the Android prebuilt's directory as `PATHS`, which find_library searches *last*,
after the system paths — and `NO_CMAKE_FIND_ROOT_PATH` beside it lifts the
sysroot confinement that would have hidden `/usr/lib`. So the host's x86-64
`libonig.so` wins and the link dies on "incompatible with aarch64linux".
oniguruma is a dependency of jq, bat, git-delta and yazi here, so it is not
going anywhere; upstream never sees this because EAS images do not have it. The
patch adds `NO_DEFAULT_PATH`. It will stop applying the day the package moves,
which is the good failure — a pnpm patch that no longer applies says so.

**The new `android` CLI answers a bad package name with "Ignoring" and exit 0.**
`android sdk install ndk@27.1.12297006` prints `No url for ndk. Ignoring.`,
installs nothing, and succeeds; the path form `ndk/27.1.12297006` is the one that
works. So never trust its exit status — the install entry ends on `[ -x
"$SDK/platform-tools/adb" ]` for exactly this reason, and anything added beside
it needs its own test that the component landed.
