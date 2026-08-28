# Beerocracy

A weekly ballot for deciding where to have the beer. One sheet per ISO week:
sign the register, mark the days that work for you, swipe through the places,
watch the tally fill in as everyone else votes. On Monday at 00:00 it resets and
you argue about it all over again.

Days take three answers, not two. Tapping a day cycles it through **yes**,
**maybe** and back to nothing. A maybe counts towards the day exactly like a yes
— it is still a body in the pub — but it is tallied separately, so a day held up
entirely by maybes looks as shaky as it is. Where two days draw, the one more
people are certain about wins.

Elixir · Phoenix LiveView · Ash · SQLite.

## Adding a place

The catalogue is **not** in the database. It lives in
[`priv/places.yml`](priv/places.yml), so adding your local is a pull request
that anyone can review:

```yaml
- slug: hopfenkeller # unique, lowercase, permanent — votes are stored against it
  name: Hopfenkeller
  tagline: Vaulted cellar, twenty taps, no daylight and no regrets.
  emoji: 🍺 # optional
  accent: amber # optional: amber copper gold rust moss plum slate
  beer:
    rating: 5 # 1 (regrettable) to 5 (we would queue for it)
    note: Twenty rotating taps, half of them local.
  food:
    rating: 2
    note: Pretzels and a cheese board. You will not leave full.
  reach:
    office: 6 # a bare number means minutes on foot
    station:
      walk: 9 # give both and the card leads with whichever is
      transit: 5 # quicker, and notes the other underneath
  open: # optional — when the place is open at all
    days: [thursday, friday] # default: all five weekdays
    from: "17:00"
    to: "20:00"
  season: # optional — for pop-ups and summer bars
    from: 2026-06-12
    until: 2026-08-30
  outdoor: true # optional — warns when the winning day looks wet
  tags: [taproom, cellar] # optional
  url: https://example.com/hopfenkeller # optional
```

Each destination under `reach` takes a `walk:` time, a `transit:` time (public
transport), or both — whichever you can honestly fill in. `office: 5` is
shorthand for `office: {walk: 5}`.

Times are measured **from the office** and **from Bern Hauptbahnhof**. They are
door-to-door estimates, not timetable truth — if one is wrong, fix it in a PR.

The file header documents every field. Both pages in the app link straight at
the file on GitHub — the **Add a place** link opens it in GitHub's editor, which
turns into a fork-and-pull-request for anyone without write access.

CI validates the catalogue on each pull request, so a typo fails the build with
a message naming the entry rather than surfacing later as a crash. Check it
yourself first:

```console
$ mix beerocracy.check_places
```

Changing a place's `slug` throws away that place's voting history — rename the
`name` instead, which is free.

## Running it

Signing in goes through GitHub, so you need an OAuth application of your own
before the ballot will accept a vote. Register a development one at
[github.com/settings/developers](https://github.com/settings/developers) with
the callback URL `http://localhost:4000/auth/user/github/callback`, then put its
credentials — and your own handle, so you are the admin — in a `.env` file:

```console
$ cp .env.example .env
$ $EDITOR .env
```

`.env` is not checked in. Anything `config/runtime.exs` reads can go in it, and
a real environment variable always wins over the file.

```console
$ mix setup
$ mix phx.server
```

Then open [`localhost:4000`](http://localhost:4000). Without credentials the app
still runs and the sheet is still readable — nobody can sign in, so nobody can
vote.

Useful commands:

```console
$ mix test                        # the suite
$ mix precommit                   # compile without warnings, format, test
$ mix beerocracy.check_places      # validate priv/places.yml
$ mix beerocracy.migrate_voters --list   # who still has votes with no account
```

### Votes from before the login

A voter used to be whatever name they typed, normalised — `jonas`. Now they are
their GitHub account — `gh:1234`. Votes cast under the old scheme belong to
nobody. Run the task with `--list` (or no arguments at all) to see who is still
unmigrated and what it would guess for each, then map the old keys onto
handles:

```console
$ mix beerocracy.migrate_voters --list
$ mix beerocracy.migrate_voters jonas=anehx mira=miradev
$ mix beerocracy.migrate_voters jonas=anehx mira=miradev --commit
```

Nothing is written without `--commit`, and **nobody has to have signed in
first**. A handle already on the sheet is resolved locally; anybody else is
looked up against GitHub's public user endpoint, since an account id is public
and permanent. Their votes are waiting for them the first time they arrive. The
dry run prints the account each handle resolved to, so a mistyped handle reads
as somebody else's name rather than quietly becoming somebody else's votes.

Pass `--offline` to skip the lookup and work only with people who already have
accounts here.

This only matters for a week that is **still open**. A closed week reads back
correctly whatever its votes are keyed on, because the archive is computed per
week rather than per person. The cost of leaving it is that somebody who voted
before signing in votes again afterwards and is counted twice — which is why it
is worth doing before the ballot fills up on a Monday.

## Deploying

Every push to `main` runs the tests and, if they pass, builds and pushes a
container to `ghcr.io/<owner>/<repo>:latest`.

```console
$ docker run -d \
    --name beerocracy \
    -v beerocracy:/data \
    -p 4000:4000 \
    -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
    -e TOKEN_SIGNING_SECRET="$(mix phx.gen.secret)" \
    -e GITHUB_CLIENT_ID=... \
    -e GITHUB_CLIENT_SECRET=... \
    -e ADMIN_USERS=anehx \
    -e PHX_HOST=beer.example.com \
    ghcr.io/<owner>/<repo>:latest
```

Or with compose:

```yaml
services:
  beerocracy:
    image: ghcr.io/anehx/beerocracy:latest
    restart: unless-stopped
    init: true
    environment:
      PORT: 4200
    env_file: [.env]
    ports: ["4200:4200"]
    volumes: ["./data:/data"]
```

The database is created and migrated on boot.

**About that volume.** SQLite writes the database *and* its `-wal`/`-shm`
companions, so the directory has to be writable, not just the file. A bind
mount like `./data` arrives owned by whoever created it on the host — and when
the directory does not exist yet, Docker creates it as `root`. The container
therefore starts as root just long enough to take ownership of the data
directory, then drops to an unprivileged user for everything else; no
application code runs as root.

If you pin `user:` in compose, the container can no longer fix the ownership
itself, so make the directory match: `chown -R 1000:1000 ./data`. Get it wrong
and it says so on the first line of the log rather than failing as a database
pool timeout.

| Variable          | Default              | What it does                                          |
| ----------------- | -------------------- | ----------------------------------------------------- |
| `SECRET_KEY_BASE` | —, **required**      | Signs session and LiveView tokens                     |
| `TOKEN_SIGNING_SECRET` | —, **required** | Signs the sign-in tokens. Changing it signs everybody out |
| `GITHUB_CLIENT_ID` | —                   | The OAuth application people sign in through          |
| `GITHUB_CLIENT_SECRET` | —               | Its secret. Without both, nobody can sign in and nobody can vote |
| `ADMIN_USERS`     | —, nobody            | Comma-separated GitHub handles allowed at `/admin/dashboard` |
| `DATABASE_PATH`   | `/data/beerocracy.db` | SQLite file; keep it on a volume or votes die on redeploy |
| `PHX_HOST`        | `localhost`          | Public hostname                                       |
| `PHX_SCHEME`      | `https`              | Set to `http` when there is no TLS in front           |
| `PHX_URL_PORT`    | `443` / `80`         | Public port, if it is not the standard one            |
| `PORT`            | `4000`               | Port the container listens on                         |
| `PLACES_FILE`     | bundled `places.yml` | Path to an alternative catalogue                      |
| `REPO_URL`        | this repository      | Where the "add a place" links point — set it if you fork |
| `REPO_BRANCH`     | `main`               | Branch those links open                               |

Mounting your own catalogue with `PLACES_FILE` is an escape hatch for trying
something out; the pull request is the intended route, so everyone can see what
got added.

## How it works

| Where                        | What                                                              |
| ---------------------------- | ----------------------------------------------------------------- |
| `lib/beerocracy/week.ex`     | ISO week keys (`2026-W34`). Votes are scoped by one, which is the whole reset mechanism — nothing is ever deleted. |
| `lib/beerocracy/places.ex`   | Parses and validates `priv/places.yml`, cached against the file's mtime. |
| `lib/beerocracy/voting/`     | Ash resources: `DayVote` and `PlaceVote`, one row per person per week. |
| `lib/beerocracy/ballot.ex`   | Turns votes into a tally and broadcasts changes over PubSub.       |
| `lib/beerocracy/accounts.ex`  | Display names, and who is an admin. Signing in itself is `ash_authentication`. |
| `lib/beerocracy/minutes.ex`  | Where we actually went, when that was not where we voted to go. The one thing not derived from votes. |
| `lib/beerocracy_web/live/ballot_live.ex` | The entire UI, plus the swipe gesture as a colocated hook. |

**Only the people who will actually be there choose the place.** A swipe counts
when its owner is marked for the winning day — a maybe is enough. Someone with
no day at all, or only free on other days, has their swipes held as waiting:
kept and displayed rather than binned, and counted the moment the day they are
down for takes the lead.

**The winning day is decided in three steps**, each reached only when the one
before it draws: most people (a maybe counts as a body), then fewest maybes,
then nearest the weekend. The last one always separates them.

**Opening hours are enforced, not decorative.** A place that cannot host the
winning day never wins it — the sheet names the more popular place and says it
is shut, rather than quietly promoting the runner-up. A place whose season has
ended, or whose hours miss the evening entirely, leaves the ballot by itself.

**An outdoor place on a wet day gets a warning**, not a demotion. People are
allowed to sit in the rain; they just should not be surprised by it.

**Past weeks are read back from the votes already stored.** Each card shows how
long ago we were last there, and the tally lists recent weeks, so nobody
proposes the same pub four Thursdays running.

**Winning the vote is not the same as being where we went**, and an admin can
say so. Article IV has a form — visible only to admins — for writing down the
day and the place a week actually ended up at: the winner was shut, six people
walked past it and went next door, somebody had a birthday. The record overrides
that week in the archive and in the "we were there recently" note on the cards.
It changes no votes, and the ballot's own verdict stays on the sheet underneath,
relabelled *what the vote said*. Weeks without a correction — nearly all of
them — behave exactly as they always did.

The swipe deck is **dealt in a different order to every voter**, so the top of
`places.yml` does not get judged while everyone is still interested while the
bottom gets rushed. The order is derived from your name and the week: stable
every time you open the sheet — a deck that reordered itself between swipes
would be unusable — different from everyone else's, and reshuffled next Monday.

**You sign in with GitHub, and pick your own name.** They are separate on
purpose. Votes are filed under the GitHub account id — a number nobody can
change and nobody else can claim — while the name on the sheet is yours to
change whenever you like. Renaming yourself rewrites the name on every mark you
have ever made and moves no votes at all, because nothing was ever keyed on it.

The GitHub account also settles who is who, which the old name box could not:
two people typing "Jonas" used to be one voter overwriting the other.

Everyone with a GitHub account can sign in — the login is there to tell people
apart, not to keep them out. Admins are the exception and are named by handle in
`ADMIN_USERS`, which is a restart rather than a database edit; they get the
LiveDashboard at `/admin/dashboard`, and the minutes described below.

The sheet is readable signed out. **Reset my vote** in Article I clears your own
days and swipes for the week and leaves everyone else's marks alone; **Undo**
under the deck takes back just the last swipe.
