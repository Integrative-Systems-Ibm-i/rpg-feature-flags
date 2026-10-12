# CI setup — GitHub Actions building on IBM i

```
   GitHub  ──(runner polls outbound)──►  runner machine  ──(SSH, local)──►  IBM i
   source + workflow                     runs the job                        compiles
```

**GitHub never reaches the IBM i, and no IBM i credential is stored in GitHub.**
The runner lives inside your network and holds the SSH key.

---

## 1. Repository variables

**Settings → Secrets and variables → Actions → Variables → New repository variable**

| Name | Value |
|---|---|
| `IBMI_HOST` | your IBM i hostname or IP |
| `IBMI_USER` | the user profile the build runs as |

These are *variables*, not secrets — neither is sensitive, and visible values make
failed builds far easier to read. The thing that actually grants access is the SSH
key, which never leaves the runner.

## 2. SSH key, runner → IBM i

On the runner machine:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ibmi_demo -N "" -C "github-actions-ibmi"
ssh-copy-id -i ~/.ssh/ibmi_demo.pub YOURUSER@YOUR-IBMI
ssh -i ~/.ssh/ibmi_demo YOURUSER@YOUR-IBMI "echo ok"     # must not prompt
```

If it still prompts for a password, the cause is almost always permissions —
sshd's StrictModes refuses a key when the home directory is group- or
world-writable:

```bash
chmod 755 ~                     # NOT 775 or 777
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

Also make sure `authorized_keys` is ASCII (CCSID 819), not UTF-8.

## 3. Register the runner

**Settings → Actions → Runners → New self-hosted runner**, pick your OS, and run the
download/configure commands it gives you. When it asks for **additional labels**, enter:

```
ibmi
```

That label is what `runs-on: [self-hosted, ibmi]` targets.

Start it:

```bash
cd ~/actions-runner && ./run.sh        # foreground — good for demos
cd ~/actions-runner && ./svc.sh install && ./svc.sh start   # background service
```

> For a live demo, run it in the **foreground** in a visible terminal. Watching the
> runner pick up the job is half the effect.

## 4. What the workflow does

| Step | |
|---|---|
| Check out | standard `actions/checkout` |
| Decide target | `main` → `FLGDEV`; any other branch → its own library, so two branches never fight over one set of objects |
| Copy source | `tar` over SSH into a per-run staging directory |
| Compile build program | `CRTBNDCL` on `BUILDDEMO` |
| Build | `CALL BUILDDEMO` — display file and program |
| Verify | lists the objects with their creation timestamps |
| Clean up | removes the staged source, always |

## 5. Why ibmi-ci, and what it does not solve

The workflow uses [`ibmi-ci`](https://github.com/IBM/ibmi-ci) (`ici`) instead of
hand-rolled `ssh` and `tar`. What that buys:

- **`--push` is selective.** It skips `.git`, `.env`, and dotfiles on its own, so the
  `COPYFILE_DISABLE` and AIX-tar problems disappear.
- **`--cl` runs CL directly** — no `system "..."` wrapper, so no nested quoting.
- **`--ignore`** marks a step as allowed-to-fail, replacing `>/dev/null 2>&1`.
- **One connection** for the whole build instead of five separate `ssh` calls.

**What it does NOT solve:** each `--cl` still gets its own job, so a library list set
in one does not carry to the next. Verified directly — `ADDLIBLE` then `DSPOBJD` on an
unqualified name fails with CPF2105. That is why the real build still lives in
`BUILDDEMO.clle`, which does its own `ADDLIBLE` and runs everything in one job.

**Credentials:** `IBMI_PRIVATE_KEY` wants the key *contents*, not a path. The workflow
reads it off the runner's disk at run time (`$(cat ~/.ssh/ibmi_demo)`), so the key is
never stored in GitHub. Do not follow the upstream example that puts `IBMI_PASSWORD`
in repository secrets — it works, but it throws away the best property of this setup.

**Status:** `ibmi-ci` is not archived but has had no commits since September 2025.
Plain `ssh` remains a perfectly good fallback.

## 6. Things that will bite you

- **PASE `system` gives every call its own library list.** `ADDLIBLE` in one command
  does not apply to the next. Anything needing a library list has to run inside a
  single CL program — which is exactly why the build is `BUILDDEMO.clle` rather than
  a shell script.
- **DDS cannot compile from the IFS.** `CRTDSPF` has no `SRCSTMF` parameter, so the
  DDS is staged into a source member first with `CPYFRMSTMF`. `BUILDDEMO` handles it.
- **PASE `tar` is AIX tar** — no `-z`. Send uncompressed.
- **On macOS runners set `COPYFILE_DISABLE=1`**, or every file arrives with an
  `._AppleDouble` sibling.
- **`CRTSQLRPGI` defaults to `GENLVL(10)`**, so a *severity 20 warning* fails the
  build. That is usually what "it compiled on my machine" means.
- **CL `CHAR(256)` parameters must be padded** by the caller; a short literal leaves
  the program reading past the end of the value.
- **A branch library must be self-contained.** `BUILDDEMO` builds the data model, the
  journal, the service program *and* the demo, because a branch gets an empty library
  and `DEMO01` cannot bind to a `FLAGSRV` that is not there.
- **You cannot rebuild while the demo is on screen.** `DEMO01` holds a lock on the
  display file; press F3 first. The build now says so in plain words.
